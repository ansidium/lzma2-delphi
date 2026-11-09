unit Lzma.Sdk.EncoderFacade;

{$B-}

interface

uses System.SysUtils, Lzma.Types, Lzma.Sdk.Contracts, Lzma.Sdk.Properties, Lzma.Sdk.Encoder26;

type
  // Owns the opaque native SDK encoder and retains both supplied allocators
  // until all workers and their allocations have been destroyed.
  TLzmaSdkLzmaEnc = class
  private
    FHandle: CLzmaEncHandle;
    FAllocator, FAllocatorBig: ILzmaAllocator;
    FPreparedSource: ILzmaSeqInStream;
  public
    constructor Create; overload;
    constructor Create(const Allocator, AllocatorBig: ILzmaAllocator); overload;
    destructor Destroy; override;
    function SetProps(const Props: TLzmaSdkLzmaEncProps26): SRes;
    procedure SetDataSize(const ExpectedDataSize: UInt64);
    function WriteProperties(Properties: PByte; var Size: SizeT): SRes; overload;
    function WriteProperties(out Properties: TBytes): SRes; overload;
    function IsWriteEndMark: UInt32;
    function Encode(const Source: ILzmaSeqInStream; const Destination: ILzmaSeqOutStream;
      const Progress: ILzmaCompressProgress = nil): SRes;
    function MemEncode(Dest: PByte; var DestLen: SizeT; Src: PByte; SrcLen: SizeT;
      WriteEndMark: Int32; const Progress: ILzmaCompressProgress = nil): SRes;
    function MemPrepare(Src: PByte; SrcLen: SizeT; KeepWindowSize: UInt32): SRes;
    function PrepareForLzma2(const Source: ILzmaSeqInStream; KeepWindowSize: UInt32): SRes;
    function CodeOneMemBlock(ReInit: Boolean; Dest: PByte; var DestLen: SizeT;
      DesiredPackSize: UInt32; var UnpackSize: UInt32): SRes;
    function GetCurBuf: PByte;
    procedure SaveState;
    procedure RestoreState;
    procedure Finish;
    // Borrowed for interoperability. Ownership remains with this object.
    property NativeHandle: CLzmaEncHandle read FHandle;
  end;

implementation

uses System.SysConst, Lzma.Errors;

type
  TReadCallback = class(TInterfacedObject, ILzmaSeqInStream)
  private
    FSource: ILzmaSeqInStream;
  public
    constructor Create(const Source: ILzmaSeqInStream);
    function Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;
  TWriteCallback = class(TInterfacedObject, ILzmaSeqOutStream)
  private
    FDestination: ILzmaSeqOutStream;
  public
    constructor Create(const Destination: ILzmaSeqOutStream);
    function Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;
  TProgressCallback = class(TInterfacedObject, ILzmaCompressProgress)
  private
    FProgress: ILzmaCompressProgress;
  public
    constructor Create(const Progress: ILzmaCompressProgress);
    function Progress(const InSize, OutSize: UInt64): SRes;
  end;

constructor TReadCallback.Create(const Source: ILzmaSeqInStream);
begin inherited Create; FSource := Source; end;

function TReadCallback.Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
begin
  try
    Result := FSource.Read(Buffer, Count, ProcessedSize);
  except
    on E: Exception do
    begin
      ProcessedSize := 0;
      if E is ELzmaError then Result := ELzmaError(E).ResultCode
      else if E is EOutOfMemory then Result := SZ_ERROR_MEM
      else Result := SZ_ERROR_READ;
    end;
  end;
end;

constructor TWriteCallback.Create(const Destination: ILzmaSeqOutStream);
begin inherited Create; FDestination := Destination; end;

function TWriteCallback.Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
begin
  try
    Result := FDestination.Write(Buffer, Count, ProcessedSize);
  except
    on E: Exception do
    begin
      ProcessedSize := 0;
      if E is ELzmaError then Result := ELzmaError(E).ResultCode
      else if E is EOutOfMemory then Result := SZ_ERROR_MEM
      else Result := SZ_ERROR_WRITE;
    end;
  end;
end;

constructor TProgressCallback.Create(const Progress: ILzmaCompressProgress);
begin inherited Create; FProgress := Progress; end;

function TProgressCallback.Progress(const InSize, OutSize: UInt64): SRes;
begin
  try
    Result := FProgress.Progress(InSize, OutSize);
  except
    on E: Exception do Result := SZ_ERROR_PROGRESS;
  end;
end;

function GuardProgress(const Progress: ILzmaCompressProgress): ILzmaCompressProgress;
begin
  if Progress = nil then Result := nil else Result := TProgressCallback.Create(Progress);
end;

constructor TLzmaSdkLzmaEnc.Create;
begin
  Create(nil, nil);
end;

