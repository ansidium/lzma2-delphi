unit Lzma2.Sdk.Decoder26;

// Native Delphi port of LZMA SDK 26.05 Lzma2Dec.c / Lzma2Dec.h.
// Igor Pavlov, public domain. No input-prefix replay or growing output cache.
{$POINTERMATH ON}
{$B-}
{$ALIGN 8}
interface
uses Lzma.Types,Lzma.Sdk.Contracts,Lzma.Sdk.Decoder26;
type
  TLzma2ParseStatus26=TLzma2ParseStatus;
  TLzma2Dec26=record
    State:UInt32;
    Control,NeedInitLevel,IsExtraMode,Pad:Byte;
    PackSize,UnpackSize:UInt32;
    Decoder:TLzmaDec26;
  end;
procedure Lzma2Dec_Construct(var P:TLzma2Dec26);
procedure Lzma2Dec_FreeProbs(var P:TLzma2Dec26;const Alloc:ILzmaAllocator=nil);
procedure Lzma2Dec_Free(var P:TLzma2Dec26;const Alloc:ILzmaAllocator=nil);
function Lzma2Dec_AllocateProbs(var P:TLzma2Dec26;Prop:Byte;const Alloc:ILzmaAllocator=nil):SRes;
function Lzma2Dec_Allocate(var P:TLzma2Dec26;Prop:Byte;const Alloc:ILzmaAllocator=nil):SRes;
procedure Lzma2Dec_Init(var P:TLzma2Dec26);
function Lzma2Dec_DecodeToDic(var P:TLzma2Dec26;DicLimit:SizeT;Src:PByte;var SrcLen:SizeT;
  FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
function Lzma2Dec_DecodeToBuf(var P:TLzma2Dec26;Dest:PByte;var DestLen:SizeT;Src:PByte;var SrcLen:SizeT;
  FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
function Lzma2Dec_Parse(var P:TLzma2Dec26;OutSize:SizeT;Src:PByte;var SrcLen:SizeT;CheckFinishBlock:Boolean):TLzma2ParseStatus26;
function Lzma2Dec_GetUnpackExtra(const P:TLzma2Dec26):UInt32;
function Lzma2Decode(Dest:PByte;var DestLen:SizeT;Src:PByte;var SrcLen:SizeT;
  Prop:Byte;FinishMode:TLzmaFinishMode;out Status:TLzmaStatus;const Alloc:ILzmaAllocator=nil):SRes;
implementation
const
  StateControl=0;StateUnpack0=1;StateUnpack1=2;StatePack0=3;StatePack1=4;
  StateProp=5;StateData=6;StateDataCont=7;StateFinished=8;StateError=9;
type TOldProps=array[0..4] of Byte;
function Add32(A,B:UInt32):UInt32;inline;
begin Result:=UInt32(UInt64(A)+B);end;
function AddSize(A,B:SizeT):SizeT;inline;
begin if B>High(SizeT)-A then Result:=B-(High(SizeT)-A)-1 else Result:=A+B;end;
function OldProps(Prop:Byte;out Props:TOldProps):SRes;
var Dictionary:UInt32;
begin
  if Prop>40 then Exit(SZ_ERROR_UNSUPPORTED);
  if Prop=40 then Dictionary:=High(UInt32)
  else Dictionary:=(UInt32(2) or (Prop and 1)) shl (Prop div 2+11);
  Props[0]:=4;Props[1]:=Byte(Dictionary);Props[2]:=Byte(Dictionary shr 8);
  Props[3]:=Byte(Dictionary shr 16);Props[4]:=Byte(Dictionary shr 24);Result:=SZ_OK;
end;
procedure Lzma2Dec_Construct(var P:TLzma2Dec26);
begin LzmaDec_Construct(P.Decoder);end;
procedure Lzma2Dec_FreeProbs(var P:TLzma2Dec26;const Alloc:ILzmaAllocator);
begin LzmaDec_FreeProbs(P.Decoder,Alloc);end;
procedure Lzma2Dec_Free(var P:TLzma2Dec26;const Alloc:ILzmaAllocator);
begin LzmaDec_Free(P.Decoder,Alloc);end;
function Lzma2Dec_AllocateProbs(var P:TLzma2Dec26;Prop:Byte;const Alloc:ILzmaAllocator):SRes;
var Props:TOldProps;
begin Result:=OldProps(Prop,Props);if Result=SZ_OK then Result:=LzmaDec_AllocateProbs(P.Decoder,@Props[0],5,Alloc);end;
function Lzma2Dec_Allocate(var P:TLzma2Dec26;Prop:Byte;const Alloc:ILzmaAllocator):SRes;
var Props:TOldProps;
begin Result:=OldProps(Prop,Props);if Result=SZ_OK then Result:=LzmaDec_Allocate(P.Decoder,@Props[0],5,Alloc);end;
procedure Lzma2Dec_Init(var P:TLzma2Dec26);
begin
  P.State:=StateControl;P.NeedInitLevel:=$E0;P.IsExtraMode:=0;P.UnpackSize:=0;
  LzmaDec_Init(P.Decoder);
end;
function UpdateState(var P:TLzma2Dec26;B:Byte):UInt32;
var Lc,Lp,Value:UInt32;
begin
  case P.State of
  StateControl:
    begin
      P.IsExtraMode:=0;P.Control:=B;if B=0 then Exit(StateFinished);
      if (B and $80)=0 then
      begin
        if B=1 then P.NeedInitLevel:=$C0
        else if (B>2) or (P.NeedInitLevel=$E0) then Exit(StateError);
      end
      else
      begin
        if B<P.NeedInitLevel then Exit(StateError);
        P.NeedInitLevel:=0;P.UnpackSize:=UInt32(B and $1F) shl 16;
      end;
      Result:=StateUnpack0;
    end;
  StateUnpack0:begin P.UnpackSize:=P.UnpackSize or (UInt32(B) shl 8);Result:=StateUnpack1;end;
  StateUnpack1:
    begin
      P.UnpackSize:=Add32(P.UnpackSize or B,1);
      if (P.Control and $80)=0 then Result:=StateData else Result:=StatePack0;
    end;
  StatePack0:begin P.PackSize:=UInt32(B) shl 8;Result:=StatePack1;end;
  StatePack1:
    begin
      P.PackSize:=Add32(P.PackSize or B,1);
      if (P.Control and $40)<>0 then Result:=StateProp else Result:=StateData;
    end;
  StateProp:
    begin
      if B>=225 then Exit(StateError);Lc:=B mod 9;Value:=B div 9;
      P.Decoder.Prop.Pb:=Byte(Value div 5);Lp:=Value mod 5;
      if Lc+Lp>4 then Exit(StateError);
      P.Decoder.Prop.Lc:=Byte(Lc);P.Decoder.Prop.Lp:=Byte(Lp);Result:=StateData;
    end;
  else Result:=StateError;end;
end;
procedure UpdateUncompressed(var P:TLzmaDec26;Src:PByte;Size:SizeT);
begin
  if Size<>0 then Move(Src^,P.Dic[P.DicPos],Size);Inc(P.DicPos,Size);
  if (P.CheckDicSize=0) and (P.Prop.DicSize-P.ProcessedPos<=Size) then P.CheckDicSize:=P.Prop.DicSize;
  P.ProcessedPos:=Add32(P.ProcessedPos,UInt32(Size));
end;
function Lzma2Dec_DecodeToDic(var P:TLzma2Dec26;DicLimit:SizeT;Src:PByte;var SrcLen:SizeT;
  FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
var InSize,DicPos,InCur,OutCur:SizeT;CurFinish:TLzmaFinishMode;Res:SRes;
begin
  InSize:=SrcLen;SrcLen:=0;Status:=lsNotSpecified;
  if (DicLimit>P.Decoder.DicBufSize) or (P.Decoder.DicPos>DicLimit) or
    ((InSize<>0) and (Src=nil)) then Exit(SZ_ERROR_PARAM);
  while P.State<>StateError do
  begin
    if P.State=StateFinished then begin Status:=lsFinishedWithMark;Exit(SZ_OK);end;
    DicPos:=P.Decoder.DicPos;
    if (DicPos=DicLimit) and (FinishMode=lfmAny) then begin Status:=lsNotFinished;Exit(SZ_OK);end;
    if (P.State<>StateData) and (P.State<>StateDataCont) then
    begin
      if SrcLen=InSize then begin Status:=lsNeedsMoreInput;Exit(SZ_OK);end;
      Inc(SrcLen);P.State:=UpdateState(P,Src^);Inc(Src);
      if (DicPos=DicLimit) and (P.State<>StateFinished) then Break;
      Continue;
    end;
    InCur:=InSize-SrcLen;OutCur:=DicLimit-DicPos;CurFinish:=lfmAny;
    if OutCur>=P.UnpackSize then begin OutCur:=P.UnpackSize;CurFinish:=lfmEnd;end;
    if (P.Control and $80)=0 then
    begin
      if InCur=0 then begin Status:=lsNeedsMoreInput;Exit(SZ_OK);end;
      if P.State=StateData then LzmaDec_InitDicAndState(P.Decoder,P.Control=1,False);
      if InCur>OutCur then InCur:=OutCur;
      if InCur=0 then Break;
      UpdateUncompressed(P.Decoder,Src,InCur);Inc(Src,InCur);Inc(SrcLen,InCur);Dec(P.UnpackSize,UInt32(InCur));
      if P.UnpackSize=0 then P.State:=StateControl else P.State:=StateDataCont;
    end
    else
    begin
      if P.State=StateData then
      begin
        LzmaDec_InitDicAndState(P.Decoder,P.Control>=$E0,P.Control>=$A0);P.State:=StateDataCont;
      end;
      if InCur>P.PackSize then InCur:=P.PackSize;
      Res:=LzmaDec_DecodeToDic(P.Decoder,DicPos+OutCur,Src,InCur,CurFinish,Status);
      Inc(Src,InCur);Inc(SrcLen,InCur);Dec(P.PackSize,UInt32(InCur));
      OutCur:=P.Decoder.DicPos-DicPos;Dec(P.UnpackSize,UInt32(OutCur));
      if Res<>SZ_OK then Break;
      if Status=lsNeedsMoreInput then begin if P.PackSize=0 then Break;Exit(SZ_OK);end;
      if (InCur=0) and (OutCur=0) then
      begin
        if (Status<>lsMaybeFinishedWithoutMark) or (P.UnpackSize<>0) or (P.PackSize<>0) then Break;
        P.State:=StateControl;
      end;
      Status:=lsNotSpecified;
    end;
  end;
  Status:=lsNotSpecified;P.State:=StateError;Result:=SZ_ERROR_DATA;
end;
function Lzma2Dec_Parse(var P:TLzma2Dec26;OutSize:SizeT;Src:PByte;var SrcLen:SizeT;CheckFinishBlock:Boolean):TLzma2ParseStatus26;
var InSize,InCur,Remaining:SizeT;
begin
  InSize:=SrcLen;SrcLen:=0;
  while P.State<>StateError do
  begin
    if P.State=StateFinished then Exit(lpsFinishedWithMark);
    if (OutSize=0) and not CheckFinishBlock then Exit(lpsNotFinished);
    if (Src=nil) and (InSize<>0) then Break;
    if (P.State<>StateData) and (P.State<>StateDataCont) then
    begin
      if SrcLen=InSize then Exit(lpsNeedsMoreInput);
      Inc(SrcLen);P.State:=UpdateState(P,Src^);Inc(Src);
      if (P.State=StateUnpack0) and ((P.Control=1) or (P.Control>=$E0)) then Exit(lpsNewBlock);
      if (OutSize=0) and (P.State<>StateFinished) then Exit(lpsNotFinished);
      if P.State=StateData then Exit(lpsNewChunk);
      Continue;
    end;
    if OutSize=0 then Exit(lpsNotFinished);
    InCur:=InSize-SrcLen;
    if (P.Control and $80)=0 then
    begin
      if InCur=0 then Exit(lpsNeedsMoreInput);
      if InCur>P.UnpackSize then InCur:=P.UnpackSize;if InCur>OutSize then InCur:=OutSize;
      P.Decoder.DicPos:=AddSize(P.Decoder.DicPos,InCur);Inc(Src,InCur);Inc(SrcLen,InCur);
      Dec(OutSize,InCur);Dec(P.UnpackSize,UInt32(InCur));
      if P.UnpackSize=0 then P.State:=StateControl else P.State:=StateDataCont;
    end
    else
    begin
      P.IsExtraMode:=1;
      if InCur=0 then begin if P.PackSize<>0 then Exit(lpsNeedsMoreInput);end
      else if P.State=StateData then
      begin
        P.State:=StateDataCont;
        if Src^<>0 then begin Inc(SrcLen);P.PackSize:=Add32(P.PackSize,High(UInt32));Break;end;
      end;
      if InCur>P.PackSize then InCur:=P.PackSize;
      Inc(Src,InCur);Inc(SrcLen,InCur);Dec(P.PackSize,UInt32(InCur));
      if P.PackSize=0 then
      begin
        Remaining:=OutSize;if Remaining>P.UnpackSize then Remaining:=P.UnpackSize;
        P.Decoder.DicPos:=AddSize(P.Decoder.DicPos,Remaining);Dec(P.UnpackSize,UInt32(Remaining));Dec(OutSize,Remaining);
        if P.UnpackSize=0 then P.State:=StateControl;
      end;
    end;
  end;
  P.State:=StateError;Result:=lpsNotSpecified;
end;
function Lzma2Dec_GetUnpackExtra(const P:TLzma2Dec26):UInt32;
begin if P.IsExtraMode<>0 then Result:=P.UnpackSize else Result:=0;end;
function Lzma2Dec_DecodeToBuf(var P:TLzma2Dec26;Dest:PByte;var DestLen:SizeT;Src:PByte;var SrcLen:SizeT;
  FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
var OutSize,InSize,InCur,OutCur,DicPos:SizeT;CurFinish:TLzmaFinishMode;
begin
  OutSize:=DestLen;InSize:=SrcLen;SrcLen:=0;DestLen:=0;Status:=lsNotSpecified;
  if ((OutSize<>0) and (Dest=nil)) or (P.Decoder.DicBufSize=0) then Exit(SZ_ERROR_PARAM);
  while True do
  begin
    InCur:=InSize;
    if P.Decoder.DicPos=P.Decoder.DicBufSize then P.Decoder.DicPos:=0;
    DicPos:=P.Decoder.DicPos;CurFinish:=lfmAny;OutCur:=P.Decoder.DicBufSize-DicPos;
    if OutCur>=OutSize then begin OutCur:=OutSize;CurFinish:=FinishMode;end;
    Result:=Lzma2Dec_DecodeToDic(P,DicPos+OutCur,Src,InCur,CurFinish,Status);
    Inc(Src,InCur);Dec(InSize,InCur);Inc(SrcLen,InCur);OutCur:=P.Decoder.DicPos-DicPos;
    if OutCur<>0 then Move(P.Decoder.Dic[DicPos],Dest^,OutCur);
    Inc(Dest,OutCur);Dec(OutSize,OutCur);Inc(DestLen,OutCur);
    if Result<>SZ_OK then Exit;
    if (OutCur=0) or (OutSize=0) then Exit(SZ_OK);
  end;
end;
function Lzma2Decode(Dest:PByte;var DestLen:SizeT;Src:PByte;var SrcLen:SizeT;
  Prop:Byte;FinishMode:TLzmaFinishMode;out Status:TLzmaStatus;const Alloc:ILzmaAllocator):SRes;
var P:TLzma2Dec26;OutSize,InSize:SizeT;
begin
  OutSize:=DestLen;InSize:=SrcLen;DestLen:=0;SrcLen:=0;Status:=lsNotSpecified;Lzma2Dec_Construct(P);
  Result:=Lzma2Dec_AllocateProbs(P,Prop,Alloc);if Result<>SZ_OK then Exit;
  try
    P.Decoder.Dic:=Dest;P.Decoder.DicBufSize:=OutSize;Lzma2Dec_Init(P);SrcLen:=InSize;
    Result:=Lzma2Dec_DecodeToDic(P,OutSize,Src,SrcLen,FinishMode,Status);DestLen:=P.Decoder.DicPos;
    if (Result=SZ_OK) and (Status=lsNeedsMoreInput) then Result:=SZ_ERROR_INPUT_EOF;
  finally Lzma2Dec_FreeProbs(P,Alloc);end;
end;
end.
