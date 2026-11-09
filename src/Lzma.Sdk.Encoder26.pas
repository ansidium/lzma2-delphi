unit Lzma.Sdk.Encoder26;

// Native SDK 26.05 encoder (Igor Pavlov, public domain).
// Native scalar/MT encoder; public routing and finite SDK checks are recorded in the release registry.
// Z7_ST retains an explicit scalar-only build of the same source.
{$ALIGN 8}
{$POINTERMATH ON}
{$B-}

interface

uses Lzma.Types, Lzma.Sdk.Contracts, Lzma.Sdk.Properties;

type
  CLzmaEncProps = TLzmaSdkLzmaEncProps26;
  CLzmaEncHandle = Pointer;

{$IFDEF LZMA_SDK_ENCODER_MT_QA}
  TLzmaEncMtProbe = record
    Mode, HashCreated, BtCreated, HashConsumed, BtConsumed: UInt32;
    HashThread, BtThread: NativeUInt;
  end;
function LzmaEnc_QueryMt(P: CLzmaEncHandle): TLzmaEncMtProbe;
function LzmaEnc_QaSeedPositions(P: CLzmaEncHandle; Seed: UInt32): SRes;
{$ENDIF}

procedure LzmaEncProps_Init(out Props: CLzmaEncProps);
procedure LzmaEncProps_Normalize(var Props: CLzmaEncProps);
function LzmaEncProps_GetDictSize(const Props: CLzmaEncProps): UInt32;
function LzmaEnc_Create(const Alloc: ILzmaAllocator): CLzmaEncHandle;
procedure LzmaEnc_Destroy(P: CLzmaEncHandle; const Alloc, AllocBig: ILzmaAllocator);
function LzmaEnc_SetProps(P: CLzmaEncHandle; const Props: CLzmaEncProps): SRes;
procedure LzmaEnc_SetDataSize(P: CLzmaEncHandle; ExpectedDataSize: UInt64);
function LzmaEnc_WriteProperties(P: CLzmaEncHandle; Properties: PByte; var Size: SizeT): SRes;
function LzmaEnc_IsWriteEndMark(P: CLzmaEncHandle): UInt32;
function LzmaEnc_MemPrepare(P: CLzmaEncHandle; Src: PByte; SrcLen: SizeT;
  KeepWindowSize: UInt32; const Alloc, AllocBig: ILzmaAllocator): SRes;
function LzmaEnc_PrepareForLzma2(P: CLzmaEncHandle; const Stream: ILzmaSeqInStream;
  KeepWindowSize: UInt32; const Alloc, AllocBig: ILzmaAllocator): SRes;
function LzmaEnc_GetCurBuf(P: CLzmaEncHandle): PByte;
procedure LzmaEnc_SaveState(P: CLzmaEncHandle);
procedure LzmaEnc_RestoreState(P: CLzmaEncHandle);
procedure LzmaEnc_Finish(P: CLzmaEncHandle);
function LzmaEnc_Encode(P: CLzmaEncHandle; const OutStream: ILzmaSeqOutStream;
  const InStream: ILzmaSeqInStream; const Progress: ILzmaCompressProgress;
  const Alloc, AllocBig: ILzmaAllocator): SRes;
function LzmaEnc_MemEncode(P: CLzmaEncHandle; Dest: PByte; var DestLen: SizeT;
  Src: PByte; SrcLen: SizeT; WriteEndMark: Int32; const Progress: ILzmaCompressProgress;
  const Alloc, AllocBig: ILzmaAllocator): SRes;
function LzmaEncode(Dest: PByte; var DestLen: SizeT; Src: PByte; SrcLen: SizeT;
  const Props: CLzmaEncProps; PropsEncoded: PByte; var PropsSize: SizeT;
  WriteEndMark: Int32; const Progress: ILzmaCompressProgress;
  const Alloc, AllocBig: ILzmaAllocator): SRes;
