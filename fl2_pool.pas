unit FL2Pool;

interface

uses

  System.Classes, System.SyncObjs, System.Generics.Collections;

type
  TFL2POOL_function = procedure(opaque: Pointer; n: NativeInt);

  TFL2PoolCtx = class;

  TFL2WorkerThread = class(TThread)
  private
    FPool: TFL2PoolCtx;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TFL2PoolCtx);
  end;

  TFL2PoolCtx = class
  private
    FThreads: array of TFL2WorkerThread;
    FQueueMutex: TCriticalSection;
    FBusyCond: TEvent;
    FNewJobsCond: TEvent;
    FShutdown: Boolean;
    FFunction: TFL2POOL_function;
    FOpaque: Pointer;
    FQueueIndex: NativeInt;
    FQueueEnd: NativeInt;
    FNumThreadsBusy: Integer;
  public
    constructor Create(numThreads: Integer);
    destructor Destroy; override;

    procedure AddRange(function_: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
    procedure Add(function_: TFL2POOL_function; opaque: Pointer; n: NativeInt);
    function WaitAll(timeout: Cardinal): Boolean;
    function ThreadsBusy: Integer;
    function SizeOfCtx: NativeUInt;
  end;

function FL2POOL_create(numThreads: Cardinal): TFL2PoolCtx;
procedure FL2POOL_free(ctx: TFL2PoolCtx);
procedure FL2POOL_add(ctx: TFL2PoolCtx; func: TFL2POOL_function; opaque: Pointer; n: NativeInt);
procedure FL2POOL_addRange(ctx: TFL2PoolCtx; func: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
function FL2POOL_waitAll(ctx: TFL2PoolCtx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: TFL2PoolCtx): Cardinal;
function FL2POOL_sizeof(ctx: TFL2PoolCtx): NativeUInt;

implementation

{ TFL2WorkerThread }

constructor TFL2WorkerThread.Create(APool: TFL2PoolCtx);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FPool := APool;
end;

procedure TFL2WorkerThread.Execute;
var
  n: NativeInt;
begin
  while not Terminated do
  begin
    if FPool.FNewJobsCond.WaitFor(INFINITE) <> wrSignaled then
      Continue;
    if Terminated then
      Break;
    while True do
    begin
      FPool.FQueueMutex.Acquire;
      try
        if (FPool.FQueueIndex >= FPool.FQueueEnd) then
        begin
          if FPool.FShutdown then
            Exit;
          Break;
        end;
        n := FPool.FQueueIndex;
        Inc(FPool.FQueueIndex);
        Inc(FPool.FNumThreadsBusy);
      finally
        FPool.FQueueMutex.Release;
      end;

      try
        if Assigned(FPool.FFunction) then
          FPool.FFunction(FPool.FOpaque, n);
      finally
        FPool.FQueueMutex.Acquire;
        try
          Dec(FPool.FNumThreadsBusy);
          if (FPool.FNumThreadsBusy = 0) and (FPool.FQueueIndex >= FPool.FQueueEnd) then
            FPool.FBusyCond.SetEvent;
        finally
          FPool.FQueueMutex.Release;
        end;
      end;
    end;
  end;
end;

{ TFL2PoolCtx }

constructor TFL2PoolCtx.Create(numThreads: Integer);
var
  i: Integer;
begin
  inherited Create;
  if numThreads < 1 then
    numThreads := 1;
  FQueueMutex := TCriticalSection.Create;
  FBusyCond := TEvent.Create(nil, True, True, '');
  FNewJobsCond := TEvent.Create(nil, False, False, '');
  SetLength(FThreads, numThreads);
  for i := 0 to numThreads - 1 do
    FThreads[i] := TFL2WorkerThread.Create(Self);
end;

destructor TFL2PoolCtx.Destroy;
var
  i: Integer;
begin
  FQueueMutex.Acquire;
  FShutdown := True;
  FNewJobsCond.SetEvent;
  FQueueMutex.Release;
  for i := 0 to High(FThreads) do
  begin
    FThreads[i].Terminate;
    FNewJobsCond.SetEvent;
    FThreads[i].WaitFor;
    FThreads[i].Free;
  end;
  FNewJobsCond.Free;
  FBusyCond.Free;
  FQueueMutex.Free;
  inherited Destroy;
end;

procedure TFL2PoolCtx.Add(function_: TFL2POOL_function; opaque: Pointer; n: NativeInt);
begin
  AddRange(function_, opaque, n, n + 1);
end;

procedure TFL2PoolCtx.AddRange(function_: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
begin
  FQueueMutex.Acquire;
  try
    FFunction := function_;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    FBusyCond.ResetEvent;
    FNewJobsCond.SetEvent;
  finally
    FQueueMutex.Release;
  end;
end;

function TFL2PoolCtx.SizeOfCtx: NativeUInt;
begin
  Result := SizeOf(Self) + Length(FThreads) * SizeOf(Pointer);
end;

function TFL2PoolCtx.ThreadsBusy: Integer;
begin
  Result := FNumThreadsBusy;
end;

function TFL2PoolCtx.WaitAll(timeout: Cardinal): Boolean;
begin
  Result := FBusyCond.WaitFor(timeout) = wrSignaled;
end;

function FL2POOL_create(numThreads: Cardinal): TFL2PoolCtx;
begin
  Result := TFL2PoolCtx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: TFL2PoolCtx);
begin
  ctx.Free;
end;

procedure FL2POOL_add(ctx: TFL2PoolCtx; func: TFL2POOL_function; opaque: Pointer; n: NativeInt);
begin
  ctx.Add(func, opaque, n);
end;

procedure FL2POOL_addRange(ctx: TFL2PoolCtx; func: TFL2POOL_function; opaque: Pointer; first, last: NativeInt);
begin
  ctx.AddRange(func, opaque, first, last);
end;

function FL2POOL_waitAll(ctx: TFL2PoolCtx; timeout: Cardinal): Integer;
begin
  if ctx.WaitAll(timeout) then
    Result := 0
  else
    Result := 1;
end;

function FL2POOL_threadsBusy(ctx: TFL2PoolCtx): Cardinal;
begin
  Result := ctx.ThreadsBusy;
end;

function FL2POOL_sizeof(ctx: TFL2PoolCtx): NativeUInt;
begin
  Result := ctx.SizeOfCtx;
end;

end.
