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
{$IF Defined(MSWINDOWS)}
  Winapi.Windows,
{$ENDIF}
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

type
  TStandaloneHeaderStream = class(TStream)
  private
    FDestination: TStream;
    FHeader: array[0..LZMA_STANDALONE_HEADER_SIZE - 1] of Byte;
    FHeaderWritten: Boolean;
  public
    constructor Create(const Destination: TStream; const PropsBytes: TBytes;
      const UnpackedSize: UInt64);
    function Write(const Buffer; Count: TNativeCount): TNativeCount; override;
    property HeaderWritten: Boolean read FHeaderWritten;
  end;

constructor TStandaloneHeaderStream.Create(const Destination: TStream;
  const PropsBytes: TBytes; const UnpackedSize: UInt64);
begin
  inherited Create;
  FDestination := Destination;
  Move(PropsBytes[0], FHeader[0], LZMA_PROPS_SIZE);
  WriteUi64LE(@FHeader[LZMA_PROPS_SIZE], UnpackedSize);
end;

function TStandaloneHeaderStream.Write(const Buffer; Count: TNativeCount): TNativeCount;
begin
  if Count < 0 then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid standalone LZMA output size');
  if Count = 0 then
    Exit(0);
  if not FHeaderWritten then
  begin
    WriteExact(FDestination, FHeader[0], SizeOf(FHeader));
    FHeaderWritten := True;
  end;
  WriteExact(FDestination, Buffer, NativeUInt(Count));
  Result := Count;
end;

function HasIndependentStorage(const Source, Destination: TStream): Boolean;
var
  SourceMemory, DestinationMemory, SourceFile, DestinationFile: Boolean;
{$IF Defined(MSWINDOWS)}
  SourceInfo, DestinationInfo: TByHandleFileInformation;
{$ENDIF}
begin
  Result := False;
  if Source = Destination then
    Exit;

  // Subclasses can delegate to another stream or expose shared storage.
  SourceMemory := (Source.ClassType = TMemoryStream) or (Source.ClassType = TBytesStream);
  DestinationMemory := (Destination.ClassType = TMemoryStream) or
    (Destination.ClassType = TBytesStream);
  if SourceMemory and DestinationMemory then
    Exit(TCustomMemoryStream(Source).Memory <> TCustomMemoryStream(Destination).Memory);

  SourceFile := Source.ClassType = TFileStream;
  DestinationFile := Destination.ClassType = TFileStream;
  if (SourceMemory and DestinationFile) or (SourceFile and DestinationMemory) then
    Exit(True);

{$IF Defined(MSWINDOWS)}
  // File names can differ for the same backing file. Failed queries keep snapshots.
  if SourceFile and DestinationFile then
  begin
    SourceInfo := Default(TByHandleFileInformation);
    DestinationInfo := Default(TByHandleFileInformation);
    if GetFileInformationByHandle(TFileStream(Source).Handle, SourceInfo) and
       GetFileInformationByHandle(TFileStream(Destination).Handle, DestinationInfo) and
       (SourceInfo.dwVolumeSerialNumber <> 0) and (DestinationInfo.dwVolumeSerialNumber <> 0) and
       ((SourceInfo.nFileIndexHigh <> 0) or (SourceInfo.nFileIndexLow <> 0)) and
       ((DestinationInfo.nFileIndexHigh <> 0) or (DestinationInfo.nFileIndexLow <> 0)) then
      Result := (SourceInfo.dwVolumeSerialNumber <> DestinationInfo.dwVolumeSerialNumber) or
        (SourceInfo.nFileIndexHigh <> DestinationInfo.nFileIndexHigh) or
        (SourceInfo.nFileIndexLow <> DestinationInfo.nFileIndexLow);
  end;
{$ENDIF}
end;

function TryGetKnownRemaining(const Source: TStream; out Remaining: UInt64): Boolean;
var
  StreamSize, StreamPosition: Int64;
begin
  Result := False;
  Remaining := 0;
  // Generic TStream.Size may silently return zero on a nonseekable source.
  if not ((Source is TCustomMemoryStream) or (Source is TFileStream)) then
    Exit;
  try
    StreamPosition := Source.Position;
    if StreamPosition < 0 then
      Exit;
    StreamSize := Source.Size;
    if StreamSize < StreamPosition then
      Exit;
    Remaining := UInt64(StreamSize - StreamPosition);
    Result := True;
  except
    Result := False;
  end;
end;

function ReadStandaloneSnapshot(const Source: TStream; const BufferSize: NativeUInt;
  const MemoryLimit: UInt64; const Progress: TLzma2ProgressEvent;
  const ProbeKnownSize: Boolean; const CapacityHint: UInt64 = High(UInt64)): TBytes;
