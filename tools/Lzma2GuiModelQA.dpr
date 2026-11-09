program Lzma2GuiModelQA;

{$APPTYPE CONSOLE}
{$R Lzma2GUIManifest.res}

uses System.SysUtils, System.Classes, System.JSON, System.IOUtils,
  System.IniFiles, System.RegularExpressions,System.Threading, Winapi.Windows,
  Lzma2GuiCatalog, Lzma2GuiSettings, Lzma2GuiResources, Lzma2ThreadChoice,
  Lzma.Errors,Lzma.Types,Lzma2GuiErrors,Lzma2Benchmark;

var Checks, Cases: Integer; Log: TStringList; Stream: TResourceStream;
    Bytes: TBytes; Data, Strings, Entry: TJSONObject; Pair: TJSONPair;
    Language, I, Level, Workers, BudgetMiB: Integer;
    FormatTokens, OtherTokens: TMatchCollection;
    Config, Loaded, Defaults: TGuiPackingPreferences;
    Container, Mode, IniPath, Text: string;
    Ini: TMemIniFile; LastDictionary, Dictionary: UInt64;
    ThreadChoice:TThreadChoiceState;

procedure Check(const Condition: Boolean; const Detail: string);
begin Inc(Checks);if not Condition then raise Exception.Create(Detail);end;

function Equal(const A,B: TGuiPackingPreferences): Boolean;
begin
  Result:=(A.Container=B.Container) and (A.Level=B.Level) and
    (A.DictionaryMode=B.DictionaryMode) and (A.DictionaryMiB=B.DictionaryMiB) and
    (A.Threads=B.Threads) and (A.Check=B.Check);
end;

procedure AuditFailureReports;
var Aggregate:EAggregateException;Failure:TGuiFailure;Language:Integer;
begin
  Aggregate:=EAggregateException.Create('outer context',[
    ELzmaDataError.Create(SZ_ERROR_NO_ARCHIVE,'native cause gjpqy'),
    ELzmaCancelled.Create(SZ_ERROR_PROGRESS,'cancelled sibling')]);
  try
    for Language:=0 to GuiLanguageCount-1 do
    begin
      Failure:=DescribeGuiFailure(Aggregate,Language);
      Check(Failure.Summary=GuiText(Language,'The archive is damaged or incomplete.'),
        'Actual leaf error must supply the localized summary');
      Check(Pos('native cause gjpqy',Failure.Details)>0,'Underlying cause is retained');
      Check(Pos('cancelled sibling',Failure.Details)>0,'Sibling diagnostics are retained');
      Check(Pos('outer context',Failure.Details)>0,'Aggregate context is retained');
      Check(Pos('EAggregateException',Failure.Summary)=0,'Internal wrapper is not the user-facing summary');
    end;
  finally Aggregate.Free;end;
end;

procedure AuditEffectiveAffinity;
var OriginalMask,SystemMask,NarrowMask,Bit:NativeUInt;Found,I:Integer;
    Options:TLzma2Options;Budget:UInt64;
begin
  Check(GetProcessAffinityMask(GetCurrentProcess,OriginalMask,SystemMask),'Process affinity query');
  NarrowMask:=0;Found:=0;Bit:=1;
  for I:=0 to SizeOf(NativeUInt)*8-1 do
  begin
    if (OriginalMask and Bit)<>0 then begin NarrowMask:=NarrowMask or Bit;Inc(Found);end;
    if Found=2 then Break;
    if I<SizeOf(NativeUInt)*8-1 then Bit:=Bit shl 1;
  end;
  Check(Found>=1,'Effective CPUs available');
  Check(SetProcessAffinityMask(GetCurrentProcess,NarrowMask),'Apply process-local QA affinity');
  try
    Check(GuiProcessorCount=Found,'Auto/list CPU count must follow actual process affinity');
    Options:=Default(TLzma2Options);Options.Level:=5;Options.DictionarySize:=UInt64(1) shl 20;
    Options.Container:=lcRawLzma2;Budget:=UInt64(512) shl 30;
    Check(AutoThreadCount(Options,Budget,GuiProcessorCount)=Found,'Packing Auto actual affinity');
    Check(TLzmaBenchmark.AutoWorkers(Options.DictionarySize,Budget,GuiProcessorCount)=Found,'Benchmark Auto actual affinity');
    Check(AutoThreadCount(Options,Budget,256)=256,'Packing Auto must admit more than 128 CPUs');
    Check(TLzmaBenchmark.AutoWorkers(Options.DictionarySize,Budget,256)=256,'Benchmark Auto must admit more than 128 CPUs');
  finally Check(SetProcessAffinityMask(GetCurrentProcess,OriginalMask),'Restore process-local affinity');end;
end;

