unit Lzma.Sdk.MatchFinderMt26;

// Native SDK 26.05 LzFindMt.c/LzFindOpt.c (Igor Pavlov, public domain).
// Caller-owned unmanaged state and allocator-owned bounded transfer buffers.
// The hash and BT workers use RTL threads; the LZ caller is the consumer.
{$ALIGN 8}
{$POINTERMATH ON}
{$B-}
interface

uses Lzma.Types, Lzma.Sdk.Contracts, Lzma.Sdk.MatchFinder26, Lzma.Sdk.Threads26;

const
  MtHashBlockSize = UInt32(1) shl 17;
  MtHashNumBlocks = 2;
  MtBtBlockSize = UInt32(1) shl 16;
  MtBtNumBlocks = 16;

type
  CMtSync = record
    NumProcessedBlocks: UInt32;
    AffinityGroup: Int32;
    AffinityInGroup, Affinity: UInt64;
    Thread: CThread;
    WasCreated, NeedStart, CsWasInitialized, CsWasEntered: Int32;
    ExitRequested, StopWriting: Int32;
    CanStart, WasStopped: CAutoResetEvent;
    FreeSemaphore, FilledSemaphore: CSemaphore;
    Cs: CCriticalSection;
  end;
  PCMatchFinderMt = ^CMatchFinderMt;
  TMfMixMatches = function(P: PCMatchFinderMt; MatchMinPos: UInt32;
    Distances: PUInt32): PUInt32; cdecl;
  TMfGetHeads = procedure(Buffer: PByte; Pos: UInt32; Hash: PUInt32;
    HashMask: UInt32; Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
  CMatchFinderMt = record
    PointerToCurPos: PByte;
    BtBuf, BtBufPos, BtBufPosLimit: PUInt32;
    LzPos, BtNumAvailBytes: UInt32;
    Hash: PUInt32;
    FixedHashSize, HistorySize: UInt32;
    Crc: PUInt32;
    MixMatchesFunc: TMfMixMatches;
    FailureLzBt: UInt32;
    FailureBuf: array[0..0] of UInt32;
    BtSync: CMtSync;
    BtDummy: array[0..127] of Byte;
    HashBuf: PUInt32;
    HashBufPos, HashBufPosLimit, HashNumAvail, FailureBt: UInt32;
    Son: PLzRef;
    MatchMaxLen, NumHashBytes, Pos: UInt32;
    Buffer: PByte;
    CyclicBufferPos, CyclicBufferSize, CutValue: UInt32;
    HashSync: CMtSync;
    GetHeadsFunc: TMfGetHeads;
    MatchFinder: PCMatchFinder;
  end;

procedure MatchFinderMt_Construct(var P: CMatchFinderMt);
procedure MatchFinderMt_Destruct(var P: CMatchFinderMt; const Alloc: ILzmaAllocator);
function MatchFinderMt_Create(var P: CMatchFinderMt; HistorySize, KeepAddBufferBefore,
  MatchMaxLen, KeepAddBufferAfter: UInt32; const Alloc: ILzmaAllocator): SRes;
procedure MatchFinderMt_CreateVTable(var P: CMatchFinderMt; out VTable: IMatchFinder2);
function MatchFinderMt_InitMt(var P: CMatchFinderMt): SRes;
procedure MatchFinderMt_ReleaseStream(var P: CMatchFinderMt);
function GetMatchesSpecN_2(LenLimit: PByte; Pos: SizeT; Cur: PByte; Son: PLzRef;
  CutValue: UInt32; D: PUInt32; MaxLen: SizeT; Hash, Limit, HashEnd: PUInt32;
  CyclicBufferPos: SizeT; CyclicBufferSize: UInt32; var PosRes: UInt32): PUInt32;

{$IFDEF LZMA_SDK_ENCODER_MT_QA}
procedure LzmaMtQa_SetThreadFailure(AtCall, ErrorCode: UInt32);
function LzmaMtQa_ThreadCalls: UInt32;
{$ENDIF}

implementation

uses System.SysUtils, Winapi.Windows;

{$Q-}
{$R-}

const
  HashBufferSize = MtHashBlockSize * MtHashNumBlocks;
  BtBufferSize = MtBtBlockSize * MtBtNumBlocks;
  Hash2Size = UInt32(1) shl 10;

function Allocate(const Alloc: ILzmaAllocator; Count: SizeT): Pointer;
begin
  try
    if Alloc = nil then Result := LzmaDefaultAllocate(Count) else Result := Alloc.Alloc(Count);
  except on E: EOutOfMemory do Result := nil; end;
end;
procedure Release(const Alloc: ILzmaAllocator; Address: Pointer);
begin
  if Alloc = nil then LzmaDefaultFree(Address) else Alloc.FreeMem(Address);
end;

{$IFDEF LZMA_SDK_ENCODER_MT_QA}
// Fault injection is absent from release builds. All create/init calls below
// occur on the LZ caller; this finite QA harness uses one handle at a time.
var QaThreadAt, QaThreadError, QaThreadCount: UInt32;
procedure LzmaMtQa_SetThreadFailure(AtCall, ErrorCode: UInt32);
begin QaThreadAt:=AtCall;QaThreadError:=ErrorCode;QaThreadCount:=0;end;
function LzmaMtQa_ThreadCalls: UInt32;
begin Result:=QaThreadCount;end;
function QaThreadCall: WRes;
begin
  Inc(QaThreadCount);if (QaThreadAt<>0) and (QaThreadCount=QaThreadAt) then Result:=QaThreadError else Result:=0;
end;
function QaSemaphoreInit(var S:CSemaphore;Initial,Maximum:UInt32):WRes;
var CloseResult:WRes;
begin
  Result:=QaThreadCall;
  if Result=0 then Exit(Semaphore_OptCreateInit(S,Initial,Maximum));
  CloseResult:=HandlePtr_Close(S);if CloseResult<>0 then Result:=CloseResult;
end;
{$ENDIF}
{$I Lzma.Sdk.MatchFinderMt26.Sync.inc}
{$I Lzma.Sdk.MatchFinderMt26.Opt.inc}

function U16(P: PByte): UInt32; inline;
begin Result := UInt32(P[0]) or (UInt32(P[1]) shl 8); end;
function U24(P: PByte): UInt32; inline;
begin Result := U16(P) or (UInt32(P[2]) shl 16); end;

procedure GetHeads2(Buffer: PByte; Pos: UInt32; Hash: PUInt32; HashMask: UInt32;
  Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
var V: UInt32;
begin
  while NumHeads <> 0 do
  begin V := U16(Buffer); Heads^ := Pos-Hash[V]; Hash[V] := Pos;
    Inc(Buffer); Inc(Heads); Inc(Pos); Dec(NumHeads); end;
end;
procedure GetHeads3(Buffer: PByte; Pos: UInt32; Hash: PUInt32; HashMask: UInt32;
  Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
var V: UInt32;
begin
  while NumHeads <> 0 do
  begin V := (Crc[Buffer[0]] xor U16(Buffer+1)) and HashMask;
    Heads^ := Pos-Hash[V]; Hash[V] := Pos;
    Inc(Buffer); Inc(Heads); Inc(Pos); Dec(NumHeads); end;
end;
procedure GetHeads3b(Buffer: PByte; Pos: UInt32; Hash: PUInt32; HashMask: UInt32;
  Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
var V: UInt32;
begin
  while NumHeads <> 0 do
  begin V := U24(Buffer); Heads^ := Pos-Hash[V]; Hash[V] := Pos;
    Inc(Buffer); Inc(Heads); Inc(Pos); Dec(NumHeads); end;
end;
procedure GetHeads4(Buffer: PByte; Pos: UInt32; Hash: PUInt32; HashMask: UInt32;
  Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
var V: UInt32;
begin
  while NumHeads <> 0 do
  begin V := (Crc[Buffer[0]] and HashMask) xor ((Crc[Buffer[3]] shl 5) and HashMask) xor U16(Buffer+1);
    Heads^ := Pos-Hash[V]; Hash[V] := Pos;
    Inc(Buffer); Inc(Heads); Inc(Pos); Dec(NumHeads); end;
end;
procedure GetHeads4b(Buffer: PByte; Pos: UInt32; Hash: PUInt32; HashMask: UInt32;
  Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
var V: UInt32;
begin
  while NumHeads <> 0 do
  begin V := (Crc[Buffer[0]] and HashMask) xor U24(Buffer+1);
    Heads^ := Pos-Hash[V]; Hash[V] := Pos;
    Inc(Buffer); Inc(Heads); Inc(Pos); Dec(NumHeads); end;
end;
procedure GetHeads5(Buffer: PByte; Pos: UInt32; Hash: PUInt32; HashMask: UInt32;
  Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
var V: UInt32;
begin
  while NumHeads <> 0 do
  begin V := (Crc[Buffer[0]] and HashMask) xor ((Crc[Buffer[3]] shl 5) and HashMask)
      xor ((Crc[Buffer[4]] shl 10) and HashMask) xor U16(Buffer+1);
    Heads^ := Pos-Hash[V]; Hash[V] := Pos;
    Inc(Buffer); Inc(Heads); Inc(Pos); Dec(NumHeads); end;
end;
procedure GetHeads5b(Buffer: PByte; Pos: UInt32; Hash: PUInt32; HashMask: UInt32;
  Heads: PUInt32; NumHeads: UInt32; Crc: PUInt32); cdecl;
var V: UInt32;
begin
  while NumHeads <> 0 do
  begin V := (Crc[Buffer[0]] and HashMask) xor ((Crc[Buffer[4]] shl 5) and HashMask) xor U24(Buffer+1);
    Heads^ := Pos-Hash[V]; Hash[V] := Pos;
    Inc(Buffer); Inc(Heads); Inc(Pos); Dec(NumHeads); end;
end;

procedure HashThreadBody(P: PCMatchFinderMt);
var S: ^CMtSync; Mf: PCMatchFinder; BlockIndex, Num, SubValue: UInt32;
  Heads: PUInt32; BeforePtr: PByte; Offset: NativeInt;
begin
  S := @P.HashSync; Mf := P.MatchFinder;
  while True do
  begin
    BlockIndex := 0; Handle_WaitObject(S.CanStart);
    if S.ExitRequested <> 0 then Exit;
    MatchFinder_Init_HighHash(Mf^);
    while True do
    begin
      if MatchFinder_NeedMove(Mf^) <> 0 then
      begin
        EnterCriticalSection(P.BtSync.Cs); EnterCriticalSection(P.HashSync.Cs);
        BeforePtr := Mf.Buffer; MatchFinder_MoveBlock(Mf^);
        Offset := NativeInt(BeforePtr)-NativeInt(Mf.Buffer);
        P.PointerToCurPos := P.PointerToCurPos-Offset; P.Buffer := P.Buffer-Offset;
        LeaveCriticalSection(P.HashSync.Cs); LeaveCriticalSection(P.BtSync.Cs);
        Continue;
      end;
      Handle_WaitObject(S.FreeSemaphore);
      if S.ExitRequested <> 0 then Exit;
      if S.StopWriting <> 0 then Break;
      MatchFinder_ReadIfRequired(Mf^);
      Heads := P.HashBuf+(BlockIndex and (MtHashNumBlocks-1))*MtHashBlockSize; Inc(BlockIndex);
      Num := Inline_MatchFinder_GetNumAvailableBytes(Mf^); Heads[0] := 2; Heads[1] := Num;
      if Num >= Mf.NumHashBytes then
      begin
        Num := Num-Mf.NumHashBytes+1; if Num > MtHashBlockSize-2 then Num := MtHashBlockSize-2;
        if Mf.Pos > High(UInt32)-Num then
        begin
          SubValue := Mf.Pos-Mf.HistorySize-1; MatchFinder_REDUCE_OFFSETS(Mf^,SubValue);
          MatchFinder_Normalize3(SubValue,Mf.Hash+Mf.FixedHashSize,SizeT(Mf.HashMask)+1);
        end;
        Heads[0] := 2+Num;
        P.GetHeadsFunc(Mf.Buffer,Mf.Pos,PUInt32(Mf.Hash+Mf.FixedHashSize),Mf.HashMask,Heads+2,Num,@Mf.Crc[0]);
      end;
      Inc(Mf.Pos,Num); Inc(Mf.Buffer,Num);
      Semaphore_Release1(S.FilledSemaphore);
    end;
    Event_Set(S.WasStopped);
  end;
end;

procedure BtGetMatches(P: PCMatchFinderMt; D: PUInt32);
var NumProcessed, CurPos, Limit, Bi, K, Avail, AvailSum, Size, Size2,
    Pos, CyclicPos, LenLimit, SubValue, PosRes, Processed: UInt32;
  H, DEnd: PUInt32;
begin
  NumProcessed := 0; CurPos := 2; Limit := MtBtBlockSize-P.MatchMaxLen*2; D[1] := P.HashNumAvail;
  if P.FailureBt <> 0 then begin D[0] := 0; Exit; end;
  while CurPos < Limit do
  begin
    if P.HashBufPos = P.HashBufPosLimit then
    begin
      Bi := MtSync_GetNextBlock(P.HashSync); K := (Bi and (MtHashNumBlocks-1))*MtHashBlockSize;
      H := P.HashBuf+K; Avail := H[1]; P.HashBufPosLimit := K+H[0];
      P.HashNumAvail := Avail; P.HashBufPos := K+2;
      AvailSum := NumProcessed+Avail; if AvailSum < NumProcessed then AvailSum := High(UInt32);
      D[1] := AvailSum;
      if Avail >= P.NumHashBytes then Continue;
      P.HashNumAvail := 0; D[0] := CurPos+Avail; Inc(D,CurPos);
      while Avail <> 0 do begin D^ := 0; Inc(D); Dec(Avail); end;
      Exit;
    end;
    Size := P.HashBufPosLimit-P.HashBufPos; Pos := P.Pos; CyclicPos := P.CyclicBufferPos;
    LenLimit := P.MatchMaxLen; if LenLimit >= P.HashNumAvail then LenLimit := P.HashNumAvail;
    Size2 := P.HashNumAvail-LenLimit+1; if Size2 < Size then Size := Size2;
    Size2 := P.CyclicBufferSize-CyclicPos; if Size2 < Size then Size := Size2;
    if Pos > High(UInt32)-Size then
    begin
      SubValue := Pos-P.CyclicBufferSize; Dec(Pos,SubValue); P.Pos := Pos;
      MatchFinder_Normalize3(SubValue,P.Son,SizeT(P.CyclicBufferSize)*2);
    end;
    PosRes := Pos;
    DEnd := GetMatchesSpecN_2(P.Buffer+LenLimit-1,Pos,P.Buffer,P.Son,P.CutValue,D+CurPos,
      P.NumHashBytes-1,P.HashBuf+P.HashBufPos,D+Limit,P.HashBuf+P.HashBufPos+Size,
      CyclicPos,P.CyclicBufferSize,PosRes);
    if DEnd = nil then begin P.FailureBt := 1; D[0] := 0; Exit; end;
    CurPos := UInt32((NativeUInt(DEnd)-NativeUInt(D)) div SizeOf(UInt32));
    Processed := PosRes-Pos; Pos := PosRes; Inc(P.HashBufPos,Processed);
    Inc(CyclicPos,Processed); Inc(P.Buffer,Processed);
    Processed := Pos-P.Pos; Inc(NumProcessed,Processed); Dec(P.HashNumAvail,Processed); P.Pos := Pos;
    if CyclicPos = P.CyclicBufferSize then CyclicPos := 0;
    P.CyclicBufferPos := CyclicPos;
  end;
  D[0] := CurPos;
end;

procedure BtFillBlock(P: PCMatchFinderMt; GlobalBlockIndex: UInt32);
begin
  if P.HashSync.NeedStart = 0 then MtSync_Lock(P.HashSync);
  BtGetMatches(P,P.BtBuf+SizeT(GlobalBlockIndex and (MtBtNumBlocks-1))*MtBtBlockSize);
  MtSync_Unlock(P.HashSync);
end;
procedure BtThreadBody(P: PCMatchFinderMt);
var S: ^CMtSync; BlockIndex: UInt32;
begin
  S := @P.BtSync;
  while True do
  begin
    BlockIndex := 0; Handle_WaitObject(S.CanStart);
    while True do
    begin
      if S.ExitRequested <> 0 then Exit;
      Handle_WaitObject(S.FreeSemaphore); if S.StopWriting <> 0 then Break;
      BtFillBlock(P,BlockIndex); Inc(BlockIndex); Semaphore_Release1(S.FilledSemaphore);
    end;
    MtSync_StopWriting(P.HashSync); Event_Set(S.WasStopped);
  end;
end;
function HashThreadProc(Param: Pointer): Integer;
begin HashThreadBody(Param); Result := 0; end;
function BtThreadProc(Param: Pointer): Integer;
begin BtThreadBody(Param); Result := 0; end;

procedure MatchFinderMt_Construct(var P: CMatchFinderMt);
begin
  P.HashBuf := nil; MtSync_Construct(P.HashSync); MtSync_Construct(P.BtSync);
end;
procedure MatchFinderMt_ReleaseStream(var P: CMatchFinderMt);
begin MtSync_StopWriting(P.BtSync); end;
procedure MatchFinderMt_Destruct(var P: CMatchFinderMt; const Alloc: ILzmaAllocator);
begin
  MatchFinderMt_ReleaseStream(P); MtSync_Destruct(P.BtSync); MtSync_Destruct(P.HashSync);
  Release(Alloc,P.HashBuf); P.HashBuf := nil;
end;
function MatchFinderMt_Create(var P: CMatchFinderMt; HistorySize, KeepAddBufferBefore,
  MatchMaxLen, KeepAddBufferAfter: UInt32; const Alloc: ILzmaAllocator): SRes;
begin
  P.HistorySize := HistorySize; if MtBtBlockSize <= MatchMaxLen*4 then Exit(SZ_ERROR_PARAM);
  if P.HashBuf = nil then
  begin
    P.HashBuf := Allocate(Alloc,(SizeT(HashBufferSize)+SizeT(BtBufferSize))*SizeOf(UInt32));
    if P.HashBuf = nil then Exit(SZ_ERROR_MEM); P.BtBuf := P.HashBuf+HashBufferSize;
  end;
  Inc(KeepAddBufferBefore,HashBufferSize+BtBufferSize); Inc(KeepAddBufferAfter,MtHashBlockSize);
  if MatchFinder_Create(P.MatchFinder^,HistorySize,KeepAddBufferBefore,MatchMaxLen,KeepAddBufferAfter,Alloc)=0 then Exit(SZ_ERROR_MEM);
  Result := MtSync_Create(P.HashSync,HashThreadProc,@P); if Result <> SZ_OK then Exit;
  Result := MtSync_Create(P.BtSync,BtThreadProc,@P);
end;
function MatchFinderMt_InitMt(var P: CMatchFinderMt): SRes;
begin
  Result := MtSync_Init(P.HashSync,MtHashNumBlocks);
  if Result = SZ_OK then Result := MtSync_Init(P.BtSync,MtBtNumBlocks);
end;
procedure MatchFinderMt_Init(Obj: Pointer); cdecl;
var P: PCMatchFinderMt; Mf: PCMatchFinder;
begin
  P := Obj; Mf := P.MatchFinder;
  P.BtBufPos := nil; P.BtBufPosLimit := nil; P.HashBufPos := 0; P.HashBufPosLimit := 0;
  P.HashNumAvail := 0; P.FailureBt := 0; MatchFinder_Init_4(Mf^); MatchFinder_Init_LowHash(Mf^);
  P.PointerToCurPos := Mf.Buffer; P.BtNumAvailBytes := 0; P.FailureLzBt := 0; P.LzPos := 1;
  P.Hash := PUInt32(Mf.Hash); P.FixedHashSize := Mf.FixedHashSize; P.Crc := @Mf.Crc[0];
  P.Son := Mf.Son; P.MatchMaxLen := Mf.MatchMaxLen; P.NumHashBytes := Mf.NumHashBytes;
  P.Pos := Mf.Pos; P.CyclicBufferPos := P.Pos; P.CyclicBufferSize := Mf.CyclicBufferSize;
  P.Buffer := Mf.Buffer; P.CutValue := Mf.CutValue;
end;

function NextBtBlock(P: PCMatchFinderMt): UInt32;
var Bi, NumItems, SubValue: UInt32; Bt: PUInt32;
begin
  if P.FailureLzBt <> 0 then P.BtBufPos := @P.FailureBuf[0]
  else
  begin
    Bi := MtSync_GetNextBlock(P.BtSync); Bt := P.BtBuf+SizeT(Bi and (MtBtNumBlocks-1))*MtBtBlockSize;
    NumItems := Bt[0]; P.BtBufPosLimit := Bt+NumItems; P.BtNumAvailBytes := Bt[1]; P.BtBufPos := Bt+2;
    if (NumItems < 2) or (NumItems > MtBtBlockSize) then
    begin
      P.FailureBuf[0] := 0; P.BtBufPos := @P.FailureBuf[0];
      P.BtBufPosLimit := PUInt32(@P.FailureBuf[0])+1; P.FailureLzBt := 1;
    end;
    if P.LzPos >= High(UInt32)-MtBtBlockSize then
    begin
      SubValue := P.LzPos-P.HistorySize-1; Dec(P.LzPos,SubValue);
      MatchFinder_Normalize3(SubValue,PLzRef(P.Hash),P.FixedHashSize);
    end;
  end;
  Result := P.BtNumAvailBytes;
end;
function MtGetPointer(Obj: Pointer): PByte; cdecl;
begin Result := PCMatchFinderMt(Obj).PointerToCurPos; end;
function MtGetAvailable(Obj: Pointer): UInt32; cdecl;
var P: PCMatchFinderMt;
begin
  P := Obj; if P.BtBufPos <> P.BtBufPosLimit then Result := P.BtNumAvailBytes else Result := NextBtBlock(P);
end;

function MixMatches2(P: PCMatchFinderMt; MatchMinPos: UInt32; D: PUInt32): PUInt32; cdecl;
var H2, C2, M: UInt32; Cur: PByte;
begin
  Cur := P.PointerToCurPos; M := P.LzPos; H2 := (P.Crc[Cur[0]] xor Cur[1]) and (Hash2Size-1);
  C2 := P.Hash[H2]; P.Hash[H2] := M;
  if (C2 >= MatchMinPos) and ((Cur+NativeInt(C2)-NativeInt(M))^ = Cur[0]) then
  begin D[0] := 2; D[1] := M-C2-1; Inc(D,2); end;
  Result := D;
end;
function MixMatches3(P: PCMatchFinderMt; MatchMinPos: UInt32; D: PUInt32): PUInt32; cdecl;
var Temp, H2, H3, C2, C3, M: UInt32; Cur: PByte;
begin
  Cur := P.PointerToCurPos; M := P.LzPos; Temp := P.Crc[Cur[0]] xor Cur[1]; H2 := Temp and (Hash2Size-1);
  H3 := (Temp xor (UInt32(Cur[2]) shl 8)) and $FFFF; C2 := P.Hash[H2]; C3 := P.Hash[Hash2Size+H3];
  P.Hash[H2] := M; P.Hash[Hash2Size+H3] := M;
  if (C2 >= MatchMinPos) and ((Cur+NativeInt(C2)-NativeInt(M))^ = Cur[0]) then
  begin
    D[1] := M-C2-1;
    if (Cur+NativeInt(C2)-NativeInt(M)+2)^ = Cur[2] then begin D[0] := 3; Exit(D+2); end;
    D[0] := 2; Inc(D,2);
  end;
  if (C3 >= MatchMinPos) and ((Cur+NativeInt(C3)-NativeInt(M))^ = Cur[0]) then
  begin D[0] := 3; D[1] := M-C3-1; Inc(D,2); end;
  Result := D;
end;
function MixMatches4(P: PCMatchFinderMt; MatchMinPos: UInt32; D: PUInt32): PUInt32; cdecl;
var Temp, H2, H3, C2, C3, M: UInt32; Cur: PByte;
begin
  Cur := P.PointerToCurPos; M := P.LzPos; Temp := P.Crc[Cur[0]] xor Cur[1]; H2 := Temp and (Hash2Size-1);
  H3 := (Temp xor (UInt32(Cur[2]) shl 8)) and $FFFF; C2 := P.Hash[H2]; C3 := P.Hash[Hash2Size+H3];
  P.Hash[H2] := M; P.Hash[Hash2Size+H3] := M;
  if (C2 >= MatchMinPos) and ((Cur+NativeInt(C2)-NativeInt(M))^ = Cur[0]) then
  begin
    D[1] := M-C2-1;
    if (Cur+NativeInt(C2)-NativeInt(M)+2)^ = Cur[2] then
    begin
      if (Cur+NativeInt(C2)-NativeInt(M)+3)^ = Cur[3] then begin D[0] := 4; Exit(D+2); end;
      D[0] := 3; Exit(D+2);
    end;
    D[0] := 2; Inc(D,2);
  end;
  if (C3 >= MatchMinPos) and ((Cur+NativeInt(C3)-NativeInt(M))^ = Cur[0]) then
  begin
    D[1] := M-C3-1;
    if (Cur+NativeInt(C3)-NativeInt(M)+3)^ = Cur[3] then begin D[0] := 4; Exit(D+2); end;
    D[0] := 3; Inc(D,2);
  end;
  Result := D;
end;
function MtGetMatches2(Obj: Pointer; D: PUInt32): PUInt32; cdecl;
var P: PCMatchFinderMt; Bt, BtLimit: PUInt32; Len: UInt32;
begin
  P := Obj; Bt := P.BtBufPos; Len := Bt^; Inc(Bt); BtLimit := Bt+Len;
  P.BtBufPos := BtLimit; Dec(P.BtNumAvailBytes); Inc(P.LzPos); Inc(P.PointerToCurPos);
  while Bt <> BtLimit do begin D[0] := Bt[0]; D[1] := Bt[1]; Inc(D,2); Inc(Bt,2); end;
  Result := D;
end;
function MtGetMatches(Obj: Pointer; D: PUInt32): PUInt32; cdecl;
var P: PCMatchFinderMt; Bt: PUInt32; Len, Avail, M: UInt32;
begin
  P := Obj; Bt := P.BtBufPos; Len := Bt^; Inc(Bt); Avail := P.BtNumAvailBytes-1;
  P.BtNumAvailBytes := Avail; P.BtBufPos := Bt+Len;
  if Len = 0 then
  begin
    if Avail >= 3 then
    begin
      M := P.LzPos; if M > P.HistorySize then Dec(M,P.HistorySize) else M := 1;
      D := P.MixMatchesFunc(P,M,D);
    end;
  end
  else
  begin
    D := P.MixMatchesFunc(P,P.LzPos-Bt[1],D);
    repeat D[0] := Bt[0]; D[1] := Bt[1]; Inc(D,2); Inc(Bt,2); Dec(Len,2); until Len = 0;
  end;
  Inc(P.LzPos); Inc(P.PointerToCurPos); Result := D;
end;
procedure MtSkip(P: PCMatchFinderMt; Num, HashBytes: UInt32);
var Avail, Temp, H2, H3: UInt32; Cur: PByte;
begin
  if Num = 0 then Exit;
  repeat
    if P.BtBufPos = P.BtBufPosLimit then NextBtBlock(P);
    Avail := P.BtNumAvailBytes; Dec(P.BtNumAvailBytes);
    if (HashBytes <> 0) and (Avail >= HashBytes) then
    begin
      Cur := P.PointerToCurPos; Temp := P.Crc[Cur[0]] xor Cur[1]; H2 := Temp and (Hash2Size-1);
      P.Hash[H2] := P.LzPos;
      if HashBytes = 3 then
      begin H3 := (Temp xor (UInt32(Cur[2]) shl 8)) and $FFFF; P.Hash[Hash2Size+H3] := P.LzPos; end;
    end;
    Inc(P.LzPos); Inc(P.PointerToCurPos); Inc(P.BtBufPos,SizeT(P.BtBufPos^)+1); Dec(Num);
  until Num = 0;
end;
procedure MtSkip0(Obj: Pointer; Num: UInt32); cdecl;
begin MtSkip(Obj,Num,0); end;
procedure MtSkip2(Obj: Pointer; Num: UInt32); cdecl;
begin MtSkip(Obj,Num,2); end;
procedure MtSkip3(Obj: Pointer; Num: UInt32); cdecl;
begin MtSkip(Obj,Num,3); end;
procedure MatchFinderMt_CreateVTable(var P: CMatchFinderMt; out VTable: IMatchFinder2);
begin
  VTable.Init := MatchFinderMt_Init; VTable.GetNumAvailableBytes := MtGetAvailable;
  VTable.GetPointerToCurrentPos := MtGetPointer; VTable.GetMatches := MtGetMatches;
  case P.MatchFinder.NumHashBytes of
    2: begin P.GetHeadsFunc := GetHeads2; P.MixMatchesFunc := nil; VTable.Skip := MtSkip0; VTable.GetMatches := MtGetMatches2; end;
    3: begin
      if P.MatchFinder.BigHash <> 0 then P.GetHeadsFunc := GetHeads3b else P.GetHeadsFunc := GetHeads3;
      P.MixMatchesFunc := MixMatches2; VTable.Skip := MtSkip2;
    end;
    4: begin
      if P.MatchFinder.BigHash <> 0 then P.GetHeadsFunc := GetHeads4b else P.GetHeadsFunc := GetHeads4;
      P.MixMatchesFunc := MixMatches3; VTable.Skip := MtSkip3;
    end;
    else begin
      if P.MatchFinder.BigHash <> 0 then P.GetHeadsFunc := GetHeads5b else P.GetHeadsFunc := GetHeads5;
      P.MixMatchesFunc := MixMatches4; VTable.Skip := MtSkip3;
    end;
  end;
end;

end.