constructor TLzmaSdkLzmaEnc.Create(const Allocator, AllocatorBig: ILzmaAllocator);
begin
  inherited Create;
  FAllocator := Allocator;
  FAllocatorBig := AllocatorBig;
  FHandle := LzmaEnc_Create(FAllocator);
  if FHandle = nil then
    raise EOutOfMemory.CreateRes(@SOutOfMemory);
end;

destructor TLzmaSdkLzmaEnc.Destroy;
begin
  LzmaEnc_Destroy(FHandle, FAllocator, FAllocatorBig);
  FHandle := nil;
  FPreparedSource := nil;
  FAllocatorBig := nil;
  FAllocator := nil;
  inherited;
end;

function TLzmaSdkLzmaEnc.SetProps(const Props: TLzmaSdkLzmaEncProps26): SRes;
begin
  Result := LzmaEnc_SetProps(FHandle, Props);
end;

procedure TLzmaSdkLzmaEnc.SetDataSize(const ExpectedDataSize: UInt64);
begin
  LzmaEnc_SetDataSize(FHandle, ExpectedDataSize);
end;

function TLzmaSdkLzmaEnc.WriteProperties(Properties: PByte; var Size: SizeT): SRes;
begin
  Result := LzmaEnc_WriteProperties(FHandle, Properties, Size);
end;

function TLzmaSdkLzmaEnc.WriteProperties(out Properties: TBytes): SRes;
var Size: SizeT;
begin
  SetLength(Properties, LZMA_PROPS_SIZE);
  Size := Length(Properties);
  Result := WriteProperties(PByte(Properties), Size);
  if Result <> SZ_OK then Properties := nil;
end;

function TLzmaSdkLzmaEnc.IsWriteEndMark: UInt32;
begin
  Result := LzmaEnc_IsWriteEndMark(FHandle);
end;

function TLzmaSdkLzmaEnc.Encode(const Source: ILzmaSeqInStream;
  const Destination: ILzmaSeqOutStream; const Progress: ILzmaCompressProgress): SRes;
var Input: ILzmaSeqInStream; Output: ILzmaSeqOutStream; Callback: ILzmaCompressProgress;
begin
  if (Source = nil) or (Destination = nil) then Exit(SZ_ERROR_PARAM);
  Finish;
  Input := TReadCallback.Create(Source);
  Output := TWriteCallback.Create(Destination);
  Callback := GuardProgress(Progress);
  try
    Result := LzmaEnc_Encode(FHandle, Output, Input, Callback, FAllocator, FAllocatorBig);
  finally
    // Borrowed callbacks must outlive every hash/BT worker, also on exceptions.
    Finish;
  end;
end;

function TLzmaSdkLzmaEnc.MemEncode(Dest: PByte; var DestLen: SizeT;
  Src: PByte; SrcLen: SizeT; WriteEndMark: Int32; const Progress: ILzmaCompressProgress): SRes;
var Callback: ILzmaCompressProgress;
begin
  Finish;
  Callback := GuardProgress(Progress);
  try
    Result := LzmaEnc_MemEncode(FHandle, Dest, DestLen, Src, SrcLen,
      WriteEndMark, Callback, FAllocator, FAllocatorBig);
  finally
    Finish;
  end;
end;

function TLzmaSdkLzmaEnc.MemPrepare(Src: PByte; SrcLen: SizeT; KeepWindowSize: UInt32): SRes;
begin
  Finish;
  Result := LzmaEnc_MemPrepare(FHandle, Src, SrcLen, KeepWindowSize, FAllocator, FAllocatorBig);
end;

function TLzmaSdkLzmaEnc.PrepareForLzma2(const Source: ILzmaSeqInStream; KeepWindowSize: UInt32): SRes;
begin
  if Source = nil then Exit(SZ_ERROR_PARAM);
  Finish;
  FPreparedSource := TReadCallback.Create(Source);
  Result := LzmaEnc_PrepareForLzma2(FHandle, FPreparedSource, KeepWindowSize, FAllocator, FAllocatorBig);
end;

function TLzmaSdkLzmaEnc.CodeOneMemBlock(ReInit: Boolean; Dest: PByte;
  var DestLen: SizeT; DesiredPackSize: UInt32; var UnpackSize: UInt32): SRes;
begin
  Result := LzmaEnc_CodeOneMemBlock(FHandle, ReInit, Dest, DestLen, DesiredPackSize, UnpackSize);
end;

function TLzmaSdkLzmaEnc.GetCurBuf: PByte;
begin
  Result := LzmaEnc_GetCurBuf(FHandle);
end;

procedure TLzmaSdkLzmaEnc.SaveState;
begin
  LzmaEnc_SaveState(FHandle);
end;

procedure TLzmaSdkLzmaEnc.RestoreState;
begin
  LzmaEnc_RestoreState(FHandle);
end;

procedure TLzmaSdkLzmaEnc.Finish;
begin
  LzmaEnc_Finish(FHandle);
  FPreparedSource := nil;
end;

end.
