unit Lzma.Sdk.MatchFinder26;

// Native scalar port of SDK 26.05 C/LzFind.c (Igor Pavlov, public domain).
// The caller owns the record, the input stream and direct-input bytes. Hash,
// son and streaming-window storage are actual allocations from Alloc.
interface

uses Lzma.Types, Lzma.Sdk.Contracts;

{$ALIGN 8}
{$POINTERMATH ON}
{$B-} // C-style short-circuit guards also apply in projects compiled with B+.

type
  CLzRef = UInt32;
  PLzRef = ^CLzRef;
  PCMatchFinder = ^CMatchFinder;
  CMatchFinder = record
    Buffer: PByte;
    Pos, PosLimit, StreamPos, LenLimit: UInt32;
    CyclicBufferPos, CyclicBufferSize: UInt32;
    StreamEndWasReached, BtMode, BigHash, DirectInput: Byte;
    MatchMaxLen: UInt32;
    Hash, Son: PLzRef;
    HashMask, CutValue: UInt32;
    BufBase: PByte;
    Stream: Pointer; // borrowed ILzmaSeqInStream; no hidden reference ownership
    BlockSize, KeepSizeBefore, KeepSizeAfter: UInt32;
    NumHashBytes: UInt32;
    DirectInputRem: SizeT;
    HistorySize, FixedHashSize: UInt32;
    NumHashBytes_Min, NumHashOutBits: Byte;
    Pad2: array[0..1] of Byte;
    Result: SRes;
    Crc: array[0..255] of UInt32;
    NumRefs: SizeT;
    ExpectedDataSize: UInt64;
  end;

  TMfInit = procedure(P: Pointer); cdecl;
  TMfGetNumAvailableBytes = function(P: Pointer): UInt32; cdecl;
  TMfGetPointerToCurrentPos = function(P: Pointer): PByte; cdecl;
  TMfGetMatches = function(P: Pointer; Distances: PUInt32): PUInt32; cdecl;
  TMfSkip = procedure(P: Pointer; Num: UInt32); cdecl;
  IMatchFinder2 = record
    Init: TMfInit;
    GetNumAvailableBytes: TMfGetNumAvailableBytes;
    GetPointerToCurrentPos: TMfGetPointerToCurrentPos;
    GetMatches: TMfGetMatches;
    Skip: TMfSkip;
  end;

function Inline_MatchFinder_GetPointerToCurrentPos(const P: CMatchFinder): PByte; inline;
function Inline_MatchFinder_GetNumAvailableBytes(const P: CMatchFinder): UInt32; inline;
procedure MatchFinder_SET_DIRECT_INPUT_BUF(var P: CMatchFinder; Src: PByte; SrcLen: SizeT);
procedure MatchFinder_SET_STREAM(var P: CMatchFinder; const Stream: ILzmaSeqInStream);
procedure MatchFinder_REDUCE_OFFSETS(var P: CMatchFinder; SubValue: UInt32);
procedure MatchFinder_Construct(var P: CMatchFinder);
function MatchFinder_Create(var P: CMatchFinder; HistorySize, KeepAddBufferBefore,
  MatchMaxLen, KeepAddBufferAfter: UInt32; const Alloc: ILzmaAllocator): Integer;
procedure MatchFinder_Free(var P: CMatchFinder; const Alloc: ILzmaAllocator);
function MatchFinder_NeedMove(const P: CMatchFinder): Integer;
procedure MatchFinder_MoveBlock(var P: CMatchFinder);
procedure MatchFinder_ReadIfRequired(var P: CMatchFinder);
procedure MatchFinder_Normalize3(SubValue: UInt32; Items: PLzRef; NumItems: SizeT);
procedure MatchFinder_Init_LowHash(var P: CMatchFinder);
procedure MatchFinder_Init_HighHash(var P: CMatchFinder);
procedure MatchFinder_Init_4(var P: CMatchFinder);
procedure MatchFinder_Init(P: Pointer); cdecl;
procedure MatchFinder_CreateVTable(var P: CMatchFinder; out VTable: IMatchFinder2);
function GetMatchesSpec1(LenLimit, CurMatch, Pos: UInt32; Cur: PByte; Son: PLzRef;
  CyclicBufferPos: SizeT; CyclicBufferSize, CutValue: UInt32;
  Distances: PUInt32; MaxLen: UInt32): PUInt32;
function Bt3Zip_MatchFinder_GetMatches(P: PCMatchFinder; Distances: PUInt32): PUInt32;
function Hc3Zip_MatchFinder_GetMatches(P: PCMatchFinder; Distances: PUInt32): PUInt32;
procedure Bt3Zip_MatchFinder_Skip(P: PCMatchFinder; Num: UInt32);
procedure Hc3Zip_MatchFinder_Skip(P: PCMatchFinder; Num: UInt32);
procedure LzFindPrepare;

