unit FL2Pool;

interface

uses
  FL2Threading;

type
  FL2POOL_function = procedure(opaque: Pointer; n: PtrInt);

  PFL2POOL_ctx = ^TFL2POOL_ctx;
  TFL2POOL_ctx = record
    numThreads: Cardinal;
  end;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;

implementation

uses
  System.SysUtils;

function FL2POOL_create(numThreads: Cardinal): PFL2POOL_ctx;
begin
  New(Result);
  Result^.numThreads := FL2_checkNbThreads(numThreads);
end;

procedure FL2POOL_free(ctx: PFL2POOL_ctx);
begin
  if ctx <> nil then
    Dispose(ctx);
end;

function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
begin
  if ctx = nil then
    Result := 0
  else
    Result := SizeOf(ctx^);
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; first, last: PtrInt);
var
  i: PtrInt;
begin
  if ctx = nil then Exit;
  for i := first to last - 1 do
    func(opaque, i);
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: FL2POOL_function; opaque: Pointer; n: PtrInt);
begin
  FL2POOL_addRange(ctx, func, opaque, n, n + 1);
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  Result := 0; // synchronous stub
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;
begin
  Result := 0;
end;

end.
