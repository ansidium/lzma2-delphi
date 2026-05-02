unit Lzma.Xz;

interface

uses
  System.Classes,
  System.SysUtils,
  System.SyncObjs,
  Lzma.Types;

type
  TLzmaXz = class
  public
    class procedure Encode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure Decode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
  end;

implementation

uses
  System.Hash,
  Lzma.Alloc,
  Lzma.Encoder,
  Lzma.Errors,
  Lzma.MtDec,
  Lzma.Streams,
  Lzma.XzCrc,
  Lzma2.Encoder,
  Lzma2.Decoder;

const
  XZ_PADDING_PROGRESS_GRANULARITY = 4096;

type
  TXzIndexRecord = record
    UnpaddedSize: UInt64;
    UnpackSize: UInt64;
  end;

  TXzIndexRecords = array of TXzIndexRecord;

  TXzMtBlock = record
    RawData: TBytes;
    ExpectedDigest: TBytes;
    Lzma2Prop: Byte;
    PayloadOffset: Int64;
    CheckOffset: Int64;
    CheckSize: NativeUInt;
    HeaderSize: UInt64;
    PackSize: UInt64;
    HeaderUnpackSize: UInt64;
  end;

  TXzMtBlocks = array of TXzMtBlock;

  TXzCheckState = record
  private
    FCheckId: Byte;
    FCrc32: UInt32;
    FCrc64: UInt64;
    FSha256: THashSHA2;
  public
    procedure Init(const CheckId: Byte);
    procedure Update(const Buffer; const Count: NativeUInt);
    function Finish: TBytes;
  end;

  TCheckedReadStream = class(TStream)
  private
    FSource: TStream;
    FCheck: TXzCheckState;
    FBytesRead: UInt64;
  protected
    function GetSize: Int64; override;
  public
    constructor Create(const Source: TStream; const CheckId: Byte);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    function Digest: TBytes;
    property BytesRead: UInt64 read FBytesRead;
  end;

  TLimitedReadStream = class(TStream)
  private
    FBase: TStream;
    FLimit: UInt64;
    FPosition: UInt64;
  public
    constructor Create(const Base: TStream; const Limit: UInt64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Position64: UInt64 read FPosition;
  end;

  TCountingWriteStream = class(TStream)
  private
    FDestination: TStream;
    FBytesWritten: UInt64;
  public
    constructor Create(const Destination: TStream);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property BytesWritten: UInt64 read FBytesWritten;
  end;

  TCheckedWriteStream = class(TStream)
  private
    FDestination: TStream;
    FCheck: TXzCheckState;
    FBytesWritten: UInt64;
  public
    constructor Create(const Destination: TStream; const CheckId: Byte);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    function Digest: TBytes;
    property BytesWritten: UInt64 read FBytesWritten;
  end;

procedure TXzCheckState.Init(const CheckId: Byte);
begin
  FCheckId := CheckId;
  case FCheckId of
    XZ_CHECK_NO:
      ;
    XZ_CHECK_CRC32:
      FCrc32 := CRC_INIT_VAL;
    XZ_CHECK_CRC64:
      FCrc64 := CRC64_INIT_VAL;
    XZ_CHECK_SHA256:
      FSha256 := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
  else
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ check id');
  end;
end;

procedure TXzCheckState.Update(const Buffer; const Count: NativeUInt);
begin
  if Count = 0 then
    Exit;
  case FCheckId of
    XZ_CHECK_NO:
      ;
    XZ_CHECK_CRC32:
      FCrc32 := Crc32Update(FCrc32, @Buffer, Count);
    XZ_CHECK_CRC64:
      FCrc64 := Crc64Update(FCrc64, @Buffer, Count);
    XZ_CHECK_SHA256:
      FSha256.Update(Buffer, Cardinal(Count));
  else
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ check id');
  end;
end;

function TXzCheckState.Finish: TBytes;
var
  C32: UInt32;
  C64: UInt64;
  I: Integer;
begin
  case FCheckId of
    XZ_CHECK_NO:
      SetLength(Result, 0);
    XZ_CHECK_CRC32:
      begin
        SetLength(Result, 4);
        C32 := FCrc32 xor CRC_INIT_VAL;
        WriteUi32LE(@Result[0], C32);
      end;
    XZ_CHECK_CRC64:
      begin
        SetLength(Result, 8);
        C64 := FCrc64 xor CRC64_INIT_VAL;
        for I := 0 to 7 do
        begin
          Result[I] := Byte(C64);
          C64 := C64 shr 8;
        end;
      end;
    XZ_CHECK_SHA256:
      Result := FSha256.HashAsBytes;
  else
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ check id');
  end;
end;

constructor TCheckedReadStream.Create(const Source: TStream; const CheckId: Byte);
begin
  inherited Create;
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  FSource := Source;
  FCheck.Init(CheckId);
  FBytesRead := 0;
end;

function TCheckedReadStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  Result := ReadAvailable(FSource, Buffer, Count);
  if Result > 0 then
  begin
    if UInt64(Result) > High(UInt64) - FBytesRead then
      RaiseLzmaError(SZ_ERROR_MEM, 'XZ block input size overflow');
    FCheck.Update(Buffer, Result);
    Inc(FBytesRead, UInt64(Result));
  end;
end;

function TCheckedReadStream.Write(const Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_WRITE, 'Checked input stream is read-only');
  Result := 0;
end;

function TCheckedReadStream.GetSize: Int64;
var
  BasePosition: Int64;
begin
  BasePosition := FSource.Position - Int64(FBytesRead);
  Result := FSource.Size - BasePosition;
end;

function TCheckedReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Origin = soCurrent) and (Offset = 0) then
    Exit(Int64(FBytesRead));
  RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Checked input stream is not seekable');
  Result := Int64(FBytesRead);
end;

function TCheckedReadStream.Digest: TBytes;
begin
  Result := FCheck.Finish;
end;

constructor TLimitedReadStream.Create(const Base: TStream; const Limit: UInt64);
begin
  inherited Create;
  FBase := Base;
  FLimit := Limit;
  FPosition := 0;
end;

function TLimitedReadStream.Read(var Buffer; Count: Longint): Longint;
var
  Remaining: UInt64;
begin
  if Count <= 0 then
    Exit(0);
  if FPosition >= FLimit then
    Exit(0);
  Remaining := FLimit - FPosition;
  if UInt64(Count) > Remaining then
    Count := Integer(Remaining);
  Result := ReadAvailable(FBase, Buffer, Count);
  Inc(FPosition, UInt64(Result));
end;

function TLimitedReadStream.Write(const Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_WRITE, 'Limited input stream is read-only');
  Result := 0;
end;

function TLimitedReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Origin = soCurrent) and (Offset = 0) then
    Exit(Int64(FPosition));
  RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Limited input stream is not seekable');
  Result := Int64(FPosition);
end;

constructor TCountingWriteStream.Create(const Destination: TStream);
begin
  inherited Create;
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');
  FDestination := Destination;
  FBytesWritten := 0;
end;

function TCountingWriteStream.Read(var Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Counting output stream is write-only');
  Result := 0;
end;

function TCountingWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  if UInt64(Count) > High(UInt64) - FBytesWritten then
    RaiseLzmaError(SZ_ERROR_MEM, 'XZ block packed size overflow');
  WriteExact(FDestination, Buffer, Count);
  Inc(FBytesWritten, UInt64(Count));
  Result := Count;
end;

function TCountingWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Origin = soCurrent) and (Offset = 0) then
    Exit(Int64(FBytesWritten));
  RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Counting output stream is not seekable');
  Result := Int64(FBytesWritten);
end;

constructor TCheckedWriteStream.Create(const Destination: TStream; const CheckId: Byte);
begin
  inherited Create;
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');
  FDestination := Destination;
  FCheck.Init(CheckId);
  FBytesWritten := 0;
end;

function TCheckedWriteStream.Read(var Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Checked output stream is write-only');
  Result := 0;
end;

function TCheckedWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);
  if UInt64(Count) > High(UInt64) - FBytesWritten then
    RaiseLzmaError(SZ_ERROR_MEM, 'XZ block output size overflow');
  WriteExact(FDestination, Buffer, Count);
  FCheck.Update(Buffer, Count);
  Inc(FBytesWritten, UInt64(Count));
  Result := Count;
