unit Lzma.Encoder;

{$B-} // Match-history bounds guards must precede indexed reads.

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
  private
    class function RequiredMemoryCore(const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const InputCapacity: NativeUInt; const Framed, SdkFinder: Boolean;
      const HashOutBits: UInt32; const ExpectedDataSize: UInt64): UInt64; static;
    class function RequiredMemoryForInputCore(const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const InputUpperBound: UInt64; const BufferSize: NativeUInt;
      const Framed, SdkFinder: Boolean; const HashOutBits: UInt32;
      const ExpectedDataSize: UInt64): UInt64; static;
    class procedure EncodeLzma2StreamCore(Source, Destination: TStream;
      const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
      const Progress: TLzma2ProgressEvent; const Diagnostics: PLzma2EncodeDiagnostics;
      const BufferSize: NativeUInt; const MemoryLimit: UInt64;
      const UseSdkMtHighHash: Boolean); static;
    class procedure EncodeStreamCore(Source, Destination: TStream;
      const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
      const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
      const MemoryLimit: UInt64; const UseMatchFinderThread, UseSdkMtHighHash: Boolean;
      out FullOptimumDecisionCount: UInt64; out ActualThreadCount: Integer;
      const Progress: TLzma2ProgressEvent; const SdkFinder: Boolean = False;
      const HashOutBits: UInt32 = 0; const ExpectedDataSize: UInt64 = High(UInt64)); static;
  public
    class function NormalizeProfile(const Level: TLzma2CompressionLevel; const DictionarySize: UInt64): TLzmaEncoderProfile; static;
    class function EffectiveHistorySize(const DictionarySize: UInt64): NativeUInt; static;
    class function MaximumLzma2EncodedSize(const InputSize: UInt64): UInt64; static;
    // Upper bound for owned input/kernel payloads; caller/RTL/allocator overhead is separate.
    class function RequiredStreamingMemory(const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const InputCapacity: NativeUInt; const Framed: Boolean): UInt64; static;
    // Includes every input-window allocation/admission stage for any input up to this size.
    class function RequiredStreamingMemoryForInput(const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const InputUpperBound: UInt64; const BufferSize: NativeUInt;
      const Framed: Boolean): UInt64; static;
    class function ResolveThreadCount(const Profile: TLzmaEncoderProfile;
      const RequestedThreadCount: Integer): Integer; static;
    class function RequiredStreamingMemoryForInputWithThreads(const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const InputUpperBound: UInt64; const BufferSize: NativeUInt;
      const RequestedThreadCount: Integer): UInt64; static;
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
    class procedure EncodeLzma2Stream(Source, Destination: TStream;
      const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
      const Progress: TLzma2ProgressEvent = nil;
      const Diagnostics: PLzma2EncodeDiagnostics = nil;
      const BufferSize: NativeUInt = 0; const MemoryLimit: UInt64 = 0); static;
    // Internal worker entry; scheduling and memory ownership remain with the caller.
    class procedure EncodeLzma2MtWorkerStream(Source, Destination: TStream;
      const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
      const Progress: TLzma2ProgressEvent; const Diagnostics: PLzma2EncodeDiagnostics;
      const BufferSize: NativeUInt; const MemoryLimit: UInt64); static;
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
    class procedure Encode(Source: TStream; Destination: TStream; const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
      const MemoryLimit: UInt64; out FullOptimumDecisionCount: UInt64;
      const Progress: TLzma2ProgressEvent = nil); overload; static;
    class procedure EncodeWithThreads(Source, Destination: TStream;
      const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
      const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
      const MemoryLimit: UInt64; const RequestedThreadCount: Integer;
      out FullOptimumDecisionCount: UInt64; out ActualThreadCount: Integer;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure EncodeWithSdkSettings(Source, Destination: TStream;
      const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
      const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
      const MemoryLimit: UInt64; const RequestedThreadCount: Integer;
      const HashOutBits: UInt32; const ExpectedDataSize: UInt64;
      out FullOptimumDecisionCount: UInt64; out ActualThreadCount: Integer;
      const Progress: TLzma2ProgressEvent = nil); static;
    class function RequiredSdkMemoryForInputWithThreads(const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const InputUpperBound: UInt64; const BufferSize: NativeUInt;
      const RequestedThreadCount: Integer; const HashOutBits: UInt32;
      const ExpectedDataSize: UInt64): UInt64; static;
{$IFDEF LZMA_MT_QA}
    // Test-only serial reference: SDK MT hash mode with no producer thread.
    class procedure EncodeMtReference(Source, Destination: TStream;
      const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
      const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
      const MemoryLimit: UInt64; out FullOptimumDecisionCount: UInt64;
      const Progress: TLzma2ProgressEvent = nil); static;
{$ENDIF}
  end;

implementation

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
{$IFOPT Q-}
{$IFOPT R-}
{$DEFINE LZMA_ENCODER_FLAT_OPTIMUM_FRAME}
{$ENDIF}
{$ENDIF}
{$ENDIF}

uses
  Lzma.Alloc,
  Lzma.EncoderHeuristics,
  Lzma.Errors,
  Lzma.MtMatchFinder,
  Lzma.PriceTables,
  Lzma.Sdk.MatchFinder,
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

  TLzmaStatefulFrameLimits = record
  public const
    MaxUnpackedSize = NativeUInt(1) shl 21;
    MaxPackedSize = UInt64(1) shl 16;
    // SDK 26.05 LzmaEnc.c, kPackReserve and LzmaEnc_CodeOneBlock limits.
    FullOptimumUnpackSlack = 300;
    UnpackReserve = NativeUInt(LZMA_FULL_OPTIMUM_NUM_OPTS + FullOptimumUnpackSlack);
    PackReserve = UInt64(LZMA_FULL_OPTIMUM_NUM_OPTS) * 8;
  end;

  TProbArray = array[0..MaxInt div SizeOf(CLzmaProb) - 1] of CLzmaProb;
  PProbArray = ^TProbArray;

  TLenEncoder = record
    Low: TLzmaLenLowProbs;
    High: TLzmaLenHighProbs;
  end;

  TLzmaRangeEncoder = class
  private const
    kStreamBufferCapacity = NativeUInt(1) shl 15;
    kInitialOutputCapacity = NativeUInt(1) shl 16;
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
    class function OutputCapacityFor(const OutputBytes: UInt64): NativeUInt; static;
  end;

  PLzmaLiteralProbs = ^TLzmaLiteralProbs;

  TLzmaEncoderModelSnapshot = record
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
    Literals: TArray<CLzmaProb>;
    State: UInt32;
    Reps: array[0..3] of UInt32;
  end;

  TLzmaEncoderContext = class
  private
    FInitialized: Boolean;
    FUseSdkMtHighHash: Boolean;
    FUseSdkFinder: Boolean;
    FSdkHashOutBits: UInt32;
    FSdkExpectedDataSize: UInt64;
    FUseMatchFinderThread: Boolean;
    FMatchFinderThread: TLzmaMatchFinderPipeline;
    FWindowBase: UInt64;
    FThreadProgress: TLzma2ProgressEvent;
    FOutputSink: TStream;
    FContinuousRange: Boolean;
    FFrameStart: NativeUInt;
    FModelSnapshot: TLzmaEncoderModelSnapshot;
    IsMatch: TLzmaOptimumModelPosStateProbs;
    IsRep: TLzmaOptimumModelStateProbs;
    IsRepG0: TLzmaOptimumModelStateProbs;
    IsRepG1: TLzmaOptimumModelStateProbs;
    IsRepG2: TLzmaOptimumModelStateProbs;
    IsRep0Long: TLzmaOptimumModelPosStateProbs;
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
    SdkFinder: TLzmaSdkMatchFinder;
    Encoder: TLzmaRangeEncoder;
    Pos: NativeUInt;
    Processed: UInt64;
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

    PricedLiteralPrice: UInt32;
    PricedShortRepPrice: UInt32;
    InsertedUntil: NativeUInt;
    MatchCache: TLzmaFastParserMatchCache;
    NextProgressAt: UInt64;
    LocalFullOptimumDecisionCount: UInt64;
  public
    constructor Create(const OutputSink: TStream = nil);
    destructor Destroy; override;
    procedure RebaseWindow(const DropCount, NewCount: NativeUInt);
    procedure PauseMatchFinder;
    procedure ResumeMatchFinder(const Count: NativeUInt; const FinalInput: Boolean);
    procedure SaveModels(var Snapshot: TLzmaEncoderModelSnapshot);
    procedure RestoreModels(const Snapshot: TLzmaEncoderModelSnapshot);
    function Encode(const Data: TBytes; const Offset, Count: NativeUInt;
  const Props: TLzmaProps; const FastBytes: Integer; const CutValue: UInt32;
  const MatchFinderKind: TLzmaMatchFinderKind; const WriteEndMarker: Boolean;
  const EnableOptimumWindow: Boolean; const Progress: TLzma2ProgressEvent;
  const FullOptimumDecisionCount: PUInt64; const BoundedFrame: Boolean = False;
  const FinalInput: Boolean = True;
  const FrameUnpackLimit: NativeUInt = TLzmaStatefulFrameLimits.MaxUnpackedSize): TBytes;
  end;

{$IFDEF LZMA_ENCODER_FLAT_OPTIMUM_FRAME}
type
  PEncoderOptimumInputBytes = ^TBytes;
  TEncoderFullOptimumFrame = record
    Owner: TLzmaEncoderContext;
    InputRef: PEncoderOptimumInputBytes;
    Offset, Count: NativeUInt;
    Cur, Last, MainLen, NumAvail, NumPairs, BestRep: UInt32;
    MainMatch: TLzmaMatch;
    RepLens: TLzmaOptimumRepLens;
    Model: TLzmaOptimumProbModelView;


    function NumAvailAt(const RelativePos: NativeUInt): UInt32;
    function RepLenAtPos(const RelativePos: NativeUInt; const Distance: UInt32): UInt32;
    procedure InsertRange(const RelativePos, RangeCount: NativeUInt);
    procedure EnsureInsertedUntil(const NewInsertedUntil: NativeUInt);
    procedure MarkInsertedUntil(const NewInsertedUntil: NativeUInt);
    function ReadMatchDistancesAndInsert(const RelativePos: NativeUInt;
    var MatchList: TLzmaMatchBuffer): TLzmaMatch;
    function ReadCurrentMatchDistances(const RelativePos: NativeUInt;
    var MatchList: TLzmaMatchBuffer): TLzmaMatch;
    function AvailableAt(const At: UInt32): UInt32;
    function ProbsAt(const At, AtState: UInt32): TLzmaOptimumProbInput;
    function RepLength(const At, Distance, Limit: UInt32): UInt32;
    function LiteralCost(const At, AtState, RepDistance: UInt32): UInt32;
    function Rep0Price(const At, AtState: UInt32): UInt32;
    procedure ExtendFrontier(const Target: UInt32);
    procedure Store(const Target, Price, Len, PathBack, Extra: UInt32;
      const Source: TLzmaOptimumNode);
    procedure Relax(const Initial: Boolean);
    function Run(out Back: UInt32): UInt32;
  end;
{$ENDIF}



  TLzmaEncoderInputWindow = record
    Source: TStream;
    Data: TBytes;
    Count, Capacity, DictionarySize, ReadQuantum: NativeUInt;
    FinalInput: Boolean;
    IncrementalInput: Boolean;
    TotalRead, MaxRetained: UInt64;
    Progress: TLzma2ProgressEvent;
    ReportedInput, ReportedOutput: UInt64;
    procedure Initialize(InputSource: TStream; const Profile: TLzmaEncoderProfile;
      const Props: TLzmaProps; const InputProgress: TLzma2ProgressEvent = nil;
      const BufferSize: NativeUInt = 0; const Incremental: Boolean = False;
      const MemoryLimit: UInt64 = 0; const Framed: Boolean = False;
      const SdkFinder: Boolean = False; const HashOutBits: UInt32 = 0;
      const ExpectedDataSize: UInt64 = High(UInt64));
    procedure Fill;
    procedure RefillAtBoundary(Context: TLzmaEncoderContext; const CommittedOutput: UInt64 = 0);
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
  Slot := LzmaGetPosSlot(Dist);
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

function LzmaEncoderLiteralProbCount(const Props: TLzmaProps): NativeInt;
begin
  if (Props.Lc > 8) or (Props.Lp > 4) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA literal properties');
  Result := (SizeOf(TLzmaLiteralProbs) div SizeOf(CLzmaProb)) shl (Props.Lc + Props.Lp);
end;

function LzmaEncoderOptimumWindowEnd(const Available: NativeUInt): UInt32;
begin
  if Available >= LZMA_FULL_OPTIMUM_NUM_OPTS then
    Result := LZMA_FULL_OPTIMUM_NUM_OPTS - 1
  else
    Result := UInt32(Available);
end;

class function TLzmaRangeEncoder.OutputCapacityFor(const OutputBytes: UInt64): NativeUInt;
begin
  if OutputBytes = 0 then Exit(0);
  if OutputBytes > UInt64(High(NativeInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA range output exceeds native TBytes capacity');
  Result := kInitialOutputCapacity;
  while UInt64(Result) < OutputBytes do
  begin
    if Result > NativeUInt(High(NativeInt)) div 2 then
      RaiseLzmaError(SZ_ERROR_MEM, 'LZMA range output exceeds native TBytes capacity');
    Result := Result * 2;
  end;
end;

function SdkFinderHashBytes(const Kind: TLzmaMatchFinderKind): UInt32;
begin
  case Kind of
    mfBinaryTree2: Result := 2;
    mfBinaryTree3: Result := 3;
    mfHashChain5, mfBinaryTree5: Result := 5;
  else Result := 4;
  end;
end;

function SdkFinderIsBinaryTree(const Kind: TLzmaMatchFinderKind): Boolean;
begin Result := Kind in [mfBinaryTree2, mfBinaryTree3, mfBinaryTree4, mfBinaryTree5]; end;

class function TLzmaRawEncoder.RequiredStreamingMemory(const Profile: TLzmaEncoderProfile;
  const Props: TLzmaProps; const InputCapacity: NativeUInt; const Framed: Boolean): UInt64;
begin Result := RequiredMemoryCore(Profile, Props, InputCapacity, Framed, False, 0, High(UInt64)); end;

class function TLzmaRawEncoder.RequiredMemoryCore(const Profile: TLzmaEncoderProfile;
  const Props: TLzmaProps; const InputCapacity: NativeUInt; const Framed, SdkFinder: Boolean;
  const HashOutBits: UInt32; const ExpectedDataSize: UInt64): UInt64;
var
  LiteralBytes, Workspace, Decisions, Replay, Cells, WindowEnd: UInt64;
  RangeCapacity, PayloadBytes, ParserPeak, MaterialPeak: UInt64;
  FullParser: Boolean;
begin
  if (Props.Lc > 8) or (Props.Lp > 4) or (Props.Pb > 4) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA encoder properties');
  if Framed and (Props.Lc + Props.Lp > 4) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA2 encoder properties');
  if InputCapacity > NativeUInt(High(NativeInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'LZMA input exceeds native TBytes capacity');
  // The framed empty-input route constructs a context but does not enter Encode.
  if Framed and (InputCapacity = 0) then
    Exit(TLzmaEncoderContext.InstanceSize);
  Result := CheckedMemoryAdd(InputCapacity, UInt64(TLzmaEncoderContext.InstanceSize));
  Result := CheckedMemoryAdd(Result, UInt64(TLzmaRangeEncoder.InstanceSize));
  if SdkFinder then
    Result := CheckedMemoryAdd(Result, TLzmaSdkMatchFinder.RequiredMemory(InputCapacity,
      EffectiveHistorySize(Props.DictionarySize), SdkFinderHashBytes(Profile.MatchFinderKind),
      SdkFinderIsBinaryTree(Profile.MatchFinderKind), HashOutBits, ExpectedDataSize, True))
  else
    Result := CheckedMemoryAdd(Result, LzmaMatchFinderMemoryRequired(InputCapacity,
      EffectiveHistorySize(Props.DictionarySize), Profile.MatchFinderKind));
  LiteralBytes := CheckedMemoryMultiply(UInt64(LzmaEncoderLiteralProbCount(Props)), SizeOf(CLzmaProb));
  Result := CheckedMemoryAdd(Result, LiteralBytes);
  if Framed then Result := CheckedMemoryAdd(Result, LiteralBytes);
  Workspace := 0;
  Decisions := 0;
  Replay := 0;
  FullParser := (Profile.ParserMode = lpmSdkProfile) and (Profile.Algorithm <> 0);
  if FullParser then
  begin
    Result := CheckedMemoryAdd(Result,
      CheckedMemoryMultiply(LZMA_FULL_OPTIMUM_NUM_OPTS, SizeOf(TLzmaOptimumNode)));
    WindowEnd := LzmaEncoderOptimumWindowEnd(InputCapacity);
    if WindowEnd >= 2 then
    begin
      Cells := CheckedMemoryAdd(WindowEnd, 1);
      Workspace := CheckedMemoryMultiply(Cells, CheckedMemoryAdd(SizeOf(TLzmaMatchBuffer),
        CheckedMemoryAdd(SizeOf(UInt32), SizeOf(TLzmaOptimumStateProbInputs))));
      // Backward's temporary decisions coexist with the new persistent replay.
      Decisions := CheckedMemoryMultiply(WindowEnd, SizeOf(TLzmaOptimumDecision));
      Replay := CheckedMemoryMultiply(WindowEnd - 1, SizeOf(TLzmaOptimumDecision));
    end;
  end;
  if not Framed then
  begin
    Result := CheckedMemoryAdd(Result, TLzmaRangeEncoder.kStreamBufferCapacity);
    Result := CheckedMemoryAdd(Result, Workspace);
    Result := CheckedMemoryAdd(Result, Decisions);
    Result := CheckedMemoryAdd(Result, Replay);
    Exit;
  end;
  PayloadBytes := TLzmaStatefulFrameLimits.MaxPackedSize;
  RangeCapacity := TLzmaRangeEncoder.OutputCapacityFor(PayloadBytes);
  // The previous Payload remains alive while Context.Encode builds its successor.
  ParserPeak := CheckedMemoryAdd(RangeCapacity, PayloadBytes);
  ParserPeak := CheckedMemoryAdd(ParserPeak, Workspace);
  ParserPeak := CheckedMemoryAdd(ParserPeak, Decisions);
  ParserPeak := CheckedMemoryAdd(ParserPeak, Replay);
  MaterialPeak := CheckedMemoryAdd(RangeCapacity, CheckedMemoryMultiply(PayloadBytes, 2));
  MaterialPeak := CheckedMemoryAdd(MaterialPeak, Replay);
  if MaterialPeak > ParserPeak then ParserPeak := MaterialPeak;
  Result := CheckedMemoryAdd(Result, ParserPeak);
end;

function LzmaMaximumRangeOperationsPerSymbol: UInt64;
var
  LengthBits, LiteralBits, RepBits, MatchBits, FooterBits: UInt64;
begin
  // Literal: IsMatch followed by one byte. Length paths have one/two choices.
  LiteralBits := 1 + SizeOf(Byte) * 8;
  LengthBits := 2 + TLzmaEncoderConstants.kLenNumHighBits;
  if 2 + TLzmaEncoderConstants.kLenNumLowBits > LengthBits then
    LengthBits := 2 + TLzmaEncoderConstants.kLenNumLowBits;
  // IsMatch/IsRep, then at most G0/G1/G2 for four rep distances.
  RepBits := 2 + (SizeOf(TLzmaOptimumReps) div SizeOf(UInt32) - 1) + LengthBits;
  // Slot 63 has 30 footer bits, split between direct and align coding.
  FooterBits := (((UInt64(1) shl TLzmaEncoderConstants.kNumPosSlotBits) - 1) shr 1) - 1;
  MatchBits := 2 + LengthBits + TLzmaEncoderConstants.kNumPosSlotBits + FooterBits;
  Result := LiteralBits;
  if RepBits > Result then Result := RepBits;
  if MatchBits > Result then Result := MatchBits;
end;

function LzmaMinimumFullFrameUnpacked: UInt64;
var
  PackedThreshold, PackedMinimum, UnpackedMinimum, Operations, MinimumFrameLimit: UInt64;
begin
  // Before flush, output bytes plus pending cache bytes equals ShiftLow calls.
  // Every range operation calls ShiftLow at most once; every symbol consumes input.
  // Explicit frame limits are clamped by CheckedBufferSize (currently 4096).
  MinimumFrameLimit := CheckedBufferSize(1);
  if MinimumFrameLimit > TLzmaStatefulFrameLimits.MaxUnpackedSize then
    MinimumFrameLimit := TLzmaStatefulFrameLimits.MaxUnpackedSize;
  if (TLzmaStatefulFrameLimits.PackReserve >= TLzmaStatefulFrameLimits.MaxPackedSize) or
    (TLzmaStatefulFrameLimits.UnpackReserve >= MinimumFrameLimit) then
    Exit(1);
  PackedThreshold := TLzmaStatefulFrameLimits.MaxPackedSize - TLzmaStatefulFrameLimits.PackReserve;
  Operations := LzmaMaximumRangeOperationsPerSymbol;
  PackedMinimum := PackedThreshold div Operations;
  if PackedThreshold mod Operations <> 0 then Inc(PackedMinimum);
  UnpackedMinimum := MinimumFrameLimit - TLzmaStatefulFrameLimits.UnpackReserve;
  Result := PackedMinimum;
  if UnpackedMinimum < Result then Result := UnpackedMinimum;
  if Result = 0 then Result := 1;
end;

procedure LzmaStreamingInputDimensions(const Props: TLzmaProps; const BufferSize: NativeUInt;
  out DictionarySize, ReadQuantum, RequestedCapacity: NativeUInt);
var
  Dictionary: UInt64;
begin
  Dictionary := TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize);
  if (Dictionary = 0) or
    (Dictionary > UInt64(High(NativeInt)) - TLzmaStatefulFrameLimits.MaxUnpackedSize -
      TLzmaStatefulFrameLimits.UnpackReserve) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA encoder input configuration');
  DictionarySize := NativeUInt(Dictionary);
  RequestedCapacity := DictionarySize + TLzmaStatefulFrameLimits.MaxUnpackedSize +
    TLzmaStatefulFrameLimits.UnpackReserve;
  ReadQuantum := CheckedBufferSize(BufferSize);
  if ReadQuantum > TLzmaStatefulFrameLimits.MaxUnpackedSize then
    ReadQuantum := TLzmaStatefulFrameLimits.MaxUnpackedSize;
  if ReadQuantum > RequestedCapacity then
    ReadQuantum := RequestedCapacity;
end;

class function TLzmaRawEncoder.RequiredStreamingMemoryForInput(const Profile: TLzmaEncoderProfile;
  const Props: TLzmaProps; const InputUpperBound: UInt64; const BufferSize: NativeUInt;
  const Framed: Boolean): UInt64;
begin Result := RequiredMemoryForInputCore(Profile, Props, InputUpperBound, BufferSize, Framed, False, 0, High(UInt64)); end;

class function TLzmaRawEncoder.RequiredMemoryForInputCore(const Profile: TLzmaEncoderProfile;
  const Props: TLzmaProps; const InputUpperBound: UInt64; const BufferSize: NativeUInt;
  const Framed, SdkFinder: Boolean; const HashOutBits: UInt32;
  const ExpectedDataSize: UInt64): UInt64;
var
  DictionarySize, ReadQuantum, RequestedCapacity, EndCapacity: NativeUInt;
  Peak: UInt64;

  procedure IncludePeak(const Value: UInt64);
  begin
    if Value > Result then Result := Value;
  end;

begin
  LzmaStreamingInputDimensions(Props, BufferSize, DictionarySize, ReadQuantum, RequestedCapacity);
  Result := RequiredMemoryCore(Profile, Props, ReadQuantum, Framed, SdkFinder, HashOutBits, ExpectedDataSize);
  // EOF before the first quantum: shrinking can temporarily retain the old input array.
  EndCapacity := ReadQuantum - 1;
  if InputUpperBound < UInt64(EndCapacity) then EndCapacity := NativeUInt(InputUpperBound);
  IncludePeak(CheckedMemoryAdd(ReadQuantum,
    RequiredMemoryCore(Profile, Props, EndCapacity, Framed, SdkFinder, HashOutBits, ExpectedDataSize)));
  if InputUpperBound > UInt64(ReadQuantum) then
  begin
    Peak := RequiredMemoryCore(Profile, Props, RequestedCapacity, Framed, SdkFinder, HashOutBits, ExpectedDataSize);
    IncludePeak(CheckedMemoryAdd(ReadQuantum, Peak));
    // Framed prefill can reach EOF after growth and shrink once more before the finder exists.
    if Framed then
    begin
      EndCapacity := RequestedCapacity - 1;
      if InputUpperBound < UInt64(EndCapacity) then EndCapacity := NativeUInt(InputUpperBound);
      if EndCapacity > ReadQuantum then
        IncludePeak(CheckedMemoryAdd(RequestedCapacity,
          RequiredMemoryCore(Profile, Props, EndCapacity, Framed, SdkFinder, HashOutBits, ExpectedDataSize)));
    end;
  end;
end;

class function TLzmaRawEncoder.ResolveThreadCount(const Profile: TLzmaEncoderProfile;
  const RequestedThreadCount: Integer): Integer;
begin
  if RequestedThreadCount < 1 then
    RaiseLzmaError(SZ_ERROR_PARAM, 'LZMA thread count must be positive');
  Result := 1;
  // SDK enables its MT match finder only for normal BT parsing.
  if (RequestedThreadCount > 1) and (Profile.ParserMode = lpmSdkProfile) and
    (Profile.Algorithm <> 0) and (Profile.MatchFinderKind in
      [mfBinaryTree2, mfBinaryTree3, mfBinaryTree4, mfBinaryTree5]) then
    Result := 2;
end;

class function TLzmaRawEncoder.RequiredStreamingMemoryForInputWithThreads(
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const InputUpperBound: UInt64; const BufferSize: NativeUInt;
  const RequestedThreadCount: Integer): UInt64;
begin
  Result := RequiredStreamingMemoryForInput(Profile, Props, InputUpperBound, BufferSize, False);
  if ResolveThreadCount(Profile, RequestedThreadCount) = 2 then
    Result := CheckedMemoryAdd(Result, TLzmaMatchFinderPipeline.RequiredMemory);
end;

class function TLzmaRawEncoder.MaximumLzma2EncodedSize(const InputSize: UInt64): UInt64;
var
  Frames, CopyChunks: UInt64;
begin
  if InputSize = 0 then Exit(SizeOf(Byte));
  Frames := InputSize div LzmaMinimumFullFrameUnpacked;
  if InputSize mod LzmaMinimumFullFrameUnpacked <> 0 then Inc(Frames);
  CopyChunks := InputSize div TLzmaStatefulFrameLimits.MaxPackedSize;
  if InputSize mod TLzmaStatefulFrameLimits.MaxPackedSize <> 0 then Inc(CopyChunks);
  // For a positive partition, sum ceil(part / C) <= ceil(total / C) + frames - 1.
  CopyChunks := CheckedMemoryAdd(CopyChunks, Frames - 1);
  Result := CheckedMemoryAdd(InputSize,
    CheckedMemoryMultiply(CopyChunks, SizeOf(Byte) + SizeOf(UInt16)));
  Result := CheckedMemoryAdd(Result, SizeOf(Byte));
end;

constructor TLzmaRangeEncoder.Create(const OutputStream: TStream);
begin
  inherited Create;
  FOutputStream := OutputStream;
  if FOutputStream <> nil then
    SetLength(FStreamBuffer, kStreamBufferCapacity);
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
      SetLength(FStreamBuffer, kStreamBufferCapacity);
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
    NewCapacity := OutputCapacityFor(CheckedMemoryAdd(FOutputSize, 1));
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
{$IFDEF CPUX64}
{$IFOPT Q+}
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

{$ELSE}
var
  I: Integer;
  RangeValue: UInt32;
  LowValue: UInt64;
begin
  RangeValue := FRange;
  LowValue := FLow;
  for I := Integer(NumBits) - 1 downto 0 do
  begin
    RangeValue := RangeValue shr 1;
    if ((Value shr UInt32(I)) and 1) <> 0 then
      LowValue := LowValue + RangeValue;
    if RangeValue < LZMA_TOP_VALUE then
    begin
      RangeValue := RangeValue shl 8;
      FRange := RangeValue;
      FLow := LowValue;
      ShiftLow;
      RangeValue := FRange;
      LowValue := FLow;
    end
  end;
  FRange := RangeValue;
  FLow := LowValue;
end;

{$ENDIF}

{$ELSE}
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

{$ENDIF}
procedure TLzmaRangeEncoder.BitTreeEncode(var Probs; const NumBits, Symbol: UInt32);
{$IFDEF CPUX64}
{$IFOPT Q+}
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

{$ELSE}
type
  PLiteralProb = ^CLzmaProb;
var
  P: PProbArray;
  M: UInt32;
  BitIndex: Integer;
  Bit: UInt32;
  Prob: PLiteralProb;
  Bound, RangeValue: UInt32;
  LowValue: UInt64;
begin
  P := @Probs;
  M := 1;
  RangeValue := FRange;
  LowValue := FLow;
  for BitIndex := Integer(NumBits) - 1 downto 0 do
  begin
    Bit := (Symbol shr UInt32(BitIndex)) and 1;
    Prob := @P^[M];
    Bound := (RangeValue shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob^);
    if Bit = 0 then
    begin
      RangeValue := Bound;
      Prob^ := LzmaProbUpdate0(Prob^);
    end
    else
    begin
      LowValue := LowValue + Bound;
      RangeValue := RangeValue - Bound;
      Prob^ := LzmaProbUpdate1(Prob^);
    end;
    if RangeValue < LZMA_TOP_VALUE then
    begin
      RangeValue := RangeValue shl 8;
      // Output callbacks and failures must observe the complete current state.
      FRange := RangeValue;
      FLow := LowValue;
      ShiftLow;
      RangeValue := FRange;
      LowValue := FLow;
    end;
    M := (M shl 1) or Bit;
  end;
  FRange := RangeValue;
  FLow := LowValue;
end;

{$ENDIF}

{$ELSE}
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

{$ENDIF}
procedure TLzmaRangeEncoder.BitTreeReverseEncode(var Probs; const NumBits, Symbol: UInt32);
{$IFDEF CPUX64}
{$IFOPT Q+}
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

{$ELSE}
type
  PLiteralProb = ^CLzmaProb;
var
  P: PProbArray;
  I: UInt32;
  M: UInt32;
  Bit: UInt32;
  Prob: PLiteralProb;
  Bound, RangeValue: UInt32;
  LowValue: UInt64;
begin
  P := @Probs;
  M := 1;
  RangeValue := FRange;
  LowValue := FLow;
  for I := 0 to NumBits - 1 do
  begin
    Bit := (Symbol shr I) and 1;
    Prob := @P^[M];
    Bound := (RangeValue shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob^);
    if Bit = 0 then
    begin
      RangeValue := Bound;
      Prob^ := LzmaProbUpdate0(Prob^);
    end
    else
    begin
      LowValue := LowValue + Bound;
      RangeValue := RangeValue - Bound;
      Prob^ := LzmaProbUpdate1(Prob^);
    end;
    if RangeValue < LZMA_TOP_VALUE then
    begin
      RangeValue := RangeValue shl 8;
      // Output callbacks and failures must observe the complete current state.
      FRange := RangeValue;
      FLow := LowValue;
      ShiftLow;
      RangeValue := FRange;
      LowValue := FLow;
    end;
    M := (M shl 1) or Bit;
  end;
  FRange := RangeValue;
  FLow := LowValue;
end;

{$ENDIF}

{$ELSE}
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

{$ENDIF}
procedure TLzmaRangeEncoder.EncodeLiteral(var Probs; const Value: Byte);
{$IFDEF CPUX64}
{$IFOPT Q+}
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

{$ELSE}
type
  PLiteralProb = ^CLzmaProb;
var
  P: PProbArray;
  Prob: PLiteralProb;
  Symbol, Bit, Bound, RangeValue: UInt32;
  LowValue: UInt64;
begin
  P := @Probs;
  Symbol := UInt32(Value) or $100;
  RangeValue := FRange;
  LowValue := FLow;
  repeat
    Bit := (Symbol shr 7) and 1;
    Prob := @P^[Symbol shr 8];
    Bound := (RangeValue shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob^);
    if Bit = 0 then
    begin
      RangeValue := Bound;
      Prob^ := LzmaProbUpdate0(Prob^);
    end
    else
    begin
      LowValue := LowValue + Bound;
      RangeValue := RangeValue - Bound;
      Prob^ := LzmaProbUpdate1(Prob^);
    end;
    if RangeValue < LZMA_TOP_VALUE then
    begin
      RangeValue := RangeValue shl 8;
      // Output callbacks and failures must observe the complete current state.
      FRange := RangeValue;
      FLow := LowValue;
      ShiftLow;
      RangeValue := FRange;
      LowValue := FLow;
    end;
    Symbol := Symbol shl 1;
  until Symbol >= $10000;
  FRange := RangeValue;
  FLow := LowValue;
end;

{$ENDIF}

{$ELSE}
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

{$ENDIF}
procedure TLzmaRangeEncoder.EncodeMatchedLiteral(var Probs; const Value, MatchByte: Byte);
{$IFDEF CPUX64}
{$IFOPT Q+}
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

{$ELSE}
type
  PLiteralProb = ^CLzmaProb;
var
  P: PProbArray;
  Symbol: UInt32;
  Match: UInt32;
  MatchBit: UInt32;
  Bit: UInt32;
  Offset: UInt32;
  Prob: PLiteralProb;
  Bound, RangeValue: UInt32;
  LowValue: UInt64;
begin
  P := @Probs;
  Symbol := UInt32(Value) or $100;
  Match := UInt32(MatchByte);
  Offset := $100;
  RangeValue := FRange;
  LowValue := FLow;
  repeat
    Match := Match shl 1;
    MatchBit := Match and Offset;
    Bit := (Symbol shr 7) and 1;
    Prob := @P^[Offset + MatchBit + (Symbol shr 8)];
    Bound := (RangeValue shr LZMA_NUM_BIT_MODEL_TOTAL_BITS) * UInt32(Prob^);
    if Bit = 0 then
    begin
      RangeValue := Bound;
      Prob^ := LzmaProbUpdate0(Prob^);
    end
    else
    begin
      LowValue := LowValue + Bound;
      RangeValue := RangeValue - Bound;
      Prob^ := LzmaProbUpdate1(Prob^);
    end;
    if RangeValue < LZMA_TOP_VALUE then
    begin
      RangeValue := RangeValue shl 8;
      // Output callbacks and failures must observe the complete current state.
      FRange := RangeValue;
      FLow := LowValue;
      ShiftLow;
      RangeValue := FRange;
      LowValue := FLow;
    end;
    Symbol := Symbol shl 1;
    Offset := Offset and not (Match xor Symbol);
  until Symbol >= $10000;
  FRange := RangeValue;
  FLow := LowValue;
end;

{$ENDIF}

{$ELSE}
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

{$ENDIF}
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

class function TLzmaRawEncoder.EffectiveHistorySize(const DictionarySize: UInt64): NativeUInt;
const
  kLzmaMaxHistorySize = UInt64(15) shl 28;
begin
  if DictionarySize > kLzmaMaxHistorySize then
    Result := NativeUInt(kLzmaMaxHistorySize)
  else
    Result := NativeUInt(DictionarySize);
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
{$IF SizeOf(NativeUInt) > SizeOf(UInt32)}
  if Count > NativeUInt(High(UInt32)) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Literal-only LZMA chunk is too large');
{$ENDIF}

  InitProbArray(IsMatch, kNumStates * kNumPosStatesMax);
  SetLength(Literals, LzmaEncoderLiteralProbCount(Props));
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
  SetLength(Literals, LzmaEncoderLiteralProbCount(Props));
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

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
type
  PLzmaOptimumStoreContext56 = ^TLzmaOptimumStoreContext56;
  TLzmaOptimumStoreContext56 = record
    Price, Len, PathBack, Extra: UInt32;
    Destination, SourceNode: Pointer;
  end;

procedure LzmaStoreOptimumNode56(const Context: PLzmaOptimumStoreContext56);
asm
        .PARAMS 0
        MOV     RAX,[RCX].TLzmaOptimumStoreContext56.Destination
        MOV     RDX,[RCX].TLzmaOptimumStoreContext56.SourceNode
        MOVDQU  XMM0,[RCX]
        MOV     R8D,[RCX].TLzmaOptimumStoreContext56.PathBack
        MOV     R9D,[RCX].TLzmaOptimumStoreContext56.Extra
        MOV     R10D,[RDX].TLzmaOptimumNode.State
        MOVDQU  XMM1,[RDX].TLzmaOptimumNode.Reps
        CMP     R8D,LZMA_OPTIMUM_BACK_LITERAL
        JE      @@literal
        CMP     R9D,1
        JE      @@literal_rep
        CMP     R8D,4
        JAE     @@normal_match
        TEST    R8D,R8D
        JZ      @@rep_state
        CMP     R8D,1
        JE      @@rep_one
        CMP     R8D,2
        JE      @@rep_two
        PSHUFD  XMM1,XMM1,$93
        JMP     @@rep_state
@@rep_one:
        PSHUFD  XMM1,XMM1,$E1
        JMP     @@rep_state
@@rep_two:
        PSHUFD  XMM1,XMM1,$D2
@@rep_state:
        MOV     R11D,[RCX].TLzmaOptimumStoreContext56.Len
        CMP     R11D,1
        JE      @@short_rep
        LEA     RDX,LZMA_STATE_REP_NEXT
        MOV     R10D,[RDX+R10*4]
        JMP     @@extra_state
@@short_rep:
        LEA     RDX,LZMA_STATE_SHORT_REP_NEXT
        MOV     R10D,[RDX+R10*4]
        JMP     @@extra_state
@@normal_match:
        PSLLDQ  XMM1,4
        LEA     R11D,[R8-3]
        MOVD    XMM2,R11D
        POR     XMM1,XMM2
        LEA     RDX,LZMA_STATE_MATCH_NEXT
        MOV     R10D,[RDX+R10*4]
@@extra_state:
        CMP     R9D,1
        JBE     @@commit
        LEA     RDX,LZMA_STATE_LITERAL_NEXT
        MOV     R10D,[RDX+R10*4]
        LEA     RDX,LZMA_STATE_REP_NEXT
        MOV     R10D,[RDX+R10*4]
        JMP     @@commit
@@literal:
        LEA     RDX,LZMA_STATE_LITERAL_NEXT
        MOV     R10D,[RDX+R10*4]
        JMP     @@commit
@@literal_rep:
        LEA     RDX,LZMA_STATE_LITERAL_NEXT
        MOV     R10D,[RDX+R10*4]
        LEA     RDX,LZMA_STATE_REP_NEXT
        MOV     R10D,[RDX+R10*4]
@@commit:
        // Context inputs, source state and all four reps were captured before
        // the first target write. Source/destination overlap keeps old staging.
        MOVD    R11D,XMM0
        MOV     [RAX].TLzmaOptimumNode.Price,R11D
        MOV     [RAX].TLzmaOptimumNode.State,R10D
        MOVDQU  [RAX].TLzmaOptimumNode.Reps,XMM1
        PSRLDQ  XMM0,4
        MOVQ    QWORD PTR [RAX].TLzmaOptimumNode.PathLen,XMM0
        PSRLDQ  XMM0,8
        MOVD    [RAX].TLzmaOptimumNode.Extra,XMM0
        PXOR    XMM2,XMM2
        LEA     RDX,[RAX].TLzmaOptimumNode.PosPrev
        MOVDQU  [RDX],XMM2
        MOV     DWORD PTR [RAX].TLzmaOptimumNode.BackPrev2,0
end;
{$ENDIF}


{$IFDEF LZMA_ENCODER_FLAT_OPTIMUM_FRAME}
function TEncoderFullOptimumFrame.NumAvailAt(const RelativePos: NativeUInt): UInt32;
  begin
    Result := TLzmaEncoderConstants.kMatchMaxLen;
    if Count - RelativePos < NativeUInt(Result) then
      Result := UInt32(Count - RelativePos);
  end;



function TEncoderFullOptimumFrame.RepLenAtPos(const RelativePos: NativeUInt; const Distance: UInt32): UInt32;
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
    if InputRef^[Left] <> InputRef^[Right] then
      Exit;
    Result := 1;
    if MaxLen = 1 then
      Exit;

    if InputRef^[Left + 1] <> InputRef^[Right + 1] then
      Exit;
    Result := 2 + LzmaCountMatchingBytes(InputRef^, Left + 2, Right + 2, MaxLen - 2);
  end;


procedure TEncoderFullOptimumFrame.InsertRange(const RelativePos, RangeCount: NativeUInt);
  begin
    if Owner.FMatchFinderThread <> nil then
      Owner.FMatchFinderThread.AdvanceTo(Owner.FWindowBase + RelativePos + RangeCount)
    else if Owner.SdkFinder <> nil then
      Owner.SdkFinder.InsertRange(RelativePos, RangeCount)
    else if Owner.Bt4Finder <> nil then
      Owner.Bt4Finder.InsertRange(RelativePos, RangeCount)
    else if Owner.Hc5Finder <> nil then
      Owner.Hc5Finder.SkipRangeMonotonic(RelativePos, RangeCount)
    else if Owner.Hc4Finder <> nil then
      Owner.Hc4Finder.InsertRange(RelativePos, RangeCount)
    else
      Owner.GreedyFinder.InsertRange(RelativePos, RangeCount);
  end;


procedure TEncoderFullOptimumFrame.EnsureInsertedUntil(const NewInsertedUntil: NativeUInt);
  var
    Target: NativeUInt;
  begin
    Target := NewInsertedUntil;
    if Target > Count then
      Target := Count;
    if Target <= Owner.InsertedUntil then
      Exit;

    if (Owner.SdkFinder = nil) and (Owner.Bt4Finder = nil) and (Owner.Hc5Finder = nil) and (Owner.Hc4Finder = nil) and
      (Owner.GreedyFinder = nil) then
    begin
      Owner.InsertedUntil := Target;
      Exit;
    end;

    InsertRange(Owner.InsertedUntil, Target - Owner.InsertedUntil);
    Owner.InsertedUntil := Target;
  end;


procedure TEncoderFullOptimumFrame.MarkInsertedUntil(const NewInsertedUntil: NativeUInt);
  var
    Target: NativeUInt;
  begin
    Target := NewInsertedUntil;
    if Target > Count then
      Target := Count;
    if Owner.InsertedUntil < Target then
      Owner.InsertedUntil := Target;
  end;


function TEncoderFullOptimumFrame.ReadMatchDistancesAndInsert(const RelativePos: NativeUInt;
    var MatchList: TLzmaMatchBuffer): TLzmaMatch;
  var
    AvailableLen: UInt32;
    CurrentTail: NativeUInt;
  begin
    EnsureInsertedUntil(RelativePos);
    if Owner.FMatchFinderThread <> nil then
      Owner.FMatchFinderThread.ReadAt(Owner.FWindowBase + RelativePos, MatchList)
    else if Owner.SdkFinder <> nil then
      Owner.SdkFinder.ReadMatchPairs(RelativePos, MatchList)
    else if Owner.Bt4Finder <> nil then
      Owner.Bt4Finder.ReadMatchPairs(RelativePos, MatchList)
    else if Owner.Hc5Finder <> nil then
      Owner.Hc5Finder.ReadMatchPairs(RelativePos, MatchList)
    else if Owner.Hc4Finder <> nil then
      Owner.Hc4Finder.ReadMatchPairs(RelativePos, MatchList)
    else
      Owner.GreedyFinder.ReadMatchPairs(RelativePos, MatchList);
    MarkInsertedUntil(RelativePos + 1);

    if MatchList.Count = 0 then
    begin
      Result.Length := 0;
      Result.Distance := 0;
    end
    else
    begin
      Result := MatchList.Last;
      // Both engine parsers retain raw fb-capped pairs and a separate main match.
      if Result.Length = Owner.EffectiveFastBytes then
      begin
        AvailableLen := NumAvailAt(RelativePos);
        if Result.Length < AvailableLen then
        begin
          CurrentTail := Offset + RelativePos + NativeUInt(Result.Length);
          Result.Length := Result.Length + LzmaCountMatchingBytes(InputRef^, CurrentTail,
            CurrentTail - NativeUInt(Result.Distance), AvailableLen - Result.Length);
        end;
      end;
    end;
    if Owner.FullOptimumState.Enabled then
    begin
      AvailableLen := NumAvailAt(RelativePos);
      if Owner.FullOptimumState.AdditionalOffset < High(UInt32) then
        Inc(Owner.FullOptimumState.AdditionalOffset);
      Owner.FullOptimumState.NumAvail := AvailableLen;
      Owner.FullOptimumState.NumPairs := UInt32(MatchList.Count) * 2;
      Owner.FullOptimumState.LongestMatchLen := Result.Length;
      // This state belongs to the encoder; only active cached pairs are read.
      Owner.FullOptimumState.CachedMatches.CopyPairsFrom(MatchList);
      Owner.FullOptimumState.CachedMainMatch := Result;
    end;
  end;


function TEncoderFullOptimumFrame.ReadCurrentMatchDistances(const RelativePos: NativeUInt;
    var MatchList: TLzmaMatchBuffer): TLzmaMatch;
  begin
    if Owner.MatchCache.TryTake(RelativePos, MatchList, Result) then
      Exit;
    Result := ReadMatchDistancesAndInsert(RelativePos, MatchList);
  end;


function TEncoderFullOptimumFrame.AvailableAt(const At: UInt32): UInt32;
    var
      Remaining: NativeUInt;
    begin
      Result := LZMA_FULL_OPTIMUM_NUM_OPTS - 1 - At;
      Remaining := Count - (Owner.Pos + NativeUInt(At));
      if Remaining < NativeUInt(Result) then
        Result := UInt32(Remaining);
    end;


function TEncoderFullOptimumFrame.ProbsAt(const At, AtState: UInt32): TLzmaOptimumProbInput;
    begin
      Result := Model.Read(At, AtState, (Owner.Processed + At) and Owner.PbMask);
    end;


function TEncoderFullOptimumFrame.RepLength(const At, Distance, Limit: UInt32): UInt32;
    begin
      Result := RepLenAtPos(Owner.Pos + NativeUInt(At), Distance);
      if Result > Limit then
        Result := Limit;
      if Result < TLzmaEncoderConstants.kMatchMinLen then
        Result := 0;
    end;


function TEncoderFullOptimumFrame.LiteralCost(const At, AtState, RepDistance: UInt32): UInt32;
    var
      Relative, LiteralOffset: NativeUInt;
      Previous, Value, MatchValue: Byte;
      LiteralState: UInt32;
      View: TLzmaOptimumLiteralView;
    begin
      Relative := Owner.Pos + NativeUInt(At);
      if Relative = 0 then
        Previous := 0
      else
        Previous := InputRef^[Offset + Relative - 1];
      Value := InputRef^[Offset + Relative];
      LiteralState := (((Owner.Processed + At) and Owner.LpMask) shl Owner.LcBits) +
        (UInt32(Previous) shr Owner.LcShift);
      LiteralOffset := NativeUInt(LiteralState) * LZMA_LITERAL_PROB_COUNT;
      View := Default(TLzmaOptimumLiteralView);
      View.LiteralProbs := PLzmaOptimumLiteralProbs(@Owner.Literals[LiteralOffset]);
      View.Enabled := True;
      View.Value := Value;
      View.UseMatchedLiteral := AtState >= TLzmaEncoderConstants.kNumLitStates;
      if View.UseMatchedLiteral then
      begin
        if (RepDistance = 0) or (NativeUInt(RepDistance) > Relative) then
          RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid online optimum literal history');
        MatchValue := InputRef^[Offset + Relative - NativeUInt(RepDistance)];
        View.MatchByte := MatchValue;
        Result := LzmaMatchedLiteralPrice(View.LiteralProbs^, Value, MatchValue, Owner.ProbPrices);
      end
      else
        Result := LzmaLiteralPrice(View.LiteralProbs^, Value, Owner.ProbPrices);
    end;


function TEncoderFullOptimumFrame.Rep0Price(const At, AtState: UInt32): UInt32;
    var
      Prob: TLzmaOptimumProbInput;
    begin
      Prob := ProbsAt(At, AtState);
      Result := LzmaRepMatchPrefixPrice(Owner.ProbPrices, Prob.IsMatchProb, Prob.IsRepProb) +
        LzmaRep0LongPrice(Owner.ProbPrices, Prob.IsRepG0Prob, Prob.IsRep0LongProb);
    end;


procedure TEncoderFullOptimumFrame.ExtendFrontier(const Target: UInt32);
    begin
      if Target > Last then
        Last := Target;
    end;


procedure TEncoderFullOptimumFrame.Store(const Target, Price, Len, PathBack, Extra: UInt32;
      const Source: TLzmaOptimumNode);
    var
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
      NativeContext: TLzmaOptimumStoreContext56;
{$ENDIF}
      Node: TLzmaOptimumNode;
      Index: Integer;
      Distance: UInt32;
    begin
      if Price >= Owner.FullOptimumState.Nodes[Integer(Target)].Price then
        Exit;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
      if Source.State < UInt32(Length(LZMA_STATE_LITERAL_NEXT)) then
      begin
        NativeContext.Price := Price;
        NativeContext.Len := Len;
        NativeContext.PathBack := PathBack;
        NativeContext.Extra := Extra;
        NativeContext.Destination := @Owner.FullOptimumState.Nodes[Integer(Target)];
        NativeContext.SourceNode := @Source;
        LzmaStoreOptimumNode56(@NativeContext);
        Exit;
      end;
{$ENDIF}
      Node := Default(TLzmaOptimumNode);
      Node.Price := Price;
      Node.PathLen := Len;
      Node.PathBack := PathBack;
      Node.Extra := Extra;
      Node.Reps := Source.Reps;
      if PathBack = LZMA_OPTIMUM_BACK_LITERAL then
        Node.State := LZMA_STATE_LITERAL_NEXT[Source.State]
      else if (Extra = 1) then
      begin
        // Literal + rep0 preserves the source repetition ordering.
        Node.State := LZMA_STATE_REP_NEXT[LZMA_STATE_LITERAL_NEXT[Source.State]];
      end
      else
      begin
        if PathBack < 4 then
        begin
          Distance := Source.Reps[Integer(PathBack)];
          for Index := Integer(PathBack) downto 1 do
            Node.Reps[Index] := Source.Reps[Index - 1];
          Node.Reps[0] := Distance;
          if Len = 1 then
            Node.State := LZMA_STATE_SHORT_REP_NEXT[Source.State]
          else
            Node.State := LZMA_STATE_REP_NEXT[Source.State];
        end
        else
        begin
          Node.Reps[0] := PathBack - 3;
          Node.Reps[1] := Source.Reps[0];
          Node.Reps[2] := Source.Reps[1];
          Node.Reps[3] := Source.Reps[2];
          Node.State := LZMA_STATE_MATCH_NEXT[Source.State];
        end;
        if Extra > 1 then
          Node.State := LZMA_STATE_REP_NEXT[LZMA_STATE_LITERAL_NEXT[Node.State]];
      end;
      Owner.FullOptimumState.Nodes[Integer(Target)] := Node;
    end;


procedure TEncoderFullOptimumFrame.Relax(const Initial: Boolean);
    var
      Node: TLzmaOptimumNode;
      Prob, LiteralProb: TLzmaOptimumProbInput;
      FullAvailable, Available, PosState, MatchPrice, RepPrice, LitPrice: UInt32;
      Price, CandidatePrice, Len, Len2, StartLen, RepIndex, FirstState: UInt32;
      Tail, Target, Distance, PairIndex, NextPos, NextState: UInt32;
      CurrentByte, MatchByte: Byte;
      HasRep0, NextIsLit: Boolean;
    begin
      Node := Owner.FullOptimumState.Nodes[Integer(Cur)];
      Prob := ProbsAt(Cur, Node.State);
      PosState := (Owner.Processed + Cur) and Owner.PbMask;
      FullAvailable := AvailableAt(Cur);
      Available := FullAvailable;
      if Available > Owner.EffectiveFastBytes then
        Available := Owner.EffectiveFastBytes;
      CurrentByte := InputRef^[Offset + Owner.Pos + NativeUInt(Cur)];
      HasRep0 := (Node.Reps[0] <> 0) and
        (NativeUInt(Node.Reps[0]) <= Owner.Pos + NativeUInt(Cur));
      MatchByte := 0;
      if HasRep0 then
        MatchByte := InputRef^[Offset + Owner.Pos + NativeUInt(Cur) - NativeUInt(Node.Reps[0])];
      MatchPrice := Node.Price + LzmaBitPrice(Owner.ProbPrices, Prob.IsMatchProb, 1);
      RepPrice := MatchPrice + LzmaBitPrice(Owner.ProbPrices, Prob.IsRepProb, 1);
      LitPrice := Node.Price + LzmaBitPrice(Owner.ProbPrices, Prob.IsMatchProb, 0);
      NextIsLit := False;
      if (not Initial) and
        (((Owner.FullOptimumState.Nodes[Integer(Cur + 1)].Price <> High(UInt32)) and
          HasRep0 and (MatchByte = CurrentByte)) or
         (LitPrice > Owner.FullOptimumState.Nodes[Integer(Cur + 1)].Price)) then
        LitPrice := 0
      else
      begin
        Inc(LitPrice, LiteralCost(Cur, Node.State, Node.Reps[0]));
        if LitPrice < Owner.FullOptimumState.Nodes[Integer(Cur + 1)].Price then
        begin
          Store(Cur + 1, LitPrice, 1, LZMA_OPTIMUM_BACK_LITERAL, 0, Node);
          NextIsLit := True;
        end;
      end;

      // Initial short rep has its own SDK condition. Interior short reps require
      // literal state and preserve the SDK next-node/tie suppression rules.
      if HasRep0 and (MatchByte = CurrentByte) and
        ((Initial and (RepLens[0] = 0)) or
         ((not Initial) and (Node.State < TLzmaEncoderConstants.kNumLitStates) and
          (RepPrice < Owner.FullOptimumState.Nodes[Integer(Cur + 1)].Price) and
          ((Owner.FullOptimumState.Nodes[Integer(Cur + 1)].PathLen < 2) or
           (Owner.FullOptimumState.Nodes[Integer(Cur + 1)].PathBack <> 0)))) then
      begin
        Price := RepPrice + LzmaShortRepPrice(Owner.ProbPrices,
          Prob.IsRepG0Prob, Prob.IsRep0LongProb);
        if Price < Owner.FullOptimumState.Nodes[Integer(Cur + 1)].Price then
        begin
          Store(Cur + 1, Price, 1, 0, 0, Node);
          NextIsLit := False;
        end;
      end;
      if FullAvailable < 2 then
        Exit;

      if (not Initial) and (not NextIsLit) and (LitPrice <> 0) and HasRep0 and
        (MatchByte <> CurrentByte) and (FullAvailable > 2) then
      begin
        Tail := RepLength(Cur + 1, Node.Reps[0], FullAvailable - 1);
        if Tail > Owner.EffectiveFastBytes then
          Tail := Owner.EffectiveFastBytes;
        if Tail >= 2 then
        begin
          Target := Cur + 1 + Tail;
          ExtendFrontier(Target);
          NextState := LZMA_STATE_LITERAL_NEXT[Node.State];
          Price := LitPrice + Rep0Price(Cur + 1, NextState) +
            LzmaLenPrice(Owner.RepLenPrices, (Owner.Processed + Cur + 1) and Owner.PbMask, Tail);
          Store(Target, Price, Tail, 0, 1, Node);
        end;
      end;

      StartLen := TLzmaEncoderConstants.kMatchMinLen;
      for RepIndex := 0 to 3 do
      begin
        if Initial then
          Len := RepLens[Integer(RepIndex)]
        else
          Len := RepLength(Cur, Node.Reps[Integer(RepIndex)], Available);
        if Len < 2 then
          Continue;
        ExtendFrontier(Cur + Len);
        Price := RepPrice + LzmaPureRepPrice(Owner.ProbPrices, Prob.IsRepG0Prob,
          Prob.IsRepG1Prob, Prob.IsRepG2Prob, Prob.IsRep0LongProb, RepIndex);
        Len2 := Len;
        repeat
          CandidatePrice := Price + LzmaLenPrice(Owner.RepLenPrices, PosState, Len2);
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
{$IFOPT Q-}
          if CandidatePrice < Owner.FullOptimumState.Nodes[Integer(Cur + Len2)].Price then
{$ENDIF}
{$ENDIF}
            Store(Cur + Len2, CandidatePrice, Len2, RepIndex, 0, Node);
          Dec(Len2);
        until Len2 < 2;
        if RepIndex = 0 then
          StartLen := Len + 1;

        if Initial or (FullAvailable <= Len + 2) then
          Continue;
        Tail := RepLength(Cur + Len + 1, Node.Reps[Integer(RepIndex)],
          FullAvailable - Len - 1);
        if Tail > Owner.EffectiveFastBytes then
          Tail := Owner.EffectiveFastBytes;
        if Tail < 2 then
          Continue;
        Target := Cur + Len + 1 + Tail;
        ExtendFrontier(Target);
        FirstState := LZMA_STATE_REP_NEXT[Node.State];
        LiteralProb := ProbsAt(Cur + Len, FirstState);
        CandidatePrice := Price + LzmaLenPrice(Owner.RepLenPrices, PosState, Len) +
          LzmaBitPrice(Owner.ProbPrices, LiteralProb.IsMatchProb, 0) +
          LiteralCost(Cur + Len, FirstState, Node.Reps[Integer(RepIndex)]);
        NextPos := Cur + Len + 1;
        NextState := LZMA_STATE_LITERAL_NEXT[FirstState];
        Inc(CandidatePrice, Rep0Price(NextPos, NextState) +
          LzmaLenPrice(Owner.RepLenPrices, (Owner.Processed + NextPos) and Owner.PbMask, Tail));
        Store(Target, CandidatePrice, Tail, RepIndex, Len + 1, Node);
      end;

      // Preserve SDK match-length traversal and extra-path ordering at each
      // actual pair boundary, rather than a separate extras-before-matches pass.
      if MainLen > Available then
      begin
        MainLen := Available;
        // SDK clips the first covering pair and excludes all later pairs.
        // Keeping Count would introduce duplicate clipped length boundaries.
        PairIndex := 0;
        while MainLen > Owner.Matches.Items[Integer(PairIndex)].Length do
          Inc(PairIndex);
        Owner.Matches.Items[Integer(PairIndex)].Length := MainLen;
        Owner.Matches.Count := Integer(PairIndex) + 1;
      end;
      if MainLen < StartLen then
        Exit;
      ExtendFrontier(Cur + MainLen);
      Price := MatchPrice + LzmaBitPrice(Owner.ProbPrices, Prob.IsRepProb, 0);
      PairIndex := 0;
      while StartLen > Owner.Matches.Items[Integer(PairIndex)].Length do
        Inc(PairIndex);
      Len := StartLen;
      repeat
        Distance := Owner.Matches.Items[Integer(PairIndex)].Distance;
        CandidatePrice := Price + LzmaLenPrice(Owner.LenPrices, PosState, Len) +
          LzmaMatchDistancePrice(Owner.DistancePrices, Len, Distance);
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
{$IFOPT Q-}
        if CandidatePrice < Owner.FullOptimumState.Nodes[Integer(Cur + Len)].Price then
{$ENDIF}
{$ENDIF}
          Store(Cur + Len, CandidatePrice, Len, Distance + 3, 0, Node);
        if Len = Owner.Matches.Items[Integer(PairIndex)].Length then
        begin
          if (not Initial) and (FullAvailable > Len + 2) then
          begin
            Tail := RepLength(Cur + Len + 1, Distance, FullAvailable - Len - 1);
            if Tail > Owner.EffectiveFastBytes then
              Tail := Owner.EffectiveFastBytes;
            if Tail >= 2 then
            begin
              Target := Cur + Len + 1 + Tail;
              ExtendFrontier(Target);
              FirstState := LZMA_STATE_MATCH_NEXT[Node.State];
              LiteralProb := ProbsAt(Cur + Len, FirstState);
              Inc(CandidatePrice, LzmaBitPrice(Owner.ProbPrices, LiteralProb.IsMatchProb, 0) +
                LiteralCost(Cur + Len, FirstState, Distance));
              NextPos := Cur + Len + 1;
              NextState := LZMA_STATE_LITERAL_NEXT[FirstState];
              Inc(CandidatePrice, Rep0Price(NextPos, NextState) +
                LzmaLenPrice(Owner.RepLenPrices, (Owner.Processed + NextPos) and Owner.PbMask, Tail));
              Store(Target, CandidatePrice, Tail, Distance + 3, Len + 1, Node);
            end;
          end;
          Inc(PairIndex);
          if PairIndex = UInt32(Owner.Matches.Count) then
            Break;
        end;
        Inc(Len);
      until False;
    end;


function TEncoderFullOptimumFrame.Run(out Back: UInt32): UInt32;
  var
    I, J: UInt32;
  begin
    Back := LZMA_OPTIMUM_BACK_LITERAL;
    if LzmaFullOptimumTryReplay(Owner.FullOptimumState, Result, Back) then
    begin
      Inc(Owner.LocalFullOptimumDecisionCount);
      Exit;
    end;
    Result := 1;
    if LzmaFullOptimumBeginDecision(Owner.FullOptimumState, NumAvail, NumPairs, MainLen) then
      MainMatch := ReadCurrentMatchDistances(Owner.Pos, Owner.Matches)
    else if not LzmaFullOptimumLoadCachedMatches(Owner.FullOptimumState, Owner.Matches, MainMatch) then
      RaiseLzmaError(SZ_ERROR_FAIL, 'Missing retained online optimum match');
    NumAvail := NumAvailAt(Owner.Pos);
    if NumAvail < TLzmaEncoderConstants.kMatchMinLen then
    begin
      Owner.FullOptimumState.BackRes := Back;
      Exit;
    end;
    MainLen := MainMatch.Length;
    BestRep := 0;
    FillChar(RepLens, SizeOf(RepLens), 0);
    for I := 0 to 3 do
    begin
      RepLens[Integer(I)] := RepLength(0, Owner.Reps[I], NumAvail);
      if RepLens[Integer(I)] > RepLens[Integer(BestRep)] then
        BestRep := I;
      if RepLens[Integer(I)] = TLzmaEncoderConstants.kMatchMaxLen then
        Break;
    end;
    if RepLens[Integer(BestRep)] >= Owner.EffectiveFastBytes then
    begin
      Back := BestRep;
      Result := RepLens[Integer(BestRep)];
      EnsureInsertedUntil(Owner.Pos + NativeUInt(Result));
      LzmaFullOptimumMovePos(Owner.FullOptimumState, Result - 1);
      Owner.FullOptimumState.BackRes := Back;
      Exit;
    end;
    if MainLen >= Owner.EffectiveFastBytes then
    begin
      Back := MainMatch.Distance + 3;
      Result := MainLen;
      EnsureInsertedUntil(Owner.Pos + NativeUInt(Result));
      LzmaFullOptimumMovePos(Owner.FullOptimumState, Result - 1);
      Owner.FullOptimumState.BackRes := Back;
      Exit;
    end;

    Last := MainLen;
    if Last < RepLens[Integer(BestRep)] then
      Last := RepLens[Integer(BestRep)];
    if (Last < 2) and
      ((Owner.Reps[0] = 0) or (NativeUInt(Owner.Reps[0]) > Owner.Pos) or
       (InputRef^[Offset + Owner.Pos] <> InputRef^[Offset + Owner.Pos - NativeUInt(Owner.Reps[0])])) then
    begin
      Owner.FullOptimumState.BackRes := Back;
      Exit;
    end;
    // Init/reset already allocates these 2048 nodes. Previous solves clear only
    // touched prices after Backward, preserving the SDK amortized work bound.
    if Length(Owner.FullOptimumState.Nodes) <> LZMA_FULL_OPTIMUM_NUM_OPTS then
      RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid online optimum node capacity');
    Owner.FullOptimumState.Nodes[0] := Default(TLzmaOptimumNode);
    Owner.FullOptimumState.Nodes[0].Price := 0;
    Owner.FullOptimumState.Nodes[0].State := Owner.State;
    for I := 0 to 3 do
      Owner.FullOptimumState.Nodes[0].Reps[Integer(I)] := Owner.Reps[I];
    Model := TLzmaOptimumProbModelView.Borrow(Owner.IsMatch, Owner.IsRep, Owner.IsRepG0,
      Owner.IsRepG1, Owner.IsRepG2, Owner.IsRep0Long, LZMA_FULL_OPTIMUM_NUM_OPTS);
    Cur := 0;
    Relax(True);
    if Last < 2 then
    begin
      Back := Owner.FullOptimumState.Nodes[1].PathBack;
      Owner.FullOptimumState.Nodes[1].Price := High(UInt32);
      Owner.FullOptimumState.BackRes := Back;
      Exit(1);
    end;
    repeat
      Inc(Cur);
      if Cur = Last then
        Break;
      if Cur >= LZMA_FULL_OPTIMUM_NUM_OPTS - 64 then
      begin
        I := Cur;
        for J := Cur + 1 to Last do
          if Owner.FullOptimumState.Nodes[Integer(I)].Price >=
            Owner.FullOptimumState.Nodes[Integer(J)].Price then
            I := J;
        if I <> Cur then
        begin
          EnsureInsertedUntil(Owner.Pos + NativeUInt(I));
          LzmaFullOptimumMovePos(Owner.FullOptimumState, I - Cur);
        end;
        Cur := I;
        Break;
      end;
      MainMatch := ReadMatchDistancesAndInsert(Owner.Pos + NativeUInt(Cur), Owner.Matches);
      MainLen := MainMatch.Length;
      // The just-read query remains cached at AdditionalOffset=cur+1. Replay
      // covers only cur bytes; after commit the retained query has offset1.
      if MainLen >= Owner.EffectiveFastBytes then
        Break;
      Relax(False);
    until False;
    if not LzmaFullOptimumBackward(Owner.FullOptimumState, Cur, Result, Back) then
      RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid online optimum backward path');
    for I := 1 to Last do
      Owner.FullOptimumState.Nodes[Integer(I)].Price := High(UInt32);
    Inc(Owner.LocalFullOptimumDecisionCount);
    Owner.FullOptimumState.BackRes := Back;
  end;


{$ENDIF}

function TLzmaEncoderContext.Encode(const Data: TBytes; const Offset, Count: NativeUInt;
  const Props: TLzmaProps; const FastBytes: Integer; const CutValue: UInt32;
  const MatchFinderKind: TLzmaMatchFinderKind; const WriteEndMarker: Boolean;
  const EnableOptimumWindow: Boolean; const Progress: TLzma2ProgressEvent;
  const FullOptimumDecisionCount: PUInt64; const BoundedFrame, FinalInput: Boolean;
  const FrameUnpackLimit: NativeUInt): TBytes;
const
  kProgressInterval = UInt64(1) shl 20;
  kMaxFramePackSize = TLzmaStatefulFrameLimits.MaxPackedSize;
  kFrameUnpackReserve = TLzmaStatefulFrameLimits.UnpackReserve;
  kFramePackReserve = TLzmaStatefulFrameLimits.PackReserve;
var
{$IFDEF LZMA_ENCODER_FLAT_OPTIMUM_FRAME}
  FullFrame: TEncoderFullOptimumFrame;
{$ENDIF}
  InitialDecisionCount: UInt64;
  ContinuingSession: Boolean;
  FinderInputCount: NativeUInt;

  procedure MaybeReportProgress;
  var
    Processed64: UInt64;
  begin
    if not Assigned(Progress) then
      Exit;
    Processed64 := Processed;
    if Processed64 < NextProgressAt then
      Exit;
    ReportProgress(Progress, Processed64, Encoder.FCommittedOutputSize);
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
{$IF SizeOf(NativeUInt) > SizeOf(UInt32)}
    if (Count < kMinPeriodicFastPathSize) or (Count > NativeUInt(High(UInt32))) then
{$ELSE}
    if Count < kMinPeriodicFastPathSize then
{$ENDIF}
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
    Result := TLzmaEncoderConstants.kMatchMaxLen;
    if Count - RelativePos < NativeUInt(Result) then
      Result := UInt32(Count - RelativePos);
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
    if FMatchFinderThread <> nil then
      FMatchFinderThread.AdvanceTo(FWindowBase + RelativePos + RangeCount)
    else if SdkFinder <> nil then
      SdkFinder.InsertRange(RelativePos, RangeCount)
    else if Bt4Finder <> nil then
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

    if (SdkFinder = nil) and (Bt4Finder = nil) and (Hc5Finder = nil) and (Hc4Finder = nil) and
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

  function ReadMatchDistancesAndInsert(const RelativePos: NativeUInt;
    var MatchList: TLzmaMatchBuffer): TLzmaMatch;
  var
    AvailableLen: UInt32;
    CurrentTail: NativeUInt;
  begin
    EnsureInsertedUntil(RelativePos);
    if FMatchFinderThread <> nil then
      FMatchFinderThread.ReadAt(FWindowBase + RelativePos, MatchList)
    else if SdkFinder <> nil then
      SdkFinder.ReadMatchPairs(RelativePos, MatchList)
    else if Bt4Finder <> nil then
      Bt4Finder.ReadMatchPairs(RelativePos, MatchList)
    else if Hc5Finder <> nil then
      Hc5Finder.ReadMatchPairs(RelativePos, MatchList)
    else if Hc4Finder <> nil then
      Hc4Finder.ReadMatchPairs(RelativePos, MatchList)
    else
      GreedyFinder.ReadMatchPairs(RelativePos, MatchList);
    MarkInsertedUntil(RelativePos + 1);

    if MatchList.Count = 0 then
    begin
      Result.Length := 0;
      Result.Distance := 0;
    end
    else
    begin
      Result := MatchList.Last;
      // Both engine parsers retain raw fb-capped pairs and a separate main match.
      if Result.Length = EffectiveFastBytes then
      begin
        AvailableLen := NumAvailAt(RelativePos);
        if Result.Length < AvailableLen then
        begin
          CurrentTail := Offset + RelativePos + NativeUInt(Result.Length);
          Result.Length := Result.Length + LzmaCountMatchingBytes(Data, CurrentTail,
            CurrentTail - NativeUInt(Result.Distance), AvailableLen - Result.Length);
        end;
      end;
    end;
    if FullOptimumState.Enabled then
    begin
      AvailableLen := NumAvailAt(RelativePos);
      if FullOptimumState.AdditionalOffset < High(UInt32) then
        Inc(FullOptimumState.AdditionalOffset);
      FullOptimumState.NumAvail := AvailableLen;
      FullOptimumState.NumPairs := UInt32(MatchList.Count) * 2;
      FullOptimumState.LongestMatchLen := Result.Length;
      // This state belongs to the encoder; only active cached pairs are read.
      FullOptimumState.CachedMatches.CopyPairsFrom(MatchList);
      FullOptimumState.CachedMainMatch := Result;
    end;
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

  function GetOptimumFast(out Back: UInt32): UInt32;
  const
    MARK_LIT = UInt32($FFFFFFFF);
  var
    MainMatch, Candidate, NextMatch: TLzmaMatch;
    MainLen, MainDist, NumAvail, I, CandidateDist, NewDist: UInt32;
    PairIndex: Integer;
  begin
    // SDK 26.05 LzmaEnc.c GetOptimumFast; distances below are SDK zero-based.
    MainMatch := ReadCurrentMatchDistances(Pos, Matches);
    MainLen := MainMatch.Length;
    NumAvail := NumAvailAt(Pos);
    Back := MARK_LIT;
    if NumAvail < 2 then
      Exit(1);

    BestRepIndex := 0;
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
        BestRepIndex := Integer(I);
        BestRepLen := RepLen;
      end;
    end;

    if MainLen >= EffectiveFastBytes then
    begin
      Back := MainMatch.Distance + 3;
      Exit(MainLen);
    end;

    MainDist := 0;
    if MainLen >= 2 then
    begin
      MainDist := MainMatch.Distance - 1;
      PairIndex := Matches.Count - 1;
      while PairIndex > 0 do
      begin
        Candidate := Matches.Items[PairIndex - 1];
        if MainLen <> Candidate.Length + 1 then
          Break;
        CandidateDist := Candidate.Distance - 1;
        if not ((MainDist shr 7) > CandidateDist) then
          Break;
        Dec(PairIndex);
        Dec(MainLen);
        MainDist := CandidateDist;
      end;
      if (MainLen = 2) and (MainDist >= $80) then
        MainLen := 1;
    end;

    if (BestRepLen >= 2) and
      ((BestRepLen + 1 >= MainLen) or
       ((BestRepLen + 2 >= MainLen) and (MainDist >= UInt32(1) shl 9)) or
       ((BestRepLen + 3 >= MainLen) and (MainDist >= UInt32(1) shl 15))) then
    begin
      Back := UInt32(BestRepIndex);
      Exit(BestRepLen);
    end;

    if (MainLen < 2) or (NumAvail <= 2) then
      Exit(1);

    NextMatch := ReadLookaheadMatch(Pos + 1);
    if NextMatch.Length >= 2 then
    begin
      NewDist := NextMatch.Distance - 1;
      if ((NextMatch.Length >= MainLen) and (NewDist < MainDist)) or
        ((NextMatch.Length = MainLen + 1) and not ((NewDist shr 7) > MainDist)) or
        (NextMatch.Length > MainLen + 1) or
        ((NextMatch.Length + 1 >= MainLen) and (MainLen >= 3) and
         ((MainDist shr 7) > NewDist)) then
        Exit(1);
    end;

    for I := 0 to 3 do
    begin
      RepLen := RepLenAtPos(Pos + 1, Reps[I]);
      if (RepLen >= 2) and (RepLen >= MainLen - 1) then
        Exit(1);
    end;

    Back := MainDist + 4;
    Result := MainLen;
  end;

{$IFDEF LZMA_ENCODER_FLAT_OPTIMUM_FRAME}
  function GetOptimumFull(out Back: UInt32): UInt32;
  begin
    Result := FullFrame.Run(Back);
  end;
{$ELSE}
  function GetOptimumFull(out Back: UInt32): UInt32;
  var
    Cur, Last, MainLen, NumAvail, NumPairs, BestRep, I, J: UInt32;
    MainMatch: TLzmaMatch;
    RepLens: TLzmaOptimumRepLens;
    Model: TLzmaOptimumProbModelView;

    function AvailableAt(const At: UInt32): UInt32;
    var
      Remaining: NativeUInt;
    begin
      Result := LZMA_FULL_OPTIMUM_NUM_OPTS - 1 - At;
      Remaining := Count - (Pos + NativeUInt(At));
      if Remaining < NativeUInt(Result) then
        Result := UInt32(Remaining);
    end;

    function ProbsAt(const At, AtState: UInt32): TLzmaOptimumProbInput;
    begin
      Result := Model.Read(At, AtState, (Processed + At) and PbMask);
    end;

    function RepLength(const At, Distance, Limit: UInt32): UInt32;
    begin
      Result := RepLenAtPos(Pos + NativeUInt(At), Distance);
      if Result > Limit then
        Result := Limit;
      if Result < TLzmaEncoderConstants.kMatchMinLen then
        Result := 0;
    end;

    function LiteralCost(const At, AtState, RepDistance: UInt32): UInt32;
    var
      Relative, LiteralOffset: NativeUInt;
      Previous, Value, MatchValue: Byte;
      LiteralState: UInt32;
      View: TLzmaOptimumLiteralView;
    begin
      Relative := Pos + NativeUInt(At);
      if Relative = 0 then
        Previous := 0
      else
        Previous := Data[Offset + Relative - 1];
      Value := Data[Offset + Relative];
      LiteralState := (((Processed + At) and LpMask) shl LcBits) +
        (UInt32(Previous) shr LcShift);
      LiteralOffset := NativeUInt(LiteralState) * LZMA_LITERAL_PROB_COUNT;
      View := Default(TLzmaOptimumLiteralView);
      View.LiteralProbs := PLzmaOptimumLiteralProbs(@Literals[LiteralOffset]);
      View.Enabled := True;
      View.Value := Value;
      View.UseMatchedLiteral := AtState >= TLzmaEncoderConstants.kNumLitStates;
      if View.UseMatchedLiteral then
      begin
        if (RepDistance = 0) or (NativeUInt(RepDistance) > Relative) then
          RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid online optimum literal history');
        MatchValue := Data[Offset + Relative - NativeUInt(RepDistance)];
        View.MatchByte := MatchValue;
        Result := LzmaMatchedLiteralPrice(View.LiteralProbs^, Value, MatchValue, ProbPrices);
      end
      else
        Result := LzmaLiteralPrice(View.LiteralProbs^, Value, ProbPrices);
    end;

    function Rep0Price(const At, AtState: UInt32): UInt32;
    var
      Prob: TLzmaOptimumProbInput;
    begin
      Prob := ProbsAt(At, AtState);
      Result := LzmaRepMatchPrefixPrice(ProbPrices, Prob.IsMatchProb, Prob.IsRepProb) +
        LzmaRep0LongPrice(ProbPrices, Prob.IsRepG0Prob, Prob.IsRep0LongProb);
    end;

    procedure ExtendFrontier(const Target: UInt32);
    begin
      if Target > Last then
        Last := Target;
    end;

    procedure Store(const Target, Price, Len, PathBack, Extra: UInt32;
      const Source: TLzmaOptimumNode);
    var
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
      NativeContext: TLzmaOptimumStoreContext56;
{$ENDIF}
      Node: TLzmaOptimumNode;
      Index: Integer;
      Distance: UInt32;
    begin
      if Price >= FullOptimumState.Nodes[Integer(Target)].Price then
        Exit;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
      if Source.State < UInt32(Length(LZMA_STATE_LITERAL_NEXT)) then
      begin
        NativeContext.Price := Price;
        NativeContext.Len := Len;
        NativeContext.PathBack := PathBack;
        NativeContext.Extra := Extra;
        NativeContext.Destination := @FullOptimumState.Nodes[Integer(Target)];
        NativeContext.SourceNode := @Source;
        LzmaStoreOptimumNode56(@NativeContext);
        Exit;
      end;
{$ENDIF}
      Node := Default(TLzmaOptimumNode);
      Node.Price := Price;
      Node.PathLen := Len;
      Node.PathBack := PathBack;
      Node.Extra := Extra;
      Node.Reps := Source.Reps;
      if PathBack = LZMA_OPTIMUM_BACK_LITERAL then
        Node.State := LZMA_STATE_LITERAL_NEXT[Source.State]
      else if (Extra = 1) then
      begin
        // Literal + rep0 preserves the source repetition ordering.
        Node.State := LZMA_STATE_REP_NEXT[LZMA_STATE_LITERAL_NEXT[Source.State]];
      end
      else
      begin
        if PathBack < 4 then
        begin
          Distance := Source.Reps[Integer(PathBack)];
          for Index := Integer(PathBack) downto 1 do
            Node.Reps[Index] := Source.Reps[Index - 1];
          Node.Reps[0] := Distance;
          if Len = 1 then
            Node.State := LZMA_STATE_SHORT_REP_NEXT[Source.State]
          else
            Node.State := LZMA_STATE_REP_NEXT[Source.State];
        end
        else
        begin
          Node.Reps[0] := PathBack - 3;
          Node.Reps[1] := Source.Reps[0];
          Node.Reps[2] := Source.Reps[1];
          Node.Reps[3] := Source.Reps[2];
          Node.State := LZMA_STATE_MATCH_NEXT[Source.State];
        end;
        if Extra > 1 then
          Node.State := LZMA_STATE_REP_NEXT[LZMA_STATE_LITERAL_NEXT[Node.State]];
      end;
      FullOptimumState.Nodes[Integer(Target)] := Node;
    end;

    procedure Relax(const Initial: Boolean);
    var
      Node: TLzmaOptimumNode;
      Prob, LiteralProb: TLzmaOptimumProbInput;
      FullAvailable, Available, PosState, MatchPrice, RepPrice, LitPrice: UInt32;
      Price, CandidatePrice, Len, Len2, StartLen, RepIndex, FirstState: UInt32;
      Tail, Target, Distance, PairIndex, NextPos, NextState: UInt32;
      CurrentByte, MatchByte: Byte;
      HasRep0, NextIsLit: Boolean;
    begin
      Node := FullOptimumState.Nodes[Integer(Cur)];
      Prob := ProbsAt(Cur, Node.State);
      PosState := (Processed + Cur) and PbMask;
      FullAvailable := AvailableAt(Cur);
      Available := FullAvailable;
      if Available > EffectiveFastBytes then
        Available := EffectiveFastBytes;
      CurrentByte := Data[Offset + Pos + NativeUInt(Cur)];
      HasRep0 := (Node.Reps[0] <> 0) and
        (NativeUInt(Node.Reps[0]) <= Pos + NativeUInt(Cur));
      MatchByte := 0;
      if HasRep0 then
        MatchByte := Data[Offset + Pos + NativeUInt(Cur) - NativeUInt(Node.Reps[0])];
      MatchPrice := Node.Price + LzmaBitPrice(ProbPrices, Prob.IsMatchProb, 1);
      RepPrice := MatchPrice + LzmaBitPrice(ProbPrices, Prob.IsRepProb, 1);
      LitPrice := Node.Price + LzmaBitPrice(ProbPrices, Prob.IsMatchProb, 0);
      NextIsLit := False;
      if (not Initial) and
        (((FullOptimumState.Nodes[Integer(Cur + 1)].Price <> High(UInt32)) and
          HasRep0 and (MatchByte = CurrentByte)) or
         (LitPrice > FullOptimumState.Nodes[Integer(Cur + 1)].Price)) then
        LitPrice := 0
      else
      begin
        Inc(LitPrice, LiteralCost(Cur, Node.State, Node.Reps[0]));
        if LitPrice < FullOptimumState.Nodes[Integer(Cur + 1)].Price then
        begin
          Store(Cur + 1, LitPrice, 1, LZMA_OPTIMUM_BACK_LITERAL, 0, Node);
          NextIsLit := True;
        end;
      end;

      // Initial short rep has its own SDK condition. Interior short reps require
      // literal state and preserve the SDK next-node/tie suppression rules.
      if HasRep0 and (MatchByte = CurrentByte) and
        ((Initial and (RepLens[0] = 0)) or
         ((not Initial) and (Node.State < TLzmaEncoderConstants.kNumLitStates) and
          (RepPrice < FullOptimumState.Nodes[Integer(Cur + 1)].Price) and
          ((FullOptimumState.Nodes[Integer(Cur + 1)].PathLen < 2) or
           (FullOptimumState.Nodes[Integer(Cur + 1)].PathBack <> 0)))) then
      begin
        Price := RepPrice + LzmaShortRepPrice(ProbPrices,
          Prob.IsRepG0Prob, Prob.IsRep0LongProb);
        if Price < FullOptimumState.Nodes[Integer(Cur + 1)].Price then
        begin
          Store(Cur + 1, Price, 1, 0, 0, Node);
          NextIsLit := False;
        end;
      end;
      if FullAvailable < 2 then
        Exit;

      if (not Initial) and (not NextIsLit) and (LitPrice <> 0) and HasRep0 and
        (MatchByte <> CurrentByte) and (FullAvailable > 2) then
      begin
        Tail := RepLength(Cur + 1, Node.Reps[0], FullAvailable - 1);
        if Tail > EffectiveFastBytes then
          Tail := EffectiveFastBytes;
        if Tail >= 2 then
        begin
          Target := Cur + 1 + Tail;
          ExtendFrontier(Target);
          NextState := LZMA_STATE_LITERAL_NEXT[Node.State];
          Price := LitPrice + Rep0Price(Cur + 1, NextState) +
            LzmaLenPrice(RepLenPrices, (Processed + Cur + 1) and PbMask, Tail);
          Store(Target, Price, Tail, 0, 1, Node);
        end;
      end;

      StartLen := TLzmaEncoderConstants.kMatchMinLen;
      for RepIndex := 0 to 3 do
      begin
        if Initial then
          Len := RepLens[Integer(RepIndex)]
        else
          Len := RepLength(Cur, Node.Reps[Integer(RepIndex)], Available);
        if Len < 2 then
          Continue;
        ExtendFrontier(Cur + Len);
        Price := RepPrice + LzmaPureRepPrice(ProbPrices, Prob.IsRepG0Prob,
          Prob.IsRepG1Prob, Prob.IsRepG2Prob, Prob.IsRep0LongProb, RepIndex);
        Len2 := Len;
        repeat
          CandidatePrice := Price + LzmaLenPrice(RepLenPrices, PosState, Len2);
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
{$IFOPT Q-}
          if CandidatePrice < FullOptimumState.Nodes[Integer(Cur + Len2)].Price then
{$ENDIF}
{$ENDIF}
            Store(Cur + Len2, CandidatePrice, Len2, RepIndex, 0, Node);
          Dec(Len2);
        until Len2 < 2;
        if RepIndex = 0 then
          StartLen := Len + 1;

        if Initial or (FullAvailable <= Len + 2) then
          Continue;
        Tail := RepLength(Cur + Len + 1, Node.Reps[Integer(RepIndex)],
          FullAvailable - Len - 1);
        if Tail > EffectiveFastBytes then
          Tail := EffectiveFastBytes;
        if Tail < 2 then
          Continue;
        Target := Cur + Len + 1 + Tail;
        ExtendFrontier(Target);
        FirstState := LZMA_STATE_REP_NEXT[Node.State];
        LiteralProb := ProbsAt(Cur + Len, FirstState);
        CandidatePrice := Price + LzmaLenPrice(RepLenPrices, PosState, Len) +
          LzmaBitPrice(ProbPrices, LiteralProb.IsMatchProb, 0) +
          LiteralCost(Cur + Len, FirstState, Node.Reps[Integer(RepIndex)]);
        NextPos := Cur + Len + 1;
        NextState := LZMA_STATE_LITERAL_NEXT[FirstState];
        Inc(CandidatePrice, Rep0Price(NextPos, NextState) +
          LzmaLenPrice(RepLenPrices, (Processed + NextPos) and PbMask, Tail));
        Store(Target, CandidatePrice, Tail, RepIndex, Len + 1, Node);
      end;

      // Preserve SDK match-length traversal and extra-path ordering at each
      // actual pair boundary, rather than a separate extras-before-matches pass.
      if MainLen > Available then
      begin
        MainLen := Available;
        // SDK clips the first covering pair and excludes all later pairs.
        // Keeping Count would introduce duplicate clipped length boundaries.
        PairIndex := 0;
        while MainLen > Matches.Items[Integer(PairIndex)].Length do
          Inc(PairIndex);
        Matches.Items[Integer(PairIndex)].Length := MainLen;
        Matches.Count := Integer(PairIndex) + 1;
      end;
      if MainLen < StartLen then
        Exit;
      ExtendFrontier(Cur + MainLen);
      Price := MatchPrice + LzmaBitPrice(ProbPrices, Prob.IsRepProb, 0);
      PairIndex := 0;
      while StartLen > Matches.Items[Integer(PairIndex)].Length do
        Inc(PairIndex);
      Len := StartLen;
      repeat
        Distance := Matches.Items[Integer(PairIndex)].Distance;
        CandidatePrice := Price + LzmaLenPrice(LenPrices, PosState, Len) +
          LzmaMatchDistancePrice(DistancePrices, Len, Distance);
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
{$IFOPT Q-}
        if CandidatePrice < FullOptimumState.Nodes[Integer(Cur + Len)].Price then
{$ENDIF}
{$ENDIF}
          Store(Cur + Len, CandidatePrice, Len, Distance + 3, 0, Node);
        if Len = Matches.Items[Integer(PairIndex)].Length then
        begin
          if (not Initial) and (FullAvailable > Len + 2) then
          begin
            Tail := RepLength(Cur + Len + 1, Distance, FullAvailable - Len - 1);
            if Tail > EffectiveFastBytes then
              Tail := EffectiveFastBytes;
            if Tail >= 2 then
            begin
              Target := Cur + Len + 1 + Tail;
              ExtendFrontier(Target);
              FirstState := LZMA_STATE_MATCH_NEXT[Node.State];
              LiteralProb := ProbsAt(Cur + Len, FirstState);
              Inc(CandidatePrice, LzmaBitPrice(ProbPrices, LiteralProb.IsMatchProb, 0) +
                LiteralCost(Cur + Len, FirstState, Distance));
              NextPos := Cur + Len + 1;
              NextState := LZMA_STATE_LITERAL_NEXT[FirstState];
              Inc(CandidatePrice, Rep0Price(NextPos, NextState) +
                LzmaLenPrice(RepLenPrices, (Processed + NextPos) and PbMask, Tail));
              Store(Target, CandidatePrice, Tail, Distance + 3, Len + 1, Node);
            end;
          end;
          Inc(PairIndex);
          if PairIndex = UInt32(Matches.Count) then
            Break;
        end;
        Inc(Len);
      until False;
    end;

  begin
    Back := LZMA_OPTIMUM_BACK_LITERAL;
    if LzmaFullOptimumTryReplay(FullOptimumState, Result, Back) then
    begin
      Inc(LocalFullOptimumDecisionCount);
      Exit;
    end;
    Result := 1;
    if LzmaFullOptimumBeginDecision(FullOptimumState, NumAvail, NumPairs, MainLen) then
      MainMatch := ReadCurrentMatchDistances(Pos, Matches)
    else if not LzmaFullOptimumLoadCachedMatches(FullOptimumState, Matches, MainMatch) then
      RaiseLzmaError(SZ_ERROR_FAIL, 'Missing retained online optimum match');
    NumAvail := NumAvailAt(Pos);
    if NumAvail < TLzmaEncoderConstants.kMatchMinLen then
    begin
      FullOptimumState.BackRes := Back;
      Exit;
    end;
    MainLen := MainMatch.Length;
    BestRep := 0;
    FillChar(RepLens, SizeOf(RepLens), 0);
    for I := 0 to 3 do
    begin
      RepLens[Integer(I)] := RepLength(0, Reps[I], NumAvail);
      if RepLens[Integer(I)] > RepLens[Integer(BestRep)] then
        BestRep := I;
      if RepLens[Integer(I)] = TLzmaEncoderConstants.kMatchMaxLen then
        Break;
    end;
    if RepLens[Integer(BestRep)] >= EffectiveFastBytes then
    begin
      Back := BestRep;
      Result := RepLens[Integer(BestRep)];
      EnsureInsertedUntil(Pos + NativeUInt(Result));
      LzmaFullOptimumMovePos(FullOptimumState, Result - 1);
      FullOptimumState.BackRes := Back;
      Exit;
    end;
    if MainLen >= EffectiveFastBytes then
    begin
      Back := MainMatch.Distance + 3;
      Result := MainLen;
      EnsureInsertedUntil(Pos + NativeUInt(Result));
      LzmaFullOptimumMovePos(FullOptimumState, Result - 1);
      FullOptimumState.BackRes := Back;
      Exit;
    end;

    Last := MainLen;
    if Last < RepLens[Integer(BestRep)] then
      Last := RepLens[Integer(BestRep)];
    if (Last < 2) and
      ((Reps[0] = 0) or (NativeUInt(Reps[0]) > Pos) or
       (Data[Offset + Pos] <> Data[Offset + Pos - NativeUInt(Reps[0])])) then
    begin
      FullOptimumState.BackRes := Back;
      Exit;
    end;
    // Init/reset already allocates these 2048 nodes. Previous solves clear only
    // touched prices after Backward, preserving the SDK amortized work bound.
    if Length(FullOptimumState.Nodes) <> LZMA_FULL_OPTIMUM_NUM_OPTS then
      RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid online optimum node capacity');
    FullOptimumState.Nodes[0] := Default(TLzmaOptimumNode);
    FullOptimumState.Nodes[0].Price := 0;
    FullOptimumState.Nodes[0].State := State;
    for I := 0 to 3 do
      FullOptimumState.Nodes[0].Reps[Integer(I)] := Reps[I];
    Model := TLzmaOptimumProbModelView.Borrow(IsMatch, IsRep, IsRepG0,
      IsRepG1, IsRepG2, IsRep0Long, LZMA_FULL_OPTIMUM_NUM_OPTS);
    Cur := 0;
    Relax(True);
    if Last < 2 then
    begin
      Back := FullOptimumState.Nodes[1].PathBack;
      FullOptimumState.Nodes[1].Price := High(UInt32);
      FullOptimumState.BackRes := Back;
      Exit(1);
    end;
    repeat
      Inc(Cur);
      if Cur = Last then
        Break;
      if Cur >= LZMA_FULL_OPTIMUM_NUM_OPTS - 64 then
      begin
        I := Cur;
        for J := Cur + 1 to Last do
          if FullOptimumState.Nodes[Integer(I)].Price >=
            FullOptimumState.Nodes[Integer(J)].Price then
            I := J;
        if I <> Cur then
        begin
          EnsureInsertedUntil(Pos + NativeUInt(I));
          LzmaFullOptimumMovePos(FullOptimumState, I - Cur);
        end;
        Cur := I;
        Break;
      end;
      MainMatch := ReadMatchDistancesAndInsert(Pos + NativeUInt(Cur), Matches);
      MainLen := MainMatch.Length;
      // The just-read query remains cached at AdditionalOffset=cur+1. Replay
      // covers only cur bytes; after commit the retained query has offset1.
      if MainLen >= EffectiveFastBytes then
        Break;
      Relax(False);
    until False;
    if not LzmaFullOptimumBackward(FullOptimumState, Cur, Result, Back) then
      RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid online optimum backward path');
    for I := 1 to Last do
      FullOptimumState.Nodes[Integer(I)].Price := High(UInt32);
    Inc(LocalFullOptimumDecisionCount);
    FullOptimumState.BackRes := Back;
  end;

{$ENDIF}
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
  InitialDecisionCount := LocalFullOptimumDecisionCount;
  ContinuingSession := FInitialized;
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
  if FullOptimumDecisionCount <> nil then
    FullOptimumDecisionCount^ := 0;
{$IFDEF LZMA_ENCODER_FLAT_OPTIMUM_FRAME}
  FullFrame.Owner := Self;
  FullFrame.InputRef := @Data;
  FullFrame.Offset := Offset;
  FullFrame.Count := Count;
{$ENDIF}

  try
    if not FInitialized then
    begin
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
  SetLength(Literals, LzmaEncoderLiteralProbCount(Props));
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
  SdkFinder := nil;
  Encoder := nil;
  LocalFullOptimumDecisionCount := 0;
    Encoder := TLzmaRangeEncoder.Create(FOutputSink);
    Encoder.Init;
    Pos := 0;
    Processed := 0;
    NextProgressAt := kProgressInterval;
    InsertedUntil := 0;
    MatchCache.Clear;
    LzmaFullOptimumInit(FullOptimumState, EnableOptimumWindow);
    State := 0;
    Reps[0] := 1;
    Reps[1] := 1;
    Reps[2] := 1;
    Reps[3] := 1;

    if (not BoundedFrame) and (not FContinuousRange) and
      (not FullOptimumState.Enabled) and TryDetectSmallPeriodicChunk(PeriodicDistance) then
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

    FinderInputCount := Count;
    if FContinuousRange then
      FinderInputCount := NativeUInt(Length(Data)) - Offset;
    // Cap engine-owned finder traversal for both fast and full parsing.
    if FUseSdkFinder then
      SdkFinder := TLzmaSdkMatchFinder.Create(Data, Offset, FinderInputCount,
        TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize), SdkFinderHashBytes(MatchFinderKind),
        EffectiveFastBytes, CutValue, FUseSdkMtHighHash, SdkFinderIsBinaryTree(MatchFinderKind),
        FSdkHashOutBits, FSdkExpectedDataSize, True)
    else case MatchFinderKind of
      mfBinaryTree2:
        SdkFinder := TLzmaSdkBinaryTreeMatchFinder.Create(Data, Offset, FinderInputCount,
          TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize), 2,
          EffectiveFastBytes, CutValue, FUseSdkMtHighHash);
      mfBinaryTree3:
        SdkFinder := TLzmaSdkBinaryTreeMatchFinder.Create(Data, Offset, FinderInputCount,
          TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize), 3,
          EffectiveFastBytes, CutValue, FUseSdkMtHighHash);
      mfBinaryTree5:
        SdkFinder := TLzmaSdkBinaryTreeMatchFinder.Create(Data, Offset, FinderInputCount,
          TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize), 5,
          EffectiveFastBytes, CutValue, FUseSdkMtHighHash);
      mfHashChain4:
        Hc4Finder := TLzmaHashChain4MatchFinder.Create(Data, Offset, FinderInputCount,
        TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize),
        EffectiveFastBytes, EffectiveFastBytes, CutValue);
      mfHashChain5:
        Hc5Finder := TLzmaHashChain5MatchFinder.Create(Data, Offset, FinderInputCount,
          TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize),
          EffectiveFastBytes, EffectiveFastBytes, CutValue);
      mfBinaryTree4:
        begin
          if FUseSdkMtHighHash then
            Bt4Finder := TLzmaBinaryTree4MatchFinder.CreateSdkMtHighHash(Data, Offset, FinderInputCount,
              TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize),
              EffectiveFastBytes, EffectiveFastBytes, CutValue)
          else
            Bt4Finder := TLzmaBinaryTree4MatchFinder.Create(Data, Offset, FinderInputCount,
              TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize),
              EffectiveFastBytes, EffectiveFastBytes, CutValue);
        end;
    else
      GreedyFinder := TLzmaGreedyMatchFinder.Create(Data, Offset, FinderInputCount,
        TLzmaRawEncoder.EffectiveHistorySize(Props.DictionarySize),
        EffectiveFastBytes, EffectiveFastBytes, CutValue);
    end;
    if FinderInputCount <> Count then
      RebaseWindow(0, Count);

    FInitialized := True;
    if FUseMatchFinderThread then
    begin
      FThreadProgress := Progress;
      FMatchFinderThread := TLzmaMatchFinderPipeline.Create(
        procedure(const Position: NativeUInt; var Pairs: TLzmaMatchBuffer)
        begin
          if SdkFinder <> nil then SdkFinder.ReadMatchPairs(Position, Pairs)
          else Bt4Finder.ReadMatchPairs(Position, Pairs);
        end,
        procedure
        begin
          // Progress/cancel and all stream callbacks stay on the encoder caller.
          ReportProgress(FThreadProgress, Processed, Encoder.FCommittedOutputSize);
        end);
      ResumeMatchFinder(Count, FinalInput);
    end;
    end;

    if ContinuingSession and (not FContinuousRange) then
      Encoder.Init;
    FFrameStart := Pos;
    if BoundedFrame then
    begin
      SaveModels(FModelSnapshot);
      RefreshOptimumPriceTables;
      // SDK CodeOneMemBlock initializes both price families for each frame.
      if FullOptimumState.Enabled then
        LzmaFullOptimumResetRefreshCounters(FullOptimumState);
    end;

    while Pos < Count do
    begin
      // SDK bounded frames consume pending fast-parser lookahead before a limit stop.
      if (Pos > FFrameStart) and
        ((FullOptimumState.Enabled and (FullOptimumState.AdditionalOffset = 0)) or
         ((not FullOptimumState.Enabled) and
          ((not BoundedFrame) or (InsertedUntil = Pos)))) and
        ((BoundedFrame and
          (((Pos - FFrameStart) + kFrameUnpackReserve >= FrameUnpackLimit) or
           (Encoder.FOutputSize + Encoder.FCacheSize + kFramePackReserve >= kMaxFramePackSize))) or
         ((not FinalInput) and (Count - Pos <= kFrameUnpackReserve))) then
        Break;
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
        if (BackRes <> LZMA_OPTIMUM_BACK_LITERAL) and (BackRes >= 4) then
          LzmaFullOptimumNoteNormalMatch(FullOptimumState)
        else if (BackRes < 4) and (LenRes > 1) then
          LzmaFullOptimumNoteRepLen(FullOptimumState);
        if not LzmaFullOptimumCommitEncodedLen(FullOptimumState, LenRes) then
          RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA full optimum additionalOffset underflow');
        if LzmaFullOptimumCanRefreshPrices(FullOptimumState) then
        begin
          if FullOptimumState.MatchPriceCount >= LZMA_FULL_OPTIMUM_MATCH_PRICE_REFRESH then
          begin
            LzmaUpdateLenPriceEncoder(LenPrices, LenEncoder.Low, LenEncoder.High,
              NumPosStates, ProbPrices);
            LzmaUpdateDistancePriceEncoder(DistancePrices, PosSlot, PosDecoders,
              Align, ProbPrices);
            FullOptimumState.MatchPriceCount := 0;
          end;
          if FullOptimumState.RepLenEncCounter <= 0 then
          begin
            LzmaUpdateLenPriceEncoder(RepLenPrices, RepLenEncoder.Low,
              RepLenEncoder.High, NumPosStates, ProbPrices);
            FullOptimumState.RepLenEncCounter := LZMA_FULL_OPTIMUM_REP_LEN_COUNT;
          end;
        end;
      end;
    end;

    if (not FContinuousRange) or FinalInput then
    begin
      if FContinuousRange then
        ReportProgress(Progress, Processed, Encoder.FCommittedOutputSize);
      if WriteEndMarker then
        EncodeEndMarker;
      Encoder.FlushData;
      if FOutputSink = nil then
        Result := Encoder.ToBytes
      else
        Result := nil;
    end
    else
      Result := nil;
  finally
    if FullOptimumDecisionCount <> nil then
      FullOptimumDecisionCount^ := LocalFullOptimumDecisionCount - InitialDecisionCount;
  end;
