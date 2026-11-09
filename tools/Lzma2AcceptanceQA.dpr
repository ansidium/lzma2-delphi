program Lzma2AcceptanceQA;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.IOUtils, System.Threading,
  System.Generics.Collections,
  Winapi.Windows, Lzma.Api, Lzma.Types, Lzma.Errors, Lzma.SevenZip;

var Checks, Cases, ContainerIndex, Level, Threads, SizeIndex, Calls, I: Integer;
    Data, ArchiveBytes: TBytes;
    Source, Encoded, Decoded: TBytesStream;
    Options: TLzma2Options;
    EncodeInfo: TLzma2EncodeDiagnostics;
    DecodeInfo: TLzma2DecodeDiagnostics;
    Task: ITask;
    MainThread, CallbackThread: DWORD;
    Log: TStringList;
    Entries: TArray<TLzma7zEncodeEntry>;
    Listed: TArray<TLzma7zEntry>;
    Root, ExtractRoot: string;
    OutputStreams: TObjectList<TStream>;

procedure Check(const Condition: Boolean; const Detail: string);
begin
  Inc(Checks);
  if not Condition then raise Exception.Create('FAIL: '+Detail);
end;

function Config(const Kind, CompressionLevel, WorkerCount: Integer): TLzma2Options;
begin
  case Kind of
    0: Result:=TLzma2.RawLzma2Options(CompressionLevel,WorkerCount);
    1: Result:=TLzma2.StandaloneLzmaOptions(CompressionLevel);
    2: Result:=TLzma2.XzOptions(CompressionLevel,WorkerCount);
  else Result:=TLzma2.SevenZipOptions('fixture.bin',CompressionLevel,WorkerCount);
  end;
  Result.ThreadCount:=WorkerCount;
  Result.DictionarySize:=1 shl 20;
  Result.MemoryLimit:=128 shl 20;
end;

procedure FreeStreams;
begin FreeAndNil(Source);FreeAndNil(Encoded);FreeAndNil(Decoded);end;

