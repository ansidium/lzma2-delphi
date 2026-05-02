unit Lzma.EncoderHeuristics;

interface

uses
  Lzma.MatchFinder,
  Lzma.PriceTables,
  Lzma.RangeCoder,
  Lzma.Types;

const
  LZMA_OPTIMUM_BACK_LITERAL: UInt32 = $FFFFFFFF;
  LZMA_FULL_OPTIMUM_NUM_OPTS = 1 shl 11;
  LZMA_FULL_OPTIMUM_REP_LEN_COUNT = 64;
  LZMA_FULL_OPTIMUM_MATCH_PRICE_REFRESH = 64;

type
  TLzmaOptimumReps = array[0..3] of UInt32;

  TLzmaOptimumNode = record
    Price: UInt32;
    State: UInt32;
    Reps: TLzmaOptimumReps;
    PathLen: UInt32;
    PathBack: UInt32;
    Extra: UInt32;
    PosPrev: UInt32;
    BackPrev: UInt32;
    Prev1IsLiteral: Boolean;
    PosPrev2: UInt32;
    BackPrev2: UInt32;
  end;

  TLzmaOptimumDecision = record
    Len: UInt32;
    Back: UInt32;
  end;

  TLzmaOptimumBackwardState = record
    OptCur: UInt32;
    OptEnd: UInt32;
    QueueCount: UInt32;
  end;

  TLzmaFullOptimumState = record
    Enabled: Boolean;
    OptCur: UInt32;
    OptEnd: UInt32;
    LongestMatchLen: UInt32;
    NumPairs: UInt32;
    NumAvail: UInt32;
    AdditionalOffset: UInt32;
    BackRes: UInt32;
    MatchPriceCount: UInt32;
    RepLenEncCounter: Integer;
    Nodes: TArray<TLzmaOptimumNode>;
    CachedMatches: TLzmaMatchBuffer;
    CachedMainMatch: TLzmaMatch;
    ReplayDecisions: TArray<TLzmaOptimumDecision>;
    ReplayIndex: UInt32;
    ReplayCount: UInt32;
  end;

  TLzmaOptimumRepLens = array[0..3] of UInt32;

  TLzmaOptimumLiteralInput = record
    Enabled: Boolean;
    LiteralProbs: TLzmaLiteralProbs;
    Value: Byte;
    UseMatchedLiteral: Boolean;
    MatchByte: Byte;
  end;

  TLzmaOptimumProbInput = record
    IsMatchProb: CLzmaProb;
    IsRepProb: CLzmaProb;
    IsRepG0Prob: CLzmaProb;
    IsRepG1Prob: CLzmaProb;
    IsRepG2Prob: CLzmaProb;
    IsRep0LongProb: CLzmaProb;
  end;

  TLzmaOptimumStateProbInputs = array[0..11] of TLzmaOptimumProbInput;

  TLzmaOptimumLiteralResolver = reference to function(const Pos: UInt32;
    const Node: TLzmaOptimumNode; out LiteralInput: TLzmaOptimumLiteralInput): Boolean;
  TLzmaOptimumRepLensResolver = reference to procedure(const Pos: UInt32;
    const Reps: TLzmaOptimumReps; out RepLens: TLzmaOptimumRepLens);

  TLzmaFastParserMatchCacheEntry = record
    Valid: Boolean;
    Position: NativeUInt;
    MainMatch: TLzmaMatch;
    Matches: TLzmaMatchBuffer;
  end;

  TLzmaFastParserMatchCache = record
  private
    FEntries: array[0..7] of TLzmaFastParserMatchCacheEntry;
  public
    procedure Clear;
    procedure Store(const RelativePos: NativeUInt; const Matches: TLzmaMatchBuffer;
      const MainMatch: TLzmaMatch);
    function TryTake(const RelativePos: NativeUInt; out Matches: TLzmaMatchBuffer;
      out MainMatch: TLzmaMatch): Boolean;
    function Valid: Boolean;
  end;

function LzmaFastParserPrefersRepOverMain(const BestRepLen, MainMatchLength,
  MainMatchDistance: UInt32): Boolean; inline;
function LzmaOptimumPrefersShortRepOverLiteral(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const IsMatchProb, IsRepProb, IsRepG0Prob,
  IsRep0LongProb: CLzmaProb; const Value: Byte; const UseMatchedLiteral: Boolean;
  const MatchByte: Byte; out LiteralPrice, ShortRepPrice: UInt32): Boolean;
function LzmaOptimumPrefersRepOverMatch(const ProbPrices: TLzmaProbPrices;
  const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const IsMatchProb, IsRepProb,
  IsRepG0Prob, IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb;
  const PosState, RepIndex, RepLen, MatchLen, MatchDistance: UInt32;
  out RepPrice, MatchPrice: UInt32): Boolean;
function LzmaOptimumPrefersLiteralThenMatchOverMatch(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const CurrentIsMatchProb,
  CurrentIsRepProb, NextIsMatchProb, NextIsRepProb: CLzmaProb;
  const CurrentPosState, NextPosState: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const CurrentMatchLen, CurrentMatchDistance, NextMatchLen, NextMatchDistance: UInt32;
  out LiteralThenMatchPrice, MatchPrice: UInt32): Boolean;
function LzmaOptimumPrefersLiteralThenRepOverMatch(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const CurrentIsMatchProb,
  CurrentIsRepProb, NextIsMatchProb, NextIsRepProb, NextIsRepG0Prob,
  NextIsRepG1Prob, NextIsRepG2Prob, NextIsRep0LongProb: CLzmaProb;
  const CurrentPosState, NextPosState, RepIndex: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const CurrentMatchLen, CurrentMatchDistance, NextRepLen: UInt32;
  out LiteralThenRepPrice, MatchPrice: UInt32): Boolean;
function LzmaOptimumPrefersMatchLiteralRep0OverMatch(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const CurrentIsMatchProb,
  CurrentIsRepProb, LiteralIsMatchProb, RepIsMatchProb, RepIsRepProb,
  RepIsRepG0Prob, RepIsRep0LongProb: CLzmaProb;
  const CurrentPosState, LiteralPosState, RepPosState: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const FirstMatchLen, FirstMatchDistance, RepLen, CurrentMatchLen,
  CurrentMatchDistance: UInt32; out MatchLiteralRep0Price, MatchPrice: UInt32): Boolean;
procedure LzmaOptimumPrepareNodes(var Nodes: array of TLzmaOptimumNode;
  const StartPrice: UInt32 = 0); overload;
procedure LzmaOptimumPrepareNodes(var Nodes: array of TLzmaOptimumNode;
  const StartPrice, StartState: UInt32; const StartReps: array of UInt32); overload;
procedure LzmaOptimumSeedRepCandidates(var Nodes: array of TLzmaOptimumNode;
  const RepLens: array of UInt32; const ProbPrices: TLzmaProbPrices;
  const RepLenPrices: TLzmaLenPriceEncoder; const IsMatchProb, IsRepProb, IsRepG0Prob,
  IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb; const PosState: UInt32);
procedure LzmaOptimumSeedMatchCandidates(var Nodes: array of TLzmaOptimumNode;
  const Matches: TLzmaMatchBuffer; const ProbPrices: TLzmaProbPrices;
  const LenPrices: TLzmaLenPriceEncoder; const DistancePrices: TLzmaDistancePriceEncoder;
  const IsMatchProb, IsRepProb: CLzmaProb; const PosState, StartLen, MainLen: UInt32);
function LzmaOptimumRelaxRepCandidates(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const RepLens: array of UInt32; const ProbPrices: TLzmaProbPrices;
  const RepLenPrices: TLzmaLenPriceEncoder; const IsMatchProb, IsRepProb, IsRepG0Prob,
  IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb; const PosState: UInt32;
  out BestRelaxedPrice: UInt32): Boolean;
function LzmaOptimumRelaxMatchCandidates(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const Matches: TLzmaMatchBuffer; const ProbPrices: TLzmaProbPrices;
  const LenPrices: TLzmaLenPriceEncoder; const DistancePrices: TLzmaDistancePriceEncoder;
  const IsMatchProb, IsRepProb: CLzmaProb; const PosState, StartLen, MainLen: UInt32;
  out BestRelaxedPrice: UInt32): Boolean;
function LzmaOptimumRelaxMatchLiteralRep0Candidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const MatchIsMatchProb, MatchIsRepProb,
  LiteralIsMatchProb, RepIsMatchProb, RepIsRepProb, RepIsRepG0Prob,
  RepIsRep0LongProb: CLzmaProb; const MatchPosState, LiteralPosState,
  RepPosState: UInt32; const Value: Byte; const UseMatchedLiteral: Boolean;
  const MatchByte: Byte; const FirstMatchLen, FirstMatchDistance, RepLen: UInt32;
  out CandidatePrice: UInt32): Boolean;
function LzmaOptimumRelaxRepLiteralRep0Candidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const RepLenPrices: TLzmaLenPriceEncoder;
  const FirstIsMatchProb, FirstIsRepProb, FirstIsRepG0Prob, FirstIsRepG1Prob,
  FirstIsRepG2Prob, FirstIsRep0LongProb, LiteralIsMatchProb, RepIsMatchProb,
  RepIsRepProb, RepIsRepG0Prob, RepIsRep0LongProb: CLzmaProb;
  const FirstPosState, RepPosState, FirstRepIndex: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const FirstRepLen, RepLen: UInt32; out CandidatePrice: UInt32): Boolean;
function LzmaOptimumRelaxLiteralCandidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const IsMatchProb: CLzmaProb;
  const Value: Byte; const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  out LiteralPrice: UInt32): Boolean;
function LzmaOptimumRelaxShortRepCandidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const IsMatchProb, IsRepProb, IsRepG0Prob, IsRep0LongProb: CLzmaProb;
  out ShortRepPrice: UInt32): Boolean;
function LzmaOptimumRelaxLiteralRep0Candidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const RepLenPrices: TLzmaLenPriceEncoder;
  const LiteralIsMatchProb, RepIsMatchProb, RepIsRepProb, RepIsRepG0Prob,
  RepIsRep0LongProb: CLzmaProb; const RepPosState: UInt32;
  const Value: Byte; const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const RepLen: UInt32; out CandidatePrice: UInt32): Boolean;
function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const RepLensByPos: array of TLzmaOptimumRepLens;
  const PosStates: array of UInt32; const ProbPrices: TLzmaProbPrices;
  const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const IsMatchProb,
  IsRepProb, IsRepG0Prob, IsRepG1Prob, IsRepG2Prob,
  IsRep0LongProb: CLzmaProb): Boolean; overload;
function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const RepLensByPos: array of TLzmaOptimumRepLens;
  const PosStates: array of UInt32;
  const LiteralInputsByPos: array of TLzmaOptimumLiteralInput;
  const ProbPrices: TLzmaProbPrices; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const IsMatchProb,
  IsRepProb, IsRepG0Prob, IsRepG1Prob, IsRepG2Prob,
  IsRep0LongProb: CLzmaProb): Boolean; overload;
function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const RepLensByPos: array of TLzmaOptimumRepLens;
  const PosStates: array of UInt32;
  const LiteralInputsByPos: array of TLzmaOptimumLiteralInput;
  const ProbInputsByPos: array of TLzmaOptimumStateProbInputs;
  const ProbPrices: TLzmaProbPrices; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder): Boolean; overload;
function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const PosStates: array of UInt32;
  const LiteralResolver: TLzmaOptimumLiteralResolver;
  const RepLensResolver: TLzmaOptimumRepLensResolver;
  const ProbInputsByPos: array of TLzmaOptimumStateProbInputs;
  const ProbPrices: TLzmaProbPrices; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder): Boolean; overload;
function LzmaOptimumSelectWindowTarget(const Nodes: array of TLzmaOptimumNode;
  const InitialTargetEnd, WindowEnd, BaselinePrice: UInt32;
  out TargetEnd, TargetPrice: UInt32): Boolean;
function LzmaOptimumReplayFirstDecision(const Nodes: array of TLzmaOptimumNode;
  const EndPos: UInt32; out Len, Back: UInt32): Boolean;
function LzmaOptimumReplayPath(const Nodes: array of TLzmaOptimumNode;
  const EndPos: UInt32; var Decisions: array of TLzmaOptimumDecision;
  out DecisionCount: UInt32): Boolean;
function LzmaOptimumReplaySdkBackward(const Nodes: array of TLzmaOptimumNode;
  const EndPos: UInt32; var Decisions: array of TLzmaOptimumDecision;
  out DecisionCount: UInt32; out BackwardState: TLzmaOptimumBackwardState): Boolean;
procedure LzmaFullOptimumInit(var State: TLzmaFullOptimumState;
  const Enabled: Boolean = False);
procedure LzmaFullOptimumResetWindow(var State: TLzmaFullOptimumState);
procedure LzmaFullOptimumNoteReadMatchDistances(var State: TLzmaFullOptimumState;
  const NumAvail: UInt32; const Matches: TLzmaMatchBuffer; const MainMatch: TLzmaMatch);
function LzmaFullOptimumLoadCachedMatches(const State: TLzmaFullOptimumState;
  out Matches: TLzmaMatchBuffer; out MainMatch: TLzmaMatch): Boolean;
