unit Lzma2Benchmark;

interface

uses System.Classes, System.SysUtils, System.SyncObjs;

type
  TBenchmarkState = (bsIdle, bsPreparing, bsCompressing, bsDecompressing,
    bsComplete, bsCancelled, bsError);

  TBenchmarkConfig = record
    DictionarySize: UInt64;
    Workers, Passes, PhaseMilliseconds: Integer;
    MemoryLimit: UInt64;
  end;

  TBenchmarkMetric = record
    Bytes, Iterations: UInt64;
    WallSeconds, CpuSeconds, Commands: Double;
    function SpeedKiB: Double;
    function UsagePercent: Double;
    function RatingMips: Double;
    function RatingPerUsage: Double;
    procedure Add(const Other: TBenchmarkMetric);
  end;

  TBenchmarkSnapshot = record
    State: TBenchmarkState;
    Config: TBenchmarkConfig;
    CompletedPasses: Integer;
    ElapsedMilliseconds: Int64;
    RequiredMemory: UInt64;
    CurrentCompression, CurrentDecompression: TBenchmarkMetric;
    AverageCompression, AverageDecompression: TBenchmarkMetric;
    ErrorText: string;
    function Finished: Boolean;
  end;

  TLzmaBenchmark = class
  private
    FConfig: TBenchmarkConfig;
    FLock: TCriticalSection;
    FSnapshot: TBenchmarkSnapshot;
    FCoordinator: TThread;
    FCancel, FActiveWorkers: Integer;
    FStartTick: Int64;
    procedure Run;
    procedure ChangeState(const State: TBenchmarkState);
  public
    constructor Create(const Config: TBenchmarkConfig);
    destructor Destroy; override;
    procedure Start;
    procedure Cancel;
    procedure Wait;
    function Snapshot: TBenchmarkSnapshot;
    function ActiveWorkers: Integer;
    class function RequiredMemory(const Config: TBenchmarkConfig): UInt64; static;
    class function AutoWorkers(const DictionarySize, MemoryLimit: UInt64;
      const CpuCount: Integer): Integer; static;
    class function MaximumDictionarySize: UInt64; static;
  end;

function BenchmarkData(const DictionaryBits: Integer; const Count: NativeInt; const Salt: UInt32;
  const IsCancelled: TFunc<Boolean> = nil): TBytes;
function CompressionComplexity(const DictionarySize: UInt64): UInt64;

implementation

uses System.Math, System.Diagnostics, Winapi.Windows, Lzma.Api, Lzma.Types,
  Lzma.Errors, Lzma.Encoder;

const
  MiB = UInt64(1024 * 1024);
  AdditionalData = 65536;

type
  TFixedBufferStream = class(TStream)
  private
    FBuffer: TBytes;
    FPosition, FLength: Int64;
  public
    constructor Create(const Capacity: NativeInt);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    procedure Reset;
    function Data: Pointer;
    property Length: Int64 read FLength;
  end;

  TBenchmarkWorker = class(TThread)
  private
    FData: TBytes;
    FSource: TBytesStream;
    FPacked, FDecoded: TFixedBufferStream;
    FOptions: TLzma2Options;
    FBegin, FDone: TEvent;
    FCancel, FActive: PInteger;
    FStop, FStarted, FCompression: Boolean;
    FDuration: Integer;
    FIterations, FBytes: UInt64;
    FCommands: Double;
    FError: string;
    procedure Progress(const InBytes, OutBytes: UInt64; var Cancel: Boolean);
  protected
    procedure Execute; override;
  public
    constructor CreateWorker(const Data: TBytes; const Options: TLzma2Options;
      const CancelFlag, ActiveCount: PInteger; const Duration: Integer);
    destructor Destroy; override;
    procedure StartWorker;
    procedure BeginPhase(const Compressing: Boolean);
    procedure Await;
  end;

function TBenchmarkMetric.SpeedKiB: Double;
begin
  Result := 0;
  if WallSeconds > 0 then Result := Bytes / WallSeconds / 1024;
end;

function TBenchmarkMetric.UsagePercent: Double;
begin
  Result := 0;
  if WallSeconds > 0 then Result := 100 * CpuSeconds / WallSeconds;
end;

function TBenchmarkMetric.RatingMips: Double;
begin
  Result := 0;
  if WallSeconds > 0 then Result := Commands / WallSeconds / 1000000;
end;

function TBenchmarkMetric.RatingPerUsage: Double;
begin
  Result := 0;
  if CpuSeconds > 0 then Result := Commands / CpuSeconds / 1000000;
end;

