unit FL2Pool;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  FL2Threading;

// ----------------------------------------------------------------------------
// Task function signature
//  opaque: user-defined context pointer
//  n: task index
// ----------------------------------------------------------------------------
FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);

// ----------------------------------------------------------------------------
// Procedural API
// ----------------------------------------------------------------------------
function FL2POOL_create(numThreads: NativeUInt): Pointer;
procedure FL2POOL_free(ctx: Pointer);
function FL2POOL_sizeof(ctx: Pointer): NativeUInt;
procedure FL2POOL_add(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: Pointer): NativeUInt;

implementation

// ----------------------------------------------------------------------------
// Internal thread class
// ----------------------------------------------------------------------------
type
  TFL2POOLThread = class(TThread)
  private
    FOwner: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AOwner: Pointer);
  end;

// ----------------------------------------------------------------------------
// Internal pool context
// ----------------------------------------------------------------------------
  TFL2POOL_ctx = class
  private
    FNumThreads: NativeUInt;
    FFunction: FL2POOL_function;
    FOpaque: Pointer;
    FQueueIndex, FQueueEnd: PtrInt;
    FNumThreadsBusy: NativeUInt;
    FQueueMutex: TCriticalSection;
    FBusyCond: TEvent;
    FNewJobsCond: TEvent;
    FShutdown: Boolean;
    FThreads: array of TFL2POOLThread;
    function SizeOfContext: NativeUInt;
  public
    constructor Create(numThreads: NativeUInt);
    destructor Destroy; override;
    procedure AddRange(func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: NativeUInt;
  end;

// ----------------------------------------------------------------------------
// API Implementations
// ----------------------------------------------------------------------------

function FL2POOL_create(numThreads: NativeUInt): Pointer;
begin
  Result := TFL2POOL_ctx.Create(numThreads);
end;

procedure FL2POOL_free(ctx: Pointer);
begin
  if ctx <> nil then
    TObject(ctx).Free;
end;

function FL2POOL_sizeof(ctx: Pointer): NativeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := TFL2POOL_ctx(ctx).SizeOfContext;
end;

procedure FL2POOL_add(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  if ctx = nil then Exit;
  TFL2POOL_ctx(ctx).AddRange(func, opaque, n, n + 1);
end;

procedure FL2POOL_addRange(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if ctx = nil then Exit;
  TFL2POOL_ctx(ctx).AddRange(func, opaque, first, last);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
begin
  if ctx = nil then
    Exit(0);
  Result := TFL2POOL_ctx(ctx).WaitAll(timeout);
end;

function FL2POOL_threadsBusy(ctx: Pointer): NativeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := TFL2POOL_ctx(ctx).ThreadsBusy;
end;

// ----------------------------------------------------------------------------
// TFL2POOLThread implementation
// ----------------------------------------------------------------------------
constructor TFL2POOLThread.Create(const AOwner: Pointer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  Start;
end;

procedure TFL2POOLThread.Execute;
var
  ctx: TFL2POOL_ctx;
  idx: PtrInt;
begin
  ctx := TFL2POOL_ctx(FOwner);
  while True do
  begin
    // Wait for tasks or shutdown
    ctx.FQueueMutex.Enter;
    try
      while (ctx.FQueueIndex >= ctx.FQueueEnd) and not ctx.FShutdown do
      begin
        ctx.FQueueMutex.Leave;
        ctx.FNewJobsCond.WaitFor(INFINITE);
        ctx.FQueueMutex.Enter;
      end;
      if ctx.FShutdown then
        Exit;
      idx := ctx.FQueueIndex;
      Inc(ctx.FQueueIndex);
      Inc(ctx.FNumThreadsBusy);
    finally
      if ctx.FQueueMutex.Owned then
        ctx.FQueueMutex.Leave;
    end;

    try
      if Assigned(ctx.FFunction) then
        ctx.FFunction(ctx.FOpaque, idx);
    finally
      // Mark completion
      ctx.FQueueMutex.Enter;
      try
        Dec(ctx.FNumThreadsBusy);
        ctx.FBusyCond.SetEvent;
      finally
        ctx.FQueueMutex.Leave;
      end;
    end;
  end;
end;

// ----------------------------------------------------------------------------
// TFL2POOL_ctx implementation
// ----------------------------------------------------------------------------
constructor TFL2POOL_ctx.Create(numThreads: NativeUInt);
var
  i: Integer;
begin
  inherited Create;
  FNumThreads := FL2_checkNbThreads(numThreads);
  FQueueIndex := 0;
  FQueueEnd := 0;
  FNumThreadsBusy := 0;
  FShutdown := False;
  FQueueMutex := TCriticalSection.Create;
  FBusyCond := TEvent.Create(nil, False, False, '');
  FNewJobsCond := TEvent.Create(nil, True, False, '');
  SetLength(FThreads, FNumThreads);
  for i := 0 to Integer(FNumThreads) - 1 do
    FThreads[i] := TFL2POOLThread.Create(Self);
end;

destructor TFL2POOL_ctx.Destroy;
var
  i: Integer;
begin
  // Shutdown signal
  FQueueMutex.Enter;
  try
    FShutdown := True;
    FNewJobsCond.SetEvent;
  finally
    FQueueMutex.Leave;
  end;

  // Wait threads
  for i := 0 to High(FThreads) do
    if Assigned(FThreads[i]) then
    begin
      FThreads[i].WaitFor;
      FThreads[i].Free;
    end;

  FNewJobsCond.Free;
  FBusyCond.Free;
  FQueueMutex.Free;
  inherited;
end;

procedure TFL2POOL_ctx.AddRange(func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
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

function TFL2POOL_ctx.WaitAll(timeout: Cardinal): Integer;
var
  waitRes: Cardinal;
begin
  // Quick exit
  FQueueMutex.Enter;
  try
    if (FNumThreadsBusy = 0) and (FQueueIndex >= FQueueEnd) then
      Exit(0);
  finally
    FQueueMutex.Leave;
  end;

  if timeout = 0 then
  begin
    repeat
      FBusyCond.WaitFor(INFINITE);
      FQueueMutex.Enter;
    until (FNumThreadsBusy = 0) and (FQueueIndex >= FQueueEnd);
    FQueueMutex.Leave;
    Exit(0);
  end;

  waitRes := FBusyCond.WaitFor(timeout);
  FQueueMutex.Enter;
  try
    if (FNumThreadsBusy > 0) or (FQueueIndex < FQueueEnd) then
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
  // Approximate: object + thread pointers array
  Result := SizeOf(TFL2POOL_ctx) + FNumThreads * SizeOf(Pointer);
end;

end.
