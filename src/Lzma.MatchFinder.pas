unit Lzma.MatchFinder;

interface

uses
  System.SysUtils;

type
  TLzmaMatchFinderKind = (
    mfHashChain4,
    mfHashChain5,
    mfBinaryTree4
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
    procedure Add(const Len, Dist: UInt32); inline;
    function Last: TLzmaMatch; inline;
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
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHeads2: array of NativeInt;
    FHeads: array of NativeInt;
    FPrev: array of NativeInt;
    FInserted: array of Boolean;
    FLastReadValid: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function HashAt(const RelativePos: NativeUInt): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
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
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHash4Mask: NativeUInt;
    FCyclicBufferSize: NativeUInt;
    FHeads2: array of NativeInt;
    FHeads3: array of NativeInt;
    FHeads4: array of NativeInt;
    FPrev: array of NativeInt;
    FInserted: array of Boolean;
    FLastReadValid: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function Hash3At(const RelativePos: NativeUInt): NativeInt;
    function Hash4At(const RelativePos: NativeUInt): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
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
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHash5Mask: NativeUInt;
    FCyclicBufferSize: NativeUInt;
    FHeads2: array of NativeInt;
    FHeads3: array of NativeInt;
    FHeads5: array of NativeInt;
    FPrev: array of NativeInt;
    FInserted: array of Boolean;
    FLastReadValid: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function Hash3At(const RelativePos: NativeUInt): NativeInt;
    function Hash5At(const RelativePos: NativeUInt): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
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
    FMaxDistance: NativeUInt;
    FFastBytes: UInt32;
    FMaxMatchLen: UInt32;
    FMaxDepth: UInt32;
    FHash4Mask: NativeUInt;
    FCyclicBufferSize: NativeUInt;
    FHeads2: array of NativeInt;
    FHeads3: array of NativeInt;
    FHeads4: array of NativeInt;
    FSons: array of NativeInt;
    FInserted: array of Boolean;
    FLastReadValid: Boolean;
    FLastReadPos: NativeUInt;
    FLastReadMatches: TLzmaMatchBuffer;
    function Hash2At(const RelativePos: NativeUInt): NativeInt;
    function Hash3At(const RelativePos: NativeUInt): NativeInt;
    function Hash4At(const RelativePos: NativeUInt): NativeInt;
    function SonIndex(const RelativePos: NativeUInt; const Right: Boolean): NativeInt;
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const FastBytes, MaxMatchLen: UInt32;
      const CutValue: UInt32 = 0);
    procedure Insert(const RelativePos: NativeUInt);
    procedure InsertRange(const RelativePos, Count: NativeUInt);
    procedure SkipRangeMonotonic(const RelativePos, Count: NativeUInt);
    procedure ReadMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
    procedure GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer); overload;
    function GetMatches(const RelativePos: NativeUInt): TLzmaMatchArray; overload;
    function SonSlotCount: NativeUInt;
    function Find(const RelativePos: NativeUInt): TLzmaMatch;
  end;

function LzmaCountMatchingBytes(const Data: TBytes; const Left, Right: NativeUInt;
  const MaxLen: UInt32): UInt32; inline;

implementation

type
  TNativeIntArray = array[0..MaxInt div SizeOf(NativeInt) - 1] of NativeInt;
  PNativeIntArray = ^TNativeIntArray;

const
  kLzHashCrcShift1 = 5;
  kLzHashCrcShift2 = 10;

var
  GLzmaHashCrc: array[Byte] of UInt32;
  GLzmaHashCrcShift1: array[Byte] of UInt32;
  GLzmaHashCrcShift2: array[Byte] of UInt32;
  GLzmaHashCrcPair: array[Word] of UInt32;
  GLzmaHashCrcShiftPair: array[Word] of UInt32;

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
  for I := 0 to High(Word) do
  begin
    GLzmaHashCrcPair[Word(I)] := GLzmaHashCrc[Byte(I)] xor UInt32(Byte(I shr 8));
    GLzmaHashCrcShiftPair[Word(I)] := GLzmaHashCrcShift1[Byte(I)] xor
      GLzmaHashCrcShift2[Byte(I shr 8)];
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

function LzmaHasBytesAt(const RelativePos, Count: NativeUInt; const Needed: UInt32): Boolean; inline;
begin
  Result := (RelativePos < Count) and (NativeUInt(Needed) <= Count - RelativePos);
end;

function LzmaCountMatchingBytes(const Data: TBytes; const Left, Right: NativeUInt;
  const MaxLen: UInt32): UInt32;
var
  PLeft: PByte;
  PRight: PByte;