procedure TBenchmarkMetric.Add(const Other: TBenchmarkMetric);
begin
  Inc(Bytes, Other.Bytes);
  Inc(Iterations, Other.Iterations);
  WallSeconds := WallSeconds + Other.WallSeconds;
  CpuSeconds := CpuSeconds + Other.CpuSeconds;
  Commands := Commands + Other.Commands;
end;

function TBenchmarkSnapshot.Finished: Boolean;
begin
  Result := State in [bsComplete, bsCancelled, bsError];
end;

function CompressionComplexity(const DictionarySize: UInt64): UInt64;
var Size: UInt64;
    Bits, SubLog: UInt64;
begin
  Size := Max(DictionarySize, UInt64(1) shl 18);
  Bits := 0;
  while (Size shr (Bits + 1) <> 0) and (Bits < 62) do Inc(Bits);
  if Bits >= 8 then SubLog := (Size shr (Bits - 8)) and 255
  else SubLog := (Size shl (8 - Bits)) and 255;
  SubLog := Bits * 256 + SubLog - 18 * 256;
  Result := 870 + ((SubLog * SubLog * 5) shr 16);
end;

function BenchmarkData(const DictionaryBits: Integer; const Count: NativeInt; const Salt: UInt32;
  const IsCancelled: TFunc<Boolean>): TBytes;
var A, B, R: UInt32;
    Pos, Distance: NativeInt;
    Len, Bits, MaxBits, LogBits, NewBits, I: Integer;
  function RandomWord: UInt32;
  begin
    A := UInt32(36969 * (A and $FFFF) + (A shr 16));
    B := UInt32(18000 * (B and $FFFF) + (B shr 16));
    Result := Salt xor UInt32((UInt64(A) shl 16) + B);
  end;
  function Take(const N: Integer): UInt32;
  begin
    Result := R and ((UInt32(1) shl N) - 1);
    R := R shr N;
  end;
  function LengthBits: Integer;
  var N: Integer;
  begin N := Integer(Take(2)); Result := Integer(Take(1 + N)); end;
begin
  if (DictionaryBits < 10) or
    (DictionaryBits > 22+SizeOf(NativeInt) div 4*5) or (Count < 1024) then
    raise EArgumentException.Create('Invalid benchmark data dimensions');
  if Assigned(IsCancelled) and IsCancelled() then Exit(nil);
  SetLength(Result, Count);
  A := 362436069;
  B := 521288629;
  Pos := 0;
  Distance := 1;
  Bits := 1;
  while Pos < Count do
  begin
    if ((Pos and $FFFF) < 64) and Assigned(IsCancelled) and IsCancelled() then
      Exit(nil);
    R := RandomWord;
    if (Take(1) = 0) or (Pos < 1024) then
    begin
      Result[Pos] := Byte(R and 255);
      Inc(Pos);
    end
    else
    begin
      Len := 1 + LengthBits;
      if Take(3) <> 0 then
      begin
        Inc(Len, LengthBits);
        while (UInt64(1) shl Bits) < UInt64(Pos) do Inc(Bits);
        MaxBits := Min(DictionaryBits, Bits);
        LogBits := 5;
        if MaxBits <= 21 then LogBits := 4;
        repeat
          NewBits := Integer(Take(LogBits)) + 6;
          R := RandomWord;
          if NewBits > MaxBits then Continue;
          Distance := NativeInt(UInt64(R) and ((UInt64(1) shl NewBits) - 1));
          if Distance < Pos then Break;
          R := RandomWord;
        until False;
        Inc(Distance);
      end;
      Len := Integer(Min(NativeInt(Len), Count - Pos));
      for I := 0 to Len - 1 do Result[Pos + I] := Result[Pos + I - Distance];
      Inc(Pos, Len);
    end;
  end;
end;

constructor TFixedBufferStream.Create(const Capacity: NativeInt);
begin
  inherited Create;
  SetLength(FBuffer, Capacity);
end;

function TFixedBufferStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Count < 0 then raise EReadError.Create('Negative benchmark read');
  Result := Integer(Max(Int64(0), Min(Int64(Count), FLength - FPosition)));
  if Result > 0 then Move(FBuffer[NativeInt(FPosition)], Buffer, Result);
  Inc(FPosition, Result);
end;

function TFixedBufferStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count < 0) or (FPosition > System.Length(FBuffer) - Int64(Count)) then
    raise EWriteError.Create('Benchmark output exceeds its reserved buffer');
  if Count > 0 then Move(Buffer, FBuffer[NativeInt(FPosition)], Count);
  Inc(FPosition, Count);
  FLength := Max(FLength, FPosition);
  Result := Count;
