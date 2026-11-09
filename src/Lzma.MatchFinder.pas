unit Lzma.MatchFinder;

interface

uses
  System.SysUtils,
  Lzma.Alloc;

type
  TLzmaMatchFinderKind = (
    mfHashChain4,
    mfHashChain5,
    mfBinaryTree4,
    mfBinaryTree2,
    mfBinaryTree3,
    mfBinaryTree5
  );

  TLzmaMatch = record
    Length: UInt32;
    Distance: UInt32;
  end;

  TLzmaMatchArray = TArray<TLzmaMatch>;

  TLzmaMatchBuffer = record
    Count: Integer;
    Items: array[0..273] of TLzmaMatch;
    procedure Clear; inline;
    // Copies Count active pairs; other receiver entries are unchanged.
    procedure CopyPairsFrom(const Source: TLzmaMatchBuffer); inline;
    procedure Add(const Len, Dist: UInt32); inline;
    function Last: TLzmaMatch; inline;
  end;

  TLzmaPositionLinks = record
  private
    FCompact: TArray<UInt32>;
    FWide: TArray<NativeInt>;
    FIsCompact: Boolean;
    function GetItem(const Index: NativeInt): NativeInt; inline;
    procedure SetItem(const Index, Value: NativeInt); inline;
    function GetCount: NativeInt; inline;
    function GetCompactData: Pointer; inline;
    function GetWideData: Pointer; inline;
  public
    procedure Initialize(const SlotCount: NativeInt; const MaxPosition: NativeUInt);
    property Items[const Index: NativeInt]: NativeInt read GetItem write SetItem; default;
    property Count: NativeInt read GetCount;
    property IsCompact: Boolean read FIsCompact;
    property CompactData: Pointer read GetCompactData;
    property WideData: Pointer read GetWideData;
  end;

  TLzmaInsertedBits = record
  private const
    kBitsPerByte = 8;
  private
    FBytes: TBytes;
    FCount: NativeUInt;
    FPrefixCount: NativeUInt;
    procedure Materialize;
    class function BytesForBits(const Count: NativeUInt): NativeUInt; static; inline;
    function GetItem(const Index: NativeUInt): Boolean; inline;
    procedure SetItem(const Index: NativeUInt; const Value: Boolean); inline;
  public
    procedure Initialize(const Count: NativeUInt);
    procedure SetRange(const First, Count: NativeUInt; const Value: Boolean = True);
    procedure DropPrefix(const DropCount, UsedCount: NativeUInt);
    property Items[const Index: NativeUInt]: Boolean read GetItem write SetItem; default;
    property Count: NativeUInt read FCount;
  end;

  TLzmaGreedyMatchFinder = class
  private const
    kHash2Size = 1 shl 10;
    kHashSize = 1 shl 16;
    kDefaultHashDepth = 256;
    kMinLowHashLength = 2;
    kMinHashLength = 3;
  private
    FData: TBytes;
    FOffset: NativeUInt;
    FCount: NativeUInt;
    FPositionBase: NativeUInt;
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHeads2: TLzmaPositionLinks;
    FHeads: TLzmaPositionLinks;
    FPrev: TLzmaPositionLinks;
    FInserted: TLzmaInsertedBits;
    FLastReadValid: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    procedure EnsureEpochCapacity(const Count: NativeUInt);
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function HashAt(const RelativePos: NativeUInt): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    procedure SetInputCount(const Count: NativeUInt);
    procedure RebaseWindow(const DropCount: NativeUInt);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    // Same cached read, copying only the active pairs.
    procedure ReadMatchPairs(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    procedure GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer); overload;
    function GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray; overload;
    function Find(const RelativePos: NativeUInt): TLzmaMatch;
  end;

  TLzmaHashChain4MatchFinder = class
  private const
    kHash2Size = 1 shl 10;
    kHash3Size = 1 shl 16;
    kHash4Size = 1 shl 16;
    kDefaultHashDepth = 256;
    kMinLowHashLength = 2;
    kMinHash3Length = 3;
    kMinHash4Length = 4;
  private
    FData: TBytes;
    FOffset: NativeUInt;
    FCount: NativeUInt;
    FPositionBase: NativeUInt;
    FCyclicPhase: NativeUInt;
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHash4Mask: NativeUInt;
    FCyclicBufferSize: NativeUInt;
    FHeads2: TLzmaPositionLinks;
    FHeads3: TLzmaPositionLinks;
    FHeads4: TLzmaPositionLinks;
    FPrev: TLzmaPositionLinks;
    FInserted: TLzmaInsertedBits;
    FLastReadValid: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    procedure EnsureEpochCapacity(const Count: NativeUInt);
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function Hash3At(const RelativePos: NativeUInt): NativeInt;
    function Hash4At(const RelativePos: NativeUInt): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    procedure SetInputCount(const Count: NativeUInt);
    procedure RebaseWindow(const DropCount: NativeUInt);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    // Same cached read, copying only the active pairs.
    procedure ReadMatchPairs(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    procedure GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer); overload;
    function GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray; overload;
    function ChainSlotCount: NativeUInt;
    function Find(const RelativePos: NativeUInt): TLzmaMatch;
  end;

  TLzmaHashChain5MatchFinder = class
  private const
    kHash2Size = 1 shl 10;
    kHash3Size = 1 shl 16;
    kHash5Size = 1 shl 16;
    kDefaultHashDepth = 256;
    kMinLowHashLength = 2;
    kMinHash3Length = 3;
    kMinHash5Length = 5;
  private
    FData: TBytes;
    FOffset: NativeUInt;
    FCount: NativeUInt;
    FPositionBase: NativeUInt;
    FCyclicPhase: NativeUInt;
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHash5Mask: NativeUInt;
    FCyclicBufferSize: NativeUInt;
    FHeads2: TLzmaPositionLinks;
    FHeads3: TLzmaPositionLinks;
    FHeads5: TLzmaPositionLinks;
    FPrev: TLzmaPositionLinks;
    FInserted: TLzmaInsertedBits;
    FLastReadValid: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    procedure EnsureEpochCapacity(const Count: NativeUInt);
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function Hash3At(const RelativePos: NativeUInt): NativeInt;
    function Hash5At(const RelativePos: NativeUInt): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    procedure SetInputCount(const Count: NativeUInt);
    procedure RebaseWindow(const DropCount: NativeUInt);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    // Same cached read, copying only the active pairs.
    procedure ReadMatchPairs(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    procedure GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer); overload;
    function GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray; overload;
    function ChainSlotCount: NativeUInt;
    function Find(const RelativePos: NativeUInt): TLzmaMatch;
  end;

  TLzmaBinaryTree4MatchFinder = class
  private const
    kHash2Size = 1 shl 10;
    kHash3Size = 1 shl 16;
    kHash4Size = 1 shl 16;
    kDefaultHashDepth = 256;
    kMinLowHashLength = 2;
    kMinHash3Length = 3;
    kMinHash4Length = 4;
  private
    FData: TBytes;
    FOffset: NativeUInt;
    FCount: NativeUInt;
    FPositionBase: NativeUInt;
    FCyclicPhase: NativeUInt;
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHash4Mask: NativeUInt;
    FCyclicBufferSize: NativeUInt;
    FHeads2: TLzmaPositionLinks;
    FHeads3: TLzmaPositionLinks;
    FHeads4: TLzmaPositionLinks;
    FSons: TLzmaPositionLinks;
    FInserted: TLzmaInsertedBits;
    FLastReadValid: Boolean;
    FFusedReadSafe: Boolean;
    FUseSdkMtHighHash: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    procedure EnsureEpochCapacity(const Count: NativeUInt);
    procedure CollectMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer;
      const InsertCurrent: Boolean);
    procedure ReadMatchesAndInsert(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function Hash3At(const RelativePos: NativeUInt): NativeInt;
    function Hash4At(const RelativePos: NativeUInt): NativeInt;
    function SonIndex(const RelativePos: NativeUInt; const Right: Boolean): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    // Internal MT-worker experiment: change only the SDK bigHash formula.
    class function CreateSdkMtHighHash(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0): TLzmaBinaryTree4MatchFinder; static;
    procedure SetInputCount(const Count: NativeUInt);
    procedure RebaseWindow(const DropCount: NativeUInt);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    // Same cached read, copying only the active pairs.
    procedure ReadMatchPairs(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    procedure GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer); overload;
    function GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray; overload;
    function SonSlotCount: NativeUInt;
    function Find(const RelativePos: NativeUInt): TLzmaMatch;
  end;

function LzmaCountMatchingBytes(const Data: TBytes; const Left, Right: NativeUInt;
  const MaxLen: UInt32): UInt32; inline;

// Kernel-owned instance and array payload capacities; shared input data and
// RTL/allocator bookkeeping belong to the caller's separate memory budget.
function LzmaMatchFinderMemoryRequired(const AllocatedCount: NativeUInt;
  const DictionarySize: UInt64; const Kind: TLzmaMatchFinderKind): UInt64;

implementation

uses
  Lzma.Sdk.MatchFinder;

type
  TPositionLinkArray = array[0..MaxInt div SizeOf(UInt32) - 1] of UInt32;
  PPositionLinkArray = ^TPositionLinkArray;

const
  kLzHashCrcShift1 = 5;
  kLzHashCrcShift2 = 10;

var
  GLzmaHashCrc: array[Byte] of UInt32;
  GLzmaHashCrcShift1: array[Byte] of UInt32;
  GLzmaHashCrcShift2: array[Byte] of UInt32;

procedure LzmaInitHashCrc;
var
  I: Integer;
  J: Integer;
  R: UInt32;
begin
  for I := 0 to 255 do
  begin
    R := UInt32(I);
    for J := 0 to 7 do
    begin
      if (R and 1) <> 0 then
        R := (R shr 1) xor UInt32($EDB88320)
      else
        R := R shr 1;
    end;
    GLzmaHashCrc[Byte(I)] := R;
    GLzmaHashCrcShift1[Byte(I)] := R shl kLzHashCrcShift1;
    GLzmaHashCrcShift2[Byte(I)] := R shl kLzHashCrcShift2;
  end;
end;

function LzmaSdkHashMask(const HistorySize: NativeUInt; const NumHashBytes: UInt32): NativeUInt;
begin
  if NumHashBytes = 2 then
    Exit((NativeUInt(1) shl 16) - 1);

  Result := HistorySize;
  if Result <> 0 then
    Dec(Result);
  Result := Result or (Result shr 1);
  Result := Result or (Result shr 2);
  Result := Result or (Result shr 4);
  Result := Result or (Result shr 8);
  Result := Result shr 1;
  if Result >= (NativeUInt(1) shl 24) then
  begin
    if NumHashBytes = 3 then
      Result := (NativeUInt(1) shl 24) - 1
    else
      Result := Result shr 1;
  end;
  Result := Result or ((NativeUInt(1) shl 16) - 1);
  if NumHashBytes >= 5 then
    Result := Result or ((NativeUInt(256) shl kLzHashCrcShift2) - 1);
end;

function LzmaHashArrayLength(const HashMask: NativeUInt): NativeInt;
begin
  if HashMask > NativeUInt(High(NativeInt) - 1) then
    raise EArgumentOutOfRangeException.Create('Match finder hash table is too large');
  Result := NativeInt(HashMask) + 1;
end;

type
  TLzmaMatchFinderAllocation = record
    HistorySize: NativeUInt;
    CyclicSize: NativeUInt;
    HashMask: NativeUInt;
    Hash2Slots: NativeInt;
    Hash3Slots: NativeInt;
    HashSlots: NativeInt;
    LinkSlots: NativeInt;
    InstanceBytes: UInt64;
  end;

function LzmaUsesCompactPositionLinks(const MaxPosition: NativeUInt): Boolean; inline;
begin
{$IF SizeOf(NativeUInt) > SizeOf(UInt32)}
  Result := MaxPosition <= High(UInt32);
{$ELSE}
  Result := True;
{$ENDIF}
end;

function LzmaMatchFinderAllocation(const AllocatedCount: NativeUInt;
  const DictionarySize: UInt64; const Kind: TLzmaMatchFinderKind): TLzmaMatchFinderAllocation;
var
  HashBytes: UInt32;
begin
  // Clamp before the native-width conversion, including direct wide callers.
  if DictionarySize > UInt64(AllocatedCount) then
    Result.HistorySize := AllocatedCount
  else
    Result.HistorySize := NativeUInt(DictionarySize);
  case Kind of
    mfHashChain4:
      begin
        HashBytes := 4;
        Result.Hash2Slots := TLzmaHashChain4MatchFinder.kHash2Size;
        Result.Hash3Slots := TLzmaHashChain4MatchFinder.kHash3Size;
        Result.InstanceBytes := TLzmaHashChain4MatchFinder.InstanceSize;
      end;
    mfHashChain5:
      begin
        HashBytes := 5;
        Result.Hash2Slots := TLzmaHashChain5MatchFinder.kHash2Size;
        Result.Hash3Slots := TLzmaHashChain5MatchFinder.kHash3Size;
        Result.InstanceBytes := TLzmaHashChain5MatchFinder.InstanceSize;
      end;
    mfBinaryTree4:
      begin
        HashBytes := 4;
        Result.Hash2Slots := TLzmaBinaryTree4MatchFinder.kHash2Size;
        Result.Hash3Slots := TLzmaBinaryTree4MatchFinder.kHash3Size;
        Result.InstanceBytes := TLzmaBinaryTree4MatchFinder.InstanceSize;
      end;
  else
    raise EArgumentOutOfRangeException.Create('Invalid match finder kind');
  end;
  if Kind = mfBinaryTree4 then
  begin
    if Result.HistorySize >= NativeUInt(High(NativeInt) div 2) then
      raise EArgumentOutOfRangeException.Create('Match finder cyclic window is too large');
  end
  else if Result.HistorySize >= NativeUInt(High(NativeInt)) then
    raise EArgumentOutOfRangeException.Create('Match finder cyclic window is too large');
  Result.CyclicSize := Result.HistorySize + 1;
  if Kind = mfBinaryTree4 then
    Result.LinkSlots := NativeInt(Result.CyclicSize) * 2
  else
    Result.LinkSlots := NativeInt(Result.CyclicSize);
  Result.HashMask := LzmaSdkHashMask(Result.HistorySize, HashBytes);
  Result.HashSlots := LzmaHashArrayLength(Result.HashMask);
end;

function LzmaMatchFinderMemoryRequired(const AllocatedCount: NativeUInt;
  const DictionarySize: UInt64; const Kind: TLzmaMatchFinderKind): UInt64;
var
  Allocation: TLzmaMatchFinderAllocation;
  LinkBytes, LinkSlots: UInt64;
begin
  case Kind of
    mfBinaryTree2: Exit(TLzmaSdkBinaryTreeMatchFinder.RequiredMemory(AllocatedCount, DictionarySize, 2));
    mfBinaryTree3: Exit(TLzmaSdkBinaryTreeMatchFinder.RequiredMemory(AllocatedCount, DictionarySize, 3));
    mfBinaryTree5: Exit(TLzmaSdkBinaryTreeMatchFinder.RequiredMemory(AllocatedCount, DictionarySize, 5));
  end;
  Allocation := LzmaMatchFinderAllocation(AllocatedCount, DictionarySize, Kind);
  if LzmaUsesCompactPositionLinks(AllocatedCount) then
    LinkBytes := SizeOf(UInt32)
  else
    LinkBytes := SizeOf(NativeInt);
  LinkSlots := CheckedMemoryAdd(UInt64(Allocation.Hash2Slots), UInt64(Allocation.Hash3Slots));
  LinkSlots := CheckedMemoryAdd(LinkSlots, UInt64(Allocation.HashSlots));
  LinkSlots := CheckedMemoryAdd(LinkSlots, UInt64(Allocation.LinkSlots));
  Result := CheckedMemoryAdd(Allocation.InstanceBytes,
    CheckedMemoryMultiply(LinkSlots, LinkBytes));
  Result := CheckedMemoryAdd(Result, TLzmaInsertedBits.BytesForBits(AllocatedCount));
end;

function LzmaHasBytesAt(const RelativePos, Count: NativeUInt; const Needed: UInt32): Boolean; inline;
begin
  Result := (RelativePos < Count) and (NativeUInt(Needed) <= Count - RelativePos);
end;

function EqualLowBytes(Value: UInt64): UInt32; inline;
begin
  Result := 0;
  if UInt32(Value) = 0 then
  begin
    Value := Value shr 32;
    Inc(Result, 4);
  end;
  if (Value and $FFFF) = 0 then
  begin
    Value := Value shr 16;
    Inc(Result, 2);
  end;
  if (Value and $FF) = 0 then
    Inc(Result);
end;

function LzmaCountMatchingBytes(const Data: TBytes; const Left, Right: NativeUInt;
  const MaxLen: UInt32): UInt32;
var
  PLeft, PRight: PByte;
  Difference: UInt64;
begin
  Result := 0;
  if MaxLen = 0 then
    Exit;
  PLeft := @Data[Left];
  PRight := @Data[Right];
  while MaxLen - Result >= SizeOf(UInt64) * 2 do
  begin
    Difference := PUInt64(PLeft)^ xor PUInt64(PRight)^;
    if Difference <> 0 then
      Exit(Result + EqualLowBytes(Difference));
    Difference := PUInt64(NativeUInt(PLeft) + SizeOf(UInt64))^ xor
      PUInt64(NativeUInt(PRight) + SizeOf(UInt64))^;
    if Difference <> 0 then
      Exit(Result + SizeOf(UInt64) + EqualLowBytes(Difference));
    Inc(PLeft, SizeOf(UInt64) * 2);
    Inc(PRight, SizeOf(UInt64) * 2);
    Inc(Result, SizeOf(UInt64) * 2);
  end;
  if MaxLen - Result >= SizeOf(UInt64) then
  begin
    Difference := PUInt64(PLeft)^ xor PUInt64(PRight)^;
    if Difference <> 0 then
      Exit(Result + EqualLowBytes(Difference));
    Inc(PLeft, SizeOf(UInt64));
    Inc(PRight, SizeOf(UInt64));
    Inc(Result, SizeOf(UInt64));
  end;
  while (Result < MaxLen) and (PLeft^ = PRight^) do
  begin
    Inc(PLeft);
    Inc(PRight);
    Inc(Result);
  end;
end;

procedure TLzmaMatchBuffer.Clear;
begin
  Count := 0;
end;

procedure TLzmaMatchBuffer.CopyPairsFrom(const Source: TLzmaMatchBuffer);
var
  PairCount: Integer;
begin
  PairCount := Source.Count;
  if (PairCount < 0) or (PairCount > Length(Items)) then
    raise EArgumentOutOfRangeException.Create('Invalid match buffer count');
  if PairCount > 0 then
    Move(Source.Items[0], Items[0], NativeUInt(PairCount) * SizeOf(Items[0]));
  Count := PairCount;
end;

procedure TLzmaMatchBuffer.Add(const Len, Dist: UInt32);
begin
  if Count < Length(Items) then
  begin
    Items[Count].Length := Len;
    Items[Count].Distance := Dist;
    Inc(Count);
  end
  else
  begin
    Items[High(Items)].Length := Len;
    Items[High(Items)].Distance := Dist;
  end;
end;

function TLzmaMatchBuffer.Last: TLzmaMatch;
begin
  if Count = 0 then
  begin
    Result.Length := 0;
    Result.Distance := 0;
  end
  else
    Result := Items[Count - 1];
end;

procedure TLzmaPositionLinks.Initialize(const SlotCount: NativeInt;
  const MaxPosition: NativeUInt);
begin
  // Marks are relative positions plus one; table length does not bound them.
  // Keep native-width storage for direct callers with windows above UInt32.
  FIsCompact := LzmaUsesCompactPositionLinks(MaxPosition);
  if FIsCompact then
  begin
    SetLength(FWide, 0);
    SetLength(FCompact, SlotCount);
  end
  else
  begin
    SetLength(FCompact, 0);
    SetLength(FWide, SlotCount);
  end;
end;

function TLzmaPositionLinks.GetItem(const Index: NativeInt): NativeInt;
begin
  if FIsCompact then
    Result := FCompact[Index]
  else
    Result := FWide[Index];
end;

procedure TLzmaPositionLinks.SetItem(const Index, Value: NativeInt);
begin
  if FIsCompact then
    FCompact[Index] := UInt32(Value)
  else
    FWide[Index] := Value;
end;

function TLzmaPositionLinks.GetCount: NativeInt;
begin
  if FIsCompact then
    Result := Length(FCompact)
  else
    Result := Length(FWide);
end;

function TLzmaPositionLinks.GetCompactData: Pointer;
begin
  Result := Pointer(FCompact);
end;

function TLzmaPositionLinks.GetWideData: Pointer;
begin
  Result := Pointer(FWide);
end;

class function TLzmaInsertedBits.BytesForBits(const Count: NativeUInt): NativeUInt;
begin
  Result := Count div kBitsPerByte;
  if Count mod kBitsPerByte <> 0 then
    Inc(Result);
end;

procedure TLzmaInsertedBits.Initialize(const Count: NativeUInt);
begin
  FBytes := nil;
  FCount := Count;
  FPrefixCount := 0;
end;

procedure TLzmaInsertedBits.Materialize;
var
  FullBytes: NativeUInt;
  TailBits: NativeUInt;
begin
  SetLength(FBytes, NativeInt(BytesForBits(FCount)));
  FullBytes := FPrefixCount div kBitsPerByte;
  if FullBytes <> 0 then
    FillChar(FBytes[0], FullBytes, $FF);
  TailBits := FPrefixCount mod kBitsPerByte;
  if TailBits <> 0 then
    FBytes[FullBytes] := Byte((1 shl TailBits) - 1);
  FPrefixCount := 0;
end;

function TLzmaInsertedBits.GetItem(const Index: NativeUInt): Boolean;
begin
  if FBytes = nil then
    Exit(Index < FPrefixCount);
  Result := (FBytes[Index div kBitsPerByte] and
    (Byte(1) shl (Index mod kBitsPerByte))) <> 0;
end;

procedure TLzmaInsertedBits.SetItem(const Index: NativeUInt; const Value: Boolean);
var
  ByteIndex: NativeUInt;
  Mask: Byte;
begin
  if FBytes = nil then
  begin
    if Value then
    begin
      if Index < FPrefixCount then
        Exit;
      if Index = FPrefixCount then
      begin
        Inc(FPrefixCount);
        Exit;
      end;
    end
    else
    begin
      if Index >= FPrefixCount then
        Exit;
      if Index = FPrefixCount - 1 then
      begin
        Dec(FPrefixCount);
        Exit;
      end;
    end;
    Materialize;
  end;
  ByteIndex := Index div kBitsPerByte;
  Mask := Byte(1 shl (Index mod kBitsPerByte));
  if Value then
    FBytes[ByteIndex] := FBytes[ByteIndex] or Mask
  else
    FBytes[ByteIndex] := FBytes[ByteIndex] and not Mask;
end;

procedure TLzmaInsertedBits.SetRange(const First, Count: NativeUInt; const Value: Boolean);
var
  Stop: NativeUInt;
  FirstByte: NativeUInt;
  LastByte: NativeUInt;
  FirstMask: Byte;
  LastMask: Byte;

  procedure ApplyMask(const ByteIndex: NativeUInt; const Mask: Byte);
  begin
    if Value then
      FBytes[ByteIndex] := FBytes[ByteIndex] or Mask
    else
      FBytes[ByteIndex] := FBytes[ByteIndex] and not Mask;
  end;

begin
  if (Count = 0) or (First >= FCount) then
    Exit;
  if Count > FCount - First then
    Stop := FCount
  else
    Stop := First + Count;
  if FBytes = nil then
  begin
    if Value then
    begin
      if First <= FPrefixCount then
      begin
        if Stop > FPrefixCount then
          FPrefixCount := Stop;
        Exit;
      end;
    end
    else
    begin
      if First >= FPrefixCount then
        Exit;
      if Stop >= FPrefixCount then
      begin
        FPrefixCount := First;
        Exit;
      end;
    end;
    Materialize;
  end;
  FirstByte := First div kBitsPerByte;
  LastByte := (Stop - 1) div kBitsPerByte;
  FirstMask := Byte($FF shl (First mod kBitsPerByte));
  LastMask := Byte($FF shr (kBitsPerByte - 1 - ((Stop - 1) mod kBitsPerByte)));
  if FirstByte = LastByte then
  begin
    ApplyMask(FirstByte, FirstMask and LastMask);
    Exit;
  end;
  ApplyMask(FirstByte, FirstMask);
  if LastByte > FirstByte + 1 then
    if Value then
      FillChar(FBytes[FirstByte + 1], LastByte - FirstByte - 1, $FF)
    else
      FillChar(FBytes[FirstByte + 1], LastByte - FirstByte - 1, 0);
  ApplyMask(LastByte, LastMask);
end;

procedure TLzmaInsertedBits.DropPrefix(const DropCount, UsedCount: NativeUInt);
var
  Remaining: NativeUInt;
  RemainingBytes: NativeUInt;
  StoredBytes: NativeUInt;
  ByteShift: NativeUInt;
  BitShift: NativeUInt;
  DestinationByte: NativeUInt;
  SourceByte: NativeUInt;
  Value: UInt32;
begin
  if (UsedCount > FCount) or (DropCount > UsedCount) then
    raise EArgumentOutOfRangeException.Create('Invalid inserted bitset window');
  if (DropCount = 0) and (UsedCount = FCount) then
    Exit;
  if FBytes = nil then
  begin
    if FPrefixCount > UsedCount then
      FPrefixCount := UsedCount;
    if FPrefixCount > DropCount then
      Dec(FPrefixCount, DropCount)
    else
      FPrefixCount := 0;
    Exit;
  end;
  Remaining := UsedCount - DropCount;
  RemainingBytes := BytesForBits(Remaining);
  StoredBytes := NativeUInt(Length(FBytes));
  ByteShift := DropCount div kBitsPerByte;
  BitShift := DropCount mod kBitsPerByte;
  if RemainingBytes <> 0 then
  begin
    if BitShift = 0 then
      Move(FBytes[ByteShift], FBytes[0], RemainingBytes)
    else
      for DestinationByte := 0 to RemainingBytes - 1 do
      begin
        SourceByte := DestinationByte + ByteShift;
        Value := UInt32(FBytes[SourceByte]) shr BitShift;
        if SourceByte + 1 < StoredBytes then
          Value := Value or (UInt32(FBytes[SourceByte + 1]) shl (kBitsPerByte - BitShift));
        FBytes[DestinationByte] := Byte(Value);
      end;
    if Remaining mod kBitsPerByte <> 0 then
      FBytes[RemainingBytes - 1] := FBytes[RemainingBytes - 1] and
        Byte((1 shl (Remaining mod kBitsPerByte)) - 1);
  end;
  if RemainingBytes < StoredBytes then
    FillChar(FBytes[RemainingBytes], StoredBytes - RemainingBytes, 0);
end;

function LzmaCompactEpochLimit: NativeUInt; inline;
begin
  if SizeOf(NativeInt) > SizeOf(UInt32) then
    Result := High(UInt32)
  else
    Result := High(NativeInt);
end;

function LzmaTryEpochPosition(const Mark: NativeInt; const PositionBase: NativeUInt;
  out RelativePos: NativeUInt): Boolean; inline;
var
  EpochPos: NativeUInt;
begin
  Result := False;
  if Mark = 0 then
    Exit;
  EpochPos := NativeUInt(Mark - 1);
  if EpochPos < PositionBase then
    Exit;
  RelativePos := EpochPos - PositionBase;
  Result := True;
end;

procedure LzmaNormalizeMarks(var Marks: TLzmaPositionLinks; const DropCount: NativeUInt);
var
  I: NativeInt;
begin
  if Marks.IsCompact then
  begin
    for I := 0 to High(Marks.FCompact) do
      if NativeUInt(Marks.FCompact[I]) > DropCount then
        Dec(Marks.FCompact[I], UInt32(DropCount))
      else
        Marks.FCompact[I] := 0;
  end
  else
    for I := 0 to High(Marks.FWide) do
      if (Marks.FWide[I] > 0) and (NativeUInt(Marks.FWide[I]) > DropCount) then
        Dec(Marks.FWide[I], NativeInt(DropCount))
      else
        Marks.FWide[I] := 0;
end;

procedure LzmaMoveMarks(var Marks: TLzmaPositionLinks;
  const SourceIndex, DestinationIndex, Count: NativeUInt);
begin
  if Count = 0 then
    Exit;
  if Marks.IsCompact then
    Move(Marks.FCompact[SourceIndex], Marks.FCompact[DestinationIndex], Count * SizeOf(UInt32))
  else
    Move(Marks.FWide[SourceIndex], Marks.FWide[DestinationIndex], Count * SizeOf(NativeInt));
end;

procedure LzmaClearMarks(var Marks: TLzmaPositionLinks; const First, Count: NativeUInt);
begin
  if Count = 0 then
    Exit;
  if Marks.IsCompact then
    FillChar(Marks.FCompact[First], Count * SizeOf(UInt32), 0)
  else
    FillChar(Marks.FWide[First], Count * SizeOf(NativeInt), 0);
end;

procedure LzmaRotateMarksLeft(var Marks: TLzmaPositionLinks; const Shift: NativeUInt);
var
  Count, EffectiveShift: NativeInt;

  procedure ReverseCompact(const First, Last: NativeInt);
  var
    L, R: NativeInt;
    Value: UInt32;
  begin
    L := First;
    R := Last;
    while L < R do
    begin
      Value := Marks.FCompact[L];
      Marks.FCompact[L] := Marks.FCompact[R];
      Marks.FCompact[R] := Value;
      Inc(L);
      Dec(R);
    end;
  end;

  procedure ReverseWide(const First, Last: NativeInt);
  var
    L, R, Value: NativeInt;
  begin
    L := First;
    R := Last;
    while L < R do
    begin
      Value := Marks.FWide[L];
      Marks.FWide[L] := Marks.FWide[R];
      Marks.FWide[R] := Value;
      Inc(L);
      Dec(R);
    end;
  end;

begin
  Count := Marks.Count;
  if Count = 0 then
    Exit;
  EffectiveShift := NativeInt(Shift mod NativeUInt(Count));
  if EffectiveShift = 0 then
    Exit;
  if Marks.IsCompact then
  begin
    ReverseCompact(0, EffectiveShift - 1);
    ReverseCompact(EffectiveShift, Count - 1);
    ReverseCompact(0, Count - 1);
  end
  else
  begin
    ReverseWide(0, EffectiveShift - 1);
    ReverseWide(EffectiveShift, Count - 1);
    ReverseWide(0, Count - 1);
  end;
end;

constructor TLzmaGreedyMatchFinder.Create(const Data: TBytes; const Offset, Count: NativeUInt;
  const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32; const CutValue: UInt32);
begin
  inherited Create;
  if Offset > NativeUInt(Length(Data)) then
    raise EArgumentOutOfRangeException.Create('Invalid match finder offset');
  if Count > NativeUInt(Length(Data)) - Offset then
    raise EArgumentOutOfRangeException.Create('Invalid match finder count');

  FData := Data;
  FOffset := Offset;
  FCount := Count;
  FMaxDistance := DictionarySize;
  if FMaxDistance > Count then
    FMaxDistance := Count;
  FFastBytes := FastBytes;
  if FFastBytes < kMinHashLength then
    FFastBytes := kMinHashLength;
  if FFastBytes > MaxMatchLen then
    FFastBytes := MaxMatchLen;
  FMaxMatchLen := MaxMatchLen;
  if FMaxMatchLen < FFastBytes then
    FMaxMatchLen := FFastBytes;
  if CutValue = 0 then
    FMaxDepth := kDefaultHashDepth
  else
    FMaxDepth := CutValue;
  FHeads2.Initialize(kHash2Size, Count);
  FHeads.Initialize(kHashSize, Count);
  FPrev.Initialize(Count, Count);
  FInserted.Initialize(Count);
end;

function TLzmaGreedyMatchFinder.Hash2At(const RelativePos: NativeUInt): NativeInt;
begin
  Result := ((NativeInt(FData[FOffset + RelativePos]) shl 4) xor
    NativeInt(FData[FOffset + RelativePos + 1])) and (kHash2Size - 1);
end;

function TLzmaGreedyMatchFinder.HashAt(const RelativePos: NativeUInt): NativeInt;
begin
  Result := ((NativeInt(FData[FOffset + RelativePos]) shl 8) xor
    (NativeInt(FData[FOffset + RelativePos + 1]) shl 4) xor
    NativeInt(FData[FOffset + RelativePos + 2])) and (kHashSize - 1);
end;

procedure TLzmaGreedyMatchFinder.Insert(const RelativePos: NativeUInt);
var
  H2: NativeInt;
  H: NativeInt;
begin
  if RelativePos >= FCount then
    Exit;
  if FInserted[RelativePos] then
    Exit;
  FInserted[RelativePos] := True;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinLowHashLength) then
    Exit;
  H2 := Hash2At(RelativePos);
  FHeads2[H2] := NativeInt(FPositionBase + RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHashLength) then
    Exit;
  H := HashAt(RelativePos);
  FPrev[RelativePos] := FHeads[H];
  FHeads[H] := NativeInt(FPositionBase + RelativePos) + 1;
