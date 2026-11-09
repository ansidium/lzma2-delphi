unit Lzma.Sdk.MatchFinder;

interface

uses
  System.SysUtils,
  Lzma.MatchFinder;

type
  TLzmaSdkHashPlan26 = record
    AllocatedMask, ActiveMask: UInt32;
  end;

  // SDK binary-tree variants. Calls follow the SDK's monotonic GetMatches/Skip
  // cursor contract; an immediate repeated read uses the saved result.
  TLzmaSdkMatchFinder = class
  private
    FData: TBytes;
    FOffset, FCount, FCapacity, FNextPosition: NativeUInt;
    FHistory, FCyclicSize, FCyclicPhase: NativeUInt;
    FHashMask: UInt32;
    FHashBytes, FMaxLength, FCutValue: UInt32;
    FMtMode, FLastValid, FBinaryTree: Boolean;
    FLastPosition: NativeUInt;
    FLastMatches: TLzmaMatchBuffer;
    FHeads2, FHeads3, FHeads, FSons: TLzmaPositionLinks;
    function SonIndex(const Position: NativeUInt; const Right: Boolean): NativeInt;
    function Measure(const Mark: NativeInt; const Position: NativeUInt;
      const Limit, Minimum: UInt32; out Distance, MatchLength: UInt32): Boolean;
    procedure Process(const Position: NativeUInt; var Matches: TLzmaMatchBuffer;
      const Collect: Boolean);
    procedure SkipUntil(const Position: NativeUInt);
  public
    constructor Create(const Data: TBytes; const Offset, Count: NativeUInt;
      const DictionarySize: UInt64; const HashBytes, MaxLength, CutValue: UInt32;
      const MtMode: Boolean = False; const BinaryTree: Boolean = True;
      const HashOutBits: UInt32 = 0; const ExpectedDataSize: UInt64 = High(UInt64);
      const FullHashHistory: Boolean = False);
    class function HashMaskFor(const History: NativeUInt; const HashBytes: UInt32): UInt32; static;
    class function HashPlanFor(const History, HashBytes, HashOutBits: UInt32;
      const ExpectedDataSize: UInt64): TLzmaSdkHashPlan26; static;
    class function RequiredMemory(const Capacity: NativeUInt;
      const DictionarySize: UInt64; const HashBytes: UInt32;
      const BinaryTree: Boolean = True; const HashOutBits: UInt32 = 0;
      const ExpectedDataSize: UInt64 = High(UInt64);
      const FullHashHistory: Boolean = False): UInt64; static;
    procedure ReadMatchPairs(const Position: NativeUInt; var Matches: TLzmaMatchBuffer);
    procedure InsertRange(const Position, Count: NativeUInt);
    procedure RebaseWindow(const DropCount: NativeUInt);
    procedure SetInputCount(const Count: NativeUInt);
  end;

  // Preserve the first draft's public name and constructor defaults.
  TLzmaSdkBinaryTreeMatchFinder = TLzmaSdkMatchFinder;

implementation

uses
  System.Math,
  Lzma.Alloc;

const
  Hash2Slots = 1 shl 10;
  Hash3Slots = 1 shl 16;

var
  Crc: array[Byte] of UInt32;

class function TLzmaSdkMatchFinder.HashMaskFor(const History: NativeUInt;
  const HashBytes: UInt32): UInt32;
begin
  if (HashBytes < 2) or (HashBytes > 5) then
    raise EArgumentOutOfRangeException.Create('SDK binary-tree hash width');
{$IF SizeOf(NativeUInt) > SizeOf(UInt32)}
  if History > High(UInt32) then
    raise EArgumentOutOfRangeException.Create('SDK binary-tree history width');
{$ENDIF}
  if HashBytes = 2 then Exit($FFFF);
  Result := UInt32(History);
  if Result <> 0 then Dec(Result);
  Result := Result or (Result shr 1);
  Result := Result or (Result shr 2);
  Result := Result or (Result shr 4);
  Result := Result or (Result shr 8);
  Result := Result shr 1;
  if Result >= UInt32(1 shl 24) then
    if HashBytes = 3 then Result := $FFFFFF else Result := Result shr 1;
  Result := Result or $FFFF;
  if HashBytes >= 5 then Result := Result or ((256 shl 10) - 1);
