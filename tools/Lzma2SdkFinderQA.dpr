program Lzma2SdkFinderQA;
{$APPTYPE CONSOLE}
{$R Lzma2GUIManifest.res}

uses System.SysUtils, System.Classes, System.Math, System.Hash, Winapi.Windows,
  Lzma.Types, Lzma.MatchFinder, Lzma.Sdk.MatchFinder, Lzma.Sdk,
  Lzma.Encoder, Lzma.Decoder;

var Checks,Rows,HandleCases:UInt64;CaseIndex,Position:UInt32;Log:TStringList;

procedure Check(const Value:Boolean;const Detail:string);
begin
  Inc(Checks);
  if not Value then raise Exception.CreateFmt('case=%u position=%u: %s',[CaseIndex,Position,Detail]);
end;

function Read32(const Stream:TStream):UInt32;
begin Stream.ReadBuffer(Result,SizeOf(Result));end;

function Sha256(const Bytes:TBytes):string;
var Hash:THashSHA2;
begin Hash:=THashSHA2.Create;Hash.Update(Bytes);Result:=Hash.HashAsString;end;

procedure CompareTrace(const VectorPath,TracePath:string);
var V,T:TFileStream;Cases,CaseNo,ExpectedRows,Bits,L,Capacity,Dictionary,Nb,Fb,Cut,Mt,Window:UInt32;
    Data,Operations,Buffer:TBytes;Finder:TLzmaSdkBinaryTreeMatchFinder;Pairs,Again:TLzmaMatchBuffer;
    ExpectedCount,Len,Dist,I,Offset,Used,Drop,Base,History,Available:UInt32;TraceRows:UInt64;
begin
  V:=TFileStream.Create(VectorPath,fmOpenRead or fmShareDenyWrite);
  T:=TFileStream.Create(TracePath,fmOpenRead or fmShareDenyWrite);
  try
    Check((Read32(V)=$5646424C) and (Read32(V)=1),'Vector header');Cases:=Read32(V);ExpectedRows:=Read32(V);
    Check(Read32(T)=$4F46424C,'Oracle header');Bits:=Read32(T);Check(Bits in [32,64],'Oracle platform');
    Check((Read32(T)=Cases) and (Read32(T)=ExpectedRows),'Oracle coverage header');TraceRows:=0;
    for CaseNo:=0 to Cases-1 do
    begin
      CaseIndex:=CaseNo;
      L:=Read32(V);Capacity:=Read32(V);Dictionary:=Read32(V);Nb:=Read32(V);Fb:=Read32(V);Cut:=Read32(V);Mt:=Read32(V);Window:=Read32(V);
      SetLength(Data,L);SetLength(Operations,L);
      if L<>0 then begin V.ReadBuffer(Data[0],L);V.ReadBuffer(Operations[0],L);end;
      SetLength(Buffer,Capacity);Used:=Min(L,Capacity);Base:=0;
      if Used<>0 then Move(Data[0],Buffer[0],Used);
      Check(Read32(T)=CaseIndex,'Oracle case index');History:=Min(Dictionary,Capacity);
      Check(Read32(T)=TLzmaSdkBinaryTreeMatchFinder.HashMaskFor(History,Nb),'SDK hash mask');
      Finder:=TLzmaSdkBinaryTreeMatchFinder.Create(Buffer,0,Capacity,Dictionary,Nb,Fb,Cut,Mt<>0);
      try
        Finder.SetInputCount(Used);Position:=0;
        while Position<L do
        begin
          Offset:=Position-Base;
          if (Base+Used<L) and (Used-Offset<Fb) then
          begin
            Check((Window=1) and (Offset>History),'Window cannot advance');Drop:=Offset-History;
            Finder.RebaseWindow(Drop);Inc(Base,Drop);Dec(Used,Drop);Dec(Offset,Drop);
            if Used<>0 then Move(Buffer[Drop],Buffer[0],Used);
            Available:=Min(Capacity,L-Base);
            if Available>Used then Move(Data[Base+Used],Buffer[Used],Available-Used);
            Used:=Available;Finder.SetInputCount(Used);
          end;
          if Operations[Position]<>0 then
          begin
            Finder.ReadMatchPairs(Offset,Pairs);ExpectedCount:=Read32(T);
            Check(ExpectedCount=UInt32(Pairs.Count),'SDK match pair count');
            if ExpectedCount<>0 then for I:=0 to ExpectedCount-1 do
            begin
              Len:=Read32(T);Dist:=Read32(T);
              Check((Pairs.Items[I].Length=Len) and (Pairs.Items[I].Distance=Dist+1),'SDK match pair');
            end;
            Finder.ReadMatchPairs(Offset,Again);Check(Again.Count=Pairs.Count,'Repeated cached read count');
            if Pairs.Count<>0 then Check(CompareMem(@Pairs.Items[0],@Again.Items[0],Pairs.Count*SizeOf(TLzmaMatch)),'Repeated cached pairs');
            Inc(Rows);Inc(TraceRows);
          end
          else Finder.InsertRange(Offset,1);
          Inc(Position);
        end;
      finally Finder.Free;end;
      Check(Read32(T)=$4543424C,'Oracle case end');
    end;
    Check((Read32(T)=$4546424C) and (Read32(T)=ExpectedRows),'Oracle final rows');
    Check((TraceRows=ExpectedRows) and (T.Position=T.Size) and (V.Position=V.Size),'Complete input/trace coverage');
  finally T.Free;V.Free;end;
