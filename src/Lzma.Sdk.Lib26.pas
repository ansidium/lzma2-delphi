unit Lzma.Sdk.Lib26;

// SDK 26.05 LzmaLib.c / Lzma86Enc.c / Lzma86Dec.c, public domain.
{$POINTERMATH ON}
{$B-}
interface
uses Lzma.Types;
const
  LZMA86_HEADER_SIZE = 14;
  LZMA86_SIZE_OFFSET = 6;
  SZ_FILTER_NO = 0;
  SZ_FILTER_YES = 1;
  SZ_FILTER_AUTO = 2;
function LzmaCompress(Dest: PByte; var DestLen: SizeT; Src: PByte; SrcLen: SizeT;
  OutProps: PByte; var OutPropsSize: SizeT; Level: Int32; DictSize: UInt32;
  Lc, Lp, Pb, Fb, NumThreads: Int32): SRes;
function LzmaUncompress(Dest: PByte; var DestLen: SizeT; Src: PByte;
  var SrcLen: SizeT; Props: PByte; PropsSize: SizeT): SRes;
function Lzma86_Encode(Dest: PByte; var DestLen: SizeT; Src: PByte;
  SrcLen: SizeT; Level: Int32; DictSize: UInt32; FilterMode: Int32): SRes;
function Lzma86_GetUnpackSize(Src: PByte; SrcLen: SizeT; var UnpackSize: UInt64): SRes;
function Lzma86_Decode(Dest: PByte; var DestLen: SizeT; Src: PByte;
  var SrcLen: SizeT): SRes;
implementation
uses System.SysUtils, Lzma.Sdk.Contracts, Lzma.Sdk.Encoder26,
  Lzma.Sdk.Decoder26, Lzma.Sdk.Bcj26, Lzma.Sdk.Memory;

function LzmaCompress(Dest: PByte; var DestLen: SizeT; Src: PByte; SrcLen: SizeT;
  OutProps: PByte; var OutPropsSize: SizeT; Level: Int32; DictSize: UInt32;
  Lc, Lp, Pb, Fb, NumThreads: Int32): SRes;
var Props: CLzmaEncProps;
begin
  LzmaEncProps_Init(Props); Props.Level := Level; Props.DictSize := DictSize;
  Props.Lc := Lc; Props.Lp := Lp; Props.Pb := Pb; Props.Fb := Fb;
  Props.NumThreads := NumThreads;
  Result := LzmaEncode(Dest,DestLen,Src,SrcLen,Props,OutProps,OutPropsSize,0,nil,nil,nil);
end;
function LzmaUncompress(Dest: PByte; var DestLen: SizeT; Src: PByte;
  var SrcLen: SizeT; Props: PByte; PropsSize: SizeT): SRes;
var Status: TLzmaStatus;
begin
  Result := LzmaDecode(Dest,DestLen,Src,SrcLen,Props,UInt32(PropsSize and $FFFFFFFF),lfmAny,Status);
end;
function Lzma86_GetUnpackSize(Src: PByte; SrcLen: SizeT; var UnpackSize: UInt64): SRes;
var I: Integer;
begin
  if SrcLen < LZMA86_HEADER_SIZE then Exit(SZ_ERROR_INPUT_EOF);
  UnpackSize := 0;
  for I := 0 to 7 do UnpackSize := UnpackSize or (UInt64(Src[LZMA86_SIZE_OFFSET+I]) shl (I*8));
  Result := SZ_OK;
end;
function Lzma86_Decode(Dest: PByte; var DestLen: SizeT; Src: PByte;
  var SrcLen: SizeT): SRes;
var UseFilter: Byte; InputSize: SizeT; Status: TLzmaStatus; State: UInt32;
begin
  if SrcLen < LZMA86_HEADER_SIZE then Exit(SZ_ERROR_INPUT_EOF);
  UseFilter := Src[0];
  if UseFilter > 1 then begin DestLen := 0; Exit(SZ_ERROR_UNSUPPORTED); end;
  InputSize := SrcLen-LZMA86_HEADER_SIZE;
  Result := LzmaDecode(Dest,DestLen,Src+LZMA86_HEADER_SIZE,InputSize,Src+1,5,lfmAny,Status);
  SrcLen := InputSize+LZMA86_HEADER_SIZE;
  if Result <> SZ_OK then Exit;
  if UseFilter = 1 then begin State := 0; z7_BranchConvSt_X86_Dec(Dest,DestLen,0,State); end;
end;
function Lzma86_Encode(Dest: PByte; var DestLen: SizeT; Src: PByte;
  SrcLen: SizeT; Level: Int32; DictSize: UInt32; FilterMode: Int32): SRes;
var OutSize, PackSize, PropsSize, MinSize: SizeT; Filtered, Input: PByte;
  UseFilter, BestFiltered, CurrentFiltered: Boolean; Props: CLzmaEncProps;
  State: UInt32; I, Passes: Integer; Current: SRes;
begin
  OutSize := DestLen; DestLen := 0;
  if OutSize < LZMA86_HEADER_SIZE then Exit(SZ_ERROR_OUTPUT_EOF);
  LzmaEncProps_Init(Props); Props.Level := Level; Props.DictSize := DictSize;
  for I := 0 to 7 do Dest[LZMA86_SIZE_OFFSET+I] := Byte(UInt64(SrcLen) shr (I*8));
  Filtered := nil; UseFilter := FilterMode <> SZ_FILTER_NO;
  Result := SZ_ERROR_OUTPUT_EOF;
  try
    if UseFilter then
    begin
      if SrcLen <> 0 then
      begin
        Filtered := LzmaDefaultAllocate(SrcLen);
        if Filtered = nil then Exit(SZ_ERROR_MEM);
        LzmaSdkMove(Filtered,Src,SrcLen);
      end;
      State := 0; z7_BranchConvSt_X86_Enc(Filtered,SrcLen,0,State);
    end;
    MinSize := 0; BestFiltered := False;
    if FilterMode = SZ_FILTER_AUTO then Passes := 3 else Passes := 1;
    for I := 0 to Passes-1 do
    begin
      PackSize := OutSize-LZMA86_HEADER_SIZE; PropsSize := 5;
      CurrentFiltered := (Passes > 1) and (I = Passes-1);
      if CurrentFiltered and not BestFiltered then Break;
      if UseFilter and (I = 0) then CurrentFiltered := True;
      if CurrentFiltered then Input := Filtered else Input := Src;
      Current := LzmaEncode(Dest+LZMA86_HEADER_SIZE,PackSize,Input,SrcLen,
        Props,Dest+1,PropsSize,0,nil,nil,nil);
      if Current <> SZ_ERROR_OUTPUT_EOF then
      begin
        if Current <> SZ_OK then begin Result := Current; Break; end;
        if (PackSize <= MinSize) or (Result <> SZ_OK) then
        begin MinSize := PackSize; BestFiltered := CurrentFiltered; Result := SZ_OK; end;
      end;
    end;
    Dest[0] := Ord(BestFiltered); DestLen := LZMA86_HEADER_SIZE+MinSize;
  finally LzmaDefaultFree(Filtered); end;
end;
end.
