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
    kDefaultLc = 3;
    kDefaultLp = 0;
    kLzma2LiteralContextBitsMax = 4;
    // Each range bit reads at most one byte; include the longest match branch.
    kMaxLengthInput = 2 + kLenNumHighBits;
    kMaxDistanceInput = kNumPosSlotBits +
      (((1 shl kNumPosSlotBits) - 1) shr 1) - 1;
    // A committed symbol also includes its final normalization byte.
    kMaxSymbolInput = 2 + kMaxLengthInput + kMaxDistanceInput + 1;
    kRangeFlushTailSize = 1 + SizeOf(UInt32);
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    kFastBulkSymbolLimit = 64;
    kFastBulkByteLimit = 4096;
{$ENDIF}
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

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    TSymbolKind = (skLiteral, skShortRep, skMatch, skRepMatch,
      skBadHistory, skRepBeforeLiteral);
    TSymbolContext = record
      DictLen: NativeUInt;
      PbMask, LpMask, LcBits, LcShift: UInt32;
    end;
    PSymbolContext = ^TSymbolContext;
    TDecodedSymbol = record
      Kind: TSymbolKind;
      Value, Len: UInt32;
    end;
    TDecodedBulk = record
      Symbol: TDecodedSymbol;
      Context: PSymbolContext;
      RemainingBytes, ProducedBytes, CompletedSymbols: UInt32;
      HasSymbol: Boolean;
    end;
{$ENDIF}

    TStreamInput = record
      Source: TStream;
      Base: UInt64;
      EndOfInput: Boolean;
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
    FEndMarkerConsumed: Boolean;
    FInput: TBytes;
    FInputPos: NativeUInt;
    FInputLimit: NativeUInt;
    FOutput: TStream;
    FOutputBuffer: TBytes;
    FOutputData: PByte;
    FOutputLimit: NativeUInt;
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
    procedure NormalizeRange; inline;
    function DecodeBit(var Prob: CLzmaProb): UInt32; inline;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    function DecodeLiteralFast(var Probs; MatchByte: UInt32; const Matched: Boolean): Byte;
{$ENDIF}
    function DecodeLiteral(var Probs; MatchByte: UInt32; const Matched: Boolean): Byte; inline;
    function DecodeDirectBits(const NumBits: UInt32): UInt32; inline;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    function BitTreeDecodeFast(var Probs; const NumBits: UInt32): UInt32;
{$ENDIF}
    function BitTreeDecode(var Probs; const NumBits: UInt32): UInt32; inline;
    function BitTreeReverseDecode(var Probs; const NumBits: UInt32): UInt32; inline;
    function DecodeLen(var Decoder: TLenDecoder; const PosState: UInt32): UInt32; inline;
    function DecodeDistance(const Len: UInt32): UInt32; inline;
    procedure AddHistoryByte(const B: Byte);
    procedure InitializeOutput;
    procedure FlushOutput; inline;
    procedure PutByte(const B: Byte); inline;
    function GetByte(const Distance: UInt32): Byte; inline;
    procedure CopyMatch(const Distance: UInt32; Len: UInt32);
    function IsUnreadRangeFlushTail: Boolean;
    procedure ConsumeKnownSizeEndMarker;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    procedure DecodeSymbolFast(const Context: PSymbolContext; out Decoded: TDecodedSymbol);
    function FastBulkCapacity(const DictLen: NativeUInt;
      const AvailableOutput, ProgressBudget: UInt64): UInt32; inline;
    procedure DecodeSymbolsBulk(const Context: PSymbolContext; var Bulk: TDecodedBulk);
{$ENDIF}
    procedure InitializeInput(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const Source: TStream; const InputCapacity: NativeUInt; out Input: TStreamInput);
    procedure RefillInput(var Input: TStreamInput; const Minimum: NativeUInt;
      const ReadAhead: Boolean = True);
    function FinishInput(var Input: TStreamInput): Boolean;
    function DecodeChunkInternal(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const UnpackSize: UInt64; const Destination: TStream;
      const Progress: TLzma2ProgressEvent; const InputBase, OutputBase: UInt64;
      const AllowEndMarker: Boolean; const Source: TStream = nil;
      const InputCapacity: NativeUInt = 0): UInt64;
    function DecodeUntilEndMarkerInternal(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const Destination: TStream; const Progress: TLzma2ProgressEvent;
      const InputBase, OutputBase: UInt64; const Source: TStream;
      const InputCapacity: NativeUInt): UInt64;
    procedure SaveDecodeSnapshot(var Snapshot: TDecodeSnapshot);
    procedure RestoreDecodeSnapshot(const Snapshot: TDecodeSnapshot);
    function AvailableHistory: UInt64; inline;
  public
    class function RequiredMemory(const DictionarySize: UInt64; const Lc, Lp: UInt32;
      const WithSnapshot: Boolean = False): UInt64; static;
    class function RequiredLzma2Memory(const DictionarySize: UInt64): UInt64; static;
    class function StreamingInputCapacity(const BufferSize: NativeUInt;
      const KnownInputSize: UInt64 = High(UInt64)): NativeUInt; static;
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
    // A complete LZMA1 payload may finish by size or by an optional end marker.
    // DecodeChunk retains strict LZMA2 semantics and rejects end markers.
    function DecodeKnownSize(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const UnpackSize: UInt64; const Destination: TStream;
      const Progress: TLzma2ProgressEvent = nil; const InputBase: UInt64 = 0;
      const OutputBase: UInt64 = 0): NativeUInt;
    function DecodeKnownSizePartial(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const TotalUnpackSize, OutputLimit: UInt64; const Destination: TStream;
      out ConsumedSize: NativeUInt; out Finished, NeedsMoreInput: Boolean;
      const Progress: TLzma2ProgressEvent = nil; const InputBase: UInt64 = 0;
      const OutputBase: UInt64 = 0): NativeUInt; overload;
    function DecodeKnownSizePartial(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const TotalUnpackSize, OutputLimit: UInt64; const FinishAtEnd: Boolean; const Destination: TStream;
      out ConsumedSize: NativeUInt; out Finished, NeedsMoreInput: Boolean;
      const Progress: TLzma2ProgressEvent = nil; const InputBase: UInt64 = 0;
      const OutputBase: UInt64 = 0): NativeUInt; overload;
    function DecodeUntilEndMarker(const Data: TBytes; const Offset, PackSize: NativeUInt;
      const Destination: TStream; const Progress: TLzma2ProgressEvent = nil;
      const InputBase: UInt64 = 0; const OutputBase: UInt64 = 0): NativeUInt;
    // Internal container entrypoints: InputCapacity is the admitted fixed allocation.
    // A successful stream decode validates EOF and counts the accepted flush tail.
    function DecodeKnownSizeStream(const Source: TStream; const InputCapacity: NativeUInt;
      const UnpackSize: UInt64; const Destination: TStream;
      const Progress: TLzma2ProgressEvent = nil; const InputBase: UInt64 = 0;
      const OutputBase: UInt64 = 0): UInt64;
    function DecodeUntilEndMarkerStream(const Source: TStream; const InputCapacity: NativeUInt;
      const Destination: TStream; const Progress: TLzma2ProgressEvent = nil;
      const InputBase: UInt64 = 0; const OutputBase: UInt64 = 0): UInt64;
    property InputPosition: NativeUInt read FInputPos;
    property ProcessedSize: UInt64 read FProcessed;
    property EndMarkerConsumed: Boolean read FEndMarkerConsumed;
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
  Lzma.Alloc,
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

class function TLzmaDecoderState.StreamingInputCapacity(const BufferSize: NativeUInt;
  const KnownInputSize: UInt64): NativeUInt;
begin
  Result := CheckedBufferSize(BufferSize);
  if Result > NativeUInt(High(Integer)) then
    Result := High(Integer);
  if KnownInputSize < UInt64(Result) then
    Result := NativeUInt(KnownInputSize);
  // A source can grow after a reliable size probe. Keep room for one full symbol.
  if Result < kMaxSymbolInput then
    Result := kMaxSymbolInput;
end;

procedure TLzmaDecoderState.InitializeInput(const Data: TBytes; const Offset,
  PackSize: NativeUInt; const Source: TStream; const InputCapacity: NativeUInt;
  out Input: TStreamInput);
begin
  Input.Source := Source;
  Input.Base := 0;
  Input.EndOfInput := False;
  if Source = nil then
  begin
    if Offset > NativeUInt(Length(Data)) then
      RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Invalid LZMA chunk offset');
    if PackSize > NativeUInt(Length(Data)) - Offset then
      RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA chunk');
    FInput := Data;
    FInputPos := Offset;
    FInputLimit := Offset + PackSize;
    Exit;
  end;

  if (InputCapacity < kMaxSymbolInput) or
     (InputCapacity > NativeUInt(High(Integer))) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA streaming input capacity');
  FInput := nil;
  SetLength(FInput, NativeInt(InputCapacity));
  FInputPos := 0;
  FInputLimit := 0;
  RefillInput(Input, kMaxSymbolInput);
end;

procedure TLzmaDecoderState.RefillInput(var Input: TStreamInput; const Minimum: NativeUInt;
  const ReadAhead: Boolean);
var
  Remaining, ReadSize: NativeUInt;
  ReadCount: Integer;
begin
  if (Input.Source = nil) or Input.EndOfInput then
    Exit;
  if FInputLimit - FInputPos >= Minimum then
    Exit;

  Remaining := FInputLimit - FInputPos;
  Input.Base := CheckedMemoryAdd(Input.Base, UInt64(FInputPos));
  if (Remaining <> 0) and (FInputPos <> 0) then
    Move(FInput[FInputPos], FInput[0], Remaining);
  FInputPos := 0;
  FInputLimit := Remaining;
  while (FInputLimit < Minimum) and not Input.EndOfInput do
  begin
    ReadSize := NativeUInt(Length(FInput)) - FInputLimit;
    if not ReadAhead and (ReadSize > Minimum - FInputLimit) then
      ReadSize := Minimum - FInputLimit;
    ReadCount := ReadAvailable(Input.Source, FInput[FInputLimit], ReadSize);
    if ReadCount = 0 then
      Input.EndOfInput := True
    else
      Inc(FInputLimit, NativeUInt(ReadCount));
  end;
end;

function TLzmaDecoderState.FinishInput(var Input: TStreamInput): Boolean;
begin
  Result := IsUnreadRangeFlushTail;
  if not Result or (Input.Source = nil) then
    Exit;
  // A sixth byte proves an invalid global tail, including across a refill.
  RefillInput(Input, kRangeFlushTailSize + 1, False);
  Result := Input.EndOfInput and IsUnreadRangeFlushTail;
end;

class function TLzmaDecoderState.RequiredMemory(const DictionarySize: UInt64;
  const Lc, Lp: UInt32; const WithSnapshot: Boolean): UInt64;
var
  DictSize, Literals, InitialModels, DecodeModels: UInt64;
  BufferedDictionary, BufferedModels, BufferedMemory: UInt64;
