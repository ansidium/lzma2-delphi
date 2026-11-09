# Desktop LZMA benchmark

The third GUI mode benchmarks the native Delphi engine using reproducible
LZ-style data. It has current and average compression/extraction speed (KiB/s),
process CPU usage (%), CPU-normalized rating (R/U, MIPS), rating (MIPS), a combined
rating, elapsed time, completed passes and resolved worker count. Copy exports
actual configuration and paired completed-pass averages.

## Defaults and memory

The initial dictionary is 32 MiB and pass count is 10, following
[7-Zip 26.05 BenchmarkDialog.cpp](https://github.com/ip7z/7zip/blob/26.05/CPP/7zip/UI/GUI/BenchmarkDialog.cpp#L490)
and [BenchmarkDialog.h](https://github.com/ip7z/7zip/blob/26.05/CPP/7zip/UI/GUI/BenchmarkDialog.h#L9).
Auto uses the effective process affinity CPU count and admits workers against
MemoryLimit, without a 128-worker cap. The ordinary list ends at the effective
logical processor count; Other accepts larger positive Integer values. If even
one worker cannot fit at startup, the initial dictionary
steps down through the available presets. An explicitly chosen setting is never
silently rewritten when Start is pressed.

The GUI budget is half of available physical and virtual memory, whichever is
smaller. Each worker is admitted using the engine's streaming memory estimate,
bounded outer data/output/decode buffers and allocator/RTL headroom. Manual
worker counts remain subject to this budget; Start is disabled when they exceed
it. This is an admission estimate rather than a Windows process working-set cap.

## Measurement

Each independent worker uses standalone LZMA level 5, a 1 MiB I/O buffer and its
own deterministic data. Both phases run at least one second per pass. This
worker arrangement differs from 7-Zip's internal encoder threading; benchmark
scores are useful for this program and are not an assertion of identical 7-Zip
workloads, speed parity, or file-compression performance.

Wall time uses QueryPerformanceCounter; CPU time uses process kernel + user time
from GetProcessTimes. CPU usage is total process CPU seconds / wall seconds ×100,
so it can exceed 100% and includes GUI/process work, as does the Windows 7-Zip
process timer. Speeds are unpacked bytes / wall seconds / 1024.

Rating formulas and synthetic workload reference:
[7-Zip 26.05 Bench.cpp](https://github.com/ip7z/7zip/blob/26.05/CPP/7zip/UI/Common/Bench.cpp).
Compression commands per byte use 870 + 5×(logSub(dictionary)−18×256)² / 65536;
extraction commands use 190×raw compressed payload bytes + 4×unpacked bytes.
Rating = commands / wall seconds / 1,000,000. R/U = commands / process CPU seconds
/ 1,000,000. Averages sum bytes, commands and times across paired completed
passes. An incomplete canceled pass does not enter averages; every decoded
buffer must match the generated input.

The benchmark runs on dedicated workers. The UI polls snapshots every 100 ms;
Stop requests cancellation, and close joins all workers before exit. Settings
are disabled while measurement is active. No compressor helper process or
external compression DLL is involved.
