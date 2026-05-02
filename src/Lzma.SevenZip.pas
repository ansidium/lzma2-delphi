unit Lzma.SevenZip;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.Types;

type
  TLzma7zEncodeMethod = (zemLzma2, zemLzma);

  TLzma7zEntry = record
    FileName: string;
    Size: UInt64;
    HasCrc: Boolean;
    Crc: UInt32;
    HasStream: Boolean;
    IsDirectory: Boolean;
    IsEmptyStream: Boolean;
    HasCreationTime: Boolean;
    CreationTime: UInt64;
    HasAccessTime: Boolean;
    AccessTime: UInt64;
    HasModifiedTime: Boolean;
    ModifiedTime: UInt64;
    HasAttributes: Boolean;
    Attributes: UInt32;
  end;

  TLzma7zEncodeEntry = record
    FileName: string;
    IsDirectory: Boolean;
    HasCreationTime: Boolean;
    CreationTime: UInt64;
    HasAccessTime: Boolean;
    AccessTime: UInt64;
    HasModifiedTime: Boolean;
    ModifiedTime: UInt64;
    HasAttributes: Boolean;
    Attributes: UInt32;
  end;

  TLzma7zOpenEntryStream = reference to function(const Entry: TLzma7zEntry): TStream;
  TLzma7zCreateEntryStream = reference to function(const Entry: TLzma7zEncodeEntry;
    const EntryIndex: Integer): TStream;

  TLzma7z = class
  public
    class procedure Encode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure EncodeEntries(const Entries: TArray<TLzma7zEncodeEntry>;
      const CreateEntryStream: TLzma7zCreateEntryStream; Destination: TStream;
      const Options: TLzma2Options; const Method: TLzma7zEncodeMethod = zemLzma2;
      const Progress: TLzma2ProgressEvent = nil); static;
    class procedure Decode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
      const Progress: TLzma2ProgressEvent = nil); static;
    class function List(Source: TStream): TArray<TLzma7zEntry>; static;
    class procedure ExtractAll(Source: TStream; const OpenEntry: TLzma7zOpenEntryStream;
      const Options: TLzma2Options; const Progress: TLzma2ProgressEvent = nil); static;
    class function ReadSingleFileName(Source: TStream): string; static;
  end;

implementation

uses
  Lzma.Decoder,
  Lzma.Errors,
  Lzma.Lzma,
  Lzma.Streams,
  Lzma.XzCrc,
  Lzma2.Decoder,
  Lzma2.Encoder;

const
  SEVENZ_SIGNATURE_SIZE = 6;
  SEVENZ_SIGNATURE_HEADER_SIZE = 32;
  LZMA_STANDALONE_HEADER_SIZE = LZMA_PROPS_SIZE + 8;

  SEVENZ_NID_END = $00;
  SEVENZ_NID_HEADER = $01;
  SEVENZ_NID_MAIN_STREAMS_INFO = $04;
  SEVENZ_NID_FILES_INFO = $05;
  SEVENZ_NID_PACK_INFO = $06;
  SEVENZ_NID_UNPACK_INFO = $07;
  SEVENZ_NID_SUB_STREAMS_INFO = $08;
  SEVENZ_NID_SIZE = $09;
  SEVENZ_NID_CRC = $0A;
  SEVENZ_NID_FOLDER = $0B;
  SEVENZ_NID_CODERS_UNPACK_SIZE = $0C;
  SEVENZ_NID_NUM_UNPACK_STREAM = $0D;
  SEVENZ_NID_EMPTY_STREAM = $0E;
  SEVENZ_NID_EMPTY_FILE = $0F;
  SEVENZ_NID_ANTI = $10;
  SEVENZ_NID_NAME = $11;
  SEVENZ_NID_CREATION_TIME = $12;
  SEVENZ_NID_ACCESS_TIME = $13;
  SEVENZ_NID_MODIFICATION_TIME = $14;
  SEVENZ_NID_WIN_ATTRIBUTES = $15;
  SEVENZ_NID_ENCODED_HEADER = $17;

  SEVENZ_METHOD_LZMA2 = $21;
  SEVENZ_METHOD_LZMA: array[0..2] of Byte = ($03, $01, $01);

  SEVENZ_SIGNATURE: array[0..SEVENZ_SIGNATURE_SIZE - 1] of Byte =
    ($37, $7A, $BC, $AF, $27, $1C);

type
  TSevenZipCoderMethod = (szcmNone, szcmLzma, szcmLzma2);

  TSevenZipDigestVector = record
    Defined: TArray<Boolean>;
    Values: TArray<UInt32>;
  end;

  TSevenZipPackStreamInfo = record
    Offset: UInt64;
    Size: UInt64;
    Crc: UInt32;
    HasCrc: Boolean;
  end;

  TSevenZipFolderInfo = record
    PackStreamIndex: Integer;
    CoderMethod: TSevenZipCoderMethod;
    CoderProperties: TBytes;
    DictionaryProperty: Byte;
    UnpackSize: UInt64;
    Crc: UInt32;
    HasCrc: Boolean;
    SubStreamCount: Integer;
  end;

  TSevenZipSubStreamInfo = record
    FolderIndex: Integer;
    OffsetInFolder: UInt64;
    Size: UInt64;
    Crc: UInt32;
    HasCrc: Boolean;
  end;

  TSevenZipFileInfo = record
    Entry: TLzma7zEntry;
    SubStreamIndex: Integer;
  end;

  TSevenZipEncodedFileInfo = record
    Entry: TLzma7zEncodeEntry;
    HasStream: Boolean;
    UnpackSize: UInt64;
    UnpackCrc: UInt32;
    PackSize: UInt64;
    PackCrc: UInt32;
    CoderMethod: TSevenZipCoderMethod;
    CoderProperties: TBytes;
  end;

  TSevenZipArchiveInfo = record
    PackPos: UInt64;
    PackStreams: TArray<TSevenZipPackStreamInfo>;
    Folders: TArray<TSevenZipFolderInfo>;
    SubStreams: TArray<TSevenZipSubStreamInfo>;
    Files: TArray<TSevenZipFileInfo>;
    ArchiveEndPosition: Int64;
  end;

  TSevenZipCrcReadStream = class(TStream)
  private
    FBase: TStream;
    FCrc: UInt32;
    FBytesRead: UInt64;
    function GetDigest: UInt32;
  public
    constructor Create(const Base: TStream);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Read(var Buffer; Count: NativeInt): NativeInt; overload; override;
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
{$ENDIF}
    property BytesRead: UInt64 read FBytesRead;
    property Digest: UInt32 read GetDigest;
  end;

  TSevenZipCrcWriteStream = class(TStream)
  private
    FBase: TStream;
    FCrc: UInt32;
    FBytesWritten: UInt64;
    function GetDigest: UInt32;
  public
    constructor Create(const Base: TStream);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Read(var Buffer; Count: NativeInt): NativeInt; overload; override;
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
{$ENDIF}
    property BytesWritten: UInt64 read FBytesWritten;
    property Digest: UInt32 read GetDigest;
  end;

  TSevenZipBoundedReadStream = class(TStream)
  private
    FBase: TStream;
    FRemaining: UInt64;
    FCrc: UInt32;
    FBytesRead: UInt64;
    function GetDigest: UInt32;
  public
    constructor Create(const Base: TStream; const Size: UInt64);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Read(var Buffer; Count: NativeInt): NativeInt; overload; override;
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
{$ENDIF}
    property BytesRead: UInt64 read FBytesRead;
    property Digest: UInt32 read GetDigest;
  end;

procedure AppendByte(var Target: TBytes; const Value: Byte);
var
  OldLen: Integer;
begin
  OldLen := Length(Target);
  SetLength(Target, OldLen + 1);
  Target[OldLen] := Value;
end;

procedure AppendBytes(var Target: TBytes; const Source: TBytes);
var
  OldLen: Integer;
begin
  if Length(Source) = 0 then
    Exit;
  OldLen := Length(Target);
  SetLength(Target, OldLen + Length(Source));
  Move(Source[0], Target[OldLen], Length(Source));
end;

procedure AppendUi32LE(var Target: TBytes; const Value: UInt32);
var
  Bytes: TBytes;
begin
  SetLength(Bytes, SizeOf(UInt32));
  WriteUi32LE(@Bytes[0], Value);
  AppendBytes(Target, Bytes);
end;

procedure AppendUi64LE(var Target: TBytes; const Value: UInt64);
var
  Bytes: TBytes;
begin
  SetLength(Bytes, SizeOf(UInt64));
  WriteUi64LE(@Bytes[0], Value);
  AppendBytes(Target, Bytes);
end;

function SevenZipNumberBytes(const Value: UInt64): TBytes;
begin
  if Value < $80 then
  begin
    SetLength(Result, 1);
    Result[0] := Byte(Value);
  end
  else
  begin
    SetLength(Result, 9);
    Result[0] := $FF;
    WriteUi64LE(@Result[1], Value);
  end;
end;

procedure AppendSevenZipNumber(var Target: TBytes; const Value: UInt64);
begin
  AppendBytes(Target, SevenZipNumberBytes(Value));
end;

procedure AppendSevenZipSignatureAndVersion(var Target: TBytes);
var
  I: Integer;
begin
  for I := 0 to High(SEVENZ_SIGNATURE) do
    AppendByte(Target, SEVENZ_SIGNATURE[I]);
  AppendByte(Target, 0);
  AppendByte(Target, 4);
end;

function Crc32OfBytes(const Data: TBytes): UInt32;
begin
  if Length(Data) = 0 then
    Result := Crc32Calc(nil, 0)
  else
    Result := Crc32Calc(@Data[0], Length(Data));
end;

function ReadHeaderByte(const Data: TBytes; var Offset: NativeUInt): Byte;
begin
  if Offset >= NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of 7z header');
  Result := Data[Offset];
  Inc(Offset);
end;

function ReadHeaderUi32LE(const Data: TBytes; var Offset: NativeUInt): UInt32;
begin
  if Offset + SizeOf(UInt32) > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of 7z CRC field');
  Result := ReadUi32LE(@Data[Offset]);
  Inc(Offset, SizeOf(UInt32));
end;

function ReadHeaderUi64LE(const Data: TBytes; var Offset: NativeUInt): UInt64;
begin
  if Offset + SizeOf(UInt64) > NativeUInt(Length(Data)) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of 7z UInt64 field');
  Result := ReadUi64LE(@Data[Offset]);
  Inc(Offset, SizeOf(UInt64));
end;

function ReadSevenZipNumber(const Data: TBytes; var Offset: NativeUInt): UInt64;
var
  First: Byte;
  Mask: Byte;
  I: Integer;
  Low: UInt64;
  High: UInt64;