begin
  if (Lc > 8) or (Lp > 4) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA literal properties');
  DictSize := DictionarySize;
  if DictSize < 4096 then DictSize := 4096;
  if DictSize > UInt64(High(NativeInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is too large for a Delphi dynamic array');
  Literals := CheckedMemoryMultiply(UInt64($300) shl (Lc + Lp), SizeOf(CLzmaProb));
  InitialModels := CheckedMemoryAdd(Literals,
    CheckedMemoryMultiply(UInt64($300) shl (kDefaultLc + kDefaultLp), SizeOf(CLzmaProb)));
  DecodeModels := Literals;
  if WithSnapshot then DecodeModels := CheckedMemoryAdd(DecodeModels, Literals);
  BufferedModels := CheckedMemoryAdd(DecodeModels, kOutputBufferSize);
  if InitialModels > DecodeModels then DecodeModels := InitialModels;
  if InitialModels > BufferedModels then BufferedModels := InitialModels;
  Result := CheckedMemoryAdd(CheckedMemoryAdd(TLzmaDecoderState.InstanceSize,
    DictSize), DecodeModels);
  // Known-size input can cap a declared dictionary below the borrowed-output
  // boundary. Admission must also cover that smaller dictionary plus its buffer.
  BufferedDictionary := DictSize;
  if BufferedDictionary >= kOutputBufferSize then
    BufferedDictionary := kOutputBufferSize - 1;
  BufferedMemory := CheckedMemoryAdd(CheckedMemoryAdd(TLzmaDecoderState.InstanceSize,
    BufferedDictionary), BufferedModels);
  if BufferedMemory > Result then Result := BufferedMemory;
end;

class function TLzmaDecoderState.RequiredLzma2Memory(const DictionarySize: UInt64): UInt64;
begin
  Result := RequiredMemory(DictionarySize, kLzma2LiteralContextBitsMax, 0);
  // A model resize can retain two distinct legal literal-context sizes.
  Result := CheckedMemoryAdd(Result, CheckedMemoryMultiply(
    UInt64($300) shl (kLzma2LiteralContextBitsMax - 1), SizeOf(CLzmaProb)));
end;

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
  FProps.Lc := kDefaultLc;
  FProps.Lp := kDefaultLp;
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
  if Length(FLiterals) <> $300 shl (FProps.Lc + FProps.Lp) then
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
  if Props.Lc + Props.Lp > kLzma2LiteralContextBitsMax then
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
  FEndMarkerConsumed := False;
end;

procedure TLzmaDecoderState.InitRange;
var
  I: Integer;
begin
  FEndMarkerConsumed := False;
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

procedure TLzmaDecoderState.NormalizeRange;
begin
  if FRange < LZMA_TOP_VALUE then
  begin
    if FInputPos >= FInputLimit then
      RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range stream');
    FRange := FRange shl 8;
    FCode := (FCode shl 8) or FInput[FInputPos];
    Inc(FInputPos);
  end;
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

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
function TLzmaDecoderState.DecodeLiteralFast(var Probs; MatchByte: UInt32;
  const Matched: Boolean): Byte;
const
  // SAR((31 - Prob), 5) equals -(Prob shr 5) for the one-bit update.
  kProbDeltaDifference = LZMA_BIT_MODEL_TOTAL - ((1 shl LZMA_NUM_MOVE_BITS) - 1);
asm
        .PARAMS 0
        .PUSHNV RBX
        .PUSHNV RSI
        .PUSHNV RDI
        .PUSHNV R12
        MOV     RBX,RCX
        MOV     RSI,RDX
        MOV     RDI,[RBX].TLzmaDecoderState.FInput
        ADD     RDI,[RBX].TLzmaDecoderState.FInputPos
        MOV     R10D,[RBX].TLzmaDecoderState.FRange
        MOV     R11D,[RBX].TLzmaDecoderState.FCode
        TEST    R9B,R9B
        JNZ     @@matched
        XOR     R8D,R8D
        JMP     @@start
@@matched:
        OR      R8D,$100
@@start:
        MOV     R9D,1
@@literal_bit:
        ADD     R8D,R8D
        MOV     EAX,R9D
        TEST    R8D,R8D
        JZ      @@prob_selected_0
        MOV     ECX,R8D
        AND     ECX,$100
        ADD     EAX,ECX
        ADD     EAX,$100
@@prob_selected_0:
        LEA     RDX,[RSI+RAX*2]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_0
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RDI]
        OR      R11D,ECX
        INC     RDI
@@normalized_0:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R12B
        MOVZX   R12D,R12B
        IMUL    ECX,R12D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R12+R9*2]
        MOV     ECX,R8D
        SHR     ECX,8
        XOR     EAX,EAX
        CMP     ECX,R9D
        CMOVNE  R8D,EAX
        CMP     R9D,$100
        JB      @@literal_bit
        MOV     [RBX].TLzmaDecoderState.FRange,R10D
        MOV     [RBX].TLzmaDecoderState.FCode,R11D
        SUB     RDI,[RBX].TLzmaDecoderState.FInput
        MOV     [RBX].TLzmaDecoderState.FInputPos,RDI
        MOV     EAX,R9D
        SUB     EAX,$100
end;
{$ENDIF}

function TLzmaDecoderState.DecodeLiteral(var Probs; MatchByte: UInt32;
  const Matched: Boolean): Byte;
var
  P: PProbArray;
  Prob: ^CLzmaProb;
  RangeValue: UInt32;
  CodeValue: UInt32;
  Symbol: UInt32;
  Bound: UInt32;
begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  // One normalization byte per bit is the maximum literal input consumption.
  if FInputPos <= FInputLimit then
    if FInputLimit - FInputPos >= SizeOf(Byte) * 8 then
      Exit(DecodeLiteralFast(Probs, MatchByte, Matched));
{$ENDIF}
  P := @Probs;
  RangeValue := FRange;
  CodeValue := FCode;
  Symbol := 1;
  if Matched then
    MatchByte := MatchByte or $100
  else
    MatchByte := 0;
  repeat
    MatchByte := MatchByte shl 1;
    if MatchByte = 0 then
      Prob := @P^[Symbol]
    else
      Prob := @P^[$100 + (MatchByte and $100) + Symbol];
    if RangeValue < LZMA_TOP_VALUE then
    begin
      if FInputPos >= FInputLimit then
      begin
        FRange := RangeValue;
        FCode := CodeValue;
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range stream');
      end;
      RangeValue := RangeValue shl 8;
      CodeValue := (CodeValue shl 8) or FInput[FInputPos];
      Inc(FInputPos);
    end;
    Bound := (RangeValue shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob^);
    if CodeValue < Bound then
    begin
      RangeValue := Bound;
      Prob^ := CLzmaProb(Prob^ + ((LZMA_BIT_MODEL_TOTAL - Prob^) shr LZMA_NUM_MOVE_BITS));
      Symbol := Symbol shl 1;
    end
    else
    begin
      RangeValue := RangeValue - Bound;
      CodeValue := CodeValue - Bound;
      Prob^ := CLzmaProb(Prob^ - (Prob^ shr LZMA_NUM_MOVE_BITS));
      Symbol := (Symbol shl 1) or 1;
    end;
    if MatchByte shr 8 <> Symbol then
      MatchByte := 0;
  until Symbol >= $100;
  FRange := RangeValue;
  FCode := CodeValue;
  Result := Byte(Symbol - $100);
end;

function TLzmaDecoderState.DecodeDirectBits(const NumBits: UInt32): UInt32;
var
{$IFOPT Q+}
  I, RangeValue, CodeValue: UInt32;
{$ELSE}
  I, T, RangeValue, CodeValue: UInt32;
{$ENDIF}
begin
  RangeValue := FRange;
  CodeValue := FCode;
  Result := 0;
  for I := 1 to NumBits do
  begin
    if RangeValue < LZMA_TOP_VALUE then
    begin
      if FInputPos >= FInputLimit then
      begin
        FRange := RangeValue;
        FCode := CodeValue;
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range stream');
      end;
      RangeValue := RangeValue shl 8;
      CodeValue := (CodeValue shl 8) or FInput[FInputPos];
      Inc(FInputPos);
    end;
    RangeValue := RangeValue shr 1;
{$IFOPT Q+}
    // Preserve the high-bit test of (Code - Range) mod 2^32 without overflow.
    Result := Result shl 1;
    if (CodeValue >= RangeValue) and
      (CodeValue < (RangeValue or $80000000)) then
    begin
      CodeValue := CodeValue - RangeValue;
      Result := Result or 1;
    end;
{$ELSE}
    CodeValue := CodeValue - RangeValue;
    T := UInt32(0) - (CodeValue shr 31);
    CodeValue := CodeValue + (RangeValue and T);
    Result := (Result shl 1) + (T + 1);
{$ENDIF}
  end;
  FRange := RangeValue;
  FCode := CodeValue;
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
function TLzmaDecoderState.BitTreeDecodeFast(var Probs; const NumBits: UInt32): UInt32;
const
  kProbDeltaDifference = LZMA_BIT_MODEL_TOTAL - ((1 shl LZMA_NUM_MOVE_BITS) - 1);
asm
        .PARAMS 0
        .PUSHNV RBX
        .PUSHNV RSI
        .PUSHNV RDI
        .PUSHNV R12
        MOV     RBX,RCX
        MOV     RSI,RDX
        MOV     RDI,[RBX].TLzmaDecoderState.FInput
        ADD     RDI,[RBX].TLzmaDecoderState.FInputPos
        MOV     R10D,[RBX].TLzmaDecoderState.FRange
        MOV     R11D,[RBX].TLzmaDecoderState.FCode
        MOV     ECX,R8D
        MOV     R8D,1
        SHL     R8D,CL
        MOV     R9D,1
@@tree_bit:
        LEA     RDX,[RSI+R9*2]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RDI]
        OR      R11D,ECX
        INC     RDI
@@normalized:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R12B
        MOVZX   R12D,R12B
        IMUL    ECX,R12D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R12+R9*2]
        CMP     R9D,R8D
        JB      @@tree_bit
        MOV     [RBX].TLzmaDecoderState.FRange,R10D
        MOV     [RBX].TLzmaDecoderState.FCode,R11D
        SUB     RDI,[RBX].TLzmaDecoderState.FInput
        MOV     [RBX].TLzmaDecoderState.FInputPos,RDI
        MOV     EAX,R9D
        SUB     EAX,R8D
end;
{$ENDIF}

function TLzmaDecoderState.BitTreeDecode(var Probs; const NumBits: UInt32): UInt32;
var
  P: PProbArray;
  Prob: ^CLzmaProb;
  I, Bit, Bound, RangeValue, CodeValue: UInt32;
begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  // Each decoded bit can consume at most one normalization byte.
  if (NumBits > 0) and (NumBits <= kLenNumHighBits) then
    if FInputPos <= FInputLimit then
      if FInputLimit - FInputPos >= NumBits then
        Exit(BitTreeDecodeFast(Probs, NumBits));
{$ENDIF}
  P := @Probs;
  RangeValue := FRange;
  CodeValue := FCode;
  Result := 1;
  for I := 1 to NumBits do
  begin
    Prob := @P^[Result];
    if RangeValue < LZMA_TOP_VALUE then
    begin
      if FInputPos >= FInputLimit then
      begin
        FRange := RangeValue;
        FCode := CodeValue;
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range stream');
      end;
      RangeValue := RangeValue shl 8;
      CodeValue := (CodeValue shl 8) or FInput[FInputPos];
      Inc(FInputPos);
    end;
    Bound := (RangeValue shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob^);
    if CodeValue < Bound then
    begin
      RangeValue := Bound;
      Prob^ := CLzmaProb(Prob^ + ((LZMA_BIT_MODEL_TOTAL - Prob^) shr LZMA_NUM_MOVE_BITS));
      Bit := 0;
    end
    else
    begin
      RangeValue := RangeValue - Bound;
      CodeValue := CodeValue - Bound;
      Prob^ := CLzmaProb(Prob^ - (Prob^ shr LZMA_NUM_MOVE_BITS));
      Bit := 1;
    end;
    Result := (Result shl 1) or Bit;
  end;
  Dec(Result, UInt32(1) shl NumBits);
  FRange := RangeValue;
  FCode := CodeValue;
end;

function TLzmaDecoderState.BitTreeReverseDecode(var Probs; const NumBits: UInt32): UInt32;
var
  P: PProbArray;
  Prob: ^CLzmaProb;
  I, M, Bit, Bound, RangeValue, CodeValue: UInt32;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  FastValue: UInt32;
{$ENDIF}
begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if (NumBits > 0) and (NumBits <= kLenNumHighBits) then
    if FInputPos <= FInputLimit then
      if FInputLimit - FInputPos >= NumBits then
      begin
        FastValue := BitTreeDecodeFast(Probs, NumBits);
        Result := 0;
        for I := 1 to NumBits do
        begin
          Result := (Result shl 1) or (FastValue and 1);
          FastValue := FastValue shr 1;
        end;
        Exit;
      end;
{$ENDIF}
  P := @Probs;
  RangeValue := FRange;
  CodeValue := FCode;
  Result := 0;
  M := 1;
  for I := 0 to NumBits - 1 do
  begin
    Prob := @P^[M];
    if RangeValue < LZMA_TOP_VALUE then
    begin
      if FInputPos >= FInputLimit then
      begin
        FRange := RangeValue;
        FCode := CodeValue;
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Truncated LZMA range stream');
      end;
      RangeValue := RangeValue shl 8;
      CodeValue := (CodeValue shl 8) or FInput[FInputPos];
      Inc(FInputPos);
    end;
    Bound := (RangeValue shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob^);
    if CodeValue < Bound then
    begin
      RangeValue := Bound;
      Prob^ := CLzmaProb(Prob^ + ((LZMA_BIT_MODEL_TOTAL - Prob^) shr LZMA_NUM_MOVE_BITS));
      Bit := 0;
    end
    else
    begin
      RangeValue := RangeValue - Bound;
      CodeValue := CodeValue - Bound;
      Prob^ := CLzmaProb(Prob^ - (Prob^ shr LZMA_NUM_MOVE_BITS));
      Bit := 1;
    end;
    M := (M shl 1) or Bit;
    Result := Result or (Bit shl I);
  end;
  FRange := RangeValue;
  FCode := CodeValue;
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

procedure TLzmaDecoderState.InitializeOutput;
begin
  if Length(FDictionary) = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  if NativeUInt(Length(FDictionary)) >= kOutputBufferSize then
  begin
    FOutputBuffer := nil;
    FOutputData := @FDictionary[FDictPos];
    FOutputLimit := NativeUInt(Length(FDictionary)) - FDictPos;
    if FOutputLimit > kOutputBufferSize then
      FOutputLimit := kOutputBufferSize;
  end
  else
  begin
    if Length(FOutputBuffer) = 0 then
      SetLength(FOutputBuffer, kOutputBufferSize);
    FOutputData := Pointer(FOutputBuffer);
    FOutputLimit := NativeUInt(Length(FOutputBuffer));
  end;
end;

procedure TLzmaDecoderState.FlushOutput;
begin
  if FOutputPos = 0 then
    Exit;
  WriteExact(FOutput, FOutputData^, FOutputPos);
  FOutputPos := 0;
  if FOutputBuffer = nil then
    InitializeOutput;
end;

procedure TLzmaDecoderState.PutByte(const B: Byte);
begin
  if FOutputData = nil then
    InitializeOutput;
  AddHistoryByte(B);
  FOutputData[FOutputPos] := B;
  Inc(FOutputPos);
  if FOutputPos = FOutputLimit then
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
  if FOutputData = nil then
    InitializeOutput;

  Dist := NativeUInt(Distance);
  LenOriginal := NativeUInt(Len);
  Remaining := LenOriginal;
  if Dist > FDictPos then
    SourcePos := FDictPos + DictLen - Dist
  else
    SourcePos := FDictPos - Dist;

  if Dist = 1 then
  begin
    B := FDictionary[SourcePos];
    while Remaining <> 0 do
    begin
      if FOutputPos = FOutputLimit then
        FlushOutput;

      RunLen := Remaining;
      if RunLen > DictLen - FDictPos then
        RunLen := DictLen - FDictPos;
      OutputRun := FOutputLimit - FOutputPos;
      if RunLen > OutputRun then
        RunLen := OutputRun;

      FillChar(FDictionary[FDictPos], RunLen, B);
      if FOutputBuffer <> nil then
        FillChar(FOutputData[FOutputPos], RunLen, B);

      Inc(FDictPos, RunLen);
      if FDictPos = DictLen then
        FDictPos := 0;
      Inc(FOutputPos, RunLen);
      Dec(Remaining, RunLen);
    end;
  end
  else if Dist <= NativeUInt(Length(Pattern)) then
  begin
    PatternLen := Dist;
    for PatternIndex := 0 to PatternLen - 1 do
      Pattern[PatternIndex] := FDictionary[(SourcePos + PatternIndex) mod DictLen];
    PatternOffset := 0;

    while Remaining <> 0 do
    begin
      if FOutputPos = FOutputLimit then
        FlushOutput;

      RunLen := Remaining;
      if RunLen > DictLen - FDictPos then
        RunLen := DictLen - FDictPos;
      OutputRun := FOutputLimit - FOutputPos;
      if RunLen > OutputRun then
        RunLen := OutputRun;

      SeedLen := 0;
      while (SeedLen < RunLen) and (SeedLen < PatternLen) do
      begin
        FOutputData[FOutputPos + SeedLen] := Pattern[(PatternOffset + SeedLen) mod PatternLen];
        Inc(SeedLen);
      end;

      OutputRun := SeedLen;
      while OutputRun < RunLen do
      begin
        SeedLen := OutputRun;
        if SeedLen > RunLen - OutputRun then
          SeedLen := RunLen - OutputRun;
        Move(FOutputData[FOutputPos], FOutputData[FOutputPos + OutputRun], SeedLen);
        Inc(OutputRun, SeedLen);
      end;

      if FOutputBuffer <> nil then
        Move(FOutputData[FOutputPos], FDictionary[FDictPos], RunLen);
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
      if FOutputPos = FOutputLimit then
        FlushOutput;

      RunLen := Remaining;
      if RunLen > Dist then
        RunLen := Dist;
      if RunLen > DictLen - SourcePos then
        RunLen := DictLen - SourcePos;
      if RunLen > DictLen - FDictPos then
        RunLen := DictLen - FDictPos;
      OutputRun := FOutputLimit - FOutputPos;
      if RunLen > OutputRun then
        RunLen := OutputRun;

      Move(FDictionary[SourcePos], FOutputData[FOutputPos], RunLen);
      if FOutputBuffer <> nil then
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
  // A match can fill the buffer exactly before the next symbol is a literal.
  if FOutputPos = FOutputLimit then
    FlushOutput;
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
  if FInputLimit - FInputPos > kRangeFlushTailSize then
    Exit;
  if FCode <> 0 then
    Exit;
  for I := FInputPos to FInputLimit - 1 do
    if FInput[I] <> 0 then
      Exit;
  Result := True;
end;

procedure TLzmaDecoderState.ConsumeKnownSizeEndMarker;
var
  PosState: UInt32;
  Len: UInt32;
begin
  PosState := UInt32(FProcessed) and ((UInt32(1) shl FProps.Pb) - 1);
  if DecodeBit(FIsMatch[FState][PosState]) = 0 then
    RaiseLzmaError(SZ_ERROR_DATA, 'LZMA literal follows declared unpack size');
  if DecodeBit(FIsRep[FState]) <> 0 then
    RaiseLzmaError(SZ_ERROR_DATA, 'LZMA repeated match follows declared unpack size');
  Len := DecodeLen(FLenDecoder, PosState);
  if DecodeDistance(Len) <> High(UInt32) then
    RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match follows declared unpack size');
  NormalizeRange;
  if FCode <> 0 then
    RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA end marker did not finish cleanly');
  FEndMarkerConsumed := True;
end;

procedure TLzmaDecoderState.SaveDecodeSnapshot(var Snapshot: TDecodeSnapshot);
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
  if Length(Snapshot.Literals) <> Length(FLiterals) then
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
  if Length(FLiterals) <> Length(Snapshot.Literals) then
    SetLength(FLiterals, Length(Snapshot.Literals));
  if Length(Snapshot.Literals) <> 0 then
    System.Move(Snapshot.Literals[0], FLiterals[0], Length(Snapshot.Literals) * SizeOf(CLzmaProb));
end;

function TLzmaDecoderState.DecodeKnownSizePartial(const Data: TBytes; const Offset,
  PackSize: NativeUInt; const TotalUnpackSize, OutputLimit: UInt64; const Destination: TStream;
  out ConsumedSize: NativeUInt; out Finished, NeedsMoreInput: Boolean;
  const Progress: TLzma2ProgressEvent; const InputBase, OutputBase: UInt64): NativeUInt;
begin
  Result := DecodeKnownSizePartial(Data, Offset, PackSize, TotalUnpackSize,
    OutputLimit, True, Destination, ConsumedSize, Finished, NeedsMoreInput,
    Progress, InputBase, OutputBase);
end;

