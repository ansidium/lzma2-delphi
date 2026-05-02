unit Lzma.Decoder;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.Types;

type
  TLzmaDecoderState = class
  private const
    kNumStates = 12;
    kNumPosBitsMax = 4;
    kNumPosStatesMax = 1 shl kNumPosBitsMax;
    kNumLitStates = 7;
    kLenNumLowBits = 3;
    kLenNumLowSymbols = 1 shl kLenNumLowBits;
    kLenNumHighBits = 8;
    kLenNumHighSymbols = 1 shl kLenNumHighBits;
    kNumLenToPosStates = 4;
    kNumPosSlotBits = 6;
    kStartPosModelIndex = 4;
    kEndPosModelIndex = 14;
    kNumFullDistances = 1 shl (kEndPosModelIndex shr 1);
    kNumAlignBits = 4;
    kAlignTableSize = 1 shl kNumAlignBits;
    kMatchMinLen = 2;
    kOutputBufferSize = 1 shl 18;
  private type
    TProbArray = array[0..MaxInt div SizeOf(CLzmaProb) - 1] of CLzmaProb;
    PProbArray = ^TProbArray;
    TProbDynArray = array of CLzmaProb;

    TLenDecoder = record
      Choice: CLzmaProb;
      Choice2: CLzmaProb;
      Low: array[0..kNumPosStatesMax - 1, 0..kLenNumLowSymbols - 1] of CLzmaProb;
      Mid: array[0..kNumPosStatesMax - 1, 0..kLenNumLowSymbols - 1] of CLzmaProb;
      High: array[0..kLenNumHighSymbols - 1] of CLzmaProb;
    end;

    TDecodeSnapshot = record
      InputPos: NativeUInt;
      Processed: UInt64;
      State: UInt32;
      Reps: array[0..3] of UInt32;
      Range: UInt32;
      Code: UInt32;
      NeedRangeInit: Boolean;
      IsMatch: array[0..kNumStates - 1, 0..kNumPosStatesMax - 1] of CLzmaProb;
      IsRep: array[0..kNumStates - 1] of CLzmaProb;
      IsRepG0: array[0..kNumStates - 1] of CLzmaProb;
      IsRepG1: array[0..kNumStates - 1] of CLzmaProb;
      IsRepG2: array[0..kNumStates - 1] of CLzmaProb;
      IsRep0Long: array[0..kNumStates - 1, 0..kNumPosStatesMax - 1] of CLzmaProb;
      PosSlot: array[0..kNumLenToPosStates - 1, 0..(1 shl kNumPosSlotBits) - 1] of CLzmaProb;
      PosDecoders: array[0..kNumFullDistances - kEndPosModelIndex] of CLzmaProb;
      Align: array[0..kAlignTableSize - 1] of CLzmaProb;
      LenDecoder: TLenDecoder;
      RepLenDecoder: TLenDecoder;
      Literals: TProbDynArray;
    end;
  private
    FProps: TLzmaProps;
    FDictionary: TBytes;
    FDictPos: NativeUInt;
    FDictFull: NativeUInt;
    FProcessed: UInt64;
    FState: UInt32;
    FReps: array[0..3] of UInt32;
    FRange: UInt32;
    FCode: UInt32;
    FNeedRangeInit: Boolean;
    FInput: TBytes;
    FInputPos: NativeUInt;
    FInputLimit: NativeUInt;
    FOutput: TStream;
    FOutputBuffer: TBytes;
    FOutputPos: NativeUInt;

    FIsMatch: array[0..kNumStates - 1, 0..kNumPosStatesMax - 1] of CLzmaProb;
    FIsRep: array[0..kNumStates - 1] of CLzmaProb;
    FIsRepG0: array[0..kNumStates - 1] of CLzmaProb;
    FIsRepG1: array[0..kNumStates - 1] of CLzmaProb;
    FIsRepG2: array[0..kNumStates - 1] of CLzmaProb;
    FIsRep0Long: array[0..kNumStates - 1, 0..kNumPosStatesMax - 1] of CLzmaProb;
    FPosSlot: array[0..kNumLenToPosStates - 1, 0..(1 shl kNumPosSlotBits) - 1] of CLzmaProb;
    FPosDecoders: array[0..kNumFullDistances - kEndPosModelIndex] of CLzmaProb;
    FAlign: array[0..kAlignTableSize - 1] of CLzmaProb;
    FLenDecoder: TLenDecoder;
    FRepLenDecoder: TLenDecoder;
    FLiterals: TProbDynArray;

    procedure InitProbArray(var Data; const Count: NativeUInt);
    procedure InitLenDecoder(var Decoder: TLenDecoder);
    procedure InitRange;
    function DecodeBit(var Prob: CLzmaProb): UInt32; inline;
    function DecodeDirectBits(const NumBits: UInt32): UInt32; inline;
    function BitTreeDecode(var Probs; const NumBits: UInt32): UInt32; inline;
    function BitTreeReverseDecode(var Probs; const NumBits: UInt32): UInt32; inline;
    function DecodeLen(var Decoder: TLenDecoder; const PosState: UInt32): UInt32; inline;
    function DecodeDistance(const Len: UInt32): UInt32; inline;
    procedure AddHistoryByte(const B: Byte);
    procedure FlushOutput; inline;
    procedure PutByte(const B: Byte); inline;
    function GetByte(const Distance: UInt32): Byte; inline;
    procedure CopyMatch(const Distance: UInt32; Len: UInt32);
    function IsUnreadRangeFlushTail: Boolean;
    procedure SaveDecodeSnapshot(out Snapshot: TDecodeSnapshot);
    procedure RestoreDecodeSnapshot(const Snapshot: TDecodeSnapshot);
    function AvailableHistory: UInt64; inline;
  public
    constructor Create(const DictionarySize: UInt64);
    procedure SetProperties(const Props: TLzmaProps);
    procedure SetLcLpPb(const EncodedProps: Byte);
    procedure ResetDictionary;
    procedure ResetState;
    procedure WriteUncompressed(const Data: TBytes; const Offset, Count: NativeUInt;
      const Destination: TStream);
    function DecodeChunk(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const UnpackSize: UInt64; const Destination: TStream;
      const Progress: TLzma2ProgressEvent = nil; const InputBase: UInt64 = 0;
      const OutputBase: UInt64 = 0): NativeUInt;
    function DecodeKnownSizePartial(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const TotalUnpackSize, OutputLimit: UInt64; const Destination: TStream;
      out ConsumedSize: NativeUInt; out Finished, NeedsMoreInput: Boolean;
      const Progress: TLzma2ProgressEvent = nil; const InputBase: UInt64 = 0;
      const OutputBase: UInt64 = 0): NativeUInt;
    function DecodeUntilEndMarker(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const Destination: TStream; const Progress: TLzma2ProgressEvent = nil;
      const InputBase: UInt64 = 0; const OutputBase: UInt64 = 0): NativeUInt;
    property InputPosition: NativeUInt read FInputPos;
    property ProcessedSize: UInt64 read FProcessed;
    property Properties: TLzmaProps read FProps;
  end;

  TLzmaRawDecoder = class
  public
    class function DecodeProperties(const Props: TBytes; out Decoded: TLzmaProps): Boolean; static;
    class procedure Decode(Source: TStream; Destination: TStream; const Props: TBytes;
      const UnpackedSize: UInt64; const Progress: TLzma2ProgressEvent = nil); static;
    class procedure DecodeUntilEndMarker(Source: TStream; Destination: TStream; const Props: TBytes;
      const Progress: TLzma2ProgressEvent = nil); static;
  end;

