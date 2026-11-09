program Lzma2SdkParserQA;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, Winapi.Windows, Lzma2.SdkParser;

var Vectors,Expected:TFileStream;Data:TBytes;Parser:TLzma2SdkParser;
    Rows,Row,Op,InputLimit,CheckFinish,I:UInt32;
    OutputLimit,Value,Consumed,InputPosition,Checks:UInt64;
    Used:NativeUInt;Status:TLzma2ParseStatus;Cursor:PByte;
    StatusCounts:array[TLzma2ParseStatus] of UInt64;
    HandlesBefore,HandlesAfter:DWORD;Log:TStringList;

function Read32(Stream:TStream):UInt32;
begin Stream.ReadBuffer(Result,SizeOf(Result));end;
function Read64(Stream:TStream):UInt64;
begin Stream.ReadBuffer(Result,SizeOf(Result));end;

procedure Check(Condition:Boolean; const Detail:string);
begin
  Inc(Checks);
  if not Condition then raise Exception.CreateFmt('row=%d %s',[Row,Detail]);
end;

procedure Compare32(Actual:UInt32; const FieldName:string);
var Reference:UInt32;
begin
  Reference:=Read32(Expected);
  Check(Actual=Reference,Format('%s actual=%u SDK=%u',[FieldName,Actual,Reference]));
end;

procedure Compare64(Actual:UInt64; const FieldName:string);
var Reference:UInt64;
begin
  Reference:=Read64(Expected);
  Check(Actual=Reference,Format('%s actual=%u SDK=%u',[FieldName,Actual,Reference]));
end;

begin
  Log:=TStringList.Create;
  try
    try
      if ParamCount<>3 then raise Exception.Create('Vectors, native SDK expected trace and log paths required');
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesBefore),'Initial handle count');
      Vectors:=TFileStream.Create(ParamStr(1),fmOpenRead or fmShareDenyWrite);
      try
        Expected:=TFileStream.Create(ParamStr(2),fmOpenRead or fmShareDenyWrite);
        try
          Check(Read32(Vectors)=$5150324C,'Vector magic');Rows:=Read32(Vectors);
          Check(Rows>0,'Empty vector set');
          Check(Read32(Expected)=$4F50324C,'SDK trace magic');
          Check(Read32(Expected)=SizeOf(NativeUInt)*8,'SDK trace uses a different native word size');
          Check(Read32(Expected)=Rows,'SDK trace row coverage');
          Parser:=TLzma2SdkParser.Create;InputPosition:=0;
          for Row:=0 to Rows-1 do
          begin
            Op:=Read32(Vectors);OutputLimit:=Read64(Vectors);InputLimit:=Read32(Vectors);
            CheckFinish:=Read32(Vectors);Value:=Read64(Vectors);Consumed:=0;
            Status:=lpsNotSpecified;
            case Op of
              0:begin
                  Parser:=TLzma2SdkParser.Create;InputPosition:=0;
                  Check(InputLimit<=131072,'Invalid vector data size');
                  SetLength(Data,InputLimit);
                  if InputLimit<>0 then Vectors.ReadBuffer(Data[0],InputLimit);
                end;
              1:begin
                  Check(InputPosition<=UInt64(Length(Data)),'Input cursor escaped fixture');
                  Used:=NativeUInt(UInt64(Length(Data))-InputPosition);
                  if Used>InputLimit then Used:=InputLimit;
                  Cursor:=Pointer(Data);Inc(Cursor,NativeUInt(InputPosition));
                  Status:=Parser.Parse(NativeUInt(OutputLimit and UInt64(High(NativeUInt))),Cursor,Used,CheckFinish<>0);
                  Check(Used<=UInt64(Length(Data))-InputPosition,'Parser overread input');
                  Consumed:=Used;Inc(InputPosition,Used);Inc(StatusCounts[Status]);
                end;
              2:begin Parser.Init;InputPosition:=0;end;
              3:Parser.DictionaryPosition:=NativeUInt(Value and UInt64(High(NativeUInt)));
            else raise Exception.Create('Unknown vector operation');
            end;
            Compare32(Ord(Status),'status');Compare64(Consumed,'consumed');
            Compare32(Ord(Parser.State),'state');Compare32(Parser.Control,'control');
            Compare32(Parser.NeedInitLevel,'needInitLevel');Compare32(Ord(Parser.ExtraMode),'extraMode');
            Compare32(Parser.PackedRemaining,'packRemaining');Compare32(Parser.UnpackedRemaining,'unpackRemaining');
            Compare64(Parser.DictionaryPosition,'dictionaryPosition');
            Compare32(Parser.Lc,'lc');Compare32(Parser.Lp,'lp');Compare32(Parser.Pb,'pb');
            Compare32(Parser.UnpackExtra,'unpackExtra');
          end;
          Check(Vectors.Position=Vectors.Size,'Unconsumed vector records');
          Check(Expected.Position=Expected.Size,'Extra SDK trace records');
          for Status:=Low(TLzma2ParseStatus) to High(TLzma2ParseStatus) do
            if Status<>lpsMaybeFinishedWithoutMark then Check(StatusCounts[Status]>0,'Uncovered SDK parse status');
        finally Expected.Free;end;
      finally Vectors.Free;end;
      Data:=nil;
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesAfter),'Final handle count');
      Check(HandlesAfter=HandlesBefore,'Parser QA leaked kernel handles');
      Log.Add(Format('rows=%u checks=%u failures=0 nativeBits=%d handlesBefore=%d handlesAfter=%d',
        [Rows,Checks,SizeOf(NativeUInt)*8,HandlesBefore,HandlesAfter]));
      for I:=Ord(Low(TLzma2ParseStatus)) to Ord(High(TLzma2ParseStatus)) do
        Log.Add(Format('status=%d count=%u',[I,StatusCounts[TLzma2ParseStatus(I)]]));
      Log.SaveToFile(ParamStr(3),TEncoding.UTF8);Writeln(Log[0]);
    except
      on E:Exception do
      begin
        Log.Add(E.ClassName+': '+E.Message);
        if ParamCount=3 then Log.SaveToFile(ParamStr(3),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;
      end;
    end;
  finally Log.Free;end;
end.
