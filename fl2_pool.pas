unit FL2Pool;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  FL2Threading;

const
  // Максимальное количество потоков по умолчанию
  FL2POOL_MAXTHREADS = FL2_MAXTHREADS;

// ----------------------------------------------------------------------------
// Task function signature
//  opaque: user-defined context pointer
//  n: task index
// ----------------------------------------------------------------------------
TFL2PoolFunction = procedure(opaque: Pointer; n: PtrInt);

// ----------------------------------------------------------------------------
// Procedural API
// ----------------------------------------------------------------------------
function FL2Pool_Create(numThreads: NativeUInt): Pointer;
procedure FL2Pool_Free(ctx: Pointer);
function FL2Pool_SizeOf(ctx: Pointer): NativeUInt;
procedure FL2Pool_Add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
procedure FL2Pool_AddRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
function FL2Pool_WaitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2Pool_ThreadsBusy(ctx: Pointer): NativeUInt;

implementation

// ----------------------------------------------------------------------------
// Internal thread class
// ----------------------------------------------------------------------------

type
  TFL2PoolThread = class(TThread)
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

  TFL2PoolCtx = class
  private
    FNumThreads: NativeUInt;
    FFunction: TFL2PoolFunction;
    FOpaque: Pointer;
    FQueueIndex, FQueueEnd: PtrInt;
    FNumBusy: NativeUInt;
    FMutex: TCriticalSection;
    FBusyEvt: TEvent;
    FNewEvt: TEvent;
    FShutdown: Boolean;
    FThreads: array of TFL2PoolThread;
    function SizeOfContext: NativeUInt;
  public
    constructor Create(numThreads: NativeUInt);
    destructor Destroy; override;
    procedure AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
    function WaitAll(timeout: Cardinal): Integer;
    function ThreadsBusy: NativeUInt;
  end;

// ----------------------------------------------------------------------------
// API implementations
// ----------------------------------------------------------------------------

function FL2Pool_Create(numThreads: NativeUInt): Pointer;
begin
  Result := TFL2PoolCtx.Create(numThreads);
end;

procedure FL2Pool_Free(ctx: Pointer);
begin
  if Assigned(ctx) then
    TObject(ctx).Free;
end;

function FL2Pool_SizeOf(ctx: Pointer): NativeUInt;
begin
  if not Assigned(ctx) then
    Exit(0);
  Result := TFL2PoolCtx(ctx).SizeOfContext;
end;

procedure FL2Pool_Add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
begin
  if not Assigned(ctx) then Exit;
  TFL2PoolCtx(ctx).AddRange(func, opaque, n, n + 1);
end;

procedure FL2Pool_AddRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
begin
  if not Assigned(ctx) then Exit;
  TFL2PoolCtx(ctx).AddRange(func, opaque, first, last);
end;

function FL2Pool_WaitAll(ctx: Pointer; timeout: Cardinal): Integer;
begin
  if not Assigned(ctx) then
    Exit(0);
  Result := TFL2PoolCtx(ctx).WaitAll(timeout);
end;

function FL2Pool_ThreadsBusy(ctx: Pointer): NativeUInt;
begin
  if not Assigned(ctx) then
    Exit(0);
  Result := TFL2PoolCtx(ctx).ThreadsBusy;
end;

// ----------------------------------------------------------------------------
// TFL2PoolThread implementation
// ----------------------------------------------------------------------------

constructor TFL2PoolThread.Create(const AOwner: Pointer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  Start;
end;

procedure TFL2PoolThread.Execute;
var
  Ctx: TFL2PoolCtx;
  idx: PtrInt;
begin
  Ctx := TFL2PoolCtx(FOwner);
  while True do
  begin
    Ctx.FMutex.Enter;
    try
      while (Ctx.FQueueIndex >= Ctx.FQueueEnd) and not Ctx.FShutdown do
      begin
        Ctx.FMutex.Leave;
        Ctx.FNewEvt.WaitFor(INFINITE);
        Ctx.FMutex.Enter;
      end;
      if Ctx.FShutdown then Exit;
      idx := Ctx.FQueueIndex;
      Inc(Ctx.FQueueIndex);
      Inc(Ctx.FNumBusy);
    finally
      if Ctx.FMutex.Owned then Ctx.FMutex.Leave;
    end;

    try
      if Assigned(Ctx.FFunction) then
        Ctx.FFunction(Ctx.FOpaque, idx);
    finally
      Ctx.FMutex.Enter;
      try
        Dec(Ctx.FNumBusy);
        Ctx.FBusyEvt.SetEvent;
      finally
        Ctx.FMutex.Leave;
      end;
    end;
  end;
end;

// ----------------------------------------------------------------------------
// TFL2PoolCtx implementation
// ----------------------------------------------------------------------------

constructor TFL2PoolCtx.Create(numThreads: NativeUInt);
var i: Integer;
begin
  inherited Create;
  FNumThreads := FL2_checkNbThreads(numThreads);
  FQueueIndex := 0;
  FQueueEnd := 0;
  FNumBusy := 0;
  FShutdown := False;
  FMutex := TCriticalSection.Create;
  FBusyEvt := TEvent.Create(nil, False, False, '');
  FNewEvt := TEvent.Create(nil, True, False, '');
  SetLength(FThreads, FNumThreads);
  for i := 0 to Integer(FNumThreads) - 1 do
    FThreads[i] := TFL2PoolThread.Create(Self);
end;

destructor TFL2PoolCtx.Destroy;
var i: Integer;
begin
  FMutex.Enter;
  try
    FShutdown := True;
    FNewEvt.SetEvent;
  finally
    FMutex.Leave;
  end;

  for i := 0 to High(FThreads) do
    if Assigned(FThreads[i]) then
    begin
      FThreads[i].WaitFor;
      FThreads[i].Free;
    end;

  FNewEvt.Free;
  FBusyEvt.Free;
  FMutex.Free;
  inherited;
end;

procedure TFL2PoolCtx.AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
begin
  FMutex.Enter;
  try
    FFunction := func;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    FNewEvt.SetEvent;
  finally
    FMutex.Leave;
  end;
end;

function TFL2PoolCtx.WaitAll(timeout: Cardinal): Integer;
var waitRes: Cardinal;
begin
  FMutex.Enter;
  try
    if (FNumBusy = 0) and (FQueueIndex >= FQueueEnd) then
      Exit(0);
  finally
    FMutex.Leave;
  end;

  if timeout = 0 then
  begin
    repeat
      FBusyEvt.WaitFor(INFINITE);
      FMutex.Enter;
    until (FNumBusy = 0) and (FQueueIndex >= FQueueEnd);
    FMutex.Leave;
    Exit(0);
  end;

  waitRes := FBusyEvt.WaitFor(timeout);
  FMutex.Enter;
  try
    if (FNumBusy > 0) or (FQueueIndex < FQueueEnd) then
      Result := 1
    else
      Result := 0;
  finally
    FMutex.Leave;
  end;
end;

function TFL2PoolCtx.ThreadsBusy: NativeUInt;
begin
  Result := FNumBusy;
end;

function TFL2PoolCtx.SizeOfContext: NativeUInt;
begin
  Result := SizeOf(TFL2PoolCtx) + FNumThreads * SizeOf(Pointer);
end;

end.