end;

procedure TLzmaGreedyMatchFinder.InsertRange(const RelativePos, Count: NativeUInt);
var
  Pos: NativeUInt;
  StopPos: NativeUInt;
begin
  if (Count = 0) or (RelativePos >= FCount) then
    Exit;
  Pos := RelativePos;
  StopPos := RelativePos + Count;
  if (StopPos < RelativePos) or (StopPos > FCount) then
    StopPos := FCount;
  while Pos < StopPos do
  begin
    Insert(Pos);
    Inc(Pos);
  end;
end;

procedure TLzmaGreedyMatchFinder.ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches := FLastReadMatches;
    Exit;
  end;

  GetMatches(RelativePos, Matches);
  Insert(RelativePos);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches := Matches;
end;

procedure TLzmaGreedyMatchFinder.ReadMatchPairs(const RelativePos: NativeUInt;
  var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches.CopyPairsFrom(FLastReadMatches);
    Exit;
  end;

  GetMatches(RelativePos, Matches);
  Insert(RelativePos);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches.CopyPairsFrom(Matches);
end;

procedure TLzmaGreedyMatchFinder.GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
var
  H: NativeInt;
  CandidateMark: NativeInt;
  Candidate: NativeUInt;
  Distance: NativeUInt;
  CurrentLen: UInt32;
  BestLen: UInt32;
  MaxLen: UInt32;
  CurrentBase: NativeUInt;
  CandidateBase: NativeUInt;
  Depth: UInt32;

begin
  Matches.Clear;
  if not LzmaHasBytesAt(RelativePos, FCount, kMinLowHashLength) then
    Exit;

  MaxLen := FMaxMatchLen;
  if FCount - RelativePos < NativeUInt(MaxLen) then
    MaxLen := UInt32(FCount - RelativePos);
  if MaxLen < kMinLowHashLength then
    Exit;

  H := Hash2At(RelativePos);
  CandidateMark := FHeads2[H];
  if LzmaTryEpochPosition(CandidateMark, FPositionBase, Candidate) then
  begin
    if Candidate < RelativePos then
    begin
      Distance := RelativePos - Candidate;
      if (Distance <= FMaxDistance) and
        (FData[FOffset + Candidate] = FData[FOffset + RelativePos]) and
        (FData[FOffset + Candidate + 1] = FData[FOffset + RelativePos + 1]) then
      begin
        if (MaxLen >= kMinHashLength) and
          (FData[FOffset + Candidate + 2] = FData[FOffset + RelativePos + 2]) then
          BestLen := 0
        else
        begin
          BestLen := kMinLowHashLength;
          Matches.Add(BestLen, UInt32(Distance));
        end;
      end
      else
        BestLen := 0;
    end
    else
      BestLen := 0;
  end
  else
    BestLen := 0;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHashLength) then
    Exit;
  if MaxLen < kMinHashLength then
    Exit;

  H := HashAt(RelativePos);
  CandidateMark := FHeads[H];
  Depth := 0;
  CurrentBase := FOffset + RelativePos;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, Candidate) then
      Break;
    if Candidate >= RelativePos then
      Break;
    Distance := RelativePos - Candidate;
    if Distance > FMaxDistance then
      Break;

    CandidateBase := FOffset + Candidate;
    if FData[CandidateBase + BestLen] = FData[CurrentBase + BestLen] then
    begin
      CurrentLen := LzmaCountMatchingBytes(FData, CandidateBase, CurrentBase, MaxLen);
      if (CurrentLen >= kMinHashLength) and (CurrentLen > BestLen) then
      begin
        BestLen := CurrentLen;
        Matches.Add(CurrentLen, UInt32(Distance));
        if BestLen = MaxLen then
          Break;
      end;
    end;

    CandidateMark := FPrev[Candidate];
    Inc(Depth);
  end;
