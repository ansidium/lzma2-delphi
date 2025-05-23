{*
 * Fast LZMA2 thread pool translated to Delphi
 * Copyright (c) 2016-present, Yann Collet
 * Modified for FL2 by Conor McCarthy
 * Licensed under BSD or GPLv2 as found in the project root.
 *}

unit FL2Pool;

interface

uses
  System.SysUtils, FL2Threading;

type
  TFL2PoolFunction = procedure(opaque: Pointer; n: NativeInt);

  TFL2PoolCtx = record
    numThreads    : Cardinal;
    jobFunction   : TFL2PoolFunction;
    opaque        : Pointer;
    numThreadsBusy: Cardinal;
    queueIndex    : NativeInt;
    queueEnd      : NativeInt;
    queueMutex    : TFL2_pthread_mutex_t;
    busyCond      : TFL2_pthread_cond_t;
    newJobsCond   : TFL2_pthread_cond_t;
    shutdown      : Integer;
    threads       : array of TFL2_pthread_t;
  end;
  PFL2PoolCtx = ^TFL2PoolCtx;

function FL2POOL_create(numThreads: Cardinal): PFL2PoolCtx;
procedure FL2POOL_free(ctx: PFL2PoolCtx);
function FL2POOL_sizeof(ctx: PFL2PoolCtx): NativeUInt;
procedure FL2POOL_add(ctx: PFL2PoolCtx; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
procedure FL2POOL_addRange(ctx: PFL2PoolCtx; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
function FL2POOL_waitAll(ctx: PFL2PoolCtx; timeout: Cardinal): Boolean;
function FL2POOL_threadsBusy(ctx: PFL2PoolCtx): Cardinal;

implementation

function FL2POOL_thread(arg: Pointer): Pointer;
var
  ctx: PFL2PoolCtx;
  n: NativeInt;
begin
  ctx := PFL2PoolCtx(arg);
  if ctx = nil then
    Exit(nil);
  FL2_pthread_mutex_lock(ctx^.queueMutex);
  while True do
  begin
    while (ctx^.queueIndex >= ctx^.queueEnd) and (ctx^.shutdown = 0) do
      FL2_pthread_cond_wait(ctx^.newJobsCond, ctx^.queueMutex);
    if ctx^.shutdown <> 0 then
    begin
      FL2_pthread_mutex_unlock(ctx^.queueMutex);
      Exit(arg);
    end;
    n := ctx^.queueIndex;
    Inc(ctx^.queueIndex);
    Inc(ctx^.numThreadsBusy);
    FL2_pthread_mutex_unlock(ctx^.queueMutex);

    if Assigned(ctx^.jobFunction) then
      ctx^.jobFunction(ctx^.opaque, n);

    FL2_pthread_mutex_lock(ctx^.queueMutex);
    Dec(ctx^.numThreadsBusy);
    FL2_pthread_cond_signal(ctx^.busyCond);
  end;
end;

function FL2POOL_create(numThreads: Cardinal): PFL2PoolCtx;
var
  i: Cardinal;
begin
  numThreads := FL2_checkNbThreads(numThreads);
  if numThreads = 0 then
    Exit(nil);
  New(Result);
  FillChar(Result^, SizeOf(TFL2PoolCtx), 0);
  SetLength(Result^.threads, numThreads);
  FL2_pthread_mutex_init(Result^.queueMutex);
  FL2_pthread_cond_init(Result^.busyCond);
  FL2_pthread_cond_init(Result^.newJobsCond);
  Result^.shutdown := 0;
  Result^.numThreads := 0;
  for i := 0 to numThreads - 1 do
    if FL2_pthread_create(Result^.threads[i], nil, @FL2POOL_thread, Result) <> 0 then
    begin
      Result^.numThreads := i;
      FL2POOL_free(Result);
      Exit(nil);
    end;
  Result^.numThreads := numThreads;
end;

procedure FL2POOL_join(ctx: PFL2PoolCtx);
var
  i: Cardinal;
  Dummy: Pointer;
begin
  FL2_pthread_mutex_lock(ctx^.queueMutex);
  ctx^.shutdown := 1;
  FL2_pthread_cond_broadcast(ctx^.newJobsCond);
  FL2_pthread_mutex_unlock(ctx^.queueMutex);
  for i := 0 to ctx^.numThreads - 1 do
    FL2_pthread_join(ctx^.threads[i], Dummy);
end;

procedure FL2POOL_free(ctx: PFL2PoolCtx);
begin
  if ctx = nil then
    Exit;
  FL2POOL_join(ctx);
  FL2_pthread_mutex_destroy(ctx^.queueMutex);
  FL2_pthread_cond_destroy(ctx^.busyCond);
  FL2_pthread_cond_destroy(ctx^.newJobsCond);
  SetLength(ctx^.threads, 0);
  Dispose(ctx);
end;

function FL2POOL_sizeof(ctx: PFL2PoolCtx): NativeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := SizeOf(TFL2PoolCtx) + ctx^.numThreads * SizeOf(Pointer);
end;

procedure FL2POOL_add(ctx: PFL2PoolCtx; func: TFL2PoolFunction; opaque: Pointer; n: NativeInt);
begin
  FL2POOL_addRange(ctx, func, opaque, n, n + 1);
end;

procedure FL2POOL_addRange(ctx: PFL2PoolCtx; func: TFL2PoolFunction; opaque: Pointer; first, last: NativeInt);
begin
  if ctx = nil then
    Exit;
  Assert(ctx^.numThreadsBusy = 0);
  FL2_pthread_mutex_lock(ctx^.queueMutex);
  ctx^.jobFunction := func;
  ctx^.opaque := opaque;
  ctx^.queueIndex := first;
  ctx^.queueEnd := last;
  FL2_pthread_cond_broadcast(ctx^.newJobsCond);
  FL2_pthread_mutex_unlock(ctx^.queueMutex);
end;

function FL2POOL_waitAll(ctx: PFL2PoolCtx; timeout: Cardinal): Boolean;
begin
  if (ctx = nil) or ((ctx^.numThreadsBusy = 0) and (ctx^.queueIndex >= ctx^.queueEnd)) or
     (ctx^.shutdown <> 0) then
    Exit(False);
  FL2_pthread_mutex_lock(ctx^.queueMutex);
  if timeout <> 0 then
  begin
    if ((ctx^.numThreadsBusy <> 0) or (ctx^.queueIndex < ctx^.queueEnd)) and (ctx^.shutdown = 0) then
      FL2_pthread_cond_timedwait(ctx^.busyCond, ctx^.queueMutex, timeout);
  end
  else
  begin
    while ((ctx^.numThreadsBusy <> 0) or (ctx^.queueIndex < ctx^.queueEnd)) and (ctx^.shutdown = 0) do
      FL2_pthread_cond_wait(ctx^.busyCond, ctx^.queueMutex);
  end;
  FL2_pthread_mutex_unlock(ctx^.queueMutex);
  Result := (ctx^.numThreadsBusy <> 0) and (ctx^.shutdown = 0);
end;

function FL2POOL_threadsBusy(ctx: PFL2PoolCtx): Cardinal;
begin
  if ctx = nil then
    Exit(0);
  Result := ctx^.numThreadsBusy;
end;

end.
