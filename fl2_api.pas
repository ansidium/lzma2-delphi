unit FL2API;

interface

uses
  System.SysUtils;

const
  LibFL2 = 'fast-lzma2.dll';

function FL2_versionNumber: Cardinal; cdecl; external LibFL2;
function FL2_versionString: PAnsiChar; cdecl; external LibFL2;
function FL2_compress(dst: Pointer; dstCapacity: NativeUInt; const src: Pointer; srcSize: NativeUInt; compressionLevel: Integer): NativeUInt; cdecl; external LibFL2;
function FL2_compressMt(dst: Pointer; dstCapacity: NativeUInt; const src: Pointer; srcSize: NativeUInt; compressionLevel: Integer; nbThreads: Cardinal): NativeUInt; cdecl; external LibFL2;
function FL2_decompress(dst: Pointer; dstCapacity: NativeUInt; const src: Pointer; compressedSize: NativeUInt): NativeUInt; cdecl; external LibFL2;
function FL2_decompressMt(dst: Pointer; dstCapacity: NativeUInt; const src: Pointer; compressedSize: NativeUInt; nbThreads: Cardinal): NativeUInt; cdecl; external LibFL2;
function FL2_findDecompressedSize(const src: Pointer; srcSize: NativeUInt): UInt64; cdecl; external LibFL2;
function FL2_compressBound(srcSize: NativeUInt): NativeUInt; cdecl; external LibFL2;
function FL2_isError(code: NativeUInt): Boolean; cdecl; external LibFL2;
function FL2_isTimedOut(code: NativeUInt): Boolean; cdecl; external LibFL2;
function FL2_getErrorName(code: NativeUInt): PAnsiChar; cdecl; external LibFL2;

function CompressBuffer(const Src; SrcSize: NativeUInt; var Dst; DstCapacity: NativeUInt; Level: Integer; NbThreads: Cardinal = 0): NativeUInt;
function DecompressBuffer(const Src; CompressedSize: NativeUInt; var Dst; DstSize: NativeUInt; NbThreads: Cardinal = 0): NativeUInt;

implementation

function CompressBuffer(const Src; SrcSize: NativeUInt; var Dst; DstCapacity: NativeUInt; Level: Integer; NbThreads: Cardinal): NativeUInt;
begin
  if NbThreads <= 1 then
    Result := FL2_compress(@Dst, DstCapacity, @Src, SrcSize, Level)
  else
    Result := FL2_compressMt(@Dst, DstCapacity, @Src, SrcSize, Level, NbThreads);
end;

function DecompressBuffer(const Src; CompressedSize: NativeUInt; var Dst; DstSize: NativeUInt; NbThreads: Cardinal): NativeUInt;
begin
  if NbThreads <= 1 then
    Result := FL2_decompress(@Dst, DstSize, @Src, CompressedSize)
  else
    Result := FL2_decompressMt(@Dst, DstSize, @Src, CompressedSize, NbThreads);
end;

end.