implementation

// Positions and CRC arithmetic deliberately wrap modulo 2^32, as in C.
// Pointer counts use SizeT, independently of Delphi's signed array limits.
{$Q-}
{$R-}

const
  Hash2Size = UInt32(1) shl 10;
  Hash3Size = UInt32(1) shl 16;
  Fix4HashSize = Hash2Size + Hash3Size;
  BlockMoveAlign = UInt32(1) shl 7;
  BlockSizeAlign = UInt32(1) shl 16;
  BlockSizeReserveMin = UInt32(1) shl 24;

function Allocate(const Alloc: ILzmaAllocator; Count: SizeT): Pointer;
begin
  if Alloc = nil then Result := LzmaDefaultAllocate(Count)
  else Result := Alloc.Alloc(Count);
end;

procedure Release(const Alloc: ILzmaAllocator; Address: Pointer);
begin
  if Alloc = nil then LzmaDefaultFree(Address)
  else Alloc.FreeMem(Address);
end;

function Inline_MatchFinder_GetPointerToCurrentPos(const P: CMatchFinder): PByte;
begin Result := P.Buffer; end;

function Inline_MatchFinder_GetNumAvailableBytes(const P: CMatchFinder): UInt32;
begin Result := P.StreamPos - P.Pos; end;

procedure MatchFinder_SET_DIRECT_INPUT_BUF(var P: CMatchFinder; Src: PByte; SrcLen: SizeT);
begin
  P.Stream := nil; P.DirectInput := 1; P.Buffer := Src; P.DirectInputRem := SrcLen;
end;

procedure MatchFinder_SET_STREAM(var P: CMatchFinder; const Stream: ILzmaSeqInStream);
begin P.Stream := Pointer(Stream); P.DirectInput := 0; end;

procedure MatchFinder_REDUCE_OFFSETS(var P: CMatchFinder; SubValue: UInt32);
begin Dec(P.Pos, SubValue); Dec(P.StreamPos, SubValue); end;

procedure MatchFinder_Construct(var P: CMatchFinder);
var I, J, R: UInt32;
begin
  P.Buffer := nil; P.BufBase := nil; P.DirectInput := 0; P.Stream := nil;
  P.Hash := nil; P.ExpectedDataSize := High(UInt64);
  P.CutValue := 32; P.BtMode := 1; P.NumHashBytes := 4;
  P.NumHashBytes_Min := 2; P.NumHashOutBits := 0; P.BigHash := 0;
  for I := 0 to 255 do
  begin
    R := I;
    for J := 0 to 7 do R := (R shr 1) xor ($EDB88320 and (UInt32(0) - (R and 1)));
    P.Crc[I] := R;
  end;
end;

procedure FreeWindow(var P: CMatchFinder; const Alloc: ILzmaAllocator);
begin Release(Alloc, P.BufBase); P.BufBase := nil; end;

procedure FreeRefs(var P: CMatchFinder; const Alloc: ILzmaAllocator);
begin Release(Alloc, P.Hash); P.Hash := nil; end;

procedure MatchFinder_Free(var P: CMatchFinder; const Alloc: ILzmaAllocator);
begin FreeRefs(P, Alloc); FreeWindow(P, Alloc); end;

function CreateWindow(var P: CMatchFinder; BlockSize: UInt32;
  const Alloc: ILzmaAllocator): Boolean;
begin
  if BlockSize = 0 then Exit(False);
  if (P.BufBase = nil) or (P.BlockSize <> BlockSize) then
  begin
    FreeWindow(P, Alloc); P.BlockSize := BlockSize;
    P.BufBase := Allocate(Alloc, BlockSize);
  end;
  Result := P.BufBase <> nil;
end;

function GetBlockSize(const P: CMatchFinder; HistorySize: UInt32): UInt32;
const BlockSizeMax = UInt32($FFFF0000);
var Rem, Reserve: UInt32;
begin
  Result := P.KeepSizeBefore + P.KeepSizeAfter;
  if (P.KeepSizeBefore < HistorySize) or (Result < P.KeepSizeBefore) then Exit(0);
  Rem := BlockSizeMax - Result;
  if Result < UInt32(1) shl 30 then Reserve := Result shr 1 else Reserve := Result shr 2;
  Inc(Reserve, (1 shl 12) + BlockMoveAlign + BlockSizeAlign);
  if (Result >= BlockSizeMax) or (Rem < BlockSizeReserveMin) then Exit(0);
  if Reserve >= Rem then Result := BlockSizeMax
  else Result := (Result + Reserve) and not (BlockSizeAlign - 1);