end;

procedure TLzmaEncoderInputWindow.Initialize(InputSource: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const InputProgress: TLzma2ProgressEvent; const BufferSize: NativeUInt;
  const Incremental: Boolean; const MemoryLimit: UInt64; const Framed, SdkFinder: Boolean;
  const HashOutBits: UInt32; const ExpectedDataSize: UInt64);
var
  RequestedCapacity: NativeUInt;
  Lookahead: Byte;
  LookaheadCount: Integer;
begin
  Self := Default(TLzmaEncoderInputWindow);
  Source := InputSource;
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA encoder input configuration');
  LzmaStreamingInputDimensions(Props, BufferSize, DictionarySize, ReadQuantum, RequestedCapacity);
  IncrementalInput := Incremental;
  Progress := InputProgress;
  Capacity := ReadQuantum;
  if Capacity > RequestedCapacity then
    Capacity := RequestedCapacity;
  ReportProgress(Progress, 0, 0);
  ValidateMemoryLimit(TLzmaRawEncoder.RequiredMemoryCore(Profile, Props, Capacity,
    Framed, SdkFinder, HashOutBits, ExpectedDataSize), MemoryLimit);
  SetLength(Data, NativeInt(Capacity));
  Fill;
  if not FinalInput then
  begin
    LookaheadCount := ReadAvailable(Source, Lookahead, SizeOf(Lookahead));
    if LookaheadCount = 0 then
      FinalInput := True
    else
    begin
      Inc(TotalRead, UInt64(LookaheadCount));
      ReportProgress(Progress, ReportedInput, ReportedOutput);
      // A moving reallocation may retain the old array until its copy completes.
      ValidateMemoryLimit(CheckedMemoryAdd(UInt64(Length(Data)),
        TLzmaRawEncoder.RequiredMemoryCore(Profile, Props, RequestedCapacity,
          Framed, SdkFinder, HashOutBits, ExpectedDataSize)), MemoryLimit);
      Capacity := RequestedCapacity;
      SetLength(Data, NativeInt(Capacity));
      Data[Count] := Lookahead;
      Inc(Count);
      if not IncrementalInput then
        Fill;
    end;
  end;
  if FinalInput then
  begin
    Capacity := Count;
    if Capacity <> NativeUInt(Length(Data)) then
    begin
      ValidateMemoryLimit(CheckedMemoryAdd(UInt64(Length(Data)),
        TLzmaRawEncoder.RequiredMemoryCore(Profile, Props, Capacity, Framed, SdkFinder, HashOutBits, ExpectedDataSize)), MemoryLimit);
      SetLength(Data, NativeInt(Capacity));
    end;
    if DictionarySize > Count then
      DictionarySize := Count;
  end;
