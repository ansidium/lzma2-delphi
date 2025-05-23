unit FL2Pool;

interface

uses
  System.Classes, System.SyncObjs, System.SysUtils;

type
  TFL2PoolFunction = procedure(opaque: Pointer; n: NativeInt);

  PFL2PoolJob = ^TFL2PoolJob;
  TFL2PoolJob = record
    Func: TFL2PoolFunction;
    Opaque: Pointer;
    Index: NativeInt;
    Next: PFL2PoolJob;
  end;

  TFL2Worker = class(TThread)
  private
    FPool: TObject;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TObject);
  end;

  TFL2PoolCtx = class
  private
    FThreads: array of TFL2Worker;
    FQueueLock: TCriticalSection;
    FQueueEvent: TEvent;
    FBusyEvent: TEvent;
    FQueueHead: PFL2PoolJob;
    FQueueTail: PFL2PoolJob;
    FShutdown: Boolean;
    FNumThreadsBusy: Integer;
    procedure PushJob(const Job: TFL2PoolJob);
    function PopJob(out Job: TFL2PoolJob): Boolean;
    procedure WorkerExecute(Worker: TFL2Worker);
  public
    constructor Create(numThreads: Cardinal);
    destructor Destroy; override;
    procedure Add(func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
    procedure AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
    function WaitAll(timeout: Cardinal): Boolean;
    function ThreadsBusy: Integer;
  end;

implementation

{ TFL2Worker }

constructor TFL2Worker.Create(APool: TObject);
begin
  FPool := APool;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TFL2Worker.Execute;
begin
  TFL2PoolCtx(FPool).WorkerExecute(Self);

end;

{ TFL2PoolCtx }
constructor TFL2PoolCtx.Create(numThreads: Cardinal);
var
  i: Integer;
begin
  inherited Create;
  FQueueLock := TCriticalSection.Create;
  FQueueEvent := TEvent.Create(nil, False, False, '');
  FBusyEvent := TEvent.Create(nil, True, False, '');
  FQueueHead := nil;
  FQueueTail := nil;
  FShutdown := False;
  FNumThreadsBusy := 0;
  SetLength(FThreads, numThreads);
  for i := 0 to High(FThreads) do
    FThreads[i] := TFL2Worker.Create(Self);
end;

destructor TFL2PoolCtx.Destroy;
var
  i: Integer;
  job: TFL2PoolJob;
begin
  FShutdown := True;
  FQueueEvent.SetEvent;
  for i := 0 to High(FThreads) do
  begin
    FThreads[i].WaitFor;
    FThreads[i].Free;
  end;
  FQueueLock.Free;
  FQueueEvent.Free;
  FBusyEvent.Free;
  while PopJob(job) do ;
  inherited Destroy;
end;

procedure TFL2PoolCtx.PushJob(const Job: TFL2PoolJob);
var
  NewJob: PFL2PoolJob;
begin
  New(NewJob);
  NewJob^ := Job;
  NewJob^.Next := nil;
  FQueueLock.Acquire;
  try
    if FQueueTail <> nil then
      FQueueTail^.Next := NewJob
    else
      FQueueHead := NewJob;
    FQueueTail := NewJob;
    FQueueEvent.SetEvent;
  finally
    FQueueLock.Release;
  end;
end;

function TFL2PoolCtx.PopJob(out Job: TFL2PoolJob): Boolean;
var
  Node: PFL2PoolJob;
begin
  FQueueLock.Acquire;
  try
    Node := FQueueHead;
    if Node <> nil then
    begin
      FQueueHead := Node^.Next;
      if FQueueHead = nil then
        FQueueTail := nil;
    end;
  finally
    FQueueLock.Release;
  end;
  if Node = nil then
    Exit(False);
  Job := Node^;
  Dispose(Node);
  Result := True;
end;

procedure TFL2PoolCtx.WorkerExecute(Worker: TFL2Worker);
var
  Job: TFL2PoolJob;
begin
  while not FShutdown do
  begin
    if not PopJob(Job) then
    begin
      if FShutdown then
        Break;
      FQueueEvent.WaitFor(INFINITE);
      Continue;
    end;
    FBusyEvent.ResetEvent;
    TInterlocked.Increment(FNumThreadsBusy);
    try
      Job.Func(Job.Opaque, Job.Index);
    finally
      TInterlocked.Decrement(FNumThreadsBusy);
      if (FNumThreadsBusy = 0) and (FQueueHead = nil) then
        FBusyEvent.SetEvent;
    end;
  end;
end;

procedure TFL2PoolCtx.Add(func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
begin
  AddRange(func, opaque, n, n + 1);
end;

procedure TFL2PoolCtx.AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
var
  idx: NativeInt;
  job: TFL2PoolJob;
begin
  for idx := first to last - 1 do
  begin
    job.Func := func;
    job.Opaque := opaque;
    job.Index := idx;
    PushJob(job);
  end;
end;

function TFL2PoolCtx.WaitAll(timeout: Cardinal): Boolean;
var
  res: TWaitResult;
begin
  if timeout = 0 then
  begin
    while (FNumThreadsBusy > 0) or (FQueueHead <> nil) do
      FBusyEvent.WaitFor(INFINITE);
    Result := True;
  end
  else
  begin
    res := FBusyEvent.WaitFor(timeout);
    Result := res = wrSignaled;
  end;
end;

function TFL2PoolCtx.ThreadsBusy: Integer;
begin
  Result := FNumThreadsBusy;
end;

end.
