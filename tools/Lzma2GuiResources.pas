unit Lzma2GuiResources;

interface

uses Lzma.Types;

function GuiMemoryBudget: UInt64;
function GuiProcessorCount: Integer;
function GuiAutomaticDictionary(const Level, Workers: Integer; const Budget: UInt64): UInt64;
function AutoThreadCount(const Options: TLzma2Options; const Budget: UInt64;
  const CpuCount: Integer): Integer;

implementation

uses System.Classes, System.Math, Winapi.Windows, Lzma.Encoder, Lzma.MatchFinder,
  Lzma.Alloc, Lzma.Errors, Lzma.Lzma, Lzma2GuiCatalog;

const GuiRtlHeadroom = UInt64(64) shl 20;

function GuiAutomaticDictionary(const Level, Workers: Integer; const Budget: UInt64): UInt64;
var Profile: TLzmaEncoderProfile; Props: TLzmaProps; Required, PerWorker: UInt64;
begin
  Result:=UInt64(GuiProfileDictionaryMiB(Level)) shl 20;
  PerWorker:=Budget div UInt64(Max(1,Workers));
  repeat
    Profile:=TLzmaRawEncoder.NormalizeProfile(TLzma2CompressionLevel(Level),Result);
    Props:=TLzmaRawEncoder.DefaultProperties(Result);
    Required:=TLzmaRawEncoder.RequiredStreamingMemoryForInput(Profile,Props,
      Result+(UInt64(1) shl 16),1 shl 20,False)+GuiRtlHeadroom;
    if (Required<=PerWorker) or (Result<=UInt64(1) shl 20) then Break;
    Result:=Result shr 1;
  until False;
end;

function GuiMemoryBudget: UInt64;
var M: TMemoryStatusEx;
begin
  ZeroMemory(@M, SizeOf(M));
  M.dwLength := SizeOf(M);
  if GlobalMemoryStatusEx(M) then
    Result := Min(M.ullAvailPhys div 2, M.ullAvailVirtual div 2)
  else
    Result := UInt64(512) shl 20;
  if Result = 0 then Result := 1;
end;

function GuiProcessorCount: Integer;
var ProcessMask, SystemMask, Mask: NativeUInt;
    Count: Integer;
begin
  Result := Max(TThread.ProcessorCount, 1);
  if GetProcessAffinityMask(GetCurrentProcess, ProcessMask, SystemMask) then
  begin
    Count := 0;
    Mask := ProcessMask;
    while Mask <> 0 do
    begin
      Inc(Count, Integer(Mask and 1));
      Mask := Mask shr 1;
    end;
    if Count > 0 then Result := Min(Result, Count);
  end;
end;

function AutoThreadCount(const Options: TLzma2Options; const Budget: UInt64;
  const CpuCount: Integer): Integer;
var PerWorker, Dictionary, Required: UInt64;
    Profile: TLzmaEncoderProfile;
    Props: TLzmaProps;
begin
  Result := 1;
  if Options.Level = 0 then Exit;
  Dictionary := Options.DictionarySize;
  if Dictionary = 0 then Dictionary := DefaultDictionaryForLevel(Options.Level);
  if Options.Container = lcLzma then
  begin
    if CpuCount < 2 then Exit;
    Profile := TLzmaRawEncoder.NormalizeProfile(Options.Level, Dictionary);
    Profile.ParserMode := Options.ParserMode;
    case Options.MatchFinderProfile of
      lmfpHashChain4: Profile.MatchFinderKind := mfHashChain4;
      lmfpHashChain5: Profile.MatchFinderKind := mfHashChain5;
      lmfpBinaryTree4: Profile.MatchFinderKind := mfBinaryTree4;
    end;
    if Options.FastBytes <> 0 then Profile.FastBytes := Options.FastBytes;
    if Options.CutValue <> 0 then Profile.CutValue := Options.CutValue;
    if TLzmaRawEncoder.ResolveThreadCount(Profile, 2) <> 2 then Exit;
    Props := TLzmaRawEncoder.DefaultProperties(Dictionary);
    if not TryApplyLzmaOptionsToProps(Props, Options, False) then Exit;
    try
      Required := CheckedMemoryAdd(TLzmaRawEncoder.RequiredStreamingMemoryForInputWithThreads(
        Profile, Props, High(UInt64), Options.BufferSize, 2), GuiRtlHeadroom);
    except
      on E: ELzmaError do Exit;
    end;
    if Required <= Budget then Result := 2;
    Exit;
  end;
  // Other containers parallelize independent blocks; MemoryLimit remains authoritative.
  if Dictionary > (High(UInt64) - (UInt64(512) shl 20)) div 16 then Exit;
  // Deliberately conservative GUI admission estimate, including buffers and
  // headroom for RTL/OS allocations. This is a ceiling, not an allocation promise.
  PerWorker := Dictionary * 16 + (UInt64(512) shl 20);
  if Budget >= PerWorker then
    Result := Integer(Min(UInt64(Max(CpuCount, 1)), Budget div PerWorker));
end;

end.