end;

function HashMask(const P: CMatchFinder; Hs: UInt32; Full: Boolean): UInt32;
begin
  if P.NumHashBytes = 2 then Exit($FFFF);
  if Hs <> 0 then Dec(Hs);
  Hs := Hs or (Hs shr 1); Hs := Hs or (Hs shr 2);
  Hs := Hs or (Hs shr 4); Hs := Hs or (Hs shr 8);
  if not Full then Hs := Hs shr 1;
  if Hs >= UInt32(1) shl 24 then
    if P.NumHashBytes = 3 then Hs := $FFFFFF else if not Full then Hs := Hs shr 1;
  Hs := Hs or $FFFF;
  if P.NumHashBytes >= 5 then Hs := Hs or ((256 shl 10) - 1);
  Result := Hs;
end;

function MatchFinder_Create(var P: CMatchFinder; HistorySize, KeepAddBufferBefore,
  MatchMaxLen, KeepAddBufferAfter: UInt32; const Alloc: ILzmaAllocator): Integer;
var Hs, HsCur, Hs2, Bits, MaxBits, NewCyclicSize: UInt32;
    HashSizeSum, NumSons, NewSize, ByteSize: SizeT;
begin
  P.KeepSizeBefore := HistorySize + KeepAddBufferBefore + 1;
  Inc(KeepAddBufferAfter, MatchMaxLen);
  if KeepAddBufferAfter < P.NumHashBytes then KeepAddBufferAfter := P.NumHashBytes;
  P.KeepSizeAfter := KeepAddBufferAfter;
  if P.DirectInput <> 0 then P.BlockSize := 0;
  if (P.DirectInput <> 0) or CreateWindow(P, GetBlockSize(P, HistorySize), Alloc) then
  begin
    if P.NumHashOutBits <> 0 then
    begin
      Bits := P.NumHashOutBits;
      if P.NumHashBytes = 2 then MaxBits := 16
      else if P.NumHashBytes = 3 then MaxBits := 24 else MaxBits := 32;
      if Bits >= MaxBits then Bits := MaxBits;
      if Bits >= 32 then Hs := High(UInt32) else Hs := (UInt32(1) shl Bits) - 1;
      Hs := Hs or $FFFF;
      if P.NumHashBytes >= 5 then Hs := Hs or ((256 shl 10) - 1);
      Hs2 := HashMask(P, HistorySize, True); if Hs >= Hs2 then Hs := Hs2;
      HsCur := Hs;
      if P.ExpectedDataSize < HistorySize then
      begin
        Hs2 := HashMask(P, UInt32(P.ExpectedDataSize), True);
        if HsCur >= Hs2 then HsCur := Hs2;
      end;
    end
    else
    begin
      Hs := HashMask(P, HistorySize, False); HsCur := Hs;
      if P.ExpectedDataSize < HistorySize then
      begin
        HsCur := HashMask(P, UInt32(P.ExpectedDataSize), False);
        if HsCur >= Hs then HsCur := Hs;
      end;
    end;
    P.HashMask := HsCur;
    HashSizeSum := SizeT(Hs) + 1;
    if HashSizeSum < Hs then Exit(0);
    P.FixedHashSize := 0;
    if (P.NumHashBytes > 2) and (P.NumHashBytes_Min <= 2) then Inc(P.FixedHashSize, Hash2Size);
    if (P.NumHashBytes > 3) and (P.NumHashBytes_Min <= 3) then Inc(P.FixedHashSize, Hash3Size);
    Inc(HashSizeSum, P.FixedHashSize); P.MatchMaxLen := MatchMaxLen;
    NewCyclicSize := HistorySize + 1;
    P.HistorySize := HistorySize; P.CyclicBufferSize := NewCyclicSize;
    NumSons := NewCyclicSize; if P.BtMode <> 0 then NumSons := NumSons shl 1;
    NewSize := HashSizeSum + NumSons;
    if (NumSons < NewCyclicSize) or (NewSize < NumSons) then Exit(0);
    NewSize := (NewSize + $F) and not SizeT($F);
    // Preserve SDK reuse, including the existing Son location.
    if (P.Hash <> nil) and (P.NumRefs >= NewSize) then
    begin
      // SDK retains Son on reuse. Changing hash/tree shape can leave that
      // span overlapping the new hash tables or extending past NumRefs.
      // Keep its existing position only while both regions still fit.
      if (NativeUInt(P.Son) < NativeUInt(P.Hash+HashSizeSum)) or
        (NativeUInt(P.Son+NumSons) > NativeUInt(P.Hash+P.NumRefs)) then
        P.Son := P.Hash+HashSizeSum;
      Exit(1);
    end;
    FreeRefs(P, Alloc); P.NumRefs := NewSize;
    ByteSize := NewSize * SizeOf(CLzRef);
    if ByteSize div SizeOf(CLzRef) = NewSize then P.Hash := Allocate(Alloc, ByteSize);
    if P.Hash <> nil then begin P.Son := P.Hash + HashSizeSum; Exit(1); end;
  end;
  MatchFinder_Free(P, Alloc); Result := 0;