begin
  Checks:=0;Cases:=0;Data:=nil;Log:=TStringList.Create;
  try
    try
      if ParamCount<>1 then raise Exception.Create('Output file argument required');
      Check(GuiLanguageCount=24,'Supported language set');
      Stream:=TResourceStream.Create(HInstance,'GUI_CATALOG',RT_RCDATA);
      try SetLength(Bytes,Stream.Size);Stream.ReadBuffer(Bytes[0],Length(Bytes));
      finally Stream.Free;end;
      Data:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes)) as TJSONObject;
      Strings:=Data.GetValue<TJSONObject>('strings');
      for Pair in Strings do
      begin
        Entry:=Pair.JsonValue as TJSONObject;
        FormatTokens:=TRegEx.Matches(Entry.GetValue<string>('en'),'%(?:\d+:)?(?:\.\d+)?[dfs]');
        for Language:=0 to GuiLanguageCount-1 do
        begin
          Text:=GuiText(Language,Pair.JsonString.Value);
          Check(Text<>'','Empty translation');
          OtherTokens:=TRegEx.Matches(Text,'%(?:\d+:)?(?:\.\d+)?[dfs]');
          Check(OtherTokens.Count=FormatTokens.Count,'Translation placeholder count');
          for I:=0 to FormatTokens.Count-1 do
            Check(OtherTokens[I].Value=FormatTokens[I].Value,'Translation placeholder order');
        end;
      end;
      for Language:=0 to GuiLanguageCount-1 do
      begin
        Check((GuiLanguageCode(Language)<>'') and (GuiLanguageName(Language)<>''),'Language metadata');
        Check(GuiNumberFormat(Language).DecimalSeparator<>#0,'Locale number format');
        for I:=0 to 3 do Check(GuiByteUnit(Language,I)<>'','Localized byte unit');
      end;
      Defaults:=DefaultPackingPreferences;
      Check((Defaults.Container='7z') and (Defaults.Level=5) and
        (Defaults.DictionaryMode='auto') and (Defaults.Threads=0),'First-run packing defaults');
      Check(GuiProfileDictionaryMiB(5)=32,'Normal profile dictionary');
      ThreadChoice:=TThreadChoiceState.Create(4);
      Check((ThreadChoice.RequestedWorkers=0) and (ThreadChoice.ChoiceIndex=0),'Initial Auto thread selection');
      Check((ThreadChoice.ChoiceCount=6) and (ThreadChoice.CustomIndex=5),'Thread list must end at available CPUs plus Other');
      for Workers in [1,4,6,129,257,High(Integer)] do
      begin
        ThreadChoice.RequestedWorkers:=Workers;
        if Workers<=4 then Check(ThreadChoice.ChoiceIndex=Workers,'Ordinary thread selection')
        else Check(ThreadChoice.ChoiceIndex=ThreadChoice.CustomIndex,'Manual thread request must not be an out-of-range item index');
        Check(ThreadChoice.RequestedWorkers=Workers,'Manual request changed');
      end;
      try ThreadChoice.SelectNumericChoice(ThreadChoice.CustomIndex);Check(False,'Other must not become a thread count');
      except on E:EArgumentOutOfRangeException do Inc(Checks);end;
      Check(ThreadChoice.RequestedWorkers=High(Integer),'Invalid row committed a new request');
      ThreadChoice.SelectNumericChoice(0);
      Check(ThreadChoice.RequestedWorkers=0,'Return to Auto');
      ThreadChoice:=TThreadChoiceState.Create(256,999);
      Check((ThreadChoice.ChoiceCount=258) and (ThreadChoice.ChoiceIndex=257) and
        (ThreadChoice.RequestedWorkers=999),'CPU groups/manual values must not be capped at 128');
      try ThreadChoice.RequestedWorkers:=-1;Check(False,'Negative thread request accepted');
      except on E:EArgumentOutOfRangeException do Inc(Checks);end;
      for Level:=0 to 9 do
        for Workers in [1,2,6] do
        begin
          LastDictionary:=0;
          for BudgetMiB in [0,128,512,2048,8192] do
          begin
            Dictionary:=GuiAutomaticDictionary(Level,Workers,UInt64(BudgetMiB) shl 20);
            Check((Dictionary>=UInt64(1) shl 20) and
              (Dictionary<=UInt64(GuiProfileDictionaryMiB(Level)) shl 20),'Automatic dictionary bounds');
            Check(Dictionary>=LastDictionary,'Automatic dictionary memory monotonicity');
            LastDictionary:=Dictionary;
          end;
        end;
      IniPath:=TPath.Combine(ExtractFileDir(ParamStr(1)),'model-preferences.ini');
      Winapi.Windows.SetEnvironmentVariable('LZMA2_GUI_SETTINGS_PATH',PChar(IniPath));
      for Container in ['lzma','lzma2','xz','7z'] do
        for Mode in ['auto','preset','custom'] do
          for Level in [0,1,5,9] do
            for Workers in [0,1,6,129,257,999,High(Integer)] do
            begin
              Config:=Defaults;Config.Container:=Container;Config.DictionaryMode:=Mode;
              Config.Level:=Level;Config.Threads:=Workers;
              if Mode='custom' then Config.DictionaryMiB:=123 else Config.DictionaryMiB:=32;
              SavePackingPreferences(Config);Loaded:=LoadPackingPreferences;
              Check(Equal(Config,Loaded),'Packing preference roundtrip');Inc(Cases);
            end;
      Ini:=TMemIniFile.Create(IniPath,TEncoding.UTF8);
      try
        Check(not Ini.ValueExists('Packing','InputPath') and not Ini.ValueExists('Packing','OutputPath') and
          not Ini.ValueExists('Packing','MemoryLimit'),'Private paths and hardware budget are not stored');
        Ini.WriteInteger('Packing','Threads',-1);Ini.UpdateFile;
      finally Ini.Free;end;
      Check(Equal(LoadPackingPreferences,Defaults),'Invalid preference fallback');
      AuditFailureReports;AuditEffectiveAffinity;
      Log.Add(Format('cases=%d checks=%d failures=0; catalog, 24 locales, formats, defaults, auto dictionary, preferences, failure reports',[Cases,Checks]));
      Log.SaveToFile(ParamStr(1),TEncoding.UTF8);Writeln(Log[0]);
    except
      on E:Exception do
      begin
        Log.Add(Format('cases=%d checks=%d failure=%s: %s',[Cases,Checks,E.ClassName,E.Message]));
        if ParamCount=1 then Log.SaveToFile(ParamStr(1),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;
      end;
    end;
  finally Data.Free;Log.Free;end;
end.