end;

function TFixedBufferStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var Position: Int64;
begin
  case Origin of
    soBeginning: Position := Offset;
    soCurrent: Position := FPosition + Offset;
    soEnd: Position := FLength + Offset;
  else raise EStreamError.Create('Invalid benchmark seek origin');
  end;
  if (Position < 0) or (Position > System.Length(FBuffer)) then
    raise EStreamError.Create('Benchmark seek outside reserved buffer');
  FPosition := Position;
  Result := Position;
end;

procedure TFixedBufferStream.Reset;
begin FPosition := 0; FLength := 0; end;

function TFixedBufferStream.Data: Pointer;
begin Result := Pointer(FBuffer); end;

function KernelMemory(const DictionarySize: UInt64): UInt64;
var Profile: TLzmaEncoderProfile;
    Props: TLzmaProps;
begin
  Profile := TLzmaRawEncoder.NormalizeProfile(5, DictionarySize);
  Props := TLzmaRawEncoder.DefaultProperties(DictionarySize);
  Result := TLzmaRawEncoder.RequiredStreamingMemoryForInput(Profile, Props,
    DictionarySize + AdditionalData, 1 shl 20, False);
end;

function OuterMemory(const DictionarySize: UInt64): UInt64;
begin
  // Input, bounded output/decoded streams and source/allocator/RTL headroom.
  Result := (DictionarySize + AdditionalData) * 6 + 33 * MiB;
end;

class function TLzmaBenchmark.MaximumDictionarySize: UInt64;
begin
  // Same size_t-dependent limit as SDK 26.05 BenchmarkDialog.cpp.
  Result:=UInt64(1) shl (22+SizeOf(NativeInt) div 4*5);
end;

class function TLzmaBenchmark.RequiredMemory(const Config: TBenchmarkConfig): UInt64;
var PerWorker:UInt64;
begin
  if (Config.DictionarySize < MiB) or
    (Config.DictionarySize > MaximumDictionarySize) or
    ((Config.DictionarySize and (Config.DictionarySize - 1)) <> 0) then
    raise EArgumentException.Create('Benchmark dictionary exceeds this platform limit or is not a power of two');
  if Config.Workers < 1 then
    raise EArgumentException.Create('Benchmark worker count must be positive');
  if Config.DictionarySize+AdditionalData>(UInt64(High(NativeInt))-MiB) div 2 then
    raise EArgumentException.Create('Benchmark buffers exceed this platform address range');
  PerWorker:=KernelMemory(Config.DictionarySize)+OuterMemory(Config.DictionarySize);
  if UInt64(Config.Workers)>High(UInt64) div PerWorker then
    raise EArgumentException.Create('Benchmark memory requirement exceeds UInt64');
  Result:=UInt64(Config.Workers)*PerWorker;
end;

class function TLzmaBenchmark.AutoWorkers(const DictionarySize, MemoryLimit: UInt64;
  const CpuCount: Integer): Integer;
var Config: TBenchmarkConfig;
    PerWorker: UInt64;
begin
  Config := Default(TBenchmarkConfig);
  Config.DictionarySize := DictionarySize;
  Config.Workers := 1;
  PerWorker := RequiredMemory(Config);
  Result := Max(1, Integer(Min(UInt64(Max(CpuCount, 1)), MemoryLimit div PerWorker)));
end;

constructor TLzmaBenchmark.Create(const Config: TBenchmarkConfig);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FConfig := Config;
  FSnapshot.Config := Config;
  FSnapshot.State := bsIdle;
  FSnapshot.RequiredMemory := RequiredMemory(Config);
  if (Config.Passes < 1) or (Config.Passes > 20) or
    (Config.PhaseMilliseconds < 10) or (Config.PhaseMilliseconds > 30000) then
    raise EArgumentException.Create('Invalid benchmark pass count or phase duration');
  if (Config.MemoryLimit = 0) or (FSnapshot.RequiredMemory > Config.MemoryLimit) then
    raise EArgumentException.Create('Benchmark memory limit is too small for this dictionary and worker count');
end;

destructor TLzmaBenchmark.Destroy;
begin
  Cancel;
  Wait;
  FCoordinator.Free;
  FLock.Free;
  inherited;
end;

procedure TLzmaBenchmark.Start;
begin
  if FCoordinator <> nil then raise EInvalidOpException.Create('Benchmark already started');
  FStartTick := TStopwatch.GetTimeStamp;
  ChangeState(bsPreparing);
  FCoordinator := TThread.CreateAnonymousThread(procedure begin Run; end);
  FCoordinator.FreeOnTerminate := False;
  FCoordinator.Start;