function LzmaFullOptimumBeginDecision(var State: TLzmaFullOptimumState;
  out NumAvail, NumPairs, MainLen: UInt32): Boolean;
function LzmaFullOptimumBackward(var State: TLzmaFullOptimumState;
  const EndPos: UInt32; out Len, Back: UInt32): Boolean;
function LzmaFullOptimumTryReplay(var State: TLzmaFullOptimumState;
  out Len, Back: UInt32): Boolean;
function LzmaFullOptimumMovePos(var State: TLzmaFullOptimumState;
  const Count: UInt32): Boolean;
function LzmaFullOptimumCommitEncodedLen(var State: TLzmaFullOptimumState;
  const Len: UInt32): Boolean;
function LzmaFullOptimumCanRefreshPrices(const State: TLzmaFullOptimumState): Boolean;
procedure LzmaFullOptimumNoteNormalMatch(var State: TLzmaFullOptimumState);
procedure LzmaFullOptimumNoteRepLen(var State: TLzmaFullOptimumState);
procedure LzmaFullOptimumResetRefreshCounters(var State: TLzmaFullOptimumState);

implementation

const
  LZMA_MATCH_MIN_LEN = 2;
  LZMA_OPTIMUM_STATE_LITERAL_NEXT: array[0..11] of UInt32 = (
    0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 4, 5);
  LZMA_OPTIMUM_STATE_MATCH_NEXT: array[0..11] of UInt32 = (
    7, 7, 7, 7, 7, 7, 7, 10, 10, 10, 10, 10);
  LZMA_OPTIMUM_STATE_REP_NEXT: array[0..11] of UInt32 = (
    8, 8, 8, 8, 8, 8, 8, 11, 11, 11, 11, 11);
  LZMA_OPTIMUM_STATE_SHORT_REP_NEXT: array[0..11] of UInt32 = (
    9, 9, 9, 9, 9, 9, 9, 11, 11, 11, 11, 11);

function LzmaClampPriceToUInt32(const Price: UInt64): UInt32; inline;
begin
  if Price > High(UInt32) then
    Exit(High(UInt32));
  Result := UInt32(Price);
end;

function LzmaOptimumStateIndex(const State: UInt32): Integer; inline;
begin
  if State <= UInt32(High(LZMA_OPTIMUM_STATE_LITERAL_NEXT)) then
    Result := Integer(State)
  else
    Result := 0;
end;

function LzmaOptimumIsLiteralState(const State: UInt32): Boolean; inline;
begin
  Result := LzmaOptimumStateIndex(State) < 7;
end;

procedure LzmaOptimumCopyReps(var Target: TLzmaOptimumNode;
  const Source: TLzmaOptimumNode); inline;
var
  Index: Integer;
begin
  for Index := Low(Target.Reps) to High(Target.Reps) do
    Target.Reps[Index] := Source.Reps[Index];
end;

procedure LzmaOptimumSetLiteralContext(var Target: TLzmaOptimumNode;
  const Source: TLzmaOptimumNode); inline;
begin
  Target.State := LZMA_OPTIMUM_STATE_LITERAL_NEXT[LzmaOptimumStateIndex(Source.State)];
  LzmaOptimumCopyReps(Target, Source);
end;

procedure LzmaOptimumSetMatchContext(var Target: TLzmaOptimumNode;
  const Source: TLzmaOptimumNode; const Distance: UInt32); inline;
begin
  Target.State := LZMA_OPTIMUM_STATE_MATCH_NEXT[LzmaOptimumStateIndex(Source.State)];
  Target.Reps[0] := Distance;
  Target.Reps[1] := Source.Reps[0];
  Target.Reps[2] := Source.Reps[1];
  Target.Reps[3] := Source.Reps[2];
end;

procedure LzmaOptimumSetRepContext(var Target: TLzmaOptimumNode;
  const Source: TLzmaOptimumNode; const RepIndex: UInt32;
  const ShortRep: Boolean); inline;
var
  Index: Integer;
  RepDistance: UInt32;
begin
  if ShortRep then
    Target.State := LZMA_OPTIMUM_STATE_SHORT_REP_NEXT[LzmaOptimumStateIndex(Source.State)]
  else
    Target.State := LZMA_OPTIMUM_STATE_REP_NEXT[LzmaOptimumStateIndex(Source.State)];

  if RepIndex > 3 then
    Index := 3
  else
    Index := Integer(RepIndex);

  RepDistance := Source.Reps[Index];
  Target.Reps[0] := RepDistance;
  while Index > 0 do
  begin
    Target.Reps[Index] := Source.Reps[Index - 1];
    Dec(Index);
  end;
  for Index := Integer(RepIndex) + 1 to High(Target.Reps) do
    Target.Reps[Index] := Source.Reps[Index];
end;

procedure LzmaFullOptimumResetRefreshCounters(var State: TLzmaFullOptimumState);
begin
  State.MatchPriceCount := 0;
  State.RepLenEncCounter := LZMA_FULL_OPTIMUM_REP_LEN_COUNT;
end;

procedure LzmaFullOptimumClearReplay(var State: TLzmaFullOptimumState);
begin
  State.ReplayIndex := 0;
  State.ReplayCount := 0;
  SetLength(State.ReplayDecisions, 0);
end;

procedure LzmaFullOptimumResetWindow(var State: TLzmaFullOptimumState);
begin
  State.OptCur := 0;
  State.OptEnd := 0;
  State.LongestMatchLen := 0;
  State.NumPairs := 0;
  State.NumAvail := 0;
  State.CachedMatches.Clear;
  State.CachedMainMatch.Length := 0;
  State.CachedMainMatch.Distance := 0;
  LzmaFullOptimumClearReplay(State);
  SetLength(State.Nodes, LZMA_FULL_OPTIMUM_NUM_OPTS);
  LzmaOptimumPrepareNodes(State.Nodes, 0);
end;

procedure LzmaFullOptimumInit(var State: TLzmaFullOptimumState;
  const Enabled: Boolean);
begin
  State.Enabled := Enabled;
  State.OptCur := 0;
  State.OptEnd := 0;
  State.LongestMatchLen := 0;
  State.NumPairs := 0;
  State.NumAvail := 0;
  State.AdditionalOffset := 0;
  State.BackRes := LZMA_OPTIMUM_BACK_LITERAL;
  State.CachedMatches.Clear;
  State.CachedMainMatch.Length := 0;
  State.CachedMainMatch.Distance := 0;
  LzmaFullOptimumClearReplay(State);
  LzmaFullOptimumResetRefreshCounters(State);
  if Enabled then
    LzmaFullOptimumResetWindow(State)
  else
  begin
    SetLength(State.Nodes, 0);
    SetLength(State.ReplayDecisions, 0);
  end;
end;

procedure LzmaFullOptimumNoteReadMatchDistances(var State: TLzmaFullOptimumState;
  const NumAvail: UInt32; const Matches: TLzmaMatchBuffer; const MainMatch: TLzmaMatch);
begin
  if State.AdditionalOffset < High(UInt32) then
    Inc(State.AdditionalOffset);
  State.NumAvail := NumAvail;
  State.NumPairs := UInt32(Matches.Count) * 2;
  State.LongestMatchLen := MainMatch.Length;
  State.CachedMatches := Matches;
  State.CachedMainMatch := MainMatch;
end;

function LzmaFullOptimumLoadCachedMatches(const State: TLzmaFullOptimumState;
  out Matches: TLzmaMatchBuffer; out MainMatch: TLzmaMatch): Boolean;
begin
  Matches.Clear;
  MainMatch.Length := 0;
  MainMatch.Distance := 0;
  Result := State.AdditionalOffset <> 0;
  if not Result then
    Exit;
  Matches := State.CachedMatches;
  MainMatch := State.CachedMainMatch;
end;

function LzmaFullOptimumBeginDecision(var State: TLzmaFullOptimumState;
  out NumAvail, NumPairs, MainLen: UInt32): Boolean;
begin
  State.OptCur := 0;
  State.OptEnd := 0;
  if State.AdditionalOffset = 0 then
  begin
    NumAvail := 0;
    NumPairs := 0;
    MainLen := 0;
    Exit(True);
  end;

  NumAvail := State.NumAvail;
  NumPairs := State.NumPairs;
  MainLen := State.LongestMatchLen;
  Result := False;
end;

function LzmaFullOptimumDecisionIsUsable(const Decision: TLzmaOptimumDecision): Boolean;
begin
  Result := Decision.Len > 0;
  if not Result then
    Exit;
  if Decision.Back = LZMA_OPTIMUM_BACK_LITERAL then
    Result := Decision.Len = 1
  else if Decision.Len = 1 then
    Result := Decision.Back = 0;
end;

function LzmaFullOptimumBackward(var State: TLzmaFullOptimumState;
  const EndPos: UInt32; out Len, Back: UInt32): Boolean;
var
  BackwardState: TLzmaOptimumBackwardState;
  DecisionCount: UInt32;
  Decisions: TArray<TLzmaOptimumDecision>;
  Index: UInt32;
begin
  Result := False;
  Len := 0;
  Back := LZMA_OPTIMUM_BACK_LITERAL;
  LzmaFullOptimumClearReplay(State);

  if EndPos = 0 then
    Exit;
  SetLength(Decisions, Integer(EndPos));
  if not LzmaOptimumReplaySdkBackward(State.Nodes, EndPos, Decisions,
    DecisionCount, BackwardState) then
    Exit;
  if (DecisionCount = 0) or (not LzmaFullOptimumDecisionIsUsable(Decisions[0])) then
    Exit;

  Len := Decisions[0].Len;
  Back := Decisions[0].Back;
  State.BackRes := Back;
  State.OptCur := BackwardState.OptCur;
  State.OptEnd := BackwardState.OptEnd;

  if DecisionCount > 1 then
  begin
    SetLength(State.ReplayDecisions, Integer(DecisionCount - 1));
    for Index := 1 to DecisionCount - 1 do
    begin
      if not LzmaFullOptimumDecisionIsUsable(Decisions[Integer(Index)]) then
      begin
        LzmaFullOptimumClearReplay(State);
        State.OptCur := 0;
        State.OptEnd := 0;
        Exit;
      end;
      State.ReplayDecisions[Integer(Index - 1)] := Decisions[Integer(Index)];
    end;
    State.ReplayCount := DecisionCount - 1;
    State.ReplayIndex := 0;
  end;

  Result := True;
end;

function LzmaFullOptimumTryReplay(var State: TLzmaFullOptimumState;
  out Len, Back: UInt32): Boolean;
var
  Decision: TLzmaOptimumDecision;
begin
  Result := False;
  Len := 0;
  Back := LZMA_OPTIMUM_BACK_LITERAL;
  if State.ReplayIndex >= State.ReplayCount then
    Exit;

  Decision := State.ReplayDecisions[Integer(State.ReplayIndex)];
  if not LzmaFullOptimumDecisionIsUsable(Decision) then
  begin
    LzmaFullOptimumClearReplay(State);
    State.OptCur := State.OptEnd;
    Exit;
  end;

  Len := Decision.Len;
  Back := Decision.Back;
  Inc(State.ReplayIndex);
  if State.OptCur < State.OptEnd then
    Inc(State.OptCur)
  else
    State.OptCur := State.OptEnd;
  if State.ReplayIndex >= State.ReplayCount then
    LzmaFullOptimumClearReplay(State);
  State.BackRes := Back;
  Result := True;
end;

function LzmaFullOptimumMovePos(var State: TLzmaFullOptimumState;
  const Count: UInt32): Boolean;
begin
  Result := Count <= High(UInt32) - State.AdditionalOffset;
  if Result then
    Inc(State.AdditionalOffset, Count);
end;

function LzmaFullOptimumCommitEncodedLen(var State: TLzmaFullOptimumState;
  const Len: UInt32): Boolean;
begin
  Result := Len <= State.AdditionalOffset;
  if Result then
    Dec(State.AdditionalOffset, Len);
end;

function LzmaFullOptimumCanRefreshPrices(const State: TLzmaFullOptimumState): Boolean;
begin
  Result := State.AdditionalOffset = 0;
end;

procedure LzmaFullOptimumNoteNormalMatch(var State: TLzmaFullOptimumState);
begin
  if State.MatchPriceCount < High(UInt32) then
    Inc(State.MatchPriceCount);
end;

procedure LzmaFullOptimumNoteRepLen(var State: TLzmaFullOptimumState);
begin
  if State.RepLenEncCounter > Low(Integer) then
    Dec(State.RepLenEncCounter);
end;

procedure TLzmaFastParserMatchCache.Clear;
var
  I: Integer;
begin
  for I := Low(FEntries) to High(FEntries) do
  begin
    FEntries[I].Valid := False;
    FEntries[I].Position := 0;
    FEntries[I].MainMatch.Length := 0;
    FEntries[I].MainMatch.Distance := 0;
    FEntries[I].Matches.Clear;
  end;
end;

procedure TLzmaFastParserMatchCache.Store(const RelativePos: NativeUInt;
  const Matches: TLzmaMatchBuffer; const MainMatch: TLzmaMatch);
