unit Lzma.Alloc;

interface

uses
  Lzma.Types;

procedure ValidateMemoryLimit(const RequiredBytes, MemoryLimit: UInt64);
function CheckedBufferSize(const Value: NativeUInt): NativeUInt;

implementation

uses
  Lzma.Errors;

procedure ValidateMemoryLimit(const RequiredBytes, MemoryLimit: UInt64);
begin
  if (MemoryLimit <> 0) and (RequiredBytes > MemoryLimit) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA memory limit exceeded');
end;

function CheckedBufferSize(const Value: NativeUInt): NativeUInt;
begin
  Result := Value;
  if Result = 0 then
    Result := 1 shl 20;
  if Result < 4096 then
    Result := 4096;
end;

end.
