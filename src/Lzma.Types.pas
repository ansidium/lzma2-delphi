unit Lzma.Types;

interface

uses
  System.SysUtils;

type
  SRes = Integer;
  SizeT = NativeUInt;
  BoolInt = Integer;
  CLzmaProb = UInt16;

const
  SZ_OK = 0;
  SZ_ERROR_DATA = 1;
  SZ_ERROR_MEM = 2;
  SZ_ERROR_CRC = 3;
  SZ_ERROR_UNSUPPORTED = 4;
  SZ_ERROR_PARAM = 5;
  SZ_ERROR_INPUT_EOF = 6;
  SZ_ERROR_OUTPUT_EOF = 7;
  SZ_ERROR_READ = 8;
  SZ_ERROR_WRITE = 9;
  SZ_ERROR_PROGRESS = 10;
  SZ_ERROR_FAIL = 11;
  SZ_ERROR_THREAD = 12;
  SZ_ERROR_ARCHIVE = 16;
  SZ_ERROR_NO_ARCHIVE = 17;

  LZMA_PROPS_SIZE = 5;
  LZMA2_DIC_PROP_MAX = 40;
  LZMA2_COPY_CHUNK_SIZE = 1 shl 16;
  LZMA2_CONTROL_EOF = 0;
  LZMA2_CONTROL_COPY_RESET_DIC = 1;
  LZMA2_CONTROL_COPY_NO_RESET = 2;
  LZMA_FAST_BYTES_MIN = 5;
  LZMA_FAST_BYTES_MAX = 273;

  XZ_ID_LZMA2 = $21;
  XZ_SIG_SIZE = 6;
  XZ_STREAM_FLAGS_SIZE = 2;
  XZ_STREAM_CRC_SIZE = 4;
  XZ_STREAM_HEADER_SIZE = XZ_SIG_SIZE + XZ_STREAM_FLAGS_SIZE + XZ_STREAM_CRC_SIZE;
  XZ_STREAM_FOOTER_SIZE = 12;
  XZ_BLOCK_HEADER_SIZE_MAX = 1024;
  XZ_CHECK_NO = 0;
  XZ_CHECK_CRC32 = 1;
  XZ_CHECK_CRC64 = 4;
  XZ_CHECK_SHA256 = 10;
  XZ_BF_NUM_FILTERS_MASK = 3;
  XZ_BF_PACK_SIZE = 1 shl 6;
  XZ_BF_UNPACK_SIZE = 1 shl 7;

type
  TLzma2CompressionLevel = 0..9;

  TLzma2Container = (
    lcRawLzma2,
    lcLzma,
    lcXz,
    lc7z
  );

  TLzma2Check = (
    lzCheckNone,
    lzCheckCrc32,
    lzCheckCrc64,
    lzCheckSha256
  );

  TLzmaParserMode = (
    lpmSdkProfile,
    lpmFast,
    lpmHighSpeed
  );

  TLzmaMatchFinderProfile = (
    lmfpAuto,
    lmfpHashChain4,
    lmfpHashChain5,
    lmfpBinaryTree4
  );

  TLzma2DecodeFallbackReason = (
    ldfrNone,
    ldfrThreadCountOne,
    ldfrNonSeekableStream,
    ldfrSingleIndependentUnit,
    ldfrUnknownPackedSize,
    ldfrUnknownUnpackedSize,
    ldfrUnsupportedLayout,
    ldfrMemoryLimit,
    ldfrInsufficientWork
  );

  TLzma2DecodeDiagnostics = record
    RequestedThreadCount: Integer;
    ActualThreadCount: Integer;
    IndependentUnitCount: Integer;
    UsedMultiThread: Boolean;
    FallbackReason: TLzma2DecodeFallbackReason;
    InputSnapshot: Boolean;
  end;

  PLzma2DecodeDiagnostics = ^TLzma2DecodeDiagnostics;

  TLzma2EncodeDiagnostics = record
    RequestedThreadCount: Integer;
    ActualThreadCount: Integer;
    BatchCount: Integer;
    BlockCount: Integer;
    FastBytes: Integer;
    NiceLen: Integer;
    CutValue: UInt32;
    XzBlockSize: UInt64;
    ParserMode: TLzmaParserMode;
    MatchFinderProfile: TLzmaMatchFinderProfile;
    NumHashBytes: Integer;
    OptimumParserEnabled: Boolean;
    FullOptimumDecisionCount: UInt64;
    CopyFastPathCount: Integer;
    IncompressibleFastPathCount: Integer;
    FallbackReason: string;
  end;

  PLzma2EncodeDiagnostics = ^TLzma2EncodeDiagnostics;

  TLzma2Options = record
    Level: TLzma2CompressionLevel;
    DictionarySize: UInt64;
    ThreadCount: Integer;
    Container: TLzma2Container;
    Check: TLzma2Check;
    BufferSize: NativeUInt;
    Lc: Integer;
    Lp: Integer;
    Pb: Integer;
    FastBytes: Integer;
    CutValue: UInt32;
    MemoryLimit: UInt64;
    StrictValidation: Boolean;
    DecodeDiagnostics: PLzma2DecodeDiagnostics;
    ParserMode: TLzmaParserMode;
    MatchFinderProfile: TLzmaMatchFinderProfile;
    XzBlockSize: UInt64;
    ArchiveFileName: string;
    EncodeDiagnostics: PLzma2EncodeDiagnostics;
    LzmaEndMarker: Boolean;
  end;

  TLzma2ProgressEvent = reference to procedure(
    const InBytes: UInt64;
    const OutBytes: UInt64;
    var Cancel: Boolean
  );

  TLzmaProps = record
    Lc: Byte;
    Lp: Byte;
    Pb: Byte;
    DictionarySize: UInt32;
  end;

  TLzma2DictionaryInfo = record
    RequestedSize: UInt64;
    NormalizedSize: UInt64;
    PropertyByte: Byte;
    Exact: Boolean;
  end;