end;

procedure ReadBlock(var P: CMatchFinder);
var CurSize: UInt32; Dest: PByte; Count, Actual: SizeT;
begin
  if (P.StreamEndWasReached <> 0) or (P.Result <> SZ_OK) then Exit;
  if P.DirectInput <> 0 then
  begin
    CurSize := High(UInt32) - Inline_MatchFinder_GetNumAvailableBytes(P);
    if SizeT(CurSize) > P.DirectInputRem then CurSize := UInt32(P.DirectInputRem);
    Inc(P.StreamPos, CurSize); Dec(P.DirectInputRem, CurSize);
    if P.DirectInputRem = 0 then P.StreamEndWasReached := 1;
    Exit;
  end;
  repeat
    Dest := P.Buffer + Inline_MatchFinder_GetNumAvailableBytes(P);
    Count := NativeUInt(P.BufBase + P.BlockSize) - NativeUInt(Dest);
    if Count = 0 then Exit;
    Actual := Count;
    P.Result := ILzmaSeqInStream(P.Stream).Read(Dest^, Count, Actual);
    if P.Result <> SZ_OK then Exit;
    if Actual = 0 then begin P.StreamEndWasReached := 1; Exit; end;
    // A callback reporting more than requested violates ISeqInStream's contract.
    if Actual > Count then begin P.Result := SZ_ERROR_FAIL; Exit; end;
    Inc(P.StreamPos, UInt32(Actual));
  until Inline_MatchFinder_GetNumAvailableBytes(P) > P.KeepSizeAfter;
end;

procedure MatchFinder_MoveBlock(var P: CMatchFinder);
var Offset, KeepBefore, Count, Part: SizeT; Src, Dest: PByte;
const
{$IFDEF LZMA_MF_SMALL_MOVE_QA}
  RtlMoveLimit = SizeT(127); // test-only: exercise splitting with ordinary windows
{$ELSE}
  RtlMoveLimit = SizeT(High(NativeInt));
{$ENDIF}
begin
  Offset := NativeUInt(P.Buffer) - NativeUInt(P.BufBase) - P.KeepSizeBefore;
  KeepBefore := (Offset and (BlockMoveAlign - 1)) + P.KeepSizeBefore;
  P.Buffer := P.BufBase + KeepBefore;
  Count := KeepBefore + Inline_MatchFinder_GetNumAvailableBytes(P);
  Src := P.BufBase + (Offset and not SizeT(BlockMoveAlign - 1)); Dest := P.BufBase;
  // Delphi Move takes signed NativeInt; SDK counts are unsigned SizeT. The
  // window always moves towards lower addresses, so forward chunks preserve
  // memmove semantics even when the whole count exceeds High(NativeInt).
  while Count <> 0 do
  begin
    Part := Count; if Part > RtlMoveLimit then Part := RtlMoveLimit;
    Move(Src^, Dest^, NativeInt(Part));
    Inc(Src, Part); Inc(Dest, Part); Dec(Count, Part);
  end;
end;

function MatchFinder_NeedMove(const P: CMatchFinder): Integer;
begin
  if (P.DirectInput <> 0) or (P.StreamEndWasReached <> 0) or (P.Result <> SZ_OK) then Exit(0);
  Result := Ord(NativeUInt(P.BufBase + P.BlockSize) - NativeUInt(P.Buffer) <= P.KeepSizeAfter);
end;

procedure MatchFinder_ReadIfRequired(var P: CMatchFinder);
begin if P.KeepSizeAfter >= Inline_MatchFinder_GetNumAvailableBytes(P) then ReadBlock(P); end;

procedure SetLimits(var P: CMatchFinder);
var N, K, Mm: UInt32;
begin
  N := UInt32(0) - P.Pos; if N = 0 then N := High(UInt32);
  K := P.CyclicBufferSize - P.CyclicBufferPos; if K < N then N := K;
  K := Inline_MatchFinder_GetNumAvailableBytes(P); Mm := P.MatchMaxLen;
  if K > P.KeepSizeAfter then Dec(K, P.KeepSizeAfter)
  else if K >= Mm then begin Dec(K, Mm); Inc(K); end
  else begin Mm := K; if K <> 0 then K := 1; end;
  P.LenLimit := Mm; if K < N then N := K; P.PosLimit := P.Pos + N;
