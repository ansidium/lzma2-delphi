program Lzma2MtPipelineQA;

{$APPTYPE CONSOLE}

uses System.SysUtils, System.Classes, System.SyncObjs, System.Math,
  Winapi.Windows, Lzma.Types, Lzma.Errors, Lzma.MatchFinder, Lzma.MtMatchFinder;

type
  TFinder = class
  private
    FHc4: TLzmaHashChain4MatchFinder;
    FHc5: TLzmaHashChain5MatchFinder;
    FBt4: TLzmaBinaryTree4MatchFinder;
  public
    constructor Create(const Data:TBytes; Kind,FastBytes:Integer);
    destructor Destroy; override;
    procedure Read(Position:NativeUInt; var Matches:TLzmaMatchBuffer);
    procedure Skip(Position:NativeUInt);
  end;

var Checks,Comparisons:Integer;
    InjectedWindowFailures,InjectedReadFailures:Integer;
    MainThreadId:Cardinal;
    HandlesBefore,HandlesAfter:DWORD;

procedure Check(Condition:Boolean; const Detail:string);
begin
  TInterlocked.Increment(Checks);
  if not Condition then raise Exception.Create('FAIL: '+Detail);
end;

procedure SameMatches(const A,B:TLzmaMatchBuffer);
var I:Integer;
begin
  Inc(Comparisons);
  Check(A.Count=B.Count,'Match count differs');
  for I:=0 to A.Count-1 do
    Check((A.Items[I].Length=B.Items[I].Length) and
      (A.Items[I].Distance=B.Items[I].Distance),'Match pair differs');
end;

constructor TFinder.Create(const Data:TBytes; Kind,FastBytes:Integer);
begin
  inherited Create;
  case Kind of
    0:FHc4:=TLzmaHashChain4MatchFinder.Create(Data,0,Length(Data),4096,FastBytes,273,32);
    1:FHc5:=TLzmaHashChain5MatchFinder.Create(Data,0,Length(Data),4096,FastBytes,273,32);
    2:FBt4:=TLzmaBinaryTree4MatchFinder.Create(Data,0,Length(Data),4096,FastBytes,273,32);
    3:FBt4:=TLzmaBinaryTree4MatchFinder.CreateSdkMtHighHash(Data,0,Length(Data),4096,FastBytes,273,32);
  else raise Exception.Create('Unknown test finder');
  end;
end;

destructor TFinder.Destroy;
begin FHc4.Free;FHc5.Free;FBt4.Free;inherited;end;

procedure TFinder.Read(Position:NativeUInt; var Matches:TLzmaMatchBuffer);
begin
  if FHc4<>nil then FHc4.ReadMatchPairs(Position,Matches)
  else if FHc5<>nil then FHc5.ReadMatchPairs(Position,Matches)
  else FBt4.ReadMatchPairs(Position,Matches);
end;

procedure TFinder.Skip(Position:NativeUInt);
begin
  if FHc4<>nil then FHc4.SkipRangeMonotonic(Position,1)
  else if FHc5<>nil then FHc5.SkipRangeMonotonic(Position,1)
  else FBt4.SkipRangeMonotonic(Position,1);
end;

function Input(Pattern:Integer):TBytes;
var I:Integer;Seed:UInt32;
begin
  SetLength(Result,32768);Seed:=$76A2B19D;
  for I:=0 to High(Result) do
  begin
    Seed:=Seed xor (Seed shl 13);Seed:=Seed xor (Seed shr 17);Seed:=Seed xor (Seed shl 5);
    case Pattern of
      0:Result[I]:=Byte(Seed);
      1:Result[I]:=Byte(I mod 31);
      2:if (I>4096) and ((I mod 97)<83) then Result[I]:=Result[I-3971]
        else Result[I]:=Byte(Seed and 31);
    end;
  end;
end;

procedure FinderSemantics;
var Pattern,Kind,FastBytes,P:Integer;Data:TBytes;Lazy,Eager:TFinder;
    A,B:TLzmaMatchBuffer;
begin
  // The encoder skips most consumed positions. The producer must return the
  // same future matches when it instead reads each skipped position eagerly.
  for Pattern:=0 to 2 do
    for Kind:=0 to 3 do
      for FastBytes in [16,64,273] do
      begin
        Data:=Input(Pattern);Lazy:=TFinder.Create(Data,Kind,FastBytes);
        Eager:=nil;
        try
          Eager:=TFinder.Create(Data,Kind,FastBytes);
          for P:=0 to High(Data) do
          begin
            Eager.Read(P,A);
            if ((P mod 47)<5) or (P=High(Data)) then
            begin Lazy.Read(P,B);SameMatches(A,B);end
            else Lazy.Skip(P);
          end;
        finally Eager.Free;Lazy.Free;end;
      end;
end;

procedure NativeFinderPipeline;
var Data:TBytes;Producer,Reference:TFinder;Pipe:TLzmaMatchFinderPipeline;
    A,B:TLzmaMatchBuffer;P,ProducerId:Integer;