const
  XZ_SIG: array[0..XZ_SIG_SIZE - 1] of Byte = ($FD, Ord('7'), Ord('z'), Ord('X'), Ord('Z'), 0);

function Lzma2DictionaryFromProperty(const Prop: Byte): UInt64;
function TryLzma2PropertyFromDictionary(const DictionarySize: UInt64; const Strict: Boolean;
  out Info: TLzma2DictionaryInfo): Boolean;
function DefaultDictionaryForLevel(const Level: TLzma2CompressionLevel): UInt64;
function XzCheckId(const Check: TLzma2Check): Byte;
function XzCheckFromId(const CheckId: Byte; out Check: TLzma2Check): Boolean;
function XzCheckSizeById(const CheckId: Byte): NativeUInt;
function XzPadSize(const Size: UInt64): Byte;
function ReadUi16BE(const P: PByte): UInt16;
function ReadUi32LE(const P: PByte): UInt32;
function ReadUi32BE(const P: PByte): UInt32;
function ReadUi64LE(const P: PByte): UInt64;
procedure WriteUi16BE(const P: PByte; const Value: UInt16);
procedure WriteUi32LE(const P: PByte; const Value: UInt32);
procedure WriteUi32BE(const P: PByte; const Value: UInt32);
procedure WriteUi64LE(const P: PByte; const Value: UInt64);
function XzWriteVarInt(const Value: UInt64): TBytes;
function XzReadVarInt(const Data: TBytes; var Offset: NativeUInt; const Limit: NativeUInt;
  out Value: UInt64): Boolean;
function LzmaPropsDecode(const Data: TBytes; out Props: TLzmaProps): Boolean;
function LzmaPropsEncode(const Props: TLzmaProps): TBytes;
function TryApplyLzmaOptionsToProps(var Props: TLzmaProps; const Options: TLzma2Options;
  const StrictLzma2Props: Boolean): Boolean;
procedure SetLzma2DecodeDiagnostics(const Options: TLzma2Options; const ActualThreadCount: Integer;
  const IndependentUnitCount: Integer; const UsedMultiThread: Boolean;
  const FallbackReason: TLzma2DecodeFallbackReason; const InputSnapshot: Boolean = False);

implementation

function Lzma2DictionaryFromProperty(const Prop: Byte): UInt64;
begin
  if Prop > LZMA2_DIC_PROP_MAX then
    raise EArgumentOutOfRangeException.Create('LZMA2 dictionary property must be in 0..40');

  if Prop = LZMA2_DIC_PROP_MAX then
    Exit(UInt64($FFFFFFFF));

  Result := UInt64(2 or (Prop and 1)) shl ((Prop div 2) + 11);
