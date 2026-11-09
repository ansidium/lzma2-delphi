unit Lzma.Sdk.Decoder26;

// Native Delphi port of the LZMA SDK 26.05 dictionary/buffer decoder contract.
// LzmaDec.c / LzmaDec.h: Igor Pavlov, public domain.
// Shared native state machine for the procedural API and SDK decoder facades.

{$POINTERMATH ON}
{$B-}
{$ALIGN 8}

interface

uses Lzma.Types,Lzma.Sdk.Contracts;

const
  LZMA26_PROPS_SIZE=5;
  LZMA26_REQUIRED_INPUT_MAX=20;

type
{$IFDEF Z7_LZMA_PROB32}
  TLzmaProb26=UInt32;
{$ELSE}
  TLzmaProb26=UInt16;
{$ENDIF}
  PLzmaProb26=^TLzmaProb26;
  TLzmaProps26=record
    Lc,Lp,Pb,Pad:Byte;
    DicSize:UInt32;
  end;
  TLzmaDec26=record
    Prop:TLzmaProps26;
    Probs,Probs1664:PLzmaProb26;
    Dic:PByte;
    DicBufSize,DicPos:SizeT;
    Buf:PByte;
    Range,Code,ProcessedPos,CheckDicSize:UInt32;
    Reps:array[0..3] of UInt32;
    State,RemainLen,NumProbs,TempBufSize:UInt32;
    TempBuf:array[0..LZMA26_REQUIRED_INPUT_MAX-1] of Byte;
  end;

function LzmaProps_Decode(var P:TLzmaProps26;Data:PByte;Size:UInt32):SRes;
procedure LzmaDec_Construct(var P:TLzmaDec26);
procedure LzmaDec_InitDicAndState(var P:TLzmaDec26;const InitDic,InitState:Boolean);
procedure LzmaDec_Init(var P:TLzmaDec26);
function LzmaDec_AllocateProbs(var P:TLzmaDec26;Props:PByte;PropsSize:UInt32;
  const Alloc:ILzmaAllocator=nil):SRes;
function LzmaDec_Allocate(var P:TLzmaDec26;Props:PByte;PropsSize:UInt32;
  const Alloc:ILzmaAllocator=nil):SRes;