end;

procedure CodecHandles;
var Data,Properties,EncodedBytes:TBytes;Input:TBytesStream;Archive,Decoded:TMemoryStream;
    InApi:ILzmaSeqInStream;OutApi:ILzmaSeqOutStream;Encoder:TLzmaSdkLzmaEncoder;
    Full:TLzmaSdkLzmaEncProps26;Legacy:TLzmaSdkLzmaEncProps;Nb,Threads,Api,I:Integer;
begin
  SetLength(Data,65537);
  for I:=0 to High(Data) do Data[I]:=Byte((I div 13+I mod 7) and $FF);
  Input:=TBytesStream.Create(Data);Archive:=TMemoryStream.Create;Decoded:=TMemoryStream.Create;
  Encoder:=TLzmaSdkLzmaEncoder.Create;InApi:=TLzmaSdkSeqInStream.Create(Input);OutApi:=TLzmaSdkSeqOutStream.Create(Archive);
  try
    for Nb:=2 to 5 do for Threads:=1 to 2 do for Api:=0 to 1 do
    begin
      if Api=0 then
      begin
        Full:=TLzmaSdkLzmaEncProps26.Init;Full.DictSize:=4096;Full.Fb:=32;Full.Algo:=1;
        Full.BtMode:=1;Full.NumHashBytes:=Nb;Full.NumThreads:=Threads;
        Check(Encoder.SetProps(Full)=SZ_OK,'Full SDK BT properties');
      end
      else
      begin
        Legacy:=TLzmaSdkLzmaEncProps.Init;Legacy.DictSize:=4096;Legacy.Fb:=32;Legacy.Algo:=1;
        Legacy.BtMode:=1;Legacy.NumHashBytes:=Nb;Legacy.NumThreads:=Threads;
        Check(Encoder.SetProps(Legacy)=SZ_OK,'Legacy SDK BT properties');
      end;
      Input.Position:=0;Archive.Size:=0;Decoded.Size:=0;
      Check(Encoder.Encode(InApi,OutApi)=SZ_OK,'SDK BT handle encode');
      Check(Encoder.WriteProperties(Properties)=SZ_OK,'SDK BT property bytes');
      Archive.Position:=0;TLzmaRawDecoder.Decode(Archive,Decoded,Properties,Length(Data));
      Check((Decoded.Size=Length(Data)) and CompareMem(Decoded.Memory,Pointer(Data),Length(Data)),'SDK BT handle roundtrip');
      SetLength(EncodedBytes,NativeInt(Archive.Size));Move(Archive.Memory^,EncodedBytes[0],Length(EncodedBytes));
      Log.Add(Format('handle bt=%d threads=%d legacy=%d input=%d bytes=%d archiveSHA=%s',
        [Nb,Threads,Api,Length(Data),Length(EncodedBytes),Sha256(EncodedBytes)]));
      Inc(HandleCases);
    end;
  finally OutApi:=nil;InApi:=nil;Encoder.Free;Decoded.Free;Archive.Free;Input.Free;end;
end;

var FinderOnly:Boolean;HandlesBefore,HandlesAfter:DWORD;
begin
  Log:=TStringList.Create;
  try
    try
      FinderOnly:=(ParamCount=5) and (ParamStr(5)='--finder-only');
      if (ParamCount<>4) and not FinderOnly then raise Exception.Create('Vectors, C32 trace, C64 trace, log; optional --finder-only development precheck');
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesBefore),'Initial handles');
      CompareTrace(ParamStr(1),ParamStr(2));CompareTrace(ParamStr(1),ParamStr(3));
      if not FinderOnly then CodecHandles;
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesAfter),'Final handles');
      Check(HandlesBefore=HandlesAfter,'Finder/handle lifecycle leak');
      Log.Add(Format('rows=%u checks=%u failures=0 nativeBits=%d finderOnly=%d codecHandleTests=%u handlesBefore=%d handlesAfter=%d',
        [Rows,Checks,SizeOf(NativeUInt)*8,Ord(FinderOnly),HandleCases,HandlesBefore,HandlesAfter]));
      Log.SaveToFile(ParamStr(4),TEncoding.UTF8);Writeln(Log[Log.Count-1]);
    except on E:Exception do
      begin Log.Add(E.ClassName+': '+E.Message);if ParamCount>=4 then Log.SaveToFile(ParamStr(4),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;end;
    end;
  finally Log.Free;end;
end.