end;

class function TLzmaSdkMatchFinder.HashPlanFor(const History, HashBytes,
  HashOutBits: UInt32; const ExpectedDataSize: UInt64): TLzmaSdkHashPlan26;
var Bits, MaxBits: UInt32;
  function FullMask(const Size: UInt32): UInt32;
  begin
    if HashBytes = 2 then Exit($FFFF);
    Result := Size;
    if Result <> 0 then Dec(Result);
    Result := Result or (Result shr 1);
    Result := Result or (Result shr 2);
    Result := Result or (Result shr 4);
    Result := Result or (Result shr 8);
    if (HashBytes = 3) and (Result >= UInt32(1 shl 24)) then Result := $FFFFFF;
    Result := Result or $FFFF;
    if HashBytes >= 5 then Result := Result or ((256 shl 10) - 1);
  end;
begin
  if (HashBytes < 2) or (HashBytes > 5) then
    raise EArgumentOutOfRangeException.Create('SDK finder hash width');
  Bits := HashOutBits and $FF; // LzmaEnc_SetProps stores this field in a Byte.
  if Bits = 0 then
  begin
    Result.AllocatedMask := HashMaskFor(History, HashBytes);
    Result.ActiveMask := Result.AllocatedMask;
    if ExpectedDataSize < UInt64(History) then
      Result.ActiveMask := Min(Result.ActiveMask, HashMaskFor(NativeUInt(ExpectedDataSize), HashBytes));
    Exit;
  end;
  MaxBits := 32;
  if HashBytes = 2 then MaxBits := 16 else if HashBytes = 3 then MaxBits := 24;
  if Bits > MaxBits then Bits := MaxBits;
  if Bits = 32 then Result.AllocatedMask := High(UInt32)
  else Result.AllocatedMask := (UInt32(1) shl Bits) - 1;
  Result.AllocatedMask := Result.AllocatedMask or $FFFF;
  if HashBytes >= 5 then Result.AllocatedMask := Result.AllocatedMask or ((256 shl 10) - 1);
  Result.AllocatedMask := Min(Result.AllocatedMask, FullMask(History));
  Result.ActiveMask := Result.AllocatedMask;
  if ExpectedDataSize < UInt64(History) then
    Result.ActiveMask := Min(Result.ActiveMask, FullMask(UInt32(ExpectedDataSize)));
end;

class function TLzmaSdkMatchFinder.RequiredMemory(const Capacity: NativeUInt;
  const DictionarySize: UInt64; const HashBytes: UInt32; const BinaryTree: Boolean;
  const HashOutBits: UInt32; const ExpectedDataSize: UInt64;
  const FullHashHistory: Boolean): UInt64;
var History, HashHistory, Slots, Width, LinkCount: UInt64; Plan: TLzmaSdkHashPlan26;
begin
  History := DictionarySize;
  if History > UInt64(Capacity) then History := Capacity;
  if History > High(UInt32) then
    raise EArgumentOutOfRangeException.Create('SDK finder history width');
  LinkCount := History + 1;
  if BinaryTree then LinkCount := CheckedMemoryMultiply(LinkCount, 2);
  if LinkCount > UInt64(High(NativeInt)) then
    raise EOutOfMemory.Create('SDK finder cyclic capacity');
  HashHistory := History;
  if FullHashHistory then HashHistory := DictionarySize;
  if HashHistory > High(UInt32) then
    raise EArgumentOutOfRangeException.Create('SDK hash history width');
  Plan := HashPlanFor(UInt32(HashHistory), HashBytes, HashOutBits, ExpectedDataSize);
  Slots := UInt64(Plan.AllocatedMask) + 1;
  if Slots > UInt64(High(NativeInt)) then
    raise EOutOfMemory.Create('SDK finder hash capacity');
  if HashBytes > 2 then Slots := CheckedMemoryAdd(Slots, Hash2Slots);
  if HashBytes > 3 then Slots := CheckedMemoryAdd(Slots, Hash3Slots);
  Slots := CheckedMemoryAdd(Slots, LinkCount);
  Width := SizeOf(UInt32);
  if UInt64(Capacity) > High(UInt32) then Width := SizeOf(NativeInt);
  Result := CheckedMemoryAdd(InstanceSize, CheckedMemoryMultiply(Slots, Width));
