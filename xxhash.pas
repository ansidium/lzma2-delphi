unit xxHash;

interface

uses
  System.SysUtils;

type
  PXXH32_state = ^TXXH32_state;
  TXXH32_state = record
    totalLen: Cardinal;
    v1, v2, v3, v4: Cardinal;
    mem32: array[0..3] of Cardinal;
    memSize: Cardinal;
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
  PRIME32_1 = 2654435761;
  PRIME32_2 = 2246822519;
  PRIME32_3 = 3266489917;
  PRIME32_4 = 668265263;
  PRIME32_5 = 374761393;

function XXH32_createState: PXXH32_state;
begin
  New(Result);
  FillChar(Result^, SizeOf(TXXH32_state), 0);
end;

function XXH32_freeState(State: PXXH32_state): Integer;
begin
  if Assigned(State) then
    Dispose(State);
  Result := 0;
end;

function XXH32_reset(State: PXXH32_state; Seed: Cardinal): Integer;
begin
  FillChar(State^, SizeOf(TXXH32_state), 0);
  State^.v1 := Seed + PRIME32_1 + PRIME32_2;
  State^.v2 := Seed + PRIME32_2;
  State^.v3 := Seed;
  State^.v4 := Seed - PRIME32_1;
  Result := 0;
end;

function ROL32(Value: Cardinal; Bits: Integer): Cardinal; inline;
begin
  Result := (Value shl Bits) or (Value shr (32 - Bits));
end;

function XXH32_round(Seed, Input: Cardinal): Cardinal; inline;
begin
  Seed := Seed + Input * PRIME32_2;
  Seed := ROL32(Seed, 13);
  Seed := Seed * PRIME32_1;
  Result := Seed;
end;

function XXH32_update(State: PXXH32_state; Input: Pointer; Length: NativeUInt): Integer;
var
  p, bEnd, limit: PByte;
begin
  if Length = 0 then
    Exit(0);

  p := PByte(Input);
  bEnd := p + Length;

  Inc(State^.totalLen, Length);

  if (State^.memSize + Length) < 16 then
  begin
    Move(p^, PByte(@State^.mem32)[State^.memSize], Length);
    Inc(State^.memSize, Length);
    Exit(0);
  end;

  if State^.memSize > 0 then
  begin
    Move(p^, PByte(@State^.mem32)[State^.memSize], 16 - State^.memSize);
    p := p + (16 - State^.memSize);

    State^.v1 := XXH32_round(State^.v1, State^.mem32[0]);
    State^.v2 := XXH32_round(State^.v2, State^.mem32[1]);
    State^.v3 := XXH32_round(State^.v3, State^.mem32[2]);
    State^.v4 := XXH32_round(State^.v4, State^.mem32[3]);

    State^.memSize := 0;
  end;

  if (p + 16) <= bEnd then
  begin
    limit := bEnd - 16;
    repeat
      State^.v1 := XXH32_round(State^.v1, PCardinal(p)^); p := p + 4;
      State^.v2 := XXH32_round(State^.v2, PCardinal(p)^); p := p + 4;
      State^.v3 := XXH32_round(State^.v3, PCardinal(p)^); p := p + 4;
      State^.v4 := XXH32_round(State^.v4, PCardinal(p)^); p := p + 4;
    until p > limit;
  end;

  if p < bEnd then
  begin
    Move(p^, PByte(@State^.mem32)^, bEnd - p);
    State^.memSize := bEnd - p;
  end;

  Result := 0;
end;

function XXH32_digest(State: PXXH32_state): Cardinal;
var
  p, bEnd: PByte;
  h32: Cardinal;
begin
  p := PByte(@State^.mem32);
  bEnd := p + State^.memSize;

  if State^.totalLen >= 16 then
    h32 := ROL32(State^.v1, 1) + ROL32(State^.v2, 7) +
            ROL32(State^.v3,12) + ROL32(State^.v4,18)
  else
    h32 := State^.v3 + PRIME32_5;

  Inc(h32, State^.totalLen);

  while (p + 4) <= bEnd do
  begin
    h32 := h32 + PCardinal(p)^ * PRIME32_3;
    h32 := ROL32(h32,17) * PRIME32_4;
    Inc(p,4);
  end;

  while p < bEnd do
  begin
    h32 := h32 + p^ * PRIME32_5;
    h32 := ROL32(h32,11) * PRIME32_1;
    Inc(p);
  end;

  h32 := h32 xor (h32 shr 15);
  h32 := h32 * PRIME32_2;
  h32 := h32 xor (h32 shr 13);
  h32 := h32 * PRIME32_3;
  h32 := h32 xor (h32 shr 16);

  Result := h32;
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