end;

procedure MatchFinder_Init_LowHash(var P: CMatchFinder);
var I: SizeT;
begin
  I := 0; while I < P.FixedHashSize do begin P.Hash[I] := 0; Inc(I); end;
end;

procedure MatchFinder_Init_HighHash(var P: CMatchFinder);
var I, Count: SizeT; Items: PLzRef;
begin
  Items := P.Hash + P.FixedHashSize; Count := SizeT(P.HashMask) + 1;
  I := 0; while I < Count do begin Items[I] := 0; Inc(I); end;
end;

procedure MatchFinder_Init_4(var P: CMatchFinder);
begin
  if P.DirectInput = 0 then P.Buffer := P.BufBase;
  P.Pos := 1; P.StreamPos := 1; P.Result := SZ_OK; P.StreamEndWasReached := 0;
end;

procedure MatchFinder_Init(P: Pointer);
var M: PCMatchFinder;
begin
  M := P;
  MatchFinder_Init_HighHash(M^); MatchFinder_Init_LowHash(M^); MatchFinder_Init_4(M^);
  ReadBlock(M^); M.CyclicBufferPos := M.Pos; SetLimits(M^);
end;

procedure MatchFinder_Normalize3(SubValue: UInt32; Items: PLzRef; NumItems: SizeT);
var V: UInt32;
begin
  while NumItems <> 0 do
  begin
    V := Items^; if V < SubValue then V := SubValue;
    Items^ := V - SubValue; Inc(Items); Dec(NumItems);
  end;
end;

procedure CheckLimits(var P: CMatchFinder);
var SubValue: UInt32; NumSonRefs: SizeT;
begin
  if P.KeepSizeAfter = Inline_MatchFinder_GetNumAvailableBytes(P) then
  begin
    if MatchFinder_NeedMove(P) <> 0 then MatchFinder_MoveBlock(P);
    ReadBlock(P);
  end;
  if (P.Pos = 0) and (Inline_MatchFinder_GetNumAvailableBytes(P) >= P.NumHashBytes) then
  begin
    SubValue := P.Pos - P.HistorySize - 1;
    MatchFinder_REDUCE_OFFSETS(P, SubValue);
    MatchFinder_Normalize3(SubValue, P.Hash, SizeT(P.HashMask) + 1 + P.FixedHashSize);
    NumSonRefs := P.CyclicBufferSize;
    if P.BtMode <> 0 then NumSonRefs := NumSonRefs shl 1;
    MatchFinder_Normalize3(SubValue, P.Son, NumSonRefs);
  end;
  if P.CyclicBufferPos = P.CyclicBufferSize then P.CyclicBufferPos := 0;
  SetLimits(P);
end;

procedure MovePos(var P: CMatchFinder); inline;
begin
  Inc(P.CyclicBufferPos); Inc(P.Buffer); Inc(P.Pos);
  if P.Pos = P.PosLimit then CheckLimits(P);
end;

function CyclicIndex(CyclicPos: SizeT; Delta, CyclicSize: UInt32): SizeT; inline;
begin
  Result := CyclicPos - Delta;
  if CyclicPos < Delta then Inc(Result, CyclicSize);
end;

function GetMatchesSpec1(LenLimit, CurMatch, Pos: UInt32; Cur: PByte; Son: PLzRef;
  CyclicBufferPos: SizeT; CyclicBufferSize, CutValue: UInt32;
  Distances: PUInt32; MaxLen: UInt32): PUInt32;
