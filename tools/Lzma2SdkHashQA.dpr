program Lzma2SdkHashQA;
{$APPTYPE CONSOLE}
{$R Lzma2GUIManifest.res}

uses System.SysUtils, System.Classes, System.Math, System.Hash, Winapi.Windows,
  Lzma.Types, Lzma.Errors, Lzma.MatchFinder, Lzma.Sdk.MatchFinder, Lzma.Sdk,
  Lzma.Encoder, Lzma.Decoder;

var Checks,Rows,HashRows,HandleCases,MemoryCases:UInt64;CaseIndex,Position:UInt32;Log:TStringList;

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
var V,T:TFileStream;Cases,CaseNo,ExpectedRows,Plans,PlanNo,Bits,L,Capacity,Dictionary,Nb,Fb,Cut,Mt,Window,Bt,HashBits,Hist,Allocated,Active:UInt32;Hint:UInt64;Plan:TLzmaSdkHashPlan26;
    Data,Operations,Buffer:TBytes;Finder:TLzmaSdkBinaryTreeMatchFinder;Pairs,Again:TLzmaMatchBuffer;
    ExpectedCount,Len,Dist,I,Offset,Used,Drop,Base,History,Available:UInt32;TraceRows:UInt64;
begin
  V:=TFileStream.Create(VectorPath,fmOpenRead or fmShareDenyWrite);
  T:=TFileStream.Create(TracePath,fmOpenRead or fmShareDenyWrite);
  try
    Check((Read32(V)=$5648424C) and (Read32(V)=2),'Vector header');Plans:=Read32(V);Cases:=Read32(V);ExpectedRows:=Read32(V);
    Check(Read32(T)=$4F48424C,'Oracle header');Bits:=Read32(T);Check(Bits in [32,64],'Oracle platform');
    Check((Read32(T)=Plans) and (Read32(T)=Cases) and (Read32(T)=ExpectedRows),'Oracle coverage header');TraceRows:=0;
    for PlanNo:=0 to Plans-1 do
    begin
      Hist:=Read32(V);Nb:=Read32(V);HashBits:=Read32(V);V.ReadBuffer(Hint,SizeOf(Hint));
      Plan:=TLzmaSdkMatchFinder.HashPlanFor(Hist,Nb,HashBits,Hint);Allocated:=Read32(T);Active:=Read32(T);
      Check((Plan.AllocatedMask=Allocated) and (Plan.ActiveMask=Active),'Original C allocation/active hash masks');Inc(HashRows);
    end;
    for CaseNo:=0 to Cases-1 do
    begin
      CaseIndex:=CaseNo;
      L:=Read32(V);Capacity:=Read32(V);Dictionary:=Read32(V);Nb:=Read32(V);Fb:=Read32(V);Cut:=Read32(V);Mt:=Read32(V);Window:=Read32(V);Bt:=Read32(V);HashBits:=Read32(V);V.ReadBuffer(Hint,SizeOf(Hint));
      SetLength(Data,L);SetLength(Operations,L);
      if L<>0 then begin V.ReadBuffer(Data[0],L);V.ReadBuffer(Operations[0],L);end;
      SetLength(Buffer,Capacity);Used:=Min(L,Capacity);Base:=0;
      if Used<>0 then Move(Data[0],Buffer[0],Used);
      Check(Read32(T)=CaseIndex,'Oracle case index');History:=Min(Dictionary,Capacity);
      if (Window and 2)<>0 then History:=Dictionary;
      Plan:=TLzmaSdkMatchFinder.HashPlanFor(History,Nb,HashBits,Hint);Check(Read32(T)=Plan.ActiveMask,'SDK hash mask');
      Finder:=TLzmaSdkBinaryTreeMatchFinder.Create(Buffer,0,Capacity,Dictionary,Nb,Fb,Cut,Mt<>0,Bt<>0,HashBits,Hint,(Window and 2)<>0);
      try
        Finder.SetInputCount(Used);Position:=0;
        while Position<L do
        begin
          Offset:=Position-Base;
          if (Base+Used<L) and (Used-Offset<Fb) then
          begin
            Check(((Window and 1)=1) and (Offset>History),'Window cannot advance');Drop:=Offset-History;
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

procedure HashCodecContracts;
const Widths:array[0..3] of UInt32=(1,20,32,256);
var Data,Properties,Encoded:TBytes;Input:TBytesStream;Archive,Decoded:TMemoryStream;
    InApi:ILzmaSeqInStream;OutApi:ILzmaSeqOutStream;Encoder:TLzmaSdkLzmaEncoder;
    Full:TLzmaSdkLzmaEncProps26;Legacy:TLzmaSdkLzmaEncProps;
    Kind:TLzmaMatchFinderKind;P:TLzmaEncoderProfile;Props:TLzmaProps;
    Threads,W,HIndex,I:Integer;Hint,Decisions,Budget:UInt64;Actual:Integer;
  procedure Roundtrip;
  begin
    Check(Encoder.WriteProperties(Properties)=SZ_OK,'Hash/hint property bytes');
    Archive.Position:=0;Decoded.Size:=0;
    TLzmaRawDecoder.Decode(Archive,Decoded,Properties,Length(Data));
    Check((Input.Position=Length(Data)) and (Decoded.Size=Length(Data)) and
      CompareMem(Decoded.Memory,Pointer(Data),Length(Data)),'Expected size hint truncated/corrupted input');
    SetLength(Encoded,NativeInt(Archive.Size));Move(Archive.Memory^,Encoded[0],Length(Encoded));
    Log.Add(Format('hashHandle=%u kind=%d bits=%u hint=%u bytes=%d archiveSHA=%s',
      [HandleCases,Ord(Kind),Full.NumHashOutBits,Hint,Length(Encoded),Sha256(Encoded)]));
  end;