var
  I: Integer;
  Slot: Integer;
begin
  Slot := Low(FEntries);
  for I := Low(FEntries) to High(FEntries) do
  begin
    if FEntries[I].Valid and (FEntries[I].Position = RelativePos) then
    begin
      Slot := I;
      Break;
    end;
    if (not FEntries[I].Valid) or (FEntries[I].Position < FEntries[Slot].Position) then
      Slot := I;
  end;

  FEntries[Slot].Valid := True;
  FEntries[Slot].Position := RelativePos;
  FEntries[Slot].Matches := Matches;
  FEntries[Slot].MainMatch := MainMatch;
end;

function TLzmaFastParserMatchCache.TryTake(const RelativePos: NativeUInt;
  out Matches: TLzmaMatchBuffer; out MainMatch: TLzmaMatch): Boolean;
var
  I: Integer;
begin
  Result := False;
  Matches.Clear;
  MainMatch.Length := 0;
  MainMatch.Distance := 0;

  for I := Low(FEntries) to High(FEntries) do
  begin
    if FEntries[I].Valid and (FEntries[I].Position < RelativePos) then
      FEntries[I].Valid := False;
    if FEntries[I].Valid and (FEntries[I].Position = RelativePos) then
    begin
      Matches := FEntries[I].Matches;
      MainMatch := FEntries[I].MainMatch;
      FEntries[I].Valid := False;
      Exit(True);
    end;
  end;
end;

function TLzmaFastParserMatchCache.Valid: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(FEntries) to High(FEntries) do
    if FEntries[I].Valid then
      Exit(True);
end;

function LzmaFastParserPrefersRepOverMain(const BestRepLen, MainMatchLength,
  MainMatchDistance: UInt32): Boolean;
begin
  Result := (BestRepLen >= LZMA_MATCH_MIN_LEN) and
    ((BestRepLen + 1 >= MainMatchLength) or
     ((BestRepLen + 2 >= MainMatchLength) and (MainMatchDistance > UInt32(1) shl 9)) or
     ((BestRepLen + 3 >= MainMatchLength) and (MainMatchDistance > UInt32(1) shl 15)));
end;

function LzmaOptimumPrefersShortRepOverLiteral(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const IsMatchProb, IsRepProb, IsRepG0Prob,
  IsRep0LongProb: CLzmaProb; const Value: Byte; const UseMatchedLiteral: Boolean;
  const MatchByte: Byte; out LiteralPrice, ShortRepPrice: UInt32): Boolean;
var
  LiteralPrice64: UInt64;
  ShortRepPrice64: UInt64;
begin
  LiteralPrice64 := LzmaBitPrice(ProbPrices, IsMatchProb, 0);
  if UseMatchedLiteral then
    Inc(LiteralPrice64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte, ProbPrices))
  else
    Inc(LiteralPrice64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));

  ShortRepPrice64 := UInt64(LzmaRepMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb)) +
    LzmaShortRepPrice(ProbPrices, IsRepG0Prob, IsRep0LongProb);
  LiteralPrice := LzmaClampPriceToUInt32(LiteralPrice64);
  ShortRepPrice := LzmaClampPriceToUInt32(ShortRepPrice64);
  Result := (ShortRepPrice64 <= High(UInt32)) and (ShortRepPrice64 < LiteralPrice64);
end;

function LzmaOptimumPrefersRepOverMatch(const ProbPrices: TLzmaProbPrices;
  const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const IsMatchProb, IsRepProb,
  IsRepG0Prob, IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb;
  const PosState, RepIndex, RepLen, MatchLen, MatchDistance: UInt32;
  out RepPrice, MatchPrice: UInt32): Boolean;
var
  MatchPrice64: UInt64;
  RepPrice64: UInt64;
begin
  if (RepLen < LZMA_MATCH_MIN_LEN) or (MatchLen < LZMA_MATCH_MIN_LEN) or
    (MatchDistance = 0) or (MatchDistance > High(UInt32) - 3) then
  begin
    RepPrice := High(UInt32);
    MatchPrice := High(UInt32);
    Exit(False);
  end;

  RepPrice64 := UInt64(LzmaRepMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb)) +
    LzmaPureRepPrice(ProbPrices, IsRepG0Prob, IsRepG1Prob, IsRepG2Prob,
      IsRep0LongProb, RepIndex) +
    LzmaLenPrice(RepLenPrices, PosState, RepLen);

  MatchPrice64 := UInt64(LzmaNormalMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb)) +
    LzmaLenPrice(LenPrices, PosState, MatchLen) +
    LzmaMatchDistancePrice(DistancePrices, MatchLen, MatchDistance);
  RepPrice := LzmaClampPriceToUInt32(RepPrice64);
  MatchPrice := LzmaClampPriceToUInt32(MatchPrice64);
  Result := (RepPrice64 <= High(UInt32)) and (RepPrice64 <= MatchPrice64);
end;

function LzmaOptimumPrefersLiteralThenMatchOverMatch(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const CurrentIsMatchProb,
  CurrentIsRepProb, NextIsMatchProb, NextIsRepProb: CLzmaProb;
  const CurrentPosState, NextPosState: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const CurrentMatchLen, CurrentMatchDistance, NextMatchLen, NextMatchDistance: UInt32;
  out LiteralThenMatchPrice, MatchPrice: UInt32): Boolean;
var
  LiteralThenMatchPrice64: UInt64;
  MatchPrice64: UInt64;
begin
  if (CurrentMatchLen < LZMA_MATCH_MIN_LEN) or
    (NextMatchLen < LZMA_MATCH_MIN_LEN) or
    (CurrentMatchDistance = 0) or
    (CurrentMatchDistance > High(UInt32) - 3) or
    (NextMatchDistance = 0) or
    (NextMatchDistance > High(UInt32) - 3) then
  begin
    LiteralThenMatchPrice := High(UInt32);
    MatchPrice := High(UInt32);
    Exit(False);
  end;

  LiteralThenMatchPrice64 := LzmaBitPrice(ProbPrices, CurrentIsMatchProb, 0);
  if UseMatchedLiteral then
    Inc(LiteralThenMatchPrice64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte, ProbPrices))
  else
    Inc(LiteralThenMatchPrice64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));

  Inc(LiteralThenMatchPrice64,
    UInt64(LzmaNormalMatchPrefixPrice(ProbPrices, NextIsMatchProb, NextIsRepProb)) +
    LzmaLenPrice(LenPrices, NextPosState, NextMatchLen) +
    LzmaMatchDistancePrice(DistancePrices, NextMatchLen, NextMatchDistance));

  MatchPrice64 := UInt64(LzmaNormalMatchPrefixPrice(ProbPrices, CurrentIsMatchProb, CurrentIsRepProb)) +
    LzmaLenPrice(LenPrices, CurrentPosState, CurrentMatchLen) +
    LzmaMatchDistancePrice(DistancePrices, CurrentMatchLen, CurrentMatchDistance);

  LiteralThenMatchPrice := LzmaClampPriceToUInt32(LiteralThenMatchPrice64);
  MatchPrice := LzmaClampPriceToUInt32(MatchPrice64);
  Result := (LiteralThenMatchPrice64 <= High(UInt32)) and
    (LiteralThenMatchPrice64 < MatchPrice64);
end;

function LzmaOptimumPrefersLiteralThenRepOverMatch(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const CurrentIsMatchProb,
  CurrentIsRepProb, NextIsMatchProb, NextIsRepProb, NextIsRepG0Prob,
  NextIsRepG1Prob, NextIsRepG2Prob, NextIsRep0LongProb: CLzmaProb;
  const CurrentPosState, NextPosState, RepIndex: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const CurrentMatchLen, CurrentMatchDistance, NextRepLen: UInt32;
  out LiteralThenRepPrice, MatchPrice: UInt32): Boolean;
var
  LiteralThenRepPrice64: UInt64;
  MatchPrice64: UInt64;
begin
  if (CurrentMatchLen < LZMA_MATCH_MIN_LEN) or
    (NextRepLen < LZMA_MATCH_MIN_LEN) or
    (CurrentMatchDistance = 0) or
    (CurrentMatchDistance > High(UInt32) - 3) then
  begin
    LiteralThenRepPrice := High(UInt32);
    MatchPrice := High(UInt32);
    Exit(False);
  end;

  LiteralThenRepPrice64 := LzmaBitPrice(ProbPrices, CurrentIsMatchProb, 0);
  if UseMatchedLiteral then
    Inc(LiteralThenRepPrice64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte, ProbPrices))
  else
    Inc(LiteralThenRepPrice64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));

  Inc(LiteralThenRepPrice64,
    UInt64(LzmaRepMatchPrefixPrice(ProbPrices, NextIsMatchProb, NextIsRepProb)) +
    LzmaPureRepPrice(ProbPrices, NextIsRepG0Prob, NextIsRepG1Prob, NextIsRepG2Prob,
      NextIsRep0LongProb, RepIndex) +
    LzmaLenPrice(RepLenPrices, NextPosState, NextRepLen));

  MatchPrice64 := UInt64(LzmaNormalMatchPrefixPrice(ProbPrices, CurrentIsMatchProb, CurrentIsRepProb)) +
    LzmaLenPrice(LenPrices, CurrentPosState, CurrentMatchLen) +
    LzmaMatchDistancePrice(DistancePrices, CurrentMatchLen, CurrentMatchDistance);

  LiteralThenRepPrice := LzmaClampPriceToUInt32(LiteralThenRepPrice64);
  MatchPrice := LzmaClampPriceToUInt32(MatchPrice64);
  Result := (LiteralThenRepPrice64 <= High(UInt32)) and
    (LiteralThenRepPrice64 < MatchPrice64);
end;

function LzmaOptimumPrefersMatchLiteralRep0OverMatch(const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const CurrentIsMatchProb,
  CurrentIsRepProb, LiteralIsMatchProb, RepIsMatchProb, RepIsRepProb,
  RepIsRepG0Prob, RepIsRep0LongProb: CLzmaProb;
  const CurrentPosState, LiteralPosState, RepPosState: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const FirstMatchLen, FirstMatchDistance, RepLen, CurrentMatchLen,
  CurrentMatchDistance: UInt32; out MatchLiteralRep0Price, MatchPrice: UInt32): Boolean;
var
  MatchLiteralRep0Price64: UInt64;
  MatchPrice64: UInt64;
begin
  if (FirstMatchLen < LZMA_MATCH_MIN_LEN) or
    (RepLen < LZMA_MATCH_MIN_LEN) or
    (CurrentMatchLen < LZMA_MATCH_MIN_LEN) or
    (FirstMatchDistance = 0) or
    (FirstMatchDistance > High(UInt32) - 3) or
    (CurrentMatchDistance = 0) or
    (CurrentMatchDistance > High(UInt32) - 3) then
  begin
    MatchLiteralRep0Price := High(UInt32);
    MatchPrice := High(UInt32);
    Exit(False);
  end;

  MatchLiteralRep0Price64 := UInt64(LzmaNormalMatchPrefixPrice(ProbPrices, CurrentIsMatchProb,
    CurrentIsRepProb)) + LzmaLenPrice(LenPrices, CurrentPosState, FirstMatchLen) +
    LzmaMatchDistancePrice(DistancePrices, FirstMatchLen, FirstMatchDistance);

  Inc(MatchLiteralRep0Price64, LzmaBitPrice(ProbPrices, LiteralIsMatchProb, 0));
  if UseMatchedLiteral then
    Inc(MatchLiteralRep0Price64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte, ProbPrices))
  else
    Inc(MatchLiteralRep0Price64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));

  Inc(MatchLiteralRep0Price64,
    UInt64(LzmaRepMatchPrefixPrice(ProbPrices, RepIsMatchProb, RepIsRepProb)) +
    LzmaRep0LongPrice(ProbPrices, RepIsRepG0Prob, RepIsRep0LongProb) +
    LzmaLenPrice(RepLenPrices, RepPosState, RepLen));

  MatchPrice64 := UInt64(LzmaNormalMatchPrefixPrice(ProbPrices, CurrentIsMatchProb, CurrentIsRepProb)) +
    LzmaLenPrice(LenPrices, CurrentPosState, CurrentMatchLen) +
    LzmaMatchDistancePrice(DistancePrices, CurrentMatchLen, CurrentMatchDistance);

  MatchLiteralRep0Price := LzmaClampPriceToUInt32(MatchLiteralRep0Price64);
  MatchPrice := LzmaClampPriceToUInt32(MatchPrice64);
  Result := (MatchLiteralRep0Price64 <= High(UInt32)) and
    (MatchLiteralRep0Price64 < MatchPrice64);
end;

procedure LzmaOptimumPrepareNodes(var Nodes: array of TLzmaOptimumNode;
  const StartPrice: UInt32);
var
  EmptyReps: array[0..3] of UInt32;
begin
  FillChar(EmptyReps, SizeOf(EmptyReps), 0);
  LzmaOptimumPrepareNodes(Nodes, StartPrice, 0, EmptyReps);
end;

procedure LzmaOptimumPrepareNodes(var Nodes: array of TLzmaOptimumNode;
  const StartPrice, StartState: UInt32; const StartReps: array of UInt32);