function LzmaEnc_CodeOneMemBlock(P: CLzmaEncHandle; ReInit: Boolean;
  Dest: PByte; var DestLen: SizeT; DesiredPackSize: UInt32; var UnpackSize: UInt32): SRes;

implementation

uses System.SysUtils, Lzma.Sdk.MatchFinder26, Lzma.Sdk.Memory
{$IFNDEF Z7_ST}
  , Winapi.Windows, Lzma.Sdk.Threads26, Lzma.Sdk.MatchFinderMt26
{$ENDIF}
  ;

// C's range/position arithmetic wraps. SizeT allocation/copy counts retain
// their native unsigned width; supplied allocators own every buffer below.
{$Q-}
{$R-}

const
  NativeSingleThreadBuild = {$IFDEF Z7_ST}True{$ELSE}False{$ENDIF};
  NumOpts = 1 shl 11;
  MatchMaxLen = 273;
  NumStates = 12;
  NumPosStates = 16;
  NumLenSymbols = 272;
  NumFullDistances = 128;
  RangeBufferSize = 1 shl 16;
  InfinityPrice = UInt32(1) shl 30;
  MarkLiteral = UInt32($FFFFFFFF);

type
{$IFDEF Z7_LZMA_PROB32}
  TProb = UInt32;
{$ELSE}
  TProb = UInt16;
{$ENDIF}
  PProb = ^TProb;
  TReps = array[0..3] of UInt32;
  TOptimal = record
    Price: UInt32;
    State, Extra: UInt16;
    Len, Dist: UInt32;
    Reps: TReps;
  end;
  POptimal = ^TOptimal;
  TLenProbs = record
    Low, High: array[0..255] of TProb;
  end;
  TLenPrices = record
    TableSize: UInt32;
    Prices: array[0..NumPosStates-1,0..NumLenSymbols-1] of UInt32;
  end;
  TModels = record
    LitProbs: PProb;
    State: UInt32;
    Reps: TReps;
    PosAlign: array[0..15] of TProb;
    IsRep, IsRepG0, IsRepG1, IsRepG2: array[0..NumStates-1] of TProb;
    IsMatch, IsRep0Long: array[0..NumStates-1,0..NumPosStates-1] of TProb;
    PosSlot: array[0..3,0..63] of TProb;
    PosEncoders: array[0..NumFullDistances-1] of TProb;
    Len, RepLen: TLenProbs;
  end;
  TRangeEnc = record
    Range, Cache: UInt32;
    Low, CacheSize: UInt64;
    Buf, BufLim, BufBase: PByte;
    OutStream: Pointer; // borrowed ILzmaSeqOutStream for synchronous Encode
    Processed: UInt64;
    Res: SRes;
    MemoryOutput: Boolean;
    MemoryDest: PByte;
    MemoryRemaining: SizeT;
    MemoryOverflow: Boolean;
  end;
  PEncoder = ^TEncoder;
  TEncoder = record
    FinderObject: Pointer;
    Finder: IMatchFinder2;
    OptCur, OptEnd, LongestMatchLen, NumPairs, NumAvail: UInt32;
    NumFastBytes, AdditionalOffset, LpMask, PbMask: UInt32;
    Rc: TRangeEnc;
    BackRes, Lc, Lp, Pb, Lclp: UInt32;
    FastMode, WriteEndMark, Finished, MultiThread, NeedInit: UInt32;
    NowPos64: UInt64;
    MatchPriceCount: UInt32;
    RepLenCounter: Int32;
    DistTableSize, DictSize: UInt32;
    Res: SRes;
    Mfb: CMatchFinder;
{$IFNDEF Z7_ST}
    MtMode: UInt32;
    Mfmt: CMatchFinderMt;
{$ENDIF}
    ProbPrices: array[0..127] of UInt32;
    Matches: array[0..MatchMaxLen*2+1] of UInt32;
    AlignPrices: array[0..15] of UInt32;
    PosSlotPrices: array[0..3,0..63] of UInt32;
    DistancePrices: array[0..3,0..NumFullDistances-1] of UInt32;
    Models: TModels;
    LenPrices, RepLenPrices: TLenPrices;
    Opt: array[0..NumOpts-1] of TOptimal;
    SavedModels: TModels;
    Props: CLzmaEncProps;
  end;

