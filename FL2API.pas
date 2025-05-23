unit FL2API;

interface

uses
  System.SysUtils, FL2Common;

function CompressBuffer(const src; srcSize: NativeUInt; var dst; dstCapacity: NativeUInt; level: Integer; threads: Cardinal = 0): NativeUInt;
function DecompressBuffer(const src; srcSize: NativeUInt; var dst; dstCapacity: NativeUInt; threads: Cardinal = 0): NativeUInt;
function FL2_findDecompressedSize(src: Pointer; srcSize: NativeUInt): UInt64;
function FL2_getDictSizeFromProp(prop: Byte): NativeUInt;

implementation

const
  LZMA2_CONTROL_LZMA = 1 shl 7;

function LZMA2_IS_UNCOMPRESSED_STATE(control: Byte): Boolean; inline;
begin
  Result := (control and LZMA2_CONTROL_LZMA) = 0;
end;

function LZMA2_GET_LZMA_MODE(control: Byte): Byte; inline;
begin
  Result := (control shr 5) and 3;
end;

function LZMA2_IS_THERE_PROP(mode: Byte): Boolean; inline;
begin
  Result := mode >= 2;
end;

type
  TLZMA2ParseRes = (
    CHUNK_MORE_DATA,
    CHUNK_CONTINUE,
    CHUNK_DICT_RESET,
    CHUNK_FINAL,
    CHUNK_ERROR
  );

  TLZMA2Chunk = record
    PackSize: NativeUInt;
    UnpackSize: NativeUInt;
  end;

function LZMA2_parseInput(in_buf: PByte; pos: NativeUInt; len: NativeInt; var inf: TLZMA2Chunk): TLZMA2ParseRes;
var
  control: Byte;
  hasProp: Boolean;
begin
  inf.PackSize := 0;
  inf.UnpackSize := 0;

  if len <= 0 then
    Exit(CHUNK_ERROR);

  control := in_buf[pos];
  if control = 0 then
  begin
    inf.PackSize := 1;
    Exit(CHUNK_FINAL);
  end;

  if len < 3 then
    Exit(CHUNK_MORE_DATA);

  if LZMA2_IS_UNCOMPRESSED_STATE(control) then
  begin
    if control > 2 then
      Exit(CHUNK_ERROR);
    inf.UnpackSize := (NativeUInt(in_buf[pos + 1]) shl 8) or in_buf[pos + 2];
    Inc(inf.UnpackSize);
    inf.PackSize := 3 + inf.UnpackSize;
  end
  else
  begin
    hasProp := LZMA2_IS_THERE_PROP(LZMA2_GET_LZMA_MODE(control));
    if len < 5 + Ord(hasProp) then
      Exit(CHUNK_MORE_DATA);
    inf.UnpackSize := (NativeUInt(control and $1F) shl 16) or
                      (NativeUInt(in_buf[pos + 1]) shl 8) or
                      in_buf[pos + 2];
    Inc(inf.UnpackSize);
    inf.PackSize := 5 + Ord(hasProp) +
                    (NativeUInt(in_buf[pos + 3]) shl 8) +
                    in_buf[pos + 4] + 1;
    if LZMA2_GET_LZMA_MODE(control) = 3 then
      Exit(CHUNK_DICT_RESET);
  end;

  Result := CHUNK_CONTINUE;
end;

const
  LZMA2_CONTENTSIZE_ERROR = UInt64(-1);

function LZMA2_getUnpackSize(src: PByte; src_len: NativeUInt): UInt64;
var
  unpack_total: UInt64;
  pos: NativeUInt;
  chunk: TLZMA2Chunk;
  res: TLZMA2ParseRes;
begin
  unpack_total := 0;
  pos := 1;
  while pos < src_len do
  begin
    res := LZMA2_parseInput(src, pos, src_len - pos, chunk);
    if res = CHUNK_FINAL then
      Exit(unpack_total);
    Inc(pos, chunk.PackSize);
    if (res = CHUNK_ERROR) or (res = CHUNK_MORE_DATA) then
      Break;
    Inc(unpack_total, chunk.UnpackSize);
  end;
  Result := LZMA2_CONTENTSIZE_ERROR;
end;

function LZMA2_getDictSizeFromProp(dict_prop: Byte): NativeUInt;
begin
  if dict_prop > 40 then
    Exit(NativeUInt(-Ord(FL2_error_corruption_detected)));
  if dict_prop = 40 then
    Result := NativeUInt(-1)
  else
    Result := (2 or (dict_prop and 1)) shl (dict_prop div 2 + 11);
end;

function FL2_findDecompressedSize(src: Pointer; srcSize: NativeUInt): UInt64;
begin
  Result := LZMA2_getUnpackSize(PByte(src), srcSize);
end;

function FL2_getDictSizeFromProp(prop: Byte): NativeUInt;
begin
  Result := LZMA2_getDictSizeFromProp(prop);
end;

function CompressBuffer(const src; srcSize: NativeUInt; var dst; dstCapacity: NativeUInt; level: Integer; threads: Cardinal): NativeUInt;
begin
  // Placeholder implementation - compression algorithm not yet ported
  if srcSize > dstCapacity then
    Exit(NativeUInt(-Ord(FL2_error_dstSize_tooSmall)));
  Move(src, dst, srcSize);
  Result := srcSize;
end;

function DecompressBuffer(const src; srcSize: NativeUInt; var dst; dstCapacity: NativeUInt; threads: Cardinal): NativeUInt;
begin
  // Placeholder implementation - decompression algorithm not yet ported
  if srcSize > dstCapacity then
    Exit(NativeUInt(-Ord(FL2_error_dstSize_tooSmall)));
  Move(src, dst, srcSize);
  Result := srcSize;
end;

end.