var
  RepIndex: Integer;
  NodeIndex: Integer;
begin
  if Length(Nodes) = 0 then
    Exit;

  FillChar(Nodes[0], Length(Nodes) * SizeOf(TLzmaOptimumNode), 0);
  Nodes[0].Price := StartPrice;
  Nodes[0].State := StartState;
  for RepIndex := Low(Nodes[0].Reps) to High(Nodes[0].Reps) do
  begin
    if RepIndex <= High(StartReps) then
      Nodes[0].Reps[RepIndex] := StartReps[RepIndex]
    else
      Nodes[0].Reps[RepIndex] := 0;
  end;
  for NodeIndex := 1 to High(Nodes) do
    Nodes[NodeIndex].Price := High(UInt32);
end;

procedure LzmaOptimumSeedRepCandidates(var Nodes: array of TLzmaOptimumNode;
  const RepLens: array of UInt32; const ProbPrices: TLzmaProbPrices;
  const RepLenPrices: TLzmaLenPriceEncoder; const IsMatchProb, IsRepProb, IsRepG0Prob,
  IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb; const PosState: UInt32);
var
  Back: UInt32;
  CandidatePrice64: UInt64;
  Len: UInt32;
  MaxLen: UInt32;
  PrefixPrice64: UInt64;
  PureRepPrice: UInt32;
  Price: UInt32;
  RepIndex: Integer;
  RepLen: UInt32;
begin
  if (Length(Nodes) = 0) or (Length(RepLens) = 0) then
    Exit;

  MaxLen := UInt32(Length(Nodes) - 1);
  if MaxLen < LZMA_MATCH_MIN_LEN then
    Exit;
  if Nodes[0].Price = High(UInt32) then
    Exit;

  PrefixPrice64 := UInt64(Nodes[0].Price) +
    LzmaRepMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb);
  for RepIndex := Low(RepLens) to High(RepLens) do
  begin
    if RepIndex > 3 then
      Break;

    RepLen := RepLens[RepIndex];
    if RepLen < LZMA_MATCH_MIN_LEN then
      Continue;
    if RepLen > MaxLen then
      RepLen := MaxLen;

    Back := UInt32(RepIndex);
    PureRepPrice := LzmaPureRepPrice(ProbPrices, IsRepG0Prob, IsRepG1Prob,
      IsRepG2Prob, IsRep0LongProb, Back);
    Len := RepLen;
    while Len >= LZMA_MATCH_MIN_LEN do
    begin
      CandidatePrice64 := PrefixPrice64 + PureRepPrice +
        LzmaLenPrice(RepLenPrices, PosState, Len);
      if CandidatePrice64 <= High(UInt32) then
      begin
        Price := UInt32(CandidatePrice64);
        if Price < Nodes[Len].Price then
        begin
          Nodes[Len].Price := Price;
          Nodes[Len].PathLen := Len;
          Nodes[Len].PathBack := Back;
          Nodes[Len].Extra := 0;
          Nodes[Len].PosPrev := 0;
          Nodes[Len].BackPrev := Back;
          Nodes[Len].Prev1IsLiteral := False;
          Nodes[Len].PosPrev2 := 0;
          Nodes[Len].BackPrev2 := 0;
          LzmaOptimumSetRepContext(Nodes[Len], Nodes[0], Back, False);
        end;
      end;

      if Len = LZMA_MATCH_MIN_LEN then
        Break;
      Dec(Len);
    end;
  end;
end;

procedure LzmaOptimumSeedMatchCandidates(var Nodes: array of TLzmaOptimumNode;
  const Matches: TLzmaMatchBuffer; const ProbPrices: TLzmaProbPrices;
  const LenPrices: TLzmaLenPriceEncoder; const DistancePrices: TLzmaDistancePriceEncoder;
  const IsMatchProb, IsRepProb: CLzmaProb; const PosState, StartLen, MainLen: UInt32);
var
  Back: UInt32;
  CandidatePrice64: UInt64;
  Len: UInt32;
  MaxLen: UInt32;
  PairIndex: Integer;
  PrefixPrice64: UInt64;
  Price: UInt32;
begin
  if (Length(Nodes) = 0) or (Matches.Count <= 0) or (MainLen < LZMA_MATCH_MIN_LEN) then
    Exit;

  Len := StartLen;
  if Len < LZMA_MATCH_MIN_LEN then
    Len := LZMA_MATCH_MIN_LEN;

  MaxLen := MainLen;
  if MaxLen >= UInt32(Length(Nodes)) then
    MaxLen := UInt32(Length(Nodes) - 1);
  if Len > MaxLen then
    Exit;
  if Nodes[0].Price = High(UInt32) then
    Exit;

  PairIndex := 0;
  PrefixPrice64 := UInt64(Nodes[0].Price) +
    LzmaNormalMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb);
  while Len <= MaxLen do
  begin
    while (PairIndex < Matches.Count) and (Len > Matches.Items[PairIndex].Length) do
      Inc(PairIndex);
    if PairIndex >= Matches.Count then
      Exit;
    if (Matches.Items[PairIndex].Distance = 0) or
      (Matches.Items[PairIndex].Distance > High(UInt32) - 3) then
    begin
      Inc(Len);
      Continue;
    end;

    CandidatePrice64 := PrefixPrice64 + LzmaLenPrice(LenPrices, PosState, Len) +
      LzmaMatchDistancePrice(DistancePrices, Len, Matches.Items[PairIndex].Distance);
    if CandidatePrice64 <= High(UInt32) then
    begin
      Price := UInt32(CandidatePrice64);
      if Price < Nodes[Len].Price then
      begin
        Back := Matches.Items[PairIndex].Distance + 3;
        Nodes[Len].Price := Price;
        Nodes[Len].PathLen := Len;
        Nodes[Len].PathBack := Back;
        Nodes[Len].Extra := 0;
        Nodes[Len].PosPrev := 0;
        Nodes[Len].BackPrev := Back;
        Nodes[Len].Prev1IsLiteral := False;
        Nodes[Len].PosPrev2 := 0;
        Nodes[Len].BackPrev2 := 0;
        LzmaOptimumSetMatchContext(Nodes[Len], Nodes[0],
          Matches.Items[PairIndex].Distance);
      end;
    end;

    Inc(Len);
  end;
end;

function LzmaOptimumRelaxRepCandidates(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const RepLens: array of UInt32; const ProbPrices: TLzmaProbPrices;
  const RepLenPrices: TLzmaLenPriceEncoder; const IsMatchProb, IsRepProb, IsRepG0Prob,
  IsRepG1Prob, IsRepG2Prob, IsRep0LongProb: CLzmaProb; const PosState: UInt32;
  out BestRelaxedPrice: UInt32): Boolean;
var
  Back: UInt32;
  Len: UInt32;
  MaxLen: UInt32;
  CandidatePrice64: UInt64;
  NextPos: UInt32;
  PrefixPrice64: UInt64;
  PureRepPrice: UInt32;
  Price: UInt32;
  RepIndex: Integer;
  RepLen: UInt32;
begin
  Result := False;
  BestRelaxedPrice := 0;

  if (Length(Nodes) = 0) or (Length(RepLens) = 0) then
    Exit;
  if Pos >= UInt32(Length(Nodes) - 1) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;

  MaxLen := UInt32(Length(Nodes) - 1) - Pos;
  if MaxLen < LZMA_MATCH_MIN_LEN then
    Exit;

  PrefixPrice64 := UInt64(Nodes[Pos].Price) +
    LzmaRepMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb);
  for RepIndex := Low(RepLens) to High(RepLens) do
  begin
    if RepIndex > 3 then
      Break;

    RepLen := RepLens[RepIndex];
    if RepLen < LZMA_MATCH_MIN_LEN then
      Continue;
    if RepLen > MaxLen then
      RepLen := MaxLen;

    Back := UInt32(RepIndex);
    PureRepPrice := LzmaPureRepPrice(ProbPrices, IsRepG0Prob, IsRepG1Prob,
      IsRepG2Prob, IsRep0LongProb, Back);
    Len := RepLen;
    while Len >= LZMA_MATCH_MIN_LEN do
    begin
      NextPos := Pos + Len;
      CandidatePrice64 := PrefixPrice64 + PureRepPrice +
        LzmaLenPrice(RepLenPrices, PosState, Len);
      if CandidatePrice64 > High(UInt32) then
      begin
        if Len = LZMA_MATCH_MIN_LEN then
          Break;
        Dec(Len);
        Continue;
      end;

      Price := UInt32(CandidatePrice64);
      if Price < Nodes[NextPos].Price then
      begin
        Nodes[NextPos].Price := Price;
        Nodes[NextPos].PathLen := Len;
        Nodes[NextPos].PathBack := Back;
        Nodes[NextPos].Extra := 0;
        Nodes[NextPos].PosPrev := Pos;
        Nodes[NextPos].BackPrev := Back;
        Nodes[NextPos].Prev1IsLiteral := False;
        Nodes[NextPos].PosPrev2 := 0;
        Nodes[NextPos].BackPrev2 := 0;
        LzmaOptimumSetRepContext(Nodes[NextPos], Nodes[Pos], Back, False);
        if (not Result) or (Price < BestRelaxedPrice) then
          BestRelaxedPrice := Price;
        Result := True;
      end;

      if Len = LZMA_MATCH_MIN_LEN then
        Break;
      Dec(Len);
    end;
  end;
end;

function LzmaOptimumRelaxMatchCandidates(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const Matches: TLzmaMatchBuffer; const ProbPrices: TLzmaProbPrices;
  const LenPrices: TLzmaLenPriceEncoder; const DistancePrices: TLzmaDistancePriceEncoder;
  const IsMatchProb, IsRepProb: CLzmaProb; const PosState, StartLen, MainLen: UInt32;
  out BestRelaxedPrice: UInt32): Boolean;
var
  Back: UInt32;
  Len: UInt32;
  MaxLen: UInt32;
  CandidatePrice64: UInt64;
  NextPos: UInt32;
  PairIndex: Integer;
  PrefixPrice64: UInt64;
  Price: UInt32;
begin
  Result := False;
  BestRelaxedPrice := 0;

  if (Length(Nodes) = 0) or (Matches.Count <= 0) or (MainLen < LZMA_MATCH_MIN_LEN) then
    Exit;
  if Pos >= UInt32(Length(Nodes) - 1) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;

  Len := StartLen;
  if Len < LZMA_MATCH_MIN_LEN then
    Len := LZMA_MATCH_MIN_LEN;

  MaxLen := UInt32(Length(Nodes) - 1) - Pos;
  if MainLen < MaxLen then
    MaxLen := MainLen;
  if Len > MaxLen then
    Exit;

  PairIndex := 0;
  PrefixPrice64 := UInt64(Nodes[Pos].Price) +
    LzmaNormalMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb);
  while Len <= MaxLen do
  begin
    while (PairIndex < Matches.Count) and (Len > Matches.Items[PairIndex].Length) do
      Inc(PairIndex);
    if PairIndex >= Matches.Count then
      Exit;
    if (Matches.Items[PairIndex].Distance = 0) or
      (Matches.Items[PairIndex].Distance > High(UInt32) - 3) then
    begin
      Inc(Len);
      Continue;
    end;

    NextPos := Pos + Len;
    CandidatePrice64 := PrefixPrice64 + LzmaLenPrice(LenPrices, PosState, Len) +
      LzmaMatchDistancePrice(DistancePrices, Len, Matches.Items[PairIndex].Distance);
    if CandidatePrice64 > High(UInt32) then
    begin
      Inc(Len);
      Continue;
    end;

    Price := UInt32(CandidatePrice64);
    if Price < Nodes[NextPos].Price then
    begin
      Back := Matches.Items[PairIndex].Distance + 3;
      Nodes[NextPos].Price := Price;
      Nodes[NextPos].PathLen := Len;
      Nodes[NextPos].PathBack := Back;
      Nodes[NextPos].Extra := 0;
      Nodes[NextPos].PosPrev := Pos;
      Nodes[NextPos].BackPrev := Back;
      Nodes[NextPos].Prev1IsLiteral := False;
      Nodes[NextPos].PosPrev2 := 0;
      Nodes[NextPos].BackPrev2 := 0;
      LzmaOptimumSetMatchContext(Nodes[NextPos], Nodes[Pos],
        Matches.Items[PairIndex].Distance);
      if (not Result) or (Price < BestRelaxedPrice) then
        BestRelaxedPrice := Price;
      Result := True;
    end;

    Inc(Len);
  end;
end;

function LzmaOptimumRelaxMatchLiteralRep0Candidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const MatchIsMatchProb, MatchIsRepProb,
  LiteralIsMatchProb, RepIsMatchProb, RepIsRepProb, RepIsRepG0Prob,
  RepIsRep0LongProb: CLzmaProb; const MatchPosState, LiteralPosState,
  RepPosState: UInt32; const Value: Byte; const UseMatchedLiteral: Boolean;
  const MatchByte: Byte; const FirstMatchLen, FirstMatchDistance, RepLen: UInt32;
  out CandidatePrice: UInt32): Boolean;