end;

function TCheckedWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Origin = soCurrent) and (Offset = 0) then
    Exit(Int64(FBytesWritten));
  RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Checked output stream is not seekable');
  Result := Int64(FBytesWritten);
end;

function TCheckedWriteStream.Digest: TBytes;
begin
  Result := FCheck.Finish;
end;

function BytesEqualAt(const A, B: TBytes; const AOffset: NativeUInt = 0): Boolean;
var
  I: Integer;
begin
  Result := AOffset + NativeUInt(Length(B)) <= NativeUInt(Length(A));
  if not Result then
    Exit;
  for I := 0 to High(B) do
    if A[AOffset + NativeUInt(I)] <> B[I] then
      Exit(False);
end;

procedure AppendBytes(var Target: TBytes; const Source: TBytes); overload;
var
  OldLen: Integer;
begin
  if Length(Source) = 0 then
    Exit;
  OldLen := Length(Target);
  SetLength(Target, OldLen + Length(Source));
  Move(Source[0], Target[OldLen], Length(Source));
end;

procedure AppendByte(var Target: TBytes; const Value: Byte); overload;
var
  OldLen: Integer;
begin
  OldLen := Length(Target);
  SetLength(Target, OldLen + 1);
  Target[OldLen] := Value;
end;

procedure AppendZeroes(var Target: TBytes; const Count: NativeUInt);
var
  OldLen: Integer;
begin
  if Count = 0 then
    Exit;
  OldLen := Length(Target);
  SetLength(Target, OldLen + Integer(Count));
  FillChar(Target[OldLen], Count, 0);
end;

procedure WriteZeroes(const Destination: TStream; const Count: NativeUInt);
var
  Z: TBytes;
begin
  if Count = 0 then
    Exit;
  SetLength(Z, Count);
  FillChar(Z[0], Count, 0);
  WriteBytes(Destination, Z);
end;

function BuildStreamHeader(const CheckId: Byte): TBytes;
var
  Crc: UInt32;
begin
  SetLength(Result, XZ_STREAM_HEADER_SIZE);
  Move(XZ_SIG[0], Result[0], XZ_SIG_SIZE);
  Result[XZ_SIG_SIZE] := 0;
  Result[XZ_SIG_SIZE + 1] := CheckId;
  Crc := Crc32Calc(@Result[XZ_SIG_SIZE], XZ_STREAM_FLAGS_SIZE);
  WriteUi32LE(@Result[XZ_SIG_SIZE + XZ_STREAM_FLAGS_SIZE], Crc);
end;

function BuildStreamingBlockHeader(const Lzma2Prop: Byte): TBytes;
var
  Header: TBytes;
  Crc: UInt32;
begin
  SetLength(Header, 0);
  AppendByte(Header, 0);
  AppendByte(Header, 0);
  AppendBytes(Header, XzWriteVarInt(XZ_ID_LZMA2));
  AppendBytes(Header, XzWriteVarInt(1));
  AppendByte(Header, Lzma2Prop);
  AppendZeroes(Header, XzPadSize(Length(Header)));
  Header[0] := Byte(Length(Header) div 4);
  Crc := Crc32Calc(Header);
  Result := Header;
  SetLength(Result, Length(Result) + 4);
  WriteUi32LE(@Result[Length(Result) - 4], Crc);
end;

function BuildSizedBlockHeader(const Lzma2Prop: Byte; const PackSize, UnpackSize: UInt64): TBytes;
var
  Header: TBytes;
  Crc: UInt32;
begin
  SetLength(Header, 0);
  AppendByte(Header, 0);
  AppendByte(Header, XZ_BF_PACK_SIZE or XZ_BF_UNPACK_SIZE);
  AppendBytes(Header, XzWriteVarInt(PackSize));
  AppendBytes(Header, XzWriteVarInt(UnpackSize));
  AppendBytes(Header, XzWriteVarInt(XZ_ID_LZMA2));
  AppendBytes(Header, XzWriteVarInt(1));
  AppendByte(Header, Lzma2Prop);
  AppendZeroes(Header, XzPadSize(Length(Header)));
  Header[0] := Byte(Length(Header) div 4);
  Crc := Crc32Calc(Header);
  Result := Header;
  SetLength(Result, Length(Result) + 4);
  WriteUi32LE(@Result[Length(Result) - 4], Crc);
end;

function BuildIndexRecordsAndFooter(const Records: TXzIndexRecords; const CheckId: Byte): TBytes;
var
  Index: TBytes;
  Footer: TBytes;
  Crc: UInt32;
  BackwardSize: UInt32;
  I: Integer;
begin
  SetLength(Index, 0);
  AppendByte(Index, 0);
  AppendBytes(Index, XzWriteVarInt(UInt64(Length(Records))));
  for I := 0 to High(Records) do
  begin
    AppendBytes(Index, XzWriteVarInt(Records[I].UnpaddedSize));
    AppendBytes(Index, XzWriteVarInt(Records[I].UnpackSize));
  end;
  AppendZeroes(Index, XzPadSize(Length(Index)));
  Crc := Crc32Calc(Index);
  AppendByte(Index, Byte(Crc));
  AppendByte(Index, Byte(Crc shr 8));
  AppendByte(Index, Byte(Crc shr 16));
  AppendByte(Index, Byte(Crc shr 24));

  BackwardSize := UInt32(Length(Index) div 4 - 1);
  SetLength(Footer, XZ_STREAM_FOOTER_SIZE);
  WriteUi32LE(@Footer[4], BackwardSize);
  Footer[8] := 0;
  Footer[9] := CheckId;
  Crc := Crc32Calc(@Footer[4], 6);
  WriteUi32LE(@Footer[0], Crc);
  Footer[10] := Ord('Y');
  Footer[11] := Ord('Z');

  Result := Index;
  AppendBytes(Result, Footer);
end;

function BuildIndexAndFooter(const UnpaddedSize, UnpackSize: UInt64; const CheckId: Byte): TBytes;
var
  Records: TXzIndexRecords;
begin
  SetLength(Records, 1);
  Records[0].UnpaddedSize := UnpaddedSize;
  Records[0].UnpackSize := UnpackSize;
  Result := BuildIndexRecordsAndFooter(Records, CheckId);
end;

function SliceBytes(const Data: TBytes; const Offset, Count: NativeUInt): TBytes;
begin
  if (Offset > NativeUInt(Length(Data))) or (Count > NativeUInt(Length(Data)) - Offset) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'XZ stream is truncated');
  SetLength(Result, Count);
  if Count <> 0 then
    Move(Data[Offset], Result[0], Count);
end;

procedure AppendIndexRecord(var Records: TXzIndexRecords; const RecordInfo: TXzIndexRecord);
var
  OldLen: Integer;
begin
  OldLen := Length(Records);
  SetLength(Records, OldLen + 1);
  Records[OldLen] := RecordInfo;
end;

function IndexRecordsEqual(const A, B: TXzIndexRecords): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then
    Exit;
  for I := 0 to High(A) do
    if (A[I].UnpaddedSize <> B[I].UnpaddedSize) or (A[I].UnpackSize <> B[I].UnpackSize) then
      Exit(False);
end;

procedure ValidateHeader(const Data: TBytes; out CheckId: Byte);
var
  CrcExpected: UInt32;
  CrcActual: UInt32;
begin
  if Length(Data) < XZ_STREAM_HEADER_SIZE then
    RaiseLzmaError(SZ_ERROR_NO_ARCHIVE, 'Input is too small to be an XZ stream');
  if not BytesEqualAt(Data, TBytes.Create($FD, Ord('7'), Ord('z'), Ord('X'), Ord('Z'), 0)) then
    RaiseLzmaError(SZ_ERROR_NO_ARCHIVE, 'XZ stream signature mismatch');
  CrcExpected := ReadUi32LE(@Data[XZ_SIG_SIZE + XZ_STREAM_FLAGS_SIZE]);
  CrcActual := Crc32Calc(@Data[XZ_SIG_SIZE], XZ_STREAM_FLAGS_SIZE);
  if CrcExpected <> CrcActual then
    RaiseLzmaError(SZ_ERROR_NO_ARCHIVE, 'XZ stream header CRC mismatch');
  if Data[XZ_SIG_SIZE] <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ stream flags');
  CheckId := Data[XZ_SIG_SIZE + 1];
  if XzCheckSizeById(CheckId) = NativeUInt(-1) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ check type');
