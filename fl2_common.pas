/*
 * Copyright (c) 2016-present, Yann Collet, Facebook, Inc.
 * All rights reserved.
 * Modified for FL2 by Conor McCarthy
 *
 * This source code is licensed under both the BSD-style license (found in the
 * LICENSE file in the root directory of this source tree) and the GPLv2 (found
 * in the COPYING file in the root directory of this source tree).
 * You may select, at your option, one of the above-listed licenses.
 */



unit FL2Common;

interface

const
  FL2_VERSION_MAJOR = 1;
  FL2_VERSION_MINOR = 0;
  FL2_VERSION_RELEASE = 1;
  FL2_VERSION_NUMBER = FL2_VERSION_MAJOR * 100 * 100 +
                       FL2_VERSION_MINOR * 100 +
                       FL2_VERSION_RELEASE;
  FL2_VERSION_STRING = '1.0.1';

  FL2_ERROR_MAX_CODE = 20;

type
  FL2_ErrorCode = (
    FL2_error_no_error = 0,
    FL2_error_GENERIC = 1,
    FL2_error_internal = 2,
    FL2_error_corruption_detected = 3,
    FL2_error_checksum_wrong = 4,
    FL2_error_parameter_unsupported = 5,
    FL2_error_parameter_outOfBound = 6,
    FL2_error_lclpMax_exceeded = 7,
    FL2_error_stage_wrong = 8,
    FL2_error_init_missing = 9,
    FL2_error_memory_allocation = 10,
    FL2_error_dstSize_tooSmall = 11,
    FL2_error_srcSize_wrong = 12,
    FL2_error_canceled = 13,
    FL2_error_buffer = 14,
    FL2_error_timedOut = 15,
    FL2_error_maxCode = 20
  );

const
  FL2_ERROR_MAX = NativeUInt(-Ord(FL2_error_maxCode));
  FL2_ERROR_TIMEDOUT = NativeUInt(-Ord(FL2_error_timedOut));

function FL2_versionNumber: Cardinal;
function FL2_versionString: PAnsiChar;
function FL2_compressBound(srcSize: NativeUInt): NativeUInt;
function FL2_isError(code: NativeUInt): Boolean;
function FL2_isTimedOut(code: NativeUInt): Boolean;
function FL2_getErrorName(code: NativeUInt): PAnsiChar;
function FL2_getErrorCode(code: NativeUInt): FL2_ErrorCode;
function FL2_getErrorString(code: FL2_ErrorCode): PAnsiChar;

implementation

const
  kMaxChunkCompressedSize = 1 shl 16;
  kChunkSize = kMaxChunkCompressedSize - 2048;

function LZMA2_compressBound(src_size: NativeUInt): NativeUInt;
var
  chunk_min_avg: NativeUInt;
begin
  chunk_min_avg := (kChunkSize - (kChunkSize div 16)) div 2;
  Result := src_size + ((src_size + chunk_min_avg - 1) div chunk_min_avg) * 3 + 6;
end;

function FL2_versionNumber: Cardinal;
begin
  Result := FL2_VERSION_NUMBER;
end;

function FL2_versionString: PAnsiChar;
begin
  Result := PAnsiChar(FL2_VERSION_STRING);
end;

function FL2_compressBound(srcSize: NativeUInt): NativeUInt;
begin
  Result := LZMA2_compressBound(srcSize);
end;

function FL2_isError(code: NativeUInt): Boolean;
begin
  Result := code > FL2_ERROR_MAX;
end;

function FL2_isTimedOut(code: NativeUInt): Boolean;
begin
  Result := code = FL2_ERROR_TIMEDOUT;
end;

function FL2_getErrorCode(code: NativeUInt): FL2_ErrorCode;
begin
  if not FL2_isError(code) then
    Result := FL2_error_no_error
  else
    Result := FL2_ErrorCode(-Integer(code));
end;

function FL2_getErrorName(code: NativeUInt): PAnsiChar;
begin
  Result := FL2_getErrorString(FL2_getErrorCode(code));
end;

function FL2_getErrorString(code: FL2_ErrorCode): PAnsiChar;
begin
  case code of
    FL2_error_no_error:
      Result := 'No error detected';
    FL2_error_GENERIC:
      Result := 'Error (generic)';
    FL2_error_internal:
      Result := 'Internal error (bug)';
    FL2_error_corruption_detected:
      Result := 'Corrupted block detected';
    FL2_error_checksum_wrong:
      Result := 'Restored data doesn''t match checksum';
    FL2_error_parameter_unsupported:
      Result := 'Unsupported parameter';
    FL2_error_parameter_outOfBound:
      Result := 'Parameter is out of bound';
    FL2_error_lclpMax_exceeded:
      Result := 'Parameters lc+lp > 4';
    FL2_error_stage_wrong:
      Result := 'Not possible at this stage of encoding';
    FL2_error_init_missing:
      Result := 'Context should be init first';
    FL2_error_memory_allocation:
      Result := 'Allocation error : not enough memory';
    FL2_error_dstSize_tooSmall:
      Result := 'Destination buffer is too small';
    FL2_error_srcSize_wrong:
      Result := 'Src size is incorrect';
    FL2_error_canceled:
      Result := 'Processing was canceled by a call to FL2_cancelCStream() or FL2_cancelDStream()';
    FL2_error_buffer:
      Result := 'Streaming progress halted due to buffer(s) full/empty';
    FL2_error_timedOut:
      Result := 'Wait timed out. Timeouts should be handled before errors using FL2_isTimedOut()';
  else
    Result := 'Unspecified error code';
  end;
end;

{$IFDEF FL2_DEBUG}
{$IF GE(FL2_DEBUG,2)}
var
  g_debuglog_enable: Integer = 1;
{$ENDIF}
{$ENDIF}

end.

