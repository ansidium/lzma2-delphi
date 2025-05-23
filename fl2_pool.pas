unit FL2Pool;

interface

uses
  System.Classes, System.SysUtils, System.SyncObjs;

type
  TFL2POOL_function = procedure(opaque: Pointer; n: PtrInt);

  TFL2POOL_ctx = class;

  TFL2WorkerThread = class(TThread)
  private
    FPool: TFL2POOL_ctx;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TFL2POOL_ctx);
  end;

  TFL2POOL_ctx = class
  private
    FLock: TObject;
    FFunction: TFL2POOL_function;
    FOpaque: Pointer;
    FQueueIndex: PtrInt;
    FQueueEnd: PtrInt;
    FBusyCount: Integer;
    FThreads: array of TFL2WorkerThread;
    FShutdown: Boolean;
  public
    constructor Create(numThreads: Cardinal);
    destructor Destroy; override;
    procedure AddRange(function_: TFL2POOL_function; opaque: Pointer; first, last: PtrInt);
    procedure Add(function_: TFL2POOL_function; opaque: Pointer; n: PtrInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: Cardinal;
  end;

function FL2POOL_create(numThreads: Cardinal): TFL2POOL_ctx;
procedure FL2POOL_free(ctx: TFL2POOL_ctx);
procedure FL2POOL_addRange(ctx: TFL2POOL_ctx; function_: TFL2POOL_function; opaque: Pointer; first, last: PtrInt);
procedure FL2POOL_add(ctx: TFL2POOL_ctx; function_: TFL2POOL_function; opaque: Pointer; n: PtrInt);
function FL2POOL_waitAll(ctx: TFL2POOL_ctx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: TFL2POOL_ctx): Cardinal;

implementation

{ TFL2WorkerThread }

constructor TFL2WorkerThread.Create(APool: TFL2POOL_ctx);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FPool := APool;
end;

procedure TFL2WorkerThread.Execute;
var
  n: PtrInt;
  pool: TFL2POOL_ctx;
begin
  pool := FPool;
  while True do
  begin
    TMonitor.Enter(pool.FLock);
    try
      while (pool.FQueueIndex >= pool.FQueueEnd) and not pool.FShutdown do
        TMonitor.Wait(pool.FLock);
      if pool.FShutdown then
        Exit;
      n := pool.FQueueIndex;
      Inc(pool.FQueueIndex);
      Inc(pool.FBusyCount);
    finally
      TMonitor.Exit(pool.FLock);
    end;

    try
      pool.FFunction(pool.FOpaque, n);
    except
    end;

    TMonitor.Enter(pool.FLock);
    try
      Dec(pool.FBusyCount);
      TMonitor.PulseAll(pool.FLock);
    finally
      TMonitor.Exit(pool.FLock);
    end;
  end;
end;

{ TFL2POOL_ctx }

constructor TFL2POOL_ctx.Create(numThreads: Cardinal);
var
  i: Integer;
begin
  inherited Create;
  if numThreads = 0 then
    numThreads := 1;
  FLock := TObject.Create;
  FFunction := nil;
  FOpaque := nil;
  FQueueIndex := 0;
  FQueueEnd := 0;
  FBusyCount := 0;
  FShutdown := False;
  SetLength(FThreads, numThreads);
  for i := 0 to High(FThreads) do
  begin
    FThreads[i] := TFL2WorkerThread.Create(Self);
  end;
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
  for i := 0 to High(FThreads) do
  begin
    FThreads[i].WaitFor;
    FThreads[i].Free;
  end;
  FLock.Free;
  inherited;
end;

procedure TFL2POOL_ctx.AddRange(function_: TFL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  TMonitor.Enter(FLock);
  try
    FFunction := function_;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    TMonitor.PulseAll(FLock);
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TFL2POOL_ctx.Add(function_: TFL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  AddRange(function_, opaque, n, n + 1);
end;

function TFL2POOL_ctx.WaitAll(timeout: Cardinal): Integer;
var
  start: UInt64;
  remaining: Cardinal;
begin
  start := TThread.GetTickCount64;
  remaining := timeout;
  TMonitor.Enter(FLock);
  try
    while ((FBusyCount > 0) or (FQueueIndex < FQueueEnd)) and not FShutdown do
    begin
      if timeout = 0 then
        TMonitor.Wait(FLock)
      else begin
        if remaining = 0 then
          Exit(1);
        if not TMonitor.Wait(FLock, remaining) then
          Exit(1);
        remaining := timeout - (TThread.GetTickCount64 - start);
      end;
    end;
  finally
    TMonitor.Exit(FLock);
  end;
  Result := 0;
end;

function TFL2POOL_ctx.ThreadsBusy: Cardinal;
begin
  TMonitor.Enter(FLock);
  try
    Result := FBusyCount;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function FL2POOL_create(numThreads: Cardinal): TFL2POOL_ctx;
begin
  Result := TFL2POOL_ctx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: TFL2POOL_ctx);
begin
  if ctx <> nil then
    ctx.Free;
end;

procedure FL2POOL_addRange(ctx: TFL2POOL_ctx; function_: TFL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if ctx <> nil then
    ctx.AddRange(function_, opaque, first, last);
end;

procedure FL2POOL_add(ctx: TFL2POOL_ctx; function_: TFL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  if ctx <> nil then
    ctx.Add(function_, opaque, n);
end;

function FL2POOL_waitAll(ctx: TFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  if ctx = nil then
    Exit(0);
  Result := ctx.WaitAll(timeout);
end;

function FL2POOL_threadsBusy(ctx: TFL2POOL_ctx): Cardinal;
begin
  if ctx = nil then
    Result := 0
  else
    Result := ctx.ThreadsBusy;
end;

end.
