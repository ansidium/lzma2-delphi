program Lzma2MtCodecQA;
{$APPTYPE CONSOLE}
{$R Lzma2GUIManifest.res}
{$IFNDEF LZMA_MT_QA}{$MESSAGE FATAL 'LZMA_MT_QA required for the independent serial MT-hash reference'}{$ENDIF}

uses System.SysUtils, System.Classes, System.Math, System.Hash,
  Winapi.Windows, Winapi.TlHelp32, Lzma.Types, Lzma.Errors, Lzma.Alloc,
  Lzma.MatchFinder, Lzma.MtMatchFinder, Lzma.Encoder, Lzma.Decoder,
  Lzma.Api, Lzma.Sdk, Lzma2GuiResources;

type
  TInjectedProgressError=class(Exception);
  TInput=class(TBytesStream)
  public
    Fragment:Integer;
    FailAfter:Int64;
    TotalRead:UInt64;
    NoSeek:Boolean;
    constructor Create(const Data:TBytes);
    function Read(var Buffer;Count:Longint):Longint;override;
    function Seek(const Offset:Int64;Origin:TSeekOrigin):Int64;override;
  end;
  TFailingOutput=class(TMemoryStream)
  public
    function Write(const Buffer;Count:Longint):Longint;override;
{$IF SizeOf(Longint)<>SizeOf(NativeInt)}
    function Write(const Buffer;Count:NativeInt):NativeInt;overload;override;
{$ENDIF}
  end;

var Checks,Cases,Callbacks:Integer;MainThreadId:Cardinal;
    BaselineThreadIds:TArray<Cardinal>;BaselineThreadHandles:TArray<THandle>;
    SeenProducer:Boolean;Log:TStringList;

function OpenBaselineThread(Access:DWORD;Inherit:BOOL;Id:DWORD):THandle;stdcall;
  external 'kernel32.dll' name 'OpenThread';

procedure Check(Condition:Boolean;const Detail:string);
begin Inc(Checks);if not Condition then raise Exception.Create(Detail);end;

function ProcessThreadIds:TArray<Cardinal>;
var Snapshot:THandle;Entry:TThreadEntry32;
begin
  Result:=nil;Snapshot:=CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD,0);
  if Snapshot=INVALID_HANDLE_VALUE then RaiseLastOSError;
  try
    Entry.dwSize:=SizeOf(Entry);
    if Thread32First(Snapshot,Entry) then
      repeat
        if Entry.th32OwnerProcessID=GetCurrentProcessId then
        begin SetLength(Result,Length(Result)+1);Result[High(Result)]:=Entry.th32ThreadID;end;
      until not Thread32Next(Snapshot,Entry);
  finally CloseHandle(Snapshot);end;
end;

function ThreadCount:Integer;
begin Result:=Length(ProcessThreadIds);end;

procedure CaptureBaselineThreads;
var Id:Cardinal;Handle:THandle;Error:DWORD;
begin
  for Id in ProcessThreadIds do
  begin
    Handle:=OpenBaselineThread(SYNCHRONIZE,False,Id);
    if Handle=0 then
    begin
      Error:=GetLastError;
      if Error=ERROR_INVALID_PARAMETER then Continue;
      RaiseLastOSError(Error);
    end;
    try
      SetLength(BaselineThreadIds,Length(BaselineThreadIds)+1);
      SetLength(BaselineThreadHandles,Length(BaselineThreadHandles)+1);
      BaselineThreadIds[High(BaselineThreadIds)]:=Id;
      BaselineThreadHandles[High(BaselineThreadHandles)]:=Handle;
    except CloseHandle(Handle);raise;end;
  end;
  Check(Length(BaselineThreadIds)>0,'No baseline process threads captured');
end;

procedure ReleaseBaselineThreads;
var Handle:THandle;
begin
  for Handle in BaselineThreadHandles do CloseHandle(Handle);
  BaselineThreadHandles:=nil;BaselineThreadIds:=nil;
