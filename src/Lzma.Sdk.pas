unit Lzma.Sdk;

{$B-} // Nil-guarded interface and callback checks require short-circuit evaluation.

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.MatchFinder,
  Lzma.Sdk.Properties,
  Lzma.Types,Lzma.Sdk.Contracts,Lzma.Sdk.Decoder26,Lzma2.Sdk.Decoder26,Lzma2.SdkParser,
  Lzma.Sdk.EncoderFacade;

type
  TLzmaSdkLzmaEncProps26 = Lzma.Sdk.Properties.TLzmaSdkLzmaEncProps26;
  TLzmaSdkLzma2EncProps26 = Lzma.Sdk.Properties.TLzmaSdkLzma2EncProps26;
  TLzmaSdkLzmaEnc = Lzma.Sdk.EncoderFacade.TLzmaSdkLzmaEnc;
  TLzmaFinishMode = Lzma.Sdk.Contracts.TLzmaFinishMode;
  TLzmaStatus = Lzma.Sdk.Contracts.TLzmaStatus;
  ILzmaSeqInStream = Lzma.Sdk.Contracts.ILzmaSeqInStream;
  ILzmaSeqOutStream = Lzma.Sdk.Contracts.ILzmaSeqOutStream;
  ILzmaCompressProgress = Lzma.Sdk.Contracts.ILzmaCompressProgress;
  ILzmaAllocator = Lzma.Sdk.Contracts.ILzmaAllocator;
const
  lfmAny = Lzma.Sdk.Contracts.lfmAny;
  lfmEnd = Lzma.Sdk.Contracts.lfmEnd;
  lsNotSpecified = Lzma.Sdk.Contracts.lsNotSpecified;
  lsFinishedWithMark = Lzma.Sdk.Contracts.lsFinishedWithMark;
  lsNotFinished = Lzma.Sdk.Contracts.lsNotFinished;
  lsNeedsMoreInput = Lzma.Sdk.Contracts.lsNeedsMoreInput;
  lsMaybeFinishedWithoutMark = Lzma.Sdk.Contracts.lsMaybeFinishedWithoutMark;
