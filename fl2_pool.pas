unit FL2Pool;

interface

const
  InfiniteTimeout = 4294967295;

uses
  System.Classes, System.SysUtils, System.SyncObjs;

type
  TFL2PoolFunction = procedure(Opaque: Pointer; N: PtrInt);

  TFL2WorkerThread = class(TThread)
  private
    FPool: Pointer; {TFL2Pool}
  protected
    procedure Execute; override;
  public
    constructor Create(APool: Pointer);
  end;

  TFL2Pool = class
  private
    FThreads: array of TFL2WorkerThread;
    FQueueMutex: TCriticalSection;
    FNewJobs: TEvent;
    FBusyEvent: TEvent;
    FFunction: TFL2PoolFunction;
    FOpaque: Pointer;
    FQueueIndex: PtrInt;
    FQueueEnd: PtrInt;
    FNumBusy: Integer;
    FShutdown: Boolean;
    function PopJob(out N: PtrInt): Boolean;
    procedure FinishJob;
  public
    constructor Create(NumThreads: Cardinal);
    destructor Destroy; override;
    procedure AddRange(AFunction: TFL2PoolFunction; AOpaque: Pointer; First, Last: PtrInt);
    procedure Add(AFunction: TFL2PoolFunction; AOpaque: Pointer; N: PtrInt);
    function WaitAll(TimeoutMS: Cardinal): Boolean;
    function ThreadsBusy: Cardinal;
  end;

implementation

{ TFL2WorkerThread }

constructor TFL2WorkerThread.Create(APool: Pointer);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FPool := APool;
end;

procedure TFL2WorkerThread.Execute;
var
  Job: PtrInt;
begin
  while not Terminated do
  begin
    if not TFL2Pool(FPool).PopJob(Job) then
      Break;
    try
      TFL2Pool(FPool).FFunction(TFL2Pool(FPool).FOpaque, Job);
    finally
      TFL2Pool(FPool).FinishJob;
    end;
  end;
end;

{ TFL2Pool }

constructor TFL2Pool.Create(NumThreads: Cardinal);
var
  I: Integer;
begin
  inherited Create;
  if NumThreads = 0 then
    NumThreads := 1;
  SetLength(FThreads, NumThreads);
  FQueueMutex := TCriticalSection.Create;
  FNewJobs := TEvent.Create(nil, False, False, '');
  FBusyEvent := TEvent.Create(nil, False, False, '');
  for I := 0 to High(FThreads) do
    FThreads[I] := TFL2WorkerThread.Create(Self);
end;

destructor TFL2Pool.Destroy;
var
  I: Integer;
begin
  FQueueMutex.Acquire;
  FShutdown := True;
  FNewJobs.SetEvent;
  FQueueMutex.Release;
  for I := 0 to High(FThreads) do
  begin
    FThreads[I].WaitFor;
    FThreads[I].Free;
  end;
  FBusyEvent.Free;
  FNewJobs.Free;
  FQueueMutex.Free;
  inherited Destroy;
end;

function TFL2Pool.PopJob(out N: PtrInt): Boolean;
begin
  Result := False;
  while True do
  begin
    FQueueMutex.Acquire;
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
      FQueueMutex.Release;
    end;
    if not FNewJobs.WaitFor(InfiniteTimeout) then
      Exit;
  end;
end;

procedure TFL2Pool.FinishJob;
begin
  FQueueMutex.Acquire;
  try
    Dec(FNumBusy);
    if FNumBusy = 0 then
      FBusyEvent.SetEvent;
  finally
    FQueueMutex.Release;
  end;
end;

procedure TFL2Pool.AddRange(AFunction: TFL2PoolFunction; AOpaque: Pointer; First, Last: PtrInt);
begin
  FQueueMutex.Acquire;
  try
    FFunction := AFunction;
    FOpaque := AOpaque;
    FQueueIndex := First;
    FQueueEnd := Last;
    FBusyEvent.ResetEvent;
    FNewJobs.SetEvent;
  finally
    FQueueMutex.Release;
  end;
end;

procedure TFL2Pool.Add(AFunction: TFL2PoolFunction; AOpaque: Pointer; N: PtrInt);
begin
  AddRange(AFunction, AOpaque, N, N + 1);
end;

function TFL2Pool.WaitAll(TimeoutMS: Cardinal): Boolean;
begin
  Result := True;
  if TimeoutMS = 0 then
    FBusyEvent.WaitFor(InfiniteTimeout)
  else
    Result := FBusyEvent.WaitFor(TimeoutMS) = wrSignaled;
end;

function TFL2Pool.ThreadsBusy: Cardinal;
begin
  FQueueMutex.Acquire;
  try
    Result := FNumBusy;
  finally
    FQueueMutex.Release;
  end;
end;

end.