end;

procedure TLzmaEncoderInputWindow.Fill;
var
  Available, FillLimit: NativeUInt;
  ReadSize, ReadCount: Integer;
begin
  ReportProgress(Progress, ReportedInput, ReportedOutput);
  FillLimit := Capacity;
  if IncrementalInput and (FillLimit - Count > ReadQuantum) then
    FillLimit := Count + ReadQuantum;
  while Count < FillLimit do
  begin
    Available := FillLimit - Count;
    if Available > ReadQuantum then
      ReadSize := Integer(ReadQuantum)
    else
      ReadSize := Integer(Available);
    ReadCount := ReadAvailable(Source, Data[Count], NativeUInt(ReadSize));
    if ReadCount = 0 then
    begin
      FinalInput := True;
      Break;
    end;
    Inc(Count, NativeUInt(ReadCount));
    Inc(TotalRead, UInt64(ReadCount));
    ReportProgress(Progress, ReportedInput, ReportedOutput);
  end;
  if UInt64(Count) > MaxRetained then
    MaxRetained := Count;
end;

procedure TLzmaEncoderInputWindow.RefillAtBoundary(Context: TLzmaEncoderContext;
  const CommittedOutput: UInt64);
var
  DropCount: NativeUInt;
begin
  if FinalInput or
    (Count - Context.Pos > TLzmaStatefulFrameLimits.MaxUnpackedSize +
      TLzmaStatefulFrameLimits.UnpackReserve) then
    Exit;
  if Context.Pos <= DictionarySize then
  begin
    if not IncrementalInput or (Count = Capacity) then
      Exit;
    DropCount := 0;
  end
  else
    DropCount := Context.Pos - DictionarySize;
  // The finder shares this array. Acknowledge its pause BEFORE moving/filling bytes.
  Context.PauseMatchFinder;
  if DropCount <> 0 then
  begin
    Move(Data[DropCount], Data[0], Count - DropCount);
    Dec(Count, DropCount);
  end;
  ReportedInput := Context.Processed;
  ReportedOutput := CommittedOutput;
  Fill;
  Context.RebaseWindow(DropCount, Count);
  Context.ResumeMatchFinder(Count, FinalInput);
