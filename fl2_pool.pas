unit FL2Pool;

interface

uses
  FL2Threading;
  Classes, SysUtils, SyncObjs;

type
  FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);
  PFL2POOL_ctx = ^TFL2POOL_ctx;
  TFL2POOL_ctx = record
    numThreads: Cardinal;
  end;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;

implementation

uses
  System.SysUtils;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
begin
  New(Result);
  Result^.numThreads := FL2_checkNbThreads(numThreads);
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx <> nil then
    Dispose(ctx);
end;

function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
  TFL2PoolThread = class(TThread)
  private
    FOwner: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: Pointer);
  end;

  TFL2POOL_ctx = class
  private
    FNumThreads: NativeUInt;
    FFunction: FL2POOL_function;
    FOpaque: Pointer;
    FNumThreadsBusy: NativeUInt;
    FQueueIndex: PtrInt;
    FQueueEnd: PtrInt;
    FQueueMutex: TCriticalSection;
    FBusyCond: TEvent;
    FNewJobsCond: TEvent;
    FShutdown: Boolean;
    FThreads: array of TFL2PoolThread;
  public
    constructor Create(numThreads: NativeUInt);
    destructor Destroy; override;
    procedure AddRange(func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
    procedure Add(func: FL2POOL_function; opaque: Pointer; n: PtrInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: NativeUInt;
    function SizeOfContext: NativeUInt;
  end;

function FL2POOL_create(numThreads: NativeUInt): TFL2POOL_ctx;
procedure FL2POOL_free(ctx: TFL2POOL_ctx);
function FL2POOL_sizeof(ctx: TFL2POOL_ctx): NativeUInt;
procedure FL2POOL_addRange(ctx: TFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
procedure FL2POOL_add(ctx: TFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
function FL2POOL_waitAll(ctx: TFL2POOL_ctx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: TFL2POOL_ctx): NativeUInt;

implementation

{ TFL2PoolThread }

constructor TFL2PoolThread.Create(AOwner: Pointer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TFL2PoolThread.Execute;
var
  ctx: TFL2POOL_ctx;
  n: PtrInt;
begin
  ctx := TFL2POOL_ctx(FOwner);
  ctx.FQueueMutex.Enter;
  try
    while True do
    begin
      while (ctx.FQueueIndex >= ctx.FQueueEnd) and not ctx.FShutdown do
      begin
        ctx.FQueueMutex.Leave;
        ctx.FNewJobsCond.WaitFor(INFINITE);
        ctx.FQueueMutex.Enter;
      end;
      if ctx.FShutdown then
        Exit;
      n := ctx.FQueueIndex;
      Inc(ctx.FQueueIndex);
      Inc(ctx.FNumThreadsBusy);
      ctx.FQueueMutex.Leave;
      try
        if Assigned(ctx.FFunction) then
          ctx.FFunction(ctx.FOpaque, n);
      finally
        ctx.FQueueMutex.Enter;
        Dec(ctx.FNumThreadsBusy);
        ctx.FBusyCond.SetEvent;
      end;
    end;
  finally
    ctx.FQueueMutex.Leave;
  end;
end;

{ TFL2POOL_ctx }

constructor TFL2POOL_ctx.Create(numThreads: NativeUInt);
var
  i: Integer;
begin
  inherited Create;
  if numThreads = 0 then Exit;
  FNumThreads := numThreads;
  FNumThreadsBusy := 0;
  FQueueIndex := 0;
  FQueueEnd := 0;
  FQueueMutex := TCriticalSection.Create;
  FBusyCond := TEvent.Create(nil, False, False, '');
  FNewJobsCond := TEvent.Create(nil, True, False, '');
  FShutdown := False;
  SetLength(FThreads, numThreads);
  for i := 0 to High(FThreads) do
  begin
    FThreads[i] := TFL2PoolThread.Create(Self);
    FThreads[i].Start;
  end;
end;

destructor TFL2POOL_ctx.Destroy;
var
  i: Integer;
begin
  FQueueMutex.Enter;
  FShutdown := True;
  FNewJobsCond.SetEvent;
  FQueueMutex.Leave;
  for i := 0 to High(FThreads) do
  begin
    if Assigned(FThreads[i]) then
    begin
      FThreads[i].WaitFor;
      FThreads[i].Free;
    end;
  end;
  FNewJobsCond.Free;
  FBusyCond.Free;
  FQueueMutex.Free;
  inherited Destroy;
end;

procedure TFL2POOL_ctx.AddRange(func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if Self = nil then Exit;
  FQueueMutex.Enter;
  try
    FFunction := func;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    FNewJobsCond.SetEvent;
  finally
    FQueueMutex.Leave;
  end;
end;

procedure TFL2POOL_ctx.Add(func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  AddRange(func, opaque, n, n + 1);
end;

function TFL2POOL_ctx.WaitAll(timeout: Cardinal): Integer;
var
  t: Cardinal;
begin
  if Self = nil then Exit(0);
  FQueueMutex.Enter;
  try
    if (FNumThreadsBusy = 0) and (FQueueIndex >= FQueueEnd) or FShutdown then
      Exit(0);
    if timeout <> 0 then
    begin
      t := FBusyCond.WaitFor(timeout);
    end
    else
    begin
      while ((FNumThreadsBusy > 0) or (FQueueIndex < FQueueEnd)) and not FShutdown do
      begin
        FQueueMutex.Leave;
        FBusyCond.WaitFor(INFINITE);
        FQueueMutex.Enter;
      end;
      t := 0;
    end;
    if (FNumThreadsBusy > 0) and not FShutdown then
      Result := 1
    else
      Result := 0;
  finally
    FQueueMutex.Leave;
  end;
end;

function TFL2POOL_ctx.ThreadsBusy: NativeUInt;
begin
  Result := FNumThreadsBusy;
end;

function TFL2POOL_ctx.SizeOfContext: NativeUInt;
begin
  Result := SizeOf(Self) + FNumThreads * SizeOf(Pointer);
end;

function FL2POOL_create(numThreads: NativeUInt): TFL2POOL_ctx;
begin
  Result := TFL2POOL_ctx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: TFL2POOL_ctx);
begin
  if ctx <> nil then
    ctx.Free;
end;

function FL2POOL_sizeof(ctx: TFL2POOL_ctx): NativeUInt;
begin
  if ctx = nil then
    Result := 0
  else
    Result := SizeOf(ctx^);
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
var
  i: PtrInt;
begin
  if ctx = nil then Exit;
  for i := first to last - 1 do
    func(opaque, i);
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  FL2POOL_addRange(ctx, func, opaque, n, n + 1);
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  Result := 0; // synchronous stub
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;
begin
  Result := 0;
end;

end.
    Result := ctx.SizeOfContext;
end;

procedure FL2POOL_addRange(ctx: TFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if ctx <> nil then
    ctx.AddRange(func, opaque, first, last);
end;

procedure FL2POOL_add(ctx: TFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  if ctx <> nil then
    ctx.Add(func, opaque, n);
end;

function FL2POOL_waitAll(ctx: TFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  if ctx <> nil then
    Result := ctx.WaitAll(timeout)
  else
    Result := 0;
end;

function FL2POOL_threadsBusy(ctx: TFL2POOL_ctx): NativeUInt;
begin
  if ctx <> nil then
    Result := ctx.ThreadsBusy
  else
    Result := 0;
end;

end.
