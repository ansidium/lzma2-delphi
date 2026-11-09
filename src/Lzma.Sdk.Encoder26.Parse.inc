// SDK 26.05 parsing order and ties, native unmanaged optimum state.
const
  NextLiteral: array[0..11] of UInt32=(0,0,0,0,1,2,3,4,5,6,4,5);
  NextMatch: array[0..11] of UInt32=(7,7,7,7,7,7,7,10,10,10,10,10);
  NextRep: array[0..11] of UInt32=(8,8,8,8,8,8,8,11,11,11,11,11);
  NextShortRep: array[0..11] of UInt32=(9,9,9,9,9,9,9,11,11,11,11,11);

function CurrentData(P:PEncoder):PByte;inline;
begin Result:=P.Finder.GetPointerToCurrentPos(P.FinderObject);end;
procedure SkipPositions(P:PEncoder;Count:UInt32);inline;
begin Inc(P.AdditionalOffset,Count);P.Finder.Skip(P.FinderObject,Count);end;

function ReadMatchDistances(P:PEncoder;out NumPairs:UInt32):UInt32;
var EndPairs:PUInt32;A,B:PByte;Available,Distance:UInt32;
begin
  Inc(P.AdditionalOffset);P.NumAvail:=P.Finder.GetNumAvailableBytes(P.FinderObject);
  EndPairs:=P.Finder.GetMatches(P.FinderObject,@P.Matches[0]);
  NumPairs:=UInt32((NativeUInt(EndPairs)-NativeUInt(@P.Matches[0])) div SizeOf(UInt32));
  if NumPairs=0 then Exit(0);
  Result:=P.Matches[NumPairs-2];if Result<>P.NumFastBytes then Exit;
  Available:=P.NumAvail;if Available>MatchMaxLen then Available:=MatchMaxLen;
  A:=CurrentData(P)-1;Distance:=P.Matches[NumPairs-1]+1;B:=A-Distance;
  while (Result<Available) and (A[Result]=B[Result]) do Inc(Result);
end;

function LiteralProbs(P:PEncoder;Position,PreviousByte:UInt32):PProb;inline;
begin Result:=P.Models.LitProbs+UInt32(3)*(((((Position shl 8)+PreviousByte) and P.LpMask) shl P.Lc));end;

function LiteralPrice(P:PEncoder;Probs:PProb;Symbol,MatchByte:UInt32;Matched:Boolean):UInt32;
var Offs,Bit,Index:UInt32;
begin
  if not Matched then Exit(TreePrice(P,Probs,8,Symbol));
  Result:=0;Offs:=$100;Symbol:=Symbol or $100;
  repeat
    MatchByte:=MatchByte shl 1;Index:=Offs+(MatchByte and Offs)+(Symbol shr 8);
    Bit:=(Symbol shr 7) and 1;Symbol:=Symbol shl 1;Offs:=Offs and not (MatchByte xor Symbol);
    Inc(Result,Price(P,Probs[Index],Bit));
  until Symbol>=$10000;
end;

function LenToPosState(Len:UInt32):UInt32;inline;
begin if Len<5 then Result:=Len-2 else Result:=3;end;
function ShortRepPrice(P:PEncoder;State,PosState:UInt32):UInt32;inline;
begin Result:=Price(P,P.Models.IsRepG0[State],0)+Price(P,P.Models.IsRep0Long[State,PosState],0);end;
function Rep0Price(P:PEncoder;State,PosState:UInt32):UInt32;inline;
begin Result:=Price(P,P.Models.IsMatch[State,PosState],1)+Price(P,P.Models.IsRep0Long[State,PosState],1)+Price(P,P.Models.IsRep[State],1)+Price(P,P.Models.IsRepG0[State],0);end;
function PureRepPrice(P:PEncoder;RepIndex,State,PosState:UInt32):UInt32;
begin
  if RepIndex=0 then Exit(Price(P,P.Models.IsRepG0[State],0)+Price(P,P.Models.IsRep0Long[State,PosState],1));
  Result:=Price(P,P.Models.IsRepG0[State],1);
  if RepIndex=1 then Inc(Result,Price(P,P.Models.IsRepG1[State],0))
  else Inc(Result,Price(P,P.Models.IsRepG1[State],1)+Price(P,P.Models.IsRepG2[State],RepIndex-2));
