unit Lzma.Alloc;

interface

uses
  Lzma.Types;

procedure ValidateMemoryLimit(const RequiredBytes, MemoryLimit: UInt64);
function CheckedBufferSize(const Value: NativeUInt): NativeUInt;

function CheckedMemoryAdd(const Left, Right: UInt64): UInt64;
function CheckedMemoryMultiply(const Left, Right: UInt64): UInt64;

function FitsMtDecodeMemoryLimit(const InputSize, OutputSize, PerWorkerSize: UInt64;
  const WorkerCount: Integer; const MemoryLimit: UInt64): Boolean;

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

function CheckedMemoryAdd(const Left, Right: UInt64): UInt64;
begin
  if Left > High(UInt64) - Right then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA memory size overflow');
  Result := Left + Right;
end;

function CheckedMemoryMultiply(const Left, Right: UInt64): UInt64;
begin
  if Right = 0 then
    Exit(0);
  if Left > High(UInt64) div Right then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA memory size overflow');
  Result := Left * Right;
end;

function TryAddMemoryUse(var Total: UInt64; const Value: UInt64; const Limit: UInt64): Boolean;
begin
  if Limit = 0 then
  begin
    if Value > High(UInt64) - Total then
      Exit(False);
    Inc(Total, Value);
    Exit(True);
  end;
  if (Total > Limit) or (Value > Limit - Total) then
    Exit(False);
  Inc(Total, Value);
  Result := True;
end;

function FitsMtDecodeMemoryLimit(const InputSize, OutputSize, PerWorkerSize: UInt64;
  const WorkerCount: Integer; const MemoryLimit: UInt64): Boolean;
var
  Total: UInt64;
  WorkerMemory: UInt64;
begin
  if OutputSize > UInt64(High(Integer)) then
    Exit(False);
  if MemoryLimit = 0 then
    Exit(True);
  if (WorkerCount > 0) and (PerWorkerSize > High(UInt64) div UInt64(WorkerCount)) then
    Exit(False);
  WorkerMemory := UInt64(WorkerCount) * PerWorkerSize;
  Total := 0;
  Result :=
    TryAddMemoryUse(Total, InputSize, MemoryLimit) and
    TryAddMemoryUse(Total, OutputSize, MemoryLimit) and
    TryAddMemoryUse(Total, WorkerMemory, MemoryLimit);
end;

end.