end;

constructor TLzmaEncoderContext.Create(const OutputSink: TStream);
begin
  inherited Create;
  FOutputSink := OutputSink;
  FContinuousRange := OutputSink <> nil;
end;

procedure TLzmaEncoderContext.RebaseWindow(const DropCount, NewCount: NativeUInt);
begin
  if (DropCount > Pos) or (DropCount > InsertedUntil) then
    RaiseLzmaError(SZ_ERROR_FAIL, 'Invalid LZMA encoder window cursor');
  if FullOptimumState.Enabled and (FullOptimumState.AdditionalOffset <> 0) then
    RaiseLzmaError(SZ_ERROR_FAIL, 'Cannot rebase LZMA encoder input before commit');
  if SdkFinder <> nil then
  begin
    SdkFinder.RebaseWindow(DropCount);
    SdkFinder.SetInputCount(NewCount);
  end
  else if Bt4Finder <> nil then
  begin
    Bt4Finder.RebaseWindow(DropCount);
    Bt4Finder.SetInputCount(NewCount);
  end
  else if Hc5Finder <> nil then
  begin
    Hc5Finder.RebaseWindow(DropCount);
    Hc5Finder.SetInputCount(NewCount);
  end
  else if Hc4Finder <> nil then
  begin
    Hc4Finder.RebaseWindow(DropCount);
    Hc4Finder.SetInputCount(NewCount);
  end
  else if GreedyFinder <> nil then
  begin
    GreedyFinder.RebaseWindow(DropCount);
    GreedyFinder.SetInputCount(NewCount);
  end;
  Dec(Pos, DropCount);
  Dec(InsertedUntil, DropCount);
  MatchCache.RebasePositions(DropCount);
  FWindowBase := CheckedMemoryAdd(FWindowBase, DropCount);
