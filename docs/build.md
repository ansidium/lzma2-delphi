# Build Requirements

The runtime library is Delphi source code. Building the shipped tools requires
a Windows Delphi toolchain.

## Supported Build Environment

- Windows 10 / 11 x64.
- RAD Studio / Delphi 13.1 or a newer compatible Delphi compiler.
- Win64 target platform installed.
- VCL installed for `tools/Lzma2_GUI.dproj`.
- PowerShell 5.1 or newer for the test and benchmark scripts.

The runtime units in `src/` are pure Delphi source and do not require
compressor DLLs, C/C++ object files, or import libraries. Non-Windows Delphi
targets are outside the current release-tested surface.

## Tool Projects

Build these projects for `Win64` and `Release`:

- `tools/Lzma2.dproj` - command-line tool.
- `tools/Lzma2_GUI.dproj` - VCL GUI tool.

The source units live under `src/`. Applications can also add that directory
to their Delphi search path and use `Lzma.Api.TLzma2` directly.

## Tests

The main validation entry point is:

```powershell
.\tests\run-ci.ps1 -Mode inner
```

`inner` runs without external compression tools. Cross-tool and release
validation use the pinned 7-Zip/LZMA SDK and xz-utils test tools configured in
`tests/qa-tools.json`; those tools are downloaded for tests only and are not
runtime dependencies.

```powershell
.\tests\install-qa-tools.ps1
.\tests\run-ci.ps1 -Mode quick -PerformanceWorkRoot <SSD_WORKROOT>
.\tests\run-ci.ps1 -Mode release -PerformanceWorkRoot <SSD_WORKROOT>
```

Use `quick` for normal local validation and `release` only when regenerating
full cross-tool and benchmark evidence.