end;

function DistancePrice(P:PEncoder;Len,Dist:UInt32):UInt32;inline;
var Lps:UInt32;
begin
  Lps:=LenToPosState(Len);
  if Dist<NumFullDistances then Result:=P.DistancePrices[Lps,Dist]
  else Result:=P.PosSlotPrices[Lps,PosSlot(Dist)]+P.AlignPrices[Dist and 15];
end;

function Backward(P:PEncoder;Cur:UInt32):UInt32;
var Wr,Dist,Len,Extra:UInt32;
begin
  Wr:=Cur+1;P.OptEnd:=Wr;
  while True do
  begin
    Dist:=P.Opt[Cur].Dist;Len:=P.Opt[Cur].Len;Extra:=P.Opt[Cur].Extra;Dec(Cur,Len);
    if Extra<>0 then
    begin
      Dec(Wr);P.Opt[Wr].Len:=Len;Dec(Cur,Extra);Len:=Extra;
      if Extra=1 then begin P.Opt[Wr].Dist:=Dist;Dist:=MarkLiteral;end
      else begin P.Opt[Wr].Dist:=0;Dec(Len);Dec(Wr);P.Opt[Wr].Dist:=MarkLiteral;P.Opt[Wr].Len:=1;end;
    end;
    if Cur=0 then begin P.BackRes:=Dist;P.OptCur:=Wr;Exit(Len);end;
    Dec(Wr);P.Opt[Wr].Dist:=Dist;P.Opt[Wr].Len:=Len;
  end;
end;

function GetOptimum(P:PEncoder;Position:UInt32):UInt32;
var Last,Cur,NumAvail,NumPairs,MainLen,RepMaxIndex,I,PosState,MatchPrice,
    RepMatchPrice,RepLen,Cost,Cost2,Len,Offs,NormalPrice,J,Best,Delta,NewLen,
    Prev,State,Dist,B0,LitPrice,NumAvailFull,Temp,StartLen,Limit,State2,
    PosState2,Offset,RepIndex,Len2:UInt32;
    Reps,RepLens:TReps;Data,Data2:PByte;CurByte,MatchByte:Byte;
    CurOpt,NextOpt,PrevOpt,Opt:POptimal;NextIsLit:Boolean;Probs:PProb;
