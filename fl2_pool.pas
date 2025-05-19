unit FL2Pool;

interface

uses
  System.Classes;

type
  TFL2PoolFunction = procedure(opaque: Pointer; n: PtrInt);
  PFL2PoolFunction = TFL2PoolFunction;

  PFL2POOL_ctx = ^TFL2POOL_ctx;
  TFL2POOL_ctx = record
    numThreads: Integer;
  end;

function FL2POOL_create(numThreads: NativeUInt): PFL2POOL_ctx;
procedure FL2POOL_free(ctx: PFL2POOL_ctx);
function FL2POOL_sizeof(ctx: PFL2POOL_ctx): NativeUInt;
procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;

implementation

function FL2POOL_create(numThreads: NativeUInt): PFL2POOL_ctx;
begin
  if numThreads = 0 then
    Exit(nil);
  New(Result);
  Result^.numThreads := Integer(numThreads);
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
    Result := SizeOf(TFL2POOL_ctx);
end;

procedure FL2POOL_add(ctx: PFL2POOL_ctx; func: TFL2PoolFunction; opaque: Pointer; n: PtrInt);
begin
  if Assigned(func) then
    func(opaque, n);
end;

procedure FL2POOL_addRange(ctx: PFL2POOL_ctx; func: TFL2PoolFunction; opaque: Pointer; first, last: PtrInt);
var
  i: PtrInt;
begin
  if Assigned(func) then
    for i := first to last - 1 do
      func(opaque, i);
end;

function FL2POOL_waitAll(ctx: PFL2POOL_ctx; timeout: Cardinal): Integer;
begin
  Result := 0;
end;

function FL2POOL_threadsBusy(ctx: PFL2POOL_ctx): NativeUInt;
begin
  Result := 0;
end;

end.
