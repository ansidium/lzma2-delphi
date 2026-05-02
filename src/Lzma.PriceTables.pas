unit Lzma.PriceTables;

interface

uses
  System.SysUtils,
  Lzma.RangeCoder,
  Lzma.Types;

const
  LZMA_NUM_MOVE_REDUCING_BITS = 4;
  LZMA_NUM_BIT_PRICE_SHIFT_BITS = 4;
  LZMA_PROB_PRICE_COUNT = LZMA_BIT_MODEL_TOTAL shr LZMA_NUM_MOVE_REDUCING_BITS;
  LZMA_NUM_PB_STATES_MAX = 1 shl 4;
  LZMA_LEN_NUM_LOW_BITS = 3;
  LZMA_LEN_NUM_LOW_SYMBOLS = 1 shl LZMA_LEN_NUM_LOW_BITS;
  LZMA_LEN_NUM_HIGH_BITS = 8;
  LZMA_LEN_NUM_HIGH_SYMBOLS = 1 shl LZMA_LEN_NUM_HIGH_BITS;
  LZMA_LEN_NUM_SYMBOLS_TOTAL = LZMA_LEN_NUM_LOW_SYMBOLS * 2 + LZMA_LEN_NUM_HIGH_SYMBOLS;
  LZMA_NUM_LEN_TO_POS_STATES = 4;
  LZMA_NUM_POS_SLOT_BITS = 6;
  LZMA_DIST_TABLE_SIZE_MAX = 32 * 2;
  LZMA_START_POS_MODEL_INDEX = 4;
  LZMA_END_POS_MODEL_INDEX = 14;
  LZMA_NUM_FULL_DISTANCES = 1 shl (LZMA_END_POS_MODEL_INDEX shr 1);
  LZMA_NUM_ALIGN_BITS = 4;
  LZMA_ALIGN_TABLE_SIZE = 1 shl LZMA_NUM_ALIGN_BITS;
  LZMA_LITERAL_PROB_COUNT = $300;

type
  TLzmaProbPrices = array[0..LZMA_PROB_PRICE_COUNT - 1] of UInt32;
  TLzmaLenLowProbs = array[0..LZMA_NUM_PB_STATES_MAX * LZMA_LEN_NUM_LOW_SYMBOLS * 2 - 1] of CLzmaProb;
  TLzmaLenHighProbs = array[0..LZMA_LEN_NUM_HIGH_SYMBOLS - 1] of CLzmaProb;
  TLzmaLenPrices = array[0..LZMA_NUM_PB_STATES_MAX - 1, 0..LZMA_LEN_NUM_SYMBOLS_TOTAL - 1] of UInt32;
  TLzmaLenPriceEncoder = record
    TableSize: UInt32;
    NumPosStates: UInt32;
    Prices: TLzmaLenPrices;
  end;
  TLzmaPosSlotProbs = array[0..LZMA_NUM_LEN_TO_POS_STATES - 1,
    0..(1 shl LZMA_NUM_POS_SLOT_BITS) - 1] of CLzmaProb;
  TLzmaPosDecoderProbs = array[0..LZMA_NUM_FULL_DISTANCES - 1] of CLzmaProb;
  TLzmaAlignProbs = array[0..LZMA_ALIGN_TABLE_SIZE - 1] of CLzmaProb;
  TLzmaLiteralProbs = array[0..LZMA_LITERAL_PROB_COUNT - 1] of CLzmaProb;
  TLzmaPosSlotPrices = array[0..LZMA_NUM_LEN_TO_POS_STATES - 1,
    0..LZMA_DIST_TABLE_SIZE_MAX - 1] of UInt32;
  TLzmaDistancePrices = array[0..LZMA_NUM_LEN_TO_POS_STATES - 1,
    0..LZMA_NUM_FULL_DISTANCES - 1] of UInt32;
  TLzmaAlignPrices = array[0..LZMA_ALIGN_TABLE_SIZE - 1] of UInt32;
  TLzmaDistancePriceEncoder = record
    DistTableSize: UInt32;
    PosSlotPrices: TLzmaPosSlotPrices;
    DistancePrices: TLzmaDistancePrices;
    AlignPrices: TLzmaAlignPrices;
  end;

