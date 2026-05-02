# Options

`TLzma2Options.Level` accepts `0..9`.

Native behavior:

- Level `0` emits LZMA2 copy chunks.
- Levels `1..9` emit native LZMA-compressed LZMA2 chunks. Independent raw
  chunks carry reset-dictionary/reset-state/properties framing (`$E0..$FF`);
  safe literal-only continuation chunks can use SDK-style no-props/reset-state
  framing after the first properties chunk.

The native SDK-profile encoder is deterministic and produces standard LZMA2 data. Its active match finder exposes increasing match pairs, SDK CRC-based `h2`/`h3` low hashes, SDK hash-mask sizing for the active window, SDK-style `cutValue` search-depth caps, an HC5 path with `h5` main-chain matches, dictionary-sized cyclic chain storage, and monotonic skip insertion for SDK `numHashBytes = 5` HC profiles, and a BT4 path with `h4` binary-tree traversal that starts from the newest hash head, stops at dictionary-window boundaries, and stores sons in a dictionary-sized cyclic buffer. The HC4 finder remains covered as a low-level regression path and uses the same SDK CRC hash helpers. The encoder mirrors the decoder's rep probability families (`isRepG0/G1/G2`, `isRep0Long`). The SDK-profile parser path uses the native full-optimum state, SDK-style read-and-insert match distances, cached lookahead matches, `ChangePair` match shortening, live state/repetition nodes, additional-offset replay, price-table refresh counters, and relax/replay branches for literal, short-rep, rep, normal match, literal-lookahead, literal-rep0, match-literal-rep0, and rep-literal-rep0 decisions. Fully periodic raw chunks bypass match-finder allocation only when the full-optimum branch is disabled; LZMA2 additionally groups identical phase-reset periodic data into SDK-bounded chunks with later chunks preserving LZMA2 state so that raw fast path remains valid for large repeated inputs. Length probability state uses the SDK flat `low/high` layout, distance probability state uses full SDK `posEncoders` indexing, and helper tables cover SDK-style length, distance, align, literal, matched-literal, match-prefix, rep-branch, literal-vs-short-rep, and rep-vs-normal-match prices. Ratio and speed claims should be based on benchmark artifacts, not diagnostics alone.

The low-level raw LZMA encoder now follows the SDK 26.01 defaults for the fields this native encoder uses:

- raw dictionary defaults: level `0` = 64 KiB, `1` = 256 KiB, `2` = 1 MiB, `3` = 4 MiB, `4` = 16 MiB, `5` = 32 MiB, `6` = 64 MiB, `7..9` = 128/256/256 MiB;
- raw `fastBytes`: `32` for levels `< 7`, `64` for levels `7..9`;
- raw `algo`: `0` for levels `< 5`, `1` for levels `5..9` to match SDK profile normalization; both paths use the native parser and expose their selected profile through diagnostics;
- match-finder profile metadata follows SDK normalization where it is externally visible: levels `< 5` keep HC profile metadata with `numHashBytes = 5`, `cutValue = 16`, and default thread count `1`, and the active native finder slice is HC5 (`h2`/`h3` CRC low hashes plus `h5` main-chain matches); levels `5..6` use BT4 metadata with `cutValue = 32`; levels `7..9` use BT4 metadata with `cutValue = 48`; the active encoder routes HC and BT profile kinds through separate HC5 and BT4 finder slices;
- serialized raw LZMA properties align dictionary values like `LzmaEnc_WriteProperties` (`4097 -> 6144`; values from 2 MiB round up to 1 MiB multiples, so `5 MiB` stays `5 MiB`).

The low-level raw LZMA encoder can append the SDK end marker for standalone unknown-size streams, and `TLzmaRawDecoder.DecodeUntilEndMarker` decodes that form. LZMA2 compressed chunks remain known-size chunks and reject a raw LZMA end marker inside the chunk payload.

Raw LZMA accepts SDK-valid `lc`, `lp`, and `pb` values independently. The stricter `lc + lp <= 4` rule is still enforced for LZMA2 chunk properties.

Public tuning and diagnostics controls:

- `Container` selects `lcRawLzma2`, `lcLzma`, `lcXz`, or `lc7z`.
  `lcLzma` writes and reads the classic standalone LZMA format: 5-byte raw
  LZMA properties, 8-byte little-endian unpack size, then raw LZMA payload.
  Set `LzmaEndMarker = True` to encode unknown-size `.lzma` streams with
  `$FF` x 8 and an SDK end marker; unknown-size `.lzma` streams are decoded
  through the same end-marker path. The `lc7z` stream path writes single-file
  LZMA2 7z archives and reads single-file LZMA/LZMA2 7z archives with CRC
  metadata and unencoded or LZMA/LZMA2-encoded headers.
- `ArchiveFileName` is used by `lc7z` encode. Empty values are normalized to
  `data`; path components are stripped so archives store a single file name.
- `ParserMode` defaults to `lpmSdkProfile`. This selects SDK-normalized
  level/profile metadata, match finder profiles, and the isolated native
  full-optimum parser branch. Ratio and speed parity are measured by benchmarks.
  `lpmFast` and `lpmHighSpeed` are explicit opt-in modes for
  future speed/ratio tradeoffs. The `lc7z` stream API remains single-file;
  use `TLzma7z.EncodeEntries`, `TLzma7z.List`/`ExtractAll`, or CLI `a/x/e`
  for multi-entry 7z archives.