end;

function TLzmaGreedyMatchFinder.GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray;
var
  Buffer: TLzmaMatchBuffer;
  I: Integer;
begin
  GetMatches(RelativePos, Buffer);
  SetLength(Result, Buffer.Count);
  for I := 0 to Buffer.Count - 1 do
    Result[I] := Buffer.Items[I];
end;

function TLzmaGreedyMatchFinder.Find(const RelativePos: NativeUInt): TLzmaMatch;
var
  Matches: TLzmaMatchBuffer;
begin
  GetMatches(RelativePos, Matches);
  Result := Matches.Last;
end;

constructor TLzmaHashChain4MatchFinder.Create(const Data: TBytes; const Offset, Count: NativeUInt;
  const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32; const CutValue: UInt32);
var
  Allocation: TLzmaMatchFinderAllocation;
begin
  inherited Create;
  if Offset > NativeUInt(Length(Data)) then
    raise EArgumentOutOfRangeException.Create('Invalid match finder offset');
  if Count > NativeUInt(Length(Data)) - Offset then
    raise EArgumentOutOfRangeException.Create('Invalid match finder count');

  Allocation := LzmaMatchFinderAllocation(Count, DictionarySize, mfHashChain4);
  FData := Data;
  FOffset := Offset;
  FCount := Count;
  FMaxDistance := Allocation.HistorySize;
  FCyclicBufferSize := Allocation.CyclicSize;
  FFastBytes := FastBytes;
  if FFastBytes < kMinHash4Length then
    FFastBytes := kMinHash4Length;
  if FFastBytes > MaxMatchLen then
    FFastBytes := MaxMatchLen;
  FMaxMatchLen := MaxMatchLen;
  if FMaxMatchLen < FFastBytes then
    FMaxMatchLen := FFastBytes;
  if CutValue = 0 then
    FMaxDepth := kDefaultHashDepth
  else
    FMaxDepth := CutValue;
  FHash4Mask := Allocation.HashMask;
  FHeads2.Initialize(Allocation.Hash2Slots, Count);
  FHeads3.Initialize(Allocation.Hash3Slots, Count);
  FHeads4.Initialize(Allocation.HashSlots, Count);
  FPrev.Initialize(Allocation.LinkSlots, Count);
  FInserted.Initialize(Count);
end;

function TLzmaHashChain4MatchFinder.Hash2At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Result := NativeInt(Temp and (kHash2Size - 1));
end;

function TLzmaHashChain4MatchFinder.Hash3At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Result := NativeInt(Temp and (kHash3Size - 1));
end;

function TLzmaHashChain4MatchFinder.Hash4At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Temp := Temp xor GLzmaHashCrcShift1[FData[FOffset + RelativePos + 3]];
  Result := NativeInt(NativeUInt(Temp) and FHash4Mask);
end;

procedure TLzmaHashChain4MatchFinder.Insert(const RelativePos: NativeUInt);
var
  H: NativeInt;