procedure LzmaInitProbPrices(var Prices: TLzmaProbPrices);
function LzmaBitPrice(const Prices: TLzmaProbPrices; const Prob: CLzmaProb; const Bit: UInt32): UInt32; inline;
procedure LzmaInitLenProbs(var Low: TLzmaLenLowProbs; var High: TLzmaLenHighProbs);
procedure LzmaUpdateLenPrices(var Prices: TLzmaLenPrices; const Low: TLzmaLenLowProbs;
  const High: TLzmaLenHighProbs; const NumPosStates, TableSize: UInt32;
  const ProbPrices: TLzmaProbPrices);
procedure LzmaInitLenPriceEncoder(var Encoder: TLzmaLenPriceEncoder; const FastBytes: UInt32);
procedure LzmaUpdateLenPriceEncoder(var Encoder: TLzmaLenPriceEncoder; const Low: TLzmaLenLowProbs;
  const High: TLzmaLenHighProbs; const NumPosStates: UInt32; const ProbPrices: TLzmaProbPrices);
function LzmaLenPrice(const Encoder: TLzmaLenPriceEncoder; const PosState, Len: UInt32): UInt32;
procedure LzmaInitDistanceProbs(var PosSlot: TLzmaPosSlotProbs; var PosDecoders: TLzmaPosDecoderProbs;
  var Align: TLzmaAlignProbs);
procedure LzmaInitDistancePriceEncoder(var Encoder: TLzmaDistancePriceEncoder; const DictionarySize: UInt64);
procedure LzmaUpdateDistancePriceEncoder(var Encoder: TLzmaDistancePriceEncoder;
  const PosSlot: TLzmaPosSlotProbs; const PosDecoders: TLzmaPosDecoderProbs;
  const Align: TLzmaAlignProbs; const ProbPrices: TLzmaProbPrices);
function LzmaAlignPrice(const Encoder: TLzmaDistancePriceEncoder; const Align: UInt32): UInt32;
function LzmaReducedDistancePrice(const Encoder: TLzmaDistancePriceEncoder; const LenState,
  ReducedDistance: UInt32): UInt32;
function LzmaMatchDistancePrice(const Encoder: TLzmaDistancePriceEncoder; const Len,
  ActualDistance: UInt32): UInt32;
procedure LzmaInitLiteralProbs(var Probs: TLzmaLiteralProbs);
function LzmaLiteralPrice(const Probs: TLzmaLiteralProbs; const Value: Byte;
  const ProbPrices: TLzmaProbPrices): UInt32;
function LzmaMatchedLiteralPrice(const Probs: TLzmaLiteralProbs; const Value, MatchByte: Byte;
  const ProbPrices: TLzmaProbPrices): UInt32;
function LzmaNormalMatchPrefixPrice(const ProbPrices: TLzmaProbPrices; const IsMatchProb,
  IsRepProb: CLzmaProb): UInt32;
function LzmaRepMatchPrefixPrice(const ProbPrices: TLzmaProbPrices; const IsMatchProb,
  IsRepProb: CLzmaProb): UInt32;
function LzmaShortRepPrice(const ProbPrices: TLzmaProbPrices; const IsRepG0Prob,
  IsRep0LongProb: CLzmaProb): UInt32;
function LzmaRep0LongPrice(const ProbPrices: TLzmaProbPrices; const IsRepG0Prob,
  IsRep0LongProb: CLzmaProb): UInt32;
function LzmaPureRepPrice(const ProbPrices: TLzmaProbPrices; const IsRepG0Prob,
  IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb; const RepIndex: UInt32): UInt32;

implementation

function Price0(const Prices: TLzmaProbPrices; const Prob: CLzmaProb): UInt32; inline;
begin
  Result := Prices[Prob shr LZMA_NUM_MOVE_REDUCING_BITS];
end;

function Price1(const Prices: TLzmaProbPrices; const Prob: CLzmaProb): UInt32; inline;
begin
  Result := Prices[(Prob xor (LZMA_BIT_MODEL_TOTAL - 1)) shr LZMA_NUM_MOVE_REDUCING_BITS];
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

