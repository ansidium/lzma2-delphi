program Lzma.Tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Threading,
  System.SyncObjs,
  System.IOUtils,
  System.StrUtils,
  System.JSON,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.XML.JUnit,
  Lzma.Test.Process in 'Lzma.Test.Process.pas',
  Lzma.Api in '..\src\Lzma.Api.pas',
  Lzma.Alloc in '..\src\Lzma.Alloc.pas',
  Lzma.Decoder in '..\src\Lzma.Decoder.pas',
  Lzma.Encoder in '..\src\Lzma.Encoder.pas',
  Lzma.EncoderHeuristics in '..\src\Lzma.EncoderHeuristics.pas',
  Lzma.Errors in '..\src\Lzma.Errors.pas',
  Lzma.Lzma in '..\src\Lzma.Lzma.pas',
  Lzma.MatchFinder in '..\src\Lzma.MatchFinder.pas',
  Lzma.MtDec in '..\src\Lzma.MtDec.pas',
  Lzma.PriceTables in '..\src\Lzma.PriceTables.pas',
  Lzma.RangeCoder in '..\src\Lzma.RangeCoder.pas',
  Lzma.Sdk in '..\src\Lzma.Sdk.pas',
  Lzma.Streams in '..\src\Lzma.Streams.pas',
  Lzma.Types in '..\src\Lzma.Types.pas',
  Lzma.Xz in '..\src\Lzma.Xz.pas',
  Lzma.SevenZip in '..\src\Lzma.SevenZip.pas',
  Lzma.XzCrc in '..\src\Lzma.XzCrc.pas',
  Lzma2.Decoder in '..\src\Lzma2.Decoder.pas',
  Lzma2.Encoder in '..\src\Lzma2.Encoder.pas',
  Lzma.CliPaths in '..\src\Lzma.CliPaths.pas';

type
  TXzTestIndexRecord = record
    UnpaddedSize: UInt64;
    UnpackSize: UInt64;
  end;

  TSevenZipTestCoder = (sztcLzma, sztcLzma2, sztcUnsupported);

  TMatchFinderTraceResult = record
    TraceId: string;
    Finder: string;
    Expected: TLzmaMatchArray;
    Actual: TLzmaMatchArray;
  end;

  TWriteFailStream = class(TStream)
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TReadFailStream = class(TStream)
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TGenericReadFailStream = class(TStream)
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TGenericWriteFailStream = class(TStream)
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TProbeBoundReadStream = class(TBytesStream)
  private
    FProbeReadLimit: UInt64;
    FProbeReadBytes: UInt64;
    FAfterBackwardSeek: Boolean;
  public
    constructor Create(const Data: TBytes; const ProbeReadLimit: UInt64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TStreamingProbeWriteStream = class(TMemoryStream)
  private
    FSlowWorkerRunning: PInteger;
    FObservedWriteDuringSlowWorker: PInteger;
  public
    constructor Create(const SlowWorkerRunning: PInteger; const ObservedWriteDuringSlowWorker: PInteger);
    function Write(const Buffer; Count: Longint): Longint; override;
{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
{$ENDIF}
  end;

  TOutputStartedProbeWriteStream = class(TMemoryStream)
  private
    FMaxWriteCount: NativeInt;
    FOutputStarted: PInteger;
    FWriteCallCount: Integer;
  public
    constructor Create(const OutputStarted: PInteger);
    function Write(const Buffer; Count: Longint): Longint; override;
{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
{$ENDIF}
    property MaxWriteCount: NativeInt read FMaxWriteCount;
    property WriteCallCount: Integer read FWriteCallCount;
  end;

  TReadBeforeOutputProbeStream = class(TBytesStream)
  private
    FOutputStarted: PInteger;
    FReadBeforeOutput: UInt64;
  public
    constructor Create(const Data: TBytes; const OutputStarted: PInteger);
    function Read(var Buffer; Count: Longint): Longint; override;
    property ReadBeforeOutput: UInt64 read FReadBeforeOutput;
  end;

  TNonSeekableReadStream = class(TStream)
  private
    FData: TBytes;
    FPosition: Integer;
    FSeekCount: Integer;
    FDestroyedFlag: PBoolean;
  public
    constructor Create(const Data: TBytes; const DestroyedFlag: PBoolean = nil);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property SeekCount: Integer read FSeekCount;
  end;

  TDestroyTrackingMemoryStream = class(TMemoryStream)
  private
    FDestroyedFlag: PBoolean;
  public
    constructor Create(const DestroyedFlag: PBoolean);
    destructor Destroy; override;
  end;

  TTrackingSeqInStream = class(TInterfacedObject, ILzmaSeqInStream)
  private
    FData: TBytes;
    FEofReached: Boolean;
    FFirstRequestedCount: SizeT;
    FMaxRequestedCount: SizeT;
    FOffset: NativeInt;
    FReadCallCount: Integer;
  public
    constructor Create(const Data: TBytes);
    function FullyConsumed: Boolean;
    function Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
    property EofReached: Boolean read FEofReached;
    property FirstRequestedCount: SizeT read FFirstRequestedCount;
    property MaxRequestedCount: SizeT read FMaxRequestedCount;
    property ReadCallCount: Integer read FReadCallCount;
  end;

  TTrackingSeqOutStream = class(TInterfacedObject, ILzmaSeqOutStream)
  private
    FBuffer: TMemoryStream;
    FInput: TTrackingSeqInStream;
    FMaxWriteCount: SizeT;
    FWroteBeforeInputDrained: Boolean;
    FWroteBeforeInputEof: Boolean;
    FWriteCallCount: Integer;
  public
    constructor Create(const Input: TTrackingSeqInStream);
    destructor Destroy; override;
    function Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
    function ToBytes: TBytes;
    property MaxWriteCount: SizeT read FMaxWriteCount;
    property WroteBeforeInputDrained: Boolean read FWroteBeforeInputDrained;
    property WroteBeforeInputEof: Boolean read FWroteBeforeInputEof;
    property WriteCallCount: Integer read FWriteCallCount;
  end;

  TPartialSeqOutStream = class(TInterfacedObject, ILzmaSeqOutStream)
  private
    FBuffer: TMemoryStream;
    FCallCount: Integer;
    FFailCode: SRes;
    FFailOnCall: Integer;
    FMaxBytesPerWrite: SizeT;
  public
    constructor Create(const MaxBytesPerWrite: SizeT; const FailOnCall: Integer = 0;
      const FailCode: SRes = SZ_OK);
    destructor Destroy; override;
    function Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
    function ToBytes: TBytes;
  end;

  TFailingSdkProgress = class(TInterfacedObject, ILzmaCompressProgress)
  private
    FCalls: Integer;
    FResultCode: SRes;
  public
    constructor Create(const ResultCode: SRes);
    function Progress(const InSize, OutSize: UInt64): SRes;
    property Calls: Integer read FCalls;
  end;

  [TestFixture]
  TLzma2NativeTests = class
  private
    class function BytesOfSize(const Size: Integer): TBytes; static;
    class function HighEntropyBytes(const Size: Integer): TBytes; static;
    class function RepeatingBytes(const Size: Integer): TBytes; static;
    class function CrossToolDir: string; static;
    class function EnvToolPath(const EnvName: string): string; static;
    class procedure WriteAllBytes(const FileName: string; const Data: TBytes); static;
    class function ReadAllBytesFromFile(const FileName: string): TBytes; static;
    class procedure DeleteFileIfExists(const FileName: string); static;
    class procedure SkipExternalTool(const TestName: string; const EnvName: string); static;
    class procedure AssertBytesEqual(const Expected: TBytes; const Actual: TBytes; const Message: string); static;
    class procedure AppendByte(var Target: TBytes; const Value: Byte); static;
    class procedure AppendBytes(var Target: TBytes; const Source: TBytes); static;
    class procedure AppendZeroes(var Target: TBytes; const Count: NativeUInt); static;
    class function BuildTestXzHeader(const CheckId: Byte): TBytes; static;
    class function BuildTestXzRawBlockHeader(const Flags: Byte; const Body: TBytes): TBytes; static;
    class function BuildTestXzBlock(const Data: TBytes; const Options: TLzma2Options;
      out RecordInfo: TXzTestIndexRecord; const StorePackedSize: Boolean = True;
      const ExtraPayloadByte: Integer = -1; const StoreUnpackedSize: Boolean = True): TBytes; static;
    class function BuildTestXzIndexAndFooter(const Records: array of TXzTestIndexRecord;
      const CheckId: Byte): TBytes; static;
    class procedure AppendSevenZipTestNumber(var Target: TBytes; const Value: UInt64); static;
    class function BuildTestSevenZipArchiveFromPayloadAndHeader(const Payload, Header: TBytes): TBytes; static;
    class procedure PatchTestSevenZipNextHeaderByte(var Archive: TBytes; const Pattern: TBytes;
      const Occurrence, PatchOffset: Integer; const XorMask: Byte); static;
    class function BuildTestSevenZipHeaderBytes(const PackSize: UInt64; const PackCrc: UInt32;
      const UnpackSize: UInt64; const UnpackCrc: UInt32; const Coder: TSevenZipTestCoder;
      const CoderProperties: TBytes; const FileName: string): TBytes; static;
    class function BuildTestSevenZipLzmaArchive(const Data: TBytes; const FileName: string;
      const Options: TLzma2Options): TBytes; static;
    class function BuildTestSevenZipEncodedHeaderArchive(const Data: TBytes; const FileName: string;
      const HeaderCoder: TSevenZipTestCoder; const Options: TLzma2Options): TBytes; static;
    class function BuildTestSevenZipMultiFolderArchive(const FirstData, SecondData: TBytes;
      const Coder: TSevenZipTestCoder; const Options: TLzma2Options): TBytes; static;
    class function BuildTestSevenZipSolidArchive(const FirstData, SecondData: TBytes;
      const Coder: TSevenZipTestCoder; const Options: TLzma2Options): TBytes; static;
    class procedure RoundTrip(const Container: TLzma2Container; const Check: TLzma2Check; const Data: TBytes); static;
  public
    [Test]
    [Category('unit')]
    procedure DictionaryPropertyGrid;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure DictionaryPropertyRejectsAboveMaxStrict;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure Crc32XzKnownVectorAndSplitUpdate;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure Crc64XzKnownVectorAndSplitUpdate;
    [Test]
    [Category('unit')]
    procedure GreedyMatchFinderFindsLongestWithinDictionary;
    [Test]
    [Category('unit')]
    procedure GreedyMatchFinderReturnsIncreasingPairs;
    [Test]
    [Category('unit')]
    procedure GreedyMatchFinderReportsSdkTwoByteLowHashMatch;
    [Test]
    [Category('unit')]
    procedure GreedyMatchFinderHonorsCutValue;
    [Test]
    [Category('unit')]
    procedure HashChain4MatchFinderReturnsLowHashAndMainMatches;
    [Test]
    [Category('unit')]
    procedure HashChain4AndBinaryTree4ExposeLowHashMatchThroughFourByteCollision;
    [Test]
    [Category('unit')]
    procedure HashChain4AndBinaryTree4SkipTailBelowFourBytesLikeSdk;
    [Test]
    [Category('unit')]
    procedure HashChain5MatchFinderUsesFiveByteMainHash;
    [Test]
    [Category('unit')]
    procedure HashChain5MatchFinderUsesSdkCrcHashShape;
    [Test]
    [Category('unit')]
    procedure HashChain5MatchFinderSkipsTailBelowFiveBytesLikeSdk;
    [Test]
    [Category('unit')]
    procedure HashChain5MatchFinderHonorsDictionaryLimit;
    [Test]
    [Category('unit')]
    procedure HashChain4MatchFinderUsesDictionaryCyclicChainStorage;
    [Test]
    [Category('unit')]
    procedure HashChain5MatchFinderUsesDictionaryCyclicChainStorage;
    [Test]
    [Category('unit')]
    procedure HashChain4SkipRangeMonotonicMatchesClassicInsertRange;
    [Test]
    [Category('unit')]
    procedure HashChain4SkipRangeMonotonicMarksSkippedPositionsInserted;
    [Test]
    [Category('unit')]
    procedure HashChain5SkipRangeMonotonicMatchesClassicInsertRange;
    [Test]
    [Category('unit')]
    procedure HashChain5SkipRangeMonotonicMarksSkippedPositionsInserted;
    [Test]
    [Category('unit')]
    procedure BinaryTree4SkipRangeMonotonicMatchesClassicInsertRange;
    [Test]
    [Category('unit')]
    procedure BinaryTree4MatchFinderReturnsLowHashAndTreeMatches;
    [Test]
    [Category('unit')]
    procedure BinaryTree4MatchFinderStartsFromNewestHashHead;
    [Test]
    [Category('unit')]
    procedure BinaryTree4MatchFinderKeepsOlderTreeReachableFromNewestHead;
    [Test]
    [Category('unit')]
    procedure BinaryTree4MatchFinderUsesDictionaryCyclicSonStorage;
    [Test]
    [Category('unit')]
    procedure BinaryTree4MatchFinderHonorsDictionaryLimit;
    [Test]
    [Category('unit')]
    procedure HashChain4MatchFinderReadMatchesInsertsCurrentPosition;
    [Test]
    [Category('unit')]
    procedure BinaryTree4MatchFinderReadMatchesInsertsCurrentPosition;
    [Test]
    [Category('unit')]
    procedure MatchFindersIgnoreOutOfRangePositions;
    [Test]
    [Category('unit')]
    procedure MatchFinderReadMatchesIsIdempotent;
    [Test]
    [Category('unit')]
    procedure HashChain4MatchesSdkReferenceTrace;
    [Test]
    [Category('unit')]
    procedure HashChain5MatchesSdkReferenceTrace;
    [Test]
    [Category('unit')]
    procedure BinaryTree4MatchesSdkReferenceTrace;
    [Test]
    [Category('unit')]
    procedure MatchFinderSdkReferenceTraceArtifactIsWritten;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2RoundTripsCopyChunks;
    [Test]
    [Category('unit')]
    procedure LevelOneWritesCompressedChunks;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure Lzma2CompressedChunksCanReusePropsAfterFirstChunk;
    [Test]
    [Category('unit')]
    procedure Lzma2CompressedOptionsUseSdkTwoMiBChunkLimit;
    [Test]
    [Category('unit')]
    procedure GreedyEncoderCompressesRepeatingData;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaProfileMatchesSdkDefaults;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaProfileMatchesSdkMatchFinderTuning;
    [Test]
    [Category('unit')]
    procedure PublicOptionsExposeParityAndDiagnosticsDefaults;
    [Test]
    [Category('unit')]
    procedure SdkFacadeLzmaPropsNormalizeAndWriteMatchRawProps;
    [Test]
    [Category('unit')]
    procedure SdkSeqInStreamMapsGenericExceptionToReadSRes;
    [Test]
    [Category('unit')]
    procedure SdkSeqOutStreamMapsGenericExceptionToWriteSRes;
    [Test]
    [Category('unit')]
    procedure SdkSystemAllocatorAllocatesAndFreesMemory;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeRawLzmaReferenceStyleEncodeDecodeRoundTrip;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzmaEncoderUsesSeqStreamAdapterPath;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzmaEncoderStreamsEndMarkerPath;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzmaEncoderSupportsPartialSeqOutWrites;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzmaDecoderSupportsPartialSeqOutWrites;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzmaEncoderPropagatesSeqOutSRes;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzmaDecoderPropagatesSeqOutSRes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeRawLzma2ReferenceStyleEncodeDecodeRoundTrip;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2EncoderPreservesCustomLcLpPbProps;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzma2EncoderRejectsInvalidLcLpProps;
    [Test]
    [Category('unit')]
    procedure SdkFacadeLzma2PropsNormalizeBlockThreadCounts;
    [Test]
    [Category('unit')]
    procedure SdkFacadePropsNormalizeSdkDependencyVectors;
    [Test]
    [Category('unit')]
    procedure SdkFacadeProgressPreservesCallbackSRes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2EncoderHonorsBlockSize;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzmaDecoderLifecycleDecodeToBuf;
    [Test]
    [Category('unit')]
    procedure SdkFacadeLzmaDecoderLifecycleDecodeToBufEmitsFromPartialKnownSizeInput;
    [Test]
    [Category('unit')]
    procedure SdkFacadeLzmaDecoderLifecycleDecodeToDicEmitsFromPartialKnownSizeInput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzmaDecoderLifecycleKnownSizeTrailingBytes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzmaDecoderLifecycleDecodeToDicWithEndMarker;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzmaDecoderRejectsOversizedPropsBuffer;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzmaDecoderLifecycleTruncatedInputNeedsMoreInput;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzma2DecoderLifecycleRejectsInvalidProperty;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2DecoderLifecycleDecodeToBufAndDic;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2DecoderLifecyclePartialInputAndTrailingBytes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2CompressedDecoderLifecyclePartialInputAndTrailingBytes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2ParseStopsAtEofBeforeTrailingBytes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2ParseDoesNotMaterializeOutput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2ParseUsesFrameParserOnly;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2EncoderDoesNotSnapshotFullInput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2CompressedEncoderDoesNotSnapshotFullInput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2DecoderDoesNotSnapshotFullInput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2DecoderSupportsPartialSeqOutWrites;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzma2DecoderPropagatesSeqOutSRes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SdkFacadeLzma2EncoderSupportsPartialSeqOutWrites;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure SdkFacadeLzma2EncoderPropagatesSeqOutSRes;
    [Test]
    [Category('unit')]
    procedure EncodeDiagnosticsReportsSdkProfileOptimumWindowEnabled;
    [Test]
    [Category('unit')]
    procedure EncodeDiagnosticsDoesNotClaimOptimumForCopyOnlySdkProfileRawLzma2;
    [Test]
    [Category('unit')]
    procedure RawEncoderReportsActualFullOptimumDecisionCount;
    [Test]
    [Category('unit')]
    procedure RawEncoderFullSdkOptimumStateScaffoldIsPresent;
    [Test]
    [Category('unit')]
    procedure FullOptimumStateTracksSdkReadMoveAndCommitOffsets;
    [Test]
    [Category('unit')]
    procedure FullOptimumStateDisabledInitDoesNotAllocateWindow;
    [Test]
    [Category('unit')]
    procedure FullOptimumBeginDecisionUsesCachedReadWhenAdditionalOffsetIsPending;
    [Test]
    [Category('unit')]
    procedure FullOptimumStateCachesPendingMatchBuffer;
    [Test]
    [Category('unit')]
    procedure FullOptimumBackwardQueuesReplayState;
    [Test]
    [Category('unit')]
    procedure FullOptimumStateIsWiredToMatchReadAndEncodedCommit;
    [Test]
    [Category('unit')]
    procedure FullOptimumStateRefreshCountersAreAdditionalOffsetGated;
    [Test]
    [Category('unit')]
    procedure FullOptimumEncoderWiresRefreshCountersAfterCommit;
    [Test]
    [Category('unit')]
    procedure FullOptimumParserBranchIsIsolatedFromFastParser;
    [Test]
    [Category('unit')]
    procedure SdkProfileFullParserTransitionRejectsGetOptimumFastBackend;
    [Test]
    [Category('unit')]
    procedure PeriodicFastPathCannotMasqueradeAsFullSdkParserParity;
    [Test]
    [Category('unit')]
    procedure EncodeDiagnosticsKeepsOptimumWindowDisabledForHighSpeedParser;
    [Test]
    [Category('unit')]
    procedure EncodeDiagnosticsReflectsPublicTuningOverrides;
    [Test]
    [Category('unit')]
    procedure PriceTablesMatchSdkProbPrices;
    [Test]
    [Category('unit')]
    procedure PriceTablesMatchSdkInitialLenPrices;
    [Test]
    [Category('unit')]
    procedure LengthPriceEncoderUsesFastBytesTableSizeAndLookup;
    [Test]
    [Category('unit')]
    procedure DistancePriceTablesMatchSdkInitialValues;
    [Test]
    [Category('unit')]
    procedure MatchDistancePriceUsesActualDistanceAndLengthState;
    [Test]
    [Category('unit')]
    procedure LiteralPriceTablesMatchSdkInitialValues;
    [Test]
    [Category('unit')]
    procedure RepAndMatchChoicePricesMatchSdkInitialValues;
    [Test]
    [Category('unit')]
    procedure OptimumLiteralVsShortRepUsesSdkPrices;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumShortRepVsLiteralRejectsOverflowingShortRepPrice;
    [Test]
    [Category('unit')]
    procedure OptimumRepVsMatchUsesSdkPrices;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumRepVsMatchRejectsOverflowingRepPrice;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumRepVsMatchRejectsOverflowingMatchBackDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumRepVsMatchRejectsOneByteNormalMatchLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumRepVsMatchRejectsOneByteRepLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumRepVsMatchRejectsZeroMatchDistance;
    [Test]
    [Category('unit')]
    procedure OptimumRepVsMatchFixtureShowsPriceBeatsFastHeuristic;
    [Test]
    [Category('unit')]
    procedure OptimumLiteralThenMatchUsesSdkPrices;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenMatchRejectsOverflowingLookaheadPrice;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenMatchRejectsOverflowingCurrentMatchBackDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenMatchRejectsOverflowingNextMatchBackDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenMatchRejectsOneByteNextMatchLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenMatchRejectsOneByteCurrentMatchLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenMatchRejectsZeroNextMatchDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenMatchRejectsZeroCurrentMatchDistance;
    [Test]
    [Category('unit')]
    procedure OptimumLiteralThenRepUsesSdkPrices;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenRepRejectsOverflowingLookaheadPrice;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenRepRejectsOverflowingCurrentMatchBackDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenRepRejectsOneByteNextRepLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenRepRejectsOneByteCurrentMatchLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralThenRepRejectsZeroCurrentMatchDistance;
    [Test]
    [Category('unit')]
    procedure OptimumMatchLiteralRep0UsesSdkPrices;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsOverflowingLookaheadPrice;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsOverflowingFirstMatchDecisionBackDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsOverflowingCurrentMatchDecisionBackDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsOneByteFirstMatchLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsOneByteRepLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsOneByteCurrentMatchLength;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsZeroFirstMatchDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0RejectsZeroCurrentMatchDistance;
    [Test]
    [Category('unit')]
    procedure OptimumPrepareNodesClearsPathsAndSeedsStartPrice;
    [Test]
    [Category('unit')]
    procedure OptimumPrepareNodesSeedsStartStateAndReps;
    [Test]
    [Category('unit')]
    procedure OptimumMatchCandidatesUseSdkPairDistancesAcrossLengths;
    [Test]
    [Category('unit')]
    procedure OptimumRepCandidatesSeedBeforeNormalMatchesAndKeepTie;
    [Test]
    [Category('unit')]
    procedure OptimumSeedCandidatesIncludePreparedStartPrice;
    [Test]
    [Category('unit')]
    procedure OptimumSeedCandidatesRejectOverflowingStartPrice;
    [Test]
    [Category('unit')]
    procedure OptimumSeedMatchCandidatesRejectOverflowingBackDistance;
    [Test]
    [Category('unit')]
    procedure OptimumSeedMatchCandidatesRejectZeroBackDistance;
    [Test]
    [Category('unit')]
    procedure OptimumLiteralCandidateRelaxesFromPreviousNodeAndKeepsTie;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumLiteralCandidateRejectsOverflowingPreviousPrice;
    [Test]
    [Category('unit')]
    procedure OptimumShortRepCandidateRelaxesFromPreviousNodeAndKeepsTie;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumShortRepCandidateRejectsOverflowingPreviousPrice;
    [Test]
    [Category('unit')]
    procedure OptimumMatchCandidatesRelaxFromPreviousNodeAndKeepTie;
    [Test]
    [Category('unit')]
    procedure OptimumMatchCandidatesRejectOverflowingPreviousPrice;
    [Test]
    [Category('unit')]
    procedure OptimumRelaxMatchCandidatesRejectOverflowingBackDistance;
    [Test]
    [Category('unit')]
    procedure OptimumRelaxMatchCandidatesRejectZeroBackDistance;
    [Test]
    [Category('unit')]
    procedure OptimumRepCandidatesRelaxFromPreviousNodeAndKeepTie;
    [Test]
    [Category('unit')]
    procedure OptimumRepCandidatesRejectOverflowingPreviousPrice;
    [Test]
    [Category('unit')]
    procedure OptimumMatchLiteralRep0CandidateRelaxesSdkExtraPathAndKeepsTie;
    [Test]
    [Category('unit')]
    procedure OptimumRepLiteralRep0CandidateRelaxesSdkExtraPathAndKeepsTie;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0CandidateRejectsOverflowingPreviousPrice;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0CandidateRejectsOverflowingFirstMatchBackDistance;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumMatchLiteralRep0CandidateRejectsZeroFirstMatchDistance;
    [Test]
    [Category('unit')]
    procedure OptimumRelaxCandidatesRejectUnreachablePreviousNode;
    [Test]
    [Category('unit')]
    procedure OptimumRelaxCandidatesCarryStateAndRepsAcrossParserNodes;
    [Test]
    [Category('unit')]
    procedure OptimumWindowReplaysCheaperTwoStepPathOverDirectMatch;
    [Test]
    [Category('unit')]
    procedure OptimumWindowRelaxesLiteralThenMatchPath;
    [Test]
    [Category('unit')]
    procedure OptimumWindowUsesReachedNodeStateForLaterProbabilityInputs;
    [Test]
    [Category('unit')]
    procedure OptimumWindowResolvesRepLensFromReachedNodeReps;
    [Test]
    [Category('unit')]
    procedure OptimumWindowResolvesLiteralFromReachedNodeContext;
    [Test]
    [Category('unit')]
    procedure OptimumWindowRelaxesShortRepFromResolvedRepLens;
    [Test]
    [Category('unit')]
    procedure OptimumWindowRejectsShortRepOutsideLiteralState;
    [Test]
    [Category('unit')]
    procedure OptimumWindowRelaxesLiteralRep0ExtraPath;
    [Test]
    [Category('unit')]
    procedure OptimumWindowSuppressesLiteralRep0WhenLiteralIsPricedOut;
    [Test]
    [Category('unit')]
    procedure OptimumWindowRelaxesMatchLiteralRep0ExtraPath;
    [Test]
    [Category('unit')]
    procedure OptimumWindowRelaxesRepLiteralRep0ExtraPath;
    [Test]
    [Category('unit')]
    procedure OptimumWindowSelectsExtendedReplayTargetWhenItBeatsBaseline;
    [Test]
    [Category('unit')]
    procedure OptimumWindowPrunesNormalMatchesCoveredByRep0Length;
    [Test]
    [Category('unit')]
    procedure EncoderPathWiresMatchLiteralRep0ThroughOptimumRelaxPrimitive;
    [Test]
    [Category('unit')]
    procedure EncoderPathWiresShortRepLiteralThroughOptimumRelaxPrimitive;
    [Test]
    [Category('unit')]
    procedure EncoderPathWiresRepMatchThroughOptimumRelaxPrimitive;
    [Test]
    [Category('unit')]
    procedure EncoderPathDoesNotBypassRepMatchWithFastHeuristic;
    [Test]
    [Category('unit')]
    procedure EncoderPathWiresLiteralLookaheadThroughOptimumRelaxPrimitive;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure ArtifactValidatorRequiresReleasePerformanceRatioEvidence;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure ArtifactValidatorRequiresEncodeTuningDiagnosticsEvidence;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure DocsAndOptimizationPlanDescribeActiveNativeEncoder;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure FastLzma2StyleBenchmarkContractIsDocumented;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure PerformanceRunnerWritesDataOnlyBenchmarkArtifacts;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure PerformanceValidatorEnforcesDataOnlyArtifacts;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure PerformanceSummaryRequiresBenchmarkMetadata;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure CliAndVclUseAcceptanceRatioConvention;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure VclToolShowsMtDiagnosticsAndUsesTemporaryOutput;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure VclGuiSupportsPublicInstallerLanguageBaseline;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure CiBuildsIndependentMsBuildProjectsInParallel;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure GitHubWorkflowRunsReleaseCiMode;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure DUnitXCategoryTiersAreDeclaredAndQuickFiltered;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    procedure FixtureGenerationUsesContentAddressedCacheEvidence;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure CliSafeStoredOutputNameRejectsUnsafeStoredNames;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure CliSafeStoredRelativePathPreservesOnlySafeArchivePaths;
    [Test]
    [Category('unit')]
    [Category('perf-smoke')]
    [Category('perf-release')]
    procedure ReleasePerformanceRequiresSixteenThreadMtEncodeEvidence;
    [Test]
    [Category('unit')]
    procedure EncoderPathSeedsOptimumNodesWithCurrentStateAndReps;
    [Test]
    [Category('unit')]
    procedure OptimumPathReplaysLiteralThenMatchAdditionalOffset;
    [Test]
    [Category('unit')]
    procedure OptimumPathReplaysPrev1LiteralAsFirstCommand;
    [Test]
    [Category('unit')]
    procedure OptimumReplayPathReturnsMatchLiteralRep0Commands;
    [Test]
    [Category('unit')]
    procedure OptimumReplayPathReturnsRepLiteralRep0Commands;
    [Test]
    [Category('unit')]
    procedure OptimumReplaySdkBackwardExposesOptCurOptEndQueueState;
    [Test]
    [Category('unit')]
    procedure OptimumPathReplaysSdk26ExtraBranches;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsUnreachableEndNode;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsUnreachableIntermediateNode;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsUnreachablePrev1LiteralNode;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPrev1LiteralRootNonLiteralBackPrev2;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPrev1LiteralRootMultiByteLiteralCommand;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenMismatchedPosPrev;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenMismatchedBackPrev;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsExtraPathNonRep0BackPrev;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsExtraPathWithPrev1LiteralFlag;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenExtraRep0WithBackPrev2Set;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenExtraRep0WithPosPrev2Set;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenExtraOneWithNonLiteralBack;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenExtraOneWithBackPrev2Set;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenExtraOneWithPosPrev2Set;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayPathRejectsInvalidCompactExtraMetadata;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsMultiByteLiteralRootCommand;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsSingleByteMatchRootCommand;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsIntermediateMultiByteLiteralCommand;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenMultiByteLiteralCommand;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsPathLenSingleByteMatchCommand;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure OptimumReplayRejectsUnreachableStartNode;
    [Test]
    [Category('unit')]
    procedure FastParserLookaheadCacheReusesReadMatchesOnce;
    [Test]
    [Category('unit')]
    procedure FastParserLookaheadCacheKeepsMultipleAdditionalOffsets;
    [Test]
    [Category('unit')]
    procedure FastParserRepThresholdsUseSdkReducedDistance;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaPropertiesAlignDictionary;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaAllowsSdkLcLpCombination;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure LzmaStandaloneEncodeHonorsCustomLcLpPbOptions;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2CompressedChunkWritesCustomLcLpPbProp;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure Lzma2OptionsRejectInvalidLcLpPbCombination;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaChunkEncoderAcceptsHashChain4FinderKind;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaChunkEncoderAcceptsBinaryTree4FinderKind;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaEncoderOptInWindowPathRoundTripsAndWiresDriver;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaEncoderOptInWindowUsesEffectiveFastBytesBounds;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaGreedyEncoderRoundTrips;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaKnownSizeAboveUInt32ReachesDecoder;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaStreamEncoderUsesSinkBackedRangeOutput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaStreamEncoderUsesProfileMatchFinder;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaStreamProgressReportsCommittedOutput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaStreamFinalCancellationPrecedesRangeFlush;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaEndMarkerRoundTripsUnknownSize;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzmaEndMarkerRejectsDirtyTail;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzmaEndMarkerInsideLzma2ChunkFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure LzmaStandaloneRoundTripsKnownSize;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure LzmaStandaloneEncodeCanWriteUnknownSizeEndMarker;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure LzmaStandaloneDecodesUnknownSizeEndMarker;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneEncodeRejectsInputOverMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneDecodeRejectsPackedInputOverMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneRejectsShortHeader;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneRejectsInvalidProps;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneRejectsTrailingBytesAfterEndMarker;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneRejectsKnownSizeTruncation;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneRejectsUnpackSizeMismatch;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure LzmaStandaloneRejectsUnknownSizeWithoutEndMarker;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure LzmaStandaloneEncodeCancellation;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure LzmaStandaloneDecodeCancellation;
    [Test]
    [Category('unit')]
    procedure LevelFiveSingleThreadRoundTripsThroughProfileFinder;
    [Test]
    [Category('unit')]
    procedure LevelFiveMultiThreadRoundTripsThroughProfileFinder;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2CopyModeIgnoresEncoderDictionaryMemoryLimit;
    [Test]
    [Category('unit')]
    procedure SingleThreadedRawMemoryLimitIncludesMatchFinder;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzmaInvalidPropsFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2DecodeReadFailureRaisesTypedReadError;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2EncodeReadFailureRaisesTypedReadError;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2RoundTripsWithNonSeekableStreams;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2EncodeCancellation;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzma2TruncatedCopyChunkFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzma2InvalidControlFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzma2CompressedChunkWithoutPropsFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzma2InvalidLcLpPropsFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzma2CorruptRangeFlushTailFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure RawLzma2CorruptExactRangeTailFails;
    [Test]
    [Category('unit')]
    procedure MtDecodeStreamsReadyUnitsBeforeSlowWorkersFinish;
    [Test]
    [Category('unit')]
    procedure MtDecodeWriteFailureSignalsWorkersToCancel;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeUsesIndependentResetChunks;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeFallsBackForSingleIndependentStream;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeFallsBackForTinyPackedIndependentUnits;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeFallsBackForHighlyExpandedTinyPackedUnits;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeCancellationDoesNotWriteOutput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeFallsBackWhenOutputExceedsMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeChecksMemoryLimitBeforePayloadSnapshot;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzma2MtDecodeWriteFailurePropagates;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzRoundTripsAllChecks;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzDeltaFilterFailsUnsupported;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzBcjFilterFailsUnsupported;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzFilterChainFailsUnsupported;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzUnsupportedStreamFlagsFailTyped;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzUnsupportedBlockFlagsFailTyped;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzInvalidLzma2FilterPropsFailTyped;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzIndexRejectsZeroUnpaddedBlockRecord;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipSingleFileRoundTrips;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipLzmaCoderSingleFileDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipEncodedHeaderLzma2SingleFileDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipEncodedHeaderLzmaSingleFileDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipEncodedHeaderUnsupportedCoderFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipUnsupportedNormalHeaderCoderFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipMultiCoderFolderFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipPackStreamCrcMismatchFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipPayloadUnsupportedCoderFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipAlternativeCoderFlagsFailClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipReservedCoderFlagFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipUnreferencedPackStreamFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipMissingFileNamesFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipMissingNameTerminatorFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipOddUtf16NamePayloadFailsClosed;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipFolderCrcMismatchFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipSolidFileCrcMismatchFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipMultiFolderLzma2ArchiveExtractsAllEntries;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipMultiFolderLzmaArchiveExtractsAllEntries;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipMultiFileLzma2EncodeListsAndExtractsAllEntries;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipMultiFileLzmaEncodeListsAndExtractsAllEntries;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipUtf16NamesRoundTrip;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipMultiFileFailsSingleStreamDecode;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipSolidLzma2SubstreamsExtractAsSeparateFiles;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipSolidLzmaSubstreamsExtractAsSeparateFiles;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure SevenZipDecodeLeavesSourceAfterArchive;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure SevenZipHeaderCrcCorruptionFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzRoundTripsWithNonSeekableStreams;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzEncodeProgressIsMonotonic;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzEncodeCancellation;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMultiBlockDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMultiBlockEncodeDiagnosticsAggregatesRawFastPathCounts;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMultiBlockEncodeDiagnosticsReportsTuningForEmptyInput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzEncodeBlockSizeProducesIndependentBlocks;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeUsesIndependentBlocks;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeDoesNotReadAllPayloadsBeforeFirstOutput;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeWriteFailurePropagatesAndPreservesDiagnostics;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeUsesIndexPackedSizeWhenHeaderOmitsIt;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeUsesIndexUnpackedSizeWhenHeaderOmitsIt;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutPackedSize;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutUnpackedSize;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeFallsBackWhenOutputExceedsMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeChecksMemoryLimitBeforePayloadSnapshot;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzMtDecodeUsesNonzeroMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzBlockWithoutPackedSizeDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzPackedBlockRejectsRawTrailingBytes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzDecodeAvoidsFullArchiveMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzEncodeAvoidsFullSourceMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzDecodeRejectsDictionaryOverMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzDecodeRejectsMaxDictionaryPropertyOverMemoryLimit;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzDecodeCancellation;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzConcatenatedStreamsDecode;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzConcatenatedStreamsWithMixedChecksFallBackFromMt;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzStreamPaddingDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzStreamPaddingCancellation;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzBadStreamPaddingFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure CorruptedSecondXzBlockCheckFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure CorruptedXzCheckFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzTruncatedFooterFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    [Category('fuzz')]
    procedure CorruptXzRegressionFixturesFailWithExpectedErrors;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure XzWriteFailurePropagates;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('fuzz')]
    procedure XzUnsupportedCheckFails;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawTrailingBytesFail;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure SevenZipCompressedXzDecodes;
    [Test]
    [Category('unit')]
    [Category('compat')]
    procedure FixtureManifestsHaveSha256Metadata;
    [Test]
    [Category('unit')]
    [Category('container')]
    procedure RawLzmaSdkCorpusFixturesDecode;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('perf-release')]
    procedure RawLzmaSdkReleaseCorpusFixturesDecode;
    [Test]
    [Category('unit')]
    procedure AsyncApiRoundTripsRaw;
    [Test]
    [Category('unit')]
    procedure DecompressAsyncReturnsBeforeProgressCallbackCompletes;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure CrossToolDelphiXzIsAcceptedBySevenZip;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure CrossToolDelphiSevenZipIsAcceptedBySevenZip;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure CrossToolSevenZip7zDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure CrossToolSevenZipXzDecodes;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure CrossToolXzUtilsMatrixDecodes;
    [Test]
    [Category('unit')]
    [Category('compat')]
    procedure CrossToolSdkLzmaDecodesWithDelphi;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure CrossToolDelphiRawLzmaDecodesWithSdk;
    [Test]
    [Category('unit')]
    [Category('container')]
    [Category('compat')]
    procedure CrossToolDelphiRawLzmaEndMarkerDecodesWithSdk;
    [Test]
    [Category('unit')]
    procedure MultiThreadedRawMatchesSingleThreadOutput;
    [Test]
    [Category('unit')]
    [Category('perf-release')]
    [Category('soak')]
    procedure MultiThreadedRawLargeChunksRoundTrip;
    [Test]
    [Category('unit')]
    [Category('perf-release')]
    procedure MultiThreadedRawLargeChunkCopyFallbackSplits;
    [Test]
    [Category('unit')]
    procedure HighEntropyRawEncodeBypassesGreedyAttempt;
    [Test]
    [Category('unit')]
    procedure MixedBenchmarkCorpusRawEncodeCompressesRepeatingStripes;
    [Test]
    [Category('unit')]
    procedure MixedBenchmarkCorpusRawMtEncodeCompressesRepeatingStripes;
    [Test]
    [Category('unit')]
    procedure IncompressibleProbeDoesNotCopyCompressibleTail;
    [Test]
    [Category('unit')]
    procedure PeriodicRawEncodeUsesFastPath;
    [Test]
    [Category('unit')]
    [Category('fuzz')]
    procedure PeriodicFastPathRejectsChunkedPhaseReset;
    [Test]
    [Category('unit')]
    procedure PeriodicPhaseResetRawEncodeUsesSubchunkFastPath;
    [Test]
    [Category('unit')]
    procedure MultiThreadedRawCancellation;
    [Test]
    [Category('unit')]
    procedure MultiThreadedRawMemoryLimit;
    [Test]
    [Category('unit')]
    procedure MultiThreadedRawWriteFailure;
    [Test]
    [Category('unit')]
    [Category('soak')]
    procedure IndependentInstancesAreThreadSafe;
  end;

function TWriteFailStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TWriteFailStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('synthetic write failure');
end;

function TWriteFailStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

function TReadFailStream.Read(var Buffer; Count: Longint): Longint;
begin
  raise EReadError.Create('synthetic read failure');
end;

function TReadFailStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('read-fail stream is read-only');
end;

function TReadFailStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

function TGenericReadFailStream.Read(var Buffer; Count: Longint): Longint;
begin
  raise Exception.Create('synthetic generic read failure');
end;

function TGenericReadFailStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := Count;
end;

function TGenericReadFailStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

function TGenericWriteFailStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TGenericWriteFailStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise Exception.Create('synthetic generic write failure');
end;

function TGenericWriteFailStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0;
end;

constructor TProbeBoundReadStream.Create(const Data: TBytes; const ProbeReadLimit: UInt64);
begin
  inherited Create(Data);
  FProbeReadLimit := ProbeReadLimit;
  FProbeReadBytes := 0;
  FAfterBackwardSeek := False;
end;

function TProbeBoundReadStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := inherited Read(Buffer, Count);
  if (not FAfterBackwardSeek) and (Result > 0) then
  begin
    Inc(FProbeReadBytes, UInt64(Result));
    if FProbeReadBytes > FProbeReadLimit then
      raise EReadError.Create('probe read limit exceeded before memory-limit fallback');
  end;
end;

function TProbeBoundReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
var
  Before: Int64;
begin
  Before := inherited Seek(0, soCurrent);
  Result := inherited Seek(Offset, Origin);
  if (Result = 0) and (Before <> 0) then
    FAfterBackwardSeek := True;
end;

constructor TStreamingProbeWriteStream.Create(const SlowWorkerRunning: PInteger;
  const ObservedWriteDuringSlowWorker: PInteger);
begin
  inherited Create;
  FSlowWorkerRunning := SlowWorkerRunning;
  FObservedWriteDuringSlowWorker := ObservedWriteDuringSlowWorker;
end;

function TStreamingProbeWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count > 0) and (FSlowWorkerRunning <> nil) and (FObservedWriteDuringSlowWorker <> nil) and
    (TInterlocked.CompareExchange(FSlowWorkerRunning^, 0, 0) <> 0) then
    TInterlocked.Exchange(FObservedWriteDuringSlowWorker^, 1);
  Result := inherited Write(Buffer, Count);
end;

{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TStreamingProbeWriteStream.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  if (Count > 0) and (FSlowWorkerRunning <> nil) and (FObservedWriteDuringSlowWorker <> nil) and
    (TInterlocked.CompareExchange(FSlowWorkerRunning^, 0, 0) <> 0) then
    TInterlocked.Exchange(FObservedWriteDuringSlowWorker^, 1);
  Result := inherited Write(Buffer, Count);
end;
{$ENDIF}

constructor TOutputStartedProbeWriteStream.Create(const OutputStarted: PInteger);
begin
  inherited Create;
  FOutputStarted := OutputStarted;
  FMaxWriteCount := 0;
  FWriteCallCount := 0;
end;

function TOutputStartedProbeWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count > 0) and (FOutputStarted <> nil) then
    TInterlocked.Exchange(FOutputStarted^, 1);
  Inc(FWriteCallCount);
  if Count > FMaxWriteCount then
    FMaxWriteCount := Count;
  Result := inherited Write(Buffer, Count);
end;

{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TOutputStartedProbeWriteStream.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  if (Count > 0) and (FOutputStarted <> nil) then
    TInterlocked.Exchange(FOutputStarted^, 1);
  Inc(FWriteCallCount);
  if Count > FMaxWriteCount then
    FMaxWriteCount := Count;
  Result := inherited Write(Buffer, Count);
end;
{$ENDIF}

constructor TReadBeforeOutputProbeStream.Create(const Data: TBytes; const OutputStarted: PInteger);
begin
  inherited Create(Data);
  FOutputStarted := OutputStarted;
  FReadBeforeOutput := 0;
end;

function TReadBeforeOutputProbeStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := inherited Read(Buffer, Count);
  if (Result > 0) and (FOutputStarted <> nil) and
    (TInterlocked.CompareExchange(FOutputStarted^, 0, 0) = 0) then
    Inc(FReadBeforeOutput, UInt64(Result));
end;

constructor TNonSeekableReadStream.Create(const Data: TBytes; const DestroyedFlag: PBoolean);
begin
  inherited Create;
  SetLength(FData, Length(Data));
  if Length(Data) <> 0 then
    Move(Data[0], FData[0], Length(Data));
  FPosition := 0;
  FSeekCount := 0;
  FDestroyedFlag := DestroyedFlag;
  if FDestroyedFlag <> nil then
    FDestroyedFlag^ := False;
end;

destructor TNonSeekableReadStream.Destroy;
begin
  if FDestroyedFlag <> nil then
    FDestroyedFlag^ := True;
  inherited;
end;

function TNonSeekableReadStream.Read(var Buffer; Count: Longint): Longint;
var
  Remaining: Integer;
begin
  if Count <= 0 then
    Exit(0);
  Remaining := Length(FData) - FPosition;
  if Remaining <= 0 then
    Exit(0);
  if Count < Remaining then
    Remaining := Count;
  Move(FData[FPosition], Buffer, Remaining);
  Inc(FPosition, Remaining);
  Result := Remaining;
end;

function TNonSeekableReadStream.Write(const Buffer; Count: Longint): Longint;
begin
  raise EWriteError.Create('non-seekable read stream is read-only');
end;

function TNonSeekableReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Inc(FSeekCount);
  raise EStreamError.Create('seek is not supported by this test stream');
end;

constructor TDestroyTrackingMemoryStream.Create(const DestroyedFlag: PBoolean);
begin
  inherited Create;
  FDestroyedFlag := DestroyedFlag;
  if FDestroyedFlag <> nil then
    FDestroyedFlag^ := False;
end;

destructor TDestroyTrackingMemoryStream.Destroy;
begin
  if FDestroyedFlag <> nil then
    FDestroyedFlag^ := True;
  inherited;
end;

constructor TTrackingSeqInStream.Create(const Data: TBytes);
begin
  inherited Create;
  SetLength(FData, Length(Data));
  if Length(Data) <> 0 then
    Move(Data[0], FData[0], Length(Data));
  FOffset := 0;
  FEofReached := False;
  FFirstRequestedCount := 0;
  FMaxRequestedCount := 0;
  FReadCallCount := 0;
end;

function TTrackingSeqInStream.Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
var
  Remaining: NativeInt;
  ToRead: NativeInt;
begin
  ProcessedSize := 0;
  Inc(FReadCallCount);
  if FReadCallCount = 1 then
    FFirstRequestedCount := Count;
  if Count > FMaxRequestedCount then
    FMaxRequestedCount := Count;
  if Count = 0 then
    Exit(SZ_OK);

  Remaining := Length(FData) - FOffset;
  if Remaining <= 0 then
  begin
    FEofReached := True;
    Exit(SZ_OK);
  end;

  if Count > SizeT(High(NativeInt)) then
    ToRead := High(NativeInt)
  else
    ToRead := NativeInt(Count);
  if ToRead > Remaining then
    ToRead := Remaining;
  Move(FData[FOffset], Buffer, ToRead);
  Inc(FOffset, ToRead);
  ProcessedSize := SizeT(ToRead);
  Result := SZ_OK;
end;

function TTrackingSeqInStream.FullyConsumed: Boolean;
begin
  Result := FOffset >= Length(FData);
end;

constructor TTrackingSeqOutStream.Create(const Input: TTrackingSeqInStream);
begin
  inherited Create;
  FInput := Input;
  FBuffer := TMemoryStream.Create;
  FMaxWriteCount := 0;
  FWroteBeforeInputDrained := False;
  FWroteBeforeInputEof := False;
  FWriteCallCount := 0;
end;

destructor TTrackingSeqOutStream.Destroy;
begin
  FBuffer.Free;
  inherited;
end;

function TTrackingSeqOutStream.Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
begin
  ProcessedSize := 0;
  try
    Inc(FWriteCallCount);
    if Count > FMaxWriteCount then
      FMaxWriteCount := Count;
    if Count > SizeT(High(NativeInt)) then
      Exit(SZ_ERROR_MEM);
    if Count <> 0 then
    begin
      if (FInput <> nil) and (not FInput.FullyConsumed) then
        FWroteBeforeInputDrained := True;
      if (FInput <> nil) and (not FInput.EofReached) then
        FWroteBeforeInputEof := True;
      FBuffer.WriteBuffer(Buffer, NativeInt(Count));
      ProcessedSize := Count;
    end;
    Result := SZ_OK;
  except
    on E: Exception do
      Result := SZ_ERROR_WRITE;
  end;
end;

function TTrackingSeqOutStream.ToBytes: TBytes;
begin
  SetLength(Result, FBuffer.Size);
  if FBuffer.Size <> 0 then
  begin
    FBuffer.Position := 0;
    FBuffer.ReadBuffer(Result[0], Length(Result));
    FBuffer.Position := FBuffer.Size;
  end;
end;

constructor TPartialSeqOutStream.Create(const MaxBytesPerWrite: SizeT; const FailOnCall: Integer;
  const FailCode: SRes);
begin
  inherited Create;
  FBuffer := TMemoryStream.Create;
  FMaxBytesPerWrite := MaxBytesPerWrite;
  FFailOnCall := FailOnCall;
  FFailCode := FailCode;
  FCallCount := 0;
end;

destructor TPartialSeqOutStream.Destroy;
begin
  FBuffer.Free;
  inherited;
end;

function TPartialSeqOutStream.Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
var
  ToWrite: SizeT;
begin
  ProcessedSize := 0;
  Inc(FCallCount);
  if (FFailOnCall > 0) and (FCallCount >= FFailOnCall) then
    Exit(FFailCode);

  ToWrite := Count;
  if (FMaxBytesPerWrite > 0) and (ToWrite > FMaxBytesPerWrite) then
    ToWrite := FMaxBytesPerWrite;
  if ToWrite > SizeT(High(NativeInt)) then
    Exit(SZ_ERROR_MEM);

  try
    if ToWrite <> 0 then
      FBuffer.WriteBuffer(Buffer, NativeInt(ToWrite));
    ProcessedSize := ToWrite;
    Result := SZ_OK;
  except
    on E: Exception do
      Result := SZ_ERROR_WRITE;
  end;
end;

function TPartialSeqOutStream.ToBytes: TBytes;
begin
  SetLength(Result, FBuffer.Size);
  if FBuffer.Size <> 0 then
  begin
    FBuffer.Position := 0;
    FBuffer.ReadBuffer(Result[0], Length(Result));
    FBuffer.Position := FBuffer.Size;
  end;
end;

constructor TFailingSdkProgress.Create(const ResultCode: SRes);
begin
  inherited Create;
  FResultCode := ResultCode;
  FCalls := 0;
end;

function TFailingSdkProgress.Progress(const InSize, OutSize: UInt64): SRes;
begin
  Inc(FCalls);
  Result := FResultCode;
end;

class function TLzma2NativeTests.BytesOfSize(const Size: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Size);
  for I := 0 to Size - 1 do
    Result[I] := Byte((I * 131 + I div 7) and $FF);
end;

class function TLzma2NativeTests.HighEntropyBytes(const Size: Integer): TBytes;
var
  I: Integer;
  State: UInt32;
begin
  SetLength(Result, Size);
  State := UInt32($6D2B79F5);
  for I := 0 to Size - 1 do
  begin
    State := State * UInt32(1664525) + UInt32(1013904223);
    Result[I] := Byte((State shr 24) xor (State shr 16) xor UInt32(I * 17));
  end;
end;

class function TLzma2NativeTests.RepeatingBytes(const Size: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Size);
  for I := 0 to Size - 1 do
    Result[I] := Byte(Ord('A') + (I mod 5));
end;

class function TLzma2NativeTests.CrossToolDir: string;
begin
  Result := IncludeTrailingPathDelimiter(GetCurrentDir) + 'build\dunitx-cross-tool';
  ForceDirectories(Result);
end;

class function TLzma2NativeTests.EnvToolPath(const EnvName: string): string;
begin
  Result := Trim(System.SysUtils.GetEnvironmentVariable(EnvName));
end;

class procedure TLzma2NativeTests.WriteAllBytes(const FileName: string; const Data: TBytes);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmCreate);
  try
    if Length(Data) > 0 then
      Stream.WriteBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
end;

class function TLzma2NativeTests.ReadAllBytesFromFile(const FileName: string): TBytes;
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[0], Stream.Size);
  finally
    Stream.Free;
  end;
end;

class procedure TLzma2NativeTests.DeleteFileIfExists(const FileName: string);
begin
  if FileExists(FileName) then
    System.SysUtils.DeleteFile(FileName);
end;

class procedure TLzma2NativeTests.SkipExternalTool(const TestName: string; const EnvName: string);
begin
  System.Writeln('SKIP ' + TestName + ': set ' + EnvName + ' to enable this cross-tool test.');
end;

class procedure TLzma2NativeTests.AssertBytesEqual(const Expected: TBytes; const Actual: TBytes;
  const Message: string);
begin
  Assert.AreEqual(Length(Expected), Length(Actual), Message + ' size mismatch');
  if Length(Expected) > 0 then
    Assert.IsTrue(CompareMem(@Expected[0], @Actual[0], Length(Expected)), Message + ' bytes mismatch');
end;

class procedure TLzma2NativeTests.AppendByte(var Target: TBytes; const Value: Byte);
var
  OldLen: Integer;
begin
  OldLen := Length(Target);
  SetLength(Target, OldLen + 1);
  Target[OldLen] := Value;
end;

class procedure TLzma2NativeTests.AppendBytes(var Target: TBytes; const Source: TBytes);
var
  OldLen: Integer;
begin
  if Length(Source) = 0 then
    Exit;
  OldLen := Length(Target);
  SetLength(Target, OldLen + Length(Source));
  Move(Source[0], Target[OldLen], Length(Source));
end;

class procedure TLzma2NativeTests.AppendZeroes(var Target: TBytes; const Count: NativeUInt);
var
  OldLen: Integer;
begin
  if Count = 0 then
    Exit;
  OldLen := Length(Target);
  SetLength(Target, OldLen + Integer(Count));
  FillChar(Target[OldLen], Count, 0);
end;

class function TLzma2NativeTests.BuildTestXzHeader(const CheckId: Byte): TBytes;
var
  Crc: UInt32;
begin
  SetLength(Result, XZ_STREAM_HEADER_SIZE);
  Move(XZ_SIG[0], Result[0], XZ_SIG_SIZE);
  Result[XZ_SIG_SIZE] := 0;
  Result[XZ_SIG_SIZE + 1] := CheckId;
  Crc := Crc32Calc(@Result[XZ_SIG_SIZE], XZ_STREAM_FLAGS_SIZE);
  WriteUi32LE(@Result[XZ_SIG_SIZE + XZ_STREAM_FLAGS_SIZE], Crc);
end;

class function TLzma2NativeTests.BuildTestXzRawBlockHeader(const Flags: Byte; const Body: TBytes): TBytes;
var
  Crc: UInt32;
begin
  SetLength(Result, 0);
  AppendByte(Result, 0);
  AppendByte(Result, Flags);
  AppendBytes(Result, Body);
  AppendZeroes(Result, XzPadSize(Length(Result)));
  Result[0] := Byte(Length(Result) div 4);
  Crc := Crc32Calc(Result);
  AppendByte(Result, Byte(Crc));
  AppendByte(Result, Byte(Crc shr 8));
  AppendByte(Result, Byte(Crc shr 16));
  AppendByte(Result, Byte(Crc shr 24));
end;

class function TLzma2NativeTests.BuildTestXzBlock(const Data: TBytes; const Options: TLzma2Options;
  out RecordInfo: TXzTestIndexRecord; const StorePackedSize: Boolean;
  const ExtraPayloadByte: Integer; const StoreUnpackedSize: Boolean): TBytes;
var
  Raw: TBytes;
  Header: TBytes;
  Digest: TBytes;
  Crc: UInt32;
  Info: TLzma2DictionaryInfo;
  Pad: Byte;
  PayloadSize: UInt64;
  Flags: Byte;
begin
  Info := TLzma2Encoder.DictionaryInfo(TLzma2Encoder.NormalizeOptions(Options));
  Raw := TLzma2Encoder.EncodeRawBytes(Data, Options);
  PayloadSize := UInt64(Length(Raw));
  if ExtraPayloadByte >= 0 then
    Inc(PayloadSize);

  SetLength(Header, 0);
  AppendByte(Header, 0);
  Flags := 0;
  if StorePackedSize then
    Flags := Flags or XZ_BF_PACK_SIZE;
  if StoreUnpackedSize then
    Flags := Flags or XZ_BF_UNPACK_SIZE;
  AppendByte(Header, Flags);
  if StorePackedSize then
    AppendBytes(Header, XzWriteVarInt(PayloadSize));
  if StoreUnpackedSize then
    AppendBytes(Header, XzWriteVarInt(Length(Data)));
  AppendBytes(Header, XzWriteVarInt(XZ_ID_LZMA2));
  AppendBytes(Header, XzWriteVarInt(1));
  AppendByte(Header, Info.PropertyByte);
  AppendZeroes(Header, XzPadSize(Length(Header)));
  Header[0] := Byte(Length(Header) div 4);
  Crc := Crc32Calc(Header);
  AppendByte(Header, Byte(Crc));
  AppendByte(Header, Byte(Crc shr 8));
  AppendByte(Header, Byte(Crc shr 16));
  AppendByte(Header, Byte(Crc shr 24));

  Digest := CheckDigest(XzCheckId(Options.Check), Data);
  Pad := XzPadSize(PayloadSize);
  Result := Header;
  AppendBytes(Result, Raw);
  if ExtraPayloadByte >= 0 then
    AppendByte(Result, Byte(ExtraPayloadByte));
  AppendZeroes(Result, Pad);
  AppendBytes(Result, Digest);

  RecordInfo.UnpaddedSize := UInt64(Length(Header)) + PayloadSize + UInt64(Length(Digest));
  RecordInfo.UnpackSize := Length(Data);
end;

class function TLzma2NativeTests.BuildTestXzIndexAndFooter(const Records: array of TXzTestIndexRecord;
  const CheckId: Byte): TBytes;
var
  Index: TBytes;
  Footer: TBytes;
  Crc: UInt32;
  BackwardSize: UInt32;
  I: Integer;
begin
  SetLength(Index, 0);
  AppendByte(Index, 0);
  AppendBytes(Index, XzWriteVarInt(Length(Records)));
  for I := Low(Records) to High(Records) do
  begin
    AppendBytes(Index, XzWriteVarInt(Records[I].UnpaddedSize));
    AppendBytes(Index, XzWriteVarInt(Records[I].UnpackSize));
  end;
  AppendZeroes(Index, XzPadSize(Length(Index)));
  Crc := Crc32Calc(Index);
  AppendByte(Index, Byte(Crc));
  AppendByte(Index, Byte(Crc shr 8));
  AppendByte(Index, Byte(Crc shr 16));
  AppendByte(Index, Byte(Crc shr 24));

  BackwardSize := UInt32(Length(Index) div 4 - 1);
  SetLength(Footer, XZ_STREAM_FOOTER_SIZE);
  WriteUi32LE(@Footer[4], BackwardSize);
  Footer[8] := 0;
  Footer[9] := CheckId;
  Crc := Crc32Calc(@Footer[4], 6);
  WriteUi32LE(@Footer[0], Crc);
  Footer[10] := Ord('Y');
  Footer[11] := Ord('Z');

  Result := Index;
  AppendBytes(Result, Footer);
end;

class procedure TLzma2NativeTests.AppendSevenZipTestNumber(var Target: TBytes; const Value: UInt64);
var
  Bytes: TBytes;
begin
  if Value < $80 then
  begin
    AppendByte(Target, Byte(Value));
    Exit;
  end;

  SetLength(Bytes, 9);
  Bytes[0] := $FF;
  WriteUi64LE(@Bytes[1], Value);
  AppendBytes(Target, Bytes);
end;

class function TLzma2NativeTests.BuildTestSevenZipArchiveFromPayloadAndHeader(const Payload,
  Header: TBytes): TBytes;
const
  SEVENZ_SIGNATURE_SIZE = 6;
  SEVENZ_SIGNATURE_HEADER_SIZE = 32;
  SEVENZ_SIGNATURE: array[0..SEVENZ_SIGNATURE_SIZE - 1] of Byte =
    ($37, $7A, $BC, $AF, $27, $1C);
var
  I: Integer;
  SignatureHeader: TBytes;
  StartHeader: TBytes;
  Temp: TBytes;

  procedure AppendUInt32LE(var Target: TBytes; const Value: UInt32);
  begin
    SetLength(Temp, SizeOf(UInt32));
    WriteUi32LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure AppendUInt64LE(var Target: TBytes; const Value: UInt64);
  begin
    SetLength(Temp, SizeOf(UInt64));
    WriteUi64LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

begin
  SetLength(StartHeader, 0);
  AppendUInt64LE(StartHeader, UInt64(Length(Payload)));
  AppendUInt64LE(StartHeader, UInt64(Length(Header)));
  AppendUInt32LE(StartHeader, Crc32Calc(Header));

  SetLength(SignatureHeader, 0);
  for I := 0 to High(SEVENZ_SIGNATURE) do
    AppendByte(SignatureHeader, SEVENZ_SIGNATURE[I]);
  AppendByte(SignatureHeader, 0);
  AppendByte(SignatureHeader, 4);
  AppendUInt32LE(SignatureHeader, Crc32Calc(StartHeader));
  AppendBytes(SignatureHeader, StartHeader);
  Assert.AreEqual(Integer(SEVENZ_SIGNATURE_HEADER_SIZE), Integer(Length(SignatureHeader)),
    'test 7z signature header size');

  Result := SignatureHeader;
  AppendBytes(Result, Payload);
  AppendBytes(Result, Header);
end;

class procedure TLzma2NativeTests.PatchTestSevenZipNextHeaderByte(var Archive: TBytes;
  const Pattern: TBytes; const Occurrence, PatchOffset: Integer; const XorMask: Byte);
var
  Header: TBytes;
  HeaderOffset: UInt64;
  HeaderSize: UInt64;
  MatchAt: Integer;
  MatchCount: Integer;
  PatternMatches: Boolean;
  I: Integer;
  J: Integer;
begin
  Assert.IsTrue(Length(Archive) >= 32, '7z fixture must contain a signature header');
  Assert.IsTrue(Length(Pattern) > 0, '7z next-header patch pattern must be non-empty');
  Assert.IsTrue(Occurrence > 0, '7z next-header patch occurrence must be one-based');

  HeaderOffset := UInt64(32) + ReadUi64LE(@Archive[12]);
  HeaderSize := ReadUi64LE(@Archive[20]);
  Assert.IsTrue(HeaderOffset <= UInt64(High(Integer)), '7z next-header offset must fit test process');
  Assert.IsTrue(HeaderSize <= UInt64(High(Integer)), '7z next-header size must fit test process');
  Assert.IsTrue(HeaderOffset + HeaderSize <= UInt64(Length(Archive)), '7z next-header bounds');

  Header := Copy(Archive, Integer(HeaderOffset), Integer(HeaderSize));
  MatchAt := -1;
  MatchCount := 0;
  for I := 0 to Length(Header) - Length(Pattern) do
  begin
    PatternMatches := True;
    for J := 0 to High(Pattern) do
      if Header[I + J] <> Pattern[J] then
      begin
        PatternMatches := False;
        Break;
      end;
    if PatternMatches then
    begin
      Inc(MatchCount);
      if MatchCount = Occurrence then
      begin
        MatchAt := I;
        Break;
      end;
    end;
  end;
  Assert.IsTrue(MatchAt >= 0, '7z next-header patch pattern not found');
  Assert.IsTrue(PatchOffset >= 0, '7z next-header patch offset');
  Assert.IsTrue(MatchAt + PatchOffset < Length(Header), '7z next-header patch target bounds');

  Header[MatchAt + PatchOffset] := Header[MatchAt + PatchOffset] xor XorMask;
  if Length(Header) <> 0 then
    Move(Header[0], Archive[Integer(HeaderOffset)], Length(Header));
  WriteUi32LE(@Archive[28], Crc32Calc(Header));
  WriteUi32LE(@Archive[8], Crc32Calc(@Archive[12], 20));
end;

class function TLzma2NativeTests.BuildTestSevenZipHeaderBytes(const PackSize: UInt64; const PackCrc: UInt32;
  const UnpackSize: UInt64; const UnpackCrc: UInt32; const Coder: TSevenZipTestCoder;
  const CoderProperties: TBytes; const FileName: string): TBytes;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_MAIN_STREAMS_INFO = $04;
  SEVENZ_NID_FILES_INFO = $05;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
  SEVENZ_NID_CODERS_UNPACK_SIZE = $0C;
  SEVENZ_NID_NAME = $11;
var
  NameBytes: TBytes;

  procedure AppendUInt32LE(var Target: TBytes; const Value: UInt32);
  var
    Bytes: TBytes;
  begin
    SetLength(Bytes, SizeOf(UInt32));
    WriteUi32LE(@Bytes[0], Value);
    AppendBytes(Target, Bytes);
  end;

  procedure AppendCoder(var Target: TBytes);
  var
    Flags: Byte;
  begin
    case Coder of
      sztcLzma:
        begin
          Flags := $03;
          if Length(CoderProperties) <> 0 then
            Flags := Flags or $20;
          AppendByte(Target, Flags);
          AppendByte(Target, $03);
          AppendByte(Target, $01);
          AppendByte(Target, $01);
        end;
      sztcLzma2:
        begin
          Flags := $01;
          if Length(CoderProperties) <> 0 then
            Flags := Flags or $20;
          AppendByte(Target, Flags);
          AppendByte(Target, XZ_ID_LZMA2);
        end;
    else
      Flags := $01;
      AppendByte(Target, Flags);
      AppendByte(Target, $04);
    end;

    if Length(CoderProperties) <> 0 then
    begin
      AppendSevenZipTestNumber(Target, Length(CoderProperties));
      AppendBytes(Target, CoderProperties);
    end;
  end;

begin
  SetLength(Result, 0);
  AppendByte(Result, SEVENZ_NID_HEADER);

  AppendByte(Result, SEVENZ_NID_MAIN_STREAMS_INFO);
  AppendByte(Result, SEVENZ_NID_PACK_INFO);
  AppendSevenZipTestNumber(Result, 0);
  AppendSevenZipTestNumber(Result, 1);
  AppendByte(Result, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(Result, PackSize);
  AppendByte(Result, SEVENZ_NID_CRC);
  AppendByte(Result, 1);
  AppendUInt32LE(Result, PackCrc);
  AppendByte(Result, SEVENZ_NID_END);

  AppendByte(Result, SEVENZ_NID_UNPACK_INFO);
  AppendByte(Result, SEVENZ_NID_FOLDER);
  AppendSevenZipTestNumber(Result, 1);
  AppendByte(Result, 0);
  AppendSevenZipTestNumber(Result, 1);
  AppendCoder(Result);
  AppendByte(Result, SEVENZ_NID_CODERS_UNPACK_SIZE);
  AppendSevenZipTestNumber(Result, UnpackSize);
  AppendByte(Result, SEVENZ_NID_CRC);
  AppendByte(Result, 1);
  AppendUInt32LE(Result, UnpackCrc);
  AppendByte(Result, SEVENZ_NID_END);
  AppendByte(Result, SEVENZ_NID_END);

  AppendByte(Result, SEVENZ_NID_FILES_INFO);
  AppendSevenZipTestNumber(Result, 1);
  NameBytes := TEncoding.Unicode.GetBytes(FileName + #0);
  AppendByte(Result, SEVENZ_NID_NAME);
  AppendSevenZipTestNumber(Result, UInt64(Length(NameBytes)) + 1);
  AppendByte(Result, 0);
  AppendBytes(Result, NameBytes);
  AppendByte(Result, SEVENZ_NID_END);

  AppendByte(Result, SEVENZ_NID_END);
end;

class function TLzma2NativeTests.BuildTestSevenZipLzmaArchive(const Data: TBytes; const FileName: string;
  const Options: TLzma2Options): TBytes;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_MAIN_STREAMS_INFO = $04;
  SEVENZ_NID_FILES_INFO = $05;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
  SEVENZ_NID_CODERS_UNPACK_SIZE = $0C;
  SEVENZ_NID_NAME = $11;
  SEVENZ_SIGNATURE_SIZE = 6;
  SEVENZ_SIGNATURE_HEADER_SIZE = 32;
  SEVENZ_SIGNATURE: array[0..SEVENZ_SIGNATURE_SIZE - 1] of Byte =
    ($37, $7A, $BC, $AF, $27, $1C);
var
  ArchiveOptions: TLzma2Options;
  Src: TBytesStream;
  StandaloneStream: TMemoryStream;
  Standalone: TBytes;
  Props: TBytes;
  PackedBytes: TBytes;
  Header: TBytes;
  StartHeader: TBytes;
  SignatureHeader: TBytes;
  NameBytes: TBytes;
  Temp: TBytes;
  PackCrc: UInt32;
  UnpackCrc: UInt32;
  HeaderCrc: UInt32;
  StartHeaderCrc: UInt32;
  I: Integer;

  procedure AppendUInt32LE(var Target: TBytes; const Value: UInt32);
  begin
    SetLength(Temp, SizeOf(UInt32));
    WriteUi32LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure AppendUInt64LE(var Target: TBytes; const Value: UInt64);
  begin
    SetLength(Temp, SizeOf(UInt64));
    WriteUi64LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

begin
  ArchiveOptions := Options;
  ArchiveOptions.Container := lcLzma;
  ArchiveOptions.ThreadCount := 1;
  ArchiveOptions.LzmaEndMarker := False;
  Src := TBytesStream.Create(Data);
  StandaloneStream := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, StandaloneStream, ArchiveOptions);
    SetLength(Standalone, StandaloneStream.Size);
    if StandaloneStream.Size > 0 then
    begin
      StandaloneStream.Position := 0;
      StandaloneStream.ReadBuffer(Standalone[0], StandaloneStream.Size);
    end;
  finally
    StandaloneStream.Free;
    Src.Free;
  end;
  Assert.IsTrue(Length(Standalone) > 13, 'standalone LZMA fixture must include properties, size, and payload');
  Props := Copy(Standalone, 0, 5);
  PackedBytes := Copy(Standalone, 13, Length(Standalone) - 13);
  PackCrc := Crc32Calc(PackedBytes);
  UnpackCrc := Crc32Calc(Data);

  SetLength(Header, 0);
  AppendByte(Header, SEVENZ_NID_HEADER);
  AppendByte(Header, SEVENZ_NID_MAIN_STREAMS_INFO);
  AppendByte(Header, SEVENZ_NID_PACK_INFO);
  AppendSevenZipTestNumber(Header, 0);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(Header, Length(PackedBytes));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, PackCrc);
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_UNPACK_INFO);
  AppendByte(Header, SEVENZ_NID_FOLDER);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, 0);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, $23);
  AppendByte(Header, $03);
  AppendByte(Header, $01);
  AppendByte(Header, $01);
  AppendSevenZipTestNumber(Header, Length(Props));
  AppendBytes(Header, Props);
  AppendByte(Header, SEVENZ_NID_CODERS_UNPACK_SIZE);
  AppendSevenZipTestNumber(Header, Length(Data));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, UnpackCrc);
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_FILES_INFO);
  AppendSevenZipTestNumber(Header, 1);
  NameBytes := TEncoding.Unicode.GetBytes(FileName + #0);
  AppendByte(Header, SEVENZ_NID_NAME);
  AppendSevenZipTestNumber(Header, UInt64(Length(NameBytes)) + 1);
  AppendByte(Header, 0);
  AppendBytes(Header, NameBytes);
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  HeaderCrc := Crc32Calc(Header);
  SetLength(StartHeader, 0);
  AppendUInt64LE(StartHeader, UInt64(Length(PackedBytes)));
  AppendUInt64LE(StartHeader, UInt64(Length(Header)));
  AppendUInt32LE(StartHeader, HeaderCrc);
  StartHeaderCrc := Crc32Calc(StartHeader);

  SetLength(SignatureHeader, 0);
  for I := 0 to High(SEVENZ_SIGNATURE) do
    AppendByte(SignatureHeader, SEVENZ_SIGNATURE[I]);
  AppendByte(SignatureHeader, 0);
  AppendByte(SignatureHeader, 4);
  AppendUInt32LE(SignatureHeader, StartHeaderCrc);
  AppendBytes(SignatureHeader, StartHeader);
  Assert.AreEqual(Integer(SEVENZ_SIGNATURE_HEADER_SIZE), Integer(Length(SignatureHeader)), '7z signature header size');

  Result := SignatureHeader;
  AppendBytes(Result, PackedBytes);
  AppendBytes(Result, Header);
end;

class function TLzma2NativeTests.BuildTestSevenZipEncodedHeaderArchive(const Data: TBytes; const FileName: string;
  const HeaderCoder: TSevenZipTestCoder; const Options: TLzma2Options): TBytes;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_ENCODED_HEADER = $17;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
  SEVENZ_NID_CODERS_UNPACK_SIZE = $0C;
  SEVENZ_SIGNATURE_SIZE = 6;
  SEVENZ_SIGNATURE_HEADER_SIZE = 32;
  SEVENZ_SIGNATURE: array[0..SEVENZ_SIGNATURE_SIZE - 1] of Byte =
    ($37, $7A, $BC, $AF, $27, $1C);
var
  RawOptions: TLzma2Options;
  PayloadPacked: TBytes;
  PayloadProps: TBytes;
  PlainHeader: TBytes;
  EncodedHeaderPacked: TBytes;
  EncodedHeaderProps: TBytes;
  EncodedHeaderDescriptor: TBytes;
  StartHeader: TBytes;
  SignatureHeader: TBytes;
  StandaloneStream: TMemoryStream;
  HeaderSource: TBytesStream;
  Info: TLzma2DictionaryInfo;
  Temp: TBytes;
  I: Integer;

  procedure AppendUInt32LE(var Target: TBytes; const Value: UInt32);
  begin
    SetLength(Temp, SizeOf(UInt32));
    WriteUi32LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure AppendUInt64LE(var Target: TBytes; const Value: UInt64);
  begin
    SetLength(Temp, SizeOf(UInt64));
    WriteUi64LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure AppendDescriptorCoder(var Target: TBytes; const Coder: TSevenZipTestCoder; const Props: TBytes);
  var
    Flags: Byte;
  begin
    case Coder of
      sztcLzma:
        begin
          Flags := $03;
          if Length(Props) <> 0 then
            Flags := Flags or $20;
          AppendByte(Target, Flags);
          AppendByte(Target, $03);
          AppendByte(Target, $01);
          AppendByte(Target, $01);
        end;
      sztcLzma2:
        begin
          Flags := $01;
          if Length(Props) <> 0 then
            Flags := Flags or $20;
          AppendByte(Target, Flags);
          AppendByte(Target, XZ_ID_LZMA2);
        end;
    else
      AppendByte(Target, $01);
      AppendByte(Target, $04);
    end;
    if Length(Props) <> 0 then
    begin
      AppendSevenZipTestNumber(Target, Length(Props));
      AppendBytes(Target, Props);
    end;
  end;

begin
  RawOptions := Options;
  RawOptions.Container := lcRawLzma2;
  RawOptions.ThreadCount := 1;
  RawOptions.Level := 1;
  Info := TLzma2Encoder.DictionaryInfo(RawOptions);
  PayloadPacked := TLzma2Encoder.EncodeRawBytes(Data, RawOptions);
  PayloadProps := TBytes.Create(Info.PropertyByte);
  PlainHeader := BuildTestSevenZipHeaderBytes(Length(PayloadPacked), Crc32Calc(PayloadPacked),
    Length(Data), Crc32Calc(Data), sztcLzma2, PayloadProps, FileName);

  case HeaderCoder of
    sztcLzma2:
      begin
        EncodedHeaderPacked := TLzma2Encoder.EncodeRawBytes(PlainHeader, RawOptions);
        EncodedHeaderProps := TBytes.Create(Info.PropertyByte);
      end;
    sztcLzma:
      begin
        RawOptions.Container := lcLzma;
        RawOptions.LzmaEndMarker := False;
        HeaderSource := TBytesStream.Create(PlainHeader);
        StandaloneStream := TMemoryStream.Create;
        try
          TLzma2.Compress(HeaderSource, StandaloneStream, RawOptions);
          SetLength(Temp, StandaloneStream.Size);
          if StandaloneStream.Size > 0 then
          begin
            StandaloneStream.Position := 0;
            StandaloneStream.ReadBuffer(Temp[0], StandaloneStream.Size);
          end;
        finally
          StandaloneStream.Free;
          HeaderSource.Free;
        end;
        EncodedHeaderProps := Copy(Temp, 0, 5);
        EncodedHeaderPacked := Copy(Temp, 13, Length(Temp) - 13);
      end;
  else
    EncodedHeaderPacked := TBytes.Create($00);
    SetLength(EncodedHeaderProps, 0);
  end;

  SetLength(EncodedHeaderDescriptor, 0);
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_ENCODED_HEADER);
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_PACK_INFO);
  AppendSevenZipTestNumber(EncodedHeaderDescriptor, UInt64(Length(PayloadPacked)));
  AppendSevenZipTestNumber(EncodedHeaderDescriptor, 1);
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(EncodedHeaderDescriptor, Length(EncodedHeaderPacked));
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_CRC);
  AppendByte(EncodedHeaderDescriptor, 1);
  AppendUInt32LE(EncodedHeaderDescriptor, Crc32Calc(EncodedHeaderPacked));
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_END);

  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_UNPACK_INFO);
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_FOLDER);
  AppendSevenZipTestNumber(EncodedHeaderDescriptor, 1);
  AppendByte(EncodedHeaderDescriptor, 0);
  AppendSevenZipTestNumber(EncodedHeaderDescriptor, 1);
  AppendDescriptorCoder(EncodedHeaderDescriptor, HeaderCoder, EncodedHeaderProps);
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_CODERS_UNPACK_SIZE);
  AppendSevenZipTestNumber(EncodedHeaderDescriptor, Length(PlainHeader));
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_CRC);
  AppendByte(EncodedHeaderDescriptor, 1);
  AppendUInt32LE(EncodedHeaderDescriptor, Crc32Calc(PlainHeader));
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_END);
  AppendByte(EncodedHeaderDescriptor, SEVENZ_NID_END);

  SetLength(StartHeader, 0);
  AppendUInt64LE(StartHeader, UInt64(Length(PayloadPacked) + Length(EncodedHeaderPacked)));
  AppendUInt64LE(StartHeader, UInt64(Length(EncodedHeaderDescriptor)));
  AppendUInt32LE(StartHeader, Crc32Calc(EncodedHeaderDescriptor));

  SetLength(SignatureHeader, 0);
  for I := 0 to High(SEVENZ_SIGNATURE) do
    AppendByte(SignatureHeader, SEVENZ_SIGNATURE[I]);
  AppendByte(SignatureHeader, 0);
  AppendByte(SignatureHeader, 4);
  AppendUInt32LE(SignatureHeader, Crc32Calc(StartHeader));
  AppendBytes(SignatureHeader, StartHeader);
  Assert.AreEqual(Integer(SEVENZ_SIGNATURE_HEADER_SIZE), Integer(Length(SignatureHeader)),
    'encoded-header 7z signature header size');

  Result := SignatureHeader;
  AppendBytes(Result, PayloadPacked);
  AppendBytes(Result, EncodedHeaderPacked);
  AppendBytes(Result, EncodedHeaderDescriptor);
end;

class function TLzma2NativeTests.BuildTestSevenZipMultiFolderArchive(const FirstData, SecondData: TBytes;
  const Coder: TSevenZipTestCoder; const Options: TLzma2Options): TBytes;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_MAIN_STREAMS_INFO = $04;
  SEVENZ_NID_FILES_INFO = $05;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
  SEVENZ_NID_CODERS_UNPACK_SIZE = $0C;
  SEVENZ_NID_EMPTY_STREAM = $0E;
  SEVENZ_NID_EMPTY_FILE = $0F;
  SEVENZ_NID_NAME = $11;
  SEVENZ_NID_MODIFICATION_TIME = $14;
  SEVENZ_NID_WIN_ATTRIBUTES = $15;
  SEVENZ_SIGNATURE_SIZE = 6;
  SEVENZ_SIGNATURE_HEADER_SIZE = 32;
  SEVENZ_SIGNATURE: array[0..SEVENZ_SIGNATURE_SIZE - 1] of Byte =
    ($37, $7A, $BC, $AF, $27, $1C);
var
  FirstPacked: TBytes;
  SecondPacked: TBytes;
  FirstProps: TBytes;
  SecondProps: TBytes;
  PackedBytes: TBytes;
  Header: TBytes;
  StartHeader: TBytes;
  SignatureHeader: TBytes;
  NameBytes: TBytes;
  Temp: TBytes;
  I: Integer;

  procedure AppendUInt32LE(var Target: TBytes; const Value: UInt32);
  begin
    SetLength(Temp, SizeOf(UInt32));
    WriteUi32LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure AppendUInt64LE(var Target: TBytes; const Value: UInt64);
  begin
    SetLength(Temp, SizeOf(UInt64));
    WriteUi64LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure EncodePayload(const Data: TBytes; out PackedBytes, Props: TBytes);
  var
    WorkOptions: TLzma2Options;
    Info: TLzma2DictionaryInfo;
    Src: TBytesStream;
    StandaloneStream: TMemoryStream;
    Standalone: TBytes;
  begin
    WorkOptions := Options;
    WorkOptions.ThreadCount := 1;
    WorkOptions.Level := 1;
    case Coder of
      sztcLzma2:
        begin
          WorkOptions.Container := lcRawLzma2;
          Info := TLzma2Encoder.DictionaryInfo(WorkOptions);
          Props := TBytes.Create(Info.PropertyByte);
          PackedBytes := TLzma2Encoder.EncodeRawBytes(Data, WorkOptions);
        end;
      sztcLzma:
        begin
          WorkOptions.Container := lcLzma;
          WorkOptions.LzmaEndMarker := False;
          Src := TBytesStream.Create(Data);
          StandaloneStream := TMemoryStream.Create;
          try
            TLzma2.Compress(Src, StandaloneStream, WorkOptions);
            SetLength(Standalone, StandaloneStream.Size);
            if StandaloneStream.Size > 0 then
            begin
              StandaloneStream.Position := 0;
              StandaloneStream.ReadBuffer(Standalone[0], StandaloneStream.Size);
            end;
          finally
            StandaloneStream.Free;
            Src.Free;
          end;
          Props := Copy(Standalone, 0, 5);
          PackedBytes := Copy(Standalone, 13, Length(Standalone) - 13);
        end;
    else
      Assert.Fail('unsupported test 7z coder for multi-folder fixture');
    end;
  end;

  procedure AppendCoder(var Target: TBytes; const Props: TBytes);
  begin
    case Coder of
      sztcLzma:
        begin
          AppendByte(Target, $23);
          AppendByte(Target, $03);
          AppendByte(Target, $01);
          AppendByte(Target, $01);
        end;
      sztcLzma2:
        begin
          AppendByte(Target, $21);
          AppendByte(Target, XZ_ID_LZMA2);
        end;
    else
      Assert.Fail('unsupported test 7z coder for multi-folder fixture');
    end;
    AppendSevenZipTestNumber(Target, Length(Props));
    AppendBytes(Target, Props);
  end;

begin
  EncodePayload(FirstData, FirstPacked, FirstProps);
  EncodePayload(SecondData, SecondPacked, SecondProps);
  PackedBytes := FirstPacked;
  AppendBytes(PackedBytes, SecondPacked);

  SetLength(Header, 0);
  AppendByte(Header, SEVENZ_NID_HEADER);
  AppendByte(Header, SEVENZ_NID_MAIN_STREAMS_INFO);
  AppendByte(Header, SEVENZ_NID_PACK_INFO);
  AppendSevenZipTestNumber(Header, 0);
  AppendSevenZipTestNumber(Header, 2);
  AppendByte(Header, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(Header, Length(FirstPacked));
  AppendSevenZipTestNumber(Header, Length(SecondPacked));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, Crc32Calc(FirstPacked));
  AppendUInt32LE(Header, Crc32Calc(SecondPacked));
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_UNPACK_INFO);
  AppendByte(Header, SEVENZ_NID_FOLDER);
  AppendSevenZipTestNumber(Header, 2);
  AppendByte(Header, 0);
  AppendSevenZipTestNumber(Header, 1);
  AppendCoder(Header, FirstProps);
  AppendSevenZipTestNumber(Header, 1);
  AppendCoder(Header, SecondProps);
  AppendByte(Header, SEVENZ_NID_CODERS_UNPACK_SIZE);
  AppendSevenZipTestNumber(Header, Length(FirstData));
  AppendSevenZipTestNumber(Header, Length(SecondData));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, Crc32Calc(FirstData));
  AppendUInt32LE(Header, Crc32Calc(SecondData));
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_FILES_INFO);
  AppendSevenZipTestNumber(Header, 4);
  NameBytes := TEncoding.Unicode.GetBytes('dir' + #0 + 'dir/a.bin' + #0 + 'b.bin' + #0 +
    'dir/empty.txt' + #0);
  AppendByte(Header, SEVENZ_NID_NAME);
  AppendSevenZipTestNumber(Header, UInt64(Length(NameBytes)) + 1);
  AppendByte(Header, 0);
  AppendBytes(Header, NameBytes);
  AppendByte(Header, SEVENZ_NID_EMPTY_STREAM);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, $90);
  AppendByte(Header, SEVENZ_NID_EMPTY_FILE);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, $40);
  AppendByte(Header, SEVENZ_NID_MODIFICATION_TIME);
  AppendSevenZipTestNumber(Header, 34);
  AppendByte(Header, 1);
  AppendByte(Header, 0);
  AppendUInt64LE(Header, UInt64($0102030405060708));
  AppendUInt64LE(Header, UInt64($1112131415161718));
  AppendUInt64LE(Header, UInt64($2122232425262728));
  AppendUInt64LE(Header, UInt64($3132333435363738));
  AppendByte(Header, SEVENZ_NID_WIN_ATTRIBUTES);
  AppendSevenZipTestNumber(Header, 18);
  AppendByte(Header, 1);
  AppendByte(Header, 0);
  AppendUInt32LE(Header, $10);
  AppendUInt32LE(Header, $20);
  AppendUInt32LE(Header, $80);
  AppendUInt32LE(Header, $20);
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  SetLength(StartHeader, 0);
  AppendUInt64LE(StartHeader, UInt64(Length(PackedBytes)));
  AppendUInt64LE(StartHeader, UInt64(Length(Header)));
  AppendUInt32LE(StartHeader, Crc32Calc(Header));

  SetLength(SignatureHeader, 0);
  for I := 0 to High(SEVENZ_SIGNATURE) do
    AppendByte(SignatureHeader, SEVENZ_SIGNATURE[I]);
  AppendByte(SignatureHeader, 0);
  AppendByte(SignatureHeader, 4);
  AppendUInt32LE(SignatureHeader, Crc32Calc(StartHeader));
  AppendBytes(SignatureHeader, StartHeader);
  Assert.AreEqual(Integer(SEVENZ_SIGNATURE_HEADER_SIZE), Integer(Length(SignatureHeader)),
    'multi-folder 7z signature header size');

  Result := SignatureHeader;
  AppendBytes(Result, PackedBytes);
  AppendBytes(Result, Header);
end;

class function TLzma2NativeTests.BuildTestSevenZipSolidArchive(const FirstData, SecondData: TBytes;
  const Coder: TSevenZipTestCoder; const Options: TLzma2Options): TBytes;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_MAIN_STREAMS_INFO = $04;
  SEVENZ_NID_FILES_INFO = $05;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SUB_STREAMS_INFO = $08;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
  SEVENZ_NID_CODERS_UNPACK_SIZE = $0C;
  SEVENZ_NID_NUM_UNPACK_STREAM = $0D;
  SEVENZ_NID_NAME = $11;
  SEVENZ_SIGNATURE_SIZE = 6;
  SEVENZ_SIGNATURE_HEADER_SIZE = 32;
  SEVENZ_SIGNATURE: array[0..SEVENZ_SIGNATURE_SIZE - 1] of Byte =
    ($37, $7A, $BC, $AF, $27, $1C);
var
  Combined: TBytes;
  PackedBytes: TBytes;
  Props: TBytes;
  Header: TBytes;
  StartHeader: TBytes;
  SignatureHeader: TBytes;
  NameBytes: TBytes;
  Temp: TBytes;
  I: Integer;

  procedure AppendUInt32LE(var Target: TBytes; const Value: UInt32);
  begin
    SetLength(Temp, SizeOf(UInt32));
    WriteUi32LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure AppendUInt64LE(var Target: TBytes; const Value: UInt64);
  begin
    SetLength(Temp, SizeOf(UInt64));
    WriteUi64LE(@Temp[0], Value);
    AppendBytes(Target, Temp);
  end;

  procedure EncodePayload(const Data: TBytes; out PackedBytes, CoderProps: TBytes);
  var
    WorkOptions: TLzma2Options;
    Info: TLzma2DictionaryInfo;
    Src: TBytesStream;
    StandaloneStream: TMemoryStream;
    Standalone: TBytes;
  begin
    WorkOptions := Options;
    WorkOptions.ThreadCount := 1;
    WorkOptions.Level := 1;
    case Coder of
      sztcLzma2:
        begin
          WorkOptions.Container := lcRawLzma2;
          Info := TLzma2Encoder.DictionaryInfo(WorkOptions);
          CoderProps := TBytes.Create(Info.PropertyByte);
          PackedBytes := TLzma2Encoder.EncodeRawBytes(Data, WorkOptions);
        end;
      sztcLzma:
        begin
          WorkOptions.Container := lcLzma;
          WorkOptions.LzmaEndMarker := False;
          Src := TBytesStream.Create(Data);
          StandaloneStream := TMemoryStream.Create;
          try
            TLzma2.Compress(Src, StandaloneStream, WorkOptions);
            SetLength(Standalone, StandaloneStream.Size);
            if StandaloneStream.Size > 0 then
            begin
              StandaloneStream.Position := 0;
              StandaloneStream.ReadBuffer(Standalone[0], StandaloneStream.Size);
            end;
          finally
            StandaloneStream.Free;
            Src.Free;
          end;
          CoderProps := Copy(Standalone, 0, 5);
          PackedBytes := Copy(Standalone, 13, Length(Standalone) - 13);
        end;
    else
      Assert.Fail('unsupported test 7z coder for solid fixture');
    end;
  end;

  procedure AppendCoder(var Target: TBytes);
  begin
    case Coder of
      sztcLzma:
        begin
          AppendByte(Target, $23);
          AppendByte(Target, $03);
          AppendByte(Target, $01);
          AppendByte(Target, $01);
        end;
      sztcLzma2:
        begin
          AppendByte(Target, $21);
          AppendByte(Target, XZ_ID_LZMA2);
        end;
    else
      Assert.Fail('unsupported test 7z coder for solid fixture');
    end;
    AppendSevenZipTestNumber(Target, Length(Props));
    AppendBytes(Target, Props);
  end;

begin
  SetLength(Combined, 0);
  AppendBytes(Combined, FirstData);
  AppendBytes(Combined, SecondData);
  EncodePayload(Combined, PackedBytes, Props);

  SetLength(Header, 0);
  AppendByte(Header, SEVENZ_NID_HEADER);
  AppendByte(Header, SEVENZ_NID_MAIN_STREAMS_INFO);
  AppendByte(Header, SEVENZ_NID_PACK_INFO);
  AppendSevenZipTestNumber(Header, 0);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(Header, Length(PackedBytes));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, Crc32Calc(PackedBytes));
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_UNPACK_INFO);
  AppendByte(Header, SEVENZ_NID_FOLDER);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, 0);
  AppendSevenZipTestNumber(Header, 1);
  AppendCoder(Header);
  AppendByte(Header, SEVENZ_NID_CODERS_UNPACK_SIZE);
  AppendSevenZipTestNumber(Header, Length(Combined));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, Crc32Calc(Combined));
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_SUB_STREAMS_INFO);
  AppendByte(Header, SEVENZ_NID_NUM_UNPACK_STREAM);
  AppendSevenZipTestNumber(Header, 2);
  AppendByte(Header, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(Header, Length(FirstData));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, Crc32Calc(FirstData));
  AppendUInt32LE(Header, Crc32Calc(SecondData));
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_FILES_INFO);
  AppendSevenZipTestNumber(Header, 2);
  NameBytes := TEncoding.Unicode.GetBytes('solid/a.bin' + #0 + 'solid/b.bin' + #0);
  AppendByte(Header, SEVENZ_NID_NAME);
  AppendSevenZipTestNumber(Header, UInt64(Length(NameBytes)) + 1);
  AppendByte(Header, 0);
  AppendBytes(Header, NameBytes);
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  SetLength(StartHeader, 0);
  AppendUInt64LE(StartHeader, UInt64(Length(PackedBytes)));
  AppendUInt64LE(StartHeader, UInt64(Length(Header)));
  AppendUInt32LE(StartHeader, Crc32Calc(Header));

  SetLength(SignatureHeader, 0);
  for I := 0 to High(SEVENZ_SIGNATURE) do
    AppendByte(SignatureHeader, SEVENZ_SIGNATURE[I]);
  AppendByte(SignatureHeader, 0);
  AppendByte(SignatureHeader, 4);
  AppendUInt32LE(SignatureHeader, Crc32Calc(StartHeader));
  AppendBytes(SignatureHeader, StartHeader);
  Assert.AreEqual(Integer(SEVENZ_SIGNATURE_HEADER_SIZE), Integer(Length(SignatureHeader)),
    'solid 7z signature header size');

  Result := SignatureHeader;
  AppendBytes(Result, PackedBytes);
  AppendBytes(Result, Header);
end;

class procedure TLzma2NativeTests.RoundTrip(const Container: TLzma2Container; const Check: TLzma2Check;
  const Data: TBytes);
var
  Options: TLzma2Options;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := Container;
  Options.Check := Check;
  Options.Level := 0;
  Options.ThreadCount := 2;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    if Length(Data) <> 0 then
      Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.DictionaryPropertyGrid;
var
  Info: TLzma2DictionaryInfo;
begin
  Assert.AreEqual(UInt64(4096), Lzma2DictionaryFromProperty(0));
  Assert.AreEqual(UInt64(6144), Lzma2DictionaryFromProperty(1));
  Assert.AreEqual(UInt64($FFFFFFFF), Lzma2DictionaryFromProperty(40));
  Assert.IsTrue(TryLzma2PropertyFromDictionary(4097, False, Info));
  Assert.AreEqual(UInt64(6144), Info.NormalizedSize);
  Assert.AreEqual(Byte(1), Info.PropertyByte);
  Assert.IsFalse(TryLzma2PropertyFromDictionary(4097, True, Info));
end;

procedure TLzma2NativeTests.DictionaryPropertyRejectsAboveMaxStrict;
var
  Info: TLzma2DictionaryInfo;
begin
  Assert.IsFalse(TryLzma2PropertyFromDictionary(UInt64($100000000), True, Info),
    'strict validation must reject dictionaries above the LZMA2 max property');
end;

procedure TLzma2NativeTests.Crc32XzKnownVectorAndSplitUpdate;
var
  Data: TBytes;
  LongData: TBytes;
  Crc: UInt32;
begin
  Data := TEncoding.ASCII.GetBytes('123456789');

  Assert.AreEqual(UInt32($CBF43926), Crc32Calc(Data), 'CRC32/XZ known vector mismatch');

  Crc := CRC_INIT_VAL;
  Crc := Crc32Update(Crc, @Data[0], 4);
  Crc := Crc32Update(Crc, @Data[4], Length(Data) - 4);
  Assert.AreEqual(Crc32Calc(Data), Crc xor CRC_INIT_VAL, 'CRC32/XZ split update mismatch');

  LongData := TEncoding.ASCII.GetBytes('x123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789');
  Assert.AreEqual(UInt32($AEC5B6F7), Crc32Calc(@LongData[1], Length(LongData) - 1),
    'CRC32/XZ unaligned slicing-by-16 vector mismatch');

  Crc := CRC_INIT_VAL;
  Crc := Crc32Update(Crc, @LongData[1], 17);
  Crc := Crc32Update(Crc, @LongData[18], 29);
  Crc := Crc32Update(Crc, @LongData[47], Length(LongData) - 47);
  Assert.AreEqual(UInt32($AEC5B6F7), Crc xor CRC_INIT_VAL,
    'CRC32/XZ long split update mismatch');
end;

procedure TLzma2NativeTests.Crc64XzKnownVectorAndSplitUpdate;
var
  Data: TBytes;
  LongData: TBytes;
  Crc: UInt64;
begin
  Data := TEncoding.ASCII.GetBytes('123456789');

  Assert.AreEqual(UInt64($995DC9BBDF1939FA), Crc64Calc(Data), 'CRC64/XZ known vector mismatch');

  Crc := CRC64_INIT_VAL;
  Crc := Crc64Update(Crc, @Data[0], 4);
  Crc := Crc64Update(Crc, @Data[4], Length(Data) - 4);
  Assert.AreEqual(Crc64Calc(Data), Crc xor CRC64_INIT_VAL, 'CRC64/XZ split update mismatch');

  LongData := TEncoding.ASCII.GetBytes('x123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789');
  Assert.AreEqual(UInt64($7FA2394038AE0836), Crc64Calc(@LongData[1], Length(LongData) - 1),
    'CRC64/XZ unaligned slicing-by-16 vector mismatch');

  Crc := CRC64_INIT_VAL;
  Crc := Crc64Update(Crc, @LongData[1], 17);
  Crc := Crc64Update(Crc, @LongData[18], 29);
  Crc := Crc64Update(Crc, @LongData[47], Length(LongData) - 47);
  Assert.AreEqual(UInt64($7FA2394038AE0836), Crc xor CRC64_INIT_VAL,
    'CRC64/XZ long split update mismatch');
end;

procedure TLzma2NativeTests.GreedyMatchFinderFindsLongestWithinDictionary;
var
  Data: TBytes;
  Finder: TLzmaGreedyMatchFinder;
  Match: TLzmaMatch;
  I: Integer;
begin
  Data := TBytes.Create(
    Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('E'),
    Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('E'));

  Finder := TLzmaGreedyMatchFinder.Create(Data, 0, Length(Data), 16, 32, 273);
  try
    for I := 0 to 4 do
      Finder.Insert(I);
    Match := Finder.Find(5);
    Assert.AreEqual(UInt32(5), Match.Length);
    Assert.AreEqual(UInt32(5), Match.Distance);
  finally
    Finder.Free;
  end;

  Finder := TLzmaGreedyMatchFinder.Create(Data, 0, Length(Data), 4, 32, 273);
  try
    for I := 0 to 4 do
      Finder.Insert(I);
    Match := Finder.Find(5);
    Assert.AreEqual(UInt32(0), Match.Length, 'dictionary limit must reject distance 5');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.GreedyMatchFinderReturnsIncreasingPairs;
var
  Data: TBytes;
  Finder: TLzmaGreedyMatchFinder;
  Matches: TLzmaMatchArray;
  I: Integer;
begin
  Data := TBytes.Create(
    Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('E'), Ord('F'),
    Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('X'), Ord('Y'), Ord('Z'),
    Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('E'), Ord('F'), Ord('Q'));

  Finder := TLzmaGreedyMatchFinder.Create(Data, 0, Length(Data), 32, 32, 273);
  try
    for I := 0 to 12 do
      Finder.Insert(I);
    Matches := Finder.GetMatches(13);
    Assert.AreEqual(2, Integer(Length(Matches)), 'match finder should expose SDK-style increasing match pairs');
    Assert.AreEqual(UInt32(4), Matches[0].Length, 'nearest candidate length');
    Assert.AreEqual(UInt32(7), Matches[0].Distance, 'nearest candidate distance');
    Assert.AreEqual(UInt32(6), Matches[1].Length, 'older candidate extends the match');
    Assert.AreEqual(UInt32(13), Matches[1].Distance, 'older candidate distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.GreedyMatchFinderReportsSdkTwoByteLowHashMatch;
var
  Data: TBytes;
  Finder: TLzmaGreedyMatchFinder;
  Matches: TLzmaMatchArray;
  I: Integer;
begin
  Data := TBytes.Create(
    Ord('A'), Ord('B'), Ord('x'), Ord('y'),
    Ord('A'), Ord('B'), Ord('C'));

  Finder := TLzmaGreedyMatchFinder.Create(Data, 0, Length(Data), 32, 32, 273);
  try
    for I := 0 to 3 do
      Finder.Insert(I);
    Matches := Finder.GetMatches(4);
    Assert.AreEqual(1, Integer(Length(Matches)), 'SDK HC/BT low hash should report a 2-byte match');
    Assert.AreEqual(UInt32(2), Matches[0].Length, 'low-hash match length');
    Assert.AreEqual(UInt32(4), Matches[0].Distance, 'low-hash match distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.GreedyMatchFinderHonorsCutValue;
var
  Data: TBytes;
  Finder: TLzmaGreedyMatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;

begin
  Data := BytesOfSize(48);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCZ');
  PutText(20, 'ABCDEFGH');

  Finder := TLzmaGreedyMatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 1);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(1, Integer(Length(Matches)), 'cutValue=1 should inspect only the newest candidate');
    Assert.AreEqual(UInt32(3), Matches[0].Length, 'newest candidate is only a 3-byte match');
    Assert.AreEqual(UInt32(10), Matches[0].Distance, 'newest candidate distance');
  finally
    Finder.Free;
  end;

  Finder := TLzmaGreedyMatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(UInt32(8), Matches[High(Matches)].Length,
      'larger cutValue should reach the older longer candidate');
    Assert.AreEqual(UInt32(20), Matches[High(Matches)].Distance, 'older candidate distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain4MatchFinderReturnsLowHashAndMainMatches;
var
  Data: TBytes;
  Finder: TLzmaHashChain4MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(48);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCZ');
  PutText(20, 'ABCDEFGH');

  Finder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 1);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(2, Integer(Length(Matches)), 'SDK HC4 should expose h3 low-hash and h4 main-chain matches');
    Assert.AreEqual(UInt32(3), Matches[0].Length, 'h3 low-hash match length');
    Assert.AreEqual(UInt32(10), Matches[0].Distance, 'h3 low-hash distance');
    Assert.AreEqual(UInt32(8), Matches[1].Length, 'h4 main-chain match length');
    Assert.AreEqual(UInt32(20), Matches[1].Distance, 'h4 main-chain distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain4AndBinaryTree4ExposeLowHashMatchThroughFourByteCollision;
var
  Bt4: TLzmaBinaryTree4MatchFinder;
  Data: TBytes;
  Hc4: TLzmaHashChain4MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(48);
  PutText(0, 'ABCDEFGH');
  Data[10] := 0;
  Data[11] := 4;
  Data[12] := 4;
  Data[13] := 126;
  PutText(20, 'ABCDEFGH');

  Hc4 := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 1);
  try
    Hc4.Insert(0);
    Hc4.Insert(10);
    Matches := Hc4.GetMatches(20);
    Assert.AreEqual(1, Integer(Length(Matches)),
      'SDK HC4 low-hash path must survive a newer four-byte hash collision at cutValue=1');
    Assert.AreEqual(UInt32(8), Matches[0].Length, 'HC4 h2 low-hash match length');
    Assert.AreEqual(UInt32(20), Matches[0].Distance, 'HC4 h2 low-hash distance');
  finally
    Hc4.Free;
  end;

  Bt4 := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 1);
  try
    Bt4.Insert(0);
    Bt4.Insert(10);
    Matches := Bt4.GetMatches(20);
    Assert.AreEqual(1, Integer(Length(Matches)),
      'SDK BT4 low-hash path must survive a newer four-byte hash collision at cutValue=1');
    Assert.AreEqual(UInt32(8), Matches[0].Length, 'BT4 h2 low-hash match length');
    Assert.AreEqual(UInt32(20), Matches[0].Distance, 'BT4 h2 low-hash distance');
  finally
    Bt4.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain4AndBinaryTree4SkipTailBelowFourBytesLikeSdk;
var
  Data: TBytes;
  Hc4: TLzmaHashChain4MatchFinder;
  Bt4: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(23);
  PutText(0, 'ABCD');
  PutText(20, 'ABC');

  Hc4 := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    Hc4.Insert(0);
    Matches := Hc4.GetMatches(20);
    Assert.AreEqual(0, Integer(Length(Matches)),
      'SDK GET_MATCHES_HEADER(4) skips HC4 low-hash output when fewer than four bytes remain');
  finally
    Hc4.Free;
  end;

  Bt4 := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    Bt4.Insert(0);
    Matches := Bt4.GetMatches(20);
    Assert.AreEqual(0, Integer(Length(Matches)),
      'SDK GET_MATCHES_HEADER(4) skips BT4 low-hash output when fewer than four bytes remain');
  finally
    Bt4.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain5MatchFinderUsesFiveByteMainHash;
var
  Data: TBytes;
  Finder: TLzmaHashChain5MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(48);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCDZ');
  PutText(20, 'ABCDEFGH');

  Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 1);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(2, Integer(Length(Matches)), 'SDK HC5 should expose h3 low-hash and h5 main-chain matches');
    Assert.AreEqual(UInt32(4), Matches[0].Length, 'HC5 low-hash can extend the h3 candidate to four bytes');
    Assert.AreEqual(UInt32(10), Matches[0].Distance, 'HC5 low-hash distance');
    Assert.AreEqual(UInt32(8), Matches[1].Length, 'HC5 main hash should skip the newer four-byte-only candidate');
    Assert.AreEqual(UInt32(20), Matches[1].Distance, 'HC5 main-chain distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain5MatchFinderUsesSdkCrcHashShape;
var
  Data: TBytes;
  Finder: TLzmaHashChain5MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutBytes(const Offset: Integer; const Bytes: array of Byte);
  var
    I: Integer;
  begin
    for I := 0 to High(Bytes) do
      Data[Offset + I] := Bytes[I];
  end;
begin
  Data := BytesOfSize(48);
  PutBytes(0, [Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('E'), Ord('F'), Ord('G'), Ord('H')]);
  PutBytes(10, [64, 82, 67, 64, 197, Ord('x'), Ord('x'), Ord('x')]);
  PutBytes(20, [Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('E'), Ord('F'), Ord('G'), Ord('H')]);

  Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 1);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.IsTrue(Length(Matches) > 0,
      'SDK CRC-based HC5 hashes should keep the older real candidate reachable despite a simple-hash collision');
    Assert.AreEqual(UInt32(8), Matches[High(Matches)].Length, 'older real candidate length');
    Assert.AreEqual(UInt32(20), Matches[High(Matches)].Distance, 'older real candidate distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain5MatchFinderSkipsTailBelowFiveBytesLikeSdk;
var
  Data: TBytes;
  Finder: TLzmaHashChain5MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(24);
  PutText(0, 'ABCD');
  PutText(20, 'ABCD');

  Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    Finder.Insert(0);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(0, Integer(Length(Matches)),
      'SDK GET_MATCHES_HEADER(5) skips HC5 low-hash output when fewer than five bytes remain');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain5MatchFinderHonorsDictionaryLimit;
var
  Data: TBytes;
  Finder: TLzmaHashChain5MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(32);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCDEFGH');
  PutText(20, 'ABCDEFGH');

  Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 8, 32, 273, 8);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(0, Integer(Length(Matches)), 'HC5 must reject matches beyond dictionary distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain4MatchFinderUsesDictionaryCyclicChainStorage;
const
  kDictionarySize = 4096;
var
  Data: TBytes;
  Finder: TLzmaHashChain4MatchFinder;
  Match: TLzmaMatch;
  Matches: TLzmaMatchArray;
begin
  Data := RepeatingBytes(1 shl 20);
  Finder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), kDictionarySize, 32, 273, 16);
  try
    Assert.AreEqual(NativeUInt(kDictionarySize + 1), Finder.ChainSlotCount,
      'SDK HC4 chain storage must be sized by cyclic dictionary window, not full source length');
    Finder.InsertRange(0, kDictionarySize + 32);
    Matches := Finder.GetMatches(kDictionarySize + 32);
    for Match in Matches do
      Assert.IsTrue(Match.Distance <= kDictionarySize, 'HC4 match distance must stay inside dictionary window');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain5MatchFinderUsesDictionaryCyclicChainStorage;
const
  kDictionarySize = 4096;
var
  Data: TBytes;
  Finder: TLzmaHashChain5MatchFinder;
  Match: TLzmaMatch;
  Matches: TLzmaMatchArray;
begin
  Data := RepeatingBytes(1 shl 20);
  Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), kDictionarySize, 32, 273, 16);
  try
    Assert.AreEqual(NativeUInt(kDictionarySize + 1), Finder.ChainSlotCount,
      'SDK HC5 chain storage must be sized by cyclic dictionary window, not full source length');
    Finder.SkipRangeMonotonic(0, kDictionarySize + 32);
    Matches := Finder.GetMatches(kDictionarySize + 32);
    for Match in Matches do
      Assert.IsTrue(Match.Distance <= kDictionarySize, 'HC5 match distance must stay inside dictionary window');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain4SkipRangeMonotonicMatchesClassicInsertRange;
const
  kProbeCount = 5;
  kProbes: array[0..kProbeCount - 1] of NativeUInt = (8, 17, 64, 257, 4093);
var
  Data: TBytes;

  procedure AssertBuffersEqual(const Expected, Actual: TLzmaMatchBuffer; const Context: string);
  var
    I: Integer;
  begin
    Assert.AreEqual(Expected.Count, Actual.Count, Context + ' pair count');
    for I := 0 to Expected.Count - 1 do
    begin
      Assert.AreEqual(Expected.Items[I].Length, Actual.Items[I].Length,
        Context + ' length at pair ' + I.ToString);
      Assert.AreEqual(Expected.Items[I].Distance, Actual.Items[I].Distance,
        Context + ' distance at pair ' + I.ToString);
    end;
  end;

  procedure CheckData(const CaseName: string; const Source: TBytes);
  var
    ClassicFinder: TLzmaHashChain4MatchFinder;
    FastFinder: TLzmaHashChain4MatchFinder;
    Expected: TLzmaMatchBuffer;
    Actual: TLzmaMatchBuffer;
    Probe: NativeUInt;
  begin
    for Probe in kProbes do
    begin
      ClassicFinder := TLzmaHashChain4MatchFinder.Create(Source, 0, Length(Source), 1024, 32, 273, 16);
      FastFinder := TLzmaHashChain4MatchFinder.Create(Source, 0, Length(Source), 1024, 32, 273, 16);
      try
        ClassicFinder.InsertRange(0, Probe);
        FastFinder.SkipRangeMonotonic(0, Probe);

        ClassicFinder.GetMatches(Probe, Expected);
        FastFinder.GetMatches(Probe, Actual);
        AssertBuffersEqual(Expected, Actual, CaseName + ' probe ' + Probe.ToString);
      finally
        FastFinder.Free;
        ClassicFinder.Free;
      end;
    end;
  end;

begin
  CheckData('repeat5', RepeatingBytes(8192));
  CheckData('pseudo-random', BytesOfSize(8192));

  Data := BytesOfSize(8192);
  Move(RepeatingBytes(2048)[0], Data[2048], 2048);
  CheckData('mixed', Data);
end;

procedure TLzma2NativeTests.HashChain4SkipRangeMonotonicMarksSkippedPositionsInserted;
var
  Actual: TLzmaMatchBuffer;
  ClassicFinder: TLzmaHashChain4MatchFinder;
  Data: TBytes;
  Expected: TLzmaMatchBuffer;
  FastFinder: TLzmaHashChain4MatchFinder;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;

  procedure AssertBuffersEqual(const Expected, Actual: TLzmaMatchBuffer; const Context: string);
  var
    I: Integer;
  begin
    Assert.AreEqual(Expected.Count, Actual.Count, Context + ' pair count');
    for I := 0 to Expected.Count - 1 do
    begin
      Assert.AreEqual(Expected.Items[I].Length, Actual.Items[I].Length,
        Context + ' length at pair ' + I.ToString);
      Assert.AreEqual(Expected.Items[I].Distance, Actual.Items[I].Distance,
        Context + ' distance at pair ' + I.ToString);
    end;
  end;
begin
  Data := BytesOfSize(32);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCDZZZZ');
  PutText(20, 'ABCDEFGH');

  ClassicFinder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  FastFinder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    ClassicFinder.InsertRange(0, 20);
    ClassicFinder.GetMatches(20, Expected);

    FastFinder.SkipRangeMonotonic(0, 20);
    FastFinder.Insert(10);
    FastFinder.GetMatches(20, Actual);

    AssertBuffersEqual(Expected, Actual, 'HC4 skip then duplicate insert');
    Assert.IsTrue(Actual.Count > 0, 'HC4 duplicate insert must preserve match evidence');
    Assert.AreEqual(UInt32(8), Actual.Last.Length,
      'HC4 duplicate insert must not hide the older long match');
    Assert.AreEqual(UInt32(20), Actual.Last.Distance,
      'HC4 duplicate insert must preserve the older chain link');
  finally
    FastFinder.Free;
    ClassicFinder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain5SkipRangeMonotonicMatchesClassicInsertRange;
const
  kProbeCount = 5;
  kProbes: array[0..kProbeCount - 1] of NativeUInt = (8, 17, 64, 257, 4093);
var
  Data: TBytes;

  procedure AssertBuffersEqual(const Expected, Actual: TLzmaMatchBuffer; const Context: string);
  var
    I: Integer;
  begin
    Assert.AreEqual(Expected.Count, Actual.Count, Context + ' pair count');
    for I := 0 to Expected.Count - 1 do
    begin
      Assert.AreEqual(Expected.Items[I].Length, Actual.Items[I].Length,
        Context + ' length at pair ' + I.ToString);
      Assert.AreEqual(Expected.Items[I].Distance, Actual.Items[I].Distance,
        Context + ' distance at pair ' + I.ToString);
    end;
  end;

  procedure CheckData(const CaseName: string; const Source: TBytes);
  var
    ClassicFinder: TLzmaHashChain5MatchFinder;
    FastFinder: TLzmaHashChain5MatchFinder;
    Expected: TLzmaMatchBuffer;
    Actual: TLzmaMatchBuffer;
    Probe: NativeUInt;
  begin
    for Probe in kProbes do
    begin
      ClassicFinder := TLzmaHashChain5MatchFinder.Create(Source, 0, Length(Source), 1024, 32, 273, 16);
      FastFinder := TLzmaHashChain5MatchFinder.Create(Source, 0, Length(Source), 1024, 32, 273, 16);
      try
        ClassicFinder.InsertRange(0, Probe);
        FastFinder.SkipRangeMonotonic(0, Probe);

        ClassicFinder.GetMatches(Probe, Expected);
        FastFinder.GetMatches(Probe, Actual);
        AssertBuffersEqual(Expected, Actual, CaseName + ' probe ' + Probe.ToString);
      finally
        FastFinder.Free;
        ClassicFinder.Free;
      end;
    end;
  end;

begin
  CheckData('repeat5', RepeatingBytes(8192));
  CheckData('pseudo-random', BytesOfSize(8192));

  Data := BytesOfSize(8192);
  Move(RepeatingBytes(2048)[0], Data[2048], 2048);
  CheckData('mixed', Data);
end;

procedure TLzma2NativeTests.HashChain5SkipRangeMonotonicMarksSkippedPositionsInserted;
var
  Actual: TLzmaMatchBuffer;
  ClassicFinder: TLzmaHashChain5MatchFinder;
  Data: TBytes;
  Expected: TLzmaMatchBuffer;
  FastFinder: TLzmaHashChain5MatchFinder;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;

  procedure AssertBuffersEqual(const Expected, Actual: TLzmaMatchBuffer; const Context: string);
  var
    I: Integer;
  begin
    Assert.AreEqual(Expected.Count, Actual.Count, Context + ' pair count');
    for I := 0 to Expected.Count - 1 do
    begin
      Assert.AreEqual(Expected.Items[I].Length, Actual.Items[I].Length,
        Context + ' length at pair ' + I.ToString);
      Assert.AreEqual(Expected.Items[I].Distance, Actual.Items[I].Distance,
        Context + ' distance at pair ' + I.ToString);
    end;
  end;
begin
  Data := BytesOfSize(32);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCDEZZZ');
  PutText(20, 'ABCDEFGH');

  ClassicFinder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  FastFinder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    ClassicFinder.InsertRange(0, 20);
    ClassicFinder.GetMatches(20, Expected);

    FastFinder.SkipRangeMonotonic(0, 20);
    FastFinder.Insert(10);
    FastFinder.GetMatches(20, Actual);

    AssertBuffersEqual(Expected, Actual, 'HC5 skip then duplicate insert');
    Assert.IsTrue(Actual.Count > 0, 'HC5 duplicate insert must preserve match evidence');
    Assert.AreEqual(UInt32(8), Actual.Last.Length,
      'HC5 duplicate insert must not hide the older long match');
    Assert.AreEqual(UInt32(20), Actual.Last.Distance,
      'HC5 duplicate insert must preserve the older chain link');
  finally
    FastFinder.Free;
    ClassicFinder.Free;
  end;
end;

procedure TLzma2NativeTests.BinaryTree4SkipRangeMonotonicMatchesClassicInsertRange;
const
  kProbeCount = 5;
  kProbes: array[0..kProbeCount - 1] of NativeUInt = (8, 17, 64, 257, 4093);
var
  Data: TBytes;

  procedure AssertBuffersEqual(const Expected, Actual: TLzmaMatchBuffer; const Context: string);
  var
    I: Integer;
  begin
    Assert.AreEqual(Expected.Count, Actual.Count, Context + ' pair count');
    for I := 0 to Expected.Count - 1 do
    begin
      Assert.AreEqual(Expected.Items[I].Length, Actual.Items[I].Length,
        Context + ' length at pair ' + I.ToString);
      Assert.AreEqual(Expected.Items[I].Distance, Actual.Items[I].Distance,
        Context + ' distance at pair ' + I.ToString);
    end;
  end;

  procedure CheckData(const CaseName: string; const Source: TBytes);
  var
    Actual: TLzmaMatchBuffer;
    ClassicFinder: TLzmaBinaryTree4MatchFinder;
    Expected: TLzmaMatchBuffer;
    FastFinder: TLzmaBinaryTree4MatchFinder;
    Probe: NativeUInt;
  begin
    for Probe in kProbes do
    begin
      ClassicFinder := TLzmaBinaryTree4MatchFinder.Create(Source, 0, Length(Source), 1024, 32, 273, 16);
      FastFinder := TLzmaBinaryTree4MatchFinder.Create(Source, 0, Length(Source), 1024, 32, 273, 16);
      try
        ClassicFinder.InsertRange(0, Probe);
        FastFinder.SkipRangeMonotonic(0, Probe);

        ClassicFinder.GetMatches(Probe, Expected);
        FastFinder.GetMatches(Probe, Actual);
        AssertBuffersEqual(Expected, Actual, CaseName + ' probe ' + Probe.ToString);
      finally
        FastFinder.Free;
        ClassicFinder.Free;
      end;
    end;
  end;

begin
  CheckData('repeat5', RepeatingBytes(8192));
  CheckData('pseudo-random', BytesOfSize(8192));

  Data := BytesOfSize(8192);
  Move(RepeatingBytes(2048)[0], Data[2048], 2048);
  CheckData('mixed', Data);
end;

procedure TLzma2NativeTests.BinaryTree4MatchFinderReturnsLowHashAndTreeMatches;
var
  Data: TBytes;
  Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(40);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCZ');
  PutText(20, 'ABCDEFGH');

  Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 1);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(2, Integer(Length(Matches)), 'SDK BT4 should expose h3 low-hash and h4 tree matches');
    Assert.AreEqual(UInt32(3), Matches[0].Length, 'BT4 h3 low-hash match length');
    Assert.AreEqual(UInt32(10), Matches[0].Distance, 'BT4 h3 low-hash distance');
    Assert.AreEqual(UInt32(8), Matches[1].Length, 'BT4 h4 tree match length');
    Assert.AreEqual(UInt32(20), Matches[1].Distance, 'BT4 h4 tree distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.BinaryTree4MatchFinderStartsFromNewestHashHead;
var
  Data: TBytes;
  Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(24);
  PutText(0, 'ABCDEFGH');
  PutText(8, 'ABCDEFGH');
  PutText(16, 'ABCDEFGH');

  Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 12, 32, 273, 1);
  try
    Finder.Insert(0);
    Finder.Insert(8);
    Matches := Finder.GetMatches(16);
    Assert.AreEqual(1, Integer(Length(Matches)), 'BT4 hash head should point at the newest candidate');
    Assert.AreEqual(UInt32(8), Matches[0].Length, 'BT4 newest-head match length');
    Assert.AreEqual(UInt32(8), Matches[0].Distance, 'BT4 newest-head match distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.BinaryTree4MatchFinderKeepsOlderTreeReachableFromNewestHead;
var
  Data: TBytes;
  Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(32);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCDZZZZ');
  PutText(20, 'ABCDEFGH');

  Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 4);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(2, Integer(Length(Matches)), 'BT4 newest head must keep the older tree reachable');
    Assert.AreEqual(UInt32(4), Matches[0].Length, 'BT4 newer short match length');
    Assert.AreEqual(UInt32(10), Matches[0].Distance, 'BT4 newer short match distance');
    Assert.AreEqual(UInt32(8), Matches[1].Length, 'BT4 older long match length');
    Assert.AreEqual(UInt32(20), Matches[1].Distance, 'BT4 older long match distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.BinaryTree4MatchFinderUsesDictionaryCyclicSonStorage;
const
  kDictionarySize = 4096;
var
  Data: TBytes;
  Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchArray;
  Match: TLzmaMatch;
begin
  Data := RepeatingBytes(1 shl 20);
  Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), kDictionarySize, 32, 273, 32);
  try
    Assert.AreEqual(NativeUInt((kDictionarySize + 1) * 2), Finder.SonSlotCount,
      'SDK BT4 son storage must be sized by cyclic dictionary window, not full source length');
    Finder.InsertRange(0, kDictionarySize + 16);
    Matches := Finder.GetMatches(kDictionarySize + 16);
    for Match in Matches do
      Assert.IsTrue(Match.Distance <= kDictionarySize, 'BT4 match distance must stay inside dictionary window');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.BinaryTree4MatchFinderHonorsDictionaryLimit;
var
  Data: TBytes;
  Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchArray;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(32);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCDEFGH');
  PutText(20, 'ABCDEFGH');

  Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 8, 32, 273, 8);
  try
    Finder.Insert(0);
    Finder.Insert(10);
    Matches := Finder.GetMatches(20);
    Assert.AreEqual(0, Integer(Length(Matches)), 'BT4 must reject matches beyond dictionary distance');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain4MatchFinderReadMatchesInsertsCurrentPosition;
var
  Data: TBytes;
  Finder: TLzmaHashChain4MatchFinder;
  Matches: TLzmaMatchBuffer;
begin
  Data := TEncoding.ASCII.GetBytes('aaaaaaaa');
  Finder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 16, 32, 273, 8);
  try
    Finder.ReadMatches(0, Matches);
    Assert.AreEqual(0, Matches.Count, 'position 0 has no previous candidates');

    Finder.GetMatches(1, Matches);
    Assert.IsTrue(Matches.Count > 0, 'SDK-style ReadMatches must insert the current position for lookahead');
    Assert.AreEqual(UInt32(7), Matches.Last.Length, 'lookahead should see position 0 as a distance-one match');
    Assert.AreEqual(UInt32(1), Matches.Last.Distance, 'lookahead distance is the current position');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.BinaryTree4MatchFinderReadMatchesInsertsCurrentPosition;
var
  Data: TBytes;
  Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchBuffer;
begin
  Data := TEncoding.ASCII.GetBytes('aaaaaaaa');
  Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 16, 32, 273, 8);
  try
    Finder.ReadMatches(0, Matches);
    Assert.AreEqual(0, Matches.Count, 'position 0 has no previous candidates');

    Finder.GetMatches(1, Matches);
    Assert.IsTrue(Matches.Count > 0, 'SDK-style ReadMatches must insert the current position for lookahead');
    Assert.AreEqual(UInt32(7), Matches.Last.Length, 'lookahead should see position 0 as a distance-one match');
    Assert.AreEqual(UInt32(1), Matches.Last.Distance, 'lookahead distance is the current position');
  finally
    Finder.Free;
  end;
end;

procedure TLzma2NativeTests.MatchFindersIgnoreOutOfRangePositions;
var
  Data: TBytes;
  GreedyFinder: TLzmaGreedyMatchFinder;
  Hc4Finder: TLzmaHashChain4MatchFinder;
  Hc5Finder: TLzmaHashChain5MatchFinder;
  Bt4Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchBuffer;
begin
  Data := TEncoding.ASCII.GetBytes('abcdefgh');

  GreedyFinder := TLzmaGreedyMatchFinder.Create(Data, 0, Length(Data), 16, 32, 273, 8);
  try
    GreedyFinder.Insert(High(NativeUInt));
    GreedyFinder.InsertRange(High(NativeUInt), 3);
    GreedyFinder.GetMatches(High(NativeUInt), Matches);
    Assert.AreEqual(0, Matches.Count, 'greedy out-of-range match count');
  finally
    GreedyFinder.Free;
  end;

  Hc4Finder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 16, 32, 273, 8);
  try
    Hc4Finder.Insert(High(NativeUInt));
    Hc4Finder.InsertRange(High(NativeUInt), 3);
    Hc4Finder.GetMatches(High(NativeUInt), Matches);
    Assert.AreEqual(0, Matches.Count, 'HC4 out-of-range match count');
  finally
    Hc4Finder.Free;
  end;

  Hc5Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 16, 32, 273, 8);
  try
    Hc5Finder.Insert(High(NativeUInt));
    Hc5Finder.InsertRange(High(NativeUInt), 3);
    Hc5Finder.GetMatches(High(NativeUInt), Matches);
    Assert.AreEqual(0, Matches.Count, 'HC5 out-of-range match count');
  finally
    Hc5Finder.Free;
  end;

  Bt4Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 16, 32, 273, 8);
  try
    Bt4Finder.Insert(High(NativeUInt));
    Bt4Finder.InsertRange(High(NativeUInt), 3);
    Bt4Finder.GetMatches(High(NativeUInt), Matches);
    Assert.AreEqual(0, Matches.Count, 'BT4 out-of-range match count');
  finally
    Bt4Finder.Free;
  end;
end;

procedure TLzma2NativeTests.MatchFinderReadMatchesIsIdempotent;
var
  Data: TBytes;
  Hc4Finder: TLzmaHashChain4MatchFinder;
  Hc5Finder: TLzmaHashChain5MatchFinder;
  Bt4Finder: TLzmaBinaryTree4MatchFinder;
  Matches: TLzmaMatchBuffer;
  RepeatedMatches: TLzmaMatchBuffer;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(32);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCDZZZZ');
  PutText(20, 'ABCDEFGH');

  Hc4Finder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    Hc4Finder.ReadMatches(0, Matches);
    Hc4Finder.ReadMatches(10, Matches);
    Assert.AreEqual(UInt32(4), Matches.Last.Length, 'first HC4 ReadMatches at position 10');
    Hc4Finder.ReadMatches(10, RepeatedMatches);
    Assert.AreEqual(Matches.Count, RepeatedMatches.Count, 'duplicate HC4 ReadMatches pair count');
    Assert.AreEqual(Matches.Last.Length, RepeatedMatches.Last.Length, 'duplicate HC4 ReadMatches length');
    Assert.AreEqual(Matches.Last.Distance, RepeatedMatches.Last.Distance, 'duplicate HC4 ReadMatches distance');
    Hc4Finder.GetMatches(20, Matches);
    Assert.IsTrue(Matches.Count > 0, 'duplicate HC4 ReadMatches must preserve future matches');
    Assert.AreEqual(UInt32(8), Matches.Last.Length, 'duplicate HC4 ReadMatches must not hide older long matches');
    Assert.AreEqual(UInt32(20), Matches.Last.Distance, 'duplicate HC4 ReadMatches must preserve the older chain link');
  finally
    Hc4Finder.Free;
  end;

  Hc5Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    Hc5Finder.ReadMatches(0, Matches);
    Hc5Finder.ReadMatches(10, Matches);
    Assert.AreEqual(UInt32(4), Matches.Last.Length, 'first HC5 ReadMatches at position 10');
    Hc5Finder.ReadMatches(10, RepeatedMatches);
    Assert.AreEqual(Matches.Count, RepeatedMatches.Count, 'duplicate HC5 ReadMatches pair count');
    Assert.AreEqual(Matches.Last.Length, RepeatedMatches.Last.Length, 'duplicate HC5 ReadMatches length');
    Assert.AreEqual(Matches.Last.Distance, RepeatedMatches.Last.Distance, 'duplicate HC5 ReadMatches distance');
    Hc5Finder.GetMatches(20, Matches);
    Assert.IsTrue(Matches.Count > 0, 'duplicate HC5 ReadMatches must preserve future matches');
    Assert.AreEqual(UInt32(8), Matches.Last.Length, 'duplicate HC5 ReadMatches must not hide older long matches');
    Assert.AreEqual(UInt32(20), Matches.Last.Distance, 'duplicate HC5 ReadMatches must preserve the older chain link');
  finally
    Hc5Finder.Free;
  end;

  Bt4Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data), 64, 32, 273, 8);
  try
    Bt4Finder.ReadMatches(0, Matches);
    Bt4Finder.ReadMatches(10, Matches);
    Assert.AreEqual(UInt32(4), Matches.Last.Length, 'first BT4 ReadMatches at position 10');
    Bt4Finder.ReadMatches(10, RepeatedMatches);
    Assert.AreEqual(Matches.Count, RepeatedMatches.Count, 'duplicate BT4 ReadMatches pair count');
    Assert.AreEqual(Matches.Last.Length, RepeatedMatches.Last.Length, 'duplicate BT4 ReadMatches length');
    Assert.AreEqual(Matches.Last.Distance, RepeatedMatches.Last.Distance, 'duplicate BT4 ReadMatches distance');
    Bt4Finder.GetMatches(20, Matches);
    Assert.IsTrue(Matches.Count > 0, 'duplicate BT4 ReadMatches must preserve future matches');
    Assert.AreEqual(UInt32(8), Matches.Last.Length, 'duplicate BT4 ReadMatches must not hide older long matches');
    Assert.AreEqual(UInt32(20), Matches.Last.Distance, 'duplicate BT4 ReadMatches must preserve the older tree link');
  finally
    Bt4Finder.Free;
  end;
end;

function MatchFinderTraceFixturePath: string;
begin
  Result := TPath.Combine(GetCurrentDir, 'tests\fixtures\match-finder\sdk-reference-traces.json');
end;

function MatchFinderTraceArtifactPath: string;
begin
  Result := TPath.Combine(GetCurrentDir, 'artifacts\match-finder\sdk-trace-parity.json');
end;

function RequiredJsonValue(const Obj: TJSONObject; const Name: string): TJSONValue;
begin
  Result := Obj.GetValue(Name);
  Assert.IsNotNull(Result, Format('match-finder trace fixture missing "%s"', [Name]));
end;

function JsonStringValue(const Obj: TJSONObject; const Name: string): string;
begin
  Result := RequiredJsonValue(Obj, Name).Value;
end;

function JsonIntValue(const Obj: TJSONObject; const Name: string): Integer;
begin
  Result := StrToInt(RequiredJsonValue(Obj, Name).Value);
end;

function LoadMatchFinderTraceRoot: TJSONObject;
var
  JsonText: string;
  JsonValue: TJSONValue;
begin
  Assert.IsTrue(TFile.Exists(MatchFinderTraceFixturePath),
    'SDK match-finder reference trace fixture is missing');
  JsonText := TFile.ReadAllText(MatchFinderTraceFixturePath, TEncoding.UTF8);
  JsonValue := TJSONObject.ParseJSONValue(JsonText);
  Assert.IsNotNull(JsonValue, 'SDK match-finder reference trace fixture is invalid JSON');
  Assert.IsTrue(JsonValue is TJSONObject, 'SDK match-finder reference trace fixture must be a JSON object');
  Result := TJSONObject(JsonValue);
end;

function FindMatchFinderTrace(const Root: TJSONObject; const TraceId: string): TJSONObject;
var
  Traces: TJSONArray;
  I: Integer;
  Trace: TJSONObject;
begin
  Traces := RequiredJsonValue(Root, 'traces') as TJSONArray;
  for I := 0 to Traces.Count - 1 do
  begin
    Trace := Traces.Items[I] as TJSONObject;
    if SameText(JsonStringValue(Trace, 'id'), TraceId) then
      Exit(Trace);
  end;
  Assert.Fail('SDK match-finder reference trace not found: ' + TraceId);
  Result := nil;
end;

function BuildMatchFinderTraceData(const Trace: TJSONObject): TBytes;
var
  I: Integer;
  J: Integer;
  ByteValues: TJSONArray;
  Segments: TJSONArray;
  Segment: TJSONObject;
  SegmentBytes: TBytes;
  Offset: Integer;
begin
  SetLength(Result, JsonIntValue(Trace, 'sourceSize'));
  for J := 0 to Length(Result) - 1 do
    Result[J] := Byte((J * 131 + J div 7) and $FF);
  Segments := RequiredJsonValue(Trace, 'segments') as TJSONArray;
  for I := 0 to Segments.Count - 1 do
  begin
    Segment := Segments.Items[I] as TJSONObject;
    Offset := JsonIntValue(Segment, 'offset');
    if Assigned(Segment.GetValue('bytes')) then
    begin
      ByteValues := Segment.GetValue('bytes') as TJSONArray;
      SetLength(SegmentBytes, ByteValues.Count);
      for J := 0 to ByteValues.Count - 1 do
        SegmentBytes[J] := Byte(StrToInt(ByteValues.Items[J].Value));
    end
    else
      SegmentBytes := TEncoding.ASCII.GetBytes(JsonStringValue(Segment, 'ascii'));
    Assert.IsTrue((Offset >= 0) and (Offset + Length(SegmentBytes) <= Length(Result)),
      'SDK match-finder trace segment is outside the fixture buffer');
    if Length(SegmentBytes) > 0 then
      Move(SegmentBytes[0], Result[Offset], Length(SegmentBytes));
  end;
end;

function MatchFinderTraceIdsFromFixture: TArray<string>;
var
  Root: TJSONObject;
  Traces: TJSONArray;
  I: Integer;
begin
  Root := LoadMatchFinderTraceRoot;
  try
    Traces := RequiredJsonValue(Root, 'traces') as TJSONArray;
    SetLength(Result, Traces.Count);
    for I := 0 to Traces.Count - 1 do
      Result[I] := JsonStringValue(Traces.Items[I] as TJSONObject, 'id');
  finally
    Root.Free;
  end;
end;

function ExpectedMatchesFromTrace(const Trace: TJSONObject): TLzmaMatchArray;
var
  Expected: TJSONArray;
  MatchObj: TJSONObject;
  I: Integer;
begin
  Expected := RequiredJsonValue(Trace, 'expected') as TJSONArray;
  SetLength(Result, Expected.Count);
  for I := 0 to Expected.Count - 1 do
  begin
    MatchObj := Expected.Items[I] as TJSONObject;
    Result[I].Length := UInt32(JsonIntValue(MatchObj, 'length'));
    Result[I].Distance := UInt32(JsonIntValue(MatchObj, 'distance'));
  end;
end;

procedure AssertMatchArraysEqual(const Expected, Actual: TLzmaMatchArray; const Message: string);
var
  I: Integer;
begin
  Assert.AreEqual(Integer(Length(Expected)), Integer(Length(Actual)), Message + ' pair count');
  for I := 0 to High(Expected) do
  begin
    Assert.AreEqual(Expected[I].Length, Actual[I].Length,
      Format('%s pair %d length', [Message, I]));
    Assert.AreEqual(Expected[I].Distance, Actual[I].Distance,
      Format('%s pair %d distance', [Message, I]));
  end;
end;

function ComputeMatchFinderTrace(const TraceId: string): TMatchFinderTraceResult;
var
  Root: TJSONObject;
  Trace: TJSONObject;
  Data: TBytes;
  Inserts: TJSONArray;
  Operations: TJSONArray;
  Operation: TJSONObject;
  OperationsValue: TJSONValue;
  InsertPos: NativeUInt;
  QueryPos: NativeUInt;
  DictionarySize: UInt64;
  FastBytes: UInt32;
  MaxMatchLen: UInt32;
  CutValue: UInt32;
  I: Integer;
  Hc4Finder: TLzmaHashChain4MatchFinder;
  Hc5Finder: TLzmaHashChain5MatchFinder;
  Bt4Finder: TLzmaBinaryTree4MatchFinder;
begin
  Root := LoadMatchFinderTraceRoot;
  try
    Trace := FindMatchFinderTrace(Root, TraceId);
    Result.TraceId := TraceId;
    Result.Finder := JsonStringValue(Trace, 'finder');
    Result.Expected := ExpectedMatchesFromTrace(Trace);
    Data := BuildMatchFinderTraceData(Trace);
    Inserts := nil;
    if Assigned(Trace.GetValue('inserts')) then
      Inserts := Trace.GetValue('inserts') as TJSONArray;
    OperationsValue := Trace.GetValue('operations');
    Operations := nil;
    if Assigned(OperationsValue) then
      Operations := OperationsValue as TJSONArray;
    QueryPos := NativeUInt(JsonIntValue(Trace, 'query'));
    DictionarySize := UInt64(JsonIntValue(Trace, 'dictionarySize'));
    FastBytes := UInt32(JsonIntValue(Trace, 'fastBytes'));
    MaxMatchLen := UInt32(JsonIntValue(Trace, 'maxMatchLen'));
    CutValue := UInt32(JsonIntValue(Trace, 'cutValue'));

    if SameText(Result.Finder, 'HC4') then
    begin
      Hc4Finder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data),
        DictionarySize, FastBytes, MaxMatchLen, CutValue);
      try
        if Assigned(Operations) then
        begin
          for I := 0 to Operations.Count - 1 do
          begin
            Operation := Operations.Items[I] as TJSONObject;
            if SameText(JsonStringValue(Operation, 'op'), 'insert') then
              Hc4Finder.Insert(NativeUInt(JsonIntValue(Operation, 'pos')))
            else if SameText(JsonStringValue(Operation, 'op'), 'skip') then
              Hc4Finder.SkipRangeMonotonic(NativeUInt(JsonIntValue(Operation, 'start')),
                NativeUInt(JsonIntValue(Operation, 'count')))
            else
              Assert.Fail('Unsupported HC4 SDK match-finder trace operation: ' + JsonStringValue(Operation, 'op'));
          end;
        end
        else
        begin
          for I := 0 to Inserts.Count - 1 do
          begin
            InsertPos := NativeUInt(StrToInt(Inserts.Items[I].Value));
            Hc4Finder.Insert(InsertPos);
          end;
        end;
        Result.Actual := Hc4Finder.GetMatches(QueryPos);
      finally
        Hc4Finder.Free;
      end;
    end
    else if SameText(Result.Finder, 'HC5') then
    begin
      Hc5Finder := TLzmaHashChain5MatchFinder.Create(Data, 0, Length(Data),
        DictionarySize, FastBytes, MaxMatchLen, CutValue);
      try
        if Assigned(Operations) then
        begin
          for I := 0 to Operations.Count - 1 do
          begin
            Operation := Operations.Items[I] as TJSONObject;
            if SameText(JsonStringValue(Operation, 'op'), 'insert') then
              Hc5Finder.Insert(NativeUInt(JsonIntValue(Operation, 'pos')))
            else if SameText(JsonStringValue(Operation, 'op'), 'skip') then
              Hc5Finder.SkipRangeMonotonic(NativeUInt(JsonIntValue(Operation, 'start')),
                NativeUInt(JsonIntValue(Operation, 'count')))
            else
              Assert.Fail('Unsupported HC5 SDK match-finder trace operation: ' + JsonStringValue(Operation, 'op'));
          end;
        end
        else
        begin
          for I := 0 to Inserts.Count - 1 do
          begin
            InsertPos := NativeUInt(StrToInt(Inserts.Items[I].Value));
            Hc5Finder.Insert(InsertPos);
          end;
        end;
        Result.Actual := Hc5Finder.GetMatches(QueryPos);
      finally
        Hc5Finder.Free;
      end;
    end
    else if SameText(Result.Finder, 'BT4') then
    begin
      Bt4Finder := TLzmaBinaryTree4MatchFinder.Create(Data, 0, Length(Data),
        DictionarySize, FastBytes, MaxMatchLen, CutValue);
      try
        if Assigned(Operations) then
        begin
          for I := 0 to Operations.Count - 1 do
          begin
            Operation := Operations.Items[I] as TJSONObject;
            if SameText(JsonStringValue(Operation, 'op'), 'insert') then
              Bt4Finder.Insert(NativeUInt(JsonIntValue(Operation, 'pos')))
            else if SameText(JsonStringValue(Operation, 'op'), 'skip') then
              Bt4Finder.SkipRangeMonotonic(NativeUInt(JsonIntValue(Operation, 'start')),
                NativeUInt(JsonIntValue(Operation, 'count')))
            else
              Assert.Fail('Unsupported BT4 SDK match-finder trace operation: ' + JsonStringValue(Operation, 'op'));
          end;
        end
        else
        begin
          for I := 0 to Inserts.Count - 1 do
          begin
            InsertPos := NativeUInt(StrToInt(Inserts.Items[I].Value));
            Bt4Finder.Insert(InsertPos);
          end;
        end;
        Result.Actual := Bt4Finder.GetMatches(QueryPos);
      finally
        Bt4Finder.Free;
      end;
    end
    else
      Assert.Fail('Unsupported SDK match-finder reference trace finder: ' + Result.Finder);
  finally
    Root.Free;
  end;
end;

function MatchArrayToJson(const Matches: TLzmaMatchArray): TJSONArray;
var
  I: Integer;
  MatchObj: TJSONObject;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(Matches) do
  begin
    MatchObj := TJSONObject.Create;
    MatchObj.AddPair('length', TJSONNumber.Create(Integer(Matches[I].Length)));
    MatchObj.AddPair('distance', TJSONNumber.Create(Integer(Matches[I].Distance)));
    Result.AddElement(MatchObj);
  end;
end;

procedure WriteMatchFinderTraceArtifact(const Results: array of TMatchFinderTraceResult);
var
  Root: TJSONObject;
  Traces: TJSONArray;
  Trace: TJSONObject;
  I: Integer;
begin
  ForceDirectories(TPath.GetDirectoryName(MatchFinderTraceArtifactPath));
  Root := TJSONObject.Create;
  try
    Root.AddPair('schemaVersion', TJSONNumber.Create(1));
    Root.AddPair('sdk', 'LZMA SDK 26.01 C/LzFind.c reference trace');
    Root.AddPair('fixture', StringReplace(MatchFinderTraceFixturePath, '\', '/', [rfReplaceAll]));
    Traces := TJSONArray.Create;
    Root.AddPair('traces', Traces);
    for I := 0 to High(Results) do
    begin
      Trace := TJSONObject.Create;
      Trace.AddPair('id', Results[I].TraceId);
      Trace.AddPair('finder', Results[I].Finder);
      Trace.AddPair('status', 'passed');
      Trace.AddPair('expected', MatchArrayToJson(Results[I].Expected));
      Trace.AddPair('actual', MatchArrayToJson(Results[I].Actual));
      Traces.AddElement(Trace);
    end;
    TFile.WriteAllText(MatchFinderTraceArtifactPath, Root.ToJSON, TEncoding.UTF8);
  finally
    Root.Free;
  end;
end;

procedure TLzma2NativeTests.HashChain4MatchesSdkReferenceTrace;
var
  Trace: TMatchFinderTraceResult;
begin
  Trace := ComputeMatchFinderTrace('hc4-basic-two-heads');
  AssertMatchArraysEqual(Trace.Expected, Trace.Actual, 'HC4 SDK reference trace');
end;

procedure TLzma2NativeTests.HashChain5MatchesSdkReferenceTrace;
var
  Trace: TMatchFinderTraceResult;
begin
  Trace := ComputeMatchFinderTrace('hc5-basic-two-heads');
  AssertMatchArraysEqual(Trace.Expected, Trace.Actual, 'HC5 SDK reference trace');
end;

procedure TLzma2NativeTests.BinaryTree4MatchesSdkReferenceTrace;
var
  Trace: TMatchFinderTraceResult;
begin
  Trace := ComputeMatchFinderTrace('bt4-basic-two-heads');
  AssertMatchArraysEqual(Trace.Expected, Trace.Actual, 'BT4 SDK reference trace');
end;

procedure TLzma2NativeTests.MatchFinderSdkReferenceTraceArtifactIsWritten;
var
  I: Integer;
  TraceIds: TArray<string>;
  Results: TArray<TMatchFinderTraceResult>;
begin
  TraceIds := MatchFinderTraceIdsFromFixture;
  SetLength(Results, Length(TraceIds));
  for I := 0 to High(TraceIds) do
  begin
    Results[I] := ComputeMatchFinderTrace(TraceIds[I]);
    AssertMatchArraysEqual(Results[I].Expected, Results[I].Actual,
      'SDK reference trace artifact ' + TraceIds[I]);
  end;
  WriteMatchFinderTraceArtifact(Results);
  Assert.IsTrue(TFile.Exists(MatchFinderTraceArtifactPath),
    'SDK match-finder reference trace parity artifact must be written');
end;

procedure TLzma2NativeTests.RawLzma2RoundTripsCopyChunks;
begin
  RoundTrip(lcRawLzma2, lzCheckNone, BytesOfSize(0));
  RoundTrip(lcRawLzma2, lzCheckNone, BytesOfSize(1));
  RoundTrip(lcRawLzma2, lzCheckNone, BytesOfSize(65536));
  RoundTrip(lcRawLzma2, lzCheckNone, BytesOfSize(131099));
end;

procedure TLzma2NativeTests.LevelOneWritesCompressedChunks;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Data := BytesOfSize(70000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size > 0, 'encoded stream is empty');
    Assert.IsTrue(PByte(Encoded.Memory)^ >= $80, 'this level 1 fixture should start with a compressed LZMA2 chunk');
    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.Lzma2CompressedChunksCanReusePropsAfterFirstChunk;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  EncodedBytes: TBytes;
  OutBytes: TBytes;
  Pos: Integer;
  Control: Byte;
  ChunkSize: Integer;
  PackSize: Integer;
  CompressedChunks: Integer;
  NoPropsChunks: Integer;
begin
  SetLength(Data, 12 * 1024);
  if Length(Data) <> 0 then
    FillChar(Data[0], Length(Data), Ord('A'));

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.BufferSize := 4 * 1024;
  Options.ThreadCount := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));

    Pos := 0;
    CompressedChunks := 0;
    NoPropsChunks := 0;
    while Pos < Length(EncodedBytes) do
    begin
      Control := EncodedBytes[Pos];
      Inc(Pos);
      if Control = LZMA2_CONTROL_EOF then
        Break;
      if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
      begin
        Assert.IsTrue(Pos + 2 <= Length(EncodedBytes), 'truncated copy chunk header');
        ChunkSize := ((Integer(EncodedBytes[Pos]) shl 8) or Integer(EncodedBytes[Pos + 1])) + 1;
        Inc(Pos, 2 + ChunkSize);
        Continue;
      end;

      Assert.IsTrue(Control >= $80, 'invalid compressed LZMA2 chunk control');
      Assert.IsTrue(Pos + 4 <= Length(EncodedBytes), 'truncated compressed chunk header');
      ChunkSize := ((Integer(Control and $1F) shl 16) or
        (Integer(EncodedBytes[Pos]) shl 8) or Integer(EncodedBytes[Pos + 1])) + 1;
      PackSize := ((Integer(EncodedBytes[Pos + 2]) shl 8) or Integer(EncodedBytes[Pos + 3])) + 1;
      Inc(Pos, 4);
      if (Control and $40) <> 0 then
        Inc(Pos)
      else if Control >= $A0 then
        Inc(NoPropsChunks);
      Assert.IsTrue(ChunkSize <= 4 * 1024, 'test fixture should respect requested chunk size');
      Assert.IsTrue(Pos + PackSize <= Length(EncodedBytes), 'truncated compressed chunk payload');
      Inc(Pos, PackSize);
      Inc(CompressedChunks);
    end;

    Assert.IsTrue(CompressedChunks >= 2, 'fixture should contain multiple compressed chunks');
    Assert.IsTrue(NoPropsChunks >= 1, 'later compressed chunks should reuse the first chunk properties');

    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'no-props LZMA2 compressed chunk round-trip');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.Lzma2CompressedOptionsUseSdkTwoMiBChunkLimit;
var
  Options: TLzma2Options;
  Normalized: TLzma2Options;
begin
  Options := TLzma2.DefaultOptions;
  Assert.AreEqual(NativeUInt(2 shl 20), Options.BufferSize,
    'default compressed LZMA2 buffer should follow SDK 2 MiB unpack limit');

  Options.Level := 1;
  Options.BufferSize := 4 shl 20;
  Normalized := TLzma2Encoder.NormalizeOptions(Options);
  Assert.AreEqual(NativeUInt(2 shl 20), Normalized.BufferSize,
    'compressed LZMA2 chunks should cap unpack size at the SDK 2 MiB limit');

  Options.Level := 0;
  Options.BufferSize := 4 shl 20;
  Normalized := TLzma2Encoder.NormalizeOptions(Options);
  Assert.AreEqual(NativeUInt(LZMA2_COPY_CHUNK_SIZE), Normalized.BufferSize,
    'copy chunks must keep the 64 KiB LZMA2 copy packet limit');
end;

procedure TLzma2NativeTests.GreedyEncoderCompressesRepeatingData;
var
  Options: TLzma2Options;
  Data: TBytes;
  I: Integer;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  SetLength(Data, 65536);
  for I := 0 to High(Data) do
    Data[I] := Byte(Ord('A') + (I mod 5));

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size < Length(Data) div 4, 'greedy match encoder did not reduce repeating input enough');
    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaProfileMatchesSdkDefaults;
var
  Profile: TLzmaEncoderProfile;
begin
  Profile := TLzmaRawEncoder.NormalizeProfile(0, 0);
  Assert.AreEqual(UInt64(1 shl 16), Profile.DictionarySize, 'level 0 raw LZMA dictionary');
  Assert.AreEqual(32, Profile.FastBytes, 'level 0 raw LZMA fast bytes');
  Assert.AreEqual(0, Profile.Algorithm, 'level 0 raw LZMA algorithm');

  Profile := TLzmaRawEncoder.NormalizeProfile(4, 0);
  Assert.AreEqual(UInt64(1 shl 24), Profile.DictionarySize, 'level 4 raw LZMA dictionary');
  Assert.AreEqual(32, Profile.FastBytes, 'level 4 raw LZMA fast bytes');
  Assert.AreEqual(0, Profile.Algorithm, 'SDK fast algorithm applies below level 5');

  Profile := TLzmaRawEncoder.NormalizeProfile(7, 0);
  Assert.AreEqual(UInt64(1) shl 27, Profile.DictionarySize, 'level 7 raw LZMA dictionary');
  Assert.AreEqual(64, Profile.FastBytes, 'level 7 raw LZMA fast bytes');
  Assert.AreEqual(1, Profile.Algorithm, 'SDK normal algorithm applies at level 5 and above');

  Profile := TLzmaRawEncoder.NormalizeProfile(9, 12345);
  Assert.AreEqual(UInt64(12345), Profile.DictionarySize, 'explicit raw LZMA dictionary must be preserved');
  Assert.AreEqual(64, Profile.FastBytes, 'level 9 raw LZMA fast bytes');
  Assert.AreEqual(1, Profile.Algorithm, 'level 9 raw LZMA algorithm');
end;

procedure TLzma2NativeTests.RawLzmaProfileMatchesSdkMatchFinderTuning;
var
  Profile: TLzmaEncoderProfile;
begin
  Profile := TLzmaRawEncoder.NormalizeProfile(1, 0);
  Assert.AreEqual(Ord(mfHashChain5), Ord(Profile.MatchFinderKind), 'level 1 SDK match finder');
  Assert.AreEqual(5, Profile.NumHashBytes, 'level 1 SDK numHashBytes');
  Assert.AreEqual('hc5-fast-greedy', Profile.MatchFinder, 'level 1 active SDK HC5 finder');
  Assert.AreEqual(UInt32(16), Profile.CutValue, 'level 1 SDK cutValue');
  Assert.AreEqual(1, Profile.DefaultThreadCount, 'level 1 SDK default threads');
  Assert.AreEqual(Ord(lpmSdkProfile), Ord(Profile.ParserMode), 'level 1 parser mode');
  Assert.AreEqual(Ord(lmfpHashChain5), Ord(Profile.MatchFinderProfile), 'level 1 public match finder profile');

  Profile := TLzmaRawEncoder.NormalizeProfile(5, 0);
  Assert.AreEqual(Ord(mfBinaryTree4), Ord(Profile.MatchFinderKind), 'level 5 SDK match finder');
  Assert.AreEqual(4, Profile.NumHashBytes, 'level 5 SDK numHashBytes');
  Assert.AreEqual(UInt32(32), Profile.CutValue, 'level 5 SDK cutValue');
  Assert.AreEqual(2, Profile.DefaultThreadCount, 'level 5 SDK default threads');
  Assert.AreEqual(Ord(lpmSdkProfile), Ord(Profile.ParserMode), 'level 5 parser mode');
  Assert.AreEqual(Ord(lmfpBinaryTree4), Ord(Profile.MatchFinderProfile), 'level 5 public match finder profile');

  Profile := TLzmaRawEncoder.NormalizeProfile(7, 0);
  Assert.AreEqual(Ord(mfBinaryTree4), Ord(Profile.MatchFinderKind), 'level 7 SDK match finder');
  Assert.AreEqual(4, Profile.NumHashBytes, 'level 7 SDK numHashBytes');
  Assert.AreEqual(UInt32(48), Profile.CutValue, 'level 7 SDK cutValue');
  Assert.AreEqual(2, Profile.DefaultThreadCount, 'level 7 SDK default threads');
  Assert.AreEqual(Ord(lpmSdkProfile), Ord(Profile.ParserMode), 'level 7 parser mode');
  Assert.AreEqual(Ord(lmfpBinaryTree4), Ord(Profile.MatchFinderProfile), 'level 7 public match finder profile');
end;

procedure TLzma2NativeTests.PublicOptionsExposeParityAndDiagnosticsDefaults;
var
  Options: TLzma2Options;
begin
  Options := TLzma2.DefaultOptions;
  Assert.AreEqual(Ord(lpmSdkProfile), Ord(Options.ParserMode), 'default parser mode');
  Assert.AreEqual(Ord(lmfpAuto), Ord(Options.MatchFinderProfile), 'default match finder profile');
  Assert.AreEqual(-1, Options.Lc, 'default lc keeps SDK properties');
  Assert.AreEqual(-1, Options.Lp, 'default lp keeps SDK properties');
  Assert.AreEqual(-1, Options.Pb, 'default pb keeps SDK properties');
  Assert.AreEqual(UInt64(0), Options.XzBlockSize, 'default XZ block size keeps the streaming single-block writer');
  Assert.IsNull(Options.EncodeDiagnostics, 'encode diagnostics default');
end;

procedure TLzma2NativeTests.SdkFacadeLzmaPropsNormalizeAndWriteMatchRawProps;
var
  RawProps: TLzmaProps;
  RawPropsBytes: TBytes;
  SdkProps: TLzmaSdkLzmaEncProps;
  SdkPropsBytes: TBytes;
begin
  SdkProps := TLzmaSdkLzmaEncProps.Init;
  SdkProps.Level := 7;
  SdkProps.DictSize := 12345;

  Assert.AreEqual(SZ_OK, SdkProps.Normalize, 'SDK facade LZMA props normalize');
  Assert.AreEqual(3, SdkProps.Lc, 'normalized lc');
  Assert.AreEqual(0, SdkProps.Lp, 'normalized lp');
  Assert.AreEqual(2, SdkProps.Pb, 'normalized pb');
  Assert.AreEqual(64, SdkProps.Fb, 'normalized fast bytes');
  Assert.AreEqual(1, SdkProps.Algo, 'normalized SDK algorithm');
  Assert.AreEqual(1, SdkProps.BtMode, 'normalized BT mode');
  Assert.AreEqual(4, SdkProps.NumHashBytes, 'normalized num hash bytes');

  RawProps := TLzmaRawEncoder.DefaultProperties(SdkProps.DictSize);
  RawProps.Lc := Byte(SdkProps.Lc);
  RawProps.Lp := Byte(SdkProps.Lp);
  RawProps.Pb := Byte(SdkProps.Pb);
  RawPropsBytes := TLzmaRawEncoder.WriteProperties(RawProps);

  Assert.AreEqual(SZ_OK, SdkProps.WriteProperties(SdkPropsBytes), 'SDK facade writes LZMA props');
  AssertBytesEqual(RawPropsBytes, SdkPropsBytes, 'SDK facade props bytes must match native raw props writer');
end;

procedure TLzma2NativeTests.SdkSeqInStreamMapsGenericExceptionToReadSRes;
var
  ByteBuffer: Byte;
  Processed: SizeT;
  SeqIn: ILzmaSeqInStream;
  Stream: TGenericReadFailStream;
begin
  Stream := TGenericReadFailStream.Create;
  try
    SeqIn := TLzmaSdkSeqInStream.Create(Stream);
    ByteBuffer := 0;
    Processed := 1;
    Assert.AreEqual(SZ_ERROR_READ, SeqIn.Read(ByteBuffer, 1, Processed),
      'TStream read exceptions must map to SDK read failures');
    Assert.AreEqual(SizeT(0), Processed, 'failed SDK read must report no processed bytes');
  finally
    SeqIn := nil;
    Stream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkSeqOutStreamMapsGenericExceptionToWriteSRes;
var
  ByteBuffer: Byte;
  Processed: SizeT;
  SeqOut: ILzmaSeqOutStream;
  Stream: TGenericWriteFailStream;
begin
  Stream := TGenericWriteFailStream.Create;
  try
    SeqOut := TLzmaSdkSeqOutStream.Create(Stream);
    ByteBuffer := 0;
    Processed := 1;
    Assert.AreEqual(SZ_ERROR_WRITE, SeqOut.Write(ByteBuffer, 1, Processed),
      'TStream write exceptions must map to SDK write failures');
    Assert.AreEqual(SizeT(0), Processed, 'failed SDK write must report no processed bytes');
  finally
    SeqOut := nil;
    Stream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkSystemAllocatorAllocatesAndFreesMemory;
var
  Allocator: ILzmaAllocator;
  Bytes: PByte;
  Ptr: Pointer;
begin
  Allocator := TLzmaSdkSystemAllocator.Create;
  Assert.IsTrue(Allocator.Alloc(0) = nil, 'SDK allocator follows ISzAlloc zero-size allocation convention');

  Ptr := Allocator.Alloc(32);
  Assert.IsTrue(Ptr <> nil, 'SDK allocator must return memory for small allocations');
  try
    Bytes := PByte(Ptr);
    Bytes[0] := $5A;
    Bytes[31] := $A5;
    Assert.AreEqual(Byte($5A), Bytes[0], 'SDK allocator memory is writable');
    Assert.AreEqual(Byte($A5), Bytes[31], 'SDK allocator memory covers the requested size');
  finally
    Allocator.FreeMem(Ptr);
  end;

  Allocator.FreeMem(nil);
end;

procedure TLzma2NativeTests.SdkFacadeRawLzmaReferenceStyleEncodeDecodeRoundTrip;
var
  Data: TBytes;
  Dec: TLzmaSdkLzmaDec;
  DecodedBytes: TBytes;
  DestLen: SizeT;
  Encoder: TLzmaSdkLzmaEncoder;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := RepeatingBytes(32768);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 5;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set LZMA facade props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write raw LZMA facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'reference-style LZMA facade encode');
    Assert.IsTrue(Encoded.Size > 0, 'raw LZMA facade payload');
    Assert.AreEqual(Integer(LZMA_PROPS_SIZE), Integer(Length(PropsBytes)),
      'raw LZMA facade writes props separately');

    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate raw LZMA facade lifecycle decoder');
    Dec.SetUnpackSize(UInt64(Length(Data)));
    Dec.Init;
    if Length(DecodedBytes) <> 0 then
      FillChar(DecodedBytes[0], Length(DecodedBytes), 0);
    SetLength(DecodedBytes, Length(Data));
    DestLen := SizeT(Length(DecodedBytes));
    SrcLen := SizeT(Length(EncodedBytes));
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(DecodedBytes[0], DestLen, EncodedBytes[0], SrcLen,
      lfmEnd, Status), 'reference-style raw LZMA facade lifecycle decode');
    Assert.AreEqual(SizeT(Length(EncodedBytes)), SrcLen, 'raw LZMA facade payload consumed');
    Assert.AreEqual(SizeT(Length(Data)), DestLen, 'raw LZMA facade decoded size');
    Assert.AreEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status), 'raw LZMA known-size status');
    AssertBytesEqual(Data, DecodedBytes, 'SDK facade LZMA round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaEncoderUsesSeqStreamAdapterPath;
var
  Data: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  InputTracker: TTrackingSeqInStream;
  Output: ILzmaSeqOutStream;
  OutputTracker: TTrackingSeqOutStream;
  Props: TLzmaSdkLzmaEncProps;
begin
  Data := HighEntropyBytes((1 shl 20) + 32768);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 3;
  Props.DictSize := 1 shl 20;

  InputTracker := TTrackingSeqInStream.Create(Data);
  OutputTracker := TTrackingSeqOutStream.Create(InputTracker);
  Input := InputTracker;
  Output := OutputTracker;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set LZMA facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil),
      'LZMA facade stream-adapter encoder must produce valid output');
    Assert.IsTrue(Length(OutputTracker.ToBytes) > 0, 'LZMA facade output');
    Assert.IsTrue(InputTracker.ReadCallCount > 0,
      'LZMA facade encoder must read through ILzmaSeqInStream');
    Assert.IsTrue(InputTracker.FirstRequestedCount > SizeT(1 shl 16),
      'LZMA facade encoder should not use the facade-local SDK snapshot buffer for its first read');
    Assert.IsTrue(InputTracker.MaxRequestedCount > SizeT(1 shl 16),
      'LZMA facade encoder should not cap raw stream-adapter reads to the facade-local SDK snapshot buffer');
    Assert.IsTrue(OutputTracker.WroteBeforeInputDrained,
      'LZMA facade encoder must stream output before consuming the entire input');
    Assert.IsTrue(OutputTracker.MaxWriteCount > SizeT(1),
      'LZMA facade encoder must buffer range bytes before calling ISeqOutStream.Write');
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaEncoderStreamsEndMarkerPath;
var
  Data: TBytes;
  Decoded: TMemoryStream;
  DecodedBytes: TBytes;
  EncodedBytes: TBytes;
  EncodedStream: TBytesStream;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  InputTracker: TTrackingSeqInStream;
  Output: ILzmaSeqOutStream;
  OutputTracker: TTrackingSeqOutStream;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
begin
  Data := HighEntropyBytes((1 shl 20) + 32768);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 3;
  Props.DictSize := 1 shl 20;
  Props.WriteEndMark := 1;

  InputTracker := TTrackingSeqInStream.Create(Data);
  OutputTracker := TTrackingSeqOutStream.Create(InputTracker);
  Input := InputTracker;
  Output := OutputTracker;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set end-marker LZMA facade props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write end-marker LZMA facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil),
      'LZMA facade end-marker stream-adapter encoder must produce valid output');
    Assert.IsTrue(OutputTracker.WroteBeforeInputDrained,
      'LZMA facade end-marker encoder must stream output before consuming the entire input');
    Assert.IsTrue(OutputTracker.MaxWriteCount > SizeT(1),
      'LZMA facade end-marker encoder must buffer range bytes before calling ISeqOutStream.Write');
    EncodedBytes := OutputTracker.ToBytes;
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
  end;

  EncodedStream := TBytesStream.Create(EncodedBytes);
  Decoded := TMemoryStream.Create;
  try
    TLzmaRawDecoder.DecodeUntilEndMarker(EncodedStream, Decoded, PropsBytes);
    Assert.AreEqual(Int64(Length(EncodedBytes)), EncodedStream.Position,
      'end-marker raw LZMA facade payload must be consumed exactly');
    SetLength(DecodedBytes, Decoded.Size);
    if Decoded.Size <> 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(DecodedBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, DecodedBytes, 'streamed end-marker raw LZMA facade round-trip');
  finally
    Decoded.Free;
    EncodedStream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaEncoderSupportsPartialSeqOutWrites;
var
  Data: TBytes;
  Dec: TLzmaSdkLzmaDec;
  DecodedBytes: TBytes;
  DestLen: SizeT;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PartialOutput: TPartialSeqOutStream;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := RepeatingBytes(32768);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 3;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  PartialOutput := TPartialSeqOutStream.Create(11);
  Input := TLzmaSdkSeqInStream.Create(Src);
  Output := PartialOutput;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set partial-output LZMA facade props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write partial-output LZMA facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil),
      'LZMA facade must drive partial ISeqOutStream writes to completion');
    EncodedBytes := PartialOutput.ToBytes;
    Assert.IsTrue(Length(EncodedBytes) > 0, 'partial-output raw LZMA facade payload');
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
    Src.Free;
  end;

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate partial-output raw LZMA decoder');
    Dec.SetUnpackSize(UInt64(Length(Data)));
    Dec.Init;
    SetLength(DecodedBytes, Length(Data));
    DestLen := SizeT(Length(DecodedBytes));
    SrcLen := SizeT(Length(EncodedBytes));
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(DecodedBytes[0], DestLen, EncodedBytes[0], SrcLen,
      lfmEnd, Status), 'partial-output raw LZMA facade decode');
    Assert.AreEqual(SizeT(Length(EncodedBytes)), SrcLen, 'partial-output raw LZMA consumed payload');
    Assert.AreEqual(SizeT(Length(Data)), DestLen, 'partial-output raw LZMA decoded size');
    AssertBytesEqual(Data, DecodedBytes, 'partial-output LZMA facade round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderSupportsPartialSeqOutWrites;
var
  Data: TBytes;
  DecodedBytes: TBytes;
  Decoder: TLzmaSdkLzmaDecoder;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PartialOutput: TPartialSeqOutStream;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  SizeBytes: TBytes;
  Src: TBytesStream;
  StandaloneBytes: TBytes;
begin
  Data := RepeatingBytes(24576);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 3;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set LZMA decoder partial-output fixture props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write LZMA decoder partial-output fixture props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode LZMA decoder partial-output fixture');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Output := nil;
    Input := nil;
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  SetLength(SizeBytes, SizeOf(UInt64));
  WriteUi64LE(@SizeBytes[0], UInt64(Length(Data)));
  SetLength(StandaloneBytes, 0);
  AppendBytes(StandaloneBytes, PropsBytes);
  AppendBytes(StandaloneBytes, SizeBytes);
  AppendBytes(StandaloneBytes, EncodedBytes);

  Src := TBytesStream.Create(StandaloneBytes);
  PartialOutput := TPartialSeqOutStream.Create(7);
  Input := TLzmaSdkSeqInStream.Create(Src);
  Output := PartialOutput;
  Decoder := TLzmaSdkLzmaDecoder.Create;
  try
    Assert.AreEqual(SZ_OK, Decoder.Decode(Input, Output, nil),
      'LZMA decoder facade must drive partial ISeqOutStream writes to completion');
    DecodedBytes := PartialOutput.ToBytes;
    AssertBytesEqual(Data, DecodedBytes, 'partial-output LZMA decoder facade output');
  finally
    Decoder.Free;
    Output := nil;
    Input := nil;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaEncoderPropagatesSeqOutSRes;
var
  Data: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Props: TLzmaSdkLzmaEncProps;
  Src: TBytesStream;
begin
  Data := BytesOfSize(8192);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 1;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Input := TLzmaSdkSeqInStream.Create(Src);
  Output := TPartialSeqOutStream.Create(16, 1, SZ_ERROR_PROGRESS);
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set failing-output LZMA facade props');
    Assert.AreEqual(SZ_ERROR_PROGRESS, Encoder.Encode(Input, Output, nil),
      'LZMA facade must preserve the exact ISeqOutStream SRes failure');
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderPropagatesSeqOutSRes;
var
  Data: TBytes;
  Decoder: TLzmaSdkLzmaDecoder;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  SizeBytes: TBytes;
  Src: TBytesStream;
  StandaloneBytes: TBytes;
begin
  Data := BytesOfSize(8192);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 1;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set failing-output LZMA decoder fixture props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write failing-output LZMA decoder fixture props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode failing-output LZMA decoder fixture');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Output := nil;
    Input := nil;
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  SetLength(SizeBytes, SizeOf(UInt64));
  WriteUi64LE(@SizeBytes[0], UInt64(Length(Data)));
  SetLength(StandaloneBytes, 0);
  AppendBytes(StandaloneBytes, PropsBytes);
  AppendBytes(StandaloneBytes, SizeBytes);
  AppendBytes(StandaloneBytes, EncodedBytes);

  Src := TBytesStream.Create(StandaloneBytes);
  Input := TLzmaSdkSeqInStream.Create(Src);
  Output := TPartialSeqOutStream.Create(8, 1, SZ_ERROR_PROGRESS);
  Decoder := TLzmaSdkLzmaDecoder.Create;
  try
    Assert.AreEqual(SZ_ERROR_PROGRESS, Decoder.Decode(Input, Output, nil),
      'LZMA decoder facade must preserve the exact ISeqOutStream SRes failure');
  finally
    Decoder.Free;
    Output := nil;
    Input := nil;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeRawLzma2ReferenceStyleEncodeDecodeRoundTrip;
var
  Data: TBytes;
  Decoded: TMemoryStream;
  DecodedBytes: TBytes;
  Decoder: TLzmaSdkLzma2Decoder;
  Encoder: TLzmaSdkLzma2Encoder;
  Encoded: TMemoryStream;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
begin
  Data := BytesOfSize(65536);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 1;
  Props.LzmaProps.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  Decoder := TLzmaSdkLzma2Decoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set LZMA2 facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'reference-style LZMA2 facade encode');
    Assert.IsTrue(Encoded.Size > 0, 'raw LZMA2 facade output');

    Encoded.Position := 0;
    Input := TLzmaSdkSeqInStream.Create(Encoded);
    Output := TLzmaSdkSeqOutStream.Create(Decoded);
    Assert.AreEqual(SZ_OK, Decoder.Decode(Input, Output, nil), 'reference-style LZMA2 facade decode');

    SetLength(DecodedBytes, Decoded.Size);
    Decoded.Position := 0;
    if Length(DecodedBytes) <> 0 then
      Decoded.ReadBuffer(DecodedBytes[0], Length(DecodedBytes));
    AssertBytesEqual(Data, DecodedBytes, 'SDK facade raw LZMA2 round-trip');
  finally
    Decoder.Free;
    Encoder.Free;
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2EncoderPreservesCustomLcLpPbProps;
var
  Control: Byte;
  Data: TBytes;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PackSize: Integer;
  Pos: Integer;
  PropByte: Byte;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
begin
  Data := RepeatingBytes(32768);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 1;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.LzmaProps.Lc := 2;
  Props.LzmaProps.Lp := 2;
  Props.LzmaProps.Pb := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set custom LZMA2 facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode custom LZMA2 facade props');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Pos := 0;
  PropByte := 0;
  while Pos < Length(EncodedBytes) do
  begin
    Control := EncodedBytes[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
      Break;
    Assert.IsTrue(Pos + 2 <= Length(EncodedBytes), 'truncated SDK facade LZMA2 chunk header');
    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      Inc(Pos, ((Integer(EncodedBytes[Pos]) shl 8) or Integer(EncodedBytes[Pos + 1])) + 3);
      Continue;
    end;

    Assert.IsTrue(Control >= $80, 'expected SDK facade compressed LZMA2 chunk');
    Assert.IsTrue(Pos + 4 <= Length(EncodedBytes), 'truncated SDK facade compressed chunk header');
    PackSize := ((Integer(EncodedBytes[Pos + 2]) shl 8) or Integer(EncodedBytes[Pos + 3])) + 1;
    Inc(Pos, 4);
    Assert.IsTrue((Control and $40) <> 0, 'first SDK facade custom-props chunk must carry props');
    Assert.IsTrue(Pos < Length(EncodedBytes), 'truncated SDK facade compressed chunk properties');
    PropByte := EncodedBytes[Pos];
    Inc(Pos);
    Assert.IsTrue(Pos + PackSize <= Length(EncodedBytes), 'truncated SDK facade compressed chunk payload');
    Break;
  end;

  Assert.AreEqual(Byte((1 * 5 + 2) * 9 + 2), PropByte,
    'SDK LZMA2 facade must preserve custom lc/lp/pb in the compressed chunk property');
end;

procedure TLzma2NativeTests.SdkFacadeLzma2EncoderRejectsInvalidLcLpProps;
var
  Encoder: TLzmaSdkLzma2Encoder;
  Props: TLzmaSdkLzma2EncProps;
begin
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Lc := 4;
  Props.LzmaProps.Lp := 1;
  Props.LzmaProps.Pb := 2;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Assert.AreEqual(SZ_ERROR_PARAM, Encoder.SetProps(Props),
      'LZMA2 facade must reject lc + lp combinations that raw LZMA can encode but LZMA2 forbids');
  finally
    Encoder.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2PropsNormalizeBlockThreadCounts;
var
  Props: TLzmaSdkLzma2EncProps;
begin
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 1;
  Props.LzmaProps.NumThreads := 4;
  Props.NumBlockThreads := 0;
  Props.NumTotalThreads := 0;

  Assert.AreEqual(SZ_OK, Props.Normalize, 'normalize LZMA2 facade block/thread props');
  Assert.AreEqual(1, Props.NumBlockThreads,
    'LZMA2 facade must normalize zero block threads to the SDK minimum');
  Assert.AreEqual(1, Props.NumTotalThreads,
    'LZMA2 facade must normalize zero total threads to the SDK minimum');

  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 1;
  Props.LzmaProps.NumThreads := 4;
  Props.NumBlockThreads := -1;
  Props.NumTotalThreads := -1;

  Assert.AreEqual(SZ_OK, Props.Normalize, 'normalize default LZMA2 facade threads');
  Assert.AreEqual(1, Props.NumBlockThreads,
    'default LZMA2 facade block threads should remain single-threaded per block');
  Assert.AreEqual(4, Props.NumTotalThreads,
    'default LZMA2 facade total threads should inherit normalized LZMA thread count');
end;

procedure TLzma2NativeTests.SdkFacadePropsNormalizeSdkDependencyVectors;
var
  Props: TLzmaSdkLzmaEncProps;
  Lzma2Props: TLzmaSdkLzma2EncProps;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Encoded: TMemoryStream;
  Encoder: TLzmaSdkLzma2Encoder;
  SourceStream: TBytesStream;
begin
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 7;
  Props.Algo := 0;
  Assert.AreEqual(SZ_OK, Props.Normalize, 'normalize explicit fast algorithm props');
  Assert.AreEqual(0, Props.BtMode, 'SDK fast algorithm defaults to hash-chain mode');
  Assert.AreEqual(5, Props.NumHashBytes, 'SDK fast algorithm defaults to five hash bytes');
  Assert.AreEqual(1, Props.NumThreads, 'SDK fast algorithm defaults to one thread');

  Props := TLzmaSdkLzmaEncProps.Init;
  Props.NumHashBytes := 2;
  Assert.AreEqual(SZ_OK, Props.Normalize, 'normalize explicit two-byte hash props');
  Assert.AreEqual(2, Props.NumHashBytes, 'explicit two-byte hash setting must survive normalization');
  Props.NumHashBytes := 3;
  Assert.AreEqual(SZ_OK, Props.Normalize, 'normalize explicit three-byte hash props');
  Assert.AreEqual(3, Props.NumHashBytes, 'explicit three-byte hash setting must survive normalization');

  Lzma2Props := TLzmaSdkLzma2EncProps.Init;
  Lzma2Props.LzmaProps.Level := 7;
  Lzma2Props.LzmaProps.Algo := 0;
  Lzma2Props.LzmaProps.Fb := 32;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  Encoded := TMemoryStream.Create;
  SourceStream := TBytesStream.Create(RepeatingBytes(1024));
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Lzma2Props),
      'set LZMA2 facade props with explicit fast algorithm');
    Input := TLzmaSdkSeqInStream.Create(SourceStream);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output),
      'LZMA2 facade fast algorithm props must encode successfully');
  finally
    Output := nil;
    Input := nil;
    SourceStream.Free;
    Encoded.Free;
    Encoder.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeProgressPreservesCallbackSRes;
var
  Data: TBytes;
  Encoded: TMemoryStream;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Progress: ILzmaCompressProgress;
  ProgressObj: TFailingSdkProgress;
  SourceStream: TBytesStream;
begin
  Data := RepeatingBytes(2 * 1024 * 1024);
  Encoder := TLzmaSdkLzma2Encoder.Create;
  Encoded := TMemoryStream.Create;
  SourceStream := TBytesStream.Create(Data);
  ProgressObj := TFailingSdkProgress.Create(SZ_ERROR_READ);
  Progress := ProgressObj;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(TLzmaSdkLzma2EncProps.Init),
      'set default LZMA2 progress-preservation props');
    Input := TLzmaSdkSeqInStream.Create(SourceStream);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_ERROR_READ, Encoder.Encode(Input, Output, Progress),
      'SDK facade must preserve the exact progress callback SRes');
    Assert.IsTrue(ProgressObj.Calls > 0, 'progress callback must be invoked by the facade encode path');
  finally
    Progress := nil;
    Output := nil;
    Input := nil;
    SourceStream.Free;
    Encoded.Free;
    Encoder.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2EncoderHonorsBlockSize;
const
  kBlockSize = 32768;
var
  ChunkCount: Integer;
  ChunkSize: Integer;
  Control: Byte;
  Data: TBytes;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  MaxChunkSize: Integer;
  Output: ILzmaSeqOutStream;
  Pos: Integer;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
begin
  Data := BytesOfSize(100000);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.BlockSize := kBlockSize;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set block-size LZMA2 facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode block-size LZMA2 facade fixture');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Pos := 0;
  ChunkCount := 0;
  MaxChunkSize := 0;
  while Pos < Length(EncodedBytes) do
  begin
    Control := EncodedBytes[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
      Break;

    Assert.IsTrue((Control = LZMA2_CONTROL_COPY_RESET_DIC) or
      (Control = LZMA2_CONTROL_COPY_NO_RESET), 'level-0 LZMA2 facade block-size fixture must use copy chunks');
    Assert.IsTrue(Pos + 2 <= Length(EncodedBytes), 'truncated LZMA2 facade copy chunk header');
    ChunkSize := ((Integer(EncodedBytes[Pos]) shl 8) or Integer(EncodedBytes[Pos + 1])) + 1;
    Inc(Pos, 2);
    Assert.IsTrue(ChunkSize <= kBlockSize, 'LZMA2 facade BlockSize must cap copy chunk input');
    Assert.IsTrue(Pos + ChunkSize <= Length(EncodedBytes), 'truncated LZMA2 facade copy payload');
    Inc(Pos, ChunkSize);
    Inc(ChunkCount);
    if ChunkSize > MaxChunkSize then
      MaxChunkSize := ChunkSize;
  end;

  Assert.IsTrue(ChunkCount >= 4, 'LZMA2 facade BlockSize should split the 100 KiB fixture');
  Assert.AreEqual(kBlockSize, MaxChunkSize, 'LZMA2 facade BlockSize should be used as the chunk size');
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderLifecycleDecodeToBuf;
var
  Data: TBytes;
  Dec: TLzmaSdkLzmaDec;
  Decoded: TBytes;
  DestLen: SizeT;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Payload: TBytes;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := RepeatingBytes(32768);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 3;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set LZMA lifecycle facade props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write LZMA lifecycle facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode LZMA lifecycle fixture');

    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Payload := Copy(EncodedBytes, 0, Length(EncodedBytes));

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate LZMA decoder lifecycle facade');
    Dec.SetUnpackSize(UInt64(Length(Data)));
    Dec.Init;

    SetLength(Decoded, Length(Data));
    DestLen := SizeT(Length(Decoded));
    SrcLen := SizeT(Length(Payload));
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[0], DestLen, Payload[0], SrcLen, lfmEnd, Status),
      'LZMA decoder lifecycle DecodeToBuf');
    Assert.AreEqual(SizeT(Length(Payload)), SrcLen, 'LZMA DecodeToBuf consumed packed bytes');
    Assert.AreEqual(SizeT(Length(Data)), DestLen, 'LZMA DecodeToBuf produced requested bytes');
    Assert.AreEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status), 'LZMA known-size status');
    AssertBytesEqual(Data, Decoded, 'LZMA lifecycle DecodeToBuf round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderLifecycleDecodeToBufEmitsFromPartialKnownSizeInput;
var
  Data: TBytes;
  Dec: TLzmaSdkLzmaDec;
  Decoded: TBytes;
  DestLen: SizeT;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  FirstOutLen: SizeT;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PrefixLen: SizeT;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
  TotalConsumed: SizeT;
  TotalOut: SizeT;
begin
  Data := BytesOfSize(96 * 1024);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 1;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set partial known-size LZMA lifecycle props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write partial known-size LZMA props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode partial known-size LZMA fixture');

    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Output := nil;
    Input := nil;
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue(Length(EncodedBytes) > 64, 'partial known-size LZMA fixture must have a splittable payload');
  PrefixLen := SizeT(Length(EncodedBytes) div 2);
  if PrefixLen < 16 then
    PrefixLen := 16;
  Assert.IsTrue(PrefixLen < SizeT(Length(EncodedBytes)), 'partial known-size prefix must omit stream tail');

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate partial known-size LZMA decoder');
    Dec.SetUnpackSize(UInt64(Length(Data)));
    Dec.Init;

    SetLength(Decoded, Length(Data));
    DestLen := 4096;
    SrcLen := PrefixLen;
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[0], DestLen, EncodedBytes[0], SrcLen,
      lfmAny, Status), 'known-size DecodeToBuf should accept partial packed input');
    Assert.IsTrue(DestLen > 0, 'known-size DecodeToBuf must emit bytes before the packed stream is complete');
    Assert.IsTrue(DestLen < SizeT(Length(Data)), 'first known-size DecodeToBuf call should be partial output');
    Assert.IsTrue(SrcLen > 0, 'known-size DecodeToBuf should consume some partial packed input');
    Assert.AreNotEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status),
      'partial known-size DecodeToBuf must not report finished');
    AssertBytesEqual(Copy(Data, 0, Integer(DestLen)), Copy(Decoded, 0, Integer(DestLen)),
      'partial known-size DecodeToBuf prefix bytes');

    FirstOutLen := DestLen;
    TotalOut := FirstOutLen;
    TotalConsumed := SrcLen;
    while TotalOut < SizeT(Length(Data)) do
    begin
      DestLen := SizeT(Length(Data)) - TotalOut;
      SrcLen := SizeT(Length(EncodedBytes)) - TotalConsumed;
      Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[NativeInt(TotalOut)], DestLen,
        EncodedBytes[NativeInt(TotalConsumed)], SrcLen, lfmEnd, Status),
        'finish partial known-size DecodeToBuf');
      Inc(TotalConsumed, SrcLen);
      Inc(TotalOut, DestLen);
      if (DestLen = 0) and (SrcLen = 0) and (Status = lsNeedsMoreInput) then
        Assert.Fail(Format('known-size DecodeToBuf stalled: consumed=%d/%d output=%d/%d',
          [TotalConsumed, Length(EncodedBytes), TotalOut, Length(Data)]));
    end;

    Assert.AreEqual(SizeT(Length(EncodedBytes)), TotalConsumed,
      'known-size DecodeToBuf should consume the whole packed fixture after finish');
    Assert.AreEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status), 'known-size DecodeToBuf final status');
    AssertBytesEqual(Data, Decoded, 'partial known-size DecodeToBuf full round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderLifecycleDecodeToDicEmitsFromPartialKnownSizeInput;
var
  Data: TBytes;
  Dec: TLzmaSdkLzmaDec;
  DicBytes: TBytes;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  FirstDicPos: SizeT;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PrefixLen: SizeT;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
  PreviousDicPos: SizeT;
  TotalConsumed: SizeT;
begin
  Data := BytesOfSize(80 * 1024);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 1;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set partial known-size LZMA dic props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write partial known-size LZMA dic props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode partial known-size LZMA dic fixture');

    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Output := nil;
    Input := nil;
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue(Length(EncodedBytes) > 64, 'partial known-size LZMA dic fixture must have a splittable payload');
  PrefixLen := SizeT(Length(EncodedBytes) div 2);
  if PrefixLen < 16 then
    PrefixLen := 16;
  Assert.IsTrue(PrefixLen < SizeT(Length(EncodedBytes)), 'partial known-size dic prefix must omit stream tail');

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate partial known-size LZMA dic decoder');
    Dec.SetUnpackSize(UInt64(Length(Data)));
    Dec.Init;

    SrcLen := PrefixLen;
    Assert.AreEqual(SZ_OK, Dec.DecodeToDic(2048, EncodedBytes[0], SrcLen, lfmAny, Status),
      'known-size DecodeToDic should accept partial packed input');
    Assert.IsTrue(Dec.DicPos > 0, 'known-size DecodeToDic must emit bytes before the packed stream is complete');
    Assert.IsTrue(Dec.DicPos <= 2048, 'known-size DecodeToDic must respect the caller dictionary limit');
    Assert.IsTrue(SrcLen > 0, 'known-size DecodeToDic should consume some partial packed input');
    Assert.AreNotEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status),
      'partial known-size DecodeToDic must not report finished');
    FirstDicPos := Dec.DicPos;
    DicBytes := Dec.DicData;
    AssertBytesEqual(Copy(Data, 0, Integer(FirstDicPos)), DicBytes,
      'partial known-size DecodeToDic prefix bytes');

    TotalConsumed := SrcLen;
    while Dec.DicPos < SizeT(Length(Data)) do
    begin
      PreviousDicPos := Dec.DicPos;
      SrcLen := SizeT(Length(EncodedBytes)) - TotalConsumed;
      Assert.AreEqual(SZ_OK, Dec.DecodeToDic(SizeT(Length(Data)),
        EncodedBytes[NativeInt(TotalConsumed)], SrcLen, lfmEnd, Status),
        'finish partial known-size DecodeToDic');
      Inc(TotalConsumed, SrcLen);
      if (SrcLen = 0) and (Dec.DicPos = PreviousDicPos) and (Status = lsNeedsMoreInput) then
        Assert.Fail(Format('known-size DecodeToDic stalled: consumed=%d/%d output=%d/%d',
          [TotalConsumed, Length(EncodedBytes), Dec.DicPos, Length(Data)]));
    end;

    Assert.AreEqual(SizeT(Length(EncodedBytes)), TotalConsumed,
      'known-size DecodeToDic should consume the whole packed fixture after finish');
    Assert.AreEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status), 'known-size DecodeToDic final status');
    DicBytes := Dec.DicData;
    AssertBytesEqual(Data, DicBytes, 'partial known-size DecodeToDic full round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderLifecycleKnownSizeTrailingBytes;
var
  Data: TBytes;
  Dec: TLzmaSdkLzmaDec;
  Decoded: TBytes;
  DicBytes: TBytes;
  DestLen: SizeT;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Payload: TBytes;
  PayloadWithTrailer: TBytes;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := RepeatingBytes(28672);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 3;
  Props.DictSize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set trailing LZMA lifecycle facade props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write trailing LZMA lifecycle facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode trailing LZMA lifecycle fixture');

    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Output := nil;
    Input := nil;
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Payload := Copy(EncodedBytes, 0, Length(EncodedBytes));
  SetLength(PayloadWithTrailer, Length(Payload) + 2);
  Move(Payload[0], PayloadWithTrailer[0], Length(Payload));
  PayloadWithTrailer[Length(Payload)] := $DE;
  PayloadWithTrailer[Length(Payload) + 1] := $AD;

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate trailing LZMA decoder lifecycle facade');
    Dec.SetUnpackSize(UInt64(Length(Data)));
    Dec.Init;

    SetLength(Decoded, Length(Data));
    DestLen := SizeT(Length(Decoded));
    SrcLen := SizeT(Length(PayloadWithTrailer));
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[0], DestLen, PayloadWithTrailer[0], SrcLen,
      lfmEnd, Status), 'LZMA known-size DecodeToBuf with trailing bytes');
    Assert.AreEqual(SizeT(Length(Payload)), SrcLen,
      'LZMA known-size DecodeToBuf must not consume trailing bytes');
    Assert.AreEqual(SizeT(Length(Data)), DestLen, 'LZMA known-size DecodeToBuf output size');
    Assert.AreEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status), 'LZMA known-size status');
    AssertBytesEqual(Data, Decoded, 'LZMA known-size DecodeToBuf trailing round-trip');

    Dec.Init;
    Dec.SetUnpackSize(UInt64(Length(Data)));
    SrcLen := SizeT(Length(PayloadWithTrailer));
    Assert.AreEqual(SZ_OK, Dec.DecodeToDic(SizeT(Length(Data)), PayloadWithTrailer[0], SrcLen,
      lfmEnd, Status), 'LZMA known-size DecodeToDic with trailing bytes');
    Assert.AreEqual(SizeT(Length(Payload)), SrcLen,
      'LZMA known-size DecodeToDic must not consume trailing bytes');
    Assert.AreEqual(SizeT(Length(Data)), Dec.DicPos, 'LZMA known-size DecodeToDic dictionary position');
    Assert.AreEqual(Integer(lsMaybeFinishedWithoutMark), Integer(Status), 'LZMA known-size DecodeToDic status');
    DicBytes := Dec.DicData;
    AssertBytesEqual(Data, DicBytes, 'LZMA known-size DecodeToDic trailing round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderLifecycleDecodeToDicWithEndMarker;
var
  Data: TBytes;
  Dec: TLzmaSdkLzmaDec;
  DicBytes: TBytes;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzmaEncoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Payload: TBytes;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := RepeatingBytes(24576);
  Props := TLzmaSdkLzmaEncProps.Init;
  Props.Level := 3;
  Props.DictSize := 1 shl 20;
  Props.WriteEndMark := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzmaEncoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set LZMA end-marker lifecycle facade props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(PropsBytes), 'write LZMA end-marker lifecycle facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode LZMA end-marker lifecycle fixture');

    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Output := nil;
    Input := nil;
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Payload := Copy(EncodedBytes, 0, Length(EncodedBytes));

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate LZMA end-marker decoder lifecycle facade');
    Dec.Init;

    SrcLen := SizeT(Length(Payload));
    Assert.AreEqual(SZ_OK, Dec.DecodeToDic(SizeT(Length(Data)), Payload[0], SrcLen, lfmEnd, Status),
      'LZMA decoder lifecycle DecodeToDic with end marker');
    Assert.AreEqual(SizeT(Length(Payload)), SrcLen, 'LZMA DecodeToDic consumed end-marker packed bytes');
    Assert.AreEqual(SizeT(Length(Data)), Dec.DicPos, 'LZMA DecodeToDic dictionary position');
    Assert.AreEqual(Integer(lsFinishedWithMark), Integer(Status), 'LZMA DecodeToDic end-marker status');
    DicBytes := Dec.DicData;
    AssertBytesEqual(Data, DicBytes, 'LZMA lifecycle DecodeToDic end-marker round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderRejectsOversizedPropsBuffer;
var
  Dec: TLzmaSdkLzmaDec;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
begin
  Props := TLzmaSdkLzmaEncProps.Init;
  Assert.AreEqual(SZ_OK, Props.WriteProperties(PropsBytes), 'write strict-size LZMA props');
  SetLength(PropsBytes, LZMA_PROPS_SIZE + 1);
  PropsBytes[LZMA_PROPS_SIZE] := 0;

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_ERROR_UNSUPPORTED, Dec.Allocate(PropsBytes),
      'LZMA decoder lifecycle must reject oversized properties buffers');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzmaDecoderLifecycleTruncatedInputNeedsMoreInput;
var
  Dec: TLzmaSdkLzmaDec;
  Dest: array[0..0] of Byte;
  DestLen: SizeT;
  DummySource: Byte;
  Props: TLzmaSdkLzmaEncProps;
  PropsBytes: TBytes;
  Res: SRes;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Props := TLzmaSdkLzmaEncProps.Init;
  Assert.AreEqual(SZ_OK, Props.WriteProperties(PropsBytes), 'write LZMA lifecycle props');

  Dec := TLzmaSdkLzmaDec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(PropsBytes), 'allocate truncated LZMA decoder lifecycle facade');
    Dec.SetUnpackSize(1);
    Dec.Init;
    DummySource := 0;
    Dest[0] := 0;
    DestLen := SizeT(Length(Dest));
    SrcLen := 0;
    Res := Dec.DecodeToBuf(Dest[0], DestLen, DummySource, SrcLen, lfmEnd, Status);
    Assert.AreEqual(SZ_OK, Res, 'truncated LZMA lifecycle decode result');
    Assert.AreEqual(Integer(lsNeedsMoreInput), Integer(Status), 'truncated LZMA lifecycle status');
    Assert.AreEqual(SizeT(0), DestLen, 'truncated LZMA lifecycle output size');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2DecoderLifecycleRejectsInvalidProperty;
var
  Dec: TLzmaSdkLzma2Dec;
begin
  Dec := TLzmaSdkLzma2Dec.Create;
  try
    Assert.AreEqual(SZ_ERROR_UNSUPPORTED, Dec.Allocate(Byte(LZMA2_DIC_PROP_MAX + 1)),
      'LZMA2 decoder lifecycle must reject invalid dictionary property bytes');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2DecoderLifecycleDecodeToBufAndDic;
var
  Combined: TBytes;
  Data: TBytes;
  Dec: TLzmaSdkLzma2Dec;
  DicBytes: TBytes;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  FirstChunk: TBytes;
  FirstLen: SizeT;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Prop: Byte;
  Props: TLzmaSdkLzma2EncProps;
  RestChunk: TBytes;
  RestLen: SizeT;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := BytesOfSize((LZMA2_COPY_CHUNK_SIZE * 2) + 123);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set LZMA2 lifecycle facade props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(Prop), 'write LZMA2 lifecycle property');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode LZMA2 lifecycle fixture');

    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Length(EncodedBytes) <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Length(EncodedBytes));
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Dec := TLzmaSdkLzma2Dec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(Prop), 'allocate LZMA2 decoder lifecycle facade');
    Dec.Init;

    SetLength(FirstChunk, 17);
    FirstLen := SizeT(Length(FirstChunk));
    SrcLen := SizeT(Length(EncodedBytes));
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(FirstChunk[0], FirstLen, EncodedBytes[0], SrcLen, lfmAny, Status),
      'LZMA2 decoder lifecycle first DecodeToBuf');
    Assert.AreEqual(SizeT(Length(EncodedBytes)), SrcLen, 'LZMA2 first DecodeToBuf consumes packed stream');
    Assert.AreEqual(SizeT(Length(FirstChunk)), FirstLen, 'LZMA2 first DecodeToBuf output size');
    Assert.AreEqual(Integer(lsNotFinished), Integer(Status), 'LZMA2 partial output status');

    SetLength(RestChunk, Length(Data) - Length(FirstChunk));
    RestLen := SizeT(Length(RestChunk));
    SrcLen := 0;
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(RestChunk[0], RestLen, EncodedBytes[0], SrcLen, lfmEnd, Status),
      'LZMA2 decoder lifecycle second DecodeToBuf');
    Assert.AreEqual(SizeT(0), SrcLen, 'LZMA2 second DecodeToBuf uses buffered decode state');
    Assert.AreEqual(SizeT(Length(RestChunk)), RestLen, 'LZMA2 second DecodeToBuf output size');
    Assert.AreEqual(Integer(lsFinishedWithMark), Integer(Status), 'LZMA2 finished status');

    SetLength(Combined, Length(Data));
    Move(FirstChunk[0], Combined[0], Length(FirstChunk));
    Move(RestChunk[0], Combined[Length(FirstChunk)], Length(RestChunk));
    AssertBytesEqual(Data, Combined, 'LZMA2 lifecycle DecodeToBuf round-trip');

    Dec.Init;
    SrcLen := SizeT(Length(EncodedBytes));
    Assert.AreEqual(SZ_OK, Dec.DecodeToDic(SizeT(Length(Data)), EncodedBytes[0], SrcLen, lfmEnd, Status),
      'LZMA2 decoder lifecycle DecodeToDic');
    Assert.AreEqual(Integer(lsFinishedWithMark), Integer(Status), 'LZMA2 DecodeToDic finished status');
    Assert.AreEqual(SizeT(Length(Data)), Dec.DicPos, 'LZMA2 DecodeToDic dictionary position');
    DicBytes := Dec.DicData;
    AssertBytesEqual(Data, DicBytes, 'LZMA2 lifecycle DecodeToDic round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2DecoderLifecyclePartialInputAndTrailingBytes;
var
  Data: TBytes;
  Dec: TLzmaSdkLzma2Dec;
  Decoded: TBytes;
  DestLen: SizeT;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PrefixLen: SizeT;
  Prop: Byte;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
  TailWithTrailer: TBytes;
begin
  Data := BytesOfSize((LZMA2_COPY_CHUNK_SIZE * 2) + 57);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set partial-input LZMA2 lifecycle props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(Prop), 'write partial-input LZMA2 property');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode partial-input LZMA2 fixture');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Encoded.Size <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Encoded.Size);
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue((Length(EncodedBytes) > 0) and
    (EncodedBytes[High(EncodedBytes)] = LZMA2_CONTROL_EOF), 'LZMA2 lifecycle fixture must end with EOF');
  PrefixLen := SizeT(Length(EncodedBytes) - 1);
  TailWithTrailer := TBytes.Create(LZMA2_CONTROL_EOF, $DE, $AD);

  Dec := TLzmaSdkLzma2Dec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(Prop), 'allocate partial-input LZMA2 lifecycle facade');
    Dec.Init;

    SetLength(Decoded, Length(Data));
    DestLen := SizeT(Length(Decoded));
    SrcLen := PrefixLen;
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[0], DestLen, EncodedBytes[0], SrcLen, lfmAny, Status),
      'LZMA2 lifecycle partial prefix decode');
    Assert.AreEqual(PrefixLen, SrcLen, 'partial prefix bytes should be accepted into the parser buffer');
    Assert.AreEqual(SizeT(Length(Data)), DestLen,
      'copy-only partial LZMA2 lifecycle decode should emit before EOF');
    Assert.AreEqual(Integer(lsNeedsMoreInput), Integer(Status), 'partial LZMA2 lifecycle status');
    AssertBytesEqual(Data, Decoded, 'partial LZMA2 lifecycle prefix output');

    DestLen := SizeT(Length(Decoded));
    SrcLen := SizeT(Length(TailWithTrailer));
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[0], DestLen, TailWithTrailer[0], SrcLen, lfmEnd, Status),
      'LZMA2 lifecycle tail decode with trailing bytes');
    Assert.AreEqual(SizeT(1), SrcLen, 'LZMA2 lifecycle decode must stop at EOF before trailing bytes');
    Assert.AreEqual(SizeT(0), DestLen, 'EOF-only LZMA2 lifecycle tail should not duplicate prefix output');
    Assert.AreEqual(Integer(lsFinishedWithMark), Integer(Status), 'partial LZMA2 lifecycle finished status');
    AssertBytesEqual(Data, Decoded, 'LZMA2 lifecycle partial-input round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2CompressedDecoderLifecyclePartialInputAndTrailingBytes;
var
  Data: TBytes;
  Dec: TLzmaSdkLzma2Dec;
  Decoded: TBytes;
  DestLen: SizeT;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PrefixLen: SizeT;
  Prop: Byte;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
  TailWithTrailer: TBytes;
begin
  Data := RepeatingBytes((128 shl 10) + 91);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 1;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set compressed partial-input LZMA2 lifecycle props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(Prop), 'write compressed partial-input LZMA2 property');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode compressed partial-input LZMA2 fixture');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Encoded.Size <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Encoded.Size);
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue((Length(EncodedBytes) > 0) and
    (EncodedBytes[High(EncodedBytes)] = LZMA2_CONTROL_EOF), 'compressed LZMA2 fixture must end with EOF');
  PrefixLen := SizeT(Length(EncodedBytes) - 1);
  TailWithTrailer := TBytes.Create(LZMA2_CONTROL_EOF, $DE, $AD);

  Dec := TLzmaSdkLzma2Dec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(Prop), 'allocate compressed partial-input LZMA2 lifecycle facade');
    Dec.Init;

    SetLength(Decoded, Length(Data));
    DestLen := SizeT(Length(Decoded));
    SrcLen := PrefixLen;
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[0], DestLen, EncodedBytes[0], SrcLen, lfmAny, Status),
      'compressed LZMA2 lifecycle partial prefix decode');
    Assert.AreEqual(PrefixLen, SrcLen, 'compressed prefix bytes should be accepted into the parser buffer');
    Assert.AreEqual(SizeT(Length(Data)), DestLen,
      'compressed partial LZMA2 lifecycle decode should emit finished chunks before EOF');
    Assert.AreEqual(Integer(lsNeedsMoreInput), Integer(Status), 'compressed partial LZMA2 lifecycle status');
    AssertBytesEqual(Data, Decoded, 'compressed partial LZMA2 lifecycle prefix output');

    DestLen := SizeT(Length(Decoded));
    SrcLen := SizeT(Length(TailWithTrailer));
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Decoded[0], DestLen, TailWithTrailer[0], SrcLen, lfmEnd, Status),
      'compressed LZMA2 lifecycle tail decode with trailing bytes');
    Assert.AreEqual(SizeT(1), SrcLen, 'compressed LZMA2 lifecycle decode must stop at EOF before trailing bytes');
    Assert.AreEqual(SizeT(0), DestLen, 'EOF-only compressed LZMA2 lifecycle tail should not duplicate prefix output');
    Assert.AreEqual(Integer(lsFinishedWithMark), Integer(Status), 'compressed partial LZMA2 lifecycle finished status');
    AssertBytesEqual(Data, Decoded, 'compressed LZMA2 lifecycle partial-input round-trip');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2ParseStopsAtEofBeforeTrailingBytes;
var
  Data: TBytes;
  Dec: TLzmaSdkLzma2Dec;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PackedWithTrailer: TBytes;
  Prop: Byte;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := BytesOfSize((LZMA2_COPY_CHUNK_SIZE * 2) + 29);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set parser LZMA2 lifecycle props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(Prop), 'write parser LZMA2 property');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode parser LZMA2 fixture');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Encoded.Size <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Encoded.Size);
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue((Length(EncodedBytes) > 0) and
    (EncodedBytes[High(EncodedBytes)] = LZMA2_CONTROL_EOF), 'LZMA2 parser fixture must end with EOF');
  SetLength(PackedWithTrailer, Length(EncodedBytes) + 3);
  Move(EncodedBytes[0], PackedWithTrailer[0], Length(EncodedBytes));
  PackedWithTrailer[Length(EncodedBytes)] := $DE;
  PackedWithTrailer[Length(EncodedBytes) + 1] := $AD;
  PackedWithTrailer[Length(EncodedBytes) + 2] := $BE;

  Dec := TLzmaSdkLzma2Dec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(Prop), 'allocate parser LZMA2 lifecycle facade');
    Dec.Init;

    SrcLen := SizeT(Length(PackedWithTrailer));
    Assert.AreEqual(SZ_OK, Dec.Parse(PackedWithTrailer[0], SrcLen, lfmEnd, Status),
      'LZMA2 lifecycle Parse with trailing bytes');
    Assert.AreEqual(SizeT(Length(EncodedBytes)), SrcLen,
      'LZMA2 lifecycle Parse must stop at EOF before trailing bytes');
    Assert.AreEqual(Integer(lsFinishedWithMark), Integer(Status), 'LZMA2 lifecycle Parse status');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2ParseDoesNotMaterializeOutput;
var
  Data: TBytes;
  Dec: TLzmaSdkLzma2Dec;
  Dest: TBytes;
  DestLen: SizeT;
  DummySource: Byte;
  Encoded: TMemoryStream;
  EncodedBytes: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Prop: Byte;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
  SrcLen: SizeT;
  Status: TLzmaStatus;
begin
  Data := TEncoding.ASCII.GetBytes(
    'abcdefghABCDEFGHabcdefghABXDEFGHabcdefghABCYEFGHabcdefghABCZEFGH' +
    '0123456789abcdefghABCDEFGH0123456789abcdefghABXDEFGH');
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(Src);
    Output := TLzmaSdkSeqOutStream.Create(Encoded);
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set parser-only LZMA2 lifecycle props');
    Assert.AreEqual(SZ_OK, Encoder.WriteProperties(Prop), 'write parser-only LZMA2 property');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'encode parser-only LZMA2 fixture');
    SetLength(EncodedBytes, Encoded.Size);
    Encoded.Position := 0;
    if Encoded.Size <> 0 then
      Encoded.ReadBuffer(EncodedBytes[0], Encoded.Size);
  finally
    Encoder.Free;
    Encoded.Free;
    Src.Free;
  end;

  Dec := TLzmaSdkLzma2Dec.Create;
  try
    Assert.AreEqual(SZ_OK, Dec.Allocate(Prop), 'allocate parser-only LZMA2 lifecycle facade');
    Dec.Init;

    SrcLen := SizeT(Length(EncodedBytes));
    Assert.AreEqual(SZ_OK, Dec.Parse(EncodedBytes[0], SrcLen, lfmEnd, Status),
      'LZMA2 lifecycle Parse must accept a full stream');
    Assert.AreEqual(SizeT(Length(EncodedBytes)), SrcLen, 'LZMA2 lifecycle Parse consumed stream bytes');
    Assert.AreEqual(Integer(lsFinishedWithMark), Integer(Status), 'LZMA2 lifecycle Parse finished status');

    SetLength(Dest, Length(Data));
    DestLen := SizeT(Length(Dest));
    DummySource := 0;
    SrcLen := 0;
    Assert.AreEqual(SZ_OK, Dec.DecodeToBuf(Dest[0], DestLen, DummySource, SrcLen, lfmAny, Status),
      'LZMA2 lifecycle Parse must not leave materialized output for DecodeToBuf');
    Assert.AreEqual(SizeT(0), SrcLen, 'parser-only DecodeToBuf consumed no source');
    Assert.AreEqual(SizeT(0), DestLen, 'parser-only DecodeToBuf emitted no parsed output');
    Assert.AreEqual(Integer(lsNeedsMoreInput), Integer(Status), 'parser-only DecodeToBuf status');
  finally
    Dec.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2ParseUsesFrameParserOnly;
var
  ParseEnd: Integer;
  ParseSource: string;
  ParseStart: Integer;
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Sdk.pas'),
    TEncoding.UTF8);
  ParseStart := Pos('function TLzmaSdkLzma2Dec.Parse', Source);
  ParseEnd := PosEx('function TLzmaSdkLzma2Dec.DicData', Source, ParseStart);
  Assert.IsTrue((ParseStart > 0) and (ParseEnd > ParseStart),
    'LZMA2 lifecycle Parse must stay isolatable for parser-only facade checks');
  ParseSource := Copy(Source, ParseStart, ParseEnd - ParseStart);

  Assert.IsTrue(ContainsText(Source, 'function ParseRawLzma2Embedded'),
    'LZMA2 lifecycle Parse must have a parser-only raw LZMA2 framing helper');
  Assert.IsTrue(ContainsText(ParseSource, 'ParseRawLzma2Embedded'),
    'LZMA2 lifecycle Parse must use the parser-only framing helper');
  Assert.IsFalse(ContainsText(ParseSource, 'TLzma2Decoder.DecodeRawEmbedded') or
    ContainsText(ParseSource, 'TDiscardWriteStream'),
    'LZMA2 lifecycle Parse must not decode payload bytes into a discard stream');
end;

procedure TLzma2NativeTests.SdkFacadeLzma2EncoderDoesNotSnapshotFullInput;
var
  Data: TBytes;
  Decoded: TMemoryStream;
  DecodedBytes: TBytes;
  Decoder: TLzmaSdkLzma2Decoder;
  EncodedBytes: TBytes;
  EncodedStream: TBytesStream;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  InputTracker: TTrackingSeqInStream;
  Output: ILzmaSeqOutStream;
  OutputTracker: TTrackingSeqOutStream;
  Props: TLzmaSdkLzma2EncProps;
begin
  Data := BytesOfSize((LZMA2_COPY_CHUNK_SIZE * 4) + 19);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  InputTracker := TTrackingSeqInStream.Create(Data);
  OutputTracker := TTrackingSeqOutStream.Create(InputTracker);
  Input := InputTracker;
  Output := OutputTracker;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set streaming LZMA2 facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'streaming LZMA2 facade encode');
    Assert.IsTrue(OutputTracker.WroteBeforeInputEof,
      'LZMA2 SDK facade must write the first chunk before draining the whole input stream');
    EncodedBytes := OutputTracker.ToBytes;
    Assert.IsTrue(Length(EncodedBytes) > 0, 'streaming LZMA2 facade output');
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
  end;

  EncodedStream := TBytesStream.Create(EncodedBytes);
  Decoded := TMemoryStream.Create;
  Decoder := TLzmaSdkLzma2Decoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(EncodedStream);
    Output := TLzmaSdkSeqOutStream.Create(Decoded);
    Assert.AreEqual(SZ_OK, Decoder.Decode(Input, Output, nil), 'streaming LZMA2 facade decode');

    SetLength(DecodedBytes, Decoded.Size);
    Decoded.Position := 0;
    if Length(DecodedBytes) <> 0 then
      Decoded.ReadBuffer(DecodedBytes[0], Length(DecodedBytes));
    AssertBytesEqual(Data, DecodedBytes, 'streaming LZMA2 facade round-trip');
  finally
    Decoder.Free;
    Decoded.Free;
    EncodedStream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2CompressedEncoderDoesNotSnapshotFullInput;
var
  Data: TBytes;
  Decoded: TMemoryStream;
  DecodedBytes: TBytes;
  Decoder: TLzmaSdkLzma2Decoder;
  EncodedBytes: TBytes;
  EncodedStream: TBytesStream;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  InputTracker: TTrackingSeqInStream;
  Output: ILzmaSeqOutStream;
  OutputTracker: TTrackingSeqOutStream;
  Props: TLzmaSdkLzma2EncProps;
begin
  Data := BytesOfSize((2 shl 20) + (64 shl 10) + 19);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 1;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  InputTracker := TTrackingSeqInStream.Create(Data);
  OutputTracker := TTrackingSeqOutStream.Create(InputTracker);
  Input := InputTracker;
  Output := OutputTracker;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set streaming compressed LZMA2 facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil), 'streaming compressed LZMA2 facade encode');
    Assert.IsTrue(OutputTracker.WroteBeforeInputEof,
      'compressed LZMA2 SDK facade must write a chunk before draining the whole input stream');
    EncodedBytes := OutputTracker.ToBytes;
    Assert.IsTrue(Length(EncodedBytes) > 0, 'streaming compressed LZMA2 facade output');
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
  end;

  EncodedStream := TBytesStream.Create(EncodedBytes);
  Decoded := TMemoryStream.Create;
  Decoder := TLzmaSdkLzma2Decoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(EncodedStream);
    Output := TLzmaSdkSeqOutStream.Create(Decoded);
    Assert.AreEqual(SZ_OK, Decoder.Decode(Input, Output, nil), 'streaming compressed LZMA2 facade decode');
    SetLength(DecodedBytes, Decoded.Size);
    Decoded.Position := 0;
    if Length(DecodedBytes) <> 0 then
      Decoded.ReadBuffer(DecodedBytes[0], Length(DecodedBytes));
    AssertBytesEqual(Data, DecodedBytes, 'streaming compressed LZMA2 facade round-trip');
  finally
    Decoder.Free;
    Decoded.Free;
    EncodedStream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2DecoderDoesNotSnapshotFullInput;
var
  Data: TBytes;
  DecodedBytes: TBytes;
  Decoder: TLzmaSdkLzma2Decoder;
  EncodedBytes: TBytes;
  Input: ILzmaSeqInStream;
  InputTracker: TTrackingSeqInStream;
  Options: TLzma2Options;
  Output: ILzmaSeqOutStream;
  OutputTracker: TTrackingSeqOutStream;
begin
  Data := BytesOfSize((LZMA2_COPY_CHUNK_SIZE * 4) + 23);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 0;
  Options.BufferSize := LZMA2_COPY_CHUNK_SIZE;
  EncodedBytes := TLzma2Encoder.EncodeRawBytes(Data, Options);

  InputTracker := TTrackingSeqInStream.Create(EncodedBytes);
  OutputTracker := TTrackingSeqOutStream.Create(InputTracker);
  Input := InputTracker;
  Output := OutputTracker;
  Decoder := TLzmaSdkLzma2Decoder.Create;
  try
    Assert.AreEqual(SZ_OK, Decoder.Decode(Input, Output, nil), 'streaming LZMA2 facade decode');
    Assert.IsTrue(OutputTracker.WroteBeforeInputEof,
      'LZMA2 SDK decoder facade must write decoded bytes before draining the whole input stream');
    DecodedBytes := OutputTracker.ToBytes;
    AssertBytesEqual(Data, DecodedBytes, 'streaming LZMA2 facade decode output');
  finally
    Decoder.Free;
    Output := nil;
    Input := nil;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2DecoderSupportsPartialSeqOutWrites;
var
  Data: TBytes;
  DecodedBytes: TBytes;
  Decoder: TLzmaSdkLzma2Decoder;
  EncodedBytes: TBytes;
  EncodedStream: TBytesStream;
  Input: ILzmaSeqInStream;
  Options: TLzma2Options;
  Output: ILzmaSeqOutStream;
  PartialOutput: TPartialSeqOutStream;
begin
  Data := RepeatingBytes((LZMA2_COPY_CHUNK_SIZE * 2) + 29);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 0;
  Options.BufferSize := LZMA2_COPY_CHUNK_SIZE;
  EncodedBytes := TLzma2Encoder.EncodeRawBytes(Data, Options);

  EncodedStream := TBytesStream.Create(EncodedBytes);
  PartialOutput := TPartialSeqOutStream.Create(5);
  Input := TLzmaSdkSeqInStream.Create(EncodedStream);
  Output := PartialOutput;
  Decoder := TLzmaSdkLzma2Decoder.Create;
  try
    Assert.AreEqual(SZ_OK, Decoder.Decode(Input, Output, nil),
      'LZMA2 decoder facade must drive partial ISeqOutStream writes to completion');
    DecodedBytes := PartialOutput.ToBytes;
    AssertBytesEqual(Data, DecodedBytes, 'partial-output LZMA2 decoder facade output');
  finally
    Decoder.Free;
    Output := nil;
    Input := nil;
    EncodedStream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2DecoderPropagatesSeqOutSRes;
var
  Data: TBytes;
  Decoder: TLzmaSdkLzma2Decoder;
  EncodedBytes: TBytes;
  EncodedStream: TBytesStream;
  Input: ILzmaSeqInStream;
  Options: TLzma2Options;
  Output: ILzmaSeqOutStream;
begin
  Data := BytesOfSize(LZMA2_COPY_CHUNK_SIZE + 17);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 0;
  Options.BufferSize := LZMA2_COPY_CHUNK_SIZE;
  EncodedBytes := TLzma2Encoder.EncodeRawBytes(Data, Options);

  EncodedStream := TBytesStream.Create(EncodedBytes);
  Input := TLzmaSdkSeqInStream.Create(EncodedStream);
  Output := TPartialSeqOutStream.Create(8, 1, SZ_ERROR_PROGRESS);
  Decoder := TLzmaSdkLzma2Decoder.Create;
  try
    Assert.AreEqual(SZ_ERROR_PROGRESS, Decoder.Decode(Input, Output, nil),
      'LZMA2 decoder facade must preserve the exact ISeqOutStream SRes failure');
  finally
    Decoder.Free;
    Output := nil;
    Input := nil;
    EncodedStream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2EncoderSupportsPartialSeqOutWrites;
var
  Data: TBytes;
  Decoded: TMemoryStream;
  DecodedBytes: TBytes;
  Decoder: TLzmaSdkLzma2Decoder;
  EncodedBytes: TBytes;
  EncodedStream: TBytesStream;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  PartialOutput: TPartialSeqOutStream;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
begin
  Data := RepeatingBytes((LZMA2_COPY_CHUNK_SIZE * 2) + 31);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  PartialOutput := TPartialSeqOutStream.Create(7);
  Input := TLzmaSdkSeqInStream.Create(Src);
  Output := PartialOutput;
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set partial-output LZMA2 facade props');
    Assert.AreEqual(SZ_OK, Encoder.Encode(Input, Output, nil),
      'LZMA2 facade must drive partial ISeqOutStream writes to completion');
    EncodedBytes := PartialOutput.ToBytes;
    Assert.IsTrue(Length(EncodedBytes) > 0, 'partial-output LZMA2 facade output');
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
    Src.Free;
  end;

  EncodedStream := TBytesStream.Create(EncodedBytes);
  Decoded := TMemoryStream.Create;
  Decoder := TLzmaSdkLzma2Decoder.Create;
  try
    Input := TLzmaSdkSeqInStream.Create(EncodedStream);
    Output := TLzmaSdkSeqOutStream.Create(Decoded);
    Assert.AreEqual(SZ_OK, Decoder.Decode(Input, Output, nil), 'partial-output LZMA2 facade decode');

    SetLength(DecodedBytes, Decoded.Size);
    Decoded.Position := 0;
    if Length(DecodedBytes) <> 0 then
      Decoded.ReadBuffer(DecodedBytes[0], Length(DecodedBytes));
    AssertBytesEqual(Data, DecodedBytes, 'partial-output LZMA2 facade round-trip');
  finally
    Decoder.Free;
    Decoded.Free;
    EncodedStream.Free;
  end;
end;

procedure TLzma2NativeTests.SdkFacadeLzma2EncoderPropagatesSeqOutSRes;
var
  Data: TBytes;
  Encoder: TLzmaSdkLzma2Encoder;
  Input: ILzmaSeqInStream;
  Output: ILzmaSeqOutStream;
  Props: TLzmaSdkLzma2EncProps;
  Src: TBytesStream;
begin
  Data := BytesOfSize(LZMA2_COPY_CHUNK_SIZE + 1);
  Props := TLzmaSdkLzma2EncProps.Init;
  Props.LzmaProps.Level := 0;
  Props.LzmaProps.DictSize := 1 shl 20;
  Props.NumTotalThreads := 1;

  Src := TBytesStream.Create(Data);
  Input := TLzmaSdkSeqInStream.Create(Src);
  Output := TPartialSeqOutStream.Create(16, 1, SZ_ERROR_PROGRESS);
  Encoder := TLzmaSdkLzma2Encoder.Create;
  try
    Assert.AreEqual(SZ_OK, Encoder.SetProps(Props), 'set failing-output LZMA2 facade props');
    Assert.AreEqual(SZ_ERROR_PROGRESS, Encoder.Encode(Input, Output, nil),
      'LZMA2 facade must preserve the exact ISeqOutStream SRes failure');
  finally
    Encoder.Free;
    Output := nil;
    Input := nil;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.EncodeDiagnosticsReportsSdkProfileOptimumWindowEnabled;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;
begin
  Data := TEncoding.ASCII.GetBytes(
    'abcdefghABCDEFGHabcdefghABXDEFGHabcdefghABCYEFGHabcdefghABCZEFGH' +
    '0123456789abcdefghABCDEFGH0123456789abcdefghABXDEFGH');
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.FastBytes := 64;
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, Encoded, Options);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.AreEqual(Ord(lpmSdkProfile), Ord(Diagnostics.ParserMode),
    'diagnostics parser mode remains the requested SDK-profile metadata');
  Assert.AreEqual(5, Diagnostics.NumHashBytes, 'SDK-profile diagnostics must expose active HC5 hash bytes');
  Assert.IsTrue(Diagnostics.OptimumParserEnabled,
    'SDK-profile diagnostics must report the active native optimum-parser branch');
  Assert.IsTrue(Diagnostics.FullOptimumDecisionCount > 0,
    'SDK-profile diagnostics must report real full optimum decision evidence');
end;

procedure TLzma2NativeTests.RawEncoderReportsActualFullOptimumDecisionCount;
var
  Data: TBytes;
  EnabledCount: UInt64;
  DisabledCount: UInt64;
  Encoded: TBytes;
  Props: TLzmaProps;
begin
  Data := TEncoding.ASCII.GetBytes(
    'abcdefghABCDEFGHabcdefghABXDEFGHabcdefghABCYEFGHabcdefghABCZEFGH' +
    '0123456789abcdefghABCDEFGH0123456789abcdefghABXDEFGH');
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);

  DisabledCount := High(UInt64);
  Encoded := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props,
    64, 32, mfHashChain4, False, False, nil, @DisabledCount);
  Assert.IsTrue(Length(Encoded) > 0, 'raw encoder must produce bytes without optimum diagnostics');
  Assert.AreEqual(UInt64(0), DisabledCount,
    'disabled optimum parser must report zero real full optimum decisions');

  EnabledCount := 0;
  Encoded := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props,
    64, 32, mfHashChain4, False, True, nil, @EnabledCount);
  Assert.IsTrue(Length(Encoded) > 0, 'raw encoder must produce bytes with optimum diagnostics');
  Assert.IsTrue(EnabledCount > 0,
    'enabled SDK-profile path must report decisions only when the full optimum parser actually selects them');
end;

procedure TLzma2NativeTests.EncodeDiagnosticsDoesNotClaimOptimumForCopyOnlySdkProfileRawLzma2;
const
  kInputSize = 1024 * 1024;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TBytes;
  I: Integer;
  Options: TLzma2Options;
  Seed: UInt32;
begin
  SetLength(Data, kInputSize);
  Seed := UInt32($9E3779B9);
  for I := 0 to High(Data) do
  begin
    Seed := Seed * UInt32(1664525) + UInt32(1013904223);
    Data[I] := Byte(Seed shr 24);
  end;

  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := kInputSize;
  Options.EncodeDiagnostics := @Diagnostics;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);

  Assert.IsTrue(Length(Encoded) > 0, 'copy-only encode still emits an LZMA2 stream');
  Assert.AreEqual(Ord(lpmSdkProfile), Ord(Diagnostics.ParserMode),
    'copy-only diagnostics must keep the requested SDK-profile parser metadata');
  Assert.IsTrue(Diagnostics.CopyFastPathCount > 0,
    'high-entropy SDK-profile input should exercise the copy fast path');
  Assert.AreEqual(0, Diagnostics.BlockCount,
    'copy-only SDK-profile input must not report compressed LZMA blocks');
  Assert.IsFalse(Diagnostics.OptimumParserEnabled,
    'OptimumParserEnabled must only become true after a compressed LZMA block used the full parser');
  Assert.AreEqual(UInt64(0), Diagnostics.FullOptimumDecisionCount,
    'copy-only SDK-profile input must not report full optimum decisions');
end;

procedure TLzma2NativeTests.RawEncoderFullSdkOptimumStateScaffoldIsPresent;
var
  Source: string;
  StateSource: string;
  StateStart: Integer;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.EncoderHeuristics.pas'),
    TEncoding.UTF8);
  StateStart := Pos('TLzmaFullOptimumState', Source);
  Assert.IsTrue(StateStart > 0,
    'raw encoder must add a shared TLzmaFullOptimumState scaffold before enabling SDK-profile optimum diagnostics');

  StateSource := Copy(Source, StateStart, 1400);
  Assert.IsTrue(ContainsText(StateSource, 'OptCur'), 'full optimum state must track SDK optCur');
  Assert.IsTrue(ContainsText(StateSource, 'OptEnd'), 'full optimum state must track SDK optEnd');
  Assert.IsTrue(ContainsText(StateSource, 'AdditionalOffset'),
    'full optimum state must track SDK additional offset');
  Assert.IsTrue(ContainsText(StateSource, 'LongestMatchLen'),
    'full optimum state must track SDK longestMatchLen');
  Assert.IsTrue(ContainsText(StateSource, 'NumPairs'), 'full optimum state must track SDK numPairs');
  Assert.IsTrue(ContainsText(StateSource, 'NumAvail'), 'full optimum state must track SDK numAvail');
  Assert.IsTrue(ContainsText(StateSource, 'BackRes'), 'full optimum state must track SDK backRes');
  Assert.IsTrue(ContainsText(StateSource, 'MatchPriceCount'),
    'full optimum state must track SDK matchPriceCount');
  Assert.IsTrue(ContainsText(StateSource, 'RepLenEncCounter'),
    'full optimum state must track SDK repLenEncCounter');
end;

procedure TLzma2NativeTests.FullOptimumStateTracksSdkReadMoveAndCommitOffsets;
var
  MainMatch: TLzmaMatch;
  Matches: TLzmaMatchBuffer;
  State: TLzmaFullOptimumState;
begin
  LzmaFullOptimumInit(State, True);
  Assert.AreEqual(UInt32(0), State.OptCur, 'initial optCur');
  Assert.AreEqual(UInt32(0), State.OptEnd, 'initial optEnd');
  Assert.AreEqual(UInt32(0), State.AdditionalOffset, 'initial additionalOffset');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, State.BackRes, 'initial backRes');
  Assert.AreEqual(64, State.RepLenEncCounter, 'initial rep len counter');
  Assert.IsTrue(Length(State.Nodes) = LZMA_FULL_OPTIMUM_NUM_OPTS,
    'SDK optimum node window size');

  Matches.Clear;
  Matches.Add(2, 1);
  Matches.Add(5, 7);
  MainMatch.Length := 5;
  MainMatch.Distance := 7;
  LzmaFullOptimumNoteReadMatchDistances(State, 128, Matches, MainMatch);
  Assert.AreEqual(UInt32(1), State.AdditionalOffset,
    'ReadMatchDistances must increment additionalOffset');
  Assert.AreEqual(UInt32(128), State.NumAvail, 'stored numAvail');
  Assert.AreEqual(UInt32(4), State.NumPairs, 'SDK numPairs stores len/dist UInt32 count');
  Assert.AreEqual(UInt32(5), State.LongestMatchLen, 'stored longest match length');

  Assert.IsTrue(LzmaFullOptimumMovePos(State, 3), 'MOVE_POS(3) must be accepted');
  Assert.AreEqual(UInt32(4), State.AdditionalOffset,
    'MOVE_POS must add to additionalOffset');
  Assert.IsTrue(LzmaFullOptimumMovePos(State, 0), 'MOVE_POS(0) is a no-op');
  Assert.AreEqual(UInt32(4), State.AdditionalOffset, 'MOVE_POS(0) offset');

  Assert.IsTrue(LzmaFullOptimumCommitEncodedLen(State, 2),
    'committing encoded length must decrement additionalOffset');
  Assert.AreEqual(UInt32(2), State.AdditionalOffset, 'offset after partial commit');
  Assert.IsFalse(LzmaFullOptimumCommitEncodedLen(State, 3),
    'commit must reject underflow instead of wrapping additionalOffset');
  Assert.AreEqual(UInt32(2), State.AdditionalOffset, 'offset after rejected commit');
  Assert.IsTrue(LzmaFullOptimumCommitEncodedLen(State, 2), 'commit remaining offset');
  Assert.AreEqual(UInt32(0), State.AdditionalOffset, 'offset after full commit');
end;

procedure TLzma2NativeTests.FullOptimumStateDisabledInitDoesNotAllocateWindow;
var
  State: TLzmaFullOptimumState;
begin
  LzmaFullOptimumInit(State, False);
  Assert.IsFalse(State.Enabled, 'disabled full optimum state');
  Assert.AreEqual(UInt32(0), State.AdditionalOffset, 'disabled initial additionalOffset');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, State.BackRes, 'disabled initial backRes');
  Assert.IsTrue(Length(State.Nodes) = 0,
    'disabled full optimum state must not allocate the SDK node window on fast-path encode');
end;

procedure TLzma2NativeTests.FullOptimumBeginDecisionUsesCachedReadWhenAdditionalOffsetIsPending;
var
  MainLen: UInt32;
  MainMatch: TLzmaMatch;
  Matches: TLzmaMatchBuffer;
  NeedsRead: Boolean;
  NumAvail: UInt32;
  NumPairs: UInt32;
  State: TLzmaFullOptimumState;
begin
  LzmaFullOptimumInit(State, True);
  Matches.Clear;
  Matches.Add(2, 3);
  Matches.Add(6, 17);
  MainMatch.Length := 6;
  MainMatch.Distance := 17;
  LzmaFullOptimumNoteReadMatchDistances(State, 77, Matches, MainMatch);
  State.OptCur := 5;
  State.OptEnd := 9;

  MainLen := 999;
  NumAvail := 999;
  NumPairs := 999;
  NeedsRead := LzmaFullOptimumBeginDecision(State, NumAvail, NumPairs, MainLen);
  Assert.IsFalse(NeedsRead,
    'pending additionalOffset must reuse SDK cached match state instead of reading again');
  Assert.AreEqual(UInt32(0), State.OptCur, 'begin decision resets optCur');
  Assert.AreEqual(UInt32(0), State.OptEnd, 'begin decision resets optEnd');
  Assert.AreEqual(UInt32(1), State.AdditionalOffset, 'begin decision keeps pending offset');
  Assert.AreEqual(UInt32(77), NumAvail, 'cached numAvail');
  Assert.AreEqual(UInt32(4), NumPairs, 'cached SDK numPairs');
  Assert.AreEqual(UInt32(6), MainLen, 'cached longest match length');

  Assert.IsTrue(LzmaFullOptimumCommitEncodedLen(State, 1), 'clear cached read offset');
  MainLen := 999;
  NumAvail := 999;
  NumPairs := 999;
  NeedsRead := LzmaFullOptimumBeginDecision(State, NumAvail, NumPairs, MainLen);
  Assert.IsTrue(NeedsRead, 'zero additionalOffset must request a fresh match read');
  Assert.AreEqual(UInt32(0), NumAvail, 'fresh-read request must not leak cached numAvail');
  Assert.AreEqual(UInt32(0), NumPairs, 'fresh-read request must not leak cached numPairs');
  Assert.AreEqual(UInt32(0), MainLen, 'fresh-read request must not leak cached main length');
end;

procedure TLzma2NativeTests.FullOptimumStateCachesPendingMatchBuffer;
var
  Loaded: TLzmaMatchBuffer;
  LoadedMain: TLzmaMatch;
  MainMatch: TLzmaMatch;
  Matches: TLzmaMatchBuffer;
  State: TLzmaFullOptimumState;
begin
  LzmaFullOptimumInit(State, True);
  Matches.Clear;
  Matches.Add(2, 3);
  Matches.Add(5, 21);
  MainMatch := Matches.Last;

  Assert.IsFalse(LzmaFullOptimumLoadCachedMatches(State, Loaded, LoadedMain),
    'fresh full optimum state must not expose cached matches');

  LzmaFullOptimumNoteReadMatchDistances(State, 99, Matches, MainMatch);
  Assert.IsTrue(LzmaFullOptimumLoadCachedMatches(State, Loaded, LoadedMain),
    'pending additionalOffset must expose the cached SDK match buffer');
  Assert.AreEqual(2, Loaded.Count, 'cached match count');
  Assert.AreEqual(UInt32(2), Loaded.Items[0].Length, 'cached first length');
  Assert.AreEqual(UInt32(3), Loaded.Items[0].Distance, 'cached first distance');
  Assert.AreEqual(UInt32(5), Loaded.Items[1].Length, 'cached second length');
  Assert.AreEqual(UInt32(21), Loaded.Items[1].Distance, 'cached second distance');
  Assert.AreEqual(UInt32(5), LoadedMain.Length, 'cached main length');
  Assert.AreEqual(UInt32(21), LoadedMain.Distance, 'cached main distance');

  Assert.IsTrue(LzmaFullOptimumCommitEncodedLen(State, 1), 'clear cached read offset');
  Assert.IsFalse(LzmaFullOptimumLoadCachedMatches(State, Loaded, LoadedMain),
    'drained additionalOffset must not serve stale cached matches');
end;

procedure TLzma2NativeTests.FullOptimumBackwardQueuesReplayState;
var
  Back: UInt32;
  I: Integer;
  Len: UInt32;
  State: TLzmaFullOptimumState;
begin
  LzmaFullOptimumInit(State, True);
  for I := 1 to 5 do
    State.Nodes[I].Price := High(UInt32);

  State.Nodes[5].Price := 10;
  State.Nodes[5].PathLen := 2;
  State.Nodes[5].PathBack := 1;
  State.Nodes[5].Extra := 3;
  State.Nodes[5].PosPrev := 3;
  State.Nodes[5].BackPrev := 0;

  Assert.IsTrue(LzmaFullOptimumBackward(State, 5, Len, Back),
    'full optimum backward must store SDK replay state on TLzmaFullOptimumState');
  Assert.AreEqual(UInt32(2), Len, 'first replay length');
  Assert.AreEqual(UInt32(1), Back, 'first replay back');
  Assert.AreEqual(UInt32(6), State.OptEnd, 'stored SDK optEnd');
  Assert.AreEqual(UInt32(4), State.OptCur, 'stored SDK optCur');
  Assert.AreEqual(UInt32(2), State.ReplayCount, 'queued replay count');

  Assert.IsTrue(LzmaFullOptimumTryReplay(State, Len, Back), 'first queued replay');
  Assert.AreEqual(UInt32(1), Len, 'queued literal length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back, 'queued literal back');
  Assert.AreEqual(UInt32(5), State.OptCur, 'optCur after first queued replay');

  Assert.IsTrue(LzmaFullOptimumTryReplay(State, Len, Back), 'second queued replay');
  Assert.AreEqual(UInt32(2), Len, 'queued rep0 length');
  Assert.AreEqual(UInt32(0), Back, 'queued rep0 back');
  Assert.AreEqual(UInt32(6), State.OptCur, 'optCur after replay drain');
  Assert.IsFalse(LzmaFullOptimumTryReplay(State, Len, Back),
    'drained full optimum replay queue must miss');
end;

procedure TLzma2NativeTests.FullOptimumStateIsWiredToMatchReadAndEncodedCommit;
var
  CommitEnd: Integer;
  CommitSource: string;
  CommitStart: Integer;
  ReadEnd: Integer;
  ReadSource: string;
  ReadStart: Integer;
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);

  ReadStart := Pos('function ReadMatchDistancesAndInsert', Source);
  ReadEnd := PosEx('function ReadCurrentMatchDistances', Source, ReadStart);
  Assert.IsTrue((ReadStart > 0) and (ReadEnd > ReadStart),
    'raw encoder match-read helper must stay isolatable for full optimum state wiring');
  ReadSource := Copy(Source, ReadStart, ReadEnd - ReadStart);
  Assert.IsTrue(ContainsText(ReadSource, 'FullOptimumState.Enabled') and
    ContainsText(ReadSource, 'LzmaFullOptimumNoteReadMatchDistances'),
    'match reads must update full optimum cached read state under the full-parser guard');

  CommitStart := Pos('LenRes := GetOptimumFast(BackRes);', Source);
  CommitEnd := PosEx('if WriteEndMarker then', Source, CommitStart);
  Assert.IsTrue((CommitStart > 0) and (CommitEnd > CommitStart),
    'raw encoder encode loop must stay isolatable for full optimum commit wiring');
  CommitSource := Copy(Source, CommitStart, CommitEnd - CommitStart);
  Assert.IsTrue(ContainsText(CommitSource, 'FullOptimumState.Enabled') and
    ContainsText(CommitSource, 'LzmaFullOptimumCommitEncodedLen') and
    ContainsText(CommitSource, 'RaiseLzmaError'),
    'encoded commands must commit full optimum additionalOffset and reject underflow under the guard');
end;

procedure TLzma2NativeTests.FullOptimumStateRefreshCountersAreAdditionalOffsetGated;
var
  MainMatch: TLzmaMatch;
  Matches: TLzmaMatchBuffer;
  State: TLzmaFullOptimumState;
begin
  LzmaFullOptimumInit(State, True);
  Assert.IsTrue(LzmaFullOptimumCanRefreshPrices(State),
    'fresh full optimum state can refresh prices');

  Matches.Clear;
  Matches.Add(3, 1);
  MainMatch.Length := 3;
  MainMatch.Distance := 1;
  LzmaFullOptimumNoteReadMatchDistances(State, 64, Matches, MainMatch);
  Assert.IsFalse(LzmaFullOptimumCanRefreshPrices(State),
    'SDK price refresh is gated while additionalOffset is non-zero');

  Assert.IsTrue(LzmaFullOptimumCommitEncodedLen(State, 1), 'commit read offset');
  Assert.IsTrue(LzmaFullOptimumCanRefreshPrices(State),
    'price refresh becomes legal when additionalOffset returns to zero');

  LzmaFullOptimumNoteNormalMatch(State);
  Assert.AreEqual(UInt32(1), State.MatchPriceCount, 'normal match price counter');
  LzmaFullOptimumNoteRepLen(State);
  Assert.AreEqual(63, State.RepLenEncCounter, 'rep len counter decrements');
  LzmaFullOptimumResetRefreshCounters(State);
  Assert.AreEqual(UInt32(0), State.MatchPriceCount, 'refreshed match price counter');
  Assert.AreEqual(64, State.RepLenEncCounter, 'refreshed rep len counter');
end;

procedure TLzma2NativeTests.FullOptimumEncoderWiresRefreshCountersAfterCommit;
var
  CommitEnd: Integer;
  CommitSource: string;
  CommitStart: Integer;
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);
  CommitStart := Pos('LenRes := GetOptimumFast(BackRes);', Source);
  CommitEnd := PosEx('if WriteEndMarker then', Source, CommitStart);
  Assert.IsTrue((CommitStart > 0) and (CommitEnd > CommitStart),
    'raw encoder encode loop must stay isolatable for full optimum refresh wiring');
  CommitSource := Copy(Source, CommitStart, CommitEnd - CommitStart);

  Assert.IsTrue(ContainsText(CommitSource, 'LzmaFullOptimumNoteNormalMatch') and
    ContainsText(CommitSource, 'LzmaFullOptimumNoteRepLen'),
    'full optimum encode loop must update SDK match and rep length refresh counters');
  Assert.IsTrue(ContainsText(CommitSource, 'LzmaFullOptimumCanRefreshPrices') and
    ContainsText(CommitSource, 'RefreshOptimumPriceTables') and
    ContainsText(CommitSource, 'LzmaFullOptimumResetRefreshCounters'),
    'full optimum price tables must refresh only after additionalOffset drains');
end;

procedure TLzma2NativeTests.FullOptimumParserBranchIsIsolatedFromFastParser;
var
  LoopEnd: Integer;
  LoopSource: string;
  LoopStart: Integer;
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);
  LoopStart := PosEx('while Pos < Count do', Source,
    Pos('case MatchFinderKind of', Source));
  LoopEnd := PosEx('if WriteEndMarker then', Source, LoopStart);
  Assert.IsTrue((LoopStart > 0) and (LoopEnd > LoopStart),
    'raw encoder loop must stay isolatable for full parser branch checks');
  LoopSource := Copy(Source, LoopStart, LoopEnd - LoopStart);

  Assert.IsTrue(ContainsText(Source, 'function GetOptimumFull(out Back: UInt32): UInt32'),
    'raw encoder must provide an isolated full optimum decision entry point');
  Assert.IsTrue(ContainsText(LoopSource, 'if FullOptimumState.Enabled then') and
    ContainsText(LoopSource, 'LenRes := GetOptimumFull(BackRes)') and
    ContainsText(LoopSource, 'LenRes := GetOptimumFast(BackRes)'),
    'active full optimum mode must branch away from the fast parser instead of flowing through it');
  Assert.IsTrue(ContainsText(Source, 'LzmaFullOptimumBeginDecision') and
    ContainsText(Source, 'FullOptimumState.OptCur') and
    ContainsText(Source, 'FullOptimumState.OptEnd'),
    'full optimum branch must be wired around SDK begin/replay state');
  Assert.IsTrue(ContainsText(Source, 'LzmaFullOptimumBackward'),
    'full optimum branch must use the SDK-style backward replay state helper');
end;

procedure TLzma2NativeTests.SdkProfileFullParserTransitionRejectsGetOptimumFastBackend;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TMemoryStream;
  FastCallContext: string;
  FastCallContextStart: Integer;
  FastCallIsFullParserGated: Boolean;
  FastCallStart: Integer;
  LegacySdkFastBinding: Boolean;
  Options: TLzma2Options;
  Source: string;
  Src: TBytesStream;
begin
  Data := BytesOfSize(4096);
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, Encoded, Options);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);
  FastCallStart := Pos('GetOptimumFast(BackRes)', Source);
  FastCallIsFullParserGated := False;
  if FastCallStart > 0 then
  begin
    if FastCallStart > 240 then
      FastCallContextStart := FastCallStart - 240
    else
      FastCallContextStart := 1;
    FastCallContext := Copy(Source, FastCallContextStart, 520);
    FastCallIsFullParserGated := ContainsText(FastCallContext, 'EnableOptimumWindow') or
      ContainsText(FastCallContext, 'FullOptimum') or
      ContainsText(FastCallContext, 'GetOptimumFull');
  end;
  LegacySdkFastBinding := (Pos('Profile.ParserMode = lpmSdkProfile', Source) > 0) and
    (FastCallStart > 0) and (not FastCallIsFullParserGated);

  Assert.IsFalse(Diagnostics.OptimumParserEnabled and LegacySdkFastBinding,
    'SDK-profile diagnostics must not report the native optimum branch while the raw encode loop still runs through GetOptimumFast');
  Assert.IsTrue(Diagnostics.OptimumParserEnabled,
    'SDK-profile diagnostics must report the active native optimum-parser branch once it is isolated');
end;

procedure TLzma2NativeTests.PeriodicFastPathCannotMasqueradeAsFullSdkParserParity;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  PeriodicFastPathEnd: Integer;
  PeriodicFastPathSource: string;
  PeriodicFastPathStart: Integer;
  PeriodicSourceStart: Integer;
  Source: string;
  Src: TBytesStream;
begin
  Data := RepeatingBytes(128 * 1024);
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, Encoded, Options);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);
  PeriodicFastPathStart := Pos('TryDetectSmallPeriodicChunk(PeriodicDistance)', Source);
  Assert.IsTrue(PeriodicFastPathStart > 0,
    'raw encoder periodic fast path probe must stay visible for full-parser transition guard');

  PeriodicFastPathEnd := PosEx('case MatchFinderKind of', Source, PeriodicFastPathStart);
  Assert.IsTrue(PeriodicFastPathEnd > PeriodicFastPathStart,
    'raw encoder periodic fast path must stay isolatable for full-parser transition guard');
  if PeriodicFastPathStart > 240 then
    PeriodicSourceStart := PeriodicFastPathStart - 240
  else
    PeriodicSourceStart := 1;
  PeriodicFastPathSource := Copy(Source, PeriodicSourceStart,
    PeriodicFastPathEnd - PeriodicSourceStart);

  Assert.IsTrue(
    ContainsText(PeriodicFastPathSource, 'not EnableOptimumWindow') or
    ContainsText(PeriodicFastPathSource, 'not UseFullOptimumParser') or
    ContainsText(PeriodicFastPathSource, 'not FullOptimumParserEnabled') or
    ContainsText(PeriodicFastPathSource, 'not FullOptimumState.Enabled'),
    'periodic fast path must not be reported as native optimum-parser work when OptimumParserEnabled becomes true');
  Assert.IsTrue(Diagnostics.OptimumParserEnabled,
    'SDK-profile periodic corpus must still report the active native optimum-parser branch');
end;

procedure TLzma2NativeTests.EncodeDiagnosticsKeepsOptimumWindowDisabledForHighSpeedParser;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;
begin
  Data := BytesOfSize(4096);
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ParserMode := lpmHighSpeed;
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, Encoded, Options);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.AreEqual(Ord(lpmHighSpeed), Ord(Diagnostics.ParserMode),
    'diagnostics parser mode must keep the requested high-speed metadata');
  Assert.AreEqual(5, Diagnostics.NumHashBytes, 'high-speed auto diagnostics must expose active HC5 hash bytes');
  Assert.IsFalse(Diagnostics.OptimumParserEnabled,
    'high-speed parser mode keeps the bounded optimum-window path disabled');
end;

procedure TLzma2NativeTests.EncodeDiagnosticsReflectsPublicTuningOverrides;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;
begin
  Data := RepeatingBytes(8192);
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 5;
  Options.FastBytes := 64;
  Options.CutValue := 32;
  Options.MatchFinderProfile := lmfpHashChain4;
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, Encoded, Options);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.AreEqual(64, Diagnostics.FastBytes, 'diagnostics fast bytes');
  Assert.AreEqual(64, Diagnostics.NiceLen, 'diagnostics nice len');
  Assert.AreEqual(UInt32(32), Diagnostics.CutValue, 'diagnostics cut value');
  Assert.AreEqual(Ord(lmfpHashChain4), Ord(Diagnostics.MatchFinderProfile),
    'diagnostics match finder profile');
  Assert.AreEqual(4, Diagnostics.NumHashBytes, 'diagnostics match finder hash bytes');
  Assert.IsFalse(Diagnostics.OptimumParserEnabled,
    'public tuning overrides must not claim the optimum parser when the selected encode path produced no full decisions');
  Assert.AreEqual(UInt64(0), Diagnostics.FullOptimumDecisionCount,
    'public tuning overrides must keep full optimum decision evidence tied to actual parser decisions');
end;

procedure TLzma2NativeTests.PriceTablesMatchSdkProbPrices;
var
  Prices: TLzmaProbPrices;
begin
  LzmaInitProbPrices(Prices);
  Assert.AreEqual(UInt32(128), Prices[0], 'SDK ProbPrices[0]');
  Assert.AreEqual(UInt32(103), Prices[1], 'SDK ProbPrices[1]');
  Assert.AreEqual(UInt32(32), Prices[32], 'SDK ProbPrices[32]');
  Assert.AreEqual(UInt32(16), Prices[64], 'SDK ProbPrices[64]');
  Assert.AreEqual(UInt32(1), Prices[127], 'SDK ProbPrices[127]');
  Assert.AreEqual(UInt32(16), LzmaBitPrice(Prices, LZMA_PROB_INIT, 0), 'SDK price prob=1024 bit=0');
  Assert.AreEqual(UInt32(17), LzmaBitPrice(Prices, LZMA_PROB_INIT, 1), 'SDK price prob=1024 bit=1');
end;

procedure TLzma2NativeTests.PriceTablesMatchSdkInitialLenPrices;
var
  ProbPrices: TLzmaProbPrices;
  Low: TLzmaLenLowProbs;
  High: TLzmaLenHighProbs;
  Prices: TLzmaLenPrices;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(Low, High);
  LzmaUpdateLenPrices(Prices, Low, High, 1, LZMA_LEN_NUM_SYMBOLS_TOTAL, ProbPrices);

  Assert.AreEqual(UInt32(64), Prices[0][0], 'SDK initial len price for len=2');
  Assert.AreEqual(UInt32(65), Prices[0][1], 'SDK initial len price for len=3');
  Assert.AreEqual(UInt32(81), Prices[0][8], 'SDK initial len price for len=10');
  Assert.AreEqual(UInt32(82), Prices[0][9], 'SDK initial len price for len=11');
end;

procedure TLzma2NativeTests.LengthPriceEncoderUsesFastBytesTableSizeAndLookup;
var
  ProbPrices: TLzmaProbPrices;
  Low: TLzmaLenLowProbs;
  High: TLzmaLenHighProbs;
  PriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(Low, High);
  LzmaInitLenPriceEncoder(PriceEnc, 32);
  LzmaUpdateLenPriceEncoder(PriceEnc, Low, High, 4, ProbPrices);

  Assert.AreEqual(UInt32(31), PriceEnc.TableSize, 'SDK tableSize for fastBytes=32');
  Assert.AreEqual(UInt32(64), LzmaLenPrice(PriceEnc, 0, 2), 'SDK len price lookup for len=2');
  Assert.AreEqual(UInt32(65), LzmaLenPrice(PriceEnc, 2, 3), 'SDK len price lookup for pb-derived posState');
  Assert.AreEqual(UInt32(81), LzmaLenPrice(PriceEnc, 3, 10), 'SDK len price lookup for len=10');
  Assert.AreEqual(UInt32(82), LzmaLenPrice(PriceEnc, 1, 11), 'SDK len price lookup for len=11');
  Assert.WillRaise(
    procedure
    begin
      LzmaLenPrice(PriceEnc, 0, 33);
    end,
    EArgumentOutOfRangeException);
  Assert.WillRaise(
    procedure
    begin
      LzmaLenPrice(PriceEnc, 4, 2);
    end,
    EArgumentOutOfRangeException);
end;

procedure TLzma2NativeTests.DistancePriceTablesMatchSdkInitialValues;
var
  ProbPrices: TLzmaProbPrices;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  AlignProbs: TLzmaAlignProbs;
  PriceEnc: TLzmaDistancePriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(PriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(PriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs, ProbPrices);

  Assert.AreEqual(UInt32(40), PriceEnc.DistTableSize, 'SDK distTableSize for 1 MiB dictionary');
  Assert.AreEqual(UInt32(64), LzmaAlignPrice(PriceEnc, 0), 'SDK initial align price 0');
  Assert.AreEqual(UInt32(65), LzmaAlignPrice(PriceEnc, 1), 'SDK initial align price 1');
  Assert.AreEqual(UInt32(67), LzmaAlignPrice(PriceEnc, 7), 'SDK initial align price 7');
  Assert.AreEqual(UInt32(68), LzmaAlignPrice(PriceEnc, 15), 'SDK initial align price 15');

  Assert.AreEqual(UInt32(96), PriceEnc.PosSlotPrices[0][0], 'SDK initial posSlot price 0');
  Assert.AreEqual(UInt32(97), PriceEnc.PosSlotPrices[0][1], 'SDK initial posSlot price 1');
  Assert.AreEqual(UInt32(131), PriceEnc.PosSlotPrices[0][14], 'SDK initial posSlot price includes direct-bit delta');

  Assert.AreEqual(UInt32(96), LzmaReducedDistancePrice(PriceEnc, 0, 0), 'SDK initial reduced distance price 0');
  Assert.AreEqual(UInt32(97), LzmaReducedDistancePrice(PriceEnc, 0, 1), 'SDK initial reduced distance price 1');
  Assert.AreEqual(UInt32(113), LzmaReducedDistancePrice(PriceEnc, 0, 4), 'SDK initial reduced distance price 4');
  Assert.AreEqual(UInt32(114), LzmaReducedDistancePrice(PriceEnc, 0, 5), 'SDK initial reduced distance price 5');
  Assert.WillRaise(
    procedure
    begin
      LzmaAlignPrice(PriceEnc, LZMA_ALIGN_TABLE_SIZE);
    end,
    EArgumentOutOfRangeException);
end;

procedure TLzma2NativeTests.MatchDistancePriceUsesActualDistanceAndLengthState;
var
  ProbPrices: TLzmaProbPrices;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  AlignProbs: TLzmaAlignProbs;
  PriceEnc: TLzmaDistancePriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(PriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(PriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs, ProbPrices);

  Assert.AreEqual(UInt32(96), LzmaMatchDistancePrice(PriceEnc, 2, 1),
    'actual distance 1 maps to SDK reduced distance 0');
  Assert.AreEqual(UInt32(113), LzmaMatchDistancePrice(PriceEnc, 2, 5),
    'actual distance 5 maps to SDK reduced distance 4');
  Assert.AreEqual(UInt32(96), LzmaMatchDistancePrice(PriceEnc, 5, 1),
    'len >= 5 clamps to SDK len-to-pos state 3');
  Assert.AreEqual(UInt32(195), LzmaMatchDistancePrice(PriceEnc, 2, 129),
    'reduced distance 128 uses pos-slot plus align prices');
  Assert.WillRaise(
    procedure
    begin
      LzmaMatchDistancePrice(PriceEnc, 2, 0);
    end,
    EArgumentOutOfRangeException);
end;

procedure TLzma2NativeTests.LiteralPriceTablesMatchSdkInitialValues;
var
  ProbPrices: TLzmaProbPrices;
  LiteralProbs: TLzmaLiteralProbs;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LiteralProbs[1] := 1536;
  LiteralProbs[2] := 512;
  LiteralProbs[257] := 1536;

  Assert.AreEqual(UInt32(135), LzmaLiteralPrice(LiteralProbs, $00, ProbPrices),
    'SDK literal price for zero byte with live probabilities');
  Assert.AreEqual(UInt32(152), LzmaLiteralPrice(LiteralProbs, $FF, ProbPrices),
    'SDK literal price for all-one byte with live probabilities');
  Assert.AreEqual(UInt32(148), LzmaLiteralPrice(LiteralProbs, $A5, ProbPrices),
    'SDK literal price follows the root-to-leaf probability path');
  Assert.AreEqual(UInt32(148), LzmaMatchedLiteralPrice(LiteralProbs, $A5, $5A, ProbPrices),
    'SDK matched-literal price follows the encoder path for live literal probabilities');
end;

procedure TLzma2NativeTests.RepAndMatchChoicePricesMatchSdkInitialValues;
var
  ProbPrices: TLzmaProbPrices;
begin
  LzmaInitProbPrices(ProbPrices);

  Assert.AreEqual(UInt32(33), LzmaNormalMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT),
    'SDK initial normal match prefix price');
  Assert.AreEqual(UInt32(34), LzmaRepMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT),
    'SDK initial rep match prefix price');
  Assert.AreEqual(UInt32(32), LzmaShortRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT),
    'SDK initial short-rep branch price');
  Assert.AreEqual(UInt32(33), LzmaRep0LongPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT),
    'SDK initial rep0-long branch price');
  Assert.AreEqual(UInt32(33), LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, 0),
    'SDK initial pure rep0 branch price');
  Assert.AreEqual(UInt32(33), LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, 1),
    'SDK initial rep1 branch price');
  Assert.AreEqual(UInt32(50), LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, 2),
    'SDK initial rep2 branch price');
  Assert.AreEqual(UInt32(51), LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, 3),
    'SDK initial rep3 branch price');
  Assert.WillRaise(
    procedure
    begin
      LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 4);
    end,
    EArgumentOutOfRangeException);
end;

procedure TLzma2NativeTests.OptimumLiteralVsShortRepUsesSdkPrices;
var
  ProbPrices: TLzmaProbPrices;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralPrice: UInt32;
  ShortRepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LiteralProbs[1] := 1536;
  LiteralProbs[2] := 512;
  LiteralProbs[257] := 1536;

  Assert.IsTrue(
    LzmaOptimumPrefersShortRepOverLiteral(ProbPrices, LiteralProbs, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, $00, False, 0,
      LiteralPrice, ShortRepPrice),
    'SDK initial optimum prices should prefer short-rep over literal when rep0 matches one byte');
  Assert.AreEqual(UInt32(151), LiteralPrice, 'literal price = isMatch(0) + literal tree price');
  Assert.AreEqual(UInt32(66), ShortRepPrice, 'short-rep price = isMatch(1) + isRep(1) + short-rep branch');

  Assert.IsFalse(
    LzmaOptimumPrefersShortRepOverLiteral(ProbPrices, LiteralProbs, LZMA_BIT_MODEL_TOTAL - 1,
      LZMA_BIT_MODEL_TOTAL - 1, LZMA_PROB_INIT, LZMA_PROB_INIT, $00, False, 0,
      LiteralPrice, ShortRepPrice),
    'SDK optimum comparison must keep literal when literal has the lower price');
  Assert.IsTrue(LiteralPrice < ShortRepPrice, 'biased probabilities should make literal cheaper than short-rep');
end;

procedure TLzma2NativeTests.OptimumShortRepVsLiteralRejectsOverflowingShortRepPrice;
var
  I: Integer;
  LiteralPrice: UInt32;
  LiteralProbs: TLzmaLiteralProbs;
  ProbPrices: TLzmaProbPrices;
  ShortRepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  for I := Low(LiteralProbs) to High(LiteralProbs) do
    LiteralProbs[I] := LZMA_BIT_MODEL_TOTAL - 1;

  ProbPrices[0] := UInt32(1) shl 30;
  ProbPrices[(LZMA_BIT_MODEL_TOTAL - 1) shr LZMA_NUM_MOVE_REDUCING_BITS] := 1;

  Assert.IsFalse(
    LzmaOptimumPrefersShortRepOverLiteral(ProbPrices, LiteralProbs,
      LZMA_BIT_MODEL_TOTAL - 1, LZMA_BIT_MODEL_TOTAL - 1, 0, 0,
      $00, False, 0, LiteralPrice, ShortRepPrice),
    'literal-vs-short-rep comparison must not wrap an overflowing short-rep price into a win');
  Assert.IsTrue(ShortRepPrice >= LiteralPrice,
    'overflowing short-rep price must not be reported cheaper than finite literal price');
end;

procedure TLzma2NativeTests.OptimumRepVsMatchUsesSdkPrices;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs, ProbPrices);

  Assert.IsTrue(
    LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 0, 0, 2, 2, 1, RepPrice, MatchPrice),
    'SDK initial optimum prices should prefer rep0 over an equal-length normal match');
  Assert.AreEqual(UInt32(131), RepPrice, 'rep price = rep prefix + rep0 branch + rep length');
  Assert.AreEqual(UInt32(193), MatchPrice, 'match price = normal prefix + match length + distance');

  Assert.IsTrue(
    LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 0, 0, 2, 4, 1, RepPrice, MatchPrice),
    'SDK prices can prefer a two-byte rep over a longer low-distance normal match');
  Assert.IsTrue(RepPrice < MatchPrice, 'initial rep0 len=2 price should stay below match len=4 dist=1');

  Assert.IsFalse(
    LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_BIT_MODEL_TOTAL - 1, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 0, 2, 2, 1, RepPrice, MatchPrice),
    'SDK optimum comparison must keep normal match when its price is lower');
  Assert.IsTrue(MatchPrice < RepPrice, 'biased isRep probability should make normal match cheaper than rep');

  RepLenPriceEnc.Prices[0][0] := 10;
  LenPriceEnc.Prices[0][0] := 20;
  DistancePriceEnc.DistancePrices[0][0] := 24;
  Assert.IsTrue(
    LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 0, 0, 2, 2, 1, RepPrice, MatchPrice),
    'SDK full optimum keeps the earlier rep candidate when a later normal match has the same price');
  Assert.AreEqual(RepPrice, MatchPrice, 'synthetic price tables should exercise the exact tie policy');
end;

procedure TLzma2NativeTests.OptimumRepVsMatchRejectsOverflowingRepPrice;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RepLenPriceEnc.Prices[0][0] := High(UInt32) - 16;
  LenPriceEnc.Prices[0][0] := 20;
  DistancePriceEnc.DistancePrices[0][0] := 24;

  Assert.IsFalse(
    LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc, RepLenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 0, 2, 2, 1,
      RepPrice, MatchPrice),
    'rep-vs-match comparison must not wrap an overflowing rep price into a win');
  Assert.IsTrue(RepPrice >= MatchPrice,
    'overflowing rep price must not be reported cheaper than finite normal match price');
end;

procedure TLzma2NativeTests.OptimumRepVsMatchRejectsOverflowingMatchBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc, RepLenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 0, 2, 2,
      High(UInt32), RepPrice, MatchPrice),
    'rep-vs-match decision must reject normal-match distances whose encoded back overflows');
  Assert.AreEqual(High(UInt32), RepPrice,
    'overflowing normal-match distance must leave no finite rep comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'overflowing normal-match distance must clamp match price');
end;

procedure TLzma2NativeTests.OptimumRepVsMatchRejectsOneByteNormalMatchLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc,
      RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0,
      0, 2, 1, 1, RepPrice, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'rep-vs-match decision must reject one-byte normal matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte normal match is not encodable and must not win the decision');
  Assert.AreEqual(High(UInt32), RepPrice,
    'one-byte normal match must leave no finite rep comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte normal match must clamp match price');
end;

procedure TLzma2NativeTests.OptimumRepVsMatchRejectsOneByteRepLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc,
      RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0,
      0, 1, 2, 1, RepPrice, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'rep-vs-match decision must reject one-byte rep matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte rep match is not encodable and must not win the decision');
  Assert.AreEqual(High(UInt32), RepPrice,
    'one-byte rep match must clamp rep price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte rep match must leave no finite normal-match comparison price');
end;

procedure TLzma2NativeTests.OptimumRepVsMatchRejectsZeroMatchDistance;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepPrice: UInt32;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc,
      RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0,
      0, 2, 2, 0, RepPrice, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'rep-vs-match decision must reject zero normal-match distance without raising from price tables');
  Assert.IsFalse(Decision,
    'zero normal-match distance is not encodable and must not win the decision');
  Assert.AreEqual(High(UInt32), RepPrice,
    'zero normal-match distance must leave no finite rep comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'zero normal-match distance must clamp match price');
end;

procedure TLzma2NativeTests.OptimumRepVsMatchFixtureShowsPriceBeatsFastHeuristic;
var
  AlignProbs: TLzmaAlignProbs;
  Data: TBytes;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  Finder: TLzmaHashChain4MatchFinder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchPrice: UInt32;
  Matches: TLzmaMatchBuffer;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepPrice: UInt32;
begin
  Data := TEncoding.ASCII.GetBytes('xyABx0ABCDABCD!');
  Finder := TLzmaHashChain4MatchFinder.Create(Data, 0, Length(Data), 32, 32, 273, 32);
  try
    Finder.InsertRange(0, 10);
    Finder.GetMatches(10, Matches);
  finally
    Finder.Free;
  end;

  Assert.IsTrue(Matches.Count > 0, 'fixture must expose the normal match candidate');
  Assert.AreEqual(UInt32(4), Matches.Last.Length, 'fixture normal match length');
  Assert.AreEqual(UInt32(4), Matches.Last.Distance, 'fixture normal match distance');
  Assert.AreEqual(Byte(Ord('A')), Data[10], 'fixture current byte');
  Assert.AreEqual(Byte(Ord('A')), Data[10 - 8], 'fixture rep0 byte 0');
  Assert.AreEqual(Byte(Ord('B')), Data[11 - 8], 'fixture rep0 byte 1');
  Assert.AreNotEqual(Data[12], Data[12 - 8], 'fixture rep0 match must stop at length 2');
  Assert.IsFalse(LzmaFastParserPrefersRepOverMain(2, Matches.Last.Length, Matches.Last.Distance),
    'the older fast heuristic alone would choose the four-byte normal match');

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs, ProbPrices);

  Assert.IsTrue(
    LzmaOptimumPrefersRepOverMatch(ProbPrices, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 2, 0, 2, Matches.Last.Length, Matches.Last.Distance, RepPrice,
      MatchPrice),
    'SDK price tables prefer the shorter rep0 candidate in this fast-path conflict fixture');
  Assert.IsTrue(RepPrice < MatchPrice, 'fixture must keep the intended price ordering');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchUsesSdkPrices;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs, ProbPrices);

  LenPriceEnc.Prices[0][0] := 280;
  DistancePriceEnc.DistancePrices[0][4] := 280;
  LenPriceEnc.Prices[1][3] := 12;
  DistancePriceEnc.DistancePrices[3][0] := 12;

  Assert.IsTrue(
    LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices, LiteralProbs, LenPriceEnc,
      DistancePriceEnc, LZMA_BIT_MODEL_TOTAL - 1, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 0, 1, Ord('A'), False, 0, 2, 5, 5, 1,
      LiteralThenMatchPrice, MatchPrice),
    'bounded optimum pricing should choose literal + next match when it is cheaper than the current match');
  Assert.IsTrue(LiteralThenMatchPrice < MatchPrice, 'synthetic prices must keep the intended ordering');

  LenPriceEnc.Prices[0][0] := 10;
  DistancePriceEnc.DistancePrices[0][4] := 10;
  Assert.IsFalse(
    LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices, LiteralProbs, LenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 0, 1, Ord('A'), False, 0, 2, 5, 5, 1,
      LiteralThenMatchPrice, MatchPrice),
    'bounded optimum pricing must keep the current match when it is cheaper');
  Assert.IsTrue(MatchPrice < LiteralThenMatchPrice, 'second synthetic setup must prefer the current match');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchRejectsOverflowingLookaheadPrice;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  LenPriceEnc.Prices[1][3] := High(UInt32) - 16;
  DistancePriceEnc.DistancePrices[3][0] := 24;
  LenPriceEnc.Prices[0][0] := 4096;
  DistancePriceEnc.DistancePrices[0][4] := 4096;

  Assert.IsFalse(
    LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, Ord('A'), False, 0, 2, 5, 5,
      1, LiteralThenMatchPrice, MatchPrice),
    'literal-then-match comparison must not wrap an overflowing lookahead price into a win');
  Assert.IsTrue(LiteralThenMatchPrice >= MatchPrice,
    'overflowing literal-then-match price must not be reported cheaper than finite current match');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchRejectsOverflowingCurrentMatchBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, Ord('A'), False, 0, 2,
      High(UInt32), 5, 1, LiteralThenMatchPrice, MatchPrice),
    'literal-then-match decision must reject current-match distances whose encoded back overflows');
  Assert.AreEqual(High(UInt32), LiteralThenMatchPrice,
    'overflowing current match must leave no finite literal-then-match price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'overflowing current match must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchRejectsOverflowingNextMatchBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, Ord('A'), False, 0, 2,
      1, 5, High(UInt32), LiteralThenMatchPrice, MatchPrice),
    'literal-then-match decision must reject next-match distances whose encoded back overflows');
  Assert.AreEqual(High(UInt32), LiteralThenMatchPrice,
    'overflowing next match must clamp literal-then-match price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'overflowing next match must leave no finite current-match comparison price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchRejectsOneByteNextMatchLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, Ord('A'),
      False, 0, 2, 1, 1, 1, LiteralThenMatchPrice, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'literal-then-match decision must reject one-byte next matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte next match is not encodable and must not win the lookahead decision');
  Assert.AreEqual(High(UInt32), LiteralThenMatchPrice,
    'one-byte next match must clamp literal-then-match price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte next match must leave no finite current-match comparison price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchRejectsOneByteCurrentMatchLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, Ord('A'),
      False, 0, 1, 1, 2, 1, LiteralThenMatchPrice, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'literal-then-match decision must reject one-byte current matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte current match is not encodable and must not keep the baseline decision');
  Assert.AreEqual(High(UInt32), LiteralThenMatchPrice,
    'one-byte current match must leave no finite literal-then-match comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte current match must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchRejectsZeroNextMatchDistance;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, Ord('A'),
      False, 0, 2, 1, 2, 0, LiteralThenMatchPrice, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'literal-then-match decision must reject zero next-match distance without raising from price tables');
  Assert.IsFalse(Decision,
    'zero next-match distance is not encodable and must not win the lookahead decision');
  Assert.AreEqual(High(UInt32), LiteralThenMatchPrice,
    'zero next-match distance must clamp literal-then-match price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'zero next-match distance must leave no finite current-match comparison price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenMatchRejectsZeroCurrentMatchDistance;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenMatchPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersLiteralThenMatchOverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, Ord('A'),
      False, 0, 2, 0, 2, 1, LiteralThenMatchPrice, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'literal-then-match decision must reject zero current-match distance without raising from price tables');
  Assert.IsFalse(Decision,
    'zero current-match distance is not encodable and must not keep the baseline decision');
  Assert.AreEqual(High(UInt32), LiteralThenMatchPrice,
    'zero current-match distance must leave no finite literal-then-match comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'zero current-match distance must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenRepUsesSdkPrices;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenRepPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs, ProbPrices);

  LenPriceEnc.Prices[0][3] := 280;
  DistancePriceEnc.DistancePrices[3][4] := 280;
  RepLenPriceEnc.Prices[1][2] := 12;

  Assert.IsTrue(
    LzmaOptimumPrefersLiteralThenRepOverMatch(ProbPrices, LiteralProbs, LenPriceEnc,
      RepLenPriceEnc, DistancePriceEnc, LZMA_BIT_MODEL_TOTAL - 1, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('A'), False, 0, 5, 5, 4,
      LiteralThenRepPrice, MatchPrice),
    'bounded optimum pricing should choose literal + next rep when it is cheaper than the current match');
  Assert.IsTrue(LiteralThenRepPrice < MatchPrice, 'synthetic prices must prefer literal + rep');

  LenPriceEnc.Prices[0][3] := 10;
  DistancePriceEnc.DistancePrices[3][4] := 10;
  Assert.IsFalse(
    LzmaOptimumPrefersLiteralThenRepOverMatch(ProbPrices, LiteralProbs, LenPriceEnc,
      RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('A'), False, 0, 5, 5, 4,
      LiteralThenRepPrice, MatchPrice),
    'bounded optimum pricing must keep the current match when it is cheaper');
  Assert.IsTrue(MatchPrice < LiteralThenRepPrice, 'second synthetic setup must prefer current match');
end;

procedure TLzma2NativeTests.OptimumLiteralThenRepRejectsOverflowingLookaheadPrice;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenRepPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RepLenPriceEnc.Prices[1][2] := High(UInt32) - 16;
  LenPriceEnc.Prices[0][3] := 4096;
  DistancePriceEnc.DistancePrices[3][4] := 4096;

  Assert.IsFalse(
    LzmaOptimumPrefersLiteralThenRepOverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('A'),
      False, 0, 5, 5, 4, LiteralThenRepPrice, MatchPrice),
    'literal-then-rep comparison must not wrap an overflowing lookahead price into a win');
  Assert.IsTrue(LiteralThenRepPrice >= MatchPrice,
    'overflowing literal-then-rep price must not be reported cheaper than finite current match');
end;

procedure TLzma2NativeTests.OptimumLiteralThenRepRejectsOverflowingCurrentMatchBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenRepPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumPrefersLiteralThenRepOverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('A'),
      False, 0, 5, High(UInt32), 4, LiteralThenRepPrice, MatchPrice),
    'literal-then-rep decision must reject current-match distances whose encoded back overflows');
  Assert.AreEqual(High(UInt32), LiteralThenRepPrice,
    'overflowing current match must leave no finite literal-then-rep price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'overflowing current match must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenRepRejectsOneByteNextRepLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenRepPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersLiteralThenRepOverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      0, 1, 0, Ord('A'), False, 0, 2, 1, 1, LiteralThenRepPrice,
      MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'literal-then-rep decision must reject one-byte next reps without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte next rep is not encodable and must not win the lookahead decision');
  Assert.AreEqual(High(UInt32), LiteralThenRepPrice,
    'one-byte next rep must clamp literal-then-rep price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte next rep must leave no finite current-match comparison price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenRepRejectsOneByteCurrentMatchLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenRepPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersLiteralThenRepOverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      0, 1, 0, Ord('A'), False, 0, 1, 1, 2, LiteralThenRepPrice,
      MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'literal-then-rep decision must reject one-byte current matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte current match is not encodable and must not keep the baseline decision');
  Assert.AreEqual(High(UInt32), LiteralThenRepPrice,
    'one-byte current match must leave no finite literal-then-rep comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte current match must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumLiteralThenRepRejectsZeroCurrentMatchDistance;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralThenRepPrice: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersLiteralThenRepOverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      0, 1, 0, Ord('A'), False, 0, 2, 0, 2, LiteralThenRepPrice,
      MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'literal-then-rep decision must reject zero current-match distance without raising from price tables');
  Assert.IsFalse(Decision,
    'zero current-match distance is not encodable and must not keep the baseline decision');
  Assert.AreEqual(High(UInt32), LiteralThenRepPrice,
    'zero current-match distance must leave no finite literal-then-rep comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'zero current-match distance must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0UsesSdkPrices;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs, ProbPrices);

  LenPriceEnc.Prices[0][1] := 12;
  DistancePriceEnc.DistancePrices[1][0] := 12;
  RepLenPriceEnc.Prices[0][2] := 12;
  LenPriceEnc.Prices[0][5] := 420;
  DistancePriceEnc.DistancePrices[3][4] := 420;

  Assert.IsTrue(
    LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices, LiteralProbs, LenPriceEnc,
      RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 0, 3, 0, Ord('B'), False, 0, 3, 1, 4, 7, 5,
      MatchLiteralRep0Price, MatchPrice),
    'bounded optimum pricing should choose match + literal + rep0 when it is cheaper than the current match');
  Assert.IsTrue(MatchLiteralRep0Price < MatchPrice, 'synthetic prices must prefer match + literal + rep0');

  LenPriceEnc.Prices[0][5] := 10;
  DistancePriceEnc.DistancePrices[3][4] := 10;
  Assert.IsFalse(
    LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices, LiteralProbs, LenPriceEnc,
      RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, 0, 3, 0, Ord('B'), False, 0, 3, 1, 4, 7, 5,
      MatchLiteralRep0Price, MatchPrice),
    'bounded optimum pricing must keep the current match when it is cheaper');
  Assert.IsTrue(MatchPrice < MatchLiteralRep0Price, 'second synthetic setup must prefer current match');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsOverflowingLookaheadPrice;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  LenPriceEnc.Prices[0][1] := 12;
  DistancePriceEnc.DistancePrices[1][0] := 12;
  RepLenPriceEnc.Prices[0][2] := High(UInt32) - 16;
  LenPriceEnc.Prices[0][5] := 4096;
  DistancePriceEnc.DistancePrices[3][4] := 4096;

  Assert.IsFalse(
    LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 3, 0, Ord('B'), False, 0, 3, 1,
      4, 7, 5, MatchLiteralRep0Price, MatchPrice),
    'match-literal-rep0 comparison must not wrap an overflowing lookahead price into a win');
  Assert.IsTrue(MatchLiteralRep0Price >= MatchPrice,
    'overflowing match-literal-rep0 price must not be reported cheaper than finite current match');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsOverflowingFirstMatchDecisionBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'), False, 0, 2,
      High(UInt32), 2, 4, 1, MatchLiteralRep0Price, MatchPrice),
    'match+literal+rep0 decision must reject first-match distances whose encoded back overflows');
  Assert.AreEqual(High(UInt32), MatchLiteralRep0Price,
    'overflowing first-match distance must clamp match-literal-rep0 price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'overflowing first-match distance must leave no finite comparison price');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsOverflowingCurrentMatchDecisionBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'), False, 0, 2,
      1, 2, 4, High(UInt32), MatchLiteralRep0Price, MatchPrice),
    'match+literal+rep0 decision must reject current-match distances whose encoded back overflows');
  Assert.AreEqual(High(UInt32), MatchLiteralRep0Price,
    'overflowing current-match distance must leave no finite compact-path price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'overflowing current-match distance must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsOneByteFirstMatchLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'),
      False, 0, 1, 1, 2, 2, 1, MatchLiteralRep0Price, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match+literal+rep0 decision must reject one-byte first matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte first match is not encodable and must not win the compact path');
  Assert.AreEqual(High(UInt32), MatchLiteralRep0Price,
    'one-byte first match must clamp compact-path price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte first match must leave no finite current-match comparison price');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsOneByteRepLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'),
      False, 0, 2, 1, 1, 2, 1, MatchLiteralRep0Price, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match+literal+rep0 decision must reject one-byte rep matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte rep match is not encodable and must not win the compact path');
  Assert.AreEqual(High(UInt32), MatchLiteralRep0Price,
    'one-byte rep match must clamp compact-path price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte rep match must leave no finite current-match comparison price');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsOneByteCurrentMatchLength;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'),
      False, 0, 2, 1, 2, 1, 1, MatchLiteralRep0Price, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match+literal+rep0 decision must reject one-byte current matches without raising from price tables');
  Assert.IsFalse(Decision,
    'one-byte current match is not encodable and must not keep the baseline decision');
  Assert.AreEqual(High(UInt32), MatchLiteralRep0Price,
    'one-byte current match must leave no finite compact-path comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'one-byte current match must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsZeroFirstMatchDistance;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'),
      False, 0, 2, 0, 2, 2, 1, MatchLiteralRep0Price, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match+literal+rep0 decision must reject zero first-match distance without raising from price tables');
  Assert.IsFalse(Decision,
    'zero first-match distance is not encodable and must not win the compact path');
  Assert.AreEqual(High(UInt32), MatchLiteralRep0Price,
    'zero first-match distance must clamp compact-path price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'zero first-match distance must leave no finite current-match comparison price');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0RejectsZeroCurrentMatchDistance;
var
  AlignProbs: TLzmaAlignProbs;
  Decision: Boolean;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  MatchLiteralRep0Price: UInt32;
  MatchPrice: UInt32;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Decision := True;
  try
    Decision := LzmaOptimumPrefersMatchLiteralRep0OverMatch(ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'),
      False, 0, 2, 1, 2, 2, 0, MatchLiteralRep0Price, MatchPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match+literal+rep0 decision must reject zero current-match distance without raising from price tables');
  Assert.IsFalse(Decision,
    'zero current-match distance is not encodable and must not keep the baseline decision');
  Assert.AreEqual(High(UInt32), MatchLiteralRep0Price,
    'zero current-match distance must leave no finite compact-path comparison price');
  Assert.AreEqual(High(UInt32), MatchPrice,
    'zero current-match distance must clamp current-match price');
end;

procedure TLzma2NativeTests.OptimumPrepareNodesClearsPathsAndSeedsStartPrice;
var
  EmptyNodes: TArray<TLzmaOptimumNode>;
  I: Integer;
  Nodes: array[0..3] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), $A5);

  LzmaOptimumPrepareNodes(Nodes, 17);

  Assert.AreEqual(UInt32(17), Nodes[0].Price, 'start node price');
  Assert.AreEqual(UInt32(0), Nodes[0].PathLen, 'start node path length');
  Assert.AreEqual(UInt32(0), Nodes[0].PathBack, 'start node path back');
  Assert.AreEqual(UInt32(0), Nodes[0].Extra, 'start node extra marker');
  Assert.AreEqual(UInt32(0), Nodes[0].PosPrev, 'start node previous position');
  Assert.AreEqual(UInt32(0), Nodes[0].BackPrev, 'start node previous back');
  Assert.IsFalse(Nodes[0].Prev1IsLiteral, 'start node folded literal marker');
  Assert.AreEqual(UInt32(0), Nodes[0].PosPrev2, 'start node folded previous position');
  Assert.AreEqual(UInt32(0), Nodes[0].BackPrev2, 'start node folded previous back');

  for I := 1 to High(Nodes) do
  begin
    Assert.AreEqual(High(UInt32), Nodes[I].Price, 'unreached node price');
    Assert.AreEqual(UInt32(0), Nodes[I].PathLen, 'unreached node path length');
    Assert.AreEqual(UInt32(0), Nodes[I].PathBack, 'unreached node path back');
    Assert.AreEqual(UInt32(0), Nodes[I].Extra, 'unreached node extra marker');
    Assert.AreEqual(UInt32(0), Nodes[I].PosPrev, 'unreached node previous position');
    Assert.AreEqual(UInt32(0), Nodes[I].BackPrev, 'unreached node previous back');
    Assert.IsFalse(Nodes[I].Prev1IsLiteral, 'unreached node folded literal marker');
    Assert.AreEqual(UInt32(0), Nodes[I].PosPrev2, 'unreached node folded previous position');
    Assert.AreEqual(UInt32(0), Nodes[I].BackPrev2, 'unreached node folded previous back');
  end;

  LzmaOptimumPrepareNodes(EmptyNodes);
  Assert.IsTrue(Length(EmptyNodes) = 0, 'empty dynamic node array remains empty');
end;

procedure TLzma2NativeTests.OptimumPrepareNodesSeedsStartStateAndReps;
var
  I: Integer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  StartReps: array[0..3] of UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), $A5);
  StartReps[0] := 5;
  StartReps[1] := 7;
  StartReps[2] := 11;
  StartReps[3] := 13;

  LzmaOptimumPrepareNodes(Nodes, 23, 6, StartReps);

  Assert.AreEqual(UInt32(23), Nodes[0].Price, 'start node price');
  Assert.AreEqual(UInt32(6), Nodes[0].State, 'start node parser state');
  for I := Low(StartReps) to High(StartReps) do
    Assert.AreEqual(StartReps[I], Nodes[0].Reps[I], 'start node rep distance');
  for I := 1 to High(Nodes) do
  begin
    Assert.AreEqual(High(UInt32), Nodes[I].Price, 'unreached node price');
    Assert.AreEqual(UInt32(0), Nodes[I].State, 'unreached node state');
    Assert.AreEqual(UInt32(0), Nodes[I].Reps[0], 'unreached node rep0');
  end;
end;

procedure TLzma2NativeTests.OptimumMatchCandidatesUseSdkPairDistancesAcrossLengths;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..5] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  for I := Low(Nodes) to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;
  Nodes[0].Price := 0;

  Matches.Clear;
  Matches.Add(3, 20);
  Matches.Add(5, 7);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs,
    ProbPrices);

  LzmaOptimumSeedMatchCandidates(Nodes, Matches, ProbPrices, LenPriceEnc,
    DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 5);

  Assert.AreEqual(UInt32(2), Nodes[2].PathLen, 'length-2 candidate must be seeded');
  Assert.AreEqual(UInt32(20 + 3), Nodes[2].PathBack,
    'SDK pair distance should cover lengths below the first pair boundary');
  Assert.AreEqual(UInt32(3), Nodes[3].PathLen, 'length-3 candidate must be seeded');
  Assert.AreEqual(UInt32(20 + 3), Nodes[3].PathBack,
    'first match pair distance should be used through its boundary length');
  Assert.AreEqual(UInt32(4), Nodes[4].PathLen, 'length-4 candidate must be seeded');
  Assert.AreEqual(UInt32(7 + 3), Nodes[4].PathBack,
    'second match pair distance should take over after the first boundary');
  Assert.AreEqual(UInt32(5), Nodes[5].PathLen, 'length-5 candidate must be seeded');
  Assert.AreEqual(UInt32(7 + 3), Nodes[5].PathBack,
    'second match pair distance should be used through its boundary length');
end;

procedure TLzma2NativeTests.OptimumRepCandidatesSeedBeforeNormalMatchesAndKeepTie;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLens: array[0..3] of UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  for I := Low(Nodes) to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;
  Nodes[0].Price := 0;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs,
    ProbPrices);

  RepLenPriceEnc.Prices[0][0] := 10;
  LenPriceEnc.Prices[0][0] := 20;
  DistancePriceEnc.DistancePrices[0][0] := 24;

  RepLens[0] := 2;
  RepLens[1] := 0;
  RepLens[2] := 0;
  RepLens[3] := 0;

  LzmaOptimumSeedRepCandidates(Nodes, RepLens, ProbPrices, RepLenPriceEnc,
    LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, LZMA_PROB_INIT, 0);

  Assert.AreEqual(UInt32(2), Nodes[2].PathLen, 'rep0 len=2 candidate must be seeded');
  Assert.AreEqual(UInt32(0), Nodes[2].PathBack, 'rep candidate back is rep index');
  Assert.AreEqual(UInt32(77), Nodes[2].Price,
    'rep0 price should use SDK rep prefix + pure rep + rep length');

  Matches.Clear;
  Matches.Add(2, 1);
  LzmaOptimumSeedMatchCandidates(Nodes, Matches, ProbPrices, LenPriceEnc,
    DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2);

  Assert.AreEqual(UInt32(0), Nodes[2].PathBack,
    'equal-price normal match must not replace the earlier SDK rep candidate');
end;

procedure TLzma2NativeTests.OptimumSeedCandidatesIncludePreparedStartPrice;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  ExpectedMatchPrice: UInt32;
  ExpectedRepPrice: UInt32;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  MatchNodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLens: array[0..3] of UInt32;
  RepNodes: array[0..2] of TLzmaOptimumNode;
begin
  LzmaInitProbPrices(ProbPrices);

  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);

  LzmaOptimumPrepareNodes(RepNodes, 17);
  FillChar(RepLens, SizeOf(RepLens), 0);
  RepLens[0] := 2;
  ExpectedRepPrice := UInt32(17) +
    LzmaRepMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0) +
    LzmaLenPrice(RepLenPriceEnc, 0, 2);

  LzmaOptimumSeedRepCandidates(RepNodes, RepLens, ProbPrices, RepLenPriceEnc,
    LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, LZMA_PROB_INIT, 0);

  Assert.AreEqual(ExpectedRepPrice, RepNodes[2].Price,
    'initial rep seed must include prepared start-node price');

  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  LzmaOptimumPrepareNodes(MatchNodes, 17);
  Matches.Clear;
  Matches.Add(2, 1);
  ExpectedMatchPrice := UInt32(17) +
    LzmaNormalMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaLenPrice(LenPriceEnc, 0, 2) +
    LzmaMatchDistancePrice(DistancePriceEnc, 2, 1);

  LzmaOptimumSeedMatchCandidates(MatchNodes, Matches, ProbPrices, LenPriceEnc,
    DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2);

  Assert.AreEqual(ExpectedMatchPrice, MatchNodes[2].Price,
    'initial normal-match seed must include prepared start-node price');
end;

procedure TLzma2NativeTests.OptimumSeedCandidatesRejectOverflowingStartPrice;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  MatchNodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLens: array[0..3] of UInt32;
  RepNodes: array[0..2] of TLzmaOptimumNode;
begin
  LzmaInitProbPrices(ProbPrices);

  FillChar(RepNodes, SizeOf(RepNodes), 0);
  RepNodes[0].Price := High(UInt32) - 1;
  for I := 1 to High(RepNodes) do
    RepNodes[I].Price := UInt32(1) shl 30;

  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);

  FillChar(RepLens, SizeOf(RepLens), 0);
  RepLens[0] := 2;

  LzmaOptimumSeedRepCandidates(RepNodes, RepLens, ProbPrices, RepLenPriceEnc,
    LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, LZMA_PROB_INIT, 0);

  Assert.AreEqual(UInt32(1) shl 30, RepNodes[2].Price,
    'initial rep seed must not wrap an overflowing start-node price into a cheap path');

  FillChar(MatchNodes, SizeOf(MatchNodes), 0);
  MatchNodes[0].Price := High(UInt32) - 1;
  for I := 1 to High(MatchNodes) do
    MatchNodes[I].Price := UInt32(1) shl 30;

  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Matches.Clear;
  Matches.Add(2, 1);

  LzmaOptimumSeedMatchCandidates(MatchNodes, Matches, ProbPrices, LenPriceEnc,
    DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2);

  Assert.AreEqual(UInt32(1) shl 30, MatchNodes[2].Price,
    'initial normal-match seed must not wrap an overflowing start-node price into a cheap path');
end;

procedure TLzma2NativeTests.OptimumSeedMatchCandidatesRejectOverflowingBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  for I := Low(Nodes) to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;
  Nodes[0].Price := 0;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(High(UInt32)) + 1);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Matches.Clear;
  Matches.Add(2, High(UInt32));

  LzmaOptimumSeedMatchCandidates(Nodes, Matches, ProbPrices, LenPriceEnc,
    DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2);

  Assert.AreEqual(UInt32(1) shl 30, Nodes[2].Price,
    'match seed must reject distances whose encoded back overflows');
  Assert.AreEqual(UInt32(0), Nodes[2].PathLen,
    'overflowing match seed must leave path length unset');
  Assert.AreEqual(UInt32(0), Nodes[2].PathBack,
    'overflowing match seed must leave encoded back unset');
end;

procedure TLzma2NativeTests.OptimumSeedMatchCandidatesRejectZeroBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  for I := Low(Nodes) to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;
  Nodes[0].Price := 0;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Matches.Clear;
  Matches.Add(2, 0);

  RaisedMessage := '';
  try
    LzmaOptimumSeedMatchCandidates(Nodes, Matches, ProbPrices, LenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match seed must reject zero back-distance without raising from price tables');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[2].Price,
    'zero-distance match seed must preserve the existing target node');
  Assert.AreEqual(UInt32(0), Nodes[2].PathLen,
    'zero-distance match seed must leave path length unset');
  Assert.AreEqual(UInt32(0), Nodes[2].PathBack,
    'zero-distance match seed must leave encoded back unset');
end;

procedure TLzma2NativeTests.OptimumLiteralCandidateRelaxesFromPreviousNodeAndKeepsTie;
var
  Back: UInt32;
  ExpectedPrice: UInt32;
  Len: UInt32;
  LiteralPrice: UInt32;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..1] of TLzmaOptimumNode;
  ProbPrices: TLzmaProbPrices;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 40;
  Nodes[1].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  ExpectedPrice := Nodes[0].Price + LzmaBitPrice(ProbPrices, LZMA_PROB_INIT, 0) +
    LzmaLiteralPrice(LiteralProbs, Ord('A'), ProbPrices);

  Assert.IsTrue(
    LzmaOptimumRelaxLiteralCandidate(Nodes, 0, ProbPrices, LiteralProbs,
      LZMA_PROB_INIT, Ord('A'), False, 0, LiteralPrice),
    'literal candidate must relax the next optimum node from the previous node price');
  Assert.AreEqual(ExpectedPrice, LiteralPrice, 'literal candidate price');
  Assert.AreEqual(ExpectedPrice, Nodes[1].Price, 'relaxed node price');
  Assert.AreEqual(UInt32(1), Nodes[1].PathLen, 'literal path length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Nodes[1].PathBack, 'literal path back marker');
  Assert.AreEqual(UInt32(0), Nodes[1].PosPrev, 'literal previous position');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Nodes[1].BackPrev, 'literal previous back marker');

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 1, Len, Back),
    'relaxed literal node must replay as a first command');
  Assert.AreEqual(UInt32(1), Len, 'replayed literal length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back, 'replayed literal back marker');

  Assert.IsFalse(
    LzmaOptimumRelaxLiteralCandidate(Nodes, 0, ProbPrices, LiteralProbs,
      LZMA_PROB_INIT, Ord('A'), False, 0, LiteralPrice),
    'equal-price literal candidate must preserve the existing optimum node');
end;

procedure TLzma2NativeTests.OptimumLiteralCandidateRejectsOverflowingPreviousPrice;
var
  LiteralPrice: UInt32;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..1] of TLzmaOptimumNode;
  ProbPrices: TLzmaProbPrices;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := High(UInt32) - 1;
  Nodes[1].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);

  Assert.IsFalse(
    LzmaOptimumRelaxLiteralCandidate(Nodes, 0, ProbPrices, LiteralProbs,
      LZMA_PROB_INIT, Ord('A'), False, 0, LiteralPrice),
    'literal relaxation must not wrap an overflowing previous-node price into a cheap path');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[1].Price,
    'overflowing literal candidate must preserve the existing target node');
end;

procedure TLzma2NativeTests.OptimumShortRepCandidateRelaxesFromPreviousNodeAndKeepsTie;
var
  Back: UInt32;
  ExpectedPrice: UInt32;
  Len: UInt32;
  Nodes: array[0..1] of TLzmaOptimumNode;
  ProbPrices: TLzmaProbPrices;
  ShortRepPrice: UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 40;
  Nodes[1].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  ExpectedPrice := Nodes[0].Price + LzmaRepMatchPrefixPrice(ProbPrices,
    LZMA_PROB_INIT, LZMA_PROB_INIT) + LzmaShortRepPrice(ProbPrices,
    LZMA_PROB_INIT, LZMA_PROB_INIT);

  Assert.IsTrue(
    LzmaOptimumRelaxShortRepCandidate(Nodes, 0, ProbPrices, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, ShortRepPrice),
    'short-rep candidate must relax the next optimum node from the previous node price');
  Assert.AreEqual(ExpectedPrice, ShortRepPrice, 'short-rep candidate price');
  Assert.AreEqual(ExpectedPrice, Nodes[1].Price, 'relaxed short-rep node price');
  Assert.AreEqual(UInt32(1), Nodes[1].PathLen, 'short-rep path length');
  Assert.AreEqual(UInt32(0), Nodes[1].PathBack, 'short-rep path back is rep0');
  Assert.AreEqual(UInt32(0), Nodes[1].PosPrev, 'short-rep previous position');
  Assert.AreEqual(UInt32(0), Nodes[1].BackPrev, 'short-rep previous back marker');

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 1, Len, Back),
    'relaxed short-rep node must replay as a first command');
  Assert.AreEqual(UInt32(1), Len, 'replayed short-rep length');
  Assert.AreEqual(UInt32(0), Back, 'replayed short-rep back marker');

  Assert.IsFalse(
    LzmaOptimumRelaxShortRepCandidate(Nodes, 0, ProbPrices, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, ShortRepPrice),
    'equal-price short-rep candidate must preserve the existing optimum node');
end;

procedure TLzma2NativeTests.OptimumShortRepCandidateRejectsOverflowingPreviousPrice;
var
  Nodes: array[0..1] of TLzmaOptimumNode;
  ProbPrices: TLzmaProbPrices;
  ShortRepPrice: UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := High(UInt32) - 1;
  Nodes[1].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);

  Assert.IsFalse(
    LzmaOptimumRelaxShortRepCandidate(Nodes, 0, ProbPrices, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, ShortRepPrice),
    'short-rep relaxation must not wrap an overflowing previous-node price into a cheap path');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[1].Price,
    'overflowing short-rep candidate must preserve the existing target node');
end;

procedure TLzma2NativeTests.OptimumMatchCandidatesRelaxFromPreviousNodeAndKeepTie;
var
  AlignProbs: TLzmaAlignProbs;
  Back: UInt32;
  BestRelaxedPrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  ExpectedBestPrice: UInt32;
  ExpectedLen2Price: UInt32;
  ExpectedLen3Price: UInt32;
  I: Integer;
  Len: UInt32;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralPrice: UInt32;
  LiteralProbs: TLzmaLiteralProbs;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..5] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 40;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs,
    ProbPrices);

  Assert.IsTrue(
    LzmaOptimumRelaxLiteralCandidate(Nodes, 0, ProbPrices, LiteralProbs,
      LZMA_PROB_INIT, Ord('A'), False, 0, LiteralPrice),
    'literal candidate must create a previous optimum node');

  Matches.Clear;
  Matches.Add(3, 20);

  ExpectedLen2Price := Nodes[1].Price +
    LzmaNormalMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaLenPrice(LenPriceEnc, 1, 2) +
    LzmaMatchDistancePrice(DistancePriceEnc, 2, 20);
  ExpectedLen3Price := Nodes[1].Price +
    LzmaNormalMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaLenPrice(LenPriceEnc, 1, 3) +
    LzmaMatchDistancePrice(DistancePriceEnc, 3, 20);
  ExpectedBestPrice := ExpectedLen2Price;
  if ExpectedLen3Price < ExpectedBestPrice then
    ExpectedBestPrice := ExpectedLen3Price;

  Assert.IsTrue(
    LzmaOptimumRelaxMatchCandidates(Nodes, 1, Matches, ProbPrices, LenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 1, 2, 3,
      BestRelaxedPrice),
    'normal match candidates must relax from a non-zero previous node');
  Assert.AreEqual(ExpectedBestPrice, BestRelaxedPrice, 'best relaxed match price');
  Assert.AreEqual(ExpectedLen2Price, Nodes[3].Price, 'relaxed len=2 node price');
  Assert.AreEqual(UInt32(2), Nodes[3].PathLen, 'relaxed len=2 match length');
  Assert.AreEqual(UInt32(20 + 3), Nodes[3].PathBack, 'relaxed len=2 match back marker');
  Assert.AreEqual(UInt32(1), Nodes[3].PosPrev, 'relaxed len=2 previous position');
  Assert.AreEqual(UInt32(20 + 3), Nodes[3].BackPrev, 'relaxed len=2 previous back');
  Assert.AreEqual(ExpectedLen3Price, Nodes[4].Price, 'relaxed len=3 node price');
  Assert.AreEqual(UInt32(3), Nodes[4].PathLen, 'relaxed len=3 match length');
  Assert.AreEqual(UInt32(20 + 3), Nodes[4].PathBack, 'relaxed len=3 match back marker');
  Assert.AreEqual(UInt32(0), Nodes[4].Extra, 'ordinary relaxed match has no folded extra');
  Assert.IsFalse(Nodes[4].Prev1IsLiteral, 'ordinary relaxed match is not a folded literal path');
  Assert.AreEqual(UInt32(1), Nodes[4].PosPrev, 'relaxed len=3 previous position');
  Assert.AreEqual(UInt32(20 + 3), Nodes[4].BackPrev, 'relaxed len=3 previous back');
  Assert.AreEqual(UInt32(0), Nodes[4].PosPrev2, 'ordinary relaxed match clears folded position');
  Assert.AreEqual(UInt32(0), Nodes[4].BackPrev2, 'ordinary relaxed match clears folded back');

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 4, Len, Back),
    'relaxed literal then match path must replay as a first command');
  Assert.AreEqual(UInt32(1), Len, 'replayed first command length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back,
    'replayed first command must be the leading literal');

  Assert.IsFalse(
    LzmaOptimumRelaxMatchCandidates(Nodes, 1, Matches, ProbPrices, LenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 1, 2, 3,
      BestRelaxedPrice),
    'equal-price match candidates must preserve the existing optimum nodes');
end;

procedure TLzma2NativeTests.OptimumMatchCandidatesRejectOverflowingPreviousPrice;
var
  AlignProbs: TLzmaAlignProbs;
  BestRelaxedPrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := High(UInt32) - 1;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  Matches.Clear;
  Matches.Add(2, 1);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumRelaxMatchCandidates(Nodes, 0, Matches, ProbPrices, LenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2,
      BestRelaxedPrice),
    'normal-match relaxation must not wrap an overflowing previous-node price into a cheap path');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[2].Price,
    'overflowing normal-match candidate must preserve the existing target node');
end;

procedure TLzma2NativeTests.OptimumRelaxMatchCandidatesRejectOverflowingBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  BestRelaxedPrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(High(UInt32)) + 1);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Matches.Clear;
  Matches.Add(2, High(UInt32));

  Assert.IsFalse(
    LzmaOptimumRelaxMatchCandidates(Nodes, 0, Matches, ProbPrices, LenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2,
      BestRelaxedPrice),
    'match relax must reject distances whose encoded back overflows');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[2].Price,
    'overflowing normal-match distance must preserve the existing target node');
  Assert.AreEqual(UInt32(0), Nodes[2].PathLen,
    'overflowing normal-match distance must leave path length unset');
  Assert.AreEqual(UInt32(0), Nodes[2].PathBack,
    'overflowing normal-match distance must leave encoded back unset');
end;

procedure TLzma2NativeTests.OptimumRelaxMatchCandidatesRejectZeroBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  BestRelaxedPrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  Relaxed: Boolean;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Matches.Clear;
  Matches.Add(2, 0);

  RaisedMessage := '';
  Relaxed := True;
  try
    Relaxed := LzmaOptimumRelaxMatchCandidates(Nodes, 0, Matches, ProbPrices,
      LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2,
      BestRelaxedPrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match relax must reject zero back-distance without raising from price tables');
  Assert.IsFalse(Relaxed,
    'zero-distance normal-match candidate must not relax an optimum node');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[2].Price,
    'zero-distance normal-match candidate must preserve the existing target node');
  Assert.AreEqual(UInt32(0), Nodes[2].PathLen,
    'zero-distance normal-match candidate must leave path length unset');
  Assert.AreEqual(UInt32(0), Nodes[2].PathBack,
    'zero-distance normal-match candidate must leave encoded back unset');
end;

procedure TLzma2NativeTests.OptimumRepCandidatesRelaxFromPreviousNodeAndKeepTie;
var
  Back: UInt32;
  BestRelaxedPrice: UInt32;
  ExpectedBestPrice: UInt32;
  ExpectedLen2Price: UInt32;
  ExpectedLen3Price: UInt32;
  I: Integer;
  Len: UInt32;
  LiteralPrice: UInt32;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..4] of TLzmaOptimumNode;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLens: array[0..3] of UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 40;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);

  Assert.IsTrue(
    LzmaOptimumRelaxLiteralCandidate(Nodes, 0, ProbPrices, LiteralProbs,
      LZMA_PROB_INIT, Ord('B'), False, 0, LiteralPrice),
    'literal candidate must create a previous optimum node');

  RepLens[0] := 0;
  RepLens[1] := 0;
  RepLens[2] := 3;
  RepLens[3] := 0;

  ExpectedLen2Price := Nodes[1].Price +
    LzmaRepMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 2) +
    LzmaLenPrice(RepLenPriceEnc, 2, 2);
  ExpectedLen3Price := Nodes[1].Price +
    LzmaRepMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 2) +
    LzmaLenPrice(RepLenPriceEnc, 2, 3);
  ExpectedBestPrice := ExpectedLen2Price;
  if ExpectedLen3Price < ExpectedBestPrice then
    ExpectedBestPrice := ExpectedLen3Price;

  Assert.IsTrue(
    LzmaOptimumRelaxRepCandidates(Nodes, 1, RepLens, ProbPrices, RepLenPriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 2, BestRelaxedPrice),
    'rep candidates must relax from a non-zero previous node');
  Assert.AreEqual(ExpectedBestPrice, BestRelaxedPrice, 'best relaxed rep price');
  Assert.AreEqual(ExpectedLen2Price, Nodes[3].Price, 'relaxed len=2 rep node price');
  Assert.AreEqual(UInt32(2), Nodes[3].PathLen, 'relaxed len=2 rep length');
  Assert.AreEqual(UInt32(2), Nodes[3].PathBack, 'relaxed len=2 rep back marker');
  Assert.AreEqual(UInt32(1), Nodes[3].PosPrev, 'relaxed len=2 rep previous position');
  Assert.AreEqual(UInt32(2), Nodes[3].BackPrev, 'relaxed len=2 rep previous back');
  Assert.AreEqual(ExpectedLen3Price, Nodes[4].Price, 'relaxed len=3 rep node price');
  Assert.AreEqual(UInt32(3), Nodes[4].PathLen, 'relaxed rep length');
  Assert.AreEqual(UInt32(2), Nodes[4].PathBack, 'relaxed rep back marker');
  Assert.AreEqual(UInt32(0), Nodes[4].Extra, 'ordinary relaxed rep has no folded extra');
  Assert.IsFalse(Nodes[4].Prev1IsLiteral, 'ordinary relaxed rep is not a folded literal path');
  Assert.AreEqual(UInt32(1), Nodes[4].PosPrev, 'relaxed rep previous position');
  Assert.AreEqual(UInt32(2), Nodes[4].BackPrev, 'relaxed rep previous back');
  Assert.AreEqual(UInt32(0), Nodes[4].PosPrev2, 'ordinary relaxed rep clears folded position');
  Assert.AreEqual(UInt32(0), Nodes[4].BackPrev2, 'ordinary relaxed rep clears folded back');

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 4, Len, Back),
    'relaxed literal then rep path must replay as a first command');
  Assert.AreEqual(UInt32(1), Len, 'replayed rep first command length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back,
    'replayed rep first command must be the leading literal');

  Assert.IsFalse(
    LzmaOptimumRelaxRepCandidates(Nodes, 1, RepLens, ProbPrices, RepLenPriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 2, BestRelaxedPrice),
    'equal-price rep candidates must preserve the existing optimum node');
end;

procedure TLzma2NativeTests.OptimumRepCandidatesRejectOverflowingPreviousPrice;
var
  BestRelaxedPrice: UInt32;
  I: Integer;
  Nodes: array[0..2] of TLzmaOptimumNode;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLens: array[0..3] of UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := High(UInt32) - 1;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  FillChar(RepLens, SizeOf(RepLens), 0);
  RepLens[0] := 2;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumRelaxRepCandidates(Nodes, 0, RepLens, ProbPrices, RepLenPriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, BestRelaxedPrice),
    'rep relaxation must not wrap an overflowing previous-node price into a cheap path');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[2].Price,
    'overflowing rep candidate must preserve the existing target node');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0CandidateRelaxesSdkExtraPathAndKeepsTie;
var
  AlignProbs: TLzmaAlignProbs;
  Back: UInt32;
  CandidatePrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  ExpectedPrice: UInt32;
  I: Integer;
  Len: UInt32;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..7] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 40;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs,
    ProbPrices);

  ExpectedPrice := Nodes[0].Price +
    LzmaNormalMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaLenPrice(LenPriceEnc, 0, 2) +
    LzmaMatchDistancePrice(DistancePriceEnc, 2, 11) +
    LzmaBitPrice(ProbPrices, LZMA_PROB_INIT, 0) +
    LzmaLiteralPrice(LiteralProbs, Ord('C'), ProbPrices) +
    LzmaRepMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaRep0LongPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaLenPrice(RepLenPriceEnc, 3, 4);

  Assert.IsTrue(
    LzmaOptimumRelaxMatchLiteralRep0Candidate(Nodes, 0, ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 3, Ord('C'), False, 0, 2, 11,
      4, CandidatePrice),
    'match + literal + rep0 candidate must relax the SDK extra optimum node');
  Assert.AreEqual(ExpectedPrice, CandidatePrice, 'match + literal + rep0 candidate price');
  Assert.AreEqual(ExpectedPrice, Nodes[7].Price, 'relaxed SDK extra node price');
  Assert.AreEqual(UInt32(4), Nodes[7].PathLen, 'SDK extra node stores final rep0 length');
  Assert.AreEqual(UInt32(11 + 3), Nodes[7].PathBack,
    'SDK extra node stores first match back for replay');
  Assert.AreEqual(UInt32(3), Nodes[7].Extra,
    'SDK extra marker stores first match length plus the literal');
  Assert.AreEqual(UInt32(3), Nodes[7].PosPrev, 'final rep predecessor position');
  Assert.AreEqual(UInt32(0), Nodes[7].BackPrev, 'final rep predecessor is rep0');
  Assert.IsFalse(Nodes[7].Prev1IsLiteral, 'SDK extra path uses compact extra replay');

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 7, Len, Back),
    'relaxed SDK extra node must replay as a first command');
  Assert.AreEqual(UInt32(2), Len, 'replayed SDK extra first command length');
  Assert.AreEqual(UInt32(11 + 3), Back, 'replayed SDK extra first command back');

  Assert.IsFalse(
    LzmaOptimumRelaxMatchLiteralRep0Candidate(Nodes, 0, ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 3, Ord('C'), False, 0, 2, 11,
      4, CandidatePrice),
    'equal-price match + literal + rep0 candidate must preserve the existing optimum node');
end;

procedure TLzma2NativeTests.OptimumRepLiteralRep0CandidateRelaxesSdkExtraPathAndKeepsTie;
var
  Back: UInt32;
  CandidatePrice: UInt32;
  ExpectedPrice: UInt32;
  I: Integer;
  Len: UInt32;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..7] of TLzmaOptimumNode;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  StartReps: TLzmaOptimumReps;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 17;
  StartReps[1] := 11;
  LzmaOptimumPrepareNodes(Nodes, 40, 0, StartReps);
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);

  ExpectedPrice := Nodes[0].Price +
    LzmaRepMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaPureRepPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 1) +
    LzmaLenPrice(RepLenPriceEnc, 0, 2) +
    LzmaBitPrice(ProbPrices, LZMA_PROB_INIT, 0) +
    LzmaLiteralPrice(LiteralProbs, Ord('R'), ProbPrices) +
    LzmaRepMatchPrefixPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaRep0LongPrice(ProbPrices, LZMA_PROB_INIT, LZMA_PROB_INIT) +
    LzmaLenPrice(RepLenPriceEnc, 3, 4);

  Assert.IsTrue(
    LzmaOptimumRelaxRepLiteralRep0Candidate(Nodes, 0, ProbPrices, LiteralProbs,
      RepLenPriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      0, 3, 1, Ord('R'), False, 0, 2, 4, CandidatePrice),
    'rep + literal + rep0 candidate must relax the SDK extra optimum node');
  Assert.AreEqual(ExpectedPrice, CandidatePrice, 'rep + literal + rep0 candidate price');
  Assert.AreEqual(ExpectedPrice, Nodes[7].Price, 'relaxed SDK rep extra node price');
  Assert.AreEqual(UInt32(4), Nodes[7].PathLen, 'SDK rep extra node stores final rep0 length');
  Assert.AreEqual(UInt32(1), Nodes[7].PathBack,
    'SDK rep extra node stores first rep index for replay');
  Assert.AreEqual(UInt32(3), Nodes[7].Extra,
    'SDK rep extra marker stores first rep length plus the literal');
  Assert.AreEqual(UInt32(3), Nodes[7].PosPrev, 'final rep predecessor position');
  Assert.AreEqual(UInt32(0), Nodes[7].BackPrev, 'final rep predecessor is rep0');
  Assert.IsFalse(Nodes[7].Prev1IsLiteral, 'SDK rep extra path uses compact extra replay');

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 7, Len, Back),
    'relaxed SDK rep extra node must replay as a first command');
  Assert.AreEqual(UInt32(2), Len, 'replayed SDK rep extra first command length');
  Assert.AreEqual(UInt32(1), Back, 'replayed SDK rep extra first command back');

  Assert.IsFalse(
    LzmaOptimumRelaxRepLiteralRep0Candidate(Nodes, 0, ProbPrices, LiteralProbs,
      RepLenPriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      0, 3, 1, Ord('R'), False, 0, 2, 4, CandidatePrice),
    'equal-price rep + literal + rep0 candidate must preserve the existing optimum node');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0CandidateRejectsOverflowingPreviousPrice;
var
  AlignProbs: TLzmaAlignProbs;
  CandidatePrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..5] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := High(UInt32) - 1;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumRelaxMatchLiteralRep0Candidate(Nodes, 0, ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 3, Ord('C'), False, 0,
      2, 1, 2, CandidatePrice),
    'match + literal + rep0 relaxation must not wrap an overflowing previous-node price into a cheap path');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[5].Price,
    'overflowing match + literal + rep0 candidate must preserve the existing target node');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0CandidateRejectsOverflowingFirstMatchBackDistance;
var
  AlignProbs: TLzmaAlignProbs;
  CandidatePrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..5] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(High(UInt32)) + 1);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Assert.IsFalse(
    LzmaOptimumRelaxMatchLiteralRep0Candidate(Nodes, 0, ProbPrices, LiteralProbs,
      LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'), False, 0,
      2, High(UInt32), 2, CandidatePrice),
    'match + literal + rep0 relax must reject first-match distances whose encoded back overflows');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[5].Price,
    'overflowing first-match distance must preserve the existing extra-path target node');
  Assert.AreEqual(UInt32(0), Nodes[5].PathLen,
    'overflowing first-match distance must leave extra path length unset');
  Assert.AreEqual(UInt32(0), Nodes[5].PathBack,
    'overflowing first-match distance must leave first-match back unset');
end;

procedure TLzma2NativeTests.OptimumMatchLiteralRep0CandidateRejectsZeroFirstMatchDistance;
var
  AlignProbs: TLzmaAlignProbs;
  CandidatePrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  Nodes: array[0..5] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RaisedMessage: string;
  Relaxed: Boolean;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  RaisedMessage := '';
  Relaxed := True;
  try
    Relaxed := LzmaOptimumRelaxMatchLiteralRep0Candidate(Nodes, 0, ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 1, 0, Ord('C'), False, 0,
      2, 0, 2, CandidatePrice);
  except
    on E: Exception do
      RaisedMessage := E.ClassName + ': ' + E.Message;
  end;

  Assert.AreEqual('', RaisedMessage,
    'match + literal + rep0 relax must reject zero first-match distance without raising from price tables');
  Assert.IsFalse(Relaxed,
    'zero first-match distance must not relax the SDK extra path');
  Assert.AreEqual(UInt32(1) shl 30, Nodes[5].Price,
    'zero first-match distance must preserve the existing extra-path target node');
  Assert.AreEqual(UInt32(0), Nodes[5].PathLen,
    'zero first-match distance must leave extra path length unset');
  Assert.AreEqual(UInt32(0), Nodes[5].PathBack,
    'zero first-match distance must leave first-match back unset');
end;

procedure TLzma2NativeTests.OptimumRelaxCandidatesRejectUnreachablePreviousNode;
var
  AlignProbs: TLzmaAlignProbs;
  CandidatePrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  Matches: TLzmaMatchBuffer;
  NodesExtra: array[0..5] of TLzmaOptimumNode;
  NodesMatch: array[0..2] of TLzmaOptimumNode;
  NodesOne: array[0..1] of TLzmaOptimumNode;
  NodesRep: array[0..2] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLens: array[0..3] of UInt32;

  procedure MarkUnreachable(var Nodes: array of TLzmaOptimumNode);
  var
    NodeIndex: Integer;
  begin
    FillChar(Nodes[0], Length(Nodes) * SizeOf(TLzmaOptimumNode), 0);
    for NodeIndex := Low(Nodes) to High(Nodes) do
      Nodes[NodeIndex].Price := High(UInt32);
  end;

begin
  LzmaInitProbPrices(ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs, AlignProbs,
    ProbPrices);

  MarkUnreachable(NodesOne);
  Assert.IsFalse(
    LzmaOptimumRelaxLiteralCandidate(NodesOne, 0, ProbPrices, LiteralProbs,
      LZMA_PROB_INIT, Ord('A'), False, 0, CandidatePrice),
    'literal relaxation must not wrap an unreachable previous node into a cheap path');
  Assert.AreEqual(High(UInt32), NodesOne[1].Price, 'unreachable literal target price');

  MarkUnreachable(NodesOne);
  Assert.IsFalse(
    LzmaOptimumRelaxShortRepCandidate(NodesOne, 0, ProbPrices, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, CandidatePrice),
    'short-rep relaxation must not wrap an unreachable previous node into a cheap path');
  Assert.AreEqual(High(UInt32), NodesOne[1].Price, 'unreachable short-rep target price');

  Matches.Clear;
  Matches.Add(2, 1);
  MarkUnreachable(NodesMatch);
  Assert.IsFalse(
    LzmaOptimumRelaxMatchCandidates(NodesMatch, 0, Matches, ProbPrices,
      LenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2,
      CandidatePrice),
    'normal match relaxation must not wrap an unreachable previous node into a cheap path');
  Assert.AreEqual(High(UInt32), NodesMatch[2].Price, 'unreachable match target price');

  for I := Low(RepLens) to High(RepLens) do
    RepLens[I] := 0;
  RepLens[1] := 2;
  MarkUnreachable(NodesRep);
  Assert.IsFalse(
    LzmaOptimumRelaxRepCandidates(NodesRep, 0, RepLens, ProbPrices,
      RepLenPriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, CandidatePrice),
    'rep relaxation must not wrap an unreachable previous node into a cheap path');
  Assert.AreEqual(High(UInt32), NodesRep[2].Price, 'unreachable rep target price');

  MarkUnreachable(NodesExtra);
  Assert.IsFalse(
    LzmaOptimumRelaxMatchLiteralRep0Candidate(NodesExtra, 0, ProbPrices,
      LiteralProbs, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 3, Ord('C'), False, 0, 2, 1,
      2, CandidatePrice),
    'match + literal + rep0 relaxation must not wrap an unreachable previous node');
  Assert.AreEqual(High(UInt32), NodesExtra[5].Price, 'unreachable SDK extra target price');
end;

procedure TLzma2NativeTests.OptimumRelaxCandidatesCarryStateAndRepsAcrossParserNodes;
var
  AlignProbs: TLzmaAlignProbs;
  BestRelaxedPrice: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  Matches: TLzmaMatchBuffer;
  Nodes: array[0..4] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLens: array[0..3] of UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[0].State := 0;
  Nodes[0].Reps[0] := 4;
  Nodes[0].Reps[1] := 8;
  Nodes[0].Reps[2] := 16;
  Nodes[0].Reps[3] := 32;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := UInt32(1) shl 30;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  Matches.Clear;
  Matches.Add(2, 11);
  Assert.IsTrue(
    LzmaOptimumRelaxMatchCandidates(Nodes, 0, Matches, ProbPrices, LenPriceEnc,
      DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, 0, 2, 2,
      BestRelaxedPrice),
    'normal-match relax must carry parser context into the target node');
  Assert.AreEqual(UInt32(7), Nodes[2].State, 'match-next state');
  Assert.AreEqual(UInt32(11), Nodes[2].Reps[0], 'normal match becomes rep0');
  Assert.AreEqual(UInt32(4), Nodes[2].Reps[1], 'previous rep0 shifts to rep1');
  Assert.AreEqual(UInt32(8), Nodes[2].Reps[2], 'previous rep1 shifts to rep2');
  Assert.AreEqual(UInt32(16), Nodes[2].Reps[3], 'previous rep2 shifts to rep3');

  FillChar(RepLens, SizeOf(RepLens), 0);
  RepLens[0] := 2;
  Assert.IsTrue(
    LzmaOptimumRelaxRepCandidates(Nodes, 2, RepLens, ProbPrices, RepLenPriceEnc,
      LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
      LZMA_PROB_INIT, LZMA_PROB_INIT, 0, BestRelaxedPrice),
    'rep relax must continue from the target node parser context');
  Assert.AreEqual(UInt32(11), Nodes[4].State, 'rep-next state after a match state');
  Assert.AreEqual(UInt32(11), Nodes[4].Reps[0], 'rep0 remains the active distance');
  Assert.AreEqual(UInt32(4), Nodes[4].Reps[1], 'rep1 remains available');
  Assert.AreEqual(UInt32(8), Nodes[4].Reps[2], 'rep2 remains available');
  Assert.AreEqual(UInt32(16), Nodes[4].Reps[3], 'rep3 remains available');
end;

procedure TLzma2NativeTests.OptimumWindowReplaysCheaperTwoStepPathOverDirectMatch;
var
  AlignProbs: TLzmaAlignProbs;
  Back: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  Len: UInt32;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchesByPos: array[0..4] of TLzmaMatchBuffer;
  Nodes: array[0..4] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..4] of UInt32;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLensByPos: array[0..4] of TLzmaOptimumRepLens;
  StartReps: array[0..3] of UInt32;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 1;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(RepLensByPos, SizeOf(RepLensByPos), 0);
  FillChar(PosStates, SizeOf(PosStates), 0);

  MatchesByPos[0].Add(2, 1);
  MatchesByPos[0].Add(4, UInt32(1) shl 20);
  RepLensByPos[2][0] := 2;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, RepLensByPos,
    PosStates, ProbPrices, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
    LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, LZMA_PROB_INIT),
    'bounded optimum window must relax across reachable parser nodes');
  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 4, Len, Back),
    'bounded optimum window path must replay the first command');
  Assert.AreEqual(UInt32(2), Len, 'first command length');
  Assert.AreEqual(UInt32(1 + 3), Back, 'first command normal-match back');
  Assert.AreEqual(UInt32(0), Nodes[4].BackPrev, 'final command is rep0 from the reached node');
end;

procedure TLzma2NativeTests.OptimumWindowRelaxesLiteralThenMatchPath;
var
  AlignProbs: TLzmaAlignProbs;
  Back: UInt32;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  Len: UInt32;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralInputsByPos: array[0..3] of TLzmaOptimumLiteralInput;
  MatchesByPos: array[0..3] of TLzmaMatchBuffer;
  Nodes: array[0..3] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..3] of UInt32;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLensByPos: array[0..3] of TLzmaOptimumRepLens;
  StartReps: array[0..3] of UInt32;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(RepLensByPos, SizeOf(RepLensByPos), 0);
  FillChar(PosStates, SizeOf(PosStates), 0);
  FillChar(LiteralInputsByPos, SizeOf(LiteralInputsByPos), 0);

  LzmaInitLiteralProbs(LiteralInputsByPos[0].LiteralProbs);
  LiteralInputsByPos[0].Enabled := True;
  LiteralInputsByPos[0].Value := Ord('A');
  LiteralInputsByPos[0].UseMatchedLiteral := False;

  MatchesByPos[0].Add(3, UInt32(1) shl 20);
  MatchesByPos[1].Add(2, 1);

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, RepLensByPos,
    PosStates, LiteralInputsByPos, ProbPrices, LenPriceEnc, RepLenPriceEnc,
    DistancePriceEnc, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT),
    'bounded optimum window must relax literal transitions before later matches');
  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 3, Len, Back),
    'literal-then-match window path must replay the first command');
  Assert.AreEqual(UInt32(1), Len, 'first command length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back, 'first command is the leading literal');
  Assert.AreEqual(UInt32(1), Nodes[3].PosPrev, 'final command starts after the literal node');
  Assert.AreEqual(UInt32(1 + 3), Nodes[3].BackPrev, 'final command is the cheap match from pos1');
end;

procedure TLzma2NativeTests.OptimumWindowUsesReachedNodeStateForLaterProbabilityInputs;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  ExpectedRepPrice: UInt32;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralInputsByPos: array[0..4] of TLzmaOptimumLiteralInput;
  MatchesByPos: array[0..4] of TLzmaMatchBuffer;
  Nodes: array[0..4] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..4] of UInt32;
  ProbInputsByPos: array[0..4] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLensByPos: array[0..4] of TLzmaOptimumRepLens;
  StartReps: array[0..3] of UInt32;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 1;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(RepLensByPos, SizeOf(RepLensByPos), 0);
  FillChar(PosStates, SizeOf(PosStates), 0);
  FillChar(LiteralInputsByPos, SizeOf(LiteralInputsByPos), 0);

  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  ProbInputsByPos[2][7].IsMatchProb := 321;
  ProbInputsByPos[2][7].IsRepProb := 777;
  ProbInputsByPos[2][7].IsRepG0Prob := 1234;
  ProbInputsByPos[2][7].IsRep0LongProb := 1555;

  MatchesByPos[0].Add(2, 1);
  RepLensByPos[2][0] := 2;
  PosStates[2] := 2;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, RepLensByPos,
    PosStates, LiteralInputsByPos, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'bounded optimum window must use state-indexed probability inputs');
  Assert.AreEqual(UInt32(7), Nodes[2].State,
    'normal match from the start state must reach match state 7');

  ExpectedRepPrice := Nodes[2].Price +
    LzmaRepMatchPrefixPrice(ProbPrices, ProbInputsByPos[2][7].IsMatchProb,
      ProbInputsByPos[2][7].IsRepProb) +
    LzmaRep0LongPrice(ProbPrices, ProbInputsByPos[2][7].IsRepG0Prob,
      ProbInputsByPos[2][7].IsRep0LongProb) +
    LzmaLenPrice(RepLenPriceEnc, PosStates[2], 2);

  Assert.AreEqual(ExpectedRepPrice, Nodes[4].Price,
    'rep after a reached match node must use probability inputs for the reached state');
end;

procedure TLzma2NativeTests.OptimumWindowResolvesRepLensFromReachedNodeReps;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  MatchesByPos: array[0..4] of TLzmaMatchBuffer;
  Nodes: array[0..4] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..4] of UInt32;
  ProbInputsByPos: array[0..4] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  ReachedRepResolved: Boolean;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolver: TLzmaOptimumRepLensResolver;
  RootRepSeenAtReachedPos: Boolean;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 1;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  MatchesByPos[0].Add(2, 3);
  ReachedRepResolved := False;
  RootRepSeenAtReachedPos := False;
  LiteralResolver := nil;
  RepResolver :=
    procedure(const WindowPos: UInt32; const Reps: TLzmaOptimumReps;
      out RepLens: TLzmaOptimumRepLens)
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      if WindowPos <> 2 then
        Exit;
      if Reps[0] = StartReps[0] then
        RootRepSeenAtReachedPos := True;
      if Reps[0] = 3 then
      begin
        ReachedRepResolved := True;
        RepLens[0] := 2;
      end;
    end;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'bounded optimum window must resolve rep lengths from each reached node');
  Assert.IsTrue(ReachedRepResolved,
    'later rep candidate must be resolved from the match-updated rep0');
  Assert.IsFalse(RootRepSeenAtReachedPos,
    'later rep candidate must not reuse root reps after a normal match');
  Assert.AreEqual(UInt32(2), Nodes[4].PosPrev,
    'final rep must start at the reached match node');
  Assert.AreEqual(UInt32(0), Nodes[4].BackPrev,
    'final command must be rep0 from the reached node');
end;

procedure TLzma2NativeTests.OptimumWindowResolvesLiteralFromReachedNodeContext;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  MatchedLiteralContextSeen: Boolean;
  MatchesByPos: array[0..3] of TLzmaMatchBuffer;
  Nodes: array[0..3] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..3] of UInt32;
  ProbInputsByPos: array[0..3] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolver: TLzmaOptimumRepLensResolver;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 9;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  MatchesByPos[0].Add(2, 1);
  RepResolver := nil;
  MatchedLiteralContextSeen := False;
  LiteralResolver :=
    function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
      out LiteralInput: TLzmaOptimumLiteralInput): Boolean
    begin
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      Result := WindowPos = 2;
      if not Result then
        Exit;

      MatchedLiteralContextSeen :=
        (Node.State >= 7) and (Node.Reps[0] = 1);
      LiteralInput.Enabled := True;
      LiteralInput.LiteralProbs := LiteralProbs;
      LiteralInput.Value := Ord('A');
      LiteralInput.UseMatchedLiteral := MatchedLiteralContextSeen;
      LiteralInput.MatchByte := Ord('B');
    end;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'bounded optimum window must resolve literals from each reached node');
  Assert.IsTrue(MatchedLiteralContextSeen,
    'literal after a reached match must use match-state and updated rep0 context');
  Assert.AreEqual(UInt32(2), Nodes[3].PosPrev,
    'final literal must start at the reached match node');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Nodes[3].BackPrev,
    'final command must be a literal relaxed from the reached node');
end;

procedure TLzma2NativeTests.OptimumWindowRelaxesShortRepFromResolvedRepLens;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  MatchesByPos: array[0..1] of TLzmaMatchBuffer;
  Nodes: array[0..1] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..1] of UInt32;
  ProbInputsByPos: array[0..1] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolver: TLzmaOptimumRepLensResolver;
  ShortRepResolved: Boolean;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 1;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  LiteralResolver := nil;
  ShortRepResolved := False;
  RepResolver :=
    procedure(const WindowPos: UInt32; const Reps: TLzmaOptimumReps;
      out RepLens: TLzmaOptimumRepLens)
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      if (WindowPos = 0) and (Reps[0] = 1) then
      begin
        ShortRepResolved := True;
        RepLens[0] := 1;
      end;
    end;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'bounded optimum window must relax short-rep candidates from resolved rep lengths');
  Assert.IsTrue(ShortRepResolved, 'test must exercise the resolved short-rep input');
  Assert.AreEqual(UInt32(1), Nodes[1].PathLen, 'short rep is a one-byte command');
  Assert.AreEqual(UInt32(0), Nodes[1].BackPrev, 'short rep must encode as rep0');
end;

procedure TLzma2NativeTests.OptimumWindowRejectsShortRepOutsideLiteralState;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  MatchesByPos: array[0..1] of TLzmaMatchBuffer;
  Nodes: array[0..1] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..1] of UInt32;
  ProbInputsByPos: array[0..1] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolver: TLzmaOptimumRepLensResolver;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 1;
  LzmaOptimumPrepareNodes(Nodes, 0, 7, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  LiteralResolver := nil;
  RepResolver :=
    procedure(const WindowPos: UInt32; const Reps: TLzmaOptimumReps;
      out RepLens: TLzmaOptimumRepLens)
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      if (WindowPos = 0) and (Reps[0] = 1) then
        RepLens[0] := 1;
    end;

  Assert.IsFalse(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'SDK GetOptimum must not relax short-rep outside literal states');
  Assert.AreEqual(High(UInt32), Nodes[1].Price,
    'non-literal state must leave the one-byte node unreachable without a literal');
end;

procedure TLzma2NativeTests.OptimumWindowRelaxesLiteralRep0ExtraPath;
var
  AlignProbs: TLzmaAlignProbs;
  DecisionCount: UInt32;
  Decisions: array[0..1] of TLzmaOptimumDecision;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralResolvedFromStartNode: Boolean;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  MatchesByPos: array[0..5] of TLzmaMatchBuffer;
  Nodes: array[0..5] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..5] of UInt32;
  ProbInputsByPos: array[0..5] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolvedFromSyntheticLiteral: Boolean;
  RepResolver: TLzmaOptimumRepLensResolver;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 5;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);
  Nodes[1].Price := LzmaBitPrice(ProbPrices, LZMA_PROB_INIT, 0);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  LiteralResolvedFromStartNode := False;
  RepResolvedFromSyntheticLiteral := False;
  LiteralResolver :=
    function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
      out LiteralInput: TLzmaOptimumLiteralInput): Boolean
    begin
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      Result := WindowPos = 0;
      if not Result then
        Exit;

      LiteralResolvedFromStartNode := (Node.State = 0) and (Node.Reps[0] = 5);
      LiteralInput.Enabled := True;
      LiteralInput.LiteralProbs := LiteralProbs;
      LiteralInput.Value := Ord('L');
      LiteralInput.UseMatchedLiteral := False;
      LiteralInput.MatchByte := 0;
    end;
  RepResolver :=
    procedure(const WindowPos: UInt32; const Reps: TLzmaOptimumReps;
      out RepLens: TLzmaOptimumRepLens)
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      if (WindowPos = 1) and (Reps[0] = 5) then
      begin
        RepResolvedFromSyntheticLiteral := True;
        RepLens[0] := 4;
      end;
    end;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'bounded optimum window must relax SDK literal + rep0 extra paths');
  Assert.IsTrue(LiteralResolvedFromStartNode,
    'literal + rep0 extra path must resolve the literal from the current node');
  Assert.IsTrue(RepResolvedFromSyntheticLiteral,
    'literal + rep0 extra path must resolve rep0 from the synthetic literal node');
  Assert.AreEqual(UInt32(1), Nodes[5].Extra, 'literal prefix metadata');
  Assert.AreEqual(UInt32(4), Nodes[5].PathLen, 'final rep0 length metadata');
  Assert.AreEqual(UInt32(0), Nodes[5].PathBack, 'final rep0 back metadata');

  Assert.IsTrue(LzmaOptimumReplayPath(Nodes, 5, Decisions, DecisionCount),
    'literal + rep0 extra path must replay into concrete SDK optimum decisions');
  Assert.AreEqual(UInt32(2), DecisionCount, 'literal + rep0 decision count');
  Assert.AreEqual(UInt32(1), Decisions[0].Len, 'first extra-path literal length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Decisions[0].Back,
    'first extra-path literal back');
  Assert.AreEqual(UInt32(4), Decisions[1].Len, 'final extra-path rep0 length');
  Assert.AreEqual(UInt32(0), Decisions[1].Back, 'final extra-path rep0 back');
end;

procedure TLzma2NativeTests.OptimumWindowSuppressesLiteralRep0WhenLiteralIsPricedOut;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  MatchesByPos: array[0..5] of TLzmaMatchBuffer;
  Nodes: array[0..5] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..5] of UInt32;
  ProbInputsByPos: array[0..5] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolver: TLzmaOptimumRepLensResolver;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 5;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);
  Nodes[1].Price := 0;

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  LiteralResolver :=
    function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
      out LiteralInput: TLzmaOptimumLiteralInput): Boolean
    begin
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      Result := WindowPos = 0;
      if not Result then
        Exit;

      LiteralInput.Enabled := True;
      LiteralInput.LiteralProbs := LiteralProbs;
      LiteralInput.Value := Ord('L');
      LiteralInput.UseMatchedLiteral := False;
      LiteralInput.MatchByte := 0;
    end;
  RepResolver :=
    procedure(const WindowPos: UInt32; const Reps: TLzmaOptimumReps;
      out RepLens: TLzmaOptimumRepLens)
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      if (WindowPos = 1) and (Reps[0] = 5) then
        RepLens[0] := 4;
    end;

  Assert.IsFalse(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'SDK GetOptimum suppresses LIT:REP0 when the current literal price is zeroed');
  Assert.AreEqual(High(UInt32), Nodes[5].Price,
    'literal + rep0 extra path must stay unreachable when the literal was priced out');
end;

procedure TLzma2NativeTests.OptimumWindowRelaxesMatchLiteralRep0ExtraPath;
var
  AlignProbs: TLzmaAlignProbs;
  DecisionCount: UInt32;
  Decisions: array[0..2] of TLzmaOptimumDecision;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  LiteralResolvedFromMatchNode: Boolean;
  MatchesByPos: array[0..7] of TLzmaMatchBuffer;
  Nodes: array[0..7] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..7] of UInt32;
  ProbInputsByPos: array[0..7] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolvedFromLiteralNode: Boolean;
  RepResolver: TLzmaOptimumRepLensResolver;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 5;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  MatchesByPos[0].Add(2, 11);
  LiteralResolvedFromMatchNode := False;
  RepResolvedFromLiteralNode := False;
  LiteralResolver :=
    function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
      out LiteralInput: TLzmaOptimumLiteralInput): Boolean
    begin
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      Result := WindowPos = 2;
      if not Result then
        Exit;

      LiteralResolvedFromMatchNode := (Node.State = 7) and (Node.Reps[0] = 11);
      LiteralInput.Enabled := True;
      LiteralInput.LiteralProbs := LiteralProbs;
      LiteralInput.Value := Ord('Z');
      LiteralInput.UseMatchedLiteral := False;
      LiteralInput.MatchByte := 0;
    end;
  RepResolver :=
    procedure(const WindowPos: UInt32; const Reps: TLzmaOptimumReps;
      out RepLens: TLzmaOptimumRepLens)
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      if (WindowPos = 3) and (Reps[0] = 11) then
      begin
        RepResolvedFromLiteralNode := True;
        RepLens[0] := 4;
      end;
    end;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'bounded optimum window must relax SDK match + literal + rep0 extra paths');
  Assert.IsTrue(LiteralResolvedFromMatchNode,
    'extra path literal must be resolved from the synthetic match node');
  Assert.IsTrue(RepResolvedFromLiteralNode,
    'extra path rep0 length must be resolved from the synthetic literal node');
  Assert.AreEqual(UInt32(3), Nodes[7].Extra, 'match + literal prefix length metadata');
  Assert.AreEqual(UInt32(4), Nodes[7].PathLen, 'final rep0 length metadata');
  Assert.AreEqual(UInt32(14), Nodes[7].PathBack, 'first match back metadata');
  Assert.AreEqual(UInt32(0), Nodes[7].BackPrev, 'final command must be rep0');

  Assert.IsTrue(LzmaOptimumReplayPath(Nodes, 7, Decisions, DecisionCount),
    'extra path must replay into concrete SDK optimum decisions');
  Assert.AreEqual(UInt32(3), DecisionCount, 'match + literal + rep0 decision count');
  Assert.AreEqual(UInt32(2), Decisions[0].Len, 'first extra-path match length');
  Assert.AreEqual(UInt32(14), Decisions[0].Back, 'first extra-path match back');
  Assert.AreEqual(UInt32(1), Decisions[1].Len, 'middle extra-path literal length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Decisions[1].Back, 'middle extra-path literal back');
  Assert.AreEqual(UInt32(4), Decisions[2].Len, 'final extra-path rep0 length');
  Assert.AreEqual(UInt32(0), Decisions[2].Back, 'final extra-path rep0 back');
end;

procedure TLzma2NativeTests.OptimumWindowRelaxesRepLiteralRep0ExtraPath;
var
  AlignProbs: TLzmaAlignProbs;
  DecisionCount: UInt32;
  Decisions: array[0..2] of TLzmaOptimumDecision;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  I: Integer;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  LiteralProbs: TLzmaLiteralProbs;
  LiteralResolver: TLzmaOptimumLiteralResolver;
  LiteralResolvedFromRepNode: Boolean;
  MatchesByPos: array[0..7] of TLzmaMatchBuffer;
  Nodes: array[0..7] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..7] of UInt32;
  ProbInputsByPos: array[0..7] of TLzmaOptimumStateProbInputs;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepResolvedFromLiteralNode: Boolean;
  RepResolver: TLzmaOptimumRepLensResolver;
  StartReps: TLzmaOptimumReps;
  StateIndex: Integer;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 17;
  StartReps[1] := 11;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);
  LzmaInitLiteralProbs(LiteralProbs);

  for I := Low(MatchesByPos) to High(MatchesByPos) do
    MatchesByPos[I].Clear;
  FillChar(PosStates, SizeOf(PosStates), 0);
  for I := Low(ProbInputsByPos) to High(ProbInputsByPos) do
    for StateIndex := Low(ProbInputsByPos[I]) to High(ProbInputsByPos[I]) do
    begin
      ProbInputsByPos[I][StateIndex].IsMatchProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepProb := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG0Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG1Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRepG2Prob := LZMA_PROB_INIT;
      ProbInputsByPos[I][StateIndex].IsRep0LongProb := LZMA_PROB_INIT;
    end;

  LiteralResolvedFromRepNode := False;
  RepResolvedFromLiteralNode := False;
  LiteralResolver :=
    function(const WindowPos: UInt32; const Node: TLzmaOptimumNode;
      out LiteralInput: TLzmaOptimumLiteralInput): Boolean
    begin
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      Result := WindowPos = 2;
      if not Result then
        Exit;

      LiteralResolvedFromRepNode := (Node.State = 8) and (Node.Reps[0] = 11) and
        (Node.Reps[1] = 17);
      LiteralInput.Enabled := True;
      LiteralInput.LiteralProbs := LiteralProbs;
      LiteralInput.Value := Ord('Q');
      LiteralInput.UseMatchedLiteral := False;
      LiteralInput.MatchByte := 0;
    end;
  RepResolver :=
    procedure(const WindowPos: UInt32; const Reps: TLzmaOptimumReps;
      out RepLens: TLzmaOptimumRepLens)
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      if WindowPos = 0 then
        RepLens[1] := 2
      else if (WindowPos = 3) and (Reps[0] = 11) then
      begin
        RepResolvedFromLiteralNode := True;
        RepLens[0] := 4;
      end;
    end;

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, PosStates,
    LiteralResolver, RepResolver, ProbInputsByPos, ProbPrices, LenPriceEnc,
    RepLenPriceEnc, DistancePriceEnc),
    'bounded optimum window must relax SDK rep + literal + rep0 extra paths');
  Assert.IsTrue(LiteralResolvedFromRepNode,
    'rep extra path literal must be resolved from the synthetic rep node');
  Assert.IsTrue(RepResolvedFromLiteralNode,
    'rep extra path rep0 length must be resolved from the synthetic literal node');
  Assert.AreEqual(UInt32(3), Nodes[7].Extra, 'rep + literal prefix length metadata');
  Assert.AreEqual(UInt32(4), Nodes[7].PathLen, 'final rep0 length metadata');
  Assert.AreEqual(UInt32(1), Nodes[7].PathBack, 'first rep back metadata');
  Assert.AreEqual(UInt32(0), Nodes[7].BackPrev, 'final command must be rep0');

  Assert.IsTrue(LzmaOptimumReplayPath(Nodes, 7, Decisions, DecisionCount),
    'rep extra path must replay into concrete SDK optimum decisions');
  Assert.AreEqual(UInt32(3), DecisionCount, 'rep + literal + rep0 decision count');
  Assert.AreEqual(UInt32(2), Decisions[0].Len, 'first extra-path rep length');
  Assert.AreEqual(UInt32(1), Decisions[0].Back, 'first extra-path rep back');
  Assert.AreEqual(UInt32(1), Decisions[1].Len, 'middle extra-path literal length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Decisions[1].Back, 'middle extra-path literal back');
  Assert.AreEqual(UInt32(4), Decisions[2].Len, 'final extra-path rep0 length');
  Assert.AreEqual(UInt32(0), Decisions[2].Back, 'final extra-path rep0 back');
end;

procedure TLzma2NativeTests.OptimumWindowSelectsExtendedReplayTargetWhenItBeatsBaseline;
var
  I: Integer;
  Nodes: array[0..6] of TLzmaOptimumNode;
  TargetEnd: UInt32;
  TargetPrice: UInt32;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  for I := Low(Nodes) to High(Nodes) do
    Nodes[I].Price := High(UInt32);
  Nodes[0].Price := 0;
  Nodes[2].Price := 120;
  Nodes[5].Price := 80;

  Assert.IsTrue(LzmaOptimumSelectWindowTarget(Nodes, 2, 5, 90, TargetEnd,
    TargetPrice),
    'bounded optimum target selection must consider relaxed endpoints beyond the current main match');
  Assert.AreEqual(UInt32(5), TargetEnd, 'extended replay target');
  Assert.AreEqual(UInt32(80), TargetPrice, 'extended replay target price');

  Assert.IsFalse(LzmaOptimumSelectWindowTarget(Nodes, 2, 5, 80, TargetEnd,
    TargetPrice),
    'target selection must not choose an endpoint that does not beat the baseline');
  Assert.IsFalse(LzmaOptimumSelectWindowTarget(Nodes, 6, 5, 90, TargetEnd,
    TargetPrice), 'invalid target range must be rejected');
end;

procedure TLzma2NativeTests.OptimumWindowPrunesNormalMatchesCoveredByRep0Length;
var
  AlignProbs: TLzmaAlignProbs;
  DistancePriceEnc: TLzmaDistancePriceEncoder;
  LenHigh: TLzmaLenHighProbs;
  LenLow: TLzmaLenLowProbs;
  LenPriceEnc: TLzmaLenPriceEncoder;
  MatchesByPos: array[0..0] of TLzmaMatchBuffer;
  Nodes: array[0..4] of TLzmaOptimumNode;
  PosDecoderProbs: TLzmaPosDecoderProbs;
  PosSlotProbs: TLzmaPosSlotProbs;
  PosStates: array[0..0] of UInt32;
  ProbPrices: TLzmaProbPrices;
  RepLenHigh: TLzmaLenHighProbs;
  RepLenLow: TLzmaLenLowProbs;
  RepLenPriceEnc: TLzmaLenPriceEncoder;
  RepLensByPos: array[0..0] of TLzmaOptimumRepLens;
  StartReps: TLzmaOptimumReps;
begin
  FillChar(StartReps, SizeOf(StartReps), 0);
  StartReps[0] := 9;
  LzmaOptimumPrepareNodes(Nodes, 0, 0, StartReps);

  LzmaInitProbPrices(ProbPrices);
  LzmaInitLenProbs(LenLow, LenHigh);
  LzmaInitLenProbs(RepLenLow, RepLenHigh);
  LzmaInitLenPriceEncoder(LenPriceEnc, 32);
  LzmaInitLenPriceEncoder(RepLenPriceEnc, 32);
  LzmaUpdateLenPriceEncoder(LenPriceEnc, LenLow, LenHigh, 4, ProbPrices);
  LzmaUpdateLenPriceEncoder(RepLenPriceEnc, RepLenLow, RepLenHigh, 4, ProbPrices);
  LzmaInitDistanceProbs(PosSlotProbs, PosDecoderProbs, AlignProbs);
  LzmaInitDistancePriceEncoder(DistancePriceEnc, UInt64(1) shl 20);
  LzmaUpdateDistancePriceEncoder(DistancePriceEnc, PosSlotProbs, PosDecoderProbs,
    AlignProbs, ProbPrices);
  RepLenPriceEnc.Prices[0][2] := 100000;
  LenPriceEnc.Prices[0][2] := 0;

  MatchesByPos[0].Clear;
  MatchesByPos[0].Add(4, 11);
  FillChar(RepLensByPos, SizeOf(RepLensByPos), 0);
  RepLensByPos[0][0] := 4;
  FillChar(PosStates, SizeOf(PosStates), 0);

  Assert.IsTrue(LzmaOptimumRelaxWindow(Nodes, MatchesByPos, RepLensByPos,
    PosStates, ProbPrices, LenPriceEnc, RepLenPriceEnc, DistancePriceEnc,
    LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT, LZMA_PROB_INIT,
    LZMA_PROB_INIT, LZMA_PROB_INIT),
    'window relax must process the rep0 candidate');
  Assert.AreEqual(UInt32(0), Nodes[4].PathBack,
    'SDK startLen pruning must not let normal matches overwrite lengths covered by rep0');
end;

procedure TLzma2NativeTests.EncoderPathWiresMatchLiteralRep0ThroughOptimumRelaxPrimitive;
var
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('LzmaOptimumRelaxMatchLiteralRep0Candidate', Source) > 0,
    'encoder path must route match + literal + rep0 decisions through the SDK optimum relax primitive');
  Assert.IsTrue(Pos('LzmaOptimumReplayFirstDecision', Source) > 0,
    'encoder path must replay the relaxed optimum node instead of only shortening MainMatch');
  Assert.IsTrue(Pos('CurrentMatchPrice := LzmaNormalMatchPrefixPrice', Source) = 0,
    'encoder path must price the current match baseline through the normal-match relax primitive');
end;

procedure TLzma2NativeTests.EncoderPathWiresShortRepLiteralThroughOptimumRelaxPrimitive;
var
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('LzmaOptimumRelaxLiteralCandidate', Source) > 0,
    'encoder path must seed the literal candidate through the optimum relax primitive');
  Assert.IsTrue(Pos('LzmaOptimumRelaxShortRepCandidate', Source) > 0,
    'encoder path must route short-rep-vs-literal decisions through the optimum relax primitive');
  Assert.IsTrue(Pos('LzmaOptimumReplayFirstDecision', Source) > 0,
    'encoder path must replay the relaxed short-rep/literal optimum node');
end;

procedure TLzma2NativeTests.EncoderPathWiresRepMatchThroughOptimumRelaxPrimitive;
var
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('LzmaOptimumRelaxRepCandidates', Source) > 0,
    'encoder path must seed repeated-distance candidates through the optimum relax primitive');
  Assert.IsTrue(Pos('LzmaOptimumRelaxMatchCandidates', Source) > 0,
    'encoder path must seed normal match candidates through the optimum relax primitive');
  Assert.IsTrue(Pos('LzmaOptimumPrefersRepOverMatch', Source) = 0,
    'encoder path must not bypass node relaxation with the old rep-vs-match comparison helper');
end;

procedure TLzma2NativeTests.EncoderPathDoesNotBypassRepMatchWithFastHeuristic;
var
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('LzmaFastParserPrefersRepOverMain(', Source) = 0,
    'encoder path must not bypass price-table optimum relax/replay with the fast rep-over-main heuristic');
end;

procedure TLzma2NativeTests.EncoderPathWiresLiteralLookaheadThroughOptimumRelaxPrimitive;
var
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('LzmaOptimumPrefersLiteralThenMatchOverMatch', Source) = 0,
    'encoder path must not bypass node relaxation with the old literal-then-match comparison helper');
  Assert.IsTrue(Pos('LzmaOptimumPrefersLiteralThenRepOverMatch', Source) = 0,
    'encoder path must not bypass node relaxation with the old literal-then-rep comparison helper');
  Assert.IsTrue(Pos('NextMatch.Length >= MainMatch.Length', Source) = 0,
    'encoder path must not choose literal lookahead from length/distance-only next-match heuristics');
  Assert.IsTrue(Pos('LookaheadRepLen >= MainMatch.Length - 1', Source) = 0,
    'encoder path must not choose literal lookahead from length-only next-rep heuristics');
  Assert.IsTrue(Pos('LzmaOptimumReplayFirstDecision', Source) > 0,
    'encoder path must replay the relaxed literal-lookahead optimum node');
end;

procedure TLzma2NativeTests.ArtifactValidatorRequiresReleasePerformanceRatioEvidence;
var
  NegativeTests: string;
  Validator: string;
begin
  Validator := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\validate-artifacts.ps1'),
    TEncoding.UTF8);
  NegativeTests := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\test-validate-artifacts.ps1'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('usable SDK-comparable compression ratio and throughput', Validator) > 0,
    'release artifact validator must require compression ratio and throughput evidence');
  Assert.IsTrue(Pos('1.001', Validator) > 0,
    'release artifact validator must enforce the TZ compressed-size gate of SDK * 1.001');
  Assert.IsTrue(Pos('release encode ratio missing', NegativeTests) > 0,
    'validator negative tests must cover missing release ratio evidence');
  Assert.IsTrue(Pos('release encode ratio too weak', NegativeTests) > 0,
    'validator negative tests must cover weak release ratio evidence');
end;

procedure TLzma2NativeTests.ArtifactValidatorRequiresEncodeTuningDiagnosticsEvidence;
var
  NegativeTests: string;
  Validator: string;
begin
  Validator := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\validate-artifacts.ps1'),
    TEncoding.UTF8);
  NegativeTests := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\test-validate-artifacts.ps1'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('fastBytes', Validator) > 0,
    'artifact validator must require Delphi encode fastBytes diagnostics');
  Assert.IsTrue(Pos('niceLen', Validator) > 0,
    'artifact validator must require Delphi encode niceLen diagnostics');
  Assert.IsTrue(Pos('cutValue', Validator) > 0,
    'artifact validator must require Delphi encode cutValue diagnostics');
  Assert.IsTrue(Pos('xzBlockSize', Validator) > 0,
    'artifact validator must require Delphi encode xzBlockSize diagnostics');
  Assert.IsTrue(Pos('copyFastPathCount', Validator) > 0,
    'artifact validator must require Delphi encode copy fast-path diagnostics');
  Assert.IsTrue(Pos('incompressibleFastPathCount', Validator) > 0,
    'artifact validator must require Delphi encode incompressible fast-path diagnostics');
  Assert.IsTrue(Pos('only report OptimumParserEnabled=True for active sdk-profile parser rows', Validator) > 0,
    'artifact validator must reject optimum-parser diagnostics outside active SDK-profile rows');
  Assert.IsTrue(Pos('encodeBlockCount -le 0', Validator) > 0,
    'artifact validator must reject optimum-parser diagnostics without encoded LZMA blocks');
  Assert.IsTrue(Pos('fullOptimumDecisionCount -le 0', Validator) > 0,
    'artifact validator must reject optimum-parser diagnostics without real full optimum decision evidence');
  Assert.IsTrue(Pos('encode tuning and fast-path diagnostics', NegativeTests) > 0,
    'validator negative tests must cover missing encode tuning diagnostics');
  Assert.IsTrue(Pos('inconsistent optimum parser enabled flag', NegativeTests) > 0,
    'validator negative tests must cover inconsistent optimum-parser diagnostics');
  Assert.IsTrue(Pos('optimum parser enabled without encoded blocks', NegativeTests) > 0,
    'validator negative tests must cover optimum-parser diagnostics without encoded LZMA blocks');
end;

procedure TLzma2NativeTests.DocsAndOptimizationPlanDescribeActiveNativeEncoder;
var
  MemoryDoc: string;
  OptionsDoc: string;
  PerformanceScript: string;
begin
  OptionsDoc := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'docs\options.md'),
    TEncoding.UTF8);
  MemoryDoc := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'docs\memory.md'),
    TEncoding.UTF8);
  PerformanceScript := TFile.ReadAllText(TPath.Combine(GetCurrentDir,
    'tests\run-performance.ps1'), TEncoding.UTF8);

  Assert.IsTrue(Pos('native SDK-profile encoder', OptionsDoc) > 0,
    'options docs must describe the active native SDK-profile encoder path');
  Assert.IsTrue(Pos('full-optimum parser branch', OptionsDoc) > 0,
    'options docs must describe the active full-optimum parser branch');
  Assert.IsTrue(Pos('Full optimum-parser coverage remains an optimization area', OptionsDoc) = 0,
    'options docs must not describe the active full-optimum branch as missing work');
  Assert.IsTrue(Pos('The greedy encoder is deterministic', OptionsDoc) = 0,
    'options docs must not describe the active SDK-profile encoder as greedy-only');
  Assert.IsTrue(Pos('native SDK-profile LZMA chunks', MemoryDoc) > 0,
    'memory docs must describe compressed chunks as native SDK-profile LZMA chunks');
  Assert.IsTrue(Pos('Replace the current simple match finder', PerformanceScript) = 0,
    'optimization plan template must not ask to replace an already-active simple match finder');
  Assert.IsTrue(Pos('Tune the active HC5/BT4 match-finder paths', PerformanceScript) > 0,
    'optimization plan template must refer to tuning the active HC5/BT4 paths');
  Assert.IsTrue(Pos('Port SDK price tables and optimum parser', PerformanceScript) = 0,
    'optimization plan template must not ask to port already-active parser scaffolding from scratch');
end;

procedure TLzma2NativeTests.FastLzma2StyleBenchmarkContractIsDocumented;
var
  Cli: string;
begin
  Cli := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tools\Lzma2.dpr'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('Lzma2 benchmark <input-file> [switches]', Cli) > 0,
    'CLI help must document the in-memory fast-lzma2-style benchmark command');
  Assert.IsTrue(Pos('Benchmark CSV:', Cli) > 0,
    'benchmark command must print machine-readable CSV output');
  Assert.IsTrue(Pos('compressionMBps', Cli) > 0,
    'benchmark CSV must expose compression MB/s for data-only benchmark analysis');
  Assert.IsTrue(Pos('decompressionMBps', Cli) > 0,
    'benchmark CSV must expose decompression MB/s for parity with fast-lzma2 bench.c');
  Assert.IsTrue(Pos('ratio=inputBytes/compressedBytes', Cli) > 0,
    'benchmark command must document the same ratio direction as fast-lzma2 bench.c');
end;

procedure TLzma2NativeTests.PerformanceRunnerWritesDataOnlyBenchmarkArtifacts;
var
  NegativeTests: string;
  Performance: string;
  Validator: string;
begin
  Performance := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\run-performance.ps1'),
    TEncoding.UTF8);
  Validator := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\validate-artifacts.ps1'),
    TEncoding.UTF8);
  NegativeTests := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\test-validate-artifacts.ps1'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('lzma2-benchmark.samples.csv', Performance) > 0,
    'performance runner must write raw benchmark sample rows');
  Assert.IsTrue(Pos('lzma2-benchmark.summary.json', Performance) > 0,
    'performance runner must write a machine-readable benchmark summary');
  Assert.IsTrue(Pos('optimization-plan.md', Performance) > 0,
    'performance runner must keep the optimization plan diagnostic artifact');
  Assert.IsTrue(Pos('artifacts/ci/optimization-plan.md', Performance) > 0,
    'performance runner must write the markdown optimization plan outside artifacts/perf');
  Assert.IsTrue(Pos('artifacts/perf/optimization-plan.md', Performance) = 0,
    'performance runner must not put markdown diagnostics in the data-only perf artifact bundle');
  Assert.IsTrue(Pos('Write-BenchmarkSummary', Performance) > 0,
    'performance runner must summarize benchmark metadata and row/sample counts');
  Assert.IsTrue(Pos('elapsedSamplesMs', Performance) > 0,
    'benchmark rows must carry elapsed sample values');
  Assert.IsTrue(Pos('throughputSamplesMiBs', Performance) > 0,
    'benchmark rows must carry throughput sample values');
  Assert.IsTrue(Pos('numHashBytes', Performance) > 0,
    'benchmark rows must carry match-finder hash-byte diagnostics');
  Assert.IsTrue(Pos('Invoke-DelphiInMemoryGraphBenchmark', Performance) = 0,
    'performance runner must not call the old in-memory graph generator');
  Assert.IsTrue(Pos('Invoke-SevenZipGraphBenchmark', Performance) = 0,
    'performance runner must not run the old graph-only 7-Zip comparison');
  Assert.IsTrue(Pos('Write-GraphSvg', Performance) = 0,
    'performance runner must not render SVG graph artifacts');
  Assert.IsTrue(Pos('Write-GraphPng', Performance) = 0,
    'performance runner must not render PNG graph artifacts');
  Assert.IsTrue(Pos('GraphCorpus', Performance) = 0,
    'performance runner must not expose graph corpus parameters');
  Assert.IsTrue(Pos('GraphStartLevel', Performance) = 0,
    'performance runner must not expose graph level parameters');
  Assert.IsTrue((Pos('lzma2-delphi-graph.csv', Performance) = 0) and
    (Pos('lzma2-delphi-graph.json', Performance) = 0) and
    (Pos('lzma2-delphi-graph.png', Performance) = 0) and
    (Pos('lzma2-delphi-graph.svg', Performance) = 0) and
    (Pos('lzma2-delphi-graph-prompt.md', Performance) = 0),
    'performance runner must not write lzma2-delphi-graph artifacts');
  Assert.IsTrue(Pos('lzma2-benchmark.samples.csv', Validator) > 0,
    'artifact validator must require the raw sample CSV');
  Assert.IsTrue(Pos('lzma2-benchmark.summary.json', Validator) > 0,
    'artifact validator must require the benchmark summary JSON');
  Assert.IsTrue(Pos('numHashBytes', Validator) > 0,
    'artifact validator must require match-finder hash-byte diagnostics');
  Assert.IsTrue(Pos('missing benchmark samples CSV artifact', NegativeTests) > 0,
    'validator negative tests must cover missing sample evidence');
  Assert.IsTrue(Pos('missing benchmark summary JSON artifact', NegativeTests) > 0,
    'validator negative tests must cover missing summary evidence');
end;

procedure TLzma2NativeTests.PerformanceValidatorEnforcesDataOnlyArtifacts;
var
  NegativeTests: string;
  Validator: string;
begin
  NegativeTests := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\test-validate-artifacts.ps1'),
    TEncoding.UTF8);
  Validator := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\validate-artifacts.ps1'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('ForbiddenGraphArtifactPatterns', Validator) > 0,
    'artifact validator must explicitly forbid graph artifacts in release evidence');
  Assert.IsTrue(Pos('CI manifest must not include graph artifact record', Validator) > 0,
    'artifact validator must reject stale graph records in the CI manifest');
  Assert.IsTrue(Pos('Validation must not leave graph artifacts in artifacts/perf', Validator) > 0,
    'validation must reject generated graph files left under artifacts/perf in every mode');
  Assert.IsTrue(Pos('Require-GraphBenchmarkContract', Validator) = 0,
    'artifact validator must not enforce old graph row coverage');
  Assert.IsTrue(Pos('Graph benchmark PNG', Validator) = 0,
    'artifact validator must not validate PNG graph evidence');
  Assert.IsTrue(Pos('Graph benchmark SVG', Validator) = 0,
    'artifact validator must not validate SVG graph evidence');
  Assert.IsTrue(Pos('fast-lzma2-style chart', Validator) = 0,
    'artifact validator must not validate chart styling');
  Assert.IsTrue(Pos('CI manifest still contains graph artifact record', NegativeTests) > 0,
    'validator negative tests must cover stale graph records in the manifest');
  Assert.IsTrue(Pos('quick validation rejects leftover graph artifact file', NegativeTests) > 0,
    'validator negative tests must cover leftover graph artifacts outside release mode');
  Assert.IsTrue(Pos('graph png wrong dimensions', NegativeTests) = 0,
    'validator negative tests must not keep PNG graph cases');
  Assert.IsTrue(Pos('graph svg missing fast-lzma2 style contract', NegativeTests) = 0,
    'validator negative tests must not keep SVG graph cases');
end;

procedure TLzma2NativeTests.PerformanceSummaryRequiresBenchmarkMetadata;
var
  NegativeTests: string;
  Performance: string;
  Validator: string;
begin
  Performance := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\run-performance.ps1'),
    TEncoding.UTF8);
  Validator := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\validate-artifacts.ps1'),
    TEncoding.UTF8);
  NegativeTests := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\test-validate-artifacts.ps1'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('benchmark = ''lzma2-data-only''', Performance) > 0,
    'performance runner summary must identify the data-only benchmark schema');
  Assert.IsTrue(Pos('Performance summary JSON must include benchmark metadata', Validator) > 0,
    'artifact validator must require reproducible benchmark metadata');
  Assert.IsTrue(Pos('gitCommit', Performance) > 0,
    'performance runner summary must record the git commit SHA');
  Assert.IsTrue(Pos('gitBranch', Performance) > 0,
    'performance runner summary must record the git branch');
  Assert.IsTrue(Pos('gitRef', Performance) > 0,
    'performance runner summary must record the git ref');
  Assert.IsTrue(Pos('gitCommit', Validator) > 0,
    'artifact validator must require benchmark git commit metadata');
  Assert.IsTrue(Pos('summary JSON missing git metadata', NegativeTests) > 0,
    'validator negative tests must cover missing benchmark git metadata');
  Assert.IsTrue(Pos('Performance summary row count must match benchmark JSON rows', Validator) > 0,
    'artifact validator must cross-check summary and benchmark JSON row counts');
  Assert.IsTrue(Pos('Performance summary sample count must match benchmark samples CSV rows', Validator) > 0,
    'artifact validator must cross-check summary and raw sample row counts');
  Assert.IsTrue(Pos('summary JSON row-count mismatch', NegativeTests) > 0,
    'validator negative tests must cover summary/JSON row-count drift');
  Assert.IsTrue(Pos('summary JSON missing benchmark metadata', NegativeTests) > 0,
    'validator negative tests must cover missing benchmark metadata');
  Assert.IsTrue(Pos('release graph corpus', NegativeTests) = 0,
    'validator negative tests must not keep release graph corpus cases');
end;

procedure TLzma2NativeTests.CliAndVclUseAcceptanceRatioConvention;
var
  Cli: string;
  Vcl: string;
begin
  Cli := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tools\Lzma2.dpr'),
    TEncoding.UTF8);
  Vcl := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tools\Lzma2GUIMain.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('Ratio (input/output): ', Cli) > 0,
    'CLI stats must name the TZ ratio convention');
  Assert.IsTrue(Pos('InSize / OutSize', Cli) > 0,
    'CLI stats must compute ratio as inputBytes/outputBytes');
  Assert.IsTrue(Pos('Ratio (input/output): %.3f', Vcl) > 0,
    'VCL stats must name the TZ ratio convention');
  Assert.IsTrue(Pos('FInputSize / FOutputStream.Size', Vcl) > 0,
    'VCL stats must compute ratio as inputBytes/outputBytes');
end;

procedure TLzma2NativeTests.VclToolShowsMtDiagnosticsAndUsesTemporaryOutput;
var
  Vcl: string;
begin
  Vcl := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tools\Lzma2GUIMain.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('FTempOutputPath', Vcl) > 0,
    'VCL tool must write to a temporary file before replacing the final output');
  Assert.IsTrue(Pos('FinalizeOutputFile', Vcl) > 0,
    'VCL tool must finalize the temporary file only after successful completion');
  Assert.IsTrue(Pos('CleanupOutputFile', Vcl) > 0,
    'VCL tool must delete temporary output on cancel/error');
  Assert.IsTrue(Pos('Decode requested threads', Vcl) > 0,
    'VCL status must expose requested decode thread count');
  Assert.IsTrue(Pos('Decode actual threads', Vcl) > 0,
    'VCL status must expose actual decode worker count');
  Assert.IsTrue(Pos('Decode used MT', Vcl) > 0,
    'VCL status must expose whether MT decode was actually used');
  Assert.IsTrue(Pos('Decode fallback', Vcl) > 0,
    'VCL status must expose decode fallback reason');
end;

procedure TLzma2NativeTests.VclGuiSupportsPublicInstallerLanguageBaseline;
const
  ExpectedLanguages: array[0..23] of string = (
    'glEnglish',
    'glRussian',
    'glFrench',
    'glFinnish',
    'glItalian',
    'glGerman',
    'glSpanish',
    'glCzech',
    'glBrazilian',
    'glPolish',
    'glKorean',
    'glChineseSimplified',
    'glJapanese',
    'glTurkish',
    'glDanish',
    'glDutch',
    'glHungarian',
    'glNorwegian',
    'glPortuguese',
    'glSwedish',
    'glRomanian',
    'glBulgarian',
    'glGreek',
    'glUkrainian');
var
  Language: string;
  Vcl: string;
begin
  Vcl := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tools\Lzma2GUIMain.pas'),
    TEncoding.UTF8);

  for Language in ExpectedLanguages do
    Assert.IsTrue(Pos(Language, Vcl) > 0,
      Format('VCL GUI must support the public installer baseline language %s', [Language]));
  Assert.IsTrue(Pos('GuiLanguageFromLangId', Vcl) > 0,
    'VCL GUI language detection must be separated from direct Windows API lookup');
  Assert.IsTrue(Pos('TranslateEnglishText', Vcl) > 0,
    'VCL GUI must keep translations in one fallback table keyed by English source text');
end;

procedure TLzma2NativeTests.CiBuildsIndependentMsBuildProjectsInParallel;
var
  RunCi: string;
begin
  RunCi := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\run-ci.ps1'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('[int]$BuildParallelism', RunCi) > 0,
    'CI runner must expose build parallelism for local and CI resource usage');
  Assert.IsTrue(Pos('Invoke-CompilerCheckedParallel', RunCi) > 0,
    'CI runner must build independent MSBuild configurations concurrently');
  Assert.IsTrue(Pos('Start-Job', RunCi) > 0,
    'parallel build helper must use extra processes on Windows PowerShell runners');
  Assert.IsTrue(Pos('BRCC_OutputDir', RunCi) > 0,
    'parallel MSBuild jobs must isolate Delphi version-resource temporary files');
end;

procedure TLzma2NativeTests.GitHubWorkflowRunsReleaseCiMode;
var
  Workflow: string;
begin
  Workflow := TFile.ReadAllText(TPath.Combine(GetCurrentDir,
    '.github\workflows\windows-delphi.yml'), TEncoding.UTF8);

  Assert.IsTrue(Pos('run-ci.ps1 -Mode release', Workflow) > 0,
    'GitHub workflow must generate release evidence with run-ci.ps1 -Mode release');
  Assert.IsTrue(Pos('-RequireExternalTools $true', Workflow) > 0,
    'release workflow must require external SDK/xz tools');
  Assert.IsTrue(Pos('-ReleasePerformance $true', Workflow) > 0,
    'release workflow must run the release performance corpus explicitly');
  Assert.IsTrue(Pos('release_performance', Workflow) = 0,
    'release workflow must not expose a decorative release-performance toggle');
end;

procedure TLzma2NativeTests.DUnitXCategoryTiersAreDeclaredAndQuickFiltered;
var
  RunCi: string;
  Tests: string;
  RequiredCategory: string;
begin
  Tests := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\Lzma.Tests.dpr'),
    TEncoding.UTF8);
  RunCi := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\run-ci.ps1'),
    TEncoding.UTF8);

  for RequiredCategory in TArray<string>.Create('unit', 'container', 'compat',
    'perf-smoke', 'perf-release', 'soak', 'fuzz') do
    Assert.IsTrue(Pos(Format('[Category(''%s'')]', [RequiredCategory]), Tests) > 0,
      Format('DUnitX category must be declared: %s', [RequiredCategory]));

  Assert.IsTrue(Pos('TDUnitX.CheckCommandLine', Tests) > 0,
    'DUnitX runner must honor command-line category filters');
  Assert.IsTrue(Pos('--include:', RunCi) > 0,
    'CI runner must pass DUnitX include category filters');
  Assert.IsTrue(Pos('--exclude:', RunCi) > 0,
    'CI runner must pass DUnitX exclude category filters');
  Assert.IsTrue(Pos('dunitxCategoryArgs', RunCi) > 0,
    'CI manifest must preserve the executed DUnitX category filters');
  Assert.IsTrue(Pos('$dunitxArgs = @(Get-DUnitXCategoryArgs $Mode)', RunCi) > 0,
    'release/soak single DUnitX category filters must stay array-splatted');
  Assert.IsTrue(Pos('perf-release,soak,fuzz', RunCi) > 0,
    'quick mode must exclude release, soak and fuzz categories by default');
end;

procedure TLzma2NativeTests.FixtureGenerationUsesContentAddressedCacheEvidence;
var
  GenerateFixtures: string;
  GitIgnore: string;
  NegativeTests: string;
  RunCi: string;
  Validator: string;
begin
  GenerateFixtures := TFile.ReadAllText(TPath.Combine(GetCurrentDir,
    'tests\generate-fixtures.ps1'), TEncoding.UTF8);
  RunCi := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\run-ci.ps1'),
    TEncoding.UTF8);
  Validator := TFile.ReadAllText(TPath.Combine(GetCurrentDir,
    'tests\validate-artifacts.ps1'), TEncoding.UTF8);
  NegativeTests := TFile.ReadAllText(TPath.Combine(GetCurrentDir,
    'tests\test-validate-artifacts.ps1'), TEncoding.UTF8);
  GitIgnore := TFile.ReadAllText(TPath.Combine(GetCurrentDir, '.gitignore'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('tests\fixtures\cache', GenerateFixtures) > 0,
    'fixture generator must keep a persistent cache outside regenerated fixture outputs');
  Assert.IsTrue(Pos('Get-FixtureCacheKey', GenerateFixtures) > 0,
    'fixture generator must key the cache by tool/options/source identity');
  Assert.IsTrue(Pos('cacheKey', GenerateFixtures) > 0,
    'fixture manifests must record cache keys for reproducible release evidence');
  Assert.IsTrue(Pos('Require-RawLzmaFixtureCacheEvidence', Validator) > 0,
    'artifact validator must verify raw LZMA fixture cache evidence');
  Assert.IsTrue(Pos('missing fixture cache evidence', NegativeTests) > 0,
    'validator negative tests must cover missing cache evidence');
  Assert.IsTrue(Pos('/tests/fixtures/cache/', GitIgnore) > 0,
    'persistent fixture cache must remain outside git-tracked sources');
  Assert.IsTrue(Pos('tests\fixtures'') $fixtureSubdir', RunCi) > 0,
    'CI cleanup must stay scoped to generated fixture output subdirectories');
  Assert.IsTrue(Pos('tests\fixtures\cache', RunCi) = 0,
    'quick/release CI cleanup must not erase the content-addressed fixture cache');
end;

procedure TLzma2NativeTests.CliSafeStoredOutputNameRejectsUnsafeStoredNames;
begin
  Assert.AreEqual('safe.bin', SafeStoredOutputName('folder/safe.bin', 'fallback.out'),
    'stored archive paths must collapse to their leaf name');
  Assert.AreEqual('fallback.out', SafeStoredOutputName('..\..\CON. ', 'fallback.out'),
    'reserved Windows device names must fall back to a safe archive-derived name');
  Assert.AreEqual('fallback.out', SafeStoredOutputName('bad|name.txt', 'fallback.out'),
    'invalid Windows filename characters must not reach the extraction target');
  Assert.AreEqual('fallback.out', SafeStoredOutputName('COM1.txt', 'fallback.out'),
    'reserved device names with extensions must be rejected');
  Assert.AreEqual('output.bin', SafeStoredOutputName('..', 'NUL. '),
    'unsafe stored and fallback names must use the final hardcoded safe name');
end;

procedure TLzma2NativeTests.CliSafeStoredRelativePathPreservesOnlySafeArchivePaths;
begin
  Assert.AreEqual(TPath.Combine('dir', 'safe.bin'),
    SafeStoredRelativePath('dir/safe.bin', 'fallback.out', True),
    'safe 7z extraction paths should preserve relative archive directories');
  Assert.AreEqual('safe.bin', SafeStoredRelativePath('dir/safe.bin', 'fallback.out', False),
    'flat extraction should keep only the safe leaf name');
  Assert.AreEqual('fallback.out', SafeStoredRelativePath('..\escape.bin', 'fallback.out', True),
    'relative traversal must fall back to a safe name');
  Assert.AreEqual('fallback.out', SafeStoredRelativePath('C:\escape.bin', 'fallback.out', True),
    'drive-rooted archive paths must fall back to a safe name');
  Assert.AreEqual('fallback.out', SafeStoredRelativePath('dir/CON.txt', 'fallback.out', True),
    'reserved Windows names inside a relative path must be rejected');
end;

procedure TLzma2NativeTests.ReleasePerformanceRequiresSixteenThreadMtEncodeEvidence;
var
  NegativeTests: string;
  Performance: string;
  Validator: string;
begin
  Performance := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\run-performance.ps1'),
    TEncoding.UTF8);
  Validator := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\validate-artifacts.ps1'),
    TEncoding.UTF8);
  NegativeTests := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'tests\test-validate-artifacts.ps1'),
    TEncoding.UTF8);

  Assert.IsTrue((Pos('$releaseThreadMatrix = @(1, 2, 4, 8, 16)', Performance) > 0) and
    (Pos('$releaseThreadMatrix = @($releaseThreadMatrix + $logicalProcessorCount | Sort-Object -Unique)', Performance) > 0) and
    (Pos('foreach ($releaseThreads in $releaseThreadMatrix)', Performance) > 0),
    'release performance runner must emit 16-thread and logical-processor Delphi MT encode rows');
  Assert.IsTrue((Pos('$releaseComparisonThreads = @(2, 4, 8, 16)', Performance) > 0) and
    (Pos('$releaseComparisonThreads = @($releaseComparisonThreads + [Environment]::ProcessorCount | Sort-Object -Unique)', Performance) > 0) and
    (Pos('foreach ($releaseThreads in $releaseComparisonThreads)', Performance) > 0),
    'release performance comparisons must score 16-thread and logical-processor Delphi MT encode rows');
  Assert.IsTrue((Pos('$releaseThreadMatrix = @(1, 2, 4, 8, 16)', Validator) > 0) and
    (Pos('$releaseThreadMatrix = @($releaseThreadMatrix + $summaryLogicalProcessors | Sort-Object -Unique)', Validator) > 0),
    'release artifact validator must require 16-thread and logical-processor Delphi encode evidence');
  Assert.IsTrue(Pos('foreach ($threads in @($releaseThreadMatrix | Where-Object { $_ -ne 1 }))', Validator) > 0,
    'release artifact validator must require release MT comparison evidence');
  Assert.IsTrue(Pos('missing 16-thread release corpus MT row', NegativeTests) > 0,
    'validator negative tests must cover missing 16-thread release MT evidence');
end;

procedure TLzma2NativeTests.EncoderPathSeedsOptimumNodesWithCurrentStateAndReps;
var
  Source: string;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);

  Assert.IsTrue(Pos('LzmaOptimumPrepareNodes(Nodes);', Source) = 0,
    'encoder path must not prepare anonymous optimum nodes without parser state/reps');
  Assert.IsTrue(Pos('LzmaOptimumPrepareNodes(RepNodes);', Source) = 0,
    'encoder path must seed rep optimum nodes with parser state/reps');
  Assert.IsTrue(Pos('LzmaOptimumPrepareNodes(MatchNodes);', Source) = 0,
    'encoder path must seed match optimum nodes with parser state/reps');
  Assert.IsTrue(Pos('LzmaOptimumPrepareNodes(MainNodes);', Source) = 0,
    'encoder path must seed main optimum nodes with parser state/reps');
  Assert.IsTrue(Pos('LzmaOptimumPrepareNodes(Nodes, 0, State, Reps)', Source) > 0,
    'encoder path must pass the live parser state/reps to optimum preparation');
end;

procedure TLzma2NativeTests.OptimumPathReplaysLiteralThenMatchAdditionalOffset;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[1].PosPrev := 0;
  Nodes[1].BackPrev := LZMA_OPTIMUM_BACK_LITERAL;
  Nodes[5].PosPrev := 1;
  Nodes[5].BackPrev := 7 + 3;

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'optimum path replay must accept a literal then additionalOffset match path');
  Assert.AreEqual(UInt32(1), Len, 'first replayed command length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back, 'first replayed command must be literal');
end;

procedure TLzma2NativeTests.OptimumPathReplaysPrev1LiteralAsFirstCommand;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[5].Prev1IsLiteral := True;
  Nodes[5].PosPrev := 1;
  Nodes[5].BackPrev := 0;
  Nodes[5].PosPrev2 := 0;
  Nodes[5].BackPrev2 := LZMA_OPTIMUM_BACK_LITERAL;

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'optimum path replay must accept a folded Prev1IsLiteral path');
  Assert.AreEqual(UInt32(1), Len, 'first replayed folded command length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back,
    'first replayed folded command must be the literal before the rep/match');
end;

procedure TLzma2NativeTests.OptimumReplayPathReturnsMatchLiteralRep0Commands;
var
  DecisionCount: UInt32;
  Decisions: array[0..2] of TLzmaOptimumDecision;
  I: Integer;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := High(UInt32);

  Nodes[5].Price := 10;
  Nodes[5].PathLen := 2;
  Nodes[5].PathBack := 14;
  Nodes[5].Extra := 3;
  Nodes[5].PosPrev := 3;
  Nodes[5].BackPrev := 0;

  Assert.IsTrue(LzmaOptimumReplayPath(Nodes, 5, Decisions, DecisionCount),
    'full optimum replay must expand match + literal + rep0 extra path');
  Assert.AreEqual(UInt32(3), DecisionCount, 'decision count');
  Assert.AreEqual(UInt32(2), Decisions[0].Len, 'first match length');
  Assert.AreEqual(UInt32(14), Decisions[0].Back, 'first match back');
  Assert.AreEqual(UInt32(1), Decisions[1].Len, 'literal length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Decisions[1].Back, 'literal back marker');
  Assert.AreEqual(UInt32(2), Decisions[2].Len, 'rep0 length');
  Assert.AreEqual(UInt32(0), Decisions[2].Back, 'rep0 back marker');
end;

procedure TLzma2NativeTests.OptimumReplayPathReturnsRepLiteralRep0Commands;
var
  DecisionCount: UInt32;
  Decisions: array[0..2] of TLzmaOptimumDecision;
  I: Integer;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := High(UInt32);

  Nodes[5].Price := 10;
  Nodes[5].PathLen := 2;
  Nodes[5].PathBack := 1;
  Nodes[5].Extra := 3;
  Nodes[5].PosPrev := 3;
  Nodes[5].BackPrev := 0;

  Assert.IsTrue(LzmaOptimumReplayPath(Nodes, 5, Decisions, DecisionCount),
    'full optimum replay must expand rep + literal + rep0 extra path');
  Assert.AreEqual(UInt32(3), DecisionCount, 'rep extra decision count');
  Assert.AreEqual(UInt32(2), Decisions[0].Len, 'first rep length');
  Assert.AreEqual(UInt32(1), Decisions[0].Back, 'first rep back');
  Assert.AreEqual(UInt32(1), Decisions[1].Len, 'literal length after rep');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Decisions[1].Back, 'literal after rep back marker');
  Assert.AreEqual(UInt32(2), Decisions[2].Len, 'final rep0 length');
  Assert.AreEqual(UInt32(0), Decisions[2].Back, 'final rep0 back marker');
end;

procedure TLzma2NativeTests.OptimumReplaySdkBackwardExposesOptCurOptEndQueueState;
var
  BackwardState: TLzmaOptimumBackwardState;
  DecisionCount: UInt32;
  Decisions: array[0..2] of TLzmaOptimumDecision;
  I: Integer;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  for I := 1 to High(Nodes) do
    Nodes[I].Price := High(UInt32);

  Nodes[5].Price := 10;
  Nodes[5].PathLen := 2;
  Nodes[5].PathBack := 1;
  Nodes[5].Extra := 3;
  Nodes[5].PosPrev := 3;
  Nodes[5].BackPrev := 0;

  Assert.IsTrue(LzmaOptimumReplaySdkBackward(Nodes, 5, Decisions,
    DecisionCount, BackwardState),
    'SDK backward replay must expose optCur/optEnd queue state');
  Assert.AreEqual(UInt32(3), DecisionCount, 'SDK backward decision count');
  Assert.AreEqual(UInt32(6), BackwardState.OptEnd, 'SDK optEnd is end position + 1');
  Assert.AreEqual(UInt32(4), BackwardState.OptCur,
    'SDK optCur points at the first queued command after the returned decision');
  Assert.AreEqual(UInt32(2), BackwardState.QueueCount, 'queued command count');
  Assert.AreEqual(UInt32(2), Decisions[0].Len, 'returned rep length');
  Assert.AreEqual(UInt32(1), Decisions[0].Back, 'returned rep back');
  Assert.AreEqual(UInt32(1), Decisions[1].Len, 'queued literal length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Decisions[1].Back, 'queued literal back');
  Assert.AreEqual(UInt32(2), Decisions[2].Len, 'queued rep0 length');
  Assert.AreEqual(UInt32(0), Decisions[2].Back, 'queued rep0 back');
end;

procedure TLzma2NativeTests.OptimumPathReplaysSdk26ExtraBranches;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..7] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[5].PathLen := 4;
  Nodes[5].PathBack := 9 + 3;
  Nodes[5].Extra := 1;

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'SDK 26 extra=1 path must replay the leading literal');
  Assert.AreEqual(UInt32(1), Len, 'SDK 26 LIT:MATCH first command length');
  Assert.AreEqual(LZMA_OPTIMUM_BACK_LITERAL, Back, 'SDK 26 LIT:MATCH first command back');

  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[7].PathLen := 3;
  Nodes[7].PathBack := 11 + 3;
  Nodes[7].Extra := 4;

  Assert.IsTrue(LzmaOptimumReplayFirstDecision(Nodes, 7, Len, Back),
    'SDK 26 extra>1 path must replay the leading match');
  Assert.AreEqual(UInt32(3), Len, 'SDK 26 MATCH:LIT:REP0 first command length');
  Assert.AreEqual(UInt32(11 + 3), Back, 'SDK 26 MATCH:LIT:REP0 first command back');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsUnreachableEndNode;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[2].Price := High(UInt32);
  Nodes[2].PathLen := 2;
  Nodes[2].PathBack := 9 + 3;
  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 2, Len, Back),
    'path replay must reject an unreachable priced end node');

  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[5].Price := High(UInt32);
  Nodes[5].Prev1IsLiteral := True;
  Nodes[5].PosPrev := 1;
  Nodes[5].BackPrev := 0;
  Nodes[5].PosPrev2 := 0;
  Nodes[5].BackPrev2 := LZMA_OPTIMUM_BACK_LITERAL;
  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'Prev1 replay must reject an unreachable priced end node');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsUnreachableIntermediateNode;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..4] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[2].Price := High(UInt32);
  Nodes[2].PosPrev := 0;
  Nodes[2].BackPrev := 5 + 3;
  Nodes[4].Price := 10;
  Nodes[4].PosPrev := 2;
  Nodes[4].BackPrev := 9 + 3;
  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 4, Len, Back),
    'replay must reject a predecessor chain through an unreachable priced node');

  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[2].Price := High(UInt32);
  Nodes[2].PathLen := 2;
  Nodes[2].PathBack := 5 + 3;
  Nodes[4].Price := 10;
  Nodes[4].PathLen := 2;
  Nodes[4].PathBack := 9 + 3;
  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 4, Len, Back),
    'path-len replay must reject an unreachable priced intermediate node');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsUnreachablePrev1LiteralNode;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[1].Price := High(UInt32);
  Nodes[5].Price := 10;
  Nodes[5].Prev1IsLiteral := True;
  Nodes[5].PosPrev := 1;
  Nodes[5].BackPrev := 0;
  Nodes[5].PosPrev2 := 0;
  Nodes[5].BackPrev2 := LZMA_OPTIMUM_BACK_LITERAL;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'Prev1 replay must reject an unreachable priced folded literal node');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPrev1LiteralRootNonLiteralBackPrev2;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[5].Price := 10;
  Nodes[5].Prev1IsLiteral := True;
  Nodes[5].PosPrev := 1;
  Nodes[5].BackPrev := 0;
  Nodes[5].PosPrev2 := 0;
  Nodes[5].BackPrev2 := 9 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'Prev1 root replay must reject a non-literal BackPrev2 first command');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPrev1LiteralRootMultiByteLiteralCommand;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[2].Price := 7;
  Nodes[5].Price := 10;
  Nodes[5].Prev1IsLiteral := True;
  Nodes[5].PosPrev := 2;
  Nodes[5].BackPrev := 0;
  Nodes[5].PosPrev2 := 0;
  Nodes[5].BackPrev2 := LZMA_OPTIMUM_BACK_LITERAL;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'Prev1 root replay must reject a folded literal whose length is greater than one');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenMismatchedPosPrev;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..2] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[2].Price := 10;
  Nodes[2].PathLen := 2;
  Nodes[2].PathBack := 9 + 3;
  Nodes[2].PosPrev := 1;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 2, Len, Back),
    'path-len replay must reject a node whose stored predecessor disagrees with PathLen');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenMismatchedBackPrev;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..2] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[2].Price := 10;
  Nodes[2].PathLen := 2;
  Nodes[2].PathBack := 9 + 3;
  Nodes[2].BackPrev := 10 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 2, Len, Back),
    'path-len replay must reject a node whose stored BackPrev disagrees with PathBack');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsExtraPathNonRep0BackPrev;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..7] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[7].Price := 10;
  Nodes[7].PathLen := 3;
  Nodes[7].PathBack := 11 + 3;
  Nodes[7].Extra := 4;
  Nodes[7].PosPrev := 4;
  Nodes[7].BackPrev := 1;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 7, Len, Back),
    'extra replay must reject match-literal-rep paths whose final rep is not rep0');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsExtraPathWithPrev1LiteralFlag;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..7] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[7].Price := 10;
  Nodes[7].PathLen := 3;
  Nodes[7].PathBack := 11 + 3;
  Nodes[7].Extra := 4;
  Nodes[7].PosPrev := 4;
  Nodes[7].BackPrev := 0;
  Nodes[7].Prev1IsLiteral := True;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 7, Len, Back),
    'extra replay must reject nodes that also claim Prev1IsLiteral');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenExtraRep0WithBackPrev2Set;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..7] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[7].Price := 10;
  Nodes[7].PathLen := 3;
  Nodes[7].PathBack := 11 + 3;
  Nodes[7].Extra := 4;
  Nodes[7].PosPrev := 4;
  Nodes[7].BackPrev := 0;
  Nodes[7].BackPrev2 := 9 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 7, Len, Back),
    'extra>1 replay must reject nodes with BackPrev2 metadata set');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenExtraRep0WithPosPrev2Set;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..7] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[7].Price := 10;
  Nodes[7].PathLen := 3;
  Nodes[7].PathBack := 11 + 3;
  Nodes[7].Extra := 4;
  Nodes[7].PosPrev := 4;
  Nodes[7].BackPrev := 0;
  Nodes[7].PosPrev2 := 1;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 7, Len, Back),
    'extra>1 replay must reject nodes with PosPrev2 metadata set');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenExtraOneWithNonLiteralBack;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[5].Price := 10;
  Nodes[5].PathLen := 4;
  Nodes[5].PathBack := 9 + 3;
  Nodes[5].Extra := 1;
  Nodes[5].BackPrev := 9 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'extra=1 replay must reject compact paths whose first command is not literal');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenExtraOneWithBackPrev2Set;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[5].Price := 10;
  Nodes[5].PathLen := 4;
  Nodes[5].PathBack := 9 + 3;
  Nodes[5].Extra := 1;
  Nodes[5].BackPrev2 := 9 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'extra=1 replay must reject compact paths that also carry folded BackPrev2 metadata');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenExtraOneWithPosPrev2Set;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..5] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[5].Price := 10;
  Nodes[5].PathLen := 4;
  Nodes[5].PathBack := 9 + 3;
  Nodes[5].Extra := 1;
  Nodes[5].PosPrev2 := 1;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 5, Len, Back),
    'extra=1 replay must reject nodes with PosPrev2 metadata set');
end;

procedure TLzma2NativeTests.OptimumReplayPathRejectsInvalidCompactExtraMetadata;
var
  BackwardState: TLzmaOptimumBackwardState;
  DecisionCount: UInt32;
  Decisions: array[0..2] of TLzmaOptimumDecision;
  Nodes: array[0..7] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[7].Price := 10;
  Nodes[7].PathLen := 3;
  Nodes[7].PathBack := 11 + 3;
  Nodes[7].Extra := 4;
  Nodes[7].PosPrev := 4;
  Nodes[7].BackPrev := 1;
  Assert.IsFalse(LzmaOptimumReplayPath(Nodes, 7, Decisions, DecisionCount),
    'path replay must reject extra>1 paths whose final rep is not rep0');

  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[7].Price := 10;
  Nodes[7].PathLen := 3;
  Nodes[7].PathBack := 11 + 3;
  Nodes[7].Extra := 4;
  Nodes[7].PosPrev := 4;
  Nodes[7].BackPrev2 := 9 + 3;
  Assert.IsFalse(LzmaOptimumReplayPath(Nodes, 7, Decisions, DecisionCount),
    'path replay must reject extra>1 paths with folded BackPrev2 metadata');

  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[5].Price := 10;
  Nodes[5].PathLen := 4;
  Nodes[5].PathBack := 9 + 3;
  Nodes[5].Extra := 1;
  Nodes[5].BackPrev := 9 + 3;
  Assert.IsFalse(LzmaOptimumReplayPath(Nodes, 5, Decisions, DecisionCount),
    'path replay must reject extra=1 paths whose first command is not literal');
  Assert.IsFalse(LzmaOptimumReplaySdkBackward(Nodes, 5, Decisions,
    DecisionCount, BackwardState),
    'SDK backward replay must reject invalid compact extra metadata');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsMultiByteLiteralRootCommand;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..2] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[2].Price := 10;
  Nodes[2].PosPrev := 0;
  Nodes[2].BackPrev := LZMA_OPTIMUM_BACK_LITERAL;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 2, Len, Back),
    'replay must reject a root literal command whose length is greater than one');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsSingleByteMatchRootCommand;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..1] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[1].Price := 10;
  Nodes[1].PosPrev := 0;
  Nodes[1].BackPrev := 9 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 1, Len, Back),
    'replay must reject a one-byte root command encoded as a normal match');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsIntermediateMultiByteLiteralCommand;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..4] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[2].Price := 10;
  Nodes[2].PosPrev := 0;
  Nodes[2].BackPrev := 1 + 3;
  Nodes[4].Price := 20;
  Nodes[4].PosPrev := 2;
  Nodes[4].BackPrev := LZMA_OPTIMUM_BACK_LITERAL;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 4, Len, Back),
    'replay must reject intermediate multi-byte literal commands');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenMultiByteLiteralCommand;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..2] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[2].Price := 10;
  Nodes[2].PathLen := 2;
  Nodes[2].PathBack := LZMA_OPTIMUM_BACK_LITERAL;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 2, Len, Back),
    'path-len replay must reject literal commands whose length is greater than one');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsPathLenSingleByteMatchCommand;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..1] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := 0;
  Nodes[1].Price := 10;
  Nodes[1].PathLen := 1;
  Nodes[1].PathBack := 9 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 1, Len, Back),
    'path-len replay must reject one-byte normal match commands');
end;

procedure TLzma2NativeTests.OptimumReplayRejectsUnreachableStartNode;
var
  Back: UInt32;
  Len: UInt32;
  Nodes: array[0..2] of TLzmaOptimumNode;
begin
  FillChar(Nodes, SizeOf(Nodes), 0);
  Nodes[0].Price := High(UInt32);
  Nodes[2].Price := 17;
  Nodes[2].PathLen := 2;
  Nodes[2].PathBack := 9 + 3;

  Assert.IsFalse(LzmaOptimumReplayFirstDecision(Nodes, 2, Len, Back),
    'path replay must reject a path whose start node was never seeded');
end;

procedure TLzma2NativeTests.FastParserLookaheadCacheReusesReadMatchesOnce;
var
  Cache: TLzmaFastParserMatchCache;
  Loaded: TLzmaMatchBuffer;
  LoadedMain: TLzmaMatch;
  Main: TLzmaMatch;
  Stored: TLzmaMatchBuffer;
begin
  Cache.Clear;
  Stored.Clear;
  Stored.Add(2, 1);
  Stored.Add(4, 8);
  Main := Stored.Last;

  Assert.IsFalse(Cache.TryTake(3, Loaded, LoadedMain), 'empty cache must miss');

  Cache.Store(4, Stored, Main);
  Assert.IsFalse(Cache.TryTake(3, Loaded, LoadedMain), 'cache must not serve the wrong position');
  Assert.IsTrue(Cache.TryTake(4, Loaded, LoadedMain), 'lookahead match list must be reusable at the next position');
  Assert.AreEqual(2, Loaded.Count, 'cached match pair count');
  Assert.AreEqual(UInt32(2), Loaded.Items[0].Length, 'cached low match length');
  Assert.AreEqual(UInt32(1), Loaded.Items[0].Distance, 'cached low match distance');
  Assert.AreEqual(UInt32(4), LoadedMain.Length, 'cached main match length');
  Assert.AreEqual(UInt32(8), LoadedMain.Distance, 'cached main match distance');
  Assert.IsFalse(Cache.TryTake(4, Loaded, LoadedMain), 'cache entry must be single-use like SDK additionalOffset');
end;

procedure TLzma2NativeTests.FastParserLookaheadCacheKeepsMultipleAdditionalOffsets;
var
  Cache: TLzmaFastParserMatchCache;
  FirstLoaded: TLzmaMatchBuffer;
  FirstMain: TLzmaMatch;
  FirstStored: TLzmaMatchBuffer;
  Loaded: TLzmaMatchBuffer;
  LoadedMain: TLzmaMatch;
  SecondStored: TLzmaMatchBuffer;
begin
  Cache.Clear;

  FirstStored.Clear;
  FirstStored.Add(2, 1);
  FirstStored.Add(3, 7);
  FirstMain := FirstStored.Last;

  SecondStored.Clear;
  SecondStored.Add(2, 2);
  SecondStored.Add(4, 9);

  Cache.Store(4, FirstStored, FirstMain);
  Cache.Store(5, SecondStored, SecondStored.Last);

  Assert.IsTrue(Cache.TryTake(4, FirstLoaded, LoadedMain),
    'first additionalOffset entry must survive later lookahead reads');
  Assert.AreEqual(UInt32(3), LoadedMain.Length, 'pos 4 main len');
  Assert.AreEqual(UInt32(7), LoadedMain.Distance, 'pos 4 main dist');
  Assert.AreEqual(2, FirstLoaded.Count, 'pos 4 match count');

  Assert.IsTrue(Cache.TryTake(5, Loaded, LoadedMain),
    'second additionalOffset entry must remain available');
  Assert.AreEqual(UInt32(4), LoadedMain.Length, 'pos 5 main len');
  Assert.AreEqual(UInt32(9), LoadedMain.Distance, 'pos 5 main dist');
  Assert.AreEqual(2, Loaded.Count, 'pos 5 match count');

  Assert.IsFalse(Cache.TryTake(4, Loaded, LoadedMain), 'pos 4 cache entry must be single-use');
  Assert.IsFalse(Cache.TryTake(5, Loaded, LoadedMain), 'pos 5 cache entry must be single-use');
end;

procedure TLzma2NativeTests.FastParserRepThresholdsUseSdkReducedDistance;
begin
  Assert.IsFalse(LzmaFastParserPrefersRepOverMain(3, 5, UInt32(1) shl 9),
    'actual distance 0x200 is SDK mainDist 0x1FF and stays below the 0x200 threshold');
  Assert.IsTrue(LzmaFastParserPrefersRepOverMain(3, 5, (UInt32(1) shl 9) + 1),
    'actual distance 0x201 is SDK mainDist 0x200 and reaches the 0x200 threshold');

  Assert.IsFalse(LzmaFastParserPrefersRepOverMain(3, 6, UInt32(1) shl 15),
    'actual distance 0x8000 is SDK mainDist 0x7FFF and stays below the 0x8000 threshold');
  Assert.IsTrue(LzmaFastParserPrefersRepOverMain(3, 6, (UInt32(1) shl 15) + 1),
    'actual distance 0x8001 is SDK mainDist 0x8000 and reaches the 0x8000 threshold');
end;

procedure TLzma2NativeTests.RawLzmaPropertiesAlignDictionary;
var
  Props: TLzmaProps;
  Encoded: TBytes;
begin
  Props := TLzmaRawEncoder.DefaultProperties(4097);
  Encoded := TLzmaRawEncoder.WriteProperties(Props);
  Assert.AreEqual(5, Integer(Length(Encoded)), 'LZMA props size');
  Assert.AreEqual(Byte($5D), Encoded[0], 'default LZMA lc/lp/pb byte');
  Assert.AreEqual(UInt32(6144), ReadUi32LE(@Encoded[1]), 'SDK 2/3-grid alignment below 2 MiB');

  Props := TLzmaRawEncoder.DefaultProperties((2 shl 20) + 1);
  Encoded := TLzmaRawEncoder.WriteProperties(Props);
  Assert.AreEqual(UInt32(3 shl 20), ReadUi32LE(@Encoded[1]), 'SDK 1 MiB alignment from 2 MiB');

  Props := TLzmaRawEncoder.DefaultProperties(5 shl 20);
  Encoded := TLzmaRawEncoder.WriteProperties(Props);
  Assert.AreEqual(UInt32(5 shl 20), ReadUi32LE(@Encoded[1]), 'SDK keeps exact 1 MiB multiples above 2 MiB');

  Props := TLzmaRawEncoder.DefaultProperties(UInt64($FFFFFFFF));
  Encoded := TLzmaRawEncoder.WriteProperties(Props);
  Assert.AreEqual(UInt32($FFFFFFFF), ReadUi32LE(@Encoded[1]), 'SDK preserves max dictionary property');
end;

procedure TLzma2NativeTests.RawLzmaAllowsSdkLcLpCombination;
var
  Props: TLzmaProps;
  Data: TBytes;
  EncodedBytes: TBytes;
  PropsBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  OutBytes: TBytes;
begin
  Data := RepeatingBytes(8192);
  Props.Lc := 4;
  Props.Lp := 1;
  Props.Pb := 2;
  Props.DictionarySize := 1 shl 20;

  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 5);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  Src := TBytesStream.Create(EncodedBytes);
  Dst := TMemoryStream.Create;
  try
    TLzmaRawDecoder.Decode(Src, Dst, PropsBytes, Length(Data));
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA lc=4 lp=1');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneEncodeHonorsCustomLcLpPbOptions;
var
  Archive: TBytes;
  Data: TBytes;
  Decoded: TMemoryStream;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  OutBytes: TBytes;
  Src: TBytesStream;
begin
  Data := RepeatingBytes(8192);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.Lc := 4;
  Options.Lp := 1;
  Options.Pb := 2;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue(Length(Archive) > LZMA_PROPS_SIZE,
    'standalone archive must include LZMA props');
  Assert.AreEqual(Byte((2 * 5 + 1) * 9 + 4), Archive[0],
    'standalone .lzma must preserve custom lc/lp/pb props');

  Src := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'standalone custom lc/lp/pb roundtrip');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2CompressedChunkWritesCustomLcLpPbProp;
var
  Control: Byte;
  Data: TBytes;
  Decoded: TMemoryStream;
  Encoded: TBytes;
  Options: TLzma2Options;
  OutBytes: TBytes;
  PackSize: Integer;
  Pos: Integer;
  PropByte: Byte;
  Src: TBytesStream;
begin
  Data := RepeatingBytes(32768);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.Lc := 2;
  Options.Lp := 2;
  Options.Pb := 1;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Pos := 0;
  PropByte := 0;
  while Pos < Length(Encoded) do
  begin
    Control := Encoded[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
      Break;
    Assert.IsTrue(Pos + 2 <= Length(Encoded), 'truncated raw LZMA2 chunk header');
    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      Inc(Pos, ((Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 3);
      Continue;
    end;

    Assert.IsTrue(Control >= $80, 'expected compressed LZMA2 chunk');
    Assert.IsTrue(Pos + 4 <= Length(Encoded), 'truncated compressed LZMA2 header');
    PackSize := ((Integer(Encoded[Pos + 2]) shl 8) or Integer(Encoded[Pos + 3])) + 1;
    Inc(Pos, 4);
    Assert.IsTrue((Control and $40) <> 0, 'first custom-props chunk must carry LZMA props');
    Assert.IsTrue(Pos < Length(Encoded), 'truncated compressed LZMA2 properties');
    PropByte := Encoded[Pos];
    Inc(Pos);
    Assert.IsTrue(Pos + PackSize <= Length(Encoded), 'truncated compressed LZMA2 payload');
    Break;
  end;

  Assert.AreEqual(Byte((1 * 5 + 2) * 9 + 2), PropByte,
    'raw LZMA2 compressed chunk must preserve custom lc/lp/pb props');

  Src := TBytesStream.Create(Encoded);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA2 custom lc/lp/pb roundtrip');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.Lzma2OptionsRejectInvalidLcLpPbCombination;
var
  Options: TLzma2Options;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.Lc := 4;
  Options.Lp := 1;
  Options.Pb := 2;

  Assert.WillRaise(
    procedure
    begin
      TLzma2Encoder.EncodeRawBytes(RepeatingBytes(1024), Options);
    end,
    ELzmaInvalidParameter);
end;

procedure TLzma2NativeTests.RawLzmaChunkEncoderAcceptsHashChain4FinderKind;
var
  Props: TLzmaProps;
  Data: TBytes;
  EncodedBytes: TBytes;
  PropsBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  OutBytes: TBytes;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(48);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCZ');
  PutText(20, 'ABCDEFGH');
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);

  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 1, mfHashChain4);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  Src := TBytesStream.Create(EncodedBytes);
  Dst := TMemoryStream.Create;
  try
    TLzmaRawDecoder.Decode(Src, Dst, PropsBytes, Length(Data));
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA HC4 chunk finder roundtrip');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaChunkEncoderAcceptsBinaryTree4FinderKind;
var
  Props: TLzmaProps;
  Data: TBytes;
  EncodedBytes: TBytes;
  PropsBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  OutBytes: TBytes;

  procedure PutText(const Offset: Integer; const Text: string);
  var
    Bytes: TBytes;
  begin
    Bytes := TEncoding.ASCII.GetBytes(Text);
    Move(Bytes[0], Data[Offset], Length(Bytes));
  end;
begin
  Data := BytesOfSize(48);
  PutText(0, 'ABCDEFGH');
  PutText(10, 'ABCZ');
  PutText(20, 'ABCDEFGH');
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);

  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 1, mfBinaryTree4);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  Src := TBytesStream.Create(EncodedBytes);
  Dst := TMemoryStream.Create;
  try
    TLzmaRawDecoder.Decode(Src, Dst, PropsBytes, Length(Data));
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA BT4-profile chunk finder roundtrip');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaEncoderOptInWindowPathRoundTripsAndWiresDriver;
var
  Data: TBytes;
  Dst: TMemoryStream;
  HelperEnd: Integer;
  HelperSource: string;
  HelperStart: Integer;
  GateSnippet: string;
  GateStart: Integer;
  GreedyBytes: TBytes;
  OutBytes: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Source: string;
  Src: TBytesStream;
  WindowBytes: TBytes;
begin
  Data := TEncoding.ASCII.GetBytes(
    'abcdefghABCDEFGHabcdefghABXDEFGHabcdefghABCDEFGH0123456789abcdefghABCDEFGH');
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);

  GreedyBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props,
    16, 8, mfHashChain4, False);
  WindowBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props,
    16, 8, mfHashChain4, False, True);

  Assert.IsTrue(Length(WindowBytes) > 0, 'opt-in optimum-window encode must emit data');
  Assert.IsTrue(Length(WindowBytes) < Length(Data),
    Format('opt-in bounded optimum-window encode must stay compressed on the smoke corpus: window=%d input=%d greedy=%d',
      [Length(WindowBytes), Length(Data), Length(GreedyBytes)]));

  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  Src := TBytesStream.Create(WindowBytes);
  Dst := TMemoryStream.Create;
  try
    TLzmaRawDecoder.Decode(Src, Dst, PropsBytes, Length(Data));
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA opt-in optimum-window roundtrip');
  finally
    Dst.Free;
    Src.Free;
  end;

  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);
  Assert.IsTrue(Pos('EnableOptimumWindow', Source) > 0,
    'raw encoder must expose an opt-in optimum-window gate');
  Assert.IsTrue(Pos('TryGetOptimumWindowDecision', Source) > 0,
    'raw encoder must route opt-in decisions through a bounded window helper');
  Assert.IsTrue(Pos('LzmaOptimumRelaxWindow', Source) > 0,
    'raw encoder bounded helper must call the shared optimum window driver');
  Assert.IsTrue(Pos('ProbInputsByPos', Source) > 0,
    'raw encoder bounded helper must feed state-indexed probability inputs');
  GateStart := Pos('MainMatch.Length >= EffectiveFastBytes', Source);
  Assert.IsTrue(GateStart > 0, 'raw encoder bounded helper gate must stay visible');
  GateSnippet := Copy(Source, GateStart, 160);
  Assert.IsFalse(Pos('BestRepLen >= TLzmaEncoderConstants.kMatchMinLen', GateSnippet) > 0,
    'raw encoder bounded helper must still run when a long-rep candidate exists');
  HelperStart := Pos('function TryGetOptimumWindowDecision', Source);
  HelperEnd := PosEx('function GetOptimumFast', Source, HelperStart);
  Assert.IsTrue((HelperStart > 0) and (HelperEnd > HelperStart),
    'raw encoder bounded helper source must be isolated for wiring checks');
  HelperSource := Copy(Source, HelperStart, HelperEnd - HelperStart);
  Assert.IsTrue(Pos('RepBaselinePrice', HelperSource) > 0,
    'raw encoder bounded helper must compare window price against the existing rep baseline');
  Assert.IsTrue(Pos('QueueOptimumReplayPath(Nodes, TargetEnd', HelperSource) > 0,
    'raw encoder bounded helper must queue the full relaxed optimum path');
  Assert.IsFalse(Pos('kMaxOptimumWindow = 16', HelperSource) > 0,
    'raw encoder bounded helper must not cap SDK-profile optimum parsing at a fixed 16-byte window');
  Assert.IsTrue(Pos('GetOptimumWindowLimit', Source) > 0,
    'raw encoder bounded helper must derive its parsing window from the active fast-bytes profile');
  Assert.IsFalse(Pos('SetLength(Nodes, Integer(TargetEnd) + 1)', HelperSource) > 0,
    'raw encoder bounded helper must not physically cap the parser window at the current main match');
  Assert.IsTrue(Pos('OptimumReplayQueue', Source) > 0,
    'raw encoder must keep queued optimum-window decisions between encode steps');
  Assert.IsTrue(Pos('TryPopOptimumReplayDecision(Result, Back)', Source) > 0,
    'raw encoder fast path must replay queued optimum-window decisions before recomputing');
  Assert.IsFalse(Pos('LzmaOptimumReplayFirstDecision(Nodes, TargetEnd', HelperSource) > 0,
    'raw encoder bounded helper must not drop all but the first optimum-window decision');
  Assert.IsFalse(Pos('if PreferRepOverMainByPrice(MainMatch) then', HelperSource) > 0,
    'raw encoder bounded helper must not skip pricing a potentially better window path');
end;

procedure TLzma2NativeTests.RawLzmaEncoderOptInWindowUsesEffectiveFastBytesBounds;
var
  Data: TBytes;
  Dst: TMemoryStream;
  EncodedBytes: TBytes;
  HelperEnd: Integer;
  HelperSource: string;
  HelperStart: Integer;
  LimitEnd: Integer;
  LimitSource: string;
  LimitStart: Integer;
  OutBytes: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Source: string;
  Src: TBytesStream;
begin
  Data := TEncoding.ASCII.GetBytes(
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' +
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcxefghijklmnopqrstuvwxyz' +
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz');
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);

  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props,
    64, 32, mfHashChain4, False, True);
  Assert.IsTrue(Length(EncodedBytes) > 0,
    'opt-in optimum-window encode must handle fast bytes above the old 16-byte cap');

  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  Src := TBytesStream.Create(EncodedBytes);
  Dst := TMemoryStream.Create;
  try
    TLzmaRawDecoder.Decode(Src, Dst, PropsBytes, Length(Data));
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA optimum-window fast-bytes>16 roundtrip');
  finally
    Dst.Free;
    Src.Free;
  end;

  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);
  HelperStart := Pos('function TryGetOptimumWindowDecision', Source);
  HelperEnd := PosEx('function GetOptimumFast', Source, HelperStart);
  Assert.IsTrue((HelperStart > 0) and (HelperEnd > HelperStart),
    'raw encoder bounded helper source must be isolated for fast-bytes guard');
  HelperSource := Copy(Source, HelperStart, HelperEnd - HelperStart);

  Assert.IsTrue(Pos('OptimumWindowLimit := GetOptimumWindowLimit', HelperSource) > 0,
    'bounded helper must compute its parse limit from the SDK optimum lookahead bound');
  Assert.IsTrue(Pos('WindowEnd := OptimumWindowLimit', HelperSource) > 0,
    'bounded helper must start from the SDK optimum lookahead bound');
  Assert.IsTrue(Pos('SetLength(Nodes, Integer(WindowEnd) + 1)', HelperSource) > 0,
    'bounded helper must size optimum nodes to the SDK optimum lookahead bound');
  Assert.IsTrue(Pos('SetLength(MatchesByPos, Integer(WindowEnd) + 1)', HelperSource) > 0,
    'bounded helper must size match snapshots to the SDK optimum lookahead bound');
  Assert.IsTrue(Pos('ClampMatchBufferLengths(MatchesByPos[PosIndex], EffectiveFastBytes)',
    HelperSource) > 0,
    'bounded helper must still clamp direct candidate lengths to EffectiveFastBytes');
  LimitStart := Pos('function GetOptimumWindowLimit', Source);
  LimitEnd := PosEx('function TryGetOptimumWindowDecision', Source, LimitStart);
  Assert.IsTrue((LimitStart > 0) and (LimitEnd > LimitStart),
    'raw encoder optimum limit helper source must be isolated');
  LimitSource := Copy(Source, LimitStart, LimitEnd - LimitStart);
  Assert.IsFalse(Pos('Result := EffectiveFastBytes + 1 + EffectiveFastBytes', LimitSource) > 0,
    'SDK-profile full optimum parsing must not be limited to a bounded fast-bytes window');
  Assert.IsTrue(Pos('LZMA_FULL_OPTIMUM_NUM_OPTS', LimitSource) > 0,
    'SDK-profile full optimum parsing must use the SDK optimum node window');
  Assert.IsFalse(Pos('TLzmaEncoderConstants.kMatchMaxLen', LimitSource) > 0,
    'compound optimum lookahead must not be capped to a single match length');
  Assert.IsFalse((Pos('kMaxOptimumWindow = 16', HelperSource) > 0) or
    (Pos('Integer(16)', HelperSource) > 0) or (Pos('Min(16', HelperSource) > 0),
    'bounded helper must not keep a fixed 16-byte cap that can under-size the fast-bytes window');
end;

procedure TLzma2NativeTests.RawLzmaGreedyEncoderRoundTrips;
var
  Profile: TLzmaEncoderProfile;
  Props: TBytes;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Data := BytesOfSize(4096);
  Profile := TLzmaRawEncoder.NormalizeProfile(1, 1 shl 20);
  Props := TLzmaRawEncoder.WriteProperties(TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize));
  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzmaRawEncoder.Encode(Src, Encoded, Profile);
    Encoded.Position := 0;
    TLzmaRawDecoder.Decode(Encoded, Decoded, Props, Length(Data));
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaKnownSizeAboveUInt32ReachesDecoder;
var
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  Decoded: TMemoryStream;
begin
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  Src := TBytesStream.Create(nil);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzmaRawDecoder.Decode(Src, Decoded, PropsBytes, UInt64(High(UInt32)) + 1);
      end,
      ELzmaInputEof);
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaStreamEncoderUsesSinkBackedRangeOutput;
var
  Data: TBytes;
  Decoded: TMemoryStream;
  Encoded: TOutputStartedProbeWriteStream;
  OutBytes: TBytes;
  OutputStarted: Integer;
  Profile: TLzmaEncoderProfile;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Src: TReadBeforeOutputProbeStream;
begin
  Data := HighEntropyBytes((1 shl 20) + 4099);
  Profile := TLzmaRawEncoder.NormalizeProfile(1, 1 shl 20);
  Props := TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  OutputStarted := 0;
  Src := TReadBeforeOutputProbeStream.Create(Data, @OutputStarted);
  Encoded := TOutputStartedProbeWriteStream.Create(@OutputStarted);
  Decoded := TMemoryStream.Create;
  try
    TLzmaRawEncoder.Encode(Src, Encoded, Profile, Props, False, nil);
    Assert.IsTrue(Encoded.Size > 0, 'raw LZMA stream wrapper must emit output');
    Assert.IsTrue(Src.ReadBeforeOutput < UInt64(Length(Data)),
      Format('raw LZMA stream wrapper read all input before first output: read=%d size=%d',
        [Src.ReadBeforeOutput, Length(Data)]));
    Assert.IsTrue(Encoded.MaxWriteCount > 1,
      'raw LZMA sink-backed range output must buffer bytes before writing to the caller stream');

    Encoded.Position := 0;
    TLzmaRawDecoder.Decode(Encoded, Decoded, PropsBytes, Length(Data));
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size <> 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'streamed raw LZMA payload round-trip');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaStreamEncoderUsesProfileMatchFinder;
var
  Source: string;
  StreamEncoderSource: string;
  StreamStart: Integer;
begin
  Source := TFile.ReadAllText(TPath.Combine(GetCurrentDir, 'src\Lzma.Encoder.pas'),
    TEncoding.UTF8);
  Source := StringReplace(Source, #13#10, #10, [rfReplaceAll]);
  Source := StringReplace(Source, #13, #10, [rfReplaceAll]);
  StreamStart := Pos('class procedure TLzmaRawEncoder.Encode(Source: TStream; Destination: TStream; const Profile: TLzmaEncoderProfile;'#10 +
    '  const Props: TLzmaProps; const WriteEndMarker: Boolean; const Progress: TLzma2ProgressEvent);'#10 +
    'const',
    Source);
  Assert.IsTrue(StreamStart > 0, 'raw LZMA stream overload source must be isolated');
  StreamEncoderSource := Copy(Source, StreamStart, MaxInt);

  Assert.IsTrue(Pos('Profile.MatchFinderKind', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must route decisions through the requested profile match finder');
  Assert.IsTrue(Pos('TLzmaHashChain4MatchFinder.Create', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must support HC4 profile match finding');
  Assert.IsTrue(Pos('TLzmaHashChain5MatchFinder.Create', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must support HC5 profile match finding');
  Assert.IsTrue(Pos('TLzmaBinaryTree4MatchFinder.Create', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must support BT4 profile match finding');
  Assert.IsTrue(Pos('Profile.ParserMode <> lpmSdkProfile', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must branch SDK-profile parser requests into optimum-window decisions');
  Assert.IsTrue(Pos('LzmaOptimumRelaxWindow', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must use optimum-window relaxation for SDK-profile parser requests');
  Assert.IsTrue(Pos('LzmaOptimumSelectWindowTarget', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must select a priced SDK-profile target before replay');
  Assert.IsTrue(Pos('LzmaOptimumReplaySdkBackward', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must queue and replay optimum-window decisions');
  Assert.IsTrue(Pos('ReadTempMatchFinderMatchesAt(RelativePos, MatchesByPos[PosIndex])', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must use non-mutating lookahead match reads');
  Assert.IsFalse(Pos('while Distance <= SearchMax do', StreamEncoderSource) > 0,
    'raw LZMA stream encoder must not silently fall back to profile-independent brute-force search');
end;

procedure TLzma2NativeTests.RawLzmaStreamProgressReportsCommittedOutput;
var
  Data: TBytes;
  Encoded: TMemoryStream;
  LastIn: UInt64;
  LastOut: UInt64;
  ProgressCalls: Integer;
  Profile: TLzmaEncoderProfile;
  Props: TLzmaProps;
  Src: TBytesStream;
begin
  Data := HighEntropyBytes((1 shl 20) + 32768);
  Profile := TLzmaRawEncoder.NormalizeProfile(3, 1 shl 20);
  Props := TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize);
  LastIn := 0;
  LastOut := 0;
  ProgressCalls := 0;
  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzmaRawEncoder.Encode(Src, Encoded, Profile, Props, False,
      procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
      begin
        Inc(ProgressCalls);
        Assert.IsTrue(InBytes >= LastIn, 'raw LZMA stream input progress regressed');
        Assert.IsTrue(OutBytes >= LastOut, 'raw LZMA stream output progress regressed');
        Assert.IsTrue(OutBytes <= UInt64(Encoded.Size),
          'raw LZMA stream output progress must report committed destination bytes');
        LastIn := InBytes;
        LastOut := OutBytes;
      end);
    Assert.IsTrue(ProgressCalls > 0, 'raw LZMA stream encoder progress was not reported');
  finally
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaStreamFinalCancellationPrecedesRangeFlush;
var
  Data: TBytes;
  Encoded: TMemoryStream;
  Profile: TLzmaEncoderProfile;
  ProgressCalls: Integer;
  Props: TLzmaProps;
  Src: TBytesStream;
begin
  Data := HighEntropyBytes(4096);
  Profile := TLzmaRawEncoder.NormalizeProfile(3, 1 shl 20);
  Props := TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize);
  ProgressCalls := 0;
  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzmaRawEncoder.Encode(Src, Encoded, Profile, Props, False,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Inc(ProgressCalls);
            Cancel := InBytes >= UInt64(Length(Data));
          end);
      end,
      ELzmaCancelled);
    Assert.IsTrue(ProgressCalls > 0, 'raw LZMA stream final progress was not reported');
    Assert.AreEqual(Int64(0), Encoded.Size,
      'raw LZMA stream final cancellation should happen before the buffered range tail is flushed');
  finally
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaEndMarkerRoundTripsUnknownSize;
var
  Data: TBytes;
  EncodedBytes: TBytes;
  OutBytes: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  Decoded: TMemoryStream;
begin
  Data := RepeatingBytes(32768);
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 32,
    mfHashChain4, True);

  Src := TBytesStream.Create(EncodedBytes);
  Decoded := TMemoryStream.Create;
  try
    TLzmaRawDecoder.DecodeUntilEndMarker(Src, Decoded, PropsBytes);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA end-marker unknown-size roundtrip');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaEndMarkerRejectsDirtyTail;
var
  Data: TBytes;
  EncodedBytes: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  Decoded: TMemoryStream;
begin
  Data := RepeatingBytes(4096);
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 32,
    mfHashChain4, True);
  Assert.IsTrue(Length(EncodedBytes) > 0, 'raw LZMA end-marker fixture must not be empty');
  EncodedBytes[High(EncodedBytes)] := EncodedBytes[High(EncodedBytes)] xor $01;

  Src := TBytesStream.Create(EncodedBytes);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzmaRawDecoder.DecodeUntilEndMarker(Src, Decoded, PropsBytes);
      end,
      ELzmaDataError);
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneRoundTripsKnownSize;
var
  Options: TLzma2Options;
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Archive: TBytes;
  Props: TLzmaProps;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Data := RepeatingBytes(65536);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size > LZMA_PROPS_SIZE + 8, 'standalone .lzma must include header and payload');
    Assert.IsTrue(Diagnostics.OptimumParserEnabled,
      'standalone .lzma diagnostics must report the active native optimum-parser branch');
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);

    Assert.IsTrue(LzmaPropsDecode(Copy(Archive, 0, LZMA_PROPS_SIZE), Props),
      'standalone .lzma properties must be valid raw LZMA props');
    Assert.AreEqual(UInt64(Length(Data)), ReadUi64LE(@Archive[LZMA_PROPS_SIZE]),
      'standalone .lzma must store known unpack size');

    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'standalone .lzma known-size roundtrip');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneEncodeCanWriteUnknownSizeEndMarker;
var
  Options: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
  I: Integer;
begin
  Data := RepeatingBytes(32768);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.LzmaEndMarker := True;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);

    for I := 0 to 7 do
      Assert.AreEqual(Byte($FF), Archive[LZMA_PROPS_SIZE + I],
        'standalone .lzma end-marker encode must write unknown unpack size');

    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'standalone .lzma end-marker encode roundtrip');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneDecodesUnknownSizeEndMarker;
var
  Options: TLzma2Options;
  Data: TBytes;
  EncodedBytes: TBytes;
  Header: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Src: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Data := RepeatingBytes(32768);
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 32,
    mfHashChain4, True);

  SetLength(Header, 0);
  AppendBytes(Header, PropsBytes);
  SetLength(OutBytes, 8);
  FillChar(OutBytes[0], Length(OutBytes), $FF);
  AppendBytes(Header, OutBytes);
  AppendBytes(Header, EncodedBytes);

  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Src := TBytesStream.Create(Header);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'standalone .lzma unknown-size end-marker roundtrip');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneEncodeRejectsInputOverMemoryLimit;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(8192);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.MemoryLimit := Options.DictionarySize + UInt64(Length(Data)) - 1;

  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Compress(Src, Dst, Options);
      end,
      ELzmaMemoryError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneDecodeRejectsPackedInputOverMemoryLimit;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  PackedBytes: UInt64;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(8192);
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcLzma;
  BuildOptions.Level := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, BuildOptions);
    Assert.IsTrue(Encoded.Size > LZMA_PROPS_SIZE + 8, 'standalone .lzma fixture must have payload bytes');
    PackedBytes := UInt64(Encoded.Size) - UInt64(LZMA_PROPS_SIZE + 8);

    DecodeOptions := BuildOptions;
    DecodeOptions.MemoryLimit := DecodeOptions.DictionarySize + PackedBytes - 1;
    Encoded.Position := 0;
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Encoded, Dst, DecodeOptions);
      end,
      ELzmaMemoryError);
  finally
    Dst.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneRejectsShortHeader;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  SetLength(Data, LZMA_PROPS_SIZE + 7);
  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaInputEof);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneRejectsInvalidProps;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  SetLength(Data, LZMA_PROPS_SIZE + 8);
  Data[0] := $FF;
  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneRejectsTrailingBytesAfterEndMarker;
var
  Options: TLzma2Options;
  Data: TBytes;
  EncodedBytes: TBytes;
  Header: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  SizeBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(4096);
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 32,
    mfHashChain4, True);

  SetLength(Header, 0);
  AppendBytes(Header, PropsBytes);
  SetLength(SizeBytes, 8);
  FillChar(SizeBytes[0], Length(SizeBytes), $FF);
  AppendBytes(Header, SizeBytes);
  AppendBytes(Header, EncodedBytes);
  AppendByte(Header, $7A);

  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Src := TBytesStream.Create(Header);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneRejectsKnownSizeTruncation;
var
  Options: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(8192);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size - 1);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Length(Archive));
    Src.Free;
    Src := TBytesStream.Create(Archive);
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaInputEof);
  finally
    Dst.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneRejectsUnpackSizeMismatch;
var
  Options: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(8192);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Dst := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Length(Archive));
    WriteUi64LE(@Archive[LZMA_PROPS_SIZE], UInt64(Length(Data) + 1));
    Src.Free;
    Src := TBytesStream.Create(Archive);
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaInputEof);
  finally
    Dst.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneRejectsUnknownSizeWithoutEndMarker;
var
  Options: TLzma2Options;
  Data: TBytes;
  EncodedBytes: TBytes;
  Header: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  SizeBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(4096);
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 32,
    mfHashChain4, False);

  SetLength(Header, 0);
  AppendBytes(Header, PropsBytes);
  SetLength(SizeBytes, 8);
  FillChar(SizeBytes[0], Length(SizeBytes), $FF);
  AppendBytes(Header, SizeBytes);
  AppendBytes(Header, EncodedBytes);

  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Src := TBytesStream.Create(Header);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaInputEof);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneEncodeCancellation;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  ProgressCalls: Integer;
begin
  Data := RepeatingBytes(4 shl 20);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;
  ProgressCalls := 0;

  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Compress(Src, Dst, Options,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Inc(ProgressCalls);
            Cancel := InBytes >= UInt64(1 shl 20);
          end);
      end,
      ELzmaCancelled);
    Assert.IsTrue(ProgressCalls > 0, 'standalone .lzma encode should report progress before cancellation');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LzmaStandaloneDecodeCancellation;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  ProgressCalls: Integer;
begin
  Data := RepeatingBytes(4 shl 20);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcLzma;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Encoded.Position := 0;
    ProgressCalls := 0;
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Encoded, Decoded, Options,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Inc(ProgressCalls);
            Cancel := OutBytes >= UInt64(1 shl 20);
          end);
      end,
      ELzmaCancelled);
    Assert.IsTrue(ProgressCalls > 0, 'standalone .lzma decode should report progress before cancellation');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzmaEndMarkerInsideLzma2ChunkFails;
var
  Data: TBytes;
  EncodedBytes: TBytes;
  Options: TLzma2Options;
  Props: TLzmaProps;
  Raw: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(4096);
  Props := TLzmaRawEncoder.DefaultProperties(1 shl 20);
  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, 32, 32,
    mfHashChain4, True);

  SetLength(Raw, Length(EncodedBytes) + 7);
  Raw[0] := $E0 or Byte((Length(Data) - 1) shr 16);
  Raw[1] := Byte((Length(Data) - 1) shr 8);
  Raw[2] := Byte(Length(Data) - 1);
  Raw[3] := Byte((Length(EncodedBytes) - 1) shr 8);
  Raw[4] := Byte(Length(EncodedBytes) - 1);
  Raw[5] := Byte((Props.Pb * 5 + Props.Lp) * 9 + Props.Lc);
  if Length(EncodedBytes) > 0 then
    Move(EncodedBytes[0], Raw[6], Length(EncodedBytes));
  Raw[High(Raw)] := LZMA2_CONTROL_EOF;

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.DictionarySize := 1 shl 20;

  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LevelFiveSingleThreadRoundTripsThroughProfileFinder;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(200000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 5;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;
  Options.BufferSize := 1 shl 20;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Assert.IsTrue((Length(Encoded) > 0) and (Encoded[0] >= $80),
    'level 5 ST fixture should start with a compressed LZMA2 chunk');

  Src := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, Options);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'level 5 ST profile finder roundtrip');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.LevelFiveMultiThreadRoundTripsThroughProfileFinder;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TMemoryStream;
  Src: TNonSeekableReadStream;
  DecSrc: TBytesStream;
  Dst: TMemoryStream;
  EncodedBytes: TBytes;
  OutBytes: TBytes;
begin
  Data := RepeatingBytes(2 * 1024 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 5;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 4;
  Options.BufferSize := 1 shl 20;

  Src := TNonSeekableReadStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, Encoded, Options);
    SetLength(EncodedBytes, Encoded.Size);
    if Encoded.Size > 0 then
    begin
      Encoded.Position := 0;
      Encoded.ReadBuffer(EncodedBytes[0], Encoded.Size);
    end;
  finally
    Encoded.Free;
    Src.Free;
  end;
  Assert.IsTrue((Length(EncodedBytes) > 0) and (EncodedBytes[0] >= $80),
    'level 5 MT fixture should start with a compressed LZMA2 chunk');

  DecSrc := TBytesStream.Create(EncodedBytes);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(DecSrc, Dst, Options);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'level 5 MT profile finder roundtrip');
  finally
    Dst.Free;
    DecSrc.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2CopyModeIgnoresEncoderDictionaryMemoryLimit;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
begin
  Data := BytesOfSize((2 shl 20) + 123);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 0;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;
  Options.BufferSize := 1 shl 20;
  Options.MemoryLimit := 1;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Assert.IsTrue(Length(Encoded) > Length(Data), 'level 0 copy stream should be encoded without dictionary memory');
  Assert.AreEqual(Byte(LZMA2_CONTROL_COPY_RESET_DIC), Encoded[0], 'level 0 copy stream first chunk');
  Assert.AreEqual(Byte(LZMA2_CONTROL_EOF), Encoded[High(Encoded)], 'level 0 copy stream EOF');
end;

procedure TLzma2NativeTests.SingleThreadedRawMemoryLimitIncludesMatchFinder;
var
  Options: TLzma2Options;
  Data: TBytes;
begin
  Data := RepeatingBytes(200000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;
  Options.BufferSize := 1 shl 20;
  Options.MemoryLimit := Options.DictionarySize;

  Assert.WillRaise(
    procedure
    begin
      TLzma2Encoder.EncodeRawBytes(Data, Options);
    end,
    ELzmaMemoryError);
end;

procedure TLzma2NativeTests.RawLzmaInvalidPropsFails;
var
  Raw: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Raw := TBytes.Create($00);
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzmaRawDecoder.Decode(Src, Dst, TBytes.Create(9 * 5 * 5, 0, 0, 0, 0), 1);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2DecodeReadFailureRaisesTypedReadError;
var
  Options: TLzma2Options;
  Src: TReadFailStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Src := TReadFailStream.Create;
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaReadError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2EncodeReadFailureRaisesTypedReadError;
var
  Options: TLzma2Options;
  Src: TReadFailStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Src := TReadFailStream.Create;
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Compress(Src, Dst, Options);
      end,
      ELzmaReadError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2RoundTripsWithNonSeekableStreams;
var
  Options: TLzma2Options;
  Data: TBytes;
  EncodedBytes: TBytes;
  OutBytes: TBytes;
  Src: TNonSeekableReadStream;
  Encoded: TDestroyTrackingMemoryStream;
  DecSrc: TNonSeekableReadStream;
  Decoded: TDestroyTrackingMemoryStream;
  SrcDestroyed: Boolean;
  EncodedDestroyed: Boolean;
  DecSrcDestroyed: Boolean;
  DecodedDestroyed: Boolean;
begin
  Data := RepeatingBytes(70000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := 8192;

  Src := TNonSeekableReadStream.Create(Data, @SrcDestroyed);
  Encoded := TDestroyTrackingMemoryStream.Create(@EncodedDestroyed);
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.AreEqual(0, Src.SeekCount, 'raw LZMA2 encode must not seek source stream');
    Assert.IsFalse(SrcDestroyed, 'raw LZMA2 encode must not free caller-owned source stream');
    Assert.IsFalse(EncodedDestroyed, 'raw LZMA2 encode must not free caller-owned destination stream');

    SetLength(EncodedBytes, Encoded.Size);
    if Encoded.Size > 0 then
    begin
      Encoded.Position := 0;
      Encoded.ReadBuffer(EncodedBytes[0], Encoded.Size);
    end;
  finally
    Encoded.Free;
    Src.Free;
  end;

  DecSrc := TNonSeekableReadStream.Create(EncodedBytes, @DecSrcDestroyed);
  Decoded := TDestroyTrackingMemoryStream.Create(@DecodedDestroyed);
  try
    TLzma2.Decompress(DecSrc, Decoded, Options);
    Assert.AreEqual(0, DecSrc.SeekCount, 'raw LZMA2 decode must not seek source stream');
    Assert.IsFalse(DecSrcDestroyed, 'raw LZMA2 decode must not free caller-owned source stream');
    Assert.IsFalse(DecodedDestroyed, 'raw LZMA2 decode must not free caller-owned destination stream');

    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'raw LZMA2 non-seekable round-trip');
  finally
    Decoded.Free;
    DecSrc.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2EncodeCancellation;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Calls: Integer;
begin
  Data := RepeatingBytes(32768);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := 4096;
  Calls := 0;

  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Compress(Src, Dst, Options,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Inc(Calls);
            Cancel := InBytes > 0;
          end);
      end,
      ELzmaCancelled);
    Assert.IsTrue(Calls > 0, 'raw LZMA2 encode progress callback was not invoked before cancellation');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2TruncatedCopyChunkFails;
var
  Options: TLzma2Options;
  Raw: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Raw := TBytes.Create(LZMA2_CONTROL_COPY_RESET_DIC, 0, 3, Ord('A'));
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaInputEof);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2InvalidControlFails;
var
  Options: TLzma2Options;
  Raw: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Raw := TBytes.Create($03);
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2CompressedChunkWithoutPropsFails;
var
  Options: TLzma2Options;
  Raw: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Raw := TBytes.Create($80, 0, 0, 0, 0);
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2InvalidLcLpPropsFails;
var
  Options: TLzma2Options;
  Raw: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Raw := TBytes.Create($E0, 0, 0, 0, 0, 13, 0);
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2CorruptRangeFlushTailFails;
var
  Options: TLzma2Options;
  Data: TBytes;
  Raw: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := LZMA2_COPY_CHUNK_SIZE;
  Data := RepeatingBytes(70000);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size > 2, 'raw LZMA2 fixture must include PackedBytes data and EOF marker');
    SetLength(Raw, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Raw[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.AreEqual(Byte(0), Raw[High(Raw)], 'raw LZMA2 stream must end with EOF marker');
  Raw[High(Raw) - 1] := Raw[High(Raw) - 1] xor $01;

  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2CorruptExactRangeTailFails;
var
  Options: TLzma2Options;
  Data: TBytes;
  Raw: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Data := RepeatingBytes(70000);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size > 2, 'raw LZMA2 fixture must include PackedBytes data and EOF marker');
    SetLength(Raw, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Raw[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue(Raw[0] >= $80, 'raw LZMA2 fixture must start with a compressed chunk');
  Assert.AreEqual(Byte(0), Raw[High(Raw)], 'raw LZMA2 stream must end with EOF marker');
  Raw[High(Raw) - 1] := Raw[High(Raw) - 1] xor $01;

  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.MtDecodeStreamsReadyUnitsBeforeSlowWorkersFinish;
var
  Units: TArray<TBytes>;
  OutputSizes: TArray<UInt64>;
  Dst: TStreamingProbeWriteStream;
  SlowWorkerRunning: Integer;
  ObservedStreamingWrite: Integer;
  OutBytes: TBytes;
  WaitLoops: Integer;
begin
  SetLength(Units, 2);
  Units[0] := TBytes.Create($10);
  Units[1] := TBytes.Create($20);
  OutputSizes := TArray<UInt64>.Create(1, 1);
  SlowWorkerRunning := 0;
  ObservedStreamingWrite := 0;

  Dst := TStreamingProbeWriteStream.Create(@SlowWorkerRunning, @ObservedStreamingWrite);
  try
    TLzmaMtDecode.DecodeOrderedToStream(
      Units,
      OutputSizes,
      Dst,
      2,
      procedure(const Index: Integer; const Input: TBytes; const Destination: TStream)
      var
        Value: Byte;
      begin
        if Index = 1 then
        begin
          TInterlocked.Exchange(SlowWorkerRunning, 1);
          WaitLoops := 0;
          while (TInterlocked.CompareExchange(ObservedStreamingWrite, 0, 0) = 0) and (WaitLoops < 200) do
          begin
            TThread.Sleep(10);
            Inc(WaitLoops);
          end;
          Value := $22;
          Destination.WriteBuffer(Value, 1);
          TInterlocked.Exchange(SlowWorkerRunning, 0);
          Exit;
        end;

        while TInterlocked.CompareExchange(SlowWorkerRunning, 0, 0) = 0 do
          TThread.Sleep(1);
        Value := $11;
        Destination.WriteBuffer(Value, 1);
      end);

    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;

    Assert.AreEqual(Integer(2), Integer(Length(OutBytes)), 'streamed MT output size');
    Assert.AreEqual(Byte($11), OutBytes[0], 'first unit remains first in output');
    Assert.AreEqual(Byte($22), OutBytes[1], 'second unit remains second in output');
    Assert.IsTrue(TInterlocked.CompareExchange(ObservedStreamingWrite, 0, 0) <> 0,
      'ready ordered units should be written before slower workers finish');
  finally
    Dst.Free;
  end;
end;

procedure TLzma2NativeTests.MtDecodeWriteFailureSignalsWorkersToCancel;
var
  Units: TArray<TBytes>;
  OutputSizes: TArray<UInt64>;
  Dst: TWriteFailStream;
  Cancelled: Integer;
  SlowWorkerEntered: Integer;
begin
  SetLength(Units, 2);
  Units[0] := TBytes.Create($10);
  Units[1] := TBytes.Create($20);
  OutputSizes := TArray<UInt64>.Create(1, 1);
  Cancelled := 0;
  SlowWorkerEntered := 0;
  Dst := TWriteFailStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzmaMtDecode.DecodeOrderedToStream(
          Units,
          OutputSizes,
          Dst,
          2,
          procedure(const Index: Integer; const Input: TBytes; const Destination: TStream)
          var
            Value: Byte;
            WaitLoops: Integer;
          begin
            if Index = 1 then
            begin
              TInterlocked.Exchange(SlowWorkerEntered, 1);
              WaitLoops := 0;
              while (TInterlocked.CompareExchange(Cancelled, 0, 0) = 0) and (WaitLoops < 200) do
              begin
                TThread.Sleep(10);
                Inc(WaitLoops);
              end;
            end;

            Value := Byte($31 + Index);
            Destination.WriteBuffer(Value, 1);
          end,
          nil,
          nil,
          procedure
          begin
            TInterlocked.Exchange(Cancelled, 1);
          end);
      end,
      ELzmaWriteError);

    Assert.IsTrue(TInterlocked.CompareExchange(Cancelled, 0, 0) <> 0,
      'write failure should request worker cancellation');
    Assert.IsTrue(TInterlocked.CompareExchange(SlowWorkerEntered, 0, 0) <> 0,
      'test should exercise an active worker when the write fails');
  finally
    Dst.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeUsesIndependentResetChunks;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  RawA: TBytes;
  RawB: TBytes;
  Combined: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 0;
  EncodeOptions.ThreadCount := 1;
  EncodeOptions.BufferSize := LZMA2_COPY_CHUNK_SIZE;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  RawA := TLzma2Encoder.EncodeRawBytes(Blocks[0], EncodeOptions);
  RawB := TLzma2Encoder.EncodeRawBytes(Blocks[1], EncodeOptions);
  Assert.AreEqual(Byte(LZMA2_CONTROL_EOF), RawA[High(RawA)], 'first raw segment must end with EOF');
  Assert.AreEqual(Byte(LZMA2_CONTROL_EOF), RawB[High(RawB)], 'second raw segment must end with EOF');

  Combined := Copy(RawA, 0, Length(RawA) - 1);
  AppendBytes(Combined, RawB);
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Combined);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'MT raw LZMA2 reset chunks');
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'raw MT decode should use independent reset chunks');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested raw decode threads');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'raw independent unit count');
    Assert.IsTrue(Diagnostics.ActualThreadCount >= 2, 'raw MT decode should use more than one worker');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'raw MT decode fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeFallsBackForSingleIndependentStream;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Raw: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 0;
  EncodeOptions.ThreadCount := 1;
  Data := RepeatingBytes(50000);
  Raw := TLzma2Encoder.EncodeRawBytes(Data, EncodeOptions);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'single raw LZMA2 stream fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread, 'single raw stream should fall back to ST decode');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested fallback decode threads');
    Assert.AreEqual(1, Diagnostics.ActualThreadCount, 'fallback actual thread count');
    Assert.AreEqual(1, Diagnostics.IndependentUnitCount, 'single raw independent unit count');
    Assert.AreEqual(ldfrSingleIndependentUnit, Diagnostics.FallbackReason, 'raw fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeFallsBackForTinyPackedIndependentUnits;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  RawA: TBytes;
  RawB: TBytes;
  Combined: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 0;
  EncodeOptions.ThreadCount := 1;

  Blocks[0] := RepeatingBytes(1024);
  Blocks[1] := BytesOfSize(1536);
  RawA := TLzma2Encoder.EncodeRawBytes(Blocks[0], EncodeOptions);
  RawB := TLzma2Encoder.EncodeRawBytes(Blocks[1], EncodeOptions);
  Combined := Copy(RawA, 0, Length(RawA) - 1);
  AppendBytes(Combined, RawB);
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Combined);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'tiny PackedBytes raw LZMA2 reset chunks fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread,
      'tiny PackedBytes independent units should stay single-thread to avoid scheduler overhead');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested tiny-work decode threads');
    Assert.AreEqual(1, Diagnostics.ActualThreadCount, 'tiny-work fallback actual thread count');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'tiny-work raw independent unit count');
    Assert.AreEqual(ldfrInsufficientWork, Diagnostics.FallbackReason, 'raw tiny-work fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeFallsBackForHighlyExpandedTinyPackedUnits;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Raw: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 1;
  EncodeOptions.ThreadCount := 1;
  EncodeOptions.DictionarySize := 1 shl 20;
  EncodeOptions.BufferSize := 1 shl 20;

  Data := RepeatingBytes(64 * 1024 * 1024);
  Raw := TLzma2Encoder.EncodeRawBytes(Data, EncodeOptions);
  Assert.IsTrue(UInt64(Length(Raw)) * 256 < UInt64(Length(Data)),
    'test fixture should have tiny PackedBytes work compared to expanded output');

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'high-expansion raw LZMA2 fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread,
      'raw MT decode should avoid worker overhead when PackedBytes work is tiny');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested high-expansion fallback threads');
    Assert.AreEqual(1, Diagnostics.ActualThreadCount, 'high-expansion fallback actual thread count');
    Assert.IsTrue(Diagnostics.IndependentUnitCount > 1, 'high-expansion stream should still expose reset chunks');
    Assert.AreEqual(ldfrInsufficientWork, Diagnostics.FallbackReason, 'high-expansion fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeCancellationDoesNotWriteOutput;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  RawA: TBytes;
  RawB: TBytes;
  Combined: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Calls: Integer;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 0;
  EncodeOptions.ThreadCount := 1;
  EncodeOptions.BufferSize := LZMA2_COPY_CHUNK_SIZE;

  Blocks[0] := BytesOfSize(16 * 1024 * 1024);
  Blocks[1] := BytesOfSize(16 * 1024 * 1024);
  RawA := TLzma2Encoder.EncodeRawBytes(Blocks[0], EncodeOptions);
  RawB := TLzma2Encoder.EncodeRawBytes(Blocks[1], EncodeOptions);
  Combined := Copy(RawA, 0, Length(RawA) - 1);
  AppendBytes(Combined, RawB);

  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 2;
  Calls := 0;
  Src := TBytesStream.Create(Combined);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, DecodeOptions,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Inc(Calls);
            Cancel := True;
          end);
      end,
      ELzmaCancelled);
    Assert.IsTrue(Calls > 0, 'raw MT decode progress callback should be polled during worker execution');
    Assert.AreEqual(Int64(0), Dst.Size, 'cancelled raw MT decode must not write caller output');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeFallsBackWhenOutputExceedsMemoryLimit;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  RawA: TBytes;
  RawB: TBytes;
  Combined: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 0;
  EncodeOptions.ThreadCount := 1;
  EncodeOptions.DictionarySize := 4096;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  RawA := TLzma2Encoder.EncodeRawBytes(Blocks[0], EncodeOptions);
  RawB := TLzma2Encoder.EncodeRawBytes(Blocks[1], EncodeOptions);
  Combined := Copy(RawA, 0, Length(RawA) - 1);
  AppendBytes(Combined, RawB);
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.MemoryLimit := 200000;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Combined);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'raw MT decode memory fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread, 'raw MT decode should fall back before output buffering over memory limit');
    Assert.AreEqual(1, Diagnostics.ActualThreadCount, 'raw memory fallback actual thread count');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'raw memory fallback unit count');
    Assert.AreEqual(ldfrMemoryLimit, Diagnostics.FallbackReason, 'raw memory fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeChecksMemoryLimitBeforePayloadSnapshot;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  RawA: TBytes;
  RawB: TBytes;
  Combined: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TProbeBoundReadStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 0;
  EncodeOptions.ThreadCount := 1;
  EncodeOptions.DictionarySize := 4096;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  RawA := TLzma2Encoder.EncodeRawBytes(Blocks[0], EncodeOptions);
  RawB := TLzma2Encoder.EncodeRawBytes(Blocks[1], EncodeOptions);
  Combined := Copy(RawA, 0, Length(RawA) - 1);
  AppendBytes(Combined, RawB);
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.MemoryLimit := 200000;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TProbeBoundReadStream.Create(Combined, 4096);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'raw MT decode memory preflight fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread, 'raw MT memory preflight should fall back before scheduling');
    Assert.AreEqual(ldfrMemoryLimit, Diagnostics.FallbackReason, 'raw MT memory preflight fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawLzma2MtDecodeWriteFailurePropagates;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  RawA: TBytes;
  RawB: TBytes;
  Combined: TBytes;
  Src: TBytesStream;
  Dst: TWriteFailStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcRawLzma2;
  EncodeOptions.Level := 0;
  EncodeOptions.ThreadCount := 1;
  EncodeOptions.BufferSize := LZMA2_COPY_CHUNK_SIZE;

  Blocks[0] := BytesOfSize(16 * 1024 * 1024);
  Blocks[1] := BytesOfSize(16 * 1024 * 1024);
  RawA := TLzma2Encoder.EncodeRawBytes(Blocks[0], EncodeOptions);
  RawB := TLzma2Encoder.EncodeRawBytes(Blocks[1], EncodeOptions);
  Combined := Copy(RawA, 0, Length(RawA) - 1);
  AppendBytes(Combined, RawB);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 2;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Combined);
  Dst := TWriteFailStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, DecodeOptions);
      end,
      ELzmaWriteError);
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'raw MT decode diagnostics should survive caller write failure');
    Assert.AreEqual(2, Diagnostics.RequestedThreadCount, 'requested raw write-failure decode threads');
    Assert.IsTrue(Diagnostics.ActualThreadCount >= 2, 'raw write-failure decode should use workers');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'raw write-failure independent unit count');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'raw write-failure fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzRoundTripsAllChecks;
var
  Data: TBytes;
begin
  Data := BytesOfSize(70000);
  RoundTrip(lcXz, lzCheckNone, Data);
  RoundTrip(lcXz, lzCheckCrc32, Data);
  RoundTrip(lcXz, lzCheckCrc64, Data);
  RoundTrip(lcXz, lzCheckSha256, Data);
  RoundTrip(lcXz, lzCheckCrc64, nil);
end;

procedure TLzma2NativeTests.XzDeltaFilterFailsUnsupported;
const
  XZ_ID_DELTA = $03;
var
  Options: TLzma2Options;
  Body: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.ThreadCount := 1;
  SetLength(Body, 0);
  AppendBytes(Body, XzWriteVarInt(XZ_ID_DELTA));
  AppendBytes(Body, XzWriteVarInt(1));
  AppendByte(Body, 0);

  Archive := BuildTestXzHeader(XZ_CHECK_CRC32);
  AppendBytes(Archive, BuildTestXzRawBlockHeader(0, Body));
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzBcjFilterFailsUnsupported;
const
  XZ_ID_X86_BCJ = $04;
var
  Options: TLzma2Options;
  Body: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.ThreadCount := 1;
  SetLength(Body, 0);
  AppendBytes(Body, XzWriteVarInt(XZ_ID_X86_BCJ));
  AppendBytes(Body, XzWriteVarInt(0));

  Archive := BuildTestXzHeader(XZ_CHECK_CRC32);
  AppendBytes(Archive, BuildTestXzRawBlockHeader(0, Body));
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzFilterChainFailsUnsupported;
const
  XZ_ID_DELTA = $03;
var
  Options: TLzma2Options;
  Body: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.ThreadCount := 1;
  SetLength(Body, 0);
  AppendBytes(Body, XzWriteVarInt(XZ_ID_DELTA));
  AppendBytes(Body, XzWriteVarInt(1));
  AppendByte(Body, 0);
  AppendBytes(Body, XzWriteVarInt(XZ_ID_LZMA2));
  AppendBytes(Body, XzWriteVarInt(1));
  AppendByte(Body, 16);

  Archive := BuildTestXzHeader(XZ_CHECK_CRC32);
  AppendBytes(Archive, BuildTestXzRawBlockHeader(1, Body));
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzUnsupportedStreamFlagsFailTyped;
var
  Archive: TBytes;
  Crc: UInt32;
  Dst: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Archive := BuildTestXzHeader(XZ_CHECK_CRC32);
  Archive[XZ_SIG_SIZE] := 1;
  Crc := Crc32Calc(@Archive[XZ_SIG_SIZE], XZ_STREAM_FLAGS_SIZE);
  WriteUi32LE(@Archive[XZ_SIG_SIZE + XZ_STREAM_FLAGS_SIZE], Crc);

  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzUnsupportedBlockFlagsFailTyped;
var
  Archive: TBytes;
  Body: TBytes;
  Dst: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  SetLength(Body, 0);
  AppendBytes(Body, XzWriteVarInt(XZ_ID_LZMA2));
  AppendBytes(Body, XzWriteVarInt(1));
  AppendByte(Body, 16);

  Archive := BuildTestXzHeader(XZ_CHECK_CRC32);
  AppendBytes(Archive, BuildTestXzRawBlockHeader($04, Body));
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzInvalidLzma2FilterPropsFailTyped;
var
  Archive: TBytes;
  Body: TBytes;
  Dst: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;

  procedure AssertInvalidProps(const PropsSize: UInt64; const PropA: Byte;
    const PropB: Byte = 0);
  begin
    SetLength(Body, 0);
    AppendBytes(Body, XzWriteVarInt(XZ_ID_LZMA2));
    AppendBytes(Body, XzWriteVarInt(PropsSize));
    AppendByte(Body, PropA);
    if PropsSize > 1 then
      AppendByte(Body, PropB);

    Archive := BuildTestXzHeader(XZ_CHECK_CRC32);
    AppendBytes(Archive, BuildTestXzRawBlockHeader(0, Body));
    Src := TBytesStream.Create(Archive);
    Dst := TMemoryStream.Create;
    try
      Assert.WillRaise(
        procedure
        begin
          TLzma2.Decompress(Src, Dst, Options);
        end,
        ELzmaUnsupportedProperties);
    finally
      Dst.Free;
      Src.Free;
    end;
  end;

begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  AssertInvalidProps(2, 16, 0);
  AssertInvalidProps(1, 41);
end;

procedure TLzma2NativeTests.XzIndexRejectsZeroUnpaddedBlockRecord;
var
  Archive: TBytes;
  Block: TBytes;
  Data: TBytes;
  Dst: TMemoryStream;
  Options: TLzma2Options;
  RecordInfo: TXzTestIndexRecord;
  Src: TBytesStream;
begin
  Data := RepeatingBytes(8192);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc32;
  Options.ThreadCount := 1;

  Archive := BuildTestXzHeader(XZ_CHECK_CRC32);
  Block := BuildTestXzBlock(Data, Options, RecordInfo);
  AppendBytes(Archive, Block);
  RecordInfo.UnpaddedSize := 0;
  AppendBytes(Archive, BuildTestXzIndexAndFooter([RecordInfo], XZ_CHECK_CRC32));

  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipSingleFileRoundTrips;
var
  Options: TLzma2Options;
  Source: TBytes;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  Src: TBytesStream;
  Archive: TBytes;
  OutBytes: TBytes;
begin
  Source := RepeatingBytes(128 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ArchiveFileName := 'payload.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size > 32, '7z archive must include signature header and payload');
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
    Assert.AreEqual(Byte($37), Archive[0], '7z signature byte 0');
    Assert.AreEqual(Byte($7A), Archive[1], '7z signature byte 1');
    Assert.AreEqual(Byte($BC), Archive[2], '7z signature byte 2');

    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Source, OutBytes, 'single-file 7z LZMA2 round-trip');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipLzmaCoderSingleFileDecodes;
var
  Options: TLzma2Options;
  Source: TBytes;
  Archive: TBytes;
  DecodeInput: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
  StoredName: string;
begin
  Source := RepeatingBytes(96 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipLzmaArchive(Source, 'lzma.bin', Options);
  DecodeInput := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    StoredName := TLzma7z.ReadSingleFileName(DecodeInput);
    Assert.AreEqual('lzma.bin', StoredName, 'LZMA-coded 7z file name');
    DecodeInput.Position := 0;
    TLzma2.Decompress(DecodeInput, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Source, OutBytes, 'single-file 7z LZMA coder decode');
    Assert.AreEqual(Int64(Length(Archive)), DecodeInput.Position, '7z LZMA decode must stop at archive end');
  finally
    Decoded.Free;
    DecodeInput.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipEncodedHeaderLzma2SingleFileDecodes;
var
  Options: TLzma2Options;
  Source: TBytes;
  Archive: TBytes;
  DecodeInput: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
  StoredName: string;
begin
  Source := RepeatingBytes(80 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipEncodedHeaderArchive(Source, 'encoded-lzma2.bin', sztcLzma2, Options);
  DecodeInput := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    StoredName := TLzma7z.ReadSingleFileName(DecodeInput);
    Assert.AreEqual('encoded-lzma2.bin', StoredName, 'encoded LZMA2 7z file name');
    DecodeInput.Position := 0;
    TLzma2.Decompress(DecodeInput, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Source, OutBytes, 'single-file 7z LZMA2 encoded header');
    Assert.AreEqual(Int64(Length(Archive)), DecodeInput.Position, 'encoded LZMA2 header decode stops at archive end');
  finally
    Decoded.Free;
    DecodeInput.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipEncodedHeaderLzmaSingleFileDecodes;
var
  Options: TLzma2Options;
  Source: TBytes;
  Archive: TBytes;
  DecodeInput: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Source := BytesOfSize(96 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipEncodedHeaderArchive(Source, 'encoded-lzma.bin', sztcLzma, Options);
  DecodeInput := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(DecodeInput, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Source, OutBytes, 'single-file 7z LZMA encoded header');
    Assert.AreEqual(Int64(Length(Archive)), DecodeInput.Position, 'encoded LZMA header decode stops at archive end');
  finally
    Decoded.Free;
    DecodeInput.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipEncodedHeaderUnsupportedCoderFailsClosed;
var
  Options: TLzma2Options;
  Source: TBytes;
  Archive: TBytes;
  DecodeInput: TBytesStream;
  Decoded: TMemoryStream;
begin
  Source := RepeatingBytes(4096);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipEncodedHeaderArchive(Source, 'encoded-unsupported.bin', sztcUnsupported, Options);
  DecodeInput := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(DecodeInput, Decoded, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Decoded.Free;
    DecodeInput.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipUnsupportedNormalHeaderCoderFailsClosed;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Decoded: TMemoryStream;
  Header: TBytes;
  Options: TLzma2Options;
  Payload: TBytes;
begin
  Payload := TBytes.Create($00);
  Header := BuildTestSevenZipHeaderBytes(Length(Payload), Crc32Calc(Payload), 0, Crc32Calc(nil, 0),
    sztcUnsupported, nil, 'unsupported.bin');
  Archive := BuildTestSevenZipArchiveFromPayloadAndHeader(Payload, Header);

  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  ArchiveStream := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(ArchiveStream, Decoded, Options);
      end,
      ELzmaUnsupportedProperties);
    Assert.AreEqual(Int64(0), Decoded.Size, 'unsupported 7z coder must not write output');
  finally
    Decoded.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMultiCoderFolderFailsClosed;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_MAIN_STREAMS_INFO = $04;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Header: TBytes;
  Payload: TBytes;
begin
  Payload := TBytes.Create($00);
  SetLength(Header, 0);
  AppendByte(Header, SEVENZ_NID_HEADER);
  AppendByte(Header, SEVENZ_NID_MAIN_STREAMS_INFO);
  AppendByte(Header, SEVENZ_NID_PACK_INFO);
  AppendSevenZipTestNumber(Header, 0);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(Header, Length(Payload));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendByte(Header, Byte(Crc32Calc(Payload)));
  AppendByte(Header, Byte(Crc32Calc(Payload) shr 8));
  AppendByte(Header, Byte(Crc32Calc(Payload) shr 16));
  AppendByte(Header, Byte(Crc32Calc(Payload) shr 24));
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_UNPACK_INFO);
  AppendByte(Header, SEVENZ_NID_FOLDER);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, 0);
  AppendSevenZipTestNumber(Header, 2);

  Archive := BuildTestSevenZipArchiveFromPayloadAndHeader(Payload, Header);
  ArchiveStream := TBytesStream.Create(Archive);
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.List(ArchiveStream);
      end,
      ELzmaUnsupportedProperties);
  finally
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipPackStreamCrcMismatchFails;
var
  Archive: TBytes;
  Corrupt: TBytesStream;
  Decoded: TMemoryStream;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Source: TBytes;
  Src: TBytesStream;
begin
  Source := BytesOfSize(4096);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 0;
  Options.ArchiveFileName := 'pack-crc.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.IsTrue(Length(Archive) > 35, '7z CRC fixture must contain an LZMA2 copy payload');
  Archive[35] := Archive[35] xor $80;
  Corrupt := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Corrupt, Decoded, Options);
      end,
      ELzmaChecksumError);
  finally
    Decoded.Free;
    Corrupt.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipPayloadUnsupportedCoderFailsClosed;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Decoded: TMemoryStream;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Source: TBytes;
  Src: TBytesStream;
begin
  Source := RepeatingBytes(4096);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ArchiveFileName := 'unsupported-payload.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  PatchTestSevenZipNextHeaderByte(Archive, TBytes.Create($0B, $01, $00, $01, $21, XZ_ID_LZMA2, $01),
    1, 5, XZ_ID_LZMA2 xor $04);
  ArchiveStream := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(ArchiveStream, Decoded, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Decoded.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipAlternativeCoderFlagsFailClosed;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Source: TBytes;
  Src: TBytesStream;
begin
  Source := RepeatingBytes(2048);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ArchiveFileName := 'alternative-flags.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  PatchTestSevenZipNextHeaderByte(Archive, TBytes.Create($0B, $01, $00, $01, $21, XZ_ID_LZMA2, $01),
    1, 4, $80);
  ArchiveStream := TBytesStream.Create(Archive);
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.List(ArchiveStream);
      end,
      ELzmaUnsupportedProperties);
  finally
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipReservedCoderFlagFailsClosed;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Source: TBytes;
  Src: TBytesStream;
begin
  Source := RepeatingBytes(2048);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ArchiveFileName := 'reserved-coder-flag.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  PatchTestSevenZipNextHeaderByte(Archive, TBytes.Create($0B, $01, $00, $01, $21, XZ_ID_LZMA2, $01),
    1, 4, $40);
  ArchiveStream := TBytesStream.Create(Archive);
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.List(ArchiveStream);
      end,
      ELzmaUnsupportedProperties);
  finally
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipUnreferencedPackStreamFailsClosed;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_MAIN_STREAMS_INFO = $04;
  SEVENZ_NID_FILES_INFO = $05;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
  SEVENZ_NID_CODERS_UNPACK_SIZE = $0C;
  SEVENZ_NID_NAME = $11;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  EmptyPack: TBytes;
  ExtraPack: TBytes;
  Header: TBytes;
  NameBytes: TBytes;
  Options: TLzma2Options;
  Payload: TBytes;
  Props: TBytes;
  Info: TLzma2DictionaryInfo;

  procedure AppendUInt32LE(var Target: TBytes; const Value: UInt32);
  var
    Bytes: TBytes;
  begin
    SetLength(Bytes, SizeOf(UInt32));
    WriteUi32LE(@Bytes[0], Value);
    AppendBytes(Target, Bytes);
  end;

begin
  EmptyPack := TBytes.Create(0);
  ExtraPack := TBytes.Create($A5);
  Payload := EmptyPack;
  AppendBytes(Payload, ExtraPack);

  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.DictionarySize := 1 shl 20;
  Info := TLzma2Encoder.DictionaryInfo(Options);
  Props := TBytes.Create(Info.PropertyByte);

  SetLength(Header, 0);
  AppendByte(Header, SEVENZ_NID_HEADER);
  AppendByte(Header, SEVENZ_NID_MAIN_STREAMS_INFO);
  AppendByte(Header, SEVENZ_NID_PACK_INFO);
  AppendSevenZipTestNumber(Header, 0);
  AppendSevenZipTestNumber(Header, 2);
  AppendByte(Header, SEVENZ_NID_SIZE);
  AppendSevenZipTestNumber(Header, Length(EmptyPack));
  AppendSevenZipTestNumber(Header, Length(ExtraPack));
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, Crc32Calc(EmptyPack));
  AppendUInt32LE(Header, Crc32Calc(ExtraPack));
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_UNPACK_INFO);
  AppendByte(Header, SEVENZ_NID_FOLDER);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, 0);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, $21);
  AppendByte(Header, XZ_ID_LZMA2);
  AppendSevenZipTestNumber(Header, Length(Props));
  AppendBytes(Header, Props);
  AppendByte(Header, SEVENZ_NID_CODERS_UNPACK_SIZE);
  AppendSevenZipTestNumber(Header, 0);
  AppendByte(Header, SEVENZ_NID_CRC);
  AppendByte(Header, 1);
  AppendUInt32LE(Header, Crc32Calc(nil, 0));
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  AppendByte(Header, SEVENZ_NID_FILES_INFO);
  AppendSevenZipTestNumber(Header, 1);
  NameBytes := TEncoding.Unicode.GetBytes('payload.bin' + #0);
  AppendByte(Header, SEVENZ_NID_NAME);
  AppendSevenZipTestNumber(Header, UInt64(Length(NameBytes)) + 1);
  AppendByte(Header, 0);
  AppendBytes(Header, NameBytes);
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  Archive := BuildTestSevenZipArchiveFromPayloadAndHeader(Payload, Header);
  ArchiveStream := TBytesStream.Create(Archive);
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.List(ArchiveStream);
      end,
      ELzmaDataError);
  finally
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMissingFileNamesFailsClosed;
const
  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_FILES_INFO = $05;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Header: TBytes;
begin
  SetLength(Header, 0);
  AppendByte(Header, SEVENZ_NID_HEADER);
  AppendByte(Header, SEVENZ_NID_FILES_INFO);
  AppendSevenZipTestNumber(Header, 1);
  AppendByte(Header, SEVENZ_NID_END);
  AppendByte(Header, SEVENZ_NID_END);

  Archive := BuildTestSevenZipArchiveFromPayloadAndHeader(nil, Header);
  ArchiveStream := TBytesStream.Create(Archive);
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.List(ArchiveStream);
      end,
      ELzmaDataError);
  finally
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMissingNameTerminatorFailsClosed;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Header: TBytes;
  NameBytes: TBytes;
  Options: TLzma2Options;
  Pattern: TBytes;
  Payload: TBytes;
  Props: TBytes;
  Info: TLzma2DictionaryInfo;
begin
  Payload := TBytes.Create(0);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.DictionarySize := 1 shl 20;
  Info := TLzma2Encoder.DictionaryInfo(Options);
  Props := TBytes.Create(Info.PropertyByte);
  Header := BuildTestSevenZipHeaderBytes(Length(Payload), Crc32Calc(Payload), 0,
    Crc32Calc(nil, 0), sztcLzma2, Props, 'nonull.bin');
  Archive := BuildTestSevenZipArchiveFromPayloadAndHeader(Payload, Header);

  NameBytes := TEncoding.Unicode.GetBytes('nonull.bin' + #0);
  Pattern := TBytes.Create($11, Byte(Length(NameBytes) + 1), 0);
  AppendBytes(Pattern, NameBytes);
  PatchTestSevenZipNextHeaderByte(Archive, Pattern, 1, 3 + Length(NameBytes) - 2, Ord('x'));

  ArchiveStream := TBytesStream.Create(Archive);
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.List(ArchiveStream);
      end,
      ELzmaDataError);
  finally
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipOddUtf16NamePayloadFailsClosed;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Header: TBytes;
  NameBytes: TBytes;
  Options: TLzma2Options;
  Pattern: TBytes;
  Payload: TBytes;
  Props: TBytes;
  Info: TLzma2DictionaryInfo;
begin
  Payload := TBytes.Create(0);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.DictionarySize := 1 shl 20;
  Info := TLzma2Encoder.DictionaryInfo(Options);
  Props := TBytes.Create(Info.PropertyByte);
  Header := BuildTestSevenZipHeaderBytes(Length(Payload), Crc32Calc(Payload), 0,
    Crc32Calc(nil, 0), sztcLzma2, Props, 'odd.bin');
  Archive := BuildTestSevenZipArchiveFromPayloadAndHeader(Payload, Header);

  NameBytes := TEncoding.Unicode.GetBytes('odd.bin' + #0);
  Pattern := TBytes.Create($11, Byte(Length(NameBytes) + 1), 0);
  AppendBytes(Pattern, NameBytes);
  PatchTestSevenZipNextHeaderByte(Archive, Pattern, 1, 1, 1);

  ArchiveStream := TBytesStream.Create(Archive);
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.List(ArchiveStream);
      end,
      ELzmaDataError);
  finally
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipFolderCrcMismatchFails;
var
  Archive: TBytes;
  Corrupt: TBytesStream;
  Decoded: TMemoryStream;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Source: TBytes;
  Src: TBytesStream;
begin
  Source := RepeatingBytes(4096);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ArchiveFileName := 'folder-crc.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  PatchTestSevenZipNextHeaderByte(Archive, TBytes.Create($0A, $01), 2, 2, $01);
  Corrupt := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Corrupt, Decoded, Options);
      end,
      ELzmaChecksumError);
  finally
    Decoded.Free;
    Corrupt.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipSolidFileCrcMismatchFails;
var
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  FirstOut: TMemoryStream;
  Options: TLzma2Options;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipSolidArchive(BytesOfSize(4096), RepeatingBytes(4096), sztcLzma2, Options);
  PatchTestSevenZipNextHeaderByte(Archive, TBytes.Create($0A, $01), 3, 2, $01);
  ArchiveStream := TBytesStream.Create(Archive);
  FirstOut := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma7z.ExtractAll(ArchiveStream,
          function(const Entry: TLzma7zEntry): TStream
          begin
            if Entry.FileName = 'solid/a.bin' then
              Exit(FirstOut);
            Result := nil;
          end,
          Options);
      end,
      ELzmaChecksumError);
  finally
    FirstOut.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMultiFolderLzma2ArchiveExtractsAllEntries;
var
  Options: TLzma2Options;
  FirstData: TBytes;
  SecondData: TBytes;
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Entries: TArray<TLzma7zEntry>;
  FirstOut: TMemoryStream;
  SecondOut: TMemoryStream;
  EmptyOut: TMemoryStream;
  EntryCount: Integer;
  SawDirectory: Boolean;
  SawFirst: Boolean;
  SawSecond: Boolean;
  SawEmpty: Boolean;

  procedure AssertStreamBytes(const Expected: TBytes; const Stream: TMemoryStream; const Message: string);
  var
    Actual: TBytes;
  begin
    SetLength(Actual, Integer(Stream.Size));
    if Stream.Size <> 0 then
    begin
      Stream.Position := 0;
      Stream.ReadBuffer(Actual[0], Stream.Size);
    end;
    AssertBytesEqual(Expected, Actual, Message);
  end;

begin
  FirstData := RepeatingBytes(48 * 1024);
  SecondData := BytesOfSize(36 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipMultiFolderArchive(FirstData, SecondData, sztcLzma2, Options);
  ArchiveStream := TBytesStream.Create(Archive);
  FirstOut := TMemoryStream.Create;
  SecondOut := TMemoryStream.Create;
  EmptyOut := TMemoryStream.Create;
  try
    Entries := TLzma7z.List(ArchiveStream);
    Assert.AreEqual(Integer(4), Integer(Length(Entries)), 'multi-file 7z entry count');
    Assert.AreEqual('dir', Entries[0].FileName, 'directory entry name');
    Assert.IsTrue(Entries[0].IsDirectory, 'directory entry kind');
    Assert.AreEqual('dir/a.bin', Entries[1].FileName, 'first file entry name');
    Assert.AreEqual(Int64(Length(FirstData)), Int64(Entries[1].Size), 'first file listed size');
    Assert.IsTrue(Entries[1].HasModifiedTime, 'first file modified time metadata');
    Assert.AreEqual(UInt64($1112131415161718), Entries[1].ModifiedTime, 'first file modified time value');
    Assert.IsTrue(Entries[1].HasAttributes, 'first file attributes metadata');
    Assert.AreEqual(UInt32($20), Entries[1].Attributes, 'first file attributes value');
    Assert.AreEqual('dir/empty.txt', Entries[3].FileName, 'empty file entry name');
    Assert.IsTrue(Entries[3].IsEmptyStream, 'empty file entry kind');
    Assert.AreEqual(UInt64($3132333435363738), Entries[3].ModifiedTime, 'empty file modified time value');

    EntryCount := 0;
    SawDirectory := False;
    SawFirst := False;
    SawSecond := False;
    SawEmpty := False;
    ArchiveStream.Position := 0;
    TLzma7z.ExtractAll(ArchiveStream,
      function(const Entry: TLzma7zEntry): TStream
      begin
        Inc(EntryCount);
        if Entry.FileName = 'dir' then
        begin
          Assert.IsTrue(Entry.IsDirectory, 'dir entry must be marked as directory');
          SawDirectory := True;
          Exit(nil);
        end;
        if Entry.FileName = 'dir/a.bin' then
        begin
          SawFirst := True;
          Exit(FirstOut);
        end;
        if Entry.FileName = 'b.bin' then
        begin
          SawSecond := True;
          Exit(SecondOut);
        end;
        if Entry.FileName = 'dir/empty.txt' then
        begin
          Assert.IsTrue(Entry.IsEmptyStream, 'empty file must be marked as empty stream');
          SawEmpty := True;
          Exit(EmptyOut);
        end;
        Assert.Fail('unexpected multi-file 7z entry: ' + Entry.FileName);
        Result := nil;
      end,
      Options);

    Assert.AreEqual(4, EntryCount, 'extract callback must see every archive entry');
    Assert.IsTrue(SawDirectory and SawFirst and SawSecond and SawEmpty, 'all multi-file entries must be visited');
    AssertStreamBytes(FirstData, FirstOut, 'multi-folder first file bytes');
    AssertStreamBytes(SecondData, SecondOut, 'multi-folder second file bytes');
    Assert.AreEqual(Int64(0), EmptyOut.Size, 'empty file output must stay empty');
    Assert.AreEqual(Int64(Length(Archive)), ArchiveStream.Position, 'multi-folder decode stops at archive end');
  finally
    EmptyOut.Free;
    SecondOut.Free;
    FirstOut.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMultiFolderLzmaArchiveExtractsAllEntries;
var
  Options: TLzma2Options;
  FirstData: TBytes;
  SecondData: TBytes;
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  FirstOut: TMemoryStream;
  SecondOut: TMemoryStream;

  procedure AssertStreamBytes(const Expected: TBytes; const Stream: TMemoryStream; const Message: string);
  var
    Actual: TBytes;
  begin
    SetLength(Actual, Integer(Stream.Size));
    if Stream.Size <> 0 then
    begin
      Stream.Position := 0;
      Stream.ReadBuffer(Actual[0], Stream.Size);
    end;
    AssertBytesEqual(Expected, Actual, Message);
  end;

begin
  FirstData := BytesOfSize(32 * 1024);
  SecondData := RepeatingBytes(40 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipMultiFolderArchive(FirstData, SecondData, sztcLzma, Options);
  ArchiveStream := TBytesStream.Create(Archive);
  FirstOut := TMemoryStream.Create;
  SecondOut := TMemoryStream.Create;
  try
    TLzma7z.ExtractAll(ArchiveStream,
      function(const Entry: TLzma7zEntry): TStream
      begin
        if Entry.FileName = 'dir/a.bin' then
          Exit(FirstOut);
        if Entry.FileName = 'b.bin' then
          Exit(SecondOut);
        Result := nil;
      end,
      Options);
    AssertStreamBytes(FirstData, FirstOut, 'multi-folder LZMA first file bytes');
    AssertStreamBytes(SecondData, SecondOut, 'multi-folder LZMA second file bytes');
  finally
    SecondOut.Free;
    FirstOut.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMultiFileLzma2EncodeListsAndExtractsAllEntries;
var
  Options: TLzma2Options;
  EntriesToEncode: TArray<TLzma7zEncodeEntry>;
  Entries: TArray<TLzma7zEntry>;
  FirstData: TBytes;
  SecondData: TBytes;
  EmptyData: TBytes;
  ArchiveStream: TMemoryStream;
  FirstOut: TMemoryStream;
  SecondOut: TMemoryStream;
  EmptyOut: TMemoryStream;

  procedure AssertStreamBytes(const Expected: TBytes; const Stream: TMemoryStream; const Message: string);
  var
    Actual: TBytes;
  begin
    SetLength(Actual, Integer(Stream.Size));
    if Stream.Size <> 0 then
    begin
      Stream.Position := 0;
      Stream.ReadBuffer(Actual[0], Stream.Size);
    end;
    AssertBytesEqual(Expected, Actual, Message);
  end;

begin
  FirstData := RepeatingBytes(52 * 1024);
  SecondData := BytesOfSize(44 * 1024);
  SetLength(EmptyData, 0);
  SetLength(EntriesToEncode, 4);
  EntriesToEncode[0].FileName := 'dir';
  EntriesToEncode[0].IsDirectory := True;
  EntriesToEncode[0].HasAttributes := True;
  EntriesToEncode[0].Attributes := $10;
  EntriesToEncode[1].FileName := 'dir/a.bin';
  EntriesToEncode[1].HasCreationTime := True;
  EntriesToEncode[1].CreationTime := UInt64($0011223344556677);
  EntriesToEncode[1].HasAccessTime := True;
  EntriesToEncode[1].AccessTime := UInt64($1021324354657687);
  EntriesToEncode[1].HasModifiedTime := True;
  EntriesToEncode[1].ModifiedTime := UInt64($0102030405060708);
  EntriesToEncode[2].FileName := 'b.bin';
  EntriesToEncode[3].FileName := 'dir/empty.txt';

  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  ArchiveStream := TMemoryStream.Create;
  FirstOut := TMemoryStream.Create;
  SecondOut := TMemoryStream.Create;
  EmptyOut := TMemoryStream.Create;
  try
    TLzma7z.EncodeEntries(EntriesToEncode,
      function(const Entry: TLzma7zEncodeEntry; const EntryIndex: Integer): TStream
      begin
        if Entry.FileName = 'dir/a.bin' then
          Exit(TBytesStream.Create(FirstData));
        if Entry.FileName = 'b.bin' then
          Exit(TBytesStream.Create(SecondData));
        if Entry.FileName = 'dir/empty.txt' then
          Exit(TBytesStream.Create(EmptyData));
        Assert.Fail('unexpected encode callback entry: ' + Entry.FileName);
        Result := nil;
      end,
      ArchiveStream, Options, zemLzma2);

    ArchiveStream.Position := 0;
    Entries := TLzma7z.List(ArchiveStream);
    Assert.AreEqual(Integer(4), Integer(Length(Entries)), 'encoded multi-file 7z entry count');
    Assert.IsTrue(Entries[0].IsDirectory, 'encoded directory entry flag');
    Assert.AreEqual('dir/a.bin', Entries[1].FileName, 'encoded first file name');
    Assert.AreEqual(Int64(Length(FirstData)), Int64(Entries[1].Size), 'encoded first file size');
    Assert.IsTrue(Entries[1].HasModifiedTime, 'encoded first file mtime flag');
    Assert.AreEqual(UInt64($0102030405060708), Entries[1].ModifiedTime, 'encoded first file mtime value');
    Assert.IsTrue(Entries[1].HasCreationTime, 'encoded first file creation time flag');
    Assert.AreEqual(UInt64($0011223344556677), Entries[1].CreationTime, 'encoded first file creation time value');
    Assert.IsTrue(Entries[1].HasAccessTime, 'encoded first file access time flag');
    Assert.AreEqual(UInt64($1021324354657687), Entries[1].AccessTime, 'encoded first file access time value');
    Assert.AreEqual('dir/empty.txt', Entries[3].FileName, 'encoded empty file name');
    Assert.IsTrue(Entries[3].IsEmptyStream, 'encoded empty file flag');

    ArchiveStream.Position := 0;
    TLzma7z.ExtractAll(ArchiveStream,
      function(const Entry: TLzma7zEntry): TStream
      begin
        if Entry.FileName = 'dir' then
          Exit(nil);
        if Entry.FileName = 'dir/a.bin' then
          Exit(FirstOut);
        if Entry.FileName = 'b.bin' then
          Exit(SecondOut);
        if Entry.FileName = 'dir/empty.txt' then
          Exit(EmptyOut);
        Assert.Fail('unexpected encoded multi-file entry: ' + Entry.FileName);
        Result := nil;
      end,
      Options);
    AssertStreamBytes(FirstData, FirstOut, 'encoded LZMA2 first file bytes');
    AssertStreamBytes(SecondData, SecondOut, 'encoded LZMA2 second file bytes');
    Assert.AreEqual(Int64(0), EmptyOut.Size, 'encoded LZMA2 empty file bytes');
    Assert.AreEqual(ArchiveStream.Size, ArchiveStream.Position, 'encoded multi-file 7z stops at archive end');
  finally
    EmptyOut.Free;
    SecondOut.Free;
    FirstOut.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMultiFileLzmaEncodeListsAndExtractsAllEntries;
var
  Options: TLzma2Options;
  EntriesToEncode: TArray<TLzma7zEncodeEntry>;
  Entries: TArray<TLzma7zEntry>;
  FirstData: TBytes;
  SecondData: TBytes;
  EmptyData: TBytes;
  ArchiveStream: TMemoryStream;
  FirstOut: TMemoryStream;
  SecondOut: TMemoryStream;

  procedure AssertStreamBytes(const Expected: TBytes; const Stream: TMemoryStream; const Message: string);
  var
    Actual: TBytes;
  begin
    SetLength(Actual, Integer(Stream.Size));
    if Stream.Size <> 0 then
    begin
      Stream.Position := 0;
      Stream.ReadBuffer(Actual[0], Stream.Size);
    end;
    AssertBytesEqual(Expected, Actual, Message);
  end;

begin
  FirstData := BytesOfSize(28 * 1024);
  SecondData := RepeatingBytes(36 * 1024);
  SetLength(EmptyData, 0);
  SetLength(EntriesToEncode, 4);
  EntriesToEncode[0].FileName := 'dir';
  EntriesToEncode[0].IsDirectory := True;
  EntriesToEncode[1].FileName := 'dir/a.bin';
  EntriesToEncode[2].FileName := 'b.bin';
  EntriesToEncode[3].FileName := 'dir/empty.txt';

  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  ArchiveStream := TMemoryStream.Create;
  FirstOut := TMemoryStream.Create;
  SecondOut := TMemoryStream.Create;
  try
    TLzma7z.EncodeEntries(EntriesToEncode,
      function(const Entry: TLzma7zEncodeEntry; const EntryIndex: Integer): TStream
      begin
        if Entry.FileName = 'dir/a.bin' then
          Exit(TBytesStream.Create(FirstData));
        if Entry.FileName = 'b.bin' then
          Exit(TBytesStream.Create(SecondData));
        if Entry.FileName = 'dir/empty.txt' then
          Exit(TBytesStream.Create(EmptyData));
        Assert.Fail('unexpected LZMA encode callback entry: ' + Entry.FileName);
        Result := nil;
      end,
      ArchiveStream, Options, zemLzma);

    ArchiveStream.Position := 0;
    Entries := TLzma7z.List(ArchiveStream);
    Assert.AreEqual(Integer(4), Integer(Length(Entries)), 'encoded LZMA multi-file 7z entry count');
    Assert.IsTrue(Entries[0].IsDirectory, 'encoded LZMA directory entry flag');
    Assert.AreEqual(Int64(Length(FirstData)), Int64(Entries[1].Size), 'encoded LZMA first file size');
    Assert.IsTrue(Entries[3].IsEmptyStream, 'encoded LZMA empty file flag');

    ArchiveStream.Position := 0;
    TLzma7z.ExtractAll(ArchiveStream,
      function(const Entry: TLzma7zEntry): TStream
      begin
        if Entry.FileName = 'dir/a.bin' then
          Exit(FirstOut);
        if Entry.FileName = 'b.bin' then
          Exit(SecondOut);
        Result := nil;
      end,
      Options);
    AssertStreamBytes(FirstData, FirstOut, 'encoded LZMA first file bytes');
    AssertStreamBytes(SecondData, SecondOut, 'encoded LZMA second file bytes');
  finally
    SecondOut.Free;
    FirstOut.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipUtf16NamesRoundTrip;
var
  ArchiveStream: TMemoryStream;
  Data: TBytes;
  EmptyData: TBytes;
  Entries: TArray<TLzma7zEntry>;
  EntriesToEncode: TArray<TLzma7zEncodeEntry>;
  Options: TLzma2Options;
  Output: TMemoryStream;
  OutBytes: TBytes;
  UnicodeName: string;
begin
  Data := TEncoding.UTF8.GetBytes('utf16-name-payload');
  SetLength(EmptyData, 0);
  UnicodeName := 'unicode/' + #$0444#$0430#$0439#$043B + '-' + #$6D4B#$8BD5 + '.txt';

  SetLength(EntriesToEncode, 2);
  EntriesToEncode[0].FileName := 'unicode';
  EntriesToEncode[0].IsDirectory := True;
  EntriesToEncode[1].FileName := UnicodeName;

  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  ArchiveStream := TMemoryStream.Create;
  Output := TMemoryStream.Create;
  try
    TLzma7z.EncodeEntries(EntriesToEncode,
      function(const Entry: TLzma7zEncodeEntry; const EntryIndex: Integer): TStream
      begin
        if Entry.IsDirectory then
          Exit(nil);
        if Entry.FileName = UnicodeName then
          Exit(TBytesStream.Create(Data));
        Assert.Fail('unexpected UTF-16 7z encode entry: ' + Entry.FileName);
        Result := TBytesStream.Create(EmptyData);
      end,
      ArchiveStream, Options, zemLzma2);

    ArchiveStream.Position := 0;
    Entries := TLzma7z.List(ArchiveStream);
    Assert.AreEqual(Integer(2), Integer(Length(Entries)), 'UTF-16 7z entry count');
    Assert.AreEqual('unicode', Entries[0].FileName, 'UTF-16 directory entry name');
    Assert.AreEqual(UnicodeName, Entries[1].FileName, 'UTF-16 file entry name');

    ArchiveStream.Position := 0;
    TLzma7z.ExtractAll(ArchiveStream,
      function(const Entry: TLzma7zEntry): TStream
      begin
        if Entry.FileName = UnicodeName then
          Exit(Output);
        Result := nil;
      end,
      Options);

    SetLength(OutBytes, Output.Size);
    if Output.Size <> 0 then
    begin
      Output.Position := 0;
      Output.ReadBuffer(OutBytes[0], Output.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'UTF-16 7z file payload');
  finally
    Output.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipMultiFileFailsSingleStreamDecode;
var
  Options: TLzma2Options;
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  Decoded: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Archive := BuildTestSevenZipMultiFolderArchive(RepeatingBytes(4096), BytesOfSize(3072), sztcLzma2, Options);
  ArchiveStream := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(ArchiveStream, Decoded, Options);
      end,
      ELzmaUnsupportedProperties);
    Assert.AreEqual(Int64(0), Decoded.Size, 'single-stream decode must not concatenate multi-file output');
  finally
    Decoded.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipSolidLzma2SubstreamsExtractAsSeparateFiles;
var
  Options: TLzma2Options;
  FirstData: TBytes;
  SecondData: TBytes;
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  FirstOut: TMemoryStream;
  SecondOut: TMemoryStream;

  procedure AssertStreamBytes(const Expected: TBytes; const Stream: TMemoryStream; const Message: string);
  var
    Actual: TBytes;
  begin
    SetLength(Actual, Integer(Stream.Size));
    if Stream.Size <> 0 then
    begin
      Stream.Position := 0;
      Stream.ReadBuffer(Actual[0], Stream.Size);
    end;
    AssertBytesEqual(Expected, Actual, Message);
  end;

begin
  FirstData := BytesOfSize(24 * 1024);
  SecondData := RepeatingBytes(56 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipSolidArchive(FirstData, SecondData, sztcLzma2, Options);
  ArchiveStream := TBytesStream.Create(Archive);
  FirstOut := TMemoryStream.Create;
  SecondOut := TMemoryStream.Create;
  try
    TLzma7z.ExtractAll(ArchiveStream,
      function(const Entry: TLzma7zEntry): TStream
      begin
        if Entry.FileName = 'solid/a.bin' then
          Exit(FirstOut);
        if Entry.FileName = 'solid/b.bin' then
          Exit(SecondOut);
        Assert.Fail('unexpected solid 7z entry: ' + Entry.FileName);
        Result := nil;
      end,
      Options);
    AssertStreamBytes(FirstData, FirstOut, 'solid first substream bytes');
    AssertStreamBytes(SecondData, SecondOut, 'solid second substream bytes');
    Assert.AreEqual(Int64(Length(Archive)), ArchiveStream.Position, 'solid decode stops at archive end');
  finally
    SecondOut.Free;
    FirstOut.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipSolidLzmaSubstreamsExtractAsSeparateFiles;
var
  Options: TLzma2Options;
  FirstData: TBytes;
  SecondData: TBytes;
  Archive: TBytes;
  ArchiveStream: TBytesStream;
  FirstOut: TMemoryStream;
  SecondOut: TMemoryStream;

  procedure AssertStreamBytes(const Expected: TBytes; const Stream: TMemoryStream; const Message: string);
  var
    Actual: TBytes;
  begin
    SetLength(Actual, Integer(Stream.Size));
    if Stream.Size <> 0 then
    begin
      Stream.Position := 0;
      Stream.ReadBuffer(Actual[0], Stream.Size);
    end;
    AssertBytesEqual(Expected, Actual, Message);
  end;

begin
  FirstData := RepeatingBytes(20 * 1024);
  SecondData := BytesOfSize(28 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestSevenZipSolidArchive(FirstData, SecondData, sztcLzma, Options);
  ArchiveStream := TBytesStream.Create(Archive);
  FirstOut := TMemoryStream.Create;
  SecondOut := TMemoryStream.Create;
  try
    TLzma7z.ExtractAll(ArchiveStream,
      function(const Entry: TLzma7zEntry): TStream
      begin
        if Entry.FileName = 'solid/a.bin' then
          Exit(FirstOut);
        if Entry.FileName = 'solid/b.bin' then
          Exit(SecondOut);
        Assert.Fail('unexpected solid LZMA 7z entry: ' + Entry.FileName);
        Result := nil;
      end,
      Options);
    AssertStreamBytes(FirstData, FirstOut, 'solid LZMA first substream bytes');
    AssertStreamBytes(SecondData, SecondOut, 'solid LZMA second substream bytes');
    Assert.AreEqual(Int64(Length(Archive)), ArchiveStream.Position, 'solid LZMA decode stops at archive end');
  finally
    SecondOut.Free;
    FirstOut.Free;
    ArchiveStream.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipDecodeLeavesSourceAfterArchive;
var
  Options: TLzma2Options;
  Source: TBytes;
  Encoded: TMemoryStream;
  Archive: TBytes;
  ArchiveWithTail: TBytes;
  DecodeInput: TBytesStream;
  Decoded: TMemoryStream;
  Src: TBytesStream;
begin
  Source := RepeatingBytes(96 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ArchiveFileName := 'payload.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Length(Archive));
  finally
    Encoded.Free;
    Src.Free;
  end;

  SetLength(ArchiveWithTail, Length(Archive) + 3);
  Move(Archive[0], ArchiveWithTail[0], Length(Archive));
  ArchiveWithTail[Length(Archive)] := $DA;
  ArchiveWithTail[Length(Archive) + 1] := $7A;
  ArchiveWithTail[Length(Archive) + 2] := $EE;

  DecodeInput := TBytesStream.Create(ArchiveWithTail);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(DecodeInput, Decoded, Options);
    Assert.AreEqual(Int64(Length(Archive)), DecodeInput.Position,
      '7z decode must leave a seekable source positioned after the full archive header, before trailing bytes');
  finally
    Decoded.Free;
    DecodeInput.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipHeaderCrcCorruptionFails;
var
  Options: TLzma2Options;
  Source: TBytes;
  Encoded: TMemoryStream;
  Src: TBytesStream;
  Archive: TBytes;
  Corrupt: TBytesStream;
  Decoded: TMemoryStream;
begin
  Source := BytesOfSize(4096);
  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.ArchiveFileName := 'crc.bin';

  Src := TBytesStream.Create(Source);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Encoded.Size);
  finally
    Encoded.Free;
    Src.Free;
  end;

  Archive[12] := Archive[12] xor $01;
  Corrupt := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Corrupt, Decoded, Options);
      end,
      ELzmaChecksumError);
  finally
    Decoded.Free;
    Corrupt.Free;
  end;
end;

procedure TLzma2NativeTests.XzRoundTripsWithNonSeekableStreams;
var
  Options: TLzma2Options;
  Data: TBytes;
  EncodedBytes: TBytes;
  OutBytes: TBytes;
  Src: TNonSeekableReadStream;
  Encoded: TDestroyTrackingMemoryStream;
  DecSrc: TNonSeekableReadStream;
  Decoded: TDestroyTrackingMemoryStream;
  SrcDestroyed: Boolean;
  EncodedDestroyed: Boolean;
  DecSrcDestroyed: Boolean;
  DecodedDestroyed: Boolean;
begin
  Data := RepeatingBytes(70000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckSha256;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := 8192;

  Src := TNonSeekableReadStream.Create(Data, @SrcDestroyed);
  Encoded := TDestroyTrackingMemoryStream.Create(@EncodedDestroyed);
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.AreEqual(0, Src.SeekCount, 'XZ encode must not seek source stream');
    Assert.IsFalse(SrcDestroyed, 'XZ encode must not free caller-owned source stream');
    Assert.IsFalse(EncodedDestroyed, 'XZ encode must not free caller-owned destination stream');

    SetLength(EncodedBytes, Encoded.Size);
    if Encoded.Size > 0 then
    begin
      Encoded.Position := 0;
      Encoded.ReadBuffer(EncodedBytes[0], Encoded.Size);
    end;
  finally
    Encoded.Free;
    Src.Free;
  end;

  DecSrc := TNonSeekableReadStream.Create(EncodedBytes, @DecSrcDestroyed);
  Decoded := TDestroyTrackingMemoryStream.Create(@DecodedDestroyed);
  try
    TLzma2.Decompress(DecSrc, Decoded, Options);
    Assert.AreEqual(0, DecSrc.SeekCount, 'XZ decode must not seek source stream');
    Assert.IsFalse(DecSrcDestroyed, 'XZ decode must not free caller-owned source stream');
    Assert.IsFalse(DecodedDestroyed, 'XZ decode must not free caller-owned destination stream');

    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'XZ non-seekable round-trip');
  finally
    Decoded.Free;
    DecSrc.Free;
  end;
end;

procedure TLzma2NativeTests.XzEncodeProgressIsMonotonic;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
  LastIn: UInt64;
  LastOut: UInt64;
  Calls: Integer;
begin
  Data := RepeatingBytes(32768);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc64;
  Options.Level := 0;
  Options.ThreadCount := 1;
  Options.BufferSize := 4096;
  LastIn := 0;
  LastOut := 0;
  Calls := 0;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options,
      procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
      begin
        Inc(Calls);
        Assert.IsTrue(InBytes >= LastIn, 'XZ encode input progress regressed');
        Assert.IsTrue(OutBytes >= LastOut, 'XZ encode output progress regressed');
        LastIn := InBytes;
        LastOut := OutBytes;
      end);
    Assert.IsTrue(Calls > 1, 'XZ encode should report chunk and final progress');

    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'XZ monotonic progress round-trip');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzEncodeCancellation;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Calls: Integer;
begin
  Data := RepeatingBytes(32768);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc32;
  Options.Level := 0;
  Options.ThreadCount := 1;
  Options.BufferSize := 4096;
  Calls := 0;

  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Compress(Src, Dst, Options,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Inc(Calls);
            Cancel := Calls >= 2;
          end);
      end,
      ELzmaCancelled);
    Assert.IsTrue(Calls >= 2, 'XZ encode progress did not reach the cancellation point');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMultiBlockDecodes;
var
  Options: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  OutBytes: TBytes;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc64;
  Options.Level := 1;
  Options.ThreadCount := 2;
  Options.DictionarySize := 1 shl 20;

  Blocks[0] := RepeatingBytes(32768);
  Blocks[1] := BytesOfSize(49152);

  Archive := BuildTestXzHeader(XzCheckId(Options.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], Options, Records[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], Options, Records[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(Options.Check)));

  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, Options);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'multi-block XZ');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMultiBlockEncodeDiagnosticsAggregatesRawFastPathCounts;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;
begin
  Data := BytesOfSize(8192);
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckNone;
  Options.Level := 0;
  Options.ThreadCount := 1;
  Options.XzBlockSize := 4096;
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size > 0, 'multi-block XZ fixture sanity');
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.AreEqual(2, Diagnostics.BlockCount, 'two sized XZ blocks');
  Assert.AreEqual(2, Diagnostics.BatchCount, 'two raw block encode batches');
  Assert.AreEqual(2, Diagnostics.CopyFastPathCount,
    'multi-block XZ diagnostics must aggregate raw copy fast paths');
  Assert.AreEqual(0, Diagnostics.IncompressibleFastPathCount,
    'level-0 copy chunks are explicit copy path, not incompressibility fallback');
end;

procedure TLzma2NativeTests.XzMultiBlockEncodeDiagnosticsReportsTuningForEmptyInput;
var
  Data: TBytes;
  Diagnostics: TLzma2EncodeDiagnostics;
  Encoded: TMemoryStream;
  Options: TLzma2Options;
  Src: TBytesStream;
begin
  SetLength(Data, 0);
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckNone;
  Options.Level := 5;
  Options.ThreadCount := 1;
  Options.FastBytes := 48;
  Options.CutValue := 7;
  Options.MatchFinderProfile := lmfpHashChain4;
  Options.XzBlockSize := 4096;
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Assert.IsTrue(Encoded.Size > 0, 'empty multi-block XZ still writes stream metadata');
  finally
    Encoded.Free;
    Src.Free;
  end;

  Assert.AreEqual(0, Diagnostics.BlockCount, 'empty input has no XZ data blocks');
  Assert.AreEqual(0, Diagnostics.BatchCount, 'empty input has no raw encode batches');
  Assert.AreEqual(48, Diagnostics.FastBytes, 'override diagnostics fast bytes');
  Assert.AreEqual(48, Diagnostics.NiceLen, 'override diagnostics nice length');
  Assert.AreEqual(UInt32(7), Diagnostics.CutValue, 'override diagnostics cut value');
  Assert.AreEqual(Ord(lpmSdkProfile), Ord(Diagnostics.ParserMode), 'empty multi-block parser mode diagnostics');
  Assert.AreEqual(Ord(lmfpHashChain4), Ord(Diagnostics.MatchFinderProfile),
    'empty multi-block match finder diagnostics');
  Assert.AreEqual(4, Diagnostics.NumHashBytes, 'empty multi-block match finder hash bytes');
  Assert.IsFalse(Diagnostics.OptimumParserEnabled,
    'empty multi-block XZ diagnostics must not claim native optimum-parser work');
  Assert.AreEqual('none', Diagnostics.FallbackReason, 'empty multi-block fallback diagnostics');
end;

procedure TLzma2NativeTests.XzEncodeBlockSizeProducesIndependentBlocks;
var
  EncodeOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
  I: Integer;
begin
  SetLength(Data, 192 * 1024);
  for I := 0 to High(Data) do
    Data[I] := Byte(Ord('A') + ((I div 17) mod 23));

  EncodeOptions := TLzma2.DefaultOptions;
  EncodeOptions.Container := lcXz;
  EncodeOptions.Check := lzCheckCrc32;
  EncodeOptions.Level := 1;
  EncodeOptions.ThreadCount := 1;
  EncodeOptions.DictionarySize := 1 shl 20;
  EncodeOptions.XzBlockSize := 64 * 1024;

  Src := TBytesStream.Create(Data);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Dst, EncodeOptions);
    SetLength(Archive, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Archive[0], Dst.Size);
    end;
  finally
    Dst.Free;
    Src.Free;
  end;

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := EncodeOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'Delphi-generated multi-block XZ');
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'Delphi XZ block-size encode should feed MT decode');
    Assert.IsFalse(Diagnostics.InputSnapshot, 'seekable XZ MT decode should avoid a full input snapshot');
    Assert.IsTrue(Diagnostics.IndependentUnitCount >= 3, 'XZ block-size encode should produce multiple blocks');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'Delphi XZ block-size decode fallback');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeUsesIndependentBlocks;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Blocks[0] := RepeatingBytes(65536);
  Blocks[1] := BytesOfSize(98304);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], BuildOptions, Records[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], BuildOptions, Records[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'MT XZ independent blocks');
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'XZ MT decode should use independent blocks');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested XZ decode threads');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'XZ independent block count');
    Assert.IsTrue(Diagnostics.ActualThreadCount >= 2, 'XZ MT decode should use more than one worker');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'XZ MT decode fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeDoesNotReadAllPayloadsBeforeFirstOutput;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..7] of TBytes;
  Records: array[0..7] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TReadBeforeOutputProbeStream;
  Dst: TOutputStartedProbeWriteStream;
  Diagnostics: TLzma2DecodeDiagnostics;
  OutputStarted: Integer;
  I: Integer;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  SetLength(Expected, 0);
  for I := 0 to High(Blocks) do
  begin
    Blocks[I] := BytesOfSize(48 * 1024 + I * 257);
    AppendBytes(Archive, BuildTestXzBlock(Blocks[I], BuildOptions, Records[I]));
    AppendBytes(Expected, Blocks[I]);
  end;
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  OutputStarted := 0;
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 2;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TReadBeforeOutputProbeStream.Create(Archive, @OutputStarted);
  Dst := TOutputStartedProbeWriteStream.Create(@OutputStarted);
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'streamed XZ MT payload decode');
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'streamed XZ fixture should use MT decode');
    Assert.IsFalse(Diagnostics.InputSnapshot, 'streamed XZ fixture should not report an input snapshot');
    Assert.IsTrue(Src.ReadBeforeOutput < UInt64(Length(Archive)) * 3 div 5,
      Format('XZ MT decode read too much input before first output: read=%d archive=%d',
        [Src.ReadBeforeOutput, Length(Archive)]));
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeWriteFailurePropagatesAndPreservesDiagnostics;
var
  Archive: TBytes;
  Blocks: array[0..1] of TBytes;
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Diagnostics: TLzma2DecodeDiagnostics;
  Dst: TWriteFailStream;
  Records: array[0..1] of TXzTestIndexRecord;
  Src: TBytesStream;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Blocks[0] := RepeatingBytes(65536);
  Blocks[1] := BytesOfSize(98304);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], BuildOptions, Records[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], BuildOptions, Records[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TWriteFailStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, DecodeOptions);
      end,
      ELzmaWriteError);
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'XZ MT decode diagnostics should survive caller write failure');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested XZ write-failure decode threads');
    Assert.IsTrue(Diagnostics.ActualThreadCount >= 2, 'XZ write-failure decode should use workers');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'XZ write-failure independent block count');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'XZ write-failure fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeUsesIndexPackedSizeWhenHeaderOmitsIt;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], BuildOptions, Records[0], False));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], BuildOptions, Records[1], False));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'XZ MT decode should recover PackedBytes sizes from Index');
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'XZ MT decode should use Index PackedBytes sizes');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested XZ Index PackedBytes-size threads');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'XZ Index PackedBytes-size block count');
    Assert.IsTrue(Diagnostics.ActualThreadCount >= 2, 'XZ Index PackedBytes-size decode should use workers');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'XZ Index PackedBytes-size fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeUsesIndexUnpackedSizeWhenHeaderOmitsIt;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], BuildOptions, Records[0], True, -1, False));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], BuildOptions, Records[1], True, -1, False));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'XZ MT decode should recover unpacked sizes from Index');
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'XZ MT decode should use Index unpacked sizes');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested XZ Index unpacked-size threads');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'XZ Index unpacked-size block count');
    Assert.IsTrue(Diagnostics.ActualThreadCount >= 2, 'XZ Index unpacked-size decode should use workers');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'XZ Index unpacked-size fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutPackedSize;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Records: array[0..0] of TXzTestIndexRecord;
  Archive: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Data := RepeatingBytes(65536);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Data, BuildOptions, Records[0], False));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'single XZ block without header PackedBytes size fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread, 'single Index-sized XZ block should fall back to ST decode');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested XZ single-block fallback threads');
    Assert.AreEqual(1, Diagnostics.ActualThreadCount, 'XZ single-block fallback actual thread count');
    Assert.AreEqual(1, Diagnostics.IndependentUnitCount, 'single XZ block unit count');
    Assert.AreEqual(ldfrSingleIndependentUnit, Diagnostics.FallbackReason, 'XZ single-block fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutUnpackedSize;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Records: array[0..0] of TXzTestIndexRecord;
  Archive: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 1 shl 20;

  Data := RepeatingBytes(65536);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Data, BuildOptions, Records[0], True, -1, False));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'single XZ block without header unpacked size fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread, 'single Index-sized XZ block should fall back to ST decode');
    Assert.AreEqual(4, Diagnostics.RequestedThreadCount, 'requested XZ single-block fallback threads');
    Assert.AreEqual(1, Diagnostics.ActualThreadCount, 'XZ single-block fallback actual thread count');
    Assert.AreEqual(1, Diagnostics.IndependentUnitCount, 'single XZ block unit count');
    Assert.AreEqual(ldfrSingleIndependentUnit, Diagnostics.FallbackReason, 'XZ single-block fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeFallsBackWhenOutputExceedsMemoryLimit;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 4096;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], BuildOptions, Records[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], BuildOptions, Records[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.MemoryLimit := 200000;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'XZ MT decode memory fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread, 'XZ MT decode should fall back before output buffering over memory limit');
    Assert.AreEqual(1, Diagnostics.ActualThreadCount, 'XZ memory fallback actual thread count');
    Assert.AreEqual(2, Diagnostics.IndependentUnitCount, 'XZ memory fallback unit count');
    Assert.AreEqual(ldfrMemoryLimit, Diagnostics.FallbackReason, 'XZ memory fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeChecksMemoryLimitBeforePayloadSnapshot;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TProbeBoundReadStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 4096;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], BuildOptions, Records[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], BuildOptions, Records[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.MemoryLimit := 200000;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TProbeBoundReadStream.Create(Archive, 4096);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'XZ MT decode memory preflight fallback');
    Assert.IsFalse(Diagnostics.UsedMultiThread, 'XZ MT memory preflight should fall back before scheduling');
    Assert.AreEqual(ldfrMemoryLimit, Diagnostics.FallbackReason, 'XZ MT memory preflight fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzMtDecodeUsesNonzeroMemoryLimit;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks: array[0..1] of TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.ThreadCount := 1;
  BuildOptions.DictionarySize := 4096;

  Blocks[0] := RepeatingBytes(70000);
  Blocks[1] := BytesOfSize(90000);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[0], BuildOptions, Records[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks[1], BuildOptions, Records[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));
  SetLength(Expected, 0);
  AppendBytes(Expected, Blocks[0]);
  AppendBytes(Expected, Blocks[1]);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := BuildOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.MemoryLimit := 16 * 1024 * 1024;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'XZ MT decode with nonzero memory limit');
    Assert.IsTrue(Diagnostics.UsedMultiThread, 'XZ MT decode should still use workers under a sufficient memory limit');
    Assert.AreEqual(ldfrNone, Diagnostics.FallbackReason, 'XZ MT nonzero memory-limit fallback reason');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzBlockWithoutPackedSizeDecodes;
var
  Options: TLzma2Options;
  Data: TBytes;
  Records: array[0..0] of TXzTestIndexRecord;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  OutBytes: TBytes;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc32;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Data := RepeatingBytes(65536);
  Archive := BuildTestXzHeader(XzCheckId(Options.Check));
  AppendBytes(Archive, BuildTestXzBlock(Data, Options, Records[0], False));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(Options.Check)));

  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, Options);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'XZ block without PackedBytes size');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzPackedBlockRejectsRawTrailingBytes;
var
  Options: TLzma2Options;
  Data: TBytes;
  Records: array[0..0] of TXzTestIndexRecord;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc64;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Data := BytesOfSize(32768);
  Archive := BuildTestXzHeader(XzCheckId(Options.Check));
  AppendBytes(Archive, BuildTestXzBlock(Data, Options, Records[0], True, $A5));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(Options.Check)));

  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzDecodeAvoidsFullArchiveMemoryLimit;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Records: array[0..0] of TXzTestIndexRecord;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  OutBytes: TBytes;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.DictionarySize := 1 shl 20;

  Data := BytesOfSize((2 shl 20) + 16384);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Data, BuildOptions, Records[0]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));

  DecodeOptions := BuildOptions;
  DecodeOptions.MemoryLimit := DecodeOptions.DictionarySize;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, DecodeOptions);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'XZ decode memory-limit streaming');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzEncodeAvoidsFullSourceMemoryLimit;
var
  Options: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc64;
  Options.Level := 0;
  Options.DictionarySize := 1 shl 20;
  Options.MemoryLimit := Options.DictionarySize;
  Data := BytesOfSize((2 shl 20) + 32768);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);

    DecodeOptions := Options;
    Encoded.Position := 0;
    TLzma2.Decompress(Encoded, Decoded, DecodeOptions);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'XZ encode memory-limit streaming');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzDecodeRejectsDictionaryOverMemoryLimit;
var
  BuildOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Data: TBytes;
  Records: array[0..0] of TXzTestIndexRecord;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  BuildOptions := TLzma2.DefaultOptions;
  BuildOptions.Container := lcXz;
  BuildOptions.Check := lzCheckCrc32;
  BuildOptions.Level := 0;
  BuildOptions.DictionarySize := 1 shl 20;

  Data := BytesOfSize(65536);
  Archive := BuildTestXzHeader(XzCheckId(BuildOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Data, BuildOptions, Records[0]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(BuildOptions.Check)));

  DecodeOptions := BuildOptions;
  DecodeOptions.MemoryLimit := DecodeOptions.DictionarySize - 1;
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, DecodeOptions);
      end,
      ELzmaMemoryError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzDecodeRejectsMaxDictionaryPropertyOverMemoryLimit;
var
  Options: TLzma2Options;
  Archive: TBytes;
  Block: TBytes;
  Header: TBytes;
  Raw: TBytes;
  Digest: TBytes;
  Records: array[0..0] of TXzTestIndexRecord;
  Src: TBytesStream;
  Dst: TMemoryStream;
  CheckId: Byte;
  Crc: UInt32;
  PayloadSize: UInt64;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckNone;
  Options.MemoryLimit := UInt64(512) shl 20;

  CheckId := XzCheckId(Options.Check);
  Raw := TBytes.Create(LZMA2_CONTROL_EOF);
  PayloadSize := UInt64(Length(Raw));

  SetLength(Header, 0);
  AppendByte(Header, 0);
  AppendByte(Header, XZ_BF_PACK_SIZE or XZ_BF_UNPACK_SIZE);
  AppendBytes(Header, XzWriteVarInt(PayloadSize));
  AppendBytes(Header, XzWriteVarInt(0));
  AppendBytes(Header, XzWriteVarInt(XZ_ID_LZMA2));
  AppendBytes(Header, XzWriteVarInt(1));
  AppendByte(Header, LZMA2_DIC_PROP_MAX);
  AppendZeroes(Header, XzPadSize(Length(Header)));
  Header[0] := Byte(Length(Header) div 4);
  Crc := Crc32Calc(Header);
  AppendByte(Header, Byte(Crc));
  AppendByte(Header, Byte(Crc shr 8));
  AppendByte(Header, Byte(Crc shr 16));
  AppendByte(Header, Byte(Crc shr 24));

  Digest := CheckDigest(CheckId, nil);
  Block := Header;
  AppendBytes(Block, Raw);
  AppendZeroes(Block, XzPadSize(PayloadSize));
  AppendBytes(Block, Digest);

  Records[0].UnpaddedSize := UInt64(Length(Header)) + PayloadSize + UInt64(Length(Digest));
  Records[0].UnpackSize := 0;
  Archive := BuildTestXzHeader(CheckId);
  AppendBytes(Archive, Block);
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, CheckId));

  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaMemoryError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzDecodeCancellation;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 0;
  Options.DictionarySize := 1 shl 20;
  Data := BytesOfSize(200000);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Encoded.Position := 0;

    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(
          Encoded,
          Decoded,
          Options,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Cancel := OutBytes > 0;
          end);
      end,
      ELzmaCancelled);
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzConcatenatedStreamsDecode;
var
  Options: TLzma2Options;
  Data1: TBytes;
  Data2: TBytes;
  Blocks1: array[0..1] of TBytes;
  Records1: array[0..1] of TXzTestIndexRecord;
  Records2: array[0..0] of TXzTestIndexRecord;
  Expected: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 0;
  Options.Check := lzCheckCrc64;
  Options.ThreadCount := 4;
  Options.DictionarySize := 1 shl 20;

  Blocks1[0] := RepeatingBytes(4096);
  Blocks1[1] := BytesOfSize(6144);
  SetLength(Data1, 0);
  AppendBytes(Data1, Blocks1[0]);
  AppendBytes(Data1, Blocks1[1]);
  Data2 := BytesOfSize(8192);

  Archive := BuildTestXzHeader(XzCheckId(Options.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks1[0], Options, Records1[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks1[1], Options, Records1[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records1, XzCheckId(Options.Check)));
  AppendZeroes(Archive, 4);
  AppendBytes(Archive, BuildTestXzHeader(XzCheckId(Options.Check)));
  AppendBytes(Archive, BuildTestXzBlock(Data2, Options, Records2[0]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records2, XzCheckId(Options.Check)));

  SetLength(Expected, 0);
  AppendBytes(Expected, Data1);
  AppendBytes(Expected, Data2);

  Src := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'concatenated XZ streams');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzConcatenatedStreamsWithMixedChecksFallBackFromMt;
var
  FirstOptions: TLzma2Options;
  SecondOptions: TLzma2Options;
  DecodeOptions: TLzma2Options;
  Blocks1: array[0..1] of TBytes;
  Data1: TBytes;
  Data2: TBytes;
  Records1: array[0..1] of TXzTestIndexRecord;
  Records2: array[0..0] of TXzTestIndexRecord;
  Expected: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
  Diagnostics: TLzma2DecodeDiagnostics;
begin
  FirstOptions := TLzma2.DefaultOptions;
  FirstOptions.Container := lcXz;
  FirstOptions.Level := 0;
  FirstOptions.Check := lzCheckCrc32;
  FirstOptions.ThreadCount := 1;
  FirstOptions.DictionarySize := 1 shl 20;

  SecondOptions := FirstOptions;
  SecondOptions.Check := lzCheckCrc64;

  Blocks1[0] := RepeatingBytes(65536);
  Blocks1[1] := BytesOfSize(98304);
  SetLength(Data1, 0);
  AppendBytes(Data1, Blocks1[0]);
  AppendBytes(Data1, Blocks1[1]);
  Data2 := BytesOfSize(32768);

  Archive := BuildTestXzHeader(XzCheckId(FirstOptions.Check));
  AppendBytes(Archive, BuildTestXzBlock(Blocks1[0], FirstOptions, Records1[0]));
  AppendBytes(Archive, BuildTestXzBlock(Blocks1[1], FirstOptions, Records1[1]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records1, XzCheckId(FirstOptions.Check)));
  AppendZeroes(Archive, 4);
  AppendBytes(Archive, BuildTestXzHeader(XzCheckId(SecondOptions.Check)));
  AppendBytes(Archive, BuildTestXzBlock(Data2, SecondOptions, Records2[0]));
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records2, XzCheckId(SecondOptions.Check)));

  SetLength(Expected, 0);
  AppendBytes(Expected, Data1);
  AppendBytes(Expected, Data2);

  FillChar(Diagnostics, SizeOf(Diagnostics), 0);
  DecodeOptions := FirstOptions;
  DecodeOptions.ThreadCount := 4;
  DecodeOptions.DecodeDiagnostics := @Diagnostics;
  Src := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, DecodeOptions);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Expected, OutBytes, 'concatenated XZ streams with mixed checks');
    Assert.IsFalse(Diagnostics.UsedMultiThread,
      'mixed-check concatenated XZ stream should fall back from MT preflight');
    Assert.AreEqual(ldfrUnsupportedLayout, Diagnostics.FallbackReason,
      'mixed-check concatenated XZ MT fallback reason');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzStreamPaddingDecodes;
var
  Options: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 0;
  Data := BytesOfSize(4096);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    if Encoded.Size > 0 then
    begin
      Encoded.Position := 0;
      Encoded.ReadBuffer(Archive[0], Encoded.Size);
    end;
  finally
    Encoded.Free;
    Src.Free;
  end;
  AppendZeroes(Archive, 4);

  Src := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'XZ stream padding');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzStreamPaddingCancellation;
var
  Options: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  CancelAt: UInt64;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 0;
  Data := BytesOfSize(4096);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    if Encoded.Size > 0 then
    begin
      Encoded.Position := 0;
      Encoded.ReadBuffer(Archive[0], Encoded.Size);
    end;
  finally
    Encoded.Free;
    Src.Free;
  end;

  CancelAt := UInt64(Length(Archive)) + 4096;
  AppendZeroes(Archive, 8192);
  Src := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(
          Src,
          Decoded,
          Options,
          procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
          begin
            Cancel := InBytes >= CancelAt;
          end);
      end,
      ELzmaCancelled);
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzBadStreamPaddingFails;
var
  Options: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 0;
  Data := BytesOfSize(4096);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size);
    if Encoded.Size > 0 then
    begin
      Encoded.Position := 0;
      Encoded.ReadBuffer(Archive[0], Encoded.Size);
    end;
  finally
    Encoded.Free;
    Src.Free;
  end;
  AppendZeroes(Archive, 2);

  Src := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Decoded, Options);
      end,
      ELzmaDataError);
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CorruptedSecondXzBlockCheckFails;
var
  Options: TLzma2Options;
  Data: TBytes;
  Block: TBytes;
  Records: array[0..1] of TXzTestIndexRecord;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc64;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;

  Archive := BuildTestXzHeader(XzCheckId(Options.Check));
  Data := RepeatingBytes(32768);
  AppendBytes(Archive, BuildTestXzBlock(Data, Options, Records[0]));

  Data := BytesOfSize(49152);
  Block := BuildTestXzBlock(Data, Options, Records[1]);
  Block[High(Block)] := Block[High(Block)] xor $55;
  AppendBytes(Archive, Block);
  AppendBytes(Archive, BuildTestXzIndexAndFooter(Records, XzCheckId(Options.Check)));

  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaChecksumError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CorruptedXzCheckFails;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  P: PByte;
  FooterOffset: NativeUInt;
  IndexSize: NativeUInt;
  CheckSize: NativeUInt;
  DigestOffset: NativeUInt;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Check := lzCheckCrc64;
  Options.Level := 0;
  Data := BytesOfSize(4096);
  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    FooterOffset := NativeUInt(Encoded.Size) - XZ_STREAM_FOOTER_SIZE;
    P := PByte(NativeUInt(Encoded.Memory) + FooterOffset + 4);
    IndexSize := NativeUInt(ReadUi32LE(P) + 1) * 4;
    CheckSize := XzCheckSizeById(XzCheckId(Options.Check));
    DigestOffset := FooterOffset - IndexSize - CheckSize;
    P := PByte(NativeUInt(Encoded.Memory) + DigestOffset);
    P^ := P^ xor $55;
    Encoded.Position := 0;
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Encoded, Decoded, Options);
      end,
      ELzmaChecksumError);
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.XzTruncatedFooterFails;
var
  Options: TLzma2Options;
  Data: TBytes;
  Archive: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 0;
  Data := BytesOfSize(4096);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    SetLength(Archive, Encoded.Size - 1);
    Encoded.Position := 0;
    Encoded.ReadBuffer(Archive[0], Length(Archive));
  finally
    Encoded.Free;
    Src.Free;
  end;

  Src := TBytesStream.Create(Archive);
  Decoded := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Decoded, Options);
      end,
      ELzmaInputEof);
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CorruptXzRegressionFixturesFailWithExpectedErrors;
var
  Options: TLzma2Options;
  ManifestPath: string;
  ManifestText: string;
  ManifestValue: TJSONValue;
  Manifest: TJSONObject;
  Cases: TJSONArray;
  CaseValue: TJSONValue;
  CaseObject: TJSONObject;
  RelativePath: string;
  FixturePath: string;
  ExpectedErrorName: string;
  ExpectedErrorClass: ExceptClass;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  SawTruncatedFooter: Boolean;
  SawCorruptCheck: Boolean;

  function RequiredJsonString(const JsonObject: TJSONObject; const FieldName: string): string;
  var
    Value: TJSONValue;
  begin
    Value := JsonObject.GetValue(FieldName);
    Assert.IsNotNull(Value, 'corrupt XZ manifest case is missing ' + FieldName);
    Result := Value.Value;
    Assert.IsTrue(Result <> '', 'corrupt XZ manifest case has empty ' + FieldName);
  end;

  function ErrorClassForName(const ErrorName: string): ExceptClass;
  begin
    if SameText(ErrorName, 'ELzmaInputEof') then
      Exit(ELzmaInputEof);
    if SameText(ErrorName, 'ELzmaChecksumError') then
      Exit(ELzmaChecksumError);
    raise Exception.Create('Unsupported corrupt XZ expectedError: ' + ErrorName);
  end;

begin
  ManifestPath := TPath.Combine(GetCurrentDir, 'tests\fixtures\manifests\corrupt-xz-regressions.json');
  Assert.IsTrue(TFile.Exists(ManifestPath), 'corrupt XZ regression manifest is missing');

  ManifestText := TFile.ReadAllText(ManifestPath, TEncoding.UTF8);
  ManifestValue := TJSONObject.ParseJSONValue(ManifestText);
  try
    Assert.IsNotNull(ManifestValue, 'corrupt XZ regression manifest is not valid JSON');
    Assert.IsTrue(ManifestValue is TJSONObject, 'corrupt XZ regression manifest must be a JSON object');
    Manifest := TJSONObject(ManifestValue);
    Cases := Manifest.GetValue('cases') as TJSONArray;
    Assert.IsNotNull(Cases, 'corrupt XZ regression manifest is missing cases');
    Assert.IsTrue(Cases.Count >= 2, 'corrupt XZ regression manifest must include footer and checksum cases');

    Options := TLzma2.DefaultOptions;
    Options.Container := lcXz;
    SawTruncatedFooter := False;
    SawCorruptCheck := False;

    for CaseValue in Cases do
    begin
      Assert.IsTrue(CaseValue is TJSONObject, 'corrupt XZ manifest case must be a JSON object');
      CaseObject := TJSONObject(CaseValue);
      RelativePath := RequiredJsonString(CaseObject, 'fixturePath');
      ExpectedErrorName := RequiredJsonString(CaseObject, 'expectedError');
      ExpectedErrorClass := ErrorClassForName(ExpectedErrorName);
      if SameText(RelativePath, 'tests/fixtures/corrupt/sevenzip-smoke-truncated-footer.xz') then
      begin
        Assert.AreEqual('ELzmaInputEof', ExpectedErrorName, 'truncated-footer regression must expect input EOF');
        SawTruncatedFooter := True;
      end
      else if SameText(RelativePath, 'tests/fixtures/corrupt/sevenzip-smoke-corrupt-check.xz') then
      begin
        Assert.AreEqual('ELzmaChecksumError', ExpectedErrorName, 'corrupt-check regression must expect checksum failure');
        SawCorruptCheck := True;
      end;

      FixturePath := TPath.Combine(GetCurrentDir, StringReplace(RelativePath, '/', PathDelim, [rfReplaceAll]));
      Assert.IsTrue(TFile.Exists(FixturePath), 'corrupt XZ fixture is missing: ' + RelativePath);
      Archive := TFile.ReadAllBytes(FixturePath);
      Src := TBytesStream.Create(Archive);
      Dst := TMemoryStream.Create;
      try
        Assert.WillRaise(
          procedure
          begin
            TLzma2.Decompress(Src, Dst, Options);
          end,
          ExpectedErrorClass);
      finally
        Dst.Free;
        Src.Free;
      end;
    end;
    Assert.IsTrue(SawTruncatedFooter, 'corrupt XZ regression manifest is missing truncated-footer fixture case');
    Assert.IsTrue(SawCorruptCheck, 'corrupt XZ regression manifest is missing corrupt-check fixture case');
  finally
    ManifestValue.Free;
  end;
end;

procedure TLzma2NativeTests.XzWriteFailurePropagates;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  FailingDst: TWriteFailStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 0;
  Data := BytesOfSize(4096);

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
  finally
    Src.Free;
  end;

  Encoded.Position := 0;
  FailingDst := TWriteFailStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Encoded, FailingDst, Options);
      end,
      ELzmaWriteError);
  finally
    FailingDst.Free;
    Encoded.Free;
  end;
end;

procedure TLzma2NativeTests.XzUnsupportedCheckFails;
var
  Options: TLzma2Options;
  Archive: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Archive := BuildTestXzHeader(15);
  Src := TBytesStream.Create(Archive);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaUnsupportedProperties);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.RawTrailingBytesFail;
var
  Options: TLzma2Options;
  Raw: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Raw := TBytes.Create(0, $AA);
  Src := TBytesStream.Create(Raw);
  Dst := TMemoryStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2.Decompress(Src, Dst, Options);
      end,
      ELzmaDataError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.SevenZipCompressedXzDecodes;
var
  Options: TLzma2Options;
  RawXz: TBytes;
  Expected: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  RawXz := TBytes.Create(
    $FD, $37, $7A, $58, $5A, $00, $00, $01, $69, $22, $DE, $36, $02, $00, $21, $01,
    $00, $00, $00, $00, $37, $27, $97, $D6, $E0, $00, $4A, $00, $3F, $5D, $00, $77,
    $AE, $D3, $E4, $9C, $D0, $8C, $F5, $2A, $33, $88, $A8, $0C, $21, $72, $DE, $AD,
    $6D, $FB, $EC, $97, $5C, $86, $0E, $C9, $BF, $E7, $5E, $08, $7F, $5A, $C1, $0D,
    $6F, $72, $9D, $D4, $30, $2C, $60, $3A, $26, $D8, $F3, $08, $61, $0F, $95, $C1,
    $DF, $B0, $5A, $16, $07, $A7, $63, $6F, $73, $05, $34, $30, $00, $00, $00, $00,
    $20, $4A, $88, $40, $00, $01, $57, $4B, $A0, $E6, $72, $34, $90, $42, $99, $0D,
    $01, $00, $00, $00, $00, $01, $59, $5A);
  Expected := TBytes.Create(
    $EF, $BB, $BF, $4C, $5A, $4D, $41, $32, $20, $44, $65, $6C, $70, $68, $69, $20,
    $6E, $61, $74, $69, $76, $65, $20, $73, $6D, $6F, $6B, $65, $20, $73, $61, $6D,
    $70, $6C, $65, $20, $30, $31, $32, $33, $34, $35, $36, $37, $38, $39, $20, $72,
    $65, $70, $65, $61, $74, $65, $64, $20, $72, $65, $70, $65, $61, $74, $65, $64,
    $20, $72, $65, $70, $65, $61, $74, $65, $64, $0D, $0A);
  Src := TBytesStream.Create(RawXz);
  Dst := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Dst, Options);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Expected), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Expected[0], @OutBytes[0], Length(Expected)), 'decoded bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.FixtureManifestsHaveSha256Metadata;
var
  ManifestDir: string;
  Files: TArray<string>;
  FileName: string;
  Text: string;
  SourceHash: string;
  CompressedHash: string;

  function ExtractJsonString(const FieldName: string; var SearchFrom: Integer): string;
  var
    Key: string;
    StartPos: Integer;
    ColonPos: Integer;
    EndPos: Integer;
  begin
    Result := '';
    Key := '"' + FieldName + '"';
    StartPos := PosEx(Key, Text, SearchFrom);
    if StartPos = 0 then
      Exit;
    ColonPos := PosEx(':', Text, StartPos + Length(Key));
    if ColonPos = 0 then
      Exit;
    StartPos := PosEx('"', Text, ColonPos + 1);
    if StartPos = 0 then
      Exit;
    Inc(StartPos);
    EndPos := PosEx('"', Text, StartPos);
    if EndPos = 0 then
      Exit;
    Result := Copy(Text, StartPos, EndPos - StartPos);
    SearchFrom := EndPos + 1;
  end;

  function ExtractFirstJsonString(const FieldName: string): string;
  var
    SearchFrom: Integer;
  begin
    SearchFrom := 1;
    Result := ExtractJsonString(FieldName, SearchFrom);
  end;

  function FileSha256Hex(const FilePath: string): string;
  var
    Digest: TBytes;
    B: Byte;
  begin
    Result := '';
    Digest := Sha256Calc(TFile.ReadAllBytes(FilePath));
    for B in Digest do
      Result := Result + IntToHex(B, 2);
    Result := LowerCase(Result);
  end;

  procedure AssertManifestPathHashes(const PathFieldName, HashFieldName: string);
  var
    PathSearchFrom: Integer;
    HashSearchFrom: Integer;
    RelativePath: string;
    ExpectedHash: string;
    FullPath: string;
  begin
    PathSearchFrom := 1;
    HashSearchFrom := 1;
    while True do
    begin
      RelativePath := ExtractJsonString(PathFieldName, PathSearchFrom);
      if RelativePath = '' then
        Break;
      ExpectedHash := LowerCase(ExtractJsonString(HashFieldName, HashSearchFrom));
      Assert.AreEqual(64, Length(ExpectedHash), FileName + ' ' + HashFieldName + ' must be hex-encoded');
      FullPath := TPath.Combine(GetCurrentDir, StringReplace(RelativePath, '/', PathDelim, [rfReplaceAll]));
      Assert.IsTrue(TFile.Exists(FullPath), FileName + ' references missing fixture ' + RelativePath);
      Assert.AreEqual(ExpectedHash, FileSha256Hex(FullPath), FileName + ' hash mismatch for ' + RelativePath);
    end;
  end;

begin
  ManifestDir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests\fixtures\manifests';
  Assert.IsTrue(TDirectory.Exists(ManifestDir), 'fixture manifest directory is missing');
  Files := TDirectory.GetFiles(ManifestDir, '*.json');
  Assert.IsTrue(Length(Files) > 0, 'fixture manifest directory is empty');

  for FileName in Files do
  begin
    Text := TFile.ReadAllText(FileName, TEncoding.UTF8);
    Assert.IsTrue(Pos('"tool"', Text) > 0, FileName + ' is missing tool metadata');
    Assert.IsTrue(Pos('"commandLine"', Text) > 0, FileName + ' is missing generation metadata');
    Assert.IsTrue(Pos('"container"', Text) > 0, FileName + ' is missing container metadata');
    Assert.IsTrue(Pos('"method"', Text) > 0, FileName + ' is missing method metadata');
    SourceHash := ExtractFirstJsonString('sourceSha256');
    CompressedHash := ExtractFirstJsonString('compressedSha256');
    if SourceHash <> '' then
      Assert.AreEqual(64, Length(SourceHash), FileName + ' source SHA-256 must be hex-encoded');
    if CompressedHash <> '' then
      Assert.AreEqual(64, Length(CompressedHash), FileName + ' compressed SHA-256 must be hex-encoded');
    AssertManifestPathHashes('sourcePath', 'sourceSha256');
    AssertManifestPathHashes('compressedPath', 'compressedSha256');
    AssertManifestPathHashes('basePath', 'baseSha256');
    AssertManifestPathHashes('fixturePath', 'fixtureSha256');
  end;
end;

procedure TLzma2NativeTests.RawLzmaSdkCorpusFixturesDecode;
var
  RawDir: string;
  SourceDir: string;
  Files: TArray<string>;
  ArchivePath: string;
  SourcePath: string;
  Archive: TBytes;
  Expected: TBytes;
  Props: TBytes;
  PackedBytes: TBytes;
  UnpackSize: UInt64;
  Src: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  RawDir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests\fixtures\raw';
  SourceDir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'tests\fixtures\sources';
  Files := TDirectory.GetFiles(RawDir, 'raw-lzma-sdk-corpus-*.lzma');
  if Length(Files) = 0 then
  begin
    Writeln('SKIP RawLzmaSdkCorpusFixturesDecode: set LZMA_TEST_LZMA before generate-fixtures.ps1 to enable corpus fixtures.');
    Exit;
  end;

  for ArchivePath in Files do
  begin
    SourcePath := TPath.Combine(SourceDir, TPath.GetFileNameWithoutExtension(ArchivePath) + '-source.bin');
    Assert.IsTrue(TFile.Exists(SourcePath), 'missing source fixture for ' + ArchivePath);

    Archive := TFile.ReadAllBytes(ArchivePath);
    Expected := TFile.ReadAllBytes(SourcePath);
    Assert.IsTrue(Length(Archive) > LZMA_PROPS_SIZE + 8, 'SDK corpus LZMA fixture is too small: ' + ArchivePath);
    Props := Copy(Archive, 0, LZMA_PROPS_SIZE);
    UnpackSize := ReadUi64LE(@Archive[LZMA_PROPS_SIZE]);
    Assert.AreEqual(UInt64(Length(Expected)), UnpackSize, 'SDK corpus unpack size mismatch');
    PackedBytes := Copy(Archive, LZMA_PROPS_SIZE + 8, Length(Archive) - LZMA_PROPS_SIZE - 8);

    Src := TBytesStream.Create(PackedBytes);
    Decoded := TMemoryStream.Create;
    try
      TLzmaRawDecoder.Decode(Src, Decoded, Props, UnpackSize);
      SetLength(OutBytes, Decoded.Size);
      if Decoded.Size > 0 then
      begin
        Decoded.Position := 0;
        Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
      end;
      AssertBytesEqual(Expected, OutBytes, 'SDK raw LZMA corpus decoded by Delphi: ' + ArchivePath);
    finally
      Decoded.Free;
      Src.Free;
    end;
  end;
end;

procedure TLzma2NativeTests.RawLzmaSdkReleaseCorpusFixturesDecode;
var
  ManifestPath: string;
  ManifestText: string;
  ManifestValue: TJSONValue;
  Manifest: TJSONObject;
  Cases: TJSONArray;
  CaseValue: TJSONValue;
  CaseObject: TJSONObject;
  Name: string;
  CommandLine: string;
  SourcePath: string;
  ArchivePath: string;
  Archive: TBytes;
  Expected: TBytes;
  Props: TBytes;
  PackedBytes: TBytes;
  ManifestUnpackSize: UInt64;
  HeaderUnpackSize: UInt64;
  TotalUnpackSize: UInt64;
  MaxUnpackSize: UInt64;
  Src: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
  SawRepeat: Boolean;
  SawRandom: Boolean;
  SawText: Boolean;
  SawExe: Boolean;
  SawMixed: Boolean;
  SawA0: Boolean;
  SawA1: Boolean;
  SawD20: Boolean;
  SawD22: Boolean;
  SawFb32: Boolean;
  SawFb64: Boolean;

  function RequiredJsonString(const JsonObject: TJSONObject; const FieldName: string): string;
  var
    Value: TJSONValue;
  begin
    Value := JsonObject.GetValue(FieldName);
    Assert.IsNotNull(Value, 'raw LZMA release corpus case is missing ' + FieldName);
    Result := Value.Value;
    Assert.IsTrue(Result <> '', 'raw LZMA release corpus case has empty ' + FieldName);
  end;

  function RequiredJsonUInt64(const JsonObject: TJSONObject; const FieldName: string): UInt64;
  var
    Text: string;
  begin
    Text := RequiredJsonString(JsonObject, FieldName);
    Result := StrToUInt64(Text);
  end;

begin
  ManifestPath := TPath.Combine(GetCurrentDir, 'tests\fixtures\manifests\raw-lzma-sdk-release-corpus.json');
  if not TFile.Exists(ManifestPath) then
  begin
    Writeln('SKIP RawLzmaSdkReleaseCorpusFixturesDecode: run generate-fixtures.ps1 -ReleaseCorpus to enable release corpus fixtures.');
    Exit;
  end;

  ManifestText := TFile.ReadAllText(ManifestPath, TEncoding.UTF8);
  ManifestValue := TJSONObject.ParseJSONValue(ManifestText);
  try
    Assert.IsNotNull(ManifestValue, 'raw LZMA release corpus manifest is not valid JSON');
    Assert.IsTrue(ManifestValue is TJSONObject, 'raw LZMA release corpus manifest must be a JSON object');
    Manifest := TJSONObject(ManifestValue);
    Cases := Manifest.GetValue('cases') as TJSONArray;
    Assert.IsNotNull(Cases, 'raw LZMA release corpus manifest is missing cases');
    Assert.IsTrue(Cases.Count >= 5, 'raw LZMA release corpus must include at least five cases');

    TotalUnpackSize := 0;
    MaxUnpackSize := 0;
    SawRepeat := False;
    SawRandom := False;
    SawText := False;
    SawExe := False;
    SawMixed := False;
    SawA0 := False;
    SawA1 := False;
    SawD20 := False;
    SawD22 := False;
    SawFb32 := False;
    SawFb64 := False;

    for CaseValue in Cases do
    begin
      Assert.IsTrue(CaseValue is TJSONObject, 'raw LZMA release corpus case must be a JSON object');
      CaseObject := TJSONObject(CaseValue);
      Name := RequiredJsonString(CaseObject, 'name');
      CommandLine := RequiredJsonString(CaseObject, 'commandLine');
      SourcePath := TPath.Combine(GetCurrentDir,
        StringReplace(RequiredJsonString(CaseObject, 'sourcePath'), '/', PathDelim, [rfReplaceAll]));
      ArchivePath := TPath.Combine(GetCurrentDir,
        StringReplace(RequiredJsonString(CaseObject, 'compressedPath'), '/', PathDelim, [rfReplaceAll]));
      ManifestUnpackSize := RequiredJsonUInt64(CaseObject, 'unpackSize');

      Assert.IsTrue(TFile.Exists(SourcePath), 'missing raw LZMA release source fixture for ' + Name);
      Assert.IsTrue(TFile.Exists(ArchivePath), 'missing raw LZMA release compressed fixture for ' + Name);
      Archive := TFile.ReadAllBytes(ArchivePath);
      Expected := TFile.ReadAllBytes(SourcePath);
      Assert.AreEqual(UInt64(Length(Expected)), ManifestUnpackSize, 'manifest unpack size mismatch for ' + Name);
      Assert.IsTrue(Length(Archive) > LZMA_PROPS_SIZE + 8, 'SDK release LZMA fixture is too small: ' + Name);
      Props := Copy(Archive, 0, LZMA_PROPS_SIZE);
      HeaderUnpackSize := ReadUi64LE(@Archive[LZMA_PROPS_SIZE]);
      Assert.AreEqual(UInt64(Length(Expected)), HeaderUnpackSize, 'SDK release corpus unpack size mismatch for ' + Name);
      PackedBytes := Copy(Archive, LZMA_PROPS_SIZE + 8, Length(Archive) - LZMA_PROPS_SIZE - 8);

      Src := TBytesStream.Create(PackedBytes);
      Decoded := TMemoryStream.Create;
      try
        TLzmaRawDecoder.Decode(Src, Decoded, Props, HeaderUnpackSize);
        SetLength(OutBytes, Decoded.Size);
        if Decoded.Size > 0 then
        begin
          Decoded.Position := 0;
          Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
        end;
        AssertBytesEqual(Expected, OutBytes, 'SDK raw LZMA release corpus decoded by Delphi: ' + Name);
      finally
        Decoded.Free;
        Src.Free;
      end;

      TotalUnpackSize := TotalUnpackSize + UInt64(Length(Expected));
      if UInt64(Length(Expected)) > MaxUnpackSize then
        MaxUnpackSize := UInt64(Length(Expected));
      SawRepeat := SawRepeat or ContainsText(Name, 'repeat');
      SawRandom := SawRandom or ContainsText(Name, 'random');
      SawText := SawText or ContainsText(Name, 'text');
      SawExe := SawExe or ContainsText(Name, 'exe');
      SawMixed := SawMixed or ContainsText(Name, 'mixed');
      SawA0 := SawA0 or ContainsText(CommandLine, '-a0');
      SawA1 := SawA1 or ContainsText(CommandLine, '-a1');
      SawD20 := SawD20 or ContainsText(CommandLine, '-d20');
      SawD22 := SawD22 or ContainsText(CommandLine, '-d22');
      SawFb32 := SawFb32 or ContainsText(CommandLine, '-fb32');
      SawFb64 := SawFb64 or ContainsText(CommandLine, '-fb64');
    end;

    Assert.IsTrue(TotalUnpackSize >= 3145728, 'raw LZMA release corpus total unpack size remains smoke-sized');
    Assert.IsTrue(MaxUnpackSize >= 1048576, 'raw LZMA release corpus must include a 1 MiB-class case');
    Assert.IsTrue(SawRepeat, 'raw LZMA release corpus is missing repeat case');
    Assert.IsTrue(SawRandom, 'raw LZMA release corpus is missing random case');
    Assert.IsTrue(SawText, 'raw LZMA release corpus is missing text case');
    Assert.IsTrue(SawExe, 'raw LZMA release corpus is missing executable-like case');
    Assert.IsTrue(SawMixed, 'raw LZMA release corpus is missing mixed case');
    Assert.IsTrue(SawA0, 'raw LZMA release corpus is missing -a0 coverage');
    Assert.IsTrue(SawA1, 'raw LZMA release corpus is missing -a1 coverage');
    Assert.IsTrue(SawD20, 'raw LZMA release corpus is missing -d20 coverage');
    Assert.IsTrue(SawD22, 'raw LZMA release corpus is missing -d22 coverage');
    Assert.IsTrue(SawFb32, 'raw LZMA release corpus is missing -fb32 coverage');
    Assert.IsTrue(SawFb64, 'raw LZMA release corpus is missing -fb64 coverage');
  finally
    ManifestValue.Free;
  end;
end;

procedure TLzma2NativeTests.AsyncApiRoundTripsRaw;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
  Task: ITask;
begin
  Data := RepeatingBytes(100000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 2;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  try
    Task := TLzma2.CompressAsync(Src, Encoded, Options);
    Assert.IsTrue(Task.Wait(30000), 'async compression timed out');
    Assert.AreEqual(TTaskStatus.Completed, Task.Status, 'async compression task did not complete');

    Encoded.Position := 0;
    Task := TLzma2.DecompressAsync(Encoded, Decoded, Options);
    Assert.IsTrue(Task.Wait(30000), 'async decompression timed out');
    Assert.AreEqual(TTaskStatus.Completed, Task.Status, 'async decompression task did not complete');

    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.DecompressAsyncReturnsBeforeProgressCallbackCompletes;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  DecodedBytes: TBytes;
  CallbackEntered: TEvent;
  ReleaseCallback: TEvent;
  Task: ITask;
begin
  Data := RepeatingBytes(70000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 0;
  Options.ThreadCount := 1;

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  Decoded := TMemoryStream.Create;
  CallbackEntered := TEvent.Create(nil, True, False, '');
  ReleaseCallback := TEvent.Create(nil, True, False, '');
  try
    TLzma2.Compress(Src, Encoded, Options);
    Encoded.Position := 0;

    Task := TLzma2.DecompressAsync(
      Encoded,
      Decoded,
      Options,
      procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
      begin
        CallbackEntered.SetEvent;
        ReleaseCallback.WaitFor(30000);
      end);

    Assert.IsTrue(CallbackEntered.WaitFor(30000) = wrSignaled,
      'async decompression did not enter the background progress callback');
    Assert.IsTrue(Task.Status <> TTaskStatus.Completed,
      'DecompressAsync must return while the background decompression is still blocked in progress');
    Assert.IsTrue(Task.Status <> TTaskStatus.Exception, 'async decompression failed before release');

    ReleaseCallback.SetEvent;
    Assert.IsTrue(Task.Wait(30000), 'async decompression timed out after callback release');
    Assert.AreEqual(TTaskStatus.Completed, Task.Status, 'async decompression task did not complete');

    SetLength(DecodedBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(DecodedBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, DecodedBytes, 'async decompression output after blocked callback');
  finally
    ReleaseCallback.SetEvent;
    ReleaseCallback.Free;
    CallbackEntered.Free;
    Decoded.Free;
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CrossToolDelphiXzIsAcceptedBySevenZip;
const
  CaseSizes: array[0..1] of Integer = (65536, 200000);
  CaseThreads: array[0..1] of Integer = (1, 4);
var
  SevenZip: string;
  WorkDir: string;
  ArchivePath: string;
  Options: TLzma2Options;
  Data: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
  Decoded: TMemoryStream;
  I: Integer;
begin
  SevenZip := EnvToolPath('LZMA_TEST_7Z');
  if SevenZip = '' then
  begin
    SkipExternalTool('CrossToolDelphiXzIsAcceptedBySevenZip', 'LZMA_TEST_7Z');
    Exit;
  end;

  WorkDir := CrossToolDir;
  for I := Low(CaseSizes) to High(CaseSizes) do
  begin
    Data := RepeatingBytes(CaseSizes[I]);
    ArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-' + IntToStr(CaseSizes[I]) + '-' +
      IntToStr(CaseThreads[I]) + 't.xz';
    DeleteFileIfExists(ArchivePath);

    Options := TLzma2.DefaultOptions;
    Options.Container := lcXz;
    Options.Check := lzCheckCrc64;
    Options.Level := 1;
    Options.DictionarySize := 1 shl 20;
    Options.ThreadCount := CaseThreads[I];

    Src := TBytesStream.Create(Data);
    Encoded := TMemoryStream.Create;
    Decoded := TMemoryStream.Create;
    try
      TLzma2.Compress(Src, Encoded, Options);
      Encoded.Position := 0;
      Encoded.SaveToFile(ArchivePath);

      RunExternalProcessChecked(SevenZip, ['t', ArchivePath], WorkDir);

      Encoded.Position := 0;
      TLzma2.Decompress(Encoded, Decoded, Options);
      SetLength(OutBytes, Decoded.Size);
      if Decoded.Size > 0 then
      begin
        Decoded.Position := 0;
        Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
      end;
      AssertBytesEqual(Data, OutBytes, 'Delphi-generated XZ case ' + IntToStr(I));
    finally
      Decoded.Free;
      Encoded.Free;
      Src.Free;
    end;
  end;
end;

procedure TLzma2NativeTests.CrossToolDelphiSevenZipIsAcceptedBySevenZip;
var
  SevenZip: string;
  WorkDir: string;
  ArchivePath: string;
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Encoded: TMemoryStream;
begin
  SevenZip := EnvToolPath('LZMA_TEST_7Z');
  if SevenZip = '' then
  begin
    SkipExternalTool('CrossToolDelphiSevenZipIsAcceptedBySevenZip', 'LZMA_TEST_7Z');
    Exit;
  end;

  WorkDir := CrossToolDir;
  Data := RepeatingBytes(128 * 1024);
  ArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-single-file.7z';
  DeleteFileIfExists(ArchivePath);

  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ArchiveFileName := 'payload.bin';

  Src := TBytesStream.Create(Data);
  Encoded := TMemoryStream.Create;
  try
    TLzma2.Compress(Src, Encoded, Options);
    Encoded.Position := 0;
    Encoded.SaveToFile(ArchivePath);
    RunExternalProcessChecked(SevenZip, ['t', ArchivePath], WorkDir);
  finally
    Encoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CrossToolSevenZip7zDecodes;
var
  SevenZip: string;
  WorkDir: string;
  SourcePath: string;
  ArchivePath: string;
  LzmaArchivePath: string;
  EmptySourcePath: string;
  EmptyArchivePath: string;
  Options: TLzma2Options;
  Data: TBytes;
  OutBytes: TBytes;
  Src: TFileStream;
  Decoded: TMemoryStream;
begin
  SevenZip := EnvToolPath('LZMA_TEST_7Z');
  if SevenZip = '' then
  begin
    SkipExternalTool('CrossToolSevenZip7zDecodes', 'LZMA_TEST_7Z');
    Exit;
  end;

  WorkDir := CrossToolDir;
  SourcePath := IncludeTrailingPathDelimiter(WorkDir) + 'sevenzip-7z-source.bin';
  ArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'sevenzip-7z-source.7z';
  Data := RepeatingBytes(128 * 1024);
  WriteAllBytes(SourcePath, Data);
  DeleteFileIfExists(ArchivePath);

  RunExternalProcessChecked(SevenZip, ['a', '-t7z', '-mx=1', '-mmt=1', '-m0=LZMA2:d=1m',
    '-mhc=off', '-y', ArchivePath, SourcePath], WorkDir);

  Options := TLzma2.DefaultOptions;
  Options.Container := lc7z;
  Src := TFileStream.Create(ArchivePath, fmOpenRead or fmShareDenyWrite);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, '7-Zip-generated single-file 7z archive');
  finally
    Decoded.Free;
    Src.Free;
  end;

  LzmaArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'sevenzip-7z-lzma-source.7z';
  DeleteFileIfExists(LzmaArchivePath);
  RunExternalProcessChecked(SevenZip, ['a', '-t7z', '-mx=1', '-mmt=1', '-m0=LZMA:d=1m',
    '-mhc=off', '-y', LzmaArchivePath, SourcePath], WorkDir);

  Src := TFileStream.Create(LzmaArchivePath, fmOpenRead or fmShareDenyWrite);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, '7-Zip-generated single-file 7z LZMA archive');
  finally
    Decoded.Free;
    Src.Free;
  end;

  EmptySourcePath := IncludeTrailingPathDelimiter(WorkDir) + 'sevenzip-empty-source.bin';
  EmptyArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'sevenzip-empty-source.7z';
  SetLength(Data, 0);
  WriteAllBytes(EmptySourcePath, Data);
  DeleteFileIfExists(EmptyArchivePath);
  RunExternalProcessChecked(SevenZip, ['a', '-t7z', '-mx=1', '-mmt=1', '-m0=LZMA2:d=1m',
    '-mhc=off', '-y', EmptyArchivePath, EmptySourcePath], WorkDir);

  Src := TFileStream.Create(EmptyArchivePath, fmOpenRead or fmShareDenyWrite);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    Assert.AreEqual(Int64(0), Decoded.Size, '7-Zip-generated empty 7z file');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CrossToolSevenZipXzDecodes;
var
  SevenZip: string;
  WorkDir: string;
  SourcePath: string;
  ArchivePath: string;
  Options: TLzma2Options;
  Data: TBytes;
  OutBytes: TBytes;
  Src: TFileStream;
  Decoded: TMemoryStream;
begin
  SevenZip := EnvToolPath('LZMA_TEST_7Z');
  if SevenZip = '' then
  begin
    SkipExternalTool('CrossToolSevenZipXzDecodes', 'LZMA_TEST_7Z');
    Exit;
  end;

  WorkDir := CrossToolDir;
  SourcePath := IncludeTrailingPathDelimiter(WorkDir) + 'sevenzip-source.bin';
  ArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'sevenzip-source.xz';
  Data := RepeatingBytes(120000);
  WriteAllBytes(SourcePath, Data);
  DeleteFileIfExists(ArchivePath);

  RunExternalProcessChecked(SevenZip, ['a', '-txz', '-mx=1', '-y', ArchivePath, SourcePath], WorkDir);

  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Src := TFileStream.Create(ArchivePath, fmOpenRead or fmShareDenyWrite);
  Decoded := TMemoryStream.Create;
  try
    TLzma2.Decompress(Src, Decoded, Options);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, '7-Zip-generated XZ');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CrossToolXzUtilsMatrixDecodes;
const
  LevelArgs: array[0..5] of string = ('-0', '-1', '-3', '-5', '-7', '-9');
  CheckArgs: array[0..3] of string = ('none', 'crc32', 'crc64', 'sha256');
var
  Xz: string;
  WorkDir: string;
  SourcePath: string;
  ArchivePath: string;
  Options: TLzma2Options;
  Data: TBytes;
  OutBytes: TBytes;
  Src: TFileStream;
  Decoded: TMemoryStream;
  LevelIndex: Integer;
  CheckIndex: Integer;
begin
  Xz := EnvToolPath('LZMA_TEST_XZ');
  if Xz = '' then
  begin
    SkipExternalTool('CrossToolXzUtilsMatrixDecodes', 'LZMA_TEST_XZ');
    Exit;
  end;

  WorkDir := CrossToolDir;
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;

  for LevelIndex := Low(LevelArgs) to High(LevelArgs) do
  begin
    for CheckIndex := Low(CheckArgs) to High(CheckArgs) do
    begin
      Data := RepeatingBytes(32768 + LevelIndex * 4096 + CheckIndex * 1024);
      SourcePath := IncludeTrailingPathDelimiter(WorkDir) +
        'xz-utils-' + IntToStr(LevelIndex) + '-' + CheckArgs[CheckIndex] + '.bin';
      ArchivePath := SourcePath + '.xz';
      WriteAllBytes(SourcePath, Data);
      DeleteFileIfExists(ArchivePath);

      RunExternalProcessChecked(Xz, [LevelArgs[LevelIndex], '--check=' + CheckArgs[CheckIndex],
        '--block-size=16384', '-k', '-f', SourcePath], WorkDir);

      Src := TFileStream.Create(ArchivePath, fmOpenRead or fmShareDenyWrite);
      Decoded := TMemoryStream.Create;
      try
        TLzma2.Decompress(Src, Decoded, Options);
        SetLength(OutBytes, Decoded.Size);
        if Decoded.Size > 0 then
        begin
          Decoded.Position := 0;
          Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
        end;
        AssertBytesEqual(Data, OutBytes, 'xz-utils ' + LevelArgs[LevelIndex] + ' ' + CheckArgs[CheckIndex]);
      finally
        Decoded.Free;
        Src.Free;
      end;
    end;
  end;
end;

procedure TLzma2NativeTests.CrossToolSdkLzmaDecodesWithDelphi;
var
  LzmaExe: string;
  WorkDir: string;
  SourcePath: string;
  ArchivePath: string;
  Data: TBytes;
  Archive: TBytes;
  Props: TBytes;
  PackedBytes: TBytes;
  UnpackSize: UInt64;
  Src: TBytesStream;
  Decoded: TMemoryStream;
  OutBytes: TBytes;
begin
  LzmaExe := EnvToolPath('LZMA_TEST_LZMA');
  if LzmaExe = '' then
  begin
    SkipExternalTool('CrossToolSdkLzmaDecodesWithDelphi', 'LZMA_TEST_LZMA');
    Exit;
  end;

  WorkDir := CrossToolDir;
  SourcePath := IncludeTrailingPathDelimiter(WorkDir) + 'sdk-lzma-source.bin';
  ArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'sdk-lzma-source.lzma';
  Data := BytesOfSize(65536);
  WriteAllBytes(SourcePath, Data);
  DeleteFileIfExists(ArchivePath);

  RunExternalProcessChecked(LzmaExe, ['e', SourcePath, ArchivePath, '-a0', '-d20', '-fb32'], WorkDir);
  Archive := ReadAllBytesFromFile(ArchivePath);
  Assert.IsTrue(Length(Archive) > LZMA_PROPS_SIZE + 8, 'SDK LZMA fixture is too small');
  Props := Copy(Archive, 0, LZMA_PROPS_SIZE);
  UnpackSize := ReadUi64LE(@Archive[LZMA_PROPS_SIZE]);
  PackedBytes := Copy(Archive, LZMA_PROPS_SIZE + 8, Length(Archive) - LZMA_PROPS_SIZE - 8);

  Src := TBytesStream.Create(PackedBytes);
  Decoded := TMemoryStream.Create;
  try
    TLzmaRawDecoder.Decode(Src, Decoded, Props, UnpackSize);
    SetLength(OutBytes, Decoded.Size);
    if Decoded.Size > 0 then
    begin
      Decoded.Position := 0;
      Decoded.ReadBuffer(OutBytes[0], Decoded.Size);
    end;
    AssertBytesEqual(Data, OutBytes, 'SDK raw LZMA decoded by Delphi');
  finally
    Decoded.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.CrossToolDelphiRawLzmaDecodesWithSdk;
var
  LzmaExe: string;
  WorkDir: string;
  SourcePath: string;
  ArchivePath: string;
  DecodedPath: string;
  Data: TBytes;
  PropsBytes: TBytes;
  Raw: TMemoryStream;
  Standalone: TBytes;
  Src: TBytesStream;
  OutBytes: TBytes;
  Profile: TLzmaEncoderProfile;
  SizeBytes: TBytes;
begin
  LzmaExe := EnvToolPath('LZMA_TEST_LZMA');
  if LzmaExe = '' then
  begin
    SkipExternalTool('CrossToolDelphiRawLzmaDecodesWithSdk', 'LZMA_TEST_LZMA');
    Exit;
  end;

  WorkDir := CrossToolDir;
  SourcePath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-lzma-source.bin';
  ArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-lzma-source.lzma';
  DecodedPath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-lzma-source.out';
  Data := RepeatingBytes(32768);
  WriteAllBytes(SourcePath, Data);
  DeleteFileIfExists(ArchivePath);
  DeleteFileIfExists(DecodedPath);

  Profile := TLzmaRawEncoder.NormalizeProfile(1, 1 shl 20);
  PropsBytes := TLzmaRawEncoder.WriteProperties(TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize));
  Src := TBytesStream.Create(Data);
  Raw := TMemoryStream.Create;
  try
    TLzmaRawEncoder.Encode(Src, Raw, Profile);
    SetLength(Standalone, 0);
    AppendBytes(Standalone, PropsBytes);
    SetLength(SizeBytes, 8);
    WriteUi64LE(@SizeBytes[0], Length(Data));
    AppendBytes(Standalone, SizeBytes);
    SetLength(OutBytes, Raw.Size);
    if Raw.Size > 0 then
    begin
      Raw.Position := 0;
      Raw.ReadBuffer(OutBytes[0], Raw.Size);
    end;
    AppendBytes(Standalone, OutBytes);
  finally
    Raw.Free;
    Src.Free;
  end;

  WriteAllBytes(ArchivePath, Standalone);
  RunExternalProcessChecked(LzmaExe, ['d', ArchivePath, DecodedPath], WorkDir);
  OutBytes := ReadAllBytesFromFile(DecodedPath);
  AssertBytesEqual(Data, OutBytes, 'Delphi raw LZMA decoded by SDK');
end;

procedure TLzma2NativeTests.CrossToolDelphiRawLzmaEndMarkerDecodesWithSdk;
var
  LzmaExe: string;
  WorkDir: string;
  SourcePath: string;
  ArchivePath: string;
  DecodedPath: string;
  Data: TBytes;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  EncodedBytes: TBytes;
  Standalone: TBytes;
  OutBytes: TBytes;
  Profile: TLzmaEncoderProfile;
  SizeBytes: TBytes;
begin
  LzmaExe := EnvToolPath('LZMA_TEST_LZMA');
  if LzmaExe = '' then
  begin
    SkipExternalTool('CrossToolDelphiRawLzmaEndMarkerDecodesWithSdk', 'LZMA_TEST_LZMA');
    Exit;
  end;

  WorkDir := CrossToolDir;
  SourcePath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-lzma-endmark-source.bin';
  ArchivePath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-lzma-endmark-source.lzma';
  DecodedPath := IncludeTrailingPathDelimiter(WorkDir) + 'delphi-lzma-endmark-source.out';
  Data := RepeatingBytes(32768);
  WriteAllBytes(SourcePath, Data);
  DeleteFileIfExists(ArchivePath);
  DeleteFileIfExists(DecodedPath);

  Profile := TLzmaRawEncoder.NormalizeProfile(1, 1 shl 20);
  Props := TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize);
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  EncodedBytes := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props,
    Profile.FastBytes, Profile.CutValue, Profile.MatchFinderKind, True);

  SetLength(Standalone, 0);
  AppendBytes(Standalone, PropsBytes);
  SetLength(SizeBytes, 8);
  WriteUi64LE(@SizeBytes[0], UInt64($FFFFFFFFFFFFFFFF));
  AppendBytes(Standalone, SizeBytes);
  AppendBytes(Standalone, EncodedBytes);

  WriteAllBytes(ArchivePath, Standalone);
  RunExternalProcessChecked(LzmaExe, ['d', ArchivePath, DecodedPath], WorkDir);
  OutBytes := ReadAllBytesFromFile(DecodedPath);
  AssertBytesEqual(Data, OutBytes, 'Delphi raw LZMA end-marker stream decoded by SDK');
end;

procedure TLzma2NativeTests.MultiThreadedRawMatchesSingleThreadOutput;
var
  OptionsSingle: TLzma2Options;
  OptionsThreaded: TLzma2Options;
  Data: TBytes;
  EncodedSingle: TBytes;
  EncodedThreaded: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  OutBytes: TBytes;
begin
  Data := RepeatingBytes(9 * 1024 * 1024);
  OptionsSingle := TLzma2.DefaultOptions;
  OptionsSingle.Container := lcRawLzma2;
  OptionsSingle.Level := 1;
  OptionsSingle.ThreadCount := 1;
  OptionsSingle.BufferSize := LZMA2_COPY_CHUNK_SIZE;

  OptionsThreaded := OptionsSingle;
  OptionsThreaded.ThreadCount := 4;

  EncodedSingle := TLzma2Encoder.EncodeRawBytes(Data, OptionsSingle);
  EncodedThreaded := TLzma2Encoder.EncodeRawBytes(Data, OptionsThreaded);
  Assert.AreEqual(Length(EncodedSingle), Length(EncodedThreaded), 'threaded output size mismatch');
  Assert.IsTrue(CompareMem(@EncodedSingle[0], @EncodedThreaded[0], Length(EncodedSingle)),
    'threaded encoder must preserve chunk order and deterministic framing');

  Src := TBytesStream.Create(EncodedThreaded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, OptionsThreaded);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.MultiThreadedRawLargeChunksRoundTrip;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  OutBytes: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Pos: Integer;
  Control: Byte;
  ChunkSize: Integer;
  UnpackSize: Integer;
  PackSize: Integer;
  LzmaChunks: Integer;
  LargeLzmaChunks: Integer;
begin
  Data := RepeatingBytes(40 * 1024 * 1024);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 4;
  Options.BufferSize := 1 shl 20;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Pos := 0;
  LzmaChunks := 0;
  LargeLzmaChunks := 0;
  while Pos < Length(Encoded) do
  begin
    Control := Encoded[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
    begin
      Assert.AreEqual(Integer(Length(Encoded)), Pos, 'raw LZMA2 EOF marker must terminate the stream');
      Break;
    end;

    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      Assert.IsTrue(Pos + 2 <= Length(Encoded), 'truncated copy chunk header');
      ChunkSize := ((Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 1;
      Inc(Pos, 2);
      Assert.IsTrue(ChunkSize <= LZMA2_COPY_CHUNK_SIZE, 'copy chunks must stay 64 KiB framed');
      Assert.IsTrue(Pos + ChunkSize <= Length(Encoded), 'truncated copy chunk payload');
      Inc(Pos, ChunkSize);
      Continue;
    end;

    Assert.IsTrue(Control >= $80, 'invalid compressed LZMA2 control byte');
    Assert.IsTrue(Pos + 4 <= Length(Encoded), 'truncated compressed chunk header');
    UnpackSize := (((Integer(Control) and $1F) shl 16) or
      (Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 1;
    PackSize := ((Integer(Encoded[Pos + 2]) shl 8) or Integer(Encoded[Pos + 3])) + 1;
    Inc(Pos, 4);
    if (Control and $40) <> 0 then
    begin
      Assert.IsTrue(Pos < Length(Encoded), 'truncated compressed chunk properties');
      Inc(Pos);
    end;
    Assert.IsTrue(UnpackSize <= 1 shl 20, 'MT compressed chunks must respect the 1 MiB unpack cap');
    Assert.IsTrue(PackSize <= LZMA2_COPY_CHUNK_SIZE, 'MT compressed chunks must respect the 64 KiB PackedBytes cap');
    Assert.IsTrue(Pos + PackSize <= Length(Encoded), 'truncated compressed chunk payload');
    Inc(Pos, PackSize);
    Inc(LzmaChunks);
    if UnpackSize > LZMA2_COPY_CHUNK_SIZE then
      Inc(LargeLzmaChunks);
  end;

  Assert.IsTrue(LzmaChunks > 0, 'MT fixture should produce compressed chunks');
  Assert.IsTrue(LargeLzmaChunks > 0, 'MT fixture should exercise chunks larger than 64 KiB');

  Src := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, Options);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.MultiThreadedRawLargeChunkCopyFallbackSplits;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  OutBytes: TBytes;
  Src: TNonSeekableReadStream;
  EncodedStream: TMemoryStream;
  DecSrc: TBytesStream;
  Dst: TMemoryStream;
  I: Integer;
  Pos: Integer;
  Control: Byte;
  ChunkSize: Integer;
  PackSize: Integer;
  Seed: UInt32;
  CopyChunks: Integer;
begin
  SetLength(Data, 2 * 1024 * 1024);
  Seed := UInt32($12345678);
  for I := 0 to High(Data) do
  begin
    Seed := Seed * UInt32(1664525) + UInt32(1013904223);
    Data[I] := Byte(Seed shr 24);
  end;

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 4;
  Options.BufferSize := 1 shl 20;

  Src := TNonSeekableReadStream.Create(Data);
  EncodedStream := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, EncodedStream, Options);
    SetLength(Encoded, EncodedStream.Size);
    if EncodedStream.Size > 0 then
    begin
      EncodedStream.Position := 0;
      EncodedStream.ReadBuffer(Encoded[0], EncodedStream.Size);
    end;
  finally
    EncodedStream.Free;
    Src.Free;
  end;

  Pos := 0;
  CopyChunks := 0;
  while Pos < Length(Encoded) do
  begin
    Control := Encoded[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
      Break;

    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      Assert.IsTrue(Pos + 2 <= Length(Encoded), 'truncated copy chunk header');
      ChunkSize := ((Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 1;
      Inc(Pos, 2);
      Assert.IsTrue(ChunkSize <= LZMA2_COPY_CHUNK_SIZE, 'copy fallback must split 1 MiB parts into 64 KiB chunks');
      Assert.IsTrue(Pos + ChunkSize <= Length(Encoded), 'truncated copy chunk payload');
      Inc(Pos, ChunkSize);
      Inc(CopyChunks);
      Continue;
    end;

    Assert.IsTrue(Control >= $80, 'invalid compressed LZMA2 control byte');
    Assert.IsTrue(Pos + 4 <= Length(Encoded), 'truncated compressed chunk header');
    PackSize := ((Integer(Encoded[Pos + 2]) shl 8) or Integer(Encoded[Pos + 3])) + 1;
    Inc(Pos, 4);
    if (Control and $40) <> 0 then
    begin
      Assert.IsTrue(Pos < Length(Encoded), 'truncated compressed chunk properties');
      Inc(Pos);
    end;
    Assert.IsTrue(PackSize <= LZMA2_COPY_CHUNK_SIZE, 'compressed chunks must respect the 64 KiB PackedBytes cap');
    Assert.IsTrue(Pos + PackSize <= Length(Encoded), 'truncated compressed chunk payload');
    Inc(Pos, PackSize);
  end;
  Assert.IsTrue(CopyChunks > 0, 'high-entropy fixture should exercise copy fallback');

  DecSrc := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(DecSrc, Dst, Options);
    SetLength(OutBytes, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(OutBytes[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(OutBytes), 'decoded size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @OutBytes[0], Length(Data)), 'decoded bytes mismatch');
  finally
    Dst.Free;
    DecSrc.Free;
  end;
end;

procedure TLzma2NativeTests.HighEntropyRawEncodeBypassesGreedyAttempt;
const
  kInputSize = 8 * 1024 * 1024;
  kMaxElapsedMs = 500;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  Watch: TStopwatch;
  Seed: UInt32;
  I: Integer;
  Pos: Integer;
  Control: Byte;
  ChunkSize: Integer;
  CopyChunks: Integer;
  LargestCopyChunk: Integer;
begin
  SetLength(Data, kInputSize);
  Seed := UInt32($BADC0FFE);
  for I := 0 to High(Data) do
  begin
    Seed := Seed * UInt32(1664525) + UInt32(1013904223);
    Data[I] := Byte(Seed shr 24);
  end;

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := 1 shl 20;

  Watch := TStopwatch.StartNew;
  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Watch.Stop;
  Assert.IsTrue(Watch.ElapsedMilliseconds < kMaxElapsedMs,
    Format('high-entropy level-1 raw encode should bypass the greedy attempt (%d ms >= %d ms)',
      [Watch.ElapsedMilliseconds, kMaxElapsedMs]));

  Pos := 0;
  CopyChunks := 0;
  LargestCopyChunk := 0;
  while Pos < Length(Encoded) do
  begin
    Control := Encoded[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
      Break;

    Assert.IsTrue((Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET),
      'high-entropy bypass should write only copy chunks');
    Assert.IsTrue(Pos + 2 <= Length(Encoded), 'truncated high-entropy copy header');
    ChunkSize := ((Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 1;
    if ChunkSize > LargestCopyChunk then
      LargestCopyChunk := ChunkSize;
    Inc(Pos, 2);
    Assert.IsTrue(Pos + ChunkSize <= Length(Encoded), 'truncated high-entropy copy payload');
    Inc(Pos, ChunkSize);
    Inc(CopyChunks);
  end;

  Assert.IsTrue(CopyChunks > 0, 'high-entropy bypass should emit copy chunks');
  Assert.AreEqual(LZMA2_COPY_CHUNK_SIZE, LargestCopyChunk,
    'high-entropy copy fallback must keep 64 KiB LZMA2 copy packet framing');
end;

procedure TLzma2NativeTests.MixedBenchmarkCorpusRawEncodeCompressesRepeatingStripes;
const
  kInputSize = 1024 * 1024;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  Decoded: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  State: UInt32;
  NextState: UInt64;
  I: Integer;
begin
  SetLength(Data, kInputSize);
  State := UInt32($12345678);
  for I := 0 to High(Data) do
  begin
    if (I mod 8192) < 2048 then
      Data[I] := Byte(Ord('A') + (I mod 7))
    else
    begin
      NextState := (UInt64(State) * UInt64(1664525) + UInt64(1013904223)) mod UInt64(4294967296);
      State := UInt32(NextState);
      Data[I] := Byte(State shr 24);
    end;
  end;

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := 2 shl 20;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Assert.IsTrue(Length(Encoded) < (Length(Data) * 95) div 100,
    Format('mixed benchmark corpus must not be emitted as copy-like raw LZMA2: encoded=%d input=%d',
      [Length(Encoded), Length(Data)]));

  Src := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, Options);
    SetLength(Decoded, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Decoded[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(Decoded), 'decoded mixed benchmark corpus size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @Decoded[0], Length(Data)),
      'decoded mixed benchmark corpus bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.MixedBenchmarkCorpusRawMtEncodeCompressesRepeatingStripes;
const
  kInputSize = 2 * 1024 * 1024;
var
  Options: TLzma2Options;
  Diagnostics: TLzma2EncodeDiagnostics;
  Data: TBytes;
  Encoded: TBytes;
  Decoded: TBytes;
  Src: TNonSeekableReadStream;
  EncodedStream: TMemoryStream;
  DecSrc: TBytesStream;
  Dst: TMemoryStream;
  State: UInt32;
  NextState: UInt64;
  I: Integer;
begin
  SetLength(Data, kInputSize);
  State := UInt32($12345678);
  for I := 0 to High(Data) do
  begin
    if (I mod 8192) < 2048 then
      Data[I] := Byte(Ord('A') + (I mod 7))
    else
    begin
      NextState := (UInt64(State) * UInt64(1664525) + UInt64(1013904223)) mod UInt64(4294967296);
      State := UInt32(NextState);
      Data[I] := Byte(State shr 24);
    end;
  end;

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 4;
  Options.BufferSize := 1 shl 20;
  Diagnostics := Default(TLzma2EncodeDiagnostics);
  Options.EncodeDiagnostics := @Diagnostics;

  Src := TNonSeekableReadStream.Create(Data);
  EncodedStream := TMemoryStream.Create;
  try
    TLzma2Encoder.EncodeRaw(Src, EncodedStream, Options);
    SetLength(Encoded, EncodedStream.Size);
    if EncodedStream.Size > 0 then
    begin
      EncodedStream.Position := 0;
      EncodedStream.ReadBuffer(Encoded[0], EncodedStream.Size);
    end;
  finally
    EncodedStream.Free;
    Src.Free;
  end;

  Assert.AreEqual(1, Diagnostics.ActualThreadCount,
    'non-seekable mixed benchmark corpus is too small for more than one active worker');
  Assert.AreEqual('insufficient-work', Diagnostics.FallbackReason,
    'single-job MT encode diagnostics must report insufficient work instead of requested workers');
  Assert.IsTrue(Diagnostics.BatchCount > 0, 'mixed benchmark worker path should report encoded batches');
  Assert.IsTrue(Length(Encoded) < (Length(Data) * 95) div 100,
    Format('mixed benchmark MT corpus must not be emitted as copy-like raw LZMA2: encoded=%d input=%d',
      [Length(Encoded), Length(Data)]));

  DecSrc := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(DecSrc, Dst, Options);
    SetLength(Decoded, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Decoded[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(Decoded), 'decoded mixed benchmark MT corpus size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @Decoded[0], Length(Data)),
      'decoded mixed benchmark MT corpus bytes mismatch');
  finally
    Dst.Free;
    DecSrc.Free;
  end;
end;

procedure TLzma2NativeTests.IncompressibleProbeDoesNotCopyCompressibleTail;
const
  kInputSize = 1024 * 1024;
  kRandomPrefixSize = 64 * 1024;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  Decoded: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Seed: UInt32;
  I: Integer;
  Pos: Integer;
  Control: Byte;
  ChunkSize: Integer;
  PackSize: Integer;
  CompressedChunks: Integer;
begin
  SetLength(Data, kInputSize);
  Seed := UInt32($9E3779B9);
  for I := 0 to kRandomPrefixSize - 1 do
  begin
    Seed := Seed * UInt32(1664525) + UInt32(1013904223);
    Data[I] := Byte(Seed shr 24);
  end;
  for I := kRandomPrefixSize to High(Data) do
    Data[I] := Byte(Ord('A') + (I mod 5));

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;
  Options.BufferSize := kInputSize;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);

  Pos := 0;
  CompressedChunks := 0;
  while Pos < Length(Encoded) do
  begin
    Control := Encoded[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
      Break;

    Assert.IsTrue(Pos + 2 <= Length(Encoded), 'truncated LZMA2 chunk header');
    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      ChunkSize := ((Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 1;
      Inc(Pos, 2);
      Assert.IsTrue(Pos + ChunkSize <= Length(Encoded), 'truncated LZMA2 copy payload');
      Inc(Pos, ChunkSize);
    end
    else
    begin
      Assert.IsTrue(Control >= $80, 'unexpected LZMA2 control byte');
      Assert.IsTrue(Pos + 4 <= Length(Encoded), 'truncated LZMA2 compressed header');
      PackSize := ((Integer(Encoded[Pos + 2]) shl 8) or Integer(Encoded[Pos + 3])) + 1;
      Inc(Pos, 5);
      Assert.IsTrue(Pos + PackSize <= Length(Encoded), 'truncated LZMA2 compressed payload');
      Inc(Pos, PackSize);
      Inc(CompressedChunks);
    end;
  end;

  Assert.IsTrue(CompressedChunks > 0,
    'random-prefix fixture has a compressible tail and must not be copied as one incompressible chunk');

  Src := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, Options);
    SetLength(Decoded, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Decoded[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(Decoded), 'decoded mixed chunk size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @Decoded[0], Length(Data)), 'decoded mixed chunk bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.PeriodicRawEncodeUsesFastPath;
const
  kInputSize = 2 * 1024 * 1024;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  Decoded: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
begin
  Data := RepeatingBytes(kInputSize);

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 1;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Assert.IsTrue(Length(Encoded) < Length(Data) div 100,
    Format('periodic level-1 raw encode should stay compact without wall-clock gating: encoded=%d input=%d',
      [Length(Encoded), Length(Data)]));

  Src := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, Options);
    SetLength(Decoded, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Decoded[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(Decoded), 'decoded periodic size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @Decoded[0], Length(Data)), 'decoded periodic bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.PeriodicFastPathRejectsChunkedPhaseReset;
const
  kInputSize = 4 * 1024 * 1024;
  kGeneratorChunkSize = 1024 * 1024;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  Decoded: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Base: Integer;
  I: Integer;
  Limit: Integer;
begin
  SetLength(Data, kInputSize);
  Base := 0;
  while Base < Length(Data) do
  begin
    Limit := kGeneratorChunkSize;
    if Limit > Length(Data) - Base then
      Limit := Length(Data) - Base;
    for I := 0 to Limit - 1 do
      Data[Base + I] := Byte(Ord('A') + (I mod 5));
    Inc(Base, Limit);
  end;

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;
  Options.BufferSize := 2 shl 20;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Src := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, Options);
    SetLength(Decoded, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Decoded[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(Decoded), 'decoded chunked-periodic size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @Decoded[0], Length(Data)),
      'decoded chunked-periodic bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.PeriodicPhaseResetRawEncodeUsesSubchunkFastPath;
const
  kInputSize = 4 * 1024 * 1024;
  kGeneratorChunkSize = 1024 * 1024;
var
  Options: TLzma2Options;
  Data: TBytes;
  Encoded: TBytes;
  Decoded: TBytes;
  Src: TBytesStream;
  Dst: TMemoryStream;
  Base: Integer;
  I: Integer;
  Limit: Integer;
  Pos: Integer;
  Control: Byte;
  ChunkSize: Integer;
  UnpackSize: Integer;
  PackSize: Integer;
  CompressedChunks: Integer;
  NoResetChunks: Integer;
  TotalUnpackSize: Integer;
begin
  SetLength(Data, kInputSize);
  Base := 0;
  while Base < Length(Data) do
  begin
    Limit := kGeneratorChunkSize;
    if Limit > Length(Data) - Base then
      Limit := Length(Data) - Base;
    for I := 0 to Limit - 1 do
      Data[Base + I] := Byte(Ord('A') + (I mod 5));
    Inc(Base, Limit);
  end;

  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 1;
  Options.BufferSize := 2 shl 20;

  Encoded := TLzma2Encoder.EncodeRawBytes(Data, Options);
  Pos := 0;
  CompressedChunks := 0;
  NoResetChunks := 0;
  TotalUnpackSize := 0;
  while Pos < Length(Encoded) do
  begin
    Control := Encoded[Pos];
    Inc(Pos);
    if Control = LZMA2_CONTROL_EOF then
      Break;

    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      Assert.IsTrue(Pos + 2 <= Length(Encoded), 'truncated copy chunk header');
      ChunkSize := ((Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 1;
      Inc(Pos, 2);
      Assert.IsTrue(Pos + ChunkSize <= Length(Encoded), 'truncated copy chunk payload');
      Inc(Pos, ChunkSize);
      Continue;
    end;

    Assert.IsTrue(Control >= $80, 'invalid compressed LZMA2 control byte');
    Assert.IsTrue(Pos + 4 <= Length(Encoded), 'truncated compressed chunk header');
    UnpackSize := (((Integer(Control) and $1F) shl 16) or
      (Integer(Encoded[Pos]) shl 8) or Integer(Encoded[Pos + 1])) + 1;
    PackSize := ((Integer(Encoded[Pos + 2]) shl 8) or Integer(Encoded[Pos + 3])) + 1;
    Inc(Pos, 4);
    if (Control and $40) <> 0 then
    begin
      Assert.IsTrue(Pos < Length(Encoded), 'truncated compressed chunk properties');
      Inc(Pos);
    end;
    if (Control and $60) = 0 then
      Inc(NoResetChunks);
    Assert.IsTrue(UnpackSize <= 2 * kGeneratorChunkSize,
      'phase-reset periodic data must stay within the LZMA2 maximum unpack chunk size');
    Assert.IsTrue(PackSize <= LZMA2_COPY_CHUNK_SIZE, 'compressed chunks must respect the 64 KiB PackedBytes cap');
    Assert.IsTrue(Pos + PackSize <= Length(Encoded), 'truncated compressed chunk payload');
    Inc(Pos, PackSize);
    Inc(CompressedChunks);
    Inc(TotalUnpackSize, UnpackSize);
  end;
  Assert.IsTrue(CompressedChunks >= 2,
    'phase-reset periodic input should be split into multiple compressed chunks');
  Assert.IsTrue(NoResetChunks >= 1,
    'phase-reset periodic input should continue at least one compressed chunk without LZMA2 state reset');
  Assert.AreEqual(kInputSize, TotalUnpackSize,
    'phase-reset periodic compressed chunks should cover the full input');

  Src := TBytesStream.Create(Encoded);
  Dst := TMemoryStream.Create;
  try
    TLzma2Decoder.DecodeRaw(Src, Dst, Options);
    SetLength(Decoded, Dst.Size);
    if Dst.Size > 0 then
    begin
      Dst.Position := 0;
      Dst.ReadBuffer(Decoded[0], Dst.Size);
    end;
    Assert.AreEqual(Length(Data), Length(Decoded), 'decoded subchunk-periodic size mismatch');
    Assert.IsTrue(CompareMem(@Data[0], @Decoded[0], Length(Data)),
      'decoded subchunk-periodic bytes mismatch');
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.MultiThreadedRawCancellation;
var
  Options: TLzma2Options;
  Data: TBytes;
begin
  Data := RepeatingBytes(200000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 4;

  Assert.WillRaise(
    procedure
    begin
      TLzma2Encoder.EncodeRawBytes(
        Data,
        Options,
        procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
        begin
          Cancel := OutBytes > 0;
        end);
    end,
    ELzmaCancelled);
end;

procedure TLzma2NativeTests.MultiThreadedRawMemoryLimit;
var
  Options: TLzma2Options;
  Data: TBytes;
begin
  Data := RepeatingBytes(200000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 4;
  Options.MemoryLimit := 2 shl 20;

  Assert.WillRaise(
    procedure
    begin
      TLzma2Encoder.EncodeRawBytes(Data, Options);
    end,
    ELzmaMemoryError);
end;

procedure TLzma2NativeTests.MultiThreadedRawWriteFailure;
var
  Options: TLzma2Options;
  Data: TBytes;
  Src: TBytesStream;
  Dst: TWriteFailStream;
begin
  Data := RepeatingBytes(200000);
  Options := TLzma2.DefaultOptions;
  Options.Container := lcRawLzma2;
  Options.Level := 1;
  Options.ThreadCount := 4;

  Src := TBytesStream.Create(Data);
  Dst := TWriteFailStream.Create;
  try
    Assert.WillRaise(
      procedure
      begin
        TLzma2Encoder.EncodeRaw(Src, Dst, Options);
      end,
      ELzmaWriteError);
  finally
    Dst.Free;
    Src.Free;
  end;
end;

procedure TLzma2NativeTests.IndependentInstancesAreThreadSafe;
var
  Tasks: array[0..3] of ITask;
  I: Integer;
begin
  for I := Low(Tasks) to High(Tasks) do
  begin
    Tasks[I] := TTask.Run(
      procedure
      begin
        RoundTrip(lcXz, lzCheckCrc32, BytesOfSize(32768));
      end);
  end;
  TTask.WaitForAll(Tasks);
  for I := Low(Tasks) to High(Tasks) do
    Assert.AreEqual(TTaskStatus.Completed, Tasks[I].Status);
end;

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  XmlLogger: ITestLogger;
  TestResultDir: string;

begin
  try
    TDUnitX.CheckCommandLine;
    TDUnitX.RegisterTestFixture(TLzma2NativeTests);
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;
    Logger := TDUnitXConsoleLogger.Create(True);
    Runner.AddLogger(Logger);
    TestResultDir := IncludeTrailingPathDelimiter(GetCurrentDir) + 'artifacts\test-results';
    ForceDirectories(TestResultDir);
    XmlLogger := TDUnitXXMLJUnitFileLogger.Create(
      IncludeTrailingPathDelimiter(TestResultDir) + 'Lzma.Tests.junit.xml');
    Runner.AddLogger(XmlLogger);
    Results := Runner.Execute;
    if not Results.AllPassed then
      ExitCode := 1;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