begin
  Data:=Input(2);ProducerId:=0;Producer:=TFinder.Create(Data,3,64);
  Reference:=nil;Pipe:=nil;
  try
    Reference:=TFinder.Create(Data,3,64);
    Pipe:=TLzmaMatchFinderPipeline.Create(
      procedure(const Position:NativeUInt; var Matches:TLzmaMatchBuffer)
      begin
        TInterlocked.Exchange(ProducerId,Integer(GetCurrentThreadId));
        Producer.Read(Position,Matches);
      end,
      procedure begin Check(GetCurrentThreadId=MainThreadId,'Wait callback moved off caller thread');end);
    Pipe.SetWindow(0,Length(Data),64,True);
    for P:=0 to High(Data) do
    begin
      if ((P mod 47)<5) or (P=High(Data)) then
      begin
        Reference.Read(P,A);Pipe.ReadAt(P,B);SameMatches(A,B);
        Pipe.ReadAt(P,B);SameMatches(A,B);
      end
      else begin Reference.Skip(P);Pipe.AdvanceTo(P+1);end;
      Check((Pipe.BufferedCount>=0) and (Pipe.BufferedCount<=128),'Queue exceeded bounded capacity');
    end;
    Pipe.StopAndCheck;
    Check((ProducerId<>0) and (Cardinal(ProducerId)<>MainThreadId),'Finder did not run on its dedicated thread');
  finally Pipe.Free;Reference.Free;Producer.Free;end;
end;

procedure WindowAndWidePositions;
const Start=UInt64($100000000)+17;
var Pipe:TLzmaMatchFinderPipeline;A:TLzmaMatchBuffer;
    Base:UInt64;P:Integer;Calls,PausedCalls:Integer;Deadline:UInt64;
begin
  Calls:=0;Base:=Start;
  Pipe:=TLzmaMatchFinderPipeline.Create(
    procedure(const Position:NativeUInt; var Matches:TLzmaMatchBuffer)
    begin
      Matches.Clear;Matches.Add(2+UInt32((Base+Position) mod 272),UInt32((Base+Position) mod 4096));
      TInterlocked.Increment(Calls);
    end,nil,Start);
  try
    Pipe.SetWindow(Base,1024,64,False);
    Deadline:=GetTickCount64+10000;
    while (Pipe.BufferedCount<128) and (GetTickCount64<Deadline) do Sleep(1);
    Check(Pipe.BufferedCount=128,'Producer did not stop at ring capacity');
    Pipe.Pause;PausedCalls:=TInterlocked.CompareExchange(Calls,0,0);Sleep(10);
    Check(TInterlocked.CompareExchange(Calls,0,0)=PausedCalls,'Producer ran while input was paused');
    Pipe.SetWindow(Base,1024,64,False);
    for P:=0 to 959 do
    begin
      Pipe.ReadAt(Start+UInt64(P),A);
      Check((A.Count=1) and (A.Items[0].Distance=UInt32((Start+UInt64(P)) mod 4096)),'Wide absolute position truncated');
    end;
    try Pipe.ReadAt(Start+960,A);Check(False,'Nonfinal lookahead must be unavailable');
    except on E:ELzmaInvalidParameter do Inc(Checks);end;
    Pipe.Pause;Base:=Start+512;
    Pipe.SetWindow(Base,1536,64,True);
    for P:=960 to 2047 do
    begin
      Pipe.ReadAt(Start+UInt64(P),A);
      Check(A.Items[0].Distance=UInt32((Start+UInt64(P)) mod 4096),'Window rebase changed queued coordinates');
    end;
    Pipe.Pause;
    try Pipe.SetWindow(High(UInt64),1,0,True);Check(False,'Overflowing input accepted');
    except on E:ELzmaInvalidParameter do Inc(Checks);end;
    Pipe.StopAndCheck;
  finally Pipe.Free;end;
end;

procedure ErrorsAndLifecycle;
var Pipe:TLzmaMatchFinderPipeline;A:TLzmaMatchBuffer;I,P:Integer;Cancel,InWindow:Boolean;

  procedure ExpectedProducerFailure;
  begin
    Inc(Checks);
    if InWindow then Inc(InjectedWindowFailures) else Inc(InjectedReadFailures);
  end;

