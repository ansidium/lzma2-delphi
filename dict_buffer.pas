unit DictBuffer;

interface

uses
  System.SysUtils, System.Math, FL2Common, xxHash;

const
  ALIGNMENT_SIZE = 16;
  ALIGNMENT_MASK = not (NativeUInt(ALIGNMENT_SIZE) - 1);

type
  PDICT_buffer = ^TDICT_buffer;
  TDICT_buffer = record
    Data: array[0..1] of PByte;
    Index: NativeUInt;
    Async: NativeUInt;
    Overlap: NativeUInt;
    Start: NativeUInt;
    EndPos: NativeUInt;
    Size: NativeUInt;
    Total: NativeUInt;
    ResetInterval: NativeUInt;
    HashState: PXXH32_state;
  end;

procedure DICT_construct(var Buf: TDICT_buffer; Async: Boolean);
function DICT_init(var Buf: TDICT_buffer; DictSize, Overlap: NativeUInt;
  ResetMultiplier: Cardinal; DoHash: Boolean): Integer;
procedure DICT_destruct(var Buf: TDICT_buffer);
function DICT_size(const Buf: TDICT_buffer): NativeUInt;
function DICT_get(var Buf: TDICT_buffer; out Dict: Pointer): NativeUInt;
function DICT_update(var Buf: TDICT_buffer; AddedSize: NativeUInt): Integer;
procedure DICT_put(var Buf: TDICT_buffer; var Input: TFL2_inBuffer);
function DICT_availSpace(const Buf: TDICT_buffer): NativeUInt;
function DICT_hasUnprocessed(const Buf: TDICT_buffer): Boolean;
procedure DICT_getBlock(var Buf: TDICT_buffer; out Block: TFL2_dataBlock);
function DICT_getDigest(const Buf: TDICT_buffer): Cardinal;
function DICT_needShift(var Buf: TDICT_buffer): Boolean;
function DICT_async(const Buf: TDICT_buffer): Integer;
procedure DICT_shift(var Buf: TDICT_buffer);
function DICT_memUsage(const Buf: TDICT_buffer): NativeUInt;

implementation

procedure DICT_construct(var Buf: TDICT_buffer; Async: Boolean);
begin
  Buf.Data[0] := nil;
  Buf.Data[1] := nil;
  Buf.Size := 0;
  if Async then
    Buf.Async := 1
  else
    Buf.Async := 0;
  Buf.Index := 0;
  Buf.Overlap := 0;
  Buf.Start := 0;
  Buf.EndPos := 0;
  Buf.Total := 0;
  Buf.ResetInterval := 0;
  Buf.HashState := nil;
end;

function DICT_init(var Buf: TDICT_buffer; DictSize, Overlap: NativeUInt;
  ResetMultiplier: Cardinal; DoHash: Boolean): Integer;
begin
  if (Buf.Data[0] = nil) or (DictSize > Buf.Size) then
  begin
    DICT_destruct(Buf);
    GetMem(Buf.Data[0], DictSize);
    Buf.Data[1] := nil;
    if Buf.Async <> 0 then
      GetMem(Buf.Data[1], DictSize);
    if (Buf.Data[0] = nil) or ((Buf.Async <> 0) and (Buf.Data[1] = nil)) then
    begin
      DICT_destruct(Buf);
      Exit(1);
    end;
  end;
  Buf.Index := 0;
  Buf.Overlap := Overlap;
  Buf.Start := 0;
  Buf.EndPos := 0;
  Buf.Size := DictSize;
  Buf.Total := 0;
  if ResetMultiplier <> 0 then
    Buf.ResetInterval := DictSize * ResetMultiplier
  else
    Buf.ResetInterval := NativeUInt(1) shl 31;

  if DoHash then
  begin
    if Buf.HashState = nil then
      Buf.HashState := XXH32_createState;
    if Buf.HashState = nil then
      Exit(1);
    XXH32_reset(Buf.HashState, 0);
  end
  else
  begin
    if Buf.HashState <> nil then
    begin
      XXH32_freeState(Buf.HashState);
      Buf.HashState := nil;
    end;
  end;

  Result := 0;
end;

procedure DICT_destruct(var Buf: TDICT_buffer);
begin
  if Buf.Data[0] <> nil then
  begin
    FreeMem(Buf.Data[0]);
    Buf.Data[0] := nil;
  end;
  if Buf.Data[1] <> nil then
  begin
    FreeMem(Buf.Data[1]);
    Buf.Data[1] := nil;
  end;
  if Buf.HashState <> nil then
  begin
    XXH32_freeState(Buf.HashState);
    Buf.HashState := nil;
  end;
  Buf.Size := 0;