var
  Count, Capacity, NewCapacity, ReadQuantum: NativeUInt;
  ReadCount: Integer;
  Remaining: UInt64;
  Lookahead: Byte;
begin
  Count := 0;
  ReadQuantum := CheckedBufferSize(BufferSize);
  if ReadQuantum > NativeUInt(High(Integer)) then
    ReadQuantum := High(Integer);
  Capacity := ReadQuantum;
  Remaining := CapacityHint;
  if (Remaining = High(UInt64)) and ProbeKnownSize then
    if not TryGetKnownRemaining(Source, Remaining) then
      Remaining := High(UInt64);
  if Remaining < UInt64(Capacity) then
  begin
    Capacity := NativeUInt(Remaining);
    // Keep lookahead/growth valid even if a known-size source grows after EOF.
    if Capacity = 0 then
      Capacity := 1;
  end;
  ValidateMemoryLimit(Capacity, MemoryLimit);
  ReportProgress(Progress, 0, 0);
  SetLength(Result, NativeInt(Capacity));
  while True do
  begin
    while Count < Capacity do
    begin
      var ReadSize := Capacity - Count;
      if ReadSize > ReadQuantum then ReadSize := ReadQuantum;
      ReadCount := ReadAvailable(Source, Result[Count], ReadSize);
      if ReadCount = 0 then Break;
      Inc(Count, NativeUInt(ReadCount));
      ReportProgress(Progress, 0, 0);
    end;
    if Count < Capacity then Break;
    ReadCount := ReadAvailable(Source, Lookahead, SizeOf(Lookahead));
    if ReadCount = 0 then Break;
    if Capacity > NativeUInt(High(NativeInt)) div 2 then
      RaiseLzmaError(SZ_ERROR_MEM, 'Standalone LZMA input exceeds native TBytes capacity');
    NewCapacity := Capacity * 2;
    ValidateMemoryLimit(CheckedMemoryAdd(Capacity, NewCapacity), MemoryLimit);
    ReportProgress(Progress, 0, 0);
    SetLength(Result, NativeInt(NewCapacity));
    Capacity := NewCapacity;
    Result[Count] := Lookahead;
    Inc(Count);
  end;
  if Count <> Capacity then
  begin
    ValidateMemoryLimit(CheckedMemoryAdd(Capacity, Count), MemoryLimit);
    SetLength(Result, NativeInt(Count));
  end;
end;

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
  const BlockCount, ActualThreadCount: Integer; const FullOptimumDecisionCount, InputSize: UInt64);
