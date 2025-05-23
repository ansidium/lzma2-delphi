unit FL2Pool;

interface

uses
  System.Classes, System.SyncObjs, System.SysUtils, FL2Threading;

type
  TFL2PoolFunction = procedure(opaque: Pointer; n: NativeInt);

  TFL2PoolWorker = class(TThread)
  private
    FPool: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: Pointer);
  end;

  TFL2POOL_ctx = class
  private
    FThreads: array of TFL2PoolWorker;
    FQueueMutex: TCriticalSection;
    FQueueEvent: TEvent;
    FBusyEvent: TEvent;
    FFunction: TFL2PoolFunction;
    FOpaque: Pointer;
    FQueueIndex: NativeInt;
    FQueueEnd: NativeInt;
    FNumThreadsBusy: Integer;
    FShutdown: Boolean;
  public
    constructor Create(numThreads: Cardinal);
    destructor Destroy; override;
    procedure AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: Integer;
  end;

function FL2POOL_create(numThreads: Cardinal): Pointer; cdecl;
procedure FL2POOL_free(ctx: Pointer); cdecl;
procedure FL2POOL_add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt); cdecl;
procedure FL2POOL_addRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt); cdecl;
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer; cdecl;
function FL2POOL_threadsBusy(ctx: Pointer): Cardinal; cdecl;

implementation

{ TFL2PoolWorker }

constructor TFL2PoolWorker.Create(APool: Pointer);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure TFL2PoolWorker.Execute;
var
  p: TFL2POOL_ctx absolute FPool;
  n: NativeInt;
begin
  while True do
  begin
    p.FQueueMutex.Acquire;
    while (p.FQueueIndex >= p.FQueueEnd) and not p.FShutdown do
    begin
      p.FQueueMutex.Release;
      p.FQueueEvent.WaitFor(INFINITE);
      p.FQueueMutex.Acquire;
    end;
    if p.FShutdown then
    begin
      p.FQueueMutex.Release;
      Exit;
    end;
    n := p.FQueueIndex;
    Inc(p.FQueueIndex);
    Inc(p.FNumThreadsBusy);
    p.FQueueMutex.Release;

    if Assigned(p.FFunction) then
      p.FFunction(p.FOpaque, n);

    p.FQueueMutex.Acquire;
    Dec(p.FNumThreadsBusy);
    if (p.FNumThreadsBusy = 0) and (p.FQueueIndex >= p.FQueueEnd) then
      p.FBusyEvent.SetEvent;
    p.FQueueMutex.Release;
  end;
end;

{ TFL2POOL_ctx }

constructor TFL2POOL_ctx.Create(numThreads: Cardinal);
var
  i: Integer;
begin
  inherited Create;
  if numThreads = 0 then
    numThreads := FL2_checkNbThreads(0);
  SetLength(FThreads, numThreads);
  FQueueMutex := TCriticalSection.Create;
  FQueueEvent := TEvent.Create(nil, False, False, '');
  FBusyEvent := TEvent.Create(nil, True, True, '');
  for i := 0 to High(FThreads) do
    FThreads[i] := TFL2PoolWorker.Create(Self);
end;

destructor TFL2POOL_ctx.Destroy;
var
  i: Integer;
begin
  FQueueMutex.Acquire;
  FShutdown := True;
  FQueueEvent.SetEvent;
  FQueueMutex.Release;
  for i := 0 to High(FThreads) do
  begin
    FThreads[i].WaitFor;
    FThreads[i].Free;
  end;
  FBusyEvent.Free;
  FQueueEvent.Free;
  FQueueMutex.Free;
  inherited;
end;

procedure TFL2POOL_ctx.AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
begin
  FQueueMutex.Acquire;
  FFunction := func;
  FOpaque := opaque;
  FQueueIndex := first;
  FQueueEnd := last;
  FBusyEvent.ResetEvent;
  FQueueEvent.SetEvent;
  FQueueMutex.Release;
end;

function TFL2POOL_ctx.WaitAll(timeout: Cardinal): Integer;
begin
  if timeout = 0 then
    FBusyEvent.WaitFor(INFINITE)
  else
    FBusyEvent.WaitFor(timeout);
  Result := Integer((FNumThreadsBusy <> 0) or (FQueueIndex < FQueueEnd));
end;

function TFL2POOL_ctx.ThreadsBusy: Integer;
begin
  Result := FNumThreadsBusy;
end;
{ C API wrappers }

function FL2POOL_create(numThreads: Cardinal): Pointer; cdecl;
begin
  Result := TFL2POOL_ctx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: Pointer); cdecl;
begin
  if ctx <> nil then
    TFL2POOL_ctx(ctx).Free;
end;

procedure FL2POOL_add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt); cdecl;
begin
  FL2POOL_addRange(ctx, func, opaque, n, n + 1);
end;

procedure FL2POOL_addRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt); cdecl;
begin
  if ctx <> nil then
    TFL2POOL_ctx(ctx).AddRange(func, opaque, first, last);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer; cdecl;
begin
  if ctx <> nil then
    Result := TFL2POOL_ctx(ctx).WaitAll(timeout)
  else
    Result := 0;
end;

function FL2POOL_threadsBusy(ctx: Pointer): Cardinal; cdecl;
begin
  if ctx <> nil then
    Result := TFL2POOL_ctx(ctx).ThreadsBusy
  else
    Result := 0;
end;

end.