implementation

uses
  System.Math,
  Lzma.Errors,
  Lzma.RangeCoder,
  Lzma.Streams;

const
  LZMA_STATE_LITERAL_NEXT: array[0..11] of UInt32 = (
    0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 4, 5);
  LZMA_STATE_MATCH_NEXT: array[0..11] of UInt32 = (
    7, 7, 7, 7, 7, 7, 7, 10, 10, 10, 10, 10);
  LZMA_STATE_REP_NEXT: array[0..11] of UInt32 = (
    8, 8, 8, 8, 8, 8, 8, 11, 11, 11, 11, 11);
  LZMA_STATE_SHORT_REP_NEXT: array[0..11] of UInt32 = (
    9, 9, 9, 9, 9, 9, 9, 11, 11, 11, 11, 11);

constructor TLzmaDecoderState.Create(const DictionarySize: UInt64);
var
  DictSize: UInt64;
begin
  inherited Create;
  DictSize := DictionarySize;
  if DictSize < 4096 then
    DictSize := 4096;
  if DictSize > UInt64(High(NativeInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is too large for a Delphi dynamic array');
  SetLength(FDictionary, NativeInt(DictSize));
  FProps.Lc := 3;
  FProps.Lp := 0;
  FProps.Pb := 2;
  FProps.DictionarySize := UInt32(Min(DictSize, UInt64($FFFFFFFF)));
  SetLength(FLiterals, $300 shl (FProps.Lc + FProps.Lp));
  ResetDictionary;
  ResetState;
end;

procedure TLzmaDecoderState.SetProperties(const Props: TLzmaProps);
begin
  if Props.Lc > 8 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lc property');
  if Props.Lp > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA lp property');
  if Props.Pb > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA pb property');
  FProps := Props;
  SetLength(FLiterals, $300 shl (FProps.Lc + FProps.Lp));
  ResetState;
end;

procedure TLzmaDecoderState.SetLcLpPb(const EncodedProps: Byte);
var
  D: Byte;
  Props: TLzmaProps;
begin
  if EncodedProps >= 9 * 5 * 5 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Invalid LZMA property byte');
  D := EncodedProps;
  Props := FProps;
  Props.Lc := D mod 9;
  D := D div 9;
  Props.Pb := D div 5;
  Props.Lp := D mod 5;
  if Props.Lc + Props.Lp > 4 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'LZMA2 requires lc + lp <= 4');
  SetProperties(Props);
end;

procedure TLzmaDecoderState.ResetDictionary;
begin
  FDictPos := 0;
  FDictFull := 0;
  FProcessed := 0;
end;

procedure TLzmaDecoderState.InitProbArray(var Data; const Count: NativeUInt);
var
  P: PProbArray;
  I: NativeUInt;
begin
  P := @Data;
  for I := 0 to Count - 1 do
    P^[I] := LZMA_PROB_INIT;
end;

procedure TLzmaDecoderState.InitLenDecoder(var Decoder: TLenDecoder);
begin
  Decoder.Choice := LZMA_PROB_INIT;
  Decoder.Choice2 := LZMA_PROB_INIT;
  InitProbArray(Decoder.Low, kNumPosStatesMax * kLenNumLowSymbols);
  InitProbArray(Decoder.Mid, kNumPosStatesMax * kLenNumLowSymbols);
  InitProbArray(Decoder.High, kLenNumHighSymbols);
end;

procedure TLzmaDecoderState.ResetState;
begin
  InitProbArray(FIsMatch, kNumStates * kNumPosStatesMax);
  InitProbArray(FIsRep, kNumStates);
  InitProbArray(FIsRepG0, kNumStates);
  InitProbArray(FIsRepG1, kNumStates);
  InitProbArray(FIsRepG2, kNumStates);
  InitProbArray(FIsRep0Long, kNumStates * kNumPosStatesMax);
  InitProbArray(FPosSlot, kNumLenToPosStates * (1 shl kNumPosSlotBits));
  InitProbArray(FPosDecoders, Length(FPosDecoders));
  InitProbArray(FAlign, kAlignTableSize);
  if Length(FLiterals) <> 0 then
    InitProbArray(FLiterals[0], Length(FLiterals));
  InitLenDecoder(FLenDecoder);
  InitLenDecoder(FRepLenDecoder);
  FReps[0] := 1;
  FReps[1] := 1;
  FReps[2] := 1;
  FReps[3] := 1;
  FState := 0;
  FRange := $FFFFFFFF;
  FCode := 0;
  FNeedRangeInit := True;
end;

procedure TLzmaDecoderState.InitRange;
var
  I: Integer;
begin
  if FInputLimit - FInputPos < 5 then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range header');
  if FInput[FInputPos] <> 0 then
    RaiseLzmaError(SZ_ERROR_DATA, 'Invalid LZMA range header');
  Inc(FInputPos);
  FCode := 0;
  for I := 0 to 3 do
  begin
    FCode := (FCode shl 8) or FInput[FInputPos];
    Inc(FInputPos);
  end;
  FRange := $FFFFFFFF;
  FNeedRangeInit := False;
end;

function TLzmaDecoderState.DecodeBit(var Prob: CLzmaProb): UInt32;
var
  Bound: UInt32;
begin
  if FRange < LZMA_TOP_VALUE then
  begin
    if FInputPos >= FInputLimit then
      RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range stream');
    FRange := FRange shl 8;
    FCode := (FCode shl 8) or FInput[FInputPos];
    Inc(FInputPos);
  end;
  Bound := (FRange shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob);
  if FCode < Bound then
  begin
    FRange := Bound;
    Prob := CLzmaProb(Prob + ((LZMA_BIT_MODEL_TOTAL - Prob) shr LZMA_NUM_MOVE_BITS));
    Result := 0;
  end
  else
  begin
    FRange := FRange - Bound;
    FCode := FCode - Bound;
    Prob := CLzmaProb(Prob - (Prob shr LZMA_NUM_MOVE_BITS));
    Result := 1;
  end;
end;

function TLzmaDecoderState.DecodeDirectBits(const NumBits: UInt32): UInt32;
var
  I: UInt32;
  T: UInt32;
begin
  Result := 0;
  for I := 1 to NumBits do
  begin
    if FRange < LZMA_TOP_VALUE then
    begin
      if FInputPos >= FInputLimit then
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range stream');
      FRange := FRange shl 8;
      FCode := (FCode shl 8) or FInput[FInputPos];
      Inc(FInputPos);
    end;
    FRange := FRange shr 1;
    FCode := FCode - FRange;
    T := UInt32(0) - (FCode shr 31);
    FCode := FCode + (FRange and T);
    Result := (Result shl 1) + (T + 1);
  end;
end;

function TLzmaDecoderState.BitTreeDecode(var Probs; const NumBits: UInt32): UInt32;
var
  P: PProbArray;
  I: UInt32;
begin
  P := @Probs;
  Result := 1;
  for I := 1 to NumBits do
    Result := (Result shl 1) or DecodeBit(P^[Result]);
  Dec(Result, UInt32(1) shl NumBits);
end;

function TLzmaDecoderState.BitTreeReverseDecode(var Probs; const NumBits: UInt32): UInt32;
var
  P: PProbArray;
  I: UInt32;
  M: UInt32;
  Bit: UInt32;
begin
  P := @Probs;
  Result := 0;
  M := 1;
  for I := 0 to NumBits - 1 do
  begin
    Bit := DecodeBit(P^[M]);
    M := (M shl 1) or Bit;
    Result := Result or (Bit shl I);
  end;
end;

function TLzmaDecoderState.DecodeLen(var Decoder: TLenDecoder; const PosState: UInt32): UInt32;
begin
  if DecodeBit(Decoder.Choice) = 0 then
    Exit(BitTreeDecode(Decoder.Low[PosState][0], kLenNumLowBits));
  if DecodeBit(Decoder.Choice2) = 0 then
    Exit(kLenNumLowSymbols + BitTreeDecode(Decoder.Mid[PosState][0], kLenNumLowBits));
  Result := kLenNumLowSymbols * 2 + BitTreeDecode(Decoder.High[0], kLenNumHighBits);
end;

function TLzmaDecoderState.DecodeDistance(const Len: UInt32): UInt32;
var
  LenState: UInt32;
  PosSlot: UInt32;
  NumDirectBits: UInt32;
  Base: UInt32;
begin
  LenState := Len;
  if LenState >= kNumLenToPosStates then
    LenState := kNumLenToPosStates - 1;
  PosSlot := BitTreeDecode(FPosSlot[LenState][0], kNumPosSlotBits);
  if PosSlot < kStartPosModelIndex then
    Exit(PosSlot);

  NumDirectBits := (PosSlot shr 1) - 1;
  Base := (2 or (PosSlot and 1)) shl NumDirectBits;
  Result := Base;
  if PosSlot < kEndPosModelIndex then
    Inc(Result, BitTreeReverseDecode(FPosDecoders[Base - PosSlot], NumDirectBits))
  else
  begin
    Inc(Result, DecodeDirectBits(NumDirectBits - kNumAlignBits) shl kNumAlignBits);
    Inc(Result, BitTreeReverseDecode(FAlign[0], kNumAlignBits));
  end;
end;

procedure TLzmaDecoderState.AddHistoryByte(const B: Byte);
begin
  if Length(FDictionary) = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  FDictionary[FDictPos] := B;
  Inc(FDictPos);
  if FDictPos = NativeUInt(Length(FDictionary)) then
    FDictPos := 0;
  if FDictFull < NativeUInt(Length(FDictionary)) then
    Inc(FDictFull);
  Inc(FProcessed);
end;

procedure TLzmaDecoderState.FlushOutput;
begin
  if FOutputPos = 0 then
    Exit;
  WriteExact(FOutput, FOutputBuffer[0], FOutputPos);
  FOutputPos := 0;
end;

procedure TLzmaDecoderState.PutByte(const B: Byte);
begin
  AddHistoryByte(B);
  if Length(FOutputBuffer) = 0 then
    SetLength(FOutputBuffer, kOutputBufferSize);
  FOutputBuffer[FOutputPos] := B;
  Inc(FOutputPos);
  if FOutputPos = NativeUInt(Length(FOutputBuffer)) then
    FlushOutput;
end;

procedure TLzmaDecoderState.WriteUncompressed(const Data: TBytes; const Offset, Count: NativeUInt;
  const Destination: TStream);
var
  DictLen: NativeUInt;
  SourcePos: NativeUInt;
  Remaining: NativeUInt;
  RunLen: NativeUInt;
begin
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');
  if Offset > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Invalid LZMA2 uncompressed chunk offset');
  if Count > NativeUInt(Length(Data)) - Offset then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA2 uncompressed chunk');

  if Count <> 0 then
  begin
    DictLen := NativeUInt(Length(FDictionary));
    if DictLen = 0 then
      RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');

    SourcePos := Offset;
    Remaining := Count;
    while Remaining <> 0 do
    begin
      RunLen := DictLen - FDictPos;
      if RunLen > Remaining then
        RunLen := Remaining;
      Move(Data[SourcePos], FDictionary[FDictPos], RunLen);
      Inc(SourcePos, RunLen);
      Inc(FDictPos, RunLen);
      if FDictPos = DictLen then
        FDictPos := 0;
      Dec(Remaining, RunLen);
    end;

    if Count > DictLen - FDictFull then
      FDictFull := DictLen
    else
      Inc(FDictFull, Count);
    Inc(FProcessed, UInt64(Count));
    WriteExact(Destination, Data[Offset], Count);
  end;
end;

function TLzmaDecoderState.AvailableHistory: UInt64;
begin
  Result := FProcessed;
  if Result > UInt64(Length(FDictionary)) then
    Result := UInt64(Length(FDictionary));
end;

function TLzmaDecoderState.GetByte(const Distance: UInt32): Byte;
var
  Pos: NativeInt;
begin
  if (Distance = 0) or (UInt64(Distance) > AvailableHistory) then
    RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');
  Pos := NativeInt(FDictPos) - NativeInt(Distance);
  if Pos < 0 then
    Inc(Pos, Length(FDictionary));
  Result := FDictionary[Pos];
end;

procedure TLzmaDecoderState.CopyMatch(const Distance: UInt32; Len: UInt32);
var
  B: Byte;
  DictLen: NativeUInt;
  Dist: NativeUInt;
  LenOriginal: NativeUInt;
  OutputLen: NativeUInt;
  OutputRun: NativeUInt;
  Pattern: array[0..63] of Byte;
  PatternIndex: NativeUInt;
  PatternLen: NativeUInt;
  PatternOffset: NativeUInt;
  Remaining: NativeUInt;
  RunLen: NativeUInt;
  SeedLen: NativeUInt;
  SourcePos: NativeUInt;
begin
  if (Distance = 0) or (UInt64(Distance) > AvailableHistory) then
    RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');

  DictLen := NativeUInt(Length(FDictionary));
  if DictLen = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  if Length(FOutputBuffer) = 0 then
    SetLength(FOutputBuffer, kOutputBufferSize);

  Dist := NativeUInt(Distance);
  LenOriginal := NativeUInt(Len);
  Remaining := LenOriginal;
  OutputLen := NativeUInt(Length(FOutputBuffer));
  if Dist > FDictPos then
    SourcePos := FDictPos + DictLen - Dist
  else
    SourcePos := FDictPos - Dist;

  if Dist = 1 then
  begin
    B := FDictionary[SourcePos];
    while Remaining <> 0 do
    begin
      if FOutputPos = OutputLen then
        FlushOutput;

      RunLen := Remaining;
      if RunLen > DictLen - FDictPos then
        RunLen := DictLen - FDictPos;
      OutputRun := OutputLen - FOutputPos;
      if RunLen > OutputRun then
        RunLen := OutputRun;

      FillChar(FDictionary[FDictPos], RunLen, B);
      FillChar(FOutputBuffer[FOutputPos], RunLen, B);

      Inc(FDictPos, RunLen);
      if FDictPos = DictLen then
        FDictPos := 0;
      Inc(FOutputPos, RunLen);
      Dec(Remaining, RunLen);
    end;
  end
  else if Dist <= Length(Pattern) then
  begin
    PatternLen := Dist;
    for PatternIndex := 0 to PatternLen - 1 do
      Pattern[PatternIndex] := FDictionary[(SourcePos + PatternIndex) mod DictLen];
    PatternOffset := 0;

    while Remaining <> 0 do
    begin
      if FOutputPos = OutputLen then
        FlushOutput;

      RunLen := Remaining;
      if RunLen > DictLen - FDictPos then
        RunLen := DictLen - FDictPos;
      OutputRun := OutputLen - FOutputPos;
      if RunLen > OutputRun then
        RunLen := OutputRun;

      SeedLen := 0;
      while (SeedLen < RunLen) and (SeedLen < PatternLen) do
      begin
        FOutputBuffer[FOutputPos + SeedLen] := Pattern[(PatternOffset + SeedLen) mod PatternLen];
        Inc(SeedLen);
      end;

      OutputRun := SeedLen;
      while OutputRun < RunLen do
      begin
        SeedLen := OutputRun;
        if SeedLen > RunLen - OutputRun then
          SeedLen := RunLen - OutputRun;
        Move(FOutputBuffer[FOutputPos], FOutputBuffer[FOutputPos + OutputRun], SeedLen);
        Inc(OutputRun, SeedLen);
      end;

      Move(FOutputBuffer[FOutputPos], FDictionary[FDictPos], RunLen);
      Inc(FDictPos, RunLen);
      if FDictPos = DictLen then
        FDictPos := 0;
      Inc(FOutputPos, RunLen);
      Dec(Remaining, RunLen);
      PatternOffset := (PatternOffset + RunLen) mod PatternLen;
    end;
  end
  else
  begin
    while Remaining <> 0 do
    begin
      if FOutputPos = OutputLen then
        FlushOutput;

      RunLen := Remaining;
      if RunLen > Dist then
        RunLen := Dist;
      if RunLen > DictLen - SourcePos then
        RunLen := DictLen - SourcePos;
      if RunLen > DictLen - FDictPos then
        RunLen := DictLen - FDictPos;
      OutputRun := OutputLen - FOutputPos;
      if RunLen > OutputRun then
        RunLen := OutputRun;

      Move(FDictionary[SourcePos], FOutputBuffer[FOutputPos], RunLen);
      Move(FDictionary[SourcePos], FDictionary[FDictPos], RunLen);

      Inc(SourcePos, RunLen);
      if SourcePos = DictLen then
        SourcePos := 0;
      Inc(FDictPos, RunLen);
      if FDictPos = DictLen then
        FDictPos := 0;
      Inc(FOutputPos, RunLen);
      Dec(Remaining, RunLen);
    end;
  end;

  if LenOriginal > DictLen - FDictFull then
    FDictFull := DictLen
  else
    Inc(FDictFull, LenOriginal);
  Inc(FProcessed, UInt64(LenOriginal));
end;

function TLzmaDecoderState.IsUnreadRangeFlushTail: Boolean;
var
  I: NativeUInt;
begin
  Result := False;
  if FInputPos > FInputLimit then
    Exit;
  if FInputPos = FInputLimit then
    Exit(FCode = 0);
  if FInputLimit - FInputPos > 5 then
    Exit;
  if FCode <> 0 then
    Exit;
  for I := FInputPos to FInputLimit - 1 do
    if FInput[I] <> 0 then
      Exit;
  Result := True;
end;

procedure TLzmaDecoderState.SaveDecodeSnapshot(out Snapshot: TDecodeSnapshot);
begin
  Snapshot.InputPos := FInputPos;
  Snapshot.Processed := FProcessed;
  Snapshot.State := FState;
  System.Move(FReps[0], Snapshot.Reps[0], SizeOf(FReps));
  Snapshot.Range := FRange;
  Snapshot.Code := FCode;
  Snapshot.NeedRangeInit := FNeedRangeInit;
  System.Move(FIsMatch[0][0], Snapshot.IsMatch[0][0], SizeOf(FIsMatch));
  System.Move(FIsRep[0], Snapshot.IsRep[0], SizeOf(FIsRep));
  System.Move(FIsRepG0[0], Snapshot.IsRepG0[0], SizeOf(FIsRepG0));
  System.Move(FIsRepG1[0], Snapshot.IsRepG1[0], SizeOf(FIsRepG1));
  System.Move(FIsRepG2[0], Snapshot.IsRepG2[0], SizeOf(FIsRepG2));
  System.Move(FIsRep0Long[0][0], Snapshot.IsRep0Long[0][0], SizeOf(FIsRep0Long));
  System.Move(FPosSlot[0][0], Snapshot.PosSlot[0][0], SizeOf(FPosSlot));
  System.Move(FPosDecoders[0], Snapshot.PosDecoders[0], SizeOf(FPosDecoders));
  System.Move(FAlign[0], Snapshot.Align[0], SizeOf(FAlign));
  Snapshot.LenDecoder := FLenDecoder;
  Snapshot.RepLenDecoder := FRepLenDecoder;
  SetLength(Snapshot.Literals, Length(FLiterals));
  if Length(FLiterals) <> 0 then
    System.Move(FLiterals[0], Snapshot.Literals[0], Length(FLiterals) * SizeOf(CLzmaProb));
end;

procedure TLzmaDecoderState.RestoreDecodeSnapshot(const Snapshot: TDecodeSnapshot);
begin
  FInputPos := Snapshot.InputPos;
  FProcessed := Snapshot.Processed;
  FState := Snapshot.State;
  System.Move(Snapshot.Reps[0], FReps[0], SizeOf(FReps));
  FRange := Snapshot.Range;
  FCode := Snapshot.Code;
  FNeedRangeInit := Snapshot.NeedRangeInit;
  System.Move(Snapshot.IsMatch[0][0], FIsMatch[0][0], SizeOf(FIsMatch));
  System.Move(Snapshot.IsRep[0], FIsRep[0], SizeOf(FIsRep));
  System.Move(Snapshot.IsRepG0[0], FIsRepG0[0], SizeOf(FIsRepG0));
  System.Move(Snapshot.IsRepG1[0], FIsRepG1[0], SizeOf(FIsRepG1));
  System.Move(Snapshot.IsRepG2[0], FIsRepG2[0], SizeOf(FIsRepG2));
  System.Move(Snapshot.IsRep0Long[0][0], FIsRep0Long[0][0], SizeOf(FIsRep0Long));
  System.Move(Snapshot.PosSlot[0][0], FPosSlot[0][0], SizeOf(FPosSlot));
  System.Move(Snapshot.PosDecoders[0], FPosDecoders[0], SizeOf(FPosDecoders));
  System.Move(Snapshot.Align[0], FAlign[0], SizeOf(FAlign));
  FLenDecoder := Snapshot.LenDecoder;
  FRepLenDecoder := Snapshot.RepLenDecoder;
  SetLength(FLiterals, Length(Snapshot.Literals));
  if Length(Snapshot.Literals) <> 0 then
    System.Move(Snapshot.Literals[0], FLiterals[0], Length(Snapshot.Literals) * SizeOf(CLzmaProb));
end;

function TLzmaDecoderState.DecodeKnownSizePartial(const Data: TBytes; const Offset,
  PackSize: NativeUInt; const TotalUnpackSize, OutputLimit: UInt64; const Destination: TStream;
  out ConsumedSize: NativeUInt; out Finished, NeedsMoreInput: Boolean;
  const Progress: TLzma2ProgressEvent; const InputBase, OutputBase: UInt64): NativeUInt;
const
  kProgressInterval = UInt64(1) shl 20;
var
  OutStart: UInt64;
  TargetOutput: UInt64;
  NextProgressAt: UInt64;
  PosState: UInt32;
  LitState: UInt32;
  PrevByte: Byte;
  MatchByte: UInt32;
  MatchBit: UInt32;
  Bit: UInt32;
  Symbol: UInt32;
  LiteralOffset: NativeUInt;
  DictLen: NativeUInt;
  DictReadPos: NativeUInt;
  History: UInt64;
  Len: UInt32;
  Distance: UInt32;
  Temp: UInt32;
  PbMask: UInt32;
  LpMask: UInt32;
  LcBits: UInt32;
  LcShift: UInt32;
  Snapshot: TDecodeSnapshot;

  procedure MaybeReportProgress;
  var
    Produced: UInt64;
  begin
    if not Assigned(Progress) then
      Exit;
    Produced := FProcessed - OutStart;
    if Produced < NextProgressAt then
      Exit;
    ReportProgress(Progress, InputBase + UInt64(FInputPos - Offset),
      OutputBase + Produced);
    repeat
      Inc(NextProgressAt, kProgressInterval);
    until NextProgressAt > Produced;
  end;

  function TryConsumeRangeFlushTail: Boolean;
  var
    TailCount: NativeUInt;
    TailPos: NativeUInt;
  begin
    Result := False;
    if FCode <> 0 then
      Exit;

    TailPos := FInputPos;
    TailCount := 0;
    while (TailPos < FInputLimit) and (TailCount < 5) and (FInput[TailPos] = 0) do
    begin
      Inc(TailPos);
      Inc(TailCount);
    end;
    ConsumedSize := TailPos - Offset;
    Result := True;
  end;

begin
  Finished := False;
  NeedsMoreInput := False;
  ConsumedSize := 0;

  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');
  if Offset > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Invalid LZMA chunk offset');
  if PackSize > NativeUInt(Length(Data)) - Offset then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA chunk');

  FInput := Data;
  if FNeedRangeInit then
    FInputPos := Offset;
  FInputLimit := Offset + PackSize;
  FOutput := Destination;
  FOutputPos := 0;
  DictLen := NativeUInt(Length(FDictionary));
  if DictLen = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  if Length(FOutputBuffer) = 0 then
    SetLength(FOutputBuffer, kOutputBufferSize);
  PbMask := (UInt32(1) shl FProps.Pb) - 1;
  LpMask := (UInt32(1) shl FProps.Lp) - 1;
  LcBits := FProps.Lc;
  LcShift := 8 - LcBits;

  if FNeedRangeInit then
  begin
    try
      InitRange;
    except
      on E: Exception do
      begin
        if (E is ELzmaError) and (ELzmaError(E).ResultCode = SZ_ERROR_INPUT_EOF) then
        begin
          NeedsMoreInput := True;
          ConsumedSize := FInputPos - Offset;
          Exit(ConsumedSize);
        end;
        raise;
      end;
    end;
  end;

  OutStart := FProcessed;
  TargetOutput := OutputLimit;
  if TargetOutput > TotalUnpackSize then
    TargetOutput := TotalUnpackSize;
  if TargetOutput < FProcessed then
    TargetOutput := FProcessed;
  NextProgressAt := kProgressInterval;

  while (FProcessed < TargetOutput) and (FProcessed < TotalUnpackSize) do
  begin
    SaveDecodeSnapshot(Snapshot);
    try
      PosState := UInt32(FProcessed) and PbMask;
      if DecodeBit(FIsMatch[FState][PosState]) = 0 then
      begin
        if FProcessed = 0 then
          PrevByte := 0
        else
        begin
          DictReadPos := FDictPos;
          if DictReadPos = 0 then
            DictReadPos := DictLen;
          PrevByte := FDictionary[DictReadPos - 1];
        end;
        LitState := ((UInt32(FProcessed) and LpMask) shl LcBits) +
          (UInt32(PrevByte) shr LcShift);
        LiteralOffset := NativeUInt(LitState) * $300;
        Symbol := 1;
        if FState >= kNumLitStates then
        begin
          if FProcessed < UInt64(DictLen) then
            History := FProcessed
          else
            History := UInt64(DictLen);
          if (FReps[0] = 0) or (UInt64(FReps[0]) > History) then
            RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');
          if NativeUInt(FReps[0]) > FDictPos then
            DictReadPos := FDictPos + DictLen - NativeUInt(FReps[0])
          else
            DictReadPos := FDictPos - NativeUInt(FReps[0]);
          MatchByte := FDictionary[DictReadPos];
          repeat
            MatchBit := (MatchByte shr 7) and 1;
            MatchByte := (MatchByte shl 1) and $FF;
            Bit := DecodeBit(FLiterals[LiteralOffset + NativeUInt(((1 + MatchBit) shl 8) + Symbol)]);
            Symbol := (Symbol shl 1) or Bit;
            if MatchBit <> Bit then
              Break;
          until Symbol >= $100;
        end;
        while Symbol < $100 do
          Symbol := (Symbol shl 1) or DecodeBit(FLiterals[LiteralOffset + Symbol]);
        PutByte(Byte(Symbol - $100));
        FState := LZMA_STATE_LITERAL_NEXT[FState];
        MaybeReportProgress;
        Continue;
      end;

      if DecodeBit(FIsRep[FState]) = 0 then
      begin
        FReps[3] := FReps[2];
        FReps[2] := FReps[1];
        FReps[1] := FReps[0];
        Len := DecodeLen(FLenDecoder, PosState);
        FState := LZMA_STATE_MATCH_NEXT[FState];
        Distance := DecodeDistance(Len);
        if Distance = UInt32($FFFFFFFF) then
          RaiseLzmaError(SZ_ERROR_DATA, 'Unexpected raw LZMA end marker inside known-size stream');
        FReps[0] := Distance + 1;
      end
      else
      begin
        if FProcessed = 0 then
          RaiseLzmaError(SZ_ERROR_DATA, 'LZMA rep match before any literal');
        if DecodeBit(FIsRepG0[FState]) = 0 then
        begin
          if DecodeBit(FIsRep0Long[FState][PosState]) = 0 then
          begin
            FState := LZMA_STATE_SHORT_REP_NEXT[FState];
            PutByte(GetByte(FReps[0]));
            MaybeReportProgress;
            Continue;
          end;
        end
        else
        begin
          if DecodeBit(FIsRepG1[FState]) = 0 then
            Distance := FReps[1]
          else
          begin
            if DecodeBit(FIsRepG2[FState]) = 0 then
              Distance := FReps[2]
            else
            begin
              Distance := FReps[3];
              FReps[3] := FReps[2];
            end;
            FReps[2] := FReps[1];
          end;
          FReps[1] := FReps[0];
          FReps[0] := Distance;
        end;
        Len := DecodeLen(FRepLenDecoder, PosState);
        FState := LZMA_STATE_REP_NEXT[FState];
      end;

      Inc(Len, kMatchMinLen);
      if UInt64(Len) > TotalUnpackSize - FProcessed then
        RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match exceeds known unpack size');
      Temp := FReps[0];
      CopyMatch(Temp, Len);
      MaybeReportProgress;
    except
      on E: Exception do
      begin
        if (E is ELzmaError) and (ELzmaError(E).ResultCode = SZ_ERROR_INPUT_EOF) then
        begin
          RestoreDecodeSnapshot(Snapshot);
          NeedsMoreInput := True;
          Break;
        end;
        raise;
      end;
    end;
  end;

  if FProcessed >= TotalUnpackSize then
  begin
    if not TryConsumeRangeFlushTail then
      RaiseLzmaError(SZ_ERROR_DATA, 'LZMA chunk range coder did not finish cleanly');
    Finished := True;
  end
  else
    ConsumedSize := FInputPos - Offset;

  FlushOutput;
  Result := ConsumedSize;
end;

function TLzmaDecoderState.DecodeChunk(const Data: TBytes; const Offset, PackSize: NativeUInt;
  const UnpackSize: UInt64; const Destination: TStream; const Progress: TLzma2ProgressEvent;
  const InputBase, OutputBase: UInt64): NativeUInt;
const
  kProgressInterval = UInt64(1) shl 20;
var
  OutStart: UInt64;
  NextProgressAt: UInt64;
  PosState: UInt32;
  LitState: UInt32;
  PrevByte: Byte;
  MatchByte: UInt32;
  MatchBit: UInt32;
  Bit: UInt32;
  Symbol: UInt32;
  LiteralOffset: NativeUInt;
  DictLen: NativeUInt;
  DictReadPos: NativeUInt;
  History: UInt64;
  Len: UInt32;
  Distance: UInt32;
  Temp: UInt32;
  PbMask: UInt32;
  LpMask: UInt32;
  LcBits: UInt32;
  LcShift: UInt32;

  procedure MaybeReportProgress;
  var
    Produced: UInt64;
  begin
    if not Assigned(Progress) then
      Exit;
    Produced := FProcessed - OutStart;
    if Produced < NextProgressAt then
      Exit;
    ReportProgress(Progress, InputBase + UInt64(FInputPos - Offset),
      OutputBase + Produced);
    repeat
      Inc(NextProgressAt, kProgressInterval);
    until NextProgressAt > Produced;
  end;
begin
  if Offset > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Invalid LZMA chunk offset');
  if PackSize > NativeUInt(Length(Data)) - Offset then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA chunk');

  FInput := Data;
  FInputPos := Offset;
  FInputLimit := Offset + PackSize;
  FOutput := Destination;
  FOutputPos := 0;
  DictLen := NativeUInt(Length(FDictionary));
  if DictLen = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  if Length(FOutputBuffer) = 0 then
    SetLength(FOutputBuffer, kOutputBufferSize);
  PbMask := (UInt32(1) shl FProps.Pb) - 1;
  LpMask := (UInt32(1) shl FProps.Lp) - 1;
  LcBits := FProps.Lc;
  LcShift := 8 - LcBits;

  InitRange;

  OutStart := FProcessed;
  NextProgressAt := kProgressInterval;
  while FProcessed - OutStart < UnpackSize do
  begin
    PosState := UInt32(FProcessed) and PbMask;
    if DecodeBit(FIsMatch[FState][PosState]) = 0 then
    begin
      if FProcessed = 0 then
        PrevByte := 0
      else
      begin
        DictReadPos := FDictPos;
        if DictReadPos = 0 then
          DictReadPos := DictLen;
        PrevByte := FDictionary[DictReadPos - 1];
      end;
      LitState := ((UInt32(FProcessed) and LpMask) shl LcBits) +
        (UInt32(PrevByte) shr LcShift);
      LiteralOffset := NativeUInt(LitState) * $300;
      Symbol := 1;
      if FState >= kNumLitStates then
      begin
        if FProcessed < UInt64(DictLen) then
          History := FProcessed
        else
          History := UInt64(DictLen);
        if (FReps[0] = 0) or (UInt64(FReps[0]) > History) then
          RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');
        if NativeUInt(FReps[0]) > FDictPos then
          DictReadPos := FDictPos + DictLen - NativeUInt(FReps[0])
        else
          DictReadPos := FDictPos - NativeUInt(FReps[0]);
        MatchByte := FDictionary[DictReadPos];
        repeat
          MatchBit := (MatchByte shr 7) and 1;
          MatchByte := (MatchByte shl 1) and $FF;
          Bit := DecodeBit(FLiterals[LiteralOffset + NativeUInt(((1 + MatchBit) shl 8) + Symbol)]);
          Symbol := (Symbol shl 1) or Bit;
          if MatchBit <> Bit then
            Break;
        until Symbol >= $100;
      end;
      while Symbol < $100 do
        Symbol := (Symbol shl 1) or DecodeBit(FLiterals[LiteralOffset + Symbol]);
      PutByte(Byte(Symbol - $100));
      FState := LZMA_STATE_LITERAL_NEXT[FState];
      MaybeReportProgress;
      Continue;
    end;

    if DecodeBit(FIsRep[FState]) = 0 then
    begin
      FReps[3] := FReps[2];
      FReps[2] := FReps[1];
      FReps[1] := FReps[0];
      Len := DecodeLen(FLenDecoder, PosState);
      FState := LZMA_STATE_MATCH_NEXT[FState];
      Distance := DecodeDistance(Len);
      if Distance = UInt32($FFFFFFFF) then
        RaiseLzmaError(SZ_ERROR_DATA, 'Unexpected raw LZMA end marker inside LZMA2 chunk');
      FReps[0] := Distance + 1;
    end
    else
    begin
      if FProcessed = 0 then
        RaiseLzmaError(SZ_ERROR_DATA, 'LZMA rep match before any literal');
      if DecodeBit(FIsRepG0[FState]) = 0 then
      begin
        if DecodeBit(FIsRep0Long[FState][PosState]) = 0 then
        begin
          FState := LZMA_STATE_SHORT_REP_NEXT[FState];
          PutByte(GetByte(FReps[0]));
          MaybeReportProgress;
          Continue;
        end;
      end
      else
      begin
        if DecodeBit(FIsRepG1[FState]) = 0 then
          Distance := FReps[1]
        else
        begin
          if DecodeBit(FIsRepG2[FState]) = 0 then
            Distance := FReps[2]
          else
          begin
            Distance := FReps[3];
            FReps[3] := FReps[2];
          end;
          FReps[2] := FReps[1];
        end;
        FReps[1] := FReps[0];
        FReps[0] := Distance;
      end;
      Len := DecodeLen(FRepLenDecoder, PosState);
      FState := LZMA_STATE_REP_NEXT[FState];
    end;

    Inc(Len, kMatchMinLen);
    if FProcessed - OutStart + Len > UnpackSize then
      RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match exceeds LZMA2 unpack size');
    Temp := FReps[0];
    CopyMatch(Temp, Len);
    MaybeReportProgress;
  end;

  // SDK-compatible known-size chunks can finish exactly or leave only the range-coder flush tail unread.
  if not IsUnreadRangeFlushTail then
    RaiseLzmaError(SZ_ERROR_DATA, 'LZMA chunk range coder did not finish cleanly');
  FlushOutput;
  Result := PackSize;
end;

function TLzmaDecoderState.DecodeUntilEndMarker(const Data: TBytes; const Offset,
  PackSize: NativeUInt; const Destination: TStream; const Progress: TLzma2ProgressEvent;
  const InputBase, OutputBase: UInt64): NativeUInt;
const
  kProgressInterval = UInt64(1) shl 20;
var
  OutStart: UInt64;
  NextProgressAt: UInt64;
  PosState: UInt32;
  LitState: UInt32;
  PrevByte: Byte;
  MatchByte: UInt32;
  MatchBit: UInt32;
  Bit: UInt32;
  Symbol: UInt32;
  LiteralOffset: NativeUInt;
  DictLen: NativeUInt;
  DictReadPos: NativeUInt;
  History: UInt64;
  Len: UInt32;
  Distance: UInt32;
  Temp: UInt32;
  PbMask: UInt32;
  LpMask: UInt32;
  LcBits: UInt32;
  LcShift: UInt32;

  procedure MaybeReportProgress;
  var
    Produced: UInt64;
  begin
    if not Assigned(Progress) then
      Exit;
    Produced := FProcessed - OutStart;
    if Produced < NextProgressAt then
      Exit;
    ReportProgress(Progress, InputBase + UInt64(FInputPos - Offset),
      OutputBase + Produced);
    repeat
      Inc(NextProgressAt, kProgressInterval);
    until NextProgressAt > Produced;
  end;
begin
  if Offset > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Invalid LZMA chunk offset');
  if PackSize > NativeUInt(Length(Data)) - Offset then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA chunk');

  FInput := Data;
  FInputPos := Offset;
  FInputLimit := Offset + PackSize;
  FOutput := Destination;
  FOutputPos := 0;
  DictLen := NativeUInt(Length(FDictionary));
  if DictLen = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  if Length(FOutputBuffer) = 0 then
    SetLength(FOutputBuffer, kOutputBufferSize);
  PbMask := (UInt32(1) shl FProps.Pb) - 1;
  LpMask := (UInt32(1) shl FProps.Lp) - 1;
  LcBits := FProps.Lc;
  LcShift := 8 - LcBits;

  InitRange;

  OutStart := FProcessed;
  NextProgressAt := kProgressInterval;
  while True do
  begin
    PosState := UInt32(FProcessed) and PbMask;
    if DecodeBit(FIsMatch[FState][PosState]) = 0 then
    begin
      if FProcessed = 0 then
        PrevByte := 0
      else
      begin
        DictReadPos := FDictPos;
        if DictReadPos = 0 then
          DictReadPos := DictLen;
        PrevByte := FDictionary[DictReadPos - 1];
      end;
      LitState := ((UInt32(FProcessed) and LpMask) shl LcBits) +
        (UInt32(PrevByte) shr LcShift);
      LiteralOffset := NativeUInt(LitState) * $300;
      Symbol := 1;
      if FState >= kNumLitStates then
      begin
        if FProcessed < UInt64(DictLen) then
          History := FProcessed
        else
          History := UInt64(DictLen);
        if (FReps[0] = 0) or (UInt64(FReps[0]) > History) then
          RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');
        if NativeUInt(FReps[0]) > FDictPos then
          DictReadPos := FDictPos + DictLen - NativeUInt(FReps[0])
        else
          DictReadPos := FDictPos - NativeUInt(FReps[0]);
        MatchByte := FDictionary[DictReadPos];
        repeat
          MatchBit := (MatchByte shr 7) and 1;
          MatchByte := (MatchByte shl 1) and $FF;
          Bit := DecodeBit(FLiterals[LiteralOffset + NativeUInt(((1 + MatchBit) shl 8) + Symbol)]);
          Symbol := (Symbol shl 1) or Bit;
          if MatchBit <> Bit then
            Break;
        until Symbol >= $100;
      end;
      while Symbol < $100 do
        Symbol := (Symbol shl 1) or DecodeBit(FLiterals[LiteralOffset + Symbol]);
      PutByte(Byte(Symbol - $100));
      FState := LZMA_STATE_LITERAL_NEXT[FState];
      MaybeReportProgress;
      Continue;
    end;

    if DecodeBit(FIsRep[FState]) = 0 then
    begin
      FReps[3] := FReps[2];
      FReps[2] := FReps[1];
      FReps[1] := FReps[0];
      Len := DecodeLen(FLenDecoder, PosState);
      FState := LZMA_STATE_MATCH_NEXT[FState];
      Distance := DecodeDistance(Len);
      if Distance = UInt32($FFFFFFFF) then
      begin
        if not IsUnreadRangeFlushTail then
          RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA end marker did not finish cleanly');
        FlushOutput;
        Exit(FInputPos - Offset);
      end;
      FReps[0] := Distance + 1;
    end
    else
    begin
      if FProcessed = 0 then
        RaiseLzmaError(SZ_ERROR_DATA, 'LZMA rep match before any literal');
      if DecodeBit(FIsRepG0[FState]) = 0 then
      begin
        if DecodeBit(FIsRep0Long[FState][PosState]) = 0 then
        begin
          FState := LZMA_STATE_SHORT_REP_NEXT[FState];
          PutByte(GetByte(FReps[0]));
          MaybeReportProgress;
          Continue;
        end;
      end
      else
      begin
        if DecodeBit(FIsRepG1[FState]) = 0 then
          Distance := FReps[1]
        else
        begin
          if DecodeBit(FIsRepG2[FState]) = 0 then
            Distance := FReps[2]
          else
          begin
            Distance := FReps[3];
            FReps[3] := FReps[2];
          end;
          FReps[2] := FReps[1];
        end;
        FReps[1] := FReps[0];
        FReps[0] := Distance;
      end;
      Len := DecodeLen(FRepLenDecoder, PosState);
      FState := LZMA_STATE_REP_NEXT[FState];
    end;

    Inc(Len, kMatchMinLen);
    Temp := FReps[0];
    CopyMatch(Temp, Len);
    MaybeReportProgress;
  end;
end;

class function TLzmaRawDecoder.DecodeProperties(const Props: TBytes; out Decoded: TLzmaProps): Boolean;
begin
  Result := LzmaPropsDecode(Props, Decoded);
end;

class procedure TLzmaRawDecoder.Decode(Source: TStream; Destination: TStream; const Props: TBytes;
  const UnpackedSize: UInt64; const Progress: TLzma2ProgressEvent);
var
  Decoded: TLzmaProps;
  Data: TBytes;
  State: TLzmaDecoderState;
begin
  if not LzmaPropsDecode(Props, Decoded) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Invalid raw LZMA properties');
  Data := ReadAllBytes(Source);
  State := TLzmaDecoderState.Create(Decoded.DictionarySize);
  try
    State.SetProperties(Decoded);
    State.ResetDictionary;
    State.ResetState;
    State.DecodeChunk(Data, 0, Length(Data), UnpackedSize, Destination);
    ReportProgress(Progress, Length(Data), UnpackedSize);
  finally
    State.Free;
  end;
end;

class procedure TLzmaRawDecoder.DecodeUntilEndMarker(Source: TStream; Destination: TStream;
  const Props: TBytes; const Progress: TLzma2ProgressEvent);
var
  Decoded: TLzmaProps;
  Data: TBytes;
  State: TLzmaDecoderState;
  Produced: UInt64;
begin
  if not LzmaPropsDecode(Props, Decoded) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Invalid raw LZMA properties');
  Data := ReadAllBytes(Source);
  State := TLzmaDecoderState.Create(Decoded.DictionarySize);
  try
    State.SetProperties(Decoded);
    State.ResetDictionary;
    State.ResetState;
    State.DecodeUntilEndMarker(Data, 0, Length(Data), Destination);
    Produced := State.FProcessed;
    ReportProgress(Progress, Length(Data), Produced);
  finally
    State.Free;
  end;
end;

end.