type

  TLzmaSdkSeqInStream = class(TInterfacedObject, ILzmaSeqInStream)
  private
    FStream: TStream;
  public
    constructor Create(const Stream: TStream);
    function Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;

  TLzmaSdkSeqOutStream = class(TInterfacedObject, ILzmaSeqOutStream)
  private
    FStream: TStream;
  public
    constructor Create(const Stream: TStream);
    function Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;

  TLzmaSdkSystemAllocator = class(TInterfacedObject, ILzmaAllocator)
  public
    function Alloc(const Size: SizeT): Pointer;
    procedure FreeMem(const Address: Pointer);
  end;

  TLzmaSdkLzmaEncProps = record
    Level: Integer;
    DictSize: UInt32;
    Lc: Integer;
    Lp: Integer;
    Pb: Integer;
    Algo: Integer;
    Fb: Integer;
    BtMode: Integer;
    NumHashBytes: Integer;
    Mc: Integer;
    WriteEndMark: Integer;
    NumThreads: Integer;
    class function Init: TLzmaSdkLzmaEncProps; static;
    function Normalize: SRes;
    function ToRawProps(out Props: TLzmaProps; out MatchFinderKind: TLzmaMatchFinderKind): SRes;
    function WriteProperties(out PropsBytes: TBytes): SRes;
  end;

  TLzmaSdkLzma2EncProps = record
    LzmaProps: TLzmaSdkLzmaEncProps;
    BlockSize: UInt64;
    NumBlockThreads: Integer;
    NumTotalThreads: Integer;
    class function Init: TLzmaSdkLzma2EncProps; static;
    function Normalize: SRes;
    function WriteProperties(out Prop: Byte): SRes;
  end;

  TLzmaSdkLzmaEncoder = class
  private
    FProps: TLzmaSdkLzmaEncProps;
    FNative: TLzmaSdkLzmaEnc;
    FProps26Active: Boolean;
    FExpectedDataSize: UInt64;
    FExpectedDataSizeSet: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function SetProps(const Props: TLzmaSdkLzmaEncProps): SRes; overload;
    function SetProps(const Props: TLzmaSdkLzmaEncProps26): SRes; overload;
    function WriteProperties(out PropsBytes: TBytes): SRes; overload;
    function WriteProperties(Properties: PByte; var Size: SizeT): SRes; overload;
    function IsWriteEndMark: UInt32;
    procedure SetDataSize(const ExpectedDataSize: UInt64);
    function Encode(const Source: ILzmaSeqInStream; const Destination: ILzmaSeqOutStream;
      const Progress: ILzmaCompressProgress = nil): SRes;
  end;

  TLzmaSdkLzmaDecoder = class
  public
    function Decode(const Source: ILzmaSeqInStream; const Destination: ILzmaSeqOutStream;
      const Progress: ILzmaCompressProgress = nil): SRes;
  end;

  TLzmaSdkLzmaDec = class
  private
    FNative:TLzmaDec26;
    FAllocator:ILzmaAllocator;
    FAllocated,FHasUnpackSize:Boolean;
    FUnpackSize,FProduced:UInt64;
    function GetDicPos:SizeT;
    procedure SetDicPos(const Value:SizeT);
    procedure LimitOutput(var Capacity:SizeT;var FinishMode:TLzmaFinishMode);
    function AccountOutput(const Produced:SizeT;const Res:SRes;var Status:TLzmaStatus):SRes;
  public
    constructor Create;overload;
    constructor Create(const Allocator:ILzmaAllocator);overload;
    destructor Destroy;override;
    function Allocate(const Props:TBytes):SRes;
    procedure Init;
    procedure SetUnpackSize(const UnpackSize:UInt64);
    function DecodeToBuf(var Dest;var DestLen:SizeT;const Src;var SrcLen:SizeT;
      const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
    function DecodeToDic(const DicLimit:SizeT;const Src;var SrcLen:SizeT;
      const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
    function DicData:TBytes;
    property DicPos:SizeT read GetDicPos write SetDicPos;
  end;

  TLzmaSdkLzma2Encoder = class
  private
    FProps: TLzmaSdkLzma2EncProps;
  public
    constructor Create;
    function SetProps(const Props: TLzmaSdkLzma2EncProps): SRes;
    function WriteProperties(out Prop: Byte): SRes;
    function Encode(const Source: ILzmaSeqInStream; const Destination: ILzmaSeqOutStream;
      const Progress: ILzmaCompressProgress = nil): SRes;
  end;

  TLzmaSdkLzma2Decoder = class
  public
    function Decode(const Source: ILzmaSeqInStream; const Destination: ILzmaSeqOutStream;
      const Progress: ILzmaCompressProgress = nil): SRes;
  end;

  TLzmaSdkLzma2Dec = class
  private
    FNative:TLzma2Dec26;
    FAllocator:ILzmaAllocator;
    FParser:TLzma2SdkParser;
    FAllocated:Boolean;
    function GetDicPos:SizeT;
    procedure SetDicPos(const Value:SizeT);
  public
    constructor Create;overload;
    constructor Create(const Allocator:ILzmaAllocator);overload;
    destructor Destroy;override;
    function Allocate(const Prop:Byte):SRes;
    procedure Init;
    function DecodeToBuf(var Dest;var DestLen:SizeT;const Src;var SrcLen:SizeT;
      const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
    function DecodeToDic(const DicLimit:SizeT;const Src;var SrcLen:SizeT;
      const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
    function Parse(const Src;var SrcLen:SizeT;const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
    function DicData:TBytes;
    property DicPos:SizeT read GetDicPos write SetDicPos;
  end;

implementation

uses
  System.Math,
  Lzma.Api,
  Lzma.Decoder,
  Lzma.Encoder,
  Lzma.Errors,
  Lzma.Lzma,
  Lzma.Streams,
  Lzma2.Decoder,
  Lzma2.Encoder;

const
  LZMA_SDK_IO_BUFFER_SIZE = 1 shl 16;

type
  TLzmaSdkSeqInStreamAdapter = class(TStream)
  private
    FPosition: Int64;
    FSource: ILzmaSeqInStream;
  public
    constructor Create(const Source: ILzmaSeqInStream);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TLzmaSdkSeqOutStreamAdapter = class(TStream)
  private
    FDestination: ILzmaSeqOutStream;
    FPosition: Int64;
    FResultCode: SRes;
    FStrictSdkWrite: Boolean;
    function WriteCore(const Buffer; const Count: NativeInt): NativeInt;
  public
    constructor Create(const Destination: ILzmaSeqOutStream; const StrictSdkWrite: Boolean = False);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
{$ENDIF}
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property ResultCode: SRes read FResultCode;
  end;

  TLzmaSdkProgressBridge = class
  private
    FProgress: ILzmaCompressProgress;
    FResultCode: SRes;
  public
    constructor Create(const Progress: ILzmaCompressProgress);
    function AsEvent: TLzma2ProgressEvent;
    property ResultCode: SRes read FResultCode;
  end;

function ExceptionToSRes(const E: Exception): SRes;
begin
  if E is ELzmaError then
    Exit(ELzmaError(E).ResultCode);
  if E is EOutOfMemory then
    Exit(SZ_ERROR_MEM);
  if E is EReadError then
    Exit(SZ_ERROR_READ);
  if E is EWriteError then
    Exit(SZ_ERROR_WRITE);
  Result := SZ_ERROR_FAIL;
end;

function ExceptionToReadSRes(const E: Exception): SRes;
begin
  if (E is ELzmaError) or (E is EOutOfMemory) then
    Exit(ExceptionToSRes(E));
  Result := SZ_ERROR_READ;
end;

function ExceptionToWriteSRes(const E: Exception): SRes;
begin
  if (E is ELzmaError) or (E is EOutOfMemory) then
    Exit(ExceptionToSRes(E));
  Result := SZ_ERROR_WRITE;
end;

function CheckedReadSize(const Count: SizeT): Integer;
begin
  if Count > SizeT(High(Integer)) then
    Result := High(Integer)
  else
    Result := Integer(Count);
end;

function MakeProgressAdapter(const Progress: ILzmaCompressProgress;
  out Bridge: TLzmaSdkProgressBridge): TLzma2ProgressEvent;
begin
  Bridge := nil;
  if Progress = nil then
    Exit(nil);
  Bridge := TLzmaSdkProgressBridge.Create(Progress);
  Result := Bridge.AsEvent();
end;

function MatchFinderKindFromProps(const Props: TLzmaSdkLzmaEncProps): TLzmaMatchFinderKind;
begin
  if Props.BtMode <> 0 then
  begin
    case Props.NumHashBytes of
      2: Result := mfBinaryTree2;
      3: Result := mfBinaryTree3;
      5: Result := mfBinaryTree5;
    else Result := mfBinaryTree4;
    end;
  end
  else if Props.NumHashBytes >= 5 then
    Result := mfHashChain5
  else
    Result := mfHashChain4;
end;

constructor TLzmaSdkProgressBridge.Create(const Progress: ILzmaCompressProgress);
begin
  inherited Create;
  FProgress := Progress;
  FResultCode := SZ_OK;
end;

function TLzmaSdkProgressBridge.AsEvent: TLzma2ProgressEvent;
begin
  Result :=
    procedure(const InBytes: UInt64; const OutBytes: UInt64; var Cancel: Boolean)
    begin
      if FResultCode <> SZ_OK then
      begin
        Cancel := True;
        Exit;
      end;
      FResultCode := FProgress.Progress(InBytes, OutBytes);
      Cancel := FResultCode <> SZ_OK;
    end;
end;

constructor TLzmaSdkSeqInStreamAdapter.Create(const Source: ILzmaSeqInStream);
begin
  inherited Create;
  FSource := Source;
  FPosition := 0;
end;

function TLzmaSdkSeqInStreamAdapter.Read(var Buffer; Count: Longint): Longint;
var
  Processed: SizeT;
  Res: SRes;
begin
  if FSource = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'SDK input stream is nil');
  if Count <= 0 then
    Exit(0);

  Processed := 0;
  Res := FSource.Read(Buffer, SizeT(Count), Processed);
  if Res <> SZ_OK then
    RaiseLzmaError(Res, 'SDK input stream read failed');
  if Processed > SizeT(Count) then
    RaiseLzmaError(SZ_ERROR_READ, 'SDK input stream returned too many bytes');

  Result := Integer(Processed);
  Inc(FPosition, Result);
end;

function TLzmaSdkSeqInStreamAdapter.Write(const Buffer; Count: Longint): Longint;
begin
  Result := 0;
  RaiseLzmaError(SZ_ERROR_WRITE, 'SDK input stream is read-only');
end;

function TLzmaSdkSeqInStreamAdapter.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Origin = soCurrent) and (Offset = 0) then
    Exit(FPosition);
  raise EStreamError.Create('SDK input stream adapter is not seekable');
end;

constructor TLzmaSdkSeqOutStreamAdapter.Create(const Destination: ILzmaSeqOutStream;
  const StrictSdkWrite: Boolean);
begin
  inherited Create;
  FDestination := Destination;
  FPosition := 0;
  FResultCode := SZ_OK;
  FStrictSdkWrite := StrictSdkWrite;
end;

function TLzmaSdkSeqOutStreamAdapter.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
  RaiseLzmaError(SZ_ERROR_READ, 'SDK output stream is write-only');
end;

function TLzmaSdkSeqOutStreamAdapter.WriteCore(const Buffer; const Count: NativeInt): NativeInt;
var
  Offset: NativeInt;
  Processed: SizeT;
  Remaining: SizeT;
  Res: SRes;
  Start: PByte;
begin
  if FDestination = nil then
    RaiseLzmaError(SZ_ERROR_PARAM, 'SDK output stream is nil');
  if Count <= 0 then
    Exit(0);

  Start := @Buffer;
  Offset := 0;
  while Offset < Count do
  begin
    Remaining := SizeT(Count - Offset);
    Processed := 0;
    Res := FDestination.Write(Start[Offset], Remaining, Processed);
    if Res <> SZ_OK then
    begin
      if FStrictSdkWrite then FResultCode := SZ_ERROR_WRITE else FResultCode := Res;
      RaiseLzmaError(FResultCode, 'SDK output stream write failed');
    end;
    if (Processed = 0) or (Processed > Remaining) then
    begin
      FResultCode := SZ_ERROR_WRITE;
      RaiseLzmaError(SZ_ERROR_WRITE, 'SDK output stream made no forward progress');
    end;
    if FStrictSdkWrite and (Processed <> Remaining) then
    begin
      FResultCode := SZ_ERROR_WRITE;
      RaiseLzmaError(SZ_ERROR_WRITE, 'SDK output stream returned a short write');
    end;
    Inc(Offset, NativeInt(Processed));
  end;

  Inc(FPosition, Count);
  Result := Count;
end;

function TLzmaSdkSeqOutStreamAdapter.Write(const Buffer; Count: Longint): Longint;
begin
  Result := Longint(WriteCore(Buffer, Count));
end;

{$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TLzmaSdkSeqOutStreamAdapter.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  Result := WriteCore(Buffer, Count);
end;
{$ENDIF}

function TLzmaSdkSeqOutStreamAdapter.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Origin = soCurrent) and (Offset = 0) then
    Exit(FPosition);
  raise EStreamError.Create('SDK output stream adapter is not seekable');
end;

function BuildOptionsFromLzma2Props(const Props: TLzmaSdkLzma2EncProps): TLzma2Options;
var
  BlockThreads: Integer;
  LzmaThreads: Integer;
  ThreadsByTotal: Integer;
begin
  Result := TLzma2.DefaultOptions;
  Result.Container := lcRawLzma2;
  Result.Level := TLzma2CompressionLevel(EnsureRange(Props.LzmaProps.Level, Low(TLzma2CompressionLevel),
    High(TLzma2CompressionLevel)));
  Result.DictionarySize := Props.LzmaProps.DictSize;
  Result.Lc := Props.LzmaProps.Lc;
  Result.Lp := Props.LzmaProps.Lp;
  Result.Pb := Props.LzmaProps.Pb;
  Result.FastBytes := Props.LzmaProps.Fb;
  if Props.LzmaProps.Mc > 0 then
    Result.CutValue := UInt32(Props.LzmaProps.Mc);
  if Props.LzmaProps.BtMode <> 0 then
    Result.MatchFinderProfile := lmfpBinaryTree4
  else if Props.LzmaProps.NumHashBytes >= 5 then
    Result.MatchFinderProfile := lmfpHashChain5
  else
    Result.MatchFinderProfile := lmfpHashChain4;
  if Props.BlockSize <> 0 then
    Result.BufferSize := NativeUInt(Props.BlockSize);

  LzmaThreads := Props.LzmaProps.NumThreads;
  if LzmaThreads < 1 then
    LzmaThreads := 1;
  BlockThreads := Props.NumBlockThreads;
  if BlockThreads < 1 then
    BlockThreads := 1;
  if Props.NumTotalThreads > 0 then
  begin
    ThreadsByTotal := Props.NumTotalThreads div LzmaThreads;
    if ThreadsByTotal < 1 then
      ThreadsByTotal := Props.NumTotalThreads;
    if BlockThreads > ThreadsByTotal then
      BlockThreads := ThreadsByTotal;
  end;
  Result.ThreadCount := BlockThreads;
  if Props.LzmaProps.Algo <> 0 then
    Result.ParserMode := lpmSdkProfile
  else
    Result.ParserMode := lpmHighSpeed;
end;

function BuildOptionsFromLzmaProps(const Props: TLzmaSdkLzmaEncProps): TLzma2Options;
begin
  Result := TLzma2.DefaultOptions;
  Result.Container := lcLzma;
  Result.Level := TLzma2CompressionLevel(EnsureRange(Props.Level, Low(TLzma2CompressionLevel),
    High(TLzma2CompressionLevel)));
  Result.DictionarySize := Props.DictSize;
  Result.Lc := Props.Lc;
  Result.Lp := Props.Lp;
  Result.Pb := Props.Pb;
  Result.FastBytes := Props.Fb;
  if Props.Mc > 0 then
    Result.CutValue := UInt32(Props.Mc);
  if Props.BtMode <> 0 then
    Result.MatchFinderProfile := lmfpBinaryTree4
  else if Props.NumHashBytes >= 5 then
    Result.MatchFinderProfile := lmfpHashChain5
  else
    Result.MatchFinderProfile := lmfpHashChain4;
  if Props.NumThreads > 0 then
    Result.ThreadCount := Props.NumThreads
  else
    Result.ThreadCount := 1;
  if Props.Algo <> 0 then
    Result.ParserMode := lpmSdkProfile
  else
    Result.ParserMode := lpmHighSpeed;
  Result.LzmaEndMarker := Props.WriteEndMark <> 0;
end;

constructor TLzmaSdkSeqInStream.Create(const Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
end;

function TLzmaSdkSeqInStream.Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
begin
  ProcessedSize := 0;
  if FStream = nil then
    Exit(SZ_ERROR_PARAM);
  try
    if Count = 0 then
      Exit(SZ_OK);
    ProcessedSize := SizeT(FStream.Read(Buffer, CheckedReadSize(Count)));
    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToReadSRes(E);
  end;
end;

constructor TLzmaSdkSeqOutStream.Create(const Stream: TStream);
begin
  inherited Create;
  FStream := Stream;
end;

function TLzmaSdkSeqOutStream.Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
var
  ToWrite: Integer;
begin
  ProcessedSize := 0;
  if FStream = nil then
    Exit(SZ_ERROR_PARAM);
  try
    if Count = 0 then
      Exit(SZ_OK);
    ToWrite := CheckedReadSize(Count);
    ProcessedSize := SizeT(FStream.Write(Buffer, ToWrite));
    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToWriteSRes(E);
  end;
end;

function TLzmaSdkSystemAllocator.Alloc(const Size:SizeT):Pointer;
begin Result:=LzmaDefaultAllocate(Size);end;
procedure TLzmaSdkSystemAllocator.FreeMem(const Address:Pointer);
begin LzmaDefaultFree(Address);end;

class function TLzmaSdkLzmaEncProps.Init: TLzmaSdkLzmaEncProps;
begin
  Result.Level := 5;
  Result.DictSize := 0;
  Result.Lc := -1;
  Result.Lp := -1;
  Result.Pb := -1;
  Result.Algo := -1;
  Result.Fb := -1;
  Result.BtMode := -1;
  Result.NumHashBytes := -1;
  Result.Mc := 0;
  Result.WriteEndMark := 0;
  Result.NumThreads := -1;
end;

function TLzmaSdkLzmaEncProps.Normalize: SRes;
var
  Profile: TLzmaEncoderProfile;
begin
  if Level < 0 then
    Level := 5
  else if Level > 9 then
    Level := 9;

  if DictSize = 0 then
    Profile := TLzmaRawEncoder.NormalizeProfile(TLzma2CompressionLevel(Level), 0)
  else
    Profile := TLzmaRawEncoder.NormalizeProfile(TLzma2CompressionLevel(Level), DictSize);
  if DictSize = 0 then
    DictSize := UInt32(Profile.DictionarySize);

  if Lc < 0 then
    Lc := 3;
  if Lp < 0 then
    Lp := 0;
  if Pb < 0 then
    Pb := 2;
  if (Lc > 8) or (Lp > 4) or (Pb > 4) then
    Exit(SZ_ERROR_PARAM);

  if Algo < 0 then
    Algo := Profile.Algorithm;
  if Algo > 1 then
    Algo := 1;
  if Fb < 0 then
    Fb := Profile.FastBytes;
  if Fb < LZMA_FAST_BYTES_MIN then
    Fb := LZMA_FAST_BYTES_MIN
  else if Fb > LZMA_FAST_BYTES_MAX then
    Fb := LZMA_FAST_BYTES_MAX;

  if BtMode < 0 then
  begin
    if Algo = 0 then
      BtMode := 0
    else if Profile.MatchFinderKind = mfBinaryTree4 then
      BtMode := 1
    else
      BtMode := 0;
  end;
  if BtMode <> 0 then
    BtMode := 1;

  if NumHashBytes < 0 then
  begin
    if (Algo = 0) and (BtMode = 0) then
      NumHashBytes := 5
    else
      NumHashBytes := Profile.NumHashBytes;
  end;
  if NumHashBytes < 2 then
    NumHashBytes := 2
  else if NumHashBytes > 5 then
    NumHashBytes := 5;

  if Mc <= 0 then
    Mc := Integer(Profile.CutValue);
  if NumThreads < 0 then
  begin
    if Algo = 0 then
      NumThreads := 1
    else
      NumThreads := Profile.DefaultThreadCount;
  end;
  if NumThreads < 1 then
    NumThreads := 1;

  Result := SZ_OK;
end;

function TLzmaSdkLzmaEncProps.ToRawProps(out Props: TLzmaProps;
  out MatchFinderKind: TLzmaMatchFinderKind): SRes;
var
  Normalized: TLzmaSdkLzmaEncProps;
begin
  Normalized := Self;
  Result := Normalized.Normalize;
  if Result <> SZ_OK then
    Exit;

  Props := TLzmaRawEncoder.DefaultProperties(Normalized.DictSize);
  Props.Lc := Byte(Normalized.Lc);
  Props.Lp := Byte(Normalized.Lp);
  Props.Pb := Byte(Normalized.Pb);
  MatchFinderKind := MatchFinderKindFromProps(Normalized);
end;

function TLzmaSdkLzmaEncProps.WriteProperties(out PropsBytes: TBytes): SRes;
var
  MatchFinderKind: TLzmaMatchFinderKind;
  Props: TLzmaProps;
begin
  SetLength(PropsBytes, 0);
  Result := ToRawProps(Props, MatchFinderKind);
  if Result <> SZ_OK then
    Exit;
  PropsBytes := TLzmaRawEncoder.WriteProperties(Props);
end;

class function TLzmaSdkLzma2EncProps.Init: TLzmaSdkLzma2EncProps;
begin
  Result.LzmaProps := TLzmaSdkLzmaEncProps.Init;
  Result.BlockSize := 0;
  Result.NumBlockThreads := -1;
  Result.NumTotalThreads := -1;
end;

function TLzmaSdkLzma2EncProps.Normalize: SRes;
var
  LzmaThreads: Integer;
  ThreadsByTotal: Integer;
begin
  Result := LzmaProps.Normalize;
  if Result <> SZ_OK then
    Exit;
  if LzmaProps.Lc + LzmaProps.Lp > 4 then
    Exit(SZ_ERROR_PARAM);

  if BlockSize > UInt64(High(NativeUInt)) then
    Exit(SZ_ERROR_PARAM);

  LzmaThreads := LzmaProps.NumThreads;
  if LzmaThreads < 1 then
    LzmaThreads := 1;

  if NumTotalThreads < 0 then
  begin
    if NumBlockThreads < 1 then
      NumBlockThreads := 1;
    if NumBlockThreads > High(Integer) div LzmaThreads then
      NumTotalThreads := High(Integer)
    else
      NumTotalThreads := LzmaThreads * NumBlockThreads;
  end
  else
  begin
    if NumTotalThreads < 1 then
      NumTotalThreads := 1;
    ThreadsByTotal := NumTotalThreads div LzmaThreads;
    if ThreadsByTotal < 1 then
      ThreadsByTotal := NumTotalThreads;
    if NumBlockThreads < 1 then
      NumBlockThreads := ThreadsByTotal
    else if NumBlockThreads > ThreadsByTotal then
      NumBlockThreads := ThreadsByTotal;
  end;
  if NumTotalThreads < 1 then
    NumTotalThreads := 1;
end;

function TLzmaSdkLzma2EncProps.WriteProperties(out Prop: Byte): SRes;
var
  Info: TLzma2DictionaryInfo;
  Normalized: TLzmaSdkLzma2EncProps;
begin
  Prop := 0;
  Normalized := Self;
  Result := Normalized.Normalize;
  if Result <> SZ_OK then
    Exit;
  if not TryLzma2PropertyFromDictionary(Normalized.LzmaProps.DictSize, False, Info) then
    Exit(SZ_ERROR_PARAM);
  Prop := Info.PropertyByte;
  Result := SZ_OK;
end;

constructor TLzmaSdkLzmaEncoder.Create;
begin
  inherited Create;
  FProps := TLzmaSdkLzmaEncProps.Init;
  FExpectedDataSize := High(UInt64);
end;

destructor TLzmaSdkLzmaEncoder.Destroy;
begin
  FNative.Free;
  inherited;
end;

function TLzmaSdkLzmaEncoder.SetProps(const Props: TLzmaSdkLzmaEncProps): SRes;
var
  Normalized: TLzmaSdkLzmaEncProps;
begin
  Normalized := Props;
  Result := Normalized.Normalize;
  if Result = SZ_OK then
  begin
    FProps := Normalized;
    FProps26Active := False;
  end;
end;

function TLzmaSdkLzmaEncoder.SetProps(const Props: TLzmaSdkLzmaEncProps26): SRes;
begin
  try
    if FNative = nil then FNative := TLzmaSdkLzmaEnc.Create;
    Result := FNative.SetProps(Props);
    if Result = SZ_OK then FProps26Active := True;
  except
    on E: Exception do Result := ExceptionToSRes(E);
  end;
end;

function TLzmaSdkLzmaEncoder.WriteProperties(out PropsBytes: TBytes): SRes;
begin
  if FProps26Active then Result := FNative.WriteProperties(PropsBytes)
  else Result := FProps.WriteProperties(PropsBytes);
end;

function TLzmaSdkLzmaEncoder.WriteProperties(Properties: PByte; var Size: SizeT): SRes;
var Bytes: TBytes;
begin
  if (Size < LZMA_PROPS_SIZE) or (Properties = nil) then Exit(SZ_ERROR_PARAM);
  if FProps26Active then Exit(FNative.WriteProperties(Properties, Size));
  Result := FProps.WriteProperties(Bytes);
  if Result = SZ_OK then
  begin Size := LZMA_PROPS_SIZE; Move(Bytes[0], Properties^, LZMA_PROPS_SIZE); end;
end;

function TLzmaSdkLzmaEncoder.IsWriteEndMark: UInt32;
begin
  if FProps26Active then Result := FNative.IsWriteEndMark
  else Move(FProps.WriteEndMark, Result, SizeOf(Result));
end;

procedure TLzmaSdkLzmaEncoder.SetDataSize(const ExpectedDataSize: UInt64);
begin
  FExpectedDataSize := ExpectedDataSize;
  FExpectedDataSizeSet := True;
  if FNative <> nil then FNative.SetDataSize(ExpectedDataSize);
end;

function TLzmaSdkLzmaEncoder.Encode(const Source: ILzmaSeqInStream;
  const Destination: ILzmaSeqOutStream; const Progress: ILzmaCompressProgress): SRes;
var
  Input: TStream;
  MatchFinderKind: TLzmaMatchFinderKind;
  Normalized: TLzmaSdkLzmaEncProps;
  Output: TStream;
  OutputAdapter: TLzmaSdkSeqOutStreamAdapter;
  Profile: TLzmaEncoderProfile;
  ProgressAdapter: TLzma2ProgressEvent;
  ProgressBridge: TLzmaSdkProgressBridge;
  Props: TLzmaProps;
  DecisionCount: UInt64;
  ActualThreadCount: Integer;
  RequestedThreads: Integer;
  RequestedHashOutBits: UInt32;
  WriteEndMark: Boolean;
begin
  try
    if (Source = nil) or (Destination = nil) then
      Exit(SZ_ERROR_PARAM);

    if FProps26Active then
    begin
      if FExpectedDataSizeSet then FNative.SetDataSize(FExpectedDataSize);
      Exit(FNative.Encode(Source, Destination, Progress));
    end;

    RequestedHashOutBits := 0;
    Normalized := FProps;
    Result := Normalized.Normalize;
    if Result <> SZ_OK then
      Exit;
    Result := Normalized.ToRawProps(Props, MatchFinderKind);
    if Result <> SZ_OK then
      Exit;

    Profile := TLzmaRawEncoder.NormalizeProfile(
      TLzma2CompressionLevel(EnsureRange(Normalized.Level, Low(TLzma2CompressionLevel),
      High(TLzma2CompressionLevel))), Normalized.DictSize);
    Profile.DictionarySize := Props.DictionarySize;
    Profile.Algorithm := Normalized.Algo;
    Profile.FastBytes := Normalized.Fb;
    Profile.CutValue := UInt32(Normalized.Mc);
    RequestedThreads := Normalized.NumThreads;
    WriteEndMark := Normalized.WriteEndMark <> 0;
    Profile.MatchFinderKind := MatchFinderKind;
    case MatchFinderKind of
      mfHashChain5:
        begin
          Profile.MatchFinderProfile := lmfpHashChain5;
          Profile.NumHashBytes := 5;
          Profile.MatchFinder := 'hc5-sdk-facade';
        end;
      mfBinaryTree2, mfBinaryTree3, mfBinaryTree4, mfBinaryTree5:
        begin
          Profile.MatchFinderProfile := lmfpBinaryTree4;
          Profile.NumHashBytes := 4;
          case MatchFinderKind of
            mfBinaryTree2: Profile.NumHashBytes := 2;
            mfBinaryTree3: Profile.NumHashBytes := 3;
            mfBinaryTree5: Profile.NumHashBytes := 5;
          end;
          Profile.MatchFinder := 'bt' + IntToStr(Profile.NumHashBytes) + '-sdk-facade';
        end;
    else
      Profile.MatchFinderProfile := lmfpHashChain4;
      Profile.NumHashBytes := 4;
      Profile.MatchFinder := 'hc4-sdk-facade';
    end;
    if Profile.Algorithm <> 0 then
      Profile.ParserMode := lpmSdkProfile
    else
      Profile.ParserMode := lpmHighSpeed;

    Input := TLzmaSdkSeqInStreamAdapter.Create(Source);
    OutputAdapter := TLzmaSdkSeqOutStreamAdapter.Create(Destination, False);
    Output := OutputAdapter;
    ProgressAdapter := MakeProgressAdapter(Progress, ProgressBridge);
    try
      try
        try
          if FExpectedDataSizeSet then
            TLzmaRawEncoder.EncodeWithSdkSettings(Input, Output, Profile, Props,
              WriteEndMark, 0, 0, RequestedThreads, RequestedHashOutBits, FExpectedDataSize,
              DecisionCount, ActualThreadCount, ProgressAdapter)
          else
            TLzmaRawEncoder.EncodeWithThreads(Input, Output, Profile, Props,
              WriteEndMark, 0, 0, RequestedThreads,
              DecisionCount, ActualThreadCount, ProgressAdapter);
        except
          on E: Exception do
          begin
            if OutputAdapter.ResultCode <> SZ_OK then
              Exit(OutputAdapter.ResultCode);
            if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
              Exit(ProgressBridge.ResultCode);
            raise;
          end;
        end;
        if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
          Exit(ProgressBridge.ResultCode);
      finally
        ProgressBridge.Free;
      end;
    finally
      Output.Free;
      Input.Free;
    end;

    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToSRes(E);
  end;
end;

function TLzmaSdkLzmaDecoder.Decode(const Source: ILzmaSeqInStream;
  const Destination: ILzmaSeqOutStream; const Progress: ILzmaCompressProgress): SRes;
var
  Input: TStream;
  Output: TStream;
  OutputAdapter: TLzmaSdkSeqOutStreamAdapter;
  ProgressAdapter: TLzma2ProgressEvent;
  ProgressBridge: TLzmaSdkProgressBridge;
  Options: TLzma2Options;
begin
  try
    if (Source = nil) or (Destination = nil) then
      Exit(SZ_ERROR_PARAM);

    Input := TLzmaSdkSeqInStreamAdapter.Create(Source);
    OutputAdapter := TLzmaSdkSeqOutStreamAdapter.Create(Destination);
    Output := OutputAdapter;
    try
      Options := TLzma2.DefaultOptions;
      Options.Container := lcLzma;
      ProgressAdapter := MakeProgressAdapter(Progress, ProgressBridge);
      try
        try
          TLzmaStandalone.Decode(Input, Output, Options, ProgressAdapter);
        except
          on E: Exception do
          begin
            if OutputAdapter.ResultCode <> SZ_OK then
              Exit(OutputAdapter.ResultCode);
            if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
              Exit(ProgressBridge.ResultCode);
            raise;
          end;
        end;
        if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
          Exit(ProgressBridge.ResultCode);
      finally
        ProgressBridge.Free;
      end;
    finally
      Output.Free;
      Input.Free;
    end;

    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToSRes(E);
  end;
end;

constructor TLzmaSdkLzmaDec.Create;
begin inherited Create;FAllocator:=LzmaDefaultAllocator;end;
constructor TLzmaSdkLzmaDec.Create(const Allocator:ILzmaAllocator);
begin inherited Create;if Allocator=nil then FAllocator:=LzmaDefaultAllocator else FAllocator:=Allocator;end;
destructor TLzmaSdkLzmaDec.Destroy;
begin if (FNative.Probs<>nil) or (FNative.Dic<>nil) then LzmaDec_Free(FNative,FAllocator);inherited;end;
function TLzmaSdkLzmaDec.Allocate(const Props:TBytes):SRes;
begin
  if Length(Props)<>LZMA_PROPS_SIZE then Exit(SZ_ERROR_UNSUPPORTED);
  Result:=LzmaDec_Allocate(FNative,@Props[0],LZMA_PROPS_SIZE,FAllocator);
  FAllocated:=FNative.Probs<>nil;
  if Result=SZ_OK then begin FHasUnpackSize:=False;FUnpackSize:=0;Init;end;
end;
procedure TLzmaSdkLzmaDec.Init;
begin LzmaDec_Init(FNative);FProduced:=0;end;
procedure TLzmaSdkLzmaDec.SetUnpackSize(const UnpackSize:UInt64);
begin FHasUnpackSize:=True;FUnpackSize:=UnpackSize;Init;end;
function TLzmaSdkLzmaDec.GetDicPos:SizeT;
begin Result:=FNative.DicPos;end;
procedure TLzmaSdkLzmaDec.SetDicPos(const Value:SizeT);
begin
  if Value>FNative.DicBufSize then RaiseLzmaError(SZ_ERROR_PARAM,'Dictionary position exceeds allocated storage');
  FNative.DicPos:=Value;
end;
procedure TLzmaSdkLzmaDec.LimitOutput(var Capacity:SizeT;var FinishMode:TLzmaFinishMode);
var Remaining:UInt64;
begin
  if not FHasUnpackSize then Exit;
  Remaining:=FUnpackSize-FProduced;
  if Capacity>Remaining then Capacity:=SizeT(Remaining);
  if Capacity<Remaining then FinishMode:=lfmAny;
end;
function TLzmaSdkLzmaDec.AccountOutput(const Produced:SizeT;const Res:SRes;var Status:TLzmaStatus):SRes;
begin
  Inc(FProduced,Produced);Result:=Res;
  if FHasUnpackSize and (Result=SZ_OK) and (FProduced<FUnpackSize) then
  begin
    if Status=lsFinishedWithMark then begin Result:=SZ_ERROR_DATA;Status:=lsNotFinished;end
    else if Status=lsMaybeFinishedWithoutMark then Status:=lsNotFinished;
  end;
end;
function TLzmaSdkLzmaDec.DecodeToBuf(var Dest;var DestLen:SizeT;const Src;var SrcLen:SizeT;
  const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
var Mode:TLzmaFinishMode;
begin
  Status:=lsNotSpecified;
  if not FAllocated then begin DestLen:=0;SrcLen:=0;Exit(SZ_ERROR_PARAM);end;
  Mode:=FinishMode;LimitOutput(DestLen,Mode);
  Result:=LzmaDec_DecodeToBuf(FNative,@Dest,DestLen,@Src,SrcLen,Mode,Status);
  Result:=AccountOutput(DestLen,Result,Status);
end;
function TLzmaSdkLzmaDec.DecodeToDic(const DicLimit:SizeT;const Src;var SrcLen:SizeT;
  const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
var Mode:TLzmaFinishMode;Capacity,Before:SizeT;
begin
  Status:=lsNotSpecified;
  if not FAllocated or (DicLimit<FNative.DicPos) or (DicLimit>FNative.DicBufSize) then
  begin SrcLen:=0;Exit(SZ_ERROR_PARAM);end;
  Before:=FNative.DicPos;Capacity:=DicLimit-Before;Mode:=FinishMode;LimitOutput(Capacity,Mode);
  Result:=LzmaDec_DecodeToDic(FNative,Before+Capacity,@Src,SrcLen,Mode,Status);
  Result:=AccountOutput(FNative.DicPos-Before,Result,Status);
end;
function TLzmaSdkLzmaDec.DicData:TBytes;
begin
  SetLength(Result,NativeInt(FNative.DicPos));
  if FNative.DicPos<>0 then Move(FNative.Dic^,Result[0],FNative.DicPos);
end;

constructor TLzmaSdkLzma2Encoder.Create;
begin
  inherited Create;
  FProps := TLzmaSdkLzma2EncProps.Init;
end;

function TLzmaSdkLzma2Encoder.SetProps(const Props: TLzmaSdkLzma2EncProps): SRes;
var
  Normalized: TLzmaSdkLzma2EncProps;
begin
  Normalized := Props;
  Result := Normalized.Normalize;
  if Result = SZ_OK then
    FProps := Normalized;
end;

function TLzmaSdkLzma2Encoder.WriteProperties(out Prop: Byte): SRes;
begin
  Result := FProps.WriteProperties(Prop);
end;

function TLzmaSdkLzma2Encoder.Encode(const Source: ILzmaSeqInStream;
  const Destination: ILzmaSeqOutStream; const Progress: ILzmaCompressProgress): SRes;
var
  Input: TStream;
  Normalized: TLzmaSdkLzma2EncProps;
  Options: TLzma2Options;
  Output: TStream;
  OutputAdapter: TLzmaSdkSeqOutStreamAdapter;
  ProgressAdapter: TLzma2ProgressEvent;
  ProgressBridge: TLzmaSdkProgressBridge;
begin
  try
    if (Source = nil) or (Destination = nil) then
      Exit(SZ_ERROR_PARAM);

    Normalized := FProps;
    Result := Normalized.Normalize;
    if Result <> SZ_OK then
      Exit;
    Options := BuildOptionsFromLzma2Props(Normalized);
    Input := TLzmaSdkSeqInStreamAdapter.Create(Source);
    OutputAdapter := TLzmaSdkSeqOutStreamAdapter.Create(Destination);
    Output := OutputAdapter;
    try
      ProgressAdapter := MakeProgressAdapter(Progress, ProgressBridge);
      try
        try
          TLzma2Encoder.EncodeRawWithAlgorithm(Input, Output, Options,
            Normalized.LzmaProps.Algo, ProgressAdapter);
        except
          on E: Exception do
          begin
            if OutputAdapter.ResultCode <> SZ_OK then
              Exit(OutputAdapter.ResultCode);
            if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
              Exit(ProgressBridge.ResultCode);
            raise;
          end;
        end;
        if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
          Exit(ProgressBridge.ResultCode);
      finally
        ProgressBridge.Free;
      end;
    finally
      Output.Free;
      Input.Free;
    end;

    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToSRes(E);
  end;
end;

function TLzmaSdkLzma2Decoder.Decode(const Source: ILzmaSeqInStream;
  const Destination: ILzmaSeqOutStream; const Progress: ILzmaCompressProgress): SRes;
var
  Input: TStream;
  Options: TLzma2Options;
  Output: TStream;
  OutputAdapter: TLzmaSdkSeqOutStreamAdapter;
  ProgressAdapter: TLzma2ProgressEvent;
  ProgressBridge: TLzmaSdkProgressBridge;
begin
  try
    if (Source = nil) or (Destination = nil) then
      Exit(SZ_ERROR_PARAM);

    Input := TLzmaSdkSeqInStreamAdapter.Create(Source);
    OutputAdapter := TLzmaSdkSeqOutStreamAdapter.Create(Destination);
    Output := OutputAdapter;
    try
      Options := TLzma2.DefaultOptions;
      Options.Container := lcRawLzma2;
      ProgressAdapter := MakeProgressAdapter(Progress, ProgressBridge);
      try
        try
          TLzma2Decoder.DecodeRaw(Input, Output, Options, ProgressAdapter);
        except
          on E: Exception do
          begin
            if OutputAdapter.ResultCode <> SZ_OK then
              Exit(OutputAdapter.ResultCode);
            if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
              Exit(ProgressBridge.ResultCode);
            raise;
          end;
        end;
        if (ProgressBridge <> nil) and (ProgressBridge.ResultCode <> SZ_OK) then
          Exit(ProgressBridge.ResultCode);
      finally
        ProgressBridge.Free;
      end;
    finally
      Output.Free;
      Input.Free;
    end;

    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToSRes(E);
  end;
end;

constructor TLzmaSdkLzma2Dec.Create;
begin inherited Create;FAllocator:=LzmaDefaultAllocator;end;
constructor TLzmaSdkLzma2Dec.Create(const Allocator:ILzmaAllocator);
begin inherited Create;if Allocator=nil then FAllocator:=LzmaDefaultAllocator else FAllocator:=Allocator;end;
destructor TLzmaSdkLzma2Dec.Destroy;
begin if (FNative.Decoder.Probs<>nil) or (FNative.Decoder.Dic<>nil) then Lzma2Dec_Free(FNative,FAllocator);inherited;end;
function TLzmaSdkLzma2Dec.Allocate(const Prop:Byte):SRes;
begin
  Result:=Lzma2Dec_Allocate(FNative,Prop,FAllocator);
  FAllocated:=FNative.Decoder.Probs<>nil;
  if Result=SZ_OK then Init;
end;
procedure TLzmaSdkLzma2Dec.Init;
begin
  Lzma2Dec_Init(FNative);FParser:=TLzma2SdkParser.Create;
end;
function TLzmaSdkLzma2Dec.GetDicPos:SizeT;
begin Result:=FNative.Decoder.DicPos;end;
procedure TLzmaSdkLzma2Dec.SetDicPos(const Value:SizeT);
begin
  if Value>FNative.Decoder.DicBufSize then RaiseLzmaError(SZ_ERROR_PARAM,'Dictionary position exceeds allocated storage');
  FNative.Decoder.DicPos:=Value;
end;
function TLzmaSdkLzma2Dec.DecodeToBuf(var Dest;var DestLen:SizeT;const Src;var SrcLen:SizeT;
  const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
begin
  if not FAllocated then begin DestLen:=0;SrcLen:=0;Status:=lsNotSpecified;Exit(SZ_ERROR_PARAM);end;
  Result:=Lzma2Dec_DecodeToBuf(FNative,@Dest,DestLen,@Src,SrcLen,FinishMode,Status);
end;
function TLzmaSdkLzma2Dec.DecodeToDic(const DicLimit:SizeT;const Src;var SrcLen:SizeT;
  const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
begin
  if not FAllocated then begin SrcLen:=0;Status:=lsNotSpecified;Exit(SZ_ERROR_PARAM);end;
  Result:=Lzma2Dec_DecodeToDic(FNative,DicLimit,@Src,SrcLen,FinishMode,Status);
end;
function TLzmaSdkLzma2Dec.Parse(const Src;var SrcLen:SizeT;
  const FinishMode:TLzmaFinishMode;out Status:TLzmaStatus):SRes;
var InputSize,Used:SizeT;Cursor:PByte;Parsed:TLzma2ParseStatus;
begin
  InputSize:=SrcLen;SrcLen:=0;Status:=lsNotSpecified;Result:=SZ_OK;
  if not FAllocated then Exit(SZ_ERROR_PARAM);
  Cursor:=@Src;
  repeat
    Used:=InputSize-SrcLen;
    Parsed:=FParser.Parse(High(SizeT),Cursor,Used,FinishMode=lfmEnd);
    Inc(Cursor,Used);Inc(SrcLen,Used);
  until (Parsed<>lpsNewBlock) and (Parsed<>lpsNewChunk);
  case Parsed of
    lpsFinishedWithMark:Status:=lsFinishedWithMark;
    lpsNotFinished:Status:=lsNotFinished;
    lpsNeedsMoreInput:Status:=lsNeedsMoreInput;
  else Result:=SZ_ERROR_DATA;Status:=lsNotFinished;end;
end;
function TLzmaSdkLzma2Dec.DicData:TBytes;
begin
  SetLength(Result,NativeInt(FNative.Decoder.DicPos));
  if FNative.Decoder.DicPos<>0 then Move(FNative.Decoder.Dic^,Result[0],FNative.Decoder.DicPos);
end;

end.