end;

constructor TLzmaSdkMatchFinder.Create(const Data: TBytes;
  const Offset, Count: NativeUInt; const DictionarySize: UInt64;
  const HashBytes, MaxLength, CutValue: UInt32; const MtMode, BinaryTree: Boolean;
  const HashOutBits: UInt32; const ExpectedDataSize: UInt64; const FullHashHistory: Boolean);
var Plan: TLzmaSdkHashPlan26; LinkCount: NativeUInt; HashHistory: UInt64;
begin
  inherited Create;
  if (Offset > NativeUInt(Length(Data))) or
    (Count > NativeUInt(Length(Data)) - Offset) then
    raise EArgumentOutOfRangeException.Create('SDK binary-tree input bounds');
  RequiredMemory(Count, DictionarySize, HashBytes, BinaryTree, HashOutBits, ExpectedDataSize, FullHashHistory);
  if not BinaryTree and ((HashBytes < 4) or MtMode) then
    raise EArgumentOutOfRangeException.Create('SDK hash-chain mode');
  FBinaryTree := BinaryTree;
  FData := Data; FOffset := Offset; FCount := Count; FCapacity := Count;
  if DictionarySize > UInt64(Count) then FHistory := Count
  else FHistory := NativeUInt(DictionarySize);
  FCyclicSize := FHistory + 1;
  FHashBytes := HashBytes; FMaxLength := MaxLength; FCutValue := CutValue;
  if (FMaxLength < HashBytes) or (FMaxLength > 273) then
    raise EArgumentOutOfRangeException.Create('SDK binary-tree match length');
  if FCutValue = 0 then FCutValue := 256;
  FMtMode := MtMode;
  HashHistory := FHistory;
  if FullHashHistory then HashHistory := DictionarySize;
  Plan := HashPlanFor(UInt32(HashHistory), HashBytes, HashOutBits, ExpectedDataSize);
  FHashMask := Plan.ActiveMask;
  if HashBytes > 2 then FHeads2.Initialize(Hash2Slots, Count);
  if HashBytes > 3 then FHeads3.Initialize(Hash3Slots, Count);
  FHeads.Initialize(NativeInt(Plan.AllocatedMask) + 1, Count);
  LinkCount := FCyclicSize;
  if BinaryTree then LinkCount := LinkCount * 2;
  FSons.Initialize(NativeInt(LinkCount), Count);
end;

function TLzmaSdkMatchFinder.SonIndex(const Position: NativeUInt;
  const Right: Boolean): NativeInt;
begin
  Result := NativeInt((FCyclicPhase + Position) mod FCyclicSize) * 2 + Ord(Right);
end;

function TLzmaSdkMatchFinder.Measure(const Mark: NativeInt;
  const Position: NativeUInt; const Limit, Minimum: UInt32;
  out Distance, MatchLength: UInt32): Boolean;
