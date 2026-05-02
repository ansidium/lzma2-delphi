unit Lzma.Encoder;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.MatchFinder,
  Lzma.RangeCoder,
  Lzma.Types;

type
  TLzmaEncoderProfile = record
    Level: TLzma2CompressionLevel;
    DictionarySize: UInt64;
    FastBytes: Integer;
    Algorithm: Integer;
    MatchFinderKind: TLzmaMatchFinderKind;
    MatchFinderProfile: TLzmaMatchFinderProfile;
    ParserMode: TLzmaParserMode;
    NumHashBytes: Integer;
    CutValue: UInt32;
    DefaultThreadCount: Integer;
    MatchFinder: string;
  end;

  TLzmaRawEncoder = class
  public
    class function NormalizeProfile(const Level: TLzma2CompressionLevel; const DictionarySize: UInt64): TLzmaEncoderProfile; static;
    class function DefaultProperties(const DictionarySize: UInt64): TLzmaProps; static;
    class function WriteProperties(const Props: TLzmaProps): TBytes; static;
    class function EncodeLiteralOnlyChunk(const Data: TBytes; const Offset, Count: NativeUInt;
      const Props: TLzmaProps): TBytes; static;
    class function EncodeLiteralOnlyChunkWithState(const Data: TBytes; const Offset, Count: NativeUInt;
      const Props: TLzmaProps; const InitialProcessed: UInt64; const InitialPrevByte: Byte): TBytes; static;
    class function EncodeGreedyChunk(const Data: TBytes; const Offset, Count: NativeUInt;
      const Props: TLzmaProps; const FastBytes: Integer; const CutValue: UInt32 = 0;
      const MatchFinderKind: TLzmaMatchFinderKind = mfHashChain4;
      const WriteEndMarker: Boolean = False;
      const EnableOptimumWindow: Boolean = False;
      const Progress: TLzma2ProgressEvent = nil;
      const FullOptimumDecisionCount: PUInt64 = nil): TBytes; static;
    class function EncodePeriodicChunks(const Data: TBytes; const Offset, Count, ChunkSize: NativeUInt;
      const Props: TLzmaProps; const Period: UInt32; out Chunks: TArray<TBytes>): Boolean; static;
    class function EncodeRepeatedPeriodicUnitChunks(const Data: TBytes; const Offset, Count,
      ChunkSize: NativeUInt; const Props: TLzmaProps; const Period: UInt32;
      const UnitSize: UInt32; out Chunks: TArray<TBytes>): Boolean; static;
    class procedure Encode(Source: TStream; Destination: TStream; const Profile: TLzmaEncoderProfile;
      const Progress: TLzma2ProgressEvent = nil); overload; static;
    class procedure Encode(Source: TStream; Destination: TStream; const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const WriteEndMarker: Boolean;
      const Progress: TLzma2ProgressEvent = nil); overload; static;
  end;

implementation

uses
  Lzma.EncoderHeuristics,
  Lzma.Errors,
  Lzma.PriceTables,
  Lzma.Streams;

type
  TLzmaEncoderConstants = record
  public const
    kNumStates = 12;
    kNumPosBitsMax = 4;
    kNumPosStatesMax = 1 shl kNumPosBitsMax;
    kNumLitStates = 7;
    kLenNumLowBits = 3;
    kLenNumLowSymbols = 1 shl kLenNumLowBits;
    kLenNumHighBits = 8;
    kLenNumHighSymbols = 1 shl kLenNumHighBits;
    kLenNumSymbolsTotal = kLenNumLowSymbols * 2 + kLenNumHighSymbols;
    kNumLenToPosStates = 4;
    kNumPosSlotBits = 6;
    kStartPosModelIndex = 4;
    kEndPosModelIndex = 14;
    kNumFullDistances = 1 shl (kEndPosModelIndex shr 1);
    kNumAlignBits = 4;
    kAlignTableSize = 1 shl kNumAlignBits;
    kMatchMinLen = 2;
    kMatchMaxLen = kMatchMinLen + kLenNumSymbolsTotal - 1;
  end;

  TProbArray = array[0..MaxInt div SizeOf(CLzmaProb) - 1] of CLzmaProb;
  PProbArray = ^TProbArray;

  TLenEncoder = record
    Low: TLzmaLenLowProbs;
    High: TLzmaLenHighProbs;
  end;

  TLzmaRangeEncoder = class
  private
    FLow: UInt64;
    FRange: UInt32;
    FCache: Byte;
    FCacheSize: UInt64;
    FOutput: TBytes;
    FOutputStream: TStream;
    FOutputSize: UInt64;
    FCommittedOutputSize: UInt64;
    FStreamBuffer: TBytes;
    FStreamBufferSize: NativeInt;
    procedure FlushStreamBuffer;
    procedure PutByte(const B: Byte); inline;
    procedure ShiftLow;
  public
    constructor Create(const OutputStream: TStream = nil);
    destructor Destroy; override;
    procedure Init;
    procedure EncodeBit(var Prob: CLzmaProb; const Bit: UInt32); inline;
    procedure EncodeDirectBits(const Value, NumBits: UInt32);
    procedure BitTreeEncode(var Probs; const NumBits, Symbol: UInt32);
    procedure BitTreeReverseEncode(var Probs; const NumBits, Symbol: UInt32);
    procedure EncodeLiteral(var Probs; const Value: Byte);
    procedure EncodeMatchedLiteral(var Probs; const Value, MatchByte: Byte);
    procedure FlushData;
    function ToBytes: TBytes;
  end;

const
  LZMA_STATE_LITERAL_NEXT: array[0..11] of UInt32 = (
    0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 4, 5);
  LZMA_STATE_MATCH_NEXT: array[0..11] of UInt32 = (
    7, 7, 7, 7, 7, 7, 7, 10, 10, 10, 10, 10);
  LZMA_STATE_REP_NEXT: array[0..11] of UInt32 = (
    8, 8, 8, 8, 8, 8, 8, 11, 11, 11, 11, 11);
  LZMA_STATE_SHORT_REP_NEXT: array[0..11] of UInt32 = (
    9, 9, 9, 9, 9, 9, 9, 11, 11, 11, 11, 11);

procedure InitProbArray(var Data; const Count: NativeUInt);
var
  P: PProbArray;
  I: NativeUInt;
begin
  P := @Data;
  for I := 0 to Count - 1 do
    P^[I] := LZMA_PROB_INIT;
end;

function SdkRawDictionaryForLevel(const Level: TLzma2CompressionLevel): UInt64;
begin
  if Level <= 4 then
    Result := UInt64(1) shl (Level * 2 + 16)
  else if Level <= 8 then
    Result := UInt64(1) shl (Level + 20)
  else
    Result := UInt64(1) shl 28;
end;

function SdkAlignedRawDictionary(const DictionarySize: UInt32): UInt32;
var
  I: UInt32;
  V: UInt32;
  Aligned: UInt64;
const
  kDictMask = UInt64((UInt32(1) shl 20) - 1);
begin
  if DictionarySize >= UInt32(1) shl 21 then
  begin
    Aligned := (UInt64(DictionarySize) + kDictMask) and not kDictMask;
    if Aligned > UInt64(High(UInt32)) then
      V := DictionarySize
    else
      V := UInt32(Aligned);
    if V < DictionarySize then
      V := DictionarySize;
    Exit(V);
  end;

  I := 11 * 2;
  repeat
    V := UInt32(2 + (I and 1)) shl (I shr 1);
    Inc(I);
  until V >= DictionarySize;
  Result := V;
end;

procedure InitLenEncoder(var Encoder: TLenEncoder);
begin
  LzmaInitLenProbs(Encoder.Low, Encoder.High);
end;

function GetLenToPosState(const Len: UInt32): UInt32;
begin
  if Len < TLzmaEncoderConstants.kNumLenToPosStates + 1 then
    Result := Len - TLzmaEncoderConstants.kMatchMinLen
  else
    Result := TLzmaEncoderConstants.kNumLenToPosStates - 1;
end;

function GetPosSlot(const Dist: UInt32): UInt32;
var
  Z: UInt32;
  V: UInt32;
begin
  if Dist < 2 then
    Exit(Dist);
  Z := 0;
  V := Dist;
  while V > 1 do
  begin
    V := V shr 1;
    Inc(Z);
  end;
  Dec(Z);
  Result := (Z shl 1) + (Dist shr Z);
end;

function ChangePair(const SmallDistance, BigDistance: UInt32): Boolean;
begin
  Result := ((BigDistance - 1) shr 7) > (SmallDistance - 1);
end;

procedure EncodeLenSymbol(const Encoder: TLzmaRangeEncoder; var LenEncoder: TLenEncoder;
  Symbol, PosState: UInt32);
var
  PosOffset: UInt32;
begin
  PosOffset := PosState shl (1 + TLzmaEncoderConstants.kLenNumLowBits);
  if Symbol < TLzmaEncoderConstants.kLenNumLowSymbols then
  begin
    Encoder.EncodeBit(LenEncoder.Low[0], 0);
    Encoder.BitTreeEncode(LenEncoder.Low[PosOffset], TLzmaEncoderConstants.kLenNumLowBits, Symbol);
    Exit;
  end;

  Encoder.EncodeBit(LenEncoder.Low[0], 1);
  Dec(Symbol, TLzmaEncoderConstants.kLenNumLowSymbols);
  if Symbol < TLzmaEncoderConstants.kLenNumLowSymbols then
  begin
    Encoder.EncodeBit(LenEncoder.Low[TLzmaEncoderConstants.kLenNumLowSymbols], 0);
    Encoder.BitTreeEncode(LenEncoder.Low[PosOffset + TLzmaEncoderConstants.kLenNumLowSymbols],
      TLzmaEncoderConstants.kLenNumLowBits, Symbol);
    Exit;
  end;

  Encoder.EncodeBit(LenEncoder.Low[TLzmaEncoderConstants.kLenNumLowSymbols], 1);
  Dec(Symbol, TLzmaEncoderConstants.kLenNumLowSymbols);
  Encoder.BitTreeEncode(LenEncoder.High[0], TLzmaEncoderConstants.kLenNumHighBits, Symbol);
end;

procedure EncodeDistance(const Encoder: TLzmaRangeEncoder; var PosSlot;
  var PosDecoders; var Align; const Len, ActualDistance: UInt32);
var
  PosSlotArray: PProbArray;
  PosDecArray: PProbArray;
  AlignArray: PProbArray;
  Dist: UInt32;
  LenState: UInt32;
  Slot: UInt32;
  FooterBits: UInt32;
  Base: UInt32;
begin
  if ActualDistance = 0 then
    RaiseLzmaError(SZ_ERROR_PARAM, 'LZMA match distance must be positive');

  PosSlotArray := @PosSlot;
  PosDecArray := @PosDecoders;
  AlignArray := @Align;
  Dist := ActualDistance - 1;
  LenState := GetLenToPosState(Len);
  Slot := GetPosSlot(Dist);
  Encoder.BitTreeEncode(PosSlotArray^[
    LenState * (UInt32(1) shl TLzmaEncoderConstants.kNumPosSlotBits)],
    TLzmaEncoderConstants.kNumPosSlotBits, Slot);

  if Dist < TLzmaEncoderConstants.kStartPosModelIndex then
    Exit;

  FooterBits := (Slot shr 1) - 1;
  Base := (UInt32(2) or (Slot and 1)) shl FooterBits;
  if Dist < Base then
    RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid LZMA distance slot calculation');

  if Dist < TLzmaEncoderConstants.kNumFullDistances then
  begin
    Encoder.BitTreeReverseEncode(PosDecArray^[Base], FooterBits, Dist);
    Exit;
  end;

  Encoder.EncodeDirectBits((Dist - Base) shr TLzmaEncoderConstants.kNumAlignBits,
    FooterBits - TLzmaEncoderConstants.kNumAlignBits);
  Encoder.BitTreeReverseEncode(AlignArray^[0], TLzmaEncoderConstants.kNumAlignBits,
    Dist and (TLzmaEncoderConstants.kAlignTableSize - 1));
end;

constructor TLzmaRangeEncoder.Create(const OutputStream: TStream);
begin
  inherited Create;
  FOutputStream := OutputStream;
  if FOutputStream <> nil then
    SetLength(FStreamBuffer, 1 shl 15);
end;

destructor TLzmaRangeEncoder.Destroy;
begin
  inherited Destroy;
end;

procedure TLzmaRangeEncoder.Init;
begin
  FOutputSize := 0;
  FCommittedOutputSize := 0;
  FStreamBufferSize := 0;
  FLow := 0;
  FRange := $FFFFFFFF;
  FCache := 0;
  FCacheSize := 0;
end;

procedure TLzmaRangeEncoder.FlushStreamBuffer;
begin
  if (FOutputStream = nil) or (FStreamBufferSize = 0) then
    Exit;
  WriteExact(FOutputStream, FStreamBuffer[0], FStreamBufferSize);
  Inc(FCommittedOutputSize, UInt64(FStreamBufferSize));
  FStreamBufferSize := 0;
end;

procedure TLzmaRangeEncoder.PutByte(const B: Byte);
var
  NewCapacity: NativeUInt;