end;

function TryLzma2PropertyFromDictionary(const DictionarySize: UInt64; const Strict: Boolean;
  out Info: TLzma2DictionaryInfo): Boolean;
var
  I: Integer;
  Candidate: UInt64;
  Request: UInt64;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.RequestedSize := DictionarySize;
  Request := DictionarySize;
  if Request < 4096 then
    Request := 4096;
  if Request > UInt64($FFFFFFFF) then
    Request := UInt64($FFFFFFFF);

  for I := 0 to LZMA2_DIC_PROP_MAX do
  begin
    Candidate := Lzma2DictionaryFromProperty(Byte(I));
    if Request <= Candidate then
    begin
      Info.NormalizedSize := Candidate;
      Info.PropertyByte := Byte(I);
      Info.Exact := DictionarySize = Candidate;
      Result := (not Strict) or Info.Exact;
      Exit;
    end;
  end;

  Result := False;
end;

function DefaultDictionaryForLevel(const Level: TLzma2CompressionLevel): UInt64;
begin
  case Level of
    0: Result := 1 shl 20;
    1: Result := 1 shl 20;
    2: Result := 2 shl 20;
    3: Result := 4 shl 20;
    4: Result := 4 shl 20;
    5: Result := 8 shl 20;
    6: Result := 16 shl 20;
    7: Result := 32 shl 20;
    8: Result := 64 shl 20;
  else
    Result := 64 shl 20;
  end;
end;

function XzCheckId(const Check: TLzma2Check): Byte;
begin
  case Check of
    lzCheckNone: Result := XZ_CHECK_NO;
    lzCheckCrc32: Result := XZ_CHECK_CRC32;
    lzCheckCrc64: Result := XZ_CHECK_CRC64;
    lzCheckSha256: Result := XZ_CHECK_SHA256;
  else
    Result := XZ_CHECK_CRC64;
  end;
end;

function XzCheckFromId(const CheckId: Byte; out Check: TLzma2Check): Boolean;
begin
  Result := True;
  case CheckId of
    XZ_CHECK_NO: Check := lzCheckNone;
    XZ_CHECK_CRC32: Check := lzCheckCrc32;
    XZ_CHECK_CRC64: Check := lzCheckCrc64;
    XZ_CHECK_SHA256: Check := lzCheckSha256;
  else
    Check := lzCheckNone;
    Result := False;
  end;
end;

function XzCheckSizeById(const CheckId: Byte): NativeUInt;
begin
  case CheckId of
    XZ_CHECK_NO: Result := 0;
    XZ_CHECK_CRC32: Result := 4;
    XZ_CHECK_CRC64: Result := 8;
    XZ_CHECK_SHA256: Result := 32;
  else
    Result := NativeUInt(-1);
  end;
end;

function XzPadSize(const Size: UInt64): Byte;
begin
  Result := Byte((4 - (Size and 3)) and 3);
end;

function ReadUi16BE(const P: PByte): UInt16;
begin
  Result := (UInt16(P[0]) shl 8) or UInt16(P[1]);
end;

function ReadUi32LE(const P: PByte): UInt32;
begin
  Result := UInt32(P[0]) or (UInt32(P[1]) shl 8) or (UInt32(P[2]) shl 16) or (UInt32(P[3]) shl 24);
end;

function ReadUi32BE(const P: PByte): UInt32;
begin
  Result := (UInt32(P[0]) shl 24) or (UInt32(P[1]) shl 16) or (UInt32(P[2]) shl 8) or UInt32(P[3]);
end;

function ReadUi64LE(const P: PByte): UInt64;
begin
  Result := UInt64(ReadUi32LE(P)) or (UInt64(ReadUi32LE(P + 4)) shl 32);
end;

procedure WriteUi16BE(const P: PByte; const Value: UInt16);
begin
  P[0] := Byte(Value shr 8);
  P[1] := Byte(Value);
end;

procedure WriteUi32LE(const P: PByte; const Value: UInt32);
begin
  P[0] := Byte(Value);
  P[1] := Byte(Value shr 8);
  P[2] := Byte(Value shr 16);
  P[3] := Byte(Value shr 24);
end;

procedure WriteUi32BE(const P: PByte; const Value: UInt32);
begin
  P[0] := Byte(Value shr 24);
  P[1] := Byte(Value shr 16);
  P[2] := Byte(Value shr 8);
  P[3] := Byte(Value);
