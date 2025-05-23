unit FL2Helpers;

interface

uses
  System.SysUtils, System.Classes, FL2API;

function FL2CompressBytes(const Input: TBytes; Level: Integer; Threads: Cardinal = 0): TBytes;
function FL2DecompressBytes(const Input: TBytes; Threads: Cardinal = 0): TBytes; overload;
function FL2DecompressBytes(const Input: TBytes; DecompressedSize: NativeUInt; Threads: Cardinal = 0): TBytes; overload;
function FL2CompressString(const S: string; Level: Integer; Threads: Cardinal = 0; Encoding: TEncoding = nil): TBytes;
function FL2DecompressString(const Input: TBytes; Threads: Cardinal = 0; Encoding: TEncoding = nil): string;

implementation

function FL2CompressBytes(const Input: TBytes; Level: Integer; Threads: Cardinal): TBytes;
var
  OutSize: NativeUInt;
  Bound: NativeUInt;
begin
  Bound := FL2_compressBound(Length(Input));
  SetLength(Result, Bound);
  if Length(Input) > 0 then
    OutSize := CompressBuffer(Input[0], Length(Input), Result[0], Bound, Level, Threads)
  else
    OutSize := CompressBuffer(Input, 0, Result[0], Bound, Level, Threads);
  if FL2_isError(OutSize) then
    raise Exception.Create(string(FL2_getErrorName(OutSize)));
  SetLength(Result, OutSize);
end;

function FL2DecompressBytes(const Input: TBytes; DecompressedSize: NativeUInt; Threads: Cardinal): TBytes;
var
  DecSize: NativeUInt;
begin
  SetLength(Result, DecompressedSize);
  if Length(Input) > 0 then
    DecSize := DecompressBuffer(Input[0], Length(Input), Result[0], DecompressedSize, Threads)
  else
    DecSize := DecompressBuffer(Input, 0, Result[0], DecompressedSize, Threads);
  if FL2_isError(DecSize) then
    raise Exception.Create(string(FL2_getErrorName(DecSize)));
  SetLength(Result, DecSize);
end;

function FL2DecompressBytes(const Input: TBytes; Threads: Cardinal): TBytes;
var
  Size64: UInt64;
begin
  if Length(Input) = 0 then
    Exit(nil);
  Size64 := FL2_findDecompressedSize(@Input[0], Length(Input));
  if Size64 = UInt64(-1) then
    raise Exception.Create('Unknown decompressed size');
  Result := FL2DecompressBytes(Input, Size64, Threads);
end;

function FL2CompressString(const S: string; Level: Integer; Threads: Cardinal; Encoding: TEncoding): TBytes;
var
  Bytes: TBytes;
begin
  if Encoding = nil then
    Encoding := TEncoding.UTF8;
  Bytes := Encoding.GetBytes(S);
  Result := FL2CompressBytes(Bytes, Level, Threads);
end;

function FL2DecompressString(const Input: TBytes; Threads: Cardinal; Encoding: TEncoding): string;
var
  Bytes: TBytes;
begin
  if Encoding = nil then
    Encoding := TEncoding.UTF8;
  Bytes := FL2DecompressBytes(Input, Threads);
  Result := Encoding.GetString(Bytes);
end;

end.