begin
  P.OptCur:=0;P.OptEnd:=0;
  if P.AdditionalOffset=0 then MainLen:=ReadMatchDistances(P,NumPairs)
  else begin MainLen:=P.LongestMatchLen;NumPairs:=P.NumPairs;end;
  NumAvail:=P.NumAvail;
  if NumAvail<2 then begin P.BackRes:=MarkLiteral;Exit(1);end;
  if NumAvail>MatchMaxLen then NumAvail:=MatchMaxLen;
  Data:=CurrentData(P)-1;RepMaxIndex:=0;
  for I:=0 to 3 do
  begin
    Reps[I]:=P.Models.Reps[I];Data2:=Data-Reps[I];
    if (Data[0]<>Data2[0]) or (Data[1]<>Data2[1]) then begin RepLens[I]:=0;Continue;end;
    Len:=2;while (Len<NumAvail) and (Data[Len]=Data2[Len]) do Inc(Len);
    RepLens[I]:=Len;if Len>RepLens[RepMaxIndex] then RepMaxIndex:=I;
    if Len=MatchMaxLen then Break;
  end;
  if RepLens[RepMaxIndex]>=P.NumFastBytes then
  begin
    P.BackRes:=RepMaxIndex;Len:=RepLens[RepMaxIndex];SkipPositions(P,Len-1);Exit(Len);
  end;
  if MainLen>=P.NumFastBytes then
  begin P.BackRes:=P.Matches[NumPairs-1]+4;SkipPositions(P,MainLen-1);Exit(MainLen);end;
  CurByte:=Data^;MatchByte:=(Data-Reps[0])^;
  Last:=RepLens[RepMaxIndex];if Last<=MainLen then Last:=MainLen;
  if (Last<2) and (CurByte<>MatchByte) then begin P.BackRes:=MarkLiteral;Exit(1);end;
  P.Opt[0].State:=UInt16(P.Models.State);PosState:=Position and P.PbMask;
  Probs:=LiteralProbs(P,Position,(Data-1)^);
  P.Opt[1].Price:=Price(P,P.Models.IsMatch[P.Models.State,PosState],0)+
    LiteralPrice(P,Probs,CurByte,MatchByte,P.Models.State>=7);
  P.Opt[1].Dist:=MarkLiteral;P.Opt[1].Extra:=0;
  MatchPrice:=Price(P,P.Models.IsMatch[P.Models.State,PosState],1);
  RepMatchPrice:=MatchPrice+Price(P,P.Models.IsRep[P.Models.State],1);
  if (MatchByte=CurByte) and (RepLens[0]=0) then
  begin
    Cost:=RepMatchPrice+ShortRepPrice(P,P.Models.State,PosState);
    if Cost<P.Opt[1].Price then begin P.Opt[1].Price:=Cost;P.Opt[1].Dist:=0;P.Opt[1].Extra:=0;end;
    if Last<2 then begin P.BackRes:=P.Opt[1].Dist;Exit(1);end;
  end;
  P.Opt[1].Len:=1;P.Opt[0].Reps:=Reps;
  for I:=0 to 3 do
  begin
    RepLen:=RepLens[I];if RepLen<2 then Continue;
    Cost:=RepMatchPrice+PureRepPrice(P,I,P.Models.State,PosState);
    repeat
      Cost2:=Cost+P.RepLenPrices.Prices[PosState,RepLen-2];Opt:=@P.Opt[RepLen];
      if Cost2<Opt.Price then begin Opt.Price:=Cost2;Opt.Len:=RepLen;Opt.Dist:=I;Opt.Extra:=0;end;
      Dec(RepLen);
    until RepLen<2;
  end;
  Len:=RepLens[0]+1;
  if Len<=MainLen then
  begin
    Offs:=0;NormalPrice:=MatchPrice+Price(P,P.Models.IsRep[P.Models.State],0);
    if Len<2 then Len:=2 else while Len>P.Matches[Offs] do Inc(Offs,2);
    while True do
    begin
      Dist:=P.Matches[Offs+1];Cost:=NormalPrice+P.LenPrices.Prices[PosState,Len-2]+DistancePrice(P,Len,Dist);
      Opt:=@P.Opt[Len];
      if Cost<Opt.Price then begin Opt.Price:=Cost;Opt.Len:=Len;Opt.Dist:=Dist+4;Opt.Extra:=0;end;
      if Len=P.Matches[Offs] then begin Inc(Offs,2);if Offs=NumPairs then Break;end;
      Inc(Len);
    end;
  end;
  Cur:=0;
  while True do
  begin
    Inc(Cur);if Cur=Last then Break;
    if Cur>=NumOpts-64 then
    begin
      Cost:=P.Opt[Cur].Price;Best:=Cur;J:=Cur+1;
      while J<=Last do
      begin Cost2:=P.Opt[J].Price;if Cost>=Cost2 then begin Cost:=Cost2;Best:=J;end;Inc(J);end;
      Delta:=Best-Cur;if Delta<>0 then SkipPositions(P,Delta);Cur:=Best;Break;
    end;
    NewLen:=ReadMatchDistances(P,NumPairs);
    if NewLen>=P.NumFastBytes then begin P.NumPairs:=NumPairs;P.LongestMatchLen:=NewLen;Break;end;
    CurOpt:=@P.Opt[Cur];Inc(Position);Prev:=Cur-CurOpt.Len;
    if CurOpt.Len=1 then
    begin
      State:=P.Opt[Prev].State;
      if CurOpt.Dist=0 then State:=NextShortRep[State] else State:=NextLiteral[State];
    end
    else
    begin
      Dist:=CurOpt.Dist;
      if CurOpt.Extra<>0 then
      begin
        Dec(Prev,CurOpt.Extra);State:=8;
        if CurOpt.Extra=1 then if Dist<4 then State:=8 else State:=7;
      end
      else
      begin State:=P.Opt[Prev].State;if Dist<4 then State:=NextRep[State] else State:=NextMatch[State];end;
      PrevOpt:=@P.Opt[Prev];B0:=PrevOpt.Reps[0];
      if Dist<4 then
      begin
        if Dist=0 then Reps:=PrevOpt.Reps
        else
        begin
          Reps[1]:=B0;B0:=PrevOpt.Reps[1];
          if Dist=1 then begin Reps[0]:=B0;Reps[2]:=PrevOpt.Reps[2];Reps[3]:=PrevOpt.Reps[3];end
          else begin Reps[2]:=B0;Reps[0]:=PrevOpt.Reps[Dist];Reps[3]:=PrevOpt.Reps[Dist xor 1];end;
        end;
      end
      else begin Reps[0]:=Dist-4+1;Reps[1]:=B0;Reps[2]:=PrevOpt.Reps[1];Reps[3]:=PrevOpt.Reps[2];end;
    end;
    CurOpt.State:=UInt16(State);CurOpt.Reps:=Reps;
    Data:=CurrentData(P)-1;CurByte:=Data^;MatchByte:=(Data-Reps[0])^;PosState:=Position and P.PbMask;
    Cost:=CurOpt.Price;Temp:=P.Models.IsMatch[State,PosState];
    MatchPrice:=Cost+Price(P,Temp,1);LitPrice:=Cost+Price(P,Temp,0);
    NextOpt:=@P.Opt[Cur+1];NextIsLit:=False;
    if ((NextOpt.Price<InfinityPrice) and (MatchByte=CurByte)) or (LitPrice>NextOpt.Price) then LitPrice:=0
    else
    begin
      Inc(LitPrice,LiteralPrice(P,LiteralProbs(P,Position,(Data-1)^),CurByte,MatchByte,State>=7));
      if LitPrice<NextOpt.Price then
      begin NextOpt.Price:=LitPrice;NextOpt.Len:=1;NextOpt.Dist:=MarkLiteral;NextOpt.Extra:=0;NextIsLit:=True;end;
    end;
    RepMatchPrice:=MatchPrice+Price(P,P.Models.IsRep[State],1);
    NumAvailFull:=P.NumAvail;Temp:=NumOpts-1-Cur;if NumAvailFull>Temp then NumAvailFull:=Temp;
    if (State<7) and (MatchByte=CurByte) and (RepMatchPrice<NextOpt.Price) and
       ((NextOpt.Len<2) or (NextOpt.Dist<>0)) then
    begin
      Cost:=RepMatchPrice+ShortRepPrice(P,State,PosState);
      if Cost<NextOpt.Price then
      begin NextOpt.Price:=Cost;NextOpt.Len:=1;NextOpt.Dist:=0;NextOpt.Extra:=0;NextIsLit:=False;end;
    end;
    if NumAvailFull<2 then Continue;
    NumAvail:=NumAvailFull;if NumAvail>P.NumFastBytes then NumAvail:=P.NumFastBytes;
    if not NextIsLit and (LitPrice<>0) and (MatchByte<>CurByte) and (NumAvailFull>2) then
    begin
      Data2:=Data-Reps[0];
      if (Data[1]=Data2[1]) and (Data[2]=Data2[2]) then
      begin
        Limit:=P.NumFastBytes+1;if Limit>NumAvailFull then Limit:=NumAvailFull;
        Len:=3;while (Len<Limit) and (Data[Len]=Data2[Len]) do Inc(Len);
        State2:=NextLiteral[State];PosState2:=(Position+1) and P.PbMask;
        Cost:=LitPrice+Rep0Price(P,State2,PosState2);Offset:=Cur+Len;
        if Last<Offset then Last:=Offset;Dec(Len);
        Cost2:=Cost+P.RepLenPrices.Prices[PosState2,Len-2];Opt:=@P.Opt[Offset];
        if Cost2<Opt.Price then begin Opt.Price:=Cost2;Opt.Len:=Len;Opt.Dist:=0;Opt.Extra:=1;end;
      end;
    end;
    StartLen:=2;
    for RepIndex:=0 to 3 do
    begin
      Data2:=Data-Reps[RepIndex];if (Data[0]<>Data2[0]) or (Data[1]<>Data2[1]) then Continue;
      Len:=2;while (Len<NumAvail) and (Data[Len]=Data2[Len]) do Inc(Len);
      Offset:=Cur+Len;if Last<Offset then Last:=Offset;
      Len2:=Len;Cost:=RepMatchPrice+PureRepPrice(P,RepIndex,State,PosState);
      repeat
        Cost2:=Cost+P.RepLenPrices.Prices[PosState,Len2-2];Opt:=@P.Opt[Cur+Len2];
        if Cost2<Opt.Price then begin Opt.Price:=Cost2;Opt.Len:=Len2;Opt.Dist:=RepIndex;Opt.Extra:=0;end;
        Dec(Len2);
      until Len2<2;
      if RepIndex=0 then StartLen:=Len+1;
      Len2:=Len+1;Limit:=Len2+P.NumFastBytes;if Limit>NumAvailFull then Limit:=NumAvailFull;Inc(Len2,2);
      if (Len2<=Limit) and (Data[Len2-2]=Data2[Len2-2]) and (Data[Len2-1]=Data2[Len2-1]) then
      begin
        State2:=NextRep[State];PosState2:=(Position+Len) and P.PbMask;
        Inc(Cost,P.RepLenPrices.Prices[PosState,Len-2]+Price(P,P.Models.IsMatch[State2,PosState2],0)+
          LiteralPrice(P,LiteralProbs(P,Position+Len,Data[Len-1]),Data[Len],Data2[Len],True));
        State2:=5;PosState2:=(PosState2+1) and P.PbMask;Inc(Cost,Rep0Price(P,State2,PosState2));
        while (Len2<Limit) and (Data[Len2]=Data2[Len2]) do Inc(Len2);
        Dec(Len2,Len);Offset:=Cur+Len+Len2;if Last<Offset then Last:=Offset;Dec(Len2);
        Cost2:=Cost+P.RepLenPrices.Prices[PosState2,Len2-2];Opt:=@P.Opt[Offset];
        if Cost2<Opt.Price then begin Opt.Price:=Cost2;Opt.Len:=Len2;Opt.Extra:=UInt16(Len+1);Opt.Dist:=RepIndex;end;
      end;
    end;
    if NewLen>NumAvail then
    begin
      NewLen:=NumAvail;NumPairs:=0;while NewLen>P.Matches[NumPairs] do Inc(NumPairs,2);
      P.Matches[NumPairs]:=NewLen;Inc(NumPairs,2);
    end;
    if NewLen>=StartLen then
    begin
      NormalPrice:=MatchPrice+Price(P,P.Models.IsRep[State],0);Offset:=Cur+NewLen;if Last<Offset then Last:=Offset;
      Offs:=0;while StartLen>P.Matches[Offs] do Inc(Offs,2);Dist:=P.Matches[Offs+1];Len:=StartLen;
      while True do
      begin
        Cost:=NormalPrice+P.LenPrices.Prices[PosState,Len-2]+DistancePrice(P,Len,Dist);Opt:=@P.Opt[Cur+Len];
        if Cost<Opt.Price then begin Opt.Price:=Cost;Opt.Len:=Len;Opt.Dist:=Dist+4;Opt.Extra:=0;end;
        if Len=P.Matches[Offs] then
        begin
          Data2:=Data-Dist-1;Len2:=Len+1;Limit:=Len2+P.NumFastBytes;
          if Limit>NumAvailFull then Limit:=NumAvailFull;Inc(Len2,2);
          if (Len2<=Limit) and (Data[Len2-2]=Data2[Len2-2]) and (Data[Len2-1]=Data2[Len2-1]) then
          begin
            while (Len2<Limit) and (Data[Len2]=Data2[Len2]) do Inc(Len2);Dec(Len2,Len);
            State2:=NextMatch[State];PosState2:=(Position+Len) and P.PbMask;
            Inc(Cost,Price(P,P.Models.IsMatch[State2,PosState2],0)+
              LiteralPrice(P,LiteralProbs(P,Position+Len,Data[Len-1]),Data[Len],Data2[Len],True));
            State2:=4;PosState2:=(PosState2+1) and P.PbMask;Inc(Cost,Rep0Price(P,State2,PosState2));
            Offset:=Cur+Len+Len2;if Last<Offset then Last:=Offset;Dec(Len2);
            Cost2:=Cost+P.RepLenPrices.Prices[PosState2,Len2-2];Opt:=@P.Opt[Offset];
            if Cost2<Opt.Price then begin Opt.Price:=Cost2;Opt.Len:=Len2;Opt.Extra:=UInt16(Len+1);Opt.Dist:=Dist+4;end;
          end;
          Inc(Offs,2);if Offs=NumPairs then Break;Dist:=P.Matches[Offs+1];
        end;
        Inc(Len);
      end;
    end;
  end;
  repeat P.Opt[Last].Price:=InfinityPrice;Dec(Last);until Last=0;
  Result:=Backward(P,Cur);