var
  CandidatePrice64: UInt64;
  EndPos64: UInt64;
  EndPos: UInt32;
  FirstBack: UInt32;
  LiteralNode: TLzmaOptimumNode;
  MatchNode: TLzmaOptimumNode;
begin
  Result := False;
  CandidatePrice := 0;

  if Length(Nodes) = 0 then
    Exit;
  if Pos >= UInt32(Length(Nodes)) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;
  if (FirstMatchLen < LZMA_MATCH_MIN_LEN) or (RepLen < LZMA_MATCH_MIN_LEN) then
    Exit;
  if (FirstMatchDistance = 0) or (FirstMatchDistance > High(UInt32) - 3) then
    Exit;

  EndPos64 := UInt64(Pos) + UInt64(FirstMatchLen) + 1 + UInt64(RepLen);
  if EndPos64 >= UInt64(Length(Nodes)) then
    Exit;
  EndPos := UInt32(EndPos64);

  CandidatePrice64 := UInt64(Nodes[Pos].Price) +
    LzmaNormalMatchPrefixPrice(ProbPrices, MatchIsMatchProb, MatchIsRepProb) +
    LzmaLenPrice(LenPrices, MatchPosState, FirstMatchLen) +
    LzmaMatchDistancePrice(DistancePrices, FirstMatchLen, FirstMatchDistance) +
    LzmaBitPrice(ProbPrices, LiteralIsMatchProb, 0);
  if UseMatchedLiteral then
    Inc(CandidatePrice64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte, ProbPrices))
  else
    Inc(CandidatePrice64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));
  Inc(CandidatePrice64,
    LzmaRepMatchPrefixPrice(ProbPrices, RepIsMatchProb, RepIsRepProb) +
    LzmaRep0LongPrice(ProbPrices, RepIsRepG0Prob, RepIsRep0LongProb) +
    LzmaLenPrice(RepLenPrices, RepPosState, RepLen));
  if CandidatePrice64 > High(UInt32) then
    Exit;

  CandidatePrice := UInt32(CandidatePrice64);

  if CandidatePrice >= Nodes[EndPos].Price then
    Exit;

  FirstBack := FirstMatchDistance + 3;
  Nodes[EndPos].Price := CandidatePrice;
  Nodes[EndPos].PathLen := RepLen;
  Nodes[EndPos].PathBack := FirstBack;
  Nodes[EndPos].Extra := FirstMatchLen + 1;
  Nodes[EndPos].PosPrev := Pos + FirstMatchLen + 1;
  Nodes[EndPos].BackPrev := 0;
  Nodes[EndPos].Prev1IsLiteral := False;
  Nodes[EndPos].PosPrev2 := 0;
  Nodes[EndPos].BackPrev2 := 0;
  MatchNode := Nodes[Pos];
  LzmaOptimumSetMatchContext(MatchNode, Nodes[Pos], FirstMatchDistance);
  LzmaOptimumSetLiteralContext(LiteralNode, MatchNode);
  LzmaOptimumSetRepContext(Nodes[EndPos], LiteralNode, 0, False);
  Result := True;
end;

function LzmaOptimumRelaxRepLiteralRep0Candidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const RepLenPrices: TLzmaLenPriceEncoder;
  const FirstIsMatchProb, FirstIsRepProb, FirstIsRepG0Prob, FirstIsRepG1Prob,
  FirstIsRepG2Prob, FirstIsRep0LongProb, LiteralIsMatchProb, RepIsMatchProb,
  RepIsRepProb, RepIsRepG0Prob, RepIsRep0LongProb: CLzmaProb;
  const FirstPosState, RepPosState, FirstRepIndex: UInt32; const Value: Byte;
  const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const FirstRepLen, RepLen: UInt32; out CandidatePrice: UInt32): Boolean;
var
  CandidatePrice64: UInt64;
  EndPos: UInt32;
  EndPos64: UInt64;
  LiteralNode: TLzmaOptimumNode;
  RepNode: TLzmaOptimumNode;
begin
  Result := False;
  CandidatePrice := 0;

  if Length(Nodes) = 0 then
    Exit;
  if Pos >= UInt32(Length(Nodes)) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;
  if FirstRepIndex > 3 then
    Exit;
  if (FirstRepLen < LZMA_MATCH_MIN_LEN) or (RepLen < LZMA_MATCH_MIN_LEN) then
    Exit;

  EndPos64 := UInt64(Pos) + UInt64(FirstRepLen) + 1 + UInt64(RepLen);
  if EndPos64 >= UInt64(Length(Nodes)) then
    Exit;
  EndPos := UInt32(EndPos64);

  CandidatePrice64 := UInt64(Nodes[Pos].Price) +
    LzmaRepMatchPrefixPrice(ProbPrices, FirstIsMatchProb, FirstIsRepProb) +
    LzmaPureRepPrice(ProbPrices, FirstIsRepG0Prob, FirstIsRepG1Prob,
      FirstIsRepG2Prob, FirstIsRep0LongProb, FirstRepIndex) +
    LzmaLenPrice(RepLenPrices, FirstPosState, FirstRepLen) +
    LzmaBitPrice(ProbPrices, LiteralIsMatchProb, 0);
  if UseMatchedLiteral then
    Inc(CandidatePrice64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte, ProbPrices))
  else
    Inc(CandidatePrice64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));
  Inc(CandidatePrice64,
    LzmaRepMatchPrefixPrice(ProbPrices, RepIsMatchProb, RepIsRepProb) +
    LzmaRep0LongPrice(ProbPrices, RepIsRepG0Prob, RepIsRep0LongProb) +
    LzmaLenPrice(RepLenPrices, RepPosState, RepLen));
  if CandidatePrice64 > High(UInt32) then
    Exit;

  CandidatePrice := UInt32(CandidatePrice64);
  if CandidatePrice >= Nodes[EndPos].Price then
    Exit;

  Nodes[EndPos].Price := CandidatePrice;
  Nodes[EndPos].PathLen := RepLen;
  Nodes[EndPos].PathBack := FirstRepIndex;
  Nodes[EndPos].Extra := FirstRepLen + 1;
  Nodes[EndPos].PosPrev := Pos + FirstRepLen + 1;
  Nodes[EndPos].BackPrev := 0;
  Nodes[EndPos].Prev1IsLiteral := False;
  Nodes[EndPos].PosPrev2 := 0;
  Nodes[EndPos].BackPrev2 := 0;
  RepNode := Nodes[Pos];
  LzmaOptimumSetRepContext(RepNode, Nodes[Pos], FirstRepIndex, False);
  LzmaOptimumSetLiteralContext(LiteralNode, RepNode);
  LzmaOptimumSetRepContext(Nodes[EndPos], LiteralNode, 0, False);
  Result := True;
end;

function LzmaOptimumRelaxLiteralCandidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const IsMatchProb: CLzmaProb;
  const Value: Byte; const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  out LiteralPrice: UInt32): Boolean;
var
  CandidatePrice64: UInt64;
  NextPos: UInt32;
begin
  Result := False;
  LiteralPrice := 0;

  if Length(Nodes) = 0 then
    Exit;
  if Pos >= UInt32(Length(Nodes) - 1) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;

  NextPos := Pos + 1;
  CandidatePrice64 := UInt64(Nodes[Pos].Price) + LzmaBitPrice(ProbPrices, IsMatchProb, 0);
  if UseMatchedLiteral then
    Inc(CandidatePrice64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte, ProbPrices))
  else
    Inc(CandidatePrice64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));
  if CandidatePrice64 > High(UInt32) then
    Exit;

  LiteralPrice := UInt32(CandidatePrice64);

  if LiteralPrice >= Nodes[NextPos].Price then
    Exit;

  Nodes[NextPos].Price := LiteralPrice;
  Nodes[NextPos].PathLen := 1;
  Nodes[NextPos].PathBack := LZMA_OPTIMUM_BACK_LITERAL;
  Nodes[NextPos].Extra := 0;
  Nodes[NextPos].PosPrev := Pos;
  Nodes[NextPos].BackPrev := LZMA_OPTIMUM_BACK_LITERAL;
  Nodes[NextPos].Prev1IsLiteral := False;
  Nodes[NextPos].PosPrev2 := 0;
  Nodes[NextPos].BackPrev2 := 0;
  LzmaOptimumSetLiteralContext(Nodes[NextPos], Nodes[Pos]);
  Result := True;
end;

function LzmaOptimumRelaxShortRepCandidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const IsMatchProb, IsRepProb, IsRepG0Prob, IsRep0LongProb: CLzmaProb;
  out ShortRepPrice: UInt32): Boolean;
var
  CandidatePrice64: UInt64;
  NextPos: UInt32;
begin
  Result := False;
  ShortRepPrice := 0;

  if Length(Nodes) = 0 then
    Exit;
  if Pos >= UInt32(Length(Nodes) - 1) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;

  NextPos := Pos + 1;
  CandidatePrice64 := UInt64(Nodes[Pos].Price) +
    LzmaRepMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb) +
    LzmaShortRepPrice(ProbPrices, IsRepG0Prob, IsRep0LongProb);
  if CandidatePrice64 > High(UInt32) then
    Exit;

  ShortRepPrice := UInt32(CandidatePrice64);
  if ShortRepPrice >= Nodes[NextPos].Price then
    Exit;

  Nodes[NextPos].Price := ShortRepPrice;
  Nodes[NextPos].PathLen := 1;
  Nodes[NextPos].PathBack := 0;
  Nodes[NextPos].Extra := 0;
  Nodes[NextPos].PosPrev := Pos;
  Nodes[NextPos].BackPrev := 0;
  Nodes[NextPos].Prev1IsLiteral := False;
  Nodes[NextPos].PosPrev2 := 0;
  Nodes[NextPos].BackPrev2 := 0;
  LzmaOptimumSetRepContext(Nodes[NextPos], Nodes[Pos], 0, True);
  Result := True;
end;

function LzmaOptimumRelaxSdkLiteralCandidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralInput: TLzmaOptimumLiteralInput; const IsMatchProb: CLzmaProb;
  out LiteralPrice: UInt32; out NextIsLit: Boolean): Boolean;
var
  LiteralPrefixPrice64: UInt64;
  NextPos: UInt32;
begin
  Result := False;
  LiteralPrice := 0;
  NextIsLit := False;

  if (Length(Nodes) = 0) or (not LiteralInput.Enabled) then
    Exit;
  if Pos >= UInt32(Length(Nodes) - 1) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;

  NextPos := Pos + 1;
  LiteralPrefixPrice64 := UInt64(Nodes[Pos].Price) +
    LzmaBitPrice(ProbPrices, IsMatchProb, 0);
  if ((Nodes[NextPos].Price < High(UInt32)) and
      (LiteralInput.MatchByte = LiteralInput.Value)) or
    (LiteralPrefixPrice64 > Nodes[NextPos].Price) then
    Exit;

  Result := LzmaOptimumRelaxLiteralCandidate(Nodes, Pos, ProbPrices,
    LiteralInput.LiteralProbs, IsMatchProb, LiteralInput.Value,
    LiteralInput.UseMatchedLiteral, LiteralInput.MatchByte, LiteralPrice);
  NextIsLit := Result;
end;

function LzmaOptimumCanRelaxSdkShortRep(const Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const IsMatchProb, IsRepProb: CLzmaProb): Boolean;
var
  NextPos: UInt32;
  RepMatchPrice64: UInt64;
begin
  Result := False;
  if Length(Nodes) = 0 then
    Exit;
  if Pos >= UInt32(Length(Nodes) - 1) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;
  if not LzmaOptimumIsLiteralState(Nodes[Pos].State) then
    Exit;

  NextPos := Pos + 1;
  RepMatchPrice64 := UInt64(Nodes[Pos].Price) +
    LzmaRepMatchPrefixPrice(ProbPrices, IsMatchProb, IsRepProb);
  if RepMatchPrice64 >= Nodes[NextPos].Price then
    Exit;
  if (Nodes[NextPos].PathLen >= LZMA_MATCH_MIN_LEN) and
    (Nodes[NextPos].PathBack = 0) then
    Exit;

  Result := True;
end;

function LzmaOptimumRelaxLiteralRep0Candidate(var Nodes: array of TLzmaOptimumNode;
  const Pos: UInt32; const ProbPrices: TLzmaProbPrices;
  const LiteralProbs: TLzmaLiteralProbs; const RepLenPrices: TLzmaLenPriceEncoder;
  const LiteralIsMatchProb, RepIsMatchProb, RepIsRepProb, RepIsRepG0Prob,
  RepIsRep0LongProb: CLzmaProb; const RepPosState: UInt32;
  const Value: Byte; const UseMatchedLiteral: Boolean; const MatchByte: Byte;
  const RepLen: UInt32; out CandidatePrice: UInt32): Boolean;
var
  CandidatePrice64: UInt64;
  EndPos: UInt32;
  EndPos64: UInt64;
  LiteralNode: TLzmaOptimumNode;
