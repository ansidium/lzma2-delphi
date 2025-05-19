unit FL2Pool;

interface

uses
  FL2Threading;

type
  TFL2PoolJob = procedure(opaque: Pointer; n: PtrInt);

function FL2POOL_create(numThreads: Cardinal): Pointer;
procedure FL2POOL_free(ctx: Pointer);
function FL2POOL_sizeof(ctx: Pointer): NativeUInt;
procedure FL2POOL_add(ctx: Pointer; fn: TFL2PoolJob; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: Pointer; fn: TFL2PoolJob; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: Pointer): NativeUInt;

implementation

uses
  Classes;

type
  PFL2PoolCtx = ^TFL2PoolCtx;
  TFL2PoolCtx = record
    numThreads: Cardinal;
  end;

function FL2POOL_create(numThreads: Cardinal): Pointer;
var
  ctx: PFL2PoolCtx;
begin
  numThreads := FL2_checkNbThreads(numThreads);
  New(ctx);
  ctx^.numThreads := numThreads;
  Result := ctx;
end;

procedure FL2POOL_free(ctx: Pointer);
begin
  if ctx = nil then Exit;
  Dispose(PFL2PoolCtx(ctx));
end;

function FL2POOL_sizeof(ctx: Pointer): NativeUInt;
begin
  if ctx = nil then Exit(0);
  Result := SizeOf(TFL2PoolCtx);
end;

procedure FL2POOL_add(ctx: Pointer; fn: TFL2PoolJob; opaque: Pointer; n: PtrInt);
begin
  if Assigned(fn) then
    fn(opaque, n);
end;

procedure FL2POOL_addRange(ctx: Pointer; fn: TFL2PoolJob; opaque: Pointer; first, last: PtrInt);
var
  i: PtrInt;
begin
  for i := first to last - 1 do
    FL2POOL_add(ctx, fn, opaque, i);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
begin
  Result := 0;
end;

function FL2POOL_threadsBusy(ctx: Pointer): NativeUInt;
begin
  Result := 0;
end;

end.
