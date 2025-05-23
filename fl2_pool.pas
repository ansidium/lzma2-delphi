unit FL2Pool;

interface

uses
  System.SysUtils;

type
  TFL2PoolFunction = procedure(opaque: Pointer; n: NativeInt);

  TFL2POOL_ctx = class
  private
    FNumThreads: Integer;
    FFunction: TFL2PoolFunction;
    FOpaque: Pointer;
    FQueueIndex: NativeInt;
    FQueueEnd: NativeInt;
    FBusyCount: Integer;
    FShutdown: Boolean;
    FLock: TObject;
    FThreads: array of TThread;
  public
    constructor Create(numThreads: Integer);
    destructor Destroy; override;
    procedure AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
    procedure Add(func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: NativeInt;
  end;

function FL2POOL_create(numThreads: NativeInt): Pointer;
procedure FL2POOL_free(ctx: Pointer);
function FL2POOL_sizeof(ctx: Pointer): NativeUInt;
procedure FL2POOL_addRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
procedure FL2POOL_add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: Pointer): NativeInt;

implementation

uses
  System.Classes;

type
  TFL2WorkerThread = class(TThread)
  private
    FPool: TFL2POOL_ctx;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TFL2POOL_ctx);
  end;

{ TFL2WorkerThread }

constructor TFL2WorkerThread.Create(APool: TFL2POOL_ctx);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure TFL2WorkerThread.Execute;
var
  n: NativeInt;
begin
  while True do
  begin
    TMonitor.Enter(FPool.FLock);
    try
      while (FPool.FQueueIndex >= FPool.FQueueEnd) and not FPool.FShutdown do
        TMonitor.Wait(FPool.FLock);
      if FPool.FShutdown then
        Exit;
      n := FPool.FQueueIndex;
      Inc(FPool.FQueueIndex);
      Inc(FPool.FBusyCount);
    finally
      TMonitor.Exit(FPool.FLock);
    end;

    FPool.FFunction(FPool.FOpaque, n);

    TMonitor.Enter(FPool.FLock);
    try
      Dec(FPool.FBusyCount);
      if (FPool.FBusyCount = 0) and (FPool.FQueueIndex >= FPool.FQueueEnd) then
        TMonitor.PulseAll(FPool.FLock);
    finally
      TMonitor.Exit(FPool.FLock);
    end;
  end;
end;

{ TFL2POOL_ctx }

constructor TFL2POOL_ctx.Create(numThreads: Integer);
var
  i: Integer;
begin
  inherited Create;
  if numThreads < 1 then
    numThreads := 1;
  FNumThreads := numThreads;
  FLock := TObject.Create;
  SetLength(FThreads, FNumThreads);
  for i := 0 to FNumThreads - 1 do
    FThreads[i] := TFL2WorkerThread.Create(Self);
end;

destructor TFL2POOL_ctx.Destroy;
var
  i: Integer;
begin
  TMonitor.Enter(FLock);
  try
    FShutdown := True;
    TMonitor.PulseAll(FLock);
  finally
    TMonitor.Exit(FLock);
  end;

  for i := 0 to Length(FThreads) - 1 do
    if Assigned(FThreads[i]) then
    begin
      FThreads[i].WaitFor;
      FThreads[i].Free;
    end;
  FLock.Free;
  inherited Destroy;
end;

procedure TFL2POOL_ctx.AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
begin
  if not Assigned(func) then
    Exit;
  TMonitor.Enter(FLock);
  try
    FFunction := func;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    TMonitor.PulseAll(FLock);
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TFL2POOL_ctx.Add(func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
begin
  AddRange(func, opaque, n, n + 1);
end;

function TFL2POOL_ctx.WaitAll(timeout: Cardinal): Integer;
var
  start: UInt64;
  remaining: Cardinal;
begin
  start := GetTickCount64;
  TMonitor.Enter(FLock);
  try
    while (FBusyCount <> 0) or (FQueueIndex < FQueueEnd) do
    begin
      if timeout = 0 then
        TMonitor.Wait(FLock)
      else
      begin
        remaining := timeout - Cardinal(GetTickCount64 - start);
        if remaining <= 0 then
          Exit(1);
        TMonitor.Wait(FLock, remaining);
      end;
    end;
    Result := 0;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TFL2POOL_ctx.ThreadsBusy: NativeInt;
begin
  TMonitor.Enter(FLock);
  try
    Result := FBusyCount;
  finally
    TMonitor.Exit(FLock);
  end;
end;

{ Function wrappers }

function FL2POOL_create(numThreads: NativeInt): Pointer;
begin
  Result := TFL2POOL_ctx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: Pointer);
begin
  TObject(ctx).Free;
end;

function FL2POOL_sizeof(ctx: Pointer): NativeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := SizeOf(TFL2POOL_ctx) + TFL2POOL_ctx(ctx).FNumThreads * SizeOf(Pointer);
end;

procedure FL2POOL_addRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
begin
  if ctx <> nil then
    TFL2POOL_ctx(ctx).AddRange(func, opaque, first, last);
end;

procedure FL2POOL_add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
begin
  if ctx <> nil then
    TFL2POOL_ctx(ctx).Add(func, opaque, n);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
begin
  if ctx <> nil then
    Result := TFL2POOL_ctx(ctx).WaitAll(timeout)
  else
    Result := 0;
end;

function FL2POOL_threadsBusy(ctx: Pointer): NativeInt;
begin
  if ctx <> nil then
    Result := TFL2POOL_ctx(ctx).ThreadsBusy
  else
    Result := 0;
end;

end.