begin
  if FOutputStream <> nil then
  begin
    if Length(FStreamBuffer) = 0 then
      SetLength(FStreamBuffer, 1 shl 15);
    FStreamBuffer[FStreamBufferSize] := B;
    Inc(FStreamBufferSize);
    Inc(FOutputSize);
    if FStreamBufferSize = Length(FStreamBuffer) then
      FlushStreamBuffer;
    Exit;
  end;

  if FOutputSize > UInt64(High(NativeUInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA range output exceeds native TBytes capacity');
  if NativeUInt(FOutputSize) = NativeUInt(Length(FOutput)) then
  begin
    NewCapacity := NativeUInt(Length(FOutput));
    if NewCapacity < 65536 then
      NewCapacity := 65536
    else if NewCapacity > NativeUInt(High(NativeInt)) div 2 then
      RaiseLzmaError(SZ_ERROR_MEM, 'LZMA range output exceeds native TBytes capacity')
    else
      NewCapacity := NewCapacity * 2;
    SetLength(FOutput, NativeInt(NewCapacity));
  end;
  FOutput[NativeInt(FOutputSize)] := B;
  Inc(FOutputSize);
end;

procedure TLzmaRangeEncoder.ShiftLow;
var
  Low32: UInt32;
  High: UInt32;
  B: Byte;
begin
  Low32 := UInt32(FLow);
  High := UInt32(FLow shr 32);
  FLow := UInt64(Low32 shl 8);

  if (Low32 < UInt32($FF000000)) or (High <> 0) then
  begin
    B := Byte(UInt32(FCache) + High);
    PutByte(B);
    FCache := Byte(Low32 shr 24);
    if FCacheSize = 0 then
      Exit;

    Inc(High, $FF);
    repeat
      B := Byte(High);
      PutByte(B);
      Dec(FCacheSize);
    until FCacheSize = 0;
    Exit;
  end;

  Inc(FCacheSize);
end;

procedure TLzmaRangeEncoder.EncodeBit(var Prob: CLzmaProb; const Bit: UInt32);
var
  Bound: UInt32;
begin
  Bound := (FRange shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob);
  if Bit = 0 then
  begin
    FRange := Bound;
    Prob := LzmaProbUpdate0(Prob);
  end
  else
  begin
    FLow := FLow + Bound;
    FRange := FRange - Bound;
    Prob := LzmaProbUpdate1(Prob);
  end;

  if FRange < LZMA_TOP_VALUE then
  begin
    FRange := FRange shl 8;
    ShiftLow;
  end;
end;

procedure TLzmaRangeEncoder.EncodeDirectBits(const Value, NumBits: UInt32);
var
  I: Integer;
begin
  for I := Integer(NumBits) - 1 downto 0 do
  begin
    FRange := FRange shr 1;
    if ((Value shr UInt32(I)) and 1) <> 0 then
      FLow := FLow + FRange;
    if FRange < LZMA_TOP_VALUE then
    begin
      FRange := FRange shl 8;
      ShiftLow;
    end
  end;
end;

procedure TLzmaRangeEncoder.BitTreeEncode(var Probs; const NumBits, Symbol: UInt32);
var
  P: PProbArray;
  M: UInt32;
  BitIndex: Integer;
  Bit: UInt32;
begin
  P := @Probs;
  M := 1;
  for BitIndex := Integer(NumBits) - 1 downto 0 do
  begin
    Bit := (Symbol shr UInt32(BitIndex)) and 1;
    EncodeBit(P^[M], Bit);
    M := (M shl 1) or Bit;
  end;
end;

procedure TLzmaRangeEncoder.BitTreeReverseEncode(var Probs; const NumBits, Symbol: UInt32);
var
  P: PProbArray;
  I: UInt32;
  M: UInt32;
  Bit: UInt32;
begin
  P := @Probs;
  M := 1;
  for I := 0 to NumBits - 1 do
  begin
    Bit := (Symbol shr I) and 1;
    EncodeBit(P^[M], Bit);
    M := (M shl 1) or Bit;
  end;
end;

procedure TLzmaRangeEncoder.EncodeLiteral(var Probs; const Value: Byte);
var
  P: PProbArray;
  Symbol: UInt32;
  Bit: UInt32;
begin
  P := @Probs;
  Symbol := UInt32(Value) or $100;
  repeat
    Bit := (Symbol shr 7) and 1;
    EncodeBit(P^[Symbol shr 8], Bit);
    Symbol := Symbol shl 1;
  until Symbol >= $10000;
end;

procedure TLzmaRangeEncoder.EncodeMatchedLiteral(var Probs; const Value, MatchByte: Byte);
var
  P: PProbArray;
  Symbol: UInt32;
  Match: UInt32;
  MatchBit: UInt32;
  Bit: UInt32;
  Offset: UInt32;
begin
  P := @Probs;
  Symbol := UInt32(Value) or $100;
  Match := UInt32(MatchByte);
  Offset := $100;
  repeat
    Match := Match shl 1;
    MatchBit := Match and Offset;
    Bit := (Symbol shr 7) and 1;
    EncodeBit(P^[Offset + MatchBit + (Symbol shr 8)], Bit);
    Symbol := Symbol shl 1;
    Offset := Offset and not (Match xor Symbol);
  until Symbol >= $10000;
end;

procedure TLzmaRangeEncoder.FlushData;
var
  I: Integer;
begin
  for I := 0 to 4 do
    ShiftLow;
  FlushStreamBuffer;
end;

function TLzmaRangeEncoder.ToBytes: TBytes;
begin
  if FOutputStream <> nil then
    RaiseLzmaError(SZ_ERROR_FAIL, 'Cannot materialize a sink-backed LZMA range encoder');
  if FOutputSize > UInt64(High(NativeInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA range output exceeds native TBytes capacity');
  SetLength(Result, NativeInt(FOutputSize));
  if FOutputSize <> 0 then
    Move(FOutput[0], Result[0], NativeInt(FOutputSize));
end;

class function TLzmaRawEncoder.NormalizeProfile(const Level: TLzma2CompressionLevel;
  const DictionarySize: UInt64): TLzmaEncoderProfile;
var
  BtMode: Boolean;
begin
  Result.Level := Level;
  Result.DictionarySize := DictionarySize;
  Result.ParserMode := lpmSdkProfile;
  if Result.DictionarySize = 0 then
    Result.DictionarySize := SdkRawDictionaryForLevel(Level);
  if Level < 7 then
    Result.FastBytes := 32
  else
    Result.FastBytes := 64;
  case Level of
    0:
      begin
        Result.Algorithm := 0;
        Result.MatchFinder := 'hc5-fast-greedy';
      end;
    1..3:
      begin
        Result.Algorithm := 0;
        Result.MatchFinder := 'hc5-fast-greedy';
      end;
    4:
      begin
        Result.Algorithm := 0;
        Result.MatchFinder := 'hc5-fast-greedy';
      end;
    5..6:
      begin
        Result.Algorithm := 1;
        Result.MatchFinder := 'bt4-normal-greedy';
      end;
  else
    Result.Algorithm := 1;
    Result.MatchFinder := 'bt4-ultra-greedy';
  end;
  BtMode := Result.Algorithm <> 0;
  if BtMode then
  begin
    Result.MatchFinderKind := mfBinaryTree4;
    Result.MatchFinderProfile := lmfpBinaryTree4;
    Result.NumHashBytes := 4;
    Result.CutValue := UInt32(16 + (Result.FastBytes shr 1));
    Result.DefaultThreadCount := 2;
  end
  else
  begin
    Result.MatchFinderKind := mfHashChain5;
    Result.MatchFinderProfile := lmfpHashChain5;
    Result.NumHashBytes := 5;
    Result.CutValue := UInt32(16 + (Result.FastBytes shr 1)) shr 1;
    Result.DefaultThreadCount := 1;
  end;
end;

class function TLzmaRawEncoder.WriteProperties(const Props: TLzmaProps): TBytes;
var
  Aligned: TLzmaProps;
begin
  Aligned := Props;
  Aligned.DictionarySize := SdkAlignedRawDictionary(Props.DictionarySize);
  Result := LzmaPropsEncode(Aligned);
end;

class function TLzmaRawEncoder.DefaultProperties(const DictionarySize: UInt64): TLzmaProps;
begin
  Result.Lc := 3;
  Result.Lp := 0;
  Result.Pb := 2;
  if DictionarySize >= UInt64(1) shl 32 then
    Result.DictionarySize := UInt32($FFFFFFFF)
  else if DictionarySize < 4096 then
    Result.DictionarySize := 4096
  else
    Result.DictionarySize := UInt32(DictionarySize);
end;

class function TLzmaRawEncoder.EncodeLiteralOnlyChunk(const Data: TBytes; const Offset, Count: NativeUInt;
  const Props: TLzmaProps): TBytes;
begin
  Result := EncodeLiteralOnlyChunkWithState(Data, Offset, Count, Props, 0, 0);
end;

class function TLzmaRawEncoder.EncodeLiteralOnlyChunkWithState(const Data: TBytes; const Offset,
  Count: NativeUInt; const Props: TLzmaProps; const InitialProcessed: UInt64;
  const InitialPrevByte: Byte): TBytes;
const
  kNumStates = 12;
  kNumPosBitsMax = 4;
  kNumPosStatesMax = 1 shl kNumPosBitsMax;
var
  IsMatch: array[0..kNumStates - 1, 0..kNumPosStatesMax - 1] of CLzmaProb;
  Literals: array of CLzmaProb;
  Encoder: TLzmaRangeEncoder;
  Pos: NativeUInt;
  Processed: UInt64;
  State: UInt32;
  PosState: UInt32;
  LitState: UInt32;
  LiteralOffset: NativeUInt;
  PrevByte: Byte;
  Value: Byte;
  PbMask: UInt32;
  LpMask: UInt32;
  LcBits: UInt32;
  LcShift: UInt32;
begin
  if Props.Lc > 8 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lc property');
  if Props.Lp > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lp property');
  if Props.Pb > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA pb property');
  if Offset > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Invalid LZMA encoder chunk offset');
  if Count > NativeUInt(Length(Data)) - Offset then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA encoder chunk');
  if Count > NativeUInt(High(UInt32)) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Literal-only LZMA chunk is too large');

  InitProbArray(IsMatch, kNumStates * kNumPosStatesMax);
  SetLength(Literals, $300 shl (Props.Lc + Props.Lp));
  InitProbArray(Literals[0], Length(Literals));
  PbMask := (UInt32(1) shl Props.Pb) - 1;
  LpMask := (UInt32(1) shl Props.Lp) - 1;
  LcBits := Props.Lc;
  LcShift := 8 - LcBits;

  Encoder := TLzmaRangeEncoder.Create;
  try
    Encoder.Init;
    Processed := InitialProcessed;
    PrevByte := InitialPrevByte;
    State := 0;
    if Count <> 0 then
    begin
      for Pos := 0 to Count - 1 do
      begin
        Value := Data[Offset + Pos];
        PosState := UInt32(Processed) and PbMask;
        Encoder.EncodeBit(IsMatch[State][PosState], 0);
        LitState := ((UInt32(Processed) and LpMask) shl LcBits) +
          (UInt32(PrevByte) shr LcShift);
        LiteralOffset := NativeUInt(LitState) * $300;
        Encoder.EncodeLiteral(Literals[LiteralOffset], Value);
        State := LZMA_STATE_LITERAL_NEXT[State];
        PrevByte := Value;
        Inc(Processed);
      end;
    end;
    Encoder.FlushData;
    Result := Encoder.ToBytes;
  finally
    Encoder.Free;
  end;
end;

class function TLzmaRawEncoder.EncodePeriodicChunks(const Data: TBytes; const Offset, Count,
  ChunkSize: NativeUInt; const Props: TLzmaProps; const Period: UInt32;
  out Chunks: TArray<TBytes>): Boolean;
begin
  Result := EncodeRepeatedPeriodicUnitChunks(Data, Offset, Count, ChunkSize, Props,
    Period, 0, Chunks);
end;

class function TLzmaRawEncoder.EncodeRepeatedPeriodicUnitChunks(const Data: TBytes; const Offset, Count,
  ChunkSize: NativeUInt; const Props: TLzmaProps; const Period: UInt32;
  const UnitSize: UInt32; out Chunks: TArray<TBytes>): Boolean;
var
  IsMatch: array[0..TLzmaEncoderConstants.kNumStates - 1,
    0..TLzmaEncoderConstants.kNumPosStatesMax - 1] of CLzmaProb;
  IsRep: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG0: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG1: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG2: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRep0Long: array[0..TLzmaEncoderConstants.kNumStates - 1,
    0..TLzmaEncoderConstants.kNumPosStatesMax - 1] of CLzmaProb;
  PosSlot: TLzmaPosSlotProbs;
  PosDecoders: TLzmaPosDecoderProbs;
  Align: TLzmaAlignProbs;
  LenEncoder: TLenEncoder;
  RepLenEncoder: TLenEncoder;
  Literals: array of CLzmaProb;
  Encoder: TLzmaRangeEncoder;
  AbsolutePos: NativeUInt;
  ChunkEnd: NativeUInt;
  ChunkIndex: Integer;
  ChunkCount: NativeUInt;
  LenRes: UInt32;
  PbMask: UInt32;
  LpMask: UInt32;
  LcBits: UInt32;
  LcShift: UInt32;
  PosState: UInt32;
  LitState: UInt32;
  LiteralOffset: NativeUInt;
  Value: Byte;
  PrevByte: Byte;
  MatchByte: Byte;
  State: UInt32;
  Reps: array[0..3] of UInt32;
  Processed: UInt64;

  function ActiveDistance: UInt32;
  begin
    if (UnitSize <> 0) and (AbsolutePos >= NativeUInt(UnitSize)) then
      Result := UnitSize
    else
      Result := Period;
  end;

  procedure EncodeOneLiteral;
  begin
    Value := Data[Offset + AbsolutePos];
    PosState := UInt32(Processed) and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 0);
    if AbsolutePos = 0 then
      PrevByte := 0
    else
      PrevByte := Data[Offset + AbsolutePos - 1];
    LitState := ((UInt32(Processed) and LpMask) shl LcBits) +
      (UInt32(PrevByte) shr LcShift);
    LiteralOffset := NativeUInt(LitState) * $300;
    if (State >= TLzmaEncoderConstants.kNumLitStates) and (NativeUInt(Reps[0]) <= AbsolutePos) then
    begin
      MatchByte := Data[Offset + AbsolutePos - NativeUInt(Reps[0])];
      Encoder.EncodeMatchedLiteral(Literals[LiteralOffset], Value, MatchByte);
    end
    else
      Encoder.EncodeLiteral(Literals[LiteralOffset], Value);
    State := LZMA_STATE_LITERAL_NEXT[State];
    Inc(AbsolutePos);
    Inc(Processed);
  end;

  procedure MoveRepToFront(const RepIndex: Integer);
  var
    Distance: UInt32;
  begin
    if RepIndex = 0 then
      Exit;
    Distance := Reps[RepIndex];
    case RepIndex of
      1:
        Reps[1] := Reps[0];
      2:
        begin
          Reps[2] := Reps[1];
          Reps[1] := Reps[0];
        end;
    else
      Reps[3] := Reps[2];
      Reps[2] := Reps[1];
      Reps[1] := Reps[0];
    end;
    Reps[0] := Distance;
  end;

  procedure EncodeOneRep(const RepIndex: Integer; const Len: UInt32);
  begin
    PosState := UInt32(Processed) and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 1);
    Encoder.EncodeBit(IsRep[State], 1);
    if (RepIndex = 0) and (Len = 1) then
    begin
      Encoder.EncodeBit(IsRepG0[State], 0);
      Encoder.EncodeBit(IsRep0Long[State][PosState], 0);
      State := LZMA_STATE_SHORT_REP_NEXT[State];
    end
    else
    begin
      if RepIndex = 0 then
      begin
        Encoder.EncodeBit(IsRepG0[State], 0);
        Encoder.EncodeBit(IsRep0Long[State][PosState], 1);
      end
      else
      begin
        Encoder.EncodeBit(IsRepG0[State], 1);
        if RepIndex = 1 then
          Encoder.EncodeBit(IsRepG1[State], 0)
        else
        begin
          Encoder.EncodeBit(IsRepG1[State], 1);
          Encoder.EncodeBit(IsRepG2[State], UInt32(Ord(RepIndex <> 2)));
        end;
        MoveRepToFront(RepIndex);
      end;
      EncodeLenSymbol(Encoder, RepLenEncoder,
        Len - TLzmaEncoderConstants.kMatchMinLen, PosState);
      State := LZMA_STATE_REP_NEXT[State];
    end;
    Inc(AbsolutePos, Len);
    Inc(Processed, Len);
  end;

  procedure EncodeOneMatch(const Len, Distance: UInt32);
  begin
    PosState := UInt32(Processed) and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 1);
    Encoder.EncodeBit(IsRep[State], 0);
    EncodeLenSymbol(Encoder, LenEncoder, Len - TLzmaEncoderConstants.kMatchMinLen, PosState);
    EncodeDistance(Encoder, PosSlot, PosDecoders, Align, Len, Distance);
    Reps[3] := Reps[2];
    Reps[2] := Reps[1];
    Reps[1] := Reps[0];
    Reps[0] := Distance;
    State := LZMA_STATE_MATCH_NEXT[State];
    Inc(AbsolutePos, Len);
    Inc(Processed, Len);
  end;

begin
  Result := False;
  SetLength(Chunks, 0);
  if (Props.Lc > 8) or (Props.Lp > 4) or (Props.Pb > 4) then
    Exit;
  if (Period = 0) or (ChunkSize = 0) or (Count = 0) then
    Exit;
  if Offset > NativeUInt(Length(Data)) then
    Exit;
  if Count > NativeUInt(Length(Data)) - Offset then
    Exit;
  if (Count div ChunkSize) > NativeUInt(High(Integer)) then
    Exit;

  InitProbArray(IsMatch, TLzmaEncoderConstants.kNumStates *
    TLzmaEncoderConstants.kNumPosStatesMax);
  InitProbArray(IsRep, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG0, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG1, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG2, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRep0Long, TLzmaEncoderConstants.kNumStates *
    TLzmaEncoderConstants.kNumPosStatesMax);
  InitProbArray(PosSlot, TLzmaEncoderConstants.kNumLenToPosStates *
    (UInt32(1) shl TLzmaEncoderConstants.kNumPosSlotBits));
  InitProbArray(PosDecoders, Length(PosDecoders));
  InitProbArray(Align, TLzmaEncoderConstants.kAlignTableSize);
  InitLenEncoder(LenEncoder);
  InitLenEncoder(RepLenEncoder);
  SetLength(Literals, $300 shl (Props.Lc + Props.Lp));
  if Length(Literals) <> 0 then
    InitProbArray(Literals[0], Length(Literals));
  PbMask := (UInt32(1) shl Props.Pb) - 1;
  LpMask := (UInt32(1) shl Props.Lp) - 1;
  LcBits := Props.Lc;
  LcShift := 8 - LcBits;
  State := 0;
  Reps[0] := 1;
  Reps[1] := 1;
  Reps[2] := 1;
  Reps[3] := 1;
  Processed := 0;
  AbsolutePos := 0;

  ChunkCount := (Count + ChunkSize - 1) div ChunkSize;
  SetLength(Chunks, Integer(ChunkCount));
  for ChunkIndex := 0 to Integer(ChunkCount) - 1 do
  begin
    ChunkEnd := AbsolutePos + ChunkSize;
    if ChunkEnd > Count then
      ChunkEnd := Count;
    Encoder := TLzmaRangeEncoder.Create;
    try
      Encoder.Init;
      while AbsolutePos < ChunkEnd do
      begin
        if NativeUInt(Period) > AbsolutePos then
          EncodeOneLiteral
        else
        begin
          LenRes := UInt32(ChunkEnd - AbsolutePos);
          if LenRes > TLzmaEncoderConstants.kMatchMaxLen then
            LenRes := TLzmaEncoderConstants.kMatchMaxLen;
          if (UnitSize <> 0) and (AbsolutePos < NativeUInt(UnitSize)) and
            (AbsolutePos + NativeUInt(LenRes) > NativeUInt(UnitSize)) then
            LenRes := UInt32(NativeUInt(UnitSize) - AbsolutePos);
          if LenRes < TLzmaEncoderConstants.kMatchMinLen then
            EncodeOneLiteral
          else if Reps[0] = ActiveDistance then
            EncodeOneRep(0, LenRes)
          else
            EncodeOneMatch(LenRes, ActiveDistance);
        end;
      end;
      Encoder.FlushData;
      Chunks[ChunkIndex] := Encoder.ToBytes;
    finally
      Encoder.Free;
    end;
  end;
  Result := True;
end;

class function TLzmaRawEncoder.EncodeGreedyChunk(const Data: TBytes; const Offset, Count: NativeUInt;
  const Props: TLzmaProps; const FastBytes: Integer; const CutValue: UInt32;
  const MatchFinderKind: TLzmaMatchFinderKind; const WriteEndMarker: Boolean;
  const EnableOptimumWindow: Boolean; const Progress: TLzma2ProgressEvent;
  const FullOptimumDecisionCount: PUInt64): TBytes;
const
  kProgressInterval = UInt64(1) shl 20;
var
  IsMatch: array[0..TLzmaEncoderConstants.kNumStates - 1,
    0..TLzmaEncoderConstants.kNumPosStatesMax - 1] of CLzmaProb;
  IsRep: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG0: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG1: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG2: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRep0Long: array[0..TLzmaEncoderConstants.kNumStates - 1,
    0..TLzmaEncoderConstants.kNumPosStatesMax - 1] of CLzmaProb;
  PosSlot: TLzmaPosSlotProbs;
  PosDecoders: TLzmaPosDecoderProbs;
  Align: TLzmaAlignProbs;
  LenEncoder: TLenEncoder;
  RepLenEncoder: TLenEncoder;
  Literals: array of CLzmaProb;
  GreedyFinder: TLzmaGreedyMatchFinder;
  Hc4Finder: TLzmaHashChain4MatchFinder;
  Hc5Finder: TLzmaHashChain5MatchFinder;
  Bt4Finder: TLzmaBinaryTree4MatchFinder;
  Encoder: TLzmaRangeEncoder;
  Pos: NativeUInt;
  Processed: UInt32;
  State: UInt32;
  Reps: array[0..3] of UInt32;
  PosState: UInt32;
  LitState: UInt32;
  LiteralOffset: NativeUInt;
  Value: Byte;
  PrevByte: Byte;
  MatchByte: Byte;
  Matches: TLzmaMatchBuffer;
  EffectiveFastBytes: UInt32;
  NumPosStates: UInt32;
  ProbPrices: TLzmaProbPrices;
  LenPrices: TLzmaLenPriceEncoder;
  RepLenPrices: TLzmaLenPriceEncoder;
  DistancePrices: TLzmaDistancePriceEncoder;
  BestRepIndex: Integer;
  BestRepLen: UInt32;
  RepLen: UInt32;
  BackRes: UInt32;
  LenRes: UInt32;
  PbMask: UInt32;
  LpMask: UInt32;
  LcBits: UInt32;
  LcShift: UInt32;
  PeriodicDistance: UInt32;
  FullOptimumState: TLzmaFullOptimumState;

type
  PLzmaLiteralProbs = ^TLzmaLiteralProbs;

var
  PricedLiteralPrice: UInt32;
  PricedShortRepPrice: UInt32;
  InsertedUntil: NativeUInt;
  MatchCache: TLzmaFastParserMatchCache;
  NextProgressAt: UInt64;
  LocalFullOptimumDecisionCount: UInt64;
  OptimumReplayCount: UInt32;
  OptimumReplayIndex: UInt32;
  OptimumReplayQueue: TArray<TLzmaOptimumDecision>;

  procedure MaybeReportProgress;
  var
    Processed64: UInt64;
  begin
    if not Assigned(Progress) then
      Exit;
    Processed64 := Processed;
    if Processed64 < NextProgressAt then
      Exit;
    ReportProgress(Progress, Processed64, 0);
    repeat
      Inc(NextProgressAt, kProgressInterval);
    until NextProgressAt > Processed64;
  end;

  function TryDetectSmallPeriodicChunk(out Period: UInt32): Boolean;
  const
    kMinPeriodicFastPathSize = NativeUInt(1) shl 16;
    kMaxPeriodicDistance = 16;
  var
    Candidate: UInt32;
    MatchLen: UInt32;
  begin
    Period := 0;
    Result := False;
    if Count < kMinPeriodicFastPathSize then
      Exit;

    for Candidate := 1 to kMaxPeriodicDistance do
    begin
      if NativeUInt(Candidate) >= Count then
        Break;

      MatchLen := LzmaCountMatchingBytes(Data, Offset, Offset + NativeUInt(Candidate),
        UInt32(Count - NativeUInt(Candidate)));
      if MatchLen = UInt32(Count - NativeUInt(Candidate)) then
      begin
        Period := Candidate;
        Exit(True);
      end;
    end;
  end;

  function NumAvailAt(const RelativePos: NativeUInt): UInt32;
  begin
    Result := UInt32(Count - RelativePos);
    if Result > TLzmaEncoderConstants.kMatchMaxLen then
      Result := TLzmaEncoderConstants.kMatchMaxLen;
  end;

  procedure ClearOptimumReplayQueue;
  begin
    OptimumReplayCount := 0;
    OptimumReplayIndex := 0;
    SetLength(OptimumReplayQueue, 0);
  end;

  function IsOptimumReplayDecisionUsable(
    const Decision: TLzmaOptimumDecision): Boolean;
  begin
    Result := False;
    if (Decision.Len = 0) or (Decision.Len > NumAvailAt(Pos)) then
      Exit;
    if Decision.Back = LZMA_OPTIMUM_BACK_LITERAL then
      Result := Decision.Len = 1
    else if Decision.Len = 1 then
      Result := Decision.Back = 0
    else
      Result := True;
  end;

  function TryPopOptimumReplayDecision(out Len, Back: UInt32): Boolean;
  var
    Decision: TLzmaOptimumDecision;
  begin
    Result := False;
    if OptimumReplayIndex >= OptimumReplayCount then
      Exit;

    Decision := OptimumReplayQueue[Integer(OptimumReplayIndex)];
    if not IsOptimumReplayDecisionUsable(Decision) then
    begin
      ClearOptimumReplayQueue;
      Exit;
    end;

    Len := Decision.Len;
    Back := Decision.Back;
    Inc(OptimumReplayIndex);
    if OptimumReplayIndex >= OptimumReplayCount then
      ClearOptimumReplayQueue;
    Result := True;
  end;

  function QueueOptimumReplayPath(const Nodes: array of TLzmaOptimumNode;
    const EndPos: UInt32; out FirstLen, FirstBack: UInt32): Boolean;
  var
    BackwardState: TLzmaOptimumBackwardState;
    DecisionCount: UInt32;
    Decisions: TArray<TLzmaOptimumDecision>;
    Index: UInt32;
  begin
    Result := False;
    FirstLen := 0;
    FirstBack := LZMA_OPTIMUM_BACK_LITERAL;
    ClearOptimumReplayQueue;

    SetLength(Decisions, Integer(EndPos));
    if not LzmaOptimumReplaySdkBackward(Nodes, EndPos, Decisions, DecisionCount,
      BackwardState) then
      Exit;
    if (DecisionCount = 0) or not IsOptimumReplayDecisionUsable(Decisions[0]) then
      Exit;
    if BackwardState.QueueCount <> DecisionCount - 1 then
      Exit;

    FirstLen := Decisions[0].Len;
    FirstBack := Decisions[0].Back;
    if DecisionCount > 1 then
    begin
      SetLength(OptimumReplayQueue, Integer(DecisionCount - 1));
      for Index := 1 to DecisionCount - 1 do
        OptimumReplayQueue[Integer(Index - 1)] := Decisions[Integer(Index)];
      OptimumReplayCount := DecisionCount - 1;
      OptimumReplayIndex := 0;
    end;

    Result := True;
  end;

  function RepLenAtPos(const RelativePos: NativeUInt; const Distance: UInt32): UInt32;
  var
    Left: NativeUInt;
    MaxLen: UInt32;
    Right: NativeUInt;
  begin
    Result := 0;
    if (Distance = 0) or (RelativePos > Count) or (NativeUInt(Distance) > RelativePos) then
      Exit;
    MaxLen := NumAvailAt(RelativePos);
    if MaxLen > TLzmaEncoderConstants.kMatchMaxLen then
      MaxLen := TLzmaEncoderConstants.kMatchMaxLen;
    if MaxLen = 0 then
      Exit;

    Left := Offset + RelativePos;
    Right := Left - NativeUInt(Distance);
    if Data[Left] <> Data[Right] then
      Exit;
    Result := 1;
    if MaxLen = 1 then
      Exit;

    if Data[Left + 1] <> Data[Right + 1] then
      Exit;
    Result := 2 + LzmaCountMatchingBytes(Data, Left + 2, Right + 2, MaxLen - 2);
  end;

  function RepLenAt(const Distance: UInt32): UInt32;
  begin
    Result := RepLenAtPos(Pos, Distance);
  end;

  procedure InsertRange(const RelativePos, RangeCount: NativeUInt);
  begin
    if Bt4Finder <> nil then
      Bt4Finder.InsertRange(RelativePos, RangeCount)
    else if Hc5Finder <> nil then
      Hc5Finder.SkipRangeMonotonic(RelativePos, RangeCount)
    else if Hc4Finder <> nil then
      Hc4Finder.InsertRange(RelativePos, RangeCount)
    else
      GreedyFinder.InsertRange(RelativePos, RangeCount);
  end;

  procedure EnsureInsertedUntil(const NewInsertedUntil: NativeUInt);
  var
    Target: NativeUInt;
  begin
    Target := NewInsertedUntil;
    if Target > Count then
      Target := Count;
    if Target <= InsertedUntil then
      Exit;

    if (Bt4Finder = nil) and (Hc5Finder = nil) and (Hc4Finder = nil) and
      (GreedyFinder = nil) then
    begin
      InsertedUntil := Target;
      Exit;
    end;

    InsertRange(InsertedUntil, Target - InsertedUntil);
    InsertedUntil := Target;
  end;

  procedure MarkInsertedUntil(const NewInsertedUntil: NativeUInt);
  var
    Target: NativeUInt;
  begin
    Target := NewInsertedUntil;
    if Target > Count then
      Target := Count;
    if InsertedUntil < Target then
      InsertedUntil := Target;
  end;

  function ReadMatchDistances(const RelativePos: NativeUInt; var MatchList: TLzmaMatchBuffer): TLzmaMatch;
  begin
    if Bt4Finder <> nil then
      Bt4Finder.GetMatches(RelativePos, MatchList)
    else if Hc5Finder <> nil then
      Hc5Finder.GetMatches(RelativePos, MatchList)
    else if Hc4Finder <> nil then
      Hc4Finder.GetMatches(RelativePos, MatchList)
    else
      GreedyFinder.GetMatches(RelativePos, MatchList);
    if MatchList.Count = 0 then
    begin
      Result.Length := 0;
      Result.Distance := 0;
    end
    else
      Result := MatchList.Last;
  end;

  function ReadMatchDistancesAndInsert(const RelativePos: NativeUInt;
    var MatchList: TLzmaMatchBuffer): TLzmaMatch;
  begin
    EnsureInsertedUntil(RelativePos);
    if Bt4Finder <> nil then
      Bt4Finder.ReadMatches(RelativePos, MatchList)
    else if Hc5Finder <> nil then
      Hc5Finder.ReadMatches(RelativePos, MatchList)
    else if Hc4Finder <> nil then
      Hc4Finder.ReadMatches(RelativePos, MatchList)
    else
      GreedyFinder.ReadMatches(RelativePos, MatchList);
    MarkInsertedUntil(RelativePos + 1);

    if MatchList.Count = 0 then
    begin
      Result.Length := 0;
      Result.Distance := 0;
    end
    else
      Result := MatchList.Last;
    if FullOptimumState.Enabled then
      LzmaFullOptimumNoteReadMatchDistances(FullOptimumState,
        NumAvailAt(RelativePos), MatchList, Result);
  end;

  function ReadCurrentMatchDistances(const RelativePos: NativeUInt;
    var MatchList: TLzmaMatchBuffer): TLzmaMatch;
  begin
    if MatchCache.TryTake(RelativePos, MatchList, Result) then
      Exit;
    Result := ReadMatchDistancesAndInsert(RelativePos, MatchList);
  end;

  function ReadLookaheadMatch(const RelativePos: NativeUInt): TLzmaMatch;
  var
    LookaheadMatches: TLzmaMatchBuffer;
  begin
    Result := ReadMatchDistancesAndInsert(RelativePos, LookaheadMatches);
    MatchCache.Store(RelativePos, LookaheadMatches, Result);
  end;

  procedure ClampMatchBufferLengths(var MatchList: TLzmaMatchBuffer; const MaxLen: UInt32);
  var
    MatchIndex: Integer;
  begin
    for MatchIndex := 0 to MatchList.Count - 1 do
    begin
      if MatchList.Items[MatchIndex].Length > MaxLen then
        MatchList.Items[MatchIndex].Length := MaxLen;
    end;
  end;

  procedure ShortenMainMatch(var MainMatch: TLzmaMatch; const MatchList: TLzmaMatchBuffer);
  var
    PairIndex: Integer;
    Candidate: TLzmaMatch;
  begin
    if MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen then
      Exit;

    PairIndex := MatchList.Count - 1;
    while PairIndex > 0 do
    begin
      Candidate := MatchList.Items[PairIndex - 1];
      if MainMatch.Length <> Candidate.Length + 1 then
        Break;
      if not ChangePair(Candidate.Distance, MainMatch.Distance) then
        Break;
      MainMatch := Candidate;
      Dec(PairIndex);
    end;

    if (MainMatch.Length = TLzmaEncoderConstants.kMatchMinLen) and
      (MainMatch.Distance - 1 >= $80) then
    begin
      MainMatch.Length := 0;
      MainMatch.Distance := 0;
    end;
  end;

  function PreferShortRepOverLiteralByPrice: Boolean;
  var
    CurrentByte: Byte;
    Nodes: array[0..1] of TLzmaOptimumNode;
    PriceMatchByte: Byte;
    PricePrevByte: Byte;
    PriceLitState: UInt32;
    PriceLiteralOffset: NativeUInt;
    PricePosState: UInt32;
    ReplayBack: UInt32;
    ReplayLen: UInt32;
    UseMatchedLiteral: Boolean;
  begin
    Result := False;
    CurrentByte := Data[Offset + Pos];
    if Pos = 0 then
      PricePrevByte := 0
    else
      PricePrevByte := Data[Offset + Pos - 1];

    PriceLitState := ((Processed and LpMask) shl LcBits) +
      (UInt32(PricePrevByte) shr LcShift);
    PriceLiteralOffset := NativeUInt(PriceLitState) * LZMA_LITERAL_PROB_COUNT;
    PricePosState := Processed and PbMask;
    UseMatchedLiteral := (State >= TLzmaEncoderConstants.kNumLitStates) and (Reps[0] <= Pos);
    if UseMatchedLiteral then
      PriceMatchByte := Data[Offset + Pos - Reps[0]]
    else
      PriceMatchByte := 0;

    LzmaOptimumPrepareNodes(Nodes, 0, State, Reps);

    if not LzmaOptimumRelaxLiteralCandidate(Nodes, 0, ProbPrices,
      PLzmaLiteralProbs(@Literals[PriceLiteralOffset])^, IsMatch[State][PricePosState],
      CurrentByte, UseMatchedLiteral, PriceMatchByte, PricedLiteralPrice) then
      Exit;

    LzmaOptimumRelaxShortRepCandidate(Nodes, 0, ProbPrices, IsMatch[State][PricePosState],
      IsRep[State], IsRepG0[State], IsRep0Long[State][PricePosState], PricedShortRepPrice);

    Result := LzmaOptimumReplayFirstDecision(Nodes, 1, ReplayLen, ReplayBack) and
      (ReplayLen = 1) and (ReplayBack = 0);
  end;

  procedure RefreshOptimumPriceTables;
  begin
    LzmaUpdateLenPriceEncoder(LenPrices, LenEncoder.Low, LenEncoder.High, NumPosStates, ProbPrices);
    LzmaUpdateLenPriceEncoder(RepLenPrices, RepLenEncoder.Low, RepLenEncoder.High, NumPosStates, ProbPrices);
    LzmaUpdateDistancePriceEncoder(DistancePrices, PosSlot, PosDecoders, Align, ProbPrices);
  end;

  function PreferRepOverMainByPrice(const MainMatch: TLzmaMatch): Boolean;
  var
    MatchCandidates: TLzmaMatchBuffer;
    MatchNodes: array of TLzmaOptimumNode;
    MatchPrice: UInt32;
    MaxCandidateLen: UInt32;
    PricePosState: UInt32;
    RepLens: array[0..3] of UInt32;
    RepNodes: array of TLzmaOptimumNode;
    RepPrice: UInt32;
    ReplayBack: UInt32;
    ReplayLen: UInt32;
  begin
    Result := False;
    if (BestRepIndex < 0) or (BestRepLen < TLzmaEncoderConstants.kMatchMinLen) or
      (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) then
      Exit;
    if BestRepIndex > High(RepLens) then
      Exit;

    RefreshOptimumPriceTables;
    PricePosState := Processed and PbMask;
    MaxCandidateLen := MainMatch.Length;
    if BestRepLen > MaxCandidateLen then
      MaxCandidateLen := BestRepLen;

    SetLength(RepNodes, Integer(MaxCandidateLen) + 1);
    SetLength(MatchNodes, Integer(MaxCandidateLen) + 1);
    LzmaOptimumPrepareNodes(RepNodes, 0, State, Reps);
    LzmaOptimumPrepareNodes(MatchNodes, 0, State, Reps);

    FillChar(RepLens, SizeOf(RepLens), 0);
    RepLens[BestRepIndex] := BestRepLen;
    if not LzmaOptimumRelaxRepCandidates(RepNodes, 0, RepLens, ProbPrices,
      RepLenPrices, IsMatch[State][PricePosState], IsRep[State], IsRepG0[State],
      IsRepG1[State], IsRepG2[State], IsRep0Long[State][PricePosState],
      PricePosState, RepPrice) then
      Exit;
    RepPrice := RepNodes[Integer(BestRepLen)].Price;
    if RepPrice = High(UInt32) then
      Exit;

    MatchCandidates.Clear;
    MatchCandidates.Add(MainMatch.Length, MainMatch.Distance);
    if not LzmaOptimumRelaxMatchCandidates(MatchNodes, 0, MatchCandidates,
      ProbPrices, LenPrices, DistancePrices, IsMatch[State][PricePosState],
      IsRep[State], PricePosState, MainMatch.Length, MainMatch.Length,
      MatchPrice) then
      Exit;
    MatchPrice := MatchNodes[Integer(MainMatch.Length)].Price;
    if MatchPrice = High(UInt32) then
      Exit;

    if RepPrice <= MatchPrice then
    begin
      Result := LzmaOptimumReplayFirstDecision(RepNodes, BestRepLen, ReplayLen,
        ReplayBack) and (ReplayLen = BestRepLen) and
        (ReplayBack = UInt32(BestRepIndex));
      Exit;
    end;

    LzmaOptimumReplayFirstDecision(MatchNodes, MainMatch.Length, ReplayLen, ReplayBack);
  end;

  function PreferLiteralThenNextMatchByPrice(const MainMatch, NextMatch: TLzmaMatch): Boolean;
  var
    CurrentByte: Byte;
    LiteralEnd: UInt32;
    LiteralThenMatchPrice: UInt32;
    MainMatchCandidates: TLzmaMatchBuffer;
    MainNodes: array of TLzmaOptimumNode;
    MatchCandidates: TLzmaMatchBuffer;
    MatchByteForLiteral: Byte;
    MatchNodes: array of TLzmaOptimumNode;
    MatchPrice: UInt32;
    NextPosState: UInt32;
    NextState: UInt32;
    PriceLitState: UInt32;
    PriceLiteralOffset: NativeUInt;
    PricePosState: UInt32;
    PricePrevByte: Byte;
    ReplayBack: UInt32;
    ReplayLen: UInt32;
    UseMatchedLiteral: Boolean;
  begin
    Result := False;
    if (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) or
      (NextMatch.Length < TLzmaEncoderConstants.kMatchMinLen) or
      (MainMatch.Length > EffectiveFastBytes) or (NextMatch.Length > EffectiveFastBytes) or
      (Pos + 1 >= Count) then
      Exit;

    RefreshOptimumPriceTables;
    CurrentByte := Data[Offset + Pos];
    if Pos = 0 then
      PricePrevByte := 0
    else
      PricePrevByte := Data[Offset + Pos - 1];

    PriceLitState := ((Processed and LpMask) shl LcBits) +
      (UInt32(PricePrevByte) shr LcShift);
    PriceLiteralOffset := NativeUInt(PriceLitState) * LZMA_LITERAL_PROB_COUNT;
    PricePosState := Processed and PbMask;
    NextPosState := (Processed + 1) and PbMask;
    NextState := LZMA_STATE_LITERAL_NEXT[State];
    UseMatchedLiteral := (State >= TLzmaEncoderConstants.kNumLitStates) and (Reps[0] <= Pos);
    if UseMatchedLiteral then
      MatchByteForLiteral := Data[Offset + Pos - Reps[0]]
    else
      MatchByteForLiteral := 0;

    SetLength(MainNodes, Integer(MainMatch.Length) + 1);
    LzmaOptimumPrepareNodes(MainNodes, 0, State, Reps);
    MainMatchCandidates.Clear;
    MainMatchCandidates.Add(MainMatch.Length, MainMatch.Distance);
    if not LzmaOptimumRelaxMatchCandidates(MainNodes, 0, MainMatchCandidates,
      ProbPrices, LenPrices, DistancePrices, IsMatch[State][PricePosState],
      IsRep[State], PricePosState, MainMatch.Length, MainMatch.Length,
      MatchPrice) then
      Exit;
    MatchPrice := MainNodes[Integer(MainMatch.Length)].Price;
    if MatchPrice = High(UInt32) then
      Exit;

    LiteralEnd := 1 + NextMatch.Length;
    SetLength(MatchNodes, Integer(LiteralEnd) + 1);
    LzmaOptimumPrepareNodes(MatchNodes, 0, State, Reps);

    if not LzmaOptimumRelaxLiteralCandidate(MatchNodes, 0, ProbPrices,
      PLzmaLiteralProbs(@Literals[PriceLiteralOffset])^, IsMatch[State][PricePosState],
      CurrentByte, UseMatchedLiteral, MatchByteForLiteral, LiteralThenMatchPrice) then
      Exit;

    MatchCandidates.Clear;
    MatchCandidates.Add(NextMatch.Length, NextMatch.Distance);
    if not LzmaOptimumRelaxMatchCandidates(MatchNodes, 1, MatchCandidates,
      ProbPrices, LenPrices, DistancePrices, IsMatch[NextState][NextPosState],
      IsRep[NextState], NextPosState, NextMatch.Length, NextMatch.Length,
      LiteralThenMatchPrice) then
      Exit;
    LiteralThenMatchPrice := MatchNodes[Integer(LiteralEnd)].Price;
    if LiteralThenMatchPrice = High(UInt32) then
      Exit;

    if LiteralThenMatchPrice < MatchPrice then
      Result := LzmaOptimumReplayFirstDecision(MatchNodes, LiteralEnd, ReplayLen,
        ReplayBack) and (ReplayLen = 1) and (ReplayBack = LZMA_OPTIMUM_BACK_LITERAL);
  end;

  function PreferLiteralThenNextRepByPrice(const MainMatch: TLzmaMatch;
    const NextRepIndex, NextRepLen: UInt32): Boolean;
  var
    CurrentByte: Byte;
    LiteralEnd: UInt32;
    LiteralThenRepPrice: UInt32;
    MainMatchCandidates: TLzmaMatchBuffer;
    MainNodes: array of TLzmaOptimumNode;
    MatchByteForLiteral: Byte;
    MatchPrice: UInt32;
    NextPosState: UInt32;
    NextState: UInt32;
    PriceLitState: UInt32;
    PriceLiteralOffset: NativeUInt;
    PricePosState: UInt32;
    PricePrevByte: Byte;
    RepLens: array[0..3] of UInt32;
    RepNodes: array of TLzmaOptimumNode;
    ReplayBack: UInt32;
    ReplayLen: UInt32;
    UseMatchedLiteral: Boolean;
  begin
    Result := False;
    if (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) or
      (NextRepLen < TLzmaEncoderConstants.kMatchMinLen) or
      (MainMatch.Length > EffectiveFastBytes) or (NextRepLen > EffectiveFastBytes) or
      (Pos + 1 >= Count) then
      Exit;
    if NextRepIndex > UInt32(High(RepLens)) then
      Exit;

    RefreshOptimumPriceTables;
    CurrentByte := Data[Offset + Pos];
    if Pos = 0 then
      PricePrevByte := 0
    else
      PricePrevByte := Data[Offset + Pos - 1];

    PriceLitState := ((Processed and LpMask) shl LcBits) +
      (UInt32(PricePrevByte) shr LcShift);
    PriceLiteralOffset := NativeUInt(PriceLitState) * LZMA_LITERAL_PROB_COUNT;
    PricePosState := Processed and PbMask;
    NextPosState := (Processed + 1) and PbMask;
    NextState := LZMA_STATE_LITERAL_NEXT[State];
    UseMatchedLiteral := (State >= TLzmaEncoderConstants.kNumLitStates) and (Reps[0] <= Pos);
    if UseMatchedLiteral then
      MatchByteForLiteral := Data[Offset + Pos - Reps[0]]
    else
      MatchByteForLiteral := 0;

    SetLength(MainNodes, Integer(MainMatch.Length) + 1);
    LzmaOptimumPrepareNodes(MainNodes, 0, State, Reps);
    MainMatchCandidates.Clear;
    MainMatchCandidates.Add(MainMatch.Length, MainMatch.Distance);
    if not LzmaOptimumRelaxMatchCandidates(MainNodes, 0, MainMatchCandidates,
      ProbPrices, LenPrices, DistancePrices, IsMatch[State][PricePosState],
      IsRep[State], PricePosState, MainMatch.Length, MainMatch.Length,
      MatchPrice) then
      Exit;
    MatchPrice := MainNodes[Integer(MainMatch.Length)].Price;
    if MatchPrice = High(UInt32) then
      Exit;

    LiteralEnd := 1 + NextRepLen;
    SetLength(RepNodes, Integer(LiteralEnd) + 1);
    LzmaOptimumPrepareNodes(RepNodes, 0, State, Reps);

    if not LzmaOptimumRelaxLiteralCandidate(RepNodes, 0, ProbPrices,
      PLzmaLiteralProbs(@Literals[PriceLiteralOffset])^, IsMatch[State][PricePosState],
      CurrentByte, UseMatchedLiteral, MatchByteForLiteral, LiteralThenRepPrice) then
      Exit;

    FillChar(RepLens, SizeOf(RepLens), 0);
    RepLens[NextRepIndex] := NextRepLen;
    if not LzmaOptimumRelaxRepCandidates(RepNodes, 1, RepLens, ProbPrices,
      RepLenPrices, IsMatch[NextState][NextPosState], IsRep[NextState],
      IsRepG0[NextState], IsRepG1[NextState], IsRepG2[NextState],
      IsRep0Long[NextState][NextPosState], NextPosState, LiteralThenRepPrice) then
      Exit;
    LiteralThenRepPrice := RepNodes[Integer(LiteralEnd)].Price;
    if LiteralThenRepPrice = High(UInt32) then
      Exit;

    if LiteralThenRepPrice < MatchPrice then
      Result := LzmaOptimumReplayFirstDecision(RepNodes, LiteralEnd, ReplayLen,
        ReplayBack) and (ReplayLen = 1) and (ReplayBack = LZMA_OPTIMUM_BACK_LITERAL);
  end;

  function PreferMatchLiteralRep0ByPrice(var MainMatch: TLzmaMatch;
    const MatchList: TLzmaMatchBuffer): Boolean;
  var
    BestCandidate: TLzmaMatch;
    BestPrice: UInt32;
    Candidate: TLzmaMatch;
    CandidateEnd: UInt32;
    CandidateIndex: Integer;
    CandidatePathPrice: UInt32;
    CurrentMatchPrice: UInt32;
    LiteralByte: Byte;
    LiteralMatchByte: Byte;
    LiteralPos: NativeUInt;
    LiteralPosState: UInt32;
    LiteralState: UInt32;
    MatchPosState: UInt32;
    MatchState: UInt32;
    Nodes: array of TLzmaOptimumNode;
    PriceLiteralOffset: NativeUInt;
    PriceLitState: UInt32;
    PricePrevByte: Byte;
    ReplayBack: UInt32;
    ReplayLen: UInt32;
    RepLenAfterLiteral: UInt32;
    RepPosState: UInt32;
    UseMatchedLiteral: Boolean;

    function PriceCurrentMatchByRelax(const CurrentMatch: TLzmaMatch;
      const CurrentState, CurrentPosState: UInt32): UInt32;
    var
      MatchCandidates: TLzmaMatchBuffer;
      MatchNodes: array of TLzmaOptimumNode;
      RelaxedPrice: UInt32;
    begin
      Result := High(UInt32);
      if CurrentMatch.Length < TLzmaEncoderConstants.kMatchMinLen then
        Exit;

      SetLength(MatchNodes, Integer(CurrentMatch.Length) + 1);
      LzmaOptimumPrepareNodes(MatchNodes, 0, CurrentState, Reps);

      MatchCandidates.Clear;
      MatchCandidates.Add(CurrentMatch.Length, CurrentMatch.Distance);
      if LzmaOptimumRelaxMatchCandidates(MatchNodes, 0, MatchCandidates,
        ProbPrices, LenPrices, DistancePrices, IsMatch[CurrentState][CurrentPosState],
        IsRep[CurrentState], CurrentPosState, CurrentMatch.Length, CurrentMatch.Length,
        RelaxedPrice) then
        Result := MatchNodes[Integer(CurrentMatch.Length)].Price;
    end;

  begin
    Result := False;
    if (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) or (MatchList.Count <= 1) then
      Exit;

    RefreshOptimumPriceTables;
    BestPrice := High(UInt32);
    BestCandidate.Length := 0;
    BestCandidate.Distance := 0;
    MatchPosState := Processed and PbMask;
    MatchState := LZMA_STATE_MATCH_NEXT[State];
    LiteralState := LZMA_STATE_LITERAL_NEXT[MatchState];

    for CandidateIndex := 0 to MatchList.Count - 1 do
    begin
      Candidate := MatchList.Items[CandidateIndex];
      if (Candidate.Length < TLzmaEncoderConstants.kMatchMinLen) or
        (Candidate.Length >= MainMatch.Length) or (Candidate.Length > EffectiveFastBytes) then
        Continue;

      LiteralPos := Pos + Candidate.Length;
      if (LiteralPos + 1 >= Count) or (Candidate.Distance = 0) or (Candidate.Distance > LiteralPos) then
        Continue;

      RepLenAfterLiteral := RepLenAtPos(LiteralPos + 1, Candidate.Distance);
      if (RepLenAfterLiteral < TLzmaEncoderConstants.kMatchMinLen) or
        (RepLenAfterLiteral > EffectiveFastBytes) then
        Continue;

      LiteralByte := Data[Offset + LiteralPos];
      PricePrevByte := Data[Offset + LiteralPos - 1];
      PriceLitState := (((Processed + Candidate.Length) and LpMask) shl LcBits) +
        (UInt32(PricePrevByte) shr LcShift);
      PriceLiteralOffset := NativeUInt(PriceLitState) * LZMA_LITERAL_PROB_COUNT;
      LiteralPosState := (Processed + Candidate.Length) and PbMask;
      RepPosState := (Processed + Candidate.Length + 1) and PbMask;
      UseMatchedLiteral := MatchState >= TLzmaEncoderConstants.kNumLitStates;
      if UseMatchedLiteral then
        LiteralMatchByte := Data[Offset + LiteralPos - Candidate.Distance]
      else
        LiteralMatchByte := 0;

      CurrentMatchPrice := PriceCurrentMatchByRelax(MainMatch, State, MatchPosState);
      if CurrentMatchPrice = High(UInt32) then
        Continue;

      CandidateEnd := Candidate.Length + 1 + RepLenAfterLiteral;
      SetLength(Nodes, Integer(CandidateEnd) + 1);
      LzmaOptimumPrepareNodes(Nodes, 0, State, Reps);
      Nodes[Integer(CandidateEnd)].Price := CurrentMatchPrice;

      if LzmaOptimumRelaxMatchLiteralRep0Candidate(Nodes, 0, ProbPrices,
        PLzmaLiteralProbs(@Literals[PriceLiteralOffset])^, LenPrices, RepLenPrices,
        DistancePrices, IsMatch[State][MatchPosState], IsRep[State],
        IsMatch[MatchState][LiteralPosState], IsMatch[LiteralState][RepPosState],
        IsRep[LiteralState], IsRepG0[LiteralState], IsRep0Long[LiteralState][RepPosState],
        MatchPosState, LiteralPosState, RepPosState, LiteralByte, UseMatchedLiteral,
        LiteralMatchByte, Candidate.Length, Candidate.Distance, RepLenAfterLiteral,
        CandidatePathPrice) and
        LzmaOptimumReplayFirstDecision(Nodes, CandidateEnd, ReplayLen, ReplayBack) and
        (ReplayBack >= 3) and (ReplayLen >= TLzmaEncoderConstants.kMatchMinLen) and
        (CandidatePathPrice < BestPrice) then
      begin
        BestPrice := CandidatePathPrice;
        BestCandidate.Length := ReplayLen;
        BestCandidate.Distance := ReplayBack - 3;
      end;
    end;

    if BestCandidate.Length <> 0 then
    begin
      MainMatch := BestCandidate;
      Result := True;
    end;
  end;

  function PreferLiteralLookahead(const MainMatch: TLzmaMatch): Boolean;
  var
    NextMatch: TLzmaMatch;
    I: Integer;
    LookaheadRepLen: UInt32;
  begin
    Result := False;
    if (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) or
      (NumAvailAt(Pos) <= TLzmaEncoderConstants.kMatchMinLen) or (Pos + 1 >= Count) then
      Exit;

    NextMatch := ReadLookaheadMatch(Pos + 1);
    if NextMatch.Length >= TLzmaEncoderConstants.kMatchMinLen then
    begin
      if PreferLiteralThenNextMatchByPrice(MainMatch, NextMatch) then
        Exit(True);
    end;

    for I := 0 to 3 do
    begin
      LookaheadRepLen := RepLenAtPos(Pos + 1, Reps[I]);
      if PreferLiteralThenNextRepByPrice(MainMatch, UInt32(I), LookaheadRepLen) then
        Exit(True);
    end;
  end;

  function GetOptimumWindowLimit: UInt32;
  begin
    Result := LZMA_FULL_OPTIMUM_NUM_OPTS - 1;
  end;

  function TryGetOptimumWindowDecision(const MainMatch: TLzmaMatch;
    out WindowLen, WindowBack: UInt32): Boolean;
  var
    BaselineCandidates: TLzmaMatchBuffer;
    BaselineNodes: TArray<TLzmaOptimumNode>;
    BaselineRepLens: TLzmaOptimumRepLens;
    BestBaselinePrice: UInt32;
    BaselinePrice: UInt32;
    LiteralResolver: TLzmaOptimumLiteralResolver;
    LookaheadMatch: TLzmaMatch;
    MatchesByPos: TArray<TLzmaMatchBuffer>;
    Nodes: TArray<TLzmaOptimumNode>;
    PosIndex: Integer;
    PosStates: TArray<UInt32>;
    ProbInputsByPos: TArray<TLzmaOptimumStateProbInputs>;
    ProbState: Integer;
    RelativePos: NativeUInt;
    RepBaselineNodes: TArray<TLzmaOptimumNode>;
    RepBaselinePrice: UInt32;
    RepResolver: TLzmaOptimumRepLensResolver;
    InitialTargetEnd: UInt32;
    OptimumWindowLimit: UInt32;
    ReplayBack: UInt32;
    ReplayLen: UInt32;
    TargetEnd: UInt32;
    WindowEnd: UInt32;
    WindowPrice: UInt32;
  begin
    Result := False;
    WindowLen := 0;
    WindowBack := LZMA_OPTIMUM_BACK_LITERAL;

    OptimumWindowLimit := GetOptimumWindowLimit;
    if (not EnableOptimumWindow) or
      (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) or
      (MainMatch.Length >= EffectiveFastBytes) then
      Exit;

    InitialTargetEnd := MainMatch.Length;
    WindowEnd := OptimumWindowLimit;
    if WindowEnd > NumAvailAt(Pos) then
      WindowEnd := NumAvailAt(Pos);
    if InitialTargetEnd > WindowEnd then
      Exit;

    RefreshOptimumPriceTables;

    SetLength(BaselineNodes, Integer(InitialTargetEnd) + 1);
    LzmaOptimumPrepareNodes(BaselineNodes, 0, State, Reps);
    BaselineCandidates.Clear;
    BaselineCandidates.Add(MainMatch.Length, MainMatch.Distance);
    if not LzmaOptimumRelaxMatchCandidates(BaselineNodes, 0, BaselineCandidates,
      ProbPrices, LenPrices, DistancePrices, IsMatch[State][Processed and PbMask],
      IsRep[State], Processed and PbMask, MainMatch.Length, MainMatch.Length,
      BaselinePrice) then
      Exit;
    BaselinePrice := BaselineNodes[Integer(InitialTargetEnd)].Price;
    if BaselinePrice = High(UInt32) then
      Exit;
    BestBaselinePrice := BaselinePrice;

    if (BestRepIndex >= 0) and
      (BestRepIndex <= High(BaselineRepLens)) and
      (BestRepLen >= TLzmaEncoderConstants.kMatchMinLen) then
    begin
      FillChar(BaselineRepLens, SizeOf(BaselineRepLens), 0);
      BaselineRepLens[BestRepIndex] := BestRepLen;
      SetLength(RepBaselineNodes, Integer(BestRepLen) + 1);
      LzmaOptimumPrepareNodes(RepBaselineNodes, 0, State, Reps);
      if LzmaOptimumRelaxRepCandidates(RepBaselineNodes, 0,
        BaselineRepLens, ProbPrices, RepLenPrices,
        IsMatch[State][Processed and PbMask], IsRep[State], IsRepG0[State],
        IsRepG1[State], IsRepG2[State], IsRep0Long[State][Processed and PbMask],
        Processed and PbMask, RepBaselinePrice) then
      begin
        RepBaselinePrice := RepBaselineNodes[Integer(BestRepLen)].Price;
        if RepBaselinePrice < BestBaselinePrice then
          BestBaselinePrice := RepBaselinePrice;
      end;
    end;

    SetLength(Nodes, Integer(WindowEnd) + 1);
    SetLength(MatchesByPos, Integer(WindowEnd) + 1);
    SetLength(PosStates, Integer(WindowEnd) + 1);
    SetLength(ProbInputsByPos, Integer(WindowEnd) + 1);
    LzmaOptimumPrepareNodes(Nodes, 0, State, Reps);

    for PosIndex := 0 to Integer(WindowEnd) - 1 do
    begin
      RelativePos := Pos + NativeUInt(PosIndex);
      PosStates[PosIndex] := (Processed + UInt32(PosIndex)) and PbMask;

      for ProbState := 0 to TLzmaEncoderConstants.kNumStates - 1 do
      begin
        ProbInputsByPos[PosIndex][ProbState].IsMatchProb :=
          IsMatch[ProbState][PosStates[PosIndex]];
        ProbInputsByPos[PosIndex][ProbState].IsRepProb := IsRep[ProbState];
        ProbInputsByPos[PosIndex][ProbState].IsRepG0Prob := IsRepG0[ProbState];
        ProbInputsByPos[PosIndex][ProbState].IsRepG1Prob := IsRepG1[ProbState];
        ProbInputsByPos[PosIndex][ProbState].IsRepG2Prob := IsRepG2[ProbState];
        ProbInputsByPos[PosIndex][ProbState].IsRep0LongProb :=
          IsRep0Long[ProbState][PosStates[PosIndex]];
      end;

      if PosIndex = 0 then
      begin
        MatchesByPos[PosIndex] := Matches;
        ClampMatchBufferLengths(MatchesByPos[PosIndex], EffectiveFastBytes);
      end
      else
      begin
        LookaheadMatch := ReadMatchDistancesAndInsert(RelativePos, MatchesByPos[PosIndex]);
        ClampMatchBufferLengths(MatchesByPos[PosIndex], EffectiveFastBytes);
        if LookaheadMatch.Length > EffectiveFastBytes then
          LookaheadMatch.Length := EffectiveFastBytes;
        MatchCache.Store(RelativePos, MatchesByPos[PosIndex], LookaheadMatch);
      end;
    end;

    LiteralResolver :=
      function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
        out LiteralInput: TLzmaOptimumLiteralInput): Boolean
      var
        MatchByteForLiteral: Byte;
        PriceLitState: UInt32;
        PriceLiteralOffset: NativeUInt;
        PricePrevByte: Byte;
        LiteralRelativePos: NativeUInt;
        UseMatchedLiteral: Boolean;
      begin
        FillChar(LiteralInput, SizeOf(LiteralInput), 0);
        LiteralRelativePos := Pos + NativeUInt(WindowPos);
        Result := LiteralRelativePos < Count;
        if not Result then
          Exit;

        if LiteralRelativePos = 0 then
          PricePrevByte := 0
        else
          PricePrevByte := Data[Offset + LiteralRelativePos - 1];
        PriceLitState := (((Processed + WindowPos) and LpMask) shl LcBits) +
          (UInt32(PricePrevByte) shr LcShift);
        PriceLiteralOffset := NativeUInt(PriceLitState) * LZMA_LITERAL_PROB_COUNT;
        UseMatchedLiteral := (Node.State >= TLzmaEncoderConstants.kNumLitStates) and
          (Node.Reps[0] > 0) and (NativeUInt(Node.Reps[0]) <= LiteralRelativePos);
        if UseMatchedLiteral then
          MatchByteForLiteral := Data[Offset + LiteralRelativePos - NativeUInt(Node.Reps[0])]
        else
          MatchByteForLiteral := 0;

        LiteralInput.Enabled := True;
        LiteralInput.LiteralProbs :=
          PLzmaLiteralProbs(@Literals[PriceLiteralOffset])^;
        LiteralInput.Value := Data[Offset + LiteralRelativePos];
        LiteralInput.UseMatchedLiteral := UseMatchedLiteral;
        LiteralInput.MatchByte := MatchByteForLiteral;
      end;

    RepResolver :=
      procedure(const WindowPos: UInt32; const NodeReps: TLzmaOptimumReps;
        out RepLens: TLzmaOptimumRepLens)
      var
        Left: NativeUInt;
        MaxLen: UInt32;
        RepDistance: UInt32;
        RepIndex: Integer;
        RepRelativePos: NativeUInt;
        Right: NativeUInt;
      begin
        FillChar(RepLens, SizeOf(RepLens), 0);
        RepRelativePos := Pos + NativeUInt(WindowPos);
        for RepIndex := Low(NodeReps) to High(NodeReps) do
        begin
          RepDistance := NodeReps[RepIndex];
          if (RepDistance = 0) or (RepRelativePos > Count) or
            (NativeUInt(RepDistance) > RepRelativePos) then
            Continue;

          MaxLen := UInt32(Count - RepRelativePos);
          if MaxLen > TLzmaEncoderConstants.kMatchMaxLen then
            MaxLen := TLzmaEncoderConstants.kMatchMaxLen;
          if MaxLen = 0 then
            Continue;

          Left := Offset + RepRelativePos;
          Right := Left - NativeUInt(RepDistance);
          if Data[Left] <> Data[Right] then
            Continue;
          RepLens[RepIndex] := 1;
          if MaxLen = 1 then
            Continue;

          if Data[Left + 1] <> Data[Right + 1] then
            Continue;
          RepLens[RepIndex] := 2 + LzmaCountMatchingBytes(Data, Left + 2,
            Right + 2, MaxLen - 2);
          if RepLens[RepIndex] > EffectiveFastBytes then
            RepLens[RepIndex] := EffectiveFastBytes;
        end;
      end;

    if not LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
      LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPrices,
      RepLenPrices, DistancePrices) then
      Exit;

    if not LzmaOptimumSelectWindowTarget(Nodes, InitialTargetEnd, WindowEnd,
      BestBaselinePrice, TargetEnd, WindowPrice) then
      Exit;
    if (TargetEnd > EffectiveFastBytes) and (Nodes[Integer(TargetEnd)].Extra = 0) then
      Exit;

    if not QueueOptimumReplayPath(Nodes, TargetEnd, ReplayLen, ReplayBack) then
      Exit;
    if ReplayBack = LZMA_OPTIMUM_BACK_LITERAL then
    begin
      ClearOptimumReplayQueue;
      Exit;
    end;
    if ReplayLen <= MainMatch.Length then
    begin
      ClearOptimumReplayQueue;
      Exit;
    end;

    WindowLen := ReplayLen;
    WindowBack := ReplayBack;
    Result := WindowLen > 0;
  end;

  function GetOptimumFast(out Back: UInt32): UInt32;
  const
    MARK_LIT = UInt32($FFFFFFFF);
  var
    MainMatch: TLzmaMatch;
    NumAvail: UInt32;
    I: UInt32;
    WindowBack: UInt32;
    WindowLen: UInt32;
  begin
    Back := MARK_LIT;
    Result := 1;
    if TryPopOptimumReplayDecision(Result, Back) then
      Exit;

    NumAvail := NumAvailAt(Pos);
    if NumAvail < TLzmaEncoderConstants.kMatchMinLen then
      Exit;

    BestRepIndex := -1;
    BestRepLen := 0;
    for I := 0 to 3 do
    begin
      RepLen := RepLenAt(Reps[I]);
      if RepLen >= EffectiveFastBytes then
      begin
        Back := I;
        Exit(RepLen);
      end;
      if RepLen > BestRepLen then
      begin
        BestRepLen := RepLen;
        BestRepIndex := Integer(I);
      end;
    end;

    MainMatch := ReadCurrentMatchDistances(Pos, Matches);
    if MainMatch.Length >= EffectiveFastBytes then
    begin
      Back := MainMatch.Distance + 3;
      Exit(MainMatch.Length);
    end;

    ShortenMainMatch(MainMatch, Matches);
    if (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) or
      (NumAvail <= TLzmaEncoderConstants.kMatchMinLen) then
    begin
      if (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) and
        (BestRepLen >= TLzmaEncoderConstants.kMatchMinLen) and (BestRepIndex >= 0) then
      begin
        Back := UInt32(BestRepIndex);
        Exit(BestRepLen);
      end;

      if (BestRepLen = 1) and (BestRepIndex = 0) then
      begin
        if PreferShortRepOverLiteralByPrice then
        begin
          Back := 0;
          Exit(1);
        end;
      end;
      Exit(1);
    end;

    if TryGetOptimumWindowDecision(MainMatch, WindowLen, WindowBack) then
    begin
      Back := WindowBack;
      Exit(WindowLen);
    end;

    if PreferLiteralLookahead(MainMatch) then
      Exit(1);

    PreferMatchLiteralRep0ByPrice(MainMatch, Matches);

    if PreferRepOverMainByPrice(MainMatch) then
    begin
      Back := UInt32(BestRepIndex);
      Exit(BestRepLen);
    end;

    Back := MainMatch.Distance + 3;
    Result := MainMatch.Length;
  end;

  function GetOptimumFull(out Back: UInt32): UInt32;
  const
    MARK_LIT = UInt32($FFFFFFFF);
  var
    MainLen: UInt32;
    NumAvail: UInt32;
    NumPairs: UInt32;
    MainMatch: TLzmaMatch;
    NeedsFreshRead: Boolean;

    function TryBuildFullOptimumPath(out PathLen, PathBack: UInt32): Boolean;
    var
      LiteralResolver: TLzmaOptimumLiteralResolver;
      LookaheadMatch: TLzmaMatch;
      MatchesByPos: TArray<TLzmaMatchBuffer>;
      PosIndex: Integer;
      PosStates: TArray<UInt32>;
      ProbInputsByPos: TArray<TLzmaOptimumStateProbInputs>;
      ProbState: Integer;
      RelativePos: NativeUInt;
      RepResolver: TLzmaOptimumRepLensResolver;
      TargetEnd: UInt32;
      WindowEnd: UInt32;

      function SelectReplayTarget(const MaxTarget: UInt32): UInt32;
      var
        Candidate: UInt32;
        Node: TLzmaOptimumNode;
      begin
        Result := 0;
        if Length(FullOptimumState.Nodes) <= 1 then
          Exit;

        Candidate := MaxTarget;
        if Candidate >= UInt32(Length(FullOptimumState.Nodes)) then
          Candidate := UInt32(Length(FullOptimumState.Nodes) - 1);
        while Candidate > 1 do
        begin
          Node := FullOptimumState.Nodes[Integer(Candidate)];
          if (Node.Price <> High(UInt32)) and (Node.Extra = 0) and
            ((Node.PathBack <> LZMA_OPTIMUM_BACK_LITERAL) or
             (Node.PathLen > 1) or Node.Prev1IsLiteral) then
            Exit(Candidate);
          Dec(Candidate);
        end;

        if FullOptimumState.Nodes[1].Price <> High(UInt32) then
          Result := 1;
      end;

      function ReplayPathIsValid(const FirstLen, FirstBack: UInt32): Boolean;
      var
        Decision: TLzmaOptimumDecision;
        DecisionIndex: UInt32;
        Distance: UInt32;
        RepIndex: Integer;
        SimPos: NativeUInt;
        SimReps: array[0..3] of UInt32;

        procedure MoveSimRepToFront(const Index: Integer);
        var
          I: Integer;
          Value: UInt32;
        begin
          if Index <= 0 then
            Exit;
          Value := SimReps[Index];
          for I := Index downto 1 do
            SimReps[I] := SimReps[I - 1];
          SimReps[0] := Value;
        end;

        function AcceptDecision(const DecisionLen, DecisionBack: UInt32): Boolean;
        var
          Left: NativeUInt;
          Right: NativeUInt;
        begin
          Result := False;
          if (DecisionLen = 0) or (SimPos + NativeUInt(DecisionLen) > Count) then
            Exit;
          if DecisionBack = LZMA_OPTIMUM_BACK_LITERAL then
          begin
            Result := DecisionLen = 1;
            if Result then
              Inc(SimPos);
            Exit;
          end;

          if DecisionBack < 4 then
          begin
            RepIndex := Integer(DecisionBack);
            Distance := SimReps[RepIndex];
            if (Distance = 0) or (NativeUInt(Distance) > SimPos) then
              Exit;
            Left := Offset + SimPos;
            Right := Left - NativeUInt(Distance);
            if LzmaCountMatchingBytes(Data, Left, Right, DecisionLen) <> DecisionLen then
              Exit;
            MoveSimRepToFront(RepIndex);
            Inc(SimPos, DecisionLen);
            Exit(True);
          end;

          Distance := DecisionBack - 3;
          if (Distance = 0) or (NativeUInt(Distance) > SimPos) then
            Exit;
          Left := Offset + SimPos;
          Right := Left - NativeUInt(Distance);
          if LzmaCountMatchingBytes(Data, Left, Right, DecisionLen) <> DecisionLen then
            Exit;
          SimReps[3] := SimReps[2];
          SimReps[2] := SimReps[1];
          SimReps[1] := SimReps[0];
          SimReps[0] := Distance;
          Inc(SimPos, DecisionLen);
          Result := True;
        end;

      begin
        SimPos := Pos;
        for RepIndex := 0 to 3 do
          SimReps[RepIndex] := Reps[RepIndex];
        Result := AcceptDecision(FirstLen, FirstBack);
        if not Result then
          Exit;
        if FullOptimumState.ReplayCount = 0 then
          Exit;

        for DecisionIndex := 0 to FullOptimumState.ReplayCount - 1 do
        begin
          Decision := FullOptimumState.ReplayDecisions[Integer(DecisionIndex)];
          if not AcceptDecision(Decision.Len, Decision.Back) then
            Exit(False);
        end;
      end;

      procedure ClearFullReplay;
      begin
        FullOptimumState.OptCur := 0;
        FullOptimumState.OptEnd := 0;
        FullOptimumState.ReplayIndex := 0;
        FullOptimumState.ReplayCount := 0;
        SetLength(FullOptimumState.ReplayDecisions, 0);
      end;

    begin
      Result := False;
      PathLen := 1;
      PathBack := MARK_LIT;

      WindowEnd := NumAvail;
      if WindowEnd >= LZMA_FULL_OPTIMUM_NUM_OPTS then
        WindowEnd := LZMA_FULL_OPTIMUM_NUM_OPTS - 1;
      if WindowEnd > GetOptimumWindowLimit then
        WindowEnd := GetOptimumWindowLimit;
      if WindowEnd = 0 then
        Exit;

      SetLength(FullOptimumState.Nodes, Integer(WindowEnd) + 1);
      SetLength(MatchesByPos, Integer(WindowEnd) + 1);
      SetLength(PosStates, Integer(WindowEnd) + 1);
      SetLength(ProbInputsByPos, Integer(WindowEnd) + 1);
      LzmaOptimumPrepareNodes(FullOptimumState.Nodes, 0, State, Reps);

      for PosIndex := 0 to Integer(WindowEnd) - 1 do
      begin
        RelativePos := Pos + NativeUInt(PosIndex);
        PosStates[PosIndex] := (Processed + UInt32(PosIndex)) and PbMask;

        for ProbState := 0 to TLzmaEncoderConstants.kNumStates - 1 do
        begin
          ProbInputsByPos[PosIndex][ProbState].IsMatchProb :=
            IsMatch[ProbState][PosStates[PosIndex]];
          ProbInputsByPos[PosIndex][ProbState].IsRepProb := IsRep[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRepG0Prob := IsRepG0[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRepG1Prob := IsRepG1[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRepG2Prob := IsRepG2[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRep0LongProb :=
            IsRep0Long[ProbState][PosStates[PosIndex]];
        end;

        if PosIndex = 0 then
        begin
          MatchesByPos[PosIndex] := Matches;
          ClampMatchBufferLengths(MatchesByPos[PosIndex], EffectiveFastBytes);
        end
        else
        begin
          LookaheadMatch := ReadMatchDistancesAndInsert(RelativePos,
            MatchesByPos[PosIndex]);
          ClampMatchBufferLengths(MatchesByPos[PosIndex], EffectiveFastBytes);
          if LookaheadMatch.Length > EffectiveFastBytes then
            LookaheadMatch.Length := EffectiveFastBytes;
        end;
      end;

      LiteralResolver :=
        function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
          out LiteralInput: TLzmaOptimumLiteralInput): Boolean
        var
          MatchByteForLiteral: Byte;
          PriceLitState: UInt32;
          PriceLiteralOffset: NativeUInt;
          PricePrevByte: Byte;
          LiteralRelativePos: NativeUInt;
          UseMatchedLiteral: Boolean;
        begin
          FillChar(LiteralInput, SizeOf(LiteralInput), 0);
          LiteralRelativePos := Pos + NativeUInt(WindowPos);
          Result := LiteralRelativePos < Count;
          if not Result then
            Exit;

          if LiteralRelativePos = 0 then
            PricePrevByte := 0
          else
            PricePrevByte := Data[Offset + LiteralRelativePos - 1];
          PriceLitState := (((Processed + WindowPos) and LpMask) shl LcBits) +
            (UInt32(PricePrevByte) shr LcShift);
          PriceLiteralOffset := NativeUInt(PriceLitState) * LZMA_LITERAL_PROB_COUNT;
          UseMatchedLiteral := (Node.State >= TLzmaEncoderConstants.kNumLitStates) and
            (Node.Reps[0] > 0) and (NativeUInt(Node.Reps[0]) <= LiteralRelativePos);
          if UseMatchedLiteral then
            MatchByteForLiteral := Data[Offset + LiteralRelativePos - NativeUInt(Node.Reps[0])]
          else
            MatchByteForLiteral := 0;

          LiteralInput.Enabled := True;
          LiteralInput.LiteralProbs :=
            PLzmaLiteralProbs(@Literals[PriceLiteralOffset])^;
          LiteralInput.Value := Data[Offset + LiteralRelativePos];
          LiteralInput.UseMatchedLiteral := UseMatchedLiteral;
          LiteralInput.MatchByte := MatchByteForLiteral;
        end;

      RepResolver :=
        procedure(const WindowPos: UInt32; const NodeReps: TLzmaOptimumReps;
          out RepLens: TLzmaOptimumRepLens)
        var
          Left: NativeUInt;
          MaxLen: UInt32;
          RepDistance: UInt32;
          RepIndex: Integer;
          RepRelativePos: NativeUInt;
          Right: NativeUInt;
        begin
          FillChar(RepLens, SizeOf(RepLens), 0);
          RepRelativePos := Pos + NativeUInt(WindowPos);
          for RepIndex := Low(NodeReps) to High(NodeReps) do
          begin
            RepDistance := NodeReps[RepIndex];
            if (RepDistance = 0) or (RepRelativePos > Count) or
              (NativeUInt(RepDistance) > RepRelativePos) then
              Continue;

            MaxLen := UInt32(Count - RepRelativePos);
            if MaxLen > TLzmaEncoderConstants.kMatchMaxLen then
              MaxLen := TLzmaEncoderConstants.kMatchMaxLen;
            if MaxLen > EffectiveFastBytes then
              MaxLen := EffectiveFastBytes;
            if MaxLen = 0 then
              Continue;

            Left := Offset + RepRelativePos;
            Right := Left - NativeUInt(RepDistance);
            if Data[Left] <> Data[Right] then
              Continue;
            RepLens[RepIndex] := 1;
            if MaxLen = 1 then
              Continue;

            if Data[Left + 1] <> Data[Right + 1] then
              Continue;
            RepLens[RepIndex] := 2 + LzmaCountMatchingBytes(Data, Left + 2,
              Right + 2, MaxLen - 2);
          end;
        end;

      if not LzmaOptimumRelaxWindow(FullOptimumState.Nodes, MatchesByPos,
        PosStates, LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices,
        LenPrices, RepLenPrices, DistancePrices) then
        Exit;

      TargetEnd := SelectReplayTarget(WindowEnd);
      while TargetEnd <> 0 do
      begin
        if LzmaFullOptimumBackward(FullOptimumState, TargetEnd,
          PathLen, PathBack) and ReplayPathIsValid(PathLen, PathBack) then
        begin
          FullOptimumState.AdditionalOffset := TargetEnd;
          Exit(True);
        end;

        ClearFullReplay;
        FullOptimumState.Nodes[Integer(TargetEnd)].Price := High(UInt32);
        if TargetEnd = 1 then
          Break;
        TargetEnd := SelectReplayTarget(TargetEnd - 1);
      end;
    end;

  begin
    Back := MARK_LIT;
    Result := 1;

    if LzmaFullOptimumTryReplay(FullOptimumState, Result, Back) then
    begin
      Inc(LocalFullOptimumDecisionCount);
      Exit;
    end;

    NeedsFreshRead := LzmaFullOptimumBeginDecision(FullOptimumState,
      NumAvail, NumPairs, MainLen);
    if NeedsFreshRead then
      MainMatch := ReadCurrentMatchDistances(Pos, Matches)
    else if not LzmaFullOptimumLoadCachedMatches(FullOptimumState, Matches,
      MainMatch) then
    begin
      Matches.Clear;
      MainMatch.Length := MainLen;
      MainMatch.Distance := 0;
    end;
    NumAvail := NumAvailAt(Pos);
    if NumAvail < TLzmaEncoderConstants.kMatchMinLen then
    begin
      FullOptimumState.BackRes := Back;
      Exit;
    end;

    BestRepIndex := -1;
    BestRepLen := 0;
    for NumPairs := 0 to 3 do
    begin
      RepLen := RepLenAt(Reps[NumPairs]);
      if RepLen >= EffectiveFastBytes then
      begin
        Back := NumPairs;
        Result := RepLen;
        if Result > 1 then
          LzmaFullOptimumMovePos(FullOptimumState, Result - 1);
        FullOptimumState.BackRes := Back;
        Exit;
      end;
      if RepLen > BestRepLen then
      begin
        BestRepLen := RepLen;
        BestRepIndex := Integer(NumPairs);
      end;
    end;

    if MainMatch.Length >= EffectiveFastBytes then
    begin
      Back := MainMatch.Distance + 3;
      Result := MainMatch.Length;
      if Result > 1 then
        LzmaFullOptimumMovePos(FullOptimumState, Result - 1);
      FullOptimumState.BackRes := Back;
      Exit;
    end;

    if (MainMatch.Length < TLzmaEncoderConstants.kMatchMinLen) and
      (BestRepLen < TLzmaEncoderConstants.kMatchMinLen) then
    begin
      if (BestRepLen = 1) and (BestRepIndex = 0) and
        PreferShortRepOverLiteralByPrice then
      begin
        Back := 0;
        FullOptimumState.BackRes := Back;
        Exit(1);
      end;
      FullOptimumState.BackRes := Back;
      Exit(1);
    end;

    if TryBuildFullOptimumPath(Result, Back) then
    begin
      Inc(LocalFullOptimumDecisionCount);
      FullOptimumState.BackRes := Back;
      Exit;
    end;

    FullOptimumState.BackRes := Back;
  end;

  procedure EncodeOneLiteral;
  begin
    Value := Data[Offset + Pos];
    PosState := Processed and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 0);

    if Pos = 0 then
      PrevByte := 0
    else
      PrevByte := Data[Offset + Pos - 1];
    LitState := ((Processed and LpMask) shl LcBits) +
      (UInt32(PrevByte) shr LcShift);
    LiteralOffset := NativeUInt(LitState) * $300;

    if (State >= TLzmaEncoderConstants.kNumLitStates) and (Reps[0] <= Pos) then
    begin
      MatchByte := Data[Offset + Pos - Reps[0]];
      Encoder.EncodeMatchedLiteral(Literals[LiteralOffset], Value, MatchByte);
    end
    else
      Encoder.EncodeLiteral(Literals[LiteralOffset], Value);

    State := LZMA_STATE_LITERAL_NEXT[State];
    EnsureInsertedUntil(Pos + 1);
    Inc(Pos);
    Inc(Processed);
    MaybeReportProgress;
  end;

  procedure MoveRepToFront(const RepIndex: Integer);
  var
    Distance: UInt32;
  begin
    if RepIndex = 0 then
      Exit;
    Distance := Reps[RepIndex];
    case RepIndex of
      1:
        Reps[1] := Reps[0];
      2:
        begin
          Reps[2] := Reps[1];
          Reps[1] := Reps[0];
        end;
    else
      Reps[3] := Reps[2];
      Reps[2] := Reps[1];
      Reps[1] := Reps[0];
    end;
    Reps[0] := Distance;
  end;

  procedure EncodeOneRep(const RepIndex: Integer; const Len: UInt32);
  begin
    PosState := Processed and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 1);
    Encoder.EncodeBit(IsRep[State], 1);

    if (RepIndex = 0) and (Len = 1) then
    begin
      Encoder.EncodeBit(IsRepG0[State], 0);
      Encoder.EncodeBit(IsRep0Long[State][PosState], 0);
      State := LZMA_STATE_SHORT_REP_NEXT[State];
    end
    else
    begin
      if RepIndex = 0 then
      begin
        Encoder.EncodeBit(IsRepG0[State], 0);
        Encoder.EncodeBit(IsRep0Long[State][PosState], 1);
      end
      else
      begin
        Encoder.EncodeBit(IsRepG0[State], 1);
        if RepIndex = 1 then
          Encoder.EncodeBit(IsRepG1[State], 0)
        else
        begin
          Encoder.EncodeBit(IsRepG1[State], 1);
          Encoder.EncodeBit(IsRepG2[State], UInt32(Ord(RepIndex <> 2)));
        end;
        MoveRepToFront(RepIndex);
      end;

      EncodeLenSymbol(Encoder, RepLenEncoder,
        Len - TLzmaEncoderConstants.kMatchMinLen, PosState);
      State := LZMA_STATE_REP_NEXT[State];
    end;

    EnsureInsertedUntil(Pos + Len);
    Inc(Pos, Len);
    Inc(Processed, Len);
    MaybeReportProgress;
  end;

  procedure EncodeOneMatch(const Len, Distance: UInt32);
  begin
    PosState := Processed and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 1);
    Encoder.EncodeBit(IsRep[State], 0);
    EncodeLenSymbol(Encoder, LenEncoder, Len - TLzmaEncoderConstants.kMatchMinLen, PosState);
    EncodeDistance(Encoder, PosSlot, PosDecoders, Align, Len, Distance);

    Reps[3] := Reps[2];
    Reps[2] := Reps[1];
    Reps[1] := Reps[0];
    Reps[0] := Distance;
    State := LZMA_STATE_MATCH_NEXT[State];

    EnsureInsertedUntil(Pos + Len);
    Inc(Pos, Len);
    Inc(Processed, Len);
    MaybeReportProgress;
  end;

  procedure EncodeEndMarker;
  var
    MarkerPosState: UInt32;
  begin
    MarkerPosState := Processed and PbMask;
    Encoder.EncodeBit(IsMatch[State][MarkerPosState], 1);
    Encoder.EncodeBit(IsRep[State], 0);
    EncodeLenSymbol(Encoder, LenEncoder, 0, MarkerPosState);
    Encoder.BitTreeEncode(PosSlot[0][0], TLzmaEncoderConstants.kNumPosSlotBits,
      (UInt32(1) shl TLzmaEncoderConstants.kNumPosSlotBits) - 1);
    Encoder.EncodeDirectBits((UInt32(1) shl (30 - TLzmaEncoderConstants.kNumAlignBits)) - 1,
      30 - TLzmaEncoderConstants.kNumAlignBits);
    Encoder.BitTreeReverseEncode(Align[0], TLzmaEncoderConstants.kNumAlignBits,
      TLzmaEncoderConstants.kAlignTableSize - 1);
    State := LZMA_STATE_MATCH_NEXT[State];
  end;