begin
  First := ReadHeaderByte(Data, Offset);
  if (First and $80) = 0 then
    Exit(First);

  Low := 0;
  Mask := $80;
  for I := 0 to 7 do
  begin
    if (First and Mask) = 0 then
    begin
      High := UInt64(First and (Mask - 1));
      Exit((High shl (8 * I)) or Low);
    end;
    Low := Low or (UInt64(ReadHeaderByte(Data, Offset)) shl (8 * I));
    Mask := Mask shr 1;
  end;
  Result := Low;
end;

procedure SkipHeaderBytes(const Data: TBytes; var Offset: NativeUInt; const Count: UInt64);
begin
  if Count > UInt64(Length(Data)) - UInt64(Offset) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of 7z property');
  Inc(Offset, NativeUInt(Count));
end;

function ReadHeaderBytes(const Data: TBytes; var Offset: NativeUInt; const Count: UInt64): TBytes;
begin
  if Count > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z property is too large');
  if Count > UInt64(Length(Data)) - UInt64(Offset) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of 7z property');
  SetLength(Result, Integer(Count));
  if Count <> 0 then
    Move(Data[Offset], Result[0], Integer(Count));
  Inc(Offset, NativeUInt(Count));
end;

function SevenZipBitVectorByteCount(const Count: UInt64): UInt64;
begin
  Result := (Count + 7) div 8;
end;

function SevenZipBitVectorIsSet(const Bits: TBytes; const Index: UInt64): Boolean;
var
  ByteIndex: UInt64;
  BitIndex: Byte;
begin
  ByteIndex := Index div 8;
  if ByteIndex > UInt64(High(Integer)) then
    Exit(False);
  if Integer(ByteIndex) >= Length(Bits) then
    Exit(False);
  BitIndex := Byte(Index mod 8);
  Result := (Bits[Integer(ByteIndex)] and ($80 shr BitIndex)) <> 0;
end;

function ReadPlainBitVector(const Data: TBytes; var Offset: NativeUInt; const Count: UInt64): TBytes;
begin
  Result := ReadHeaderBytes(Data, Offset, SevenZipBitVectorByteCount(Count));
end;

function ReadDefinedBitVector(const Data: TBytes; var Offset: NativeUInt; const Count: UInt64): TBytes;
var
  AllDefined: Byte;
  ByteCount: UInt64;
  I: Integer;
  LastBits: Byte;
begin
  ByteCount := SevenZipBitVectorByteCount(Count);
  AllDefined := ReadHeaderByte(Data, Offset);
  if ByteCount > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z bit vector is too large');
  if AllDefined = 0 then
    Exit(ReadHeaderBytes(Data, Offset, ByteCount));

  SetLength(Result, Integer(ByteCount));
  for I := 0 to High(Result) do
    Result[I] := $FF;
  LastBits := Byte(Count and 7);
  if (Length(Result) <> 0) and (LastBits <> 0) then
    Result[High(Result)] := Byte(((1 shl LastBits) - 1) shl (8 - LastBits));
end;

function CountSevenZipDefinedBits(const Bits: TBytes; const Count: UInt64): UInt64;
var
  I: UInt64;
begin
  Result := 0;
  if Count = 0 then
    Exit;
  for I := 0 to Count - 1 do
    if SevenZipBitVectorIsSet(Bits, I) then
      Inc(Result);
end;

procedure ReadDigestVector(const Data: TBytes; var Offset: NativeUInt; const Count: UInt64;
  out Digest: TSevenZipDigestVector);
var
  AllDefined: Byte;
  Bits: Byte;
  I: UInt64;
begin
  Bits := 0;
  if Count > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z digest vector is too large');
  SetLength(Digest.Defined, Integer(Count));
  SetLength(Digest.Values, Integer(Count));
  if Count = 0 then
    Exit;
  AllDefined := ReadHeaderByte(Data, Offset);
  if AllDefined <> 0 then
  begin
    for I := 0 to Count - 1 do
      Digest.Defined[Integer(I)] := True;
  end
  else
  begin
    for I := 0 to Count - 1 do
    begin
      if (I and 7) = 0 then
        Bits := ReadHeaderByte(Data, Offset);
      Digest.Defined[Integer(I)] := (Bits and ($80 shr Byte(I and 7))) <> 0;
    end;
  end;

  for I := 0 to Count - 1 do
    if Digest.Defined[Integer(I)] then
      Digest.Values[Integer(I)] := ReadHeaderUi32LE(Data, Offset);
end;

function DecodeSevenZipName(const Data: TBytes; var Offset: NativeUInt; const Size: UInt64): string;
var
  EndOffset: NativeUInt;
  Code: UInt16;
  FoundTerminator: Boolean;
begin
  Result := '';
  if Size = 0 then
    RaiseLzmaError(SZ_ERROR_DATA, '7z name property is empty');
  if Size > UInt64(Length(Data)) - UInt64(Offset) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of 7z name property');
  if ((Size - 1) and 1) <> 0 then
    RaiseLzmaError(SZ_ERROR_DATA, '7z name property has an odd UTF-16 payload size');
  EndOffset := Offset + NativeUInt(Size);
  if ReadHeaderByte(Data, Offset) <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Out-of-line 7z file names are not supported');
  FoundTerminator := False;
  while Offset + 1 < EndOffset do
  begin
    Code := UInt16(Data[Offset]) or (UInt16(Data[Offset + 1]) shl 8);
    Inc(Offset, 2);
    if Code = 0 then
    begin
      FoundTerminator := True;
      Break;
    end;
    Result := Result + Char(Code);
  end;
  if not FoundTerminator then
    RaiseLzmaError(SZ_ERROR_DATA, '7z name property is missing a null terminator');
  if Offset <> EndOffset then
    RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes in 7z name property');
  Offset := EndOffset;
end;

function DecodeSevenZipNames(const Data: TBytes; var Offset: NativeUInt; const Size: UInt64;
  const Count: UInt64): TArray<string>;
var
  EndOffset: NativeUInt;
  FileIndex: Integer;
  Code: UInt16;
  FoundTerminator: Boolean;
begin
  if Count > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z file count is too large');
  SetLength(Result, Integer(Count));
  if Size = 0 then
    RaiseLzmaError(SZ_ERROR_DATA, '7z name property is empty');
  if Size > UInt64(Length(Data)) - UInt64(Offset) then
    RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of 7z name property');
  if ((Size - 1) and 1) <> 0 then
    RaiseLzmaError(SZ_ERROR_DATA, '7z name property has an odd UTF-16 payload size');
  EndOffset := Offset + NativeUInt(Size);
  if ReadHeaderByte(Data, Offset) <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Out-of-line 7z file names are not supported');

  for FileIndex := 0 to High(Result) do
  begin
    Result[FileIndex] := '';
    FoundTerminator := False;
    while Offset + 1 < EndOffset do
    begin
      Code := UInt16(Data[Offset]) or (UInt16(Data[Offset + 1]) shl 8);
      Inc(Offset, 2);
      if Code = 0 then
      begin
        FoundTerminator := True;
        Break;
      end;
      Result[FileIndex] := Result[FileIndex] + Char(Code);
    end;
    if not FoundTerminator then
      RaiseLzmaError(SZ_ERROR_DATA, '7z name property is missing a null terminator');
  end;
  if Offset <> EndOffset then
    RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes in 7z name property');
  Offset := EndOffset;
end;

function NormalizeArchiveFileName(const Name: string): string;
begin
  Result := ExtractFileName(Name);
  if Result = '' then
    Result := 'data';
end;

function NormalizeSevenZipStoredName(const Name: string; const IsDirectory: Boolean): string;
var
  Part: string;
  Sep: Integer;
  I: Integer;
begin
  Result := StringReplace(Trim(Name), '\', '/', [rfReplaceAll]);
  while (Result <> '') and (Result[1] = '/') do
    Delete(Result, 1, 1);
  while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);

  if Result = '' then
  begin
    if IsDirectory then
      Result := 'directory'
    else
      Result := 'data';
  end;
  if (Length(Result) >= 2) and (Result[2] = ':') then
    RaiseLzmaError(SZ_ERROR_PARAM, '7z entry names must be relative');

  Part := '';
  for I := 1 to Length(Result) + 1 do
  begin
    if (I > Length(Result)) or (Result[I] = '/') then
    begin
      if (Part = '') or (Part = '.') or (Part = '..') then
        RaiseLzmaError(SZ_ERROR_PARAM, '7z entry names must not contain empty or traversal segments');
      Part := '';
    end
    else
      Part := Part + Result[I];
  end;

  Sep := Pos('//', Result);
  if Sep <> 0 then
    RaiseLzmaError(SZ_ERROR_PARAM, '7z entry names must not contain empty segments');
end;

function IsSevenZipLzmaMethod(const MethodId: TBytes): Boolean;
var
  I: Integer;
begin
  Result := Length(MethodId) = Length(SEVENZ_METHOD_LZMA);
  if not Result then
    Exit;
  for I := 0 to High(SEVENZ_METHOD_LZMA) do
    if MethodId[I] <> SEVENZ_METHOD_LZMA[I] then
      Exit(False);
end;

function BuildSevenZipHeader(const FileName: string; const PackSize: UInt64; const PackCrc: UInt32;
  const UnpackSize: UInt64; const UnpackCrc: UInt32; const DictionaryProperty: Byte): TBytes;
var
  NameBytes: TBytes;
