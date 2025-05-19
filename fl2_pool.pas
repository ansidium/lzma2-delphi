unit FL2Pool;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections;

type
  FL2POOL_function = procedure(opaque: Pointer; n: NativeInt);
  PFL2POOL_ctx = ^TFL2POOL_ctx;

  TFL2POOL_ctx = class
  private
    type
      TJob = record
        Index: NativeInt;
      end;

      TWorker = class(TThread)
      private
        FPool: TFL2POOL_ctx;
      protected
        procedure Execute; override;
      public
        constructor Create(APool: TFL2POOL_ctx);
      end;
  private
    FWorkers: array of TWorker;
    FQueue: System.Generics.Collections.TQueue<TJob>;
    FLock: TCriticalSection;
    FWorkEvent: TEvent;
    FIdleEvent: TEvent;
    FFunction: FL2POOL_function;
    FOpaque: Pointer;
    FBusy: Integer;
    FShutdown: Boolean;
  public
    constructor Create(numThreads: Cardinal);
    destructor Destroy; override;
    procedure Add(func: FL2POOL_function; opaque: Pointer; n: NativeInt);
    procedure AddRange(func: FL2POOL_function; opaque: Pointer; first, last: NativeInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: NativeUInt;
    function PoolSize: NativeUInt;
  end;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: NativeInt);
procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: NativeInt);
function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;

implementation

uses
  System.SyncObjs, System.Generics.Collections;

{ TFL2POOL_ctx.TWorker }

constructor TFL2POOL_ctx.TWorker.Create(APool: TFL2POOL_ctx);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure TFL2POOL_ctx.TWorker.Execute;
var
  job: TJob;
begin
  while not Terminated do
  begin
    if FPool.FWorkEvent.WaitFor(INFINITE) <> wrSignaled then
      Continue;
    if Terminated or FPool.FShutdown then
      Break;
    while True do
    begin
      FPool.FLock.Acquire;
      try
        if FPool.FQueue.Count = 0 then
        begin
          FPool.FWorkEvent.ResetEvent;
          Break;
        end;
        job := FPool.FQueue.Dequeue;
        Inc(FPool.FBusy);
      finally
        FPool.FLock.Release;
      end;
      try
        if Assigned(FPool.FFunction) then
          FPool.FFunction(FPool.FOpaque, job.Index);
      finally
        FPool.FLock.Acquire;
        try
          Dec(FPool.FBusy);
          if (FPool.FQueue.Count = 0) and (FPool.FBusy = 0) then
            FPool.FIdleEvent.SetEvent;
        finally
          FPool.FLock.Release;
        end;
      end;
    end;
  end;
end;

{ TFL2POOL_ctx }

constructor TFL2POOL_ctx.Create(numThreads: Cardinal);
var
  i: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWorkEvent := TEvent.Create(nil, True, False, '');
  FIdleEvent := TEvent.Create(nil, True, True, '');
  FQueue := TQueue<TJob>.Create;
  SetLength(FWorkers, numThreads);
  for i := 0 to High(FWorkers) do
    FWorkers[i] := TWorker.Create(Self);
end;

destructor TFL2POOL_ctx.Destroy;
var
  i: Integer;
begin
  FShutdown := True;
  FWorkEvent.SetEvent;
  for i := 0 to High(FWorkers) do
  begin
    FWorkers[i].Terminate;
    FWorkers[i].WaitFor;
    FWorkers[i].Free;
  end;
  FQueue.Free;
  FLock.Free;
  FWorkEvent.Free;
  FIdleEvent.Free;
  inherited;
end;

procedure TFL2POOL_ctx.Add(func: FL2POOL_function; opaque: Pointer; n: NativeInt);
begin
  AddRange(func, opaque, n, n + 1);
end;

procedure TFL2POOL_ctx.AddRange(func: FL2POOL_function; opaque: Pointer; first, last: NativeInt);
var
  idx: NativeInt;
  job: TJob;
begin
  FLock.Acquire;
  try
    FFunction := func;
    FOpaque := opaque;
    for idx := first to last - 1 do
    begin
      job.Index := idx;
      FQueue.Enqueue(job);
    end;
    FIdleEvent.ResetEvent;
    FWorkEvent.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TFL2POOL_ctx.WaitAll(timeout: Cardinal): Integer;
begin
  if FIdleEvent.WaitFor(timeout) = wrSignaled then
    Result := 0
  else
    Result := 1;
end;

function TFL2POOL_ctx.ThreadsBusy: NativeUInt;
begin
  FLock.Acquire;
  try
    Result := FBusy;
  finally
    FLock.Release;
  end;
end;

function TFL2POOL_ctx.PoolSize: NativeUInt;
begin
  Result := InstanceSize + Cardinal(Length(FWorkers)) * SizeOf(Pointer);
end;

{ Global wrappers }

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
begin
  New(Result);
  Result^ := TFL2POOL_ctx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx <> nil then
  begin
    ctx^.Free;
    Dispose(ctx);
  end;
end;

function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := ctx^.PoolSize;
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: NativeInt);
begin
  if ctx <> nil then
    ctx^.Add(func, opaque, n);
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: NativeInt);
begin
  if ctx <> nil then
    ctx^.AddRange(func, opaque, first, last);
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  if ctx <> nil then
    Result := ctx^.WaitAll(timeout)
  else
    Result := 0;
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;
begin
  if ctx <> nil then
    Result := ctx^.ThreadsBusy
  else
    Result := 0;
end;

end.
