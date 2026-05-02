unit Lzma.Lzma;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.Types;

type
  TLzmaStandalone = class
  public
    class procedure Encode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure Decode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
  end;

implementation

uses
  Lzma.Alloc,
  Lzma.Decoder,
  Lzma.Encoder,
  Lzma.Errors,
  Lzma.MatchFinder,
  Lzma.Streams,
  Lzma2.Encoder;

const
  LZMA_STANDALONE_HEADER_SIZE = LZMA_PROPS_SIZE + 8;
  LZMA_STANDALONE_UNKNOWN_SIZE = UInt64($FFFFFFFFFFFFFFFF);

procedure ApplyProfileOptionOverrides(const Options: TLzma2Options; var Profile: TLzmaEncoderProfile);
begin
  case Options.MatchFinderProfile of
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
  if Options.FastBytes <> 0 then
    Profile.FastBytes := Options.FastBytes;
  if Options.CutValue <> 0 then
    Profile.CutValue := Options.CutValue;
  Profile.ParserMode := Options.ParserMode;
end;

procedure ResetEncodeDiagnostics(const Options: TLzma2Options; const Profile: TLzmaEncoderProfile;
  const BlockCount: Integer; const FullOptimumDecisionCount: UInt64);
begin
  if Options.EncodeDiagnostics = nil then
    Exit;
  Options.EncodeDiagnostics^.RequestedThreadCount := Options.ThreadCount;
  Options.EncodeDiagnostics^.ActualThreadCount := 1;
  Options.EncodeDiagnostics^.BatchCount := 1;
  Options.EncodeDiagnostics^.BlockCount := BlockCount;
  Options.EncodeDiagnostics^.FastBytes := Profile.FastBytes;
  Options.EncodeDiagnostics^.NiceLen := Profile.FastBytes;
  Options.EncodeDiagnostics^.CutValue := Profile.CutValue;
  Options.EncodeDiagnostics^.XzBlockSize := 0;
  Options.EncodeDiagnostics^.ParserMode := Profile.ParserMode;
  Options.EncodeDiagnostics^.MatchFinderProfile := Profile.MatchFinderProfile;
  Options.EncodeDiagnostics^.NumHashBytes := Profile.NumHashBytes;
  Options.EncodeDiagnostics^.OptimumParserEnabled := FullOptimumDecisionCount > 0;
  Options.EncodeDiagnostics^.FullOptimumDecisionCount := FullOptimumDecisionCount;
  Options.EncodeDiagnostics^.CopyFastPathCount := 0;
  Options.EncodeDiagnostics^.IncompressibleFastPathCount := 0;
  Options.EncodeDiagnostics^.FallbackReason := 'none';
end;

function TryGetStreamPosition(const Stream: TStream; out Position: UInt64): Boolean;
var
  Value: Int64;
begin
  Result := False;
  Position := 0;
  try
    Value := Stream.Position;
    if Value < 0 then
      Exit;
    Position := UInt64(Value);
    Result := True;
  except
    Result := False;
  end;
end;

function HasOnlyZeroTail(const Data: TBytes; const Offset: NativeUInt): Boolean;
var
  I: NativeUInt;
begin
  if Offset > NativeUInt(Length(Data)) then
    Exit(False);
  if Offset = NativeUInt(Length(Data)) then
    Exit(True);
  for I := Offset to NativeUInt(Length(Data)) - 1 do
    if Data[I] <> 0 then
      Exit(False);
  Result := True;
end;

function OneShotPayloadLimit(const RequiredBytes, MemoryLimit: UInt64): UInt64;
begin
  Result := UInt64(High(NativeInt));
  if MemoryLimit = 0 then
    Exit;
  ValidateMemoryLimit(RequiredBytes, MemoryLimit);
  if MemoryLimit <= RequiredBytes then
    Exit(0);
  Result := MemoryLimit - RequiredBytes;
  if Result > UInt64(High(NativeInt)) then
    Result := UInt64(High(NativeInt));
end;