end;

procedure TLzmaEncoderContext.PauseMatchFinder;
begin
  if FMatchFinderThread <> nil then FMatchFinderThread.Pause;
end;

procedure TLzmaEncoderContext.ResumeMatchFinder(const Count: NativeUInt; const FinalInput: Boolean);
begin
  if FMatchFinderThread <> nil then
    FMatchFinderThread.SetWindow(FWindowBase, Count, EffectiveFastBytes, FinalInput);
end;

procedure TLzmaEncoderContext.SaveModels(var Snapshot: TLzmaEncoderModelSnapshot);
begin
  Move(IsMatch, Snapshot.IsMatch, SizeOf(IsMatch));
  Move(IsRep, Snapshot.IsRep, SizeOf(IsRep));
  Move(IsRepG0, Snapshot.IsRepG0, SizeOf(IsRepG0));
  Move(IsRepG1, Snapshot.IsRepG1, SizeOf(IsRepG1));
  Move(IsRepG2, Snapshot.IsRepG2, SizeOf(IsRepG2));
  Move(IsRep0Long, Snapshot.IsRep0Long, SizeOf(IsRep0Long));
  Snapshot.PosSlot := PosSlot;
  Snapshot.PosDecoders := PosDecoders;
  Snapshot.Align := Align;
  Snapshot.LenEncoder := LenEncoder;
  Snapshot.RepLenEncoder := RepLenEncoder;
  Snapshot.State := State;
  Move(Reps, Snapshot.Reps, SizeOf(Reps));
  SetLength(Snapshot.Literals, Length(Literals));
  if Length(Literals) <> 0 then
    Move(Literals[0], Snapshot.Literals[0], Length(Literals) * SizeOf(CLzmaProb));