begin
  Result := False;
  CandidatePrice := 0;

  if Length(Nodes) = 0 then
    Exit;
  if Pos >= UInt32(Length(Nodes)) then
    Exit;
  if Nodes[Pos].Price = High(UInt32) then
    Exit;
  if RepLen < LZMA_MATCH_MIN_LEN then
    Exit;

  EndPos64 := UInt64(Pos) + 1 + UInt64(RepLen);
  if EndPos64 >= UInt64(Length(Nodes)) then
    Exit;
  EndPos := UInt32(EndPos64);

  CandidatePrice64 := UInt64(Nodes[Pos].Price) +
    LzmaBitPrice(ProbPrices, LiteralIsMatchProb, 0);
  if UseMatchedLiteral then
    Inc(CandidatePrice64, LzmaMatchedLiteralPrice(LiteralProbs, Value, MatchByte,
      ProbPrices))
  else
    Inc(CandidatePrice64, LzmaLiteralPrice(LiteralProbs, Value, ProbPrices));
  Inc(CandidatePrice64,
    LzmaRepMatchPrefixPrice(ProbPrices, RepIsMatchProb, RepIsRepProb) +
    LzmaRep0LongPrice(ProbPrices, RepIsRepG0Prob, RepIsRep0LongProb) +
    LzmaLenPrice(RepLenPrices, RepPosState, RepLen));
  if CandidatePrice64 > High(UInt32) then
    Exit;

  CandidatePrice := UInt32(CandidatePrice64);
  if CandidatePrice >= Nodes[EndPos].Price then
    Exit;

  Nodes[EndPos].Price := CandidatePrice;
  Nodes[EndPos].PathLen := RepLen;
  Nodes[EndPos].PathBack := 0;
  Nodes[EndPos].Extra := 1;
  Nodes[EndPos].PosPrev := Pos + 1;
  Nodes[EndPos].BackPrev := 0;
  Nodes[EndPos].Prev1IsLiteral := False;
  Nodes[EndPos].PosPrev2 := 0;
  Nodes[EndPos].BackPrev2 := 0;
  LiteralNode := Nodes[Pos];
  LzmaOptimumSetLiteralContext(LiteralNode, Nodes[Pos]);
  LzmaOptimumSetRepContext(Nodes[EndPos], LiteralNode, 0, False);
  Result := True;
end;

function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const RepLensByPos: array of TLzmaOptimumRepLens;
  const PosStates: array of UInt32; const ProbPrices: TLzmaProbPrices;
  const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const IsMatchProb,
  IsRepProb, IsRepG0Prob, IsRepG1Prob, IsRepG2Prob,
  IsRep0LongProb: CLzmaProb): Boolean;
var
  EmptyLiteralInputs: TArray<TLzmaOptimumLiteralInput>;
begin
  SetLength(EmptyLiteralInputs, 0);
  Result := LzmaOptimumRelaxWindow(Nodes, MatchesByPos, RepLensByPos,
    PosStates, EmptyLiteralInputs, ProbPrices, LenPrices, RepLenPrices,
    DistancePrices, IsMatchProb, IsRepProb, IsRepG0Prob, IsRepG1Prob,
    IsRepG2Prob, IsRep0LongProb);
end;

function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const RepLensByPos: array of TLzmaOptimumRepLens;
  const PosStates: array of UInt32;
  const LiteralInputsByPos: array of TLzmaOptimumLiteralInput;
  const ProbPrices: TLzmaProbPrices; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder; const IsMatchProb,
  IsRepProb, IsRepG0Prob, IsRepG1Prob, IsRepG2Prob,
  IsRep0LongProb: CLzmaProb): Boolean;
var
  BestRelaxedPrice: UInt32;
  LiteralPrice: UInt32;
  MatchIndex: Integer;
  MatchStartLen: UInt32;
  MainLen: UInt32;
  NextIsLit: Boolean;
  PosIndex: Integer;
  PosState: UInt32;
begin
  Result := False;
  if Length(Nodes) <= 1 then
    Exit;

  for PosIndex := 0 to High(Nodes) - 1 do
  begin
    if Nodes[PosIndex].Price = High(UInt32) then
      Continue;

    MatchStartLen := LZMA_MATCH_MIN_LEN;
    NextIsLit := False;
    PosState := 0;
    if PosIndex <= High(PosStates) then
      PosState := PosStates[PosIndex];

    if (PosIndex <= High(LiteralInputsByPos)) and
      LiteralInputsByPos[PosIndex].Enabled then
    begin
      if LzmaOptimumRelaxSdkLiteralCandidate(Nodes, UInt32(PosIndex),
        ProbPrices, LiteralInputsByPos[PosIndex], IsMatchProb, LiteralPrice,
        NextIsLit) then
        Result := True;
    end;

    if PosIndex <= High(RepLensByPos) then
    begin
      if (RepLensByPos[PosIndex][0] > 0) and
        LzmaOptimumCanRelaxSdkShortRep(Nodes, UInt32(PosIndex), ProbPrices,
          IsMatchProb, IsRepProb) then
      begin
        if LzmaOptimumRelaxShortRepCandidate(Nodes, UInt32(PosIndex),
          ProbPrices, IsMatchProb, IsRepProb, IsRepG0Prob, IsRep0LongProb,
          BestRelaxedPrice) then
        begin
          NextIsLit := False;
          Result := True;
        end;
      end;

      if LzmaOptimumRelaxRepCandidates(Nodes, UInt32(PosIndex),
        RepLensByPos[PosIndex], ProbPrices, RepLenPrices, IsMatchProb,
        IsRepProb, IsRepG0Prob, IsRepG1Prob, IsRepG2Prob, IsRep0LongProb,
        PosState, BestRelaxedPrice) then
        Result := True;
      if RepLensByPos[PosIndex][0] >= LZMA_MATCH_MIN_LEN then
        MatchStartLen := RepLensByPos[PosIndex][0] + 1;
    end;

    if PosIndex <= High(MatchesByPos) then
    begin
      MainLen := 0;
      for MatchIndex := 0 to MatchesByPos[PosIndex].Count - 1 do
      begin
        if MatchesByPos[PosIndex].Items[MatchIndex].Length > MainLen then
          MainLen := MatchesByPos[PosIndex].Items[MatchIndex].Length;
      end;

      if MainLen >= LZMA_MATCH_MIN_LEN then
      begin
        if LzmaOptimumRelaxMatchCandidates(Nodes, UInt32(PosIndex),
          MatchesByPos[PosIndex], ProbPrices, LenPrices, DistancePrices,
          IsMatchProb, IsRepProb, PosState, MatchStartLen, MainLen,
          BestRelaxedPrice) then
          Result := True;
      end;
    end;
  end;
end;

function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const RepLensByPos: array of TLzmaOptimumRepLens;
  const PosStates: array of UInt32;
  const LiteralInputsByPos: array of TLzmaOptimumLiteralInput;
  const ProbInputsByPos: array of TLzmaOptimumStateProbInputs;
  const ProbPrices: TLzmaProbPrices; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder): Boolean;
var
  BestRelaxedPrice: UInt32;
  CurrentProbs: TLzmaOptimumProbInput;
  LiteralPrice: UInt32;
  MatchIndex: Integer;
  MatchStartLen: UInt32;
  MainLen: UInt32;
  NextIsLit: Boolean;
  PosIndex: Integer;
  PosState: UInt32;
  StateIndex: UInt32;
begin
  Result := False;
  if Length(Nodes) <= 1 then
    Exit;

  for PosIndex := 0 to High(Nodes) - 1 do
  begin
    if Nodes[PosIndex].Price = High(UInt32) then
      Continue;

    MatchStartLen := LZMA_MATCH_MIN_LEN;
    NextIsLit := False;
    PosState := 0;
    if PosIndex <= High(PosStates) then
      PosState := PosStates[PosIndex];

    CurrentProbs.IsMatchProb := LZMA_PROB_INIT;
    CurrentProbs.IsRepProb := LZMA_PROB_INIT;
    CurrentProbs.IsRepG0Prob := LZMA_PROB_INIT;
    CurrentProbs.IsRepG1Prob := LZMA_PROB_INIT;
    CurrentProbs.IsRepG2Prob := LZMA_PROB_INIT;
    CurrentProbs.IsRep0LongProb := LZMA_PROB_INIT;
    if PosIndex <= High(ProbInputsByPos) then
    begin
      StateIndex := LzmaOptimumStateIndex(Nodes[PosIndex].State);
      CurrentProbs := ProbInputsByPos[PosIndex][Integer(StateIndex)];
    end;

    if (PosIndex <= High(LiteralInputsByPos)) and
      LiteralInputsByPos[PosIndex].Enabled then
    begin
      if LzmaOptimumRelaxSdkLiteralCandidate(Nodes, UInt32(PosIndex),
        ProbPrices, LiteralInputsByPos[PosIndex], CurrentProbs.IsMatchProb,
        LiteralPrice, NextIsLit) then
        Result := True;
    end;

    if PosIndex <= High(RepLensByPos) then
    begin
      if (RepLensByPos[PosIndex][0] > 0) and
        LzmaOptimumCanRelaxSdkShortRep(Nodes, UInt32(PosIndex), ProbPrices,
          CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb) then
      begin
        if LzmaOptimumRelaxShortRepCandidate(Nodes, UInt32(PosIndex),
          ProbPrices, CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb,
          CurrentProbs.IsRepG0Prob, CurrentProbs.IsRep0LongProb,
          BestRelaxedPrice) then
        begin
          NextIsLit := False;
          Result := True;
        end;
      end;

      if LzmaOptimumRelaxRepCandidates(Nodes, UInt32(PosIndex),
        RepLensByPos[PosIndex], ProbPrices, RepLenPrices,
        CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb,
        CurrentProbs.IsRepG0Prob, CurrentProbs.IsRepG1Prob,
        CurrentProbs.IsRepG2Prob, CurrentProbs.IsRep0LongProb,
        PosState, BestRelaxedPrice) then
        Result := True;
      if RepLensByPos[PosIndex][0] >= LZMA_MATCH_MIN_LEN then
        MatchStartLen := RepLensByPos[PosIndex][0] + 1;
    end;

    if PosIndex <= High(MatchesByPos) then
    begin
      MainLen := 0;
      for MatchIndex := 0 to MatchesByPos[PosIndex].Count - 1 do
      begin
        if MatchesByPos[PosIndex].Items[MatchIndex].Length > MainLen then
          MainLen := MatchesByPos[PosIndex].Items[MatchIndex].Length;
      end;

      if MainLen >= LZMA_MATCH_MIN_LEN then
      begin
        if LzmaOptimumRelaxMatchCandidates(Nodes, UInt32(PosIndex),
          MatchesByPos[PosIndex], ProbPrices, LenPrices, DistancePrices,
          CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb, PosState,
          MatchStartLen, MainLen, BestRelaxedPrice) then
          Result := True;
      end;
    end;
  end;
end;

function LzmaOptimumRelaxWindow(var Nodes: array of TLzmaOptimumNode;
  const MatchesByPos: array of TLzmaMatchBuffer;
  const PosStates: array of UInt32;
  const LiteralResolver: TLzmaOptimumLiteralResolver;
  const RepLensResolver: TLzmaOptimumRepLensResolver;
  const ProbInputsByPos: array of TLzmaOptimumStateProbInputs;
  const ProbPrices: TLzmaProbPrices; const LenPrices, RepLenPrices: TLzmaLenPriceEncoder;
  const DistancePrices: TLzmaDistancePriceEncoder): Boolean;
