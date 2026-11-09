unit Lzma2.Encoder;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.Types;

type
  TLzma2Encoder = class
  private
    class procedure EncodeRawCore(Source: TStream; Destination: TStream;
      const Options: TLzma2Options; const AlgorithmOverride: Integer;
      const Progress: TLzma2ProgressEvent); static;
  public
    class function NormalizeOptions(const Options: TLzma2Options): TLzma2Options; static;
    class function DictionaryInfo(const Options: TLzma2Options): TLzma2DictionaryInfo; static;
    class procedure EncodeRaw(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure EncodeRawWithAlgorithm(Source: TStream; Destination: TStream;
      const Options: TLzma2Options; const Algorithm: Integer;
      const Progress: TLzma2ProgressEvent = nil); static;
    class function EncodeRawBytes(const Source: TBytes; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil): TBytes; static;
  end;

implementation

uses
  System.SyncObjs,
  Lzma.Alloc,
  Lzma.Encoder,
  Lzma.Errors,
  Lzma.MatchFinder,
  Lzma.Streams;

const
  LZMA2_ALGORITHM_FROM_LEVEL = -1;
  LZMA2_COPY_HEADER_SIZE = 3;
  LZMA2_LZMA_CHUNK_SIZE = 1 shl 21;
  LZMA2_MT_BATCH_SIZE = 64 shl 20;

type
  TLzma2WorkerOutputStream = class(TMemoryStream)
  private
    FBytes: TBytes;
    FMaximumCapacity: NativeUInt;
  protected
    function Realloc(var NewCapacity: NativeInt): Pointer; override;
  public
    constructor Create(const InputSize: UInt64);
    property Bytes: TBytes read FBytes;
  end;

  TLzma2OutputChunk = record
    Diagnostics: TLzma2EncodeDiagnostics;
    Data: TBytes;
    Completed: Boolean;
    ErrorCode: SRes;
    ErrorMessage: string;
  end;

  TLzma2ChunkJob = class
  public
    Index: Integer;
    Input: TBytes;
    Count: Integer;
    Props: TLzmaProps;
    Profile: TLzmaEncoderProfile;
    BufferSize: NativeUInt;
    MemoryLimit: UInt64;
    CancelFlag: PInteger;
    Output: TLzma2OutputChunk;
    procedure Execute;
  end;

function BuildLzma2CopyChunk(const Chunk: TBytes; const Count: Integer; const ResetDictionary: Boolean): TBytes;
begin
  SetLength(Result, Count + LZMA2_COPY_HEADER_SIZE);
  Result[0] := LZMA2_CONTROL_COPY_NO_RESET;
  if ResetDictionary then
    Result[0] := LZMA2_CONTROL_COPY_RESET_DIC;
  Result[1] := Byte((Count - 1) shr 8);
  Result[2] := Byte(Count - 1);
  if Count > 0 then
    Move(Chunk[0], Result[LZMA2_COPY_HEADER_SIZE], Count);
end;


constructor TLzma2WorkerOutputStream.Create(const InputSize: UInt64);
var
  Maximum: UInt64;
begin
  inherited Create;
  Maximum := TLzmaRawEncoder.MaximumLzma2EncodedSize(InputSize);
  if Maximum > UInt64(High(NativeInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA2 worker output exceeds native capacity');
  FMaximumCapacity := NativeUInt(Maximum);
end;

function TLzma2WorkerOutputStream.Realloc(var NewCapacity: NativeInt): Pointer;
var
  Growth: NativeUInt;
begin
  if (NewCapacity < 0) or (NativeUInt(NewCapacity) > FMaximumCapacity) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA2 worker output bound exceeded');
  if NewCapacity = 0 then
  begin
    FBytes := nil;
    Exit(nil);
  end;
  if NewCapacity <= Capacity then
    NewCapacity := Capacity
  else
  begin
    Growth := NativeUInt(Capacity);
    if Growth = 0 then Growth := SizeOf(Byte)
    else if Growth > FMaximumCapacity div 2 then Growth := FMaximumCapacity
    else Growth := Growth * 2;
    if Growth < NativeUInt(NewCapacity) then Growth := NativeUInt(NewCapacity);
    NewCapacity := NativeInt(Growth);
    SetLength(FBytes, NewCapacity);
  end;
  Result := Pointer(FBytes);
end;

procedure TLzma2ChunkJob.Execute;
var
  InputStream: TBytesStream;
  OutputStream: TLzma2WorkerOutputStream;
  EncodedSize: NativeInt;
  WorkerProgress: TLzma2ProgressEvent;
begin
  try
    if (Count < 0) or (Count <> Length(Input)) then
      RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid LZMA2 worker input');
    Output.Diagnostics := Default(TLzma2EncodeDiagnostics);
    InputStream := TBytesStream.Create(Input);
    try
      OutputStream := TLzma2WorkerOutputStream.Create(UInt64(Count));
      try
        WorkerProgress := procedure(const InBytes, OutBytes: UInt64; var Cancel: Boolean)
          begin
            Cancel := False;
            if CancelFlag <> nil then
              Cancel := TInterlocked.CompareExchange(CancelFlag^, 0, 0) <> 0;
          end;
        TLzmaRawEncoder.EncodeLzma2MtWorkerStream(InputStream, OutputStream, Profile, Props,
          WorkerProgress, @Output.Diagnostics, BufferSize, MemoryLimit);
        if (OutputStream.Size < 1) or
          (PByte(OutputStream.Memory)[NativeInt(OutputStream.Size) - 1] <> LZMA2_CONTROL_EOF) then
          RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA2 worker did not finish its stream');
        EncodedSize := NativeInt(OutputStream.Size) - 1;
        Output.Data := OutputStream.Bytes;
      finally
        OutputStream.Free;
      end;
    finally
      InputStream.Free;
    end;
    SetLength(Output.Data, EncodedSize);
  except
    on E: ELzmaError do
    begin
      Output.ErrorCode := E.ResultCode;
      Output.ErrorMessage := E.Message;
    end;
    on E: Exception do
    begin
      Output.ErrorCode := SZ_ERROR_THREAD;
      Output.ErrorMessage := E.ClassName + ': ' + E.Message;
    end;
  end;
  Input := nil;
  Output.Completed := True;
end;

class function TLzma2Encoder.NormalizeOptions(const Options: TLzma2Options): TLzma2Options;
var
  Props: TLzmaProps;
begin
  Result := Options;
  if Result.DictionarySize = 0 then
    Result.DictionarySize := DefaultDictionaryForLevel(Result.Level);
  if Result.ThreadCount < 1 then
    Result.ThreadCount := 1;
  Result.BufferSize := CheckedBufferSize(Result.BufferSize);
  if Result.Level = 0 then
  begin
    if Result.BufferSize > LZMA2_COPY_CHUNK_SIZE then
      Result.BufferSize := LZMA2_COPY_CHUNK_SIZE;
  end
  else if Result.BufferSize > LZMA2_LZMA_CHUNK_SIZE then
    Result.BufferSize := LZMA2_LZMA_CHUNK_SIZE;
  if (Result.ParserMode = lpmHighSpeed) and (Result.MatchFinderProfile = lmfpAuto) then
    Result.MatchFinderProfile := lmfpHashChain5;
  if (Result.FastBytes <> 0) and
    ((Result.FastBytes < LZMA_FAST_BYTES_MIN) or (Result.FastBytes > LZMA_FAST_BYTES_MAX)) then
    RaiseLzmaError(SZ_ERROR_PARAM, Format('Fast bytes must be 0 or in %d..%d',
      [LZMA_FAST_BYTES_MIN, LZMA_FAST_BYTES_MAX]));
  Props := TLzmaRawEncoder.DefaultProperties(Result.DictionarySize);
  if not TryApplyLzmaOptionsToProps(Props, Result, Result.Container <> lcLzma) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA lc/lp/pb options');
end;

class function TLzma2Encoder.DictionaryInfo(const Options: TLzma2Options): TLzma2DictionaryInfo;
var
  Normalized: TLzma2Options;
begin
  Normalized := NormalizeOptions(Options);
  if not TryLzma2PropertyFromDictionary(Normalized.DictionarySize, Normalized.StrictValidation, Result) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Dictionary size is not representable as an LZMA2 property');
end;

class procedure TLzma2Encoder.EncodeRaw(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
begin
  EncodeRawCore(Source, Destination, Options, LZMA2_ALGORITHM_FROM_LEVEL, Progress);
end;

class procedure TLzma2Encoder.EncodeRawWithAlgorithm(Source: TStream; Destination: TStream;
  const Options: TLzma2Options; const Algorithm: Integer; const Progress: TLzma2ProgressEvent);
begin
  if (Algorithm <> 0) and (Algorithm <> 1) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA encoder algorithm');
  EncodeRawCore(Source, Destination, Options, Algorithm, Progress);
end;

class procedure TLzma2Encoder.EncodeRawCore(Source: TStream; Destination: TStream;
  const Options: TLzma2Options; const AlgorithmOverride: Integer;
  const Progress: TLzma2ProgressEvent);
var
  Normalized: TLzma2Options;
  Info: TLzma2DictionaryInfo;
  Buffer: TBytes;
  ReadCount: Integer;
  EofByte: Byte;
  Props: TLzmaProps;
  ChunkBufferSize: NativeUInt;
  InTotal, OutTotal: UInt64;
  FirstChunk, UseCompressedChunks: Boolean;
  Profile: TLzmaEncoderProfile;

  procedure ApplyProfileOptionOverrides;
  begin
    case Normalized.MatchFinderProfile of
      lmfpHashChain4:
        begin
          Profile.MatchFinderKind := mfHashChain4;
          Profile.MatchFinderProfile := lmfpHashChain4;
          Profile.MatchFinder := 'hc4-diagnostic';
          Profile.NumHashBytes := 4;
        end;
      lmfpHashChain5:
        begin
          Profile.MatchFinderKind := mfHashChain5;
          Profile.MatchFinderProfile := lmfpHashChain5;
          Profile.MatchFinder := 'hc5-diagnostic';
          Profile.NumHashBytes := 5;
        end;
      lmfpBinaryTree4:
        begin
          Profile.MatchFinderKind := mfBinaryTree4;
          Profile.MatchFinderProfile := lmfpBinaryTree4;
          Profile.MatchFinder := 'bt4-diagnostic';
          Profile.NumHashBytes := 4;
        end;
    end;
    if Normalized.FastBytes <> 0 then
      Profile.FastBytes := Normalized.FastBytes;
    if Normalized.CutValue <> 0 then
      Profile.CutValue := Normalized.CutValue;
    Profile.ParserMode := Normalized.ParserMode;
  end;

  procedure ResetEncodeDiagnostics;
  begin
    if Normalized.EncodeDiagnostics = nil then
      Exit;
    Normalized.EncodeDiagnostics^.RequestedThreadCount := Normalized.ThreadCount;
    Normalized.EncodeDiagnostics^.ActualThreadCount := 1;
    Normalized.EncodeDiagnostics^.BatchCount := 0;
    Normalized.EncodeDiagnostics^.BlockCount := 0;
    Normalized.EncodeDiagnostics^.FastBytes := Profile.FastBytes;
    Normalized.EncodeDiagnostics^.NiceLen := Profile.FastBytes;
    Normalized.EncodeDiagnostics^.CutValue := Profile.CutValue;
    Normalized.EncodeDiagnostics^.XzBlockSize := Normalized.XzBlockSize;
    Normalized.EncodeDiagnostics^.ParserMode := Profile.ParserMode;
    Normalized.EncodeDiagnostics^.MatchFinderProfile := Profile.MatchFinderProfile;
    Normalized.EncodeDiagnostics^.NumHashBytes := Profile.NumHashBytes;
    Normalized.EncodeDiagnostics^.OptimumParserEnabled := False;
    Normalized.EncodeDiagnostics^.FullOptimumDecisionCount := 0;
    Normalized.EncodeDiagnostics^.CopyFastPathCount := 0;
    Normalized.EncodeDiagnostics^.IncompressibleFastPathCount := 0;
    Normalized.EncodeDiagnostics^.FallbackReason := 'none';
  end;

  procedure MergeCommittedDiagnostics(const Item: TLzma2EncodeDiagnostics);
  begin
    if Normalized.EncodeDiagnostics = nil then
      Exit;
    Inc(Normalized.EncodeDiagnostics^.BlockCount, Item.BlockCount);
    Inc(Normalized.EncodeDiagnostics^.FullOptimumDecisionCount, Item.FullOptimumDecisionCount);
    Inc(Normalized.EncodeDiagnostics^.CopyFastPathCount, Item.CopyFastPathCount);
    Inc(Normalized.EncodeDiagnostics^.IncompressibleFastPathCount, Item.IncompressibleFastPathCount);
    Normalized.EncodeDiagnostics^.OptimumParserEnabled :=
      Normalized.EncodeDiagnostics^.OptimumParserEnabled or Item.OptimumParserEnabled;
  end;

  procedure NoteBatch;
  begin
    if Normalized.EncodeDiagnostics <> nil then
      Inc(Normalized.EncodeDiagnostics^.BatchCount);
  end;

  procedure NoteCopyFastPath(const Incompressible: Boolean);
  begin
    if Normalized.EncodeDiagnostics = nil then
      Exit;
    Inc(Normalized.EncodeDiagnostics^.CopyFastPathCount);
    if Incompressible then
      Inc(Normalized.EncodeDiagnostics^.IncompressibleFastPathCount);
  end;

  procedure NoteMtActualWorkers(const Count: Integer);
  begin
    if Normalized.EncodeDiagnostics <> nil then
      Normalized.EncodeDiagnostics^.ActualThreadCount := Count;
  end;

  function TryGetSourceRemaining(out Remaining: UInt64): Boolean;
  var
    CurrentPosition: Int64;
    SourceSize: Int64;
  begin
    Remaining := 0;
    Result := False;

    try
      CurrentPosition := Source.Position;
      SourceSize := Source.Size;
    except
      Exit;
    end;
    if SourceSize < CurrentPosition then
      Exit;

    Remaining := UInt64(SourceSize - CurrentPosition);
    Result := True;
  end;

  function MtReadBufferSize: NativeUInt;
  var
    PartsPerJob: NativeUInt;
  begin
    PartsPerJob := LZMA2_MT_BATCH_SIZE div ChunkBufferSize;
    if PartsPerJob = 0 then
      PartsPerJob := 1;
    Result := PartsPerJob * ChunkBufferSize;
  end;

  function ShouldUseMtEncode: Boolean;
  var
    Remaining: UInt64;
    MinParallelInput: UInt64;
  begin
    Result := UseCompressedChunks and (Normalized.ThreadCount > 1);
    if not Result then
      Exit;

    MinParallelInput := UInt64(MtReadBufferSize) * 2;
    if TryGetSourceRemaining(Remaining) and (Remaining < MinParallelInput) then
      Result := False;
  end;

  function CopyMemoryRequired: UInt64;
  var
    PartCapacity: UInt64;
  begin
    PartCapacity := ChunkBufferSize;
    if PartCapacity > LZMA2_COPY_CHUNK_SIZE then PartCapacity := LZMA2_COPY_CHUNK_SIZE;
    // Buffer, the old local Chunk and its newly constructed copy packet coexist.
    Result := CheckedMemoryAdd(ChunkBufferSize,
      CheckedMemoryAdd(CheckedMemoryMultiply(PartCapacity, 2), LZMA2_COPY_HEADER_SIZE));
  end;

  procedure WorkerMemoryBudget(const WorkerCount: Integer; const ReadCapacity: NativeUInt;
    out Required, KernelLimit: UInt64);
  var
    OutputCapacity, KernelCapacity, SlotOuter, SlotCapacity, PoolCapacity, OtherSlots: UInt64;
  begin
    if WorkerCount < 1 then
      RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA2 worker count');
    OutputCapacity := TLzmaRawEncoder.MaximumLzma2EncodedSize(ReadCapacity);
    KernelCapacity := TLzmaRawEncoder.RequiredStreamingMemoryForInput(Profile, Props,
      ReadCapacity, ChunkBufferSize, True);
    // Job.Input shares the TBytesStream storage. Output old/new capacities may coexist.
    SlotOuter := CheckedMemoryAdd(ReadCapacity, CheckedMemoryMultiply(OutputCapacity, 2));
    SlotOuter := CheckedMemoryAdd(SlotOuter, CheckedMemoryAdd(TLzma2ChunkJob.InstanceSize,
      CheckedMemoryAdd(TBytesStream.InstanceSize, TLzma2WorkerOutputStream.InstanceSize)));
    SlotCapacity := CheckedMemoryAdd(SlotOuter, KernelCapacity);
    // These arrays and events persist after jobs finish. RTL threads/closures/OS overhead is separate.
    PoolCapacity := CheckedMemoryMultiply(UInt64(WorkerCount),
      CheckedMemoryAdd(SizeOf(TThread) + SizeOf(TLzma2ChunkJob) + SizeOf(TEvent) * 2 +
        SizeOf(TLzma2OutputChunk), CheckedMemoryMultiply(TEvent.InstanceSize, 2)));
    PoolCapacity := CheckedMemoryAdd(PoolCapacity, TEvent.InstanceSize);
    Required := CheckedMemoryAdd(PoolCapacity, CheckedMemoryMultiply(UInt64(WorkerCount), SlotCapacity));
    KernelLimit := 0;
    if Normalized.MemoryLimit <> 0 then
    begin
      // Every other pending/running/completed slot keeps its full fixed reservation.
      OtherSlots := CheckedMemoryMultiply(UInt64(WorkerCount - 1), SlotCapacity);
      OtherSlots := CheckedMemoryAdd(OtherSlots, CheckedMemoryAdd(PoolCapacity, SlotOuter));
      if OtherSlots < Normalized.MemoryLimit then
        KernelLimit := Normalized.MemoryLimit - OtherSlots;
    end;
  end;

  function MtMemoryFits: Boolean;
  var
    Required, KernelLimit: UInt64;
  begin
    WorkerMemoryBudget(Normalized.ThreadCount, MtReadBufferSize, Required, KernelLimit);
    Result := (Normalized.MemoryLimit = 0) or (Required <= Normalized.MemoryLimit);
    if not Result and (Normalized.EncodeDiagnostics <> nil) then
      Normalized.EncodeDiagnostics^.FallbackReason := 'memory-limit';
  end;

  procedure WriteCopyChunk(const Count: Integer; const ResetDictionary: Boolean; const Incompressible: Boolean);
  var
    Chunk: TBytes;
    Offset: Integer;
    PartCount: Integer;
    ResetThisChunk: Boolean;
  begin
    Offset := 0;
    ResetThisChunk := ResetDictionary;
    while Offset < Count do
    begin
      PartCount := Count - Offset;
      if PartCount > LZMA2_COPY_CHUNK_SIZE then
        PartCount := LZMA2_COPY_CHUNK_SIZE;
      SetLength(Chunk, PartCount);
      if PartCount > 0 then
        Move(Buffer[Offset], Chunk[0], PartCount);
      Chunk := BuildLzma2CopyChunk(Chunk, PartCount, ResetThisChunk);
      WriteBytes(Destination, Chunk);
      Inc(OutTotal, UInt64(Length(Chunk)));
      NoteCopyFastPath(Incompressible);
      ResetThisChunk := False;
      Inc(Offset, PartCount);
    end;
  end;

  procedure EncodeRawMt;
  var
    Results: array of TLzma2OutputChunk;
    Threads: array of TThread;
    Jobs: array of TLzma2ChunkJob;
    JobReady: array of TEvent;
    JobDone: array of TEvent;
    WorkerDone: TEvent;
    StopWorkers: Integer;
    CancelWorkers: Integer;
    Chunk: TBytes;
    LocalRead: Integer;
    MaxWorkers: Integer;
    ActiveCount: Integer;
    NextIndex: Integer;
    NextToWrite: Integer;
    FirstErrorCode: SRes;
    FirstErrorMessage: string;
    EndOfInput: Boolean;
    StopScheduling: Boolean;
    Slot: Integer;
    PeakActiveWorkers: Integer;
    ReadBufferSize: NativeUInt;
    ReadBufferByteCount: Integer;
    StartedJobCount: Integer;
    RequiredMemory, WorkerKernelLimit: UInt64;

    procedure CaptureError(const Code: SRes; const Msg: string);
    begin
      if FirstErrorCode = SZ_OK then
      begin
        FirstErrorCode := Code;
        FirstErrorMessage := Msg;
      end;
      StopScheduling := True;
      TInterlocked.Exchange(CancelWorkers, 1);
    end;

    procedure CaptureException(const E: Exception);
    begin
      if E is ELzmaError then
        CaptureError(ELzmaError(E).ResultCode, E.Message)
      else
        CaptureError(SZ_ERROR_THREAD, E.ClassName + ': ' + E.Message);
    end;

    function FindFreeSlot: Integer;
    begin
      for Result := 0 to High(Threads) do
        if Jobs[Result] = nil then
          Exit;
      Result := -1;
    end;

    function NewWorker(const ASlot: Integer): TThread;
    begin
      Result := TThread.CreateAnonymousThread(
        procedure
        begin
          while JobReady[ASlot].WaitFor = wrSignaled do
          begin
            if TInterlocked.CompareExchange(StopWorkers, 0, 0) <> 0 then
              Exit;
            try
              Jobs[ASlot].Execute;
            finally
              JobDone[ASlot].SetEvent;
              WorkerDone.SetEvent;
            end;
          end;
        end);
      Result.FreeOnTerminate := False;
    end;

    procedure StartWorker(const ASlot: Integer; const AIndex: Integer; const AChunk: TBytes;
      const ACount: Integer);
    var
      Job: TLzma2ChunkJob;
    begin
      Job := TLzma2ChunkJob.Create;
      Job.Index := AIndex;
      Job.Input := AChunk;
      Job.Count := ACount;
      Job.Props := Props;
      Job.Profile := Profile;
      Job.BufferSize := ChunkBufferSize;
      Job.MemoryLimit := WorkerKernelLimit;
      Job.CancelFlag := @CancelWorkers;
      Jobs[ASlot] := Job;
      NoteBatch;
      try
        if Threads[ASlot] = nil then
        begin
          JobReady[ASlot] := TEvent.Create(nil, False, False, '');
          JobDone[ASlot] := TEvent.Create(nil, True, False, '');
          Threads[ASlot] := NewWorker(ASlot);
          Threads[ASlot].Start;
        end;
        JobDone[ASlot].ResetEvent;
        JobReady[ASlot].SetEvent;
      except
        Jobs[ASlot] := nil;
        Job.Free;
        raise;
      end;
      Inc(ActiveCount);
      Inc(StartedJobCount);
      if ActiveCount > PeakActiveWorkers then
        PeakActiveWorkers := ActiveCount;
    end;

    function WaitForOneWorker: Integer;
    var
      SlotIndex: Integer;
    begin
      repeat
        for SlotIndex := 0 to High(Threads) do
          if (Jobs[SlotIndex] <> nil) and
            (JobDone[SlotIndex].WaitFor(0) = wrSignaled) then
            Exit(SlotIndex);
        if WorkerDone.WaitFor <> wrSignaled then
          RaiseLzmaError(SZ_ERROR_THREAD, 'Unable to wait for an encoder worker');
      until False;
    end;

    procedure FinishWorker(const ASlot: Integer);
    var
      ResultIndex: Integer;
      Job: TLzma2ChunkJob;
    begin
      Job := Jobs[ASlot];
      if Job = nil then
      begin
        CaptureError(SZ_ERROR_THREAD, 'Worker job state was lost');
        ResultIndex := -1;
      end
      else
        ResultIndex := Job.Index mod MaxWorkers;
      if Threads[ASlot] = nil then
        CaptureError(SZ_ERROR_THREAD, 'Worker thread state was lost')
      else
        if JobDone[ASlot].WaitFor <> wrSignaled then
          CaptureError(SZ_ERROR_THREAD, 'Unable to collect an encoder worker result');
      if (ResultIndex >= 0) and (ResultIndex < Length(Results)) then
      begin
        if not Job.Output.Completed then
        begin
          Job.Output.ErrorCode := SZ_ERROR_THREAD;
          Job.Output.ErrorMessage := 'Worker task failed before producing a result';
        end;
        Results[ResultIndex] := Job.Output;
        Results[ResultIndex].Completed := True;
        if Results[ResultIndex].ErrorCode <> SZ_OK then
          CaptureError(Results[ResultIndex].ErrorCode, Results[ResultIndex].ErrorMessage);
      end;
      if Job <> nil then
      begin
        Job.Output.Data := nil;
        Job.Free;
      end;
      Jobs[ASlot] := nil;
      Dec(ActiveCount);
    end;

    procedure ReportMtProgress;
    var
      Cancel: Boolean;
    begin
      if not Assigned(Progress) then
        Exit;
      Cancel := False;
      Progress(InTotal, OutTotal, Cancel);
      if Cancel then
        CaptureError(SZ_ERROR_PROGRESS, 'Operation cancelled');
    end;

    procedure DrainReadyResults;
    var
      ResultIndex: Integer;
    begin
      while NextToWrite < NextIndex do
      begin
        ResultIndex := NextToWrite mod MaxWorkers;
        if not Results[ResultIndex].Completed then
          Break;
        if Results[ResultIndex].ErrorCode <> SZ_OK then
        begin
          CaptureError(Results[ResultIndex].ErrorCode, Results[ResultIndex].ErrorMessage);
        end;
        if FirstErrorCode = SZ_OK then
        begin
          WriteBytes(Destination, Results[ResultIndex].Data);
          Inc(OutTotal, UInt64(Length(Results[ResultIndex].Data)));
          MergeCommittedDiagnostics(Results[ResultIndex].Diagnostics);
          ReportMtProgress;
        end;
        Results[ResultIndex] := Default(TLzma2OutputChunk);
        Inc(NextToWrite);
      end;
    end;

    procedure WaitAndFreeOutstandingJobs;
    var
      SlotIndex: Integer;
      Job: TLzma2ChunkJob;
    begin
      TInterlocked.Exchange(CancelWorkers, 1);
      TInterlocked.Exchange(StopWorkers, 1);
      for SlotIndex := 0 to High(Threads) do
        if Threads[SlotIndex] <> nil then
          JobReady[SlotIndex].SetEvent;
      for SlotIndex := 0 to High(Threads) do
      begin
        if Threads[SlotIndex] <> nil then
        begin
          try
            Threads[SlotIndex].WaitFor;
          except
            // Cleanup must not mask the original main-thread exception.
          end;
          Threads[SlotIndex].Free;
          Threads[SlotIndex] := nil;
        end;
        Job := Jobs[SlotIndex];
        if Job <> nil then
        begin
          Job.Input := nil;
          Job.Output.Data := nil;
          Job.Free;
          Jobs[SlotIndex] := nil;
        end;
        JobDone[SlotIndex].Free;
        JobReady[SlotIndex].Free;
      end;
      ActiveCount := 0;
      WorkerDone.Free;
  end;
begin
    MaxWorkers := Normalized.ThreadCount;
    ReadBufferSize := MtReadBufferSize;
    if ReadBufferSize > NativeUInt(High(Integer)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'LZMA2 MT read batch is too large');
    ReadBufferByteCount := Integer(ReadBufferSize);
    WorkerMemoryBudget(MaxWorkers, ReadBufferSize, RequiredMemory, WorkerKernelLimit);
    ValidateMemoryLimit(RequiredMemory, Normalized.MemoryLimit);

    SetLength(Threads, MaxWorkers);
    SetLength(Jobs, MaxWorkers);
    SetLength(JobReady, MaxWorkers);
    SetLength(JobDone, MaxWorkers);
    SetLength(Results, MaxWorkers);
    WorkerDone := nil;
    StopWorkers := 0;
    CancelWorkers := 0;

    ActiveCount := 0;
    NextIndex := 0;
    NextToWrite := 0;
    FirstErrorCode := SZ_OK;
    FirstErrorMessage := '';
    EndOfInput := False;
    StopScheduling := False;
    PeakActiveWorkers := 0;
    StartedJobCount := 0;

    try
      WorkerDone := TEvent.Create(nil, False, False, '');
      repeat
        while (not EndOfInput) and (not StopScheduling) and
          (NextIndex - NextToWrite < MaxWorkers) do
        begin
          try
            SetLength(Chunk, ReadBufferByteCount);
            LocalRead := ReadAvailable(Source, Chunk[0], Length(Chunk));
            if LocalRead = 0 then
            begin
              Chunk := nil;
              EndOfInput := True;
              Break;
            end;
            if LocalRead < Length(Chunk) then
              SetLength(Chunk, LocalRead);
          except
            on E: Exception do
            begin
              CaptureException(E);
              Break;
            end;
          end;

          Inc(InTotal, UInt64(LocalRead));
          Slot := FindFreeSlot;
          if Slot < 0 then
          begin
            CaptureError(SZ_ERROR_THREAD, 'No free worker slot');
            Break;
          end;
          try
            StartWorker(Slot, NextIndex, Chunk, LocalRead);
            Chunk := nil;
            Inc(NextIndex);
          except
            on E: Exception do
            begin
              CaptureException(E);
              Break;
            end;
          end;
        end;

        DrainReadyResults;
        if ActiveCount = 0 then
          Break;
        Slot := WaitForOneWorker;
        FinishWorker(Slot);
        DrainReadyResults;
      until False;

      while ActiveCount > 0 do
      begin
        Slot := WaitForOneWorker;
        FinishWorker(Slot);
        DrainReadyResults;
      end;

      DrainReadyResults;
    finally
      WaitAndFreeOutstandingJobs;
    end;
    if PeakActiveWorkers > 0 then
      NoteMtActualWorkers(PeakActiveWorkers)
    else
      NoteMtActualWorkers(1);
    if (FirstErrorCode = SZ_OK) and (StartedJobCount > 0) and (PeakActiveWorkers < 2) and
      (Normalized.EncodeDiagnostics <> nil) then
      Normalized.EncodeDiagnostics^.FallbackReason := 'insufficient-work';
    if FirstErrorCode <> SZ_OK then
      RaiseLzmaError(FirstErrorCode, FirstErrorMessage);
  end;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  Normalized := NormalizeOptions(Options);
  if AlgorithmOverride <> LZMA2_ALGORITHM_FROM_LEVEL then
  begin
    // Explicit SDK algorithms select compression, including level zero.
    Normalized.BufferSize := CheckedBufferSize(Options.BufferSize);
    if Normalized.BufferSize > LZMA2_LZMA_CHUNK_SIZE then
      Normalized.BufferSize := LZMA2_LZMA_CHUNK_SIZE;
  end;
  Info := DictionaryInfo(Normalized);
  UseCompressedChunks := (Normalized.Level > 0) or
    (AlgorithmOverride <> LZMA2_ALGORITHM_FROM_LEVEL);
  ChunkBufferSize := Normalized.BufferSize;
  Props := TLzmaRawEncoder.DefaultProperties(Info.NormalizedSize);
  if not TryApplyLzmaOptionsToProps(Props, Normalized, True) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA2 lc/lp/pb options');
  Profile := TLzmaRawEncoder.NormalizeProfile(Normalized.Level, Info.NormalizedSize);
  if AlgorithmOverride <> LZMA2_ALGORITHM_FROM_LEVEL then
    Profile.Algorithm := AlgorithmOverride;
  ApplyProfileOptionOverrides;
  ResetEncodeDiagnostics;
  InTotal := 0;
  OutTotal := 0;
  FirstChunk := True;

  if ShouldUseMtEncode and MtMemoryFits then
    EncodeRawMt
  else
  begin
    if (Normalized.ThreadCount > 1) and (Normalized.EncodeDiagnostics <> nil) and
      (Normalized.EncodeDiagnostics^.FallbackReason = 'none') then
      Normalized.EncodeDiagnostics^.FallbackReason := 'single-thread-scheduling';
    if UseCompressedChunks then
    begin
      TLzmaRawEncoder.EncodeLzma2Stream(Source, Destination, Profile, Props,
        Progress, Normalized.EncodeDiagnostics, ChunkBufferSize, Normalized.MemoryLimit);
      Exit;
    end;
    ValidateMemoryLimit(CopyMemoryRequired, Normalized.MemoryLimit);
    SetLength(Buffer, ChunkBufferSize);
    repeat
      ReadCount := ReadAvailable(Source, Buffer[0], Length(Buffer));
      if ReadCount > 0 then
      begin
        Inc(InTotal, UInt64(ReadCount));
        WriteCopyChunk(ReadCount, FirstChunk, False);
        FirstChunk := False;
        ReportProgress(Progress, InTotal, OutTotal);
      end;
    until ReadCount = 0;
  end;

  EofByte := LZMA2_CONTROL_EOF;
  WriteExact(Destination, EofByte, 1);
  Inc(OutTotal);
  ReportProgress(Progress, InTotal, OutTotal);
end;

class function TLzma2Encoder.EncodeRawBytes(const Source: TBytes; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent): TBytes;
var
  InStream: TBytesStream;
  OutStream: TMemoryStream;
begin
  InStream := TBytesStream.Create(Source);
  OutStream := TMemoryStream.Create;
  try
    EncodeRaw(InStream, OutStream, Options, Progress);
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

end.
