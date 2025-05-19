unit FL2Pool;

interface

uses
  System.Classes, System.SysUtils, System.SyncObjs,
  FL2Threading;

const
  // Индикатор бесконечного ожидания
  InfiniteTimeout: Cardinal = INFINITE;
  // Максимальное количество потоков в пуле
  FL2POOL_MAXTHREADS = FL2_MAXTHREADS;

// ----------------------------------------------------------------------------
// Подпись задачи
//  opaque: пользовательский контекст
//  n: индекс задачи
// ----------------------------------------------------------------------------
TFL2PoolFunction = procedure(opaque: Pointer; n: PtrInt);

// ----------------------------------------------------------------------------
// Процедурный API пула
// ----------------------------------------------------------------------------
function FL2Pool_Create(numThreads: NativeUInt): Pointer;
procedure FL2Pool_Free(ctx: Pointer);
function FL2Pool_SizeOf(ctx: Pointer): NativeUInt;
procedure FL2Pool_Add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
procedure FL2Pool_AddRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
function FL2Pool_WaitAll(ctx: Pointer; timeout: Cardinal): Boolean;
function FL2Pool_ThreadsBusy(ctx: Pointer): Cardinal;

implementation

// ----------------------------------------------------------------------------
// Внутренний класс потока-рабочего
// ----------------------------------------------------------------------------
type
  TFL2WorkerThread = class(TThread)
  private
    FPool: Pointer; // TFL2PoolCtx
  protected
    procedure Execute; override;
  public
    constructor Create(APool: Pointer);
  end;

// ----------------------------------------------------------------------------
// Внутренний контекст пула
// ----------------------------------------------------------------------------
  TFL2PoolCtx = class
  private
    FThreads: array of TFL2WorkerThread;
    FMutex: TCriticalSection;
    FNewJobs: TEvent;
    FBusyEvent: TEvent;
    FFunction: TFL2PoolFunction;
    FOpaque: Pointer;
    FQueueIndex, FQueueEnd: PtrInt;
    FNumBusy: Integer;
    FShutdown: Boolean;
    function PopJob(out N: PtrInt): Boolean;
    procedure FinishJob;
    function SizeOfContext: NativeUInt;
  public
    constructor Create(numThreads: Cardinal);
    destructor Destroy; override;
    procedure AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
    procedure Add(func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
    function WaitAll(timeout: Cardinal): Boolean;
    function ThreadsBusy: Cardinal;
  end;

// ----------------------------------------------------------------------------
// API реализации
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
  if Assigned(ctx) then
    Result := TFL2PoolCtx(ctx).SizeOfContext
  else
    Result := 0;
end;

procedure FL2Pool_Add(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
begin
  if Assigned(ctx) then
    TFL2PoolCtx(ctx).Add(func, opaque, n);
end;

procedure FL2Pool_AddRange(ctx: Pointer; func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
begin
  if Assigned(ctx) then
    TFL2PoolCtx(ctx).AddRange(func, opaque, first, last);
end;

function FL2Pool_WaitAll(ctx: Pointer; timeout: Cardinal): Boolean;
begin
  if Assigned(ctx) then
    Result := TFL2PoolCtx(ctx).WaitAll(timeout)
  else
    Result := True;
end;

function FL2Pool_ThreadsBusy(ctx: Pointer): Cardinal;
begin
  if Assigned(ctx) then
    Result := TFL2PoolCtx(ctx).ThreadsBusy
  else
    Result := 0;
end;

// ----------------------------------------------------------------------------
// TFL2WorkerThread implementation
// ----------------------------------------------------------------------------

constructor TFL2WorkerThread.Create(APool: Pointer);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FPool := APool;
end;

procedure TFL2WorkerThread.Execute;
var
  job: PtrInt;
begin
  while not Terminated do
  begin
    if not TFL2PoolCtx(FPool).PopJob(job) then
      Break;
    try
      TFL2PoolCtx(FPool).FFunction(TFL2PoolCtx(FPool).FOpaque, job);
    finally
      TFL2PoolCtx(FPool).FinishJob;
    end;
  end;
end;

// ----------------------------------------------------------------------------
// TFL2PoolCtx implementation
// ----------------------------------------------------------------------------

constructor TFL2PoolCtx.Create(numThreads: Cardinal);
var i: Integer;
begin
  inherited Create;
  if numThreads = 0 then
    numThreads := 1;
  numThreads := FL2_checkNbThreads(numThreads);
  SetLength(FThreads, numThreads);
  FMutex := TCriticalSection.Create;
  FNewJobs := TEvent.Create(nil, False, False, '');
  FBusyEvent := TEvent.Create(nil, False, False, '');
  FFunction := nil;
  FOpaque := nil;
  FQueueIndex := 0;
  FQueueEnd := 0;
  FNumBusy := 0;
  FShutdown := False;
  for i := 0 to High(FThreads) do
    FThreads[i] := TFL2WorkerThread.Create(Self);
end;

destructor TFL2PoolCtx.Destroy;
var i: Integer;
begin
  FMutex.Acquire;
  try
    FShutdown := True;
    FNewJobs.SetEvent;
  finally
    FMutex.Release;
  end;
  for i := 0 to High(FThreads) do
  begin
    FThreads[i].WaitFor;
    FThreads[i].Free;
  end;
  FBusyEvent.Free;
  FNewJobs.Free;
  FMutex.Free;
  inherited;
end;

function TFL2PoolCtx.PopJob(out N: PtrInt): Boolean;
begin
  Result := False;
  while True do
  begin
    FMutex.Acquire;
    try
      if FShutdown then Exit;
      if FQueueIndex < FQueueEnd then
      begin
        N := FQueueIndex;
        Inc(FQueueIndex);
        Inc(FNumBusy);
        Result := True;
        Exit;
      end;
      FNewJobs.ResetEvent;
    finally
      FMutex.Release;
    end;
    if not FNewJobs.WaitFor(InfiniteTimeout) then
      Exit;
  end;
end;

procedure TFL2PoolCtx.FinishJob;
begin
  FMutex.Acquire;
  try
    Dec(FNumBusy);
    if FNumBusy = 0 then
      FBusyEvent.SetEvent;
  finally
    FMutex.Release;
  end;
end;

procedure TFL2PoolCtx.AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
begin
  FMutex.Acquire;
  try
    FFunction := func;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    FBusyEvent.ResetEvent;
    FNewJobs.SetEvent;
  finally
    FMutex.Release;
  end;
end;

procedure TFL2PoolCtx.Add(func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
begin
  AddRange(func, opaque, n, n + 1);
end;

function TFL2PoolCtx.WaitAll(timeout: Cardinal): Boolean;
begin
  if timeout = 0 then
    FBusyEvent.WaitFor(InfiniteTimeout)
  else
    Result := FBusyEvent.WaitFor(timeout) = wrSignaled;
end;

function TFL2PoolCtx.ThreadsBusy: Cardinal;
begin
  FMutex.Acquire;
  try
    Result := FNumBusy;
  finally
    FMutex.Release;
  end;
end;

function TFL2PoolCtx.SizeOfContext: NativeUInt;
begin
  Result := SizeOf(TFL2PoolCtx) + Length(FThreads) * SizeOf(Pointer);
end;

end.
