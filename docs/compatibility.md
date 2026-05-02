# Compatibility

This project implements native Delphi LZMA, LZMA2, XZ, and a limited 7z surface.
The runtime does not load compressor DLLs, link C/C++ object files, or spawn
external compressor processes.

## Supported Formats

- Raw LZMA2 streams.
- Standalone `.lzma` streams with the classic SDK-compatible 13-byte header.
- `.xz` streams with one LZMA2 filter per block.
- `.7z` archives that use LZMA or LZMA2 folders/coders.

## XZ

Supported XZ features:

- stream checks `none`, `crc32`, `crc64`, and `sha256`;
- one LZMA2 filter per block;
- single-block and multi-block streams;
- stream padding;
- concatenated XZ streams;
- multi-threaded decode when independent blocks can be scheduled safely.

Unsupported XZ features fail closed with typed exceptions.

## 7z

Supported 7z features:

- LZMA and LZMA2 single-coder folders;
- CRC metadata;
- directories and empty files;
- multiple files and non-solid archives through `TLzma7z`;
- solid LZMA/LZMA2 substreams for extraction;
- unencoded, LZMA-encoded, and LZMA2-encoded headers.

Intentionally unsupported 7z features:

- encrypted archives;
- non-LZMA/LZMA2 coders;
- multi-coder filter graphs;
- AES, PPMd, ZIP, TAR, gzip, bzip2, zstd, and unrelated formats.

## Interoperability

Compatibility tests cover these directions where the format supports them:

- Delphi-generated XZ tested by 7-Zip and xz-utils.
- 7-Zip/xz-utils-generated XZ decoded by Delphi.
- Delphi-generated standalone `.lzma` decoded by the LZMA SDK tool.
- LZMA SDK-generated standalone `.lzma` decoded by Delphi.
- Delphi-generated 7z archives tested and extracted by 7-Zip.
- 7-Zip-generated LZMA/LZMA2 7z archives listed and extracted by Delphi.

External tools are used only by tests, fixtures, CI, and benchmarks. The pinned
tool versions and hashes are configured in `tests/qa-tools.json`.

## Error Behavior

Malformed chunks, bad checksums, truncated input, unsupported filters, and
unsupported 7z coders fail closed with typed exceptions from `Lzma.Errors`.
Raw LZMA2 has no container checksum by design; use XZ or 7z when archive-level
integrity metadata is required.
