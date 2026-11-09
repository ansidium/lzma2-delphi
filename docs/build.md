# Build and test

Use Windows with Delphi 13.2 (RAD Studio 37.0), the Win32 and Win64 target platforms, VCL, and PowerShell 5.1 or newer.

From the repository root, run:

```powershell
.\build.ps1 -Platform Win64 -OutputRoot .\build\win64
.\build.ps1 -Platform Win32 -OutputRoot .\build\win32
```

Choose a fresh output directory for each build. Use `-Target CLI` or `-Target GUI` to build one tool. Use `-DelphiRoot` when RAD Studio is installed outside its default location.

`build.ps1` compiles `tools/Lzma2.dpr` and `tools/Lzma2_GUI.dpr`. The executables go in `bin` under the output directory. Logs, maps, and compiler objects stay under that directory too. The IDE projects are in `tools`.

Applications that use the codec can add `src` to their unit search path. The CLI and GUI link the Delphi codec into the executables.

## Tests

```powershell
.\tests\run-ci.ps1 -Mode inner
.\tests\install-qa-tools.ps1
.\tests\run-ci.ps1 -Mode quick -RequireExternalTools $true -PerformanceWorkRoot C:\lzma2-qa
```

`inner` runs the Win64 DUnitX suite without external compression tools. `quick` also builds the Win64 tools, checks compatibility, and validates the test artifacts. The SDK and XZ reference tools are pinned in [tests/qa-tools.json](../tests/qa-tools.json). Use an owned scratch directory for the test work root.

See [release acceptance](release-acceptance.md) for the release and soak tiers and [performance](performance.md) for the benchmark procedure.