var Ptr0, Ptr1, Pair: PLzRef; Pb: PByte; Len0, Len1, Len, CmCheck, Delta, Pair0: UInt32;
begin
  Ptr0 := Son + (CyclicBufferPos shl 1) + 1; Ptr1 := Ptr0 - 1;
  Len0 := 0; Len1 := 0;
  CmCheck := Pos - CyclicBufferSize; if Pos < CyclicBufferSize then CmCheck := 0;
  if CmCheck < CurMatch then
  repeat
    Delta := Pos - CurMatch;
    Pair := Son + (CyclicIndex(CyclicBufferPos, Delta, CyclicBufferSize) shl 1);
    Pb := Cur - Delta; Len := Len0; if Len1 < Len then Len := Len1;
    Pair0 := Pair[0];
    if Pb[Len] = Cur[Len] then
    begin
      Inc(Len);
      while (Len <> LenLimit) and (Pb[Len] = Cur[Len]) do Inc(Len);
      if MaxLen < Len then
      begin
        MaxLen := Len; Distances[0] := Len; Distances[1] := Delta - 1; Inc(Distances, 2);
        if Len = LenLimit then
        begin Ptr1^ := Pair0; Ptr0^ := Pair[1]; Exit(Distances); end;
      end;
    end;
    if Pb[Len] < Cur[Len] then
    begin Ptr1^ := CurMatch; CurMatch := Pair[1]; Ptr1 := Pair + 1; Len1 := Len; end
    else
    begin Ptr0^ := CurMatch; CurMatch := Pair[0]; Ptr0 := Pair; Len0 := Len; end;
    Dec(CutValue);
  until (CutValue = 0) or (CmCheck >= CurMatch);
  Ptr0^ := 0; Ptr1^ := 0; Result := Distances;
end;

procedure SkipMatchesSpec(LenLimit, CurMatch, Pos: UInt32; Cur: PByte; Son: PLzRef;
  CyclicBufferPos: SizeT; CyclicBufferSize, CutValue: UInt32);
var Ptr0, Ptr1, Pair: PLzRef; Pb: PByte; Len0, Len1, Len, CmCheck, Delta: UInt32;
begin
  Ptr0 := Son + (CyclicBufferPos shl 1) + 1; Ptr1 := Ptr0 - 1;
  Len0 := 0; Len1 := 0;
  CmCheck := Pos - CyclicBufferSize; if Pos < CyclicBufferSize then CmCheck := 0;
  if CmCheck < CurMatch then
  repeat
    Delta := Pos - CurMatch;
    Pair := Son + (CyclicIndex(CyclicBufferPos, Delta, CyclicBufferSize) shl 1);
    Pb := Cur - Delta; Len := Len0; if Len1 < Len then Len := Len1;
    if Pb[Len] = Cur[Len] then
    begin
      Inc(Len);
      while (Len <> LenLimit) and (Pb[Len] = Cur[Len]) do Inc(Len);
      if Len = LenLimit then begin Ptr1^ := Pair[0]; Ptr0^ := Pair[1]; Exit; end;
    end;
    if Pb[Len] < Cur[Len] then
    begin Ptr1^ := CurMatch; CurMatch := Pair[1]; Ptr1 := Pair + 1; Len1 := Len; end
    else
    begin Ptr0^ := CurMatch; CurMatch := Pair[0]; Ptr0 := Pair; Len0 := Len; end;
    Dec(CutValue);
  until (CutValue = 0) or (CmCheck >= CurMatch);
  Ptr0^ := 0; Ptr1^ := 0;
end;

function HcGetMatches(LenLimit, CurMatch, Pos: UInt32; Cur: PByte; Son: PLzRef;
  CyclicBufferPos: SizeT; CyclicBufferSize, CutValue: UInt32;
  Distances: PUInt32; MaxLen: UInt32): PUInt32;
var Delta, Len: UInt32; Pb: PByte;
begin
  Son[CyclicBufferPos] := CurMatch;
  repeat
    if CurMatch = 0 then Break;
    Delta := Pos - CurMatch; if Delta >= CyclicBufferSize then Break;
    CurMatch := Son[CyclicIndex(CyclicBufferPos, Delta, CyclicBufferSize)];
    Pb := Cur - Delta;
    if Cur[MaxLen] = Pb[MaxLen] then
    begin
      Len := 0; while (Len <> LenLimit) and (Cur[Len] = Pb[Len]) do Inc(Len);
      if Len = LenLimit then
      begin Distances[0] := Len; Distances[1] := Delta - 1; Exit(Distances + 2); end;
      if MaxLen < Len then
      begin MaxLen := Len; Distances[0] := Len; Distances[1] := Delta - 1; Inc(Distances, 2); end;
    end;
    Dec(CutValue);
  until CutValue = 0;
  Result := Distances;
end;

procedure HashValues(const P: CMatchFinder; Cur: PByte; Width: UInt32; Zip: Boolean;
  out H2, H3, Hv, FixedSize: UInt32); inline;
var Temp: UInt32;
begin
  H2 := 0; H3 := 0; FixedSize := 0;
  if Zip then begin Hv := ((UInt32(Cur[2]) or (UInt32(Cur[0]) shl 8)) xor P.Crc[Cur[1]]) and $FFFF; Exit; end;
  if Width = 2 then begin Hv := UInt32(Cur[0]) or (UInt32(Cur[1]) shl 8); Exit; end;
  Temp := P.Crc[Cur[0]] xor Cur[1]; H2 := Temp and (Hash2Size - 1);
  Temp := Temp xor (UInt32(Cur[2]) shl 8); FixedSize := Hash2Size;
  if Width >= 4 then
  begin
    H3 := Temp and (Hash3Size - 1); Temp := Temp xor (P.Crc[Cur[3]] shl 5);
    FixedSize := Fix4HashSize;
  end;
  if Width >= 5 then Temp := Temp xor (P.Crc[Cur[4]] shl 10);
  Hv := Temp and P.HashMask;