end;

function NewThreadIds:TArray<Cardinal>;
var Id:Cardinal;I:Integer;Known:Boolean;State:DWORD;
begin
  Result:=nil;
  for Id in ProcessThreadIds do
  begin
    Known:=False;
    for I:=0 to High(BaselineThreadIds) do
      if Id=BaselineThreadIds[I] then
      begin
        State:=WaitForSingleObject(BaselineThreadHandles[I],0);
        if State=WAIT_FAILED then RaiseLastOSError;
        Known:=State=WAIT_TIMEOUT;
        Break;
      end;
    if not Known then
    begin SetLength(Result,Length(Result)+1);Result[High(Result)]:=Id;end;
  end;
end;

function ThreadIdsText(const Ids:TArray<Cardinal>):string;
var Id:Cardinal;
begin
  Result:='';
  for Id in Ids do
  begin if Result<>'' then Result:=Result+',';Result:=Result+UIntToStr(Id);end;
end;

procedure CallerProgress(const InputBytes,OutputBytes:UInt64;var Cancel:Boolean);
begin
  Inc(Callbacks);Check(GetCurrentThreadId=MainThreadId,'Progress moved onto producer thread');
  if not SeenProducer then SeenProducer:=Length(NewThreadIds)>0;
end;

constructor TInput.Create(const Data:TBytes);
begin inherited Create(Data);Fragment:=7919;FailAfter:=-1;end;

function TInput.Read(var Buffer;Count:Longint):Longint;
begin
  Check(GetCurrentThreadId=MainThreadId,'Input stream read moved onto producer thread');
  if (FailAfter>=0) and (TotalRead>=UInt64(FailAfter)) then
    RaiseLzmaError(SZ_ERROR_READ,'Injected input failure');
  Count:=Min(Count,Fragment);
  if (FailAfter>=0) and (UInt64(Count)>UInt64(FailAfter)-TotalRead) then
    Count:=Longint(UInt64(FailAfter)-TotalRead);
  Result:=inherited Read(Buffer,Count);Inc(TotalRead,UInt64(Result));
end;

function TInput.Seek(const Offset:Int64;Origin:TSeekOrigin):Int64;
begin
  if NoSeek then raise EStreamError.Create('Test input is not seekable');
  Result:=inherited Seek(Offset,Origin);
end;

function TFailingOutput.Write(const Buffer;Count:Longint):Longint;
begin Result:=0;RaiseLzmaError(SZ_ERROR_WRITE,'Injected output failure');end;
{$IF SizeOf(Longint)<>SizeOf(NativeInt)}
function TFailingOutput.Write(const Buffer;Count:NativeInt):NativeInt;
begin Result:=0;RaiseLzmaError(SZ_ERROR_WRITE,'Injected native output failure');end;
{$ENDIF}

function Data(const Size,Pattern:Integer):TBytes;
var I:Integer;Seed:UInt32;
begin
  SetLength(Result,Size);Seed:=$D0A95C31;
  for I:=0 to Size-1 do
  begin
    Seed:=Seed xor (Seed shl 13);Seed:=Seed xor (Seed shr 17);Seed:=Seed xor (Seed shl 5);
    case Pattern of
      0:Result[I]:=Byte(Seed and 255);
      1:Result[I]:=Byte(I mod 31);
      2:if (I>=65521) and ((I mod 251)<233) then Result[I]:=Result[I-65521]
        else Result[I]:=Byte(Seed and 63);
    end;
  end;
end;

function Profile(const Level:TLzma2CompressionLevel;const FastBytes:Integer):TLzmaEncoderProfile;
begin
  Result:=TLzmaRawEncoder.NormalizeProfile(Level,65536);
  Result.FastBytes:=FastBytes;
end;