end;

procedure ValidateFooterBytes(const Footer: TBytes; const CheckId: Byte; const IndexSize: NativeUInt);
var
  FooterCrcExpected: UInt32;
  FooterCrcActual: UInt32;
  BackwardSize: UInt64;
begin
  if Length(Footer) <> XZ_STREAM_FOOTER_SIZE then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer is truncated');
  if (Footer[10] <> Ord('Y')) or (Footer[11] <> Ord('Z')) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer signature mismatch');
  if (Footer[8] <> 0) or (Footer[9] <> CheckId) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer flags do not match header flags');
  FooterCrcExpected := ReadUi32LE(@Footer[0]);
  FooterCrcActual := Crc32Calc(@Footer[4], 6);
  if FooterCrcExpected <> FooterCrcActual then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer CRC mismatch');
  BackwardSize := UInt64(ReadUi32LE(@Footer[4]) + 1) * 4;
  if BackwardSize <> IndexSize then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer backward size does not match the index');
end;

procedure ValidateFooter(const Data: TBytes; const CheckId: Byte; out IndexOffset: NativeUInt; out IndexSize: NativeUInt);
var
  FooterOffset: NativeUInt;
  FooterCrcExpected: UInt32;
  FooterCrcActual: UInt32;
  BackwardSize: UInt64;
begin
  FooterOffset := NativeUInt(Length(Data)) - XZ_STREAM_FOOTER_SIZE;
  if (Data[FooterOffset + 10] <> Ord('Y')) or (Data[FooterOffset + 11] <> Ord('Z')) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer signature mismatch');
  if (Data[FooterOffset + 8] <> 0) or (Data[FooterOffset + 9] <> CheckId) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer flags do not match header flags');
  FooterCrcExpected := ReadUi32LE(@Data[FooterOffset]);
  FooterCrcActual := Crc32Calc(@Data[FooterOffset + 4], 6);
  if FooterCrcExpected <> FooterCrcActual then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ footer CRC mismatch');

  BackwardSize := UInt64(ReadUi32LE(@Data[FooterOffset + 4]) + 1) * 4;
  if BackwardSize > FooterOffset - XZ_STREAM_HEADER_SIZE then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index points before stream header');
  IndexSize := NativeUInt(BackwardSize);
  IndexOffset := FooterOffset - IndexSize;
end;

procedure ParseIndex(const Data: TBytes; const IndexOffset, IndexSize: NativeUInt; out Records: TXzIndexRecords);
var
  Index: TBytes;
  Pos: NativeUInt;
  Limit: NativeUInt;
  CrcExpected: UInt32;
  CrcActual: UInt32;
  NumRecords: UInt64;
  I: Integer;
begin
  SetLength(Records, 0);
  Index := SliceBytes(Data, IndexOffset, IndexSize);
  if IndexSize < 4 then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index is too small');
  CrcExpected := ReadUi32LE(@Index[IndexSize - 4]);
  CrcActual := Crc32Calc(@Index[0], IndexSize - 4);
  if CrcExpected <> CrcActual then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index CRC mismatch');
  Pos := 0;
  Limit := IndexSize - 4;
  if (Limit = 0) or (Index[Pos] <> 0) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index marker mismatch');
  Inc(Pos);
  if not XzReadVarInt(Index, Pos, Limit, NumRecords) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index record count');
  if NumRecords > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'XZ index has too many records for this process');
  if NumRecords = 0 then
  begin
    while Pos < Limit do
    begin
      if Index[Pos] <> 0 then
        RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ empty index padding is not zero');
      Inc(Pos);
    end;
    Exit;
  end;
  SetLength(Records, Integer(NumRecords));
  for I := 0 to High(Records) do
  begin
    if not XzReadVarInt(Index, Pos, Limit, Records[I].UnpaddedSize) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index unpadded size');
    if Records[I].UnpaddedSize = 0 then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index zero unpadded size');
    if not XzReadVarInt(Index, Pos, Limit, Records[I].UnpackSize) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index unpack size');
  end;
  while Pos < Limit do
  begin
    if Index[Pos] <> 0 then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index padding is not zero');
    Inc(Pos);
  end;
end;

function XzReadVarIntFromStream(const Source: TStream; var IndexBytes: TBytes; out Value: UInt64): Boolean;
var
  I: Integer;
  B: Byte;
begin
  Value := 0;
  Result := False;
  I := 0;
  while I < 9 do
  begin
    B := ReadByteRequired(Source);
    AppendByte(IndexBytes, B);
    Value := Value or (UInt64(B and $7F) shl (7 * I));
    Inc(I);
    if (B and $80) = 0 then
    begin
      Result := not ((B = 0) and (I <> 1));
      Exit;
    end;
  end;
end;

procedure ParseIndexForward(const Source: TStream; out Records: TXzIndexRecords; out IndexSize: NativeUInt);
var
  IndexBytes: TBytes;
  CrcBytes: array[0..3] of Byte;
  CrcExpected: UInt32;
  CrcActual: UInt32;
  NumRecords: UInt64;
  I: Integer;
  PadByte: Byte;
begin
  SetLength(Records, 0);
  SetLength(IndexBytes, 0);
  AppendByte(IndexBytes, 0);

  if not XzReadVarIntFromStream(Source, IndexBytes, NumRecords) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index record count');
  if NumRecords > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'XZ index has too many records for this process');

  SetLength(Records, Integer(NumRecords));
  for I := 0 to High(Records) do
  begin
    if not XzReadVarIntFromStream(Source, IndexBytes, Records[I].UnpaddedSize) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index unpadded size');
    if Records[I].UnpaddedSize = 0 then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index zero unpadded size');
    if not XzReadVarIntFromStream(Source, IndexBytes, Records[I].UnpackSize) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ index unpack size');
  end;

  while (Length(IndexBytes) and 3) <> 0 do
  begin
    PadByte := ReadByteRequired(Source);
    if PadByte <> 0 then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index padding is not zero');
    AppendByte(IndexBytes, PadByte);
  end;

  ReadExact(Source, CrcBytes[0], SizeOf(CrcBytes));
  CrcExpected := ReadUi32LE(@CrcBytes[0]);
  CrcActual := Crc32Calc(IndexBytes);
  if CrcExpected <> CrcActual then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index CRC mismatch');
  IndexSize := NativeUInt(Length(IndexBytes) + SizeOf(CrcBytes));
end;

procedure ParseBlockHeaderBytes(const Header: TBytes;
  out HeaderSize: NativeUInt; out PackSize, UnpackSize: UInt64; out Lzma2Prop: Byte);
var
  HeaderCrcExpected: UInt32;
  HeaderCrcActual: UInt32;
  Pos: NativeUInt;
  Limit: NativeUInt;
  Flags: Byte;
  FilterId: UInt64;
  PropsSize: UInt64;
