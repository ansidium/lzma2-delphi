unit Lzma2.Decoder;

interface

uses
  System.Classes,
  System.SyncObjs,
  System.SysUtils,
  Lzma.Types;

type
  TLzma2Decoder = class
  public
    class procedure DecodeRaw(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure DecodeRawEmbedded(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      out ConsumedBytes: UInt64; out ProducedBytes: UInt64;
      const Progress: TLzma2ProgressEvent = nil); static;
    class function DecodeRawBytes(const Source: TBytes; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil): TBytes; static;
  end;

implementation

uses
  Lzma.Alloc,
  Lzma.Decoder,
  Lzma.Errors,
  Lzma.MtDec,
  Lzma.Streams;

const
  LZMA2_MT_DECODE_TARGET_UNIT_SIZE = UInt64(8) shl 20;

function EffectiveThreadCount(const Options: TLzma2Options): Integer;
begin
  Result := Options.ThreadCount;
  if Result < 1 then
    Result := 1;
end;

function TryGetStreamPosition(const Source: TStream; out Position: Int64): Boolean;
begin
  Result := True;
  try
    Position := Source.Position;
  except
    Position := 0;
    Result := False;
  end;
end;

function TryGetStreamRemaining(const Source: TStream; out Remaining: UInt64): Boolean;
var
  Position: Int64;
  Size: Int64;
begin
  Result := True;
  try
    Position := Source.Position;
    Size := Source.Size;
    if Size < Position then
      Remaining := 0
    else
      Remaining := UInt64(Size - Position);
  except
    Remaining := 0;
    Result := False;
  end;
end;

procedure RestoreStreamPosition(const Source: TStream; const Position: Int64);
begin
  try
    Source.Position := Position;
  except
    on E: Exception do
      RaiseLzmaError(SZ_ERROR_READ, 'Unable to restore input stream position: ' + E.Message);
  end;
end;

function RawControlResetsDictionary(const Control: Byte): Boolean;
begin
  Result := (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control >= $E0);
end;

procedure AddRawUnit(var Units: TArray<TBytes>; var OutputSizes: TArray<UInt64>;
  var InputSizes: TArray<UInt64>; const Data: TBytes; const Offset, Count: NativeUInt; const OutputSize: UInt64;
  const AppendEof: Boolean);
var
  UnitBytes: TBytes;
  UnitSize: NativeUInt;
  OldLen: Integer;
begin
  if Count = 0 then
    Exit;
  UnitSize := Count;
  if AppendEof then
    Inc(UnitSize);
  if UnitSize > NativeUInt(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode unit is too large for this process');

  SetLength(UnitBytes, Integer(UnitSize));
  Move(Data[Offset], UnitBytes[0], Count);
  if AppendEof then
    UnitBytes[High(UnitBytes)] := LZMA2_CONTROL_EOF;

  OldLen := Length(Units);
  SetLength(Units, OldLen + 1);
  SetLength(OutputSizes, OldLen + 1);
  SetLength(InputSizes, OldLen + 1);
  Units[OldLen] := UnitBytes;
  OutputSizes[OldLen] := OutputSize;
  InputSizes[OldLen] := Count;
end;

procedure AppendRawByte(var Data: TBytes; const Value: Byte);
var
  OldLen: Integer;
begin
  OldLen := Length(Data);
  SetLength(Data, OldLen + 1);
  Data[OldLen] := Value;
end;

procedure AppendRawBytes(var Data: TBytes; const Source: TBytes; const Count: NativeUInt);
var
  OldLen: Integer;
begin
  if Count = 0 then
    Exit;
  if Count > NativeUInt(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode unit is too large for this process');
  OldLen := Length(Data);
  if Count > NativeUInt(High(Integer) - OldLen) then
    RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode unit is too large for this process');
  SetLength(Data, OldLen + Integer(Count));
  Move(Source[0], Data[OldLen], Count);
end;

procedure AddRawUnitBytes(var Units: TArray<TBytes>; var OutputSizes: TArray<UInt64>;
  var InputSizes: TArray<UInt64>; var UnitBytes: TBytes; const OutputSize, InputSize: UInt64;
  const AppendEof: Boolean);
var
  OldLen: Integer;
begin
  if Length(UnitBytes) = 0 then
    Exit;
  if AppendEof then
    AppendRawByte(UnitBytes, LZMA2_CONTROL_EOF);

  OldLen := Length(Units);
  SetLength(Units, OldLen + 1);
  SetLength(OutputSizes, OldLen + 1);
  SetLength(InputSizes, OldLen + 1);
  Units[OldLen] := UnitBytes;
  OutputSizes[OldLen] := OutputSize;
  InputSizes[OldLen] := InputSize;
  SetLength(UnitBytes, 0);
end;

procedure AddRawOutputSize(var Total: UInt64; const Delta: UInt64);
begin
  if Delta > High(UInt64) - Total then
    RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode output size overflow');
  Inc(Total, Delta);
end;

procedure SplitRawLzma2IndependentUnits(const Data: TBytes; out Units: TArray<TBytes>;
  out OutputSizes: TArray<UInt64>; out InputSizes: TArray<UInt64>);
var
  Pos: NativeUInt;
  ControlPos: NativeUInt;
  SegmentStart: NativeUInt;
  SegmentOutputSize: UInt64;
  Control: Byte;
  ChunkSize: NativeUInt;
  PackSize: NativeUInt;
  UnpackSize: UInt64;
begin
  SetLength(Units, 0);
  SetLength(OutputSizes, 0);
  SetLength(InputSizes, 0);
  Pos := 0;
  SegmentStart := 0;
  SegmentOutputSize := 0;

  while Pos < NativeUInt(Length(Data)) do
  begin
    ControlPos := Pos;
    Control := Data[Pos];
    Inc(Pos);

    if Control = LZMA2_CONTROL_EOF then
    begin
      AddRawUnit(Units, OutputSizes, InputSizes, Data, SegmentStart, Pos - SegmentStart, SegmentOutputSize, False);
      if Pos <> NativeUInt(Length(Data)) then
        RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes after LZMA2 end marker');
      Exit;
    end;

    if RawControlResetsDictionary(Control) and (ControlPos > SegmentStart) then
    begin
      AddRawUnit(Units, OutputSizes, InputSizes, Data, SegmentStart, ControlPos - SegmentStart,
        SegmentOutputSize, True);
      SegmentStart := ControlPos;
      SegmentOutputSize := 0;
    end;

    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      if Pos + 2 > NativeUInt(Length(Data)) then
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'LZMA2 copy chunk header is truncated');
      ChunkSize := (NativeUInt(Data[Pos]) shl 8) or NativeUInt(Data[Pos + 1]);
      Inc(ChunkSize);
      Inc(Pos, 2);
      if Pos + ChunkSize > NativeUInt(Length(Data)) then
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'LZMA2 copy chunk payload is truncated');
      Inc(Pos, ChunkSize);
      AddRawOutputSize(SegmentOutputSize, ChunkSize);
      Continue;
    end;

    if Control < $80 then
      RaiseLzmaError(SZ_ERROR_DATA, 'Invalid LZMA2 control byte');

    if Pos + 4 > NativeUInt(Length(Data)) then
      RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'LZMA2 compressed chunk header is truncated');
    UnpackSize := (UInt64(Control and $1F) shl 16) or (UInt64(Data[Pos]) shl 8) or UInt64(Data[Pos + 1]);
    Inc(UnpackSize);
    PackSize := (NativeUInt(Data[Pos + 2]) shl 8) or NativeUInt(Data[Pos + 3]);
    Inc(PackSize);
    Inc(Pos, 4);
    if (Control and $40) <> 0 then
    begin
      if Pos >= NativeUInt(Length(Data)) then
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'LZMA2 compressed chunk properties are truncated');
      Inc(Pos);
    end;
    if Pos + PackSize > NativeUInt(Length(Data)) then
      RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'LZMA2 compressed chunk payload is truncated');
    Inc(Pos, PackSize);
    AddRawOutputSize(SegmentOutputSize, UnpackSize);
  end;

  RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'LZMA2 stream is missing end marker');