function Sha256(const Bytes:TBytes):string;
var Hash:THashSHA2;
begin
  Hash:=THashSHA2.Create;Hash.Update(Bytes);Result:=Hash.HashAsString;
end;

procedure IdleThreads;
var Deadline:UInt64;Extra:TArray<Cardinal>;
begin
  Deadline:=GetTickCount64+2000;
  Extra:=NewThreadIds;
  while (Length(Extra)>0) and (GetTickCount64<Deadline) do
  begin Sleep(1);Extra:=NewThreadIds;end;
  // Windows may retire its original pool threads while this test runs.
  // Accept only surviving original thread objects, never a new worker that
  // merely replaces a retired thread in the aggregate process thread count.
  Check(Length(Extra)=0,'Unexpected threads after encoder return: '+ThreadIdsText(Extra));
end;

procedure RawCase(const Bytes:TBytes;const FastBytes:Integer;const BufferSize:NativeUInt;
  const EndMark:Boolean;const LiteralCase:Integer=0;
  const FinderKind:TLzmaMatchFinderKind=mfBinaryTree4);
var A,B:TInput;Reference,Encoded,Decoded:TMemoryStream;P:TLzmaEncoderProfile;
    Props:TLzmaProps;PropsBytes,EncodedBytes:TBytes;D1,D2,Required:UInt64;Actual:Integer;
begin
  P:=Profile(5,FastBytes);P.MatchFinderKind:=FinderKind;
  Props:=TLzmaRawEncoder.DefaultProperties(P.DictionarySize);
  case LiteralCase of
    1:begin Props.Lc:=0;Props.Lp:=4;Props.Pb:=4;end;
    2:begin Props.Lc:=8;Props.Lp:=0;Props.Pb:=0;end;
  end;
  A:=TInput.Create(Bytes);B:=TInput.Create(Bytes);
  Reference:=TMemoryStream.Create;Encoded:=TMemoryStream.Create;Decoded:=TMemoryStream.Create;
  try
    A.Fragment:=97;B.Fragment:=4093;
    TLzmaRawEncoder.EncodeMtReference(A,Reference,P,Props,EndMark,BufferSize,0,D1);
    Required:=TLzmaRawEncoder.RequiredStreamingMemoryForInputWithThreads(P,Props,Length(Bytes),BufferSize,2);
    SeenProducer:=False;
    TLzmaRawEncoder.EncodeWithThreads(B,Encoded,P,Props,EndMark,BufferSize,Required,2,D2,Actual,CallerProgress);
    Check(Actual=2,'Normal BT LZMA did not report its actual two stages');
    Check(SeenProducer,'No live producer was visible during MT progress');
    Check((A.TotalRead=UInt64(Length(Bytes))) and (B.TotalRead=A.TotalRead),'Input coverage differs');
    Check((Reference.Size=Encoded.Size) and CompareMem(Reference.Memory,Encoded.Memory,NativeInt(Encoded.Size)),
      'Concurrent LZMA differs from serial SDK-MT-hash reference');
    Check(D1=D2,'Scheduling changed optimum decisions');
    PropsBytes:=TLzmaRawEncoder.WriteProperties(Props);Encoded.Position:=0;
    if EndMark then TLzmaRawDecoder.DecodeUntilEndMarker(Encoded,Decoded,PropsBytes)
    else TLzmaRawDecoder.Decode(Encoded,Decoded,PropsBytes,Length(Bytes));
    Check((Decoded.Size=Length(Bytes)) and CompareMem(Decoded.Memory,Pointer(Bytes),Length(Bytes)),'Raw MT roundtrip differs');
    SetLength(EncodedBytes,NativeInt(Encoded.Size));
    if Encoded.Size<>0 then Move(Encoded.Memory^,EncodedBytes[0],NativeInt(Encoded.Size));
    Inc(Cases);
    Log.Add(Format('case=%d input=%d fb=%d buffer=%d end=%d literals=%d finder=%d decisions=%u inputSHA=%s archiveSHA=%s',
      [Cases,Length(Bytes),FastBytes,BufferSize,Ord(EndMark),LiteralCase,Ord(FinderKind),D2,
       Sha256(Bytes),Sha256(EncodedBytes)]));
  finally Decoded.Free;Encoded.Free;Reference.Free;B.Free;A.Free;end;
  IdleThreads;
