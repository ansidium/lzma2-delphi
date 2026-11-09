unit Lzma.Sdk.Contracts;
interface
uses Lzma.Types;
type
  TLzmaFinishMode=(lfmAny,lfmEnd);
  TLzmaStatus=(lsNotSpecified,lsFinishedWithMark,lsNotFinished,lsNeedsMoreInput,lsMaybeFinishedWithoutMark);
  TLzma2ParseStatus=(lpsNotSpecified,lpsFinishedWithMark,lpsNotFinished,lpsNeedsMoreInput,
    lpsMaybeFinishedWithoutMark,lpsNewBlock,lpsNewChunk);
  TLzma2ParserState=(lzpsControl,lzpsUnpack0,lzpsUnpack1,lzpsPack0,lzpsPack1,lzpsProp,
    lzpsData,lzpsDataCont,lzpsFinished,lzpsError);
  ILzmaSeqInStream=interface
    ['{ACB685A7-1664-45C5-B9E6-C6261CE7E6E7}']
    function Read(var Buffer;const Count:SizeT;out ProcessedSize:SizeT):SRes;
  end;
  ILzmaSeqOutStream=interface
    ['{3B42F50C-74E5-47AC-A2B4-7C2D058D15D2}']
    function Write(const Buffer;const Count:SizeT;out ProcessedSize:SizeT):SRes;
  end;
  ILzmaCompressProgress=interface
    ['{2358CD94-AE6E-44C9-BBC8-25B66B9BA078}']
    function Progress(const InSize,OutSize:UInt64):SRes;
  end;
  ILzmaAllocator=interface
    ['{D95BF641-A965-4B54-B140-6A6F1051D259}']
    function Alloc(const Size:SizeT):Pointer;
    procedure FreeMem(const Address:Pointer);
  end;
function LzmaDefaultAllocate(const Size:SizeT):Pointer;
procedure LzmaDefaultFree(const Address:Pointer);
function LzmaDefaultAllocator:ILzmaAllocator;
implementation
uses Winapi.Windows;
type
  TDefaultAllocator=class(TInterfacedObject,ILzmaAllocator)
    function Alloc(const Size:SizeT):Pointer;
    procedure FreeMem(const Address:Pointer);
  end;
function LzmaDefaultAllocate(const Size:SizeT):Pointer;
begin
  if Size=0 then Exit(nil);
  // size_t stays full-width, including Win32 requests above High(NativeInt).
  Result:=HeapAlloc(GetProcessHeap,HEAP_ZERO_MEMORY,Size);
end;
procedure LzmaDefaultFree(const Address:Pointer);
begin if Address<>nil then HeapFree(GetProcessHeap,0,Address);end;
function TDefaultAllocator.Alloc(const Size:SizeT):Pointer;
begin Result:=LzmaDefaultAllocate(Size);end;
procedure TDefaultAllocator.FreeMem(const Address:Pointer);
begin LzmaDefaultFree(Address);end;
function LzmaDefaultAllocator:ILzmaAllocator;
begin Result:=TDefaultAllocator.Create;end;
end.
