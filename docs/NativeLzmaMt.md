# Native LZMA threading

For standalone `.lzma`, set `ThreadCount` on the compression options.

```pascal
Options := TLzma2.StandaloneLzmaOptions(5);
Options.ThreadCount := 2;
TLzma2.Compress(Source, Destination, Options, Progress);
```

Normal binary-tree profiles can run match finding ahead of range encoding. Fast and hash-chain profiles use the serial path. For raw LZMA, `TLzmaRawEncoder.EncodeWithThreads` lets the caller request the threaded path. The high-level diagnostic records the requested and resolved thread counts.

The match finder passes candidate matches through a bounded queue. The encoder owns stream I/O and progress callbacks and joins its workers on completion, cancellation, or I/O failure. The encoder's memory estimate includes the queue and worker allocations.

LZMA2 handles inner LZMA workers and block workers separately. The SDK-style encoder and decoder entry points are listed in the [API registry](sdk-completion.md).
