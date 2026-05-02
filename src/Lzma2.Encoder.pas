unit Lzma2.Encoder;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.Types;

type
  TLzma2Encoder = class
  public
    class function NormalizeOptions(const Options: TLzma2Options): TLzma2Options; static;
    class function DictionaryInfo(const Options: TLzma2Options): TLzma2DictionaryInfo; static;
    class procedure EncodeRaw(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class function EncodeRawBytes(const Source: TBytes; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil): TBytes; static;
  end;

implementation

uses
  Lzma.Alloc,
  Lzma.Encoder,
  Lzma.Errors,
  Lzma.MatchFinder,
  Lzma.Streams;

const
  LZMA2_COPY_HEADER_SIZE = 3;
  LZMA2_LZMA_HEADER_SIZE = 6;
  LZMA2_LZMA_CHUNK_SIZE = 1 shl 21;
  LZMA2_LZMA_PACK_SIZE_MAX = 1 shl 16;
  LZMA2_MT_BATCH_SIZE = 64 shl 20;
  LZMA2_MT_BATCH_SIZE_8T = 64 shl 20;
  LZMA2_MT_BATCH_SIZE_2T = 64 shl 20;
  LZMA2_INCOMPRESSIBLE_MIN_SIZE = 64 shl 10;
  LZMA2_INCOMPRESSIBLE_RETRY_MIN_SIZE = 32 shl 10;
  LZMA2_INCOMPRESSIBLE_HIST_SAMPLE = 64 shl 10;
  LZMA2_INCOMPRESSIBLE_HASH_SPAN = 128 shl 10;
  LZMA2_INCOMPRESSIBLE_HASH_STEP = 16;
  LZMA2_MIXED_SUBCHUNK_SIZE = 8 shl 10;
  LZMA2_PERIODIC_SUBCHUNK_SIZE = LZMA2_LZMA_CHUNK_SIZE - (8 * 273);
  LZMA2_PERIODIC_GROUP_LIMIT = 512 shl 20;
  LZMA2_PERIODIC_MIN_SIZE = 64 shl 10;
  LZMA2_PERIODIC_MAX_DISTANCE = 16;

type
  TLzma2ChunkJob = class
  public
    Index: Integer;
    Input: TBytes;
    Count: Integer;
    Props: TLzmaProps;
    FastBytes: Integer;
    CutValue: UInt32;
    MatchFinderKind: TLzmaMatchFinderKind;
    EnableOptimumWindow: Boolean;
    PropByte: Byte;
    PartLimit: Integer;
    FullOptimumDecisionCount: UInt64;
    Data: TBytes;
    Completed: Boolean;
    ErrorCode: SRes;
    ErrorMessage: string;
    procedure Execute;
  end;

  TLzma2OutputChunk = record
    Data: TBytes;
    InputSize: Integer;
    FullOptimumDecisionCount: UInt64;
    Completed: Boolean;
    ErrorCode: SRes;
    ErrorMessage: string;
  end;

function BuildLzma2CopyChunk(const Chunk: TBytes; const Count: Integer; const ResetDictionary: Boolean): TBytes;
begin
  SetLength(Result, Count + LZMA2_COPY_HEADER_SIZE);
  Result[0] := LZMA2_CONTROL_COPY_NO_RESET;
  if ResetDictionary then
    Result[0] := LZMA2_CONTROL_COPY_RESET_DIC;
  Result[1] := Byte((Count - 1) shr 8);
  Result[2] := Byte(Count - 1);
  if Count > 0 then
    Move(Chunk[0], Result[LZMA2_COPY_HEADER_SIZE], Count);
end;

function BuildLzma2CompressedChunk(const Count: Integer; const Encoded: TBytes; const PropByte: Byte;
  const ResetDictionary: Boolean = True; const WriteProperties: Boolean = True): TBytes;
var
  EncodedSize: Integer;
  HeaderSize: Integer;
  HasProperties: Boolean;
begin
  EncodedSize := Length(Encoded);
  if EncodedSize > LZMA2_LZMA_PACK_SIZE_MAX then
    RaiseLzmaError(SZ_ERROR_PARAM, 'LZMA2 compressed chunk exceeds 64 KiB packed size');
  HasProperties := WriteProperties or ResetDictionary;
  HeaderSize := 5;
  if HasProperties then
    Inc(HeaderSize);
  SetLength(Result, EncodedSize + HeaderSize);
  Result[0] := $80 or Byte((Count - 1) shr 16);
  if ResetDictionary then
    Result[0] := Result[0] or $60
  else if HasProperties then
    Result[0] := Result[0] or $40
  else
    Result[0] := Result[0] or $20;
  Result[1] := Byte((Count - 1) shr 8);
  Result[2] := Byte(Count - 1);
  Result[3] := Byte((EncodedSize - 1) shr 8);
  Result[4] := Byte(EncodedSize - 1);
  if HasProperties then
    Result[5] := PropByte;
  if EncodedSize > 0 then
    Move(Encoded[0], Result[HeaderSize], EncodedSize);
end;

procedure EnsureLzma2BatchCapacity(var Output: TBytes; const RequiredSize: Integer);
var
  NewCapacity: Integer;
begin
  if RequiredSize <= Length(Output) then
    Exit;

  NewCapacity := Length(Output);
  if NewCapacity < 1024 then
    NewCapacity := 1024;
  while NewCapacity < RequiredSize do
  begin
    if NewCapacity > High(Integer) div 2 then
    begin
      NewCapacity := RequiredSize;
      Break;
    end;
    NewCapacity := NewCapacity * 2;
  end;
  SetLength(Output, NewCapacity);
end;

procedure AppendLzma2CopyChunkFromRange(var Output: TBytes; var OutputSize: Integer; const Chunk: TBytes;
  const Offset, Count: Integer; const ResetDictionary: Boolean);
var
  NewSize: Integer;
begin
  NewSize := OutputSize + Count + LZMA2_COPY_HEADER_SIZE;
  EnsureLzma2BatchCapacity(Output, NewSize);
  Output[OutputSize] := LZMA2_CONTROL_COPY_NO_RESET;
  if ResetDictionary then
    Output[OutputSize] := LZMA2_CONTROL_COPY_RESET_DIC;
  Output[OutputSize + 1] := Byte((Count - 1) shr 8);
  Output[OutputSize + 2] := Byte(Count - 1);
  if Count > 0 then
    Move(Chunk[Offset], Output[OutputSize + LZMA2_COPY_HEADER_SIZE], Count);
  OutputSize := NewSize;
end;

procedure AppendLzma2CopyChunksFromRange(var Output: TBytes; var OutputSize: Integer; const Chunk: TBytes;
  const Offset, Count: Integer; const ResetDictionary: Boolean);
var
  SourceOffset: Integer;
  Remaining: Integer;
  PartCount: Integer;
  ResetThisChunk: Boolean;
begin
  SourceOffset := Offset;
  Remaining := Count;
  ResetThisChunk := ResetDictionary;
  while Remaining > 0 do
  begin
    PartCount := Remaining;
    if PartCount > LZMA2_COPY_CHUNK_SIZE then
      PartCount := LZMA2_COPY_CHUNK_SIZE;
    AppendLzma2CopyChunkFromRange(Output, OutputSize, Chunk, SourceOffset, PartCount, ResetThisChunk);
    ResetThisChunk := False;
    Inc(SourceOffset, PartCount);
    Dec(Remaining, PartCount);
  end;
end;

procedure AppendLzma2EncodedBytes(var Output: TBytes; var OutputSize: Integer; const Data: TBytes);
var
  NewSize: Integer;
begin
  if Length(Data) = 0 then
    Exit;
  NewSize := OutputSize + Length(Data);
  EnsureLzma2BatchCapacity(Output, NewSize);
  Move(Data[0], Output[OutputSize], Length(Data));
  OutputSize := NewSize;
end;

function Lzma2CopyRangeEncodedSize(const Count: Integer): Integer;
var
  ChunkCount: Integer;
begin
  ChunkCount := (Count + LZMA2_COPY_CHUNK_SIZE - 1) div LZMA2_COPY_CHUNK_SIZE;
  Result := Count + ChunkCount * LZMA2_COPY_HEADER_SIZE;
end;

function LooksIncompressibleChunk(const Data: TBytes; const Offset, Count: Integer; const Props: TLzmaProps;
  const FastBytes: Integer; const CutValue: UInt32; const MatchFinderKind: TLzmaMatchFinderKind;
  const LikelyIncompressible: Boolean = False): Boolean;
var
  Seen: TBytes;
  ProbeEncoded: TBytes;
  SampleWindow: Integer;
  HashSpan: Integer;
  ProbeCount: Integer;
  HashSamples: Integer;
  HashRepeats: Integer;
  LastSampleOffset: Integer;
  SampleOffset: Integer;
  Pos: Integer;
  B: Byte;
  H: UInt32;

  function HighEntropySample(const SampleOffset: Integer): Boolean;
  var
    Histogram: array[0..255] of UInt32;
    SampleCount: Integer;
    DistinctCount: Integer;
    MaxBucket: UInt32;
    I: Integer;
  begin
    Result := False;
    if (SampleOffset < 0) or (SampleOffset >= Count) then
      Exit;

    FillChar(Histogram, SizeOf(Histogram), 0);
    SampleCount := Count - SampleOffset;
    if SampleCount > LZMA2_INCOMPRESSIBLE_HIST_SAMPLE then
      SampleCount := LZMA2_INCOMPRESSIBLE_HIST_SAMPLE;
    for I := 0 to SampleCount - 1 do
      Inc(Histogram[Data[Offset + SampleOffset + I]]);

    DistinctCount := 0;
    MaxBucket := 0;
    for I := Low(Histogram) to High(Histogram) do
    begin
      if Histogram[I] <> 0 then
      begin
        Inc(DistinctCount);
        if Histogram[I] > MaxBucket then
          MaxBucket := Histogram[I];
      end;
    end;

    Result := (DistinctCount >= 240) and (MaxBucket <= UInt32(SampleCount div 32));
  end;

  function RequireHighEntropySample(const SampleOffset: Integer): Boolean;
  begin
    if SampleOffset = LastSampleOffset then
      Exit(True);
    Result := HighEntropySample(SampleOffset);
    if Result then
      LastSampleOffset := SampleOffset;
  end;
begin
  Result := False;
  if (Count < LZMA2_INCOMPRESSIBLE_MIN_SIZE) and
    ((not LikelyIncompressible) or (Count < LZMA2_INCOMPRESSIBLE_RETRY_MIN_SIZE)) then
    Exit;
  if (Offset < 0) or (Count < 0) or (Offset > Length(Data)) or (Count > Length(Data) - Offset) then
    Exit;

  SampleWindow := Count;
  if SampleWindow > LZMA2_INCOMPRESSIBLE_HIST_SAMPLE then
    SampleWindow := LZMA2_INCOMPRESSIBLE_HIST_SAMPLE;
  LastSampleOffset := -1;
  if not RequireHighEntropySample(0) then
    Exit;
  if Count > SampleWindow then
  begin
    if Count > SampleWindow * 2 then
    begin
      SampleOffset := (Count - SampleWindow) div 2;
      if not RequireHighEntropySample(SampleOffset) then
        Exit;
    end;
    if not RequireHighEntropySample(Count - SampleWindow) then
      Exit;
  end;
  if LikelyIncompressible then
    Exit(True);

  HashSpan := Count;
  if HashSpan > LZMA2_INCOMPRESSIBLE_HASH_SPAN then
    HashSpan := LZMA2_INCOMPRESSIBLE_HASH_SPAN;
  if HashSpan < 4096 then
    Exit;

  SetLength(Seen, 1 shl 16);
  HashSamples := 0;
  HashRepeats := 0;
  Pos := 0;
  while Pos + 4 <= HashSpan do
  begin
    H := UInt32(Data[Offset + Pos]);
    H := H xor (UInt32(Data[Offset + Pos + 1]) shl 8);
    H := H xor (UInt32(Data[Offset + Pos + 2]) shl 16);
    H := H xor (UInt32(Data[Offset + Pos + 3]) shl 24);
    H := (H * UInt32(2654435761)) xor (H shr 16);
    B := Seen[H and $FFFF];
    if B <> 0 then
      Inc(HashRepeats)
    else
      Seen[H and $FFFF] := 1;
    Inc(HashSamples);
    Inc(Pos, LZMA2_INCOMPRESSIBLE_HASH_STEP);
  end;

  if HashSamples < 128 then
    Exit;
  if (HashRepeats >= (HashSamples * 3) div 4) and not LikelyIncompressible then
    Exit;

  ProbeCount := Count;
  if ProbeCount > LZMA2_COPY_CHUNK_SIZE then
    ProbeCount := LZMA2_COPY_CHUNK_SIZE;
  ProbeEncoded := TLzmaRawEncoder.EncodeGreedyChunk(Data, Offset, ProbeCount, Props, FastBytes, CutValue,
    MatchFinderKind);
  Result := (Length(ProbeEncoded) = 0) or (Length(ProbeEncoded) > LZMA2_LZMA_PACK_SIZE_MAX) or
    (Length(ProbeEncoded) + LZMA2_LZMA_HEADER_SIZE >= Lzma2CopyRangeEncodedSize(ProbeCount));
end;

function TryDetectSmallPeriodicRange(const Data: TBytes; const Offset, Count: Integer;
  out Period: UInt32): Boolean;
var
  Candidate: UInt32;
  MatchLen: UInt32;
begin
  Period := 0;
  Result := False;
  if (Count < LZMA2_PERIODIC_MIN_SIZE) or (Offset < 0) or (Count < 0) or
    (Offset > Length(Data)) or (Count > Length(Data) - Offset) then
    Exit;

  for Candidate := 1 to LZMA2_PERIODIC_MAX_DISTANCE do
  begin
    if Integer(Candidate) >= Count then
      Break;
    MatchLen := LzmaCountMatchingBytes(Data, NativeUInt(Offset), NativeUInt(Offset) + Candidate,
      UInt32(Count - Integer(Candidate)));
    if MatchLen = UInt32(Count - Integer(Candidate)) then
    begin
      Period := Candidate;
      Exit(True);
    end;
  end;
end;

function TryDetectRepeatedPeriodicUnitRange(const Data: TBytes; const Offset, Count: Integer;
  const UnitSize: UInt32; out Period: UInt32): Boolean;
var
  MatchLen: UInt32;
begin
  Period := 0;
  Result := False;
  if (UnitSize = 0) or (UnitSize > UInt32(High(Integer))) then
    Exit;
  if (Integer(UnitSize) > Count div 2) or (Offset < 0) or (Count < 0) or
    (Offset > Length(Data)) or (Count > Length(Data) - Offset) then
    Exit;
  if not TryDetectSmallPeriodicRange(Data, Offset, Integer(UnitSize), Period) then
    Exit;
  MatchLen := LzmaCountMatchingBytes(Data, NativeUInt(Offset),
    NativeUInt(Offset) + NativeUInt(UnitSize), UInt32(Count - Integer(UnitSize)));
  Result := MatchLen = UInt32(Count - Integer(UnitSize));
end;

procedure AppendLzma2CompressedChunk(var Output: TBytes; var OutputSize: Integer; const Count: Integer;
  const Encoded: TBytes; const PropByte: Byte; const ResetDictionary: Boolean = True;
  const WriteProperties: Boolean = True; const ResetState: Boolean = True); forward;

function TryBuildLzma2PeriodicSubchunkSplit(const Chunk: TBytes; const Offset, Count: Integer;
  const Props: TLzmaProps; const FastBytes: Integer; const CutValue: UInt32;
  const MatchFinderKind: TLzmaMatchFinderKind; const EnableOptimumWindow: Boolean;
  const PropByte: Byte; out Output: TBytes; out FullOptimumDecisionCount: UInt64): Boolean;
var
  EncodedChunks: TArray<TBytes>;
  EncodedSize: Integer;
  OutputSize: Integer;
  SubOffset: Integer;
  PartCount: Integer;
  Period: UInt32;
  UnitSize: UInt32;
  ChunkIndex: Integer;
  UseRepeatedUnit: Boolean;
begin
  Result := False;
  SetLength(Output, 0);
  FullOptimumDecisionCount := 0;
  if Count < LZMA2_PERIODIC_MIN_SIZE then
    Exit;
  if Count <= LZMA2_LZMA_CHUNK_SIZE then
    Exit;
  if (Offset < 0) or (Count < 0) or (Offset > Length(Chunk)) or (Count > Length(Chunk) - Offset) then
    Exit;

  UnitSize := 0;
  UseRepeatedUnit := False;
  if Props.DictionarySize <= UInt32(High(Integer)) then
  begin
    UnitSize := UInt32(Props.DictionarySize);
    UseRepeatedUnit := TryDetectRepeatedPeriodicUnitRange(Chunk, Offset, Count, UnitSize, Period);
  end;
  if (not UseRepeatedUnit) and (not TryDetectSmallPeriodicRange(Chunk, Offset, Count, Period)) then
    Exit;

  if UseRepeatedUnit then
  begin
    if not TLzmaRawEncoder.EncodeRepeatedPeriodicUnitChunks(Chunk, NativeUInt(Offset),
      NativeUInt(Count), LZMA2_PERIODIC_SUBCHUNK_SIZE, Props, Period, UnitSize,
      EncodedChunks) then
      Exit;
  end
  else if not TLzmaRawEncoder.EncodePeriodicChunks(Chunk, NativeUInt(Offset), NativeUInt(Count),
    LZMA2_PERIODIC_SUBCHUNK_SIZE, Props, Period, EncodedChunks) then
    Exit;

  OutputSize := 0;
  SubOffset := 0;
  for ChunkIndex := 0 to High(EncodedChunks) do
  begin
    PartCount := Count - SubOffset;
    if PartCount > LZMA2_PERIODIC_SUBCHUNK_SIZE then
      PartCount := LZMA2_PERIODIC_SUBCHUNK_SIZE;
    EncodedSize := Length(EncodedChunks[ChunkIndex]);
    if (EncodedSize <= 0) or (EncodedSize > LZMA2_LZMA_PACK_SIZE_MAX) or
      (EncodedSize + LZMA2_LZMA_HEADER_SIZE >= Lzma2CopyRangeEncodedSize(PartCount)) then
    begin
      SetLength(Output, 0);
      Exit;
    end;
    AppendLzma2CompressedChunk(Output, OutputSize, PartCount,
      EncodedChunks[ChunkIndex], PropByte, ChunkIndex = 0, ChunkIndex = 0, ChunkIndex = 0);
    Inc(SubOffset, PartCount);
  end;
  SetLength(Output, OutputSize);
  Result := True;
end;

procedure AppendLzma2CompressedChunk(var Output: TBytes; var OutputSize: Integer; const Count: Integer;
  const Encoded: TBytes; const PropByte: Byte; const ResetDictionary: Boolean = True;
  const WriteProperties: Boolean = True; const ResetState: Boolean = True);
var
  NewSize: Integer;
  EncodedSize: Integer;
  HeaderSize: Integer;
  HasProperties: Boolean;
begin
  EncodedSize := Length(Encoded);
  if EncodedSize > LZMA2_LZMA_PACK_SIZE_MAX then
    RaiseLzmaError(SZ_ERROR_PARAM, 'LZMA2 compressed chunk exceeds 64 KiB packed size');
  HasProperties := WriteProperties or ResetDictionary;
  HeaderSize := 5;
  if HasProperties then
    Inc(HeaderSize);
  NewSize := OutputSize + EncodedSize + HeaderSize;
  EnsureLzma2BatchCapacity(Output, NewSize);
  Output[OutputSize] := $80 or Byte((Count - 1) shr 16);
  if ResetDictionary then
    Output[OutputSize] := Output[OutputSize] or $60
  else if HasProperties then
    Output[OutputSize] := Output[OutputSize] or $40
  else if ResetState then
    Output[OutputSize] := Output[OutputSize] or $20;
  Output[OutputSize + 1] := Byte((Count - 1) shr 8);
  Output[OutputSize + 2] := Byte(Count - 1);
  Output[OutputSize + 3] := Byte((EncodedSize - 1) shr 8);
  Output[OutputSize + 4] := Byte(EncodedSize - 1);
  if HasProperties then
    Output[OutputSize + 5] := PropByte;
  if EncodedSize > 0 then
    Move(Encoded[0], Output[OutputSize + HeaderSize], EncodedSize);
  OutputSize := NewSize;
end;

function TryBuildLzma2SplitFallback(const Chunk: TBytes; const Offset, Count: Integer; const Props: TLzmaProps;
  const FastBytes: Integer; const CutValue: UInt32; const MatchFinderKind: TLzmaMatchFinderKind;
  const EnableOptimumWindow: Boolean; const PropByte: Byte; out Output: TBytes;
  out FullOptimumDecisionCount: UInt64): Boolean;
var
  HeadCount: Integer;
  TailCount: Integer;
  TailEncoded: TBytes;
  TailEncodedSize: Integer;
  OutputSize: Integer;
  RawFullOptimumDecisionCount: UInt64;
begin
  Result := False;
  SetLength(Output, 0);
  FullOptimumDecisionCount := 0;
  if Count <= LZMA2_COPY_CHUNK_SIZE + LZMA2_INCOMPRESSIBLE_RETRY_MIN_SIZE then
    Exit;

  HeadCount := LZMA2_COPY_CHUNK_SIZE;
  TailCount := Count - HeadCount;
  if not LooksIncompressibleChunk(Chunk, Offset, HeadCount, Props, FastBytes, CutValue, MatchFinderKind) then
    Exit;
  if LooksIncompressibleChunk(Chunk, Offset + HeadCount, TailCount, Props, FastBytes, CutValue,
    MatchFinderKind) then
    Exit;

  RawFullOptimumDecisionCount := 0;
  TailEncoded := TLzmaRawEncoder.EncodeGreedyChunk(Chunk, Offset + HeadCount, TailCount, Props,
    FastBytes, CutValue, MatchFinderKind, False, EnableOptimumWindow, nil,
    @RawFullOptimumDecisionCount);
  TailEncodedSize := Length(TailEncoded);
  if (TailEncodedSize <= 0) or (TailEncodedSize > LZMA2_LZMA_PACK_SIZE_MAX) or
    (TailEncodedSize + LZMA2_LZMA_HEADER_SIZE >= Lzma2CopyRangeEncodedSize(TailCount)) then
    Exit;

  OutputSize := 0;
  AppendLzma2CopyChunksFromRange(Output, OutputSize, Chunk, Offset, HeadCount, True);
  AppendLzma2CompressedChunk(Output, OutputSize, TailCount, TailEncoded, PropByte);
  SetLength(Output, OutputSize);
  FullOptimumDecisionCount := RawFullOptimumDecisionCount;
  Result := True;
end;

function TryBuildLzma2SubchunkFallback(const Chunk: TBytes; const Offset, Count: Integer; const Props: TLzmaProps;
  const FastBytes: Integer; const CutValue: UInt32; const MatchFinderKind: TLzmaMatchFinderKind;
  const EnableOptimumWindow: Boolean; const PropByte: Byte; out Output: TBytes;
  out FullOptimumDecisionCount: UInt64): Boolean;
var
  Encoded: TBytes;
  EncodedSize: Integer;
  LocalFullOptimumDecisionCount: UInt64;
  OutputSize: Integer;
  SubOffset: Integer;
  PartCount: Integer;
  AnyCompressed: Boolean;
  RawFullOptimumDecisionCount: UInt64;
begin
  Result := False;
  SetLength(Output, 0);
  FullOptimumDecisionCount := 0;
  if Count <= LZMA2_COPY_CHUNK_SIZE then
    Exit;

  OutputSize := 0;
  SubOffset := 0;
  AnyCompressed := False;
  LocalFullOptimumDecisionCount := 0;
  while SubOffset < Count do
  begin
    PartCount := Count - SubOffset;
    if PartCount > LZMA2_MIXED_SUBCHUNK_SIZE then
      PartCount := LZMA2_MIXED_SUBCHUNK_SIZE;

    RawFullOptimumDecisionCount := 0;
    Encoded := TLzmaRawEncoder.EncodeGreedyChunk(Chunk, Offset + SubOffset, PartCount, Props,
      FastBytes, CutValue, MatchFinderKind, False, EnableOptimumWindow, nil,
      @RawFullOptimumDecisionCount);
    EncodedSize := Length(Encoded);
    if (EncodedSize > 0) and (EncodedSize <= LZMA2_LZMA_PACK_SIZE_MAX) and
      (EncodedSize + LZMA2_LZMA_HEADER_SIZE < Lzma2CopyRangeEncodedSize(PartCount)) then
    begin
      AppendLzma2CompressedChunk(Output, OutputSize, PartCount, Encoded, PropByte);
      Inc(LocalFullOptimumDecisionCount, RawFullOptimumDecisionCount);
      AnyCompressed := True;
    end
    else
      AppendLzma2CopyChunksFromRange(Output, OutputSize, Chunk, Offset + SubOffset, PartCount, True);

    Inc(SubOffset, PartCount);
  end;

  if (not AnyCompressed) or (OutputSize >= Lzma2CopyRangeEncodedSize(Count)) then
  begin
    SetLength(Output, 0);
    Exit;
  end;

  SetLength(Output, OutputSize);
  FullOptimumDecisionCount := LocalFullOptimumDecisionCount;
  Result := True;
end;

function EncodeLzma2WorkerBatch(const Chunk: TBytes; const Count: Integer; const Props: TLzmaProps;
  const FastBytes: Integer; const CutValue: UInt32; const MatchFinderKind: TLzmaMatchFinderKind;
  const EnableOptimumWindow: Boolean; const PropByte: Byte; const PartLimit: Integer;
  out FullOptimumDecisionCount: UInt64): TBytes;
var
  Offset: Integer;
  PartCount: Integer;
  Encoded: TBytes;
  EncodedSize: Integer;
  OutputSize: Integer;
  LikelyIncompressible: Boolean;
  SplitFallback: TBytes;
  SplitFullOptimumDecisionCount: UInt64;
  RawFullOptimumDecisionCount: UInt64;
begin
  SetLength(Result, 0);
  FullOptimumDecisionCount := 0;
  OutputSize := 0;
  Offset := 0;
  LikelyIncompressible := False;
  if TryBuildLzma2PeriodicSubchunkSplit(Chunk, 0, Count, Props, FastBytes, CutValue,
    MatchFinderKind, EnableOptimumWindow, PropByte, SplitFallback,
    SplitFullOptimumDecisionCount) then
  begin
    Result := SplitFallback;
    FullOptimumDecisionCount := SplitFullOptimumDecisionCount;
    Exit;
  end;

  while Offset < Count do
  begin
    PartCount := Count - Offset;
    if PartCount > PartLimit then
      PartCount := PartLimit;

    if TryBuildLzma2PeriodicSubchunkSplit(Chunk, Offset, PartCount, Props, FastBytes, CutValue,
      MatchFinderKind, EnableOptimumWindow, PropByte, SplitFallback,
      SplitFullOptimumDecisionCount) then
    begin
      AppendLzma2EncodedBytes(Result, OutputSize, SplitFallback);
      Inc(FullOptimumDecisionCount, SplitFullOptimumDecisionCount);
      LikelyIncompressible := False;
    end
    else if LooksIncompressibleChunk(Chunk, Offset, PartCount, Props, FastBytes, CutValue, MatchFinderKind,
      LikelyIncompressible) then
    begin
      AppendLzma2CopyChunksFromRange(Result, OutputSize, Chunk, Offset, PartCount, True);
      LikelyIncompressible := True;
    end
    else
    begin
      RawFullOptimumDecisionCount := 0;
      Encoded := TLzmaRawEncoder.EncodeGreedyChunk(Chunk, Offset, PartCount, Props, FastBytes, CutValue,
        MatchFinderKind, False, EnableOptimumWindow, nil, @RawFullOptimumDecisionCount);
      EncodedSize := Length(Encoded);
      if (EncodedSize > 0) and (EncodedSize <= LZMA2_LZMA_PACK_SIZE_MAX) and
        (EncodedSize + LZMA2_LZMA_HEADER_SIZE < Lzma2CopyRangeEncodedSize(PartCount)) then
      begin
        AppendLzma2CompressedChunk(Result, OutputSize, PartCount, Encoded, PropByte);
        Inc(FullOptimumDecisionCount, RawFullOptimumDecisionCount);
        LikelyIncompressible := False;
      end
      else
      begin
        if TryBuildLzma2SubchunkFallback(Chunk, Offset, PartCount, Props, FastBytes, CutValue,
          MatchFinderKind, EnableOptimumWindow, PropByte, SplitFallback,
          SplitFullOptimumDecisionCount) or
          TryBuildLzma2SplitFallback(Chunk, Offset, PartCount, Props, FastBytes, CutValue,
          MatchFinderKind, EnableOptimumWindow, PropByte, SplitFallback,
          SplitFullOptimumDecisionCount) then
        begin
          AppendLzma2EncodedBytes(Result, OutputSize, SplitFallback);
          Inc(FullOptimumDecisionCount, SplitFullOptimumDecisionCount);
          LikelyIncompressible := False;
        end
        else
        begin
          AppendLzma2CopyChunksFromRange(Result, OutputSize, Chunk, Offset, PartCount, True);
          LikelyIncompressible := True;
        end;
      end;
    end;
    Inc(Offset, PartCount);
  end;
  SetLength(Result, OutputSize);
end;

procedure TLzma2ChunkJob.Execute;
begin
  try
    Data := EncodeLzma2WorkerBatch(Input, Count, Props, FastBytes, CutValue, MatchFinderKind,
      EnableOptimumWindow, PropByte, PartLimit, FullOptimumDecisionCount);
  except
    on E: ELzmaError do
    begin
      ErrorCode := E.ResultCode;
      ErrorMessage := E.Message;
    end;
    on E: Exception do
    begin
      ErrorCode := SZ_ERROR_THREAD;
      ErrorMessage := E.ClassName + ': ' + E.Message;
    end;
  end;
  Input := nil;
  Completed := True;
end;

class function TLzma2Encoder.NormalizeOptions(const Options: TLzma2Options): TLzma2Options;
var
  Props: TLzmaProps;
begin
  Result := Options;
  if Result.DictionarySize = 0 then
    Result.DictionarySize := DefaultDictionaryForLevel(Result.Level);
  if Result.ThreadCount < 1 then
    Result.ThreadCount := 1;
  Result.BufferSize := CheckedBufferSize(Result.BufferSize);
  if Result.Level = 0 then
  begin
    if Result.BufferSize > LZMA2_COPY_CHUNK_SIZE then
      Result.BufferSize := LZMA2_COPY_CHUNK_SIZE;
  end
  else if Result.BufferSize > LZMA2_LZMA_CHUNK_SIZE then
    Result.BufferSize := LZMA2_LZMA_CHUNK_SIZE;
  if (Result.ParserMode = lpmHighSpeed) and (Result.MatchFinderProfile = lmfpAuto) then
    Result.MatchFinderProfile := lmfpHashChain5;
  if (Result.FastBytes <> 0) and
    ((Result.FastBytes < LZMA_FAST_BYTES_MIN) or (Result.FastBytes > LZMA_FAST_BYTES_MAX)) then
    RaiseLzmaError(SZ_ERROR_PARAM, Format('Fast bytes must be 0 or in %d..%d',
      [LZMA_FAST_BYTES_MIN, LZMA_FAST_BYTES_MAX]));
  Props := TLzmaRawEncoder.DefaultProperties(Result.DictionarySize);
  if not TryApplyLzmaOptionsToProps(Props, Result, Result.Container <> lcLzma) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA lc/lp/pb options');
end;

class function TLzma2Encoder.DictionaryInfo(const Options: TLzma2Options): TLzma2DictionaryInfo;
var
  Normalized: TLzma2Options;
begin
  Normalized := NormalizeOptions(Options);
  if not TryLzma2PropertyFromDictionary(Normalized.DictionarySize, Normalized.StrictValidation, Result) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Dictionary size is not representable as an LZMA2 property');
end;

class procedure TLzma2Encoder.EncodeRaw(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  Normalized: TLzma2Options;
  Info: TLzma2DictionaryInfo;
  Buffer: TBytes;
  PendingBuffer: TBytes;
  PeriodicGroup: TBytes;
  EncodedChunk: TBytes;
  SplitFallback: TBytes;
  EncodedSize: Integer;
  ReadCount: Integer;
  PeriodicGroupCount: Integer;
  PendingReadCount: Integer;
  EofByte: Byte;
  Props: TLzmaProps;
  PropByte: Byte;
  ChunkBufferSize: NativeUInt;
  InTotal: UInt64;
  OutTotal: UInt64;
  FirstChunk: Boolean;
  UseCompressedChunks: Boolean;
  LikelyIncompressible: Boolean;
  Profile: TLzmaEncoderProfile;
  EnableOptimumWindow: Boolean;
  ChunkFullOptimumDecisionCount: UInt64;
  CanWriteNoPropsCompressed: Boolean;
  HistorySize: UInt64;
  HistoryPrevByte: Byte;
  SplitFullOptimumDecisionCount: UInt64;
  HasPendingBuffer: Boolean;
  CurrentReadCounted: Boolean;

  procedure ApplyProfileOptionOverrides;
  begin
    case Normalized.MatchFinderProfile of
      lmfpHashChain4:
        begin
          Profile.MatchFinderKind := mfHashChain4;
          Profile.MatchFinderProfile := lmfpHashChain4;
          Profile.MatchFinder := 'hc4-diagnostic';
          Profile.NumHashBytes := 4;
        end;
      lmfpHashChain5:
        begin
          Profile.MatchFinderKind := mfHashChain5;
          Profile.MatchFinderProfile := lmfpHashChain5;
          Profile.MatchFinder := 'hc5-diagnostic';
          Profile.NumHashBytes := 5;
        end;
      lmfpBinaryTree4:
        begin
          Profile.MatchFinderKind := mfBinaryTree4;
          Profile.MatchFinderProfile := lmfpBinaryTree4;
          Profile.MatchFinder := 'bt4-diagnostic';
          Profile.NumHashBytes := 4;
        end;
    end;
    if Normalized.FastBytes <> 0 then
      Profile.FastBytes := Normalized.FastBytes;
    if Normalized.CutValue <> 0 then
      Profile.CutValue := Normalized.CutValue;
    Profile.ParserMode := Normalized.ParserMode;
  end;

  procedure ResetEncodeDiagnostics;
  begin
    if Normalized.EncodeDiagnostics = nil then
      Exit;
    Normalized.EncodeDiagnostics^.RequestedThreadCount := Normalized.ThreadCount;
    Normalized.EncodeDiagnostics^.ActualThreadCount := 1;
    Normalized.EncodeDiagnostics^.BatchCount := 0;
    Normalized.EncodeDiagnostics^.BlockCount := 0;
    Normalized.EncodeDiagnostics^.FastBytes := Profile.FastBytes;
    Normalized.EncodeDiagnostics^.NiceLen := Profile.FastBytes;
    Normalized.EncodeDiagnostics^.CutValue := Profile.CutValue;
    Normalized.EncodeDiagnostics^.XzBlockSize := Normalized.XzBlockSize;
    Normalized.EncodeDiagnostics^.ParserMode := Profile.ParserMode;
    Normalized.EncodeDiagnostics^.MatchFinderProfile := Profile.MatchFinderProfile;
    Normalized.EncodeDiagnostics^.NumHashBytes := Profile.NumHashBytes;
    Normalized.EncodeDiagnostics^.OptimumParserEnabled := False;
    Normalized.EncodeDiagnostics^.FullOptimumDecisionCount := 0;
    Normalized.EncodeDiagnostics^.CopyFastPathCount := 0;
    Normalized.EncodeDiagnostics^.IncompressibleFastPathCount := 0;
    Normalized.EncodeDiagnostics^.FallbackReason := 'none';
  end;

  procedure NoteFullOptimumDecisions(const DecisionCount: UInt64);
  begin
    if (Normalized.EncodeDiagnostics = nil) or (DecisionCount = 0) then
      Exit;
    Normalized.EncodeDiagnostics^.FullOptimumDecisionCount :=
      Normalized.EncodeDiagnostics^.FullOptimumDecisionCount + DecisionCount;
    Normalized.EncodeDiagnostics^.OptimumParserEnabled := True;
  end;

  procedure NoteEncodedBlock(const FullOptimumDecisionCount: UInt64 = 0);
  begin
    if Normalized.EncodeDiagnostics = nil then
      Exit;
    Inc(Normalized.EncodeDiagnostics^.BlockCount);
    NoteFullOptimumDecisions(FullOptimumDecisionCount);
  end;

  procedure NoteEncodedBlocksInBytes(const Data: TBytes;
    const FullOptimumDecisionCount: UInt64 = 0);
  var
    CompressedBlockCount: Integer;
    Control: Byte;
    HasProperties: Boolean;
    PackSize: Integer;
    Pos: Integer;
    UnpackSize: Integer;
  begin
    if Normalized.EncodeDiagnostics = nil then
      Exit;
    Pos := 0;
    CompressedBlockCount := 0;
    while Pos < Length(Data) do
    begin
      Control := Data[Pos];
      Inc(Pos);
      if Control = LZMA2_CONTROL_EOF then
        Break;
      if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
      begin
        if Pos + 2 > Length(Data) then
          Break;
        UnpackSize := ((Integer(Data[Pos]) shl 8) or Integer(Data[Pos + 1])) + 1;
        Inc(Pos, 2 + UnpackSize);
        Continue;
      end;
      if Control < $80 then
        Break;
      if Pos + 4 > Length(Data) then
        Break;
      PackSize := ((Integer(Data[Pos + 2]) shl 8) or Integer(Data[Pos + 3])) + 1;
      Inc(Pos, 4);
      HasProperties := (Control and $40) <> 0;
      if HasProperties then
        Inc(Pos);
      Inc(CompressedBlockCount);
      NoteEncodedBlock;
      Inc(Pos, PackSize);
    end;
    if CompressedBlockCount > 0 then
      NoteFullOptimumDecisions(FullOptimumDecisionCount);
  end;

  procedure NoteBatch;
  begin
    if Normalized.EncodeDiagnostics <> nil then
      Inc(Normalized.EncodeDiagnostics^.BatchCount);
  end;

  procedure NoteCopyFastPath(const Incompressible: Boolean);
  begin
    if Normalized.EncodeDiagnostics = nil then
      Exit;
    Inc(Normalized.EncodeDiagnostics^.CopyFastPathCount);
    if Incompressible then
      Inc(Normalized.EncodeDiagnostics^.IncompressibleFastPathCount);
  end;

  procedure NoteMtActualWorkers(const Count: Integer);
  begin
    if Normalized.EncodeDiagnostics <> nil then
      Normalized.EncodeDiagnostics^.ActualThreadCount := Count;
  end;

  function TryGetSourceRemaining(out Remaining: UInt64): Boolean;
  var
    CurrentPosition: Int64;
    SourceSize: Int64;
  begin
    Remaining := 0;
    Result := False;

    try
      CurrentPosition := Source.Position;
      SourceSize := Source.Size;
    except
      Exit;
    end;
    if SourceSize < CurrentPosition then
      Exit;

    Remaining := UInt64(SourceSize - CurrentPosition);
    Result := True;
  end;

  function MtBatchTargetSize: NativeUInt;
  begin
    if Normalized.ThreadCount <= 2 then
      Result := LZMA2_MT_BATCH_SIZE_2T
    else if Normalized.ThreadCount >= 8 then
      Result := LZMA2_MT_BATCH_SIZE_8T
    else
      Result := LZMA2_MT_BATCH_SIZE;
  end;

  function MtReadBufferSize: NativeUInt;
  var
    PartsPerJob: NativeUInt;
  begin
    PartsPerJob := MtBatchTargetSize div ChunkBufferSize;
    if PartsPerJob = 0 then
      PartsPerJob := 1;
    Result := PartsPerJob * ChunkBufferSize;
  end;

  function ShouldUseMtEncode: Boolean;
  var
    Remaining: UInt64;
    MinParallelInput: UInt64;
  begin
    Result := UseCompressedChunks and (Normalized.ThreadCount > 1);
    if not Result then
      Exit;

    MinParallelInput := UInt64(MtReadBufferSize) * 2;
    if TryGetSourceRemaining(Remaining) and (Remaining < MinParallelInput) then
      Result := False;
  end;

  function SingleThreadMemoryRequired: UInt64;
  const
    kMatchFinderWorkerOverhead = UInt64(8) shl 20;
  begin
    if not UseCompressedChunks then
      Exit(0);

    Result := Info.NormalizedSize +
      UInt64(ChunkBufferSize) * (UInt64(SizeOf(NativeInt)) * 2 + 4) +
      kMatchFinderWorkerOverhead;
  end;

  procedure WriteCopyChunk(const Count: Integer; const ResetDictionary: Boolean; const Incompressible: Boolean);
  var
    Chunk: TBytes;
    Offset: Integer;
    PartCount: Integer;
    ResetThisChunk: Boolean;
  begin
    Offset := 0;
    ResetThisChunk := ResetDictionary;
    while Offset < Count do
    begin
      PartCount := Count - Offset;
      if PartCount > LZMA2_COPY_CHUNK_SIZE then
        PartCount := LZMA2_COPY_CHUNK_SIZE;
      SetLength(Chunk, PartCount);
      if PartCount > 0 then
        Move(Buffer[Offset], Chunk[0], PartCount);
      Chunk := BuildLzma2CopyChunk(Chunk, PartCount, ResetThisChunk);
      WriteBytes(Destination, Chunk);
      Inc(OutTotal, UInt64(Length(Chunk)));
      NoteCopyFastPath(Incompressible);
      ResetThisChunk := False;
      Inc(Offset, PartCount);
    end;
    if ResetDictionary then
    begin
      CanWriteNoPropsCompressed := False;
      HistorySize := 0;
      HistoryPrevByte := 0;
    end;
    if Count > 0 then
    begin
      if UInt64(Count) > High(UInt64) - HistorySize then
        HistorySize := High(UInt64)
      else
        Inc(HistorySize, UInt64(Count));
      HistoryPrevByte := Buffer[Count - 1];
    end;
  end;

  procedure WriteLzmaChunk(const Count: Integer; const Encoded: TBytes;
    const ResetDictionary: Boolean = True; const WriteProperties: Boolean = True;
    const FullOptimumDecisionCount: UInt64 = 0);
  var
    Chunk: TBytes;
  begin
    Chunk := BuildLzma2CompressedChunk(Count, Encoded, PropByte, ResetDictionary, WriteProperties);
    WriteBytes(Destination, Chunk);
    Inc(OutTotal, UInt64(Length(Chunk)));
    NoteEncodedBlock(FullOptimumDecisionCount);
    if ResetDictionary then
      HistorySize := 0;
    if Count > 0 then
    begin
      if UInt64(Count) > High(UInt64) - HistorySize then
        HistorySize := High(UInt64)
      else
        Inc(HistorySize, UInt64(Count));
      HistoryPrevByte := Buffer[Count - 1];
    end;
    CanWriteNoPropsCompressed := True;
  end;

  procedure StashPendingBuffer(const Data: TBytes; const Count: Integer);
  begin
    if Count <= 0 then
      Exit;
    SetLength(PendingBuffer, Count);
    Move(Data[0], PendingBuffer[0], Count);
    PendingReadCount := Count;
    HasPendingBuffer := True;
  end;

  function ReadNextEncodeBuffer(out AlreadyCounted: Boolean): Integer;
  begin
    AlreadyCounted := False;
    if HasPendingBuffer then
    begin
      if NativeUInt(Length(Buffer)) <> ChunkBufferSize then
        SetLength(Buffer, ChunkBufferSize);
      if Length(Buffer) < PendingReadCount then
        SetLength(Buffer, PendingReadCount);
      Move(PendingBuffer[0], Buffer[0], PendingReadCount);
      Result := PendingReadCount;
      SetLength(PendingBuffer, 0);
      PendingReadCount := 0;
      HasPendingBuffer := False;
      AlreadyCounted := True;
      Exit;
    end;

    if NativeUInt(Length(Buffer)) <> ChunkBufferSize then
      SetLength(Buffer, ChunkBufferSize);
    Result := ReadAvailable(Source, Buffer[0], Length(Buffer));
  end;

  function IsDistanceContinuation(const Existing: TBytes; const ExistingCount: Integer;
    const Next: TBytes; const NextCount: Integer; const Distance: UInt32): Boolean;
  var
    I: Integer;
    SourceIndex: Integer;
    Expected: Byte;
  begin
    Result := False;
    if (Distance = 0) or (ExistingCount < Integer(Distance)) or (NextCount < 0) then
      Exit;
    for I := 0 to NextCount - 1 do
    begin
      SourceIndex := I - Integer(Distance);
      if SourceIndex >= 0 then
        Expected := Next[SourceIndex]
      else
        Expected := Existing[ExistingCount + SourceIndex];
      if Next[I] <> Expected then
        Exit;
    end;
    Result := True;
  end;

  function TryReadPeriodicGroup(const FirstCount: Integer; out Group: TBytes;
    out GroupCount: Integer): Boolean;
  var
    Period: UInt32;
    UnitSize: UInt32;
    Next: TBytes;
    NextCount: Integer;
    NewSize: Integer;
    ContinuationDistance: UInt32;
  begin
    Result := False;
    SetLength(Group, 0);
    GroupCount := 0;
    if ChunkBufferSize < LZMA2_PERIODIC_SUBCHUNK_SIZE then
      Exit;
    ContinuationDistance := 0;
    if Props.DictionarySize <= UInt32(High(Integer)) then
    begin
      UnitSize := UInt32(Props.DictionarySize);
      if TryDetectRepeatedPeriodicUnitRange(Buffer, 0, FirstCount, UnitSize, Period) then
        ContinuationDistance := UnitSize;
    end;
    if ContinuationDistance = 0 then
    begin
      if not TryDetectSmallPeriodicRange(Buffer, 0, FirstCount, Period) then
        Exit;
      ContinuationDistance := Period;
    end;

    SetLength(Group, FirstCount);
    Move(Buffer[0], Group[0], FirstCount);
    GroupCount := FirstCount;
    SetLength(Next, ChunkBufferSize);

    while UInt64(GroupCount) < UInt64(LZMA2_PERIODIC_GROUP_LIMIT) do
    begin
      NextCount := ReadAvailable(Source, Next[0], Length(Next));
      if NextCount = 0 then
        Break;
      Inc(InTotal, UInt64(NextCount));
      if not IsDistanceContinuation(Group, GroupCount, Next, NextCount, ContinuationDistance) then
      begin
        StashPendingBuffer(Next, NextCount);
        Break;
      end;

      NewSize := GroupCount + NextCount;
      SetLength(Group, NewSize);
      Move(Next[0], Group[GroupCount], NextCount);
      GroupCount := NewSize;
    end;

    Result := GroupCount > FirstCount;
  end;

  procedure EncodeRawMt;
  var
    Results: array of TLzma2OutputChunk;
    Threads: array of TThread;
    Jobs: array of TLzma2ChunkJob;
    Chunk: TBytes;
    LocalRead: Integer;
    MaxWorkers: Integer;
    ActiveCount: Integer;
    NextIndex: Integer;
    NextToWrite: Integer;
    FirstErrorCode: SRes;
    FirstErrorMessage: string;
    EndOfInput: Boolean;
    StopScheduling: Boolean;
    Slot: Integer;
    CompletedNormally: Boolean;
    PeakActiveWorkers: Integer;
    ReadBufferSize: NativeUInt;
    ReadBufferByteCount: Integer;
    StartedJobCount: Integer;

    procedure CaptureError(const Code: SRes; const Msg: string);
    begin
      if FirstErrorCode = SZ_OK then
      begin
        FirstErrorCode := Code;
        FirstErrorMessage := Msg;
      end;
      StopScheduling := True;
    end;

    procedure CaptureException(const E: Exception);
    begin
      if E is ELzmaError then
        CaptureError(ELzmaError(E).ResultCode, E.Message)
      else
        CaptureError(SZ_ERROR_THREAD, E.ClassName + ': ' + E.Message);
    end;

    function MemoryRequiredForWorkers(const WorkerCount: Integer): UInt64;
    const
      kGreedyWorkerOverhead = UInt64(8) shl 20;
    var
      PerWorker: UInt64;
    begin
      PerWorker := Info.NormalizedSize +
        UInt64(ReadBufferSize) * 4 +
        UInt64(ChunkBufferSize) * (UInt64(SizeOf(NativeInt)) * 2 + 4) +
        kGreedyWorkerOverhead;
      Result := Info.NormalizedSize + UInt64(WorkerCount) * PerWorker;
    end;

    function FindFreeSlot: Integer;
    begin
      for Result := 0 to High(Threads) do
        if (Threads[Result] = nil) and (Jobs[Result] = nil) then
          Exit;
      Result := -1;
    end;

    procedure StartWorker(const ASlot: Integer; const AIndex: Integer; const AChunk: TBytes;
      const ACount: Integer);
    var
      Job: TLzma2ChunkJob;
    begin
      Job := TLzma2ChunkJob.Create;
      Job.Index := AIndex;
      Job.Input := AChunk;
      Job.Count := ACount;
      Job.Props := Props;
      Job.FastBytes := Profile.FastBytes;
      Job.CutValue := Profile.CutValue;
      Job.MatchFinderKind := Profile.MatchFinderKind;
      Job.EnableOptimumWindow := EnableOptimumWindow;
      Job.PropByte := PropByte;
      Job.PartLimit := Integer(ChunkBufferSize);
      Jobs[ASlot] := Job;
      NoteBatch;
      try
        Threads[ASlot] := TThread.CreateAnonymousThread(
          procedure
          begin
            Job.Execute;
          end);
        Threads[ASlot].FreeOnTerminate := False;
        Threads[ASlot].Start;
      except
        Threads[ASlot].Free;
        Threads[ASlot] := nil;
        Jobs[ASlot] := nil;
        Job.Free;
        raise;
      end;
      Inc(ActiveCount);
      Inc(StartedJobCount);
      if ActiveCount > PeakActiveWorkers then
        PeakActiveWorkers := ActiveCount;
    end;

    function WaitForOneWorker: Integer;
    var
      SlotIndex: Integer;
    begin
      repeat
        for SlotIndex := 0 to High(Threads) do
          if (Threads[SlotIndex] <> nil) and Threads[SlotIndex].Finished then
            Exit(SlotIndex);
        TThread.Sleep(0);
      until False;
    end;

    procedure FinishWorker(const ASlot: Integer);
    var
      ResultIndex: Integer;
      Job: TLzma2ChunkJob;
    begin
      Job := Jobs[ASlot];
      if Job = nil then
      begin
        CaptureError(SZ_ERROR_THREAD, 'Worker job state was lost');
        ResultIndex := -1;
      end
      else
        ResultIndex := Job.Index;
      if Threads[ASlot] = nil then
        CaptureError(SZ_ERROR_THREAD, 'Worker thread state was lost')
      else
        Threads[ASlot].WaitFor;
      if (ResultIndex >= 0) and (ResultIndex < Length(Results)) then
      begin
        if not Job.Completed then
        begin
          Job.ErrorCode := SZ_ERROR_THREAD;
          Job.ErrorMessage := 'Worker task failed before producing a result';
        end;
        Results[ResultIndex].InputSize := Job.Count;
        Results[ResultIndex].Data := Job.Data;
        Results[ResultIndex].FullOptimumDecisionCount := Job.FullOptimumDecisionCount;
        Results[ResultIndex].ErrorCode := Job.ErrorCode;
        Results[ResultIndex].ErrorMessage := Job.ErrorMessage;
        Results[ResultIndex].Completed := True;
        if Results[ResultIndex].ErrorCode <> SZ_OK then
          CaptureError(Results[ResultIndex].ErrorCode, Results[ResultIndex].ErrorMessage);
      end;
      if Job <> nil then
      begin
        Job.Data := nil;
        Job.Free;
      end;
      if Threads[ASlot] <> nil then
      begin
        Threads[ASlot].Free;
        Threads[ASlot] := nil;
      end;
      Jobs[ASlot] := nil;
      Dec(ActiveCount);
    end;

    procedure ReportMtProgress;
    var
      Cancel: Boolean;
    begin
      if not Assigned(Progress) then
        Exit;
      Cancel := False;
      Progress(InTotal, OutTotal, Cancel);
      if Cancel then
        CaptureError(SZ_ERROR_PROGRESS, 'Operation cancelled');
    end;

    procedure DrainReadyResults;
    begin
      while (NextToWrite < Length(Results)) and Results[NextToWrite].Completed do
      begin
        if Results[NextToWrite].ErrorCode <> SZ_OK then
        begin
          CaptureError(Results[NextToWrite].ErrorCode, Results[NextToWrite].ErrorMessage);
          Inc(NextToWrite);
          Continue;
        end;
        if FirstErrorCode = SZ_OK then
        begin
          WriteBytes(Destination, Results[NextToWrite].Data);
          Inc(OutTotal, UInt64(Length(Results[NextToWrite].Data)));
          NoteEncodedBlocksInBytes(Results[NextToWrite].Data,
            Results[NextToWrite].FullOptimumDecisionCount);
          ReportMtProgress;
        end;
        Results[NextToWrite].Data := nil;
        Inc(NextToWrite);
      end;
    end;

    procedure WaitAndFreeOutstandingJobs;
    var
      SlotIndex: Integer;
      Job: TLzma2ChunkJob;
    begin
      for SlotIndex := 0 to High(Threads) do
      begin
        if Threads[SlotIndex] <> nil then
        begin
          try
            Threads[SlotIndex].WaitFor;
          except
            // Cleanup must not mask the original main-thread exception.
          end;
          Threads[SlotIndex].Free;
          Threads[SlotIndex] := nil;
        end;
        Job := Jobs[SlotIndex];
        if Job <> nil then
        begin
          Job.Input := nil;
          Job.Data := nil;
          Job.Free;
          Jobs[SlotIndex] := nil;
        end;
      end;
      ActiveCount := 0;
  end;
begin
    MaxWorkers := Normalized.ThreadCount;
    ReadBufferSize := MtReadBufferSize;
    if ReadBufferSize > NativeUInt(High(Integer)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'LZMA2 MT read batch is too large');
    ReadBufferByteCount := Integer(ReadBufferSize);
    ValidateMemoryLimit(MemoryRequiredForWorkers(MaxWorkers), Normalized.MemoryLimit);

    SetLength(Threads, MaxWorkers);
    SetLength(Jobs, MaxWorkers);

    ActiveCount := 0;
    NextIndex := 0;
    NextToWrite := 0;
    FirstErrorCode := SZ_OK;
    FirstErrorMessage := '';
    EndOfInput := False;
    StopScheduling := False;
    CompletedNormally := False;
    PeakActiveWorkers := 0;
    StartedJobCount := 0;

    try
      repeat
        while (not EndOfInput) and (not StopScheduling) and (ActiveCount < MaxWorkers) do
        begin
          try
            ValidateMemoryLimit(MemoryRequiredForWorkers(ActiveCount + 1), Normalized.MemoryLimit);
            SetLength(Chunk, ReadBufferByteCount);
            LocalRead := ReadAvailable(Source, Chunk[0], Length(Chunk));
            if LocalRead = 0 then
            begin
              Chunk := nil;
              EndOfInput := True;
              Break;
            end;
            if LocalRead < Length(Chunk) then
              SetLength(Chunk, LocalRead);
          except
            on E: Exception do
            begin
              CaptureException(E);
              Break;
            end;
          end;

          Inc(InTotal, UInt64(LocalRead));
          SetLength(Results, NextIndex + 1);
          Slot := FindFreeSlot;
          if Slot < 0 then
          begin
            CaptureError(SZ_ERROR_THREAD, 'No free worker slot');
            Break;
          end;
          try
            StartWorker(Slot, NextIndex, Chunk, LocalRead);
            Chunk := nil;
            Inc(NextIndex);
          except
            on E: Exception do
            begin
              CaptureException(E);
              Break;
            end;
          end;
        end;

        DrainReadyResults;
        if ActiveCount = 0 then
          Break;
        Slot := WaitForOneWorker;
        FinishWorker(Slot);
        DrainReadyResults;
      until False;

      while ActiveCount > 0 do
      begin
        Slot := WaitForOneWorker;
        FinishWorker(Slot);
        DrainReadyResults;
      end;

      DrainReadyResults;
      CompletedNormally := True;
    finally
      if not CompletedNormally then
        WaitAndFreeOutstandingJobs;
    end;
    if PeakActiveWorkers > 0 then
      NoteMtActualWorkers(PeakActiveWorkers)
    else
      NoteMtActualWorkers(1);
    if (FirstErrorCode = SZ_OK) and (StartedJobCount > 0) and (PeakActiveWorkers < 2) and
      (Normalized.EncodeDiagnostics <> nil) then
      Normalized.EncodeDiagnostics^.FallbackReason := 'insufficient-work';
    if FirstErrorCode <> SZ_OK then
      RaiseLzmaError(FirstErrorCode, FirstErrorMessage);
  end;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  Normalized := NormalizeOptions(Options);
  Info := DictionaryInfo(Normalized);

  UseCompressedChunks := Normalized.Level > 0;
  ChunkBufferSize := Normalized.BufferSize;
  ValidateMemoryLimit(SingleThreadMemoryRequired, Normalized.MemoryLimit);
  SetLength(Buffer, ChunkBufferSize);
  Props := TLzmaRawEncoder.DefaultProperties(Info.NormalizedSize);
  if not TryApplyLzmaOptionsToProps(Props, Normalized, True) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA2 lc/lp/pb options');
  PropByte := Byte((Props.Pb * 5 + Props.Lp) * 9 + Props.Lc);
  Profile := TLzmaRawEncoder.NormalizeProfile(Normalized.Level, Info.NormalizedSize);
  ApplyProfileOptionOverrides;
  EnableOptimumWindow := UseCompressedChunks and (Profile.ParserMode = lpmSdkProfile);
  ResetEncodeDiagnostics;
  InTotal := 0;
  OutTotal := 0;
  FirstChunk := True;
  LikelyIncompressible := False;
  CanWriteNoPropsCompressed := False;
  HistorySize := 0;
  HistoryPrevByte := 0;
  HasPendingBuffer := False;
  PendingReadCount := 0;

  if ShouldUseMtEncode then
    EncodeRawMt
  else
  begin
    if (Normalized.ThreadCount > 1) and (Normalized.EncodeDiagnostics <> nil) then
      Normalized.EncodeDiagnostics^.FallbackReason := 'single-thread-scheduling';

    repeat
      ReadCount := ReadNextEncodeBuffer(CurrentReadCounted);
      if ReadCount > 0 then
      begin
        if not CurrentReadCounted then
          Inc(InTotal, UInt64(ReadCount));
        if UseCompressedChunks then
        begin
          if TryReadPeriodicGroup(ReadCount, PeriodicGroup, PeriodicGroupCount) then
          begin
            Buffer := PeriodicGroup;
            ReadCount := PeriodicGroupCount;
          end;
          if TryBuildLzma2PeriodicSubchunkSplit(Buffer, 0, ReadCount, Props, Profile.FastBytes,
            Profile.CutValue, Profile.MatchFinderKind, EnableOptimumWindow, PropByte,
            SplitFallback, SplitFullOptimumDecisionCount) then
          begin
            WriteBytes(Destination, SplitFallback);
            Inc(OutTotal, UInt64(Length(SplitFallback)));
            NoteEncodedBlocksInBytes(SplitFallback, SplitFullOptimumDecisionCount);
            CanWriteNoPropsCompressed := False;
            LikelyIncompressible := False;
          end
          else if LooksIncompressibleChunk(Buffer, 0, ReadCount, Props, Profile.FastBytes, Profile.CutValue,
            Profile.MatchFinderKind, LikelyIncompressible) then
          begin
            WriteCopyChunk(ReadCount, True, True);
            LikelyIncompressible := True;
          end
          else
          begin
            ChunkFullOptimumDecisionCount := 0;
            EncodedChunk := TLzmaRawEncoder.EncodeGreedyChunk(Buffer, 0, ReadCount, Props,
              Profile.FastBytes, Profile.CutValue, Profile.MatchFinderKind, False,
              EnableOptimumWindow, nil, @ChunkFullOptimumDecisionCount);
            EncodedSize := Length(EncodedChunk);
            if CanWriteNoPropsCompressed and (ReadCount <= 16 * 1024) then
            begin
              SplitFallback := TLzmaRawEncoder.EncodeLiteralOnlyChunkWithState(Buffer, 0,
                NativeUInt(ReadCount), Props, HistorySize, HistoryPrevByte);
              if (Length(SplitFallback) > 0) and (Length(SplitFallback) <= LZMA2_LZMA_PACK_SIZE_MAX) and
                (Length(SplitFallback) + 5 < Lzma2CopyRangeEncodedSize(ReadCount)) then
              begin
                WriteLzmaChunk(ReadCount, SplitFallback, False, False, 0);
                LikelyIncompressible := False;
                FirstChunk := False;
                ReportProgress(Progress, InTotal, OutTotal);
                Continue;
              end;
            end;
            if (EncodedSize > 0) and (EncodedSize <= LZMA2_LZMA_PACK_SIZE_MAX) and
              (EncodedSize + LZMA2_LZMA_HEADER_SIZE < Lzma2CopyRangeEncodedSize(ReadCount)) then
            begin
              WriteLzmaChunk(ReadCount, EncodedChunk, True, True,
                ChunkFullOptimumDecisionCount);
              LikelyIncompressible := False;
            end
            else
            begin
              if TryBuildLzma2SubchunkFallback(Buffer, 0, ReadCount, Props, Profile.FastBytes,
                Profile.CutValue, Profile.MatchFinderKind, EnableOptimumWindow, PropByte,
                SplitFallback, SplitFullOptimumDecisionCount) or
                TryBuildLzma2SplitFallback(Buffer, 0, ReadCount, Props, Profile.FastBytes,
                Profile.CutValue, Profile.MatchFinderKind, EnableOptimumWindow, PropByte,
                SplitFallback, SplitFullOptimumDecisionCount) then
              begin
                WriteBytes(Destination, SplitFallback);
                Inc(OutTotal, UInt64(Length(SplitFallback)));
                NoteEncodedBlocksInBytes(SplitFallback, SplitFullOptimumDecisionCount);
                CanWriteNoPropsCompressed := False;
                LikelyIncompressible := False;
              end
              else
              begin
                WriteCopyChunk(ReadCount, True, False);
                LikelyIncompressible := True;
              end;
            end;
          end;
        end
        else
          WriteCopyChunk(ReadCount, FirstChunk, False);
        FirstChunk := False;
        ReportProgress(Progress, InTotal, OutTotal);
      end;
    until ReadCount = 0;
  end;

  EofByte := LZMA2_CONTROL_EOF;
  WriteExact(Destination, EofByte, 1);
  Inc(OutTotal);
  ReportProgress(Progress, InTotal, OutTotal);
end;

class function TLzma2Encoder.EncodeRawBytes(const Source: TBytes; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent): TBytes;
var
  InStream: TBytesStream;
  OutStream: TMemoryStream;
begin
  InStream := TBytesStream.Create(Source);
  OutStream := TMemoryStream.Create;
  try
    EncodeRaw(InStream, OutStream, Options, Progress);
    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    OutStream.Free;
    InStream.Free;
  end;
end;

end.
