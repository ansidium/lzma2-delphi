# Third-Party Notices

This repository is licensed under the MIT License, as described in `LICENSE`.
The following notices apply to third-party materials referenced by the source
tree, used by tests, or included in binary release packages.

## LZMA SDK

The implementation includes native Delphi translations of the public-domain
LZMA SDK 26.05 codec, match-finder, threading and BCJ algorithms. The corresponding sources in SDK 26.06 serve as the compatibility and test reference.

- Project: LZMA SDK
- Author: Igor Pavlov
- Website: https://www.7-zip.org/sdk.html
- License: public domain

The LZMA SDK website states that the LZMA SDK is placed in the public domain.

## fast-lzma2 Reference

[fast-lzma2](https://github.com/conor42/fast-lzma2), by Conor McCarthy, is a
design and benchmark reference for performance work. The project remains a
native Delphi implementation; fast-lzma2 is not linked or loaded at runtime.

## External QA Tools

The test and benchmark scripts can download or use external tools listed in
`tests/qa-tools.json`, including 7-Zip/LZMA SDK and xz-utils tools. Those tools
are used only for tests, fixtures, CI, and benchmarks; they are not runtime
dependencies of the library.

## Desktop benchmark reference

The synthetic LZ workload, rating formulas and initial settings reference Igor
Pavlov's 7-Zip 26.05 `CPP/7zip/UI/Common/Bench.cpp` and
`CPP/7zip/UI/GUI/BenchmarkDialog.cpp` / `.h`. The Delphi implementation independently implements the workload mathematics and
uses its own worker orchestration, memory admission and native GUI; no 7-Zip
binary, source file or object file is included or linked. The upstream reference
files are licensed under GNU LGPL 2.1 or later according to
https://github.com/ip7z/7zip/blob/26.05/DOC/License.txt . This reference attribution
does not describe all 7-Zip components as public domain.

## Application mark

The original application mark is provided as SVG, PNG sizes and Windows ICO in
the source assets. Lettering was outlined locally from the Windows Segoe UI
Semibold font; no font file or third-party compressor logo is distributed.