end;

procedure TLzmaEncoderContext.RestoreModels(const Snapshot: TLzmaEncoderModelSnapshot);
begin
  Move(Snapshot.IsMatch, IsMatch, SizeOf(IsMatch));
  Move(Snapshot.IsRep, IsRep, SizeOf(IsRep));
  Move(Snapshot.IsRepG0, IsRepG0, SizeOf(IsRepG0));
  Move(Snapshot.IsRepG1, IsRepG1, SizeOf(IsRepG1));
  Move(Snapshot.IsRepG2, IsRepG2, SizeOf(IsRepG2));
  Move(Snapshot.IsRep0Long, IsRep0Long, SizeOf(IsRep0Long));
  PosSlot := Snapshot.PosSlot;
  PosDecoders := Snapshot.PosDecoders;
  Align := Snapshot.Align;
  LenEncoder := Snapshot.LenEncoder;
  RepLenEncoder := Snapshot.RepLenEncoder;
  State := Snapshot.State;
  Move(Snapshot.Reps, Reps, SizeOf(Reps));
  SetLength(Literals, Length(Snapshot.Literals));
  if Length(Literals) <> 0 then
    Move(Snapshot.Literals[0], Literals[0], Length(Literals) * SizeOf(CLzmaProb));
end;

function LzmaWriteContextLzma2Frame(Context: TLzmaEncoderContext;
  Output: TStream; const Data, Payload: TBytes; const StartPos, UnpackSize: NativeUInt;
  const Props: TLzmaProps; var NeedDictionary, NeedProperties: Boolean;
  out CompressedFrame: Boolean): UInt64;
