unit Lzma.Sdk.Bcj26;

// SDK 26.05 Bra86.c, Igor Pavlov, public domain. Native scalar X86 BCJ.
{$POINTERMATH ON}
{$B-}
interface
uses Lzma.Types;
function z7_BranchConvSt_X86_Enc(Data: PByte; Size: SizeT; Pc: UInt32;
  var State: UInt32): PByte;
function z7_BranchConvSt_X86_Dec(Data: PByte; Size: SizeT; Pc: UInt32;
  var State: UInt32): PByte;
implementation
{$Q-}
{$R-}
function Convert(Data: PByte; Size: SizeT; Pc: UInt32; var State: UInt32;
  Encoding: Boolean): PByte;
label Start, MainLoop, M0, M1, M2, A0, A1, A2, A3, ContinueMask, FinishP, Finish;
var P, Lim: PByte; Mask, V, C: UInt32;
begin
  P := Data;
  if Size < 5 then Exit(P);
  Lim := P+Size-4; Mask := State; Pc := Pc+4-UInt32(NativeUInt(P));
  goto Start;
ContinueMask:
  Mask := Mask or 4;
Start:
  if NativeUInt(P) >= NativeUInt(Lim) then goto Finish;
  Inc(P,4);
  if (P[-4] and $FE) = $E8 then goto M0; Mask := Mask shr 1;
  if (P[-3] and $FE) = $E8 then goto M1; Mask := Mask shr 1;
  if (P[-2] and $FE) = $E8 then goto M2; Mask := 0;
  if (P[-1] and $FE) = $E8 then goto A3;
  goto MainLoop;
M0: Dec(P);
M1: Dec(P);
M2: Dec(P);
  if Mask = 0 then goto A3;
  if NativeUInt(P) > NativeUInt(Lim) then goto FinishP;
  if (Mask > 4) or (Mask = 3) then
  begin Mask := Mask shr 1; goto ContinueMask; end;
  Mask := Mask shr 1;
  if ((UInt32(P[Mask])+1) and $FE) = 0 then goto ContinueMask;
  V := PUInt32(P)^+$1000000;
  if (V and $FE000000) <> 0 then goto ContinueMask;
  C := Pc+UInt32(NativeUInt(P));
  if Encoding then Inc(V,C) else Dec(V,C);
  Mask := Mask shl 3;
  if (((V shr Mask)+1) and $FE) = 0 then
  begin
    V := V xor ((UInt32($100) shl Mask)-1);
    if Encoding then Inc(V,C) else Dec(V,C);
  end;
  Mask := 0; V := (V and $1FFFFFF)-$1000000;
  PUInt32(P)^ := V; Inc(P,4);
MainLoop:
  if NativeUInt(P) >= NativeUInt(Lim) then goto Finish;
  repeat
    Inc(P,4);
    if (P[-4] and $FE) = $E8 then goto A0;
    if (P[-3] and $FE) = $E8 then goto A1;
    if (P[-2] and $FE) = $E8 then goto A2;
    if (P[-1] and $FE) = $E8 then goto A3;
  until NativeUInt(P) >= NativeUInt(Lim);
  goto Finish;
A0: Dec(P);
A1: Dec(P);
A2: Dec(P);
A3:
  if NativeUInt(P) > NativeUInt(Lim) then goto FinishP;
  V := PUInt32(P)^+$1000000;
  if (V and $FE000000) <> 0 then goto ContinueMask;
  C := Pc+UInt32(NativeUInt(P));
  if Encoding then Inc(V,C) else Dec(V,C);
  V := (V and $1FFFFFF)-$1000000; PUInt32(P)^ := V; Inc(P,4);
  goto MainLoop;
FinishP: Dec(P);
Finish:
  State := Mask; Result := P;
end;
function z7_BranchConvSt_X86_Enc(Data: PByte; Size: SizeT; Pc: UInt32;
  var State: UInt32): PByte;
begin Result := Convert(Data,Size,Pc,State,True); end;
function z7_BranchConvSt_X86_Dec(Data: PByte; Size: SizeT; Pc: UInt32;
  var State: UInt32): PByte;
begin Result := Convert(Data,Size,Pc,State,False); end;
end.