end;

function GetMatches(P: PCMatchFinder; Distances: PUInt32; Width: UInt32;
  Tree, Zip: Boolean): PUInt32;
var Cur, Pb: PByte; LenLimit, H2, H3, Hv, FixedSize, Pos, CurMatch,
    D2, D3, Mmm, MaxLen: UInt32; HavePrefix: Boolean;
begin
  LenLimit := P.LenLimit;
  if LenLimit < Width then begin MovePos(P^); Exit(Distances); end;
  Cur := P.Buffer; Pos := P.Pos;
  HashValues(P^, Cur, Width, Zip, H2, H3, Hv, FixedSize);
  D2 := 0; D3 := 0;
  CurMatch := P.Hash[SizeT(FixedSize) + Hv];
  if (Width > 2) and not Zip then
  begin
    D2 := Pos - P.Hash[H2]; P.Hash[H2] := Pos;
    if Width >= 4 then
    begin D3 := Pos - P.Hash[SizeT(Hash2Size) + H3]; P.Hash[SizeT(Hash2Size) + H3] := Pos; end;
  end;
  P.Hash[SizeT(FixedSize) + Hv] := Pos;
  MaxLen := Width - 1;
  Mmm := P.CyclicBufferSize; if Pos < Mmm then Mmm := Pos;
  HavePrefix := False;
  if not Zip and (Width = 3) then
  begin
    if (D2 < Mmm) and ((Cur - D2)^ = Cur^) then
    begin
      MaxLen := 2; Pb := Cur - D2;
      while (MaxLen <> LenLimit) and (Pb[MaxLen] = Cur[MaxLen]) do Inc(MaxLen);
      Distances[0] := MaxLen; Distances[1] := D2 - 1; Inc(Distances, 2);
      HavePrefix := True;
    end;
  end
  else if not Zip and (Width >= 4) then
  begin
    if (D2 < Mmm) and ((Cur - D2)^ = Cur^) then
    begin
      Distances[0] := 2; Distances[1] := D2 - 1; Inc(Distances, 2);
      if (Cur - D2 + 2)^ = Cur[2] then HavePrefix := True
      else if (D3 < Mmm) and ((Cur - D3)^ = Cur^) then
      begin D2 := D3; Distances[1] := D3 - 1; Inc(Distances, 2); HavePrefix := True; end;
    end
    else if (D3 < Mmm) and ((Cur - D3)^ = Cur^) then
    begin D2 := D3; Distances[1] := D3 - 1; Inc(Distances, 2); HavePrefix := True; end;
    if HavePrefix then
    begin
      if Width >= 5 then
      begin
        (Distances - 2)^ := 3;
        if (Cur - D2 + 3)^ <> Cur[3] then HavePrefix := False;
      end;
      if HavePrefix then
      begin
        Pb := Cur - D2;
        while (MaxLen <> LenLimit) and (Pb[MaxLen] = Cur[MaxLen]) do Inc(MaxLen);
        (Distances - 2)^ := MaxLen;
      end;
    end;
  end;
  if HavePrefix and (MaxLen = LenLimit) then
  begin
    if Tree then SkipMatchesSpec(LenLimit, CurMatch, Pos, Cur, P.Son,
      P.CyclicBufferPos, P.CyclicBufferSize, P.CutValue)
    else P.Son[P.CyclicBufferPos] := CurMatch;
  end
  else if Tree then Distances := GetMatchesSpec1(LenLimit, CurMatch, Pos, Cur, P.Son,
    P.CyclicBufferPos, P.CyclicBufferSize, P.CutValue, Distances, MaxLen)
  else Distances := HcGetMatches(LenLimit, CurMatch, Pos, Cur, P.Son,
    P.CyclicBufferPos, P.CyclicBufferSize, P.CutValue, Distances, MaxLen);
  MovePos(P^); Result := Distances;
end;