procedure LzmaDec_FreeProbs(var P:TLzmaDec26;const Alloc:ILzmaAllocator=nil);
procedure LzmaDec_Free(var P:TLzmaDec26;const Alloc:ILzmaAllocator=nil);
function LzmaDec_DecodeToDic(var P:TLzmaDec26;DicLimit:SizeT;Src:PByte;var SrcLen:SizeT;
  FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
function LzmaDec_DecodeToBuf(var P:TLzmaDec26;Dest:PByte;var DestLen:SizeT;
  Src:PByte;var SrcLen:SizeT;FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
function LzmaDecode(Dest:PByte;var DestLen:SizeT;Src:PByte;var SrcLen:SizeT;
  PropData:PByte;PropSize:UInt32;FinishMode:TLzmaFinishMode;out Status:TLzmaStatus;
  const Alloc:ILzmaAllocator=nil):SRes;

implementation

uses System.SysUtils,System.Math,Lzma.Sdk.Memory;

const
  TopValue=UInt32(1) shl 24;
  ProbTotal=2048;
  NumStates=12;
  NumLitStates=7;
  MatchMinLen=2;
  MatchSpecLen=274;
  ErrorFail=511;
  ErrorData=512;
  BadRepCode=UInt32($BFFFFC00);
  SpecPos=0;
  IsRep0Long=128;
  RepLenCoder=384;
  LenCoder=896;
  IsMatch=1408;
  AlignProbs=1664;
  IsRep=1680;
  IsRepG0=1692;
  IsRepG1=1704;
  IsRepG2=1716;
  PosSlot=1728;
  LiteralProbs=1984;
  BaseProbs=1984;
  LiteralSize=$300;

type
  TDummy26=(dmInputEof,dmLiteral,dmMatch,dmRep);
  TRange26=record
    Input,InputEnd:PByte;
    Range,Code:UInt32;
    TestOnly,NeedsInput:Boolean;
    function Normalize:Boolean;
    function Bit(Prob:PLzmaProb26):UInt32;
    function Tree(Probs:PLzmaProb26;NumBits:UInt32):UInt32;
    function Reverse(Probs:PLzmaProb26;NumBits:UInt32;Start:UInt32=1):UInt32;
    function Direct:UInt32;
  end;

function Add32(const A,B:UInt32):UInt32;inline;
begin Result:=UInt32(UInt64(A)+B);end;

function ProbCount(const P:TLzmaProps26):UInt32;inline;
begin Result:=BaseProbs+(UInt32(LiteralSize) shl (P.Lc+P.Lp));end;

function EffectiveAllocator(const Alloc:ILzmaAllocator):ILzmaAllocator;
begin
  if Alloc=nil then Result:=LzmaDefaultAllocator else Result:=Alloc;
end;

function AllocateMemory(const Alloc:ILzmaAllocator;const Size:SizeT):Pointer;
begin
  try Result:=Alloc.Alloc(Size);
  except on E:EOutOfMemory do Result:=nil;end;
end;

function LzmaProps_Decode(var P:TLzmaProps26;Data:PByte;Size:UInt32):SRes;
var D:Byte;Dictionary:UInt32;
begin
  if Size<LZMA26_PROPS_SIZE then Exit(SZ_ERROR_UNSUPPORTED);
  if Data=nil then Exit(SZ_ERROR_PARAM);
  Dictionary:=UInt32(Data[1]) or (UInt32(Data[2]) shl 8) or
    (UInt32(Data[3]) shl 16) or (UInt32(Data[4]) shl 24);
  if Dictionary<4096 then Dictionary:=4096;
  P.DicSize:=Dictionary;
  D:=Data[0];if D>=225 then Exit(SZ_ERROR_UNSUPPORTED);
  P.Lc:=D mod 9;D:=D div 9;P.Pb:=D div 5;P.Lp:=D mod 5;
  Result:=SZ_OK;
end;

procedure LzmaDec_Construct(var P:TLzmaDec26);
begin P.Dic:=nil;P.Probs:=nil;end;

procedure LzmaDec_InitDicAndState(var P:TLzmaDec26;const InitDic,InitState:Boolean);
begin
  P.RemainLen:=MatchSpecLen+1;P.TempBufSize:=0;
  if InitDic then
  begin P.ProcessedPos:=0;P.CheckDicSize:=0;P.RemainLen:=MatchSpecLen+2;end;
  if InitState then P.RemainLen:=MatchSpecLen+2;
end;

procedure LzmaDec_Init(var P:TLzmaDec26);
begin P.DicPos:=0;LzmaDec_InitDicAndState(P,True,True);end;

procedure LzmaDec_FreeProbs(var P:TLzmaDec26;const Alloc:ILzmaAllocator);
var A:ILzmaAllocator;
begin A:=EffectiveAllocator(Alloc);A.FreeMem(P.Probs);P.Probs:=nil;end;

procedure FreeDictionary(var P:TLzmaDec26;const A:ILzmaAllocator);
begin A.FreeMem(P.Dic);P.Dic:=nil;end;

procedure LzmaDec_Free(var P:TLzmaDec26;const Alloc:ILzmaAllocator);
var A:ILzmaAllocator;
begin A:=EffectiveAllocator(Alloc);LzmaDec_FreeProbs(P,A);FreeDictionary(P,A);end;

function AllocateProbs2(var P:TLzmaDec26;const PropNew:TLzmaProps26;const A:ILzmaAllocator):SRes;
var Count:UInt32;
begin
  Count:=ProbCount(PropNew);
  if (P.Probs=nil) or (Count<>P.NumProbs) then
  begin
    LzmaDec_FreeProbs(P,A);
    P.Probs:=AllocateMemory(A,SizeT(Count)*SizeOf(TLzmaProb26));
    if P.Probs=nil then Exit(SZ_ERROR_MEM);
    P.Probs1664:=P.Probs+1664;P.NumProbs:=Count;
  end;
  Result:=SZ_OK;
end;

function LzmaDec_AllocateProbs(var P:TLzmaDec26;Props:PByte;PropsSize:UInt32;
  const Alloc:ILzmaAllocator):SRes;
var PropNew:TLzmaProps26;A:ILzmaAllocator;
begin
  Result:=LzmaProps_Decode(PropNew,Props,PropsSize);if Result<>SZ_OK then Exit;
  A:=EffectiveAllocator(Alloc);
  Result:=AllocateProbs2(P,PropNew,A);if Result<>SZ_OK then Exit;
  P.Prop:=PropNew;
end;

function LzmaDec_Allocate(var P:TLzmaDec26;Props:PByte;PropsSize:UInt32;
  const Alloc:ILzmaAllocator):SRes;
var PropNew:TLzmaProps26;A:ILzmaAllocator;Mask,DictionarySize:SizeT;Sum:UInt64;
begin
  Result:=LzmaProps_Decode(PropNew,Props,PropsSize);if Result<>SZ_OK then Exit;
  A:=EffectiveAllocator(Alloc);
  Result:=AllocateProbs2(P,PropNew,A);if Result<>SZ_OK then Exit;
  Mask:=4095;
  if PropNew.DicSize>=(UInt32(1) shl 30) then Mask:=(UInt32(1) shl 22)-1
  else if PropNew.DicSize>=(UInt32(1) shl 22) then Mask:=(UInt32(1) shl 20)-1;
  Sum:=UInt64(PropNew.DicSize)+Mask;
  if SizeOf(SizeT)=4 then DictionarySize:=SizeT(UInt32(Sum)) and not Mask
  else DictionarySize:=SizeT(Sum) and not Mask;
  if DictionarySize<PropNew.DicSize then DictionarySize:=PropNew.DicSize;
  if (P.Dic=nil) or (DictionarySize<>P.DicBufSize) then
  begin
    FreeDictionary(P,A);P.Dic:=AllocateMemory(A,DictionarySize);
    if P.Dic=nil then begin LzmaDec_FreeProbs(P,A);Exit(SZ_ERROR_MEM);end;
  end;
  P.DicBufSize:=DictionarySize;P.Prop:=PropNew;Result:=SZ_OK;
end;

function TRange26.Normalize:Boolean;
begin
  if NeedsInput then Exit(False);
  if Range<TopValue then
  begin
    if NativeUInt(Input)>=NativeUInt(InputEnd) then
    begin NeedsInput:=True;Exit(False);end;
    Range:=Range shl 8;Code:=(Code shl 8) or Input^;Inc(Input);
  end;
  Result:=True;
end;

function TRange26.Bit(Prob:PLzmaProb26):UInt32;
var Value,Bound:UInt32;
begin
  if not Normalize then Exit(0);
  Value:=Prob^;Bound:=(Range shr 11)*Value;
  if Code<Bound then
  begin
    Range:=Bound;Result:=0;
    if not TestOnly then Prob^:=TLzmaProb26(Value+((ProbTotal-Value) shr 5));
  end
  else
  begin
    Dec(Range,Bound);Dec(Code,Bound);Result:=1;
    if not TestOnly then Prob^:=TLzmaProb26(Value-(Value shr 5));
  end;
end;

function TRange26.Tree(Probs:PLzmaProb26;NumBits:UInt32):UInt32;
var I:UInt32;
begin
  I:=1;
  while NumBits<>0 do begin I:=(I shl 1) or Bit(Probs+I);Dec(NumBits);end;
  Result:=I;
end;

function TRange26.Reverse(Probs:PLzmaProb26;NumBits:UInt32;Start:UInt32):UInt32;
var I,M:UInt32;
begin
  I:=Start;M:=1;
  while NumBits<>0 do
  begin
    if Bit(Probs+I)=0 then begin Inc(I,M);M:=M shl 1;end
    else begin M:=M shl 1;Inc(I,M);end;
    Dec(NumBits);
  end;
  Result:=I-M;
end;

function TRange26.Direct:UInt32;
begin
  if not Normalize then Exit(0);
  Range:=Range shr 1;
  if Code>=Range then begin Dec(Code,Range);Result:=1;end else Result:=0;
end;

function DecodeLength(var C:TRange26;Probs:PLzmaProb26;PosState:UInt32):UInt32;
begin
  if C.Bit(Probs)=0 then Result:=C.Tree(Probs+PosState,3)-8
  else if C.Bit(Probs+8)=0 then Result:=C.Tree(Probs+PosState+8,3)
  else Result:=C.Tree(Probs+256,8)-256+16;
end;

function HistoryByte(const P:TLzmaDec26;const Distance:UInt32):Byte;inline;
var Position:SizeT;
begin
  if P.DicPos<Distance then Position:=P.DicPos+P.DicBufSize-Distance
  else Position:=P.DicPos-Distance;
  Result:=P.Dic[Position];
end;

procedure WriteRem(var P:TLzmaDec26;Limit:SizeT);
var Count:UInt32;I:UInt32;
begin
  Count:=P.RemainLen;if Count=0 then Exit;
  if Limit-P.DicPos<Count then Count:=UInt32(Limit-P.DicPos);
  if Count=0 then Exit;
  if (P.CheckDicSize=0) and (P.Prop.DicSize-P.ProcessedPos<=Count) then
    P.CheckDicSize:=P.Prop.DicSize;
  P.ProcessedPos:=Add32(P.ProcessedPos,Count);Dec(P.RemainLen,Count);
  for I:=1 to Count do begin P.Dic[P.DicPos]:=HistoryByte(P,P.Reps[0]);Inc(P.DicPos);end;
end;

function DecodeSymbol(var P:TLzmaDec26;var C:TRange26;Limit:SizeT;out Kind:TDummy26):SRes;
var PosState,Context,Symbol,MatchByte,Offs,BitMask,B,LengthValue,Slot,DirectBits,
    Distance,OldState,Count,I:UInt32;Probs:PLzmaProb26;Prev:Byte;
begin
  Result:=SZ_OK;PosState:=(P.ProcessedPos and ((UInt32(1) shl P.Prop.Pb)-1)) shl 4;
  OldState:=P.State;
  if C.Bit(P.Probs+IsMatch+PosState+P.State)=0 then
  begin
    Kind:=dmLiteral;Prev:=0;
    if (P.ProcessedPos<>0) or (P.CheckDicSize<>0) then
      if P.DicPos=0 then Prev:=P.Dic[P.DicBufSize-1] else Prev:=P.Dic[P.DicPos-1];
    Context:=((P.ProcessedPos and ((UInt32(1) shl P.Prop.Lp)-1)) shl P.Prop.Lc)+
      (UInt32(Prev) shr (8-P.Prop.Lc));
    Probs:=P.Probs+LiteralProbs+LiteralSize*Context;Symbol:=1;
    if P.State<NumLitStates then
    begin
      while Symbol<256 do Symbol:=(Symbol shl 1) or C.Bit(Probs+Symbol);
      if P.State<4 then P.State:=0 else Dec(P.State,3);
    end
    else
    begin
      MatchByte:=HistoryByte(P,P.Reps[0]);Offs:=256;
      while Symbol<256 do
      begin
        MatchByte:=MatchByte shl 1;BitMask:=Offs;Offs:=Offs and MatchByte;
        B:=C.Bit(Probs+Offs+BitMask+Symbol);Symbol:=(Symbol shl 1) or B;
        if B=0 then Offs:=Offs xor BitMask;
      end;
      if P.State<10 then Dec(P.State,3) else Dec(P.State,6);
    end;
    if not C.TestOnly then
    begin
      if P.DicPos>=Limit then Exit(SZ_ERROR_FAIL);
      P.Dic[P.DicPos]:=Byte(Symbol);
    end;
    Inc(P.DicPos);P.ProcessedPos:=Add32(P.ProcessedPos,1);P.RemainLen:=0;
    Exit;
  end;
  if C.Bit(P.Probs+IsRep+P.State)=0 then
  begin
    Kind:=dmMatch;LengthValue:=DecodeLength(C,P.Probs+LenCoder,PosState);
    Slot:=C.Tree(P.Probs+PosSlot+(Min(LengthValue,UInt32(3)) shl 6),6)-64;
    Distance:=Slot;
    if Slot>=4 then
    begin
      DirectBits:=(Slot shr 1)-1;Distance:=2 or (Slot and 1);
      if Slot<14 then
      begin
        Distance:=Distance shl DirectBits;
        Distance:=C.Reverse(P.Probs+SpecPos,DirectBits,Distance+1);
      end
      else
      begin
        Dec(DirectBits,4);
        for I:=1 to DirectBits do Distance:=(Distance shl 1) or C.Direct;
        Distance:=(Distance shl 4) or C.Reverse(P.Probs+AlignProbs,4);
        if Distance=High(UInt32) then
        begin P.RemainLen:=MatchSpecLen;P.State:=OldState;Exit;end;
      end;
    end;
    P.Reps[3]:=P.Reps[2];P.Reps[2]:=P.Reps[1];P.Reps[1]:=P.Reps[0];
    P.Reps[0]:=Add32(Distance,1);
    if OldState<NumLitStates then P.State:=7 else P.State:=10;
    if not C.TestOnly then
    begin
      if P.CheckDicSize=0 then Count:=P.ProcessedPos else Count:=P.CheckDicSize;
      if Distance>=Count then
      begin P.RemainLen:=LengthValue+ErrorData+MatchMinLen;Exit(SZ_ERROR_DATA);end;
    end;
  end
  else
  begin
    Kind:=dmRep;
    if C.Bit(P.Probs+IsRepG0+P.State)=0 then
    begin
      if C.Bit(P.Probs+IsRep0Long+PosState+P.State)=0 then
      begin
        if not C.TestOnly then
        begin
          if P.DicPos>=Limit then Exit(SZ_ERROR_FAIL);
          P.Dic[P.DicPos]:=HistoryByte(P,P.Reps[0]);
        end;
        Inc(P.DicPos);P.ProcessedPos:=Add32(P.ProcessedPos,1);
        if P.State<NumLitStates then P.State:=9 else P.State:=11;
        P.RemainLen:=0;Exit;
      end;
    end
    else
    begin
      if C.Bit(P.Probs+IsRepG1+P.State)=0 then Distance:=P.Reps[1]
      else
      begin
        if C.Bit(P.Probs+IsRepG2+P.State)=0 then Distance:=P.Reps[2]
        else begin Distance:=P.Reps[3];P.Reps[3]:=P.Reps[2];end;
        P.Reps[2]:=P.Reps[1];
      end;
      P.Reps[1]:=P.Reps[0];P.Reps[0]:=Distance;
    end;
    if P.State<NumLitStates then P.State:=8 else P.State:=11;
    LengthValue:=DecodeLength(C,P.Probs+RepLenCoder,PosState);
  end;
  P.RemainLen:=LengthValue+MatchMinLen;
  if not C.TestOnly then
  begin
    Count:=P.RemainLen;if Limit-P.DicPos<Count then Count:=UInt32(Limit-P.DicPos);
    for I:=1 to Count do begin P.Dic[P.DicPos]:=HistoryByte(P,P.Reps[0]);Inc(P.DicPos);end;
    P.ProcessedPos:=Add32(P.ProcessedPos,Count);Dec(P.RemainLen,Count);
  end;
end;

function TryDummy(const P:TLzmaDec26;Src,SrcEnd:PByte;out Consumed:SizeT):TDummy26;
var Shadow:TLzmaDec26;C:TRange26;Kind:TDummy26;
begin
  Shadow:=P;C.Input:=Src;C.InputEnd:=SrcEnd;C.Range:=P.Range;C.Code:=P.Code;
  C.TestOnly:=True;C.NeedsInput:=False;
  DecodeSymbol(Shadow,C,P.DicPos,Kind);
  if not C.Normalize then Exit(dmInputEof);
  Consumed:=NativeUInt(C.Input)-NativeUInt(Src);Result:=Kind;
end;

function DecodeReal2(var P:TLzmaDec26;Limit:SizeT;BufLimit,BufEnd:PByte):SRes;
var C:TRange26;Kind:TDummy26;Remain:UInt32;
begin
  if P.CheckDicSize=0 then
  begin
    Remain:=P.Prop.DicSize-P.ProcessedPos;
    if Limit-P.DicPos>Remain then Limit:=P.DicPos+Remain;
  end;
  C.Input:=P.Buf;C.InputEnd:=BufEnd;C.Range:=P.Range;C.Code:=P.Code;
  C.TestOnly:=False;C.NeedsInput:=False;
  repeat
    Result:=DecodeSymbol(P,C,Limit,Kind);
    if (Result<>SZ_OK) or (P.RemainLen=MatchSpecLen) then Break;
  until (P.DicPos>=Limit) or (NativeUInt(C.Input)>=NativeUInt(BufLimit));
  if not C.Normalize then Result:=SZ_ERROR_FAIL;
  P.Buf:=C.Input;P.Range:=C.Range;P.Code:=C.Code;
  if (P.CheckDicSize=0) and (P.ProcessedPos>=P.Prop.DicSize) then
    P.CheckDicSize:=P.Prop.DicSize;
end;

function LzmaDec_DecodeToDic(var P:TLzmaDec26;DicLimit:SizeT;Src:PByte;var SrcLen:SizeT;
  FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
var InSize,Processed,DummyProcessed:SizeT;I,Rem,Ahead:UInt32;
    CheckEnd,UsedDummy:Boolean;Dummy:TDummy26;BufLimit,Start:PByte;Res:SRes;
begin
  InSize:=SrcLen;SrcLen:=0;Status:=lsNotSpecified;
  if (DicLimit>P.DicBufSize) or (P.DicPos>DicLimit) or
    ((InSize<>0) and (Src=nil)) or (P.Probs=nil) then Exit(SZ_ERROR_PARAM);
  if P.RemainLen>MatchSpecLen then
  begin
    if P.RemainLen>MatchSpecLen+2 then
      if P.RemainLen=ErrorFail then Exit(SZ_ERROR_FAIL) else Exit(SZ_ERROR_DATA);
    while (InSize>0) and (P.TempBufSize<5) do
    begin P.TempBuf[P.TempBufSize]:=Src^;Inc(P.TempBufSize);Inc(Src);Inc(SrcLen);Dec(InSize);end;
    if (P.TempBufSize<>0) and (P.TempBuf[0]<>0) then Exit(SZ_ERROR_DATA);
    if P.TempBufSize<5 then begin Status:=lsNeedsMoreInput;Exit(SZ_OK);end;
    P.Code:=(UInt32(P.TempBuf[1]) shl 24) or (UInt32(P.TempBuf[2]) shl 16) or
      (UInt32(P.TempBuf[3]) shl 8) or P.TempBuf[4];
    if (P.CheckDicSize=0) and (P.ProcessedPos=0) and (P.Code>=BadRepCode) then
      Exit(SZ_ERROR_DATA);
    P.Range:=High(UInt32);P.TempBufSize:=0;
    if P.RemainLen>MatchSpecLen+1 then
    begin
      for I:=0 to ProbCount(P.Prop)-1 do P.Probs[I]:=ProbTotal div 2;
      P.Reps[0]:=1;P.Reps[1]:=1;P.Reps[2]:=1;P.Reps[3]:=1;P.State:=0;
    end;
    P.RemainLen:=0;
  end;
  while True do
  begin
    if P.RemainLen=MatchSpecLen then
    begin
      if P.Code<>0 then Exit(SZ_ERROR_DATA);
      Status:=lsFinishedWithMark;Exit(SZ_OK);
    end;
    WriteRem(P,DicLimit);CheckEnd:=False;
    if P.DicPos>=DicLimit then
    begin
      if (P.RemainLen=0) and (P.Code=0) then
      begin Status:=lsMaybeFinishedWithoutMark;Exit(SZ_OK);end;
      if FinishMode=lfmAny then begin Status:=lsNotFinished;Exit(SZ_OK);end;
      if P.RemainLen<>0 then begin Status:=lsNotFinished;Exit(SZ_ERROR_DATA);end;
      CheckEnd:=True;
    end;
    if P.TempBufSize=0 then
    begin
      UsedDummy:=(InSize<LZMA26_REQUIRED_INPUT_MAX) or CheckEnd;
      if UsedDummy then
      begin
        Dummy:=TryDummy(P,Src,Src+InSize,DummyProcessed);
        if Dummy=dmInputEof then
        begin
          if InSize>=LZMA26_REQUIRED_INPUT_MAX then Break;
          P.TempBufSize:=UInt32(InSize);
          if InSize<>0 then Move(Src^,P.TempBuf[0],InSize);
          Inc(SrcLen,InSize);Status:=lsNeedsMoreInput;Exit(SZ_OK);
        end;
        if DummyProcessed>LZMA26_REQUIRED_INPUT_MAX then Break;
        if CheckEnd and (Dummy<>dmMatch) then
        begin
          Inc(SrcLen,DummyProcessed);P.TempBufSize:=UInt32(DummyProcessed);
          if DummyProcessed<>0 then Move(Src^,P.TempBuf[0],DummyProcessed);
          Status:=lsNotFinished;Exit(SZ_ERROR_DATA);
        end;
        BufLimit:=Src;
      end
      else BufLimit:=Src+InSize-LZMA26_REQUIRED_INPUT_MAX;
      P.Buf:=Src;Res:=DecodeReal2(P,DicLimit,BufLimit,Src+InSize);
      Processed:=NativeUInt(P.Buf)-NativeUInt(Src);
      if UsedDummy then begin if DummyProcessed<>Processed then Break;end
      else if Processed>InSize then Break;
      Inc(Src,Processed);Dec(InSize,Processed);Inc(SrcLen,Processed);
      if Res<>SZ_OK then
      begin
        if Res=SZ_ERROR_FAIL then begin P.RemainLen:=ErrorFail;Exit(SZ_ERROR_FAIL);end;
        P.RemainLen:=ErrorData;Exit(SZ_ERROR_DATA);
      end;
      Continue;
    end;
    Rem:=P.TempBufSize;Ahead:=0;
    while (Rem<LZMA26_REQUIRED_INPUT_MAX) and (Ahead<InSize) do
    begin P.TempBuf[Rem]:=Src[Ahead];Inc(Rem);Inc(Ahead);end;
    UsedDummy:=(Rem<LZMA26_REQUIRED_INPUT_MAX) or CheckEnd;
    if UsedDummy then
    begin
      Start:=@P.TempBuf[0];
      Dummy:=TryDummy(P,Start,Start+Rem,DummyProcessed);
      if Dummy=dmInputEof then
      begin
        if Rem>=LZMA26_REQUIRED_INPUT_MAX then Break;
        P.TempBufSize:=Rem;Inc(SrcLen,Ahead);Status:=lsNeedsMoreInput;Exit(SZ_OK);
      end;
      if DummyProcessed<P.TempBufSize then Break;
      if CheckEnd and (Dummy<>dmMatch) then
      begin
        Inc(SrcLen,DummyProcessed-P.TempBufSize);P.TempBufSize:=UInt32(DummyProcessed);
        Status:=lsNotFinished;Exit(SZ_ERROR_DATA);
      end;
    end;
    Start:=@P.TempBuf[0];P.Buf:=Start;
    Res:=DecodeReal2(P,DicLimit,Start,Start+Rem);
    Processed:=NativeUInt(P.Buf)-NativeUInt(Start);
    if UsedDummy then begin if DummyProcessed<>Processed then Break;end
    else if (Processed>LZMA26_REQUIRED_INPUT_MAX) or (Processed<P.TempBufSize) then Break;
    Dec(Processed,P.TempBufSize);
    if Processed>InSize then Break;
    Inc(Src,Processed);Dec(InSize,Processed);Inc(SrcLen,Processed);P.TempBufSize:=0;
    if Res<>SZ_OK then
    begin
      if Res=SZ_ERROR_FAIL then begin P.RemainLen:=ErrorFail;Exit(SZ_ERROR_FAIL);end;
      P.RemainLen:=ErrorData;Exit(SZ_ERROR_DATA);
    end;
  end;
  P.RemainLen:=ErrorFail;Result:=SZ_ERROR_FAIL;
end;

function LzmaDec_DecodeToBuf(var P:TLzmaDec26;Dest:PByte;var DestLen:SizeT;
  Src:PByte;var SrcLen:SizeT;FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
var OutSize,InSize,InCurrent,OutCurrent,DicPos:SizeT;CurrentFinish:TLzmaFinishMode;
begin
  OutSize:=DestLen;InSize:=SrcLen;SrcLen:=0;DestLen:=0;Status:=lsNotSpecified;
  if ((OutSize<>0) and (Dest=nil)) or (P.DicBufSize=0) then Exit(SZ_ERROR_PARAM);
  while True do
  begin
    InCurrent:=InSize;
    if P.DicPos=P.DicBufSize then P.DicPos:=0;
    DicPos:=P.DicPos;
    if OutSize>P.DicBufSize-DicPos then
    begin OutCurrent:=P.DicBufSize;CurrentFinish:=lfmAny;end
    else begin OutCurrent:=DicPos+OutSize;CurrentFinish:=FinishMode;end;
    Result:=LzmaDec_DecodeToDic(P,OutCurrent,Src,InCurrent,CurrentFinish,Status);
    Inc(Src,InCurrent);Dec(InSize,InCurrent);Inc(SrcLen,InCurrent);
    OutCurrent:=P.DicPos-DicPos;
    if OutCurrent<>0 then LzmaSdkMove(Dest,P.Dic+DicPos,OutCurrent);
    Inc(Dest,OutCurrent);Dec(OutSize,OutCurrent);Inc(DestLen,OutCurrent);
    if Result<>SZ_OK then Exit;
    if (OutCurrent=0) or (OutSize=0) then Exit(SZ_OK);
  end;
end;

function LzmaDecode(Dest:PByte;var DestLen:SizeT;Src:PByte;var SrcLen:SizeT;
  PropData:PByte;PropSize:UInt32;FinishMode:TLzmaFinishMode;out Status:TLzmaStatus;
  const Alloc:ILzmaAllocator):SRes;
var P:TLzmaDec26;OutSize,InSize:SizeT;A:ILzmaAllocator;
begin
  OutSize:=DestLen;InSize:=SrcLen;DestLen:=0;SrcLen:=0;Status:=lsNotSpecified;
  if InSize<5 then Exit(SZ_ERROR_INPUT_EOF);
  LzmaDec_Construct(P);A:=EffectiveAllocator(Alloc);
  Result:=LzmaDec_AllocateProbs(P,PropData,PropSize,A);if Result<>SZ_OK then Exit;
  try
    P.Dic:=Dest;P.DicBufSize:=OutSize;LzmaDec_Init(P);SrcLen:=InSize;
    Result:=LzmaDec_DecodeToDic(P,OutSize,Src,SrcLen,FinishMode,Status);
    DestLen:=P.DicPos;
    if (Result=SZ_OK) and (Status=lsNeedsMoreInput) then Result:=SZ_ERROR_INPUT_EOF;
  finally LzmaDec_FreeProbs(P,A);end;
end;

end.
