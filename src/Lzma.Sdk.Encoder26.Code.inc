// SDK 26.05 block/range driver and caller-bounded interfaces, scalar backend.
procedure RangeDirectBits(var R:TRangeEnc;Symbol,Bits:UInt32);
begin
  while Bits<>0 do
  begin
    Dec(Bits);R.Range:=R.Range shr 1;
    if (Symbol shr Bits) and 1<>0 then Inc(R.Low,R.Range);
    if R.Range<UInt32(1) shl 24 then begin R.Range:=R.Range shl 8;RangeShiftLow(R);end;
  end;
end;

function RangeProcessed(const R:TRangeEnc):UInt64;inline;
begin Result:=R.Processed+(NativeUInt(R.Buf)-NativeUInt(R.BufBase))+R.CacheSize;end;

procedure WriteEndMarker(P:PEncoder;PosState:UInt32);
begin
  RangeBit(P.Rc,@P.Models.IsMatch[P.Models.State,PosState],1);
  RangeBit(P.Rc,@P.Models.IsRep[P.Models.State],0);P.Models.State:=NextMatch[P.Models.State];
  LenEncode(P.Models.Len,P.Rc,0,PosState);RangeTree(P.Rc,@P.Models.PosSlot[0,0],6,63);
  RangeDirectBits(P.Rc,$3FFFFFF,26);RangeReverseTree(P.Rc,@P.Models.PosAlign[0],4,15);
end;

function CheckErrors(P:PEncoder):SRes;
begin
  if P.Res<>SZ_OK then Exit(P.Res);
  if P.Rc.Res<>SZ_OK then P.Res:=SZ_ERROR_WRITE;
{$IFNDEF Z7_ST}
  if (P.MtMode<>0) and (P.Mfmt.FailureLzBt<>0) then P.Res:=SResFromWRes(ERROR_INTERNAL_ERROR);
{$ENDIF}
  if P.Mfb.Result<>SZ_OK then P.Res:=SZ_ERROR_READ;
  if P.Res<>SZ_OK then P.Finished:=1;Result:=P.Res;
end;

function FlushEncoder(P:PEncoder;NowPos:UInt32):SRes;
var I:Integer;
begin
  P.Finished:=1;
  if P.WriteEndMark<>0 then WriteEndMarker(P,NowPos and P.PbMask);
  for I:=0 to 4 do RangeShiftLow(P.Rc);
  RangeFlushStream(P.Rc);Result:=CheckErrors(P);
end;

function CodeOneBlock(P:PEncoder;MaxPackSize,MaxUnpackSize:UInt32):SRes;
var NowPos,StartPos,NumPairs,Dist,Len,PosState,State,Slot,FooterBits,Base,
    Processed,Oci:UInt32;Data:PByte;Probs:PProb;CurByte:Byte;