procedure Skip(P: PCMatchFinder; Num, Width: UInt32; Tree, Zip: Boolean);
var H2, H3, Hv, FixedSize, CurMatch: UInt32;
begin
  // The SDK precondition is Num > 0. Accept zero as a harmless no-op too.
  while Num <> 0 do
  begin
    if P.LenLimit >= Width then
    begin
      HashValues(P^, P.Buffer, Width, Zip, H2, H3, Hv, FixedSize);
      CurMatch := P.Hash[SizeT(FixedSize) + Hv];
      if (Width > 2) and not Zip then
      begin
        P.Hash[H2] := P.Pos;
        if Width >= 4 then P.Hash[SizeT(Hash2Size) + H3] := P.Pos;
      end;
      P.Hash[SizeT(FixedSize) + Hv] := P.Pos;
      if Tree then SkipMatchesSpec(P.LenLimit, CurMatch, P.Pos, P.Buffer, P.Son,
        P.CyclicBufferPos, P.CyclicBufferSize, P.CutValue)
      else P.Son[P.CyclicBufferPos] := CurMatch;
    end;
    MovePos(P^); Dec(Num);
  end;
end;

function CurrentPointer(P: Pointer): PByte; cdecl;
begin Result := PCMatchFinder(P).Buffer; end;
function Available(P: Pointer): UInt32; cdecl;
begin Result := Inline_MatchFinder_GetNumAvailableBytes(PCMatchFinder(P)^); end;

function Bt2(P: Pointer; D: PUInt32): PUInt32; cdecl;
begin Result := GetMatches(P, D, 2, True, False); end;
function Bt3(P: Pointer; D: PUInt32): PUInt32; cdecl;
begin Result := GetMatches(P, D, 3, True, False); end;
function Bt4(P: Pointer; D: PUInt32): PUInt32; cdecl;
begin Result := GetMatches(P, D, 4, True, False); end;
function Bt5(P: Pointer; D: PUInt32): PUInt32; cdecl;
begin Result := GetMatches(P, D, 5, True, False); end;
function Hc4(P: Pointer; D: PUInt32): PUInt32; cdecl;
begin Result := GetMatches(P, D, 4, False, False); end;
function Hc5(P: Pointer; D: PUInt32): PUInt32; cdecl;
begin Result := GetMatches(P, D, 5, False, False); end;
procedure SkipBt2(P: Pointer; N: UInt32); cdecl;
begin Skip(P, N, 2, True, False); end;
procedure SkipBt3(P: Pointer; N: UInt32); cdecl;
begin Skip(P, N, 3, True, False); end;
procedure SkipBt4(P: Pointer; N: UInt32); cdecl;
begin Skip(P, N, 4, True, False); end;
procedure SkipBt5(P: Pointer; N: UInt32); cdecl;
begin Skip(P, N, 5, True, False); end;
procedure SkipHc4(P: Pointer; N: UInt32); cdecl;
begin Skip(P, N, 4, False, False); end;
procedure SkipHc5(P: Pointer; N: UInt32); cdecl;
begin Skip(P, N, 5, False, False); end;

function Bt3Zip_MatchFinder_GetMatches(P: PCMatchFinder; Distances: PUInt32): PUInt32;
begin Result := GetMatches(P, Distances, 3, True, True); end;
function Hc3Zip_MatchFinder_GetMatches(P: PCMatchFinder; Distances: PUInt32): PUInt32;
begin Result := GetMatches(P, Distances, 3, False, True); end;
procedure Bt3Zip_MatchFinder_Skip(P: PCMatchFinder; Num: UInt32);
begin Skip(P, Num, 3, True, True); end;
procedure Hc3Zip_MatchFinder_Skip(P: PCMatchFinder; Num: UInt32);
begin Skip(P, Num, 3, False, True); end;

procedure MatchFinder_CreateVTable(var P: CMatchFinder; out VTable: IMatchFinder2);
begin
  VTable.Init := MatchFinder_Init; VTable.GetNumAvailableBytes := Available;
  VTable.GetPointerToCurrentPos := CurrentPointer;
  if P.BtMode = 0 then
    if P.NumHashBytes <= 4 then begin VTable.GetMatches := Hc4; VTable.Skip := SkipHc4; end
    else begin VTable.GetMatches := Hc5; VTable.Skip := SkipHc5; end
  else if P.NumHashBytes = 2 then begin VTable.GetMatches := Bt2; VTable.Skip := SkipBt2; end
  else if P.NumHashBytes = 3 then begin VTable.GetMatches := Bt3; VTable.Skip := SkipBt3; end
  else if P.NumHashBytes = 4 then begin VTable.GetMatches := Bt4; VTable.Skip := SkipBt4; end
  else begin VTable.GetMatches := Bt5; VTable.Skip := SkipBt5; end;
end;

procedure LzFindPrepare;
begin
  // Scalar saturating subtraction has no CPU feature initialization.
end;

end.
