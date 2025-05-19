unit FL2Pool;

interface

type
  FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);
  PFL2POOL_ctx = ^FL2POOL_ctx;
  FL2POOL_ctx = record
    numThreads: Cardinal;
  end;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
procedure FL2POOL_add(ctx: Pointer; fn: FL2POOL_function; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: Pointer; fn: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: Pointer): NativeUInt;

implementation

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
begin
  New(Result);
  Result^.numThreads := numThreads;
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx <> nil then
    Dispose(ctx);
end;

function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := SizeOf(ctx^);
end;

procedure FL2POOL_add(ctx: Pointer; fn: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  if Assigned(fn) then
    fn(opaque, n);
end;

procedure FL2POOL_addRange(ctx: Pointer; fn: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
var
  i: PtrInt;
begin
  if Assigned(fn) then
    for i := first to last - 1 do
      fn(opaque, i);
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