begin
  if RelativePos >= FCount then
    Exit;
  if FInserted[RelativePos] then
    Exit;
  FInserted[RelativePos] := True;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinLowHashLength) then
    Exit;
  H := Hash2At(RelativePos);
  FHeads2[H] := NativeInt(FPositionBase + RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash3Length) then
    Exit;
  H := Hash3At(RelativePos);
  FHeads3[H] := NativeInt(FPositionBase + RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;
  H := Hash4At(RelativePos);
  FPrev[(FPositionBase + RelativePos + FCyclicPhase) mod FCyclicBufferSize] := FHeads4[H];
  FHeads4[H] := NativeInt(FPositionBase + RelativePos) + 1;
end;

procedure TLzmaHashChain4MatchFinder.InsertRange(const RelativePos, Count: NativeUInt);
var
  Pos: NativeUInt;
  StopPos: NativeUInt;
begin
  if (Count = 0) or (RelativePos >= FCount) then
    Exit;
  Pos := RelativePos;
  StopPos := RelativePos + Count;
  if (StopPos < RelativePos) or (StopPos > FCount) then
    StopPos := FCount;
  while Pos < StopPos do
  begin
    Insert(Pos);
    Inc(Pos);
  end;
end;

procedure TLzmaHashChain4MatchFinder.SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
var
  ChainSlot: NativeUInt;
  Cur: PByte;
  FullHashStop: NativeUInt;
  H: NativeInt;
  Heads2: PPositionLinkArray;
  Heads3: PPositionLinkArray;
  Heads4: PPositionLinkArray;
  Mark: NativeInt;
  Pos: NativeUInt;
  Prev: PPositionLinkArray;
  PrevSlot: PUInt32;
  Remaining: NativeUInt;
  RunRemaining: NativeUInt;
  StopPos: NativeUInt;
  Temp: UInt32;
begin
  if (Count = 0) or (RelativePos >= FCount) then
    Exit;

  Pos := RelativePos;
  StopPos := RelativePos + Count;
  if (StopPos < RelativePos) or (StopPos > FCount) then
    StopPos := FCount;

  if not FPrev.IsCompact then
  begin
    // The bulk loop updates links even for positions already inserted.
    while Pos < StopPos do
    begin
      FInserted[Pos] := False;
      Insert(Pos);
      Inc(Pos);
    end;
    Exit;
  end;

  FInserted.SetRange(RelativePos, StopPos - RelativePos);

  if FCount >= kMinHash4Length then
  begin
    FullHashStop := FCount - kMinHash4Length + 1;
    if FullHashStop > StopPos then
      FullHashStop := StopPos;
  end
  else
    FullHashStop := Pos;

  if FullHashStop > Pos then
    Remaining := FullHashStop - Pos
  else
    Remaining := 0;
  if Remaining <> 0 then
    Cur := @FData[FOffset + Pos]
  else
    Cur := nil;

  Heads2 := PPositionLinkArray(FHeads2.CompactData);
  Heads3 := PPositionLinkArray(FHeads3.CompactData);
  Heads4 := PPositionLinkArray(FHeads4.CompactData);
  Prev := PPositionLinkArray(FPrev.CompactData);
  ChainSlot := (FPositionBase + Pos + FCyclicPhase) mod FCyclicBufferSize;
  Mark := NativeInt(FPositionBase + Pos) + 1;
  while Remaining <> 0 do
  begin
    RunRemaining := FCyclicBufferSize - ChainSlot;
    if RunRemaining > Remaining then
      RunRemaining := Remaining;
    PrevSlot := @Prev^[ChainSlot];
    Inc(ChainSlot, RunRemaining);
    if ChainSlot = FCyclicBufferSize then
      ChainSlot := 0;

    Dec(Remaining, RunRemaining);
    while RunRemaining <> 0 do
    begin
      Temp := (GLzmaHashCrc[Cur^] xor UInt32(PByte(NativeUInt(Cur) + 1)^));

      H := NativeInt(Temp and (kHash2Size - 1));
      Heads2^[H] := UInt32(Mark);

      Temp := Temp xor (UInt32(PByte(NativeUInt(Cur) + 2)^) shl 8);
      H := NativeInt(Temp and (kHash3Size - 1));
      Heads3^[H] := UInt32(Mark);

      Temp := Temp xor GLzmaHashCrcShift1[PByte(NativeUInt(Cur) + 3)^];
      H := NativeInt(NativeUInt(Temp) and FHash4Mask);
      PrevSlot^ := Heads4^[H];
      Heads4^[H] := UInt32(Mark);
      Inc(Cur);
      Inc(PrevSlot);
      Inc(Mark);
      Dec(RunRemaining);
    end;
  end;
  Pos := FullHashStop;

  while Pos < StopPos do
  begin
    if LzmaHasBytesAt(Pos, FCount, kMinLowHashLength) then
    begin
      Mark := NativeInt(FPositionBase + Pos) + 1;
      Temp := (GLzmaHashCrc[FData[FOffset + Pos]] xor UInt32(FData[FOffset + Pos + 1]));
      H := NativeInt(Temp and (kHash2Size - 1));
      FHeads2[H] := Mark;

      if LzmaHasBytesAt(Pos, FCount, kMinHash3Length) then
      begin
        Temp := Temp xor (UInt32(FData[FOffset + Pos + 2]) shl 8);
        H := NativeInt(Temp and (kHash3Size - 1));
        FHeads3[H] := Mark;
      end;
    end;
    Inc(Pos);
  end;
end;

procedure TLzmaHashChain4MatchFinder.ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches := FLastReadMatches;
    Exit;
  end;

  GetMatches(RelativePos, Matches);
  Insert(RelativePos);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches := Matches;
end;

procedure TLzmaHashChain4MatchFinder.ReadMatchPairs(const RelativePos: NativeUInt;
  var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches.CopyPairsFrom(FLastReadMatches);
    Exit;
  end;

  GetMatches(RelativePos, Matches);
  Insert(RelativePos);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches.CopyPairsFrom(Matches);
end;

procedure TLzmaHashChain4MatchFinder.GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
var
  H: NativeInt;
  CandidateMark: NativeInt;
  Candidate: NativeUInt;
  Distance: NativeUInt;
  CurrentLen: UInt32;
  BestLen: UInt32;
  MaxLen: UInt32;
  CurrentBase: NativeUInt;
  CandidateBase: NativeUInt;
  Depth: UInt32;

  function TryMeasureLowHashCandidate(const CandidateMark: NativeInt;
    const MinLen: UInt32; out MatchDistance, MatchLen: UInt32): Boolean;
  var
    CandidatePos: NativeUInt;
    Distance: NativeUInt;
  begin
    Result := False;
    MatchDistance := 0;
    MatchLen := 0;
    if CandidateMark = 0 then
      Exit;

    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, CandidatePos) then
      Exit;
    if CandidatePos >= RelativePos then
      Exit;
    Distance := RelativePos - CandidatePos;
    if Distance > FMaxDistance then
      Exit;

    MatchLen := LzmaCountMatchingBytes(FData, FOffset + CandidatePos, CurrentBase, MaxLen);
    if MatchLen < MinLen then
      Exit;

    MatchDistance := UInt32(Distance);
    Result := True;
  end;

  procedure AddSdkLowHashMatches;
  var
    H2Distance: UInt32;
    H2Len: UInt32;
    H3Distance: UInt32;
    H3Len: UInt32;
  begin
    if TryMeasureLowHashCandidate(FHeads2[Hash2At(RelativePos)], kMinLowHashLength,
      H2Distance, H2Len) then
    begin
      if H2Len = kMinLowHashLength then
      begin
        BestLen := H2Len;
        Matches.Add(H2Len, H2Distance);
        if TryMeasureLowHashCandidate(FHeads3[Hash3At(RelativePos)], kMinHash3Length,
          H3Distance, H3Len) then
        begin
          BestLen := H3Len;
          Matches.Add(H3Len, H3Distance);
        end;
      end
      else
      begin
        BestLen := H2Len;
        Matches.Add(H2Len, H2Distance);
      end;
      Exit;
    end;

    if TryMeasureLowHashCandidate(FHeads3[Hash3At(RelativePos)], kMinHash3Length,
      H3Distance, H3Len) then
    begin
      BestLen := H3Len;
      Matches.Add(H3Len, H3Distance);
    end;
  end;
begin
  Matches.Clear;
  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;

  MaxLen := FMaxMatchLen;
  if FCount - RelativePos < NativeUInt(MaxLen) then
    MaxLen := UInt32(FCount - RelativePos);
  if MaxLen < kMinLowHashLength then
    Exit;

  BestLen := 0;
  CurrentBase := FOffset + RelativePos;
  AddSdkLowHashMatches;
  if BestLen = MaxLen then
    Exit;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;
  if MaxLen < kMinHash4Length then
    Exit;

  H := Hash4At(RelativePos);
  CandidateMark := FHeads4[H];
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, Candidate) then
      Break;
    if Candidate >= RelativePos then
      Break;
    Distance := RelativePos - Candidate;
    if Distance > FMaxDistance then
      Break;

    CandidateBase := FOffset + Candidate;
    if FData[CandidateBase + BestLen] = FData[CurrentBase + BestLen] then
    begin
      CurrentLen := LzmaCountMatchingBytes(FData, CandidateBase, CurrentBase, MaxLen);
      if (CurrentLen >= kMinHash4Length) and (CurrentLen > BestLen) then
      begin
        BestLen := CurrentLen;
        Matches.Add(CurrentLen, UInt32(Distance));
        if BestLen = MaxLen then
          Break;
      end;
    end;

    CandidateMark := FPrev[(FPositionBase + Candidate + FCyclicPhase) mod FCyclicBufferSize];
    Inc(Depth);
  end;
end;

function TLzmaHashChain4MatchFinder.GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray;
var
  Buffer: TLzmaMatchBuffer;
  I: Integer;
begin
  GetMatches(RelativePos, Buffer);
  SetLength(Result, Buffer.Count);
  for I := 0 to Buffer.Count - 1 do
    Result[I] := Buffer.Items[I];
end;

function TLzmaHashChain4MatchFinder.ChainSlotCount: NativeUInt;
begin
  Result := NativeUInt(FPrev.Count);
end;

function TLzmaHashChain4MatchFinder.Find(const RelativePos: NativeUInt): TLzmaMatch;
var
  Matches: TLzmaMatchBuffer;
begin
  GetMatches(RelativePos, Matches);
  Result := Matches.Last;
end;

constructor TLzmaHashChain5MatchFinder.Create(const Data: TBytes; const Offset, Count: NativeUInt;
  const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32; const CutValue: UInt32);
var
  Allocation: TLzmaMatchFinderAllocation;
begin
  inherited Create;
  if Offset > NativeUInt(Length(Data)) then
    raise EArgumentOutOfRangeException.Create('Invalid match finder offset');
  if Count > NativeUInt(Length(Data)) - Offset then
    raise EArgumentOutOfRangeException.Create('Invalid match finder count');

  Allocation := LzmaMatchFinderAllocation(Count, DictionarySize, mfHashChain5);
  FData := Data;
  FOffset := Offset;
  FCount := Count;
  FMaxDistance := Allocation.HistorySize;
  FCyclicBufferSize := Allocation.CyclicSize;
  FFastBytes := FastBytes;
  if FFastBytes < kMinHash5Length then
    FFastBytes := kMinHash5Length;
  if FFastBytes > MaxMatchLen then
    FFastBytes := MaxMatchLen;
  FMaxMatchLen := MaxMatchLen;
  if FMaxMatchLen < FFastBytes then
    FMaxMatchLen := FFastBytes;
  if CutValue = 0 then
    FMaxDepth := kDefaultHashDepth
  else
    FMaxDepth := CutValue;
  FHash5Mask := Allocation.HashMask;
  FHeads2.Initialize(Allocation.Hash2Slots, Count);
  FHeads3.Initialize(Allocation.Hash3Slots, Count);
  FHeads5.Initialize(Allocation.HashSlots, Count);
  FPrev.Initialize(Allocation.LinkSlots, Count);
  FInserted.Initialize(Count);
end;

function TLzmaHashChain5MatchFinder.Hash2At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Result := NativeInt(Temp and (kHash2Size - 1));
end;

function TLzmaHashChain5MatchFinder.Hash3At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Result := NativeInt(Temp and (kHash3Size - 1));
end;

function TLzmaHashChain5MatchFinder.Hash5At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Temp := Temp xor (GLzmaHashCrcShift1[FData[FOffset + RelativePos + 3]] xor GLzmaHashCrcShift2[FData[FOffset + RelativePos + 4]]);
  Result := NativeInt(NativeUInt(Temp) and FHash5Mask);
end;

procedure TLzmaHashChain5MatchFinder.Insert(const RelativePos: NativeUInt);
var
  H: NativeInt;
begin
  if RelativePos >= FCount then
    Exit;
  if FInserted[RelativePos] then
    Exit;
  FInserted[RelativePos] := True;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash5Length) then
    Exit;
  H := Hash2At(RelativePos);
  FHeads2[H] := NativeInt(FPositionBase + RelativePos) + 1;

  H := Hash3At(RelativePos);
  FHeads3[H] := NativeInt(FPositionBase + RelativePos) + 1;

  H := Hash5At(RelativePos);
  FPrev[(FPositionBase + RelativePos + FCyclicPhase) mod FCyclicBufferSize] := FHeads5[H];
  FHeads5[H] := NativeInt(FPositionBase + RelativePos) + 1;
end;

procedure TLzmaHashChain5MatchFinder.InsertRange(const RelativePos, Count: NativeUInt);
var
  Pos: NativeUInt;
  StopPos: NativeUInt;
begin
  if (Count = 0) or (RelativePos >= FCount) then
    Exit;
  Pos := RelativePos;
  StopPos := RelativePos + Count;
  if (StopPos < RelativePos) or (StopPos > FCount) then
    StopPos := FCount;
  while Pos < StopPos do
  begin
    Insert(Pos);
    Inc(Pos);
  end;
end;

procedure TLzmaHashChain5MatchFinder.SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
var
  Cur: PByte;
  FullHashStop: NativeUInt;
  H: NativeInt;
  Heads2: PPositionLinkArray;
  Heads3: PPositionLinkArray;
  Heads5: PPositionLinkArray;
  Mark: NativeInt;
  Pos: NativeUInt;
  Prev: PPositionLinkArray;
  PrevSlot: PUInt32;
  Remaining: NativeUInt;
  RunRemaining: NativeUInt;
  ChainSlot: NativeUInt;
  StopPos: NativeUInt;
  Temp: UInt32;