var
  BestRelaxedPrice: UInt32;
  CurrentProbs: TLzmaOptimumProbInput;
  LiteralInput: TLzmaOptimumLiteralInput;
  LiteralPrice: UInt32;
  MatchIndex: Integer;
  MatchStartLen: UInt32;
  MainLen: UInt32;
  NextIsLit: Boolean;
  PosIndex: Integer;
  PosState: UInt32;
  RepLens: TLzmaOptimumRepLens;
  StateIndex: UInt32;

  function PosStateAt(const Pos: UInt32): UInt32;
  begin
    Result := 0;
    if (High(PosStates) >= 0) and (Pos <= UInt32(High(PosStates))) then
      Result := PosStates[Integer(Pos)];
  end;

  function ProbInputAt(const Pos, State: UInt32): TLzmaOptimumProbInput;
  var
    EffectiveState: UInt32;
  begin
    Result.IsMatchProb := LZMA_PROB_INIT;
    Result.IsRepProb := LZMA_PROB_INIT;
    Result.IsRepG0Prob := LZMA_PROB_INIT;
    Result.IsRepG1Prob := LZMA_PROB_INIT;
    Result.IsRepG2Prob := LZMA_PROB_INIT;
    Result.IsRep0LongProb := LZMA_PROB_INIT;
    if (High(ProbInputsByPos) >= 0) and (Pos <= UInt32(High(ProbInputsByPos))) then
    begin
      EffectiveState := LzmaOptimumStateIndex(State);
      Result := ProbInputsByPos[Integer(Pos)][Integer(EffectiveState)];
    end;
  end;

  procedure TryRelaxLiteralRep0ExtraPath(const CurrentLiteralPrice: UInt32;
    const CurrentNextIsLit: Boolean);
  var
    CandidatePrice: UInt32;
    ExtraRepLens: TLzmaOptimumRepLens;
    LiteralNode: TLzmaOptimumNode;
    RepPos: UInt32;
    RepProbs: TLzmaOptimumProbInput;
  begin
    if CurrentNextIsLit or (CurrentLiteralPrice = 0) then
      Exit;
    if (not Assigned(LiteralResolver)) or (not Assigned(RepLensResolver)) then
      Exit;

    FillChar(LiteralInput, SizeOf(LiteralInput), 0);
    if (not LiteralResolver(UInt32(PosIndex), Nodes[PosIndex], LiteralInput)) or
      (not LiteralInput.Enabled) then
      Exit;
    if LiteralInput.MatchByte = LiteralInput.Value then
      Exit;

    LiteralNode := Nodes[PosIndex];
    LzmaOptimumSetLiteralContext(LiteralNode, Nodes[PosIndex]);
    RepPos := UInt32(PosIndex) + 1;
    FillChar(ExtraRepLens, SizeOf(ExtraRepLens), 0);
    RepLensResolver(RepPos, LiteralNode.Reps, ExtraRepLens);
    if ExtraRepLens[0] < LZMA_MATCH_MIN_LEN then
      Exit;

    RepProbs := ProbInputAt(RepPos, LiteralNode.State);
    if LzmaOptimumRelaxLiteralRep0Candidate(Nodes, UInt32(PosIndex),
      ProbPrices, LiteralInput.LiteralProbs, RepLenPrices,
      CurrentProbs.IsMatchProb, RepProbs.IsMatchProb, RepProbs.IsRepProb,
      RepProbs.IsRepG0Prob, RepProbs.IsRep0LongProb, PosStateAt(RepPos),
      LiteralInput.Value, LiteralInput.UseMatchedLiteral,
      LiteralInput.MatchByte, ExtraRepLens[0], CandidatePrice) then
      Result := True;
  end;

  procedure TryRelaxMatchLiteralRep0ExtraPaths;
  var
    CandidatePrice: UInt32;
    ExtraRepLens: TLzmaOptimumRepLens;
    ExtraMatchIndex: Integer;
    FirstMatch: TLzmaMatch;
    LiteralNode: TLzmaOptimumNode;
    LiteralPos: UInt32;
    LiteralProbs: TLzmaOptimumProbInput;
    MatchNode: TLzmaOptimumNode;
    RepPos: UInt32;
    RepProbs: TLzmaOptimumProbInput;
  begin
    if (not Assigned(LiteralResolver)) or (not Assigned(RepLensResolver)) then
      Exit;
    if PosIndex > High(MatchesByPos) then
      Exit;

    for ExtraMatchIndex := 0 to MatchesByPos[PosIndex].Count - 1 do
    begin
      FirstMatch := MatchesByPos[PosIndex].Items[ExtraMatchIndex];
      if (FirstMatch.Length < LZMA_MATCH_MIN_LEN) or
        (FirstMatch.Distance = 0) or (FirstMatch.Distance > High(UInt32) - 3) then
        Continue;
      if UInt64(PosIndex) + UInt64(FirstMatch.Length) + 1 >= UInt64(Length(Nodes)) then
        Continue;

      MatchNode := Nodes[PosIndex];
      LzmaOptimumSetMatchContext(MatchNode, Nodes[PosIndex], FirstMatch.Distance);

      LiteralPos := UInt32(PosIndex) + FirstMatch.Length;
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      if (not LiteralResolver(LiteralPos, MatchNode, LiteralInput)) or
        (not LiteralInput.Enabled) then
        Continue;

      LiteralNode := MatchNode;
      LzmaOptimumSetLiteralContext(LiteralNode, MatchNode);

      RepPos := LiteralPos + 1;
      FillChar(ExtraRepLens, SizeOf(ExtraRepLens), 0);
      RepLensResolver(RepPos, LiteralNode.Reps, ExtraRepLens);
      if ExtraRepLens[0] < LZMA_MATCH_MIN_LEN then
        Continue;

      LiteralProbs := ProbInputAt(LiteralPos, MatchNode.State);
      RepProbs := ProbInputAt(RepPos, LiteralNode.State);
      if LzmaOptimumRelaxMatchLiteralRep0Candidate(Nodes, UInt32(PosIndex),
        ProbPrices, LiteralInput.LiteralProbs, LenPrices, RepLenPrices,
        DistancePrices, CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb,
        LiteralProbs.IsMatchProb, RepProbs.IsMatchProb, RepProbs.IsRepProb,
        RepProbs.IsRepG0Prob, RepProbs.IsRep0LongProb, PosState,
        PosStateAt(LiteralPos), PosStateAt(RepPos), LiteralInput.Value,
        LiteralInput.UseMatchedLiteral, LiteralInput.MatchByte,
        FirstMatch.Length, FirstMatch.Distance, ExtraRepLens[0],
        CandidatePrice) then
        Result := True;
    end;
  end;

  procedure TryRelaxRepLiteralRep0ExtraPaths(const CurrentRepLens: TLzmaOptimumRepLens);
  var
    CandidatePrice: UInt32;
    ExtraRepLens: TLzmaOptimumRepLens;
    FirstRepIndex: Integer;
    FirstRepLen: UInt32;
    LiteralNode: TLzmaOptimumNode;
    LiteralPos: UInt32;
    LiteralProbs: TLzmaOptimumProbInput;
    RepNode: TLzmaOptimumNode;
    RepPos: UInt32;
    RepProbs: TLzmaOptimumProbInput;
  begin
    if (not Assigned(LiteralResolver)) or (not Assigned(RepLensResolver)) then
      Exit;

    for FirstRepIndex := Low(CurrentRepLens) to High(CurrentRepLens) do
    begin
      FirstRepLen := CurrentRepLens[FirstRepIndex];
      if FirstRepLen < LZMA_MATCH_MIN_LEN then
        Continue;
      if UInt64(PosIndex) + UInt64(FirstRepLen) + 1 >= UInt64(Length(Nodes)) then
        Continue;

      RepNode := Nodes[PosIndex];
      LzmaOptimumSetRepContext(RepNode, Nodes[PosIndex], UInt32(FirstRepIndex), False);

      LiteralPos := UInt32(PosIndex) + FirstRepLen;
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      if (not LiteralResolver(LiteralPos, RepNode, LiteralInput)) or
        (not LiteralInput.Enabled) then
        Continue;

      LiteralNode := RepNode;
      LzmaOptimumSetLiteralContext(LiteralNode, RepNode);

      RepPos := LiteralPos + 1;
      FillChar(ExtraRepLens, SizeOf(ExtraRepLens), 0);
      RepLensResolver(RepPos, LiteralNode.Reps, ExtraRepLens);
      if ExtraRepLens[0] < LZMA_MATCH_MIN_LEN then
        Continue;

      LiteralProbs := ProbInputAt(LiteralPos, RepNode.State);
      RepProbs := ProbInputAt(RepPos, LiteralNode.State);
      if LzmaOptimumRelaxRepLiteralRep0Candidate(Nodes, UInt32(PosIndex),
        ProbPrices, LiteralInput.LiteralProbs, RepLenPrices,
        CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb,
        CurrentProbs.IsRepG0Prob, CurrentProbs.IsRepG1Prob,
        CurrentProbs.IsRepG2Prob, CurrentProbs.IsRep0LongProb,
        LiteralProbs.IsMatchProb, RepProbs.IsMatchProb, RepProbs.IsRepProb,
        RepProbs.IsRepG0Prob, RepProbs.IsRep0LongProb, PosState,
        PosStateAt(RepPos), UInt32(FirstRepIndex), LiteralInput.Value,
        LiteralInput.UseMatchedLiteral, LiteralInput.MatchByte, FirstRepLen,
        ExtraRepLens[0], CandidatePrice) then
        Result := True;
    end;
  end;
begin
  Result := False;
  if Length(Nodes) <= 1 then
    Exit;

  for PosIndex := 0 to High(Nodes) - 1 do
  begin
    if Nodes[PosIndex].Price = High(UInt32) then
      Continue;

    MatchStartLen := LZMA_MATCH_MIN_LEN;
    NextIsLit := False;
    LiteralPrice := 0;
    PosState := PosStateAt(UInt32(PosIndex));
    StateIndex := LzmaOptimumStateIndex(Nodes[PosIndex].State);
    CurrentProbs := ProbInputAt(UInt32(PosIndex), StateIndex);

    if Assigned(LiteralResolver) then
    begin
      FillChar(LiteralInput, SizeOf(LiteralInput), 0);
      if LiteralResolver(UInt32(PosIndex), Nodes[PosIndex], LiteralInput) and
        LiteralInput.Enabled then
      begin
        if LzmaOptimumRelaxSdkLiteralCandidate(Nodes, UInt32(PosIndex),
          ProbPrices, LiteralInput, CurrentProbs.IsMatchProb, LiteralPrice,
          NextIsLit) then
          Result := True;
      end;
    end;

    if Assigned(RepLensResolver) then
    begin
      FillChar(RepLens, SizeOf(RepLens), 0);
      RepLensResolver(UInt32(PosIndex), Nodes[PosIndex].Reps, RepLens);
      if RepLens[0] > 0 then
      begin
        if LzmaOptimumCanRelaxSdkShortRep(Nodes, UInt32(PosIndex),
          ProbPrices, CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb) and
          LzmaOptimumRelaxShortRepCandidate(Nodes, UInt32(PosIndex),
          ProbPrices, CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb,
          CurrentProbs.IsRepG0Prob, CurrentProbs.IsRep0LongProb,
          BestRelaxedPrice) then
        begin
          NextIsLit := False;
          Result := True;
        end;
      end;

      TryRelaxLiteralRep0ExtraPath(LiteralPrice, NextIsLit);

      if LzmaOptimumRelaxRepCandidates(Nodes, UInt32(PosIndex), RepLens,
        ProbPrices, RepLenPrices, CurrentProbs.IsMatchProb,
        CurrentProbs.IsRepProb, CurrentProbs.IsRepG0Prob,
        CurrentProbs.IsRepG1Prob, CurrentProbs.IsRepG2Prob,
        CurrentProbs.IsRep0LongProb, PosState, BestRelaxedPrice) then
        Result := True;

      TryRelaxRepLiteralRep0ExtraPaths(RepLens);
      if RepLens[0] >= LZMA_MATCH_MIN_LEN then
        MatchStartLen := RepLens[0] + 1;
    end;

    if PosIndex <= High(MatchesByPos) then
    begin
      TryRelaxMatchLiteralRep0ExtraPaths;
      MainLen := 0;
      for MatchIndex := 0 to MatchesByPos[PosIndex].Count - 1 do
      begin
        if MatchesByPos[PosIndex].Items[MatchIndex].Length > MainLen then
          MainLen := MatchesByPos[PosIndex].Items[MatchIndex].Length;
      end;

      if MainLen >= LZMA_MATCH_MIN_LEN then
      begin
        if LzmaOptimumRelaxMatchCandidates(Nodes, UInt32(PosIndex),
          MatchesByPos[PosIndex], ProbPrices, LenPrices, DistancePrices,
          CurrentProbs.IsMatchProb, CurrentProbs.IsRepProb, PosState,
          MatchStartLen, MainLen, BestRelaxedPrice) then
          Result := True;
      end;
    end;
  end;
end;

function LzmaOptimumSelectWindowTarget(const Nodes: array of TLzmaOptimumNode;
  const InitialTargetEnd, WindowEnd, BaselinePrice: UInt32;
  out TargetEnd, TargetPrice: UInt32): Boolean;
var
  CandidateEnd: UInt32;
  EffectiveWindowEnd: UInt32;
begin
  Result := False;
  TargetEnd := 0;
  TargetPrice := High(UInt32);

  if Length(Nodes) = 0 then
    Exit;
  if InitialTargetEnd >= UInt32(Length(Nodes)) then
    Exit;
  EffectiveWindowEnd := WindowEnd;
  if EffectiveWindowEnd >= UInt32(Length(Nodes)) then
    EffectiveWindowEnd := UInt32(Length(Nodes) - 1);
  if InitialTargetEnd > EffectiveWindowEnd then
    Exit;

  for CandidateEnd := InitialTargetEnd to EffectiveWindowEnd do
  begin
    if Nodes[Integer(CandidateEnd)].Price < TargetPrice then
    begin
      TargetPrice := Nodes[Integer(CandidateEnd)].Price;
      TargetEnd := CandidateEnd;
    end;
  end;

  Result := TargetPrice < BaselinePrice;
end;

function LzmaOptimumReplayFirstDecision(const Nodes: array of TLzmaOptimumNode;
  const EndPos: UInt32; out Len, Back: UInt32): Boolean;
var
  CurrentPos: UInt32;
  CurrentBack: UInt32;
  CurrentExtra: UInt32;
  CurrentLen: UInt32;
  Limit: UInt32;
  PrevPos: UInt32;
  StepCount: UInt32;
