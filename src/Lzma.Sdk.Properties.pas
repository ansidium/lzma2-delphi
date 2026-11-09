unit Lzma.Sdk.Properties;

{$ALIGN 8}

interface

uses System.SysUtils, Lzma.Types;

const
  LZMA_SDK_BLOCK_THREADS_MAX = 256; // SDK 26.05 C/MtCoder.h
  LZMA_SDK_BLOCK_SIZE_AUTO = UInt64(0);
  LZMA_SDK_BLOCK_SIZE_SOLID = High(UInt64);

type
  // Applied scalar state of LzmaEnc_SetProps; Normalize and SetProps differ.
  TLzmaSdkEffectiveLzmaProps26 = record
    DictSize, Lc, Lp, Pb, Fb, BtMode, NumHashBytes, NumHashOutBits: UInt32;
    Mc, WriteEndMark, MultiThread, FastMode: UInt32;
  end;

  // Complete CLzmaEncProps 26.05 field widths/order. The legacy Delphi record
  // in Lzma.Sdk remains a separate compatibility interface.
  TLzmaSdkLzmaEncProps26 = record
    Level: Int32;
    DictSize: UInt32;
    Lc, Lp, Pb, Algo, Fb, BtMode, NumHashBytes: Int32;
    NumHashOutBits, Mc, WriteEndMark: UInt32;
    NumThreads, AffinityGroup: Int32;
    ReduceSize, Affinity, AffinityInGroup: UInt64;
    class function Init: TLzmaSdkLzmaEncProps26; static;
    procedure Normalize(const SingleThreadBuild: Boolean = False);
    function GetDictionarySize(const SingleThreadBuild: Boolean = False): UInt32;
    function GetEffective(out Effective: TLzmaSdkEffectiveLzmaProps26;
      const SingleThreadBuild: Boolean = False): SRes;
    function WriteProperties(Properties: PByte; var Size: SizeT;
      const SingleThreadBuild: Boolean = False): SRes; overload;
    function WriteProperties(out Properties: TBytes;
      const SingleThreadBuild: Boolean = False): SRes; overload;
  end;

  TLzmaSdkLzma2EncProps26 = record
    LzmaProps: TLzmaSdkLzmaEncProps26;
    BlockSize: UInt64;
    NumBlockThreadsReduced, NumBlockThreadsMax, NumTotalThreads: Int32;
    NumThreadGroups: UInt32;
    class function Init: TLzmaSdkLzma2EncProps26; static;
    procedure Normalize(const SingleThreadBuild: Boolean = False);
    function WriteProperties(const SingleThreadBuild: Boolean = False): Byte;
  end;

implementation

function MultiplyInt32(const A, B: Int32): Int32;
var UA, UB, Bits: UInt32;
begin
  // Explicit machine-width arithmetic, also when Delphi R+/Q+ is enabled.
  // SDK callers should avoid signed-overflow/zero-division normalization inputs.
  Move(A, UA, SizeOf(A)); Move(B, UB, SizeOf(B));
  Bits := UInt32((UInt64(UA) * UInt64(UB)) and $FFFFFFFF);
  Move(Bits, Result, SizeOf(Result));
end;

class function TLzmaSdkLzmaEncProps26.Init: TLzmaSdkLzmaEncProps26;
begin
  Result := Default(TLzmaSdkLzmaEncProps26);
  Result.Level := 5;
  Result.ReduceSize := High(UInt64);
  Result.Lc := -1; Result.Lp := -1; Result.Pb := -1;
  Result.Algo := -1; Result.Fb := -1; Result.BtMode := -1;
  Result.NumHashBytes := -1; Result.NumThreads := -1; Result.AffinityGroup := -1;
end;