procedure SetPrices3(const Probs: TLzmaLenLowProbs; const ProbOffset: NativeInt;
  const StartPrice: UInt32; var Prices: TLzmaLenPrices; const PosState, PriceOffset: UInt32;
  const ProbPrices: TLzmaProbPrices);
var
  I: UInt32;
  Price: UInt32;
  Prob: CLzmaProb;
begin
  I := 0;
  while I < LZMA_LEN_NUM_LOW_SYMBOLS do
  begin
    Price := StartPrice;
    Price := Price + LzmaBitPrice(ProbPrices, Probs[ProbOffset + 1], I shr 2);
    Price := Price + LzmaBitPrice(ProbPrices, Probs[ProbOffset + 2 + (I shr 2)], (I shr 1) and 1);
    Prob := Probs[ProbOffset + 4 + (I shr 1)];
    Prices[PosState][PriceOffset + I] := Price + Price0(ProbPrices, Prob);
    Prices[PosState][PriceOffset + I + 1] := Price + Price1(ProbPrices, Prob);
    Inc(I, 2);
  end;
end;

procedure LzmaInitProbPrices(var Prices: TLzmaProbPrices);
var
  I: UInt32;
  J: UInt32;
  W: UInt32;
  BitCount: UInt32;
begin
  for I := 0 to High(Prices) do
  begin
    W := (I shl LZMA_NUM_MOVE_REDUCING_BITS) + (UInt32(1) shl (LZMA_NUM_MOVE_REDUCING_BITS - 1));
    BitCount := 0;
    for J := 0 to LZMA_NUM_BIT_PRICE_SHIFT_BITS - 1 do
    begin
      W := W * W;
      BitCount := BitCount shl 1;
      while W >= (UInt32(1) shl 16) do
      begin
        W := W shr 1;
        Inc(BitCount);
      end;
    end;
    Prices[I] := (UInt32(LZMA_NUM_BIT_MODEL_TOTAL_BITS) shl LZMA_NUM_BIT_PRICE_SHIFT_BITS) -
      15 - BitCount;
  end;
end;

function LzmaBitPrice(const Prices: TLzmaProbPrices; const Prob: CLzmaProb; const Bit: UInt32): UInt32;
var
  Mask: UInt32;
begin
  Mask := UInt32(0) - (Bit and 1);
  Result := Prices[(UInt32(Prob) xor (Mask and (LZMA_BIT_MODEL_TOTAL - 1))) shr
    LZMA_NUM_MOVE_REDUCING_BITS];
end;

procedure LzmaInitLenProbs(var Low: TLzmaLenLowProbs; var High: TLzmaLenHighProbs);
var
  I: Integer;
begin
  for I := 0 to Length(Low) - 1 do
    Low[I] := LZMA_PROB_INIT;
  for I := 0 to Length(High) - 1 do
    High[I] := LZMA_PROB_INIT;
end;

procedure LzmaUpdateLenPrices(var Prices: TLzmaLenPrices; const Low: TLzmaLenLowProbs;
  const High: TLzmaLenHighProbs; const NumPosStates, TableSize: UInt32;
  const ProbPrices: TLzmaProbPrices);
var
  PosState: UInt32;
  A: UInt32;
  B: UInt32;
  C: UInt32;
  I: UInt32;
  Sym: UInt32;
  Price: UInt32;
  Bit: UInt32;
  Prob: CLzmaProb;