var
  CopyPos, CopySize: NativeUInt;
  PackedMinusOne, UnpackedMinusOne: UInt32;
  Control: Byte;
  Written, PackedWireSize, CopyWireSize: UInt64;

  procedure PutByte(const Value: Byte);
  begin
    WriteExact(Output, Value, 1);
    Inc(Written);
  end;

begin
  Written := 0;
  CompressedFrame := False;
  if (UnpackSize = 0) or (UnpackSize > NativeUInt(1) shl 21) then
    RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA2 frame unpack bound exceeded');
  if Length(Payload) > 65536 then
    RaiseLzmaError(SZ_ERROR_FAIL, 'LZMA2 frame packed bound exceeded');
  PackedWireSize := UInt64(Length(Payload)) + 5 + UInt64(Ord(NeedProperties));
  CopyWireSize := UInt64(UnpackSize) + 3 *
    ((UInt64(UnpackSize) + TLzmaStatefulFrameLimits.MaxPackedSize - 1) div
      TLzmaStatefulFrameLimits.MaxPackedSize);
  if PackedWireSize >= CopyWireSize then
  begin
    Context.RestoreModels(Context.FModelSnapshot);
    CopyPos := StartPos;
    while CopyPos < Context.Pos do
    begin
      CopySize := Context.Pos - CopyPos;
      if CopySize > 65536 then
        CopySize := 65536;
      if NeedDictionary then
        PutByte(1)
      else
        PutByte(2);
      PutByte(Byte((CopySize - 1) shr 8));
      PutByte(Byte((CopySize - 1) and $FF));
      WriteExact(Output, Data[CopyPos], CopySize);
      Inc(Written, CopySize);
      NeedDictionary := False;
      Inc(CopyPos, CopySize);
    end;
  end
  else
  begin
    UnpackedMinusOne := UInt32(UnpackSize - 1);
    PackedMinusOne := UInt32(Length(Payload) - 1);
    if NeedDictionary then
      Control := $E0
    else if NeedProperties then
      Control := $C0
    else
      Control := $80;
    PutByte(Control or Byte(UnpackedMinusOne shr 16));
    PutByte(Byte((UnpackedMinusOne shr 8) and $FF));
    PutByte(Byte(UnpackedMinusOne and $FF));
    PutByte(Byte(PackedMinusOne shr 8));
    PutByte(Byte(PackedMinusOne and $FF));
    if NeedProperties then
      PutByte(Byte((Props.Pb * 5 + Props.Lp) * 9 + Props.Lc));
    WriteExact(Output, Payload[0], Length(Payload));
    Inc(Written, UInt64(Length(Payload)));
    NeedDictionary := False;
    NeedProperties := False;
    CompressedFrame := True;
  end;
  Result := Written;
