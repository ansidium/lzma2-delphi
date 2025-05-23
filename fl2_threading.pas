/*
 * Copyright (c) 2016 Tino Reichardt
 * All rights reserved.
 *
 * This source code is licensed under both the BSD-style license (found in the
 * LICENSE file in the root directory of this source tree) and the GPLv2 (found
 * in the COPYING file in the root directory of this source tree).
 *
 * You can contact the author at:
 *  - zstdmt source repository: https://github.com/mcmilk/zstdmt
 */

unit FL2Threading;

interface

uses
  System.Classes, System.SyncObjs;

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

function FL2_pthread_create(out thread: TFL2_pthread_t; unused: Pointer;
  start_routine: TFL2ThreadProc; arg: Pointer): Integer;
function FL2_pthread_join(thread: TFL2_pthread_t; out value_ptr: Pointer): Integer;

{ Convenience wrappers matching the C API }
function FL2_createThread(out thread: TFL2_pthread_t; start_routine: TFL2ThreadProc;
  arg: Pointer): Integer; inline;
function FL2_joinThread(thread: TFL2_pthread_t; out value_ptr: Pointer): Integer; inline;

procedure FL2_pthread_mutex_init(out mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_mutex_destroy(var mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_mutex_lock(mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_mutex_unlock(mutex: TFL2_pthread_mutex_t);

procedure FL2_pthread_cond_init(out cond: TFL2_pthread_cond_t);
procedure FL2_pthread_cond_destroy(var cond: TFL2_pthread_cond_t);
procedure FL2_pthread_cond_wait(cond: TFL2_pthread_cond_t; mutex: TFL2_pthread_mutex_t);
procedure FL2_pthread_cond_timedwait(cond: TFL2_pthread_cond_t; mutex: TFL2_pthread_mutex_t; timeout_ms: Cardinal);
procedure FL2_pthread_cond_signal(cond: TFL2_pthread_cond_t);
procedure FL2_pthread_cond_broadcast(cond: TFL2_pthread_cond_t);

function FL2_countPhysicalCores: Cardinal;
function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation

{ TFL2_pthread_t }

constructor TFL2_pthread_t.Create(AProc: TFL2ThreadProc; AArg: Pointer);
begin
  FProc := AProc;
  FArg := AArg;
  FreeOnTerminate := False;
  inherited Create(False);
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

function FL2_pthread_create(out thread: TFL2_pthread_t; unused: Pointer;
  start_routine: TFL2ThreadProc; arg: Pointer): Integer;
begin
  thread := TFL2_pthread_t.Create(start_routine, arg);
  Result := 0;
end;

function FL2_pthread_join(thread: TFL2_pthread_t; out value_ptr: Pointer): Integer;
begin
  if thread <> nil then
  begin
    thread.WaitFor;
    value_ptr := thread.ResultValue;
    thread.Free;
  end
  else
    value_ptr := nil;
  Result := 0;
end;

function FL2_createThread(out thread: TFL2_pthread_t; start_routine: TFL2ThreadProc;
  arg: Pointer): Integer;
begin
  Result := FL2_pthread_create(thread, nil, start_routine, arg);
end;

function FL2_joinThread(thread: TFL2_pthread_t; out value_ptr: Pointer): Integer;
begin
  Result := FL2_pthread_join(thread, value_ptr);
end;

procedure FL2_pthread_mutex_init(out mutex: TFL2_pthread_mutex_t);
begin
  mutex := TCriticalSection.Create;
end;

procedure FL2_pthread_mutex_destroy(var mutex: TFL2_pthread_mutex_t);
begin
  mutex.Free;
  mutex := nil;
end;

procedure FL2_pthread_mutex_lock(mutex: TFL2_pthread_mutex_t);
begin
  mutex.Acquire;
end;

procedure FL2_pthread_mutex_unlock(mutex: TFL2_pthread_mutex_t);
begin
  mutex.Release;
end;

procedure FL2_pthread_cond_init(out cond: TFL2_pthread_cond_t);
begin
  cond := TFL2_pthread_cond_t.Create;
end;

procedure FL2_pthread_cond_destroy(var cond: TFL2_pthread_cond_t);
begin
  cond.Free;
  cond := nil;
end;

procedure FL2_pthread_cond_wait(cond: TFL2_pthread_cond_t; mutex: TFL2_pthread_mutex_t);
begin
  cond.Wait(mutex);
end;

procedure FL2_pthread_cond_timedwait(cond: TFL2_pthread_cond_t; mutex: TFL2_pthread_mutex_t; timeout_ms: Cardinal);
begin
  cond.TimedWait(mutex, timeout_ms);
end;

procedure FL2_pthread_cond_signal(cond: TFL2_pthread_cond_t);
begin
  cond.Signal;
end;

procedure FL2_pthread_cond_broadcast(cond: TFL2_pthread_cond_t);
begin
  cond.Broadcast;
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
  if nbThreads = 0 then
    nbThreads := 1;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;

end.
