# Memory

Ownership rules:

- Caller owns all `TStream` instances.
- The library never closes streams passed to public APIs.
- Raw LZMA2 level `0` copy encode/decode uses a 64 KiB maximum copy chunk.
- Raw LZMA2 levels `1..9` encode native SDK-profile LZMA chunks up to the SDK 2 MiB unpack limit when the compressed payload fits the LZMA2 64 KiB packed-size field. Copy fallback is always split into 64 KiB LZMA2 copy chunks.
- LZMA-compressed decode buffers decoded output in 256 KiB batches before writing to the caller stream.
- MT raw LZMA2 compression keeps at most `ThreadCount` encode jobs in flight. Each job reads about 64 MiB of input, or about 16 MiB when `ThreadCount >= 8`, then splits that batch into normalized LZMA2 chunks up to 2 MiB. Phase-reset periodic data can be emitted as SDK-bounded compressed chunks with later chunks preserving LZMA2 state to avoid match-finder allocation on synthetic repeated corpora. Small seekable inputs fall back to the single-thread path when there is not enough data to keep at least two MT jobs busy. Worker threads own their input bytes and encoded output bytes; only the main thread touches caller streams and progress callbacks.
- MT raw LZMA2 and XZ decode first require a seekable source, independent reset chunks or XZ blocks whose sizes are stored in the block header or recoverable from the XZ Index, and enough memory for in-flight packed units, worker output buffers, and worker decoder dictionaries. Raw LZMA2 is split from the source stream into independent units and can coalesce adjacent reset chunks into about 8 MiB scheduled units, but it still requires enough packed input work to justify worker scheduling and falls back before scheduling high-expansion tiny-packed streams. XZ MT decode reads the footer/index from the seekable stream and schedules packed block payloads without materializing the full decoded output. The ordered writer drains consecutive ready units to the caller stream. If checks fail, decode restores the source position and falls back to the single-thread path with `TLzma2DecodeDiagnostics.FallbackReason = ldfrMemoryLimit`, `ldfrNonSeekableStream`, `ldfrSingleIndependentUnit`, `ldfrUnsupportedLayout`, or `ldfrInsufficientWork`.
- XZ encode streams the source through checksum calculation and raw LZMA2 encoding, then writes the XZ index/footer after the block sizes are known. `XzBlockSize = 0` emits one block; a nonzero `XzBlockSize` emits sized independent blocks and records one XZ Index record per block. CRC32 and CRC64 use fixed 16-slice lookup tables generated at unit initialization.
- XZ decode reads the container forward block by block, including multi-block streams and blocks without a stored packed size. It writes decoded bytes directly through a checksum stream, so it does not buffer decoded blocks internally.
- Standalone `.lzma` encode/decode remains a buffered raw LZMA path because the classic container stores a single raw LZMA payload. It now applies `MemoryLimit` to the dictionary plus the required source/packed payload snapshot and raises `ELzmaMemoryError` before growing that snapshot beyond the configured limit. The low-level `TLzmaRawEncoder.Encode` stream wrapper no longer has the old 64 MiB cap for known-size or end-marker payloads; that path reads bounded input chunks, keeps raw LZMA probability state and active rep history across chunks, routes decisions through the requested HC4/HC5/BT4 native match finder, uses the native optimum-window/replay helpers for SDK-profile requests, and writes buffered range output directly to the caller stream. It is a streaming correctness path, not a byte-identical SDK `LzmaEnc.c` full-optimum compression-parity claim.

`TLzma2Options.MemoryLimit` is enforced against normalized dictionary requests where applicable and against conservative single-thread and MT in-flight estimates before compressed worker scheduling. Level `0` copy encode does not charge encoder dictionary/match-finder memory. Compressed-path estimates include active input/output chunks plus extra headroom for HC4/HC5/BT4 match-finder arrays, including SDK-sized CRC hash heads for the active window, HC5 dictionary-sized cyclic chain storage, and BT4 dictionary-sized cyclic son storage, probability tables, and range output buffers. Caller-owned output stream growth is outside the internal memory limit.
OOM and limit failures raise `ELzmaMemoryError`.

Rule-of-thumb estimates:

- ST encode: `dictionary + chunkBuffer + matchFinderTables + probabilityTables + rangeBuffer`; level `0` copy mode is limited by the 64 KiB copy chunk and caller stream growth.
- MT encode: `ThreadCount * batchInputBytes + ThreadCount * encodedBatchBytes + ThreadCount * encoderWorkingSet`, with batches currently capped near 64 MiB, or 16 MiB for `ThreadCount >= 8`.
- ST decode: `dictionary + 256 KiB output buffer + container/check state`.
- MT raw/XZ decode: `scheduledPackedBytes + activeWorkerOutputBytes + ActualThreadCount * dictionary + ordered-writer bookkeeping`; successful streaming MT paths record `InputSnapshot = False` in decode diagnostics.

Thread-safety:

- Independent calls and independent instances are safe to run in parallel.
- A single stream instance must not be shared by concurrent operations unless the caller provides synchronization.
- Progress callbacks are invoked from the caller/main path. MT decode workers only observe the shared cancellation flag raised by the main path.

Diagnostics:

- Memory-limit failures raise `ELzmaMemoryError`.
- Decode diagnostics can report whether multi-threaded decode was used and why
  a stream fell back to single-threaded decode.
- Test runs include leak and memory-limit coverage, but generated reports are
  not part of the runtime package.
