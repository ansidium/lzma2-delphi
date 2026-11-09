# LZMA SDK 26.06 API coverage

The Delphi port implements 47 functions and 7 macros from seven SDK headers. The [machine-readable registry](sdk-completion.json) records the header declarations, Delphi source locations, and source hashes. Source files are hashed with LF line endings.

| SDK API | Delphi |
|---|---|
| LzmaEncProps_Init | Lzma.Sdk.Encoder26.LzmaEncProps_Init |
| LzmaEncProps_Normalize | Lzma.Sdk.Encoder26.LzmaEncProps_Normalize |
| LzmaEncProps_GetDictSize | Lzma.Sdk.Encoder26.LzmaEncProps_GetDictSize |
| LzmaEnc_Create | Lzma.Sdk.Encoder26.LzmaEnc_Create |
| LzmaEnc_Destroy | Lzma.Sdk.Encoder26.LzmaEnc_Destroy |
| LzmaEnc_SetProps | Lzma.Sdk.Encoder26.LzmaEnc_SetProps |
| LzmaEnc_SetDataSize | Lzma.Sdk.Encoder26.LzmaEnc_SetDataSize |
| LzmaEnc_WriteProperties | Lzma.Sdk.Encoder26.LzmaEnc_WriteProperties |
| LzmaEnc_IsWriteEndMark | Lzma.Sdk.Encoder26.LzmaEnc_IsWriteEndMark |
| LzmaEnc_Encode | Lzma.Sdk.Encoder26.LzmaEnc_Encode |
| LzmaEnc_MemEncode | Lzma.Sdk.Encoder26.LzmaEnc_MemEncode |
| LzmaEncode | Lzma.Sdk.Encoder26.LzmaEncode |
| Lzma2EncProps_Init | Lzma2.Sdk.Encoder26.Lzma2EncProps_Init |
| Lzma2EncProps_Normalize | Lzma2.Sdk.Encoder26.Lzma2EncProps_Normalize |
| Lzma2Enc_Create | Lzma2.Sdk.Encoder26.Lzma2Enc_Create |
| Lzma2Enc_Destroy | Lzma2.Sdk.Encoder26.Lzma2Enc_Destroy |
| Lzma2Enc_SetProps | Lzma2.Sdk.Encoder26.Lzma2Enc_SetProps |
| Lzma2Enc_SetDataSize | Lzma2.Sdk.Encoder26.Lzma2Enc_SetDataSize |
| Lzma2Enc_WriteProperties | Lzma2.Sdk.Encoder26.Lzma2Enc_WriteProperties |
| Lzma2Enc_Encode2 | Lzma2.Sdk.Encoder26.Lzma2Enc_Encode2 |
| LzmaProps_Decode | Lzma.Sdk.Decoder26.LzmaProps_Decode |
| LzmaDec_Init | Lzma.Sdk.Decoder26.LzmaDec_Init |
| LzmaDec_AllocateProbs | Lzma.Sdk.Decoder26.LzmaDec_AllocateProbs |
| LzmaDec_FreeProbs | Lzma.Sdk.Decoder26.LzmaDec_FreeProbs |
| LzmaDec_Allocate | Lzma.Sdk.Decoder26.LzmaDec_Allocate |
| LzmaDec_Free | Lzma.Sdk.Decoder26.LzmaDec_Free |
| LzmaDec_DecodeToDic | Lzma.Sdk.Decoder26.LzmaDec_DecodeToDic |
| LzmaDec_DecodeToBuf | Lzma.Sdk.Decoder26.LzmaDec_DecodeToBuf |
| LzmaDecode | Lzma.Sdk.Decoder26.LzmaDecode |
| Lzma2Dec_AllocateProbs | Lzma2.Sdk.Decoder26.Lzma2Dec_AllocateProbs |
| Lzma2Dec_Allocate | Lzma2.Sdk.Decoder26.Lzma2Dec_Allocate |
| Lzma2Dec_Init | Lzma2.Sdk.Decoder26.Lzma2Dec_Init |
| Lzma2Dec_DecodeToDic | Lzma2.Sdk.Decoder26.Lzma2Dec_DecodeToDic |
| Lzma2Dec_DecodeToBuf | Lzma2.Sdk.Decoder26.Lzma2Dec_DecodeToBuf |
| Lzma2Dec_Parse | Lzma2.Sdk.Decoder26.Lzma2Dec_Parse |
| Lzma2Decode | Lzma2.Sdk.Decoder26.Lzma2Decode |
| Lzma2DecMtProps_Init | Lzma2.Sdk.DecoderMt26.Lzma2DecMtProps_Init |
| Lzma2DecMt_Create | Lzma2.Sdk.DecoderMt26.Lzma2DecMt_Create |
| Lzma2DecMt_Destroy | Lzma2.Sdk.DecoderMt26.Lzma2DecMt_Destroy |
| Lzma2DecMt_Decode | Lzma2.Sdk.DecoderMt26.Lzma2DecMt_Decode |
| Lzma2DecMt_Init | Lzma2.Sdk.DecoderMt26.Lzma2DecMt_Init |
| Lzma2DecMt_Read | Lzma2.Sdk.DecoderMt26.Lzma2DecMt_Read |
| LzmaCompress | Lzma.Sdk.Lib26.LzmaCompress |
| LzmaUncompress | Lzma.Sdk.Lib26.LzmaUncompress |
| Lzma86_Encode | Lzma.Sdk.Lib26.Lzma86_Encode |
| Lzma86_GetUnpackSize | Lzma.Sdk.Lib26.Lzma86_GetUnpackSize |
| Lzma86_Decode | Lzma.Sdk.Lib26.Lzma86_Decode |
| LzmaDec_CONSTRUCT | Lzma.Sdk.Decoder26.LzmaDec_Construct |
| LzmaDec_Construct | Lzma.Sdk.Decoder26.LzmaDec_Construct |
| Lzma2Dec_CONSTRUCT | Lzma2.Sdk.Decoder26.Lzma2Dec_Construct |
| Lzma2Dec_Construct | Lzma2.Sdk.Decoder26.Lzma2Dec_Construct |
| Lzma2Dec_FreeProbs | Lzma2.Sdk.Decoder26.Lzma2Dec_FreeProbs |
| Lzma2Dec_Free | Lzma2.Sdk.Decoder26.Lzma2Dec_Free |
| Lzma2Dec_GetUnpackExtra | Lzma2.Sdk.Decoder26.Lzma2Dec_GetUnpackExtra |

## Limits

- Raw LZMA accepts all 225 property bytes. LZMA2 limits `lc + lp` to 4 and accepts dictionary properties 0 through 40.
- With the SDK's default FastPos configuration, the native encoder rejects dictionaries above 128 MiB on Win32. The Win64 encoder clamps to `0xF0000000` bytes.
- The LZMA hash and binary-tree pipeline uses workers when the selected algorithm and match finder support it. LZMA2 allows up to 256 block threads. The raw LZMA2 pull decoder accepts up to 32 workers.
- The raw multithreaded decoder follows the SDK's finish behavior. The high-level archive readers validate their own container boundaries.
- The low-level interfaces are Delphi APIs. Use the Delphi records and allocators described in [property records](Sdk26Properties.md).

See [release scope](release-scope.md) for the validation matrix.
