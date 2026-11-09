program Lzma2BenchmarkQA;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.Diagnostics, System.Math,
  Winapi.Windows, Lzma2Benchmark;

var Checks: Integer;
    Log: TStringList;
    Config: TBenchmarkConfig;
    Bench: TLzmaBenchmark;
    S: TBenchmarkSnapshot;
    A, B: TBytes;
    M, Other: TBenchmarkMetric;
    I, MaxWorkers: Integer;
    HandlesBefore, HandlesAfter: DWORD;
    Deadline: UInt64;
    PerWorker:UInt64;

procedure Check(const Condition: Boolean; const Detail: string);
begin
  Inc(Checks);
  if not Condition then raise Exception.Create('FAIL: '+Detail);
end;

procedure WaitFinished(const B: TLzmaBenchmark);
var Watch: TStopwatch;
begin
  Watch:=TStopwatch.StartNew;
  repeat
    S:=B.Snapshot;
    MaxWorkers:=Max(MaxWorkers,B.ActiveWorkers);
    if S.Finished then Break;
    if Watch.ElapsedMilliseconds>60000 then
    begin B.Cancel; raise Exception.Create('Benchmark did not finish within 60 seconds'); end;
    Sleep(5);
  until False;
  B.Wait;
  Check(B.ActiveWorkers=0,'All benchmark workers must be joined');
end;