end;

function GetOptimumFast(P:PEncoder):UInt32;
var NumAvail,MainDist,MainLen,NumPairs,RepIndex,RepLen,I,Len,Dist2,Len1,NewDist,Limit:UInt32;
  Data,Data2:PByte;
begin
  if P.AdditionalOffset=0 then MainLen:=ReadMatchDistances(P,NumPairs)
  else begin MainLen:=P.LongestMatchLen;NumPairs:=P.NumPairs;end;
  NumAvail:=P.NumAvail;P.BackRes:=MarkLiteral;if NumAvail<2 then Exit(1);
  if NumAvail>MatchMaxLen then NumAvail:=MatchMaxLen;
  Data:=CurrentData(P)-1;RepLen:=0;RepIndex:=0;
  for I:=0 to 3 do
  begin
    Data2:=Data-P.Models.Reps[I];if (Data[0]<>Data2[0]) or (Data[1]<>Data2[1]) then Continue;
    Len:=2;while (Len<NumAvail) and (Data[Len]=Data2[Len]) do Inc(Len);
    if Len>=P.NumFastBytes then begin P.BackRes:=I;SkipPositions(P,Len-1);Exit(Len);end;
    if Len>RepLen then begin RepIndex:=I;RepLen:=Len;end;
  end;
  if MainLen>=P.NumFastBytes then
  begin P.BackRes:=P.Matches[NumPairs-1]+4;SkipPositions(P,MainLen-1);Exit(MainLen);end;
  MainDist:=0;
  if MainLen>=2 then
  begin
    MainDist:=P.Matches[NumPairs-1];
    while NumPairs>2 do
    begin
      if MainLen<>P.Matches[NumPairs-4]+1 then Break;
      Dist2:=P.Matches[NumPairs-3];if (MainDist shr 7)<=Dist2 then Break;
      Dec(NumPairs,2);Dec(MainLen);MainDist:=Dist2;
    end;
    if (MainLen=2) and (MainDist>=$80) then MainLen:=1;
  end;
  if (RepLen>=2) and ((RepLen+1>=MainLen) or ((RepLen+2>=MainLen) and (MainDist>=1 shl 9)) or
    ((RepLen+3>=MainLen) and (MainDist>=1 shl 15))) then
  begin P.BackRes:=RepIndex;SkipPositions(P,RepLen-1);Exit(RepLen);end;
  if (MainLen<2) or (NumAvail<=2) then Exit(1);
  Len1:=ReadMatchDistances(P,P.NumPairs);P.LongestMatchLen:=Len1;
  if Len1>=2 then
  begin
    NewDist:=P.Matches[P.NumPairs-1];
    if ((Len1>=MainLen) and (NewDist<MainDist)) or
       ((Len1=MainLen+1) and ((NewDist shr 7)<=MainDist)) or (Len1>MainLen+1) or
       ((Len1+1>=MainLen) and (MainLen>=3) and ((MainDist shr 7)>NewDist)) then Exit(1);
  end;
  Data:=CurrentData(P)-1;
  for I:=0 to 3 do
  begin
    Data2:=Data-P.Models.Reps[I];if (Data[0]<>Data2[0]) or (Data[1]<>Data2[1]) then Continue;
    Limit:=MainLen-1;Len:=2;
    while True do begin if Len>=Limit then Exit(1);if Data[Len]<>Data2[Len] then Break;Inc(Len);end;
  end;
  P.BackRes:=MainDist+4;if MainLen<>2 then SkipPositions(P,MainLen-2);Result:=MainLen;
end;