begin
  if (Count = 0) or (RelativePos >= FCount) then
    Exit;

  Pos := RelativePos;
  StopPos := RelativePos + Count;
  if (StopPos < RelativePos) or (StopPos > FCount) then
    StopPos := FCount;

  if not FPrev.IsCompact then
  begin
    // The bulk loop updates links even for positions already inserted.
    while Pos < StopPos do
    begin
      FInserted[Pos] := False;
      Insert(Pos);
      Inc(Pos);
    end;
    Exit;
  end;

  FInserted.SetRange(RelativePos, StopPos - RelativePos);

  if FCount >= kMinHash5Length then
  begin
    FullHashStop := FCount - kMinHash5Length + 1;
    if FullHashStop > StopPos then
      FullHashStop := StopPos;
  end
  else
    FullHashStop := Pos;

  if FullHashStop > Pos then
    Remaining := FullHashStop - Pos
  else
    Remaining := 0;
  if Remaining <> 0 then
    Cur := @FData[FOffset + Pos]
  else
    Cur := nil;
  Heads2 := PPositionLinkArray(FHeads2.CompactData);
  Heads3 := PPositionLinkArray(FHeads3.CompactData);
  Heads5 := PPositionLinkArray(FHeads5.CompactData);
  Prev := PPositionLinkArray(FPrev.CompactData);
  ChainSlot := (FPositionBase + Pos + FCyclicPhase) mod FCyclicBufferSize;
  Mark := NativeInt(FPositionBase + Pos) + 1;
  while Remaining <> 0 do
  begin
    RunRemaining := FCyclicBufferSize - ChainSlot;
    if RunRemaining > Remaining then
      RunRemaining := Remaining;
    PrevSlot := @Prev^[ChainSlot];
    Inc(ChainSlot, RunRemaining);
    if ChainSlot = FCyclicBufferSize then
      ChainSlot := 0;

    Dec(Remaining, RunRemaining);
    while RunRemaining <> 0 do
    begin
      Temp := (GLzmaHashCrc[Cur^] xor UInt32(PByte(NativeUInt(Cur) + 1)^));

      H := NativeInt(Temp and (kHash2Size - 1));
      Heads2^[H] := UInt32(Mark);

      Temp := Temp xor (UInt32(PByte(NativeUInt(Cur) + 2)^) shl 8);
      H := NativeInt(Temp and (kHash3Size - 1));
      Heads3^[H] := UInt32(Mark);

      Temp := Temp xor (GLzmaHashCrcShift1[PByte(NativeUInt(Cur) + 3)^] xor GLzmaHashCrcShift2[PByte(NativeUInt(Cur) + 4)^]);
      H := NativeInt(NativeUInt(Temp) and FHash5Mask);
      PrevSlot^ := Heads5^[H];
      Heads5^[H] := UInt32(Mark);
      Inc(Cur);
      Inc(PrevSlot);
      Inc(Mark);
      Dec(RunRemaining);
    end;
  end;
  Pos := FullHashStop;

  while Pos < StopPos do
  begin
    if LzmaHasBytesAt(Pos, FCount, kMinLowHashLength) then
    begin
      Mark := NativeInt(FPositionBase + Pos) + 1;
      Temp := (GLzmaHashCrc[FData[FOffset + Pos]] xor UInt32(FData[FOffset + Pos + 1]));
      H := NativeInt(Temp and (kHash2Size - 1));
      FHeads2[H] := Mark;

      if LzmaHasBytesAt(Pos, FCount, kMinHash3Length) then
      begin
        Temp := Temp xor (UInt32(FData[FOffset + Pos + 2]) shl 8);
        H := NativeInt(Temp and (kHash3Size - 1));
        FHeads3[H] := Mark;
      end;
    end;
    Inc(Pos);
  end;
end;

procedure TLzmaHashChain5MatchFinder.ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches := FLastReadMatches;
    Exit;
  end;

  GetMatches(RelativePos, Matches);
  Insert(RelativePos);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches := Matches;
end;

procedure TLzmaHashChain5MatchFinder.ReadMatchPairs(const RelativePos: NativeUInt;
  var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches.CopyPairsFrom(FLastReadMatches);
    Exit;
  end;

  GetMatches(RelativePos, Matches);
  Insert(RelativePos);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches.CopyPairsFrom(Matches);
end;

procedure TLzmaHashChain5MatchFinder.GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
var
  H: NativeInt;
  CandidateMark: NativeInt;
  Candidate: NativeUInt;
  Distance: NativeUInt;
  CurrentLen: UInt32;
  BestLen: UInt32;
  MaxLen: UInt32;
  CurrentBase: NativeUInt;
  CandidateBase: NativeUInt;
  Depth: UInt32;
  CurrentChainSlot: NativeUInt;
  CandidateChainSlot: NativeUInt;

  procedure AddLowHashMatch(const CandidateMark: NativeInt; const MinLen: UInt32);
  begin
    if CandidateMark = 0 then
      Exit;
    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, Candidate) then
      Exit;
    if Candidate >= RelativePos then
      Exit;
    Distance := RelativePos - Candidate;
    if Distance > FMaxDistance then
      Exit;

    CandidateBase := FOffset + Candidate;
    CurrentLen := LzmaCountMatchingBytes(FData, CandidateBase, CurrentBase, MaxLen);
    if (CurrentLen >= MinLen) and (CurrentLen > BestLen) then
    begin
      BestLen := CurrentLen;
      Matches.Add(CurrentLen, UInt32(Distance));
    end;
  end;

begin
  Matches.Clear;
  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash5Length) then
    Exit;

  MaxLen := FMaxMatchLen;
  if FCount - RelativePos < NativeUInt(MaxLen) then
    MaxLen := UInt32(FCount - RelativePos);
  if MaxLen < kMinHash5Length then
    Exit;

  BestLen := 0;
  CurrentBase := FOffset + RelativePos;

  H := Hash2At(RelativePos);
  AddLowHashMatch(FHeads2[H], kMinLowHashLength);

  H := Hash3At(RelativePos);
  AddLowHashMatch(FHeads3[H], kMinHash3Length);
  if BestLen = MaxLen then
    Exit;

  H := Hash5At(RelativePos);
  CandidateMark := FHeads5[H];
  if CandidateMark = 0 then
    Exit;
  CurrentChainSlot := (FPositionBase + RelativePos + FCyclicPhase) mod FCyclicBufferSize;
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, Candidate) then
      Break;
    if Candidate >= RelativePos then
      Break;
    Distance := RelativePos - Candidate;
    if Distance > FMaxDistance then
      Break;

    CandidateBase := FOffset + Candidate;
    if FData[CandidateBase + BestLen] = FData[CurrentBase + BestLen] then
    begin
      CurrentLen := LzmaCountMatchingBytes(FData, CandidateBase, CurrentBase, MaxLen);
      if (CurrentLen >= kMinHash5Length) and (CurrentLen > BestLen) then
      begin
        BestLen := CurrentLen;
        Matches.Add(CurrentLen, UInt32(Distance));
        if BestLen = MaxLen then
          Break;
      end;
    end;

    // Distance is smaller than the cyclic buffer, so one wrap replaces division.
    if Distance <= CurrentChainSlot then
      CandidateChainSlot := CurrentChainSlot - Distance
    else
      CandidateChainSlot := FCyclicBufferSize - (Distance - CurrentChainSlot);
    CandidateMark := FPrev[CandidateChainSlot];
    Inc(Depth);
  end;
end;

function TLzmaHashChain5MatchFinder.GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray;
var
  Buffer: TLzmaMatchBuffer;
  I: Integer;
begin
  GetMatches(RelativePos, Buffer);
  SetLength(Result, Buffer.Count);
  for I := 0 to Buffer.Count - 1 do
    Result[I] := Buffer.Items[I];
end;

function TLzmaHashChain5MatchFinder.ChainSlotCount: NativeUInt;
begin
  Result := NativeUInt(FPrev.Count);
end;

function TLzmaHashChain5MatchFinder.Find(const RelativePos: NativeUInt): TLzmaMatch;
var
  Matches: TLzmaMatchBuffer;
begin
  GetMatches(RelativePos, Matches);
  Result := Matches.Last;
end;

constructor TLzmaBinaryTree4MatchFinder.Create(const Data: TBytes; const Offset, Count: NativeUInt;
  const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32; const CutValue: UInt32);
var
  Allocation: TLzmaMatchFinderAllocation;
begin
  inherited Create;
  if Offset > NativeUInt(Length(Data)) then
    raise EArgumentOutOfRangeException.Create('Invalid match finder offset');
  if Count > NativeUInt(Length(Data)) - Offset then
    raise EArgumentOutOfRangeException.Create('Invalid match finder count');

  Allocation := LzmaMatchFinderAllocation(Count, DictionarySize, mfBinaryTree4);
  FData := Data;
  FOffset := Offset;
  FCount := Count;
  FMaxDistance := Allocation.HistorySize;
  FCyclicBufferSize := Allocation.CyclicSize;
  FFastBytes := FastBytes;
  if FFastBytes < kMinHash4Length then
    FFastBytes := kMinHash4Length;
  if FFastBytes > MaxMatchLen then
    FFastBytes := MaxMatchLen;
  FMaxMatchLen := MaxMatchLen;
  if FMaxMatchLen < FFastBytes then
    FMaxMatchLen := FFastBytes;
  if CutValue = 0 then
    FMaxDepth := kDefaultHashDepth
  else
    FMaxDepth := CutValue;
  FHash4Mask := Allocation.HashMask;
  FHeads2.Initialize(Allocation.Hash2Slots, Count);
  FHeads3.Initialize(Allocation.Hash3Slots, Count);
  FHeads4.Initialize(Allocation.HashSlots, Count);
  FSons.Initialize(Allocation.LinkSlots, Count);
  FInserted.Initialize(Count);
  FFusedReadSafe := True;
end;

class function TLzmaBinaryTree4MatchFinder.CreateSdkMtHighHash(const Data: TBytes;
  const Offset, Count: NativeUInt; const DictionarySize: UInt64;
  const FastBytes, MaxMatchLen, CutValue: UInt32): TLzmaBinaryTree4MatchFinder;
begin
  Result := TLzmaBinaryTree4MatchFinder.Create(Data, Offset, Count, DictionarySize,
    FastBytes, MaxMatchLen, CutValue);
  // SDK LzmaEnc.c selects GetHeads4b only after the actual mask is known.
  Result.FUseSdkMtHighHash := Result.FHash4Mask >= NativeUInt($FFFFFF);
end;

function TLzmaBinaryTree4MatchFinder.Hash2At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Result := NativeInt(Temp and (kHash2Size - 1));
end;

function TLzmaBinaryTree4MatchFinder.Hash3At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Result := NativeInt(Temp and (kHash3Size - 1));
end;

function TLzmaBinaryTree4MatchFinder.Hash4At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  if FUseSdkMtHighHash then
  begin
    // SDK LzFindMt.c GetHeads4b: CRC[b0] xor the raw next three bytes.
    Temp := GLzmaHashCrc[FData[FOffset + RelativePos]] xor
      UInt32(FData[FOffset + RelativePos + 1]) xor
      (UInt32(FData[FOffset + RelativePos + 2]) shl 8) xor
      (UInt32(FData[FOffset + RelativePos + 3]) shl 16);
    Result := NativeInt(NativeUInt(Temp) and FHash4Mask);
    Exit;
  end;
  Temp := (GLzmaHashCrc[FData[FOffset + RelativePos]] xor UInt32(FData[FOffset + RelativePos + 1]));
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Temp := Temp xor GLzmaHashCrcShift1[FData[FOffset + RelativePos + 3]];
  Result := NativeInt(NativeUInt(Temp) and FHash4Mask);
end;

function TLzmaBinaryTree4MatchFinder.SonIndex(const RelativePos: NativeUInt; const Right: Boolean): NativeInt;
var
  CyclicPos: NativeUInt;
begin
  CyclicPos := (FPositionBase + RelativePos + FCyclicPhase) mod FCyclicBufferSize;
  Result := NativeInt(CyclicPos) * 2 + Ord(Right);
end;

