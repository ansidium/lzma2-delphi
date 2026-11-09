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
    class function RequiredMemory(const DictionarySize: UInt64): UInt64; static;
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
  out PackedInputSize: UInt64; const MemoryLimit: UInt64 = 0);
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
  CapturedBytes: UInt64;

  function CurrentMemory: UInt64;
  begin
    Result := CheckedMemoryAdd(CapturedBytes, UInt64(Length(CurrentUnit)));
    Result := CheckedMemoryAdd(Result, UInt64(Length(Payload)));
    Result := CheckedMemoryAdd(Result, CheckedMemoryMultiply(UInt64(Length(Units)), SizeOf(TBytes)));
    Result := CheckedMemoryAdd(Result, CheckedMemoryMultiply(UInt64(Length(OutputSizes)), SizeOf(UInt64)));
    Result := CheckedMemoryAdd(Result, CheckedMemoryMultiply(UInt64(Length(InputSizes)), SizeOf(UInt64)));
  end;

  procedure ValidateGrowth(const NewBytes: UInt64);
  begin
    if MemoryLimit <> 0 then
      ValidateMemoryLimit(CheckedMemoryAdd(CurrentMemory, NewBytes), MemoryLimit);
  end;

  procedure AddCurrentUnit(const AppendEof: Boolean);
  var
    OldLen: Integer;
  begin
    if SegmentInputSize = 0 then Exit;
    if CapturePayloads and AppendEof then
    begin
      ValidateGrowth(CheckedMemoryAdd(UInt64(Length(CurrentUnit)), 1));
      AppendRawByte(CurrentUnit, LZMA2_CONTROL_EOF);
    end;
    OldLen := Length(Units);
    if OldLen = High(Integer) then
      RaiseLzmaError(SZ_ERROR_MEM, 'Too many raw LZMA2 decode units');
    ValidateGrowth(CheckedMemoryMultiply(UInt64(OldLen) + 1, SizeOf(TBytes)));
    SetLength(Units, OldLen + 1);
    ValidateGrowth(CheckedMemoryMultiply(UInt64(OldLen) + 1, SizeOf(UInt64)));
    SetLength(OutputSizes, OldLen + 1);
    ValidateGrowth(CheckedMemoryMultiply(UInt64(OldLen) + 1, SizeOf(UInt64)));
    SetLength(InputSizes, OldLen + 1);
    if CapturePayloads then
    begin
      Units[OldLen] := CurrentUnit;
      CapturedBytes := CheckedMemoryAdd(CapturedBytes, UInt64(Length(CurrentUnit)));
      SetLength(CurrentUnit, 0);
    end;
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
    begin
      ValidateGrowth(CheckedMemoryAdd(UInt64(Length(CurrentUnit)), 1));
      AppendRawByte(CurrentUnit, Value);
    end;
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
      if NativeUInt(Length(Payload)) <> Count then
      begin
        ValidateGrowth(Count);
        SetLength(Payload, Integer(Count));
      end;
      ReadExact(Source, Payload[0], Count);
      ValidateGrowth(CheckedMemoryAdd(UInt64(Length(CurrentUnit)), Count));
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
  CapturedBytes := 0;

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
  ValidateMemoryLimit(TLzma2Decoder.RequiredMemory(DictSize), Options.MemoryLimit);
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

      ReadExact(Source, Buffer[0], PackSize);
      Inc(InTotal, PackSize);
      Decoder.DecodeChunk(Buffer, 0, PackSize, UnpackSize, Destination);
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
  WorkerMemory, MetadataMemory, StoredPackedSize, MaxPackedUnit, PackedUnitSize: UInt64;
  CaptureMemory, DecodeRetainedMemory: UInt64;
  CancelRequested: Integer;
  WorkerProgress: TLzma2ProgressEvent;
  WaitProc: TLzmaMtWaitProc;
  OriginalUnitCount: Integer;
  I: Integer;

  function FitsCurrentDecodePlan(const Captured: Boolean): Boolean;
  var
    UnitIndex: Integer;
  begin
    MaxUnitOutputSize := 0;
    StoredPackedSize := 0;
    for UnitIndex := 0 to High(Units) do
    begin
      if OutputSizes[UnitIndex] > MaxUnitOutputSize then
        MaxUnitOutputSize := OutputSizes[UnitIndex];
      if Captured then
        StoredPackedSize := CheckedMemoryAdd(StoredPackedSize, UInt64(Length(Units[UnitIndex])));
    end;
    if not Captured then
      StoredPackedSize := CheckedMemoryAdd(PackedInputSize, UInt64(Length(Units) - 1));
    if (Workers > 0) and (MaxUnitOutputSize > High(UInt64) div UInt64(Workers)) then
      WorkerOutputMemory := High(UInt64)
    else
      WorkerOutputMemory := UInt64(Workers) * MaxUnitOutputSize;
    DecodeRetainedMemory := CheckedMemoryAdd(StoredPackedSize, MetadataMemory);
    DecodeRetainedMemory := CheckedMemoryAdd(DecodeRetainedMemory,
      TLzmaMtDecode.RequiredMemory(Length(Units), Workers));
    DecodeRetainedMemory := CheckedMemoryAdd(DecodeRetainedMemory,
      CheckedMemoryMultiply(UInt64(Workers), TBytesStream.InstanceSize));
    WorkerMemory := TLzma2Decoder.RequiredMemory(DictSize);
    Result := FitsMtDecodeMemoryLimit(DecodeRetainedMemory, WorkerOutputMemory, WorkerMemory,
      Workers, Options.MemoryLimit);
  end;

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

  try
    SplitRawLzma2IndependentUnitsFromStream(Source, Options.MemoryLimit = 0, Units, OutputSizes,
      InputSizes, PackedInputSize, Options.MemoryLimit);
  except
    on E: ELzmaMemoryError do
    begin
      if Options.MemoryLimit = 0 then raise;
      RestoreStreamPosition(Source, StartPosition);
      SetLzma2DecodeDiagnostics(Options, 1, Length(Units), False, ldfrMemoryLimit);
      Exit;
    end;
  end;
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
  DictSize := Options.DictionarySize;
  if DictSize = 0 then
    DictSize := DefaultDictionaryForLevel(Options.Level);
  MetadataMemory := CheckedMemoryMultiply(UInt64(Length(Units)),
    SizeOf(TBytes) + 2 * SizeOf(UInt64));
  StoredPackedSize := CheckedMemoryAdd(PackedInputSize, UInt64(Length(Units) - 1));
  MaxPackedUnit := 0;
  for I := 0 to High(InputSizes) do
  begin
    PackedUnitSize := InputSizes[I];
    if I < High(InputSizes) then PackedUnitSize := CheckedMemoryAdd(PackedUnitSize, 1);
    if PackedUnitSize > MaxPackedUnit then MaxPackedUnit := PackedUnitSize;
  end;
  CaptureMemory := CheckedMemoryAdd(StoredPackedSize, MaxPackedUnit);
  CaptureMemory := CheckedMemoryAdd(CaptureMemory, LZMA2_COPY_CHUNK_SIZE);
  CaptureMemory := CheckedMemoryAdd(CaptureMemory, MetadataMemory);
  // Only one metadata array resizes at a time during capture.
  CaptureMemory := CheckedMemoryAdd(CaptureMemory,
    CheckedMemoryMultiply(UInt64(Length(Units) - 1), SizeOf(UInt64)));
  if ((Options.MemoryLimit <> 0) and (CaptureMemory > Options.MemoryLimit)) or
    not FitsCurrentDecodePlan(False) then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SetLzma2DecodeDiagnostics(Options, 1, OriginalUnitCount, False, ldfrMemoryLimit);
    Exit;
  end;

  if Options.MemoryLimit <> 0 then
  begin
    RestoreStreamPosition(Source, StartPosition);
    try
      SplitRawLzma2IndependentUnitsFromStream(Source, True, Units, OutputSizes, InputSizes,
        PackedInputSize, Options.MemoryLimit);
    except
      on E: ELzmaMemoryError do
      begin
        RestoreStreamPosition(Source, StartPosition);
        SetLzma2DecodeDiagnostics(Options, 1, OriginalUnitCount, False, ldfrMemoryLimit);
        Exit;
      end;
    end;
    if Length(Units) <> OriginalUnitCount then
      RaiseLzmaError(SZ_ERROR_DATA, 'Raw LZMA2 MT decode preflight changed while reading payloads');
    // Rewind may expose different valid data from a mutable caller-owned stream.
    // Admit the captured arrays and their actual output sizes before workers allocate.
    if not FitsCurrentDecodePlan(True) then
    begin
      RestoreStreamPosition(Source, StartPosition);
      SetLzma2DecodeDiagnostics(Options, 1, OriginalUnitCount, False, ldfrMemoryLimit);
      Exit;
    end;
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

class function TLzma2Decoder.RequiredMemory(const DictionarySize: UInt64): UInt64;
begin
  Result := CheckedMemoryAdd(TLzmaDecoderState.RequiredLzma2Memory(DictionarySize),
    LZMA2_COPY_CHUNK_SIZE);
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