begin
  if (NumPosStates = 0) or (NumPosStates > LZMA_NUM_PB_STATES_MAX) then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA length price pos-state count');
  if (TableSize = 0) or (TableSize > LZMA_LEN_NUM_SYMBOLS_TOTAL) then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA length price table size');

  B := Price1(ProbPrices, Low[0]);
  A := Price0(ProbPrices, Low[0]);
  C := B + Price0(ProbPrices, Low[LZMA_LEN_NUM_LOW_SYMBOLS]);
  for PosState := 0 to NumPosStates - 1 do
  begin
    SetPrices3(Low, PosState shl (1 + LZMA_LEN_NUM_LOW_BITS), A, Prices, PosState, 0, ProbPrices);
    SetPrices3(Low, (PosState shl (1 + LZMA_LEN_NUM_LOW_BITS)) + LZMA_LEN_NUM_LOW_SYMBOLS,
      C, Prices, PosState, LZMA_LEN_NUM_LOW_SYMBOLS, ProbPrices);
  end;

  if TableSize <= LZMA_LEN_NUM_LOW_SYMBOLS * 2 then
    Exit;

  B := B + Price1(ProbPrices, Low[LZMA_LEN_NUM_LOW_SYMBOLS]);
  I := TableSize - (LZMA_LEN_NUM_LOW_SYMBOLS * 2 - 1);
  I := I shr 1;
  while I <> 0 do
  begin
    Dec(I);
    Sym := I + (UInt32(1) shl (LZMA_LEN_NUM_HIGH_BITS - 1));
    Price := B;
    while Sym >= 2 do
    begin
      Bit := Sym and 1;
      Sym := Sym shr 1;
      Price := Price + LzmaBitPrice(ProbPrices, High[Sym], Bit);
    end;

    Prob := High[I + (UInt32(1) shl (LZMA_LEN_NUM_HIGH_BITS - 1))];
    Prices[0][LZMA_LEN_NUM_LOW_SYMBOLS * 2 + I * 2] := Price + Price0(ProbPrices, Prob);
    Prices[0][LZMA_LEN_NUM_LOW_SYMBOLS * 2 + I * 2 + 1] := Price + Price1(ProbPrices, Prob);
  end;

  for PosState := 1 to NumPosStates - 1 do
    for I := LZMA_LEN_NUM_LOW_SYMBOLS * 2 to TableSize - 1 do
      Prices[PosState][I] := Prices[0][I];
end;

procedure LzmaInitLenPriceEncoder(var Encoder: TLzmaLenPriceEncoder; const FastBytes: UInt32);
begin
  if FastBytes < 2 then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA fast-bytes value');

  Encoder.TableSize := FastBytes + 1 - 2;
  Encoder.NumPosStates := 0;
  if Encoder.TableSize > LZMA_LEN_NUM_SYMBOLS_TOTAL then
    Encoder.TableSize := LZMA_LEN_NUM_SYMBOLS_TOTAL;
end;

procedure LzmaUpdateLenPriceEncoder(var Encoder: TLzmaLenPriceEncoder; const Low: TLzmaLenLowProbs;
  const High: TLzmaLenHighProbs; const NumPosStates: UInt32; const ProbPrices: TLzmaProbPrices);
begin
  LzmaUpdateLenPrices(Encoder.Prices, Low, High, NumPosStates, Encoder.TableSize, ProbPrices);
  Encoder.NumPosStates := NumPosStates;
end;

function LzmaLenPrice(const Encoder: TLzmaLenPriceEncoder; const PosState, Len: UInt32): UInt32;
var
  Symbol: UInt32;
begin
  if Len < 2 then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA match length');
  Symbol := Len - 2;
  if (PosState >= Encoder.NumPosStates) or (Symbol >= Encoder.TableSize) then
    raise EArgumentOutOfRangeException.Create('LZMA length price is outside the initialized table');
  Result := Encoder.Prices[PosState][Symbol];
end;

procedure LzmaInitDistanceProbs(var PosSlot: TLzmaPosSlotProbs; var PosDecoders: TLzmaPosDecoderProbs;
  var Align: TLzmaAlignProbs);
var
  I: Integer;
  J: Integer;
begin
  for I := 0 to LZMA_NUM_LEN_TO_POS_STATES - 1 do
    for J := 0 to (1 shl LZMA_NUM_POS_SLOT_BITS) - 1 do
      PosSlot[I][J] := LZMA_PROB_INIT;
  for I := 0 to Length(PosDecoders) - 1 do
    PosDecoders[I] := LZMA_PROB_INIT;
  for I := 0 to Length(Align) - 1 do
    Align[I] := LZMA_PROB_INIT;
end;

procedure LzmaInitDistancePriceEncoder(var Encoder: TLzmaDistancePriceEncoder; const DictionarySize: UInt64);
var
  I: UInt32;
begin
  I := LZMA_END_POS_MODEL_INDEX shr 1;
  while I < 32 do
  begin
    if DictionarySize <= (UInt64(1) shl I) then
      Break;
    Inc(I);
  end;
  Encoder.DistTableSize := I * 2;
end;