procedure LzmaEncProps_Init(out Props: CLzmaEncProps);
begin Props := CLzmaEncProps.Init; end;
procedure LzmaEncProps_Normalize(var Props: CLzmaEncProps);
begin Props.Normalize(NativeSingleThreadBuild); end;
function LzmaEncProps_GetDictSize(const Props: CLzmaEncProps): UInt32;
begin Result := Props.GetDictionarySize(NativeSingleThreadBuild); end;

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

procedure InitPriceTable(P: PEncoder);
var I, J, W, BitCount: UInt32;
begin
  for I := 0 to 127 do
  begin
    W := (I shl 4) + 8; BitCount := 0;
    for J := 0 to 3 do
    begin
      W := W * W; BitCount := BitCount shl 1;
      while W >= UInt32(1) shl 16 do begin W := W shr 1; Inc(BitCount); end;
    end;
    P.ProbPrices[I] := (11 shl 4) - 15 - BitCount;
  end;
end;

function LzmaEnc_SetProps(P: CLzmaEncHandle; const Props: CLzmaEncProps): SRes;
const
  // SDK's default x86/AMD64 build uses the FastPos table configuration.
  // Preserve its SetProps rejection before mutating the handle or allocating.
  SdkNumLogBits = 11 + SizeOf(SizeT) div 8 * 3;
  SdkMaxCompressLog = (SdkNumLogBits - 1) * 2 + 7;
var E: TLzmaSdkEffectiveLzmaProps26; V: PEncoder;
begin
  V := P; Result := Props.GetEffective(E, NativeSingleThreadBuild); if Result <> SZ_OK then Exit;
  if UInt64(E.DictSize) > UInt64(1) shl SdkMaxCompressLog then Exit(SZ_ERROR_PARAM);
  V.Props := Props; V.Props.Normalize(NativeSingleThreadBuild);
  V.DictSize := E.DictSize; V.NumFastBytes := E.Fb;
  V.Lc := E.Lc; V.Lp := E.Lp; V.Pb := E.Pb;
  V.FastMode := E.FastMode; V.WriteEndMark := E.WriteEndMark; V.MultiThread := E.MultiThread;
  V.Mfb.BtMode := Byte(E.BtMode); V.Mfb.NumHashBytes := E.NumHashBytes;
  V.Mfb.NumHashOutBits := Byte(E.NumHashOutBits); V.Mfb.CutValue := E.Mc;
{$IFNDEF Z7_ST}
  V.Mfmt.BtSync.Affinity := Props.Affinity; V.Mfmt.HashSync.Affinity := Props.Affinity;
  V.Mfmt.BtSync.AffinityGroup := Props.AffinityGroup; V.Mfmt.HashSync.AffinityGroup := Props.AffinityGroup;
  V.Mfmt.BtSync.AffinityInGroup := Props.AffinityInGroup; V.Mfmt.HashSync.AffinityInGroup := Props.AffinityInGroup;
{$ENDIF}
end;

function LzmaEnc_Create(const Alloc: ILzmaAllocator): CLzmaEncHandle;
var P: PEncoder; Props: CLzmaEncProps;
begin
  P := Allocate(Alloc, SizeOf(TEncoder)); Result := P; if P = nil then Exit;
  // Unmanaged record: no RTL object/header or hidden managed-array ownership.
  FillChar(P^, SizeOf(TEncoder), 0); MatchFinder_Construct(P.Mfb);
{$IFNDEF Z7_ST}
  P.Mfmt.MatchFinder := @P.Mfb; MatchFinderMt_Construct(P.Mfmt);
{$ENDIF}
  LzmaEncProps_Init(Props); LzmaEnc_SetProps(P, Props); InitPriceTable(P);
end;