begin
  if P.NeedInit<>0 then
  begin
{$IFNDEF Z7_ST}
    if P.MtMode<>0 then
    begin Result:=MatchFinderMt_InitMt(P.Mfmt);if Result<>SZ_OK then Exit;end;
{$ENDIF}
    P.Finder.Init(P.FinderObject);P.NeedInit:=0;
  end;
  if P.Finished<>0 then Exit(P.Res);
  Result:=CheckErrors(P);if Result<>SZ_OK then Exit;
  NowPos:=UInt32(P.NowPos64);StartPos:=NowPos;
  if P.NowPos64=0 then
  begin
    if P.Finder.GetNumAvailableBytes(P.FinderObject)=0 then Exit(FlushEncoder(P,NowPos));
    ReadMatchDistances(P,NumPairs);RangeBit(P.Rc,@P.Models.IsMatch[0,0],0);
    CurByte:=(CurrentData(P)-P.AdditionalOffset)^;LiteralEncode(P.Rc,P.Models.LitProbs,CurByte);
    Dec(P.AdditionalOffset);Inc(NowPos);
  end;
  if P.Finder.GetNumAvailableBytes(P.FinderObject)<>0 then
  while True do
  begin
    if P.FastMode<>0 then Len:=GetOptimumFast(P)
    else
    begin
      Oci:=P.OptCur;
      if P.OptEnd=Oci then Len:=GetOptimum(P,NowPos)
      else begin Len:=P.Opt[Oci].Len;P.BackRes:=P.Opt[Oci].Dist;P.OptCur:=Oci+1;end;
    end;
    PosState:=NowPos and P.PbMask;Dist:=P.BackRes;State:=P.Models.State;
    if Dist=MarkLiteral then
    begin
      RangeBit(P.Rc,@P.Models.IsMatch[State,PosState],0);
      Data:=CurrentData(P)-P.AdditionalOffset;Probs:=LiteralProbs(P,NowPos,(Data-1)^);CurByte:=Data^;
      P.Models.State:=NextLiteral[State];
      if State<7 then LiteralEncode(P.Rc,Probs,CurByte)
      else MatchedLiteralEncode(P.Rc,Probs,CurByte,(Data-P.Models.Reps[0])^);
    end
    else
    begin
      RangeBit(P.Rc,@P.Models.IsMatch[State,PosState],1);
      if Dist<4 then
      begin
        RangeBit(P.Rc,@P.Models.IsRep[State],1);
        if Dist=0 then
        begin
          RangeBit(P.Rc,@P.Models.IsRepG0[State],0);
          if Len<>1 then RangeBit(P.Rc,@P.Models.IsRep0Long[State,PosState],1)
          else begin RangeBit(P.Rc,@P.Models.IsRep0Long[State,PosState],0);P.Models.State:=NextShortRep[State];end;
        end
        else
        begin
          RangeBit(P.Rc,@P.Models.IsRepG0[State],1);
          if Dist=1 then begin RangeBit(P.Rc,@P.Models.IsRepG1[State],0);Dist:=P.Models.Reps[1];end
          else
          begin
            RangeBit(P.Rc,@P.Models.IsRepG1[State],1);
            if Dist=2 then begin RangeBit(P.Rc,@P.Models.IsRepG2[State],0);Dist:=P.Models.Reps[2];end
            else begin RangeBit(P.Rc,@P.Models.IsRepG2[State],1);Dist:=P.Models.Reps[3];P.Models.Reps[3]:=P.Models.Reps[2];end;
            P.Models.Reps[2]:=P.Models.Reps[1];
          end;
          P.Models.Reps[1]:=P.Models.Reps[0];P.Models.Reps[0]:=Dist;
        end;
        if Len<>1 then
        begin LenEncode(P.Models.RepLen,P.Rc,Len-2,PosState);Dec(P.RepLenCounter);P.Models.State:=NextRep[State];end;
      end
      else
      begin
        RangeBit(P.Rc,@P.Models.IsRep[State],0);P.Models.State:=NextMatch[State];
        LenEncode(P.Models.Len,P.Rc,Len-2,PosState);Dec(Dist,4);
        P.Models.Reps[3]:=P.Models.Reps[2];P.Models.Reps[2]:=P.Models.Reps[1];
        P.Models.Reps[1]:=P.Models.Reps[0];P.Models.Reps[0]:=Dist+1;Inc(P.MatchPriceCount);
        Slot:=PosSlot(Dist);RangeTree(P.Rc,@P.Models.PosSlot[LenToPosState(Len),0],6,Slot);
        if Dist>=4 then
        begin
          FooterBits:=(Slot shr 1)-1;
          if Dist<NumFullDistances then
          begin Base:=(2 or (Slot and 1)) shl FooterBits;RangeReverseTree(P.Rc,@P.Models.PosEncoders[Base],FooterBits,Dist);end
          else
          begin RangeDirectBits(P.Rc,Dist shr 4,FooterBits-4);RangeReverseTree(P.Rc,@P.Models.PosAlign[0],4,Dist and 15);end;
        end;
      end;
    end;
    Inc(NowPos,Len);Dec(P.AdditionalOffset,Len);
    if P.AdditionalOffset=0 then
    begin
      if P.FastMode=0 then
      begin
        if P.MatchPriceCount>=64 then begin FillDistancePrices(P);UpdateLenPrices(P,P.LenPrices,P.Models.Len);end;
        if P.RepLenCounter<=0 then begin P.RepLenCounter:=64;UpdateLenPrices(P,P.RepLenPrices,P.Models.RepLen);end;
      end;
      if P.Finder.GetNumAvailableBytes(P.FinderObject)=0 then Break;
      Processed:=NowPos-StartPos;
      if MaxPackSize<>0 then
      begin
        if (Processed+NumOpts+300>=MaxUnpackSize) or (SizeT(RangeProcessed(P.Rc))+NumOpts*8>=MaxPackSize) then Break;
      end
      else if Processed>=UInt32(1) shl 17 then
      begin Inc(P.NowPos64,UInt32(NowPos-StartPos));Exit(CheckErrors(P));end;
    end;
  end;
  Inc(P.NowPos64,UInt32(NowPos-StartPos));Result:=FlushEncoder(P,NowPos);
end;

