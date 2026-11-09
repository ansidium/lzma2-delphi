unit Lzma.MtMatchFinder;

{$ALIGN 8}

interface

uses System.Classes, System.SysUtils, System.SyncObjs, Lzma.MatchFinder;

type
  TLzmaMtReadMatches = reference to procedure(const Position: NativeUInt;
    var Matches: TLzmaMatchBuffer);

  // One producer owns the match finder. The encoder consumes bounded records.
  // Input bytes/finder coordinates may change only after Pause acknowledges.
  TLzmaMatchFinderPipeline = class
  private const
    QueueCapacity=128;
  private type
    TEntry = record
      Position: UInt64;
      Matches: TLzmaMatchBuffer;
    end;
  private
    FWritePosition,FReadPosition: Int64;
    FStop,FPause,FStopped: Integer;
    FBase,FLimit: UInt64;
    FQueue: array[0..QueueCapacity-1] of TEntry;
    FLastPosition: UInt64;
    FLastMatches: TLzmaMatchBuffer;
    FHaveLast,FStartAttempted: Boolean;
    FWorker: TThread;
    FWake,FData,FPaused,FResumed: TEvent;
    FReader: TLzmaMtReadMatches;
    FOnWait: TProc;
    FErrorCode: Integer;
    FErrorText: string;
    procedure Run;
    procedure CheckFailure;
    procedure WaitForData;
    procedure PublishRead(const Position: UInt64);
    function Written: UInt64;
    function Consumed: UInt64;
  public
    constructor Create(const Reader: TLzmaMtReadMatches; const OnWait: TProc=nil;
      const StartPosition: UInt64=0);
    destructor Destroy; override;
    procedure Pause;
    procedure SetWindow(const Base: UInt64; const Count,Lookahead: NativeUInt;
      const FinalInput: Boolean);
    procedure AdvanceTo(const Position: UInt64);
    procedure ReadAt(const Position: UInt64; var Matches: TLzmaMatchBuffer);
    procedure Stop;
    procedure StopAndCheck;
    function BufferedCount: Integer;
    class function RequiredMemory: UInt64; static;
  end;

implementation

uses System.Math, Lzma.Types, Lzma.Errors;

class function TLzmaMatchFinderPipeline.RequiredMemory: UInt64;
begin
  // Queue, event/RTL bookkeeping and conservative producer-stack headroom.
  Result:=UInt64(InstanceSize)+(UInt64(1) shl 20)+16384;
end;

function TLzmaMatchFinderPipeline.Written: UInt64;
begin Result:=UInt64(TInterlocked.Read(FWritePosition));end;
function TLzmaMatchFinderPipeline.Consumed: UInt64;
begin Result:=UInt64(TInterlocked.Read(FReadPosition));end;

constructor TLzmaMatchFinderPipeline.Create(const Reader: TLzmaMtReadMatches;
  const OnWait: TProc; const StartPosition: UInt64);
begin
  inherited Create;
  if ((NativeUInt(@FWritePosition) or NativeUInt(@FReadPosition)) and 7)<>0 then
    RaiseLzmaError(SZ_ERROR_THREAD,'Match-finder atomic positions must be 8-byte aligned');
  if not Assigned(Reader) or (StartPosition>UInt64(High(Int64))) then
    RaiseLzmaError(SZ_ERROR_PARAM,'Invalid match-finder pipeline configuration');
  FReader:=Reader;FOnWait:=OnWait;FBase:=StartPosition;FLimit:=StartPosition;
  FWritePosition:=Int64(StartPosition);FReadPosition:=Int64(StartPosition);
  FPause:=1;
  FWake:=TEvent.Create(nil,False,False,'');
  FData:=TEvent.Create(nil,False,False,'');
  FPaused:=TEvent.Create(nil,True,False,'');
  FResumed:=TEvent.Create(nil,True,False,'');
  FWorker:=TThread.CreateAnonymousThread(procedure begin Run;end);
  FWorker.FreeOnTerminate:=False;
  FStartAttempted:=True;FWorker.Start;
  Pause;
end;

