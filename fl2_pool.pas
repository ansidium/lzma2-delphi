unit FL2Pool;

interface

uses
  System.SysUtils;

type
  FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);

  PFL2POOL_ctx = ^TFL2POOL_ctx;
  TFL2POOL_ctx = record
    numThreads: SizeUInt;
  end;

function FL2POOL_create(numThreads: SizeUInt): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
function FL2POOL_sizeof(ctx: PFL2POOL_ctx): SizeUInt;
procedure FL2POOL_addRange(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
procedure FL2POOL_add(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: Pointer): SizeUInt;

implementation

function FL2POOL_create(numThreads: SizeUInt): PFL2POOL_ctx;
begin
  New(Result);
  Result^.numThreads := numThreads;
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx <> nil then
    Dispose(ctx);
end;

function FL2POOL_sizeof(ctx: PFL2POOL_ctx): SizeUInt;
begin
  if ctx = nil then
    Exit(0);
  Result := SizeOf(TFL2POOL_ctx);
end;

procedure FL2POOL_addRange(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
var
  i: PtrInt;
begin
  for i := first to last - 1 do
    func(opaque, i);
end;

procedure FL2POOL_add(ctx: Pointer; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  FL2POOL_addRange(ctx, func, opaque, n, n + 1);
end;

function FL2POOL_waitAll(ctx: Pointer; timeout: Cardinal): Integer;
begin
  Result := 0;
end;

function FL2POOL_threadsBusy(ctx: Pointer): SizeUInt;
begin
  Result := 0;
end;

end.