end;

function DICT_size(const Buf: TDICT_buffer): NativeUInt;
begin
  Result := Buf.Size;
end;

function DICT_get(var Buf: TDICT_buffer; out Dict: Pointer): NativeUInt;
begin
  DICT_shift(Buf);
  Dict := Pointer(NativeUInt(Buf.Data[Buf.Index]) + Buf.EndPos);
  Result := Buf.Size - Buf.EndPos;
end;

function DICT_update(var Buf: TDICT_buffer; AddedSize: NativeUInt): Integer;
begin
  Inc(Buf.EndPos, AddedSize);
  Assert(Buf.EndPos <= Buf.Size);
  if DICT_availSpace(Buf) = 0 then
    Result := 1
  else
    Result := 0;
end;

procedure DICT_put(var Buf: TDICT_buffer; var Input: TFL2_inBuffer);
var
  ToRead: NativeUInt;
begin
  ToRead := Min(Buf.Size - Buf.EndPos, Input.size - Input.pos);
  Move(PByte(Input.src)[Input.pos], PByte(Buf.Data[Buf.Index])[Buf.EndPos], ToRead);
  Inc(Input.pos, ToRead);
  Inc(Buf.EndPos, ToRead);
end;

function DICT_availSpace(const Buf: TDICT_buffer): NativeUInt;
begin
  Result := Buf.Size - Buf.EndPos;
end;

function DICT_hasUnprocessed(const Buf: TDICT_buffer): Boolean;
begin
  Result := Buf.Start < Buf.EndPos;
end;

procedure DICT_getBlock(var Buf: TDICT_buffer; out Block: TFL2_dataBlock);
begin
  Block.data := Buf.Data[Buf.Index];
  Block.start := Buf.Start;
  Block.EndPos := Buf.EndPos;
  if Buf.HashState <> nil then
    XXH32_update(Buf.HashState, Buf.Data[Buf.Index] + Buf.Start,
      Buf.EndPos - Buf.Start);
  Inc(Buf.Total, Buf.EndPos - Buf.Start);
  Buf.Start := Buf.EndPos;
end;

function DICT_getDigest(const Buf: TDICT_buffer): Cardinal;
begin
  if Buf.HashState <> nil then
    Result := XXH32_digest(Buf.HashState)
  else
    Result := 0;
end;

function DICT_needShift(var Buf: TDICT_buffer): Boolean;
var
  Overlap: NativeUInt;
begin
  if Buf.Start < Buf.EndPos then
    Exit(False);
  if Buf.Total + Buf.Size - Buf.Overlap > Buf.ResetInterval then
    Overlap := 0
  else
    Overlap := Buf.Overlap;
  Result := (Buf.Start = Buf.EndPos) and
            ((Overlap = 0) or (Buf.EndPos >= Overlap + ALIGNMENT_SIZE));
end;

function DICT_async(const Buf: TDICT_buffer): Integer;
begin
  Result := Buf.Async;
end;

procedure DICT_shift(var Buf: TDICT_buffer);
var
  Overlap, FromPos, OverlapSize: NativeUInt;
  Src, Dst: PByte;
begin
  if Buf.Start < Buf.EndPos then
    Exit;

  Overlap := Buf.Overlap;
  if Buf.Total + Buf.Size - Buf.Overlap > Buf.ResetInterval then
    Overlap := 0;

  if Overlap = 0 then
  begin
    Buf.Start := 0;
    Buf.EndPos := 0;
    Buf.Index := Buf.Index xor Buf.Async;
    Buf.Total := 0;
  end
  else if Buf.EndPos >= Overlap + ALIGNMENT_SIZE then
  begin
    FromPos := (Buf.EndPos - Overlap) and ALIGNMENT_MASK;
    Src := Buf.Data[Buf.Index];
    Dst := Buf.Data[Buf.Index xor Buf.Async];
    OverlapSize := Buf.EndPos - FromPos;
    if (OverlapSize <= FromPos) or (Dst <> Src) then
      Move(Src[FromPos], Dst^, OverlapSize)
    else if FromPos <> 0 then
      Move(Src[FromPos], Src^, OverlapSize);
    Buf.Start := OverlapSize;
    Buf.EndPos := OverlapSize;
    Buf.Index := Buf.Index xor Buf.Async;
  end;
end;

function DICT_memUsage(const Buf: TDICT_buffer): NativeUInt;
begin
  Result := (1 + Buf.Async) * Buf.Size;
end;

end.

