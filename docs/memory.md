# Memory

Ownership rules:

- Caller owns all `TStream` instances.
- The library never closes streams passed to public APIs.
- Raw LZMA2 level `0` copy encode/decode uses a 64 KiB maximum copy chunk.
- Raw LZMA2 levels `1..9` encode native SDK-profile LZMA chunks up to the SDK 2 MiB unpack limit when the compressed payload fits the LZMA2 64 KiB packed-size field. Copy fallback is always split into 64 KiB LZMA2 copy chunks.
- LZMA-compressed decode writes batches up to 256 KiB. When the allocated dictionary is at least this size, pending output borrows a contiguous dictionary span and is flushed before that span wraps or is reused. Smaller dictionaries retain a separate 256 KiB output buffer to preserve write batching.
- MT raw LZMA2 compression keeps at most `ThreadCount` encode jobs in flight. Each job reads up to about 64 MiB of input and uses a streaming encoder context that preserves dictionary and probability state across LZMA2 frames within the job. Frames respect the 2 MiB unpacked and 64 KiB packed limits; each worker job starts an independent dictionary-reset unit. Small seekable inputs fall back to the single-thread path when there is not enough data to keep at least two MT jobs busy. Worker threads own their input bytes and encoded output bytes; only the main thread touches caller streams and progress callbacks.
- MT raw LZMA2 and XZ decode first require a seekable source, independent reset chunks or XZ blocks whose sizes are stored in the block header or recoverable from the XZ Index, and enough memory for in-flight packed units, worker output buffers, and worker decoder dictionaries. Raw LZMA2 is split from the source stream into independent units and can coalesce adjacent reset chunks into about 8 MiB scheduled units, but it still requires enough packed input work to justify worker scheduling and falls back before scheduling high-expansion tiny-packed streams. XZ MT decode reads the footer/index from the seekable stream and schedules packed block payloads without materializing the full decoded output. The ordered writer drains consecutive ready units to the caller stream. If checks fail, decode restores the source position and falls back to the single-thread path with `TLzma2DecodeDiagnostics.FallbackReason = ldfrMemoryLimit`, `ldfrNonSeekableStream`, `ldfrSingleIndependentUnit`, `ldfrUnsupportedLayout`, or `ldfrInsufficientWork`.
- XZ encode streams the source through checksum calculation and raw LZMA2 encoding, then writes the XZ index/footer after the block sizes are known. `XzBlockSize = 0` emits one block; a nonzero `XzBlockSize` emits sized independent blocks and records one XZ Index record per block. CRC32 and CRC64 use fixed 16-slice lookup tables generated at unit initialization.
- XZ decode reads the container forward block by block, including multi-block streams and blocks without a stored packed size. It writes decoded bytes directly through a checksum stream, so it does not buffer decoded blocks internally.
- Standalone `.lzma` encode streams known-size input and end-marker input through the native raw encoder. If the source size is unknown and `LzmaEndMarker = False`, it retains a source snapshot to obtain the size for the header. Standalone decode uses a bounded packed-input window for exact native `TMemoryStream`, `TBytesStream`, and `TFileStream` pairs when their storage is proven independent and the window fits the memory budget. Shared storage, custom streams, and uncertain file identities retain the packed payload before decoding. `BufferSize` keeps its 2 MiB default. `MemoryLimit` checks include the applicable input window or retained snapshot and encoder or decoder working buffers. The raw encoder keeps probability state and repetition history across bounded input refills and writes buffered range output directly to the caller stream. SDK-profile algorithm 1 uses a bounded online optimum workspace and borrows live probability models; algorithm 0 and explicit fast modes use the native SDK-style fast parser. The workspace is reused across queries. These paths do not imply byte-identical SDK output or compression-performance parity for every profile.

`TLzma2Options.MemoryLimit` is enforced against normalized dictionary requests where applicable and against conservative single-thread and MT in-flight estimates before compressed worker scheduling. Level `0` copy encode does not charge encoder dictionary/match-finder memory. Compressed-path estimates include active input/output chunks plus extra headroom for HC4/HC5/BT4 match-finder arrays, including SDK-sized CRC hash heads for the active window, HC5 dictionary-sized cyclic chain storage, and BT4 dictionary-sized cyclic son storage, probability tables, and range output buffers. Caller-owned output stream growth is outside the internal memory limit. This is a codec allocation budget, not a process working-set or private-commit cap; RTL thread, closure, and OS overhead are outside the worker estimates.
OOM and limit failures raise `ELzmaMemoryError`.

For known-size standalone `.lzma` streams and classic LZMA folders in 7z,
the decoder dictionary allocation is capped by the complete declared output size,
with the existing 4 KiB minimum. A solid folder uses the size of all its substreams;
classic LZMA encoded headers use the same rule. The original dictionary properties
still govern memory admission before reading the payload. Unknown-size streams,
raw LZMA2 and XZ retain their existing allocation policy.

Decoder admission remains conservative when a known output size reduces the
dictionary allocation. It covers both the declared dictionary with borrowed output
and the largest smaller dictionary that still needs a separate output buffer,
including the applicable probability models and optional partial-decode snapshot.
The estimate therefore remains monotonic across the 256 KiB output boundary.

Rule-of-thumb estimates:

- ST encode: `input/history window + matchFinderTables + probabilityTables + parser workspace + range/frame buffers`; level `0` copy mode uses copy buffers rather than encoder dictionary or match-finder storage.
- MT encode: `ThreadCount * batchInputBytes + ThreadCount * encodedBatchBytes + ThreadCount * encoderWorkingSet + worker bookkeeping`, with batches currently capped near 64 MiB. Reservations also account for overlapping old/new output buffer capacities.
- ST decode: `dictionary + decoder state/models + optional 256 KiB output buffer + container/check state`. The separate output array is allocated only when the dictionary capacity is below 256 KiB.
- MT raw/XZ decode: `scheduledPackedBytes + activeWorkerOutputBytes + ActualThreadCount * dictionary + ordered-writer bookkeeping`; successful streaming MT paths record `InputSnapshot = False` in decode diagnostics.

Thread-safety:

- Independent calls and independent instances are safe to run in parallel.
- A single stream instance must not be shared by concurrent operations unless the caller provides synchronization.
- Progress callbacks are invoked from the caller/main path. MT decode workers only observe the shared cancellation flag raised by the main path.

Diagnostics:

- Memory-limit failures raise `ELzmaMemoryError`.
- Decode diagnostics can report whether multi-threaded decode was used and why
  a stream fell back to single-threaded decode.
- Tests cover memory limits and allocation boundaries. DUnitX leak counters do
  not replace heap instrumentation or process-memory measurements. Generated
  reports are not part of the runtime package.