end;

procedure ModesAndGui;
var P:TLzmaEncoderProfile;Kind:TLzmaMatchFinderKind;Mode:TLzmaParserMode;
    Level:TLzma2CompressionLevel;Requested,Expected:Integer;Options:TLzma2Options;
begin
  for Level:=Low(TLzma2CompressionLevel) to High(TLzma2CompressionLevel) do
    for Kind in [mfHashChain4,mfHashChain5,mfBinaryTree4,mfBinaryTree2,mfBinaryTree3,mfBinaryTree5] do
      for Mode in [lpmFast,lpmHighSpeed,lpmSdkProfile] do
        for Requested in [1,2,3,High(Integer)] do
        begin
          P:=Profile(Level,32);P.MatchFinderKind:=Kind;P.ParserMode:=Mode;Expected:=1;
          if (Requested>1) and (P.Algorithm<>0) and
            (Kind in [mfBinaryTree2,mfBinaryTree3,mfBinaryTree4,mfBinaryTree5]) and
            (Mode=lpmSdkProfile) then Expected:=2;
          Check(TLzmaRawEncoder.ResolveThreadCount(P,Requested)=Expected,'SDK normal/fast/BT/HC mode dispatch');
        end;
  P:=Profile(5,32);
  try TLzmaRawEncoder.ResolveThreadCount(P,0);Check(False,'Zero raw thread count accepted');
  except on E:ELzmaInvalidParameter do Inc(Checks);end;
  Options:=TLzma2.StandaloneLzmaOptions(5);Options.DictionarySize:=65536;
  Check(AutoThreadCount(Options,High(UInt64),1)=1,'Auto must respect single-CPU affinity');
  Check(AutoThreadCount(Options,High(UInt64),64)=2,'Auto must select normal BT MT when resources allow');
  Check(AutoThreadCount(Options,1,64)=1,'Auto must respect memory admission');
  Options.MatchFinderProfile:=lmfpHashChain5;
  Check(AutoThreadCount(Options,High(UInt64),64)=1,'Hash-chain Auto must remain serial');
  Options:=TLzma2.StandaloneLzmaOptions(1);
  Check(AutoThreadCount(Options,High(UInt64),64)=1,'Fast Auto must remain serial');
end;

procedure PublicDispatch(const Bytes:TBytes;const NoSeek:Boolean);
var A:TInput;Archive,Decoded,Raw:TMemoryStream;Options:TLzma2Options;Diag:TLzma2EncodeDiagnostics;
    Encoder:TLzmaSdkLzmaEncoder;Settings:TLzmaSdkLzmaEncProps;InApi:ILzmaSeqInStream;OutApi:ILzmaSeqOutStream;
    RefInput:TInput;P:TLzmaEncoderProfile;Props:TLzmaProps;Decisions:UInt64;
