# Public API

The normal entry point is `Lzma.Api.TLzma2`. It exposes stream-first methods,
file helpers, and option factories for the common containers. Most applications
should start with these helpers instead of filling every `TLzma2Options` field
manually.

## Common Recipes

### XZ File

```pascal
uses
  Lzma.Api,
  Lzma.Types;

var
  Options: TLzma2Options;
begin
  Options := TLzma2.XzOptions(6, 4, lzCheckCrc64);
  TLzma2.CompressFile('data.bin', 'data.xz', Options);
  TLzma2.DecompressFile('data.xz', 'data.out', Options);
end;
```

### Raw LZMA2 Stream

```pascal
var
  Options: TLzma2Options;
begin
  Options := TLzma2.RawLzma2Options(6, 1);
  TLzma2.Compress(SourceStream, PackedStream, Options);
  PackedStream.Position := 0;
  TLzma2.Decompress(PackedStream, OutputStream, Options);
end;
```

### Standalone LZMA

```pascal
var
  Options: TLzma2Options;
begin
  Options := TLzma2.StandaloneLzmaOptions(6, False);
  TLzma2.CompressFile('data.bin', 'data.lzma', Options);
  TLzma2.DecompressFile('data.lzma', 'data.out', Options);
end;
```

Set `EndMarker` to `True` when writing an SDK end-marker stream instead of a
known unpack-size standalone LZMA stream.

### Single-File 7z

```pascal
var
  Options: TLzma2Options;
begin
  Options := TLzma2.SevenZipOptions('', 6, 2);
  TLzma2.CompressFile('data.bin', 'data.7z', Options);
end;
```

When `ArchiveFileName` is empty, `CompressFile` stores
`ExtractFileName(SourceFileName)` in the 7z metadata.

### Factory Shortcuts

```pascal
var
  Options: TLzma2Options;
begin
  Options := TLzma2.DefaultOptionsFor(lcXz, 6, 1);
  Options := TLzma2.FastOptionsFor(lcRawLzma2, 4); // level 1
  Options := TLzma2.MaxOptionsFor(lcXz, 4);        // level 9
end;
```

For stream methods, ownership stays with the caller. The library does not close input or output streams. File helpers open and close their own `TFileStream` instances. Single-thread raw LZMA2, standalone `.lzma`, and XZ encode/decode paths operate forward over the source stream and are covered with `TStream` contract tests where the format permits it. The `lcLzma` path writes the classic 13-byte standalone LZMA header, encodes either a known unpack size or an SDK end marker via `LzmaEndMarker`, decodes known-size streams, and decodes unknown-size streams through the SDK end marker. The `lc7z` encoder needs a seekable destination because the 7z signature header is patched after the packed stream and header sizes are known; it writes one LZMA2 folder/coder. `TLzma2.Decompress` remains a single-file 7z stream API and rejects multi-entry archives instead of concatenating files. `Lzma.SevenZip.TLzma7z.List` and `ExtractAll` provide the archive API for multi-entry LZMA/LZMA2 7z files, including directories, empty files, multiple folders/pack streams, solid substreams, CRC metadata, and unencoded or LZMA/LZMA2-encoded headers. Multi-threaded decode uses seekable input when it can split independent raw LZMA2 reset chunks or XZ blocks; unsuitable and non-seekable sources fall back to single-thread decode.
Async calls return a started `System.Threading.ITask`; the caller must keep both streams alive and not use them concurrently until the task has completed. Progress callbacks run on the task/worker thread, so UI code should marshal or poll state instead of touching controls directly.
XZ decompression streams decoded bytes to the destination while calculating the block check; if a later block check fails, the destination may already contain bytes written before the error.

Progress callbacks receive total input and output bytes and can cancel by setting `Cancel := True`.
Cancellation raises `ELzmaCancelled`.

## Advanced Options

`TLzma2Options` remains public for callers that need to mirror CLI settings or
fine-tune encoder internals. The option factories initialize the normal fields;
advanced callers can then override specific values:

```pascal
Options := TLzma2.XzOptions(6, 4, lzCheckCrc64);
Options.DictionarySize := 64 * 1024 * 1024;
Options.FastBytes := 64;        // 0 keeps the level default; otherwise 5..273
Options.CutValue := 32;         // 0 keeps the level default match-finder cycles
Options.Lc := -1;               // -1 keeps SDK defaults; explicit lc/lp/pb are supported
Options.Lp := -1;
Options.Pb := -1;
Options.XzBlockSize := 0;       // 0 keeps the streaming single-block writer
Options.ParserMode := lpmSdkProfile;
Options.MatchFinderProfile := lmfpAuto;
```

For `lc7z`, `ArchiveFileName` controls the stored file name. For `lcLzma`,
`LzmaEndMarker` selects known-size standalone output (`False`) or SDK end-marker
output (`True`).

Decode diagnostics are opt-in through `TLzma2Options.DecodeDiagnostics`:

```pascal
var
  Diagnostics: TLzma2DecodeDiagnostics;

FillChar(Diagnostics, SizeOf(Diagnostics), 0);
Options.ThreadCount := 4;
Options.DecodeDiagnostics := @Diagnostics;
TLzma2.Decompress(SourceStream, DestinationStream, Options);

// Diagnostics.RequestedThreadCount, ActualThreadCount,
// IndependentUnitCount, UsedMultiThread, and FallbackReason
// describe the mode that was actually used.
```