begin
  if Options.EncodeDiagnostics = nil then
    Exit;
  Options.EncodeDiagnostics^.RequestedThreadCount := Options.ThreadCount;
  Options.EncodeDiagnostics^.ActualThreadCount := ActualThreadCount;
  Options.EncodeDiagnostics^.BatchCount := 1;
  Options.EncodeDiagnostics^.BlockCount := BlockCount;
  Options.EncodeDiagnostics^.FastBytes := Profile.FastBytes;
  Options.EncodeDiagnostics^.NiceLen := Profile.FastBytes;
  Options.EncodeDiagnostics^.CutValue := Profile.CutValue;
  Options.EncodeDiagnostics^.XzBlockSize := 0;
  Options.EncodeDiagnostics^.ParserMode := Profile.ParserMode;
  Options.EncodeDiagnostics^.MatchFinderProfile := Profile.MatchFinderProfile;
  Options.EncodeDiagnostics^.NumHashBytes := Profile.NumHashBytes;
  Options.EncodeDiagnostics^.OptimumParserEnabled := (InputSize <> 0) and
    (Profile.ParserMode = lpmSdkProfile) and (Profile.Algorithm <> 0);
  Options.EncodeDiagnostics^.FullOptimumDecisionCount := FullOptimumDecisionCount;
  Options.EncodeDiagnostics^.CopyFastPathCount := 0;
  Options.EncodeDiagnostics^.IncompressibleFastPathCount := 0;
  Options.EncodeDiagnostics^.FallbackReason := 'none';
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
  PropsBytes, Snapshot: TBytes;
  SnapshotSource: TBytesStream;
  InputSource: TStream;
  HeaderStream: TStandaloneHeaderStream;
  RawProgress: TLzma2ProgressEvent;
  FullOptimumDecisionCount, UnpackedSize, ActualInput, ActualOutput: UInt64;
  RetainedMemory, RawMemoryLimit: UInt64;
  KnownSize, WriteEndMarker: Boolean;
  ActualThreadCount: Integer;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  Normalized := TLzma2Encoder.NormalizeOptions(Options);
  Profile := TLzmaRawEncoder.NormalizeProfile(Normalized.Level, Normalized.DictionarySize);
  ApplyProfileOptionOverrides(Normalized, Profile);
  Props := TLzmaRawEncoder.DefaultProperties(Profile.DictionarySize);
  if not TryApplyLzmaOptionsToProps(Props, Normalized, False) then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Invalid LZMA lc/lp/pb options');
  // Validate every raw property before input is consumed or output is written.
  TLzmaRawEncoder.RequiredStreamingMemory(Profile, Props, 0, False);
  ReportProgress(Progress, 0, 0);
  WriteEndMarker := Normalized.LzmaEndMarker;
  KnownSize := False;
  if not WriteEndMarker then
    KnownSize := TryGetKnownRemaining(Source, UnpackedSize);
  if WriteEndMarker then
    UnpackedSize := LZMA_STANDALONE_UNKNOWN_SIZE;

  SnapshotSource := nil;
  HeaderStream := nil;
  InputSource := Source;
  RetainedMemory := UInt64(TStandaloneHeaderStream.InstanceSize);
  try
    if not WriteEndMarker and not KnownSize then
    begin
      Snapshot := ReadStandaloneSnapshot(Source, Normalized.BufferSize,
        Normalized.MemoryLimit, Progress, False);
      UnpackedSize := UInt64(Length(Snapshot));
      RetainedMemory := CheckedMemoryAdd(RetainedMemory,
        CheckedMemoryAdd(UInt64(Length(Snapshot)), UInt64(TBytesStream.InstanceSize)));
      ValidateMemoryLimit(RetainedMemory, Normalized.MemoryLimit);
      SnapshotSource := TBytesStream.Create(Snapshot);
      InputSource := SnapshotSource;
    end;
    ValidateMemoryLimit(CheckedMemoryAdd(RetainedMemory, LZMA_PROPS_SIZE), Normalized.MemoryLimit);
    PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
    HeaderStream := TStandaloneHeaderStream.Create(Destination, PropsBytes, UnpackedSize);
    PropsBytes := nil;
    RawMemoryLimit := 0;
    if Normalized.MemoryLimit <> 0 then
    begin
      ValidateMemoryLimit(CheckedMemoryAdd(RetainedMemory, 1), Normalized.MemoryLimit);
      RawMemoryLimit := Normalized.MemoryLimit - RetainedMemory;
    end;
    ActualInput := 0;
    ActualOutput := 0;
    RawProgress := procedure(const InputBytes, OutputBytes: UInt64; var Cancel: Boolean)
      begin
        ActualInput := InputBytes;
        ActualOutput := OutputBytes;
        if HeaderStream.HeaderWritten then
          ActualOutput := CheckedMemoryAdd(ActualOutput, LZMA_STANDALONE_HEADER_SIZE);
        if Assigned(Progress) then
          Progress(ActualInput, ActualOutput, Cancel);
      end;
    TLzmaRawEncoder.EncodeWithThreads(InputSource, HeaderStream, Profile, Props, WriteEndMarker,
      Normalized.BufferSize, RawMemoryLimit, Normalized.ThreadCount, FullOptimumDecisionCount,
      ActualThreadCount, RawProgress);
    if not WriteEndMarker and (ActualInput <> UnpackedSize) then
      RaiseLzmaError(SZ_ERROR_READ, 'Standalone LZMA input size changed during encoding');
    ResetEncodeDiagnostics(Normalized, Profile, 1, ActualThreadCount, FullOptimumDecisionCount, ActualInput);
    ReportProgress(Progress, ActualInput, ActualOutput);
  finally
    HeaderStream.Free;
    SnapshotSource.Free;
  end;
end;