begin
  Result := 0;
  if MaxLen = 0 then
    Exit;

  PLeft := @Data[Left];
  PRight := @Data[Right];
  while Result + (SizeOf(UInt64) * 2) <= MaxLen do
  begin
    if (PUInt64(PLeft)^ <> PUInt64(PRight)^) or
      (PUInt64(NativeUInt(PLeft) + SizeOf(UInt64))^ <>
        PUInt64(NativeUInt(PRight) + SizeOf(UInt64))^) then
      Break;
    Inc(PLeft, SizeOf(UInt64) * 2);
    Inc(PRight, SizeOf(UInt64) * 2);
    Inc(Result, SizeOf(UInt64) * 2);
  end;

  while Result + SizeOf(UInt64) <= MaxLen do
  begin
    if PUInt64(PLeft)^ <> PUInt64(PRight)^ then
      Break;
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
  SetLength(FHeads2, kHash2Size);
  SetLength(FHeads, kHashSize);
  SetLength(FPrev, Count);
  SetLength(FInserted, Count);
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
  FHeads2[H2] := NativeInt(RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHashLength) then
    Exit;
  H := HashAt(RelativePos);
  FPrev[RelativePos] := FHeads[H];
  FHeads[H] := NativeInt(RelativePos) + 1;
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

  MaxLen := UInt32(FCount - RelativePos);
  if MaxLen > FMaxMatchLen then
    MaxLen := FMaxMatchLen;
  if MaxLen < kMinLowHashLength then
    Exit;

  H := Hash2At(RelativePos);
  CandidateMark := FHeads2[H];
  if CandidateMark <> 0 then
  begin
    Candidate := NativeUInt(CandidateMark - 1);
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
    Candidate := NativeUInt(CandidateMark - 1);
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
  if FMaxDistance >= NativeUInt(High(NativeInt)) then
    raise EArgumentOutOfRangeException.Create('Match finder cyclic window is too large');
  FCyclicBufferSize := FMaxDistance + 1;
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
  FHash4Mask := LzmaSdkHashMask(FMaxDistance, 4);
  SetLength(FHeads2, kHash2Size);
  SetLength(FHeads3, kHash3Size);
  SetLength(FHeads4, LzmaHashArrayLength(FHash4Mask));
  SetLength(FPrev, NativeInt(FCyclicBufferSize));
  SetLength(FInserted, Count);
end;

function TLzmaHashChain4MatchFinder.Hash2At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Result := NativeInt(Temp and (kHash2Size - 1));
end;

function TLzmaHashChain4MatchFinder.Hash3At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Result := NativeInt(Temp and (kHash3Size - 1));
end;

