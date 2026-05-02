# lzma2-delphi

![Delphi Win64](https://img.shields.io/badge/Delphi%20Win64-inner%20passing-brightgreen)
![SDK baseline](https://img.shields.io/badge/LZMA%20SDK-26.01-blue)
![Runtime](https://img.shields.io/badge/runtime-pure%20Delphi-brightgreen)
![Platform](https://img.shields.io/badge/platform-Win64-lightgrey)

Native Delphi LZMA, LZMA2, XZ, and limited 7z implementation aligned with
7-Zip/LZMA SDK 26.01. The runtime is source-only Delphi code: it does not load
`7z.dll`, `lzma.dll`, `liblzma`, `.obj`, `.lib`, or spawn compressor helper
processes at runtime.

This project is intended for applications that need a Delphi-native compression
stack with stream APIs, deterministic release tooling, cross-tool compatibility
tests, and reproducible performance evidence.

## Highlights

- `TStream` first API through `TLzma2` and Delphi-native SDK facade calls in
  `Lzma.Sdk`.
- Raw LZMA2, raw/standalone LZMA, XZ with one LZMA2 filter per block, and 7z
  archives using LZMA/LZMA2 folders.
- Multi-threaded LZMA2 encode with deterministic output ordering.
- Multi-threaded raw LZMA2 and XZ decode for independent reset chunks/blocks,
  with ordered output and explicit fallback diagnostics.
- XZ checks: `none`, `crc32`, `crc64`, and `sha256`.
- CLI and VCL tools under `tools/`, plus DUnitX, cross-tool, benchmark, and
  release-validator tiers under `tests/`.
- Runtime purity audit: external 7-Zip/xz/LZMA SDK tools are allowed only in
  tests, fixtures, CI, and benchmarks.

## Format Support

| Format | Encode | Decode | Notes |
| --- | --- | --- | --- |
| Raw LZMA2 | Yes | Yes | Native stream API and CLI `-tlzma2`/`-traw` paths. |
| Raw LZMA | Yes | Yes | SDK fixture and compatibility surface. |
| Standalone `.lzma` | Yes | Yes | Classic SDK properties, dictionary, and size header. |
| XZ `.xz` | Yes | Yes | One LZMA2 filter per block; multi-block decode supported. |
| 7z `.7z` | Yes | Yes | LZMA/LZMA2 folders, multi-entry archives, directories, empty files, solid substreams, and encoded headers. |

Out of scope: encrypted 7z archives, non-LZMA/LZMA2 7z coders, arbitrary 7z
filter graphs, ZIP, TAR, gzip, bzip2, zstd, PPMd, and AES.

## Install

Add the `src` units to your Delphi project search path or include the units
directly. The public API is intentionally small:

```pascal
uses
  System.Classes,
  Lzma.Api,
  Lzma.Types;

var
  Options: TLzma2Options;
begin
  Options := TLzma2.DefaultOptions;
  Options.Container := lcXz;
  Options.Level := 1;
  Options.DictionarySize := 1 shl 20;
  Options.ThreadCount := 4;
  Options.Check := lzCheckCrc64;

  TLzma2.Compress(SourceStream, DestinationStream, Options);
  TLzma2.Decompress(SourceStream, DestinationStream, Options);
end;
```

Stream ownership stays with the caller. The library never closes caller-owned
input or output streams.

## CLI Quick Start

Build `tools/Lzma2.dproj` for Win64 Release, then use the 7-Zip-style command
surface:

```powershell
.\Lzma2.exe a data.xz data.bin -txz -mx=1 -md=1m -mmt=4 -mcheck=crc64
.\Lzma2.exe t data.xz -txz
.\Lzma2.exe x data.xz unpacked.bin -txz

.\Lzma2.exe a data.lzma data.bin -tlzma -mx=1 -md=1m
.\Lzma2.exe a tree.7z .\data-dir -t7z -mx=1 -md=1m -m0=LZMA2:d=1m
.\Lzma2.exe x tree.7z -o.\out -t7z

.\Lzma2.exe benchmark silesia.tar -T2 -D2 -1 -e9 -i2 -t3 -txz
.\Lzma2.exe --version
```

Common switches:

| Switch | Purpose |
| --- | --- |
| `-txz`, `-tlzma`, `-t7z`, `-traw`, `-tlzma2` | Container selection. |
| `-mx=N`, `-mxN` | Compression level `0..9`. |
| `-md=SIZE`, `-mdSIZE` | Dictionary size, for example `1m`, `64m`, `4g`. |
| `-mmt=N`, `-mmtN`, `-mmt=on` | Requested worker count. |
| `-m0=LZMA2|LZMA[:d=SIZE][:mt=N][:fb=N][:mc=N][:mf=hc4|hc5|bt4]` | 7z method settings. |
| `-mcheck=none|crc32|crc64|sha256`, `-scrcCRC64` | XZ check selection. |
| `-ms=SIZE` | Native multi-block XZ output block size. |
| `-o{dir}`, `-spod`, `-spoc`, `-spor` | Output-path modes. |
| `--progress`, `--no-progress`, `--help`, `--version` | CLI ergonomics. |

The legacy script-compatible form remains available:

```powershell
.\Lzma2.exe compress input.bin output.xz xz 1 1048576 4 crc64
.\Lzma2.exe decompress output.xz roundtrip.bin xz
```

## Performance Snapshot

Measured on 2026-05-02 with Delphi 13.1 Win64 and the official LZMA SDK 26.01
`7zr.exe` baseline on an AMD Ryzen 9 9950X3D. Throughput is end-to-end MiB/s.
Ratio is `compressed / original`, lower is better.

| Workload | Operation | Threads | Native Delphi | LZMA SDK 26.01 | Native ratio | SDK ratio |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `repeat5-256m`, XZ/LZMA2 level 1 | Encode | 1 | `807.6 MiB/s` | `463.8 MiB/s` | `39,356 B` (`0.0147%`) | `40,140 B` (`0.0150%`) |
| `repeat5-256m`, XZ/LZMA2 level 1 | Encode | 32 requested / 4 actual | `1391.3 MiB/s` | `463.8 MiB/s` | `39,628 B` (`0.0148%`) | `40,140 B` (`0.0150%`) |
| `repeat5-256m`, XZ/LZMA2 level 1 | Decode | 1 | `1299.5 MiB/s` | `1185.2 MiB/s` | `39,360 B` (`0.0147%`) | `40,140 B` (`0.0150%`) |
| `mixed-256m`, XZ/LZMA2 8 MiB blocks | Decode | 16 | `207.3 MiB/s` | `94.3 MiB/s` | `194.7 MiB` (`76.07%`) | `194.7 MiB` (`76.07%`) |

## Quality Gates

Use the same tiers as CI:

```powershell
.\tests\run-ci.ps1 -Mode inner
.\tests\run-ci.ps1 -Mode quick -PerformanceWorkRoot <PERFORMANCE_WORK_ROOT>
.\tests\run-ci.ps1 -Mode release -PerformanceWorkRoot <PERFORMANCE_WORK_ROOT>
```

The release tier validates DUnitX, cross-tool compatibility, runtime purity,
artifact manifests, SDK trace evidence, malformed-format behavior, and
performance gates against the configured 7-Zip/LZMA SDK 26.01 and xz-utils
tools from `tests/qa-tools.json`.

Performance evidence is intentionally data-only:

- `artifacts/perf/lzma2-benchmark.csv`
- `artifacts/perf/lzma2-benchmark.json`
- `artifacts/perf/lzma2-benchmark.samples.csv`
- `artifacts/perf/lzma2-benchmark.summary.json`

Charts are generated outside release validation from those files.

## Release

Current project version: `26.01`, matching the LZMA SDK baseline.

The public release asset set is:

- `lzma2-delphi-26.01-win64.zip`
- `lzma2-delphi-26.01-win64.zip.sha256`

The ZIP contains only the Win64 command-line and GUI binaries:
`Lzma2.exe` and `Lzma2_GUI.exe`.

## Documentation

- `docs/api.md` - public API and examples.
- `docs/build.md` - compiler, platform, and test requirements.
- `docs/options.md` - option semantics and normalization.
- `docs/compatibility.md` - format scope and cross-tool behavior.
- `docs/memory.md` - memory accounting.
- `docs/performance.md` - benchmark and artifact methodology.
- `docs/release-scope.md` - public release scope and assets.
