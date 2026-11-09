unit Lzma.Sdk.Memory;

interface

uses Lzma.Types;

// SDK counts are unsigned size_t. System.Move takes signed NativeInt.
// No allocation, admission limit, stream callback or hidden source copy.
procedure LzmaSdkMove(Dest, Source: Pointer; Count: SizeT);

{$IFDEF LZMA_SDK_COPY_QA}
function LzmaSdkMovePartSize(Count: SizeT): NativeInt;
{$ENDIF}

implementation

{$POINTERMATH ON}
{$B-}

const
{$IFDEF LZMA_SDK_COPY_SMALL_CHUNKS}
  RtlMoveLimit = SizeT(127); // test-only: force the full-size path on small data
{$ELSE}
  RtlMoveLimit = SizeT(High(NativeInt));
{$ENDIF}

function MovePartSize(Count: SizeT): NativeInt; inline;
begin
  if Count > RtlMoveLimit then Result := NativeInt(RtlMoveLimit)
  else Result := NativeInt(Count);
end;

{$IFDEF LZMA_SDK_COPY_QA}
function LzmaSdkMovePartSize(Count: SizeT): NativeInt;
begin Result := MovePartSize(Count); end;
{$ENDIF}

procedure LzmaSdkMove(Dest, Source: Pointer; Count: SizeT);
var Src, Dst: PByte; Part: NativeInt;
begin
  if (Count = 0) or (Dest = Source) then Exit;
  if Count <= RtlMoveLimit then
  begin
    System.Move(Source^, Dest^, NativeInt(Count));
    Exit;
  end;
  Src := Source; Dst := Dest;
  // Choose direction before splitting: a large overlapping move must retain
  // the same source bytes across chunk boundaries as one memmove operation.
  if (NativeUInt(Dest) > NativeUInt(Source)) and
     (NativeUInt(Dest) - NativeUInt(Source) < Count) then
  begin
    Inc(Src, Count); Inc(Dst, Count);
    repeat
      Part := MovePartSize(Count);
      Dec(Src, Part); Dec(Dst, Part);
      System.Move(Src^, Dst^, Part);
      Dec(Count, SizeT(Part));
    until Count = 0;
  end
  else
  begin
    repeat
      Part := MovePartSize(Count);
      System.Move(Src^, Dst^, Part);
      Inc(Src, Part); Inc(Dst, Part);
      Dec(Count, SizeT(Part));
    until Count = 0;
  end;
end;

end.
