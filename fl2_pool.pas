unit FL2Pool;

interface

uses
  System.Classes, System.SyncObjs;

type
  TFL2PoolFunction = procedure(opaque: Pointer; n: PtrInt);

  TFL2Pool = class
  private
    FThreads: array of TThread;
    FFunction: TFL2PoolFunction;
    FOpaque: Pointer;
    FQueueIndex: PtrInt;
    FQueueEnd: PtrInt;
    FBusyCount: Integer;
    FQueueLock: TCriticalSection;
    FNewJobs: TEvent;
    FBusyCond: TEvent;
    FShutdown: Boolean;
  protected
    procedure WorkerExecute(thread: TThread);
  public
    constructor Create(numThreads: Integer);
    destructor Destroy; override;
    procedure AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
    procedure Add(func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
    function WaitAll(timeout: Cardinal): Boolean;
    function ThreadsBusy: Integer;
  end;

implementation

{ TFL2Pool }

constructor TFL2Pool.Create(numThreads: Integer);
var
  i: Integer;
begin
  inherited Create;
  FQueueLock := TCriticalSection.Create;
  FNewJobs := TEvent.Create(nil, True, False, '');
  FBusyCond := TEvent.Create(nil, True, False, '');
  SetLength(FThreads, numThreads);
  for i := 0 to numThreads - 1 do
  begin
    FThreads[i] := TThread.CreateAnonymousThread(
      procedure
      begin
        WorkerExecute(TThread.Current);
      end);
    FThreads[i].FreeOnTerminate := False;
    FThreads[i].Start;
  end;
end;

destructor TFL2Pool.Destroy;
var
  i: Integer;
begin
  FQueueLock.Acquire;
  FShutdown := True;
  FNewJobs.SetEvent;
  FQueueLock.Release;
  for i := 0 to High(FThreads) do
  begin
    FThreads[i].WaitFor;
    FThreads[i].Free;
  end;
  FNewJobs.Free;
  FBusyCond.Free;
  FQueueLock.Free;
  inherited;
end;

procedure TFL2Pool.WorkerExecute(thread: TThread);
var
  n: PtrInt;
begin
  while True do
  begin
    FQueueLock.Acquire;
    try
      while (FQueueIndex >= FQueueEnd) and not FShutdown do
      begin
        FQueueLock.Release;
        FNewJobs.WaitFor(INFINITE);
        FNewJobs.ResetEvent;
        FQueueLock.Acquire;
      end;
      if FShutdown then
        Exit;
      n := FQueueIndex;
      Inc(FQueueIndex);
      Inc(FBusyCount);
    finally
      FQueueLock.Release;
    end;
    if Assigned(FFunction) then
      FFunction(FOpaque, n);
    FQueueLock.Acquire;
    try
      Dec(FBusyCount);
      FBusyCond.SetEvent;
    finally
      FQueueLock.Release;
    end;
  end;
end;

procedure TFL2Pool.AddRange(func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
begin
  FQueueLock.Acquire;
  try
    FFunction := func;
    FOpaque := opaque;
    FQueueIndex := first;
    FQueueEnd := last;
    FNewJobs.SetEvent;
  finally
    FQueueLock.Release;
  end;
end;

procedure TFL2Pool.Add(func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
begin
  AddRange(func, opaque, n, n + 1);
end;

function TFL2Pool.WaitAll(timeout: Cardinal): Boolean;
begin
  if timeout <> 0 then
    Result := FBusyCond.WaitFor(timeout) = wrSignaled
  else
  begin
    while FBusyCount > 0 do
      FBusyCond.WaitFor(INFINITE);
    Result := True;
  end;
  FBusyCond.ResetEvent;
end;

function TFL2Pool.ThreadsBusy: Integer;
begin
  Result := FBusyCount;
end;

end.