begin
  Len := 0;
  Back := LZMA_OPTIMUM_BACK_LITERAL;
  Result := False;

  if (EndPos = 0) or (Length(Nodes) = 0) then
    Exit;

  Limit := UInt32(Length(Nodes));
  if EndPos >= Limit then
    Exit;
  if Nodes[EndPos].Price = High(UInt32) then
    Exit;
  if Nodes[0].Price = High(UInt32) then
    Exit;

  if Nodes[EndPos].PathLen <> 0 then
  begin
    CurrentPos := EndPos;
    StepCount := 0;
    while CurrentPos > 0 do
    begin
      if CurrentPos >= Limit then
        Exit;
      if Nodes[CurrentPos].Price = High(UInt32) then
        Exit;

      CurrentLen := Nodes[CurrentPos].PathLen;
      CurrentBack := Nodes[CurrentPos].PathBack;
      CurrentExtra := Nodes[CurrentPos].Extra;
      if (CurrentLen = 0) or (CurrentLen > CurrentPos) then
        Exit;
      if (CurrentBack = LZMA_OPTIMUM_BACK_LITERAL) and (CurrentLen <> 1) then
        Exit;
      if (CurrentLen = 1) and (CurrentBack <> LZMA_OPTIMUM_BACK_LITERAL) and
        (CurrentBack <> 0) then
        Exit;
      if (CurrentExtra = 0) and (Nodes[CurrentPos].BackPrev <> 0) and
        (Nodes[CurrentPos].BackPrev <> CurrentBack) then
        Exit;

      PrevPos := CurrentPos - CurrentLen;
      if (Nodes[CurrentPos].PosPrev <> 0) and
        (Nodes[CurrentPos].PosPrev <> PrevPos) then
        Exit;
      if (CurrentExtra <> 0) and Nodes[CurrentPos].Prev1IsLiteral then
        Exit;
      if (CurrentExtra = 1) and (Nodes[CurrentPos].BackPrev <> 0) and
        (Nodes[CurrentPos].BackPrev <> LZMA_OPTIMUM_BACK_LITERAL) then
        Exit;
      if (CurrentExtra = 1) and (Nodes[CurrentPos].BackPrev2 <> 0) then
        Exit;
      if (CurrentExtra = 1) and (Nodes[CurrentPos].PosPrev2 <> 0) then
        Exit;
      if (CurrentExtra > 1) and (Nodes[CurrentPos].BackPrev <> 0) then
        Exit;
      if (CurrentExtra > 1) and (Nodes[CurrentPos].BackPrev2 <> 0) then
        Exit;
      if (CurrentExtra > 1) and (Nodes[CurrentPos].PosPrev2 <> 0) then
        Exit;

      CurrentPos := PrevPos;
      if CurrentExtra <> 0 then
      begin
        if CurrentExtra > CurrentPos then
          Exit;

        Dec(CurrentPos, CurrentExtra);
        if CurrentExtra = 1 then
        begin
          CurrentLen := 1;
          CurrentBack := LZMA_OPTIMUM_BACK_LITERAL;
        end
        else
          CurrentLen := CurrentExtra - 1;
      end;

      if CurrentPos = 0 then
      begin
        Len := CurrentLen;
        Back := CurrentBack;
        Exit(True);
      end;

      Inc(StepCount);
      if StepCount > Limit then
        Exit;
    end;
  end;

  CurrentPos := EndPos;
  StepCount := 0;
  while CurrentPos > 0 do
  begin
    if CurrentPos >= Limit then
      Exit;
    if Nodes[CurrentPos].Price = High(UInt32) then
      Exit;

    if Nodes[CurrentPos].Prev1IsLiteral then
    begin
      PrevPos := Nodes[CurrentPos].PosPrev;
      if (PrevPos = 0) or (PrevPos >= CurrentPos) or
        (Nodes[CurrentPos].PosPrev2 >= PrevPos) then
        Exit;
      if Nodes[PrevPos].Price = High(UInt32) then
        Exit;

      if Nodes[CurrentPos].PosPrev2 = 0 then
      begin
        if Nodes[CurrentPos].BackPrev2 <> LZMA_OPTIMUM_BACK_LITERAL then
          Exit;
        if PrevPos <> 1 then
          Exit;
        Len := 1;
        Back := Nodes[CurrentPos].BackPrev2;
        Exit(True);
      end;

      CurrentPos := Nodes[CurrentPos].PosPrev2;
      Inc(StepCount);
      if StepCount > Limit then
        Exit;
      Continue;
    end;

    PrevPos := Nodes[CurrentPos].PosPrev;
    CurrentBack := Nodes[CurrentPos].BackPrev;
    if PrevPos >= CurrentPos then
      Exit;

    CurrentLen := CurrentPos - PrevPos;
    if (CurrentBack = LZMA_OPTIMUM_BACK_LITERAL) and (CurrentLen <> 1) then
      Exit;
    if (CurrentLen = 1) and (CurrentBack <> LZMA_OPTIMUM_BACK_LITERAL) and
      (CurrentBack <> 0) then
      Exit;

    if PrevPos = 0 then
    begin
      if (CurrentBack = LZMA_OPTIMUM_BACK_LITERAL) and (CurrentPos <> 1) then
        Exit;
      if (CurrentPos = 1) and (CurrentBack <> LZMA_OPTIMUM_BACK_LITERAL) and
        (CurrentBack <> 0) then
        Exit;
      Len := CurrentPos - PrevPos;
      Back := CurrentBack;
      Exit(True);
    end;

    Inc(StepCount);
    if StepCount > Limit then
      Exit;

    CurrentPos := PrevPos;
  end;
end;

function LzmaOptimumReplayPath(const Nodes: array of TLzmaOptimumNode;
  const EndPos: UInt32; var Decisions: array of TLzmaOptimumDecision;
  out DecisionCount: UInt32): Boolean;
var
  Limit: UInt32;

  function IsValidDecision(const DecisionLen, DecisionBack: UInt32): Boolean;
  begin
    Result := DecisionLen > 0;
    if not Result then
      Exit;
    if DecisionBack = LZMA_OPTIMUM_BACK_LITERAL then
      Result := DecisionLen = 1
    else if DecisionLen = 1 then
      Result := DecisionBack = 0;
  end;

  function AppendDecision(const DecisionLen, DecisionBack: UInt32): Boolean;
  begin
    Result := False;
    if not IsValidDecision(DecisionLen, DecisionBack) then
      Exit;
    if DecisionCount >= UInt32(Length(Decisions)) then
      Exit;

    Decisions[Integer(DecisionCount)].Len := DecisionLen;
    Decisions[Integer(DecisionCount)].Back := DecisionBack;
    Inc(DecisionCount);
    Result := True;
  end;

  function ReplayTo(const CurrentPos, Depth: UInt32): Boolean;
  var
    CurrentBack: UInt32;
    CurrentExtra: UInt32;
    CurrentLen: UInt32;
    PrevPos: UInt32;
  begin
    Result := False;
    if Depth > Limit then
      Exit;
    if CurrentPos = 0 then
      Exit(True);
    if CurrentPos >= Limit then
      Exit;
    if Nodes[CurrentPos].Price = High(UInt32) then
      Exit;

    if Nodes[CurrentPos].PathLen <> 0 then
    begin
      CurrentLen := Nodes[CurrentPos].PathLen;
      CurrentBack := Nodes[CurrentPos].PathBack;
      CurrentExtra := Nodes[CurrentPos].Extra;
      if (CurrentLen = 0) or (CurrentLen > CurrentPos) then
        Exit;

      if CurrentExtra <> 0 then
      begin
        if (CurrentBack = LZMA_OPTIMUM_BACK_LITERAL) and (CurrentLen <> 1) then
          Exit;
        if (CurrentLen = 1) and (CurrentBack <> LZMA_OPTIMUM_BACK_LITERAL) and
          (CurrentBack <> 0) then
          Exit;

        PrevPos := CurrentPos - CurrentLen;
        if (Nodes[CurrentPos].PosPrev <> 0) and
          (Nodes[CurrentPos].PosPrev <> PrevPos) then
          Exit;
        if Nodes[CurrentPos].Prev1IsLiteral then
          Exit;
        if (CurrentExtra = 1) and (Nodes[CurrentPos].BackPrev <> 0) and
          (Nodes[CurrentPos].BackPrev <> LZMA_OPTIMUM_BACK_LITERAL) then
          Exit;
        if (CurrentExtra = 1) and (Nodes[CurrentPos].BackPrev2 <> 0) then
          Exit;
        if (CurrentExtra = 1) and (Nodes[CurrentPos].PosPrev2 <> 0) then
          Exit;
        if (CurrentExtra > 1) and (Nodes[CurrentPos].BackPrev <> 0) then
          Exit;
        if (CurrentExtra > 1) and (Nodes[CurrentPos].BackPrev2 <> 0) then
          Exit;
        if (CurrentExtra > 1) and (Nodes[CurrentPos].PosPrev2 <> 0) then
          Exit;

        if CurrentExtra > PrevPos then
          Exit;
        Dec(PrevPos, CurrentExtra);
        if not ReplayTo(PrevPos, Depth + 1) then
          Exit;

        if CurrentExtra = 1 then
        begin
          if not AppendDecision(1, LZMA_OPTIMUM_BACK_LITERAL) then
            Exit;
          Exit(AppendDecision(CurrentLen, CurrentBack));
        end;

        if not AppendDecision(CurrentExtra - 1, CurrentBack) then
          Exit;
        if not AppendDecision(1, LZMA_OPTIMUM_BACK_LITERAL) then
          Exit;
        Exit(AppendDecision(CurrentLen, Nodes[CurrentPos].BackPrev));
      end;

      if not IsValidDecision(CurrentLen, CurrentBack) then
        Exit;
      PrevPos := CurrentPos - CurrentLen;
      if (Nodes[CurrentPos].PosPrev <> 0) and
        (Nodes[CurrentPos].PosPrev <> PrevPos) then
        Exit;
      if (Nodes[CurrentPos].BackPrev <> 0) and
        (Nodes[CurrentPos].BackPrev <> CurrentBack) then
        Exit;
      if not ReplayTo(PrevPos, Depth + 1) then
        Exit;
      Exit(AppendDecision(CurrentLen, CurrentBack));
    end;

    if Nodes[CurrentPos].Prev1IsLiteral then
    begin
      PrevPos := Nodes[CurrentPos].PosPrev;
      if (PrevPos = 0) or (PrevPos >= CurrentPos) then
        Exit;
      if Nodes[CurrentPos].PosPrev2 = 0 then
      begin
        if PrevPos <> 1 then
          Exit;
        if Nodes[CurrentPos].BackPrev2 <> LZMA_OPTIMUM_BACK_LITERAL then
          Exit;
        if not ReplayTo(0, Depth + 1) then
          Exit;
        Exit(AppendDecision(1, LZMA_OPTIMUM_BACK_LITERAL));
      end;
      Exit;
    end;

    PrevPos := Nodes[CurrentPos].PosPrev;
    CurrentBack := Nodes[CurrentPos].BackPrev;
    if PrevPos >= CurrentPos then
      Exit;
    CurrentLen := CurrentPos - PrevPos;
    if not IsValidDecision(CurrentLen, CurrentBack) then
      Exit;
    if not ReplayTo(PrevPos, Depth + 1) then
      Exit;
    Result := AppendDecision(CurrentLen, CurrentBack);
  end;

begin
  DecisionCount := 0;
  Result := False;
  if (EndPos = 0) or (Length(Nodes) = 0) or (Length(Decisions) = 0) then
    Exit;

  Limit := UInt32(Length(Nodes));
  if EndPos >= Limit then
    Exit;
  if Nodes[0].Price = High(UInt32) then
    Exit;
  if Nodes[EndPos].Price = High(UInt32) then
    Exit;

  Result := ReplayTo(EndPos, 0);
  if not Result then
    DecisionCount := 0;
end;

function LzmaOptimumReplaySdkBackward(const Nodes: array of TLzmaOptimumNode;
  const EndPos: UInt32; var Decisions: array of TLzmaOptimumDecision;
  out DecisionCount: UInt32; out BackwardState: TLzmaOptimumBackwardState): Boolean;
var
  Consumed: UInt32;
  Index: UInt32;
begin
  FillChar(BackwardState, SizeOf(BackwardState), 0);
  DecisionCount := 0;
  Result := False;

  if (EndPos = 0) or (EndPos >= UInt32(Length(Nodes))) then
    Exit;
  if EndPos >= LZMA_FULL_OPTIMUM_NUM_OPTS then
    Exit;

  if not LzmaOptimumReplayPath(Nodes, EndPos, Decisions, DecisionCount) then
    Exit;
  if DecisionCount = 0 then
    Exit;

  Consumed := 0;
  for Index := 0 to DecisionCount - 1 do
  begin
    if Decisions[Integer(Index)].Len > EndPos - Consumed then
    begin
      DecisionCount := 0;
      Exit;
    end;
    Inc(Consumed, Decisions[Integer(Index)].Len);
  end;
  if Consumed <> EndPos then
  begin
    DecisionCount := 0;
    Exit;
  end;

  BackwardState.OptEnd := EndPos + 1;
  BackwardState.QueueCount := DecisionCount - 1;
  if BackwardState.QueueCount = 0 then
    BackwardState.OptCur := BackwardState.OptEnd
  else
    BackwardState.OptCur := BackwardState.OptEnd - BackwardState.QueueCount;
  Result := True;
end;

end.