var Candidate, Delta: NativeUInt;
begin
  Result := False; Distance := 0; MatchLength := 0;
  if Mark <= 0 then Exit;
  Candidate := NativeUInt(Mark - 1);
  if Candidate >= Position then Exit;
  Delta := Position - Candidate;
  if Delta > FHistory then Exit;
  MatchLength := LzmaCountMatchingBytes(FData, FOffset + Candidate,
    FOffset + Position, Limit);
  if MatchLength < Minimum then Exit;
  Distance := UInt32(Delta); Result := True;
end;

procedure TLzmaSdkMatchFinder.Process(const Position: NativeUInt;
  var Matches: TLzmaMatchBuffer; const Collect: Boolean);
var Temp, H2, H3, H, Limit, Best, MatchLength, Depth, LowLimit: UInt32;
    Dist2, Len2, Dist3, Len3, Distance: UInt32;
    Mark2, Mark3, CandidateMark: NativeInt;
    PtrLess, PtrGreater, CandidateLess, CandidateGreater: NativeInt;
    Candidate, Delta: NativeUInt;
    Tree, LowMatches: TLzmaMatchBuffer;
    Has2, Has3: Boolean;
    I: Integer;

  procedure ReadLow(const MinimumTreeDistance: UInt32);
  begin
    LowMatches.Clear;
    if FHashBytes = 2 then Exit;
    LowLimit := Limit;
    if FMtMode then LowLimit := FHashBytes - 1;
    Has2 := Measure(Mark2, Position, LowLimit, 2, Dist2, Len2);
    Has3 := False;
    if FHashBytes >= 4 then
      Has3 := Measure(Mark3, Position, LowLimit, 3, Dist3, Len3);
    if FMtMode then
    begin
      if Has2 and (Dist2 >= MinimumTreeDistance) then Has2 := False;
      if Has3 and (Dist3 >= MinimumTreeDistance) then Has3 := False;
    end;
    if Has2 then
    begin
      LowMatches.Add(Len2, Dist2);
      // SDK prefers h2 when it already provides at least three bytes, even
      // when the separate h3 candidate could be longer (notably BT5).
      if (Len2 = 2) and Has3 then LowMatches.Add(Len3, Dist3);
    end
    else if Has3 then LowMatches.Add(Len3, Dist3);
  end;