procedure FillAlignPrices(var Encoder: TLzmaDistancePriceEncoder; const Align: TLzmaAlignProbs;
  const ProbPrices: TLzmaProbPrices);
var
  I: UInt32;
  Sym: UInt32;
  M: UInt32;
  Bit: UInt32;
  Price: UInt32;
  Prob: CLzmaProb;
begin
  for I := 0 to (LZMA_ALIGN_TABLE_SIZE div 2) - 1 do
  begin
    Price := 0;
    Sym := I;
    M := 1;

    Bit := Sym and 1;
    Sym := Sym shr 1;
    Price := Price + LzmaBitPrice(ProbPrices, Align[M], Bit);
    M := (M shl 1) + Bit;

    Bit := Sym and 1;
    Sym := Sym shr 1;
    Price := Price + LzmaBitPrice(ProbPrices, Align[M], Bit);
    M := (M shl 1) + Bit;

    Bit := Sym and 1;
    Price := Price + LzmaBitPrice(ProbPrices, Align[M], Bit);
    M := (M shl 1) + Bit;

    Prob := Align[M];
    Encoder.AlignPrices[I] := Price + Price0(ProbPrices, Prob);
    Encoder.AlignPrices[I + 8] := Price + Price1(ProbPrices, Prob);
  end;
end;

procedure FillDistancesPrices(var Encoder: TLzmaDistancePriceEncoder; const PosSlot: TLzmaPosSlotProbs;
  const PosDecoders: TLzmaPosDecoderProbs; const ProbPrices: TLzmaProbPrices);
var
  TempPrices: array[0..LZMA_NUM_FULL_DISTANCES - 1] of UInt32;
  I: UInt32;
  Lps: UInt32;
  Slot: UInt32;
  PosSlotValue: UInt32;
  FooterBits: UInt32;
  Base: UInt32;
  ProbOffset: UInt32;
  Price: UInt32;
  M: UInt32;
  Sym: UInt32;
  Offset: UInt32;
  Bit: UInt32;
  Prob: CLzmaProb;
  DistTableSize2: UInt32;
  Delta: UInt32;
  SlotPrice: UInt32;