- `FastBytes` and `CutValue` default to `0`, which keeps the SDK 26.01 level
  defaults. Nonzero values override the active encoder `fastBytes`/`niceLen`
  and match-finder cycle cap; `FastBytes` accepts `5..273`.
- `Lc`, `Lp`, and `Pb` default to `-1`, which keeps the SDK property defaults
  (`3/0/2`). Standalone `.lzma` accepts SDK-valid values independently
  (`lc <= 8`, `lp <= 4`, `pb <= 4`); LZMA2-based containers additionally
  enforce `lc + lp <= 4`.
- `MatchFinderProfile` defaults to `lmfpAuto`. Auto maps levels `< 5` to the
  HC5 profile currently used by the native encoder and levels `5..9` to BT4.
  Callers can request `lmfpHashChain4`, `lmfpHashChain5`, or
  `lmfpBinaryTree4`; other match finders are rejected by the CLI/API.
- `XzBlockSize = 0` keeps the streaming single-block XZ encoder behavior. A nonzero value writes native multi-block XZ with block packed/unpacked sizes, making the archive eligible for MT XZ decode without requiring xz-utils to create the fixture.
- `EncodeDiagnostics` is optional. When assigned, it records requested and actual encode workers, batch count, LZMA2 compressed block count, `fastBytes`, `niceLen`, `cutValue`, `numHashBytes`, `XzBlockSize`, parser mode, match-finder profile, `OptimumParserEnabled`, copy/incompressible fast-path counters, and encode fallback reason. `ActualThreadCount` reports the peak active encode workers, not merely the requested thread count. `OptimumParserEnabled=True` means at least one compressed LZMA block was emitted through the SDK-profile full-parser path; copy-only streams keep it `False` even when the requested parser mode is SDK-profile. It is not by itself release ratio/performance evidence.
- `DecodeDiagnostics` is optional. It now also records whether the successful MT path used a full input snapshot. The streaming raw LZMA2 and XZ MT paths set `InputSnapshot = False`; fallback paths report the reason and run single-threaded.

CLI output path modes:

- `-o{dir}` writes an extracted archive member under `dir`. For multi-entry
  `.7z` archives, `x` preserves safe relative paths and `e` flattens entries
  to safe leaf names.
- `-spod` and `-spor` keep the directory-combine behavior for single-file
  extraction.
- `-spoc` concatenates the `-o` value and the stored file name. Use a trailing
  separator in the `-o` value if directory-combine behavior is desired.

Public LZMA2 option dictionary defaults:

This table is the high-level `TLzma2Options.Level` dictionary policy. The raw LZMA SDK profile metadata above is tracked separately; in particular, raw level `4` still follows the SDK fast HC profile (`algo = 0`, `numHashBytes = 5`) in the current native encoder.

| Level | Intent | Dictionary default |
|---:|---|---:|
| 0 | Copy / fastest | 1 MiB |
| 1 | Fast HC | 1 MiB |
| 2 | Fast HC | 2 MiB |
| 3 | Fast HC | 4 MiB |
| 4 | Fast HC / public normal boundary | 4 MiB |
| 5 | Normal BT | 8 MiB |
| 6 | Normal BT | 16 MiB |
| 7 | Maximum BT | 32 MiB |
| 8 | Ultra BT | 64 MiB |
| 9 | Ultra BT | 64 MiB |

Dictionary normalization follows the LZMA2 one-byte property grid:

- `(2 shl 11)`, `(3 shl 11)`
- `(2 shl 12)`, `(3 shl 12)`
- continuing up to `(2 shl 30)`, `(3 shl 30)`
- property `40` maps to `0xFFFFFFFF`

If `StrictValidation = False`, unsupported dictionary sizes normalize upward to the next representable value.
If `StrictValidation = True`, non-exact values are rejected with `ELzmaInvalidParameter`.

`ThreadCount` is normalized to at least `1`.

- Level `0` copy mode writes sequentially.
- Levels `1..9` use worker-thread encode jobs when `ThreadCount > 1` and the input is large enough to keep at least two worker batches busy. Each worker encodes independent reset LZMA2 chunks up to the normalized buffer size (maximum 2 MiB, matching the SDK LZMA2 unpack limit) inside larger batches: 64 MiB normally, or 16 MiB when `ThreadCount >= 8`. The main thread writes completed batches in source order so output remains deterministic.
- Decode treats `ThreadCount = 1` as strict single-thread mode. With `ThreadCount > 1`, raw LZMA2 decode attempts to split independent dictionary-reset chunks, and XZ decode attempts to split blocks that store both packed and unpacked sizes in the block header or whose sizes can be recovered from the XZ Index. If the source is non-seekable, contains only one independent unit, omits required XZ block sizes, or would exceed the memory limit, decode falls back to single-thread mode and records the reason in `TLzma2DecodeDiagnostics`. Raw LZMA2 also falls back when the split stream has too little packed work, including high-expansion tiny-packed streams where worker scheduling would dominate decoding.
- `DecodeDiagnostics` is optional. When assigned, it records the requested thread count, actual worker count, independent unit count, whether MT decode really ran, whether the MT path required an input snapshot, and a fallback reason.

Additional SDK-style block splitting and match-finder threading are not part of
the current public option surface.
