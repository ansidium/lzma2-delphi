unit FL2Pool;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs;

type
  FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);

  TFL2Worker = class(TThread)
  private
    FContext: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(ctx: Pointer);
  end;

  TFL2Pool = class
  private
    FLock: TCriticalSection;
    FNewJob: TEvent;
    FBusyEvent: TEvent;
    FWorkers: array of TFL2Worker;
    FFunction: FL2POOL_function;
    FOpaque: Pointer;
    FQueueIndex: PtrInt;
    FQueueEnd: PtrInt;
    FNumThreadsBusy: Integer;
    FShutdown: Boolean;
  public
    constructor Create(numThreads: Integer);
    destructor Destroy; override;
    procedure AddRange(func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
    procedure Add(func: FL2POOL_function; opaque: Pointer; n: PtrInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: Cardinal;
  end;

function FL2POOL_create(numThreads: SizeUInt): Pointer;
procedure FL2POOL_free(ctx: Pointer);
function FL2POOL_sizeof(ctx: Pointer): SizeUInt;
procedure FL2POOL_add(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: Pointer): SizeUInt;

implementation

{ TFL2Worker }

constructor TFL2Worker.Create(ctx: Pointer);
begin
  FContext := ctx;
  inherited Create(False);
end;

procedure TFL2Worker.Execute;
var
  pool: TFL2Pool absolute FContext;
  idx: PtrInt;
begin
  while not Terminated do
  begin
    pool.FLock.Acquire;
    while (pool.FQueueIndex >= pool.FQueueEnd) and (not pool.FShutdown) do
    begin
      pool.FLock.Release;
      pool.FNewJob.WaitFor(INFINITE);
      if Terminated then Exit;
      pool.FLock.Acquire;
    end;
    if pool.FShutdown then
    begin
      pool.FLock.Release;
      Break;
    end;
    idx := pool.FQueueIndex;
    Inc(pool.FQueueIndex);
    Inc(pool.FNumThreadsBusy);
    pool.FLock.Release;

    if Assigned(pool.FFunction) then
      pool.FFunction(pool.FOpaque, idx);

    pool.FLock.Acquire;
    Dec(pool.FNumThreadsBusy);
    pool.FBusyEvent.SetEvent;
    pool.FLock.Release;
  end;
end;

{ TFL2Pool }

constructor TFL2Pool.Create(numThreads: Integer);
var
  i: Integer;
begin
  FLock := TCriticalSection.Create;
  FNewJob := TEvent.Create(nil, True, False, '');
  FBusyEvent := TEvent.Create(nil, False, False, '');
  SetLength(FWorkers, numThreads);
  FQueueIndex := 0;
  FQueueEnd := 0;
  FNumThreadsBusy := 0;
  FShutdown := False;
  for i := 0 to numThreads - 1 do
    FWorkers[i] := TFL2Worker.Create(Self);
end;

destructor TFL2Pool.Destroy;
var
  i: Integer;
begin
  FLock.Acquire;
  FShutdown := True;
  FNewJob.SetEvent;
  FLock.Release;
  for i := 0 to Length(FWorkers) - 1 do
  begin
    FWorkers[i].Terminate;
    FNewJob.SetEvent;
    FWorkers[i].WaitFor;
    FWorkers[i].Free;
  end;
  FBusyEvent.SetEvent;
  FBusyEvent.Free;
  FNewJob.Free;
  FLock.Free;
  inherited;
end;

procedure TFL2Pool.AddRange(func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if not Assigned(func) then Exit;
  FLock.Acquire;
  FFunction := func;
  FOpaque := opaque;
  FQueueIndex := first;
  FQueueEnd := last;
  FBusyEvent.ResetEvent;
  FNewJob.SetEvent;
  FLock.Release;
end;

procedure TFL2Pool.Add(func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  AddRange(func, opaque, n, n + 1);
end;

function TFL2Pool.WaitAll(timeout: Cardinal): Integer;
begin
  if timeout = 0 then
  begin
    while ThreadsBusy > 0 do
      FBusyEvent.WaitFor(INFINITE);
    Result := 0;
  end
  else
  begin
    if ThreadsBusy > 0 then
      FBusyEvent.WaitFor(timeout);
    Result := Ord(ThreadsBusy > 0);
  end;
end;

function TFL2Pool.ThreadsBusy: Cardinal;
begin
  FLock.Acquire;
  try
    Result := FNumThreadsBusy;
  finally
    FLock.Release;
  end;
end;

function FL2POOL_create(numThreads: SizeUInt): Pointer;
begin
  Result := Pointer(TFL2Pool.Create(numThreads));
end;

procedure FL2POOL_free(ctx: Pointer);
begin
  if ctx = nil then Exit;
  TFL2Pool(ctx).Free;
end;

function FL2POOL_sizeof(ctx: Pointer): SizeUInt;
begin
  if ctx = nil then Exit(0);
  Result := SizeOf(TFL2Pool) + SizeOf(TFL2Worker) * Length(TFL2Pool(ctx).FWorkers);
end;

procedure FL2POOL_add(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  if ctx = nil then Exit;
  TFL2Pool(ctx).Add(func, opaque, n);
end;

procedure FL2POOL_addRange(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if ctx = nil then Exit;
  TFL2Pool(ctx).AddRange(func, opaque, first, last);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
begin
  if ctx = nil then Exit(0);
  Result := TFL2Pool(ctx).WaitAll(timeout);
end;

function FL2POOL_threadsBusy(ctx: Pointer): SizeUInt;
begin
  if ctx = nil then Exit(0);
  Result := TFL2Pool(ctx).ThreadsBusy;
end;

end.
