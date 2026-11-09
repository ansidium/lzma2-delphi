program Lzma2SdkPropsQA;
{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.Math, Winapi.Windows,
  Lzma.Types, Lzma.Sdk, Lzma.Sdk.Properties, Lzma.Encoder, Lzma.Decoder, Lzma.MatchFinder;

type
  TReader = record
    Data:TBytes; Position:NativeInt;
    procedure Load(const Path:string);
    procedure Read(var Buffer;const Count:NativeInt);
    function Read32:UInt32;
    function Read64:UInt64;
    function ReadByte:Byte;
    procedure Compare(const Buffer;const Count:NativeInt;const Detail:string);
  end;
  TWriter = class(TInterfacedObject,ILzmaSeqOutStream)
  public
    Stream:TMemoryStream; MaxWrite:SizeT; ReturnCode:SRes;
    constructor Create;
    destructor Destroy;override;
    function Write(const Buffer;const Count:SizeT;out ProcessedSize:SizeT):SRes;
  end;
  TProgress = class(TInterfacedObject,ILzmaCompressProgress)
  public function Progress(const InSize,OutSize:UInt64):SRes;end;

var Checks,RowsCompared:UInt64;Row:UInt32;TraceVariant:string;Log:TStringList;

procedure Check(Condition:Boolean;const Detail:string);
begin
  Inc(Checks);
  if not Condition then raise Exception.CreateFmt('variant=%s row=%u %s',[TraceVariant,Row,Detail]);
end;

procedure TReader.Load(const Path:string);
var Stream:TFileStream;
begin
  Stream:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
  try
    Check((Stream.Size>=8) and (UInt64(Stream.Size)<=UInt64(High(NativeInt))),'Trace/vector size');
    SetLength(Data,NativeInt(Stream.Size));Stream.ReadBuffer(Data[0],Length(Data));Position:=0;
  finally Stream.Free;end;
end;

procedure TReader.Read(var Buffer;const Count:NativeInt);
begin
  if (Count<0) or (Position>Length(Data)) or (Count>Length(Data)-Position) then
    raise EReadError.Create('Truncated fixed properties protocol');
  if Count<>0 then Move(Data[Position],Buffer,Count);Inc(Position,Count);
end;
function TReader.Read32:UInt32;
begin Read(Result,SizeOf(Result));end;
function TReader.Read64:UInt64;
begin Read(Result,SizeOf(Result));end;
function TReader.ReadByte:Byte;
begin Read(Result,SizeOf(Result));end;
procedure TReader.Compare(const Buffer;const Count:NativeInt;const Detail:string);
begin
  if (Count<0) or (Count>Length(Data)-Position) then raise EReadError.Create('Truncated SDK comparison');
  Check(CompareMem(@Buffer,@Data[Position],Count),Detail);Inc(Position,Count);
end;

constructor TWriter.Create;
begin inherited;Stream:=TMemoryStream.Create;MaxWrite:=High(SizeT);end;
destructor TWriter.Destroy;
begin Stream.Free;inherited;end;
function TWriter.Write(const Buffer;const Count:SizeT;out ProcessedSize:SizeT):SRes;
begin
  ProcessedSize:=0;Result:=ReturnCode;if Result<>SZ_OK then Exit;
  ProcessedSize:=Min(Count,MaxWrite);
  if ProcessedSize<>0 then Stream.WriteBuffer(Buffer,NativeInt(ProcessedSize));
end;
function TProgress.Progress(const InSize,OutSize:UInt64):SRes;
begin Result:=42;end;

procedure Layout(var Expected:TReader);
var A:TLzmaSdkLzmaEncProps26;B:TLzmaSdkLzma2EncProps26;Offsets:array[0..22] of NativeUInt;
    Base:NativeUInt;I:Integer;
begin
  Check(Expected.Read32=SizeOf(A),'CLzmaEncProps size');
  Check(Expected.Read32=SizeOf(B),'CLzma2EncProps size');
  Check(Expected.Read32=UInt32(Length(Offsets)),'SDK field offset count');
  Base:=NativeUInt(@A);
  Offsets[0]:=NativeUInt(@A.Level)-Base;Offsets[1]:=NativeUInt(@A.DictSize)-Base;
  Offsets[2]:=NativeUInt(@A.Lc)-Base;Offsets[3]:=NativeUInt(@A.Lp)-Base;Offsets[4]:=NativeUInt(@A.Pb)-Base;
  Offsets[5]:=NativeUInt(@A.Algo)-Base;Offsets[6]:=NativeUInt(@A.Fb)-Base;Offsets[7]:=NativeUInt(@A.BtMode)-Base;
  Offsets[8]:=NativeUInt(@A.NumHashBytes)-Base;Offsets[9]:=NativeUInt(@A.NumHashOutBits)-Base;
  Offsets[10]:=NativeUInt(@A.Mc)-Base;Offsets[11]:=NativeUInt(@A.WriteEndMark)-Base;
  Offsets[12]:=NativeUInt(@A.NumThreads)-Base;Offsets[13]:=NativeUInt(@A.AffinityGroup)-Base;
  Offsets[14]:=NativeUInt(@A.ReduceSize)-Base;Offsets[15]:=NativeUInt(@A.Affinity)-Base;
  Offsets[16]:=NativeUInt(@A.AffinityInGroup)-Base;
  Base:=NativeUInt(@B);Offsets[17]:=NativeUInt(@B.LzmaProps)-Base;Offsets[18]:=NativeUInt(@B.BlockSize)-Base;
  Offsets[19]:=NativeUInt(@B.NumBlockThreadsReduced)-Base;Offsets[20]:=NativeUInt(@B.NumBlockThreadsMax)-Base;
  Offsets[21]:=NativeUInt(@B.NumTotalThreads)-Base;Offsets[22]:=NativeUInt(@B.NumThreadGroups)-Base;
  for I:=0 to High(Offsets) do Check(Expected.Read32=Offsets[I],'SDK field layout');
  A:=TLzmaSdkLzmaEncProps26.Init;B:=TLzmaSdkLzma2EncProps26.Init;
  Expected.Compare(A,SizeOf(A),'LzmaEncProps_Init');Expected.Compare(B,SizeOf(B),'Lzma2EncProps_Init');
  Check(SizeOf(TLzmaSdkLzmaEncProps)=48,'Legacy LZMA record ABI changed');
  Check(SizeOf(TLzmaSdkLzma2EncProps)=64,'Legacy LZMA2 record ABI changed');
end;

procedure Trace(const Vectors,ExpectedPath:string;const SingleThreadBuild:Boolean);
var Input,Expected:TReader;Count,Index,Capacity:UInt32;P,Original,Normal:TLzmaSdkLzmaEncProps26;
    P2:TLzmaSdkLzma2EncProps26;E:TLzmaSdkEffectiveLzmaProps26;ResultCode,WriteCode:SRes;
    Props:array[0..4] of Byte;Available:SizeT;Property2:Byte;
begin
  if SingleThreadBuild then TraceVariant:='Z7_ST' else TraceVariant:='MT';
  Input.Load(Vectors);Expected.Load(ExpectedPath);
  try
    Check(Input.Read32=$51363250,'Vector magic');Count:=Input.Read32;Check(Count>0,'Empty vectors');
    Check(Expected.Read32=$4f363250,'SDK trace magic');
    Check(Expected.Read32=SizeOf(NativeUInt)*8,'SDK trace native width');
    Check(Expected.Read32=UInt32(Ord(SingleThreadBuild)),'SDK compile variant');
    Check(Expected.Read32=Count,'SDK row count');
    Check(UInt64(Length(Input.Data))=8+UInt64(Count)*108,'Full input byte coverage');
    Check(UInt64(Length(Expected.Data))=304+UInt64(Count)*258,'Full output byte coverage');
    Layout(Expected);
    for Index:=0 to Count-1 do
    begin
      Row:=Index;
      Input.Read(P,SizeOf(P));Original:=P;P2.LzmaProps:=P;
      Input.Read(P2.BlockSize,8);Input.Read(P2.NumBlockThreadsReduced,4);
      Input.Read(P2.NumBlockThreadsMax,4);Input.Read(P2.NumTotalThreads,4);Input.Read(P2.NumThreadGroups,4);
      Capacity:=Input.Read32;
      Normal:=P;Normal.Normalize(SingleThreadBuild);P2.Normalize(SingleThreadBuild);
      Expected.Compare(Normal,SizeOf(Normal),'LzmaEncProps_Normalize');
      Expected.Compare(P2,SizeOf(P2),'Lzma2EncProps_Normalize');
      Check(Expected.Read32=P.GetDictionarySize(SingleThreadBuild),'LzmaEncProps_GetDictSize');
      ResultCode:=P.GetEffective(E,SingleThreadBuild);
      Check(Expected.Read32=UInt32(ResultCode),'LzmaEnc_SetProps result');
      Expected.Compare(E,SizeOf(E),'LzmaEnc_SetProps scalar state');
      FillChar(Props,SizeOf(Props),0);Available:=Capacity;WriteCode:=ResultCode;
      if ResultCode=SZ_OK then WriteCode:=P.WriteProperties(@Props[0],Available,SingleThreadBuild);
      Check(Expected.Read32=UInt32(WriteCode),'LzmaEnc_WriteProperties result');
      Check(Expected.Read64=Available,'LzmaEnc_WriteProperties size in/out');
      Expected.Compare(Props,SizeOf(Props),'LzmaEnc_WriteProperties bytes');
      Property2:=P2.WriteProperties(SingleThreadBuild);
      Check(Expected.ReadByte=Property2,'Lzma2Enc_WriteProperties');
      Check(CompareMem(@P,@Original,SizeOf(P)),'Property queries mutated caller record');
      Inc(RowsCompared);
    end;
    Check(Input.Position=Length(Input.Data),'Input tail');Check(Expected.Position=Length(Expected.Data),'SDK trace tail');
    Log.Add(Format('variant=%s rows=%u nativeBits=%d failures=0',[TraceVariant,Count,SizeOf(NativeUInt)*8]));
  finally Input.Data:=nil;Expected.Data:=nil;end;
end;

function Payload:TBytes;
var I:Integer;
begin SetLength(Result,262149);for I:=0 to High(Result) do Result[I]:=Byte((I*17+(I shr 7)*13) and 255);end;

procedure HandleContracts;
var Encoder:TLzmaSdkLzmaEncoder;Full,Bad:TLzmaSdkLzmaEncProps26;Old:TLzmaSdkLzmaEncProps;
    Input:TBytesStream;Sink:TWriter;Output:ILzmaSeqOutStream;InApi:ILzmaSeqInStream;Progress:ILzmaCompressProgress;
    Data,Props:TBytes;Decoded,Direct:TMemoryStream;DirectInput:TBytesStream;P:TLzmaEncoderProfile;
    Raw:TLzmaProps;Decisions:UInt64;Buffer:array[0..6] of Byte;Available:SizeT;I:Integer;
  function Encode(const Native:Boolean;const ShortWrite,ErrorCode:Integer;const WithProgress:Boolean):SRes;
  begin
    if Native then Check(Encoder.SetProps(Full)=SZ_OK,'Full SetProps')
    else Check(Encoder.SetProps(Old)=SZ_OK,'Legacy SetProps');
    Input.Position:=0;Sink.Stream.Size:=0;Sink.Stream.Position:=0;Sink.MaxWrite:=SizeT(ShortWrite);Sink.ReturnCode:=ErrorCode;
    if WithProgress then Progress:=TProgress.Create else Progress:=nil;
    Result:=Encoder.Encode(InApi,Output,Progress);Progress:=nil;
  end;
begin
  TraceVariant:='public-handle';Row:=0;Data:=Payload;Input:=TBytesStream.Create(Data);
  Encoder:=TLzmaSdkLzmaEncoder.Create;Sink:=TWriter.Create;Output:=Sink;InApi:=TLzmaSdkSeqInStream.Create(Input);
  Decoded:=TMemoryStream.Create;Direct:=TMemoryStream.Create;DirectInput:=TBytesStream.Create(Data);
  try
    Full:=TLzmaSdkLzmaEncProps26.Init;Full.DictSize:=1 shl 20;Full.ReduceSize:=8192;
    Full.Fb:=73;Full.Algo:=1;Full.BtMode:=0;Full.NumThreads:=1;
    Old:=TLzmaSdkLzmaEncProps.Init;Old.DictSize:=1 shl 20;Old.Fb:=73;Old.BtMode:=0;Old.NumThreads:=1;
    Check(Old.Normalize=SZ_OK,'Legacy normalize');Check(Old.Mc=32,'Legacy MC policy was silently changed');
    Bad:=Full;Bad.Normalize;Check((Bad.Mc=26) and (Bad.NumHashBytes=5),'SDK FB/BT dependent MC/hash defaults');
    Check(Encode(True,High(Integer),SZ_OK,False)=SZ_OK,'Native full-property encode');
    Check(Encoder.WriteProperties(Props)=SZ_OK,'Native properties query');
    Check((Length(Props)=5) and (ReadUi32LE(@Props[1])=8192),'ReduceSize did not affect real encoder dictionary');
    Sink.Stream.Position:=0;TLzmaRawDecoder.Decode(Sink.Stream,Decoded,Props,Length(Data));
    Check((Decoded.Size=Length(Data)) and CompareMem(Decoded.Memory,Pointer(Data),Length(Data)),'Native full-property roundtrip');
    P:=TLzmaRawEncoder.NormalizeProfile(5,8192);P.Algorithm:=1;P.FastBytes:=73;P.CutValue:=26;
    P.MatchFinderKind:=mfHashChain5;P.ParserMode:=lpmSdkProfile;
    Raw:=TLzmaRawEncoder.DefaultProperties(8192);
    TLzmaRawEncoder.Encode(DirectInput,Direct,P,Raw,False,0,0,Decisions);
    Check((Direct.Size=Sink.Stream.Size) and CompareMem(Direct.Memory,Sink.Stream.Memory,NativeInt(Direct.Size)),
      'Full properties were not applied to the native engine');
    for I:=0 to 6 do
    begin
      FillChar(Buffer,SizeOf(Buffer),$A5);Available:=SizeT(I);
      if I<5 then
      begin
        Check(Encoder.WriteProperties(@Buffer[0],Available)=SZ_ERROR_PARAM,'Small property buffer accepted');
        Check((Available=SizeT(I)) and (Buffer[0]=$A5),'Rejected property write changed output');
      end
      else
      begin
        Check(Encoder.WriteProperties(@Buffer[0],Available)=SZ_OK,'Property buffer write');
        Check((Available=5) and CompareMem(@Buffer[0],Pointer(Props),5) and (Buffer[5]=$A5),'Property write extent');
      end;
    end;
    Full.WriteEndMark:=$80000000;Check(Encoder.SetProps(Full)=SZ_OK,'Full write-end flags');
    Check(Encoder.IsWriteEndMark=$80000000,'Write-end flags lost their original width');
    Bad:=Full;Bad.NumHashBytes:=2;Bad.BtMode:=1;
    Check(Encoder.SetProps(Bad)=SZ_OK,'Native BT2 property dispatch');
    Check(Encoder.IsWriteEndMark=$80000000,'BT2 properties lost write-end flags');
    Bad:=Full;Bad.NumHashOutBits:=1;
    Check(Encoder.SetProps(Bad)=SZ_OK,'SDK hash-out width backend');
    Bad:=Full;Bad.NumHashOutBits:=256;
    Check(Encoder.SetProps(Bad)=SZ_OK,'SDK byte-truncated zero hash width');
    Bad:=Full;Bad.Lc:=9;
    Check(Encoder.SetProps(Bad)=SZ_ERROR_PARAM,'SDK invalid literal property');
    Full.WriteEndMark:=0;
    Check(Encode(True,1,SZ_OK,False)=SZ_ERROR_WRITE,'Native SDK short-write policy');
    Check(Encode(False,1,SZ_OK,False)=SZ_OK,'Legacy partial-write retry compatibility');
    Check(Encode(True,High(Integer),42,False)=SZ_ERROR_WRITE,'Native SDK output-result mapping');
    Check(Encode(False,High(Integer),42,False)=42,'Legacy output result compatibility');
    Check(Encode(True,High(Integer),SZ_OK,True)=SZ_ERROR_PROGRESS,'Native SDK progress-result mapping');
    Check(Encode(False,High(Integer),SZ_OK,True)=42,'Legacy progress result compatibility');
    Check(Encoder.IsWriteEndMark=0,'Legacy setter did not restore legacy state');
  finally Progress:=nil;InApi:=nil;Output:=nil;DirectInput.Free;Direct.Free;Decoded.Free;Encoder.Free;Input.Free;end;
end;

var HandlesBefore,HandlesAfter:DWORD;ScalarOnly:Boolean;
begin
  Log:=TStringList.Create;
  try
    try
      ScalarOnly:=(ParamCount=5) and (ParamStr(5)='--scalar-only');
      if (ParamCount<>4) and not ScalarOnly then raise Exception.Create('Vectors, SDK MT trace, SDK Z7_ST trace and log paths required; optional --scalar-only development precheck');
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesBefore),'Initial handle query');
      Trace(ParamStr(1),ParamStr(2),False);Trace(ParamStr(1),ParamStr(3),True);
      if not ScalarOnly then HandleContracts;
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesAfter),'Final handle query');
      Check(HandlesAfter=HandlesBefore,'Properties QA leaked handles');
      Log.Add(Format('rows=%u checks=%u failures=0 nativeBits=%d handlesBefore=%d handlesAfter=%d scalarOnly=%d codecHandleTests=%d',
        [RowsCompared,Checks,SizeOf(NativeUInt)*8,HandlesBefore,HandlesAfter,Ord(ScalarOnly),Ord(not ScalarOnly)]));
      Log.SaveToFile(ParamStr(4),TEncoding.UTF8);Writeln(Log[Log.Count-1]);
    except on E:Exception do
      begin Log.Add(E.ClassName+': '+E.Message);if ParamCount>=4 then Log.SaveToFile(ParamStr(4),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;end;
    end;
  finally Log.Free;end;
end.