begin
  Matches.Clear; Tree.Clear; LowMatches.Clear;
  if Position >= FCount then Exit;
  Limit := FMaxLength;
  if FCount - Position < NativeUInt(Limit) then Limit := UInt32(FCount - Position);
  if Limit < FHashBytes then
  begin
    // MT BT5 still mixes 2..4-byte low hashes for the final four bytes,
    // although the binary-tree producer cannot calculate a five-byte hash.
    if FMtMode and (FHashBytes = 5) and (Limit = 4) then
    begin
      Temp := Crc[FData[FOffset + Position]] xor UInt32(FData[FOffset + Position + 1]);
      H2 := Temp and (Hash2Slots - 1);
      H3 := (Temp xor (UInt32(FData[FOffset + Position + 2]) shl 8)) and (Hash3Slots - 1);
      Mark2 := FHeads2[NativeInt(H2)]; Mark3 := FHeads3[NativeInt(H3)];
      if Collect then
      begin ReadLow(High(UInt32)); Matches.CopyPairsFrom(LowMatches); end;
      FHeads2[NativeInt(H2)] := NativeInt(Position) + 1;
      FHeads3[NativeInt(H3)] := NativeInt(Position) + 1;
    end;
    Exit;
  end;
  H2 := 0; H3 := 0; Mark2 := 0; Mark3 := 0;
  if FHashBytes = 2 then
    H := UInt32(FData[FOffset + Position]) or
      (UInt32(FData[FOffset + Position + 1]) shl 8)
  else
  begin
    Temp := Crc[FData[FOffset + Position]] xor UInt32(FData[FOffset + Position + 1]);
    H2 := Temp and (Hash2Slots - 1); Mark2 := FHeads2[NativeInt(H2)];
    Temp := Temp xor (UInt32(FData[FOffset + Position + 2]) shl 8);
    H3 := Temp and (Hash3Slots - 1);
    if FHashBytes >= 4 then Mark3 := FHeads3[NativeInt(H3)];
    if FMtMode and (FHashMask >= $FFFFFF) then
    begin
      if FHashBytes = 3 then
        Temp := UInt32(FData[FOffset + Position]) or
          (UInt32(FData[FOffset + Position + 1]) shl 8) or
          (UInt32(FData[FOffset + Position + 2]) shl 16)
      else
      begin
        Temp := Temp xor (UInt32(FData[FOffset + Position + 3]) shl 16);
        if FHashBytes = 5 then
          Temp := Temp xor (Crc[FData[FOffset + Position + 4]] shl 5);
      end;
    end
    else
    begin
      if FHashBytes >= 4 then Temp := Temp xor (Crc[FData[FOffset + Position + 3]] shl 5);
      if FHashBytes >= 5 then Temp := Temp xor (Crc[FData[FOffset + Position + 4]] shl 10);
    end;
    H := Temp and FHashMask;
  end;
  CandidateMark := FHeads[NativeInt(H)];
  FHeads[NativeInt(H)] := NativeInt(Position) + 1;
  if FHashBytes > 2 then FHeads2[NativeInt(H2)] := NativeInt(Position) + 1;
  if FHashBytes > 3 then FHeads3[NativeInt(H3)] := NativeInt(Position) + 1;
  Best := FHashBytes - 1;
  if Collect and not FMtMode then
  begin
    ReadLow(High(UInt32));
    if (LowMatches.Count <> 0) and (LowMatches.Last.Length > Best) then Best := LowMatches.Last.Length;
  end;
  if not FBinaryTree then
  begin
    FSons[NativeInt((FCyclicPhase + Position) mod FCyclicSize)] := CandidateMark;
    if Collect and (Best < Limit) then
    begin
      Depth := 0;
      while (CandidateMark > 0) and (Depth < FCutValue) do
      begin
        Candidate := NativeUInt(CandidateMark - 1);
        if Candidate >= Position then Break;
        Delta := Position - Candidate;
        if Delta > FHistory then Break;
        MatchLength := LzmaCountMatchingBytes(FData, FOffset + Candidate, FOffset + Position, Limit);
        if MatchLength > Best then
        begin
          Best := MatchLength; Tree.Add(MatchLength, UInt32(Delta));
          if MatchLength = Limit then Break;
        end;
        CandidateMark := FSons[NativeInt((FCyclicPhase + Candidate) mod FCyclicSize)];
        Inc(Depth);
      end;
    end;
    Matches.CopyPairsFrom(LowMatches);
    for I := 0 to Tree.Count - 1 do Matches.Add(Tree.Items[I].Length, Tree.Items[I].Distance);
    Exit;
  end;
  PtrLess := SonIndex(Position, False); PtrGreater := PtrLess + 1;
  Depth := 0;
  while (CandidateMark > 0) and (Depth < FCutValue) do
  begin
    Candidate := NativeUInt(CandidateMark - 1);
    if Candidate >= Position then Break;
    Delta := Position - Candidate;
    if Delta > FHistory then Break;
    Distance := UInt32(Delta);
    MatchLength := LzmaCountMatchingBytes(FData, FOffset + Candidate, FOffset + Position, Limit);
    if Collect and (MatchLength > Best) then
    begin Best := MatchLength; Tree.Add(MatchLength, Distance); end;
    CandidateLess := SonIndex(Candidate, False); CandidateGreater := CandidateLess + 1;
    if MatchLength = Limit then
    begin
      FSons[PtrLess] := FSons[CandidateLess];
      FSons[PtrGreater] := FSons[CandidateGreater];
      CandidateMark := -1; Break;
    end;
    if FData[FOffset + Candidate + MatchLength] < FData[FOffset + Position + MatchLength] then
    begin
      FSons[PtrLess] := CandidateMark; PtrLess := CandidateGreater;
      CandidateMark := FSons[PtrLess];
    end
    else
    begin
      FSons[PtrGreater] := CandidateMark; PtrGreater := CandidateLess;
      CandidateMark := FSons[PtrGreater];
    end;
    Inc(Depth);
  end;
  if CandidateMark <> -1 then
  begin FSons[PtrLess] := 0; FSons[PtrGreater] := 0; end;
  if not Collect then Exit;
  if FMtMode then
  begin
    // Original MT mixer emits low hashes only before the first BT distance.
    if Tree.Count <> 0 then ReadLow(Tree.Items[0].Distance)
    else if FCount - Position >= 4 then ReadLow(High(UInt32));
  end;
  Matches.CopyPairsFrom(LowMatches);
  for I := 0 to Tree.Count - 1 do Matches.Add(Tree.Items[I].Length, Tree.Items[I].Distance);
