# Release Scope

Version `26.01` tracks the LZMA SDK 26.01 baseline.

## Runtime Scope

The runtime is pure Delphi source code. It does not load `7z.dll`, `lzma.dll`,
`liblzma`, C/C++ object files, import libraries, or external compressor helper
processes.

Supported public surfaces:

- `Lzma.Api.TLzma2` stream API.
- Raw LZMA2 encode/decode.
- Standalone `.lzma` encode/decode.
- XZ encode/decode with one LZMA2 filter per block.
- Limited 7z encode/decode/list/extract for LZMA/LZMA2 archives.
- Win64 command-line and VCL GUI tools.

Out of scope:

- encrypted 7z archives;
- non-LZMA/LZMA2 7z coders;
- arbitrary multi-coder filter graphs;
- ZIP, TAR, gzip, bzip2, zstd, PPMd, AES, and unrelated archive formats.

## Public Release Assets

The public binary release contains:

- `lzma2-delphi-26.01-win64.zip`
- `lzma2-delphi-26.01-win64.zip.sha256`

The ZIP contains only:

- `Lzma2.exe`
- `Lzma2_GUI.exe`
- `sk4d.dll`
- `LICENSE`
- `THIRD-PARTY-NOTICES.md`

Source archives are provided by GitHub from the `v26.01` tag.