begin
  for I:=1 to 24 do
  begin
    Pipe:=TLzmaMatchFinderPipeline.Create(
      procedure(const Position:NativeUInt; var Matches:TLzmaMatchBuffer)
      begin
        if Position=9 then RaiseLzmaError(SZ_ERROR_READ,'Injected finder failure');
        Matches.Clear;
      end);
    try
      InWindow:=True;
      try
        // Resume acknowledges before the producer reads. A fast producer may
        // fail before SetWindow returns, so both API boundaries are valid.
        Pipe.SetWindow(0,1024,0,True);InWindow:=False;
        for P:=0 to 10 do Pipe.ReadAt(P,A);
        Check(False,'Producer exception was lost');
      except on E:ELzmaReadError do ExpectedProducerFailure;end;
    finally Pipe.Free;end;
    Cancel:=False;
    Pipe:=TLzmaMatchFinderPipeline.Create(
      procedure(const Position:NativeUInt; var Matches:TLzmaMatchBuffer)
      begin Sleep(30);Matches.Clear;end,
      procedure begin
        Check(GetCurrentThreadId=MainThreadId,'Cancellation callback thread');
        if Cancel then RaiseLzmaError(SZ_ERROR_PROGRESS,'Injected caller cancellation');
      end);
    try
      Pipe.SetWindow(0,1024,0,True);Cancel:=True;
      try Pipe.ReadAt(100,A);Check(False,'Caller cancellation was lost');
      except on E:ELzmaCancelled do Inc(Checks);end;
    finally Pipe.Free;end;
  end;
  Pipe:=TLzmaMatchFinderPipeline.Create(
    procedure(const Position:NativeUInt; var Matches:TLzmaMatchBuffer)
    begin raise TObject.Create;end);
  try
    InWindow:=True;
    try
      Pipe.SetWindow(0,1,0,True);InWindow:=False;
      Pipe.ReadAt(0,A);Check(False,'Non-Exception producer failure was lost');
    except on E:ELzmaThreadError do ExpectedProducerFailure;end;
  finally Pipe.Free;end;
  Pipe:=TLzmaMatchFinderPipeline.Create(
    procedure(const Position:NativeUInt; var Matches:TLzmaMatchBuffer)
    begin raise EOutOfMemory.Create('Injected producer allocation failure');end);
  try
    InWindow:=True;
    try
      Pipe.SetWindow(0,1,0,True);InWindow:=False;
      Pipe.ReadAt(0,A);Check(False,'Producer memory failure was lost');
    except on E:ELzmaMemoryError do ExpectedProducerFailure;end;
  finally Pipe.Free;end;
end;

procedure PauseResumeHandshake;
var Pipe:TLzmaMatchFinderPipeline;Pairs:TLzmaMatchBuffer;
    ReaderBusy,CallerOwnsWindow,Calls:Integer;Cycle:NativeUInt;
begin
  ReaderBusy:=0;CallerOwnsWindow:=0;Calls:=0;
  Pipe:=TLzmaMatchFinderPipeline.Create(
    procedure(const Position:NativeUInt; var Matches:TLzmaMatchBuffer)
    begin
      TInterlocked.Exchange(ReaderBusy,1);
      try
        if TInterlocked.CompareExchange(CallerOwnsWindow,0,0)<>0 then
          RaiseLzmaError(SZ_ERROR_FAIL,'Producer entered an acknowledged paused window');
        Matches.Clear;TInterlocked.Increment(Calls);
      finally TInterlocked.Exchange(ReaderBusy,0);end;
    end);
  try
    for Cycle:=1 to 2048 do
    begin
      Pipe.SetWindow(0,Cycle,0,True);
      Pipe.Pause;
      TInterlocked.Exchange(CallerOwnsWindow,1);
      Check(TInterlocked.CompareExchange(ReaderBusy,0,0)=0,'Pause acknowledgement precedes reader exit');
      SwitchToThread;
      TInterlocked.Exchange(CallerOwnsWindow,0);
      Pipe.SetWindow(0,Cycle,0,True);
      Pipe.ReadAt(Cycle-1,Pairs);
      Pipe.Pause;
    end;
    Pipe.StopAndCheck;
    Check(Calls=2048,'Resume handshake skipped/duplicated producer positions');
  finally Pipe.Free;end;
end;

var Report:TStringList;
begin
  Report:=TStringList.Create;
  try
    try
      if ParamCount<>1 then raise Exception.Create('Output path required');
      MainThreadId:=GetCurrentThreadId;
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesBefore),'Initial OS handle query');
      FinderSemantics;NativeFinderPipeline;WindowAndWidePositions;ErrorsAndLifecycle;PauseResumeHandshake;
      Check(InjectedWindowFailures+InjectedReadFailures=26,'Injected producer failure coverage');
      Check(GetProcessHandleCount(GetCurrentProcess,HandlesAfter),'Final OS handle query');
      Check(HandlesAfter<=HandlesBefore,'Pipeline lifecycle leaked OS handles');
      Report.Add(Format('checks=%d comparisons=%d failures=0 handlesBefore=%d handlesAfter=%d injectedWindowFailures=%d injectedReadFailures=%d',
        [Checks,Comparisons,HandlesBefore,HandlesAfter,InjectedWindowFailures,InjectedReadFailures]));
      Report.SaveToFile(ParamStr(1),TEncoding.UTF8);Writeln(Report[0]);
    except
      on E:Exception do
      begin
        Report.Add(E.ClassName+': '+E.Message);
        if ParamCount=1 then Report.SaveToFile(ParamStr(1),TEncoding.UTF8);
        Writeln(Report[Report.Count-1]);ExitCode:=1;
      end;
    end;
  finally Report.Free;end;
end.