begin
  if Length(Header) = 0 then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Missing XZ block header');
  if Header[0] = 0 then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Unexpected XZ index marker instead of block header');
  HeaderSize := NativeUInt(Header[0]) * 4 + 4;
  if (HeaderSize < 8) or (HeaderSize > XZ_BLOCK_HEADER_SIZE_MAX) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ block header size');
  if NativeUInt(Length(Header)) <> HeaderSize then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block header is truncated');
  HeaderCrcExpected := ReadUi32LE(@Header[HeaderSize - 4]);
  HeaderCrcActual := Crc32Calc(@Header[0], HeaderSize - 4);
  if HeaderCrcExpected <> HeaderCrcActual then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block header CRC mismatch');

  Pos := 1;
  Limit := HeaderSize - 4;
  Flags := Header[Pos];
  Inc(Pos);
  if (Flags and not (XZ_BF_NUM_FILTERS_MASK or XZ_BF_PACK_SIZE or XZ_BF_UNPACK_SIZE)) <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ block flags');
  if (Flags and XZ_BF_NUM_FILTERS_MASK) <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Only a single LZMA2 filter is currently supported');
  if (Flags and XZ_BF_PACK_SIZE) = 0 then
    PackSize := UInt64(-1)
  else if not XzReadVarInt(Header, Pos, Limit, PackSize) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ block packed size');
  if (Flags and XZ_BF_UNPACK_SIZE) = 0 then
    UnpackSize := UInt64(-1)
  else if not XzReadVarInt(Header, Pos, Limit, UnpackSize) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ block unpacked size');

  if not XzReadVarInt(Header, Pos, Limit, FilterId) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ filter id');
  if FilterId <> XZ_ID_LZMA2 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'XZ block does not use the LZMA2 filter');
  if not XzReadVarInt(Header, Pos, Limit, PropsSize) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ filter property size');
  if PropsSize <> 1 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA2 filter property size');
  if Pos >= Limit then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Missing LZMA2 filter property');
  Lzma2Prop := Header[Pos];
  Inc(Pos);
  if Lzma2Prop > LZMA2_DIC_PROP_MAX then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported LZMA2 dictionary property');
  while Pos < Limit do
  begin
    if Header[Pos] <> 0 then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block header padding is not zero');
    Inc(Pos);
  end;
end;

procedure ParseBlockHeader(const Data: TBytes; const Offset: NativeUInt;
  out HeaderSize: NativeUInt; out PackSize, UnpackSize: UInt64; out Lzma2Prop: Byte);
begin
  if Offset >= NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Missing XZ block header');
  ParseBlockHeaderBytes(SliceBytes(Data, Offset, NativeUInt(Data[Offset]) * 4 + 4),
    HeaderSize, PackSize, UnpackSize, Lzma2Prop);
end;

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

function ReadByteAt(const Source: TStream; const Position: Int64): Byte;
begin
  Source.Position := Position;
  ReadExact(Source, Result, 1);
end;

function ReadStreamBytesAt(const Source: TStream; const Position: Int64; const Count: NativeUInt): TBytes;
begin
  if Count > NativeUInt(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'XZ range is too large for this process');
  SetLength(Result, Integer(Count));
  if Count = 0 then
    Exit;
  Source.Position := Position;
  ReadExact(Source, Result[0], Count);
end;

function XzStreamLimitWithoutPadding(const Source: TStream; const StartPosition, SourceSize: Int64): Int64;
var
  PaddingSize: Int64;
begin
  Result := SourceSize;
  while Result > StartPosition + XZ_STREAM_HEADER_SIZE + XZ_STREAM_FOOTER_SIZE do
  begin
    if ReadByteAt(Source, Result - 1) <> 0 then
      Break;
    Dec(Result);
  end;
  PaddingSize := SourceSize - Result;
  if (PaddingSize and 3) <> 0 then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ stream padding size is not a multiple of 4');
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

procedure AppendMtBlock(var Blocks: TXzMtBlocks; const Block: TXzMtBlock);
var
  OldLen: Integer;
begin
  OldLen := Length(Blocks);
  SetLength(Blocks, OldLen + 1);
  Blocks[OldLen] := Block;
end;

function XzDataLimitWithoutStreamPadding(const Data: TBytes): NativeUInt;
begin
  Result := NativeUInt(Length(Data));
  while (Result > XZ_STREAM_HEADER_SIZE + XZ_STREAM_FOOTER_SIZE) and (Data[Result - 1] = 0) do
    Dec(Result);
  if ((NativeUInt(Length(Data)) - Result) and 3) <> 0 then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ stream padding size is not a multiple of 4');
end;

function TryPrepareXzMtBlocks(const Data: TBytes; out CheckId: Byte; out Blocks: TXzMtBlocks;
  out IndexRecords: TXzIndexRecords; out ObservedBlockCount: Integer;
  out FallbackReason: TLzma2DecodeFallbackReason): Boolean;
var
  Limit: NativeUInt;
  FooterOffset: NativeUInt;
  Footer: TBytes;
  IndexOffset: NativeUInt;
  IndexSize: NativeUInt;
  IndexSize64: UInt64;
  Offset: NativeUInt;
  HeaderSize: NativeUInt;
  HeaderPackSize: UInt64;
  HeaderUnpackSize: UInt64;
  EffectivePackSize: UInt64;
  EffectiveUnpackSize: UInt64;
  IndexPackSize: UInt64;
  Lzma2Prop: Byte;
  CheckSize: NativeUInt;
  PayloadOffset: NativeUInt;
  CheckOffset: NativeUInt;
  Pad: Byte;
  J: Integer;
  Block: TXzMtBlock;
  IndexRecord: TXzIndexRecord;
