unit Lzma.MtDec;

interface

uses
  System.Classes,
  System.SyncObjs,
  System.SysUtils;

type
  TLzmaMtDecodeProc = reference to procedure(const Index: Integer; const Input: TBytes; var Output: TBytes);
  TLzmaMtDecodeToStreamProc = reference to procedure(const Index: Integer; const Input: TBytes;
    const Destination: TStream);
  TLzmaMtAfterWriteProc = reference to procedure(const Index: Integer);
  TLzmaMtCancelProc = reference to procedure;
  TLzmaMtWaitProc = reference to function: Boolean;

  TLzmaMtDecode = class
  public
    class function DecodeOrdered(const Units: TArray<TBytes>; const ThreadCount: Integer;
      const DecodeProc: TLzmaMtDecodeProc; const WaitProc: TLzmaMtWaitProc = nil): TArray<TBytes>; static;
    class function DecodeOrderedToBytes(const Units: TArray<TBytes>; const OutputOffsets: TArray<UInt64>;
      const OutputSizes: TArray<UInt64>; const TotalOutputSize: UInt64; const ThreadCount: Integer;
      const DecodeProc: TLzmaMtDecodeToStreamProc; const WaitProc: TLzmaMtWaitProc = nil): TBytes; static;
    class procedure DecodeOrderedToStream(const Units: TArray<TBytes>; const OutputSizes: TArray<UInt64>;
      const Destination: TStream; const ThreadCount: Integer; const DecodeProc: TLzmaMtDecodeToStreamProc;
      const WaitProc: TLzmaMtWaitProc = nil; const AfterWriteProc: TLzmaMtAfterWriteProc = nil;
      const CancelProc: TLzmaMtCancelProc = nil); static;
  end;

implementation

uses
  Lzma.Errors,
  Lzma.Streams,
  Lzma.Types;