begin
  for I := LZMA_START_POS_MODEL_INDEX div 2 to (LZMA_NUM_FULL_DISTANCES div 2) - 1 do
  begin
    PosSlotValue := GetPosSlot(I);
    FooterBits := (PosSlotValue shr 1) - 1;
    Base := (UInt32(2) or (PosSlotValue and 1)) shl FooterBits;
    ProbOffset := Base * 2;
    Price := 0;
    M := 1;
    Sym := I;
    Offset := UInt32(1) shl FooterBits;
    Base := Base + I;

    while FooterBits <> 0 do
    begin
      Bit := Sym and 1;
      Sym := Sym shr 1;
      Price := Price + LzmaBitPrice(ProbPrices, PosDecoders[ProbOffset + M], Bit);
      M := (M shl 1) + Bit;
      Dec(FooterBits);
    end;

    Prob := PosDecoders[ProbOffset + M];
    TempPrices[Base] := Price + Price0(ProbPrices, Prob);
    TempPrices[Base + Offset] := Price + Price1(ProbPrices, Prob);
  end;

  DistTableSize2 := (Encoder.DistTableSize + 1) shr 1;
  for Lps := 0 to LZMA_NUM_LEN_TO_POS_STATES - 1 do
  begin
    for Slot := 0 to DistTableSize2 - 1 do
    begin
      Sym := Slot + (UInt32(1) shl (LZMA_NUM_POS_SLOT_BITS - 1));

      Bit := Sym and 1;
      Sym := Sym shr 1;
      Price := LzmaBitPrice(ProbPrices, PosSlot[Lps][Sym], Bit);

      Bit := Sym and 1;
      Sym := Sym shr 1;
      Price := Price + LzmaBitPrice(ProbPrices, PosSlot[Lps][Sym], Bit);

      Bit := Sym and 1;
      Sym := Sym shr 1;
      Price := Price + LzmaBitPrice(ProbPrices, PosSlot[Lps][Sym], Bit);

      Bit := Sym and 1;
      Sym := Sym shr 1;
      Price := Price + LzmaBitPrice(ProbPrices, PosSlot[Lps][Sym], Bit);

      Bit := Sym and 1;
      Sym := Sym shr 1;
      Price := Price + LzmaBitPrice(ProbPrices, PosSlot[Lps][Sym], Bit);

      Prob := PosSlot[Lps][Slot + (UInt32(1) shl (LZMA_NUM_POS_SLOT_BITS - 1))];
      Encoder.PosSlotPrices[Lps][Slot * 2] := Price + Price0(ProbPrices, Prob);
      Encoder.PosSlotPrices[Lps][Slot * 2 + 1] := Price + Price1(ProbPrices, Prob);
    end;

    Delta := UInt32(((LZMA_END_POS_MODEL_INDEX div 2 - 1) - LZMA_NUM_ALIGN_BITS) shl
      LZMA_NUM_BIT_PRICE_SHIFT_BITS);
    for Slot := LZMA_END_POS_MODEL_INDEX div 2 to DistTableSize2 - 1 do
    begin
      Encoder.PosSlotPrices[Lps][Slot * 2] := Encoder.PosSlotPrices[Lps][Slot * 2] + Delta;
      Encoder.PosSlotPrices[Lps][Slot * 2 + 1] := Encoder.PosSlotPrices[Lps][Slot * 2 + 1] + Delta;
      Inc(Delta, UInt32(1) shl LZMA_NUM_BIT_PRICE_SHIFT_BITS);
    end;

    Encoder.DistancePrices[Lps][0] := Encoder.PosSlotPrices[Lps][0];
    Encoder.DistancePrices[Lps][1] := Encoder.PosSlotPrices[Lps][1];
    Encoder.DistancePrices[Lps][2] := Encoder.PosSlotPrices[Lps][2];
    Encoder.DistancePrices[Lps][3] := Encoder.PosSlotPrices[Lps][3];

    I := 4;
    while I < LZMA_NUM_FULL_DISTANCES do
    begin
      SlotPrice := Encoder.PosSlotPrices[Lps][GetPosSlot(I)];
      Encoder.DistancePrices[Lps][I] := SlotPrice + TempPrices[I];
      Encoder.DistancePrices[Lps][I + 1] := SlotPrice + TempPrices[I + 1];
      Inc(I, 2);
    end;
  end;
end;

procedure LzmaUpdateDistancePriceEncoder(var Encoder: TLzmaDistancePriceEncoder;
  const PosSlot: TLzmaPosSlotProbs; const PosDecoders: TLzmaPosDecoderProbs;
  const Align: TLzmaAlignProbs; const ProbPrices: TLzmaProbPrices);
begin
  if (Encoder.DistTableSize = 0) or (Encoder.DistTableSize > LZMA_DIST_TABLE_SIZE_MAX) then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA distance table size');
  FillAlignPrices(Encoder, Align, ProbPrices);
  FillDistancesPrices(Encoder, PosSlot, PosDecoders, ProbPrices);
end;

function LzmaAlignPrice(const Encoder: TLzmaDistancePriceEncoder; const Align: UInt32): UInt32;
begin
  if Align >= LZMA_ALIGN_TABLE_SIZE then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA align price index');
  Result := Encoder.AlignPrices[Align];
end;

function LzmaReducedDistancePrice(const Encoder: TLzmaDistancePriceEncoder; const LenState,
  ReducedDistance: UInt32): UInt32;
var
  Slot: UInt32;
begin
  if LenState >= LZMA_NUM_LEN_TO_POS_STATES then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA distance len-state');
  if ReducedDistance < LZMA_NUM_FULL_DISTANCES then
    Exit(Encoder.DistancePrices[LenState][ReducedDistance]);

  Slot := GetPosSlot(ReducedDistance);
  if Slot >= Encoder.DistTableSize then
    raise EArgumentOutOfRangeException.Create('LZMA distance price is outside the initialized table');
  Result := Encoder.PosSlotPrices[LenState][Slot] +
    Encoder.AlignPrices[ReducedDistance and (LZMA_ALIGN_TABLE_SIZE - 1)];
end;

function LzmaLenToPosState(const Len: UInt32): UInt32;
begin
  if Len < 2 then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA match length');
  if Len < LZMA_NUM_LEN_TO_POS_STATES + 1 then
    Result := Len - 2
  else
    Result := LZMA_NUM_LEN_TO_POS_STATES - 1;