procedure FreeLits(P: PEncoder; const Alloc: ILzmaAllocator);
begin
  Release(Alloc, P.Models.LitProbs); Release(Alloc, P.SavedModels.LitProbs);
  P.Models.LitProbs := nil; P.SavedModels.LitProbs := nil;
end;

procedure LzmaEnc_Destroy(P: CLzmaEncHandle; const Alloc, AllocBig: ILzmaAllocator);
var V: PEncoder;
begin
  if P = nil then Exit; V := P;
{$IFNDEF Z7_ST}
  MatchFinderMt_Destruct(V.Mfmt, AllocBig);
{$ENDIF}
  MatchFinder_Free(V.Mfb, AllocBig); FreeLits(V, Alloc);
  Release(Alloc, V.Rc.BufBase); Release(Alloc, V);
end;

procedure LzmaEnc_SetDataSize(P: CLzmaEncHandle; ExpectedDataSize: UInt64);
begin PEncoder(P).Mfb.ExpectedDataSize := ExpectedDataSize; end;

function LzmaEnc_WriteProperties(P: CLzmaEncHandle; Properties: PByte; var Size: SizeT): SRes;
begin Result := PEncoder(P).Props.WriteProperties(Properties, Size, NativeSingleThreadBuild); end;
function LzmaEnc_IsWriteEndMark(P: CLzmaEncHandle): UInt32;
begin Result := PEncoder(P).WriteEndMark; end;

function Price(P: PEncoder; Prob, Bit: UInt32): UInt32; inline;
begin Result := P.ProbPrices[(Prob xor ((UInt32(0)-Bit) and 2047)) shr 4]; end;

function TreePrice(P: PEncoder; Probs: PProb; Bits, Symbol: UInt32): UInt32;
var Bit: UInt32;
begin
  Result := 0; Symbol := Symbol or (UInt32(1) shl Bits);
  repeat
    Bit := Symbol and 1; Symbol := Symbol shr 1;
    Inc(Result, Price(P, Probs[Symbol], Bit));
  until Symbol < 2;
end;

function ReversePrice(P: PEncoder; Probs: PProb; Bits, Symbol: UInt32): UInt32;
var M, Bit: UInt32;
begin
  Result := 0; M := 1;
  while Bits <> 0 do
  begin
    Bit := Symbol and 1; Symbol := Symbol shr 1;
    Inc(Result, Price(P, Probs[M], Bit)); M := (M shl 1) or Bit; Dec(Bits);
  end;
end;

function PosSlot(Pos: UInt32): UInt32;
var N, V: UInt32;
begin
  if Pos < 4 then Exit(Pos);
  V := Pos; N := 0;
  repeat V := V shr 1; Inc(N); until V = 1;
  Result := (N shl 1) + ((Pos shr (N-1)) and 1);
end;

procedure UpdateLenPrices(P: PEncoder; var Prices: TLenPrices; const Enc: TLenProbs);
var PosState, Sym, A, B, C: UInt32;
begin
  A := Price(P, Enc.Low[0], 0); B := Price(P, Enc.Low[0], 1);
  C := B + Price(P, Enc.Low[8], 0); Inc(B, Price(P, Enc.Low[8], 1));
  for PosState := 0 to (UInt32(1) shl P.Pb)-1 do
  begin
    for Sym := 0 to 7 do
    begin
      Prices.Prices[PosState,Sym] := A + TreePrice(P,@Enc.Low[PosState shl 4],3,Sym);
      Prices.Prices[PosState,Sym+8] := C + TreePrice(P,@Enc.Low[(PosState shl 4)+8],3,Sym);
    end;
    Sym := 16;
    while Sym < Prices.TableSize do
    begin Prices.Prices[PosState,Sym] := B + TreePrice(P,@Enc.High[0],8,Sym-16); Inc(Sym); end;
  end;
end;