type
  TLzmaMtOutputUnit = record
    Ready: Boolean;
    Data: TBytes;
  end;

  TLzmaSliceWriteStream = class(TStream)
  private
    FBase: PByte;
    FCapacity: UInt64;
    FPosition: UInt64;
  public
    constructor Create(const Base: PByte; const Capacity: UInt64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Position64: UInt64 read FPosition;
  end;

function SlicePtr(const Base: PByte; const Offset: UInt64): PByte;
begin
  if Offset > UInt64(High(NativeUInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'MT decode output offset is too large for this process');
  if Base = nil then
    Exit(nil);
  Result := PByte(NativeUInt(Base) + NativeUInt(Offset));
end;

constructor TLzmaSliceWriteStream.Create(const Base: PByte; const Capacity: UInt64);
begin
  inherited Create;
  FBase := Base;
  FCapacity := Capacity;
  FPosition := 0;
end;

function TLzmaSliceWriteStream.Read(var Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'MT decode output slice is write-only');
  Result := 0;
end;

function TLzmaSliceWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  if UInt64(Count) > FCapacity - FPosition then
    RaiseLzmaError(SZ_ERROR_OUTPUT_EOF, 'MT decode output slice overflow');
  Move(Buffer, FBase[NativeUInt(FPosition)], Count);
  Inc(FPosition, UInt64(Count));
  Result := Count;
end;

function TLzmaSliceWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  NewPosition: Int64;
begin
  case Origin of
    soBeginning:
      NewPosition := Offset;
    soCurrent:
      NewPosition := Int64(FPosition) + Offset;
    soEnd:
      NewPosition := Int64(FCapacity) + Offset;
  else
    NewPosition := Int64(FPosition);
  end;
  if (NewPosition < 0) or (UInt64(NewPosition) > FCapacity) then
    RaiseLzmaError(SZ_ERROR_OUTPUT_EOF, 'MT decode output slice seek is out of range');
  FPosition := UInt64(NewPosition);
  Result := NewPosition;
end;

class function TLzmaMtDecode.DecodeOrdered(const Units: TArray<TBytes>; const ThreadCount: Integer;
  const DecodeProc: TLzmaMtDecodeProc; const WaitProc: TLzmaMtWaitProc): TArray<TBytes>;
var
  Outputs: TArray<TBytes>;
  Threads: array of TThread;
  Lock: TObject;
  DoneEvent: TEvent;
  NextIndex: Integer;
  HasError: Boolean;
  ErrorCode: SRes;
  ErrorMessage: string;
  WorkerCount: Integer;

  procedure DecodeSequential;
  var
    I: Integer;
  begin
    for I := 0 to High(Units) do
      DecodeProc(I, Units[I], Outputs[I]);
  end;

  function NewWorker: TThread;
  begin
    Result := TThread.CreateAnonymousThread(
      procedure
      var
        Index: Integer;
        Decoded: TBytes;
      begin
        while True do
        begin
          TMonitor.Enter(Lock);
          try
            if HasError or (NextIndex >= Length(Units)) then
              Index := -1
            else
            begin
              Index := NextIndex;
              Inc(NextIndex);
            end;
          finally
            TMonitor.Exit(Lock);
          end;
          if Index < 0 then
          begin
            DoneEvent.SetEvent;
            Exit;
          end;
          try
            SetLength(Decoded, 0);
            DecodeProc(Index, Units[Index], Decoded);
            Outputs[Index] := Decoded;
            DoneEvent.SetEvent;
          except
            on E: Exception do
            begin
              TMonitor.Enter(Lock);
              try
                if not HasError then
                begin
                  HasError := True;
                  if E is ELzmaError then
                    ErrorCode := ELzmaError(E).ResultCode
                  else
                    ErrorCode := SZ_ERROR_THREAD;
                  ErrorMessage := E.ClassName + ': ' + E.Message;
                end;
              finally
                TMonitor.Exit(Lock);
              end;
              DoneEvent.SetEvent;
              Exit;
            end;
          end;
        end;
      end);
    Result.FreeOnTerminate := False;
  end;

  function AnyThreadRunning: Boolean;
  var
    I: Integer;
  begin
    for I := 0 to High(Threads) do
      if not Threads[I].Finished then
        Exit(True);
    Result := False;
  end;

  procedure StoreCancellation;
  begin
    TMonitor.Enter(Lock);
    try
      if not HasError then
      begin
        HasError := True;
        ErrorCode := SZ_ERROR_PROGRESS;
        ErrorMessage := 'Operation cancelled';
      end;
    finally
      TMonitor.Exit(Lock);
    end;
    DoneEvent.SetEvent;
  end;

  procedure StoreWaitException(const E: Exception);
  begin
    TMonitor.Enter(Lock);
    try
      if not HasError then
      begin
        HasError := True;
        if E is ELzmaError then
          ErrorCode := ELzmaError(E).ResultCode
        else
          ErrorCode := SZ_ERROR_PROGRESS;
        ErrorMessage := E.ClassName + ': ' + E.Message;
      end;
    finally
      TMonitor.Exit(Lock);
    end;
    DoneEvent.SetEvent;
  end;

var
  I: Integer;
begin
  if not Assigned(DecodeProc) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'MT decode procedure is not assigned');

  SetLength(Outputs, Length(Units));
  if Length(Units) = 0 then
    Exit(Outputs);

  WorkerCount := ThreadCount;
  if WorkerCount < 1 then
    WorkerCount := 1;
  if WorkerCount > Length(Units) then
    WorkerCount := Length(Units);

  if WorkerCount = 1 then
  begin
    DecodeSequential;
    Exit(Outputs);
  end;

  Lock := TObject.Create;
  DoneEvent := TEvent.Create(nil, False, False, '');
  try
    NextIndex := 0;
    HasError := False;
    ErrorCode := SZ_OK;
    ErrorMessage := '';
    SetLength(Threads, WorkerCount);
    try
      for I := 0 to High(Threads) do
      begin
        Threads[I] := NewWorker;
        Threads[I].Start;
      end;

      while AnyThreadRunning do
      begin
        if Assigned(WaitProc) then
        begin
          try
            if WaitProc then
              StoreCancellation;
          except
            on E: Exception do
              StoreWaitException(E);
          end;
        end;
        if AnyThreadRunning then
          DoneEvent.WaitFor(10);
      end;

      for I := 0 to High(Threads) do
        Threads[I].WaitFor;
    finally
      for I := 0 to High(Threads) do
        Threads[I].Free;
    end;

    if HasError then
      RaiseLzmaError(ErrorCode, ErrorMessage);
  finally
    DoneEvent.Free;
    Lock.Free;
  end;

  Result := Outputs;
end;

class function TLzmaMtDecode.DecodeOrderedToBytes(const Units: TArray<TBytes>; const OutputOffsets: TArray<UInt64>;
  const OutputSizes: TArray<UInt64>; const TotalOutputSize: UInt64; const ThreadCount: Integer;
  const DecodeProc: TLzmaMtDecodeToStreamProc; const WaitProc: TLzmaMtWaitProc): TBytes;
var
  Threads: array of TThread;
  Lock: TObject;
  DoneEvent: TEvent;
  NextIndex: Integer;
  HasError: Boolean;
  ErrorCode: SRes;
  ErrorMessage: string;
  WorkerCount: Integer;
  Base: PByte;

  procedure DecodeSequential;
  var
    I: Integer;
    Slice: TLzmaSliceWriteStream;
  begin
    for I := 0 to High(Units) do
    begin
      Slice := TLzmaSliceWriteStream.Create(SlicePtr(Base, OutputOffsets[I]), OutputSizes[I]);
      try
        DecodeProc(I, Units[I], Slice);
        if Slice.Position64 <> OutputSizes[I] then
          RaiseLzmaError(SZ_ERROR_DATA, 'MT decode output size mismatch');
      finally
        Slice.Free;
      end;
    end;
  end;

  function NewWorker: TThread;
  begin
    Result := TThread.CreateAnonymousThread(
      procedure
      var
        Index: Integer;
        Slice: TLzmaSliceWriteStream;
      begin
        while True do
        begin
          TMonitor.Enter(Lock);
          try
            if HasError or (NextIndex >= Length(Units)) then
              Index := -1
            else
            begin
              Index := NextIndex;
              Inc(NextIndex);
            end;
          finally
            TMonitor.Exit(Lock);
          end;
          if Index < 0 then
            Exit;

          Slice := TLzmaSliceWriteStream.Create(SlicePtr(Base, OutputOffsets[Index]), OutputSizes[Index]);
          try
            try
              DecodeProc(Index, Units[Index], Slice);
              if Slice.Position64 <> OutputSizes[Index] then
                RaiseLzmaError(SZ_ERROR_DATA, 'MT decode output size mismatch');
            except
              on E: Exception do
              begin
                TMonitor.Enter(Lock);
                try
                  if not HasError then
                  begin
                    HasError := True;
                    if E is ELzmaError then
                      ErrorCode := ELzmaError(E).ResultCode
                    else
                      ErrorCode := SZ_ERROR_THREAD;
                    ErrorMessage := E.ClassName + ': ' + E.Message;
                  end;
                finally
                  TMonitor.Exit(Lock);
                end;
                DoneEvent.SetEvent;
                Exit;
              end;
            end;
          finally
            Slice.Free;
          end;
          DoneEvent.SetEvent;
        end;
      end);
    Result.FreeOnTerminate := False;
  end;

  function AnyThreadRunning: Boolean;
  var
    I: Integer;
  begin
    for I := 0 to High(Threads) do
      if not Threads[I].Finished then
        Exit(True);
    Result := False;
  end;

  procedure StoreCancellation;
  begin
    TMonitor.Enter(Lock);
    try
      if not HasError then
      begin
        HasError := True;
        ErrorCode := SZ_ERROR_PROGRESS;
        ErrorMessage := 'Operation cancelled';
      end;
    finally
      TMonitor.Exit(Lock);
    end;
    DoneEvent.SetEvent;
  end;

  procedure StoreWaitException(const E: Exception);
  begin
    TMonitor.Enter(Lock);
    try
      if not HasError then
      begin
        HasError := True;
        if E is ELzmaError then
          ErrorCode := ELzmaError(E).ResultCode
        else
          ErrorCode := SZ_ERROR_PROGRESS;
        ErrorMessage := E.ClassName + ': ' + E.Message;
      end;
    finally
      TMonitor.Exit(Lock);
    end;
    DoneEvent.SetEvent;
  end;

var
  I: Integer;
begin
  if not Assigned(DecodeProc) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'MT decode procedure is not assigned');
  if (Length(OutputOffsets) <> Length(Units)) or (Length(OutputSizes) <> Length(Units)) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'MT decode output layout does not match input units');
  if TotalOutputSize > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'MT decode output is too large for this process');
  for I := 0 to High(Units) do
    if (OutputOffsets[I] > TotalOutputSize) or (OutputSizes[I] > TotalOutputSize - OutputOffsets[I]) then
      RaiseLzmaError(SZ_ERROR_PARAM, 'MT decode output slice is out of range');

  SetLength(Result, Integer(TotalOutputSize));
  if Length(Units) = 0 then
    Exit;
  if TotalOutputSize = 0 then
    Base := nil
  else
    Base := @Result[0];

  WorkerCount := ThreadCount;
  if WorkerCount < 1 then
    WorkerCount := 1;
  if WorkerCount > Length(Units) then
    WorkerCount := Length(Units);

  if WorkerCount = 1 then
  begin
    DecodeSequential;
    Exit;
  end;

  Lock := TObject.Create;
  DoneEvent := TEvent.Create(nil, False, False, '');
  try
    NextIndex := 0;
    HasError := False;
    ErrorCode := SZ_OK;
    ErrorMessage := '';
    SetLength(Threads, WorkerCount);
    try
      for I := 0 to High(Threads) do
      begin
        Threads[I] := NewWorker;
        Threads[I].Start;
      end;

      while AnyThreadRunning do
      begin
        if Assigned(WaitProc) then
        begin
          try
            if WaitProc then
              StoreCancellation;
          except
            on E: Exception do
              StoreWaitException(E);
          end;
        end;
        if AnyThreadRunning then
          DoneEvent.WaitFor(10);
      end;

      for I := 0 to High(Threads) do
        Threads[I].WaitFor;
    finally
      for I := 0 to High(Threads) do
        Threads[I].Free;
    end;

    if HasError then
      RaiseLzmaError(ErrorCode, ErrorMessage);
  finally
    DoneEvent.Free;
    Lock.Free;
  end;