function TLzmaHashChain4MatchFinder.Hash4At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
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
  FHeads2[H] := NativeInt(RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash3Length) then
    Exit;
  H := Hash3At(RelativePos);
  FHeads3[H] := NativeInt(RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;
  H := Hash4At(RelativePos);
  FPrev[RelativePos mod FCyclicBufferSize] := FHeads4[H];
  FHeads4[H] := NativeInt(RelativePos) + 1;
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
  Heads2: PNativeIntArray;
  Heads3: PNativeIntArray;
  Heads4: PNativeIntArray;
  Mark: NativeInt;
  MarkPos: NativeUInt;
  Pos: NativeUInt;
  Prev: PNativeIntArray;
  PrevSlot: PNativeInt;
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

  MarkPos := RelativePos;
  while MarkPos < StopPos do
  begin
    FInserted[MarkPos] := True;
    Inc(MarkPos);
  end;

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

  Heads2 := PNativeIntArray(Pointer(FHeads2));
  Heads3 := PNativeIntArray(Pointer(FHeads3));
  Heads4 := PNativeIntArray(Pointer(FHeads4));
  Prev := PNativeIntArray(Pointer(FPrev));
  ChainSlot := Pos mod FCyclicBufferSize;
  Mark := NativeInt(Pos) + 1;
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
      Temp := GLzmaHashCrcPair[PWord(Cur)^];

      H := NativeInt(Temp and (kHash2Size - 1));
      Heads2^[H] := Mark;

      Temp := Temp xor (UInt32(PByte(NativeUInt(Cur) + 2)^) shl 8);
      H := NativeInt(Temp and (kHash3Size - 1));
      Heads3^[H] := Mark;

      Temp := Temp xor GLzmaHashCrcShift1[PByte(NativeUInt(Cur) + 3)^];
      H := NativeInt(NativeUInt(Temp) and FHash4Mask);
      PrevSlot^ := Heads4^[H];
      Heads4^[H] := Mark;
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
      Mark := NativeInt(Pos) + 1;
      Temp := GLzmaHashCrcPair[Word(FData[FOffset + Pos]) or
        (Word(FData[FOffset + Pos + 1]) shl 8)];
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

    CandidatePos := NativeUInt(CandidateMark - 1);
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

  MaxLen := UInt32(FCount - RelativePos);
  if MaxLen > FMaxMatchLen then
    MaxLen := FMaxMatchLen;
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
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    Candidate := NativeUInt(CandidateMark - 1);
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

    CandidateMark := FPrev[Candidate mod FCyclicBufferSize];
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
  Result := NativeUInt(Length(FPrev));
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
  if FMaxDistance >= NativeUInt(High(NativeInt)) then
    raise EArgumentOutOfRangeException.Create('Match finder cyclic window is too large');
  FCyclicBufferSize := FMaxDistance + 1;
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
  FHash5Mask := LzmaSdkHashMask(FMaxDistance, 5);
  SetLength(FHeads2, kHash2Size);
  SetLength(FHeads3, kHash3Size);
  SetLength(FHeads5, LzmaHashArrayLength(FHash5Mask));
  SetLength(FPrev, NativeInt(FCyclicBufferSize));
  SetLength(FInserted, Count);
end;

function TLzmaHashChain5MatchFinder.Hash2At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Result := NativeInt(Temp and (kHash2Size - 1));
end;

function TLzmaHashChain5MatchFinder.Hash3At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Result := NativeInt(Temp and (kHash3Size - 1));
end;

function TLzmaHashChain5MatchFinder.Hash5At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Temp := Temp xor GLzmaHashCrcShiftPair[Word(FData[FOffset + RelativePos + 3]) or
    (Word(FData[FOffset + RelativePos + 4]) shl 8)];
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
  FHeads2[H] := NativeInt(RelativePos) + 1;

  H := Hash3At(RelativePos);
  FHeads3[H] := NativeInt(RelativePos) + 1;

  H := Hash5At(RelativePos);
  FPrev[RelativePos mod FCyclicBufferSize] := FHeads5[H];
  FHeads5[H] := NativeInt(RelativePos) + 1;
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
  Heads2: PNativeIntArray;
  Heads3: PNativeIntArray;
  Heads5: PNativeIntArray;
  Mark: NativeInt;
  MarkPos: NativeUInt;
  Pos: NativeUInt;
  Prev: PNativeIntArray;
  PrevSlot: PNativeInt;
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

  MarkPos := RelativePos;
  while MarkPos < StopPos do
  begin
    FInserted[MarkPos] := True;
    Inc(MarkPos);
  end;

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
  Heads2 := PNativeIntArray(Pointer(FHeads2));
  Heads3 := PNativeIntArray(Pointer(FHeads3));
  Heads5 := PNativeIntArray(Pointer(FHeads5));
  Prev := PNativeIntArray(Pointer(FPrev));
  ChainSlot := Pos mod FCyclicBufferSize;
  Mark := NativeInt(Pos) + 1;
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
      Temp := GLzmaHashCrcPair[PWord(Cur)^];

      H := NativeInt(Temp and (kHash2Size - 1));
      Heads2^[H] := Mark;

      Temp := Temp xor (UInt32(PByte(NativeUInt(Cur) + 2)^) shl 8);
      H := NativeInt(Temp and (kHash3Size - 1));
      Heads3^[H] := Mark;

      Temp := Temp xor GLzmaHashCrcShiftPair[PWord(NativeUInt(Cur) + 3)^];
      H := NativeInt(NativeUInt(Temp) and FHash5Mask);
      PrevSlot^ := Heads5^[H];
      Heads5^[H] := Mark;
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
      Mark := NativeInt(Pos) + 1;
      Temp := GLzmaHashCrcPair[Word(FData[FOffset + Pos]) or
        (Word(FData[FOffset + Pos + 1]) shl 8)];
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

  procedure AddLowHashMatch(const CandidateMark: NativeInt; const MinLen: UInt32);
  begin
    if CandidateMark = 0 then
      Exit;
    Candidate := NativeUInt(CandidateMark - 1);
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

  MaxLen := UInt32(FCount - RelativePos);
  if MaxLen > FMaxMatchLen then
    MaxLen := FMaxMatchLen;
  if MaxLen < kMinHash5Length then
    Exit;

  BestLen := 0;
  CurrentBase := FOffset + RelativePos;

  H := Hash2At(RelativePos);
  AddLowHashMatch(FHeads2[H], kMinLowHashLength);

  H := Hash3At(RelativePos);
  AddLowHashMatch(FHeads3[H], kMinHash3Length);

  H := Hash5At(RelativePos);
  CandidateMark := FHeads5[H];
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    Candidate := NativeUInt(CandidateMark - 1);
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

    CandidateMark := FPrev[Candidate mod FCyclicBufferSize];
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
  Result := NativeUInt(Length(FPrev));
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
  SonCount: NativeInt;
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
  if FMaxDistance >= NativeUInt(High(NativeInt) div 2) then
    raise EArgumentOutOfRangeException.Create('Match finder cyclic window is too large');
  FCyclicBufferSize := FMaxDistance + 1;
  SonCount := NativeInt(FCyclicBufferSize) * 2;
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
  FHash4Mask := LzmaSdkHashMask(FMaxDistance, 4);
  SetLength(FHeads2, kHash2Size);
  SetLength(FHeads3, kHash3Size);
  SetLength(FHeads4, LzmaHashArrayLength(FHash4Mask));
  SetLength(FSons, SonCount);
  SetLength(FInserted, Count);
end;

function TLzmaBinaryTree4MatchFinder.Hash2At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Result := NativeInt(Temp and (kHash2Size - 1));
end;

function TLzmaBinaryTree4MatchFinder.Hash3At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Result := NativeInt(Temp and (kHash3Size - 1));
end;

function TLzmaBinaryTree4MatchFinder.Hash4At(const RelativePos: NativeUInt): NativeInt;
var
  Temp: UInt32;
begin
  Temp := GLzmaHashCrcPair[Word(FData[FOffset + RelativePos]) or
    (Word(FData[FOffset + RelativePos + 1]) shl 8)];
  Temp := Temp xor (UInt32(FData[FOffset + RelativePos + 2]) shl 8);
  Temp := Temp xor GLzmaHashCrcShift1[FData[FOffset + RelativePos + 3]];
  Result := NativeInt(NativeUInt(Temp) and FHash4Mask);
end;

function TLzmaBinaryTree4MatchFinder.SonIndex(const RelativePos: NativeUInt; const Right: Boolean): NativeInt;
var
  CyclicPos: NativeUInt;
begin
  CyclicPos := RelativePos mod FCyclicBufferSize;
  Result := NativeInt(CyclicPos) * 2 + Ord(Right);
end;

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
begin
  if RelativePos >= FCount then
    Exit;
  if FInserted[RelativePos] then
    Exit;
  FInserted[RelativePos] := True;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinLowHashLength) then
    Exit;
  H := Hash2At(RelativePos);
  FHeads2[H] := NativeInt(RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash3Length) then
    Exit;
  H := Hash3At(RelativePos);
  FHeads3[H] := NativeInt(RelativePos) + 1;

  if not LzmaHasBytesAt(RelativePos, FCount, kMinHash4Length) then
    Exit;
  FSons[SonIndex(RelativePos, False)] := 0;
  FSons[SonIndex(RelativePos, True)] := 0;

  H := Hash4At(RelativePos);
  CandidateMark := FHeads4[H];
  FHeads4[H] := NativeInt(RelativePos) + 1;
  if CandidateMark = 0 then
    Exit;

  MaxLen := UInt32(FCount - RelativePos);
  if MaxLen > FMaxMatchLen then
    MaxLen := FMaxMatchLen;
  CurrentBase := FOffset + RelativePos;
  PtrLess := SonIndex(RelativePos, False);
  PtrGreater := SonIndex(RelativePos, True);
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    Candidate := NativeUInt(CandidateMark - 1);
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

  GetMatches(RelativePos, Matches);
  Insert(RelativePos);
  FLastReadValid := True;
  FLastReadPos := RelativePos;
  FLastReadMatches := Matches;
