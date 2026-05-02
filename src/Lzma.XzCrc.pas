unit Lzma.XzCrc;

interface

uses
  System.SysUtils;

const
  CRC_INIT_VAL = UInt32($FFFFFFFF);
  CRC64_INIT_VAL = UInt64($FFFFFFFFFFFFFFFF);

function Crc32Update(const Crc: UInt32; const Data: Pointer; const Size: NativeUInt): UInt32;
function Crc32Calc(const Data: Pointer; const Size: NativeUInt): UInt32; overload;
function Crc32Calc(const Data: TBytes): UInt32; overload;
function Crc64Update(const Crc: UInt64; const Data: Pointer; const Size: NativeUInt): UInt64;
function Crc64Calc(const Data: Pointer; const Size: NativeUInt): UInt64; overload;
function Crc64Calc(const Data: TBytes): UInt64; overload;
function Sha256Calc(const Data: TBytes): TBytes;
function CheckDigest(const CheckId: Byte; const Data: TBytes): TBytes;

implementation

uses
  System.Hash,
  Lzma.Types,
  Lzma.Errors;

var
  Gcrc32Table: array[0..15, Byte] of UInt32;
  Gcrc64Table: array[0..15, Byte] of UInt64;

procedure GenerateTables;
var
  I, J: Integer;
  R32: UInt32;
  R64: UInt64;
begin
  for I := 0 to 255 do
  begin
    R32 := UInt32(I);
    for J := 0 to 7 do
      if (R32 and 1) <> 0 then
        R32 := (R32 shr 1) xor UInt32($EDB88320)
      else
        R32 := R32 shr 1;
    Gcrc32Table[0, I] := R32;

    R64 := UInt64(I);
    for J := 0 to 7 do
      if (R64 and 1) <> 0 then
        R64 := (R64 shr 1) xor UInt64($C96C5795D7870F42)
      else
        R64 := R64 shr 1;
    Gcrc64Table[0, I] := R64;
  end;

  for J := 1 to High(Gcrc32Table) do
  begin
    for I := 0 to 255 do
    begin
      R32 := Gcrc32Table[J - 1, I];
      Gcrc32Table[J, I] := Gcrc32Table[0, Byte(R32)] xor (R32 shr 8);

      R64 := Gcrc64Table[J - 1, I];
      Gcrc64Table[J, I] := Gcrc64Table[0, Byte(R64)] xor (R64 shr 8);
    end;
  end;
end;

function Crc32Update(const Crc: UInt32; const Data: Pointer; const Size: NativeUInt): UInt32;
var
  Remaining: NativeUInt;
  P: PByte;
  V0: UInt64;
  V1: UInt64;
begin
  Result := Crc;
  if Size = 0 then
    Exit;
  P := Data;
  Remaining := Size;

  while (Remaining > 0) and ((NativeUInt(P) and 7) <> 0) do
  begin
    Result := Gcrc32Table[0, Byte(Result xor P^)] xor (Result shr 8);
    Inc(P);
    Dec(Remaining);
  end;

  while Remaining >= SizeOf(UInt64) * 2 do
  begin
    V0 := UInt64(Result) xor PUInt64(P)^;
    Inc(P, SizeOf(UInt64));
    V1 := PUInt64(P)^;
    Inc(P, SizeOf(UInt64));
    Result :=
      Gcrc32Table[15, Byte(V0)] xor
      Gcrc32Table[14, Byte(V0 shr 8)] xor
      Gcrc32Table[13, Byte(V0 shr 16)] xor
      Gcrc32Table[12, Byte(V0 shr 24)] xor
      Gcrc32Table[11, Byte(V0 shr 32)] xor
      Gcrc32Table[10, Byte(V0 shr 40)] xor
      Gcrc32Table[9, Byte(V0 shr 48)] xor
      Gcrc32Table[8, Byte(V0 shr 56)] xor
      Gcrc32Table[7, Byte(V1)] xor
      Gcrc32Table[6, Byte(V1 shr 8)] xor
      Gcrc32Table[5, Byte(V1 shr 16)] xor
      Gcrc32Table[4, Byte(V1 shr 24)] xor
      Gcrc32Table[3, Byte(V1 shr 32)] xor
      Gcrc32Table[2, Byte(V1 shr 40)] xor
      Gcrc32Table[1, Byte(V1 shr 48)] xor
      Gcrc32Table[0, Byte(V1 shr 56)];
    Dec(Remaining, SizeOf(UInt64) * 2);
  end;

  while Remaining >= SizeOf(UInt64) do
  begin
    V0 := UInt64(Result) xor PUInt64(P)^;
    Result :=
      Gcrc32Table[7, Byte(V0)] xor
      Gcrc32Table[6, Byte(V0 shr 8)] xor
      Gcrc32Table[5, Byte(V0 shr 16)] xor
      Gcrc32Table[4, Byte(V0 shr 24)] xor
      Gcrc32Table[3, Byte(V0 shr 32)] xor
      Gcrc32Table[2, Byte(V0 shr 40)] xor
      Gcrc32Table[1, Byte(V0 shr 48)] xor
      Gcrc32Table[0, Byte(V0 shr 56)];
    Inc(P, SizeOf(UInt64));
    Dec(Remaining, SizeOf(UInt64));
  end;

  while Remaining > 0 do
  begin
    Result := Gcrc32Table[0, Byte(Result xor P^)] xor (Result shr 8);
    Inc(P);
    Dec(Remaining);
  end;