end;

class procedure TLzmaMtDecode.DecodeOrderedToStream(const Units: TArray<TBytes>; const OutputSizes: TArray<UInt64>;
  const Destination: TStream; const ThreadCount: Integer; const DecodeProc: TLzmaMtDecodeToStreamProc;
  const WaitProc: TLzmaMtWaitProc; const AfterWriteProc: TLzmaMtAfterWriteProc; const CancelProc: TLzmaMtCancelProc);
var
  Outputs: TArray<TLzmaMtOutputUnit>;
  Threads: array of TThread;
  Lock: TObject;
  DoneEvent: TEvent;
  NextIndex: Integer;
  NextToWrite: Integer;
  HasError: Boolean;
  ErrorCode: SRes;
  ErrorMessage: string;
  WorkerCount: Integer;

  procedure ValidateOutputSize(const Index: Integer);
  begin
    if OutputSizes[Index] > UInt64(High(Integer)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'MT decode output unit is too large for this process');
  end;

  function DecodeUnitToBytes(const Index: Integer): TBytes;
  var
    Base: PByte;
    Slice: TLzmaSliceWriteStream;
  begin
    ValidateOutputSize(Index);
    SetLength(Result, Integer(OutputSizes[Index]));
    if Length(Result) = 0 then
      Base := nil
    else
      Base := @Result[0];
    Slice := TLzmaSliceWriteStream.Create(Base, OutputSizes[Index]);
    try
      DecodeProc(Index, Units[Index], Slice);
      if Slice.Position64 <> OutputSizes[Index] then
        RaiseLzmaError(SZ_ERROR_DATA, 'MT decode output size mismatch');
    finally
      Slice.Free;
    end;
  end;

  procedure StoreException(const E: Exception; const DefaultCode: SRes);
  begin
    TMonitor.Enter(Lock);
    try
      if not HasError then
      begin
        HasError := True;
        if E is ELzmaError then
          ErrorCode := ELzmaError(E).ResultCode
        else
          ErrorCode := DefaultCode;
        ErrorMessage := E.ClassName + ': ' + E.Message;
      end;
    finally
      TMonitor.Exit(Lock);
    end;
    if Assigned(CancelProc) then
      CancelProc;
    DoneEvent.SetEvent;
  end;

  procedure DecodeSequential;
  var
    I: Integer;
  begin
    for I := 0 to High(Units) do
    begin
      WriteBytes(Destination, DecodeUnitToBytes(I));
      if Assigned(AfterWriteProc) then
        AfterWriteProc(I);
    end;
  end;

  procedure DrainReadyOutputs;
  var
    Data: TBytes;
    WrittenIndex: Integer;
  begin
    while True do
    begin
      SetLength(Data, 0);
      TMonitor.Enter(Lock);
      try
        if HasError or (NextToWrite >= Length(Outputs)) or not Outputs[NextToWrite].Ready then
          Exit;
        WrittenIndex := NextToWrite;
        Data := Outputs[NextToWrite].Data;
        SetLength(Outputs[NextToWrite].Data, 0);
        Outputs[NextToWrite].Ready := False;
        Inc(NextToWrite);
      finally
        TMonitor.Exit(Lock);
      end;

      WriteBytes(Destination, Data);
      if Assigned(AfterWriteProc) then
        AfterWriteProc(WrittenIndex);
      DoneEvent.SetEvent;
    end;
  end;

  function NewWorker: TThread;
  begin
    Result := TThread.CreateAnonymousThread(
      procedure
      var
        Index: Integer;
        Decoded: TBytes;
        Base: PByte;
        Slice: TLzmaSliceWriteStream;
      begin
        while True do
        begin
          TMonitor.Enter(Lock);
          try
            if HasError or (NextIndex >= Length(Units)) then
              Index := -1
            else if (NextIndex - NextToWrite) >= WorkerCount then
              Index := -2
            else
            begin
              Index := NextIndex;
              Inc(NextIndex);
            end;
          finally
            TMonitor.Exit(Lock);
          end;
          if Index = -2 then
          begin
            DoneEvent.WaitFor(10);
            Continue;
          end;
          if Index < 0 then
          begin
            DoneEvent.SetEvent;
            Exit;
          end;

          try
            if OutputSizes[Index] > UInt64(High(Integer)) then
              RaiseLzmaError(SZ_ERROR_MEM, 'MT decode output unit is too large for this process');
            SetLength(Decoded, Integer(OutputSizes[Index]));
            if Length(Decoded) = 0 then
              Base := nil
            else
              Base := @Decoded[0];
            Slice := TLzmaSliceWriteStream.Create(Base, OutputSizes[Index]);
            try
              DecodeProc(Index, Units[Index], Slice);
              if Slice.Position64 <> OutputSizes[Index] then
                RaiseLzmaError(SZ_ERROR_DATA, 'MT decode output size mismatch');
            finally
              Slice.Free;
            end;

            TMonitor.Enter(Lock);
            try
              if not HasError then
              begin
                Outputs[Index].Data := Decoded;
                Outputs[Index].Ready := True;
              end;
            finally
              TMonitor.Exit(Lock);
            end;
            DoneEvent.SetEvent;
            SetLength(Decoded, 0);
          except
            on E: Exception do
            begin
              TMonitor.Enter(Lock);
              try
                if not HasError then
                begin
                  HasError := True;
                  if E is ELzmaError then
                    ErrorCode := ELzmaError(E).ResultCode
                  else
                    ErrorCode := SZ_ERROR_THREAD;
                  ErrorMessage := E.ClassName + ': ' + E.Message;
                end;
              finally
                TMonitor.Exit(Lock);
              end;
              if Assigned(CancelProc) then
                CancelProc;
              DoneEvent.SetEvent;
              Exit;
            end;
          end;
        end;
      end);
    Result.FreeOnTerminate := False;
  end;

  procedure StoreCancellation;
  begin
    TMonitor.Enter(Lock);
    try
      if not HasError then
      begin
        HasError := True;
        ErrorCode := SZ_ERROR_PROGRESS;
        ErrorMessage := 'Operation cancelled';
      end;
    finally
      TMonitor.Exit(Lock);
    end;
    if Assigned(CancelProc) then
      CancelProc;
    DoneEvent.SetEvent;
  end;

