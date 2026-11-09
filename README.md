# LZMA2 Delphi

A pure Delphi port of [LZMA SDK 26.06](https://www.7-zip.org/sdk.html) for Windows x86 and x64. Use the `TLzma2` stream API in a Delphi project, or run the command-line tool and VCL application from [GitHub Releases](https://github.com/ansidium/lzma2-delphi/releases).

| Format | Support |
| --- | --- |
| Raw LZMA and LZMA2 | Encode and decode through the SDK API. The CLI also handles raw LZMA2. |
| Standalone `.lzma` | Encode and decode. |
| XZ | One LZMA2 filter per block. Supports multiple blocks and the None, CRC32, CRC64, and SHA-256 checks. |
| 7z | LZMA and LZMA2 folders, including archives with multiple files, solid substreams, and encoded headers. |

The 7z reader supports a subset of the 7z format. See [format limits](docs/release-scope.md).

## Windows tools

Unzip the package for your architecture. `Lzma2_GUI.exe` opens the compression, extraction, and benchmark interface. `Lzma2.exe` runs from a terminal.

```powershell
.\Lzma2.exe a data.xz data.bin -txz -mx=1 -mmt=4 -mcheck=crc64
.\Lzma2.exe t data.xz -txz
.\Lzma2.exe x data.xz restored.bin -txz
```

Run `.\Lzma2.exe --help` for switches and `.\Lzma2.exe --version` for build details.

## Delphi API

Add `src` to the project's unit search path. Import `Lzma.Api` and `Lzma.Types`, then pass your streams to `TLzma2`.

```pascal
Options := TLzma2.XzOptions(1, 4, lzCheckCrc64);
TLzma2.Compress(SourceStream, PackedStream, Options);
PackedStream.Position := 0;
TLzma2.Decompress(PackedStream, OutputStream, Options);
```

The caller owns the streams. `Lzma.Sdk` exposes the SDK-style properties and low-level encoder and decoder calls. The codec runs as Delphi code in the calling process.

## Build

Use Delphi 13.2 with the Win32 and Win64 target platforms and VCL installed.

```powershell
.\build.ps1 -Platform Win64 -OutputRoot .\build\win64
.\build.ps1 -Platform Win32 -OutputRoot .\build\win32
```

The executables are in each output directory's `bin` folder. See [build and test instructions](docs/build.md).

## Documentation

- [Stream API](docs/api.md) and [compression options](docs/options.md)
- [SDK function registry](docs/sdk-completion.md) and [property records](docs/Sdk26Properties.md)
- [Compatibility](docs/compatibility.md), [memory limits](docs/memory.md), and [benchmark](docs/benchmark.md)
- [MIT license](LICENSE) and [third-party notices](THIRD-PARTY-NOTICES.md)