procedure FillDistancePrices(P: PEncoder);
var Lps, Slot, I, FooterBits, Base, Extra: UInt32;
begin
  P.MatchPriceCount := 0;
  for I := 0 to 15 do P.AlignPrices[I] := ReversePrice(P,@P.Models.PosAlign[0],4,I);
  for Lps := 0 to 3 do
  begin
    for Slot := 0 to 63 do
    begin
      Extra := 0; if Slot >= 14 then Extra := ((Slot shr 1)-1-4) shl 4;
      P.PosSlotPrices[Lps,Slot] := TreePrice(P,@P.Models.PosSlot[Lps,0],6,Slot) + Extra;
    end;
    for I := 0 to 3 do P.DistancePrices[Lps,I] := P.PosSlotPrices[Lps,I];
    for I := 4 to 127 do
    begin
      Slot := PosSlot(I); FooterBits := (Slot shr 1)-1;
      Base := (2 or (Slot and 1)) shl FooterBits;
      P.DistancePrices[Lps,I] := P.PosSlotPrices[Lps,Slot] +
        ReversePrice(P,@P.Models.PosEncoders[Base],FooterBits,I-Base);
    end;
  end;
end;

procedure RangeInit(var R: TRangeEnc);
begin
  R.Range := High(UInt32); R.Cache := 0; R.Low := 0; R.CacheSize := 0;
  R.Buf := R.BufBase; R.Processed := 0; R.Res := SZ_OK;
end;

procedure RangeFlushStream(var R: TRangeEnc);
var N, Actual: SizeT; Res: SRes;
begin
  N := NativeUInt(R.Buf)-NativeUInt(R.BufBase);
  if R.Res = SZ_OK then
  begin
    if R.MemoryOutput then
    begin
      Actual := N;
      if R.MemoryRemaining < Actual then begin Actual := R.MemoryRemaining; R.MemoryOverflow := True; end;
      if Actual <> 0 then
      begin
        LzmaSdkMove(R.MemoryDest,R.BufBase,Actual);
        Inc(R.MemoryDest,Actual); Dec(R.MemoryRemaining,Actual);
      end;
      if Actual <> N then R.Res := SZ_ERROR_WRITE;
    end
    else
    begin
      Actual := 0;
      Res := ILzmaSeqOutStream(R.OutStream).Write(R.BufBase^,N,Actual);
      if (Res <> SZ_OK) or (Actual <> N) then R.Res := SZ_ERROR_WRITE;
    end;
  end;
  Inc(R.Processed,N); R.Buf := R.BufBase;
end;

procedure RangePut(var R: TRangeEnc; Value: Byte); inline;
begin
  R.Buf^ := Value; Inc(R.Buf); if R.Buf = R.BufLim then RangeFlushStream(R);
end;

procedure RangeShiftLow(var R: TRangeEnc);
var Low, High: UInt32;
begin
  Low := UInt32(R.Low); High := UInt32(R.Low shr 32); R.Low := UInt32(Low shl 8);
  if (Low < $FF000000) or (High <> 0) then
  begin
    RangePut(R,Byte(R.Cache+High)); R.Cache := Low shr 24;
    if R.CacheSize = 0 then Exit;
    Inc(High,$FF);
    repeat RangePut(R,Byte(High)); Dec(R.CacheSize); until R.CacheSize = 0;
    Exit;
  end;
  Inc(R.CacheSize);
end;

procedure RangeBit(var R: TRangeEnc; Prob: PProb; Bit: UInt32); inline;
var Bound, V: UInt32;
begin
  V := Prob^; Bound := (R.Range shr 11)*V;
  if Bit = 0 then begin R.Range := Bound; Inc(V,(2048-V) shr 5); end
  else begin Inc(R.Low,Bound); Dec(R.Range,Bound); Dec(V,V shr 5); end;
  Prob^ := TProb(V);
  if R.Range < UInt32(1) shl 24 then begin R.Range := R.Range shl 8; RangeShiftLow(R); end;
end;

procedure RangeTree(var R: TRangeEnc; Probs: PProb; Bits, Symbol: UInt32);
var M, Bit: UInt32;
begin
  M := 1;
  repeat
    Dec(Bits); Bit := (Symbol shr Bits) and 1; RangeBit(R,Probs+M,Bit); M := (M shl 1) or Bit;
  until Bits = 0;
