unit FL2Pool;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, FL2Threading;

type
  TFL2POOL_function = procedure(opaque: Pointer; n: NativeInt);

  PFL2POOL_ctx = ^TFL2POOL_ctx;

  TFL2Condition = class
  private
    FEvent: TEvent;
    FLock: TCriticalSection;
    FWaitCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Wait(Mutex: TCriticalSection);
    procedure TimedWait(Mutex: TCriticalSection; TimeoutMs: Cardinal);
    procedure Signal;
    procedure Broadcast;
  end;

  TFL2WorkerThread = class(TThread)
  private
    FCtx: PFL2POOL_ctx;
  protected
    procedure Execute; override;
  public
    constructor Create(Ctx: PFL2POOL_ctx);
  end;

  TFL2POOL_ctx = record
    numThreads: Cardinal;
    jobFunction: TFL2POOL_function;
    opaque: Pointer;
    numThreadsBusy: Cardinal;
    queueIndex: NativeInt;
    queueEnd: NativeInt;
    queueMutex: TCriticalSection;
    busyCond: TFL2Condition;
    newJobsCond: TFL2Condition;
    shutdown: Boolean;
    threads: array of TFL2WorkerThread;
  end;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; n: NativeInt);
procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Boolean;
function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): Cardinal;

implementation

{ TFL2Condition }

constructor TFL2Condition.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, False, False, '');
  FLock := TCriticalSection.Create;
  FWaitCount := 0;
end;

destructor TFL2Condition.Destroy;
begin
  FEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFL2Condition.Wait(Mutex: TCriticalSection);
begin
  FLock.Acquire;
  Inc(FWaitCount);
  FLock.Release;
  Mutex.Leave;
  FEvent.WaitFor(INFINITE);
  Mutex.Enter;
  FLock.Acquire;
  Dec(FWaitCount);
  FLock.Release;
end;

procedure TFL2Condition.TimedWait(Mutex: TCriticalSection; TimeoutMs: Cardinal);
begin
  FLock.Acquire;
  Inc(FWaitCount);
  FLock.Release;
  Mutex.Leave;
  FEvent.WaitFor(TimeoutMs);
  Mutex.Enter;
  FLock.Acquire;
  Dec(FWaitCount);
  FLock.Release;
end;

procedure TFL2Condition.Signal;
begin
  FEvent.SetEvent;
end;

procedure TFL2Condition.Broadcast;
var
  Count, I: Integer;
begin
  FLock.Acquire;
  Count := FWaitCount;
  FLock.Release;
  for I := 1 to Count do
    FEvent.SetEvent;
end;

{ TFL2WorkerThread }

constructor TFL2WorkerThread.Create(Ctx: PFL2POOL_ctx);
begin
  FCtx := Ctx;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TFL2WorkerThread.Execute;
var
  n: NativeInt;
begin
  while True do
  begin
    FCtx^.queueMutex.Acquire;
    try
      while (FCtx^.queueIndex >= FCtx^.queueEnd) and (not FCtx^.shutdown) do
        FCtx^.newJobsCond.Wait(FCtx^.queueMutex);
      if FCtx^.shutdown then
        Exit;
      n := FCtx^.queueIndex;
      Inc(FCtx^.queueIndex);
      Inc(FCtx^.numThreadsBusy);
    finally
      FCtx^.queueMutex.Release;
    end;

    if Assigned(FCtx^.jobFunction) then
      FCtx^.jobFunction(FCtx^.opaque, n);

    FCtx^.queueMutex.Acquire;
    try
      Dec(FCtx^.numThreadsBusy);
      FCtx^.busyCond.Signal;
    finally
      FCtx^.queueMutex.Release;
    end;
  end;
end;

{ Thread pool API }

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
var
  i: Cardinal;
begin
  numThreads := FL2_checkNbThreads(numThreads);
  if numThreads = 0 then
    Exit(nil);

  New(Result);
  FillChar(Result^, SizeOf(TFL2POOL_ctx), 0);
  Result^.queueMutex := TCriticalSection.Create;
  Result^.busyCond := TFL2Condition.Create;
  Result^.newJobsCond := TFL2Condition.Create;
  Result^.shutdown := False;

  SetLength(Result^.threads, numThreads);
  Result^.numThreads := 0;
  for i := 0 to numThreads - 1 do
  begin
    Result^.threads[i] := TFL2WorkerThread.Create(Result);
    Inc(Result^.numThreads);
  end;
end;

procedure FL2POOL_join(ctx: PFL2POOL_ctx);
var
  i: Cardinal;
begin
  ctx^.queueMutex.Acquire;
  ctx^.shutdown := True;
  ctx^.newJobsCond.Broadcast;
  ctx^.queueMutex.Release;

  for i := 0 to ctx^.numThreads - 1 do
  begin
    ctx^.threads[i].WaitFor;
    ctx^.threads[i].Free;
  end;
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx = nil then
    Exit;
  FL2POOL_join(ctx);
  ctx^.queueMutex.Free;
  ctx^.busyCond.Free;
  ctx^.newJobsCond.Free;
  SetLength(ctx^.threads, 0);
  Dispose(ctx);
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; n: NativeInt);
begin
  FL2POOL_addRange(ctx, func, opaque, n, n + 1);
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
begin
  if ctx = nil then
    Exit;
  Assert(ctx^.numThreadsBusy = 0);
  ctx^.queueMutex.Acquire;
  try
    ctx^.jobFunction := func;
    ctx^.opaque := opaque;
    ctx^.queueIndex := first;
    ctx^.queueEnd := last;
    ctx^.newJobsCond.Broadcast;
  finally
    ctx^.queueMutex.Release;
  end;
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Boolean;
begin
  if (ctx = nil) or ((ctx^.numThreadsBusy = 0) and (ctx^.queueIndex >= ctx^.queueEnd)) or ctx^.shutdown then
    Exit(False);
  ctx^.queueMutex.Acquire;
  try
    if timeout <> 0 then
    begin
      if ((ctx^.numThreadsBusy <> 0) or (ctx^.queueIndex < ctx^.queueEnd)) and (not ctx^.shutdown) then
        ctx^.busyCond.TimedWait(ctx^.queueMutex, timeout);
    end
    else
    begin
      while ((ctx^.numThreadsBusy <> 0) or (ctx^.queueIndex < ctx^.queueEnd)) and (not ctx^.shutdown) do
        ctx^.busyCond.Wait(ctx^.queueMutex);
    end;
  finally
    ctx^.queueMutex.Release;
  end;
  Result := (ctx^.numThreadsBusy <> 0) and (not ctx^.shutdown);
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): Cardinal;
begin
  if ctx = nil then
    Exit(0);
  Result := ctx^.numThreadsBusy;
end;

end.