class procedure TLzmaStandalone.Decode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  Header: TBytes;
  PropsBytes: TBytes;
  Props: TLzmaProps;
  InputCapacity: NativeUInt;
  SnapshotInput: Boolean;
  PackedData: TBytes;
  UnpackedSize: UInt64;
  State: TLzmaDecoderState;
  Consumed: UInt64;
  Produced: UInt64;
  HeaderMemory, DecoderMemory, DictionaryCapacity, KnownPackedSize, PayloadLimit: UInt64;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  ValidateMemoryLimit(LZMA_STANDALONE_HEADER_SIZE, Options.MemoryLimit);
  SetLength(Header, LZMA_STANDALONE_HEADER_SIZE);
  ReadExact(Source, Header[0], Length(Header));
  HeaderMemory := CheckedMemoryAdd(UInt64(Length(Header)), LZMA_PROPS_SIZE);
  ValidateMemoryLimit(HeaderMemory, Options.MemoryLimit);
  PropsBytes := Copy(Header, 0, LZMA_PROPS_SIZE);
  if not LzmaPropsDecode(PropsBytes, Props) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Invalid standalone LZMA properties');

  DecoderMemory := TLzmaDecoderState.RequiredMemory(Props.DictionarySize, Props.Lc, Props.Lp);
  ValidateMemoryLimit(CheckedMemoryAdd(HeaderMemory, DecoderMemory), Options.MemoryLimit);
  UnpackedSize := ReadUi64LE(@Header[LZMA_PROPS_SIZE]);
  InputCapacity := 0;
  KnownPackedSize := High(UInt64);
  // Unknown streams retain pre-read behavior because their backing can be shared.
  SnapshotInput := not HasIndependentStorage(Source, Destination);
  if not SnapshotInput then
  begin
    PayloadLimit := OneShotPayloadLimit(CheckedMemoryAdd(HeaderMemory, DecoderMemory),
      Options.MemoryLimit);
    SnapshotInput := PayloadLimit < UInt64(
      TLzmaDecoderState.StreamingInputCapacity(Options.BufferSize, 0));
    if not SnapshotInput then
    begin
      InputCapacity := TLzmaDecoderState.StreamingInputCapacity(Options.BufferSize);
      // Preserve tiny reliable-input budgets when the symbol reserve sets capacity.
      if ((UnpackedSize = LZMA_STANDALONE_UNKNOWN_SIZE) or
          (UnpackedSize < UInt64(CheckedBufferSize(Options.BufferSize)))) and
         TryGetKnownRemaining(Source, KnownPackedSize) then
      begin
        InputCapacity := TLzmaDecoderState.StreamingInputCapacity(Options.BufferSize, KnownPackedSize);
        SnapshotInput := KnownPackedSize < UInt64(InputCapacity);
      end;
      if UInt64(InputCapacity) > PayloadLimit then
        InputCapacity := NativeUInt(PayloadLimit);
    end;
  end;
  if SnapshotInput then
  begin
    PayloadLimit := OneShotPayloadLimit(HeaderMemory, Options.MemoryLimit);
    PackedData := ReadStandaloneSnapshot(Source, Options.BufferSize, PayloadLimit, nil,
      (UnpackedSize = LZMA_STANDALONE_UNKNOWN_SIZE) or
      (UnpackedSize < UInt64(CheckedBufferSize(Options.BufferSize))), KnownPackedSize);
    ValidateMemoryLimit(CheckedMemoryAdd(HeaderMemory,
      CheckedMemoryAdd(UInt64(Length(PackedData)), DecoderMemory)), Options.MemoryLimit);
  end
  else
    ValidateMemoryLimit(CheckedMemoryAdd(HeaderMemory,
      CheckedMemoryAdd(UInt64(InputCapacity), DecoderMemory)), Options.MemoryLimit);
  DictionaryCapacity := Props.DictionarySize;
  if UnpackedSize < DictionaryCapacity then
    DictionaryCapacity := UnpackedSize;
  State := TLzmaDecoderState.Create(DictionaryCapacity);
  try
    State.SetProperties(Props);
    State.ResetDictionary;
    State.ResetState;
    if UnpackedSize = LZMA_STANDALONE_UNKNOWN_SIZE then
    begin
      if SnapshotInput then
      begin
        Consumed := State.DecodeUntilEndMarker(PackedData, 0, Length(PackedData), Destination,
          Progress, LZMA_STANDALONE_HEADER_SIZE, 0);
        if not HasOnlyZeroTail(PackedData, NativeUInt(Consumed)) then
          RaiseLzmaError(SZ_ERROR_DATA, 'Standalone LZMA stream has trailing bytes after the end marker');
        Consumed := UInt64(Length(PackedData));
      end
      else
        Consumed := State.DecodeUntilEndMarkerStream(Source, InputCapacity, Destination,
          Progress, LZMA_STANDALONE_HEADER_SIZE, 0);
      Produced := State.ProcessedSize;
    end
    else
    begin
      if SnapshotInput then
      begin
        State.DecodeKnownSize(PackedData, 0, Length(PackedData), UnpackedSize, Destination,
          Progress, LZMA_STANDALONE_HEADER_SIZE, 0);
        Consumed := UInt64(Length(PackedData));
      end
      else
        Consumed := State.DecodeKnownSizeStream(Source, InputCapacity, UnpackedSize, Destination,
          Progress, LZMA_STANDALONE_HEADER_SIZE, 0);
      Produced := UnpackedSize;
    end;
    ReportProgress(Progress, CheckedMemoryAdd(LZMA_STANDALONE_HEADER_SIZE, Consumed), Produced);
  finally
    State.Free;
  end;

  SetLzma2DecodeDiagnostics(Options, 1, 1, False, ldfrThreadCountOne);
end;

end.