end;

procedure RangeReverseTree(var R: TRangeEnc; Probs: PProb; Bits, Symbol: UInt32);
var M, Bit: UInt32;
begin
  M := 1;
  repeat
    Bit := Symbol and 1; Symbol := Symbol shr 1; RangeBit(R,Probs+M,Bit);
    M := (M shl 1) or Bit; Dec(Bits);
  until Bits = 0;
end;

procedure LiteralEncode(var R: TRangeEnc; Probs: PProb; Symbol: UInt32);
begin RangeTree(R,Probs,8,Symbol); end;

procedure MatchedLiteralEncode(var R: TRangeEnc; Probs: PProb; Symbol, MatchByte: UInt32);
var Offs, Bit, Index: UInt32;
begin
  Offs := $100; Symbol := Symbol or $100;
  repeat
    MatchByte := MatchByte shl 1; Index := Offs + (MatchByte and Offs) + (Symbol shr 8);
    Bit := (Symbol shr 7) and 1; Symbol := Symbol shl 1;
    Offs := Offs and not (MatchByte xor Symbol); RangeBit(R,Probs+Index,Bit);
  until Symbol >= $10000;
end;

procedure LenEncode(var Enc: TLenProbs; var R: TRangeEnc; Symbol, PosState: UInt32);
var Probs: PProb;
begin
  Probs := @Enc.Low[0];
  if Symbol >= 8 then
  begin
    RangeBit(R,Probs,1); Inc(Probs,8);
    if Symbol >= 16 then
    begin RangeBit(R,Probs,1); LiteralEncode(R,@Enc.High[0],Symbol-16); Exit; end;
    Dec(Symbol,8);
  end;
  RangeBit(R,Probs,0); RangeTree(R,Probs+(PosState shl 4),3,Symbol);
end;

procedure InitModels(P: PEncoder);
var I, J: UInt32; K, Count: SizeT;
begin
  P.Models.State := 0; for I := 0 to 3 do P.Models.Reps[I] := 1;
  RangeInit(P.Rc);
  for I := 0 to 15 do P.Models.PosAlign[I] := 1024;
  for I := 0 to 11 do
  begin
    P.Models.IsRep[I] := 1024; P.Models.IsRepG0[I] := 1024;
    P.Models.IsRepG1[I] := 1024; P.Models.IsRepG2[I] := 1024;
    for J := 0 to 15 do begin P.Models.IsMatch[I,J] := 1024; P.Models.IsRep0Long[I,J] := 1024; end;
  end;
  for I := 0 to 3 do for J := 0 to 63 do P.Models.PosSlot[I,J] := 1024;
  for I := 0 to 127 do P.Models.PosEncoders[I] := 1024;
  Count := SizeT($300) shl (P.Lc+P.Lp); K := 0;
  while K < Count do begin P.Models.LitProbs[K] := 1024; Inc(K); end;
  for I := 0 to 255 do
  begin
    P.Models.Len.Low[I] := 1024; P.Models.Len.High[I] := 1024;
    P.Models.RepLen.Low[I] := 1024; P.Models.RepLen.High[I] := 1024;
  end;
  P.OptEnd := 0; P.OptCur := 0;
  for I := 0 to NumOpts-1 do P.Opt[I].Price := InfinityPrice;
  P.AdditionalOffset := 0; P.PbMask := (UInt32(1) shl P.Pb)-1;
  P.LpMask := (UInt32($100) shl P.Lp)-(UInt32($100) shr P.Lc);
end;

procedure InitPrices(P: PEncoder);
begin
  if P.FastMode = 0 then FillDistancePrices(P);
  P.LenPrices.TableSize := P.NumFastBytes-1; P.RepLenPrices.TableSize := P.NumFastBytes-1;
  P.RepLenCounter := 64;
  UpdateLenPrices(P,P.LenPrices,P.Models.Len); UpdateLenPrices(P,P.RepLenPrices,P.Models.RepLen);