begin
  SetLength(Result, 0);
  AppendByte(Result, SEVENZ_NID_HEADER);

  AppendByte(Result, SEVENZ_NID_MAIN_STREAMS_INFO);
  AppendByte(Result, SEVENZ_NID_PACK_INFO);
  AppendSevenZipNumber(Result, 0);
  AppendSevenZipNumber(Result, 1);
  AppendByte(Result, SEVENZ_NID_SIZE);
  AppendSevenZipNumber(Result, PackSize);
  AppendByte(Result, SEVENZ_NID_CRC);
  AppendByte(Result, 1);
  AppendUi32LE(Result, PackCrc);
  AppendByte(Result, SEVENZ_NID_END);

  AppendByte(Result, SEVENZ_NID_UNPACK_INFO);
  AppendByte(Result, SEVENZ_NID_FOLDER);
  AppendSevenZipNumber(Result, 1);
  AppendByte(Result, 0);
  AppendSevenZipNumber(Result, 1);
  AppendByte(Result, $21);
  AppendByte(Result, SEVENZ_METHOD_LZMA2);
  AppendSevenZipNumber(Result, 1);
  AppendByte(Result, DictionaryProperty);
  AppendByte(Result, SEVENZ_NID_CODERS_UNPACK_SIZE);
  AppendSevenZipNumber(Result, UnpackSize);
  AppendByte(Result, SEVENZ_NID_CRC);
  AppendByte(Result, 1);
  AppendUi32LE(Result, UnpackCrc);
  AppendByte(Result, SEVENZ_NID_END);
  AppendByte(Result, SEVENZ_NID_END);

  AppendByte(Result, SEVENZ_NID_FILES_INFO);
  AppendSevenZipNumber(Result, 1);
  NameBytes := TEncoding.Unicode.GetBytes(NormalizeArchiveFileName(FileName) + #0);
  AppendByte(Result, SEVENZ_NID_NAME);
  AppendSevenZipNumber(Result, UInt64(Length(NameBytes)) + 1);
  AppendByte(Result, 0);
  AppendBytes(Result, NameBytes);
  AppendByte(Result, SEVENZ_NID_END);

  AppendByte(Result, SEVENZ_NID_END);
end;

procedure AppendSevenZipCoder(var Target: TBytes; const Method: TSevenZipCoderMethod;
  const Props: TBytes);
begin
  case Method of
    szcmLzma2:
      begin
        AppendByte(Target, $21);
        AppendByte(Target, SEVENZ_METHOD_LZMA2);
      end;
    szcmLzma:
      begin
        AppendByte(Target, $23);
        AppendByte(Target, SEVENZ_METHOD_LZMA[0]);
        AppendByte(Target, SEVENZ_METHOD_LZMA[1]);
        AppendByte(Target, SEVENZ_METHOD_LZMA[2]);
      end;
  else
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z encode folder coder is missing');
  end;
  AppendSevenZipNumber(Target, Length(Props));
  AppendBytes(Target, Props);
end;

function BuildSevenZipEntriesHeader(const Files: TArray<TSevenZipEncodedFileInfo>): TBytes;
var
  NameBytes: TBytes;
  Bits: TBytes;
  PropertyBytes: TBytes;
  I: Integer;
  PackCount: Integer;
  EmptyStreamCount: Integer;
  StreamIndex: Integer;
  EmptyIndex: Integer;
  AllDefined: Boolean;

  procedure SetBit(var Vector: TBytes; const Index: Integer);
  begin
    Vector[Index div 8] := Vector[Index div 8] or Byte($80 shr Byte(Index and 7));
  end;

  function EntryHasTime(const Index: Integer; const Nid: Byte): Boolean;
  begin
    case Nid of
      SEVENZ_NID_CREATION_TIME:
        Result := Files[Index].Entry.HasCreationTime;
      SEVENZ_NID_ACCESS_TIME:
        Result := Files[Index].Entry.HasAccessTime;
      SEVENZ_NID_MODIFICATION_TIME:
        Result := Files[Index].Entry.HasModifiedTime;
    else
      Result := False;
    end;
  end;

  function EntryTimeValue(const Index: Integer; const Nid: Byte): UInt64;
  begin
    case Nid of
      SEVENZ_NID_CREATION_TIME:
        Result := Files[Index].Entry.CreationTime;
      SEVENZ_NID_ACCESS_TIME:
        Result := Files[Index].Entry.AccessTime;
      SEVENZ_NID_MODIFICATION_TIME:
        Result := Files[Index].Entry.ModifiedTime;
    else
      Result := 0;
    end;
  end;

  procedure AppendTimeProperty(const Nid: Byte);
  var
    J: Integer;
    K: Integer;
  begin
    for J := 0 to High(Files) do
      if EntryHasTime(J, Nid) then
      begin
        SetLength(PropertyBytes, 0);
        AllDefined := True;
        for K := 0 to High(Files) do
          if not EntryHasTime(K, Nid) then
          begin
            AllDefined := False;
            Break;
          end;
        if AllDefined then
          AppendByte(PropertyBytes, 1)
        else
        begin
          AppendByte(PropertyBytes, 0);
          SetLength(Bits, (Length(Files) + 7) div 8);
          if Length(Bits) <> 0 then
            FillChar(Bits[0], Length(Bits), 0);
          for K := 0 to High(Files) do
            if EntryHasTime(K, Nid) then
              SetBit(Bits, K);
          AppendBytes(PropertyBytes, Bits);
        end;
        AppendByte(PropertyBytes, 0);
        for K := 0 to High(Files) do
          if EntryHasTime(K, Nid) then
            AppendUi64LE(PropertyBytes, EntryTimeValue(K, Nid));
        AppendByte(Result, Nid);
        AppendSevenZipNumber(Result, Length(PropertyBytes));
        AppendBytes(Result, PropertyBytes);
        Break;
      end;
  end;

begin
  SetLength(Result, 0);
  AppendByte(Result, SEVENZ_NID_HEADER);

  PackCount := 0;
  EmptyStreamCount := 0;
  for I := 0 to High(Files) do
    if Files[I].HasStream then
      Inc(PackCount)
    else
      Inc(EmptyStreamCount);

  if PackCount <> 0 then
  begin
    AppendByte(Result, SEVENZ_NID_MAIN_STREAMS_INFO);
    AppendByte(Result, SEVENZ_NID_PACK_INFO);
    AppendSevenZipNumber(Result, 0);
    AppendSevenZipNumber(Result, PackCount);
    AppendByte(Result, SEVENZ_NID_SIZE);
    for I := 0 to High(Files) do
      if Files[I].HasStream then
        AppendSevenZipNumber(Result, Files[I].PackSize);
    AppendByte(Result, SEVENZ_NID_CRC);
    AppendByte(Result, 1);
    for I := 0 to High(Files) do
      if Files[I].HasStream then
        AppendUi32LE(Result, Files[I].PackCrc);
    AppendByte(Result, SEVENZ_NID_END);

    AppendByte(Result, SEVENZ_NID_UNPACK_INFO);
    AppendByte(Result, SEVENZ_NID_FOLDER);
    AppendSevenZipNumber(Result, PackCount);
    AppendByte(Result, 0);
    for I := 0 to High(Files) do
      if Files[I].HasStream then
      begin
        AppendSevenZipNumber(Result, 1);
        AppendSevenZipCoder(Result, Files[I].CoderMethod, Files[I].CoderProperties);
      end;
    AppendByte(Result, SEVENZ_NID_CODERS_UNPACK_SIZE);
    for I := 0 to High(Files) do
      if Files[I].HasStream then
        AppendSevenZipNumber(Result, Files[I].UnpackSize);
    AppendByte(Result, SEVENZ_NID_CRC);
    AppendByte(Result, 1);
    for I := 0 to High(Files) do
      if Files[I].HasStream then
        AppendUi32LE(Result, Files[I].UnpackCrc);
    AppendByte(Result, SEVENZ_NID_END);
    AppendByte(Result, SEVENZ_NID_END);
  end;

  AppendByte(Result, SEVENZ_NID_FILES_INFO);
  AppendSevenZipNumber(Result, Length(Files));

  SetLength(NameBytes, 0);
  for I := 0 to High(Files) do
    AppendBytes(NameBytes, TEncoding.Unicode.GetBytes(Files[I].Entry.FileName + #0));
  AppendByte(Result, SEVENZ_NID_NAME);
  AppendSevenZipNumber(Result, UInt64(Length(NameBytes)) + 1);
  AppendByte(Result, 0);
  AppendBytes(Result, NameBytes);

  if EmptyStreamCount <> 0 then
  begin
    SetLength(Bits, (Length(Files) + 7) div 8);
    if Length(Bits) <> 0 then
      FillChar(Bits[0], Length(Bits), 0);
    for I := 0 to High(Files) do
      if not Files[I].HasStream then
        SetBit(Bits, I);
    AppendByte(Result, SEVENZ_NID_EMPTY_STREAM);
    AppendSevenZipNumber(Result, Length(Bits));
    AppendBytes(Result, Bits);

    SetLength(Bits, (EmptyStreamCount + 7) div 8);
    if Length(Bits) <> 0 then
      FillChar(Bits[0], Length(Bits), 0);
    EmptyIndex := 0;
    for I := 0 to High(Files) do
      if not Files[I].HasStream then
      begin
        if not Files[I].Entry.IsDirectory then
          SetBit(Bits, EmptyIndex);
        Inc(EmptyIndex);
      end;
    AppendByte(Result, SEVENZ_NID_EMPTY_FILE);
    AppendSevenZipNumber(Result, Length(Bits));
    AppendBytes(Result, Bits);
  end;

  AppendTimeProperty(SEVENZ_NID_CREATION_TIME);
  AppendTimeProperty(SEVENZ_NID_ACCESS_TIME);
  AppendTimeProperty(SEVENZ_NID_MODIFICATION_TIME);

  for I := 0 to High(Files) do
    if Files[I].Entry.HasAttributes then
    begin
      SetLength(PropertyBytes, 0);
      AllDefined := True;
      for StreamIndex := 0 to High(Files) do
        if not Files[StreamIndex].Entry.HasAttributes then
        begin
          AllDefined := False;
          Break;
        end;
      if AllDefined then
        AppendByte(PropertyBytes, 1)
      else
      begin
        AppendByte(PropertyBytes, 0);
        SetLength(Bits, (Length(Files) + 7) div 8);
        if Length(Bits) <> 0 then
          FillChar(Bits[0], Length(Bits), 0);
        for StreamIndex := 0 to High(Files) do
          if Files[StreamIndex].Entry.HasAttributes then
            SetBit(Bits, StreamIndex);
        AppendBytes(PropertyBytes, Bits);
      end;
      AppendByte(PropertyBytes, 0);
      for StreamIndex := 0 to High(Files) do
        if Files[StreamIndex].Entry.HasAttributes then
          AppendUi32LE(PropertyBytes, Files[StreamIndex].Entry.Attributes);
      AppendByte(Result, SEVENZ_NID_WIN_ATTRIBUTES);
      AppendSevenZipNumber(Result, Length(PropertyBytes));
      AppendBytes(Result, PropertyBytes);
      Break;
    end;

  AppendByte(Result, SEVENZ_NID_END);
  AppendByte(Result, SEVENZ_NID_END);
end;

function ParseFolder(const Data: TBytes; var Offset: NativeUInt): TSevenZipFolderInfo;
var
  NumCoders: UInt64;
  Flags: Byte;
  IdSize: Integer;
  MethodId: TBytes;
  I: Integer;
  NumInStreams: UInt64;
  NumOutStreams: UInt64;
  PropsSize: UInt64;
  Props: TLzmaProps;
begin
  Result := Default(TSevenZipFolderInfo);
  Result.PackStreamIndex := -1;
  Result.DictionaryProperty := High(Byte);
  Result.SubStreamCount := 1;
  NumCoders := ReadSevenZipNumber(Data, Offset);
  if NumCoders <> 1 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Only single-coder 7z folders are supported');

  Flags := ReadHeaderByte(Data, Offset);
  if (Flags and $80) <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Alternative 7z methods are not supported');
  if (Flags and $40) <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Reserved 7z coder flags are not supported');

  IdSize := Flags and $0F;
  if IdSize <= 0 then
    RaiseLzmaError(SZ_ERROR_DATA, '7z coder method id is empty');
  SetLength(MethodId, IdSize);
  for I := 0 to IdSize - 1 do
    MethodId[I] := ReadHeaderByte(Data, Offset);
  if (Length(MethodId) = 1) and (MethodId[0] = SEVENZ_METHOD_LZMA2) then
    Result.CoderMethod := szcmLzma2
  else if IsSevenZipLzmaMethod(MethodId) then
    Result.CoderMethod := szcmLzma
  else
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Only LZMA/LZMA2-coded 7z folders are supported');

  if (Flags and $10) <> 0 then
  begin
    NumInStreams := ReadSevenZipNumber(Data, Offset);
    NumOutStreams := ReadSevenZipNumber(Data, Offset);
    if (NumInStreams <> 1) or (NumOutStreams <> 1) then
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Only single-stream 7z coders are supported');
  end;

  if (Flags and $20) = 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z LZMA/LZMA2 coder properties are required');
  PropsSize := ReadSevenZipNumber(Data, Offset);
  Result.CoderProperties := ReadHeaderBytes(Data, Offset, PropsSize);
  case Result.CoderMethod of
    szcmLzma2:
      begin
        if Length(Result.CoderProperties) <> 1 then
          RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Only one-byte LZMA2 7z properties are supported');
        Result.DictionaryProperty := Result.CoderProperties[0];
        if Result.DictionaryProperty > LZMA2_DIC_PROP_MAX then
          RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z LZMA2 dictionary property');
      end;
    szcmLzma:
      begin
        if Length(Result.CoderProperties) <> 5 then
          RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Only five-byte LZMA 7z properties are supported');
        if not LzmaPropsDecode(Result.CoderProperties, Props) then
          RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z LZMA properties');
      end;
  else
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z folder coder is missing');
  end;
end;

procedure ParsePackInfo(const Data: TBytes; var Offset: NativeUInt; var Info: TSevenZipArchiveInfo);
var
  NumStreams: UInt64;
  Nid: Byte;
  Digest: TSevenZipDigestVector;
  I: Integer;
  RunningOffset: UInt64;
begin
  Info.PackPos := ReadSevenZipNumber(Data, Offset);
  NumStreams := ReadSevenZipNumber(Data, Offset);
  if NumStreams > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z pack stream count is too large');
  SetLength(Info.PackStreams, Integer(NumStreams));

  while True do
  begin
    Nid := ReadHeaderByte(Data, Offset);
    case Nid of
      SEVENZ_NID_END:
        begin
          RunningOffset := 0;
          for I := 0 to High(Info.PackStreams) do
          begin
            Info.PackStreams[I].Offset := Info.PackPos + RunningOffset;
            if Info.PackStreams[I].Offset < Info.PackPos then
              RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z pack stream offset overflow');
            Inc(RunningOffset, Info.PackStreams[I].Size);
            if RunningOffset < Info.PackStreams[I].Size then
              RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z pack stream size overflow');
          end;
          Exit;
        end;
      SEVENZ_NID_SIZE:
        for I := 0 to High(Info.PackStreams) do
          Info.PackStreams[I].Size := ReadSevenZipNumber(Data, Offset);
      SEVENZ_NID_CRC:
        begin
          ReadDigestVector(Data, Offset, NumStreams, Digest);
          for I := 0 to High(Info.PackStreams) do
          begin
            Info.PackStreams[I].HasCrc := Digest.Defined[I];
            Info.PackStreams[I].Crc := Digest.Values[I];
          end;
        end;
    else
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z PackInfo property');
    end;
  end;
end;

procedure ParseUnpackInfo(const Data: TBytes; var Offset: NativeUInt; var Info: TSevenZipArchiveInfo);
var
  Nid: Byte;
  NumFolders: UInt64;
  FolderStorage: Byte;
  Digest: TSevenZipDigestVector;
  I: Integer;
begin
  while True do
  begin
    Nid := ReadHeaderByte(Data, Offset);
    case Nid of
      SEVENZ_NID_END:
        Exit;
      SEVENZ_NID_FOLDER:
        begin
          NumFolders := ReadSevenZipNumber(Data, Offset);
          if NumFolders > UInt64(High(Integer)) then
            RaiseLzmaError(SZ_ERROR_MEM, '7z folder count is too large');
          FolderStorage := ReadHeaderByte(Data, Offset);
          if FolderStorage <> 0 then
            RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Out-of-line 7z folders are not supported');
          SetLength(Info.Folders, Integer(NumFolders));
          for I := 0 to High(Info.Folders) do
          begin
            Info.Folders[I] := ParseFolder(Data, Offset);
            Info.Folders[I].PackStreamIndex := I;
          end;
        end;
      SEVENZ_NID_CODERS_UNPACK_SIZE:
        begin
          if Length(Info.Folders) = 0 then
            RaiseLzmaError(SZ_ERROR_DATA, '7z coder unpack sizes appear before folders');
          for I := 0 to High(Info.Folders) do
            Info.Folders[I].UnpackSize := ReadSevenZipNumber(Data, Offset);
        end;
      SEVENZ_NID_CRC:
        begin
          ReadDigestVector(Data, Offset, Length(Info.Folders), Digest);
          for I := 0 to High(Info.Folders) do
          begin
            Info.Folders[I].HasCrc := Digest.Defined[I];
            Info.Folders[I].Crc := Digest.Values[I];
          end;
        end;
    else
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z UnPackInfo property');
    end;
  end;
end;

function SevenZipSubStreamDigestCount(const Info: TSevenZipArchiveInfo; const Counts: TArray<Integer>): UInt64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Counts) do
    if (Counts[I] <> 1) or (not Info.Folders[I].HasCrc) then
      Inc(Result, UInt64(Counts[I]));
end;

function SevenZipExplicitSubStreamSizeCount(const Counts: TArray<Integer>): UInt64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Counts) do
    if Counts[I] > 0 then
      Inc(Result, UInt64(Counts[I] - 1));
end;

procedure BuildSevenZipSubStreams(var Info: TSevenZipArchiveInfo; const Counts: TArray<Integer>;
  const ExplicitSizes: TArray<UInt64>; const Digests: TSevenZipDigestVector);
var
  Total: UInt64;
  I: Integer;
  J: Integer;
  SubIndex: Integer;
  SizeIndex: Integer;
  DigestIndex: Integer;
  Remaining: UInt64;
  SubSize: UInt64;
  OffsetInFolder: UInt64;
begin
  Total := 0;
  for I := 0 to High(Counts) do
    Inc(Total, UInt64(Counts[I]));
  if Total > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z substream count is too large');
  SetLength(Info.SubStreams, Integer(Total));

  SubIndex := 0;
  SizeIndex := 0;
  DigestIndex := 0;
  for I := 0 to High(Counts) do
  begin
    Info.Folders[I].SubStreamCount := Counts[I];
    Remaining := Info.Folders[I].UnpackSize;
    OffsetInFolder := 0;
    for J := 0 to Counts[I] - 1 do
    begin
      if J < Counts[I] - 1 then
      begin
        if SizeIndex >= Length(ExplicitSizes) then
          RaiseLzmaError(SZ_ERROR_DATA, '7z substream size vector is incomplete');
        SubSize := ExplicitSizes[SizeIndex];
        Inc(SizeIndex);
        if SubSize > Remaining then
          RaiseLzmaError(SZ_ERROR_DATA, '7z substream size exceeds folder unpack size');
      end
      else
        SubSize := Remaining;

      Info.SubStreams[SubIndex].FolderIndex := I;
      Info.SubStreams[SubIndex].OffsetInFolder := OffsetInFolder;
      Info.SubStreams[SubIndex].Size := SubSize;
      if (Counts[I] = 1) and Info.Folders[I].HasCrc then
      begin
        Info.SubStreams[SubIndex].HasCrc := True;
        Info.SubStreams[SubIndex].Crc := Info.Folders[I].Crc;
      end
      else if Length(Digests.Defined) <> 0 then
      begin
        if DigestIndex >= Length(Digests.Defined) then
          RaiseLzmaError(SZ_ERROR_DATA, '7z substream CRC vector is incomplete');
        Info.SubStreams[SubIndex].HasCrc := Digests.Defined[DigestIndex];
        Info.SubStreams[SubIndex].Crc := Digests.Values[DigestIndex];
        Inc(DigestIndex);
      end;

      Inc(OffsetInFolder, SubSize);
      Dec(Remaining, SubSize);
      Inc(SubIndex);
    end;
    if Remaining <> 0 then
      RaiseLzmaError(SZ_ERROR_DATA, '7z substream sizes do not cover folder unpack size');
  end;

  if SizeIndex <> Length(ExplicitSizes) then
    RaiseLzmaError(SZ_ERROR_DATA, '7z substream size vector has trailing values');
  if (Length(Digests.Defined) <> 0) and (DigestIndex <> Length(Digests.Defined)) then
    RaiseLzmaError(SZ_ERROR_DATA, '7z substream CRC vector has trailing values');
end;

procedure ParseSubStreamsInfo(const Data: TBytes; var Offset: NativeUInt; var Info: TSevenZipArchiveInfo);
var
  Nid: Byte;
  Counts: TArray<Integer>;
  ExplicitSizes: TArray<UInt64>;
  Digests: TSevenZipDigestVector;
  I: Integer;
  Count: UInt64;
  SizeCount: UInt64;
  DigestCount: UInt64;
begin
  SetLength(Counts, Length(Info.Folders));
  for I := 0 to High(Counts) do
    Counts[I] := 1;

  while True do
  begin
    Nid := ReadHeaderByte(Data, Offset);
    case Nid of
      SEVENZ_NID_END:
        begin
          if (SevenZipExplicitSubStreamSizeCount(Counts) <> 0) and (Length(ExplicitSizes) = 0) then
            RaiseLzmaError(SZ_ERROR_DATA, '7z solid substream sizes are missing');
          BuildSevenZipSubStreams(Info, Counts, ExplicitSizes, Digests);
          Exit;
        end;
      SEVENZ_NID_NUM_UNPACK_STREAM:
        for I := 0 to High(Counts) do
        begin
          Count := ReadSevenZipNumber(Data, Offset);
          if Count > UInt64(High(Integer)) then
            RaiseLzmaError(SZ_ERROR_MEM, '7z folder substream count is too large');
          Counts[I] := Integer(Count);
        end;
      SEVENZ_NID_SIZE:
        begin
          SizeCount := SevenZipExplicitSubStreamSizeCount(Counts);
          if SizeCount > UInt64(High(Integer)) then
            RaiseLzmaError(SZ_ERROR_MEM, '7z substream size count is too large');
          SetLength(ExplicitSizes, Integer(SizeCount));
          for I := 0 to High(ExplicitSizes) do
            ExplicitSizes[I] := ReadSevenZipNumber(Data, Offset);
        end;
      SEVENZ_NID_CRC:
        begin
          DigestCount := SevenZipSubStreamDigestCount(Info, Counts);
          ReadDigestVector(Data, Offset, DigestCount, Digests);
        end;
    else
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z SubStreamsInfo property');
    end;
  end;
end;

procedure ParseStreamsInfo(const Data: TBytes; var Offset: NativeUInt; var Info: TSevenZipArchiveInfo);
var
  Nid: Byte;
  HadSubStreamsInfo: Boolean;
  Counts: TArray<Integer>;
  I: Integer;
begin
  HadSubStreamsInfo := False;
  while True do
  begin
    Nid := ReadHeaderByte(Data, Offset);
    case Nid of
      SEVENZ_NID_END:
        begin
          if (not HadSubStreamsInfo) and (Length(Info.Folders) <> 0) then
          begin
            SetLength(Counts, Length(Info.Folders));
            for I := 0 to High(Counts) do
              Counts[I] := 1;
            BuildSevenZipSubStreams(Info, Counts, nil, Default(TSevenZipDigestVector));
          end;
          Exit;
        end;
      SEVENZ_NID_PACK_INFO:
        ParsePackInfo(Data, Offset, Info);
      SEVENZ_NID_UNPACK_INFO:
        ParseUnpackInfo(Data, Offset, Info);
      SEVENZ_NID_SUB_STREAMS_INFO:
        begin
          HadSubStreamsInfo := True;
          ParseSubStreamsInfo(Data, Offset, Info);
        end;
    else
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z StreamsInfo property');
    end;
  end;
end;

procedure FinalizeSevenZipFiles(var Info: TSevenZipArchiveInfo; const EmptyStreamBits, EmptyFileBits: TBytes);
var
  I: Integer;
  EmptyIndex: UInt64;
  SubStreamIndex: Integer;
begin
  EmptyIndex := 0;
  SubStreamIndex := 0;
  for I := 0 to High(Info.Files) do
  begin
    Info.Files[I].SubStreamIndex := -1;
    Info.Files[I].Entry.HasStream := not SevenZipBitVectorIsSet(EmptyStreamBits, I);
    if Info.Files[I].Entry.HasStream then
    begin
      if SubStreamIndex >= Length(Info.SubStreams) then
        RaiseLzmaError(SZ_ERROR_DATA, '7z file stream map exceeds substream count');
      Info.Files[I].SubStreamIndex := SubStreamIndex;
      Info.Files[I].Entry.Size := Info.SubStreams[SubStreamIndex].Size;
      Info.Files[I].Entry.HasCrc := Info.SubStreams[SubStreamIndex].HasCrc;
      Info.Files[I].Entry.Crc := Info.SubStreams[SubStreamIndex].Crc;
      Inc(SubStreamIndex);
    end
    else
    begin
      Info.Files[I].Entry.IsEmptyStream := True;
      Info.Files[I].Entry.Size := 0;
      Info.Files[I].Entry.IsDirectory := not SevenZipBitVectorIsSet(EmptyFileBits, EmptyIndex);
      Inc(EmptyIndex);
    end;
  end;
  if SubStreamIndex <> Length(Info.SubStreams) then
    RaiseLzmaError(SZ_ERROR_DATA, '7z substream count does not match file stream count');
end;

procedure ApplySevenZipTimes(var Info: TSevenZipArchiveInfo; const PropertyData: TBytes; const Nid: Byte);
var
  Offset: NativeUInt;
  Defined: TBytes;
  StorageFlag: Byte;
  I: Integer;
  Value: UInt64;
begin
  Offset := 0;
  Defined := ReadDefinedBitVector(PropertyData, Offset, Length(Info.Files));
  StorageFlag := ReadHeaderByte(PropertyData, Offset);
  if StorageFlag <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Out-of-line 7z timestamps are not supported');
  for I := 0 to High(Info.Files) do
    if SevenZipBitVectorIsSet(Defined, I) then
    begin
      Value := ReadHeaderUi64LE(PropertyData, Offset);
      case Nid of
        SEVENZ_NID_CREATION_TIME:
          begin
            Info.Files[I].Entry.HasCreationTime := True;
            Info.Files[I].Entry.CreationTime := Value;
          end;
        SEVENZ_NID_ACCESS_TIME:
          begin
            Info.Files[I].Entry.HasAccessTime := True;
            Info.Files[I].Entry.AccessTime := Value;
          end;
        SEVENZ_NID_MODIFICATION_TIME:
          begin
            Info.Files[I].Entry.HasModifiedTime := True;
            Info.Files[I].Entry.ModifiedTime := Value;
          end;
      else
        RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z timestamp property');
      end;
    end;
  if Offset <> NativeUInt(Length(PropertyData)) then
    RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes in 7z timestamp property');
end;

procedure ApplySevenZipAttributes(var Info: TSevenZipArchiveInfo; const PropertyData: TBytes);
var
  Offset: NativeUInt;
  Defined: TBytes;
  StorageFlag: Byte;
  I: Integer;
begin
  Offset := 0;
  Defined := ReadDefinedBitVector(PropertyData, Offset, Length(Info.Files));
  StorageFlag := ReadHeaderByte(PropertyData, Offset);
  if StorageFlag <> 0 then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Out-of-line 7z file attributes are not supported');
  for I := 0 to High(Info.Files) do
    if SevenZipBitVectorIsSet(Defined, I) then
    begin
      Info.Files[I].Entry.HasAttributes := True;
      Info.Files[I].Entry.Attributes := ReadHeaderUi32LE(PropertyData, Offset);
    end;
  if Offset <> NativeUInt(Length(PropertyData)) then
    RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes in 7z attribute property');
end;

procedure ParseFilesInfo(const Data: TBytes; var Offset: NativeUInt; var Info: TSevenZipArchiveInfo);
var
  NumFiles: UInt64;
  Nid: Byte;
  Size: UInt64;
  EmptyStreamBits: TBytes;
  EmptyFileBits: TBytes;
  Names: TArray<string>;
  I: Integer;
  PropertyData: TBytes;
  HadNames: Boolean;
begin
  NumFiles := ReadSevenZipNumber(Data, Offset);
  if NumFiles > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z file count is too large');
  SetLength(Info.Files, Integer(NumFiles));
  HadNames := NumFiles = 0;

  while True do
  begin
    Nid := ReadHeaderByte(Data, Offset);
    if Nid = SEVENZ_NID_END then
    begin
      if not HadNames then
        RaiseLzmaError(SZ_ERROR_DATA, '7z file names are missing');
      FinalizeSevenZipFiles(Info, EmptyStreamBits, EmptyFileBits);
      Exit;
    end;
    Size := ReadSevenZipNumber(Data, Offset);
    case Nid of
      SEVENZ_NID_NAME:
        begin
          if HadNames then
            RaiseLzmaError(SZ_ERROR_DATA, 'Duplicate 7z name property');
          Names := DecodeSevenZipNames(Data, Offset, Size, NumFiles);
          for I := 0 to High(Info.Files) do
            Info.Files[I].Entry.FileName := Names[I];
          HadNames := True;
        end;
      SEVENZ_NID_EMPTY_STREAM:
        EmptyStreamBits := ReadHeaderBytes(Data, Offset, Size);
      SEVENZ_NID_EMPTY_FILE:
        EmptyFileBits := ReadHeaderBytes(Data, Offset, Size);
      SEVENZ_NID_CREATION_TIME,
      SEVENZ_NID_ACCESS_TIME,
      SEVENZ_NID_MODIFICATION_TIME:
        begin
          PropertyData := ReadHeaderBytes(Data, Offset, Size);
          ApplySevenZipTimes(Info, PropertyData, Nid);
        end;
      SEVENZ_NID_WIN_ATTRIBUTES:
        begin
          PropertyData := ReadHeaderBytes(Data, Offset, Size);
          ApplySevenZipAttributes(Info, PropertyData);
        end;
      SEVENZ_NID_ANTI:
        RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z anti-file markers are not supported');
    else
      SkipHeaderBytes(Data, Offset, Size);
    end;
  end;
end;

function ParseSevenZipHeader(const Header: TBytes): TSevenZipArchiveInfo;
var
  Offset: NativeUInt;
  Nid: Byte;

  procedure ValidatePayloadInfo;
  var
    J: Integer;
  begin
    if Length(Result.Folders) = 0 then
    begin
      if Length(Result.PackStreams) <> 0 then
        RaiseLzmaError(SZ_ERROR_DATA, '7z pack streams exist without folders');
      if Length(Result.SubStreams) <> 0 then
        RaiseLzmaError(SZ_ERROR_DATA, '7z substreams exist without folders');
      Exit;
    end;

    if Length(Result.PackStreams) < Length(Result.Folders) then
      RaiseLzmaError(SZ_ERROR_DATA, '7z pack stream count does not cover folders');
    if Length(Result.PackStreams) > Length(Result.Folders) then
      RaiseLzmaError(SZ_ERROR_DATA, '7z pack stream count exceeds referenced folders');
    for J := 0 to High(Result.Folders) do
    begin
      if Result.Folders[J].PackStreamIndex < 0 then
        RaiseLzmaError(SZ_ERROR_DATA, '7z folder pack stream is missing');
      if Result.Folders[J].PackStreamIndex >= Length(Result.PackStreams) then
        RaiseLzmaError(SZ_ERROR_DATA, '7z folder pack stream index is out of range');
      if Result.Folders[J].CoderMethod = szcmNone then
        RaiseLzmaError(SZ_ERROR_DATA, '7z LZMA/LZMA2 folder is missing');
      if (Result.Folders[J].CoderMethod = szcmLzma2) and
        (Result.Folders[J].DictionaryProperty > LZMA2_DIC_PROP_MAX) then
        RaiseLzmaError(SZ_ERROR_DATA, '7z LZMA2 folder is missing');
    end;
  end;

begin
  Result := Default(TSevenZipArchiveInfo);
  Offset := 0;
  if ReadHeaderByte(Header, Offset) <> SEVENZ_NID_HEADER then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Non-standard 7z headers are not supported');

  while True do
  begin
    Nid := ReadHeaderByte(Header, Offset);
    case Nid of
      SEVENZ_NID_END:
        Break;
      SEVENZ_NID_MAIN_STREAMS_INFO:
        ParseStreamsInfo(Header, Offset, Result);
      SEVENZ_NID_FILES_INFO:
        ParseFilesInfo(Header, Offset, Result);
      SEVENZ_NID_ENCODED_HEADER:
        RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Nested encoded 7z headers are not supported');
    else
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z header property');
    end;
  end;

  if Offset <> NativeUInt(Length(Header)) then
    RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes in 7z header');
  ValidatePayloadInfo;
end;

function ParseSevenZipEncodedHeaderInfo(const Header: TBytes): TSevenZipArchiveInfo;
var
  Offset: NativeUInt;
begin
  Result := Default(TSevenZipArchiveInfo);
  Offset := 0;
  if ReadHeaderByte(Header, Offset) <> SEVENZ_NID_ENCODED_HEADER then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Encoded 7z header descriptor is missing');
  ParseStreamsInfo(Header, Offset, Result);
  if Offset <> NativeUInt(Length(Header)) then
    RaiseLzmaError(SZ_ERROR_DATA, 'Trailing bytes in encoded 7z header descriptor');
  if Length(Result.PackStreams) <> 1 then
    RaiseLzmaError(SZ_ERROR_DATA, 'Encoded 7z header pack stream is missing');
  if Result.PackStreams[0].Size = 0 then
    RaiseLzmaError(SZ_ERROR_DATA, 'Encoded 7z header pack stream is empty or missing');
  if Length(Result.Folders) <> 1 then
    RaiseLzmaError(SZ_ERROR_DATA, 'Encoded 7z header folder is missing');
  if Result.Folders[0].CoderMethod = szcmNone then
    RaiseLzmaError(SZ_ERROR_DATA, 'Encoded 7z header coder is missing');
  if (Result.Folders[0].CoderMethod = szcmLzma2) and
    (Result.Folders[0].DictionaryProperty > LZMA2_DIC_PROP_MAX) then
    RaiseLzmaError(SZ_ERROR_DATA, 'Encoded 7z LZMA2 folder is missing');
end;

constructor TSevenZipCrcReadStream.Create(const Base: TStream);
begin
  inherited Create;
  FBase := Base;
  FCrc := CRC_INIT_VAL;
end;

function TSevenZipCrcReadStream.GetDigest: UInt32;
begin
  Result := FCrc xor CRC_INIT_VAL;
end;

function TSevenZipCrcReadStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := ReadAvailable(FBase, Buffer, Count);
  if Result > 0 then
  begin
    FCrc := Crc32Update(FCrc, @Buffer, NativeUInt(Result));
    Inc(FBytesRead, UInt64(Result));
  end;
end;

function TSevenZipCrcReadStream.Write(const Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_WRITE, '7z CRC read stream is read-only');
  Result := 0;
end;

function TSevenZipCrcReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FBase.Seek(Offset, Origin);
end;

{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TSevenZipCrcReadStream.Read(var Buffer; Count: NativeInt): NativeInt;
begin
  Result := Read(Buffer, Longint(Count));
end;

function TSevenZipCrcReadStream.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  Result := Write(Buffer, Longint(Count));
end;
{$ENDIF}

constructor TSevenZipCrcWriteStream.Create(const Base: TStream);
begin
  inherited Create;
  FBase := Base;
  FCrc := CRC_INIT_VAL;
end;

function TSevenZipCrcWriteStream.GetDigest: UInt32;
begin
  Result := FCrc xor CRC_INIT_VAL;
end;

function TSevenZipCrcWriteStream.Read(var Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_READ, '7z CRC write stream is write-only');
  Result := 0;
end;

function TSevenZipCrcWriteStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := FBase.Write(Buffer, Count);
  if Result > 0 then
  begin
    FCrc := Crc32Update(FCrc, @Buffer, NativeUInt(Result));
    Inc(FBytesWritten, UInt64(Result));
  end;
end;

function TSevenZipCrcWriteStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FBase.Seek(Offset, Origin);
end;

{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TSevenZipCrcWriteStream.Read(var Buffer; Count: NativeInt): NativeInt;
begin
  Result := Read(Buffer, Longint(Count));
end;

function TSevenZipCrcWriteStream.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  Result := Write(Buffer, Longint(Count));
end;
{$ENDIF}

constructor TSevenZipBoundedReadStream.Create(const Base: TStream; const Size: UInt64);
begin
  inherited Create;
  FBase := Base;
  FRemaining := Size;
  FCrc := CRC_INIT_VAL;
end;

function TSevenZipBoundedReadStream.GetDigest: UInt32;
begin
  Result := FCrc xor CRC_INIT_VAL;
end;

function TSevenZipBoundedReadStream.Read(var Buffer; Count: Longint): Longint;
var
  Allowed: Longint;
begin
  if (Count <= 0) or (FRemaining = 0) then
    Exit(0);
  Allowed := Count;
  if UInt64(Allowed) > FRemaining then
    Allowed := Longint(FRemaining);
  Result := ReadAvailable(FBase, Buffer, Allowed);
  if Result > 0 then
  begin
    FCrc := Crc32Update(FCrc, @Buffer, NativeUInt(Result));
    Inc(FBytesRead, UInt64(Result));
    Dec(FRemaining, UInt64(Result));
  end;
end;

function TSevenZipBoundedReadStream.Write(const Buffer; Count: Longint): Longint;
begin
  RaiseLzmaError(SZ_ERROR_WRITE, '7z bounded input stream is read-only');
  Result := 0;
end;

function TSevenZipBoundedReadStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Origin = soCurrent) and (Offset = 0) then
    Exit(Int64(FBytesRead));
  RaiseLzmaError(SZ_ERROR_READ, '7z bounded input stream does not support seeking');
  Result := Int64(FBytesRead);
end;

{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TSevenZipBoundedReadStream.Read(var Buffer; Count: NativeInt): NativeInt;
begin
  Result := Read(Buffer, Longint(Count));
end;

function TSevenZipBoundedReadStream.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  Result := Write(Buffer, Longint(Count));
end;
{$ENDIF}

procedure DecodeSevenZipFolderToStream(Source: TStream; const ArchiveStart: Int64;
  const Folder: TSevenZipFolderInfo; const PackStream: TSevenZipPackStreamInfo;
  Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent; out ConsumedBytes, ProducedBytes: UInt64);
var
  RawOptions: TLzma2Options;
  PackedInput: TSevenZipBoundedReadStream;
  CheckedOutput: TSevenZipCrcWriteStream;
begin
  RawOptions := Options;
  if Folder.CoderMethod = szcmLzma2 then
  begin
    RawOptions.Container := lcRawLzma2;
    RawOptions.DictionarySize := Lzma2DictionaryFromProperty(Folder.DictionaryProperty);
  end
  else
    RawOptions.Container := lcLzma;

  Source.Position := ArchiveStart + SEVENZ_SIGNATURE_HEADER_SIZE + Int64(PackStream.Offset);
  PackedInput := TSevenZipBoundedReadStream.Create(Source, PackStream.Size);
  CheckedOutput := TSevenZipCrcWriteStream.Create(Destination);
  try
    case Folder.CoderMethod of
      szcmLzma2:
        TLzma2Decoder.DecodeRawEmbedded(PackedInput, CheckedOutput, RawOptions, ConsumedBytes, ProducedBytes, Progress);
      szcmLzma:
        begin
          TLzmaRawDecoder.Decode(PackedInput, CheckedOutput, Folder.CoderProperties, Folder.UnpackSize, Progress);
          ConsumedBytes := PackedInput.BytesRead;
          ProducedBytes := CheckedOutput.BytesWritten;
        end;
    else
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z folder coder is missing');
    end;
    if ConsumedBytes <> PackStream.Size then
      RaiseLzmaError(SZ_ERROR_DATA, '7z packed stream contains trailing bytes');
    if PackStream.HasCrc and (PackedInput.Digest <> PackStream.Crc) then
      RaiseLzmaError(SZ_ERROR_CRC, '7z packed stream CRC mismatch');
    if ProducedBytes <> Folder.UnpackSize then
      RaiseLzmaError(SZ_ERROR_DATA, '7z unpacked size mismatch');
    if Folder.HasCrc and (CheckedOutput.Digest <> Folder.Crc) then
      RaiseLzmaError(SZ_ERROR_CRC, '7z unpacked stream CRC mismatch');
  finally
    CheckedOutput.Free;
    PackedInput.Free;
  end;
end;

function DecodeSevenZipFolderToBytes(Source: TStream; const ArchiveStart: Int64;
  const Info: TSevenZipArchiveInfo): TBytes;
var
  Options: TLzma2Options;
  Output: TMemoryStream;
  ConsumedBytes: UInt64;
  ProducedBytes: UInt64;
begin
  Options := Default(TLzma2Options);
  Options.ThreadCount := 1;
  Options.Lc := -1;
  Options.Lp := -1;
  Options.Pb := -1;
  Output := TMemoryStream.Create;
  try
    if (Length(Info.Folders) <> 1) or (Length(Info.PackStreams) <> 1) then
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Encoded 7z header must use one LZMA/LZMA2 folder');
    DecodeSevenZipFolderToStream(Source, ArchiveStart, Info.Folders[0],
      Info.PackStreams[Info.Folders[0].PackStreamIndex], Output, Options, nil, ConsumedBytes, ProducedBytes);
    SetLength(Result, Output.Size);
    if Output.Size <> 0 then
    begin
      Output.Position := 0;
      Output.ReadBuffer(Result[0], Output.Size);
    end;
  finally
    Output.Free;
  end;
end;

function ReadSevenZipArchiveInfo(Source: TStream; out ArchiveStart: Int64): TSevenZipArchiveInfo;
var
  SignatureHeader: array[0..SEVENZ_SIGNATURE_HEADER_SIZE - 1] of Byte;
  I: Integer;
  StartHeaderCrc: UInt32;
  NextHeaderOffset: UInt64;
  NextHeaderSize: UInt64;
  NextHeaderCrc: UInt32;
  Header: TBytes;
  DecodedHeader: TBytes;
  EncodedHeaderInfo: TSevenZipArchiveInfo;
  HasEncodedHeader: Boolean;
  HeaderEndRelative: UInt64;
  EncodedPackEndRelative: UInt64;
  PackEndRelative: UInt64;
  ArchiveEndRelative: UInt64;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');

  ArchiveStart := 0;
  try
    ArchiveStart := Source.Position;
  except
    on E: Exception do
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z decode requires a seekable source stream: ' + E.Message);
  end;

  ReadExact(Source, SignatureHeader, SizeOf(SignatureHeader));
  for I := 0 to High(SEVENZ_SIGNATURE) do
    if SignatureHeader[I] <> SEVENZ_SIGNATURE[I] then
      RaiseLzmaError(SZ_ERROR_NO_ARCHIVE, 'Input is not a 7z archive');
  if (SignatureHeader[6] <> 0) or (SignatureHeader[7] <> 4) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z archive version');

  StartHeaderCrc := ReadUi32LE(@SignatureHeader[8]);
  if Crc32Calc(@SignatureHeader[12], 20) <> StartHeaderCrc then
    RaiseLzmaError(SZ_ERROR_CRC, '7z start header CRC mismatch');

  NextHeaderOffset := ReadUi64LE(@SignatureHeader[12]);
  NextHeaderSize := ReadUi64LE(@SignatureHeader[20]);
  NextHeaderCrc := ReadUi32LE(@SignatureHeader[28]);
  if NextHeaderSize > UInt64(High(Integer)) then
    RaiseLzmaError(SZ_ERROR_MEM, '7z header is too large');
  if ArchiveStart > High(Int64) - SEVENZ_SIGNATURE_HEADER_SIZE then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z archive start overflows stream position');
  if NextHeaderOffset > UInt64(High(Int64) - ArchiveStart - SEVENZ_SIGNATURE_HEADER_SIZE) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z next header offset overflows stream position');

  Source.Position := ArchiveStart + SEVENZ_SIGNATURE_HEADER_SIZE + Int64(NextHeaderOffset);
  SetLength(Header, Integer(NextHeaderSize));
  if Length(Header) <> 0 then
    ReadExact(Source, Header[0], Length(Header));
  if Crc32OfBytes(Header) <> NextHeaderCrc then
    RaiseLzmaError(SZ_ERROR_CRC, '7z next header CRC mismatch');

  HasEncodedHeader := (Length(Header) <> 0) and (Header[0] = SEVENZ_NID_ENCODED_HEADER);
  if HasEncodedHeader then
  begin
    EncodedHeaderInfo := ParseSevenZipEncodedHeaderInfo(Header);
    DecodedHeader := DecodeSevenZipFolderToBytes(Source, ArchiveStart, EncodedHeaderInfo);
    Result := ParseSevenZipHeader(DecodedHeader);
  end
  else
    Result := ParseSevenZipHeader(Header);

  HeaderEndRelative := NextHeaderOffset + NextHeaderSize;
  if HeaderEndRelative < NextHeaderOffset then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z next header end overflows stream position');
  ArchiveEndRelative := HeaderEndRelative;
  if HasEncodedHeader then
  begin
    for I := 0 to High(EncodedHeaderInfo.PackStreams) do
    begin
      EncodedPackEndRelative := EncodedHeaderInfo.PackStreams[I].Offset + EncodedHeaderInfo.PackStreams[I].Size;
      if EncodedPackEndRelative < EncodedHeaderInfo.PackStreams[I].Offset then
        RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Encoded 7z header packed stream end overflows stream position');
      if EncodedPackEndRelative > ArchiveEndRelative then
        ArchiveEndRelative := EncodedPackEndRelative;
    end;
  end;
  for I := 0 to High(Result.PackStreams) do
  begin
    PackEndRelative := Result.PackStreams[I].Offset + Result.PackStreams[I].Size;
    if PackEndRelative < Result.PackStreams[I].Offset then
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z packed stream end overflows stream position');
    if PackEndRelative > ArchiveEndRelative then
      ArchiveEndRelative := PackEndRelative;
  end;
  if ArchiveEndRelative > UInt64(High(Int64) - ArchiveStart - SEVENZ_SIGNATURE_HEADER_SIZE) then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z archive end overflows stream position');
  Result.ArchiveEndPosition := ArchiveStart + SEVENZ_SIGNATURE_HEADER_SIZE + Int64(ArchiveEndRelative);
end;

class procedure TLzma7z.Encode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  ArchiveStart: Int64;
  HeaderStart: Int64;
  EndPosition: Int64;
  Placeholder: array[0..SEVENZ_SIGNATURE_HEADER_SIZE - 1] of Byte;
  SignatureHeader: TBytes;
  StartHeader: TBytes;
  Header: TBytes;
  RawOptions: TLzma2Options;
  SourceCrc: TSevenZipCrcReadStream;
  PackedCrc: TSevenZipCrcWriteStream;
  Info: TLzma2DictionaryInfo;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  ArchiveStart := 0;
  try
    ArchiveStart := Destination.Position;
  except
    on E: Exception do
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z encode requires a seekable destination stream: ' + E.Message);
  end;

  FillChar(Placeholder, SizeOf(Placeholder), 0);
  WriteExact(Destination, Placeholder, SizeOf(Placeholder));

  RawOptions := Options;
  RawOptions.Container := lcRawLzma2;
  Info := TLzma2Encoder.DictionaryInfo(RawOptions);

  SourceCrc := TSevenZipCrcReadStream.Create(Source);
  PackedCrc := TSevenZipCrcWriteStream.Create(Destination);
  try
    TLzma2Encoder.EncodeRaw(SourceCrc, PackedCrc, RawOptions, Progress);
    Header := BuildSevenZipHeader(Options.ArchiveFileName, PackedCrc.BytesWritten, PackedCrc.Digest,
      SourceCrc.BytesRead, SourceCrc.Digest, Info.PropertyByte);
  finally
    PackedCrc.Free;
    SourceCrc.Free;
  end;

  HeaderStart := Destination.Position;
  WriteBytes(Destination, Header);
  EndPosition := Destination.Position;

  SetLength(StartHeader, 0);
  AppendUi64LE(StartHeader, UInt64(HeaderStart - ArchiveStart - SEVENZ_SIGNATURE_HEADER_SIZE));
  AppendUi64LE(StartHeader, UInt64(Length(Header)));
  AppendUi32LE(StartHeader, Crc32OfBytes(Header));

  SetLength(SignatureHeader, 0);
  AppendSevenZipSignatureAndVersion(SignatureHeader);
  AppendUi32LE(SignatureHeader, Crc32OfBytes(StartHeader));
  AppendBytes(SignatureHeader, StartHeader);

  Destination.Position := ArchiveStart;
  WriteBytes(Destination, SignatureHeader);
  Destination.Position := EndPosition;
end;

function TryGetRemainingStreamSize(const Source: TStream; out Remaining: UInt64): Boolean;
var
  PosValue: Int64;
  SizeValue: Int64;
begin
  Result := False;
  Remaining := 0;
  try
    PosValue := Source.Position;
    SizeValue := Source.Size;
  except
    Exit;
  end;
  if (PosValue < 0) or (SizeValue < PosValue) then
    Exit;
  Remaining := UInt64(SizeValue - PosValue);
  Result := True;
end;

function MemoryStreamToBytes(const Stream: TMemoryStream): TBytes;
begin
  SetLength(Result, Stream.Size);
  if Stream.Size <> 0 then
  begin
    Stream.Position := 0;
    Stream.ReadBuffer(Result[0], Stream.Size);
  end;
end;

class procedure TLzma7z.EncodeEntries(const Entries: TArray<TLzma7zEncodeEntry>;
  const CreateEntryStream: TLzma7zCreateEntryStream; Destination: TStream;
  const Options: TLzma2Options; const Method: TLzma7zEncodeMethod;
  const Progress: TLzma2ProgressEvent);
var
  ArchiveStart: Int64;
  HeaderStart: Int64;
  EndPosition: Int64;
  Placeholder: array[0..SEVENZ_SIGNATURE_HEADER_SIZE - 1] of Byte;
  SignatureHeader: TBytes;
  StartHeader: TBytes;
  Header: TBytes;
  EncodedFiles: TArray<TSevenZipEncodedFileInfo>;
  RawOptions: TLzma2Options;
  EntryStream: TStream;
  SourceCrc: TSevenZipCrcReadStream;
  PackedCrc: TSevenZipCrcWriteStream;
  StandaloneStream: TMemoryStream;
  StandaloneBytes: TBytes;
  RawPacked: TBytes;
  Info: TLzma2DictionaryInfo;
  Remaining: UInt64;
  I: Integer;

  procedure EncodeLzma2Entry(const Index: Integer);
  begin
    RawOptions := Options;
    RawOptions.Container := lcRawLzma2;
    Info := TLzma2Encoder.DictionaryInfo(RawOptions);
    EncodedFiles[Index].CoderMethod := szcmLzma2;
    EncodedFiles[Index].CoderProperties := TBytes.Create(Info.PropertyByte);

    SourceCrc := TSevenZipCrcReadStream.Create(EntryStream);
    PackedCrc := TSevenZipCrcWriteStream.Create(Destination);
    try
      TLzma2Encoder.EncodeRaw(SourceCrc, PackedCrc, RawOptions, Progress);
      EncodedFiles[Index].UnpackSize := SourceCrc.BytesRead;
      EncodedFiles[Index].UnpackCrc := SourceCrc.Digest;
      EncodedFiles[Index].PackSize := PackedCrc.BytesWritten;
      EncodedFiles[Index].PackCrc := PackedCrc.Digest;
    finally
      PackedCrc.Free;
      SourceCrc.Free;
    end;
  end;

  procedure EncodeLzmaEntry(const Index: Integer);
  begin
    RawOptions := Options;
    RawOptions.Container := lcLzma;
    RawOptions.LzmaEndMarker := False;
    EncodedFiles[Index].CoderMethod := szcmLzma;

    SourceCrc := TSevenZipCrcReadStream.Create(EntryStream);
    StandaloneStream := TMemoryStream.Create;
    try
      TLzmaStandalone.Encode(SourceCrc, StandaloneStream, RawOptions, Progress);
      StandaloneBytes := MemoryStreamToBytes(StandaloneStream);
      if Length(StandaloneBytes) < LZMA_STANDALONE_HEADER_SIZE then
        RaiseLzmaError(SZ_ERROR_DATA, 'Standalone LZMA encoder returned a truncated stream');
      EncodedFiles[Index].CoderProperties := Copy(StandaloneBytes, 0, LZMA_PROPS_SIZE);
      RawPacked := Copy(StandaloneBytes, LZMA_STANDALONE_HEADER_SIZE,
        Length(StandaloneBytes) - LZMA_STANDALONE_HEADER_SIZE);
      WriteBytes(Destination, RawPacked);
      EncodedFiles[Index].UnpackSize := SourceCrc.BytesRead;
      EncodedFiles[Index].UnpackCrc := SourceCrc.Digest;
      EncodedFiles[Index].PackSize := Length(RawPacked);
      EncodedFiles[Index].PackCrc := Crc32OfBytes(RawPacked);
    finally
      StandaloneStream.Free;
      SourceCrc.Free;
    end;
  end;

begin
  if Length(Entries) = 0 then
    RaiseLzmaError(SZ_ERROR_PARAM, '7z encode requires at least one entry');
  if not Assigned(CreateEntryStream) then
    RaiseLzmaError(SZ_ERROR_PARAM, '7z encode entry stream callback is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  ArchiveStart := 0;
  try
    ArchiveStart := Destination.Position;
  except
    on E: Exception do
      RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z encode requires a seekable destination stream: ' + E.Message);
  end;

  FillChar(Placeholder, SizeOf(Placeholder), 0);
  WriteExact(Destination, Placeholder, SizeOf(Placeholder));

  SetLength(EncodedFiles, Length(Entries));
  for I := 0 to High(Entries) do
  begin
    EncodedFiles[I].Entry := Entries[I];
    EncodedFiles[I].Entry.FileName := NormalizeSevenZipStoredName(Entries[I].FileName, Entries[I].IsDirectory);
    if Entries[I].IsDirectory then
      Continue;

    EntryStream := CreateEntryStream(Entries[I], I);
    if EntryStream = nil then
      RaiseLzmaError(SZ_ERROR_READ, '7z encode entry stream callback returned nil for file entry');
    try
      if TryGetRemainingStreamSize(EntryStream, Remaining) and (Remaining = 0) then
        Continue;
      EncodedFiles[I].HasStream := True;
      case Method of
        zemLzma2:
          EncodeLzma2Entry(I);
        zemLzma:
          EncodeLzmaEntry(I);
      else
        RaiseLzmaError(SZ_ERROR_UNSUPPORTED, 'Unsupported 7z encode method');
      end;
    finally
      EntryStream.Free;
    end;
  end;

  Header := BuildSevenZipEntriesHeader(EncodedFiles);
  HeaderStart := Destination.Position;
  WriteBytes(Destination, Header);
  EndPosition := Destination.Position;

  SetLength(StartHeader, 0);
  AppendUi64LE(StartHeader, UInt64(HeaderStart - ArchiveStart - SEVENZ_SIGNATURE_HEADER_SIZE));
  AppendUi64LE(StartHeader, UInt64(Length(Header)));
  AppendUi32LE(StartHeader, Crc32OfBytes(Header));

  SetLength(SignatureHeader, 0);
  AppendSevenZipSignatureAndVersion(SignatureHeader);
  AppendUi32LE(SignatureHeader, Crc32OfBytes(StartHeader));
  AppendBytes(SignatureHeader, StartHeader);

  Destination.Position := ArchiveStart;
  WriteBytes(Destination, SignatureHeader);
  Destination.Position := EndPosition;
end;

class procedure TLzma7z.Decode(Source: TStream; Destination: TStream; const Options: TLzma2Options;
  const Progress: TLzma2ProgressEvent);
var
  ArchiveStart: Int64;
  Info: TSevenZipArchiveInfo;
  FileIndex: Integer;
  SubStreamIndex: Integer;
  FolderIndex: Integer;
  TempFolder: TMemoryStream;
  Buffer: array[0..8191] of Byte;
  Remaining: UInt64;
  ChunkSize: Integer;
  ReadSize: Integer;
  Crc: UInt32;
  ConsumedBytes: UInt64;
  ProducedBytes: UInt64;
begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if Destination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Destination stream is nil');

  Info := ReadSevenZipArchiveInfo(Source, ArchiveStart);
  if (Length(Info.Files) <> 1) or Info.Files[0].Entry.IsDirectory then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z stream decode supports only a single file entry');

  FileIndex := 0;
  if not Info.Files[FileIndex].Entry.HasStream then
  begin
    SetLzma2DecodeDiagnostics(Options, 1, 1, False, ldfrSingleIndependentUnit);
    Source.Position := Info.ArchiveEndPosition;
    Exit;
  end;

  SubStreamIndex := Info.Files[FileIndex].SubStreamIndex;
  FolderIndex := Info.SubStreams[SubStreamIndex].FolderIndex;
  if (Info.Folders[FolderIndex].SubStreamCount = 1) and
    (Info.SubStreams[SubStreamIndex].OffsetInFolder = 0) and
    (Info.SubStreams[SubStreamIndex].Size = Info.Folders[FolderIndex].UnpackSize) then
  begin
    DecodeSevenZipFolderToStream(Source, ArchiveStart, Info.Folders[FolderIndex],
      Info.PackStreams[Info.Folders[FolderIndex].PackStreamIndex], Destination, Options, Progress,
      ConsumedBytes, ProducedBytes);
    Source.Position := Info.ArchiveEndPosition;
    Exit;
  end;

  TempFolder := TMemoryStream.Create;
  try
    DecodeSevenZipFolderToStream(Source, ArchiveStart, Info.Folders[FolderIndex],
      Info.PackStreams[Info.Folders[FolderIndex].PackStreamIndex], TempFolder, Options, Progress,
      ConsumedBytes, ProducedBytes);
    TempFolder.Position := Int64(Info.SubStreams[SubStreamIndex].OffsetInFolder);
    Remaining := Info.SubStreams[SubStreamIndex].Size;
    Crc := CRC_INIT_VAL;
    while Remaining <> 0 do
    begin
      ChunkSize := SizeOf(Buffer);
      if UInt64(ChunkSize) > Remaining then
        ChunkSize := Integer(Remaining);
      ReadSize := TempFolder.Read(Buffer, ChunkSize);
      if ReadSize <> ChunkSize then
        RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of decoded 7z folder');
      WriteExact(Destination, Buffer, ReadSize);
      Crc := Crc32Update(Crc, @Buffer[0], NativeUInt(ReadSize));
      Dec(Remaining, UInt64(ReadSize));
    end;
    if Info.SubStreams[SubStreamIndex].HasCrc and
      ((Crc xor CRC_INIT_VAL) <> Info.SubStreams[SubStreamIndex].Crc) then
      RaiseLzmaError(SZ_ERROR_CRC, '7z file CRC mismatch');
  finally
    TempFolder.Free;
  end;
  Source.Position := Info.ArchiveEndPosition;
end;

class function TLzma7z.List(Source: TStream): TArray<TLzma7zEntry>;
var
  ArchiveStart: Int64;
  Info: TSevenZipArchiveInfo;
  I: Integer;
begin
  Info := ReadSevenZipArchiveInfo(Source, ArchiveStart);
  SetLength(Result, Length(Info.Files));
  for I := 0 to High(Info.Files) do
    Result[I] := Info.Files[I].Entry;
  Source.Position := Info.ArchiveEndPosition;
end;

class procedure TLzma7z.ExtractAll(Source: TStream; const OpenEntry: TLzma7zOpenEntryStream;
  const Options: TLzma2Options; const Progress: TLzma2ProgressEvent);
var
  ArchiveStart: Int64;
  Info: TSevenZipArchiveInfo;
  FolderCache: TArray<TMemoryStream>;
  I: Integer;
  SubStreamIndex: Integer;
  FolderIndex: Integer;
  EntryStream: TStream;
  Buffer: array[0..8191] of Byte;
  Remaining: UInt64;
  ChunkSize: Integer;
  ReadSize: Integer;
  Crc: UInt32;
  ConsumedBytes: UInt64;
  ProducedBytes: UInt64;

  function DecodedFolder(const Index: Integer): TMemoryStream;
  begin
    if FolderCache[Index] = nil then
    begin
      FolderCache[Index] := TMemoryStream.Create;
      DecodeSevenZipFolderToStream(Source, ArchiveStart, Info.Folders[Index],
        Info.PackStreams[Info.Folders[Index].PackStreamIndex], FolderCache[Index], Options, Progress,
        ConsumedBytes, ProducedBytes);
    end;
    Result := FolderCache[Index];
  end;

begin
  if Source = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'Source stream is nil');
  if not Assigned(OpenEntry) then
    RaiseLzmaError(SZ_ERROR_PARAM, '7z extract callback is nil');

  Info := ReadSevenZipArchiveInfo(Source, ArchiveStart);
  SetLength(FolderCache, Length(Info.Folders));
  try
    for I := 0 to High(Info.Files) do
    begin
      EntryStream := OpenEntry(Info.Files[I].Entry);
      if Info.Files[I].Entry.IsDirectory or (not Info.Files[I].Entry.HasStream) then
        Continue;
      if EntryStream = nil then
        RaiseLzmaError(SZ_ERROR_WRITE, '7z extract callback returned nil for file entry');

      SubStreamIndex := Info.Files[I].SubStreamIndex;
      FolderIndex := Info.SubStreams[SubStreamIndex].FolderIndex;
      DecodedFolder(FolderIndex).Position := Int64(Info.SubStreams[SubStreamIndex].OffsetInFolder);
      Remaining := Info.SubStreams[SubStreamIndex].Size;
      Crc := CRC_INIT_VAL;
      while Remaining <> 0 do
      begin
        ChunkSize := SizeOf(Buffer);
        if UInt64(ChunkSize) > Remaining then
          ChunkSize := Integer(Remaining);
        ReadSize := DecodedFolder(FolderIndex).Read(Buffer, ChunkSize);
        if ReadSize <> ChunkSize then
          RaiseLzmaError(SZ_ERROR_INPUT_EOF, 'Unexpected end of decoded 7z folder');
        WriteExact(EntryStream, Buffer, ReadSize);
        Crc := Crc32Update(Crc, @Buffer[0], NativeUInt(ReadSize));
        Dec(Remaining, UInt64(ReadSize));
      end;
      if Info.SubStreams[SubStreamIndex].HasCrc and
        ((Crc xor CRC_INIT_VAL) <> Info.SubStreams[SubStreamIndex].Crc) then
        RaiseLzmaError(SZ_ERROR_CRC, '7z file CRC mismatch');
    end;
  finally
    for I := 0 to High(FolderCache) do
      FolderCache[I].Free;
  end;
  Source.Position := Info.ArchiveEndPosition;
end;

class function TLzma7z.ReadSingleFileName(Source: TStream): string;
var
  ArchiveStart: Int64;
  Info: TSevenZipArchiveInfo;
begin
  Info := ReadSevenZipArchiveInfo(Source, ArchiveStart);
  if (Length(Info.Files) <> 1) or Info.Files[0].Entry.IsDirectory then
    RaiseLzmaError(SZ_ERROR_UNSUPPORTED, '7z archive does not contain exactly one file entry');
  Result := Info.Files[0].Entry.FileName;
  Source.Position := Info.ArchiveEndPosition;
end;

end.