end;

class procedure TLzmaRawEncoder.EncodeLzma2StreamCore(Source, Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const Progress: TLzma2ProgressEvent; const Diagnostics: PLzma2EncodeDiagnostics;
  const BufferSize: NativeUInt; const MemoryLimit: UInt64;
  const UseSdkMtHighHash: Boolean);
var
  Context: TLzmaEncoderContext;
  Window: TLzmaEncoderInputWindow;
  Payload: TBytes;
  StartPos: NativeUInt;
  EnableOptimumWindow, NeedDictionary, NeedProperties, CompressedFrame: Boolean;
  CommittedOutput, DecisionCount, FrameStartProcessed: UInt64;
  FrameUnpackLimit: NativeUInt;
  TrialProgress: TLzma2ProgressEvent;
  EndMarker: Byte;
begin
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'LZMA2 output stream is required');
  if (Props.Lc + Props.Lp > 4) or (Props.Pb > 4) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA2 encoder properties');
  EnableOptimumWindow := (Profile.ParserMode = lpmSdkProfile) and (Profile.Algorithm <> 0);
  FrameUnpackLimit := TLzmaStatefulFrameLimits.MaxUnpackedSize;
  if BufferSize <> 0 then
  begin
    FrameUnpackLimit := CheckedBufferSize(BufferSize);
    if FrameUnpackLimit > TLzmaStatefulFrameLimits.MaxUnpackedSize then
      FrameUnpackLimit := TLzmaStatefulFrameLimits.MaxUnpackedSize;
  end;
  Window.Initialize(Source, Profile, Props, Progress, BufferSize, False, MemoryLimit, True);
  ValidateMemoryLimit(RequiredStreamingMemory(Profile, Props, Window.Capacity, True), MemoryLimit);
  NeedDictionary := True;
  NeedProperties := True;
  CommittedOutput := 0;
  if Diagnostics <> nil then
  begin
    Diagnostics.ActualThreadCount := 1;
    Diagnostics.OptimumParserEnabled := False;
    Diagnostics.FastBytes := Profile.FastBytes;
    Diagnostics.NiceLen := Profile.FastBytes;
    Diagnostics.CutValue := Profile.CutValue;
    Diagnostics.ParserMode := Profile.ParserMode;
    Diagnostics.MatchFinderProfile := Profile.MatchFinderProfile;
    Diagnostics.NumHashBytes := Profile.NumHashBytes;
  end;
  FrameStartProcessed := 0;
  TrialProgress := nil;
  if Assigned(Progress) then
    TrialProgress := procedure(const TrialInput, TrialOutput: UInt64; var Cancel: Boolean)
      begin
        Progress(FrameStartProcessed, CommittedOutput, Cancel);
      end;
  Context := TLzmaEncoderContext.Create;
  Context.FUseSdkMtHighHash := UseSdkMtHighHash and (Profile.Algorithm <> 0);
  try
    while Context.Pos < Window.Count do
    begin
      Window.RefillAtBoundary(Context, CommittedOutput);
      StartPos := Context.Pos;
      FrameStartProcessed := Context.Processed;
      Payload := Context.Encode(Window.Data, 0, Window.Count, Props, Profile.FastBytes,
        Profile.CutValue, Profile.MatchFinderKind, False, EnableOptimumWindow, TrialProgress,
        @DecisionCount, True, Window.FinalInput, FrameUnpackLimit);
      Inc(CommittedOutput, LzmaWriteContextLzma2Frame(Context, Destination, Window.Data,
        Payload, StartPos, Context.Pos - StartPos, Props, NeedDictionary, NeedProperties,
        CompressedFrame));
      if (Diagnostics <> nil) and CompressedFrame then
      begin
        Inc(Diagnostics.BlockCount);
        Inc(Diagnostics.FullOptimumDecisionCount, DecisionCount);
        if EnableOptimumWindow then
          Diagnostics.OptimumParserEnabled := True;
      end
      else if Diagnostics <> nil then
        Inc(Diagnostics.CopyFastPathCount, Integer(
          (UInt64(Context.Pos - StartPos) + TLzmaStatefulFrameLimits.MaxPackedSize - 1) div
            TLzmaStatefulFrameLimits.MaxPackedSize));
      ReportProgress(Progress, Context.Processed, CommittedOutput);
    end;
    EndMarker := 0;
    WriteExact(Destination, EndMarker, 1);
    Inc(CommittedOutput);
    ReportProgress(Progress, Context.Processed, CommittedOutput);
  finally
    Context.Free;
  end;
end;

class procedure TLzmaRawEncoder.EncodeLzma2Stream(Source, Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const Progress: TLzma2ProgressEvent; const Diagnostics: PLzma2EncodeDiagnostics;
  const BufferSize: NativeUInt; const MemoryLimit: UInt64);
begin
  EncodeLzma2StreamCore(Source, Destination, Profile, Props, Progress, Diagnostics,
    BufferSize, MemoryLimit, False);
end;

class procedure TLzmaRawEncoder.EncodeLzma2MtWorkerStream(Source, Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const Progress: TLzma2ProgressEvent; const Diagnostics: PLzma2EncodeDiagnostics;
  const BufferSize: NativeUInt; const MemoryLimit: UInt64);
begin
  EncodeLzma2StreamCore(Source, Destination, Profile, Props, Progress, Diagnostics,
    BufferSize, MemoryLimit, True);
end;

destructor TLzmaEncoderContext.Destroy;
begin
  // Join before destroying the range encoder, finder or its shared input window.
  FMatchFinderThread.Free;
  FThreadProgress := nil;
  Encoder.Free;
  SdkFinder.Free;
  Bt4Finder.Free;
  Hc5Finder.Free;
  Hc4Finder.Free;
  GreedyFinder.Free;
  inherited;
end;

class function TLzmaRawEncoder.EncodeGreedyChunk(const Data: TBytes; const Offset, Count: NativeUInt;
  const Props: TLzmaProps; const FastBytes: Integer; const CutValue: UInt32;
  const MatchFinderKind: TLzmaMatchFinderKind; const WriteEndMarker: Boolean;
  const EnableOptimumWindow: Boolean; const Progress: TLzma2ProgressEvent;
  const FullOptimumDecisionCount: PUInt64): TBytes;
var
  Context: TLzmaEncoderContext;
begin
  Context := TLzmaEncoderContext.Create;
  try
    Result := Context.Encode(Data, Offset, Count, Props, FastBytes, CutValue,
      MatchFinderKind, WriteEndMarker, EnableOptimumWindow, Progress,
      FullOptimumDecisionCount);
  finally
    Context.Free;
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
var
  FullOptimumDecisionCount: UInt64;
begin
  Encode(Source, Destination, Profile, Props, WriteEndMarker, 0, 0,
    FullOptimumDecisionCount, Progress);
end;

class procedure TLzmaRawEncoder.Encode(Source: TStream; Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const WriteEndMarker: Boolean; const BufferSize: NativeUInt; const MemoryLimit: UInt64;
  out FullOptimumDecisionCount: UInt64; const Progress: TLzma2ProgressEvent);
var
  ActualThreadCount: Integer;
begin
  // Preserve the existing raw entry points and their serial hash/parser behavior.
  EncodeStreamCore(Source, Destination, Profile, Props, WriteEndMarker, BufferSize,
    MemoryLimit, False, False, FullOptimumDecisionCount, ActualThreadCount, Progress);
end;

class procedure TLzmaRawEncoder.EncodeWithThreads(Source, Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
  const MemoryLimit: UInt64; const RequestedThreadCount: Integer;
  out FullOptimumDecisionCount: UInt64; out ActualThreadCount: Integer;
  const Progress: TLzma2ProgressEvent);
var UseMt: Boolean;
begin
  UseMt := ResolveThreadCount(Profile, RequestedThreadCount) = 2;
  EncodeStreamCore(Source, Destination, Profile, Props, WriteEndMarker, BufferSize,
    MemoryLimit, UseMt, UseMt, FullOptimumDecisionCount, ActualThreadCount, Progress);
end;

{$IFDEF LZMA_MT_QA}
class procedure TLzmaRawEncoder.EncodeMtReference(Source, Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
  const MemoryLimit: UInt64; out FullOptimumDecisionCount: UInt64;
  const Progress: TLzma2ProgressEvent);
var ActualThreadCount: Integer;
begin
  EncodeStreamCore(Source, Destination, Profile, Props, WriteEndMarker, BufferSize,
    MemoryLimit, False, True, FullOptimumDecisionCount, ActualThreadCount, Progress);
end;
{$ENDIF}

class procedure TLzmaRawEncoder.EncodeWithSdkSettings(Source, Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
  const MemoryLimit: UInt64; const RequestedThreadCount: Integer;
  const HashOutBits: UInt32; const ExpectedDataSize: UInt64;
  out FullOptimumDecisionCount: UInt64; out ActualThreadCount: Integer;
  const Progress: TLzma2ProgressEvent);
var UseMt: Boolean;
begin
  UseMt := ResolveThreadCount(Profile, RequestedThreadCount) = 2;
  EncodeStreamCore(Source, Destination, Profile, Props, WriteEndMarker, BufferSize,
    MemoryLimit, UseMt, UseMt, FullOptimumDecisionCount, ActualThreadCount, Progress,
    True, HashOutBits, ExpectedDataSize);
end;

class function TLzmaRawEncoder.RequiredSdkMemoryForInputWithThreads(const Profile: TLzmaEncoderProfile;
  const Props: TLzmaProps; const InputUpperBound: UInt64; const BufferSize: NativeUInt;
  const RequestedThreadCount: Integer; const HashOutBits: UInt32;
  const ExpectedDataSize: UInt64): UInt64;
begin
  Result := RequiredMemoryForInputCore(Profile, Props, InputUpperBound, BufferSize, False,
    True, HashOutBits, ExpectedDataSize);
  if ResolveThreadCount(Profile, RequestedThreadCount) = 2 then
    Result := CheckedMemoryAdd(Result, TLzmaMatchFinderPipeline.RequiredMemory);
end;

class procedure TLzmaRawEncoder.EncodeStreamCore(Source, Destination: TStream;
  const Profile: TLzmaEncoderProfile; const Props: TLzmaProps;
  const WriteEndMarker: Boolean; const BufferSize: NativeUInt;
  const MemoryLimit: UInt64; const UseMatchFinderThread, UseSdkMtHighHash: Boolean;
  out FullOptimumDecisionCount: UInt64; out ActualThreadCount: Integer;
  const Progress: TLzma2ProgressEvent; const SdkFinder: Boolean;
  const HashOutBits: UInt32; const ExpectedDataSize: UInt64);
var
  Context: TLzmaEncoderContext;
  Window: TLzmaEncoderInputWindow;
  EnableOptimumWindow: Boolean;
  DecisionCount: UInt64;
  KernelMemoryLimit, ThreadMemory: UInt64;
begin
  FullOptimumDecisionCount := 0;
  ActualThreadCount := 1;
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'LZMA streaming output is required');
  if (Props.Lc > 8) or (Props.Lp > 4) or (Props.Pb > 4) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA encoder properties');
  KernelMemoryLimit := MemoryLimit;
  if UseMatchFinderThread and (MemoryLimit <> 0) then
  begin
    ThreadMemory := TLzmaMatchFinderPipeline.RequiredMemory;
    // A zero remainder means unlimited to the old allocator; reject it explicitly.
    ValidateMemoryLimit(CheckedMemoryAdd(ThreadMemory, 1), MemoryLimit);
    KernelMemoryLimit := MemoryLimit - ThreadMemory;
  end;
  Window.Initialize(Source, Profile, Props, Progress, BufferSize, True, KernelMemoryLimit, False, SdkFinder, HashOutBits, ExpectedDataSize);
  ValidateMemoryLimit(RequiredMemoryCore(Profile, Props, Window.Capacity, False, SdkFinder, HashOutBits, ExpectedDataSize), KernelMemoryLimit);
  EnableOptimumWindow := (Profile.ParserMode = lpmSdkProfile) and (Profile.Algorithm <> 0);
  Context := TLzmaEncoderContext.Create(Destination);
  try
    Context.FUseMatchFinderThread := UseMatchFinderThread;
    Context.FUseSdkMtHighHash := UseSdkMtHighHash;
    Context.FUseSdkFinder := SdkFinder;
    Context.FSdkHashOutBits := HashOutBits;
    Context.FSdkExpectedDataSize := ExpectedDataSize;
    repeat
      if Context.Encoder <> nil then
        Window.RefillAtBoundary(Context, Context.Encoder.FCommittedOutputSize);
      Context.Encode(Window.Data, 0, Window.Count, Props, Profile.FastBytes,
        Profile.CutValue, Profile.MatchFinderKind, WriteEndMarker, EnableOptimumWindow,
        Progress, @DecisionCount, False, Window.FinalInput);
      FullOptimumDecisionCount := CheckedMemoryAdd(FullOptimumDecisionCount, DecisionCount);
      if Context.FMatchFinderThread <> nil then ActualThreadCount := 2;
    until Window.FinalInput and (Context.Pos = Window.Count);
    if Context.FMatchFinderThread <> nil then Context.FMatchFinderThread.StopAndCheck;
    ReportProgress(Progress, Context.Processed, Context.Encoder.FCommittedOutputSize);
  finally
    Context.Free;
  end;
end;

end.