procedure TLzmaSdkLzmaEncProps26.Normalize(const SingleThreadBuild: Boolean);
var V: UInt32;
begin
  if Level < 0 then Level := 5;
  if DictSize = 0 then
  begin
    if Level <= 4 then DictSize := UInt32(1) shl (Level * 2 + 16)
    else if Level <= SizeOf(NativeUInt) div 2 + 4 then
      DictSize := UInt32(1) shl (Level + 20)
    else DictSize := UInt32(1) shl (SizeOf(NativeUInt) div 2 + 24);
  end;
  if UInt64(DictSize) > ReduceSize then
  begin
    V := UInt32(ReduceSize); // guarded above: ReduceSize fits UInt32 here
    if V < 4096 then V := 4096;
    if DictSize > V then DictSize := V;
  end;
  if Lc < 0 then Lc := 3;
  if Lp < 0 then Lp := 0;
  if Pb < 0 then Pb := 2;
  if Algo < 0 then
    if Level < 5 then Algo := 0 else Algo := 1;
  if Fb < 0 then
    if Level < 7 then Fb := 32 else Fb := 64;
  if BtMode < 0 then
    if Algo = 0 then BtMode := 0 else BtMode := 1;
  if NumHashBytes < 0 then
    if BtMode <> 0 then NumHashBytes := 4 else NumHashBytes := 5;
  if Mc = 0 then
  begin
    Mc := 16 + (UInt32(Fb) shr 1);
    if BtMode = 0 then Mc := Mc shr 1;
  end;
  if NumThreads < 0 then
    if (not SingleThreadBuild) and (BtMode <> 0) and (Algo <> 0) then
      NumThreads := 2 else NumThreads := 1;
end;

function TLzmaSdkLzmaEncProps26.GetDictionarySize(const SingleThreadBuild: Boolean): UInt32;
var P: TLzmaSdkLzmaEncProps26;
begin P := Self; P.Normalize(SingleThreadBuild); Result := P.DictSize; end;

function TLzmaSdkLzmaEncProps26.GetEffective(out Effective: TLzmaSdkEffectiveLzmaProps26;
  const SingleThreadBuild: Boolean): SRes;
const MaxHistory = UInt32(15) shl 28;
var P: TLzmaSdkLzmaEncProps26;
begin
  Effective := Default(TLzmaSdkEffectiveLzmaProps26);
  P := Self; P.Normalize(SingleThreadBuild);
  if (P.Lc > 8) or (P.Lp > 4) or (P.Pb > 4) then Exit(SZ_ERROR_PARAM);
  Effective.DictSize := P.DictSize;
  if Effective.DictSize > MaxHistory then Effective.DictSize := MaxHistory;
  Effective.Lc := UInt32(P.Lc); Effective.Lp := UInt32(P.Lp); Effective.Pb := UInt32(P.Pb);
  Effective.Fb := UInt32(P.Fb);
  if Effective.Fb < 5 then Effective.Fb := 5;
  if Effective.Fb > 273 then Effective.Fb := 273;
  Effective.FastMode := Ord(P.Algo = 0); Effective.BtMode := Ord(P.BtMode <> 0);
  Effective.NumHashBytes := 4;
  if P.BtMode <> 0 then
  begin
    if P.NumHashBytes < 2 then Effective.NumHashBytes := 2
    else if P.NumHashBytes < 4 then Effective.NumHashBytes := UInt32(P.NumHashBytes);
  end;
  if P.NumHashBytes >= 5 then Effective.NumHashBytes := 5;
  Effective.NumHashOutBits := P.NumHashOutBits and 255;
  Effective.Mc := P.Mc; Effective.WriteEndMark := P.WriteEndMark;
  if not SingleThreadBuild then Effective.MultiThread := Ord(P.NumThreads > 1);
  Result := SZ_OK;
end;

function TLzmaSdkLzmaEncProps26.WriteProperties(Properties: PByte; var Size: SizeT;
  const SingleThreadBuild: Boolean): SRes;
var E: TLzmaSdkEffectiveLzmaProps26; V, I: UInt32;
begin
  if (Size < LZMA_PROPS_SIZE) or (Properties = nil) then Exit(SZ_ERROR_PARAM);
  Result := GetEffective(E, SingleThreadBuild);
  if Result <> SZ_OK then Exit;
  Size := LZMA_PROPS_SIZE;
  Properties[0] := Byte((E.Pb * 5 + E.Lp) * 9 + E.Lc);
  if E.DictSize >= UInt32(1) shl 21 then
    V := UInt32((UInt64(E.DictSize) + $FFFFF) and $FFF00000)
  else
  begin
    I := 22;
    repeat V := (UInt32(2) + (I and 1)) shl (I shr 1); Inc(I);
    until V >= E.DictSize;
  end;
  if V < E.DictSize then V := E.DictSize;
  for I := 0 to 3 do Properties[I + 1] := Byte((V shr (I * 8)) and 255);
end;

function TLzmaSdkLzmaEncProps26.WriteProperties(out Properties: TBytes;
  const SingleThreadBuild: Boolean): SRes;
var Buffer: array[0..LZMA_PROPS_SIZE - 1] of Byte; Size: SizeT;
begin
  Properties := nil; Size := Length(Buffer);
  Result := WriteProperties(@Buffer[0], Size, SingleThreadBuild);
  if Result <> SZ_OK then Exit;
  SetLength(Properties, LZMA_PROPS_SIZE); Move(Buffer[0], Properties[0], LZMA_PROPS_SIZE);