begin
  Checks:=0;
  Cases:=0;
  Log:=TStringList.Create;
  try
    try
      if ParamCount<>1 then raise Exception.Create('Result path argument required');
      Root:=ExtractFileDir(ParamStr(1));
      for SizeIndex:=0 to 2 do
      begin
        case SizeIndex of 0:SetLength(Data,0);1:SetLength(Data,4096);else SetLength(Data,65536);end;
        for I:=0 to High(Data) do Data[I]:=Byte((I*37+(I shr 7)*13) and 255);
        for ContainerIndex:=0 to 3 do
          for Level in [0,1,5] do
            for Threads in [1,2,6] do
            begin
              Options:=Config(ContainerIndex,Level,Threads);
              EncodeInfo:=Default(TLzma2EncodeDiagnostics);
              DecodeInfo:=Default(TLzma2DecodeDiagnostics);
              Options.EncodeDiagnostics:=@EncodeInfo;
              Options.DecodeDiagnostics:=@DecodeInfo;
              Source:=TBytesStream.Create(Data);Encoded:=TBytesStream.Create;Decoded:=TBytesStream.Create;
              try
                Calls:=0;
                TLzma2.Compress(Source,Encoded,Options,
                  procedure(const InBytes,OutBytes:UInt64;var Cancel:Boolean)
                  begin Inc(Calls);Cancel:=False;end);
                Check(Encoded.Size>0,'Non-empty encoded container');
                if Length(Data)>0 then Check(Calls>0,'Compression progress callback');
                Encoded.Position:=0;
                TLzma2.Decompress(Encoded,Decoded,Options);
                Check(Decoded.Size=Length(Data),'Roundtrip size');
                if Length(Data)>0 then Check(CompareMem(Pointer(Data),Decoded.Memory,Length(Data)),'Roundtrip bytes');
                Check((DecodeInfo.ActualThreadCount>=0) and (DecodeInfo.ActualThreadCount<=Threads),
                  Format('Decode thread count is bounded: container=%d level=%d requested=%d actual=%d size=%d',
                    [ContainerIndex,Level,Threads,DecodeInfo.ActualThreadCount,Length(Data)]));
                Inc(Cases);
              finally FreeStreams;end;
            end;
      end;
      SetLength(Data,262144);
      for I:=0 to High(Data) do Data[I]:=Byte((I*73+(I shr 11)) and 255);
      for ContainerIndex:=0 to 3 do
      begin
        Options:=Config(ContainerIndex,5,2);
        Source:=TBytesStream.Create(Data);Encoded:=TBytesStream.Create;
        try
          Options.MemoryLimit:=1;
          try TLzma2.Compress(Source,Encoded,Options);Check(False,'MemoryLimit must reject tiny admission');
          except on E:ELzmaMemoryError do Inc(Checks);end;
          Options.MemoryLimit:=128 shl 20;
          Source.Position:=0;Encoded.Clear;
          try
            TLzma2.Compress(Source,Encoded,Options,
              procedure(const InBytes,OutBytes:UInt64;var Cancel:Boolean)begin Cancel:=True;end);
            Check(False,'Encode cancellation must stop the operation');
          except on E:ELzmaCancelled do Inc(Checks);end;
          Source.Position:=0;Encoded.Clear;
          TLzma2.Compress(Source,Encoded,Options);
          ArchiveBytes:=Copy(Encoded.Bytes,0,Integer(Encoded.Size));
          Encoded.Position:=0;Decoded:=TBytesStream.Create;
          try
            TLzma2.Decompress(Encoded,Decoded,Options,
              procedure(const InBytes,OutBytes:UInt64;var Cancel:Boolean)begin Cancel:=True;end);
            Check(False,'Decode cancellation must stop the operation');
          except on E:ELzmaCancelled do Inc(Checks);end;
        finally FreeStreams;end;
        MainThread:=GetCurrentThreadId;CallbackThread:=0;
        Source:=TBytesStream.Create(Data);Encoded:=TBytesStream.Create;Decoded:=TBytesStream.Create;
        try
          Task:=TLzma2.CompressAsync(Source,Encoded,Options,
            procedure(const InBytes,OutBytes:UInt64;var Cancel:Boolean)
            begin CallbackThread:=GetCurrentThreadId;Cancel:=False;end);
          Check(Task.Wait(60000),'Async encode finishes');Task:=nil;
          Check(CallbackThread<>MainThread,'Async encode runs off the calling thread');
          Encoded.Position:=0;
          Task:=TLzma2.DecompressAsync(Encoded,Decoded,Options);
          Check(Task.Wait(60000),'Async decode finishes');Task:=nil;
          Check((Decoded.Size=Length(Data)) and CompareMem(Pointer(Data),Decoded.Memory,Length(Data)),'Async roundtrip bytes');
        finally
          if Task<>nil then Task.Wait;
          Task:=nil;FreeStreams;
        end;
      end;
      // Multi-entry archive API, with file ownership and Unicode names exercised.
      SetLength(Entries,3);
      Entries[0].FileName:='folder/';Entries[0].IsDirectory:=True;
      Entries[1].FileName:='folder/данные.bin';
      Entries[2].FileName:='empty.bin';
      Options:=Config(3,1,2);
      Encoded:=TBytesStream.Create;
      try
        TLzma7z.EncodeEntries(Entries,
          function(const Entry:TLzma7zEncodeEntry;const EntryIndex:Integer):TStream
          begin
            if EntryIndex=1 then Result:=TBytesStream.Create(Data)
            else Result:=TBytesStream.Create;
          end,Encoded,Options);
        Encoded.Position:=0;Listed:=TLzma7z.List(Encoded,Options);
        Check(Length(Listed)=3,'Multi-entry 7z list');
        ExtractRoot:=TPath.Combine(Root,'api-extract');
        TDirectory.CreateDirectory(ExtractRoot);
        Encoded.Position:=0;
        OutputStreams:=TObjectList<TStream>.Create(True);
        TLzma7z.ExtractAll(Encoded,
          function(const Entry:TLzma7zEntry):TStream
          var Path:string;
          begin
            Path:=TPath.Combine(ExtractRoot,StringReplace(Entry.FileName,'/','\',[rfReplaceAll]));
            if Entry.IsDirectory then begin TDirectory.CreateDirectory(Path);Exit(nil);end;
            TDirectory.CreateDirectory(ExtractFileDir(Path));
            Result:=TFileStream.Create(Path,fmCreate);
            OutputStreams.Add(Result);
          end,Options);
        FreeAndNil(OutputStreams);
        ArchiveBytes:=TFile.ReadAllBytes(TPath.Combine(ExtractRoot,'folder\данные.bin'));
        Check((Length(ArchiveBytes)=Length(Data)) and CompareMem(Pointer(ArchiveBytes),Pointer(Data),Length(Data)),'Multi-entry 7z extraction bytes');
        Check(TFile.GetSize(TPath.Combine(ExtractRoot,'empty.bin'))=0,'Empty archive member');
      finally FreeAndNil(Encoded);end;
      Log.Add(Format('cases=%d checks=%d failures=0; raw LZMA2, LZMA, XZ, 7z; levels 0/1/5; threads 1/2/6',[Cases,Checks]));
      Log.SaveToFile(ParamStr(1),TEncoding.UTF8);Writeln(Log[0]);
    except
      on E:Exception do
      begin
        Log.Add(Format('cases=%d checks=%d failure=%s: %s',[Cases,Checks,E.ClassName,E.Message]));
        if ParamCount=1 then Log.SaveToFile(ParamStr(1),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;
      end;
    end;
  finally OutputStreams.Free;FreeStreams;Log.Free;end;
end.