function TLzmaDecoderState.DecodeKnownSizePartial(const Data: TBytes; const Offset,
  PackSize: NativeUInt; const TotalUnpackSize, OutputLimit: UInt64; const FinishAtEnd: Boolean; const Destination: TStream;
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
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  FastContext: TSymbolContext;
  FastSymbol: TDecodedSymbol;
{$ENDIF}
  Snapshot: TDecodeSnapshot;
  SnapshotValid: Boolean;

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
  InitializeOutput;
  PbMask := (UInt32(1) shl FProps.Pb) - 1;
  LpMask := (UInt32(1) shl FProps.Lp) - 1;
  LcBits := FProps.Lc;
  LcShift := 8 - LcBits;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  FastContext.DictLen := DictLen;
  FastContext.PbMask := PbMask;
  FastContext.LpMask := LpMask;
  FastContext.LcBits := LcBits;
  FastContext.LcShift := LcShift;
{$ENDIF}

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
    SnapshotValid := FInputPos >= FInputLimit;
    if not SnapshotValid then
      SnapshotValid := FInputLimit - FInputPos < kMaxSymbolInput;
    if SnapshotValid then
      SaveDecodeSnapshot(Snapshot);
    try
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
      if FInputPos <= FInputLimit then
        if FInputLimit - FInputPos >= kMaxSymbolInput then
        begin
          DecodeSymbolFast(@FastContext, FastSymbol);
          case FastSymbol.Kind of
            skLiteral:
            begin
              NormalizeRange;
            SnapshotValid := False;
            PutByte(Byte(FastSymbol.Value));
              FState := LZMA_STATE_LITERAL_NEXT[FState];
            end;
            skShortRep:
            begin
              NormalizeRange;
            SnapshotValid := False;
            PutByte(GetByte(FReps[0]));
            end;
            skMatch, skRepMatch:
            begin
              if (FastSymbol.Kind = skMatch) and (FastSymbol.Value = UInt32($FFFFFFFF)) then
                RaiseLzmaError(SZ_ERROR_DATA, 'Unexpected raw LZMA end marker inside known-size stream');
              Len := FastSymbol.Len;
              Inc(Len, kMatchMinLen);
              if UInt64(Len) > TotalUnpackSize - FProcessed then
              RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match exceeds known unpack size');
              NormalizeRange;
            SnapshotValid := False;
            CopyMatch(FReps[0], Len);
            end;
            skBadHistory:
              RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');
            skRepBeforeLiteral:
              RaiseLzmaError(SZ_ERROR_DATA, 'LZMA rep match before any literal');
          end;
          MaybeReportProgress;
          Continue;
        end;
{$ENDIF}
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
        MatchByte := 0;
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
        end;
        Symbol := DecodeLiteral(FLiterals[LiteralOffset], MatchByte, FState >= kNumLitStates);
        NormalizeRange;
        SnapshotValid := False;
        PutByte(Byte(Symbol));
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
            NormalizeRange;
            SnapshotValid := False;
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
      NormalizeRange;
      Temp := FReps[0];
      SnapshotValid := False;
      CopyMatch(Temp, Len);
      MaybeReportProgress;
    except
      on E: Exception do
      begin
        if (E is ELzmaError) and (ELzmaError(E).ResultCode = SZ_ERROR_INPUT_EOF) then
        begin
          if not SnapshotValid then
            raise;
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
    // FINISH_ANY stops at the output limit without consuming an optional marker.
    if not FinishAtEnd and (FCode <> 0) then
    begin
      ConsumedSize := FInputPos - Offset;
      FlushOutput;
      Exit(ConsumedSize);
    end;
    if not TryConsumeRangeFlushTail then
    begin
      // A partial call may end inside the optional marker. Preserve its models
      // and input position so a later call can retry without emitting output.
      SaveDecodeSnapshot(Snapshot);
      try
        ConsumeKnownSizeEndMarker;
      except
        on E: Exception do
        begin
          if not ((E is ELzmaError) and
            (ELzmaError(E).ResultCode = SZ_ERROR_INPUT_EOF)) then
            raise;
          RestoreDecodeSnapshot(Snapshot);
          NeedsMoreInput := True;
          ConsumedSize := FInputPos - Offset;
          FlushOutput;
          Exit(ConsumedSize);
        end;
      end;
      if not TryConsumeRangeFlushTail then
        RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA end marker did not finish cleanly');
    end;
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
begin
  Result := NativeUInt(DecodeChunkInternal(Data, Offset, PackSize, UnpackSize, Destination,
    Progress, InputBase, OutputBase, False));
end;

function TLzmaDecoderState.DecodeKnownSize(const Data: TBytes; const Offset, PackSize: NativeUInt;
  const UnpackSize: UInt64; const Destination: TStream; const Progress: TLzma2ProgressEvent;
  const InputBase, OutputBase: UInt64): NativeUInt;
begin
  Result := NativeUInt(DecodeChunkInternal(Data, Offset, PackSize, UnpackSize, Destination,
    Progress, InputBase, OutputBase, True));
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
procedure TLzmaDecoderState.DecodeSymbolFast(const Context: PSymbolContext;
  out Decoded: TDecodedSymbol);
const
  kProbBytes = SizeOf(CLzmaProb);
  kRepBytes = SizeOf(UInt32);
  kLengthRowBytes = kLenNumLowSymbols * kProbBytes;
  kSlotRowBytes = (1 shl kNumPosSlotBits) * kProbBytes;
  kLiteralModelBytes = $300 * kProbBytes;
  kProbDeltaDifference = LZMA_BIT_MODEL_TOTAL - ((1 shl LZMA_NUM_MOVE_BITS) - 1);
asm
        .PARAMS 0
        .PUSHNV RBX
        .PUSHNV RSI
        .PUSHNV RDI
        .PUSHNV R12
        .PUSHNV R13
        .PUSHNV R14
        .PUSHNV R15
        MOV     RBX,RCX
        MOV     R12,RDX
        MOV     R15,R8
        MOV     DWORD PTR [R15].TDecodedSymbol.Kind,skLiteral
        MOV     DWORD PTR [R15].TDecodedSymbol.Value,0
        MOV     DWORD PTR [R15].TDecodedSymbol.Len,0
        MOV     RSI,[RBX].TLzmaDecoderState.FInput
        ADD     RSI,[RBX].TLzmaDecoderState.FInputPos
        MOV     R10D,[RBX].TLzmaDecoderState.FRange
        MOV     R11D,[RBX].TLzmaDecoderState.FCode
        MOV     R14D,[RBX].TLzmaDecoderState.FState
        MOV     R13D,DWORD PTR [RBX].TLzmaDecoderState.FProcessed
        AND     R13D,[R12].TSymbolContext.PbMask
        MOV     EAX,R14D
        SHL     EAX,kNumPosBitsMax+1
        LEA     RDX,[RBX].TLzmaDecoderState.FIsMatch
        ADD     RDX,RAX
        LEA     RDX,[RDX+R13*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_1
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_1:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@match_or_rep
        XOR     EAX,EAX
        CMP     QWORD PTR [RBX].TLzmaDecoderState.FProcessed,0
        JE      @@previous_ready
        MOV     RDI,[RBX].TLzmaDecoderState.FDictPos
        TEST    RDI,RDI
        JNZ     @@previous_position
        MOV     RDI,[R12].TSymbolContext.DictLen
@@previous_position:
        MOV     RDX,[RBX].TLzmaDecoderState.FDictionary
        MOVZX   EAX,BYTE PTR [RDX+RDI-1]
@@previous_ready:
        MOV     ECX,[R12].TSymbolContext.LcShift
        SHR     EAX,CL
        MOV     EDX,DWORD PTR [RBX].TLzmaDecoderState.FProcessed
        AND     EDX,[R12].TSymbolContext.LpMask
        MOV     ECX,[R12].TSymbolContext.LcBits
        SHL     EDX,CL
        ADD     EAX,EDX
        IMUL    EAX,kLiteralModelBytes
        MOV     RDI,[RBX].TLzmaDecoderState.FLiterals
        ADD     RDI,RAX
        CMP     R14D,kNumLitStates
        JB      @@plain_literal
        MOV     RAX,[R12].TSymbolContext.DictLen
        CMP     RAX,[RBX].TLzmaDecoderState.FProcessed
        CMOVA   RAX,[RBX].TLzmaDecoderState.FProcessed
        MOV     EDX,DWORD PTR [RBX].TLzmaDecoderState.FReps
        TEST    EDX,EDX
        JZ      @@bad_history
        CMP     RDX,RAX
        JA      @@bad_history
        MOV     RAX,[RBX].TLzmaDecoderState.FDictPos
        CMP     RAX,RDX
        JAE     @@matched_position
        ADD     RAX,[R12].TSymbolContext.DictLen
@@matched_position:
        SUB     RAX,RDX
        MOV     RCX,[RBX].TLzmaDecoderState.FDictionary
        MOVZX   R14D,BYTE PTR [RCX+RAX]
        OR      R14D,$100
        JMP     @@literal_start
@@plain_literal:
        XOR     R14D,R14D
@@literal_start:
        MOV     R9D,1
@@literal_bit:
        ADD     R14D,R14D
        MOV     EAX,R9D
        TEST    R14D,R14D
        JZ      @@literal_probability
        MOV     ECX,R14D
        AND     ECX,$100
        ADD     EAX,ECX
        ADD     EAX,$100
@@literal_probability:
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_2
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_2:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        XOR     EAX,EAX
        CMP     ECX,R9D
        CMOVNE  R14D,EAX
        CMP     R9D,$100
        JB      @@literal_bit
        SUB     R9D,$100
        MOV     [R15].TDecodedSymbol.Value,R9D
        JMP     @@finish
@@bad_history:
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skBadHistory
        JMP     @@finish
@@match_or_rep:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRep
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_3
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_3:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*3],EAX
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2],EAX
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes],EAX
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skMatch
        LEA     RDI,[RBX].TLzmaDecoderState.FLenDecoder
        JMP     @@length_choice
@@rep:
        CMP     QWORD PTR [RBX].TLzmaDecoderState.FProcessed,0
        JNE     @@rep_history
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skRepBeforeLiteral
        JMP     @@finish
@@rep_history:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRepG0
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_4
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_4:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_other
        MOV     EAX,R14D
        SHL     EAX,kNumPosBitsMax+1
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRep0Long
        ADD     RDX,RAX
        LEA     RDX,[RDX+R13*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_5
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_5:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_length
        LEA     RAX,LZMA_STATE_SHORT_REP_NEXT
        MOV     EAX,[RAX+R14*kRepBytes]
        MOV     [RBX].TLzmaDecoderState.FState,EAX
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skShortRep
        JMP     @@finish
@@rep_other:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRepG1
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_6
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_6:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_two_or_three
        MOV     R9D,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes]
        JMP     @@rep_promote
@@rep_two_or_three:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRepG2
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_7
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_7:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_three
        MOV     R9D,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2]
        JMP     @@rep_shift_two
@@rep_three:
        MOV     R9D,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*3]
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*3],EAX
@@rep_shift_two:
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2],EAX
@@rep_promote:
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes],EAX
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps,R9D
@@rep_length:
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skRepMatch
        LEA     RDI,[RBX].TLzmaDecoderState.FRepLenDecoder
@@length_choice:
        LEA     RDX,[RDI].TLenDecoder.Choice
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_8
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_8:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@length_choice_two
        LEA     RDI,[RDI].TLenDecoder.&Low
        JMP     @@length_low_row
@@length_choice_two:
        LEA     RDX,[RDI].TLenDecoder.Choice2
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_9
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_9:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@length_high
        MOV     DWORD PTR [R15].TDecodedSymbol.Len,kLenNumLowSymbols
        LEA     RDI,[RDI].TLenDecoder.Mid
@@length_low_row:
        MOV     EAX,R13D
        IMUL    EAX,kLengthRowBytes
        ADD     RDI,RAX
        MOV     R12D,1 shl kLenNumLowBits
        JMP     @@length_tree_start
@@length_high:
        MOV     DWORD PTR [R15].TDecodedSymbol.Len,kLenNumLowSymbols*2
        LEA     RDI,[RDI].TLenDecoder.&High
        MOV     R12D,1 shl kLenNumHighBits
@@length_tree_start:
        MOV     R9D,1