{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
type
  PLzmaBt4CompactInsertContext = ^TLzmaBt4CompactInsertContext;
  TLzmaBt4CompactInsertContext = record
    DataBase: PByte;
    CurrentBase: PByte;
    Sons: PUInt32;
    CurrentEpochPos: NativeUInt;
    PositionBase: NativeUInt;
    CurrentCyclicPos: NativeUInt;
    CyclicBufferSize: NativeUInt;
    MaxDistance: NativeUInt;
    CandidateMark: NativeUInt;
    PtrLess: NativeInt;
    PtrGreater: NativeInt;
    MaxLen: UInt32;
    MaxDepth: UInt32;
  end;


{$IFDEF LZMA_MF_NATIVE_COMPACT_COLLECT}
  PLzmaBt4CompactCollectContext = ^TLzmaBt4CompactCollectContext;
  TLzmaBt4CompactCollectContext = record
    DataBase: PByte;
    CurrentBase: PByte;
    Sons: PUInt32;
    CurrentEpochPos: NativeUInt;
    PositionBase: NativeUInt;
    CurrentCyclicPos: NativeUInt;
    CyclicBufferSize: NativeUInt;
    MaxDistance: NativeUInt;
    CandidateMark: NativeUInt;
    PtrLess: NativeInt;
    PtrGreater: NativeInt;
    MaxLen: UInt32;
    MaxDepth: UInt32;
    Matches: Pointer;
    BestLen: UInt32;
  end;

{$ENDIF}
var
  LzmaBt4Avx2Enabled: Boolean;

function LzmaCpuOsAvx2:Boolean;
asm
        .PARAMS 0
        .PUSHNV RBX
        XOR     EAX,EAX
        CPUID
        CMP     EAX,7
        JB      @@unsupported
        MOV     EAX,1
        XOR     ECX,ECX
        CPUID
        AND     ECX,$18000000
        CMP     ECX,$18000000
        JNE     @@unsupported
        XOR     ECX,ECX
        XGETBV
        AND     EAX,6
        CMP     EAX,6
        JNE     @@unsupported
        MOV     EAX,7
        XOR     ECX,ECX
        CPUID
        BT      EBX,5
        SETC    AL
        MOVZX   EAX,AL
        JMP     @@done
@@unsupported:
        XOR     EAX,EAX
@@done:
end;

procedure LzmaBt4CompactInsertAvx2Walk(const Context: PLzmaBt4CompactInsertContext);
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
        MOV     RSI,[RBX].TLzmaBt4CompactInsertContext.DataBase
        MOV     RDI,[RBX].TLzmaBt4CompactInsertContext.Sons
        MOV     R8,[RBX].TLzmaBt4CompactInsertContext.CurrentEpochPos
        MOV     R9,[RBX].TLzmaBt4CompactInsertContext.CurrentBase
        MOV     R10,[RBX].TLzmaBt4CompactInsertContext.CandidateMark
        MOV     R13,[RBX].TLzmaBt4CompactInsertContext.PtrLess
        MOV     R14,[RBX].TLzmaBt4CompactInsertContext.PtrGreater
        MOV     R15D,[RBX].TLzmaBt4CompactInsertContext.MaxLen
        XOR     R12D,R12D
@@next_node:
        TEST    R10,R10
        JZ      @@truncate
        CMP     R12D,[RBX].TLzmaBt4CompactInsertContext.MaxDepth
        JAE     @@truncate
        MOV     RAX,R10
        DEC     RAX
        CMP     RAX,[RBX].TLzmaBt4CompactInsertContext.PositionBase
        JB      @@truncate
        CMP     RAX,R8
        JAE     @@truncate
        MOV     RDX,R8
        SUB     RDX,RAX
        CMP     RDX,[RBX].TLzmaBt4CompactInsertContext.MaxDistance
        JA      @@truncate
        SUB     RAX,[RBX].TLzmaBt4CompactInsertContext.PositionBase
        LEA     R11,[RSI+RAX]
        CMP     R15D,32
        JE      @@fixed_compare
        CMP     R15D,64
        JNE     @@generic_prefix
@@fixed_compare:
        VMOVDQU YMM0,[R11]
        VMOVDQU YMM1,[R9]
        VPCMPEQB YMM0,YMM0,YMM1
        VPMOVMSKB EDX,YMM0
        XOR     EDX,$FFFFFFFF
        JNZ     @@fixed_different_0
        MOV     ECX,32
        CMP     R15D,32
        JE      @@full_match
        VMOVDQU YMM0,[R11+32]
        VMOVDQU YMM1,[R9+32]
        VPCMPEQB YMM0,YMM0,YMM1
        VPMOVMSKB EDX,YMM0
        XOR     EDX,$FFFFFFFF
        JNZ     @@fixed_different_32
        MOV     ECX,64
        JMP     @@full_match
@@fixed_different_0:
        BSF     ECX,EDX
        JMP     @@fixed_not_full
@@fixed_different_32:
        BSF     ECX,EDX
        ADD     ECX,32
        JMP     @@fixed_not_full
@@generic_prefix:
        XOR     ECX,ECX
@@words_16:
        MOV     EAX,R15D
        SUB     EAX,ECX
        CMP     EAX,16
        JB      @@word_8
        // Both full vectors are within the admitted MaxLen. SSE2 is Win64 baseline.
        VMOVDQU XMM0,[R11+RCX]
        VMOVDQU XMM1,[R9+RCX]
        VPCMPEQB XMM0,XMM0,XMM1
        VPMOVMSKB EDX,XMM0
        XOR     EDX,$FFFF
        JNZ     @@different_vector
        ADD     ECX,16
        JMP     @@words_16
@@different_vector:
        BSF     EDX,EDX
        ADD     ECX,EDX
        JMP     @@measured
@@word_8:
        CMP     EAX,8
        JB      @@tail
        MOV     RAX,QWORD PTR [R11+RCX]
        XOR     RAX,QWORD PTR [R9+RCX]
        TEST    RAX,RAX
        JNZ     @@different_word
        ADD     ECX,8
@@tail:
        CMP     ECX,R15D
        JAE     @@measured
        MOVZX   EAX,BYTE PTR [R11+RCX]
        CMP     AL,BYTE PTR [R9+RCX]
        JNE     @@measured
        INC     ECX
        JMP     @@tail
@@different_word:
        // Both incoming word-mismatch branches prove RAX <> 0.
        BSF     RDX,RAX
        SHR     EDX,3
        ADD     ECX,EDX
@@measured:
        CMP     ECX,R15D
        JE      @@full_match
@@fixed_not_full:
        // Compute the son slot before comparing bytes, while R11 is a pointer.
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     RDX,[RBX].TLzmaBt4CompactInsertContext.CurrentCyclicPos
        SUB     RDX,RAX
        JAE     @@candidate_slot_ready
        ADD     RDX,[RBX].TLzmaBt4CompactInsertContext.CyclicBufferSize
@@candidate_slot_ready:
        MOVZX   EAX,BYTE PTR [R11+RCX]
        CMP     AL,BYTE PTR [R9+RCX]
        JAE     @@write_greater
        MOV     DWORD PTR [RDI+R13*4],R10D
        LEA     R13,[RDX*2+1]
        MOV     R10D,DWORD PTR [RDI+R13*4]
        JMP     @@advance_depth
@@write_greater:
        MOV     DWORD PTR [RDI+R14*4],R10D
        LEA     R14,[RDX*2]
        MOV     R10D,DWORD PTR [RDI+R14*4]
@@advance_depth:
        INC     R12D
        JMP     @@next_node
@@full_match:
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     RDX,[RBX].TLzmaBt4CompactInsertContext.CurrentCyclicPos
        SUB     RDX,RAX
        JAE     @@full_slot_ready
        ADD     RDX,[RBX].TLzmaBt4CompactInsertContext.CyclicBufferSize
@@full_slot_ready:
        LEA     RDX,[RDX*2]
        MOV     EAX,DWORD PTR [RDI+RDX*4]
        MOV     DWORD PTR [RDI+R13*4],EAX
        MOV     EAX,DWORD PTR [RDI+RDX*4+4]
        MOV     DWORD PTR [RDI+R14*4],EAX
        JMP     @@finish
@@truncate:
        MOV     DWORD PTR [RDI+R13*4],0
        MOV     DWORD PTR [RDI+R14*4],0
@@finish:
        VZEROUPPER
end;

procedure LzmaBt4CompactInsertWalk(const Context: PLzmaBt4CompactInsertContext);
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
        MOV     RSI,[RBX].TLzmaBt4CompactInsertContext.DataBase
        MOV     RDI,[RBX].TLzmaBt4CompactInsertContext.Sons
        MOV     R8,[RBX].TLzmaBt4CompactInsertContext.CurrentEpochPos
        MOV     R9,[RBX].TLzmaBt4CompactInsertContext.CurrentBase
        MOV     R10,[RBX].TLzmaBt4CompactInsertContext.CandidateMark
        MOV     R13,[RBX].TLzmaBt4CompactInsertContext.PtrLess
        MOV     R14,[RBX].TLzmaBt4CompactInsertContext.PtrGreater
        MOV     R15D,[RBX].TLzmaBt4CompactInsertContext.MaxLen
        XOR     R12D,R12D
@@next_node:
        TEST    R10,R10
        JZ      @@truncate
        CMP     R12D,[RBX].TLzmaBt4CompactInsertContext.MaxDepth
        JAE     @@truncate
        MOV     RAX,R10
        DEC     RAX
        CMP     RAX,[RBX].TLzmaBt4CompactInsertContext.PositionBase
        JB      @@truncate
        CMP     RAX,R8
        JAE     @@truncate
        MOV     RDX,R8
        SUB     RDX,RAX
        CMP     RDX,[RBX].TLzmaBt4CompactInsertContext.MaxDistance
        JA      @@truncate
        SUB     RAX,[RBX].TLzmaBt4CompactInsertContext.PositionBase
        LEA     R11,[RSI+RAX]
        CMP     R15D,32
        JE      @@fixed_compare
        CMP     R15D,64
        JNE     @@generic_prefix
@@fixed_compare:
        MOVDQU  XMM0,[R11]
        MOVDQU  XMM1,[R9]
        PCMPEQB XMM0,XMM1
        PMOVMSKB EDX,XMM0
        XOR     EDX,$FFFF
        JNZ     @@fixed_different_0
        MOVDQU  XMM0,[R11+16]
        MOVDQU  XMM1,[R9+16]
        PCMPEQB XMM0,XMM1
        PMOVMSKB EDX,XMM0
        XOR     EDX,$FFFF
        JNZ     @@fixed_different_16
        MOV     ECX,32
        CMP     R15D,32
        JE      @@full_match
        MOVDQU  XMM0,[R11+32]
        MOVDQU  XMM1,[R9+32]
        PCMPEQB XMM0,XMM1
        PMOVMSKB EDX,XMM0
        XOR     EDX,$FFFF
        JNZ     @@fixed_different_32
        MOVDQU  XMM0,[R11+48]
        MOVDQU  XMM1,[R9+48]
        PCMPEQB XMM0,XMM1
        PMOVMSKB EDX,XMM0
        XOR     EDX,$FFFF
        JNZ     @@fixed_different_48
        MOV     ECX,64
        JMP     @@full_match
@@fixed_different_0:
        BSF     ECX,EDX
        JMP     @@fixed_not_full
@@fixed_different_16:
        BSF     ECX,EDX
        ADD     ECX,16
        JMP     @@fixed_not_full
@@fixed_different_32:
        BSF     ECX,EDX
        ADD     ECX,32
        JMP     @@fixed_not_full
@@fixed_different_48:
        BSF     ECX,EDX
        ADD     ECX,48
        JMP     @@fixed_not_full
@@generic_prefix:
        XOR     ECX,ECX
@@words_16:
        MOV     EAX,R15D
        SUB     EAX,ECX
        CMP     EAX,16
        JB      @@word_8
        // Both full vectors are within the admitted MaxLen. SSE2 is Win64 baseline.
        MOVDQU  XMM0,[R11+RCX]
        MOVDQU  XMM1,[R9+RCX]
        PCMPEQB XMM0,XMM1
        PMOVMSKB EDX,XMM0
        XOR     EDX,$FFFF
        JNZ     @@different_vector
        ADD     ECX,16
        JMP     @@words_16
@@different_vector:
        BSF     EDX,EDX
        ADD     ECX,EDX
        JMP     @@measured
@@word_8:
        CMP     EAX,8
        JB      @@tail
        MOV     RAX,QWORD PTR [R11+RCX]
        XOR     RAX,QWORD PTR [R9+RCX]
        TEST    RAX,RAX
        JNZ     @@different_word
        ADD     ECX,8
@@tail:
        CMP     ECX,R15D
        JAE     @@measured
        MOVZX   EAX,BYTE PTR [R11+RCX]
        CMP     AL,BYTE PTR [R9+RCX]
        JNE     @@measured
        INC     ECX
        JMP     @@tail
@@different_word:
        // Both incoming word-mismatch branches prove RAX <> 0.
        BSF     RDX,RAX
        SHR     EDX,3
        ADD     ECX,EDX
@@measured:
        CMP     ECX,R15D
        JE      @@full_match
@@fixed_not_full:
        // Compute the son slot before comparing bytes, while R11 is a pointer.
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     RDX,[RBX].TLzmaBt4CompactInsertContext.CurrentCyclicPos
        SUB     RDX,RAX
        JAE     @@candidate_slot_ready
        ADD     RDX,[RBX].TLzmaBt4CompactInsertContext.CyclicBufferSize
@@candidate_slot_ready:
        MOVZX   EAX,BYTE PTR [R11+RCX]
        CMP     AL,BYTE PTR [R9+RCX]
        JAE     @@write_greater
        MOV     DWORD PTR [RDI+R13*4],R10D
        LEA     R13,[RDX*2+1]
        MOV     R10D,DWORD PTR [RDI+R13*4]
        JMP     @@advance_depth
@@write_greater:
        MOV     DWORD PTR [RDI+R14*4],R10D
        LEA     R14,[RDX*2]
        MOV     R10D,DWORD PTR [RDI+R14*4]
@@advance_depth:
        INC     R12D
        JMP     @@next_node
@@full_match:
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     RDX,[RBX].TLzmaBt4CompactInsertContext.CurrentCyclicPos
        SUB     RDX,RAX
        JAE     @@full_slot_ready
        ADD     RDX,[RBX].TLzmaBt4CompactInsertContext.CyclicBufferSize
@@full_slot_ready:
        LEA     RDX,[RDX*2]
        MOV     EAX,DWORD PTR [RDI+RDX*4]
        MOV     DWORD PTR [RDI+R13*4],EAX
        MOV     EAX,DWORD PTR [RDI+RDX*4+4]
        MOV     DWORD PTR [RDI+R14*4],EAX
        JMP     @@finish
@@truncate:
        MOV     DWORD PTR [RDI+R13*4],0
        MOV     DWORD PTR [RDI+R14*4],0
@@finish:
end;
{$IFDEF LZMA_MF_NATIVE_COMPACT_COLLECT}


procedure LzmaBt4CompactCollectWalk(const Context: PLzmaBt4CompactCollectContext);
const
  kMatchPairBytes = SizeOf(TLzmaMatch);
  kMatchPairCapacity = 274;
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
        MOV     RSI,[RBX].TLzmaBt4CompactCollectContext.DataBase
        MOV     RDI,[RBX].TLzmaBt4CompactCollectContext.Sons
        MOV     R8,[RBX].TLzmaBt4CompactCollectContext.CurrentEpochPos
        MOV     R9,[RBX].TLzmaBt4CompactCollectContext.CurrentBase
        MOV     R10,[RBX].TLzmaBt4CompactCollectContext.CandidateMark
        MOV     R13,[RBX].TLzmaBt4CompactCollectContext.PtrLess
        MOV     R14,[RBX].TLzmaBt4CompactCollectContext.PtrGreater
        MOV     R15D,[RBX].TLzmaBt4CompactCollectContext.MaxLen
        XOR     R12D,R12D
@@next_node:
        TEST    R10,R10
        JZ      @@truncate
        CMP     R12D,[RBX].TLzmaBt4CompactCollectContext.MaxDepth
        JAE     @@truncate
        MOV     RAX,R10
        DEC     RAX
        CMP     RAX,[RBX].TLzmaBt4CompactCollectContext.PositionBase
        JB      @@truncate
        CMP     RAX,R8
        JAE     @@truncate
        MOV     RDX,R8
        SUB     RDX,RAX
        CMP     RDX,[RBX].TLzmaBt4CompactCollectContext.MaxDistance
        JA      @@truncate
        SUB     RAX,[RBX].TLzmaBt4CompactCollectContext.PositionBase
        LEA     R11,[RSI+RAX]
        XOR     ECX,ECX
@@words_16:
        MOV     EAX,R15D
        SUB     EAX,ECX
        CMP     EAX,16
        JB      @@word_8
        // Both full vectors are within the admitted MaxLen. SSE2 is Win64 baseline.
        MOVDQU  XMM0,[R11+RCX]
        MOVDQU  XMM1,[R9+RCX]
        PCMPEQB XMM0,XMM1
        PMOVMSKB EDX,XMM0
        XOR     EDX,$FFFF
        JNZ     @@different_vector
        ADD     ECX,16
        JMP     @@words_16
@@different_vector:
        BSF     EDX,EDX
        ADD     ECX,EDX
        JMP     @@measured
@@word_8:
        CMP     EAX,8
        JB      @@tail
        MOV     RAX,QWORD PTR [R11+RCX]
        XOR     RAX,QWORD PTR [R9+RCX]
        TEST    RAX,RAX
        JNZ     @@different_word
        ADD     ECX,8
@@tail:
        CMP     ECX,R15D
        JAE     @@measured
        MOVZX   EAX,BYTE PTR [R11+RCX]
        CMP     AL,BYTE PTR [R9+RCX]
        JNE     @@measured
        INC     ECX
        JMP     @@tail
@@different_word:
        // Both incoming word-mismatch branches prove RAX <> 0.
        BSF     RDX,RAX
        SHR     EDX,3
        ADD     ECX,EDX
@@measured:
        CMP     ECX,4
        JB      @@match_not_improved
        CMP     ECX,[RBX].TLzmaBt4CompactCollectContext.BestLen
        JBE     @@match_not_improved
        MOV     [RBX].TLzmaBt4CompactCollectContext.BestLen,ECX
        MOV     RDX,[RBX].TLzmaBt4CompactCollectContext.Matches
        MOV     EAX,DWORD PTR [RDX].TLzmaMatchBuffer.Count
        CMP     EAX,kMatchPairCapacity
        JAE     @@match_buffer_saturated
        LEA     RDX,[RDX].TLzmaMatchBuffer.Items
        LEA     RDX,[RDX+RAX*kMatchPairBytes]
        MOV     [RDX].TLzmaMatch.Length,ECX
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     [RDX].TLzmaMatch.Distance,EAX
        MOV     RDX,[RBX].TLzmaBt4CompactCollectContext.Matches
        INC     DWORD PTR [RDX].TLzmaMatchBuffer.Count
        JMP     @@match_not_improved
@@match_buffer_saturated:
        LEA     RDX,[RDX].TLzmaMatchBuffer.Items
        ADD     RDX,(kMatchPairCapacity-1)*kMatchPairBytes
        MOV     [RDX].TLzmaMatch.Length,ECX
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     [RDX].TLzmaMatch.Distance,EAX
@@match_not_improved:
        CMP     ECX,R15D
        JE      @@full_match
        // Compute the son slot before comparing bytes, while R11 is a pointer.
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     RDX,[RBX].TLzmaBt4CompactCollectContext.CurrentCyclicPos
        SUB     RDX,RAX
        JAE     @@candidate_slot_ready
        ADD     RDX,[RBX].TLzmaBt4CompactCollectContext.CyclicBufferSize
@@candidate_slot_ready:
        MOVZX   EAX,BYTE PTR [R11+RCX]
        CMP     AL,BYTE PTR [R9+RCX]
        JAE     @@write_greater
        MOV     DWORD PTR [RDI+R13*4],R10D
        LEA     R13,[RDX*2+1]
        MOV     R10D,DWORD PTR [RDI+R13*4]
        JMP     @@advance_depth
@@write_greater:
        MOV     DWORD PTR [RDI+R14*4],R10D
        LEA     R14,[RDX*2]
        MOV     R10D,DWORD PTR [RDI+R14*4]
@@advance_depth:
        INC     R12D
        JMP     @@next_node
@@full_match:
        MOV     RAX,R8
        SUB     RAX,R10
        INC     RAX
        MOV     RDX,[RBX].TLzmaBt4CompactCollectContext.CurrentCyclicPos
        SUB     RDX,RAX
        JAE     @@full_slot_ready
        ADD     RDX,[RBX].TLzmaBt4CompactCollectContext.CyclicBufferSize
@@full_slot_ready:
        LEA     RDX,[RDX*2]
        MOV     EAX,DWORD PTR [RDI+RDX*4]
        MOV     DWORD PTR [RDI+R13*4],EAX
        MOV     EAX,DWORD PTR [RDI+RDX*4+4]
        MOV     DWORD PTR [RDI+R14*4],EAX
        JMP     @@finish
@@truncate:
        MOV     DWORD PTR [RDI+R13*4],0
        MOV     DWORD PTR [RDI+R14*4],0
@@finish:
end;{$ENDIF}

{$ENDIF}

procedure TLzmaBinaryTree4MatchFinder.Insert(const RelativePos: NativeUInt);
var
  H: NativeInt;
  CandidateMark: NativeInt;
  Candidate: NativeUInt;
  CandidateBase: NativeUInt;
  CurrentBase: NativeUInt;
  CurrentLen: UInt32;
  MaxLen: UInt32;
  PtrGreater: NativeInt;
  PtrLess: NativeInt;
  Depth: UInt32;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  Walk: TLzmaBt4CompactInsertContext;
{$ENDIF}
begin
  if RelativePos >= FCount then
    Exit;
  if FInserted[RelativePos] then
    Exit;
  if (FInserted.FBytes <> nil) or (RelativePos <> FInserted.FPrefixCount) then
    FFusedReadSafe := False;
  FInserted[RelativePos] := True;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinLowHashLength) then
    Exit;
  H := Hash2At(RelativePos);
  FHeads2[H] := NativeInt(FPositionBase + RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash3Length) then
    Exit;
  H := Hash3At(RelativePos);
  FHeads3[H] := NativeInt(FPositionBase + RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;
  PtrLess := SonIndex(RelativePos, False);
  PtrGreater := PtrLess + 1;
  FSons[PtrLess] := 0;
  FSons[PtrGreater] := 0;

  H := Hash4At(RelativePos);
  CandidateMark := FHeads4[H];
  FHeads4[H] := NativeInt(FPositionBase + RelativePos) + 1;
  if CandidateMark = 0 then
    Exit;

  MaxLen := FMaxMatchLen;
  if FCount - RelativePos < NativeUInt(MaxLen) then
    MaxLen := UInt32(FCount - RelativePos);
  CurrentBase := FOffset + RelativePos;
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if FSons.IsCompact and (CandidateMark <> 0) and (FMaxDepth <> 0) then
  begin
    Walk.DataBase := @FData[FOffset];
    Walk.CurrentBase := @FData[CurrentBase];
    Walk.Sons := PUInt32(FSons.CompactData);
    Walk.CurrentEpochPos := FPositionBase + RelativePos;
    Walk.PositionBase := FPositionBase;
    Walk.CurrentCyclicPos := NativeUInt(PtrLess) shr 1;
    Walk.CyclicBufferSize := FCyclicBufferSize;
    Walk.MaxDistance := FMaxDistance;
    Walk.CandidateMark := NativeUInt(CandidateMark);
    Walk.PtrLess := PtrLess;
    Walk.PtrGreater := PtrGreater;
    Walk.MaxLen := MaxLen;
    Walk.MaxDepth := FMaxDepth;
    if LzmaBt4Avx2Enabled then
    begin
      LzmaBt4CompactInsertAvx2Walk(@Walk);
    end
    else
    begin
      LzmaBt4CompactInsertWalk(@Walk);
    end;
    Exit;
  end;
{$ENDIF}
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, Candidate) then
      Break;
    if Candidate >= RelativePos then
      Break;
    if RelativePos - Candidate > FMaxDistance then
      Break;

    CandidateBase := FOffset + Candidate;
    CurrentLen := LzmaCountMatchingBytes(FData, CandidateBase, CurrentBase, MaxLen);
    if CurrentLen = MaxLen then
    begin
      FSons[PtrLess] := FSons[SonIndex(Candidate, False)];
      FSons[PtrGreater] := FSons[SonIndex(Candidate, True)];
      Exit;
    end
    else if FData[CandidateBase + CurrentLen] < FData[CurrentBase + CurrentLen] then
    begin
      FSons[PtrLess] := CandidateMark;
      PtrLess := SonIndex(Candidate, True);
      CandidateMark := FSons[PtrLess];
    end
    else
    begin
      FSons[PtrGreater] := CandidateMark;
      PtrGreater := SonIndex(Candidate, False);
      CandidateMark := FSons[PtrGreater];
    end;
    Inc(Depth);
  end;
  FSons[PtrLess] := 0;
  FSons[PtrGreater] := 0;