end;

function LzmaMatchDistancePrice(const Encoder: TLzmaDistancePriceEncoder; const Len,
  ActualDistance: UInt32): UInt32;
begin
  if ActualDistance = 0 then
    raise EArgumentOutOfRangeException.Create('Invalid LZMA match distance');
  Result := LzmaReducedDistancePrice(Encoder, LzmaLenToPosState(Len), ActualDistance - 1);
end;

procedure LzmaInitLiteralProbs(var Probs: TLzmaLiteralProbs);
var
  I: Integer;
begin
  for I := 0 to Length(Probs) - 1 do
    Probs[I] := LZMA_PROB_INIT;
end;

function LzmaLiteralPrice(const Probs: TLzmaLiteralProbs; const Value: Byte;
  const ProbPrices: TLzmaProbPrices): UInt32;
var
  Sym: UInt32;
  Bit: UInt32;
begin
  Result := 0;
  Sym := UInt32(Value) or $100;
  repeat
    Bit := Sym and 1;
    Sym := Sym shr 1;
    Result := Result + LzmaBitPrice(ProbPrices, Probs[Sym], Bit);
  until Sym < 2;
end;

function LzmaMatchedLiteralPrice(const Probs: TLzmaLiteralProbs; const Value, MatchByte: Byte;
  const ProbPrices: TLzmaProbPrices): UInt32;
var
  Sym: UInt32;
  Match: UInt32;
  Offset: UInt32;
  Bit: UInt32;
begin
  Result := 0;
  Offset := $100;
  Sym := UInt32(Value) or $100;
  Match := MatchByte;
  repeat
    Match := Match shl 1;
    Bit := (Sym shr 7) and 1;
    Result := Result + LzmaBitPrice(ProbPrices,
      Probs[Offset + (Match and Offset) + (Sym shr 8)], Bit);
    Sym := Sym shl 1;
    Offset := Offset and not (Match xor Sym);
  until Sym >= $10000;
end;

function LzmaNormalMatchPrefixPrice(const ProbPrices: TLzmaProbPrices; const IsMatchProb,
  IsRepProb: CLzmaProb): UInt32;
begin
  Result := Price1(ProbPrices, IsMatchProb) + Price0(ProbPrices, IsRepProb);
end;

function LzmaRepMatchPrefixPrice(const ProbPrices: TLzmaProbPrices; const IsMatchProb,
  IsRepProb: CLzmaProb): UInt32;
begin
  Result := Price1(ProbPrices, IsMatchProb) + Price1(ProbPrices, IsRepProb);
end;

function LzmaShortRepPrice(const ProbPrices: TLzmaProbPrices; const IsRepG0Prob,
  IsRep0LongProb: CLzmaProb): UInt32;
begin
  Result := Price0(ProbPrices, IsRepG0Prob) + Price0(ProbPrices, IsRep0LongProb);
end;

function LzmaRep0LongPrice(const ProbPrices: TLzmaProbPrices; const IsRepG0Prob,
  IsRep0LongProb: CLzmaProb): UInt32;
begin
  Result := Price0(ProbPrices, IsRepG0Prob) + Price1(ProbPrices, IsRep0LongProb);
end;

function LzmaPureRepPrice(const ProbPrices: TLzmaProbPrices; const IsRepG0Prob,
  IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb; const RepIndex: UInt32): UInt32;
begin
  case RepIndex of
    0:
      Result := LzmaRep0LongPrice(ProbPrices, IsRepG0Prob, IsRep0LongProb);
    1:
      Result := Price1(ProbPrices, IsRepG0Prob) + Price0(ProbPrices, IsRepG1Prob);
    2:
      Result := Price1(ProbPrices, IsRepG0Prob) + Price1(ProbPrices, IsRepG1Prob) +
        Price0(ProbPrices, IsRepG2Prob);
    3:
      Result := Price1(ProbPrices, IsRepG0Prob) + Price1(ProbPrices, IsRepG1Prob) +
        Price1(ProbPrices, IsRepG2Prob);
  else
    raise EArgumentOutOfRangeException.Create('Invalid LZMA rep index');
  end;
end;

end.