@@length_tree:
        LEA     RDX,[RDI+R9*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_10
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_10:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        CMP     R9D,R12D
        JB      @@length_tree
        SUB     R9D,R12D
        ADD     [R15].TDecodedSymbol.Len,R9D
        CMP     BYTE PTR [R15].TDecodedSymbol.Kind,skMatch
        JE      @@new_match_state
        LEA     RAX,LZMA_STATE_REP_NEXT
        MOV     EAX,[RAX+R14*kRepBytes]
        MOV     [RBX].TLzmaDecoderState.FState,EAX
        JMP     @@finish
@@new_match_state:
        LEA     RAX,LZMA_STATE_MATCH_NEXT
        MOV     EAX,[RAX+R14*kRepBytes]
        MOV     [RBX].TLzmaDecoderState.FState,EAX
        MOV     ECX,[R15].TDecodedSymbol.Len
        MOV     EAX,kNumLenToPosStates-1
        CMP     ECX,kNumLenToPosStates
        CMOVAE  ECX,EAX
        IMUL    ECX,kSlotRowBytes
        LEA     RDI,[RBX].TLzmaDecoderState.FPosSlot
        ADD     RDI,RCX
        MOV     R12D,1 shl kNumPosSlotBits
        MOV     R9D,1
@@slot_tree:
        LEA     RDX,[RDI+R9*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_11
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_11:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        CMP     R9D,R12D
        JB      @@slot_tree
        SUB     R9D,R12D
        MOV     [R15].TDecodedSymbol.Value,R9D
        CMP     R9D,kStartPosModelIndex
        JB      @@distance_ready
        MOV     R13D,R9D
        SHR     R13D,1
        DEC     R13D
        MOV     EAX,R9D
        AND     EAX,1
        OR      EAX,2
        MOV     ECX,R13D
        SHL     EAX,CL
        MOV     [R15].TDecodedSymbol.Value,EAX
        CMP     R9D,kEndPosModelIndex
        JAE     @@distance_direct
        SUB     EAX,R9D
        LEA     RDI,[RBX].TLzmaDecoderState.FPosDecoders
        LEA     RDI,[RDI+RAX*kProbBytes]
        JMP     @@reverse_start
@@distance_direct:
        SUB     R13D,kNumAlignBits
        XOR     R14D,R14D
@@direct_bit:
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@direct_normalized
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@direct_normalized:
        SHR     R10D,1
        SUB     R11D,R10D
        MOV     EAX,R11D
        SHR     EAX,31
        MOV     ECX,EAX
        NEG     ECX
        AND     ECX,R10D
        ADD     R11D,ECX
        XOR     EAX,1
        LEA     R14D,[RAX+R14*2]
        DEC     R13D
        JNZ     @@direct_bit
        SHL     R14D,kNumAlignBits
        ADD     [R15].TDecodedSymbol.Value,R14D
        LEA     RDI,[RBX].TLzmaDecoderState.FAlign
        MOV     R13D,kNumAlignBits
@@reverse_start:
        MOV     R9D,1
        MOV     R12D,1
        XOR     R14D,R14D
@@reverse_bit:
        LEA     RDX,[RDI+R9*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_12
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_12:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     EAX,R8D
        NEG     EAX
        AND     EAX,R12D
        OR      R14D,EAX
        ADD     R12D,R12D
        DEC     R13D
        JNZ     @@reverse_bit
        ADD     [R15].TDecodedSymbol.Value,R14D
@@distance_ready:
        MOV     EAX,[R15].TDecodedSymbol.Value
        CMP     EAX,$FFFFFFFF
        JE      @@finish
        INC     EAX
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps,EAX
@@finish:
        MOV     [RBX].TLzmaDecoderState.FRange,R10D
        MOV     [RBX].TLzmaDecoderState.FCode,R11D
        SUB     RSI,[RBX].TLzmaDecoderState.FInput
        MOV     [RBX].TLzmaDecoderState.FInputPos,RSI
end;

function TLzmaDecoderState.FastBulkCapacity(const DictLen: NativeUInt;
  const AvailableOutput, ProgressBudget: UInt64): UInt32;
var
  Space: NativeUInt;
  Quota: UInt64;
begin
  Result := 0;
  if (FOutputData = nil) or (FOutputBuffer <> nil) then
    Exit;
  if FOutputPos > FOutputLimit then
    Exit;
  if FOutputLimit - FOutputPos <= 1 then
    Exit;
  if FDictPos >= DictLen then
    Exit;
  if DictLen - FDictPos <= 1 then
    Exit;
  if FOutputPos > High(NativeUInt) - NativeUInt(FOutputData) then
    Exit;
  if NativeUInt(FOutputData) + FOutputPos <>
     NativeUInt(@FDictionary[FDictPos]) then
    Exit;
  Quota := kFastBulkByteLimit;
  Space := FOutputLimit - FOutputPos - 1;
  if UInt64(Space) < Quota then
    Quota := UInt64(Space);
  Space := DictLen - FDictPos - 1;
  if UInt64(Space) < Quota then
    Quota := UInt64(Space);
  if AvailableOutput < Quota then
    Quota := AvailableOutput;
  if ProgressBudget < Quota then
    Quota := ProgressBudget;
  if High(UInt64) - FProcessed < Quota then
    Quota := High(UInt64) - FProcessed;
  Result := UInt32(Quota);
end;

procedure TLzmaDecoderState.DecodeSymbolsBulk(const Context: PSymbolContext;
  var Bulk: TDecodedBulk);
const
  kProbBytes = SizeOf(CLzmaProb);
  kRepBytes = SizeOf(UInt32);
  kLengthRowBytes = kLenNumLowSymbols * kProbBytes;
  kLengthChildScale = kProbBytes * 2;
  kSlotRowBytes = (1 shl kNumPosSlotBits) * kProbBytes;
  kLiteralModelBytes = $300 * kProbBytes;
  kPlainChildScale = kProbBytes * 2;
  kProbDeltaDifference = LZMA_BIT_MODEL_TOTAL - ((1 shl LZMA_NUM_MOVE_BITS) - 1);
asm
        .PARAMS 0
        .PUSHNV RBX
        .PUSHNV RSI
        .PUSHNV RDI
        .PUSHNV R12
        .PUSHNV R13
        .PUSHNV R14
        .PUSHNV R15
        MOV     RBX,RCX
        MOV     R15,R8
        MOV     [R15].TDecodedBulk.Context,RDX
        MOV     DWORD PTR [R15].TDecodedBulk.ProducedBytes,0
        MOV     DWORD PTR [R15].TDecodedBulk.CompletedSymbols,0
        MOV     BYTE PTR [R15].TDecodedBulk.HasSymbol,0
        CLD
        MOV     RSI,[RBX].TLzmaDecoderState.FInput
        ADD     RSI,[RBX].TLzmaDecoderState.FInputPos
        MOV     R10D,[RBX].TLzmaDecoderState.FRange
        MOV     R11D,[RBX].TLzmaDecoderState.FCode
@@bulk_restart:
        CMP     DWORD PTR [R15].TDecodedBulk.RemainingBytes,0
        JE      @@bulk_commit
        MOV     RAX,[RBX].TLzmaDecoderState.FInput
        ADD     RAX,[RBX].TLzmaDecoderState.FInputLimit
        CMP     RSI,RAX
        JA      @@bulk_commit
        SUB     RAX,RSI
        CMP     RAX,kMaxSymbolInput
        JB      @@bulk_commit
        MOV     R12,[R15].TDecodedBulk.Context
        MOV     DWORD PTR [R15].TDecodedSymbol.Kind,skLiteral
        MOV     DWORD PTR [R15].TDecodedSymbol.Value,0
        MOV     DWORD PTR [R15].TDecodedSymbol.Len,0
        MOV     R14D,[RBX].TLzmaDecoderState.FState
        MOV     R13D,DWORD PTR [RBX].TLzmaDecoderState.FProcessed
        AND     R13D,[R12].TSymbolContext.PbMask
        MOV     EAX,R14D
        SHL     EAX,kNumPosBitsMax+1
        LEA     RDX,[RBX].TLzmaDecoderState.FIsMatch
        ADD     RDX,RAX
        LEA     RDX,[RDX+R13*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_1
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_1:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@match_or_rep
        XOR     EAX,EAX
        CMP     QWORD PTR [RBX].TLzmaDecoderState.FProcessed,0
        JE      @@previous_ready
        MOV     RDI,[RBX].TLzmaDecoderState.FDictPos
        TEST    RDI,RDI
        JNZ     @@previous_position
        MOV     RDI,[R12].TSymbolContext.DictLen
@@previous_position:
        MOV     RDX,[RBX].TLzmaDecoderState.FDictionary
        MOVZX   EAX,BYTE PTR [RDX+RDI-1]
@@previous_ready:
        MOV     ECX,[R12].TSymbolContext.LcShift
        SHR     EAX,CL
        MOV     EDX,DWORD PTR [RBX].TLzmaDecoderState.FProcessed
        AND     EDX,[R12].TSymbolContext.LpMask
        MOV     ECX,[R12].TSymbolContext.LcBits
        SHL     EDX,CL
        ADD     EAX,EDX
        IMUL    EAX,kLiteralModelBytes
        MOV     RDI,[RBX].TLzmaDecoderState.FLiterals
        ADD     RDI,RAX
        CMP     R14D,kNumLitStates
        JB      @@plain_literal
        MOV     RAX,[R12].TSymbolContext.DictLen
        CMP     RAX,[RBX].TLzmaDecoderState.FProcessed
        CMOVA   RAX,[RBX].TLzmaDecoderState.FProcessed
        MOV     EDX,DWORD PTR [RBX].TLzmaDecoderState.FReps
        TEST    EDX,EDX
        JZ      @@bad_history
        CMP     RDX,RAX
        JA      @@bad_history
        MOV     RAX,[RBX].TLzmaDecoderState.FDictPos
        CMP     RAX,RDX
        JAE     @@matched_position
        ADD     RAX,[R12].TSymbolContext.DictLen
@@matched_position:
        SUB     RAX,RDX
        MOV     RCX,[RBX].TLzmaDecoderState.FDictionary
        MOVZX   R14D,BYTE PTR [RCX+RAX]
        OR      R14D,$100
        JMP     @@matched8_start
@@plain_literal:
        JMP     @@plain8_start
@@matched8_start:
        // Match prefix is live only in these fixed stages. A divergence
        // enters the NEXT existing plain8 stage with the advanced node.
        MOV     R9D,1
@@matched8_bit_1:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_1
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_1:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        CMP     ECX,R9D
        JNE     @@matched8_plain_2
@@matched8_bit_2:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_2
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_2:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        CMP     ECX,R9D
        JNE     @@matched8_plain_3
@@matched8_bit_3:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_3
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_3:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        CMP     ECX,R9D
        JNE     @@matched8_plain_4
@@matched8_bit_4:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_4
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_4:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        CMP     ECX,R9D
        JNE     @@matched8_plain_5
@@matched8_bit_5:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_5
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_5:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        CMP     ECX,R9D
        JNE     @@matched8_plain_6
@@matched8_bit_6:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_6
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_6:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        CMP     ECX,R9D
        JNE     @@matched8_plain_7
@@matched8_bit_7:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_7
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_7:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     ECX,R14D
        SHR     ECX,8
        CMP     ECX,R9D
        JNE     @@matched8_plain_8
@@matched8_bit_8:
        ADD     R14D,R14D
        MOV     EAX,R14D
        AND     EAX,$100
        LEA     EAX,[RAX+R9+$100]
        LEA     RDX,[RDI+RAX*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@matched8_normalized_8
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@matched8_normalized_8:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        SUB     R9D,$100
        MOV     [R15].TDecodedSymbol.Value,R9D
        JMP     @@finish
@@matched8_plain_2:
        MOVZX   R14D,WORD PTR [RDI+R9*kProbBytes]
        JMP     @@plain8_bit_2
@@matched8_plain_3:
        MOVZX   R14D,WORD PTR [RDI+R9*kProbBytes]
        JMP     @@plain8_bit_3
@@matched8_plain_4:
        MOVZX   R14D,WORD PTR [RDI+R9*kProbBytes]
        JMP     @@plain8_bit_4
@@matched8_plain_5:
        MOVZX   R14D,WORD PTR [RDI+R9*kProbBytes]
        JMP     @@plain8_bit_5
@@matched8_plain_6:
        MOVZX   R14D,WORD PTR [RDI+R9*kProbBytes]
        JMP     @@plain8_bit_6
@@matched8_plain_7:
        MOVZX   R14D,WORD PTR [RDI+R9*kProbBytes]
        JMP     @@plain8_bit_7
@@matched8_plain_8:
        MOVZX   R14D,WORD PTR [RDI+R9*kProbBytes]
        JMP     @@plain8_bit_8
@@plain8_start:
        // Initial plain-literal path only. Context/PosState are dead until finish.
        MOV     R9D,1
        MOVZX   R14D,WORD PTR [RDI+kProbBytes]
@@plain8_bit_1:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kPlainChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kPlainChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_1
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_1:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        MOV     R14D,R12D
@@plain8_bit_2:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kPlainChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kPlainChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_2
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_2:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        MOV     R14D,R12D
@@plain8_bit_3:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kPlainChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kPlainChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_3
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_3:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        MOV     R14D,R12D
@@plain8_bit_4:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kPlainChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kPlainChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_4
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_4:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        MOV     R14D,R12D
@@plain8_bit_5:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kPlainChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kPlainChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_5
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_5:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        MOV     R14D,R12D
@@plain8_bit_6:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kPlainChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kPlainChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_6
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_6:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        MOV     R14D,R12D
@@plain8_bit_7:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kPlainChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kPlainChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_7
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_7:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        MOV     R14D,R12D
@@plain8_bit_8:
        LEA     RDX,[RDI+R9*kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@plain8_normalized_8
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@plain8_normalized_8:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R14D
        SUB     ECX,R10D
        MOV     R8D,R11D
        SUB     R11D,R10D
        CMOVB   R11D,R8D
        CMOVAE  R10D,ECX
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     R13D,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,R13D
        SBB     R9D,-1
        SUB     ECX,R14D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R14D,ECX
        MOV     WORD PTR [RDX],R14W
        SUB     R9D,$100
        MOV     [R15].TDecodedSymbol.Value,R9D
        JMP     @@finish
@@bad_history:
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skBadHistory
        JMP     @@finish
@@match_or_rep:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRep
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_3
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_3:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*3],EAX
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2],EAX
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes],EAX
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skMatch
        LEA     RDI,[RBX].TLzmaDecoderState.FLenDecoder
        JMP     @@length_choice
@@rep:
        CMP     QWORD PTR [RBX].TLzmaDecoderState.FProcessed,0
        JNE     @@rep_history
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skRepBeforeLiteral
        JMP     @@finish
@@rep_history:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRepG0
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_4
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_4:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_other
        MOV     EAX,R14D
        SHL     EAX,kNumPosBitsMax+1
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRep0Long
        ADD     RDX,RAX
        LEA     RDX,[RDX+R13*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_5
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_5:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_length
        LEA     RAX,LZMA_STATE_SHORT_REP_NEXT
        MOV     EAX,[RAX+R14*kRepBytes]
        MOV     [RBX].TLzmaDecoderState.FState,EAX
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skShortRep
        JMP     @@finish
@@rep_other:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRepG1
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_6
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_6:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_two_or_three
        MOV     R9D,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes]
        JMP     @@rep_promote
@@rep_two_or_three:
        LEA     RDX,[RBX].TLzmaDecoderState.FIsRepG2
        LEA     RDX,[RDX+R14*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_7
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_7:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@rep_three
        MOV     R9D,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2]
        JMP     @@rep_shift_two
@@rep_three:
        MOV     R9D,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*3]
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*3],EAX
@@rep_shift_two:
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes]
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes*2],EAX
@@rep_promote:
        MOV     EAX,DWORD PTR [RBX].TLzmaDecoderState.FReps
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps[kRepBytes],EAX
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps,R9D
@@rep_length:
        MOV     BYTE PTR [R15].TDecodedSymbol.Kind,skRepMatch
        LEA     RDI,[RBX].TLzmaDecoderState.FRepLenDecoder