var
  I: Integer;
begin
  if not Assigned(DecodeProc) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'MT decode procedure is not assigned');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'MT decode destination stream is not assigned');
  if Length(OutputSizes) <> Length(Units) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'MT decode output layout does not match input units');

  if Length(Units) = 0 then
    Exit;

  WorkerCount := ThreadCount;
  if WorkerCount < 1 then
    WorkerCount := 1;
  if WorkerCount > Length(Units) then
    WorkerCount := Length(Units);

  if WorkerCount = 1 then
  begin
    DecodeSequential;
    Exit;
  end;

  Lock := TObject.Create;
  DoneEvent := TEvent.Create(nil, False, False, '');
  try
    SetLength(Outputs, Length(Units));
    NextIndex := 0;
    NextToWrite := 0;
    HasError := False;
    ErrorCode := SZ_OK;
    ErrorMessage := '';
    SetLength(Threads, WorkerCount);
    try
      for I := 0 to High(Threads) do
      begin
        Threads[I] := NewWorker;
        Threads[I].Start;
      end;

      while (not HasError) and (NextToWrite < Length(Outputs)) do
      begin
        try
          DrainReadyOutputs;
        except
          on E: Exception do
            StoreException(E, SZ_ERROR_WRITE);
        end;

        if Assigned(WaitProc) then
        begin
          try
            if WaitProc then
              StoreCancellation;
          except
            on E: Exception do
              StoreException(E, SZ_ERROR_PROGRESS);
          end;
        end;
        if (not HasError) and (NextToWrite < Length(Outputs)) then
          DoneEvent.WaitFor(10);
      end;

      for I := 0 to High(Threads) do
        Threads[I].WaitFor;
    finally
      for I := 0 to High(Threads) do
        Threads[I].Free;
    end;

    if HasError then
      RaiseLzmaError(ErrorCode, ErrorMessage);
  finally
    DoneEvent.Free;
    Lock.Free;
  end;
end;

end.
