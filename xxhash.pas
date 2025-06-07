unit xxHash;

interface

uses
  System.SysUtils;

type
  PXXH32_state = ^TXXH32_state;
  TXXH32_state = record
    Seed: Cardinal;
    Hash: Cardinal;
  end;

  TXXH32_canonical = packed record
    digest: array[0..3] of Byte;
  end;
  PXXH32_canonical = ^TXXH32_canonical;

const
  XXHASH_SIZEOF = SizeOf(TXXH32_canonical);

function XXH32_createState: PXXH32_state;
function XXH32_freeState(State: PXXH32_state): Integer;
function XXH32_reset(State: PXXH32_state; Seed: Cardinal): Integer;
function XXH32_update(State: PXXH32_state; Input: Pointer; Length: NativeUInt): Integer;
function XXH32_digest(State: PXXH32_state): Cardinal;
function XXH32(input: Pointer; length: NativeUInt; seed: Cardinal): Cardinal;
procedure XXH32_canonicalFromHash(out dst: TXXH32_canonical; hash: Cardinal);
function XXH32_hashFromCanonical(const src: TXXH32_canonical): Cardinal;

implementation

const
  FNV32_PRIME  = $01000193;
  FNV32_OFFSET = $811C9DC5;

function XXH32_createState: PXXH32_state;
begin
  New(Result);
  Result^.Seed := 0;
  Result^.Hash := FNV32_OFFSET;
end;

function XXH32_freeState(State: PXXH32_state): Integer;
begin
  if Assigned(State) then
    Dispose(State);
  Result := 0;
end;

function XXH32_reset(State: PXXH32_state; Seed: Cardinal): Integer;
begin
  State^.Seed := Seed;
  State^.Hash := FNV32_OFFSET xor Seed;
  Result := 0;
end;

function XXH32_update(State: PXXH32_state; Input: Pointer; Length: NativeUInt): Integer;
var
  p: PByte;
  i: NativeUInt;
begin
  p := Input;
  for i := 0 to Length - 1 do
  begin
    State^.Hash := State^.Hash xor p[i];
    State^.Hash := State^.Hash * FNV32_PRIME;
  end;
  Result := 0;
end;

function XXH32_digest(State: PXXH32_state): Cardinal;
begin
  Result := State^.Hash;
end;

function XXH32(input: Pointer; length: NativeUInt; seed: Cardinal): Cardinal;
var
  st: TXXH32_state;
begin
  XXH32_reset(@st, seed);
  XXH32_update(@st, input, length);
  Result := XXH32_digest(@st);
end;

procedure XXH32_canonicalFromHash(out dst: TXXH32_canonical; hash: Cardinal);
begin
  dst.digest[0] := Byte(hash shr 24);
  dst.digest[1] := Byte(hash shr 16);
  dst.digest[2] := Byte(hash shr 8);
  dst.digest[3] := Byte(hash);
end;

function XXH32_hashFromCanonical(const src: TXXH32_canonical): Cardinal;
begin
  Result := (Cardinal(src.digest[0]) shl 24) or
            (Cardinal(src.digest[1]) shl 16) or
            (Cardinal(src.digest[2]) shl 8) or
            Cardinal(src.digest[3]);
end;

end.