class procedure TLzmaStandalone.Encode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  Normalized: TLzma2Options;
  Profile: TLzmaEncoderProfile;
  Props: TLzmaProps;
  PropsBytes: TBytes;
  Data: TBytes;
  Encoded: TBytes;
  Header: TBytes;
  EnableOptimumWindow: Boolean;
  FullOptimumDecisionCount: UInt64;
  PayloadLimit: UInt64;
  WriteEndMarker: Boolean;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  Normalized := TLzma2Encoder.NormalizeOptions(Options);
  Profile := TLzmaRawEncoder.NormalizeProfile(Normalized.Level, Normalized.DictionarySize);
  ApplyProfileOptionOverrides(Normalized, Profile);

  PayloadLimit := OneShotPayloadLimit(Profile.DictionarySize, Normalized.MemoryLimit);
  Data := ReadAllBytesBounded(Source, PayloadLimit, 'Standalone LZMA input exceeds memory limit');
  Props := TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize);
  if not TryApplyLzmaOptionsToProps(Props, Normalized, False) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA lc/lp/pb options');
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
  EnableOptimumWindow := Profile.ParserMode = lpmSdkProfile;
  WriteEndMarker := Normalized.LzmaEndMarker;
  FullOptimumDecisionCount := 0;
  Encoded := TLzmaRawEncoder.EncodeGreedyChunk(Data, 0, Length(Data), Props, Profile.FastBytes,
    Profile.CutValue, Profile.MatchFinderKind, WriteEndMarker, EnableOptimumWindow, Progress,
    @FullOptimumDecisionCount);

  SetLength(Header, LZMA_STANDALONE_HEADER_SIZE);
  Move(PropsBytes[0], Header[0], LZMA_PROPS_SIZE);
  if WriteEndMarker then
    WriteUi64LE(@Header[LZMA_PROPS_SIZE], LZMA_STANDALONE_UNKNOWN_SIZE)
  else
    WriteUi64LE(@Header[LZMA_PROPS_SIZE], UInt64(Length(Data)));
  WriteBytes(Destination, Header);
  WriteBytes(Destination, Encoded);

  ResetEncodeDiagnostics(Normalized, Profile, 1, FullOptimumDecisionCount);
  ReportProgress(Progress, UInt64(Length(Data)),
    UInt64(LZMA_STANDALONE_HEADER_SIZE) + UInt64(Length(Encoded)));
end;

class procedure TLzmaStandalone.Decode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  Header: TBytes;
  PropsBytes: TBytes;
  Props: TLzmaProps;
  PackedData: TBytes;
  UnpackedSize: UInt64;
  State: TLzmaDecoderState;
  Consumed: NativeUInt;
  OutStart: UInt64;
  OutEnd: UInt64;
  Produced: UInt64;
  PayloadLimit: UInt64;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  SetLength(Header, LZMA_STANDALONE_HEADER_SIZE);
  ReadExact(Source, Header[0], Length(Header));
  PropsBytes := Copy(Header, 0, LZMA_PROPS_SIZE);
  if not LzmaPropsDecode(PropsBytes, Props) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Invalid standalone LZMA properties');

  PayloadLimit := OneShotPayloadLimit(Props.DictionarySize, Options.MemoryLimit);
  PackedData := ReadAllBytesBounded(Source, PayloadLimit, 'Standalone LZMA packed input exceeds memory limit');
  UnpackedSize := ReadUi64LE(@Header[LZMA_PROPS_SIZE]);

  State := TLzmaDecoderState.Create(Props.DictionarySize);
  try
    State.SetProperties(Props);
    State.ResetDictionary;
    State.ResetState;
    Produced := 0;
    if UnpackedSize = LZMA_STANDALONE_UNKNOWN_SIZE then
    begin
      if not TryGetStreamPosition(Destination, OutStart) then
        OutStart := 0;
      Consumed := State.DecodeUntilEndMarker(PackedData, 0, Length(PackedData), Destination,
        Progress, LZMA_STANDALONE_HEADER_SIZE, 0);
      if not HasOnlyZeroTail(PackedData, Consumed) then
        RaiseLzmaError(SZ_ERROR_DATA, 'Standalone LZMA stream has trailing bytes after the end marker');
      if TryGetStreamPosition(Destination, OutEnd) and (OutEnd >= OutStart) then
        Produced := OutEnd - OutStart;
    end
    else
    begin
      State.DecodeChunk(PackedData, 0, Length(PackedData), UnpackedSize, Destination,
        Progress, LZMA_STANDALONE_HEADER_SIZE, 0);
      Produced := UnpackedSize;
    end;
    ReportProgress(Progress, UInt64(LZMA_STANDALONE_HEADER_SIZE) + UInt64(Length(PackedData)), Produced);
  finally
    State.Free;
  end;

  SetLzma2DecodeDiagnostics(Options, 1, 1, False, ldfrThreadCountOne);
end;

end.