end;

function AllocateState(P: PEncoder; KeepWindowSize: UInt32;
  const Alloc, AllocBig: ILzmaAllocator): SRes;
var Lclp, DictSize, BeforeSize: UInt32; Bytes: SizeT;
begin
  if P.Rc.BufBase = nil then
  begin
    P.Rc.BufBase := Allocate(Alloc,RangeBufferSize); if P.Rc.BufBase = nil then Exit(SZ_ERROR_MEM);
    P.Rc.BufLim := P.Rc.BufBase+RangeBufferSize;
  end;
{$IFNDEF Z7_ST}
  P.MtMode := Ord((P.MultiThread <> 0) and (P.FastMode = 0) and (P.Mfb.BtMode <> 0));
{$ENDIF}
  Lclp := P.Lc+P.Lp;
  if (P.Models.LitProbs = nil) or (P.SavedModels.LitProbs = nil) or (P.Lclp <> Lclp) then
  begin
    FreeLits(P,Alloc); Bytes := (SizeT($300)*SizeOf(TProb)) shl Lclp;
    P.Models.LitProbs := Allocate(Alloc,Bytes); P.SavedModels.LitProbs := Allocate(Alloc,Bytes);
    if (P.Models.LitProbs = nil) or (P.SavedModels.LitProbs = nil) then
    begin FreeLits(P,Alloc); Exit(SZ_ERROR_MEM); end;
    P.Lclp := Lclp;
  end;
  P.Mfb.BigHash := Ord(P.DictSize > UInt32(1) shl 24); DictSize := P.DictSize;
  if (DictSize = UInt32(2) shl 30) or (DictSize = UInt32(3) shl 30) then Dec(DictSize);
  BeforeSize := NumOpts; if BeforeSize+DictSize < KeepWindowSize then BeforeSize := KeepWindowSize-DictSize;
{$IFNDEF Z7_ST}
  if P.MtMode <> 0 then
  begin
    Result := MatchFinderMt_Create(P.Mfmt,DictSize,BeforeSize,P.NumFastBytes,MatchMaxLen+1,AllocBig);
    if Result <> SZ_OK then Exit;
    P.FinderObject := @P.Mfmt; P.Mfb.BigHash := Ord(P.Mfb.HashMask >= $FFFFFF);
    MatchFinderMt_CreateVTable(P.Mfmt,P.Finder); Exit(SZ_OK);
  end;
{$ENDIF}
  if MatchFinder_Create(P.Mfb,DictSize,BeforeSize,P.NumFastBytes,MatchMaxLen+1,AllocBig) = 0 then Exit(SZ_ERROR_MEM);
  P.FinderObject := @P.Mfb; MatchFinder_CreateVTable(P.Mfb,P.Finder); Result := SZ_OK;
end;

function AllocateAndInit(P: PEncoder; KeepWindowSize: UInt32;
  const Alloc, AllocBig: ILzmaAllocator): SRes;
var I: UInt32;
begin
  I := 7;
  while (I < 32) and (P.DictSize > UInt32(1) shl I) do Inc(I);
  P.DistTableSize := I*2; P.Finished := 0; P.Res := SZ_OK; P.NowPos64 := 0; P.NeedInit := 1;
  Result := AllocateState(P,KeepWindowSize,Alloc,AllocBig); if Result <> SZ_OK then Exit;
  InitModels(P); InitPrices(P);
end;

function LzmaEnc_MemPrepare(P: CLzmaEncHandle; Src: PByte; SrcLen: SizeT;
  KeepWindowSize: UInt32; const Alloc, AllocBig: ILzmaAllocator): SRes;
var V: PEncoder;
begin
  V := P; MatchFinder_SET_DIRECT_INPUT_BUF(V.Mfb,Src,SrcLen);
  LzmaEnc_SetDataSize(P,SrcLen); Result := AllocateAndInit(V,KeepWindowSize,Alloc,AllocBig);
end;

