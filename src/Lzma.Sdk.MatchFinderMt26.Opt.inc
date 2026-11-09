function GetMatchesSpecN_2(LenLimit: PByte; Pos: SizeT; Cur: PByte; Son: PLzRef;
  CutValue: UInt32; D: PUInt32; MaxLen: SizeT; Hash, Limit, HashEnd: PUInt32;
  CyclicBufferPos: SizeT; CyclicBufferSize: UInt32; var PosRes: UInt32): PUInt32;
var Delta, Cbs, Cut, Pair0, Pair1, CurMatch: UInt32;
  Ptr0, Ptr1, Pair, Dest, Src: PLzRef; Distances: PUInt32;
  Len0, Len1, Len, Longest: PByte; Diff, Cyc: NativeInt;
{$IFDEF ENCODER_FACADE_STATE_DIAG}
  function LinkOk(P: PLzRef): Boolean;
  begin Result := (NativeUInt(P) >= NativeUInt(Son)) and
    (NativeUInt(P) < NativeUInt(Son+SizeT(CyclicBufferSize)*2)); end;
  procedure Fault(const Where: string);
  begin
    WriteLn(ErrOutput,'BT_RANGE ',Where,' pos=',Pos,' cyc=',CyclicBufferPos,' size=',CyclicBufferSize,
      ' cbs=',Cbs,' delta=',Delta,' pairCycle=',Cyc,' son=',NativeUInt(Son),
      ' ptr0=',NativeUInt(Ptr0),' ptr1=',NativeUInt(Ptr1),' pair=',NativeUInt(Pair));
  end;
{$ENDIF}
begin
  repeat
    if Hash = HashEnd then Break;
    Delta := Hash^; Inc(Hash); if Delta = 0 then Exit(nil);
    Inc(LenLimit); Cbs := CyclicBufferSize;
{$IFDEF ENCODER_FACADE_STATE_DIAG}
    if CyclicBufferPos >= CyclicBufferSize then begin Fault('entry'); Exit(nil); end;
{$ENDIF}
    if UInt32(Pos) < Cbs then
    begin if Delta > UInt32(Pos) then Exit(nil); Cbs := UInt32(Pos); end;
    if Delta >= Cbs then
    begin
      Ptr1 := Son+(CyclicBufferPos shl 1); D^ := 0; Inc(D); Ptr1[0] := 0; Ptr1[1] := 0;
    end
    else
    begin
      Inc(D); Distances := D; Ptr1 := Son+(CyclicBufferPos shl 1); Ptr0 := Ptr1+1;
      Cut := CutValue; Len0 := Cur; Len1 := Cur; Longest := Cur+MaxLen;
      while True do
      begin
        Cyc := NativeInt(CyclicBufferPos)-NativeInt(Delta);
        if CyclicBufferPos < Delta then Inc(Cyc,Cbs);
        Pair := Son+(SizeT(Cyc) shl 1); Diff := -NativeInt(Delta);
{$IFDEF ENCODER_FACADE_STATE_DIAG}
        if not LinkOk(Pair) or not LinkOk(Pair+1) then begin Fault('pair'); Exit(nil); end;
        if not LinkOk(Ptr0) or not LinkOk(Ptr1) then begin Fault('parents'); Exit(nil); end;
{$ENDIF}
        if NativeUInt(Len0) < NativeUInt(Len1) then Len := Len0 else Len := Len1;
        Pair0 := Pair^;
        if (Len+Diff)^ = Len^ then
        begin
          Inc(Len);
          if (Len <> LenLimit) and ((Len+Diff)^ = Len^) then
          repeat Inc(Len); until (Len = LenLimit) or ((Len+Diff)^ <> Len^);
          if NativeUInt(Longest) < NativeUInt(Len) then
          begin
            Longest := Len; D[0] := UInt32(NativeUInt(Len)-NativeUInt(Cur)); D[1] := Delta-1; Inc(D,2);
            if Len = LenLimit then
            begin
              Pair1 := Pair[1]; Ptr1^ := Pair0; Ptr0^ := Pair1;
              (Distances-1)^ := UInt32((NativeUInt(D)-NativeUInt(Distances)) div 4);
              if (Hash <> HashEnd) and (Hash^ = Delta) and ((LenLimit+Diff)^ = LenLimit^)
                and (NativeUInt(D) < NativeUInt(Limit)) then
              repeat
                D[0] := 2; D[1] := UInt32(NativeUInt(LenLimit)-NativeUInt(Cur)); D[2] := Delta-1; Inc(D,3);
                Inc(Cur); Inc(LenLimit); Inc(CyclicBufferPos);
                Dest := Son+(CyclicBufferPos shl 1); Cyc := Diff;
                if CyclicBufferPos < Delta then Inc(Cyc,Cbs);
                Src := Dest+(Cyc*2);
{$IFDEF ENCODER_FACADE_STATE_DIAG}
                if not LinkOk(Src) or not LinkOk(Src+1) or not LinkOk(Dest) or not LinkOk(Dest+1) then
                begin Fault('long-copy'); Exit(nil); end;
{$ENDIF}
                Pair0 := Src[0]; Pair1 := Src[1]; Dest[0] := Pair0; Dest[1] := Pair1;
                Inc(Pos); Inc(Hash);
              until (Hash = HashEnd) or (Hash^ <> Delta) or ((LenLimit+Diff)^ <> LenLimit^)
                or (NativeUInt(D) >= NativeUInt(Limit));
              Break;
            end;
          end;
        end;
        CurMatch := UInt32(Pos)-Delta;
        if (Len+Diff)^ < Len^ then
        begin Delta := Pair[1]; Ptr1^ := CurMatch; Ptr1 := Pair+1; Len1 := Len; end
        else begin Delta := Pair^; Ptr0^ := CurMatch; Ptr0 := Pair; Len0 := Len; end;
        if Delta >= CurMatch then Exit(nil);
        Delta := UInt32(Pos)-Delta; Dec(Cut);
        if (Cut = 0) or (Delta >= Cbs) then
        begin
          Ptr0^ := 0; Ptr1^ := 0;
          (Distances-1)^ := UInt32((NativeUInt(D)-NativeUInt(Distances)) div 4); Break;
        end;
      end;
    end;
    Inc(Pos); Inc(CyclicBufferPos); Inc(Cur);
  until NativeUInt(D) >= NativeUInt(Limit);
  PosRes := UInt32(Pos); Result := D;
end;