destructor TLzmaMatchFinderPipeline.Destroy;
begin
  Stop;
  FWorker.Free;FResumed.Free;FPaused.Free;FData.Free;FWake.Free;
  FReader:=nil;FOnWait:=nil;
  inherited;
end;

procedure TLzmaMatchFinderPipeline.CheckFailure;
begin
  if TInterlocked.CompareExchange(FStopped,0,0)<>0 then
  begin
    if FErrorCode<>SZ_OK then RaiseLzmaError(FErrorCode,FErrorText);
    RaiseLzmaError(SZ_ERROR_THREAD,'Match-finder producer stopped before the requested data');
  end;
end;

procedure TLzmaMatchFinderPipeline.WaitForData;
begin
  CheckFailure;
  if Assigned(FOnWait) then FOnWait();
  if FData.WaitFor(25)=wrError then
    RaiseLzmaError(SZ_ERROR_THREAD,'Match-finder data wait failed');
  CheckFailure;
end;

procedure TLzmaMatchFinderPipeline.Pause;
var WaitResult: TWaitResult;
begin
  TInterlocked.Exchange(FPause,1);
  if FWake<>nil then FWake.SetEvent;
  if FPaused=nil then Exit;
  repeat
  begin
    WaitResult:=FPaused.WaitFor(25);
    if WaitResult=wrSignaled then Break;
    if WaitResult=wrError then
      RaiseLzmaError(SZ_ERROR_THREAD,'Match-finder pause acknowledgement failed');
    CheckFailure;
    if Assigned(FOnWait) then FOnWait();
  end;
  until False;
  CheckFailure;
end;

procedure TLzmaMatchFinderPipeline.SetWindow(const Base: UInt64;
  const Count,Lookahead: NativeUInt; const FinalInput: Boolean);
var SafeCount: UInt64;WaitResult:TWaitResult;
begin
  CheckFailure;
  if FPaused.WaitFor(0)<>wrSignaled then
    RaiseLzmaError(SZ_ERROR_FAIL,'Cannot change match-finder input while its producer is running');
  SafeCount:=Count;
  if not FinalInput then
  begin
    if SafeCount>Lookahead then Dec(SafeCount,Lookahead) else SafeCount:=0;
  end;
  if (Base>UInt64(High(Int64))) or (Base>Written) or
    (SafeCount>UInt64(High(Int64))-Base) or
    (Base+SafeCount<Written) then
    RaiseLzmaError(SZ_ERROR_PARAM,'Invalid match-finder input window');
  FBase:=Base;FLimit:=Base+SafeCount;
  // Only the producer clears FPaused. Wait for its resume acknowledgement
  // before a subsequent Pause can observe an old signaled event.
  FResumed.ResetEvent;
  TInterlocked.Exchange(FPause,0);
  FWake.SetEvent;
  repeat
    WaitResult:=FResumed.WaitFor(25);
    if WaitResult=wrSignaled then Break;
    if WaitResult=wrError then
      RaiseLzmaError(SZ_ERROR_THREAD,'Match-finder resume acknowledgement failed');
    CheckFailure;
    if Assigned(FOnWait) then FOnWait();
  until False;
  CheckFailure;
end;

procedure TLzmaMatchFinderPipeline.PublishRead(const Position: UInt64);
begin
  TInterlocked.Exchange(FReadPosition,Int64(Position));
  FWake.SetEvent;
end;

procedure TLzmaMatchFinderPipeline.AdvanceTo(const Position: UInt64);
var Available,Current: UInt64;
begin
  if (Position>UInt64(High(Int64))) or (Position>FLimit) then
    RaiseLzmaError(SZ_ERROR_PARAM,'Match-finder position exceeds stream capacity');
  Current:=Consumed;
  while Current<Position do
  begin
    Available:=Written;
    if Available>Current then
    begin
      Current:=Min(Available,Position);
      PublishRead(Current);
    end
    else WaitForData;
  end;
end;

procedure TLzmaMatchFinderPipeline.ReadAt(const Position: UInt64;
  var Matches: TLzmaMatchBuffer);