end;

function Crc32Calc(const Data: Pointer; const Size: NativeUInt): UInt32;
begin
  Result := Crc32Update(CRC_INIT_VAL, Data, Size) xor CRC_INIT_VAL;
end;

function Crc32Calc(const Data: TBytes): UInt32;
begin
  if Length(Data) = 0 then
    Result := Crc32Calc(nil, 0)
  else
    Result := Crc32Calc(@Data[0], Length(Data));
end;

function Crc64Update(const Crc: UInt64; const Data: Pointer; const Size: NativeUInt): UInt64;
var
  Remaining: NativeUInt;
  P: PByte;
  V0: UInt64;
  V1: UInt64;
begin
  Result := Crc;
  if Size = 0 then
    Exit;
  P := Data;
  Remaining := Size;

  while (Remaining > 0) and ((NativeUInt(P) and 7) <> 0) do
  begin
    Result := Gcrc64Table[0, Byte(Result xor P^)] xor (Result shr 8);
    Inc(P);
    Dec(Remaining);
  end;

  while Remaining >= SizeOf(UInt64) * 2 do
  begin
    V0 := Result xor PUInt64(P)^;
    Inc(P, SizeOf(UInt64));
    V1 := PUInt64(P)^;
    Inc(P, SizeOf(UInt64));
    Result :=
      Gcrc64Table[15, Byte(V0)] xor
      Gcrc64Table[14, Byte(V0 shr 8)] xor
      Gcrc64Table[13, Byte(V0 shr 16)] xor
      Gcrc64Table[12, Byte(V0 shr 24)] xor
      Gcrc64Table[11, Byte(V0 shr 32)] xor
      Gcrc64Table[10, Byte(V0 shr 40)] xor
      Gcrc64Table[9, Byte(V0 shr 48)] xor
      Gcrc64Table[8, Byte(V0 shr 56)] xor
      Gcrc64Table[7, Byte(V1)] xor
      Gcrc64Table[6, Byte(V1 shr 8)] xor
      Gcrc64Table[5, Byte(V1 shr 16)] xor
      Gcrc64Table[4, Byte(V1 shr 24)] xor
      Gcrc64Table[3, Byte(V1 shr 32)] xor
      Gcrc64Table[2, Byte(V1 shr 40)] xor
      Gcrc64Table[1, Byte(V1 shr 48)] xor
      Gcrc64Table[0, Byte(V1 shr 56)];
    Dec(Remaining, SizeOf(UInt64) * 2);
  end;

  while Remaining >= SizeOf(UInt64) do
  begin
    V0 := Result xor PUInt64(P)^;
    Result :=
      Gcrc64Table[7, Byte(V0)] xor
      Gcrc64Table[6, Byte(V0 shr 8)] xor
      Gcrc64Table[5, Byte(V0 shr 16)] xor
      Gcrc64Table[4, Byte(V0 shr 24)] xor
      Gcrc64Table[3, Byte(V0 shr 32)] xor
      Gcrc64Table[2, Byte(V0 shr 40)] xor
      Gcrc64Table[1, Byte(V0 shr 48)] xor
      Gcrc64Table[0, Byte(V0 shr 56)];
    Inc(P, SizeOf(UInt64));
    Dec(Remaining, SizeOf(UInt64));
  end;

  while Remaining > 0 do
  begin
    Result := Gcrc64Table[0, Byte(Result xor P^)] xor (Result shr 8);
    Inc(P);
    Dec(Remaining);
  end;
end;

function Crc64Calc(const Data: Pointer; const Size: NativeUInt): UInt64;
begin
  Result := Crc64Update(CRC64_INIT_VAL, Data, Size) xor CRC64_INIT_VAL;
end;

function Crc64Calc(const Data: TBytes): UInt64;
begin
  if Length(Data) = 0 then
    Result := Crc64Calc(nil, 0)
  else
    Result := Crc64Calc(@Data[0], Length(Data));
end;

function Sha256Calc(const Data: TBytes): TBytes;
var
  Hash: THashSHA2;
begin
  Hash := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
  Hash.Update(Data, Length(Data));
  Result := Hash.HashAsBytes;
end;

function CheckDigest(const CheckId: Byte; const Data: TBytes): TBytes;
var
  C32: UInt32;
  C64: UInt64;
  I: Integer;
begin
  case CheckId of
    XZ_CHECK_NO:
      SetLength(Result, 0);
    XZ_CHECK_CRC32:
      begin
        SetLength(Result, 4);
        C32 := Crc32Calc(Data);
        WriteUi32LE(@Result[0], C32);
      end;
    XZ_CHECK_CRC64:
      begin
        SetLength(Result, 8);
        C64 := Crc64Calc(Data);
        for I := 0 to 7 do
        begin
          Result[I] := Byte(C64);
          C64 := C64 shr 8;
        end;
      end;
    XZ_CHECK_SHA256:
      Result := Sha256Calc(Data);
  else
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ check id');
  end;
end;

initialization
  GenerateTables;

end.