begin
  A:=TInput.Create(Bytes);A.NoSeek:=NoSeek;Archive:=TMemoryStream.Create;
  Decoded:=TMemoryStream.Create;Raw:=TMemoryStream.Create;RefInput:=TInput.Create(Bytes);Encoder:=nil;
  try
    Options:=TLzma2.StandaloneLzmaOptions(5);Options.DictionarySize:=65536;Options.ThreadCount:=2;
    Options.FastBytes:=32;Options.EncodeDiagnostics:=@Diag;Options.MemoryLimit:=256 shl 20;Options.BufferSize:=4096;
    TLzma2.Compress(A,Archive,Options,CallerProgress);
    Check((Diag.RequestedThreadCount=2) and (Diag.ActualThreadCount=2),'Standalone MT diagnostics');
    Archive.Position:=0;TLzma2.Decompress(Archive,Decoded,Options);
    Check((Decoded.Size=Length(Bytes)) and CompareMem(Decoded.Memory,Pointer(Bytes),Length(Bytes)),'Standalone MT roundtrip');
    P:=Profile(5,32);Props:=TLzmaRawEncoder.DefaultProperties(P.DictionarySize);
    TLzmaRawEncoder.EncodeMtReference(RefInput,Raw,P,Props,False,4096,0,Decisions);
    Check((Archive.Size=Raw.Size+13) and CompareMem(PByte(Archive.Memory)+13,Raw.Memory,NativeInt(Raw.Size)),'Standalone did not use actual MT payload');
    Archive.Size:=0;Archive.Position:=0;FreeAndNil(A);A:=TInput.Create(Bytes);A.NoSeek:=NoSeek;
    Encoder:=TLzmaSdkLzmaEncoder.Create;Settings:=TLzmaSdkLzmaEncProps.Init;
    Settings.Level:=5;Settings.DictSize:=65536;Settings.Fb:=32;Settings.NumThreads:=2;
    Check(Encoder.SetProps(Settings)=SZ_OK,'SDK SetProps');
    InApi:=TLzmaSdkSeqInStream.Create(A);OutApi:=TLzmaSdkSeqOutStream.Create(Archive);
    Check(Encoder.Encode(InApi,OutApi)=SZ_OK,'SDK facade MT encode');
    Check((Archive.Size=Raw.Size) and CompareMem(Archive.Memory,Raw.Memory,NativeInt(Raw.Size)),'SDK facade ignored NumThreads MT mode');
  finally InApi:=nil;OutApi:=nil;Encoder.Free;RefInput.Free;Raw.Free;Decoded.Free;Archive.Free;A.Free;end;
  IdleThreads;
end;

procedure Failures(const Bytes:TBytes);
var P:TLzmaEncoderProfile;Props:TLzmaProps;Input:TInput;Output:TMemoryStream;
    Decisions,Budget:UInt64;Actual,I,Kind:Integer;
begin
  P:=Profile(5,32);Props:=TLzmaRawEncoder.DefaultProperties(P.DictionarySize);
  Budget:=TLzmaMatchFinderPipeline.RequiredMemory;
  Input:=TInput.Create(Bytes);Output:=TMemoryStream.Create;
  try
    try TLzmaRawEncoder.EncodeWithThreads(Input,Output,P,Props,True,4096,Budget,2,Decisions,Actual);
      Check(False,'Zero remaining kernel budget became unlimited');
    except on E:ELzmaMemoryError do Inc(Checks);end;
    Check((Input.TotalRead=0) and (Output.Size=0),'Thread reservation did not reject before I/O');
  finally Output.Free;Input.Free;end;
  Budget:=TLzmaRawEncoder.RequiredStreamingMemoryForInputWithThreads(P,Props,Length(Bytes),4096,2);
  Input:=TInput.Create(Bytes);Output:=TMemoryStream.Create;
  try
    try TLzmaRawEncoder.EncodeWithThreads(Input,Output,P,Props,True,4096,Budget-1,2,Decisions,Actual);
      Check(False,'Insufficient combined kernel/thread budget accepted');
    except on E:ELzmaMemoryError do Inc(Checks);end;
    Check(Output.Size=0,'Memory rejection wrote a partial archive');
  finally Output.Free;Input.Free;end;
  for I:=1 to 12 do
    for Kind:=0 to 3 do
    begin
      Input:=TInput.Create(Bytes);
      if Kind=1 then Output:=TFailingOutput.Create else Output:=TMemoryStream.Create;
      try
        if Kind=0 then Input.FailAfter:=131072;
        try
          TLzmaRawEncoder.EncodeWithThreads(Input,Output,P,Props,True,4096,256 shl 20,2,Decisions,Actual,
            procedure(const InSize,OutSize:UInt64;var Cancel:Boolean)
            begin
              CallerProgress(InSize,OutSize,Cancel);
              if InSize>=65536 then
                case Kind of
                  2:Cancel:=True;
                  3:raise TInjectedProgressError.Create('Injected callback exception');
                end;
            end);
          Check(False,'Injected MT failure was lost');
        except
          on E:ELzmaReadError do Check(Kind=0,'Wrong read failure');
          on E:ELzmaWriteError do Check(Kind=1,'Wrong write failure');
          on E:ELzmaCancelled do Check(Kind=2,'Wrong cancellation failure');
          on E:TInjectedProgressError do Check(Kind=3,'Wrong progress failure');
        end;
      finally Output.Free;Input.Free;end;
      IdleThreads;
    end;