var Slot: Integer;
begin
  CheckFailure;
  if (Position>=UInt64(High(Int64))) or (Position>=FLimit) then
    RaiseLzmaError(SZ_ERROR_PARAM,'Requested match is outside the available input');
  if FHaveLast and (Position=FLastPosition) then
  begin Matches.CopyPairsFrom(FLastMatches);Exit;end;
  if Position<Consumed then
    RaiseLzmaError(SZ_ERROR_FAIL,'Match-finder reads must be monotonic');
  AdvanceTo(Position);
  while Written<=Position do WaitForData;
  Slot:=Integer(Position mod QueueCapacity);
  if FQueue[Slot].Position<>Position then
    RaiseLzmaError(SZ_ERROR_FAIL,'Match-finder queue order mismatch');
  Matches.CopyPairsFrom(FQueue[Slot].Matches);
  FLastMatches.CopyPairsFrom(Matches);FLastPosition:=Position;FHaveLast:=True;
  PublishRead(Position+1);
end;

procedure TLzmaMatchFinderPipeline.Run;
var Position: UInt64;Slot: Integer;
begin
  try
   try
    while TInterlocked.CompareExchange(FStop,0,0)=0 do
    begin
      if TInterlocked.CompareExchange(FPause,0,0)<>0 then
      begin
        FPaused.SetEvent;
        while (TInterlocked.CompareExchange(FPause,0,0)<>0) and
          (TInterlocked.CompareExchange(FStop,0,0)=0) do
          if FWake.WaitFor(INFINITE)<>wrSignaled then
            RaiseLzmaError(SZ_ERROR_THREAD,'Match-finder pause wait failed');
        FPaused.ResetEvent;
        FResumed.SetEvent;
        Continue;
      end;
      Position:=Written;
      if (Position>=FLimit) or (Position-Consumed>=QueueCapacity) then
      begin
        if FWake.WaitFor(INFINITE)<>wrSignaled then
          RaiseLzmaError(SZ_ERROR_THREAD,'Match-finder producer wait failed');
        Continue;
      end;
      Slot:=Integer(Position mod QueueCapacity);
      FReader(NativeUInt(Position-FBase),FQueue[Slot].Matches);
      if (FQueue[Slot].Matches.Count<0) or
        (FQueue[Slot].Matches.Count>Length(FQueue[Slot].Matches.Items)) then
        RaiseLzmaError(SZ_ERROR_FAIL,'Invalid match-finder result length');
      FQueue[Slot].Position:=Position;
      TInterlocked.Exchange(FWritePosition,Int64(Position+1));
      FData.SetEvent;
    end;
  except
    on E:Exception do
    begin
      if E is ELzmaError then FErrorCode:=ELzmaError(E).ResultCode
      else if E is EOutOfMemory then FErrorCode:=SZ_ERROR_MEM
      else FErrorCode:=SZ_ERROR_THREAD;
      try FErrorText:=E.ClassName+': '+E.Message;
      except FErrorText:='';end;
    end;
    else FErrorCode:=SZ_ERROR_THREAD;
   end;
  finally
    // Also wake consumers if exception formatting itself fails.
    TInterlocked.Exchange(FStopped,1);
    FData.SetEvent;FPaused.SetEvent;FResumed.SetEvent;
  end;
end;

procedure TLzmaMatchFinderPipeline.Stop;
begin
  TInterlocked.Exchange(FStop,1);
  if FWake<>nil then FWake.SetEvent;
  if FData<>nil then FData.SetEvent;
  if FWorker<>nil then
  begin
    if not FStartAttempted then begin FStartAttempted:=True;FWorker.Start;end;
    FWorker.WaitFor;
  end;
end;

procedure TLzmaMatchFinderPipeline.StopAndCheck;
begin
  Stop;
  if FErrorCode<>SZ_OK then RaiseLzmaError(FErrorCode,FErrorText);
end;

function TLzmaMatchFinderPipeline.BufferedCount: Integer;
var Value: Int64;
begin
  Value:=Int64(Written)-Int64(Consumed);
  Result:=Integer(EnsureRange(Value,Int64(0),Int64(QueueCapacity)));
end;

end.