Level `0` uses LZMA2 copy chunks. Levels `1..9` use the native LZMA range encoder inside LZMA2 chunks. The project targets format compatibility, correct round-trips, strong ratio, and high throughput rather than byte-identical compressed output.

Typed exceptions are declared in `Lzma.Errors`:

- `ELzmaInvalidParameter`
- `ELzmaUnsupportedProperties`
- `ELzmaDataError`
- `ELzmaInputEof`
- `ELzmaOutputEof`
- `ELzmaReadError`
- `ELzmaWriteError`
- `ELzmaChecksumError`
- `ELzmaMemoryError`
- `ELzmaCancelled`
- `ELzmaThreadError`

Advanced and low-level modules expose:

- `Lzma2.Encoder.TLzma2Encoder.EncodeRaw`
- `Lzma2.Decoder.TLzma2Decoder.DecodeRaw`
- `Lzma.Encoder` records and parser helpers, which are internal/advanced
  building blocks for the native encoder rather than the recommended first-use
  API
- `Lzma.Sdk` for a Delphi-native SDK-style facade with `SRes` return
  codes, `ILzmaSeqInStream`, `ILzmaSeqOutStream`, `ILzmaCompressProgress`,
  `ILzmaAllocator` / `TLzmaSdkSystemAllocator`, LZMA/LZMA2 props
  init/normalize/write helpers, and LZMA/LZMA2 encoder/decoder lifecycle
  objects. This facade mirrors SDK call semantics for native Delphi callers;
  it is not a C ABI wrapper, and it routes compression through the native
  encoder core. The allocator surface is available for reference-style flows.
  `TLzmaSdkLzma2Encoder`,
  `TLzmaSdkLzmaDecoder`, and `TLzmaSdkLzma2Decoder` stream through
  `ILzmaSeqInStream` / `ILzmaSeqOutStream` adapters where the underlying native
  path supports it. `TLzmaSdkLzmaEncoder` uses the seq-in adapter and buffered
  sink-backed range output for known-size and end-marker raw LZMA payloads, while
  still honoring partial `ISeqOutStream.Write` progress and preserving non-OK
  callback `SRes` values. That streaming raw LZMA facade path keeps probability
  state across bounded input chunks and routes decisions through the requested
  HC4/HC5/BT4 native match finder. SDK-profile requests use the native optimum
  window/replay helpers; high-speed requests use the greedy parser. This path is
  still not claimed as byte-identical SDK `LzmaEnc.c` full-optimum compression
  parity. `TLzmaSdkLzmaDec` and
  `TLzmaSdkLzma2Dec` expose SDK-style allocate/init/decode-to-buf/decode-to-dic
  lifecycle calls with `TLzmaFinishMode`, `TLzmaStatus`, and `SRes` results.
  The lifecycle decoders buffer partial caller input across calls; known-size
  LZMA can yield prefix output before the packed stream is complete and still
  reports the exact consumed payload boundary when trailing bytes are present.
  LZMA2 uses embedded decode semantics so `SrcLen` stops at the LZMA2 EOF
  marker and does not consume trailing bytes. For LZMA2 encoding, `BlockSize` maps
  to the raw LZMA2 chunk buffer size and block/total thread props constrain the
  native encoder thread count without exceeding the requested total.
- `Lzma.MtDec.TLzmaMtDecode` for ordered independent-unit decode scheduling
- `Lzma.Decoder.TLzmaRawDecoder.Decode` for known-size standalone raw LZMA
- `Lzma.Decoder.TLzmaRawDecoder.DecodeUntilEndMarker` for standalone raw LZMA streams that use the SDK end marker
- `Lzma.Lzma.TLzmaStandalone.Encode` and `Decode` for first-class `.lzma`
  container handling
- `Lzma.MatchFinder.TLzmaGreedyMatchFinder` for low-level greedy match probing
- `Lzma.Xz.TLzmaXz.Encode` for XZ streams with one LZMA2 filter per block
- `Lzma.Xz.TLzmaXz.Decode` for XZ streams with one LZMA2 filter per block
- `Lzma.SevenZip.TLzma7z.Encode` and `Decode` for single-file `.7z`
  archives with one LZMA2 encode folder, LZMA/LZMA2 decode folders, and an
  unencoded or LZMA/LZMA2-encoded header
- `Lzma.SevenZip.TLzma7z.EncodeEntries` for non-solid multi-entry `.7z`
  archives with one LZMA2 or LZMA folder per non-empty file entry
- `Lzma.SevenZip.TLzma7z.List` and `ExtractAll` for multi-entry `.7z`
  extraction via caller-provided output streams
- `Lzma.Types` helpers for LZMA/LZMA2 properties and XZ varints
- `Lzma.XzCrc` helpers for CRC32, CRC64, and SHA-256 checks

Tool projects:

- `tools/Lzma2.dproj` is the console tool.
- `tools/Lzma2_GUI.dproj` is the VCL GUI tool that runs compression/decompression through the async API and keeps caller-owned streams alive until the task completes.