end;

var Pattern,Size,Fb:Integer;EndMark:Boolean;Bytes:TBytes;FinderKind:TLzmaMatchFinderKind;
    HandlesBefore,HandlesAfter:DWORD;Warm:TThread;
begin
  Log:=TStringList.Create;
  try
    try
      if ParamCount<>1 then raise Exception.Create('Output log path required');
      MainThreadId:=GetCurrentThreadId;
      Warm:=TThread.CreateAnonymousThread(procedure begin end);
      Warm.FreeOnTerminate:=False;Warm.Start;Warm.WaitFor;Warm.Free;
      CaptureBaselineThreads;
      Log.Add('threadTracking=identity baselineThreadIds='+ThreadIdsText(BaselineThreadIds));
      RawCase(Data(257,1),32,4096,True);
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesBefore),'Initial handle query');
      ModesAndGui;
      for Pattern:=0 to 2 do
        for Size in [0,1,63,273,4097,65537] do
          for Fb in [5,32,64,273] do
            for EndMark:=False to True do RawCase(Data(Size,Pattern),Fb,4096,EndMark);
      for Pattern:=0 to 2 do
        for Fb in [32,273] do
        begin
          Bytes:=Data(3*1024*1024+273,Pattern);
          if Pattern=1 then RawCase(Bytes,Fb,65536,Fb=273)
          else RawCase(Bytes,Fb,4096,Fb=273);
        end;
      RawCase(Data(4097,2),64,4096,True,1);
      RawCase(Data(4097,2),64,4096,True,2);
      for FinderKind in [mfBinaryTree2,mfBinaryTree3,mfBinaryTree5] do
        for Pattern:=0 to 2 do for Fb in [5,64] do for EndMark:=False to True do
          RawCase(Data(262145,Pattern),Fb,4096,EndMark,0,FinderKind);
      Bytes:=Data(262145,2);PublicDispatch(Bytes,False);PublicDispatch(Bytes,True);
      Bytes:=Data(3*1024*1024+273,0);Failures(Bytes);Bytes:=nil;
      IdleThreads;Check(GetProcessHandleCount(GetCurrentProcess,HandlesAfter),'Final handle query');
      Check(HandlesAfter=HandlesBefore,'Repeated MT lifecycle leaked handles');
      Log.Add(Format('cases=%d checks=%d callbacks=%d failures=0 nativeBits=%d handlesBefore=%d handlesAfter=%d threadsAfter=%d',
        [Cases,Checks,Callbacks,SizeOf(NativeUInt)*8,HandlesBefore,HandlesAfter,ThreadCount]));
      Log.SaveToFile(ParamStr(1),TEncoding.UTF8);Writeln(Log[Log.Count-1]);
    except on E:Exception do
      begin Log.Add(E.ClassName+': '+E.Message);if ParamCount=1 then Log.SaveToFile(ParamStr(1),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;end;
    end;
  finally ReleaseBaselineThreads;Log.Free;end;
end.