begin
  Log:=TStringList.Create;
  try
    try
      if ParamCount<>1 then raise Exception.Create('Output path argument required');
      Check(CompressionComplexity(1 shl 20)=890,'1 MB rating complexity');
      Check(CompressionComplexity(16 shl 20)=1050,'16 MB rating complexity');
      M:=Default(TBenchmarkMetric);
      M.Bytes:=1 shl 20; M.WallSeconds:=2; M.CpuSeconds:=1; M.Commands:=1000000000;
      Check(SameValue(M.SpeedKiB,512),'Unpacked KiB/s');
      Check(SameValue(M.UsagePercent,50),'CPU usage');
      Check(SameValue(M.RatingMips,500),'MIPS rating');
      Check(SameValue(M.RatingPerUsage,1000),'CPU-normalized rating');
      Other:=M;Other.Bytes:=2 shl 20;Other.WallSeconds:=1;Other.CpuSeconds:=2;Other.Commands:=2000000000;
      M.Add(Other);
      Check(SameValue(M.SpeedKiB,1024),'Average must use total bytes and total time');
      A:=BenchmarkData(20,65536,0);B:=BenchmarkData(20,65536,0);
      Check(CompareMem(Pointer(A),Pointer(B),Length(A)),'Generator determinism');
      B:=BenchmarkData(20,65536,1);
      Check(not CompareMem(Pointer(A),Pointer(B),Length(A)),'Worker-specific data salt');
      A:=BenchmarkData(20,65536,0,function:Boolean begin Result:=True;end);
      Check(Length(A)=0,'Generator cancellation');
      A:=nil;B:=nil;
      Config:=Default(TBenchmarkConfig);
      Config.DictionarySize:=1 shl 20;Config.Workers:=1;
      PerWorker:=TLzmaBenchmark.RequiredMemory(Config);
      Config.Workers:=257;
      Check(TLzmaBenchmark.RequiredMemory(Config)=257*PerWorker,'Memory admission must support workers beyond 128');
      Check(TLzmaBenchmark.AutoWorkers(Config.DictionarySize,PerWorker*1024,1024)=1024,'Auto must preserve available CPU counts above 128');
      Check(TLzmaBenchmark.AutoWorkers(Config.DictionarySize,PerWorker*3,1024)=3,'Auto must obey memory admission');
      Config.Workers:=1;Config.DictionarySize:=TLzmaBenchmark.MaximumDictionarySize;
      Check(Config.DictionarySize=UInt64(1) shl (22+SizeOf(NativeInt) div 4*5),'SDK platform dictionary limit');
      Check(TLzmaBenchmark.RequiredMemory(Config)>PerWorker,'Maximum dictionary memory must remain positive and wide');
      Config.DictionarySize:=Config.DictionarySize*2;
      try
        TLzmaBenchmark.RequiredMemory(Config);Check(False,'Over-platform dictionary accepted');
      except on E:EArgumentException do Inc(Checks);end;
      if SizeOf(NativeInt)=8 then
      begin
        Config.DictionarySize:=TLzmaBenchmark.MaximumDictionarySize;
        Config.Workers:=High(Integer);
        try
          TLzmaBenchmark.RequiredMemory(Config);Check(False,'UInt64 worker-memory overflow accepted');
        except on E:EArgumentException do Inc(Checks);end;
        A:=BenchmarkData(32,NativeInt(TLzmaBenchmark.MaximumDictionarySize)+65536,0,
          function:Boolean begin Result:=True;end);
        Check(Length(A)=0,'Cancellation before a 4 GiB allocation');
      end;
      Config:=Default(TBenchmarkConfig);
      Config.DictionarySize:=1 shl 20;Config.Workers:=1;Config.Passes:=2;
      Config.PhaseMilliseconds:=30;Config.MemoryLimit:=512 shl 20;
      Check(TLzmaBenchmark.RequiredMemory(Config)<Config.MemoryLimit,'Bounded small test admission');
      Config.MemoryLimit:=1;
      Bench:=nil;
      try
        try Bench:=TLzmaBenchmark.Create(Config);
        except on E:EArgumentException do Inc(Checks); end;
        Check(Bench=nil,'Too-small memory limit must reject construction');
      finally Bench.Free; end;
      Config.MemoryLimit:=512 shl 20;
      Bench:=TLzmaBenchmark.Create(Config);
      try
        Bench.Start;WaitFinished(Bench);
        Check(S.State=bsComplete,'Single-worker benchmark completion: '+S.ErrorText);
        Check(S.CompletedPasses=2,'Paired completed passes');
        Check((S.AverageCompression.Bytes>0) and (S.AverageDecompression.Bytes>0),'Both codec phases produce results');
        Check((S.AverageCompression.RatingMips>0) and (S.AverageDecompression.RatingMips>0),'Positive ratings');
        try Bench.Start;Check(False,'Double start must fail');
        except on E:EInvalidOpException do Inc(Checks); end;
      finally Bench.Free; end;
      Config.Workers:=2;Config.Passes:=1;MaxWorkers:=0;
      Bench:=TLzmaBenchmark.Create(Config);
      try
        Bench.Start;WaitFinished(Bench);
        Check((S.State=bsComplete) and (S.CompletedPasses=1),'Two-worker completion: '+S.ErrorText);
        Check(MaxWorkers=2,'Both dedicated workers ran');
      finally Bench.Free; end;
      GetProcessHandleCount(GetCurrentProcess,HandlesBefore);
      for I:=1 to 5 do
      begin
        Config.Passes:=20;Config.PhaseMilliseconds:=1000;
        Bench:=TLzmaBenchmark.Create(Config);
        try
          Bench.Start;
          Deadline:=GetTickCount64+10000;
          repeat
            S:=Bench.Snapshot;
            if S.State=bsCompressing then Break;
            if S.Finished then raise Exception.Create('Unexpected early termination: '+S.ErrorText);
            Sleep(2);
          until GetTickCount64>Deadline;
          Check(S.State=bsCompressing,'Cancellation reaches a codec phase');
          Bench.Cancel;WaitFinished(Bench);
          Check(S.State=bsCancelled,'Cancellation state');
          Check(S.CompletedPasses=0,'Incomplete pairs must not enter averages');
        finally Bench.Free; end;
      end;
      GetProcessHandleCount(GetCurrentProcess,HandlesAfter);
      Check(HandlesAfter<=HandlesBefore+2,'Repeated cancel must not leak OS handles');
      Log.Add(Format('checks=%d failures=0 handlesBefore=%d handlesAfter=%d',[Checks,HandlesBefore,HandlesAfter]));
      Log.SaveToFile(ParamStr(1),TEncoding.UTF8);
      Writeln(Log[0]);
    except
      on E:Exception do
      begin
        Log.Add(Format('checks=%d failure=%s: %s',[Checks,E.ClassName,E.Message]));
        if ParamCount=1 then Log.SaveToFile(ParamStr(1),TEncoding.UTF8);
        Writeln(Log[Log.Count-1]);ExitCode:=1;
      end;
    end;
  finally Log.Free;end;
end.