begin
  Result := False;
  FallbackReason := ldfrUnsupportedLayout;
  ObservedBlockCount := 0;
  SetLength(Blocks, 0);
  SetLength(IndexRecords, 0);

  ValidateHeader(Data, CheckId);
  CheckSize := XzCheckSizeById(CheckId);
  Limit := XzDataLimitWithoutStreamPadding(Data);
  if Limit < XZ_STREAM_HEADER_SIZE + XZ_STREAM_FOOTER_SIZE then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ stream is truncated');

  FooterOffset := Limit - XZ_STREAM_FOOTER_SIZE;
  Footer := SliceBytes(Data, FooterOffset, XZ_STREAM_FOOTER_SIZE);
  IndexSize64 := UInt64(ReadUi32LE(@Footer[4]) + 1) * 4;
  if IndexSize64 > UInt64(FooterOffset - XZ_STREAM_HEADER_SIZE) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index points before stream header');
  if IndexSize64 > UInt64(High(NativeUInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'XZ index is too large for this process');
  IndexSize := NativeUInt(IndexSize64);
  ValidateFooterBytes(Footer, CheckId, IndexSize);
  IndexOffset := FooterOffset - IndexSize;
  ParseIndex(Data, IndexOffset, IndexSize, IndexRecords);

  Offset := XZ_STREAM_HEADER_SIZE;
  while Offset < IndexOffset do
  begin
    if Data[Offset] = 0 then
      Break;

    ParseBlockHeader(Data, Offset, HeaderSize, HeaderPackSize, HeaderUnpackSize, Lzma2Prop);
    if ObservedBlockCount >= Length(IndexRecords) then
    begin
      FallbackReason := ldfrUnsupportedLayout;
      Exit;
    end;
    IndexRecord := IndexRecords[ObservedBlockCount];
    Inc(ObservedBlockCount);

    if (UInt64(HeaderSize) > IndexRecord.UnpaddedSize) or
      (UInt64(CheckSize) > IndexRecord.UnpaddedSize - UInt64(HeaderSize)) then
    begin
      FallbackReason := ldfrUnsupportedLayout;
      Exit;
    end;
    IndexPackSize := IndexRecord.UnpaddedSize - UInt64(HeaderSize) - UInt64(CheckSize);
    if HeaderPackSize = UInt64(-1) then
      EffectivePackSize := IndexPackSize
    else
    begin
      EffectivePackSize := HeaderPackSize;
      if EffectivePackSize <> IndexPackSize then
      begin
        FallbackReason := ldfrUnsupportedLayout;
        Exit;
      end;
    end;
    if HeaderUnpackSize = UInt64(-1) then
      EffectiveUnpackSize := IndexRecord.UnpackSize
    else
    begin
      EffectiveUnpackSize := HeaderUnpackSize;
      if EffectiveUnpackSize <> IndexRecord.UnpackSize then
      begin
        FallbackReason := ldfrUnsupportedLayout;
        Exit;
      end;
    end;

    if EffectivePackSize > UInt64(High(NativeUInt)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'XZ block packed size is too large for this process');
    PayloadOffset := Offset + HeaderSize;
    if PayloadOffset > IndexOffset then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload starts past index');
    if EffectivePackSize > UInt64(IndexOffset - PayloadOffset) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload is truncated');
    Pad := XzPadSize(EffectivePackSize);
    if UInt64(Pad) > UInt64(IndexOffset - PayloadOffset) - EffectivePackSize then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload padding is truncated');
    CheckOffset := PayloadOffset + NativeUInt(EffectivePackSize) + Pad;
    if (CheckOffset > IndexOffset) or (CheckSize > IndexOffset - CheckOffset) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload is truncated');
    for J := 0 to Pad - 1 do
      if Data[PayloadOffset + NativeUInt(EffectivePackSize) + NativeUInt(J)] <> 0 then
        RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block padding is not zero');

    Block.RawData := SliceBytes(Data, PayloadOffset, NativeUInt(EffectivePackSize));
    Block.ExpectedDigest := SliceBytes(Data, CheckOffset, CheckSize);
    Block.Lzma2Prop := Lzma2Prop;
    Block.HeaderSize := HeaderSize;
    Block.PackSize := EffectivePackSize;
    Block.HeaderUnpackSize := EffectiveUnpackSize;
    AppendMtBlock(Blocks, Block);
    Offset := CheckOffset + NativeUInt(CheckSize);
  end;

  if Offset <> IndexOffset then
  begin
    FallbackReason := ldfrUnsupportedLayout;
    Exit;
  end;

  if ObservedBlockCount <> Length(IndexRecords) then
  begin
    FallbackReason := ldfrUnsupportedLayout;
    Exit;
  end;

  Result := True;
end;

function TryPrepareXzMtBlocksFromStream(const Source: TStream; const StartPosition: Int64;
  const CapturePayloads: Boolean;
  out CheckId: Byte; out Blocks: TXzMtBlocks; out IndexRecords: TXzIndexRecords;
  out ObservedBlockCount: Integer; out FallbackReason: TLzma2DecodeFallbackReason;
  out PackedInputSize: UInt64; out StreamEndPosition: Int64): Boolean;
var
  SourceSize: Int64;
  LimitPosition: Int64;
  FooterOffset: Int64;
  Footer: TBytes;
  IndexOffset: Int64;
  IndexSize: NativeUInt;
  IndexSize64: UInt64;
  IndexData: TBytes;
  Offset: Int64;
  FirstByte: Byte;
  Header: TBytes;
  HeaderSize: NativeUInt;
  HeaderPackSize: UInt64;
  HeaderUnpackSize: UInt64;
  EffectivePackSize: UInt64;
  EffectiveUnpackSize: UInt64;
  IndexPackSize: UInt64;
  Lzma2Prop: Byte;
  CheckSize: NativeUInt;
  PayloadOffset: Int64;
  CheckOffset: Int64;
  Pad: Byte;
  J: Integer;
  Block: TXzMtBlock;
  IndexRecord: TXzIndexRecord;
begin
  Result := False;
  FallbackReason := ldfrUnsupportedLayout;
  ObservedBlockCount := 0;
  PackedInputSize := 0;
  StreamEndPosition := StartPosition;
  SetLength(Blocks, 0);
  SetLength(IndexRecords, 0);

  try
    SourceSize := Source.Size;
  except
    FallbackReason := ldfrNonSeekableStream;
    Exit;
  end;
  if SourceSize < StartPosition + XZ_STREAM_HEADER_SIZE + XZ_STREAM_FOOTER_SIZE then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ stream is truncated');

  ValidateHeader(ReadStreamBytesAt(Source, StartPosition, XZ_STREAM_HEADER_SIZE), CheckId);
  CheckSize := XzCheckSizeById(CheckId);
  LimitPosition := XzStreamLimitWithoutPadding(Source, StartPosition, SourceSize);
  if LimitPosition < StartPosition + XZ_STREAM_HEADER_SIZE + XZ_STREAM_FOOTER_SIZE then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ stream is truncated');

  FooterOffset := LimitPosition - XZ_STREAM_FOOTER_SIZE;
  Footer := ReadStreamBytesAt(Source, FooterOffset, XZ_STREAM_FOOTER_SIZE);
  IndexSize64 := UInt64(ReadUi32LE(@Footer[4]) + 1) * 4;
  if IndexSize64 > UInt64(FooterOffset - StartPosition - XZ_STREAM_HEADER_SIZE) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index points before stream header');
  if IndexSize64 > UInt64(High(NativeUInt)) then
    RaiseLzmaError(SZ_ERROR_MEM, 'XZ index is too large for this process');
  IndexSize := NativeUInt(IndexSize64);
  ValidateFooterBytes(Footer, CheckId, IndexSize);
  IndexOffset := FooterOffset - Int64(IndexSize);
  IndexData := ReadStreamBytesAt(Source, IndexOffset, IndexSize);
  ParseIndex(IndexData, 0, IndexSize, IndexRecords);

  Offset := StartPosition + XZ_STREAM_HEADER_SIZE;
  while Offset < IndexOffset do
  begin
    FirstByte := ReadByteAt(Source, Offset);
    if FirstByte = 0 then
      Break;

    HeaderSize := NativeUInt(FirstByte) * 4 + 4;
    Header := ReadStreamBytesAt(Source, Offset, HeaderSize);
    ParseBlockHeaderBytes(Header, HeaderSize, HeaderPackSize, HeaderUnpackSize, Lzma2Prop);
    if ObservedBlockCount >= Length(IndexRecords) then
    begin
      FallbackReason := ldfrUnsupportedLayout;
      Exit;
    end;
    IndexRecord := IndexRecords[ObservedBlockCount];
    Inc(ObservedBlockCount);

    if (UInt64(HeaderSize) > IndexRecord.UnpaddedSize) or
      (UInt64(CheckSize) > IndexRecord.UnpaddedSize - UInt64(HeaderSize)) then
    begin
      FallbackReason := ldfrUnsupportedLayout;
      Exit;
    end;
    IndexPackSize := IndexRecord.UnpaddedSize - UInt64(HeaderSize) - UInt64(CheckSize);
    if HeaderPackSize = UInt64(-1) then
      EffectivePackSize := IndexPackSize
    else
    begin
      EffectivePackSize := HeaderPackSize;
      if EffectivePackSize <> IndexPackSize then
      begin
        FallbackReason := ldfrUnsupportedLayout;
        Exit;
      end;
    end;
    if HeaderUnpackSize = UInt64(-1) then
      EffectiveUnpackSize := IndexRecord.UnpackSize
    else
    begin
      EffectiveUnpackSize := HeaderUnpackSize;
      if EffectiveUnpackSize <> IndexRecord.UnpackSize then
      begin
        FallbackReason := ldfrUnsupportedLayout;
        Exit;
      end;
    end;

    if EffectivePackSize > UInt64(High(NativeUInt)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'XZ block packed size is too large for this process');
    PayloadOffset := Offset + Int64(HeaderSize);
    if PayloadOffset > IndexOffset then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload starts past index');
    if EffectivePackSize > UInt64(IndexOffset - PayloadOffset) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload is truncated');
    Pad := XzPadSize(EffectivePackSize);
    if UInt64(Pad) > UInt64(IndexOffset - PayloadOffset) - EffectivePackSize then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload padding is truncated');
    CheckOffset := PayloadOffset + Int64(EffectivePackSize) + Pad;
    if (CheckOffset > IndexOffset) or (CheckSize > NativeUInt(IndexOffset - CheckOffset)) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block payload is truncated');
    for J := 0 to Pad - 1 do
      if ReadByteAt(Source, PayloadOffset + Int64(EffectivePackSize) + J) <> 0 then
        RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block padding is not zero');

    if CapturePayloads then
    begin
      Block.RawData := ReadStreamBytesAt(Source, PayloadOffset, NativeUInt(EffectivePackSize));
      Block.ExpectedDigest := ReadStreamBytesAt(Source, CheckOffset, CheckSize);
    end
    else
    begin
      SetLength(Block.RawData, 0);
      SetLength(Block.ExpectedDigest, 0);
    end;
    Block.Lzma2Prop := Lzma2Prop;
    Block.PayloadOffset := PayloadOffset;
    Block.CheckOffset := CheckOffset;
    Block.CheckSize := CheckSize;
    Block.HeaderSize := HeaderSize;
    Block.PackSize := EffectivePackSize;
    Block.HeaderUnpackSize := EffectiveUnpackSize;
    AppendMtBlock(Blocks, Block);
    if EffectivePackSize > High(UInt64) - PackedInputSize then
      RaiseLzmaError(SZ_ERROR_MEM, 'XZ MT decode packed size overflow');
    Inc(PackedInputSize, EffectivePackSize);
    Offset := CheckOffset + Int64(CheckSize);
  end;

  if Offset <> IndexOffset then
  begin
    FallbackReason := ldfrUnsupportedLayout;
    Exit;
  end;
  if ObservedBlockCount <> Length(IndexRecords) then
  begin
    FallbackReason := ldfrUnsupportedLayout;
    Exit;
  end;

  StreamEndPosition := LimitPosition;
  Result := True;
end;

function DecodeXzMt(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent): Boolean;
var
  StartPosition: Int64;
  CheckId: Byte;
  Blocks: TXzMtBlocks;
  Units: TArray<TBytes>;
  OutputSizes: TArray<UInt64>;
  IndexRecords: TXzIndexRecords;
  ActualRecords: TXzIndexRecords;
  RecordInfo: TXzIndexRecord;
  FallbackReason: TLzma2DecodeFallbackReason;
  ObservedBlockCount: Integer;
  Workers: Integer;
  DecodeOptions: TLzma2Options;
  MaxBlockOutputSize: UInt64;
  MaxBlockDictionarySize: UInt64;
  TotalOutputSize: UInt64;
  InTotal: UInt64;
  OutTotal: UInt64;
  CancelRequested: Integer;
  WorkerProgress: TLzma2ProgressEvent;
  WaitProc: TLzmaMtWaitProc;
  PackedInputSize: UInt64;
  StreamEndPosition: Int64;
  ReadLock: TObject;
  I: Integer;

  function TryPrepareMtBlocks(const CapturePayloads: Boolean): Boolean;
  begin
    try
      Result := TryPrepareXzMtBlocksFromStream(Source, StartPosition, CapturePayloads,
        CheckId, Blocks, IndexRecords,
        ObservedBlockCount, FallbackReason, PackedInputSize, StreamEndPosition);
    except
      on E: ELzmaError do
      begin
        if E.ResultCode <> SZ_ERROR_ARCHIVE then
          raise;
        SetLength(Blocks, 0);
        SetLength(IndexRecords, 0);
        ObservedBlockCount := 0;
        PackedInputSize := 0;
        StreamEndPosition := StartPosition;
        FallbackReason := ldfrUnsupportedLayout;
        Result := False;
      end;
    end;
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

  if not TryPrepareMtBlocks(False) then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SetLzma2DecodeDiagnostics(Options, 1, ObservedBlockCount, False, FallbackReason);
    Exit;
  end;

  if Length(Blocks) <= 1 then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SetLzma2DecodeDiagnostics(Options, 1, Length(Blocks), False, ldfrSingleIndependentUnit);
    Exit;
  end;

  Workers := EffectiveThreadCount(Options);
  if Workers > Length(Blocks) then
    Workers := Length(Blocks);
  MaxBlockOutputSize := 0;
  MaxBlockDictionarySize := 0;
  for I := 0 to High(Blocks) do
  begin
    if Blocks[I].HeaderUnpackSize > MaxBlockOutputSize then
      MaxBlockOutputSize := Blocks[I].HeaderUnpackSize;
    if Lzma2DictionaryFromProperty(Blocks[I].Lzma2Prop) > MaxBlockDictionarySize then
      MaxBlockDictionarySize := Lzma2DictionaryFromProperty(Blocks[I].Lzma2Prop);
  end;

  SetLength(Units, Length(Blocks));
  SetLength(OutputSizes, Length(Blocks));
  TotalOutputSize := 0;
  for I := 0 to High(Blocks) do
  begin
    Units[I] := Blocks[I].RawData;
    OutputSizes[I] := Blocks[I].HeaderUnpackSize;
    if OutputSizes[I] > High(UInt64) - TotalOutputSize then
      RaiseLzmaError(SZ_ERROR_MEM, 'XZ MT decode output size overflow');
    Inc(TotalOutputSize, OutputSizes[I]);
  end;
  if not FitsMtDecodeMemoryLimit(PackedInputSize, TotalOutputSize, MaxBlockDictionarySize, Workers,
    Options.MemoryLimit) then
  begin
    RestoreStreamPosition(Source, StartPosition);
    SetLzma2DecodeDiagnostics(Options, 1, Length(Blocks), False, ldfrMemoryLimit);
    Exit;
  end;

  for I := 0 to High(Blocks) do
    SetLength(Units[I], 0);

  DecodeOptions := Options;
  DecodeOptions.ThreadCount := 1;
  DecodeOptions.DecodeDiagnostics := nil;
  CancelRequested := 0;
  SetLength(ActualRecords, 0);
  InTotal := XZ_STREAM_HEADER_SIZE;
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
  ReadLock := TObject.Create;
  try
  SetLzma2DecodeDiagnostics(Options, Workers, Length(Blocks), True, ldfrNone, False);
  TLzmaMtDecode.DecodeOrderedToStream(
    Units,
    OutputSizes,
    Destination,
    Workers,
    procedure(const Index: Integer; const Input: TBytes; const OutputSlice: TStream)
    var
      InStream: TBytesStream;
      BlockOptions: TLzma2Options;
      CheckedOutput: TCheckedWriteStream;
      ExpectedDigest: TBytes;
      Digest: TBytes;
      Payload: TBytes;
    begin
      BlockOptions := DecodeOptions;
      BlockOptions.DictionarySize := Lzma2DictionaryFromProperty(Blocks[Index].Lzma2Prop);
      if Length(Input) <> 0 then
        Payload := Input
      else
      begin
        TMonitor.Enter(ReadLock);
        try
          Payload := ReadStreamBytesAt(Source, Blocks[Index].PayloadOffset, NativeUInt(Blocks[Index].PackSize));
          ExpectedDigest := ReadStreamBytesAt(Source, Blocks[Index].CheckOffset, Blocks[Index].CheckSize);
        finally
          TMonitor.Exit(ReadLock);
        end;
      end;
      if Length(ExpectedDigest) = 0 then
        ExpectedDigest := Blocks[Index].ExpectedDigest;
      InStream := TBytesStream.Create(Payload);
      CheckedOutput := TCheckedWriteStream.Create(OutputSlice, CheckId);
      try
        TLzma2Decoder.DecodeRaw(InStream, CheckedOutput, BlockOptions, WorkerProgress);
        Digest := CheckedOutput.Digest;
        if not BytesEqualAt(Digest, ExpectedDigest) then
          RaiseLzmaError(SZ_ERROR_CRC, 'XZ block check mismatch');
      finally
        CheckedOutput.Free;
        InStream.Free;
      end;
    end,
    WaitProc,
    procedure(const Index: Integer)
    begin
      RecordInfo.UnpaddedSize := Blocks[Index].HeaderSize + Blocks[Index].PackSize +
        UInt64(Blocks[Index].CheckSize);
      RecordInfo.UnpackSize := OutputSizes[Index];
      AppendIndexRecord(ActualRecords, RecordInfo);

      Inc(InTotal, Blocks[Index].HeaderSize + Blocks[Index].PackSize + UInt64(XzPadSize(Blocks[Index].PackSize)) +
        UInt64(Blocks[Index].CheckSize));
      Inc(OutTotal, OutputSizes[Index]);
      ReportProgress(Progress, InTotal, OutTotal);
    end,
    procedure
    begin
      TInterlocked.Exchange(CancelRequested, 1);
    end);
  finally
    ReadLock.Free;
  end;

  if not IndexRecordsEqual(IndexRecords, ActualRecords) then
    RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index records do not match decoded blocks');

  Source.Position := StreamEndPosition;
  Result := True;
end;

class procedure TLzmaXz.Encode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  Normalized: TLzma2Options;
  CheckedSource: TCheckedReadStream;
  CountingOutput: TCountingWriteStream;
  Header: TBytes;
  BlockHeader: TBytes;
  Digest: TBytes;
  IndexFooter: TBytes;
  CheckId: Byte;
  Info: TLzma2DictionaryInfo;
  Pad: Byte;
  PackSize: UInt64;
  UnpackSize: UInt64;
  UnpaddedSize: UInt64;
  InTotal: UInt64;
  OutTotal: UInt64;
  RawProgress: TLzma2ProgressEvent;

  procedure EncodeMultiBlock;
  var
    BlockSize: Integer;
    Chunk: TBytes;
    Raw: TBytes;
    BlockHeader: TBytes;
    BlockDigest: TBytes;
    BlockPad: Byte;
    Records: TXzIndexRecords;
    RecordInfo: TXzIndexRecord;
    RawOptions: TLzma2Options;
    RawDiagnostics: TLzma2EncodeDiagnostics;
    Profile: TLzmaEncoderProfile;
    CheckState: TXzCheckState;
    ReadTotal: Integer;
    ReadCount: Integer;
    TotalCopyFastPathCount: Integer;
    TotalFullOptimumDecisionCount: UInt64;
    TotalIncompressibleFastPathCount: Integer;
  begin
    if Normalized.XzBlockSize > UInt64(High(Integer)) then
      RaiseLzmaError(SZ_ERROR_MEM, 'XZ block size is too large for this process');
    if Normalized.XzBlockSize = 0 then
      RaiseLzmaError(SZ_ERROR_PARAM, 'XZ block size must be non-zero for multi-block encode');

    BlockSize := Integer(Normalized.XzBlockSize);
    if BlockSize < 4096 then
      BlockSize := 4096;
    RawOptions := Normalized;
    RawOptions.Container := lcRawLzma2;
    RawOptions.ThreadCount := 1;
    RawOptions.DecodeDiagnostics := nil;
    if Normalized.EncodeDiagnostics <> nil then
      RawOptions.EncodeDiagnostics := @RawDiagnostics;

    Profile := TLzmaRawEncoder.NormalizeProfile(Normalized.Level, Info.NormalizedSize);
    case Normalized.MatchFinderProfile of
      lmfpHashChain4,
      lmfpHashChain5,
      lmfpBinaryTree4:
        Profile.MatchFinderProfile := Normalized.MatchFinderProfile;
    end;
    if Normalized.FastBytes <> 0 then
      Profile.FastBytes := Normalized.FastBytes;
    if Normalized.CutValue <> 0 then
      Profile.CutValue := Normalized.CutValue;
    Profile.ParserMode := Normalized.ParserMode;

    SetLength(Records, 0);
    TotalCopyFastPathCount := 0;
    TotalFullOptimumDecisionCount := 0;
    TotalIncompressibleFastPathCount := 0;
    while True do
    begin
      SetLength(Chunk, BlockSize);
      ReadTotal := 0;
      while ReadTotal < BlockSize do
      begin
        ReadCount := ReadAvailable(Source, Chunk[ReadTotal], BlockSize - ReadTotal);
        if ReadCount = 0 then
          Break;
        Inc(ReadTotal, ReadCount);
      end;
      if ReadTotal = 0 then
        Break;
      SetLength(Chunk, ReadTotal);

      CheckState.Init(CheckId);
      if ReadTotal > 0 then
        CheckState.Update(Chunk[0], ReadTotal);
      if RawOptions.EncodeDiagnostics <> nil then
        RawDiagnostics := Default(TLzma2EncodeDiagnostics);
      Raw := TLzma2Encoder.EncodeRawBytes(Chunk, RawOptions);
      if RawOptions.EncodeDiagnostics <> nil then
      begin
        Inc(TotalCopyFastPathCount, RawDiagnostics.CopyFastPathCount);
        Inc(TotalFullOptimumDecisionCount, RawDiagnostics.FullOptimumDecisionCount);
        Inc(TotalIncompressibleFastPathCount, RawDiagnostics.IncompressibleFastPathCount);
      end;
      BlockDigest := CheckState.Finish;
      BlockHeader := BuildSizedBlockHeader(Info.PropertyByte, UInt64(Length(Raw)), UInt64(ReadTotal));

      WriteBytes(Destination, BlockHeader);
      WriteBytes(Destination, Raw);
      BlockPad := XzPadSize(UInt64(Length(Raw)));
      WriteZeroes(Destination, BlockPad);
      WriteBytes(Destination, BlockDigest);

      Inc(InTotal, UInt64(ReadTotal));
      Inc(OutTotal, UInt64(Length(BlockHeader)) + UInt64(Length(Raw)) + UInt64(BlockPad) +
        UInt64(Length(BlockDigest)));
      RecordInfo.UnpaddedSize := UInt64(Length(BlockHeader)) + UInt64(Length(Raw)) +
        UInt64(Length(BlockDigest));
      RecordInfo.UnpackSize := UInt64(ReadTotal);
      AppendIndexRecord(Records, RecordInfo);
      ReportProgress(Progress, InTotal, OutTotal);
    end;

    IndexFooter := BuildIndexRecordsAndFooter(Records, CheckId);
    WriteBytes(Destination, IndexFooter);
    Inc(OutTotal, UInt64(Length(IndexFooter)));
    ReportProgress(Progress, InTotal, OutTotal);

    if Normalized.EncodeDiagnostics <> nil then
    begin
      if Length(Records) > 0 then
        Normalized.EncodeDiagnostics^ := RawDiagnostics;
      Normalized.EncodeDiagnostics^.RequestedThreadCount := Normalized.ThreadCount;
      Normalized.EncodeDiagnostics^.ActualThreadCount := 1;
      Normalized.EncodeDiagnostics^.BatchCount := Length(Records);
      Normalized.EncodeDiagnostics^.BlockCount := Length(Records);
      Normalized.EncodeDiagnostics^.FastBytes := Profile.FastBytes;
      Normalized.EncodeDiagnostics^.NiceLen := Profile.FastBytes;
      Normalized.EncodeDiagnostics^.CutValue := Profile.CutValue;
      Normalized.EncodeDiagnostics^.XzBlockSize := Normalized.XzBlockSize;
      Normalized.EncodeDiagnostics^.ParserMode := Profile.ParserMode;
      Normalized.EncodeDiagnostics^.MatchFinderProfile := Profile.MatchFinderProfile;
      Normalized.EncodeDiagnostics^.NumHashBytes := Profile.NumHashBytes;
      Normalized.EncodeDiagnostics^.OptimumParserEnabled :=
        TotalFullOptimumDecisionCount > 0;
      Normalized.EncodeDiagnostics^.FullOptimumDecisionCount := TotalFullOptimumDecisionCount;
      Normalized.EncodeDiagnostics^.CopyFastPathCount := TotalCopyFastPathCount;
      Normalized.EncodeDiagnostics^.IncompressibleFastPathCount := TotalIncompressibleFastPathCount;
      Normalized.EncodeDiagnostics^.FallbackReason := 'none';
    end;
  end;

begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  Normalized := TLzma2Encoder.NormalizeOptions(Options);
  Info := TLzma2Encoder.DictionaryInfo(Normalized);
  CheckId := XzCheckId(Normalized.Check);

  Header := BuildStreamHeader(CheckId);
  WriteBytes(Destination, Header);
  InTotal := 0;
  OutTotal := Length(Header);

  if Normalized.XzBlockSize <> 0 then
  begin
    EncodeMultiBlock;
    Exit;
  end;

  BlockHeader := BuildStreamingBlockHeader(Info.PropertyByte);
  WriteBytes(Destination, BlockHeader);
  Inc(OutTotal, UInt64(Length(BlockHeader)));

  CheckedSource := TCheckedReadStream.Create(Source, CheckId);
  CountingOutput := TCountingWriteStream.Create(Destination);
  RawProgress :=
    procedure(const InBytes: UInt64; const RawOutBytes: UInt64; var Cancel: Boolean)
    begin
      ReportProgress(Progress, InBytes, UInt64(Length(Header)) + UInt64(Length(BlockHeader)) + RawOutBytes);
    end;
  try
    TLzma2Encoder.EncodeRaw(CheckedSource, CountingOutput, Normalized, RawProgress);
    PackSize := CountingOutput.BytesWritten;
    UnpackSize := CheckedSource.BytesRead;
    Digest := CheckedSource.Digest;
  finally
    CountingOutput.Free;
    CheckedSource.Free;
  end;

  Inc(OutTotal, PackSize);
  Pad := XzPadSize(PackSize);
  WriteZeroes(Destination, Pad);
  Inc(OutTotal, Pad);
  WriteBytes(Destination, Digest);
  Inc(OutTotal, UInt64(Length(Digest)));

  UnpaddedSize := UInt64(Length(BlockHeader)) + PackSize + UInt64(Length(Digest));
  IndexFooter := BuildIndexAndFooter(UnpaddedSize, UnpackSize, CheckId);
  WriteBytes(Destination, IndexFooter);
  Inc(OutTotal, UInt64(Length(IndexFooter)));
  ReportProgress(Progress, UnpackSize, OutTotal);
end;

class procedure TLzmaXz.Decode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  StreamHeader: TBytes;
  Footer: TBytes;
  CheckId: Byte;
  Check: TLzma2Check;
  IndexSize: NativeUInt;
  IndexRecords: TXzIndexRecords;
  ActualRecords: TXzIndexRecords;
  RecordInfo: TXzIndexRecord;
  BlockHeader: TBytes;
  HeaderSize: NativeUInt;
  HeaderPackSize: UInt64;
  HeaderUnpackSize: UInt64;
  Lzma2Prop: Byte;
  CheckSize: NativeUInt;
  PackSize: UInt64;
  Pad: Byte;
  Digest: TBytes;
  ExpectedDigest: TBytes;
  DecodeOptions: TLzma2Options;
  BlockOutput: TCheckedWriteStream;
  LimitedInput: TLimitedReadStream;
  FirstByte: Byte;
  ConsumedBytes: UInt64;
  ProducedBytes: UInt64;
  InTotal: UInt64;
  OutTotal: UInt64;
  BlockInStart: UInt64;
  BlockOutStart: UInt64;
  RawProgress: TLzma2ProgressEvent;
  J: Integer;
  PaddingSize: NativeUInt;
  ReadCount: Integer;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  if DecodeXzMt(Source, Destination, Options, Progress) then
    Exit;

  SetLength(StreamHeader, XZ_STREAM_HEADER_SIZE);
  ReadExact(Source, StreamHeader[0], Length(StreamHeader));
  InTotal := Length(StreamHeader);
  OutTotal := 0;

  while True do
  begin
    ValidateHeader(StreamHeader, CheckId);
    if not XzCheckFromId(CheckId, Check) then
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported XZ check type');
    CheckSize := XzCheckSizeById(CheckId);
    SetLength(ActualRecords, 0);

    while True do
    begin
      FirstByte := ReadByteRequired(Source);
      Inc(InTotal);
      if FirstByte = 0 then
        Break;

      HeaderSize := NativeUInt(FirstByte) * 4 + 4;
      if (HeaderSize < 8) or (HeaderSize > XZ_BLOCK_HEADER_SIZE_MAX) then
        RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Invalid XZ block header size');
      SetLength(BlockHeader, HeaderSize);
      BlockHeader[0] := FirstByte;
      ReadExact(Source, BlockHeader[1], HeaderSize - 1);
      Inc(InTotal, HeaderSize - 1);
      ParseBlockHeaderBytes(BlockHeader, HeaderSize, HeaderPackSize, HeaderUnpackSize, Lzma2Prop);

      DecodeOptions := Options;
      DecodeOptions.DictionarySize := Lzma2DictionaryFromProperty(Lzma2Prop);
      BlockInStart := InTotal;
      BlockOutStart := OutTotal;
      RawProgress :=
        procedure(const RawInBytes: UInt64; const RawOutBytes: UInt64; var Cancel: Boolean)
        begin
          ReportProgress(Progress, BlockInStart + RawInBytes, BlockOutStart + RawOutBytes);
        end;
      BlockOutput := TCheckedWriteStream.Create(Destination, CheckId);
      try
        if HeaderPackSize = UInt64(-1) then
        begin
          TLzma2Decoder.DecodeRawEmbedded(Source, BlockOutput, DecodeOptions,
            ConsumedBytes, ProducedBytes, RawProgress);
          PackSize := ConsumedBytes;
        end
        else
        begin
          LimitedInput := TLimitedReadStream.Create(Source, HeaderPackSize);
          try
            TLzma2Decoder.DecodeRawEmbedded(LimitedInput, BlockOutput, DecodeOptions,
              ConsumedBytes, ProducedBytes, RawProgress);
            if LimitedInput.Position64 <> HeaderPackSize then
              RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes inside XZ block payload');
          finally
            LimitedInput.Free;
          end;
          PackSize := HeaderPackSize;
        end;
        Inc(InTotal, PackSize);

        if PackSize > UInt64(High(NativeUInt)) then
          RaiseLzmaError(SZ_ERROR_MEM, 'XZ block packed size is too large for this process');
        if (HeaderUnpackSize <> UInt64(-1)) and (HeaderUnpackSize <> ProducedBytes) then
          RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block header unpack size does not match decoded data');
        ExpectedDigest := BlockOutput.Digest;
      finally
        BlockOutput.Free;
      end;

      Pad := XzPadSize(PackSize);
      for J := 0 to Pad - 1 do
        if ReadByteRequired(Source) <> 0 then
          RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ block padding is not zero');
      Inc(InTotal, Pad);

      SetLength(Digest, CheckSize);
      if CheckSize <> 0 then
        ReadExact(Source, Digest[0], CheckSize);
      Inc(InTotal, CheckSize);

      if not BytesEqualAt(ExpectedDigest, Digest) then
        RaiseLzmaError(SZ_ERROR_CRC, 'XZ block check mismatch');

      Inc(OutTotal, ProducedBytes);
      RecordInfo.UnpaddedSize := UInt64(HeaderSize) + PackSize + UInt64(CheckSize);
      RecordInfo.UnpackSize := ProducedBytes;
      AppendIndexRecord(ActualRecords, RecordInfo);
      ReportProgress(Progress, InTotal, OutTotal);
    end;

    ParseIndexForward(Source, IndexRecords, IndexSize);
    Inc(InTotal, IndexSize - 1);
    if not IndexRecordsEqual(IndexRecords, ActualRecords) then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ index records do not match decoded blocks');

    SetLength(Footer, XZ_STREAM_FOOTER_SIZE);
    ReadExact(Source, Footer[0], Length(Footer));
    Inc(InTotal, Length(Footer));
    ValidateFooterBytes(Footer, CheckId, IndexSize);

    PaddingSize := 0;
    while True do
    begin
      ReadCount := ReadAvailable(Source, FirstByte, 1);
      if ReadCount = 0 then
      begin
        if (PaddingSize and 3) <> 0 then
          RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ stream padding size is not a multiple of 4');
        ReportProgress(Progress, InTotal, OutTotal);
        Exit;
      end;
      Inc(InTotal);
      if FirstByte = 0 then
      begin
        Inc(PaddingSize);
        if (PaddingSize and (XZ_PADDING_PROGRESS_GRANULARITY - 1)) = 0 then
          ReportProgress(Progress, InTotal, OutTotal);
        Continue;
      end
      else
        Break;
    end;

    if (PaddingSize and 3) <> 0 then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'XZ stream padding size is not a multiple of 4');
    if FirstByte <> XZ_SIG[0] then
      RaiseLzmaError(SZ_ERROR_ARCHIVE, 'Trailing bytes after XZ stream footer');
    StreamHeader[0] := FirstByte;
    ReadExact(Source, StreamHeader[1], XZ_STREAM_HEADER_SIZE - 1);
    Inc(InTotal, XZ_STREAM_HEADER_SIZE - 1);
  end;
end;

end.