begin
  if Props.Lc > 8 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lc property');
  if Props.Lp > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lp property');
  if Props.Pb > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA pb property');
  if Offset > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Invalid LZMA encoder chunk offset');
  if Count > NativeUInt(Length(Data)) - Offset then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA encoder chunk');
  if Count > NativeUInt(High(UInt32)) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'LZMA chunk is too large');
  if FullOptimumDecisionCount <> nil then
    FullOptimumDecisionCount^ := 0;

  if FastBytes < 5 then
    EffectiveFastBytes := 5
  else
    EffectiveFastBytes := UInt32(FastBytes);
  if EffectiveFastBytes > TLzmaEncoderConstants.kMatchMaxLen then
    EffectiveFastBytes := TLzmaEncoderConstants.kMatchMaxLen;

  InitProbArray(IsMatch, TLzmaEncoderConstants.kNumStates *
    TLzmaEncoderConstants.kNumPosStatesMax);
  InitProbArray(IsRep, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG0, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG1, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG2, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRep0Long, TLzmaEncoderConstants.kNumStates *
    TLzmaEncoderConstants.kNumPosStatesMax);
  InitProbArray(PosSlot, TLzmaEncoderConstants.kNumLenToPosStates *
    (UInt32(1) shl TLzmaEncoderConstants.kNumPosSlotBits));
  InitProbArray(PosDecoders, Length(PosDecoders));
  InitProbArray(Align, TLzmaEncoderConstants.kAlignTableSize);
  InitLenEncoder(LenEncoder);
  InitLenEncoder(RepLenEncoder);
  NumPosStates := UInt32(1) shl Props.Pb;
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenPriceEncoder(LenPrices, EffectiveFastBytes);
  LzmaInitLenPriceEncoder(RepLenPrices, EffectiveFastBytes);
  LzmaUpdateLenPriceEncoder(LenPrices, LenEncoder.Low, LenEncoder.High, NumPosStates, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPrices, RepLenEncoder.Low, RepLenEncoder.High, NumPosStates, ProbPrices);
  LzmaInitDistancePriceEncoder(DistancePrices, Props.DictionarySize);
  LzmaUpdateDistancePriceEncoder(DistancePrices, PosSlot, PosDecoders, Align, ProbPrices);
  SetLength(Literals, $300 shl (Props.Lc + Props.Lp));
  if Length(Literals) <> 0 then
    InitProbArray(Literals[0], Length(Literals));
  PbMask := (UInt32(1) shl Props.Pb) - 1;
  LpMask := (UInt32(1) shl Props.Lp) - 1;
  LcBits := Props.Lc;
  LcShift := 8 - LcBits;

  GreedyFinder := nil;
  Hc4Finder := nil;
  Hc5Finder := nil;
  Bt4Finder := nil;
  Encoder := nil;
  LocalFullOptimumDecisionCount := 0;
  try
    Encoder := TLzmaRangeEncoder.Create;
    Encoder.Init;
    Pos := 0;
    Processed := 0;
    NextProgressAt := kProgressInterval;
    InsertedUntil := 0;
    MatchCache.Clear;
    ClearOptimumReplayQueue;
    LzmaFullOptimumInit(FullOptimumState, EnableOptimumWindow);
    State := 0;
    Reps[0] := 1;
    Reps[1] := 1;
    Reps[2] := 1;
    Reps[3] := 1;

    if (not FullOptimumState.Enabled) and TryDetectSmallPeriodicChunk(PeriodicDistance) then
    begin
      while Pos < Count do
      begin
        if Pos < NativeUInt(PeriodicDistance) then
          EncodeOneLiteral
        else
        begin
          LenRes := NumAvailAt(Pos);
          if LenRes < TLzmaEncoderConstants.kMatchMinLen then
            EncodeOneLiteral
          else if Reps[0] = PeriodicDistance then
            EncodeOneRep(0, LenRes)
          else
            EncodeOneMatch(LenRes, PeriodicDistance);
        end;
      end;

      if WriteEndMarker then
        EncodeEndMarker;
      Encoder.FlushData;
      Result := Encoder.ToBytes;
      Exit;
    end;

    case MatchFinderKind of
      mfHashChain4:
        Hc4Finder := TLzmaHashChain4MatchFinder.Create(Data, Offset, Count, Props.DictionarySize,
        EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen, CutValue);
      mfHashChain5:
        Hc5Finder := TLzmaHashChain5MatchFinder.Create(Data, Offset, Count, Props.DictionarySize,
          EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen, CutValue);
      mfBinaryTree4:
        Bt4Finder := TLzmaBinaryTree4MatchFinder.Create(Data, Offset, Count, Props.DictionarySize,
          EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen, CutValue);
    else
      GreedyFinder := TLzmaGreedyMatchFinder.Create(Data, Offset, Count, Props.DictionarySize,
        EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen, CutValue);
    end;

    while Pos < Count do
    begin
      if FullOptimumState.Enabled then
        LenRes := GetOptimumFull(BackRes)
      else
        LenRes := GetOptimumFast(BackRes);
      if LenRes > NumAvailAt(Pos) then
        RaiseLzmaError(SZ_ERROR_FAIL, Format(
          'LZMA encoder decision exceeds input: pos=%d len=%d avail=%d back=%d',
          [UInt64(Pos), LenRes, NumAvailAt(Pos), BackRes]));
      if BackRes = UInt32($FFFFFFFF) then
        EncodeOneLiteral
      else if BackRes < 4 then
        EncodeOneRep(Integer(BackRes), LenRes)
      else
        EncodeOneMatch(LenRes, BackRes - 3);
      if FullOptimumState.Enabled then
      begin
        if BackRes >= 4 then
          LzmaFullOptimumNoteNormalMatch(FullOptimumState)
        else if (BackRes < 4) and (LenRes > 1) then
          LzmaFullOptimumNoteRepLen(FullOptimumState);
        if not LzmaFullOptimumCommitEncodedLen(FullOptimumState, LenRes) then
          RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA full optimum additionalOffset underflow');
        if LzmaFullOptimumCanRefreshPrices(FullOptimumState) and
          ((FullOptimumState.MatchPriceCount >= LZMA_FULL_OPTIMUM_MATCH_PRICE_REFRESH) or
           (FullOptimumState.RepLenEncCounter <= 0)) then
        begin
          RefreshOptimumPriceTables;
          LzmaFullOptimumResetRefreshCounters(FullOptimumState);
        end;
      end;
    end;

    if WriteEndMarker then
      EncodeEndMarker;
    Encoder.FlushData;
    Result := Encoder.ToBytes;
  finally
    if FullOptimumDecisionCount <> nil then
      FullOptimumDecisionCount^ := LocalFullOptimumDecisionCount;
    Encoder.Free;
    Bt4Finder.Free;
    Hc5Finder.Free;
    Hc4Finder.Free;
    GreedyFinder.Free;
  end;