end;

procedure WriteUi64LE(const P: PByte; const Value: UInt64);
begin
  WriteUi32LE(P, UInt32(Value));
  WriteUi32LE(P + 4, UInt32(Value shr 32));
end;

function XzWriteVarInt(const Value: UInt64): TBytes;
var
  V: UInt64;
  B: Byte;
begin
  V := Value;
  SetLength(Result, 0);
  repeat
    B := Byte(V and $7F) or $80;
    V := V shr 7;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := B;
  until V = 0;
  Result[High(Result)] := Result[High(Result)] and $7F;
end;

function XzReadVarInt(const Data: TBytes; var Offset: NativeUInt; const Limit: NativeUInt;
  out Value: UInt64): Boolean;
var
  I: Integer;
  B: Byte;
begin
  Value := 0;
  Result := False;
  I := 0;
  while (Offset < Limit) and (I < 9) do
  begin
    B := Data[Offset];
    Inc(Offset);
    Value := Value or (UInt64(B and $7F) shl (7 * I));
    Inc(I);
    if (B and $80) = 0 then
    begin
      Result := not ((B = 0) and (I <> 1));
      Exit;
    end;
  end;
end;

function LzmaPropsDecode(const Data: TBytes; out Props: TLzmaProps): Boolean;
var
  D: Byte;
  Dict: UInt32;
begin
  FillChar(Props, SizeOf(Props), 0);
  Result := False;
  if Length(Data) < LZMA_PROPS_SIZE then
    Exit;
  D := Data[0];
  if D >= 9 * 5 * 5 then
    Exit;
  Props.Lc := D mod 9;
  D := D div 9;
  Props.Pb := D div 5;
  Props.Lp := D mod 5;
  Dict := ReadUi32LE(@Data[1]);
  if Dict < 4096 then
    Dict := 4096;
  Props.DictionarySize := Dict;
  Result := True;
end;

function LzmaPropsEncode(const Props: TLzmaProps): TBytes;
begin
  SetLength(Result, LZMA_PROPS_SIZE);
  Result[0] := Byte((Props.Pb * 5 + Props.Lp) * 9 + Props.Lc);
  WriteUi32LE(@Result[1], Props.DictionarySize);
end;

function TryApplyLzmaOptionByte(const Value, MaxValue: Integer; var Target: Byte): Boolean;
begin
  Result := False;
  if Value = -1 then
    Exit(True);
  if (Value < -1) or (Value > MaxValue) then
    Exit;
  Target := Byte(Value);
  Result := True;
end;

function TryApplyLzmaOptionsToProps(var Props: TLzmaProps; const Options: TLzma2Options;
  const StrictLzma2Props: Boolean): Boolean;
begin
  Result :=
    TryApplyLzmaOptionByte(Options.Lc, 8, Props.Lc) and
    TryApplyLzmaOptionByte(Options.Lp, 4, Props.Lp) and
    TryApplyLzmaOptionByte(Options.Pb, 4, Props.Pb);
  if Result and StrictLzma2Props and (Integer(Props.Lc) + Integer(Props.Lp) > 4) then
    Result := False;
end;

procedure SetLzma2DecodeDiagnostics(const Options: TLzma2Options; const ActualThreadCount: Integer;
  const IndependentUnitCount: Integer; const UsedMultiThread: Boolean;
  const FallbackReason: TLzma2DecodeFallbackReason; const InputSnapshot: Boolean);
var
  RequestedThreadCount: Integer;
begin
  if Options.DecodeDiagnostics = nil then
    Exit;

  RequestedThreadCount := Options.ThreadCount;
  if RequestedThreadCount < 1 then
    RequestedThreadCount := 1;

  Options.DecodeDiagnostics^.RequestedThreadCount := RequestedThreadCount;
  Options.DecodeDiagnostics^.ActualThreadCount := ActualThreadCount;
  Options.DecodeDiagnostics^.IndependentUnitCount := IndependentUnitCount;
  Options.DecodeDiagnostics^.UsedMultiThread := UsedMultiThread;
  Options.DecodeDiagnostics^.FallbackReason := FallbackReason;
  Options.DecodeDiagnostics^.InputSnapshot := InputSnapshot;
end;

end.