@@length_choice:
        LEA     RDX,[RDI].TLenDecoder.Choice
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_8
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_8:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@length_choice_two
        LEA     RDI,[RDI].TLenDecoder.&Low
        JMP     @@length_low_row
@@length_choice_two:
        LEA     RDX,[RDI].TLenDecoder.Choice2
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_9
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_9:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        TEST    R8D,R8D
        JNZ     @@length_high
        MOV     DWORD PTR [R15].TDecodedSymbol.Len,kLenNumLowSymbols
        LEA     RDI,[RDI].TLenDecoder.Mid
@@length_low_row:
        MOV     EAX,R13D
        IMUL    EAX,kLengthRowBytes
        ADD     RDI,RAX
        // PosState in R13 and old Context/limit in R12 are now dead.
        // R14 keeps the pre-symbol state until the unchanged state table lookup.
        MOV     R9D,1
        MOVZX   R8D,WORD PTR [RDI+kProbBytes]
@@length3_bit_1:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length3_normalized_1
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length3_normalized_1:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length3_bit_2:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length3_normalized_2
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length3_normalized_2:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length3_bit_3:
        LEA     RDX,[RDI+R9*kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length3_normalized_3
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length3_normalized_3:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        SUB     R9D,1 shl kLenNumLowBits
        JMP     @@length_tree_complete
@@length_high:
        MOV     DWORD PTR [R15].TDecodedSymbol.Len,kLenNumLowSymbols*2
        LEA     RDI,[RDI].TLenDecoder.&High
        MOV     R9D,1
        MOVZX   R8D,WORD PTR [RDI+kProbBytes]
@@length8_bit_1:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_1
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_1:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length8_bit_2:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_2
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_2:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length8_bit_3:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_3
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_3:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length8_bit_4:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_4
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_4:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length8_bit_5:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_5
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_5:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length8_bit_6:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_6
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_6:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length8_bit_7:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOVZX   R12D,WORD PTR [RDI+R9*kLengthChildScale]
        MOVZX   R13D,WORD PTR [RDI+R9*kLengthChildScale+kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_7
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_7:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@length8_bit_8:
        LEA     RDX,[RDI+R9*kProbBytes]
        ADD     R9D,R9D
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@length8_normalized_8
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@length8_normalized_8:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        MOV     EAX,LZMA_BIT_MODEL_TOTAL
        CMOVB   ECX,EAX
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        SUB     R9D,1 shl kLenNumHighBits
@@length_tree_complete:
        ADD     [R15].TDecodedSymbol.Len,R9D
        CMP     BYTE PTR [R15].TDecodedSymbol.Kind,skMatch
        JE      @@new_match_state
        LEA     RAX,LZMA_STATE_REP_NEXT
        MOV     EAX,[RAX+R14*kRepBytes]
        MOV     [RBX].TLzmaDecoderState.FState,EAX
        JMP     @@finish
@@new_match_state:
        LEA     RAX,LZMA_STATE_MATCH_NEXT
        MOV     EAX,[RAX+R14*kRepBytes]
        MOV     [RBX].TLzmaDecoderState.FState,EAX
        MOV     ECX,[R15].TDecodedSymbol.Len
        MOV     EAX,kNumLenToPosStates-1
        CMP     ECX,kNumLenToPosStates
        CMOVAE  ECX,EAX
        IMUL    ECX,kSlotRowBytes
        LEA     RDI,[RBX].TLzmaDecoderState.FPosSlot
        ADD     RDI,RCX
        // Slot6 only: old state committed; R12/R13/R14 now dead.
        // Before each first5 bits, one bounded DWORD reads child0/child1.
        // EAX backs up code; CF selects the already loaded child.
        MOV     R9D,1
        MOV     R14D,LZMA_BIT_MODEL_TOTAL
        MOVZX   R8D,WORD PTR [RDI+kProbBytes]
@@slot6pair_bit_1:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOV     R12D,DWORD PTR [RDI+R9*4]
        MOV     R13D,R12D
        SHR     R13D,16
        MOVZX   R12D,R12W
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@slot6pair_normalized_1
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@slot6pair_normalized_1:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        CMOVB   ECX,R14D
        LEA     R9D,[R9+R9]
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@slot6pair_bit_2:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOV     R12D,DWORD PTR [RDI+R9*4]
        MOV     R13D,R12D
        SHR     R13D,16
        MOVZX   R12D,R12W
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@slot6pair_normalized_2
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@slot6pair_normalized_2:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        CMOVB   ECX,R14D
        LEA     R9D,[R9+R9]
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@slot6pair_bit_3:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOV     R12D,DWORD PTR [RDI+R9*4]
        MOV     R13D,R12D
        SHR     R13D,16
        MOVZX   R12D,R12W
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@slot6pair_normalized_3
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@slot6pair_normalized_3:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        CMOVB   ECX,R14D
        LEA     R9D,[R9+R9]
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@slot6pair_bit_4:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOV     R12D,DWORD PTR [RDI+R9*4]
        MOV     R13D,R12D
        SHR     R13D,16
        MOVZX   R12D,R12W
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@slot6pair_normalized_4
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@slot6pair_normalized_4:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        CMOVB   ECX,R14D
        LEA     R9D,[R9+R9]
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@slot6pair_bit_5:
        LEA     RDX,[RDI+R9*kProbBytes]
        MOV     R12D,DWORD PTR [RDI+R9*4]
        MOV     R13D,R12D
        SHR     R13D,16
        MOVZX   R12D,R12W
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@slot6pair_normalized_5
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@slot6pair_normalized_5:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        CMOVAE  R12D,R13D
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        CMOVB   ECX,R14D
        LEA     R9D,[R9+R9]
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        MOV     R8D,R12D
@@slot6pair_bit_6:
        LEA     RDX,[RDI+R9*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@slot6pair_normalized_6
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@slot6pair_normalized_6:
        MOV     ECX,R10D
        SHR     R10D,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    R10D,R8D
        SUB     ECX,R10D
        MOV     EAX,R11D
        SUB     R11D,R10D
        CMOVB   R11D,EAX
        CMOVAE  R10D,ECX
        MOV     ECX,(1 shl LZMA_NUM_MOVE_BITS)-1
        CMOVB   ECX,R14D
        LEA     R9D,[R9+R9]
        SBB     R9D,-1
        SUB     ECX,R8D
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     R8D,ECX
        MOV     WORD PTR [RDX],R8W
        SUB     R9D,1 shl kNumPosSlotBits
        MOV     [R15].TDecodedSymbol.Value,R9D
        CMP     R9D,kStartPosModelIndex
        JB      @@distance_ready
        MOV     R13D,R9D
        SHR     R13D,1
        DEC     R13D
        MOV     EAX,R9D
        AND     EAX,1
        OR      EAX,2
        MOV     ECX,R13D
        SHL     EAX,CL
        MOV     [R15].TDecodedSymbol.Value,EAX
        CMP     R9D,kEndPosModelIndex
        JAE     @@distance_direct
        SUB     EAX,R9D
        LEA     RDI,[RBX].TLzmaDecoderState.FPosDecoders
        LEA     RDI,[RDI+RAX*kProbBytes]
        JMP     @@reverse_start
@@distance_direct:
        SUB     R13D,kNumAlignBits
        XOR     R14D,R14D
@@direct_bit:
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@direct_normalized
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@direct_normalized:
        SHR     R10D,1
        SUB     R11D,R10D
        MOV     EAX,R11D
        SHR     EAX,31
        MOV     ECX,EAX
        NEG     ECX
        AND     ECX,R10D
        ADD     R11D,ECX
        XOR     EAX,1
        LEA     R14D,[RAX+R14*2]
        DEC     R13D
        JNZ     @@direct_bit
        SHL     R14D,kNumAlignBits
        ADD     [R15].TDecodedSymbol.Value,R14D
        LEA     RDI,[RBX].TLzmaDecoderState.FAlign
        MOV     R13D,kNumAlignBits
@@reverse_start:
        MOV     R9D,1
        MOV     R12D,1
        XOR     R14D,R14D
@@reverse_bit:
        LEA     RDX,[RDI+R9*kProbBytes]
        CMP     R10D,LZMA_TOP_VALUE
        JAE     @@normalized_12
        SHL     R10D,8
        SHL     R11D,8
        MOVZX   ECX,BYTE PTR [RSI]
        OR      R11D,ECX
        INC     RSI
@@normalized_12:
        MOVZX   ECX,WORD PTR [RDX]
        MOV     EAX,R10D
        SHR     EAX,LZMA_NUM_BIT_MODEL_TOTAL_BITS
        IMUL    EAX,ECX
        MOV     ECX,R10D
        SUB     ECX,EAX
        CMP     R11D,EAX
        CMOVB   ECX,EAX
        MOV     R10D,ECX
        MOV     ECX,R11D
        SUB     ECX,EAX
        CMOVAE  R11D,ECX
        SETAE   R8B
        MOVZX   R8D,R8B
        IMUL    ECX,R8D,kProbDeltaDifference
        NEG     ECX
        ADD     ECX,LZMA_BIT_MODEL_TOTAL
        MOVZX   EAX,WORD PTR [RDX]
        SUB     ECX,EAX
        SAR     ECX,LZMA_NUM_MOVE_BITS
        ADD     WORD PTR [RDX],CX
        LEA     R9D,[R8+R9*2]
        MOV     EAX,R8D
        NEG     EAX
        AND     EAX,R12D
        OR      R14D,EAX
        ADD     R12D,R12D
        DEC     R13D
        JNZ     @@reverse_bit
        ADD     [R15].TDecodedSymbol.Value,R14D
@@distance_ready:
        MOV     EAX,[R15].TDecodedSymbol.Value
        CMP     EAX,$FFFFFFFF
        JE      @@finish
        INC     EAX
        MOV     DWORD PTR [RBX].TLzmaDecoderState.FReps,EAX
@@finish:
        MOVZX   EAX,BYTE PTR [R15].TDecodedSymbol.Kind
        CMP     EAX,skLiteral
        JE      @@bulk_literal
        CMP     EAX,skShortRep
        JE      @@bulk_short_rep
        CMP     EAX,skMatch
        JNE     @@bulk_rep_or_error
        CMP     DWORD PTR [R15].TDecodedSymbol.Value,$FFFFFFFF
        JE      @@bulk_pending
        JMP     @@bulk_match
@@bulk_rep_or_error:
        CMP     EAX,skRepMatch
        JNE     @@bulk_pending
@@bulk_match:
        MOV     R13D,[R15].TDecodedSymbol.Len
        ADD     R13D,kMatchMinLen
        CMP     R13D,[R15].TDecodedBulk.RemainingBytes
        JA      @@bulk_pending
        MOV     R14,[R15].TDecodedBulk.Context
        MOV     R14,[R14].TSymbolContext.DictLen
        MOV     RAX,[RBX].TLzmaDecoderState.FProcessed
        CMP     RAX,R14
        CMOVA   RAX,R14
        MOV     R8D,DWORD PTR [RBX].TLzmaDecoderState.FReps
        TEST    R8D,R8D
        JZ      @@bulk_pending
        CMP     R8,RAX
        JA      @@bulk_pending
        MOV     R12,[RBX].TLzmaDecoderState.FDictPos
        CMP     R8,R12
        JA      @@bulk_pending
        CMP     R8D,1
        JE      @@bulk_fill_one
        MOV     R9,RSI
        MOV     RSI,[RBX].TLzmaDecoderState.FDictionary
        ADD     RSI,R12
        SUB     RSI,R8
        MOV     RDI,[RBX].TLzmaDecoderState.FOutputData
        ADD     RDI,[RBX].TLzmaDecoderState.FOutputPos
        MOV     ECX,R13D
        CMP     ECX,16
        JAE     @@bulk_copy_rep
        CMP     R8D,ECX
        JB      @@bulk_copy_rep
        CMP     ECX,8
        JB      @@bulk_copy_dword
        MOV     RAX,QWORD PTR [RSI]
        MOV     RDX,QWORD PTR [RSI+RCX-8]
        MOV     QWORD PTR [RDI],RAX
        MOV     QWORD PTR [RDI+RCX-8],RDX
        JMP     @@bulk_copy_done
@@bulk_copy_dword:
        CMP     ECX,4
        JB      @@bulk_copy_word
        MOV     EAX,DWORD PTR [RSI]
        MOV     EDX,DWORD PTR [RSI+RCX-4]
        MOV     DWORD PTR [RDI],EAX
        MOV     DWORD PTR [RDI+RCX-4],EDX
        JMP     @@bulk_copy_done
@@bulk_copy_word:
        MOVZX   EAX,WORD PTR [RSI]
        MOVZX   EDX,BYTE PTR [RSI+RCX-1]
        MOV     WORD PTR [RDI],AX
        MOV     BYTE PTR [RDI+RCX-1],DL
        JMP     @@bulk_copy_done
@@bulk_copy_rep:
        REP MOVSB
@@bulk_copy_done:
        MOV     RSI,R9
        JMP     @@bulk_match_committed
@@bulk_fill_one:
        MOV     RDI,[RBX].TLzmaDecoderState.FDictionary
        ADD     RDI,R12
        MOVZX   EAX,BYTE PTR [RDI-1]
        MOV     ECX,R13D
        REP STOSB
@@bulk_match_committed:
        ADD     [RBX].TLzmaDecoderState.FDictPos,R13
        ADD     [RBX].TLzmaDecoderState.FOutputPos,R13
        MOV     RAX,R14
        SUB     RAX,[RBX].TLzmaDecoderState.FDictFull
        CMP     R13,RAX
        JBE     @@bulk_match_history_add
        MOV     [RBX].TLzmaDecoderState.FDictFull,R14
        JMP     @@bulk_match_history_ready
@@bulk_match_history_add:
        ADD     [RBX].TLzmaDecoderState.FDictFull,R13
@@bulk_match_history_ready:
        ADD     [RBX].TLzmaDecoderState.FProcessed,R13
        JMP     @@bulk_completed
@@bulk_short_rep:
        MOV     RDX,[R15].TDecodedBulk.Context
        MOV     RAX,[RDX].TSymbolContext.DictLen
        CMP     RAX,[RBX].TLzmaDecoderState.FProcessed
        CMOVA   RAX,[RBX].TLzmaDecoderState.FProcessed
        MOV     ECX,DWORD PTR [RBX].TLzmaDecoderState.FReps
        TEST    ECX,ECX
        JZ      @@bulk_pending
        CMP     RCX,RAX
        JA      @@bulk_pending
        MOV     RAX,[RBX].TLzmaDecoderState.FDictPos
        CMP     RCX,RAX
        JA      @@bulk_pending
        SUB     RAX,RCX
        MOV     RDX,[RBX].TLzmaDecoderState.FDictionary
        MOVZX   R9D,BYTE PTR [RDX+RAX]
        JMP     @@bulk_byte
@@bulk_literal:
        MOV     R9D,[R15].TDecodedSymbol.Value
@@bulk_byte:
        MOV     RAX,[RBX].TLzmaDecoderState.FDictionary
        MOV     RCX,[RBX].TLzmaDecoderState.FDictPos
        MOV     BYTE PTR [RAX+RCX],R9B
        INC     RCX
        MOV     [RBX].TLzmaDecoderState.FDictPos,RCX
        MOV     RAX,[RBX].TLzmaDecoderState.FDictFull
        MOV     RDX,[R15].TDecodedBulk.Context
        CMP     RAX,[RDX].TSymbolContext.DictLen
        JAE     @@bulk_byte_history_full
        INC     RAX
        MOV     [RBX].TLzmaDecoderState.FDictFull,RAX
@@bulk_byte_history_full:
        INC     QWORD PTR [RBX].TLzmaDecoderState.FProcessed
        INC     QWORD PTR [RBX].TLzmaDecoderState.FOutputPos
        CMP     BYTE PTR [R15].TDecodedSymbol.Kind,skLiteral
        JNE     @@bulk_byte_state_ready
        MOV     ECX,[RBX].TLzmaDecoderState.FState
        LEA     RAX,LZMA_STATE_LITERAL_NEXT
        MOV     EAX,[RAX+RCX*kRepBytes]
        MOV     [RBX].TLzmaDecoderState.FState,EAX
@@bulk_byte_state_ready:
        MOV     R13D,1
@@bulk_completed:
        ADD     [R15].TDecodedBulk.ProducedBytes,R13D
        SUB     [R15].TDecodedBulk.RemainingBytes,R13D
        INC     DWORD PTR [R15].TDecodedBulk.CompletedSymbols
        CMP     DWORD PTR [R15].TDecodedBulk.CompletedSymbols,kFastBulkSymbolLimit
        JB      @@bulk_restart
        JMP     @@bulk_commit
@@bulk_pending:
        MOV     BYTE PTR [R15].TDecodedBulk.HasSymbol,1
@@bulk_commit:
        MOV     [RBX].TLzmaDecoderState.FRange,R10D
        MOV     [RBX].TLzmaDecoderState.FCode,R11D
        SUB     RSI,[RBX].TLzmaDecoderState.FInput
        MOV     [RBX].TLzmaDecoderState.FInputPos,RSI
end;
{$ENDIF}

function TLzmaDecoderState.DecodeChunkInternal(const Data: TBytes; const Offset, PackSize: NativeUInt;
  const UnpackSize: UInt64; const Destination: TStream; const Progress: TLzma2ProgressEvent;
  const InputBase, OutputBase: UInt64; const AllowEndMarker: Boolean;
  const Source: TStream; const InputCapacity: NativeUInt): UInt64;
const
  kProgressInterval = UInt64(1) shl 20;
var
  Input: TStreamInput;
  OutStart: UInt64;
  NextProgressAt: UInt64;
  PosState: UInt32;
  LitState: UInt32;
  PrevByte: Byte;
  MatchByte: UInt32;
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
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  FastContext: TSymbolContext;
  FastSymbol: TDecodedSymbol;
  FastBulk: TDecodedBulk;
  FastProgressBudget: UInt64;
  FastByteQuota: UInt32;
{$ENDIF}

  procedure MaybeReportProgress;
  var
    Produced: UInt64;
  begin
    if not Assigned(Progress) then
      Exit;
    Produced := FProcessed - OutStart;
    if Produced < NextProgressAt then
      Exit;
    ReportProgress(Progress, InputBase + Input.Base + UInt64(FInputPos - Offset),
      OutputBase + Produced);
    repeat
      Inc(NextProgressAt, kProgressInterval);
    until NextProgressAt > Produced;
  end;
begin
  InitializeInput(Data, Offset, PackSize, Source, InputCapacity, Input);
  FOutput := Destination;
  FOutputPos := 0;
  DictLen := NativeUInt(Length(FDictionary));
  if DictLen = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  InitializeOutput;
  PbMask := (UInt32(1) shl FProps.Pb) - 1;
  LpMask := (UInt32(1) shl FProps.Lp) - 1;
  LcBits := FProps.Lc;
  LcShift := 8 - LcBits;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  FastContext.DictLen := DictLen;
  FastContext.PbMask := PbMask;
  FastContext.LpMask := LpMask;
  FastContext.LcBits := LcBits;
  FastContext.LcShift := LcShift;
{$ENDIF}

  InitRange;

  OutStart := FProcessed;
  NextProgressAt := kProgressInterval;
  while FProcessed - OutStart < UnpackSize do
  begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    if FInputPos <= FInputLimit then
      if FInputLimit - FInputPos >= kMaxSymbolInput then
      begin
        FastProgressBudget := High(UInt64);
        if Assigned(Progress) then
        begin
          if FProcessed - OutStart < NextProgressAt then
            FastProgressBudget := NextProgressAt - (FProcessed - OutStart)
          else
            FastProgressBudget := 0;
        end;
        FastByteQuota := FastBulkCapacity(DictLen, UnpackSize - (FProcessed - OutStart), FastProgressBudget);
        if FastByteQuota <> 0 then
        begin
          FastBulk.RemainingBytes := FastByteQuota;
          DecodeSymbolsBulk(@FastContext, FastBulk);
          if not FastBulk.HasSymbol then
          begin
            MaybeReportProgress;
            Continue;
          end;
          FastSymbol := FastBulk.Symbol;
        end
        else
          DecodeSymbolFast(@FastContext, FastSymbol);
        case FastSymbol.Kind of
          skLiteral:
          begin
            PutByte(Byte(FastSymbol.Value));
            FState := LZMA_STATE_LITERAL_NEXT[FState];
          end;
          skShortRep:
          begin
            PutByte(GetByte(FReps[0]));
          end;
          skMatch, skRepMatch:
          begin
            if (FastSymbol.Kind = skMatch) and (FastSymbol.Value = UInt32($FFFFFFFF)) then
              RaiseLzmaError(SZ_ERROR_DATA, 'Unexpected raw LZMA end marker inside LZMA2 chunk');
            Len := FastSymbol.Len;
            Inc(Len, kMatchMinLen);
            if FProcessed - OutStart + Len > UnpackSize then
            RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match exceeds LZMA2 unpack size');
            CopyMatch(FReps[0], Len);
          end;
          skBadHistory:
            RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');
          skRepBeforeLiteral:
            RaiseLzmaError(SZ_ERROR_DATA, 'LZMA rep match before any literal');
        end;
        MaybeReportProgress;
        Continue;
      end;
{$ENDIF}
    if FInputLimit - FInputPos < kMaxSymbolInput then
      RefillInput(Input, kMaxSymbolInput);
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
      MatchByte := 0;
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
      end;
      Symbol := DecodeLiteral(FLiterals[LiteralOffset], MatchByte, FState >= kNumLitStates);
      PutByte(Byte(Symbol));
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

  if AllowEndMarker and (FCode <> 0) then
  begin
    RefillInput(Input, kMaxSymbolInput);
    ConsumeKnownSizeEndMarker;
  end;
  // SDK-compatible known-size chunks can finish exactly or leave only the range-coder flush tail unread.
  if not FinishInput(Input) then
    RaiseLzmaError(SZ_ERROR_DATA, 'LZMA chunk range coder did not finish cleanly');
  FlushOutput;
  if Source <> nil then
    Result := CheckedMemoryAdd(Input.Base, UInt64(FInputLimit))
  else
    Result := PackSize;
end;

function TLzmaDecoderState.DecodeUntilEndMarkerInternal(const Data: TBytes; const Offset,
  PackSize: NativeUInt; const Destination: TStream; const Progress: TLzma2ProgressEvent;
  const InputBase, OutputBase: UInt64; const Source: TStream;
  const InputCapacity: NativeUInt): UInt64;
const
  kProgressInterval = UInt64(1) shl 20;
var
  Input: TStreamInput;
  OutStart: UInt64;
  NextProgressAt: UInt64;
  PosState: UInt32;
  LitState: UInt32;
  PrevByte: Byte;
  MatchByte: UInt32;
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
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  FastContext: TSymbolContext;
  FastSymbol: TDecodedSymbol;
  FastBulk: TDecodedBulk;
  FastProgressBudget: UInt64;
  FastByteQuota: UInt32;
{$ENDIF}

  procedure MaybeReportProgress;
  var
    Produced: UInt64;
  begin
    if not Assigned(Progress) then
      Exit;
    Produced := FProcessed - OutStart;
    if Produced < NextProgressAt then
      Exit;
    ReportProgress(Progress, InputBase + Input.Base + UInt64(FInputPos - Offset),
      OutputBase + Produced);
    repeat
      Inc(NextProgressAt, kProgressInterval);
    until NextProgressAt > Produced;
  end;
begin
  InitializeInput(Data, Offset, PackSize, Source, InputCapacity, Input);
  FOutput := Destination;
  FOutputPos := 0;
  DictLen := NativeUInt(Length(FDictionary));
  if DictLen = 0 then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA dictionary is not allocated');
  InitializeOutput;
  PbMask := (UInt32(1) shl FProps.Pb) - 1;
  LpMask := (UInt32(1) shl FProps.Lp) - 1;
  LcBits := FProps.Lc;
  LcShift := 8 - LcBits;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  FastContext.DictLen := DictLen;
  FastContext.PbMask := PbMask;
  FastContext.LpMask := LpMask;
  FastContext.LcBits := LcBits;
  FastContext.LcShift := LcShift;
{$ENDIF}

  InitRange;

  OutStart := FProcessed;
  NextProgressAt := kProgressInterval;
  while True do
  begin
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
    if FInputPos <= FInputLimit then
      if FInputLimit - FInputPos >= kMaxSymbolInput then
      begin
        FastProgressBudget := High(UInt64);
        if Assigned(Progress) then
        begin
          if FProcessed - OutStart < NextProgressAt then
            FastProgressBudget := NextProgressAt - (FProcessed - OutStart)
          else
            FastProgressBudget := 0;
        end;
        FastByteQuota := FastBulkCapacity(DictLen, High(UInt64), FastProgressBudget);
        if FastByteQuota <> 0 then
        begin
          FastBulk.RemainingBytes := FastByteQuota;
          DecodeSymbolsBulk(@FastContext, FastBulk);
          if not FastBulk.HasSymbol then
          begin
            MaybeReportProgress;
            Continue;
          end;
          FastSymbol := FastBulk.Symbol;
        end
        else
          DecodeSymbolFast(@FastContext, FastSymbol);
        case FastSymbol.Kind of
          skLiteral:
          begin
            PutByte(Byte(FastSymbol.Value));
            FState := LZMA_STATE_LITERAL_NEXT[FState];
          end;
          skShortRep:
          begin
            PutByte(GetByte(FReps[0]));
          end;
          skMatch, skRepMatch:
          begin
            if (FastSymbol.Kind = skMatch) and (FastSymbol.Value = UInt32($FFFFFFFF)) then
              begin
              if not FinishInput(Input) then
                RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA end marker did not finish cleanly');
              FEndMarkerConsumed := True;
              FlushOutput;
              if Source <> nil then
                Exit(CheckedMemoryAdd(Input.Base, UInt64(FInputLimit)));
              Exit(FInputPos - Offset);
            end;
            Len := FastSymbol.Len;
            Inc(Len, kMatchMinLen);

            CopyMatch(FReps[0], Len);
          end;
          skBadHistory:
            RaiseLzmaError(SZ_ERROR_DATA, 'LZMA match distance exceeds dictionary history');
          skRepBeforeLiteral:
            RaiseLzmaError(SZ_ERROR_DATA, 'LZMA rep match before any literal');
        end;
        MaybeReportProgress;
        Continue;
      end;
{$ENDIF}
    if FInputLimit - FInputPos < kMaxSymbolInput then
      RefillInput(Input, kMaxSymbolInput);
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
      MatchByte := 0;
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
      end;
      Symbol := DecodeLiteral(FLiterals[LiteralOffset], MatchByte, FState >= kNumLitStates);
      PutByte(Byte(Symbol));
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
        if not FinishInput(Input) then
          RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA end marker did not finish cleanly');
        FEndMarkerConsumed := True;
        FlushOutput;
        if Source <> nil then
          Exit(CheckedMemoryAdd(Input.Base, UInt64(FInputLimit)));
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

function TLzmaDecoderState.DecodeUntilEndMarker(const Data: TBytes; const Offset,
  PackSize: NativeUInt; const Destination: TStream; const Progress: TLzma2ProgressEvent;
  const InputBase, OutputBase: UInt64): NativeUInt;
begin
  Result := NativeUInt(DecodeUntilEndMarkerInternal(Data, Offset, PackSize, Destination,
    Progress, InputBase, OutputBase, nil, 0));
end;

function TLzmaDecoderState.DecodeKnownSizeStream(const Source: TStream;
  const InputCapacity: NativeUInt; const UnpackSize: UInt64; const Destination: TStream;
  const Progress: TLzma2ProgressEvent; const InputBase, OutputBase: UInt64): UInt64;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');
  Result := DecodeChunkInternal(nil, 0, 0, UnpackSize, Destination, Progress,
    InputBase, OutputBase, True, Source, InputCapacity);
end;

function TLzmaDecoderState.DecodeUntilEndMarkerStream(const Source: TStream;
  const InputCapacity: NativeUInt; const Destination: TStream;
  const Progress: TLzma2ProgressEvent; const InputBase, OutputBase: UInt64): UInt64;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');
  Result := DecodeUntilEndMarkerInternal(nil, 0, 0, Destination, Progress,
    InputBase, OutputBase, Source, InputCapacity);
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
    State.DecodeKnownSize(Data, 0, Length(Data), UnpackedSize, Destination);
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