begin
  SetLength(Data,65537);
  for I:=0 to High(Data) do Data[I]:=Byte((I div 11+I mod 13) and $FF);
  Input:=TBytesStream.Create(Data);Archive:=TMemoryStream.Create;Decoded:=TMemoryStream.Create;
  Encoder:=TLzmaSdkLzmaEncoder.Create;InApi:=TLzmaSdkSeqInStream.Create(Input);OutApi:=TLzmaSdkSeqOutStream.Create(Archive);
  try
    for Kind in [mfBinaryTree2,mfBinaryTree3,mfBinaryTree4,mfBinaryTree5,mfHashChain4,mfHashChain5] do
      for Threads:=1 to 2 do for W:=0 to High(Widths) do for HIndex:=0 to 1 do
      begin
        if HIndex=0 then Hint:=0 else Hint:=High(UInt64);
        Full:=TLzmaSdkLzmaEncProps26.Init;Full.DictSize:=65536;Full.Fb:=32;Full.Algo:=1;
        Full.BtMode:=Ord(Kind in [mfBinaryTree2,mfBinaryTree3,mfBinaryTree4,mfBinaryTree5]);
        Full.NumHashBytes:=4;
        case Kind of mfBinaryTree2:Full.NumHashBytes:=2;mfBinaryTree3:Full.NumHashBytes:=3;
          mfBinaryTree5,mfHashChain5:Full.NumHashBytes:=5;end;
        Full.NumHashOutBits:=Widths[W];Full.NumThreads:=Threads;Encoder.SetDataSize(Hint);
        Check(Encoder.SetProps(Full)=SZ_OK,'Custom hash/hint full setter');
        Input.Position:=0;Archive.Size:=0;
        Check(Encoder.Encode(InApi,OutApi)=SZ_OK,'Custom hash/hint handle encode');
        Inc(HandleCases);Roundtrip;
      end;
    // Expected-size planning survives later legacy/full SetProps calls, and a
    // zero hint must still consume the entire stream.
    Hint:=0;Encoder.SetDataSize(Hint);Kind:=mfBinaryTree4;
    Legacy:=TLzmaSdkLzmaEncProps.Init;Legacy.DictSize:=65536;Legacy.Fb:=32;Legacy.NumThreads:=2;
    for I:=0 to 1 do
    begin
      Check(Encoder.SetProps(Legacy)=SZ_OK,'Legacy setter after SetDataSize');Input.Position:=0;Archive.Size:=0;
      Check(Encoder.Encode(InApi,OutApi)=SZ_OK,'Legacy expected-size encode');Inc(HandleCases);Roundtrip;
      Legacy.Fb:=64;
    end;
    // The SDK settings route has its own estimator at every initial/growth/
    // shrink admission. Test both serial and concurrent use of that budget.
    P:=TLzmaRawEncoder.NormalizeProfile(5,65536);Props:=TLzmaRawEncoder.DefaultProperties(65536);
    for Threads:=1 to 2 do
    begin
      Budget:=TLzmaRawEncoder.RequiredSdkMemoryForInputWithThreads(P,Props,Length(Data),4096,Threads,32,0);
      Input.Position:=0;Archive.Size:=0;
      TLzmaRawEncoder.EncodeWithSdkSettings(Input,Archive,P,Props,False,4096,Budget,Threads,32,0,Decisions,Actual);
      Check((Actual=Threads) and (Input.Position=Length(Data)),'SDK-settings admission/actual stages');Inc(MemoryCases);
      Input.Position:=0;Archive.Size:=0;
      try
        TLzmaRawEncoder.EncodeWithSdkSettings(Input,Archive,P,Props,False,4096,1,Threads,32,0,Decisions,Actual);
        Check(False,'SDK-settings finite memory limit was ignored');
      except on E:ELzmaMemoryError do Check(Input.Position=0,'Memory rejection happened after input consumption');end;
      Inc(MemoryCases);
    end;
  finally OutApi:=nil;InApi:=nil;Encoder.Free;Decoded.Free;Archive.Free;Input.Free;end;
end;

var FinderOnly:Boolean;HandlesBefore,HandlesAfter:DWORD;Warm:TThread;
begin
  Log:=TStringList.Create;
  try
    try
      FinderOnly:=(ParamCount=5) and (ParamStr(5)='--finder-only');
      if (ParamCount<>4) and not FinderOnly then raise Exception.Create('Vectors, C32 trace, C64 trace, log; optional --finder-only development precheck');
      if not FinderOnly then
      begin Warm:=TThread.CreateAnonymousThread(procedure begin end);Warm.FreeOnTerminate:=False;Warm.Start;Warm.WaitFor;Warm.Free;end;
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesBefore),'Initial handles');
      CompareTrace(ParamStr(1),ParamStr(2));CompareTrace(ParamStr(1),ParamStr(3));
      if not FinderOnly then begin CodecHandles;HashCodecContracts;end;
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesAfter),'Final handles');
      Check(HandlesBefore=HandlesAfter,'Finder/handle lifecycle leak');
      Log.Add(Format('rows=%u hashRows=%u checks=%u failures=0 nativeBits=%d finderOnly=%d codecHandleTests=%u memoryCases=%u handlesBefore=%d handlesAfter=%d',
        [Rows,HashRows,Checks,SizeOf(NativeUInt)*8,Ord(FinderOnly),HandleCases,MemoryCases,HandlesBefore,HandlesAfter]));
      Log.SaveToFile(ParamStr(4),TEncoding.UTF8);Writeln(Log[Log.Count-1]);
    except on E:Exception do
      begin Log.Add(E.ClassName+': '+E.Message);if ParamCount>=4 then Log.SaveToFile(ParamStr(4),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;end;
    end;
  finally Log.Free;end;
end.