end;

procedure TLzmaSdkMatchFinder.SkipUntil(const Position: NativeUInt);
var Ignored: TLzmaMatchBuffer;
begin
  while FNextPosition < Position do
  begin Process(FNextPosition, Ignored, False); Inc(FNextPosition); end;
end;

procedure TLzmaSdkMatchFinder.ReadMatchPairs(const Position: NativeUInt;
  var Matches: TLzmaMatchBuffer);
begin
  if FLastValid and (Position = FLastPosition) then
  begin Matches.CopyPairsFrom(FLastMatches); Exit; end;
  if (Position < FNextPosition) or (Position >= FCount) then
    raise EArgumentOutOfRangeException.Create('SDK binary-tree read cursor');
  SkipUntil(Position); Process(Position, Matches, True); Inc(FNextPosition);
  FLastPosition := Position; FLastValid := True; FLastMatches.CopyPairsFrom(Matches);
end;

procedure TLzmaSdkMatchFinder.InsertRange(const Position, Count: NativeUInt);
var Target: NativeUInt;
begin
  if (Position >= FCount) or (Count = 0) then Exit;
  if Count > FCount - Position then Target := FCount else Target := Position + Count;
  SkipUntil(Target);
end;

procedure TLzmaSdkMatchFinder.RebaseWindow(const DropCount: NativeUInt);
  procedure Normalize(var Links: TLzmaPositionLinks);
  var I: NativeInt; Mark: NativeInt;
  begin
    for I := 0 to Links.Count - 1 do
    begin
      Mark := Links[I];
      if (Mark <= 0) or (NativeUInt(Mark) <= DropCount) then Links[I] := 0
      else Links[I] := Mark - NativeInt(DropCount);
    end;
  end;
begin
  if (DropCount > FCount) or (DropCount > FNextPosition) then
    raise EArgumentOutOfRangeException.Create('SDK binary-tree window drop');
  if DropCount = 0 then Exit;
  Normalize(FHeads2); Normalize(FHeads3); Normalize(FHeads); Normalize(FSons);
  FCyclicPhase := (FCyclicPhase + DropCount) mod FCyclicSize;
  Dec(FCount, DropCount); Dec(FNextPosition, DropCount);
  if FLastValid then
    if FLastPosition < DropCount then FLastValid := False else Dec(FLastPosition, DropCount);
end;

procedure TLzmaSdkMatchFinder.SetInputCount(const Count: NativeUInt);
begin
  if Count > FCapacity then raise EArgumentOutOfRangeException.Create('SDK binary-tree window count');
  FCount := Count;
end;

procedure InitCrc;
var I, J: Integer; V: UInt32;
begin
  for I := 0 to 255 do
  begin
    V := UInt32(I);
    for J := 0 to 7 do
      if (V and 1) <> 0 then V := (V shr 1) xor UInt32($EDB88320) else V := V shr 1;
    Crc[Byte(I)] := V;
  end;
end;

initialization
  InitCrc;

end.
