# Release scope

Version 26.06 targets [LZMA SDK 26.06](https://www.7-zip.org/sdk.html). The encoder and decoder sources and API headers used by the Delphi port match those in SDK 26.05. Upstream's Linux `split` change applies to the [7-Zip archive handler](https://github.com/ip7z/7zip/compare/26.05...26.06).

## Formats and tools

The library handles raw LZMA and LZMA2, standalone `.lzma`, XZ with one LZMA2 filter per block, and 7z archives with LZMA or LZMA2 folders. The 7z subset excludes encrypted archives, other coders, and arbitrary filter chains.

`TLzma2` is the stream API. The SDK-style interfaces cover encoder and decoder handles, property records, LzmaLib, Lzma86, and the multithreaded LZMA2 pull decoder. See the [function registry](sdk-completion.md).

Each Windows package contains `Lzma2.exe`, `Lzma2_GUI.exe`, and the license notices. The VCL interface uses Windows Direct2D and includes compression, extraction, and a benchmark.

## Verification

The 26.06 codec checks compared 43,168 cases with the upstream C SDK across Win32 and Win64. They covered single and multithreaded builds, 16- and 32-bit probabilities, and checked and release builds. The comparison covered the tested API behavior and output bytes. Benchmark parity is a separate measurement.

The `quick` tier does not run `tests/run-performance.ps1`. See [release acceptance](release-acceptance.md) for the benchmark tiers.
