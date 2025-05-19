unit FL2Pool;

interface

uses
  System.SysUtils, System.SyncObjs, System.Classes,
  System.Generics.Collections;

type
  FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);
  PFL2POOL_ctx = Pointer;

function FL2POOL_create(numThreads: NativeUInt): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;

implementation

type
  TFL2Job = record
    Func: FL2POOL_function;
    Opaque: Pointer;
    Index: PtrInt;
  end;

  TFL2Pool = class;

  TFL2Worker = class(TThread)
  private
    FPool: TFL2Pool;
  protected
    procedure Execute; override;
  public
    constructor Create(APool: TFL2Pool);
  end;

  TFL2Pool = class
  private
    FQueue: TQueue<TFL2Job>;
    FCrit: TCriticalSection;
    FJobEvent: TEvent;
    FBusyEvent: TEvent;
    FThreads: array of TFL2Worker;
    FShutdown: Boolean;
    FBusy: Integer;
    function DequeueJob(out Job: TFL2Job): Boolean;
    procedure FinishedJob;
  public
    constructor Create(NumThreads: Integer);
    destructor Destroy; override;
    procedure AddRange(Func: FL2POOL_function; Opaque: Pointer; First, Last: PtrInt);
    procedure Add(Func: FL2POOL_function; Opaque: Pointer; N: PtrInt);
    function WaitAll(Timeout: Cardinal): Boolean;
    function ThreadsBusy: Cardinal;
  end;

{ TFL2Worker }

constructor TFL2Worker.Create(APool: TFL2Pool);
begin
  FPool := APool;
  inherited Create(False);
end;

procedure TFL2Worker.Execute;
var
  Job: TFL2Job;
begin
  while not Terminated do
  begin
    if not FPool.DequeueJob(Job) then
    begin
      if FPool.FShutdown then
        Break;
      FPool.FJobEvent.WaitFor(INFINITE);
      Continue;
    end;
    try
      Job.Func(Job.Opaque, Job.Index);
    finally
      FPool.FinishedJob;
    end;
  end;
end;

{ TFL2Pool }

constructor TFL2Pool.Create(NumThreads: Integer);
var
  i: Integer;
begin
  FQueue := TQueue<TFL2Job>.Create;
  FCrit := TCriticalSection.Create;
  FJobEvent := TEvent.Create(nil, False, False, '');
  FBusyEvent := TEvent.Create(nil, True, True, '');
  SetLength(FThreads, NumThreads);
  for i := 0 to NumThreads - 1 do
    FThreads[i] := TFL2Worker.Create(Self);
end;

destructor TFL2Pool.Destroy;
var
  Worker: TFL2Worker;
begin
  FShutdown := True;
  FJobEvent.SetEvent;
  for Worker in FThreads do
  begin
    Worker.Terminate;
    Worker.WaitFor;
    Worker.Free;
  end;
  FCrit.Free;
  FJobEvent.Free;
  FBusyEvent.Free;
  FQueue.Free;
  inherited;
end;

procedure TFL2Pool.Add(Func: FL2POOL_function; Opaque: Pointer; N: PtrInt);
var
  Job: TFL2Job;
begin
  FCrit.Enter;
  try
    Job.Func := Func;
    Job.Opaque := Opaque;
    Job.Index := N;
    FQueue.Enqueue(Job);
    FBusyEvent.ResetEvent;
  finally
    FCrit.Leave;
  end;
  FJobEvent.SetEvent;
end;

procedure TFL2Pool.AddRange(Func: FL2POOL_function; Opaque: Pointer; First, Last: PtrInt);
var
  N: PtrInt;
begin
  for N := First to Last - 1 do
    Add(Func, Opaque, N);
end;

function TFL2Pool.DequeueJob(out Job: TFL2Job): Boolean;
begin
  FCrit.Enter;
  try
    if FQueue.Count > 0 then
    begin
      Job := FQueue.Dequeue;
      Inc(FBusy);
      Result := True;
    end
    else
      Result := False;
  finally
    FCrit.Leave;
  end;
end;

procedure TFL2Pool.FinishedJob;
begin
  FCrit.Enter;
  try
    Dec(FBusy);
    if (FBusy = 0) and (FQueue.Count = 0) then
      FBusyEvent.SetEvent;
  finally
    FCrit.Leave;
  end;
end;

function TFL2Pool.ThreadsBusy: Cardinal;
begin
  FCrit.Enter;
  try
    Result := FBusy;
  finally
    FCrit.Leave;
  end;
end;

function TFL2Pool.WaitAll(Timeout: Cardinal): Boolean;
begin
  Result := FBusyEvent.WaitFor(Timeout) = wrSignaled;
end;

function FL2POOL_create(numThreads: NativeUInt): PFL2POOL_ctx;
begin
  Result := Pointer(TFL2Pool.Create(numThreads));
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx <> nil then
    TFL2Pool(ctx).Free;
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
begin
  if ctx <> nil then
    TFL2Pool(ctx).AddRange(func, opaque, first, last);
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  if ctx <> nil then
    TFL2Pool(ctx).Add(func, opaque, n);
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  if ctx = nil then
    Exit(0);
  if TFL2Pool(ctx).WaitAll(timeout) then
    Result := 0
  else
    Result := 1;
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := TFL2Pool(ctx).ThreadsBusy;
end;

end.