end;

procedure TLzmaBinaryTree4MatchFinder.GetMatches(const RelativePos: NativeUInt; var Matches: TLzmaMatchBuffer);
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

    CandidatePos := NativeUInt(CandidateMark - 1);
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

  MaxLen := UInt32(FCount - RelativePos);
  if MaxLen > FMaxMatchLen then
    MaxLen := FMaxMatchLen;
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
  Depth := 0;
  while (CandidateMark <> 0) and (Depth < FMaxDepth) do
  begin
    Candidate := NativeUInt(CandidateMark - 1);
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
      if BestLen = MaxLen then
        Break;
    end;

    if CurrentLen = MaxLen then
      CandidateMark := FSons[SonIndex(Candidate, True)]
    else if FData[CandidateBase + CurrentLen] < FData[CurrentBase + CurrentLen] then
      CandidateMark := FSons[SonIndex(Candidate, True)]
    else
      CandidateMark := FSons[SonIndex(Candidate, False)];
    Inc(Depth);
  end;
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
  Result := NativeUInt(Length(FSons));
end;

function TLzmaBinaryTree4MatchFinder.Find(const RelativePos: NativeUInt): TLzmaMatch;
var
  Matches: TLzmaMatchBuffer;
begin
  GetMatches(RelativePos, Matches);
  Result := Matches.Last;
end;

initialization
  LzmaInitHashCrc;

end.
