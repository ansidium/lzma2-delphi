# Release Acceptance

Use `quick` for normal local validation:

```powershell
tests/run-ci.ps1 -Mode quick -PerformanceWorkRoot <SSD_WORKROOT>
```

`quick` mode does not run `tests/run-performance.ps1`; it builds the Win64
tools, runs DUnitX, cross-tool smoke checks, and artifact contract validation.

Use `release` when regenerating full benchmark evidence:

```powershell
tests/run-ci.ps1 -Mode release -PerformanceWorkRoot <SSD_WORKROOT>
tests/run-ci.ps1 -Mode release -PerformanceWorkRoot <SSD_WORKROOT> -RamWorkRoot <RAM_WORKROOT>
```

Release and soak validation use the pinned QA tools from `tests/qa-tools.json`,
including `7zr.exe`, xz-utils, and the LZMA SDK reference executable. Runtime
purity checks verify that shipped binaries do not depend on those tools.

Benchmark evidence is a data-only benchmark artifact set under
`artifacts/perf/`. Release validation rejects graph artifacts such as
`lzma2-delphi-graph.*`; charts should be generated separately from the CSV/JSON
data when needed.

GitHub Actions metadata when present must include the run id/SHA/ref/attempt
and workflow name so release evidence can be traced back to the exact run.