end;

class procedure TLzmaRawEncoder.Encode(Source: TStream; Destination: TStream; const Profile: TLzmaEncoderProfile;
  const Progress: TLzma2ProgressEvent);
var
  Props: TLzmaProps;
begin
  Props := DefaultProperties(Profile.DictionarySize);
  Encode(Source, Destination, Profile, Props, False, Progress);
end;

class procedure TLzmaRawEncoder.Encode(Source: TStream; Destination: TStream; const Profile: TLzmaEncoderProfile;
  const Props: TLzmaProps; const WriteEndMarker: Boolean; const Progress: TLzma2ProgressEvent);
const
  kStreamBufferSize = 1 shl 20;
  kCompactGranularity = 1 shl 16;
  kProgressInterval = UInt64(1) shl 20;
type
  PLzmaLiteralProbs = ^TLzmaLiteralProbs;
var
  IsMatch: array[0..TLzmaEncoderConstants.kNumStates - 1,
    0..TLzmaEncoderConstants.kNumPosStatesMax - 1] of CLzmaProb;
  IsRep: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG0: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG1: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRepG2: array[0..TLzmaEncoderConstants.kNumStates - 1] of CLzmaProb;
  IsRep0Long: array[0..TLzmaEncoderConstants.kNumStates - 1,
    0..TLzmaEncoderConstants.kNumPosStatesMax - 1] of CLzmaProb;
  PosSlot: TLzmaPosSlotProbs;
  PosDecoders: TLzmaPosDecoderProbs;
  Align: TLzmaAlignProbs;
  LenEncoder: TLenEncoder;
  RepLenEncoder: TLenEncoder;
  Literals: array of CLzmaProb;
  ProbPrices: TLzmaProbPrices;
  LenPrices: TLzmaLenPriceEncoder;
  RepLenPrices: TLzmaLenPriceEncoder;
  DistancePrices: TLzmaDistancePriceEncoder;
  Buffer: TBytes;
  Pending: TBytes;
  Encoder: TLzmaRangeEncoder;
  GreedyFinder: TLzmaGreedyMatchFinder;
  Hc4Finder: TLzmaHashChain4MatchFinder;
  Hc5Finder: TLzmaHashChain5MatchFinder;
  Bt4Finder: TLzmaBinaryTree4MatchFinder;
  Count: Integer;
  FinderInsertedUntil: NativeUInt;
  PendingBase: UInt64;
  PendingSize: NativeInt;
  Processed: UInt64;
  NextProgressAt: UInt64;
  State: UInt32;
  Reps: array[0..3] of UInt32;
  PosState: UInt32;
  LitState: UInt32;
  LiteralOffset: NativeUInt;
  EffectiveFastBytes: UInt32;
  MaxSearchDistance: UInt32;
  HistoryKeep: UInt64;
  PbMask: UInt32;
  LpMask: UInt32;
  LcBits: UInt32;
  LcShift: UInt32;
  MatchFinderDirty: Boolean;
  InputEof: Boolean;
  NumPosStates: UInt32;
  OptimumReplayCount: UInt32;
  OptimumReplayIndex: UInt32;
  OptimumReplayQueue: TArray<TLzmaOptimumDecision>;

  procedure MaybeReportProgress;
  begin
    if Processed < NextProgressAt then
      Exit;
    ReportProgress(Progress, Processed, Encoder.FCommittedOutputSize);
    repeat
      Inc(NextProgressAt, kProgressInterval);
    until Processed < NextProgressAt;
  end;

  function CurrentIndex: NativeInt;
  begin
    if Processed < PendingBase then
      RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA stream encoder window underflow');
    if Processed - PendingBase > UInt64(High(NativeInt)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'LZMA stream encoder pending window exceeds native capacity');
    Result := NativeInt(Processed - PendingBase);
  end;

  function PendingAvailable: UInt64;
  begin
    if Processed < PendingBase then
      RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA stream encoder window underflow');
    Result := UInt64(PendingSize) - (Processed - PendingBase);
  end;

  procedure FreeMatchFinder;
  begin
    Bt4Finder.Free;
    Bt4Finder := nil;
    Hc5Finder.Free;
    Hc5Finder := nil;
    Hc4Finder.Free;
    Hc4Finder := nil;
    GreedyFinder.Free;
    GreedyFinder := nil;
    FinderInsertedUntil := 0;
  end;

  procedure InvalidateMatchFinder;
  begin
    FreeMatchFinder;
    MatchFinderDirty := True;
  end;

  procedure AppendPending(const Chunk; const ChunkSize: NativeInt);
  begin
    if ChunkSize <= 0 then
      Exit;
    if ChunkSize > High(NativeInt) - PendingSize then
      RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA stream encoder pending window exceeds native capacity');
    SetLength(Pending, PendingSize + ChunkSize);
    Move(Chunk, Pending[PendingSize], ChunkSize);
    Inc(PendingSize, ChunkSize);
    InvalidateMatchFinder;
  end;

  procedure CompactPending;
  var
    Drop: UInt64;
    DropNative: NativeInt;
    EncodedInPending: UInt64;
    Keep: UInt64;
    Remaining: NativeInt;

    function CurrentHistoryKeep: UInt64;
    var
      RepIndex: Integer;
      RepKeep: UInt64;
    begin
      Result := HistoryKeep;
      for RepIndex := 0 to 3 do
      begin
        RepKeep := UInt64(Reps[RepIndex]) + TLzmaEncoderConstants.kMatchMaxLen + 16;
        if RepKeep > Result then
          Result := RepKeep;
      end;
    end;
  begin
    if Processed < PendingBase then
      RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA stream encoder window underflow');
    EncodedInPending := Processed - PendingBase;
    Keep := CurrentHistoryKeep;
    if EncodedInPending <= Keep + kCompactGranularity then
      Exit;
    Drop := EncodedInPending - Keep;
    if Drop = 0 then
      Exit;
    if Drop > UInt64(PendingSize) then
      Drop := UInt64(PendingSize);
    DropNative := NativeInt(Drop);
    Remaining := PendingSize - DropNative;
    if Remaining > 0 then
      Move(Pending[DropNative], Pending[0], Remaining);
    PendingSize := Remaining;
    SetLength(Pending, PendingSize);
    Inc(PendingBase, Drop);
    InvalidateMatchFinder;
  end;

  procedure EnsureMatchFinder;
  begin
    if (not MatchFinderDirty) and
      ((GreedyFinder <> nil) or (Hc4Finder <> nil) or (Hc5Finder <> nil) or (Bt4Finder <> nil)) then
      Exit;

    FreeMatchFinder;
    case Profile.MatchFinderKind of
      mfHashChain4:
        Hc4Finder := TLzmaHashChain4MatchFinder.Create(Pending, 0, PendingSize,
          Props.DictionarySize, EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen,
          Profile.CutValue);
      mfHashChain5:
        Hc5Finder := TLzmaHashChain5MatchFinder.Create(Pending, 0, PendingSize,
          Props.DictionarySize, EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen,
          Profile.CutValue);
      mfBinaryTree4:
        Bt4Finder := TLzmaBinaryTree4MatchFinder.Create(Pending, 0, PendingSize,
          Props.DictionarySize, EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen,
          Profile.CutValue);
    else
      GreedyFinder := TLzmaGreedyMatchFinder.Create(Pending, 0, PendingSize,
        Props.DictionarySize, EffectiveFastBytes, TLzmaEncoderConstants.kMatchMaxLen,
        Profile.CutValue);
    end;
    MatchFinderDirty := False;
  end;

  procedure EnsureMatchFinderInsertedUntil(const Target: NativeUInt);
  var
    BoundedTarget: NativeUInt;
  begin
    EnsureMatchFinder;
    BoundedTarget := Target;
    if BoundedTarget > NativeUInt(PendingSize) then
      BoundedTarget := NativeUInt(PendingSize);
    if BoundedTarget <= FinderInsertedUntil then
      Exit;

    if Bt4Finder <> nil then
      Bt4Finder.InsertRange(FinderInsertedUntil, BoundedTarget - FinderInsertedUntil)
    else if Hc5Finder <> nil then
      Hc5Finder.SkipRangeMonotonic(FinderInsertedUntil, BoundedTarget - FinderInsertedUntil)
    else if Hc4Finder <> nil then
      Hc4Finder.InsertRange(FinderInsertedUntil, BoundedTarget - FinderInsertedUntil)
    else
      GreedyFinder.InsertRange(FinderInsertedUntil, BoundedTarget - FinderInsertedUntil);
    FinderInsertedUntil := BoundedTarget;
  end;

  procedure ReadMatchFinderMatchesAt(const RelativePos: NativeUInt;
    var Matches: TLzmaMatchBuffer);
  begin
    Matches.Clear;
    if (RelativePos = 0) or (RelativePos >= NativeUInt(PendingSize)) then
      Exit;

    EnsureMatchFinderInsertedUntil(RelativePos);
    if Bt4Finder <> nil then
      Bt4Finder.ReadMatches(RelativePos, Matches)
    else if Hc5Finder <> nil then
      Hc5Finder.ReadMatches(RelativePos, Matches)
    else if Hc4Finder <> nil then
      Hc4Finder.ReadMatches(RelativePos, Matches)
    else
      GreedyFinder.ReadMatches(RelativePos, Matches);
    if FinderInsertedUntil < RelativePos + 1 then
      FinderInsertedUntil := RelativePos + 1;
  end;

  procedure ReadLookaheadMatchFinderMatchesAt(const RelativePos: NativeUInt;
    var Matches: TLzmaMatchBuffer);
  begin
    Matches.Clear;
    if (RelativePos = 0) or (RelativePos >= NativeUInt(PendingSize)) then
      Exit;

    EnsureMatchFinder;
    if Bt4Finder <> nil then
      Bt4Finder.GetMatches(RelativePos, Matches)
    else if Hc5Finder <> nil then
      Hc5Finder.GetMatches(RelativePos, Matches)
    else if Hc4Finder <> nil then
      Hc4Finder.GetMatches(RelativePos, Matches)
    else
      GreedyFinder.GetMatches(RelativePos, Matches);
  end;

  procedure ClampMatchBufferLengths(var MatchList: TLzmaMatchBuffer;
    const MaxLen: UInt32);
  var
    MatchIndex: Integer;
  begin
    for MatchIndex := 0 to MatchList.Count - 1 do
    begin
      if MatchList.Items[MatchIndex].Length > MaxLen then
        MatchList.Items[MatchIndex].Length := MaxLen;
    end;
  end;

  procedure RefreshOptimumPriceTables;
  begin
    LzmaUpdateLenPriceEncoder(LenPrices, LenEncoder.Low, LenEncoder.High,
      NumPosStates, ProbPrices);
    LzmaUpdateLenPriceEncoder(RepLenPrices, RepLenEncoder.Low,
      RepLenEncoder.High, NumPosStates, ProbPrices);
    LzmaUpdateDistancePriceEncoder(DistancePrices, PosSlot, PosDecoders,
      Align, ProbPrices);
  end;

  function NumAvailAtCurrent: UInt32;
  var
    Avail: UInt64;
  begin
    Avail := PendingAvailable;
    if Avail > TLzmaEncoderConstants.kMatchMaxLen then
      Result := TLzmaEncoderConstants.kMatchMaxLen
    else
      Result := UInt32(Avail);
  end;

  function NumAvailAtRelative(const RelativePos: NativeUInt): UInt32;
  var
    Avail: NativeUInt;
  begin
    if RelativePos >= NativeUInt(PendingSize) then
      Exit(0);
    Avail := NativeUInt(PendingSize) - RelativePos;
    if Avail > TLzmaEncoderConstants.kMatchMaxLen then
      Result := TLzmaEncoderConstants.kMatchMaxLen
    else
      Result := UInt32(Avail);
  end;

  function MatchLenAtRelativeDistance(const RelativePos: NativeUInt;
    const Distance, MaxLen: UInt32): UInt32;
  var
    Avail: UInt32;
    Right: NativeUInt;
  begin
    Result := 0;
    if (Distance = 0) or (NativeUInt(Distance) > RelativePos) then
      Exit;
    Avail := NumAvailAtRelative(RelativePos);
    if (MaxLen <> 0) and (Avail > MaxLen) then
      Avail := MaxLen;
    if Avail = 0 then
      Exit;
    Right := RelativePos - NativeUInt(Distance);
    Result := LzmaCountMatchingBytes(Pending, RelativePos, Right, Avail);
  end;

  function MatchLenAtDistance(const Distance: UInt32): UInt32;
  begin
    Result := MatchLenAtRelativeDistance(NativeUInt(CurrentIndex), Distance, 0);
  end;

  function DecisionMatchesInput(const DecisionLen, DecisionBack: UInt32): Boolean;
  var
    Distance: UInt32;
  begin
    Result := False;
    if (DecisionLen = 0) or (UInt64(DecisionLen) > PendingAvailable) then
      Exit;
    if DecisionBack = LZMA_OPTIMUM_BACK_LITERAL then
      Exit(DecisionLen = 1);
    if DecisionBack < 4 then
      Distance := Reps[Integer(DecisionBack)]
    else
      Distance := DecisionBack - 3;
    Result := MatchLenAtRelativeDistance(NativeUInt(CurrentIndex), Distance,
      DecisionLen) >= DecisionLen;
  end;

  procedure ClearOptimumReplayQueue;
  begin
    OptimumReplayCount := 0;
    OptimumReplayIndex := 0;
    SetLength(OptimumReplayQueue, 0);
  end;

  function IsOptimumReplayDecisionUsable(
    const Decision: TLzmaOptimumDecision): Boolean;
  begin
    Result := DecisionMatchesInput(Decision.Len, Decision.Back);
  end;

  function TryPopOptimumReplayDecision(out Len, Back: UInt32): Boolean;
  var
    Decision: TLzmaOptimumDecision;
  begin
    Result := False;
    if OptimumReplayIndex >= OptimumReplayCount then
      Exit;

    Decision := OptimumReplayQueue[Integer(OptimumReplayIndex)];
    if not IsOptimumReplayDecisionUsable(Decision) then
    begin
      ClearOptimumReplayQueue;
      Exit;
    end;

    Len := Decision.Len;
    Back := Decision.Back;
    Inc(OptimumReplayIndex);
    if OptimumReplayIndex >= OptimumReplayCount then
      ClearOptimumReplayQueue;
    Result := True;
  end;

  function QueueOptimumReplayPath(const Nodes: array of TLzmaOptimumNode;
    const EndPos: UInt32; out FirstLen, FirstBack: UInt32): Boolean;
  var
    BackwardState: TLzmaOptimumBackwardState;
    DecisionCount: UInt32;
    Decisions: TArray<TLzmaOptimumDecision>;
    Index: UInt32;

    function ReplayPathMatchesInput: Boolean;
    var
      DecisionIndex: UInt32;
      SimPos: NativeUInt;
      SimReps: array[0..3] of UInt32;

      procedure MoveSimRepToFront(const RepIndex: Integer);
      var
        I: Integer;
        Distance: UInt32;
      begin
        if RepIndex <= 0 then
          Exit;
        Distance := SimReps[RepIndex];
        for I := RepIndex downto 1 do
          SimReps[I] := SimReps[I - 1];
        SimReps[0] := Distance;
      end;

      function AcceptDecision(const Decision: TLzmaOptimumDecision): Boolean;
      var
        Distance: UInt32;
        RepIndex: Integer;
      begin
        Result := False;
        if SimPos > NativeUInt(PendingSize) then
          Exit;
        if (Decision.Len = 0) or
          (NativeUInt(Decision.Len) > NativeUInt(PendingSize) - SimPos) then
          Exit;
        if Decision.Back = LZMA_OPTIMUM_BACK_LITERAL then
        begin
          Result := Decision.Len = 1;
          if Result then
            Inc(SimPos);
          Exit;
        end;

        if Decision.Back < 4 then
        begin
          RepIndex := Integer(Decision.Back);
          Distance := SimReps[RepIndex];
          if MatchLenAtRelativeDistance(SimPos, Distance, Decision.Len) < Decision.Len then
            Exit;
          MoveSimRepToFront(RepIndex);
          Inc(SimPos, Decision.Len);
          Exit(True);
        end;

        Distance := Decision.Back - 3;
        if MatchLenAtRelativeDistance(SimPos, Distance, Decision.Len) < Decision.Len then
          Exit;
        SimReps[3] := SimReps[2];
        SimReps[2] := SimReps[1];
        SimReps[1] := SimReps[0];
        SimReps[0] := Distance;
        Inc(SimPos, Decision.Len);
        Result := True;
      end;

    begin
      Result := False;
      SimPos := NativeUInt(CurrentIndex);
      for DecisionIndex := 0 to 3 do
        SimReps[Integer(DecisionIndex)] := Reps[Integer(DecisionIndex)];
      for DecisionIndex := 0 to DecisionCount - 1 do
      begin
        if not AcceptDecision(Decisions[Integer(DecisionIndex)]) then
          Exit;
      end;
      Result := True;
    end;
  begin
    Result := False;
    FirstLen := 0;
    FirstBack := LZMA_OPTIMUM_BACK_LITERAL;
    ClearOptimumReplayQueue;

    SetLength(Decisions, Integer(EndPos));
    if not LzmaOptimumReplaySdkBackward(Nodes, EndPos, Decisions, DecisionCount,
      BackwardState) then
      Exit;
    if (DecisionCount = 0) or (not ReplayPathMatchesInput) then
      Exit;
    if (DecisionCount = 0) or not IsOptimumReplayDecisionUsable(Decisions[0]) then
      Exit;

    FirstLen := Decisions[0].Len;
    FirstBack := Decisions[0].Back;
    if DecisionCount > 1 then
    begin
      SetLength(OptimumReplayQueue, Integer(DecisionCount - 1));
      for Index := 1 to DecisionCount - 1 do
        OptimumReplayQueue[Integer(Index - 1)] := Decisions[Integer(Index)];
      OptimumReplayCount := DecisionCount - 1;
      OptimumReplayIndex := 0;
    end;

    Result := True;
  end;

  function GetBestDecision(out Len, Back: UInt32): Boolean;
  var
    BestMatchDistance: UInt32;
    BestMatchLen: UInt32;
    BestRepIndex: Integer;
    BestRepLen: UInt32;
    Cur: NativeInt;
    MatchIndex: Integer;
    Matches: TLzmaMatchBuffer;
    RepIndex: Integer;
    TestLen: UInt32;
    WindowBack: UInt32;
    WindowLen: UInt32;

    function TryGetOptimumWindowDecision(const BaselineLen, BaselineBack: UInt32;
      out WindowLen, WindowBack: UInt32): Boolean;
    var
      LiteralResolver: TLzmaOptimumLiteralResolver;
      BaseIndex: NativeUInt;
      MatchesByPos: TArray<TLzmaMatchBuffer>;
      Nodes: TArray<TLzmaOptimumNode>;
      PosIndex: Integer;
      PosStates: TArray<UInt32>;
      ProbInputsByPos: TArray<TLzmaOptimumStateProbInputs>;
      ProbState: Integer;
      RelativePos: NativeUInt;
      RepResolver: TLzmaOptimumRepLensResolver;
      BaselinePrice: UInt32;
      InitialTargetEnd: UInt32;
      LookaheadWindowEnd: UInt32;
      ReplayBack: UInt32;
      ReplayLen: UInt32;
      TempBt4Finder: TLzmaBinaryTree4MatchFinder;
      TempFinderInsertedUntil: NativeUInt;
      TempGreedyFinder: TLzmaGreedyMatchFinder;
      TempHc4Finder: TLzmaHashChain4MatchFinder;
      TempHc5Finder: TLzmaHashChain5MatchFinder;
      TargetEnd: UInt32;
      TargetPrice: UInt32;
      WindowEnd: UInt32;

      procedure FreeTempMatchFinder;
      begin
        TempBt4Finder.Free;
        TempBt4Finder := nil;
        TempHc5Finder.Free;
        TempHc5Finder := nil;
        TempHc4Finder.Free;
        TempHc4Finder := nil;
        TempGreedyFinder.Free;
        TempGreedyFinder := nil;
        TempFinderInsertedUntil := 0;
      end;

      procedure EnsureTempMatchFinder;
      begin
        if (TempGreedyFinder <> nil) or (TempHc4Finder <> nil) or
          (TempHc5Finder <> nil) or (TempBt4Finder <> nil) then
          Exit;

        case Profile.MatchFinderKind of
          mfHashChain4:
            TempHc4Finder := TLzmaHashChain4MatchFinder.Create(Pending, 0,
              PendingSize, Props.DictionarySize, EffectiveFastBytes,
              TLzmaEncoderConstants.kMatchMaxLen, Profile.CutValue);
          mfHashChain5:
            TempHc5Finder := TLzmaHashChain5MatchFinder.Create(Pending, 0,
              PendingSize, Props.DictionarySize, EffectiveFastBytes,
              TLzmaEncoderConstants.kMatchMaxLen, Profile.CutValue);
          mfBinaryTree4:
            TempBt4Finder := TLzmaBinaryTree4MatchFinder.Create(Pending, 0,
              PendingSize, Props.DictionarySize, EffectiveFastBytes,
              TLzmaEncoderConstants.kMatchMaxLen, Profile.CutValue);
        else
          TempGreedyFinder := TLzmaGreedyMatchFinder.Create(Pending, 0,
            PendingSize, Props.DictionarySize, EffectiveFastBytes,
            TLzmaEncoderConstants.kMatchMaxLen, Profile.CutValue);
        end;
      end;

      procedure EnsureTempMatchFinderInsertedUntil(const Target: NativeUInt);
      var
        BoundedTarget: NativeUInt;
      begin
        EnsureTempMatchFinder;
        BoundedTarget := Target;
        if BoundedTarget > NativeUInt(PendingSize) then
          BoundedTarget := NativeUInt(PendingSize);
        if BoundedTarget <= TempFinderInsertedUntil then
          Exit;

        if TempBt4Finder <> nil then
          TempBt4Finder.InsertRange(TempFinderInsertedUntil,
            BoundedTarget - TempFinderInsertedUntil)
        else if TempHc5Finder <> nil then
          TempHc5Finder.SkipRangeMonotonic(TempFinderInsertedUntil,
            BoundedTarget - TempFinderInsertedUntil)
        else if TempHc4Finder <> nil then
          TempHc4Finder.InsertRange(TempFinderInsertedUntil,
            BoundedTarget - TempFinderInsertedUntil)
        else
          TempGreedyFinder.InsertRange(TempFinderInsertedUntil,
            BoundedTarget - TempFinderInsertedUntil);
        TempFinderInsertedUntil := BoundedTarget;
      end;

      procedure ReadTempMatchFinderMatchesAt(const RelativePos: NativeUInt;
        var Matches: TLzmaMatchBuffer);
      begin
        Matches.Clear;
        if (RelativePos = 0) or (RelativePos >= NativeUInt(PendingSize)) then
          Exit;

        EnsureTempMatchFinderInsertedUntil(RelativePos);
        if TempBt4Finder <> nil then
          TempBt4Finder.ReadMatches(RelativePos, Matches)
        else if TempHc5Finder <> nil then
          TempHc5Finder.ReadMatches(RelativePos, Matches)
        else if TempHc4Finder <> nil then
          TempHc4Finder.ReadMatches(RelativePos, Matches)
        else
          TempGreedyFinder.ReadMatches(RelativePos, Matches);
        if TempFinderInsertedUntil < RelativePos + 1 then
          TempFinderInsertedUntil := RelativePos + 1;
      end;

      function HasLiteralLookaheadWork(out LookaheadEnd: UInt32): Boolean;
      var
        MatchIndex: Integer;
        ProbeLen: UInt32;
        ProbeMatches: TLzmaMatchBuffer;
        RepIndex: Integer;
        TestLen: UInt32;
      begin
        Result := False;
        LookaheadEnd := 1;
        if WindowEnd <= 1 then
          Exit;

        ProbeLen := 0;
        ReadLookaheadMatchFinderMatchesAt(BaseIndex + 1, ProbeMatches);
        for MatchIndex := 0 to ProbeMatches.Count - 1 do
        begin
          TestLen := ProbeMatches.Items[MatchIndex].Length;
          if TestLen > EffectiveFastBytes then
            TestLen := EffectiveFastBytes;
          if TestLen > ProbeLen then
            ProbeLen := TestLen;
        end;

        for RepIndex := 0 to 3 do
        begin
          TestLen := MatchLenAtRelativeDistance(BaseIndex + 1,
            Reps[RepIndex], EffectiveFastBytes);
          if TestLen > ProbeLen then
            ProbeLen := TestLen;
        end;

        if ProbeLen < TLzmaEncoderConstants.kMatchMinLen then
          Exit;
        LookaheadEnd := ProbeLen + 1;
        if LookaheadEnd > WindowEnd then
          LookaheadEnd := WindowEnd;
        Result := True;
      end;

      function GetDirectBaselinePrice(out DirectPrice,
        DirectEnd: UInt32): Boolean;
      var
        BaselineInput: TLzmaOptimumLiteralInput;
        BaselineMatches: TLzmaMatchBuffer;
        BaselineNodes: TArray<TLzmaOptimumNode>;
        BaselineRepLens: TLzmaOptimumRepLens;
      begin
        Result := False;
        DirectPrice := High(UInt32);
        DirectEnd := BaselineLen;
        if DirectEnd = 0 then
          DirectEnd := 1;
        if DirectEnd >= UInt32(Length(Nodes)) then
          Exit;

        SetLength(BaselineNodes, Integer(DirectEnd) + 1);
        LzmaOptimumPrepareNodes(BaselineNodes, 0, State, Reps);
        if BaselineBack = LZMA_OPTIMUM_BACK_LITERAL then
        begin
          if (DirectEnd <> 1) or
            (not LiteralResolver(0, BaselineNodes[0], BaselineInput)) or
            (not BaselineInput.Enabled) then
            Exit;
          Result := LzmaOptimumRelaxLiteralCandidate(BaselineNodes, 0,
            ProbPrices, BaselineInput.LiteralProbs,
            IsMatch[State][UInt32(Processed) and PbMask], BaselineInput.Value,
            BaselineInput.UseMatchedLiteral, BaselineInput.MatchByte,
            DirectPrice);
        end
        else if (BaselineBack = 0) and (BaselineLen = 1) then
        begin
          Result := LzmaOptimumRelaxShortRepCandidate(BaselineNodes, 0,
            ProbPrices, IsMatch[State][UInt32(Processed) and PbMask],
            IsRep[State], IsRepG0[State],
            IsRep0Long[State][UInt32(Processed) and PbMask], DirectPrice);
        end
        else if BaselineBack < 4 then
        begin
          if (BaselineLen < TLzmaEncoderConstants.kMatchMinLen) or
            (BaselineBack > UInt32(High(BaselineRepLens))) then
            Exit;
          FillChar(BaselineRepLens, SizeOf(BaselineRepLens), 0);
          BaselineRepLens[Integer(BaselineBack)] := BaselineLen;
          Result := LzmaOptimumRelaxRepCandidates(BaselineNodes, 0,
            BaselineRepLens, ProbPrices, RepLenPrices,
            IsMatch[State][UInt32(Processed) and PbMask], IsRep[State],
            IsRepG0[State], IsRepG1[State], IsRepG2[State],
            IsRep0Long[State][UInt32(Processed) and PbMask],
            UInt32(Processed) and PbMask, DirectPrice);
        end
        else
        begin
          if BaselineLen < TLzmaEncoderConstants.kMatchMinLen then
            Exit;
          BaselineMatches.Clear;
          BaselineMatches.Add(BaselineLen, BaselineBack - 3);
          Result := LzmaOptimumRelaxMatchCandidates(BaselineNodes, 0,
            BaselineMatches, ProbPrices, LenPrices, DistancePrices,
            IsMatch[State][UInt32(Processed) and PbMask], IsRep[State],
            UInt32(Processed) and PbMask, BaselineLen, BaselineLen,
            DirectPrice);
        end;

        if Result then
          DirectPrice := BaselineNodes[Integer(DirectEnd)].Price;
        Result := Result and (DirectPrice <> High(UInt32));
      end;
    begin
      Result := False;
      WindowLen := 0;
      WindowBack := UInt32($FFFFFFFF);
      TempGreedyFinder := nil;
      TempHc4Finder := nil;
      TempHc5Finder := nil;
      TempBt4Finder := nil;
      TempFinderInsertedUntil := 0;
      if Profile.ParserMode <> lpmSdkProfile then
        Exit;

      WindowEnd := NumAvailAtCurrent;
      if WindowEnd >= LZMA_FULL_OPTIMUM_NUM_OPTS then
        WindowEnd := LZMA_FULL_OPTIMUM_NUM_OPTS - 1;
      if WindowEnd = 0 then
        Exit;
      BaseIndex := NativeUInt(Cur);

      try
      if (BaselineBack = LZMA_OPTIMUM_BACK_LITERAL) and (BaselineLen = 1) then
      begin
        if not HasLiteralLookaheadWork(LookaheadWindowEnd) then
          Exit;
        WindowEnd := LookaheadWindowEnd;
      end;

      RefreshOptimumPriceTables;
      SetLength(Nodes, Integer(WindowEnd) + 1);
      SetLength(MatchesByPos, Integer(WindowEnd) + 1);
      SetLength(PosStates, Integer(WindowEnd) + 1);
      SetLength(ProbInputsByPos, Integer(WindowEnd) + 1);
      LzmaOptimumPrepareNodes(Nodes, 0, State, Reps);

      for PosIndex := 0 to Integer(WindowEnd) - 1 do
      begin
        RelativePos := BaseIndex + NativeUInt(PosIndex);
        PosStates[PosIndex] := (UInt32(Processed) + UInt32(PosIndex)) and PbMask;

        for ProbState := 0 to TLzmaEncoderConstants.kNumStates - 1 do
        begin
          ProbInputsByPos[PosIndex][ProbState].IsMatchProb :=
            IsMatch[ProbState][PosStates[PosIndex]];
          ProbInputsByPos[PosIndex][ProbState].IsRepProb := IsRep[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRepG0Prob := IsRepG0[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRepG1Prob := IsRepG1[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRepG2Prob := IsRepG2[ProbState];
          ProbInputsByPos[PosIndex][ProbState].IsRep0LongProb :=
            IsRep0Long[ProbState][PosStates[PosIndex]];
        end;

        if PosIndex = 0 then
          MatchesByPos[PosIndex] := Matches
        else
          ReadTempMatchFinderMatchesAt(RelativePos, MatchesByPos[PosIndex]);
        ClampMatchBufferLengths(MatchesByPos[PosIndex], EffectiveFastBytes);
      end;

      LiteralResolver :=
        function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
          out LiteralInput: TLzmaOptimumLiteralInput): Boolean
        var
          LiteralRelativePos: NativeUInt;
          MatchByteForLiteral: Byte;
          PriceLiteralOffset: NativeUInt;
          PriceLitState: UInt32;
          PricePrevByte: Byte;
          UseMatchedLiteral: Boolean;
        begin
          FillChar(LiteralInput, SizeOf(LiteralInput), 0);
          LiteralRelativePos := BaseIndex + NativeUInt(WindowPos);
          Result := LiteralRelativePos < NativeUInt(PendingSize);
          if not Result then
            Exit;

          if (Processed + WindowPos) = 0 then
            PricePrevByte := 0
          else
            PricePrevByte := Pending[LiteralRelativePos - 1];
          PriceLitState := (((UInt32(Processed) + WindowPos) and LpMask) shl LcBits) +
            (UInt32(PricePrevByte) shr LcShift);
          PriceLiteralOffset := NativeUInt(PriceLitState) * LZMA_LITERAL_PROB_COUNT;
          UseMatchedLiteral := (Node.State >= TLzmaEncoderConstants.kNumLitStates) and
            (Node.Reps[0] > 0) and (UInt64(Node.Reps[0]) <= Processed + WindowPos) and
            (NativeUInt(Node.Reps[0]) <= LiteralRelativePos);
          if UseMatchedLiteral then
            MatchByteForLiteral := Pending[LiteralRelativePos - NativeUInt(Node.Reps[0])]
          else
            MatchByteForLiteral := 0;

          LiteralInput.Enabled := True;
          LiteralInput.LiteralProbs := PLzmaLiteralProbs(@Literals[PriceLiteralOffset])^;
          LiteralInput.Value := Pending[LiteralRelativePos];
          LiteralInput.UseMatchedLiteral := UseMatchedLiteral;
          LiteralInput.MatchByte := MatchByteForLiteral;
        end;

      RepResolver :=
        procedure(const WindowPos: UInt32; const NodeReps: TLzmaOptimumReps;
          out RepLens: TLzmaOptimumRepLens)
        var
          MaxLen: UInt32;
          RepIndex: Integer;
          RelativePos: NativeUInt;
          RepDistance: UInt32;
        begin
          FillChar(RepLens, SizeOf(RepLens), 0);
          RelativePos := BaseIndex + NativeUInt(WindowPos);
          if RelativePos >= NativeUInt(PendingSize) then
            Exit;
          for RepIndex := Low(NodeReps) to High(NodeReps) do
          begin
            RepDistance := NodeReps[RepIndex];
            if (RepDistance = 0) or (UInt64(RepDistance) > Processed + WindowPos) or
              (NativeUInt(RepDistance) > RelativePos) then
              Continue;
            MaxLen := UInt32(NativeUInt(PendingSize) - RelativePos);
            if MaxLen > TLzmaEncoderConstants.kMatchMaxLen then
              MaxLen := TLzmaEncoderConstants.kMatchMaxLen;
            if MaxLen > EffectiveFastBytes then
              MaxLen := EffectiveFastBytes;
            RepLens[RepIndex] := LzmaCountMatchingBytes(Pending, RelativePos,
              RelativePos - NativeUInt(RepDistance), MaxLen);
          end;
        end;

      if not LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
        LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPrices,
        RepLenPrices, DistancePrices) then
        Exit;

      if not GetDirectBaselinePrice(BaselinePrice, InitialTargetEnd) then
        Exit;
      if not LzmaOptimumSelectWindowTarget(Nodes, InitialTargetEnd, WindowEnd,
        BaselinePrice, TargetEnd, TargetPrice) then
        Exit;
      if (TargetEnd > EffectiveFastBytes) and
        (Nodes[Integer(TargetEnd)].Extra = 0) then
        Exit;
      if not QueueOptimumReplayPath(Nodes, TargetEnd, ReplayLen, ReplayBack) then
        Exit;

      WindowLen := ReplayLen;
      WindowBack := ReplayBack;
      Result := WindowLen > 0;
      finally
        FreeTempMatchFinder;
      end;
    end;
  begin
    Back := UInt32($FFFFFFFF);
    Len := 1;
    Result := True;
    if TryPopOptimumReplayDecision(Len, Back) then
      Exit;
    if NumAvailAtCurrent < TLzmaEncoderConstants.kMatchMinLen then
      Exit;

    BestRepIndex := -1;
    BestRepLen := 0;
    for RepIndex := 0 to 3 do
    begin
      TestLen := MatchLenAtDistance(Reps[RepIndex]);
      if TestLen > EffectiveFastBytes then
        TestLen := EffectiveFastBytes;
      if TestLen > BestRepLen then
      begin
        BestRepLen := TestLen;
        BestRepIndex := RepIndex;
      end;
    end;

    Cur := CurrentIndex;
    ReadMatchFinderMatchesAt(NativeUInt(Cur), Matches);
    BestMatchDistance := 0;
    BestMatchLen := 0;
    for MatchIndex := 0 to Matches.Count - 1 do
    begin
      TestLen := Matches.Items[MatchIndex].Length;
      if TestLen > EffectiveFastBytes then
        TestLen := EffectiveFastBytes;
      if (TestLen > BestMatchLen) or
        ((TestLen = BestMatchLen) and (BestMatchDistance <> 0) and
         ChangePair(Matches.Items[MatchIndex].Distance, BestMatchDistance)) then
      begin
        BestMatchLen := TestLen;
        BestMatchDistance := Matches.Items[MatchIndex].Distance;
      end;
    end;

    if (BestRepLen >= TLzmaEncoderConstants.kMatchMinLen) and (BestRepLen >= BestMatchLen) then
    begin
      Len := BestRepLen;
      Back := UInt32(BestRepIndex);
    end
    else if BestMatchLen >= TLzmaEncoderConstants.kMatchMinLen then
    begin
      Len := BestMatchLen;
      Back := BestMatchDistance + 3;
    end;

    if TryGetOptimumWindowDecision(Len, Back, WindowLen, WindowBack) then
    begin
      Len := WindowLen;
      Back := WindowBack;
    end;
  end;

  procedure MoveRepToFront(const RepIndex: Integer);
  var
    Distance: UInt32;
  begin
    if RepIndex = 0 then
      Exit;
    Distance := Reps[RepIndex];
    case RepIndex of
      1:
        Reps[1] := Reps[0];
      2:
        begin
          Reps[2] := Reps[1];
          Reps[1] := Reps[0];
        end;
    else
      Reps[3] := Reps[2];
      Reps[2] := Reps[1];
      Reps[1] := Reps[0];
    end;
    Reps[0] := Distance;
  end;

  procedure EncodeOneLiteral;
  var
    Cur: NativeInt;
    MatchByte: Byte;
    PrevByte: Byte;
    Value: Byte;
  begin
    Cur := CurrentIndex;
    Value := Pending[Cur];
    PosState := UInt32(Processed) and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 0);
    if Processed = 0 then
      PrevByte := 0
    else
      PrevByte := Pending[Cur - 1];
    LitState := ((UInt32(Processed) and LpMask) shl LcBits) +
      (UInt32(PrevByte) shr LcShift);
    LiteralOffset := NativeUInt(LitState) * $300;

    if (State >= TLzmaEncoderConstants.kNumLitStates) and (UInt64(Reps[0]) <= Processed) then
    begin
      if UInt64(Reps[0]) > UInt64(Cur) then
        RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA stream encoder compacted active literal history');
      MatchByte := Pending[Cur - NativeInt(Reps[0])];
      Encoder.EncodeMatchedLiteral(Literals[LiteralOffset], Value, MatchByte);
    end
    else
      Encoder.EncodeLiteral(Literals[LiteralOffset], Value);
    State := LZMA_STATE_LITERAL_NEXT[State];
    Inc(Processed);
    MaybeReportProgress;
  end;

  procedure EncodeOneRep(const RepIndex: Integer; const Len: UInt32);
  begin
    PosState := UInt32(Processed) and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 1);
    Encoder.EncodeBit(IsRep[State], 1);

    if (RepIndex = 0) and (Len = 1) then
    begin
      Encoder.EncodeBit(IsRepG0[State], 0);
      Encoder.EncodeBit(IsRep0Long[State][PosState], 0);
      State := LZMA_STATE_SHORT_REP_NEXT[State];
    end
    else
    begin
      if RepIndex = 0 then
      begin
        Encoder.EncodeBit(IsRepG0[State], 0);
        Encoder.EncodeBit(IsRep0Long[State][PosState], 1);
      end
      else
      begin
        Encoder.EncodeBit(IsRepG0[State], 1);
        if RepIndex = 1 then
          Encoder.EncodeBit(IsRepG1[State], 0)
        else
        begin
          Encoder.EncodeBit(IsRepG1[State], 1);
          Encoder.EncodeBit(IsRepG2[State], UInt32(Ord(RepIndex <> 2)));
        end;
        MoveRepToFront(RepIndex);
      end;
      EncodeLenSymbol(Encoder, RepLenEncoder, Len - TLzmaEncoderConstants.kMatchMinLen, PosState);
      State := LZMA_STATE_REP_NEXT[State];
    end;

    Inc(Processed, Len);
    MaybeReportProgress;
  end;

  procedure EncodeOneMatch(const Len, Distance: UInt32);
  begin
    PosState := UInt32(Processed) and PbMask;
    Encoder.EncodeBit(IsMatch[State][PosState], 1);
    Encoder.EncodeBit(IsRep[State], 0);
    EncodeLenSymbol(Encoder, LenEncoder, Len - TLzmaEncoderConstants.kMatchMinLen, PosState);
    EncodeDistance(Encoder, PosSlot, PosDecoders, Align, Len, Distance);
    Reps[3] := Reps[2];
    Reps[2] := Reps[1];
    Reps[1] := Reps[0];
    Reps[0] := Distance;
    State := LZMA_STATE_MATCH_NEXT[State];
    Inc(Processed, Len);
    MaybeReportProgress;
  end;

  procedure EncodeEndMarker;
  var
    MarkerPosState: UInt32;
  begin
    MarkerPosState := UInt32(Processed) and PbMask;
    Encoder.EncodeBit(IsMatch[State][MarkerPosState], 1);
    Encoder.EncodeBit(IsRep[State], 0);
    EncodeLenSymbol(Encoder, LenEncoder, 0, MarkerPosState);
    Encoder.BitTreeEncode(PosSlot[0][0], TLzmaEncoderConstants.kNumPosSlotBits,
      (UInt32(1) shl TLzmaEncoderConstants.kNumPosSlotBits) - 1);
    Encoder.EncodeDirectBits((UInt32(1) shl (30 - TLzmaEncoderConstants.kNumAlignBits)) - 1,
      30 - TLzmaEncoderConstants.kNumAlignBits);
    Encoder.BitTreeReverseEncode(Align[0], TLzmaEncoderConstants.kNumAlignBits,
      TLzmaEncoderConstants.kAlignTableSize - 1);
    State := LZMA_STATE_MATCH_NEXT[State];
  end;

  procedure EncodeNextDecision;
  var
    Back: UInt32;
    Len: UInt32;
  begin
    GetBestDecision(Len, Back);
    if Back = UInt32($FFFFFFFF) then
      EncodeOneLiteral
    else if Back < 4 then
      EncodeOneRep(Integer(Back), Len)
    else
      EncodeOneMatch(Len, Back - 3);
  end;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');
  if Props.Lc > 8 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lc property');
  if Props.Lp > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lp property');
  if Props.Pb > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA pb property');

  InitProbArray(IsMatch, TLzmaEncoderConstants.kNumStates *
    TLzmaEncoderConstants.kNumPosStatesMax);
  InitProbArray(IsRep, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG0, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG1, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRepG2, TLzmaEncoderConstants.kNumStates);
  InitProbArray(IsRep0Long, TLzmaEncoderConstants.kNumStates *
    TLzmaEncoderConstants.kNumPosStatesMax);
  InitProbArray(PosSlot, TLzmaEncoderConstants.kNumLenToPosStates *
    (UInt32(1) shl TLzmaEncoderConstants.kNumPosSlotBits));
  InitProbArray(PosDecoders, Length(PosDecoders));
  InitProbArray(Align, TLzmaEncoderConstants.kAlignTableSize);
  InitLenEncoder(LenEncoder);
  InitLenEncoder(RepLenEncoder);
  if Profile.FastBytes < 5 then
    EffectiveFastBytes := 5
  else if Profile.FastBytes > Integer(TLzmaEncoderConstants.kMatchMaxLen) then
    EffectiveFastBytes := TLzmaEncoderConstants.kMatchMaxLen
  else
    EffectiveFastBytes := UInt32(Profile.FastBytes);
  NumPosStates := UInt32(1) shl Props.Pb;
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenPriceEncoder(LenPrices, EffectiveFastBytes);
  LzmaInitLenPriceEncoder(RepLenPrices, EffectiveFastBytes);
  LzmaInitDistancePriceEncoder(DistancePrices, Props.DictionarySize);
  RefreshOptimumPriceTables;
  SetLength(Literals, $300 shl (Props.Lc + Props.Lp));
  if Length(Literals) <> 0 then
    InitProbArray(Literals[0], Length(Literals));
  PbMask := (UInt32(1) shl Props.Pb) - 1;
  LpMask := (UInt32(1) shl Props.Lp) - 1;
  LcBits := Props.Lc;
  LcShift := 8 - LcBits;
  MaxSearchDistance := Profile.CutValue;
  if MaxSearchDistance < 64 then
    MaxSearchDistance := 64;
  if MaxSearchDistance > 4096 then
    MaxSearchDistance := 4096;
  if UInt64(MaxSearchDistance) > Props.DictionarySize then
    MaxSearchDistance := UInt32(Props.DictionarySize);
  HistoryKeep := UInt64(MaxSearchDistance) + TLzmaEncoderConstants.kMatchMaxLen + 16;

  GreedyFinder := nil;
  Hc4Finder := nil;
  Hc5Finder := nil;
  Bt4Finder := nil;
  Encoder := TLzmaRangeEncoder.Create(Destination);
  try
    Encoder.Init;
    SetLength(Buffer, kStreamBufferSize);
    PendingBase := 0;
    PendingSize := 0;
    FinderInsertedUntil := 0;
    Processed := 0;
    NextProgressAt := kProgressInterval;
    State := 0;
    Reps[0] := 1;
    Reps[1] := 1;
    Reps[2] := 1;
    Reps[3] := 1;
    ClearOptimumReplayQueue;
    MatchFinderDirty := True;
    InputEof := False;
    repeat
      if not InputEof then
      begin
        Count := ReadAvailable(Source, Buffer[0], Length(Buffer));
        if Count = 0 then
          InputEof := True
        else
          AppendPending(Buffer[0], Count);
      end;

      while PendingAvailable > 0 do
      begin
        if (not InputEof) and (PendingAvailable <= TLzmaEncoderConstants.kMatchMaxLen) then
          Break;
        EncodeNextDecision;
        CompactPending;
      end;
    until InputEof and (PendingAvailable = 0);

    if WriteEndMarker then
      EncodeEndMarker;
    ReportProgress(Progress, Processed, Encoder.FCommittedOutputSize);
    Encoder.FlushData;
  finally
    FreeMatchFinder;
    Encoder.Free;
  end;
end;

end.
