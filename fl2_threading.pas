{*
 * Fast LZMA2 threading helpers translated to Delphi
 * Copyright (c) 2016 Tino Reichardt
 * Licensed under BSD or GPLv2 as found in the project root.
 *}

unit FL2Threading;

interface

uses
  System.Classes, System.SyncObjs, System.SysUtils;

const
  FL2_MAXTHREADS = 200;

type
  TFL2ThreadProc = function(arg: Pointer): Pointer;

  TFL2_pthread_t = class(TThread)
  private
    FProc: TFL2ThreadProc;
    FArg: Pointer;
    FResult: Pointer;
  protected
    procedure Execute; override;
  public
    constructor Create(AProc: TFL2ThreadProc; AArg: Pointer);
    property ResultValue: Pointer read FResult;
  end;

  TFL2_pthread_mutex_t = TCriticalSection;

  TFL2_pthread_cond_t = class
  private
    FEvent: TEvent;
    FLock: TCriticalSection;
    FWaitCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Wait(Mutex: TFL2_pthread_mutex_t);
    procedure TimedWait(Mutex: TFL2_pthread_mutex_t; TimeoutMs: Cardinal);
    procedure Signal;
    procedure Broadcast;
  end;

function FL2_pthread_create(out Thread: TFL2_pthread_t; Unused: Pointer;
  StartRoutine: TFL2ThreadProc; Arg: Pointer): Integer;
function FL2_pthread_join(Thread: TFL2_pthread_t; out ValuePtr: Pointer): Integer;

function FL2_createThread(out Thread: TFL2_pthread_t; StartRoutine: TFL2ThreadProc;
  Arg: Pointer): Integer; inline;
function FL2_joinThread(Thread: TFL2_pthread_t; out ValuePtr: Pointer): Integer; inline;

procedure FL2_pthread_mutex_init(out Mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_mutex_destroy(var Mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_mutex_lock(Mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_mutex_unlock(Mutex: TFL2_pthread_mutex_t);

procedure FL2_pthread_cond_init(out Cond: TFL2_pthread_cond_t);
procedure FL2_pthread_cond_destroy(var Cond: TFL2_pthread_cond_t);
procedure FL2_pthread_cond_wait(Cond: TFL2_pthread_cond_t; Mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_cond_timedwait(Cond: TFL2_pthread_cond_t; Mutex: TFL2_pthread_mutex_t; TimeoutMs: Cardinal);
procedure FL2_pthread_cond_signal(Cond: TFL2_pthread_cond_t);
procedure FL2_pthread_cond_broadcast(Cond: TFL2_pthread_cond_t);

function FL2_countPhysicalCores: Cardinal;
function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation

{ TFL2_pthread_t }

constructor TFL2_pthread_t.Create(AProc: TFL2ThreadProc; AArg: Pointer);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FProc := AProc;
  FArg := AArg;
end;

procedure TFL2_pthread_t.Execute;
begin
  if Assigned(FProc) then
    FResult := FProc(FArg)
  else
    FResult := nil;
end;

{ TFL2_pthread_cond_t }

constructor TFL2_pthread_cond_t.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, False, False, '');
  FLock := TCriticalSection.Create;
  FWaitCount := 0;
end;

destructor TFL2_pthread_cond_t.Destroy;
begin
  FEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFL2_pthread_cond_t.Wait(Mutex: TFL2_pthread_mutex_t);
begin
  FLock.Acquire;
  Inc(FWaitCount);
  FLock.Release;
  Mutex.Release;
  FEvent.WaitFor(INFINITE);
  Mutex.Acquire;
  FLock.Acquire;
  Dec(FWaitCount);
  FLock.Release;
end;

procedure TFL2_pthread_cond_t.TimedWait(Mutex: TFL2_pthread_mutex_t; TimeoutMs: Cardinal);
begin
  FLock.Acquire;
  Inc(FWaitCount);
  FLock.Release;
  Mutex.Release;
  FEvent.WaitFor(TimeoutMs);
  Mutex.Acquire;
  FLock.Acquire;
  Dec(FWaitCount);
  FLock.Release;
end;

procedure TFL2_pthread_cond_t.Signal;
begin
  FEvent.SetEvent;
end;

procedure TFL2_pthread_cond_t.Broadcast;
var
  Count, I: Integer;
begin
  FLock.Acquire;
  Count := FWaitCount;
  FLock.Release;
  for I := 1 to Count do
    FEvent.SetEvent;
end;

{ pthread wrappers }

function FL2_pthread_create(out Thread: TFL2_pthread_t; Unused: Pointer;
  StartRoutine: TFL2ThreadProc; Arg: Pointer): Integer;
begin
  Thread := TFL2_pthread_t.Create(StartRoutine, Arg);
  Result := 0;
end;

function FL2_pthread_join(Thread: TFL2_pthread_t; out ValuePtr: Pointer): Integer;
begin
  if Thread <> nil then
  begin
    Thread.WaitFor;
    ValuePtr := Thread.ResultValue;
    Thread.Free;
  end
  else
    ValuePtr := nil;
  Result := 0;
end;

function FL2_createThread(out Thread: TFL2_pthread_t; StartRoutine: TFL2ThreadProc;
  Arg: Pointer): Integer;
begin
  Result := FL2_pthread_create(Thread, nil, StartRoutine, Arg);
end;

function FL2_joinThread(Thread: TFL2_pthread_t; out ValuePtr: Pointer): Integer;
begin
  Result := FL2_pthread_join(Thread, ValuePtr);
end;

procedure FL2_pthread_mutex_init(out Mutex: TFL2_pthread_mutex_t);
begin
  Mutex := TCriticalSection.Create;
end;

procedure FL2_pthread_mutex_destroy(var Mutex: TFL2_pthread_mutex_t);
begin
  Mutex.Free;
  Mutex := nil;
end;

procedure FL2_pthread_mutex_lock(Mutex: TFL2_pthread_mutex_t);
begin
  Mutex.Acquire;
end;

procedure FL2_pthread_mutex_unlock(Mutex: TFL2_pthread_mutex_t);
begin
  Mutex.Release;
end;

procedure FL2_pthread_cond_init(out Cond: TFL2_pthread_cond_t);
begin
  Cond := TFL2_pthread_cond_t.Create;
end;

procedure FL2_pthread_cond_destroy(var Cond: TFL2_pthread_cond_t);
begin
  Cond.Free;
  Cond := nil;
end;

procedure FL2_pthread_cond_wait(Cond: TFL2_pthread_cond_t; Mutex: TFL2_pthread_mutex_t);
begin
  Cond.Wait(Mutex);
end;

procedure FL2_pthread_cond_timedwait(Cond: TFL2_pthread_cond_t; Mutex: TFL2_pthread_mutex_t; TimeoutMs: Cardinal);
begin
  Cond.TimedWait(Mutex, TimeoutMs);
end;

procedure FL2_pthread_cond_signal(Cond: TFL2_pthread_cond_t);
begin
  Cond.Signal;
end;

procedure FL2_pthread_cond_broadcast(Cond: TFL2_pthread_cond_t);
begin
  Cond.Broadcast;
end;

function FL2_countPhysicalCores: Cardinal;
begin
  Result := TThread.ProcessorCount;
  if Result = 0 then
    Result := 1;
end;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  if nbThreads = 0 then
    nbThreads := FL2_countPhysicalCores;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;

end.
