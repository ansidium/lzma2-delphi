unit FL2Pool;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs;

type
  TFL2POOLFunction = procedure(opaque: Pointer; n: NativeInt); cdecl;

  TFL2PoolCtx = class;

  TFL2PoolWorker = class(TThread)
  private
    FPool: TFL2PoolCtx;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TFL2PoolCtx);
  end;

  TFL2PoolCtx = class
  private
    FThreads: array of TFL2PoolWorker;
    FLock: TCriticalSection;
    FJobEvent: TEvent;
    FAllDone: TEvent;
    FFunction: TFL2POOLFunction;
    FOpaque: Pointer;
    FQueueIndex: NativeInt;
    FQueueEnd: NativeInt;
    FBusy: Integer;
    FShutdown: Boolean;
  public
    constructor Create(NumThreads: Integer);
    destructor Destroy; override;
    procedure AddRange(Func: TFL2POOLFunction; Opaque: Pointer; First, Last: NativeInt);
    procedure Add(Func: TFL2POOLFunction; Opaque: Pointer; N: NativeInt);
    function WaitAll(Timeout: Cardinal): Boolean;
    function ThreadsBusy: NativeInt;
  end;

function FL2POOL_create(numThreads: NativeUInt): Pointer; cdecl;
procedure FL2POOL_free(ctx: Pointer); cdecl;
procedure FL2POOL_add(ctx: Pointer; func: TFL2POOLFunction; opaque: Pointer; n: NativeInt); cdecl;
procedure FL2POOL_addRange(ctx: Pointer; func: TFL2POOLFunction; opaque: Pointer; first, last: NativeInt); cdecl;
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer; cdecl;
function FL2POOL_threadsBusy(ctx: Pointer): NativeUInt; cdecl;
implementation

{ TFL2PoolWorker }

constructor TFL2PoolWorker.Create(APool: TFL2PoolCtx);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPool := APool;
  Start;
end;

procedure TFL2PoolWorker.Execute;
var
  idx: NativeInt;
begin
  while True do
  begin
    FPool.FJobEvent.WaitFor(INFINITE);
    if FPool.FShutdown then
      Exit;
    repeat
      FPool.FLock.Enter;
      try
        if FPool.FShutdown then
          Exit;
        if FPool.FQueueIndex >= FPool.FQueueEnd then
          Break;
        idx := FPool.FQueueIndex;
        Inc(FPool.FQueueIndex);
        Inc(FPool.FBusy);
        FPool.FAllDone.ResetEvent;
      finally
        FPool.FLock.Leave;
      end;
      try
        if Assigned(FPool.FFunction) then
          FPool.FFunction(FPool.FOpaque, idx);
      finally
        FPool.FLock.Enter;
        try
          Dec(FPool.FBusy);
          if (FPool.FBusy = 0) and (FPool.FQueueIndex >= FPool.FQueueEnd) then
            FPool.FAllDone.SetEvent;
        finally
          FPool.FLock.Leave;
        end;
      end;
    until False;
  end;
end;

{ TFL2PoolCtx }

constructor TFL2PoolCtx.Create(NumThreads: Integer);
var
  i: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FJobEvent := TEvent.Create(nil, True, False, '');
  FAllDone := TEvent.Create(nil, True, True, '');
  SetLength(FThreads, NumThreads);
  for i := 0 to NumThreads - 1 do
    FThreads[i] := TFL2PoolWorker.Create(Self);
end;

destructor TFL2PoolCtx.Destroy;
var
  i: Integer;
begin
  FLock.Enter;
  FShutdown := True;
  FJobEvent.SetEvent;
  FLock.Leave;
  for i := 0 to High(FThreads) do
  begin
    FThreads[i].WaitFor;
    FThreads[i].Free;
  end;
  FJobEvent.Free;
  FAllDone.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFL2PoolCtx.AddRange(Func: TFL2POOLFunction; Opaque: Pointer; First, Last: NativeInt);
begin
  FLock.Enter;
  try
    FFunction := Func;
    FOpaque := Opaque;
    FQueueIndex := First;
    FQueueEnd := Last;
    FAllDone.ResetEvent;
    FJobEvent.SetEvent;
  finally
    FLock.Leave;
  end;
end;

procedure TFL2PoolCtx.Add(Func: TFL2POOLFunction; Opaque: Pointer; N: NativeInt);
begin
  AddRange(Func, Opaque, N, N + 1);
end;

function TFL2PoolCtx.WaitAll(Timeout: Cardinal): Boolean;
begin
  if Timeout = 0 then
    FAllDone.WaitFor(INFINITE)
  else
    FAllDone.WaitFor(Timeout);
  FLock.Enter;
  try
    Result := (FBusy <> 0) or (FQueueIndex < FQueueEnd);
  finally
    FLock.Leave;
  end;
end;

function TFL2PoolCtx.ThreadsBusy: NativeInt;
begin
  FLock.Enter;
  try
    Result := FBusy;
  finally
    FLock.Leave;
  end;
end;

{ C wrappers }

function FL2POOL_create(numThreads: NativeUInt): Pointer; cdecl;
begin
  if numThreads = 0 then
    Exit(nil);
  Result := TFL2PoolCtx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: Pointer); cdecl;
begin
  if ctx <> nil then
    TFL2PoolCtx(ctx).Free;
end;

procedure FL2POOL_add(ctx: Pointer; func: TFL2POOLFunction; opaque: Pointer; n: NativeInt); cdecl;
begin
  if ctx <> nil then
    TFL2PoolCtx(ctx).Add(func, opaque, n);
end;

procedure FL2POOL_addRange(ctx: Pointer; func: TFL2POOLFunction; opaque: Pointer; first, last: NativeInt); cdecl;
begin
  if ctx <> nil then
    TFL2PoolCtx(ctx).AddRange(func, opaque, first, last);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer; cdecl;
begin
  if ctx = nil then
    Exit(0);
  if TFL2PoolCtx(ctx).WaitAll(timeout) then
    Result := 1
  else
    Result := 0;
end;
function FL2POOL_threadsBusy(ctx: Pointer): NativeUInt; cdecl;
begin
  if ctx = nil then
    Exit(0);
  Result := TFL2PoolCtx(ctx).ThreadsBusy;
end;

end.