end;

procedure TLzmaBenchmark.Cancel;
begin TInterlocked.Exchange(FCancel, 1); end;

procedure TLzmaBenchmark.Wait;
begin if FCoordinator <> nil then FCoordinator.WaitFor; end;

function TLzmaBenchmark.ActiveWorkers: Integer;
begin Result := TInterlocked.CompareExchange(FActiveWorkers, 0, 0); end;

procedure TLzmaBenchmark.ChangeState(const State: TBenchmarkState);
begin
  FLock.Enter;
  try FSnapshot.State := State; finally FLock.Leave; end;
end;

function TLzmaBenchmark.Snapshot: TBenchmarkSnapshot;
begin
  FLock.Enter;
  try Result := FSnapshot; finally FLock.Leave; end;
  if (FStartTick <> 0) and not Result.Finished then
    Result.ElapsedMilliseconds := Round((TStopwatch.GetTimeStamp - FStartTick) * 1000.0 / TStopwatch.Frequency);
end;

constructor TBenchmarkWorker.CreateWorker(const Data: TBytes; const Options: TLzma2Options;
  const CancelFlag, ActiveCount: PInteger; const Duration: Integer);
begin
  FData := Data;
  FOptions := Options;
  FCancel := CancelFlag;
  FActive := ActiveCount;
  FDuration := Duration;
  FBegin := TEvent.Create(nil, False, False, '');
  FDone := TEvent.Create(nil, True, False, '');
  FSource := TBytesStream.Create(Data);
  if UInt64(System.Length(Data))>(UInt64(High(NativeInt))-MiB) div 2 then
    raise EArgumentException.Create('Benchmark output capacity overflow');
  FPacked := TFixedBufferStream.Create(System.Length(Data) * 2 + NativeInt(MiB));
  FDecoded := TFixedBufferStream.Create(System.Length(Data));
  inherited Create(True);
  FreeOnTerminate := False;
end;

procedure TBenchmarkWorker.StartWorker;
begin Start; FStarted := True; end;

destructor TBenchmarkWorker.Destroy;
begin
  FStop := True;
  if Handle <> 0 then
  begin
    FBegin.SetEvent;
    if not FStarted then StartWorker;
    WaitFor;
  end;
  FSource.Free;
  FPacked.Free;
  FDecoded.Free;
  FBegin.Free;
  FDone.Free;
  inherited;
end;

procedure TBenchmarkWorker.Progress(const InBytes, OutBytes: UInt64; var Cancel: Boolean);
begin Cancel := TInterlocked.CompareExchange(FCancel^, 0, 0) <> 0; end;

procedure TBenchmarkWorker.BeginPhase(const Compressing: Boolean);
begin
  FCompression := Compressing;
  FIterations := 0;
  FBytes := 0;
  FCommands := 0;
  FError := '';
  FDone.ResetEvent;
  FBegin.SetEvent;
end;

procedure TBenchmarkWorker.Await;
begin
  if FDone.WaitFor(INFINITE) <> wrSignaled then raise EInvalidOpException.Create('Benchmark worker wait failed');
end;

procedure TBenchmarkWorker.Execute;
var Watch: TStopwatch;
begin
  TInterlocked.Increment(FActive^);
  try
    while True do
    begin
      FBegin.WaitFor(INFINITE);
      if FStop then Exit;
      try
        Watch := TStopwatch.StartNew;
        repeat
          if TInterlocked.CompareExchange(FCancel^, 0, 0) <> 0 then Break;
          if FCompression then
          begin
            FSource.Position := 0;
            FPacked.Reset;
            TLzma2.Compress(FSource, FPacked, FOptions, Progress);
            FCommands := FCommands + System.Length(FData) * Double(CompressionComplexity(FOptions.DictionarySize));
          end
          else
          begin
            FPacked.Position := 0;
            FDecoded.Reset;
            TLzma2.Decompress(FPacked, FDecoded, FOptions, Progress);
            if (FDecoded.Length <> System.Length(FData)) or
              not CompareMem(FDecoded.Data, Pointer(FData), System.Length(FData)) then
              raise EInvalidOpException.Create('Benchmark decoded bytes do not match the test data');
            FCommands := FCommands + Max(Int64(0), FPacked.Length - 13) * 190.0 + System.Length(FData) * 4.0;
          end;
          Inc(FIterations);
          Inc(FBytes, UInt64(System.Length(FData)));
        until Watch.ElapsedMilliseconds >= FDuration;
      except
        on E: Exception do
          if not (E is ELzmaCancelled) then
          begin FError := E.ClassName + ': ' + E.Message; TInterlocked.Exchange(FCancel^, 1); end;
      end;
      FDone.SetEvent;
    end;
  finally TInterlocked.Decrement(FActive^); end;