end;

procedure TLzmaBinaryTree4MatchFinder.InsertRange(const RelativePos, Count: NativeUInt);
var
  Pos: NativeUInt;
  StopPos: NativeUInt;
begin
  if (Count = 0) or (RelativePos >= FCount) then
    Exit;
  Pos := RelativePos;
  StopPos := RelativePos + Count;
  if (StopPos < RelativePos) or (StopPos > FCount) then
    StopPos := FCount;
  while Pos < StopPos do
  begin
    Insert(Pos);
    Inc(Pos);
  end;
end;

procedure TLzmaBinaryTree4MatchFinder.SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
begin
  InsertRange(RelativePos, Count);
end;

procedure TLzmaBinaryTree4MatchFinder.ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches := FLastReadMatches;
    Exit;
  end;

  ReadMatchesAndInsert(RelativePos, Matches);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches := Matches;
end;

procedure TLzmaBinaryTree4MatchFinder.ReadMatchPairs(const RelativePos: NativeUInt;
  var Matches: TLzmaMatchBuffer);
begin
  if FLastReadValid and (FLastReadPos = RelativePos) then
  begin
    Matches.CopyPairsFrom(FLastReadMatches);
    Exit;
  end;

  ReadMatchesAndInsert(RelativePos, Matches);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches.CopyPairsFrom(Matches);
end;

procedure TLzmaBinaryTree4MatchFinder.ReadMatchesAndInsert(const RelativePos: NativeUInt;
  var Matches: TLzmaMatchBuffer);
begin
  // A clipped prefix after a count shrink does not prove monotonic history.
  if FFusedReadSafe and (FMaxMatchLen >= kMinHash4Length) and
    (FInserted.FBytes = nil) and
    (RelativePos = FInserted.FPrefixCount) and
    LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    CollectMatches(RelativePos, Matches, True)
  else
  begin
    GetMatches(RelativePos, Matches);
    Insert(RelativePos);
  end;
end;

procedure TLzmaBinaryTree4MatchFinder.CollectMatches(const RelativePos: NativeUInt;
  var Matches: TLzmaMatchBuffer; const InsertCurrent: Boolean);
var
  H: NativeInt;
  CandidateMark: NativeInt;
  Candidate: NativeUInt;
  Distance: NativeUInt;
  CurrentLen: UInt32;
  BestLen: UInt32;
  MaxLen: UInt32;
  CurrentBase: NativeUInt;
  CandidateBase: NativeUInt;
  Depth: UInt32;
  PtrLess: NativeInt;
  PtrGreater: NativeInt;


{$IFDEF LZMA_MF_NATIVE_COMPACT_COLLECT}
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  CollectWalk: TLzmaBt4CompactCollectContext;
{$ENDIF}

{$ENDIF}
  function TryMeasureLowHashCandidate(const CandidateMark: NativeInt;
    const MinLen: UInt32; out MatchDistance, MatchLen: UInt32): Boolean;
  var
    CandidatePos: NativeUInt;
    Distance: NativeUInt;
  begin
    Result := False;
    MatchDistance := 0;
    MatchLen := 0;
    if CandidateMark = 0 then
      Exit;

    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, CandidatePos) then
      Exit;
    if CandidatePos >= RelativePos then
      Exit;
    Distance := RelativePos - CandidatePos;
    if Distance > FMaxDistance then
      Exit;

    MatchLen := LzmaCountMatchingBytes(FData, FOffset + CandidatePos, CurrentBase, MaxLen);
    if MatchLen < MinLen then
      Exit;

    MatchDistance := UInt32(Distance);
    Result := True;
  end;

  procedure AddSdkLowHashMatches;
  var
    H2Distance: UInt32;
    H2Len: UInt32;
    H3Distance: UInt32;
    H3Len: UInt32;
  begin
    if TryMeasureLowHashCandidate(FHeads2[Hash2At(RelativePos)], kMinLowHashLength,
      H2Distance, H2Len) then
    begin
      if H2Len = kMinLowHashLength then
      begin
        BestLen := H2Len;
        Matches.Add(H2Len, H2Distance);
        if TryMeasureLowHashCandidate(FHeads3[Hash3At(RelativePos)], kMinHash3Length,
          H3Distance, H3Len) then
        begin
          BestLen := H3Len;
          Matches.Add(H3Len, H3Distance);
        end;
      end
      else
      begin
        BestLen := H2Len;
        Matches.Add(H2Len, H2Distance);
      end;
      Exit;
    end;

    if TryMeasureLowHashCandidate(FHeads3[Hash3At(RelativePos)], kMinHash3Length,
      H3Distance, H3Len) then
    begin
      BestLen := H3Len;
      Matches.Add(H3Len, H3Distance);
    end;
  end;
begin
  Matches.Clear;
  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;

  MaxLen := FMaxMatchLen;
  if FCount - RelativePos < NativeUInt(MaxLen) then
    MaxLen := UInt32(FCount - RelativePos);
  if MaxLen < kMinLowHashLength then
    Exit;

  BestLen := 0;
  CurrentBase := FOffset + RelativePos;
  AddSdkLowHashMatches;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;
  if MaxLen < kMinHash4Length then
    Exit;

  H := Hash4At(RelativePos);
  CandidateMark := FHeads4[H];
  PtrLess := 0;
  PtrGreater := 0;
  if InsertCurrent then
  begin
    // All low-hash matches and the H4 root use the old heads.
    FInserted[RelativePos] := True;
    FHeads2[Hash2At(RelativePos)] := NativeInt(FPositionBase + RelativePos) + 1;
    FHeads3[Hash3At(RelativePos)] := NativeInt(FPositionBase + RelativePos) + 1;
    FHeads4[H] := NativeInt(FPositionBase + RelativePos) + 1;
    PtrLess := SonIndex(RelativePos, False);
    PtrGreater := SonIndex(RelativePos, True);
    FSons[PtrLess] := 0;
    FSons[PtrGreater] := 0;
  end;