end;

procedure SplitRawLzma2IndependentUnitsFromStream(const Source: TStream; const CapturePayloads: Boolean;
  out Units: TArray<TBytes>; out OutputSizes: TArray<UInt64>; out InputSizes: TArray<UInt64>;
  out PackedInputSize: UInt64);
var
  CurrentUnit: TBytes;
  SegmentOutputSize: UInt64;
  SegmentInputSize: UInt64;
  Control: Byte;
  SizeHi: Byte;
  SizeLo: Byte;
  PackHi: Byte;
  PackLo: Byte;
  Prop: Byte;
  ChunkSize: NativeUInt;
  PackSize: NativeUInt;
  UnpackSize: UInt64;
  Payload: TBytes;
  Tail: Byte;

  procedure AddCurrentUnit(const AppendEof: Boolean);
  var
    OldLen: Integer;
  begin
    if CapturePayloads then
    begin
      AddRawUnitBytes(Units, OutputSizes, InputSizes, CurrentUnit, SegmentOutputSize,
        SegmentInputSize, AppendEof);
      Exit;
    end;

    if SegmentInputSize = 0 then
      Exit;
    OldLen := Length(Units);
    SetLength(Units, OldLen + 1);
    SetLength(OutputSizes, OldLen + 1);
    SetLength(InputSizes, OldLen + 1);
    Units[OldLen] := nil;
    OutputSizes[OldLen] := SegmentOutputSize;
    InputSizes[OldLen] := SegmentInputSize;
  end;

  procedure NoteInput(const Count: UInt64);
  begin
    if Count > High(UInt64) - PackedInputSize then
      RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode input size overflow');
    Inc(PackedInputSize, Count);
    if Count > High(UInt64) - SegmentInputSize then
      RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode unit size overflow');
    Inc(SegmentInputSize, Count);
  end;

  procedure AppendInputByte(const Value: Byte);
  begin
    if CapturePayloads then
      AppendRawByte(CurrentUnit, Value);
    NoteInput(1);
  end;

  procedure AppendInputPayload(const Count: NativeUInt);
  var
    SkippedTo: Int64;
  begin
    if Count = 0 then
      Exit;
    if Count > NativeUInt(High(Integer)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode payload is too large for this process');
    if CapturePayloads then
    begin
      SetLength(Payload, Integer(Count));
      ReadExact(Source, Payload[0], Count);
      AppendRawBytes(CurrentUnit, Payload, Count);
    end
    else
    begin
      SkippedTo := -1;
      try
        SkippedTo := Source.Seek(Int64(Count), soCurrent);
      except
        on E: Exception do
          RaiseLzmaError(SZ_ERROR_READ, 'Unable to skip raw LZMA2 MT decode payload: ' + E.Message);
      end;
      if SkippedTo < 0 then
        RaiseLzmaError(SZ_ERROR_READ, 'Unable to skip raw LZMA2 MT decode payload');
    end;
    NoteInput(Count);
  end;

begin
  SetLength(Units, 0);
  SetLength(OutputSizes, 0);
  SetLength(InputSizes, 0);
  SetLength(CurrentUnit, 0);
  SegmentOutputSize := 0;
  SegmentInputSize := 0;
  PackedInputSize := 0;

  while True do
  begin
    Control := ReadByteRequired(Source);
    if RawControlResetsDictionary(Control) and
      ((CapturePayloads and (Length(CurrentUnit) <> 0)) or
      ((not CapturePayloads) and (SegmentInputSize <> 0))) then
    begin
      AddCurrentUnit(True);
      SegmentOutputSize := 0;
      SegmentInputSize := 0;
    end;
    AppendInputByte(Control);

    if Control = LZMA2_CONTROL_EOF then
    begin
      AddCurrentUnit(False);
      if ReadAvailable(Source, Tail, 1) <> 0 then
        RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes after LZMA2 end marker');
      Exit;
    end;

    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      SizeHi := ReadByteRequired(Source);
      SizeLo := ReadByteRequired(Source);
      AppendInputByte(SizeHi);
      AppendInputByte(SizeLo);
      ChunkSize := (NativeUInt(SizeHi) shl 8) or NativeUInt(SizeLo);
      Inc(ChunkSize);
      AppendInputPayload(ChunkSize);
      AddRawOutputSize(SegmentOutputSize, ChunkSize);
      Continue;
    end;

    if Control < $80 then
      RaiseLzmaError(SZ_ERROR_DATA, 'Invalid LZMA2 control byte');

    SizeHi := ReadByteRequired(Source);
    SizeLo := ReadByteRequired(Source);
    PackHi := ReadByteRequired(Source);
    PackLo := ReadByteRequired(Source);
    AppendInputByte(SizeHi);
    AppendInputByte(SizeLo);
    AppendInputByte(PackHi);
    AppendInputByte(PackLo);
    UnpackSize := (UInt64(Control and $1F) shl 16) or (UInt64(SizeHi) shl 8) or UInt64(SizeLo);
    Inc(UnpackSize);
    PackSize := (NativeUInt(PackHi) shl 8) or NativeUInt(PackLo);
    Inc(PackSize);
    if (Control and $40) <> 0 then
    begin
      Prop := ReadByteRequired(Source);
      AppendInputByte(Prop);
    end;
    AppendInputPayload(PackSize);
    AddRawOutputSize(SegmentOutputSize, UnpackSize);
  end;
end;

procedure CoalesceRawLzma2MtUnits(var Units: TArray<TBytes>; var OutputSizes: TArray<UInt64>;
  var InputSizes: TArray<UInt64>; const TargetOutputSize: UInt64);
var
  NewUnits: TArray<TBytes>;
  NewOutputSizes: TArray<UInt64>;
  NewInputSizes: TArray<UInt64>;
  UnitIndex: Integer;
  GroupStart: Integer;
  GroupEnd: Integer;
  OldLen: Integer;
  CombinedSize: NativeUInt;
  DestOffset: NativeUInt;
  CopySize: NativeUInt;
  I: Integer;

  function GroupOutputSize(const FirstIndex, LastIndex: Integer): UInt64;
  var
    J: Integer;
  begin
    Result := 0;
    for J := FirstIndex to LastIndex do
    begin
      if OutputSizes[J] > High(UInt64) - Result then
        RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT coalesced output size overflow');
      Inc(Result, OutputSizes[J]);
    end;
  end;

  function GroupInputSize(const FirstIndex, LastIndex: Integer): UInt64;
  var
    J: Integer;
  begin
    Result := 0;
    for J := FirstIndex to LastIndex do
    begin
      if InputSizes[J] > High(UInt64) - Result then
        RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT coalesced input size overflow');
      Inc(Result, InputSizes[J]);
    end;
  end;

  procedure AppendGroup(const FirstIndex, LastIndex: Integer);
  var
    J: Integer;
    GroupBytes: TBytes;
  begin
    if FirstIndex = LastIndex then
    begin
      OldLen := Length(NewUnits);
      SetLength(NewUnits, OldLen + 1);
      SetLength(NewOutputSizes, OldLen + 1);
      SetLength(NewInputSizes, OldLen + 1);
      NewUnits[OldLen] := Units[FirstIndex];
      NewOutputSizes[OldLen] := OutputSizes[FirstIndex];
      NewInputSizes[OldLen] := InputSizes[FirstIndex];
      Exit;
    end;

    CombinedSize := 0;
    for J := FirstIndex to LastIndex do
    begin
      if (Length(Units[J]) = 0) or (Units[J][High(Units[J])] <> LZMA2_CONTROL_EOF) then
        RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA2 MT unit is missing end marker');
      CopySize := NativeUInt(Length(Units[J]));
      if J <> LastIndex then
        Dec(CopySize);
      if CopySize > NativeUInt(High(Integer)) - CombinedSize then
        RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT coalesced unit is too large for this process');
      Inc(CombinedSize, CopySize);
    end;

    SetLength(GroupBytes, Integer(CombinedSize));
    DestOffset := 0;
    for J := FirstIndex to LastIndex do
    begin
      CopySize := NativeUInt(Length(Units[J]));
      if J <> LastIndex then
        Dec(CopySize);
      if CopySize <> 0 then
      begin
        Move(Units[J][0], GroupBytes[DestOffset], CopySize);
        Inc(DestOffset, CopySize);
      end;
    end;

    OldLen := Length(NewUnits);
    SetLength(NewUnits, OldLen + 1);
    SetLength(NewOutputSizes, OldLen + 1);
    SetLength(NewInputSizes, OldLen + 1);
    NewUnits[OldLen] := GroupBytes;
    NewOutputSizes[OldLen] := GroupOutputSize(FirstIndex, LastIndex);
    NewInputSizes[OldLen] := GroupInputSize(FirstIndex, LastIndex);
  end;

begin
  if (TargetOutputSize = 0) or (Length(Units) <= 1) then
    Exit;

  SetLength(NewUnits, 0);
  SetLength(NewOutputSizes, 0);
  SetLength(NewInputSizes, 0);
  UnitIndex := 0;
  while UnitIndex <= High(Units) do
  begin
    GroupStart := UnitIndex;
    GroupEnd := UnitIndex;
    while (GroupEnd < High(Units)) and (GroupOutputSize(GroupStart, GroupEnd) < TargetOutputSize) do
      Inc(GroupEnd);
    AppendGroup(GroupStart, GroupEnd);
    UnitIndex := GroupEnd + 1;
  end;

  if Length(NewUnits) < Length(Units) then
  begin
    for I := 0 to High(Units) do
      SetLength(Units[I], 0);
    Units := NewUnits;
    OutputSizes := NewOutputSizes;
    InputSizes := NewInputSizes;
  end;
end;

function TryAddMemoryUse(var Total: UInt64; const Value: UInt64; const Limit: UInt64): Boolean;
begin
  if Limit = 0 then
  begin
    if Value > High(UInt64) - Total then
      Exit(False);
    Inc(Total, Value);
    Exit(True);
  end;
  if (Total > Limit) or (Value > Limit - Total) then
    Exit(False);
  Inc(Total, Value);
  Result := True;
end;

function FitsMtDecodeMemoryLimit(const InputSize, OutputSize, PerWorkerSize: UInt64;
  const WorkerCount: Integer; const MemoryLimit: UInt64): Boolean;
var
  Total: UInt64;
  WorkerMemory: UInt64;
begin
  if OutputSize > UInt64(High(Integer)) then
    Exit(False);
  if MemoryLimit = 0 then
    Exit(True);
  if (WorkerCount > 0) and (PerWorkerSize > High(UInt64) div UInt64(WorkerCount)) then
    Exit(False);
  WorkerMemory := UInt64(WorkerCount) * PerWorkerSize;
  Total := 0;
  Result :=
    TryAddMemoryUse(Total, InputSize, MemoryLimit) and
    TryAddMemoryUse(Total, OutputSize, MemoryLimit) and
    TryAddMemoryUse(Total, WorkerMemory, MemoryLimit);
end;

function HasSufficientRawMtDecodeWork(const PackedInputSize, OutputSize: UInt64;
  const WorkerCount: Integer): Boolean;
const
  kMinPackedBytesPerWorker = UInt64(2048);
  kHighExpansionOutputPerWorker = UInt64(16) shl 20;
  kHighExpansionPackedBytesPerWorker = UInt64(64) shl 10;
  kHighExpansionRatio = UInt64(256);
begin
  if WorkerCount <= 1 then
    Exit(True);
  if PackedInputSize < UInt64(WorkerCount) * kMinPackedBytesPerWorker then
    Exit(False);
  if (PackedInputSize < UInt64(WorkerCount) * kHighExpansionPackedBytesPerWorker) and
    (OutputSize >= UInt64(WorkerCount) * kHighExpansionOutputPerWorker) and
    (PackedInputSize <> 0) and (OutputSize div PackedInputSize >= kHighExpansionRatio) then
    Exit(False);
  Result := True;
end;

procedure DecodeRawInternal(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent; const RejectTrailingBytes: Boolean;
  out ConsumedBytes: UInt64; out ProducedBytes: UInt64);
var
  Buffer: TBytes;
  PackData: TBytes;
  Control: Byte;
  SizeHi: Byte;
  SizeLo: Byte;
  PackHi: Byte;
  PackLo: Byte;
  Prop: Byte;
  ChunkSize: NativeUInt;
  PackSize: NativeUInt;
  UnpackSize: UInt32;
  InTotal: UInt64;
  OutTotal: UInt64;
  DictSize: UInt64;
  NeedInitLevel: Byte;
  Decoder: TLzmaDecoderState;

  procedure EnsureDecoder;
  begin
    if Decoder <> nil then
      Exit;
    Decoder := TLzmaDecoderState.Create(DictSize);
  end;

begin
  ConsumedBytes := 0;
  ProducedBytes := 0;
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  DictSize := Options.DictionarySize;
  if DictSize = 0 then
    DictSize := DefaultDictionaryForLevel(Options.Level);
  ValidateMemoryLimit(DictSize, Options.MemoryLimit);
  SetLength(Buffer, LZMA2_COPY_CHUNK_SIZE);
  InTotal := 0;
  OutTotal := 0;
  NeedInitLevel := $E0;
  Decoder := nil;

  try
    while True do
    begin
      Control := ReadByteRequired(Source);
      Inc(InTotal);

      if Control = LZMA2_CONTROL_EOF then
      begin
        if RejectTrailingBytes and (ReadAvailable(Source, Control, 1) <> 0) then
          RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes after LZMA2 end marker');
        ConsumedBytes := InTotal;
        ProducedBytes := OutTotal;
        ReportProgress(Progress, InTotal, OutTotal);
        Exit;
      end;

      if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
      begin
        if Control = LZMA2_CONTROL_COPY_RESET_DIC then
          NeedInitLevel := $C0
        else if NeedInitLevel = $E0 then
          RaiseLzmaError(SZ_ERROR_DATA, 'LZMA2 copy chunk without initial dictionary reset');

        SizeHi := ReadByteRequired(Source);
        SizeLo := ReadByteRequired(Source);
        Inc(InTotal, 2);
        ChunkSize := (NativeUInt(SizeHi) shl 8) or NativeUInt(SizeLo);
        Inc(ChunkSize);
        ReadExact(Source, Buffer[0], ChunkSize);
        Inc(InTotal, ChunkSize);

        EnsureDecoder;
        if Control = LZMA2_CONTROL_COPY_RESET_DIC then
          Decoder.ResetDictionary;
        Decoder.WriteUncompressed(Buffer, 0, ChunkSize, Destination);

        Inc(OutTotal, ChunkSize);
        ReportProgress(Progress, InTotal, OutTotal);
        Continue;
      end;

      if Control < $80 then
        RaiseLzmaError(SZ_ERROR_DATA, 'Invalid LZMA2 control byte');
      if Control < NeedInitLevel then
        RaiseLzmaError(SZ_ERROR_DATA, 'LZMA2 compressed chunk is missing required reset information');

      UnpackSize := (UInt32(Control and $1F) shl 16);
      SizeHi := ReadByteRequired(Source);
      SizeLo := ReadByteRequired(Source);
      PackHi := ReadByteRequired(Source);
      PackLo := ReadByteRequired(Source);
      Inc(InTotal, 4);
      UnpackSize := UnpackSize or (UInt32(SizeHi) shl 8) or UInt32(SizeLo);
      Inc(UnpackSize);
      PackSize := (NativeUInt(PackHi) shl 8) or NativeUInt(PackLo);
      Inc(PackSize);

      EnsureDecoder;
      if Control >= $E0 then
        Decoder.ResetDictionary;
      if (Control and $40) <> 0 then
      begin
        Prop := ReadByteRequired(Source);
        Inc(InTotal);
        Decoder.SetLcLpPb(Prop);
      end;
      if (Control >= $A0) and ((Control and $40) = 0) then
        Decoder.ResetState;

      SetLength(PackData, PackSize);
      ReadExact(Source, PackData[0], PackSize);
      Inc(InTotal, PackSize);
      Decoder.DecodeChunk(PackData, 0, PackSize, UnpackSize, Destination);
      Inc(OutTotal, UnpackSize);
      NeedInitLevel := 0;
      ReportProgress(Progress, InTotal, OutTotal);
    end;
  finally
    Decoder.Free;
  end;
end;

function DecodeRawMt(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent): Boolean;
var
  StartPosition: Int64;
  Units: TArray<TBytes>;
  OutputSizes: TArray<UInt64>;
  InputSizes: TArray<UInt64>;
  DecodeOptions: TLzma2Options;
  Workers: Integer;
  DictSize: UInt64;
  InTotal: UInt64;
  OutTotal: UInt64;
  TotalOutputSize: UInt64;
  MaxUnitOutputSize: UInt64;
  PackedInputSize: UInt64;
  WorkerOutputMemory: UInt64;
  CancelRequested: Integer;
  WorkerProgress: TLzma2ProgressEvent;
  WaitProc: TLzmaMtWaitProc;
  OriginalUnitCount: Integer;
  I: Integer;

begin
  Result := False;
  if EffectiveThreadCount(Options) <= 1 then
  begin
    SetLzma2DecodeDiagnostics(Options, 1, 1, False, ldfrThreadCountOne);
    Exit;
  end;

  if not TryGetStreamPosition(Source, StartPosition) then
  begin
    SetLzma2DecodeDiagnostics(Options, 1, 0, False, ldfrNonSeekableStream);
    Exit;
  end;

  SplitRawLzma2IndependentUnitsFromStream(Source, Options.MemoryLimit = 0, Units, OutputSizes,
    InputSizes, PackedInputSize);
  OriginalUnitCount := Length(Units);
  if Length(Units) <= 1 then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SetLzma2DecodeDiagnostics(Options, 1, OriginalUnitCount, False, ldfrSingleIndependentUnit);
    Exit;
  end;

  Workers := EffectiveThreadCount(Options);
  if Workers > Length(Units) then
    Workers := Length(Units);
  TotalOutputSize := 0;
  for I := 0 to High(Units) do
  begin
    if OutputSizes[I] > High(UInt64) - TotalOutputSize then
      RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode output size overflow');
    Inc(TotalOutputSize, OutputSizes[I]);
  end;
  if (Options.MemoryLimit = 0) and (Length(Units) > Workers) and
    (TotalOutputSize >= UInt64(Workers) * LZMA2_MT_DECODE_TARGET_UNIT_SIZE) then
  begin
    CoalesceRawLzma2MtUnits(Units, OutputSizes, InputSizes, LZMA2_MT_DECODE_TARGET_UNIT_SIZE);
    if Workers > Length(Units) then
      Workers := Length(Units);
  end;
  if not HasSufficientRawMtDecodeWork(PackedInputSize, TotalOutputSize, Workers) then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SetLzma2DecodeDiagnostics(Options, 1, OriginalUnitCount, False, ldfrInsufficientWork);
    Exit;
  end;

  DecodeOptions := Options;
  DecodeOptions.ThreadCount := 1;
  DecodeOptions.DecodeDiagnostics := nil;
  TotalOutputSize := 0;
  MaxUnitOutputSize := 0;
  for I := 0 to High(Units) do
  begin
    if OutputSizes[I] > MaxUnitOutputSize then
      MaxUnitOutputSize := OutputSizes[I];
    if OutputSizes[I] > High(UInt64) - TotalOutputSize then
      RaiseLzmaError(SZ_ERROR_MEM, 'Raw LZMA2 MT decode output size overflow');
    Inc(TotalOutputSize, OutputSizes[I]);
  end;
  DictSize := Options.DictionarySize;
  if DictSize = 0 then
    DictSize := DefaultDictionaryForLevel(Options.Level);
  if (Workers > 0) and (MaxUnitOutputSize > High(UInt64) div UInt64(Workers)) then
    WorkerOutputMemory := High(UInt64)
  else
    WorkerOutputMemory := UInt64(Workers) * MaxUnitOutputSize;
  if not FitsMtDecodeMemoryLimit(PackedInputSize, WorkerOutputMemory, DictSize, Workers, Options.MemoryLimit) then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SetLzma2DecodeDiagnostics(Options, 1, OriginalUnitCount, False, ldfrMemoryLimit);
    Exit;
  end;

  if Options.MemoryLimit <> 0 then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SplitRawLzma2IndependentUnitsFromStream(Source, True, Units, OutputSizes, InputSizes, PackedInputSize);
    if Length(Units) <> OriginalUnitCount then
      RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA2 MT decode preflight changed while reading payloads');
  end;

  CancelRequested := 0;
  InTotal := PackedInputSize;
  OutTotal := 0;
  WorkerProgress :=
    procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
    begin
      Cancel := TInterlocked.CompareExchange(CancelRequested, 0, 0) <> 0;
    end;
  WaitProc :=
    function: Boolean
    var
      Cancel: Boolean;
    begin
      Result := TInterlocked.CompareExchange(CancelRequested, 0, 0) <> 0;
      if Result or not Assigned(Progress) then
        Exit;

      Cancel := False;
      Progress(InTotal, OutTotal, Cancel);
      if Cancel then
        TInterlocked.Exchange(CancelRequested, 1);
      Result := Cancel;
    end;
  SetLzma2DecodeDiagnostics(Options, Workers, OriginalUnitCount, True, ldfrNone);
  TLzmaMtDecode.DecodeOrderedToStream(
    Units,
    OutputSizes,
    Destination,
    Workers,
    procedure(const Index: Integer; const Input: TBytes; const OutputSlice: TStream)
    var
      InStream: TBytesStream;
    begin
      InStream := TBytesStream.Create(Input);
      try
        TLzma2Decoder.DecodeRaw(InStream, OutputSlice, DecodeOptions, WorkerProgress);
      finally
        InStream.Free;
      end;
    end,
    WaitProc,
    procedure(const Index: Integer)
    begin
      Inc(OutTotal, OutputSizes[Index]);
      ReportProgress(Progress, InTotal, OutTotal);
    end,
    procedure
    begin
      TInterlocked.Exchange(CancelRequested, 1);
    end);

  Result := True;
end;

class procedure TLzma2Decoder.DecodeRaw(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  ConsumedBytes: UInt64;
  ProducedBytes: UInt64;
begin
  if DecodeRawMt(Source, Destination, Options, Progress) then
    Exit;
  DecodeRawInternal(Source, Destination, Options, Progress, True, ConsumedBytes, ProducedBytes);
end;

class procedure TLzma2Decoder.DecodeRawEmbedded(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  out ConsumedBytes: UInt64; out ProducedBytes: UInt64; const Progress: TLzma2ProgressEvent);
begin
  if EffectiveThreadCount(Options) <= 1 then
    SetLzma2DecodeDiagnostics(Options, 1, 1, False, ldfrThreadCountOne);
  DecodeRawInternal(Source, Destination, Options, Progress, False, ConsumedBytes, ProducedBytes);
end;

class function TLzma2Decoder.DecodeRawBytes(const Source: TBytes; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent): TBytes;
var
  InStream: TBytesStream;
  OutStream: TMemoryStream;
begin
  InStream := TBytesStream.Create(Source);
  OutStream := TMemoryStream.Create;
  try
    DecodeRaw(InStream, OutStream, Options, Progress);
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