end;

function ProcessCpuSeconds: Double;
var Created, Exited, Kernel, User: TFileTime;
    K, U: UInt64;
begin
  if not GetProcessTimes(GetCurrentProcess, Created, Exited, Kernel, User) then RaiseLastOSError;
  K := (UInt64(Kernel.dwHighDateTime) shl 32) or Kernel.dwLowDateTime;
  U := (UInt64(User.dwHighDateTime) shl 32) or User.dwLowDateTime;
  Result := (K + U) / 10000000.0;
end;

procedure TLzmaBenchmark.Run;
var Workers: TArray<TBenchmarkWorker>;
    Data: TBytes;
    Options: TLzma2Options;
    I, Pass, DictionaryBits: Integer;
    Enc, Dec: TBenchmarkMetric;
    TerminalState: TBenchmarkState;
    ErrorText: string;
  function Cancelled: Boolean;
  begin Result := TInterlocked.CompareExchange(FCancel, 0, 0) <> 0; end;
  function Measure(const Compressing: Boolean): TBenchmarkMetric;
  var W: TBenchmarkWorker;
      Tick: Int64;
      Cpu: Double;
  begin
    Result := Default(TBenchmarkMetric);
    Cpu := ProcessCpuSeconds;
    Tick := TStopwatch.GetTimeStamp;
    for W in Workers do W.BeginPhase(Compressing);
    for W in Workers do W.Await;
    Result.WallSeconds := (TStopwatch.GetTimeStamp - Tick) / TStopwatch.Frequency;
    Result.CpuSeconds := Max(0.0, ProcessCpuSeconds - Cpu);
    for W in Workers do
    begin
      if W.FError <> '' then raise EInvalidOpException.Create(W.FError);
      Inc(Result.Bytes, W.FBytes);
      Inc(Result.Iterations, W.FIterations);
      Result.Commands := Result.Commands + W.FCommands;
    end;
  end;
begin
  TerminalState := bsComplete;
  try
    try
      Options := TLzma2.StandaloneLzmaOptions(5);
      Options.DictionarySize := FConfig.DictionarySize;
      Options.BufferSize := 1 shl 20;
      Options.MemoryLimit := FConfig.MemoryLimit div UInt64(FConfig.Workers) - OuterMemory(FConfig.DictionarySize);
      DictionaryBits := 0;
      while (UInt64(1) shl DictionaryBits) < FConfig.DictionarySize do Inc(DictionaryBits);
      SetLength(Workers, FConfig.Workers);
      for I := 0 to High(Workers) do
      begin
        if Cancelled then Break;
        Data := BenchmarkData(DictionaryBits, NativeInt(FConfig.DictionarySize) + AdditionalData,
          UInt32(I), function: Boolean begin Result := TInterlocked.CompareExchange(FCancel, 0, 0) <> 0; end);
        if Cancelled then Break;
        Workers[I] := TBenchmarkWorker.CreateWorker(Data, Options, @FCancel, @FActiveWorkers,
          FConfig.PhaseMilliseconds);
        Workers[I].StartWorker;
      end;
      Data := nil;
      for Pass := 1 to FConfig.Passes do
      begin
        if Cancelled then Break;
        ChangeState(bsCompressing);
        Enc := Measure(True);
        if Cancelled then Break;
        FLock.Enter;
        try FSnapshot.CurrentCompression := Enc; finally FLock.Leave; end;
        ChangeState(bsDecompressing);
        Dec := Measure(False);
        if Cancelled then Break;
        FLock.Enter;
        try
          FSnapshot.CurrentDecompression := Dec;
          FSnapshot.AverageCompression.Add(Enc);
          FSnapshot.AverageDecompression.Add(Dec);
          FSnapshot.CompletedPasses := Pass;
        finally FLock.Leave; end;
      end;
      if Cancelled then TerminalState := bsCancelled;
    except
      on E: Exception do begin TerminalState := bsError; ErrorText := E.ClassName + ': ' + E.Message; Cancel; end;
    end;
  finally
    for I := 0 to High(Workers) do Workers[I].Free;
    FLock.Enter;
    try
      FSnapshot.ElapsedMilliseconds := Round((TStopwatch.GetTimeStamp - FStartTick) * 1000.0 / TStopwatch.Frequency);
      FSnapshot.ErrorText := ErrorText;
      FSnapshot.State := TerminalState;
    finally FLock.Leave; end;
  end;
end;

end.