end;

class function TLzmaSdkLzma2EncProps26.Init: TLzmaSdkLzma2EncProps26;
begin
  Result := Default(TLzmaSdkLzma2EncProps26);
  Result.LzmaProps := TLzmaSdkLzmaEncProps26.Init;
  Result.NumBlockThreadsReduced := -1; Result.NumBlockThreadsMax := -1;
  Result.NumTotalThreads := -1;
end;

procedure TLzmaSdkLzma2EncProps26.Normalize(const SingleThreadBuild: Boolean);
const MinBlock = UInt64(1) shl 20; MaxBlock = UInt64(1) shl 28;
var P: TLzmaSdkLzmaEncProps26; T1, T1n, T2, T2r, T3, MaxThreads: Int32;
    FileSize, Block, NumBlocks: UInt64;
begin
  P := LzmaProps; P.Normalize(SingleThreadBuild); T1n := P.NumThreads;
  T1 := LzmaProps.NumThreads; T2 := NumBlockThreadsMax; T3 := NumTotalThreads;
  if SingleThreadBuild then MaxThreads := 1 else MaxThreads := LZMA_SDK_BLOCK_THREADS_MAX;
  if T2 > MaxThreads then T2 := MaxThreads;
  if T3 <= 0 then
  begin
    if T2 <= 0 then T2 := 1;
    T3 := MultiplyInt32(T1n, T2);
  end
  else if T2 <= 0 then
  begin
    T2 := T3 div T1n;
    if T2 = 0 then begin T1 := 1; T2 := T3; end;
    if T2 > MaxThreads then T2 := MaxThreads;
  end
  else if T1 <= 0 then
  begin
    T1 := T3 div T2; if T1 = 0 then T1 := 1;
  end
  else T3 := MultiplyInt32(T1n, T2);
  LzmaProps.NumThreads := T1; T2r := T2; FileSize := LzmaProps.ReduceSize;
  if (BlockSize <> LZMA_SDK_BLOCK_SIZE_SOLID) and (BlockSize <> LZMA_SDK_BLOCK_SIZE_AUTO) and
    ((BlockSize < FileSize) or (FileSize = High(UInt64))) then LzmaProps.ReduceSize := BlockSize;
  LzmaProps.Normalize(SingleThreadBuild); LzmaProps.ReduceSize := FileSize;
  T1 := LzmaProps.NumThreads;
  if BlockSize = LZMA_SDK_BLOCK_SIZE_SOLID then
  begin T2r := 1; T2 := 1; T3 := T1; end
  else if (BlockSize = LZMA_SDK_BLOCK_SIZE_AUTO) and (T2 <= 1) then
    BlockSize := LZMA_SDK_BLOCK_SIZE_SOLID
  else
  begin
    if BlockSize = LZMA_SDK_BLOCK_SIZE_AUTO then
    begin
      Block := UInt64(LzmaProps.DictSize) shl 2;
      if Block < MinBlock then Block := MinBlock;
      if Block > MaxBlock then Block := MaxBlock;
      if Block < LzmaProps.DictSize then Block := LzmaProps.DictSize;
      BlockSize := (Block + MinBlock - 1) and not (MinBlock - 1);
    end;
    if (T2 > 1) and (FileSize <> High(UInt64)) then
    begin
      NumBlocks := FileSize div BlockSize;
      if NumBlocks * BlockSize <> FileSize then Inc(NumBlocks);
      if NumBlocks < UInt32(T2) then
      begin
        T2r := Int32(NumBlocks); if T2r = 0 then T2r := 1;
        T3 := MultiplyInt32(T1, T2r);
      end;
    end;
  end;
  NumBlockThreadsMax := T2; NumBlockThreadsReduced := T2r; NumTotalThreads := T3;
end;

function TLzmaSdkLzma2EncProps26.WriteProperties(const SingleThreadBuild: Boolean): Byte;
var P: TLzmaSdkLzma2EncProps26; Dictionary: UInt32; I: Integer; Bound: UInt64;
begin
  P := Self; P.Normalize(SingleThreadBuild); Dictionary := P.LzmaProps.GetDictionarySize(SingleThreadBuild);
  for I := 0 to 39 do
  begin
    Bound := UInt64(2 or (I and 1)) shl (I div 2 + 11);
    if Dictionary <= Bound then Exit(Byte(I));
  end;
  Result := 40;
end;

end.
