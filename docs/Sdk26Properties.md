# SDK 26.06 property records

`Lzma.Sdk.Properties` defines the full SDK encoder records. `Lzma.Sdk` exposes them alongside the existing 48- and 64-byte convenience records.

| Record | Use |
| --- | --- |
| `TLzmaSdkLzmaEncProps26` | LZMA properties, match finder, end marker, thread and affinity settings, and reduced size. |
| `TLzmaSdkLzma2EncProps26` | LZMA properties plus block size, inner and block thread counts, and thread groups. |
| `CLzma2DecMtProps` | Multithreaded LZMA2 decoder thread count and input and output buffer sizes. |

`Normalize` applies SDK defaults. The encoder's `SetProps` validates and applies the resulting settings. The LZMA overload accepts the full property record, and `Lzma2Enc_SetProps` applies the LZMA2 record to an encoder handle.

`WriteProperties` writes the LZMA five-byte header or the LZMA2 dictionary byte. The LZMA pointer overload uses the caller's capacity and returns the number of bytes written. `SetDataSize` is an input size hint. Set `ReduceSize` to include the input size in dictionary normalization.

The full LZMA setter follows the SDK callback contract. A write callback must consume the requested byte count in one call. A short write returns `SZ_ERROR_WRITE` and a nonzero progress result returns `SZ_ERROR_PROGRESS`. The convenience setter retains its existing write retry and error policy.

See the [SDK API registry](sdk-completion.md) for the available entry points and limits.