function EncodePrepared(P:PEncoder;const Progress:ILzmaCompressProgress):SRes;
begin
  while True do
  begin
    Result:=CodeOneBlock(P,0,0);if (Result<>SZ_OK) or (P.Finished<>0) then Break;
    if (Progress<>nil) and (Progress.Progress(P.NowPos64,RangeProcessed(P.Rc))<>SZ_OK) then
    begin Result:=SZ_ERROR_PROGRESS;Break;end;
  end;
  LzmaEnc_Finish(P);
end;

procedure SetMemoryOutput(P:PEncoder;Dest:PByte;Capacity:SizeT);
begin
  P.Rc.MemoryOutput:=True;P.Rc.MemoryDest:=Dest;P.Rc.MemoryRemaining:=Capacity;P.Rc.MemoryOverflow:=False;P.Rc.OutStream:=nil;
end;

function LzmaEnc_Encode(P:CLzmaEncHandle;const OutStream:ILzmaSeqOutStream;
  const InStream:ILzmaSeqInStream;const Progress:ILzmaCompressProgress;
  const Alloc,AllocBig:ILzmaAllocator):SRes;
var V:PEncoder;
begin
  V:=P;MatchFinder_SET_STREAM(V.Mfb,InStream);V.Rc.MemoryOutput:=False;V.Rc.OutStream:=Pointer(OutStream);
  Result:=AllocateAndInit(V,0,Alloc,AllocBig);if Result=SZ_OK then Result:=EncodePrepared(V,Progress);
end;

function LzmaEnc_MemEncode(P:CLzmaEncHandle;Dest:PByte;var DestLen:SizeT;
  Src:PByte;SrcLen:SizeT;WriteEndMark:Int32;const Progress:ILzmaCompressProgress;
  const Alloc,AllocBig:ILzmaAllocator):SRes;
var V:PEncoder;Capacity:SizeT;
begin
  V:=P;Capacity:=DestLen;SetMemoryOutput(V,Dest,Capacity);V.WriteEndMark:=UInt32(WriteEndMark);
  Result:=LzmaEnc_MemPrepare(P,Src,SrcLen,0,Alloc,AllocBig);
  if Result=SZ_OK then
  begin
    Result:=EncodePrepared(V,Progress);
    if (Result=SZ_OK) and (V.NowPos64<>UInt64(SrcLen)) then Result:=SZ_ERROR_FAIL;
  end;
  DestLen:=Capacity-V.Rc.MemoryRemaining;
  if V.Rc.MemoryOverflow then Result:=SZ_ERROR_OUTPUT_EOF;
end;

function LzmaEncode(Dest:PByte;var DestLen:SizeT;Src:PByte;SrcLen:SizeT;
  const Props:CLzmaEncProps;PropsEncoded:PByte;var PropsSize:SizeT;
  WriteEndMark:Int32;const Progress:ILzmaCompressProgress;const Alloc,AllocBig:ILzmaAllocator):SRes;
var P:CLzmaEncHandle;
begin
  P:=LzmaEnc_Create(Alloc);if P=nil then Exit(SZ_ERROR_MEM);
  try
    Result:=LzmaEnc_SetProps(P,Props);
    if Result=SZ_OK then
    begin
      Result:=LzmaEnc_WriteProperties(P,PropsEncoded,PropsSize);
      if Result=SZ_OK then Result:=LzmaEnc_MemEncode(P,Dest,DestLen,Src,SrcLen,WriteEndMark,Progress,Alloc,AllocBig);
    end;
  finally LzmaEnc_Destroy(P,Alloc,AllocBig);end;
end;

function LzmaEnc_CodeOneMemBlock(P:CLzmaEncHandle;ReInit:Boolean;
  Dest:PByte;var DestLen:SizeT;DesiredPackSize:UInt32;var UnpackSize:UInt32):SRes;
var V:PEncoder;Before:UInt64;Capacity:SizeT;
begin
  if DesiredPackSize=0 then Exit(SZ_ERROR_PARAM); // outside the C helper's valid domain
  V:=P;Capacity:=DestLen;SetMemoryOutput(V,Dest,Capacity);
  V.WriteEndMark:=0;V.Finished:=0;V.Res:=SZ_OK;
  if ReInit then InitModels(V);
  InitPrices(V);RangeInit(V.Rc);Before:=V.NowPos64;
  Result:=CodeOneBlock(V,DesiredPackSize,UnpackSize);
  UnpackSize:=UInt32(V.NowPos64-Before);DestLen:=Capacity-V.Rc.MemoryRemaining;
  if V.Rc.MemoryOverflow then Result:=SZ_ERROR_OUTPUT_EOF;
end;
