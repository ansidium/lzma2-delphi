unit FL2Pool;

interface

uses
  System.Classes, System.SyncObjs, System.SysUtils, FL2Threading;

type
  TFL2POOL_function = procedure(opaque: Pointer; n: NativeInt);

  PFL2POOL_ctx = ^TFL2POOL_ctx;

  TFL2PoolWorker = class(TThread)
  private
    FCtx: PFL2POOL_ctx;
  protected
    procedure Execute; override;
  public
    constructor Create(ACtx: PFL2POOL_ctx);
  end;

  TFL2POOL_ctx = record
    numThreads: Cardinal;
    jobFunction: TFL2POOL_function;
    opaque: Pointer;
    numThreadsBusy: Cardinal;
    queueIndex: NativeInt;
    queueEnd: NativeInt;
    queueLock: TCriticalSection;
    busyEvent: TEvent;
    jobSem: TSemaphore;
    shutdown: Boolean;
    workers: array of TFL2PoolWorker;
  end;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; n: NativeInt);
procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Boolean;
function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): Cardinal;

implementation

{ TFL2PoolWorker }

constructor TFL2PoolWorker.Create(ACtx: PFL2POOL_ctx);
begin
  FCtx := ACtx;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TFL2PoolWorker.Execute;
var
  n: NativeInt;
begin
  while True do
  begin
    FCtx^.jobSem.Acquire(INFINITE);
    if FCtx^.shutdown then
      Break;

    FCtx^.queueLock.Acquire;
    if FCtx^.queueIndex >= FCtx^.queueEnd then
    begin
      FCtx^.queueLock.Release;
      Continue;
    end;
    n := FCtx^.queueIndex;
    Inc(FCtx^.queueIndex);
    Inc(FCtx^.numThreadsBusy);
    FCtx^.queueLock.Release;

    try
      if Assigned(FCtx^.jobFunction) then
        FCtx^.jobFunction(FCtx^.opaque, n);
    finally
      FCtx^.queueLock.Acquire;
      Dec(FCtx^.numThreadsBusy);
      if (FCtx^.numThreadsBusy = 0) and (FCtx^.queueIndex >= FCtx^.queueEnd) then
        FCtx^.busyEvent.SetEvent;
      FCtx^.queueLock.Release;
    end;
  end;
end;

{ Functions }

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
var
  i: Integer;
begin
  numThreads := FL2_checkNbThreads(numThreads);
  New(Result);
  FillChar(Result^, SizeOf(TFL2POOL_ctx), 0);
  Result^.numThreads := numThreads;
  Result^.queueLock := TCriticalSection.Create;
  Result^.busyEvent := TEvent.Create(nil, True, True, '');
  Result^.jobSem := TSemaphore.Create(0, MaxInt, '');
  SetLength(Result^.workers, numThreads);
  for i := 0 to Integer(numThreads) - 1 do
    Result^.workers[i] := TFL2PoolWorker.Create(Result);
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
var
  i: Integer;
begin
  if ctx = nil then
    Exit;
  ctx^.shutdown := True;
  ctx^.jobSem.Release(Length(ctx^.workers));
  for i := 0 to High(ctx^.workers) do
  begin
    ctx^.workers[i].WaitFor;
    ctx^.workers[i].Free;
  end;
  ctx^.queueLock.Free;
  ctx^.busyEvent.Free;
  ctx^.jobSem.Free;
  Finalize(ctx^.workers);
  Dispose(ctx);
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; n: NativeInt);
begin
  FL2POOL_addRange(ctx, func, opaque, n, n + 1);
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
var
  count: Integer;
begin
  if ctx = nil then
    Exit;
  ctx^.queueLock.Acquire;
  ctx^.jobFunction := func;
  ctx^.opaque := opaque;
  ctx^.queueIndex := first;
  ctx^.queueEnd := last;
  ctx^.busyEvent.ResetEvent;
  count := last - first;
  ctx^.queueLock.Release;
  ctx^.jobSem.Release(count);
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Boolean;
begin
  if (ctx = nil) or ((ctx^.numThreadsBusy = 0) and (ctx^.queueIndex >= ctx^.queueEnd)) or ctx^.shutdown then
    Exit(False);
  if timeout <> 0 then
  begin
    if ((ctx^.numThreadsBusy <> 0) or (ctx^.queueIndex < ctx^.queueEnd)) and not ctx^.shutdown then
      ctx^.busyEvent.WaitFor(timeout);
  end
  else
  begin
    while ((ctx^.numThreadsBusy <> 0) or (ctx^.queueIndex < ctx^.queueEnd)) and not ctx^.shutdown do
      ctx^.busyEvent.WaitFor(INFINITE);
  end;
  Result := (ctx^.numThreadsBusy <> 0) and not ctx^.shutdown;
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): Cardinal;
begin
  if ctx = nil then
    Exit(0);
  Result := ctx^.numThreadsBusy;
end;

end.