{$IFDEF LZMA_MF_NATIVE_COMPACT_COLLECT}
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  if InsertCurrent and FSons.IsCompact and (CandidateMark <> 0) and
    (FMaxDepth <> 0) then
  begin
    CollectWalk.DataBase := @FData[FOffset];
    CollectWalk.CurrentBase := @FData[CurrentBase];
    CollectWalk.Sons := PUInt32(FSons.CompactData);
    CollectWalk.CurrentEpochPos := FPositionBase + RelativePos;
    CollectWalk.PositionBase := FPositionBase;
    CollectWalk.CurrentCyclicPos := NativeUInt(PtrLess) shr 1;
    CollectWalk.CyclicBufferSize := FCyclicBufferSize;
    CollectWalk.MaxDistance := FMaxDistance;
    CollectWalk.CandidateMark := NativeUInt(CandidateMark);
    CollectWalk.PtrLess := PtrLess;
    CollectWalk.PtrGreater := PtrGreater;
    CollectWalk.MaxLen := MaxLen;
    CollectWalk.MaxDepth := FMaxDepth;
    CollectWalk.Matches := @Matches;
    CollectWalk.BestLen := BestLen;
    LzmaBt4CompactCollectWalk(@CollectWalk);
    Exit;
  end;
{$ENDIF}
{$ENDIF}
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    if not LzmaTryEpochPosition(CandidateMark, FPositionBase, Candidate) then
      Break;
    if Candidate >= RelativePos then
      Break;
    Distance := RelativePos - Candidate;
    if Distance > FMaxDistance then
      Break;

    CandidateBase := FOffset + Candidate;
    CurrentLen := LzmaCountMatchingBytes(FData, CandidateBase, CurrentBase, MaxLen);
    if (CurrentLen >= kMinHash4Length) and (CurrentLen > BestLen) then
    begin
      BestLen := CurrentLen;
      Matches.Add(CurrentLen, UInt32(Distance));
      if (BestLen = MaxLen) and not InsertCurrent then
        Break;
    end;

    if CurrentLen = MaxLen then
    begin
      if InsertCurrent then
      begin
        FSons[PtrLess] := FSons[SonIndex(Candidate, False)];
        FSons[PtrGreater] := FSons[SonIndex(Candidate, True)];
        Exit;
      end;
      CandidateMark := FSons[SonIndex(Candidate, True)];
    end
    else if FData[CandidateBase + CurrentLen] < FData[CurrentBase + CurrentLen] then
    begin
      if InsertCurrent then
      begin
        FSons[PtrLess] := CandidateMark;
        PtrLess := SonIndex(Candidate, True);
        CandidateMark := FSons[PtrLess];
      end
      else
        CandidateMark := FSons[SonIndex(Candidate, True)];
    end
    else
    begin
      if InsertCurrent then
      begin
        FSons[PtrGreater] := CandidateMark;
        PtrGreater := SonIndex(Candidate, False);
        CandidateMark := FSons[PtrGreater];
      end
      else
        CandidateMark := FSons[SonIndex(Candidate, False)];
    end;
    Inc(Depth);
  end;
  if InsertCurrent then
  begin
    FSons[PtrLess] := 0;
    FSons[PtrGreater] := 0;
  end;
end;

procedure TLzmaBinaryTree4MatchFinder.GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
begin
  CollectMatches(RelativePos, Matches, False);
end;

function TLzmaBinaryTree4MatchFinder.GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray;
var
  Buffer: TLzmaMatchBuffer;
  I: Integer;
begin
  GetMatches(RelativePos, Buffer);
  SetLength(Result, Buffer.Count);
  for I := 0 to Buffer.Count - 1 do
    Result[I] := Buffer.Items[I];
end;

function TLzmaBinaryTree4MatchFinder.SonSlotCount: NativeUInt;
begin
  Result := NativeUInt(FSons.Count);
end;

function TLzmaBinaryTree4MatchFinder.Find(const RelativePos: NativeUInt): TLzmaMatch;
var
  Matches: TLzmaMatchBuffer;
begin
  GetMatches(RelativePos, Matches);
  Result := Matches.Last;
end;

procedure TLzmaGreedyMatchFinder.EnsureEpochCapacity(const Count: NativeUInt);
var
  Limit: NativeUInt;
begin
  if not FHeads2.IsCompact then
    Exit;
  Limit := LzmaCompactEpochLimit;
  if Count > Limit then
    raise EArgumentOutOfRangeException.Create('Match finder epoch capacity');
  if FPositionBase <= Limit - Count then
    Exit;
  LzmaNormalizeMarks(FHeads2, FPositionBase);
  LzmaNormalizeMarks(FHeads, FPositionBase);
  LzmaNormalizeMarks(FPrev, FPositionBase);
  FPositionBase := 0;
end;

procedure TLzmaGreedyMatchFinder.SetInputCount(const Count: NativeUInt);
begin
  if Count > NativeUInt(Length(FData)) - FOffset then
    raise EArgumentOutOfRangeException.Create('Match finder window count');
  if Count > FInserted.Count then
    raise EArgumentOutOfRangeException.Create('Match finder inserted capacity');
  EnsureEpochCapacity(Count);
  FCount := Count;
end;

procedure TLzmaGreedyMatchFinder.RebaseWindow(const DropCount: NativeUInt);
var
  Remaining: NativeUInt;
begin
  if DropCount > FCount then
    raise EArgumentOutOfRangeException.Create('Match finder window drop');
  if DropCount = 0 then
    Exit;
  Remaining := FCount - DropCount;
  FInserted.DropPrefix(DropCount, FCount);
  if Remaining <> 0 then
    LzmaMoveMarks(FPrev, DropCount, 0, Remaining);
  if Remaining < NativeUInt(FPrev.Count) then
    LzmaClearMarks(FPrev, Remaining, NativeUInt(FPrev.Count) - Remaining);
  if FHeads2.IsCompact then
    Inc(FPositionBase, DropCount)
  else
  begin
    LzmaNormalizeMarks(FHeads2, DropCount);
    LzmaNormalizeMarks(FHeads, DropCount);
    LzmaNormalizeMarks(FPrev, DropCount);
  end;
  if FLastReadValid then
  begin
    if FLastReadPos < DropCount then
      FLastReadValid := False
    else
      Dec(FLastReadPos, DropCount);
  end;
  FCount := Remaining;
end;

procedure TLzmaHashChain4MatchFinder.EnsureEpochCapacity(const Count: NativeUInt);
var
  Limit: NativeUInt;
begin
  if not FHeads2.IsCompact then
    Exit;
  Limit := LzmaCompactEpochLimit;
  if Count > Limit then
    raise EArgumentOutOfRangeException.Create('Match finder epoch capacity');
  if FPositionBase <= Limit - Count then
    Exit;
  LzmaNormalizeMarks(FHeads2, FPositionBase);
  LzmaNormalizeMarks(FHeads3, FPositionBase);
  LzmaNormalizeMarks(FHeads4, FPositionBase);
  LzmaNormalizeMarks(FPrev, FPositionBase);
  // Keep physical cyclic slots fixed while changing epoch coordinates.
  FCyclicPhase := (FCyclicPhase + (FPositionBase mod FCyclicBufferSize)) mod FCyclicBufferSize;
  FPositionBase := 0;
end;

procedure TLzmaHashChain4MatchFinder.SetInputCount(const Count: NativeUInt);
begin
  if Count > NativeUInt(Length(FData)) - FOffset then
    raise EArgumentOutOfRangeException.Create('Match finder window count');
  if Count > FInserted.Count then
    raise EArgumentOutOfRangeException.Create('Match finder inserted capacity');
  EnsureEpochCapacity(Count);
  FCount := Count;
end;

procedure TLzmaHashChain4MatchFinder.RebaseWindow(const DropCount: NativeUInt);
var
  Remaining: NativeUInt;
begin
  if DropCount > FCount then
    raise EArgumentOutOfRangeException.Create('Match finder window drop');
  if DropCount = 0 then
    Exit;
  Remaining := FCount - DropCount;
  FInserted.DropPrefix(DropCount, FCount);
  if FHeads2.IsCompact then
    Inc(FPositionBase, DropCount)
  else
  begin
    LzmaNormalizeMarks(FHeads2, DropCount);
    LzmaNormalizeMarks(FHeads3, DropCount);
    LzmaNormalizeMarks(FHeads4, DropCount);
    LzmaNormalizeMarks(FPrev, DropCount);
    LzmaRotateMarksLeft(FPrev, DropCount mod FCyclicBufferSize);
  end;
  if FLastReadValid then
  begin
    if FLastReadPos < DropCount then
      FLastReadValid := False
    else
      Dec(FLastReadPos, DropCount);
  end;
  FCount := Remaining;
end;

procedure TLzmaHashChain5MatchFinder.EnsureEpochCapacity(const Count: NativeUInt);
var
  Limit: NativeUInt;
begin
  if not FHeads2.IsCompact then
    Exit;
  Limit := LzmaCompactEpochLimit;
  if Count > Limit then
    raise EArgumentOutOfRangeException.Create('Match finder epoch capacity');
  if FPositionBase <= Limit - Count then
    Exit;
  LzmaNormalizeMarks(FHeads2, FPositionBase);
  LzmaNormalizeMarks(FHeads3, FPositionBase);
  LzmaNormalizeMarks(FHeads5, FPositionBase);
  LzmaNormalizeMarks(FPrev, FPositionBase);
  // Keep physical cyclic slots fixed while changing epoch coordinates.
  FCyclicPhase := (FCyclicPhase + (FPositionBase mod FCyclicBufferSize)) mod FCyclicBufferSize;
  FPositionBase := 0;
end;

procedure TLzmaHashChain5MatchFinder.SetInputCount(const Count: NativeUInt);
begin
  if Count > NativeUInt(Length(FData)) - FOffset then
    raise EArgumentOutOfRangeException.Create('Match finder window count');
  if Count > FInserted.Count then
    raise EArgumentOutOfRangeException.Create('Match finder inserted capacity');
  EnsureEpochCapacity(Count);
  FCount := Count;
end;

procedure TLzmaHashChain5MatchFinder.RebaseWindow(const DropCount: NativeUInt);
var
  Remaining: NativeUInt;
begin
  if DropCount > FCount then
    raise EArgumentOutOfRangeException.Create('Match finder window drop');
  if DropCount = 0 then
    Exit;
  Remaining := FCount - DropCount;
  FInserted.DropPrefix(DropCount, FCount);
  if FHeads2.IsCompact then
    Inc(FPositionBase, DropCount)
  else
  begin
    LzmaNormalizeMarks(FHeads2, DropCount);
    LzmaNormalizeMarks(FHeads3, DropCount);
    LzmaNormalizeMarks(FHeads5, DropCount);
    LzmaNormalizeMarks(FPrev, DropCount);
    LzmaRotateMarksLeft(FPrev, DropCount mod FCyclicBufferSize);
  end;
  if FLastReadValid then
  begin
    if FLastReadPos < DropCount then
      FLastReadValid := False
    else
      Dec(FLastReadPos, DropCount);
  end;
  FCount := Remaining;
end;

procedure TLzmaBinaryTree4MatchFinder.EnsureEpochCapacity(const Count: NativeUInt);
var
  Limit: NativeUInt;
begin
  if not FHeads2.IsCompact then
    Exit;
  Limit := LzmaCompactEpochLimit;
  if Count > Limit then
    raise EArgumentOutOfRangeException.Create('Match finder epoch capacity');
  if FPositionBase <= Limit - Count then
    Exit;
  LzmaNormalizeMarks(FHeads2, FPositionBase);
  LzmaNormalizeMarks(FHeads3, FPositionBase);
  LzmaNormalizeMarks(FHeads4, FPositionBase);
  LzmaNormalizeMarks(FSons, FPositionBase);
  // Keep physical cyclic slots fixed while changing epoch coordinates.
  FCyclicPhase := (FCyclicPhase + (FPositionBase mod FCyclicBufferSize)) mod FCyclicBufferSize;
  FPositionBase := 0;
end;

procedure TLzmaBinaryTree4MatchFinder.SetInputCount(const Count: NativeUInt);
begin
  if Count > NativeUInt(Length(FData)) - FOffset then
    raise EArgumentOutOfRangeException.Create('Match finder window count');
  if Count > FInserted.Count then
    raise EArgumentOutOfRangeException.Create('Match finder inserted capacity');
  EnsureEpochCapacity(Count);
  if Count < FCount then
    FFusedReadSafe := False;
  FCount := Count;
end;

procedure TLzmaBinaryTree4MatchFinder.RebaseWindow(const DropCount: NativeUInt);
var
  Remaining: NativeUInt;
begin
  if DropCount > FCount then
    raise EArgumentOutOfRangeException.Create('Match finder window drop');
  if DropCount = 0 then
    Exit;
  Remaining := FCount - DropCount;
  FInserted.DropPrefix(DropCount, FCount);
  if FHeads2.IsCompact then
    Inc(FPositionBase, DropCount)
  else
  begin
    LzmaNormalizeMarks(FHeads2, DropCount);
    LzmaNormalizeMarks(FHeads3, DropCount);
    LzmaNormalizeMarks(FHeads4, DropCount);
    LzmaNormalizeMarks(FSons, DropCount);
    LzmaRotateMarksLeft(FSons, (DropCount mod FCyclicBufferSize) * 2);
  end;
  if FLastReadValid then
  begin
    if FLastReadPos < DropCount then
      FLastReadValid := False
    else
      Dec(FLastReadPos, DropCount);
  end;
  FCount := Remaining;
end;


initialization
{$IF Defined(CPUX64) and Defined(MSWINDOWS)}
  LzmaBt4Avx2Enabled := LzmaCpuOsAvx2;
{$ENDIF}
  LzmaInitHashCrc;

end.