function LzmaEnc_PrepareForLzma2(P: CLzmaEncHandle; const Stream: ILzmaSeqInStream;
  KeepWindowSize: UInt32; const Alloc, AllocBig: ILzmaAllocator): SRes;
var V: PEncoder;
begin
  V := P; MatchFinder_SET_STREAM(V.Mfb,Stream);
  Result := AllocateAndInit(V,KeepWindowSize,Alloc,AllocBig);
end;

function LzmaEnc_GetCurBuf(P: CLzmaEncHandle): PByte;
var V: PEncoder;
begin
  V := P; Result := V.Finder.GetPointerToCurrentPos(V.FinderObject)-V.AdditionalOffset;
end;

procedure LzmaEnc_SaveState(P: CLzmaEncHandle);
var V: PEncoder; Saved: PProb;
begin
  V := P; Saved := V.SavedModels.LitProbs; V.SavedModels := V.Models;
  V.SavedModels.LitProbs := Saved;
  LzmaSdkMove(Saved,V.Models.LitProbs,(SizeT($300)*SizeOf(TProb)) shl V.Lclp);
end;

procedure LzmaEnc_RestoreState(P: CLzmaEncHandle);
var V: PEncoder; Saved: PProb;
begin
  V := P; Saved := V.Models.LitProbs; V.Models := V.SavedModels;
  V.Models.LitProbs := Saved;
  LzmaSdkMove(Saved,V.SavedModels.LitProbs,(SizeT($300)*SizeOf(TProb)) shl V.Lclp);
end;

procedure LzmaEnc_Finish(P: CLzmaEncHandle);
begin
{$IFNDEF Z7_ST}
  if PEncoder(P).MtMode <> 0 then MatchFinderMt_ReleaseStream(PEncoder(P).Mfmt);
{$ENDIF}
end;

{$IFDEF LZMA_SDK_ENCODER_MT_QA}
function LzmaEnc_QaSeedPositions(P: CLzmaEncHandle; Seed: UInt32): SRes;
{$IFNDEF Z7_ST}
var V: PEncoder;
{$ENDIF}
begin
  Result := SZ_OK;
{$IFNDEF Z7_ST}
  V := P;
  if V.MtMode <> 0 then
  begin
    if V.NeedInit = 0 then Exit(SZ_ERROR_PARAM);
    Result := MatchFinderMt_InitMt(V.Mfmt); if Result <> SZ_OK then Exit;
    V.Finder.Init(V.FinderObject); V.NeedInit := 0;
    // Empty initialized history, before either worker starts. Position seeding
    // exercises the actual three normalization paths without multi-GiB input.
    V.Mfb.Pos := Seed; V.Mfb.StreamPos := Seed; V.Mfmt.Pos := Seed; V.Mfmt.LzPos := Seed;
  end;
{$ENDIF}
end;

function LzmaEnc_QueryMt(P: CLzmaEncHandle): TLzmaEncMtProbe;
{$IFNDEF Z7_ST}
var V: PEncoder;
{$ENDIF}
begin
  FillChar(Result,SizeOf(Result),0);
{$IFNDEF Z7_ST}
  V := P;
  { mtMode is assigned only after the range buffer allocation succeeds. }
  if V.Rc.BufBase <> nil then Result.Mode := V.MtMode;
  Result.HashCreated := UInt32(V.Mfmt.HashSync.WasCreated);
  Result.BtCreated := UInt32(V.Mfmt.BtSync.WasCreated);
  if Result.HashCreated <> 0 then
  begin Result.HashThread := V.Mfmt.HashSync.Thread; Result.HashConsumed := V.Mfmt.HashSync.NumProcessedBlocks; end;
  if Result.BtCreated <> 0 then
  begin Result.BtThread := V.Mfmt.BtSync.Thread; Result.BtConsumed := V.Mfmt.BtSync.NumProcessedBlocks; end;
{$ENDIF}
end;
{$ENDIF}

{$I Lzma.Sdk.Encoder26.Parse.inc}
{$I Lzma.Sdk.Encoder26.Code.inc}

end.
