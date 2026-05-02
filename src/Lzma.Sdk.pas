unit Lzma.Sdk;

interface

uses
  System.Classes,
  System.SysUtils,
  Lzma.MatchFinder,
  Lzma.Types;

type
  TLzmaFinishMode = (
    lfmAny,
    lfmEnd
  );

  TLzmaStatus = (
    lsNotSpecified,
    lsFinishedWithMark,
    lsNotFinished,
    lsNeedsMoreInput,
    lsMaybeFinishedWithoutMark
  );

  ILzmaSeqInStream = interface
    ['{ACB685A7-1664-45C5-B9E6-C6261CE7E6E7}']
    function Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;

  ILzmaSeqOutStream = interface
    ['{3B42F50C-74E5-47AC-A2B4-7C2D058D15D2}']
    function Write(const Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;

  ILzmaCompressProgress = interface
    ['{2358CD94-AE6E-44C9-BBC8-25B66B9BA078}']
    function Progress(const InSize, OutSize: UInt64): SRes;
  end;

  ILzmaAllocator = interface
    ['{D95BF641-A965-4B54-B140-6A6F1051D259}']
    function Alloc(const Size: SizeT): Pointer;
    procedure FreeMem(const Address: Pointer);
  end;

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
  public
    constructor Create;
    function SetProps(const Props: TLzmaSdkLzmaEncProps): SRes;
    function WriteProperties(out PropsBytes: TBytes): SRes;
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
    FAllocated: Boolean;
    FDecoded: TBytes;
    FDecodedPos: SizeT;
    FDecodedReady: Boolean;
    FDic: TBytes;
    FDicPos: SizeT;
    FHasUnpackSize: Boolean;
    FInputBuffer: TBytes;
    FKnownSizeDecodedBytes: UInt64;
    FKnownSizeFinished: Boolean;
    FProps: TLzmaProps;
    FPropsBytes: TBytes;
    FUnpackSize: UInt64;
    function CopyPendingToBuf(var Dest; const Capacity: SizeT): SizeT;
    function CopyPendingToDic(const DicLimit: SizeT; out Copied: SizeT): SRes;
    procedure CompactPendingDecoded;
    function EnsureDecoded(const Src; var SrcLen: SizeT; const FinishMode: TLzmaFinishMode): SRes;
    function PendingDecodedSize: SizeT;
    function ProduceKnownSizeDecoded(const Src; var SrcLen: SizeT; const RequestedOutput: SizeT;
      const FinishMode: TLzmaFinishMode; out NeedsMoreInput: Boolean): SRes;
    procedure SetDecodeStatus(const StatusForFinished: TLzmaStatus; out Status: TLzmaStatus);
  public
    function Allocate(const Props: TBytes): SRes;
    procedure Init;
    procedure SetUnpackSize(const UnpackSize: UInt64);
    function DecodeToBuf(var Dest; var DestLen: SizeT; const Src; var SrcLen: SizeT;
      const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
    function DecodeToDic(const DicLimit: SizeT; const Src; var SrcLen: SizeT;
      const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
    function DicData: TBytes;
    property DicPos: SizeT read FDicPos;
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
    FAllocated: Boolean;
    FDecoded: TBytes;
    FDecodedPos: SizeT;
    FDecodedReady: Boolean;
    FDic: TBytes;
    FDicPos: SizeT;
    FDictionarySize: UInt64;
    FInputBuffer: TBytes;
    FProp: Byte;
    function EnsureDecoded(const Src; var SrcLen: SizeT; const FinishMode: TLzmaFinishMode): SRes;
    procedure SetDecodeStatus(out Status: TLzmaStatus);
  public
    function Allocate(const Prop: Byte): SRes;
    procedure Init;
    function DecodeToBuf(var Dest; var DestLen: SizeT; const Src; var SrcLen: SizeT;
      const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
    function DecodeToDic(const DicLimit: SizeT; const Src; var SrcLen: SizeT;
      const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
    function Parse(const Src; var SrcLen: SizeT; const FinishMode: TLzmaFinishMode;
      out Status: TLzmaStatus): SRes;
    function DicData: TBytes;
    property DicPos: SizeT read FDicPos;
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
    function WriteCore(const Buffer; const Count: NativeInt): NativeInt;
  public
    constructor Create(const Destination: ILzmaSeqOutStream);
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

function AppendDecodeInput(var InputBuffer: TBytes; const Src; const SrcLen: SizeT;
  out OldLen: SizeT): SRes;
begin
  if SrcLen > SizeT(High(NativeInt)) then
    Exit(SZ_ERROR_MEM);
  OldLen := SizeT(Length(InputBuffer));
  if SrcLen > SizeT(High(NativeInt)) - OldLen then
    Exit(SZ_ERROR_MEM);
  if SrcLen <> 0 then
  begin
    SetLength(InputBuffer, NativeInt(OldLen + SrcLen));
    Move(Src, InputBuffer[NativeInt(OldLen)], NativeInt(SrcLen));
  end;
  Result := SZ_OK;
end;

function ConsumedFromCurrentCall(const ConsumedTotal, OldLen, SourceLen: SizeT): SizeT;
begin
  if ConsumedTotal <= OldLen then
    Exit(0);
  Result := ConsumedTotal - OldLen;
  if Result > SourceLen then
    Result := SourceLen;
end;

function ValidateLzma2ChunkProp(const Prop: Byte): SRes;
var
  D: Byte;
  Lc: Byte;
  Lp: Byte;
begin
  if Prop >= 9 * 5 * 5 then
    Exit(SZ_ERROR_UNSUPPORTED);
  D := Prop;
  Lc := D mod 9;
  D := D div 9;
  Lp := D mod 5;
  if Lc + Lp > 4 then
    Exit(SZ_ERROR_UNSUPPORTED);
  Result := SZ_OK;
end;

function ParseRawLzma2Embedded(const Data: TBytes; out ConsumedBytes: UInt64): SRes;
var
  Control: Byte;
  NeedInitLevel: Byte;
  PackSize: NativeUInt;
  Pos: NativeUInt;
begin
  ConsumedBytes := 0;
  NeedInitLevel := $E0;
  Pos := 0;

  while Pos < NativeUInt(Length(Data)) do
  begin
    Control := Data[Pos];
    Inc(Pos);

    if Control = LZMA2_CONTROL_EOF then
    begin
      ConsumedBytes := Pos;
      Exit(SZ_OK);
    end;

    if (Control = LZMA2_CONTROL_COPY_RESET_DIC) or (Control = LZMA2_CONTROL_COPY_NO_RESET) then
    begin
      if Control = LZMA2_CONTROL_COPY_RESET_DIC then
        NeedInitLevel := $C0
      else if NeedInitLevel = $E0 then
        Exit(SZ_ERROR_DATA);

      if NativeUInt(Length(Data)) - Pos < 2 then
        Exit(SZ_ERROR_INPUT_EOF);
      PackSize := (NativeUInt(Data[Pos]) shl 8) or NativeUInt(Data[Pos + 1]);
      Inc(PackSize);
      Inc(Pos, 2);
      if NativeUInt(Length(Data)) - Pos < PackSize then
        Exit(SZ_ERROR_INPUT_EOF);
      Inc(Pos, PackSize);
      Continue;
    end;

    if Control < $80 then
      Exit(SZ_ERROR_DATA);
    if Control < NeedInitLevel then
      Exit(SZ_ERROR_DATA);

    if NativeUInt(Length(Data)) - Pos < 4 then
      Exit(SZ_ERROR_INPUT_EOF);
    PackSize := (NativeUInt(Data[Pos + 2]) shl 8) or NativeUInt(Data[Pos + 3]);
    Inc(PackSize);
    Inc(Pos, 4);

    if (Control and $40) <> 0 then
    begin
      if Pos >= NativeUInt(Length(Data)) then
        Exit(SZ_ERROR_INPUT_EOF);
      Result := ValidateLzma2ChunkProp(Data[Pos]);
      if Result <> SZ_OK then
        Exit;
      Inc(Pos);
    end;

    if NativeUInt(Length(Data)) - Pos < PackSize then
      Exit(SZ_ERROR_INPUT_EOF);
    Inc(Pos, PackSize);
    NeedInitLevel := 0;
  end;

  Result := SZ_ERROR_INPUT_EOF;
end;

function CopyStreamBytes(const Source: TMemoryStream; out Data: TBytes): SRes;
begin
  if Source.Size > High(NativeInt) then
    Exit(SZ_ERROR_MEM);
  SetLength(Data, NativeInt(Source.Size));
  Source.Position := 0;
  if Length(Data) <> 0 then
    Source.ReadBuffer(Data[0], Length(Data));
  Result := SZ_OK;
end;

function DecodeKnownSizeLzmaPrefix(const InputBuffer: TBytes; const Props: TLzmaProps;
  const UnpackSize: UInt64; out Decoded: TBytes; out ConsumedTotal: SizeT): SRes;
var
  FirstError: SRes;
  PrefixLen: NativeInt;

  function TryDecodePrefix(const Count: NativeInt; out PrefixDecoded: TBytes): SRes;
  var
    Output: TMemoryStream;
    State: TLzmaDecoderState;
  begin
    SetLength(PrefixDecoded, 0);
    try
      Output := TMemoryStream.Create;
      try
        State := TLzmaDecoderState.Create(Props.DictionarySize);
        try
          State.SetProperties(Props);
          State.ResetDictionary;
          State.ResetState;
          State.DecodeChunk(InputBuffer, 0, NativeUInt(Count), UnpackSize, Output);
          Result := CopyStreamBytes(Output, PrefixDecoded);
        finally
          State.Free;
        end;
      finally
        Output.Free;
      end;
    except
      on E: Exception do
        Result := ExceptionToSRes(E);
    end;
  end;

begin
  ConsumedTotal := 0;
  Result := TryDecodePrefix(Length(InputBuffer), Decoded);
  if Result = SZ_OK then
  begin
    ConsumedTotal := SizeT(Length(InputBuffer));
    Exit;
  end;
  if Result = SZ_ERROR_INPUT_EOF then
    Exit;
  if Result <> SZ_ERROR_DATA then
    Exit;

  FirstError := Result;
  for PrefixLen := Length(InputBuffer) - 1 downto 0 do
  begin
    Result := TryDecodePrefix(PrefixLen, Decoded);
    if Result = SZ_OK then
    begin
      ConsumedTotal := SizeT(PrefixLen);
      Exit;
    end;
  end;

  Result := FirstError;
end;

function DecodeKnownSizeLzmaAvailable(const InputBuffer: TBytes; const Props: TLzmaProps;
  const UnpackSize: UInt64; out Decoded: TBytes; out ConsumedTotal: SizeT;
  out Finished, NeedsMoreInput: Boolean): SRes;
var
  Consumed: NativeUInt;
  Output: TMemoryStream;
  State: TLzmaDecoderState;
begin
  SetLength(Decoded, 0);
  ConsumedTotal := 0;
  Finished := False;
  NeedsMoreInput := False;
  try
    Output := TMemoryStream.Create;
    try
      State := TLzmaDecoderState.Create(Props.DictionarySize);
      try
        State.SetProperties(Props);
        State.ResetDictionary;
        State.ResetState;
        State.DecodeKnownSizePartial(InputBuffer, 0, NativeUInt(Length(InputBuffer)), UnpackSize,
          UnpackSize, Output, Consumed, Finished, NeedsMoreInput);
        ConsumedTotal := SizeT(Consumed);
        Result := CopyStreamBytes(Output, Decoded);
        if Result <> SZ_OK then
          Exit;
        Result := SZ_OK;
      finally
        State.Free;
      end;
    finally
      Output.Free;
    end;
  except
    on E: Exception do
      Result := ExceptionToSRes(E);
  end;
end;

function MatchFinderKindFromProps(const Props: TLzmaSdkLzmaEncProps): TLzmaMatchFinderKind;
begin
  if Props.BtMode <> 0 then
    Result := mfBinaryTree4
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

constructor TLzmaSdkSeqOutStreamAdapter.Create(const Destination: ILzmaSeqOutStream);
begin
  inherited Create;
  FDestination := Destination;
  FPosition := 0;
  FResultCode := SZ_OK;
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
      FResultCode := Res;
      RaiseLzmaError(Res, 'SDK output stream write failed');
    end;
    if (Processed = 0) or (Processed > Remaining) then
    begin
      FResultCode := SZ_ERROR_WRITE;
      RaiseLzmaError(SZ_ERROR_WRITE, 'SDK output stream made no forward progress');
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

function TLzmaSdkSystemAllocator.Alloc(const Size: SizeT): Pointer;
begin
  Result := nil;
  if Size = 0 then
    Exit;
  if Size > SizeT(High(NativeInt)) then
    Exit;
  try
    Result := System.AllocMem(NativeInt(Size));
  except
    on E: EOutOfMemory do
      Result := nil;
  end;
end;

procedure TLzmaSdkSystemAllocator.FreeMem(const Address: Pointer);
begin
  if Address <> nil then
    System.FreeMem(Address);
end;

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
end;

function TLzmaSdkLzmaEncoder.SetProps(const Props: TLzmaSdkLzmaEncProps): SRes;
var
  Normalized: TLzmaSdkLzmaEncProps;
begin
  Normalized := Props;
  Result := Normalized.Normalize;
  if Result = SZ_OK then
    FProps := Normalized;
end;

function TLzmaSdkLzmaEncoder.WriteProperties(out PropsBytes: TBytes): SRes;
begin
  Result := FProps.WriteProperties(PropsBytes);
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
begin
  try
    if (Source = nil) or (Destination = nil) then
      Exit(SZ_ERROR_PARAM);

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
    Profile.FastBytes := Normalized.Fb;
    Profile.CutValue := UInt32(Normalized.Mc);
    Profile.MatchFinderKind := MatchFinderKind;
    case MatchFinderKind of
      mfHashChain5:
        begin
          Profile.MatchFinderProfile := lmfpHashChain5;
          Profile.NumHashBytes := 5;
          Profile.MatchFinder := 'hc5-sdk-facade';
        end;
      mfBinaryTree4:
        begin
          Profile.MatchFinderProfile := lmfpBinaryTree4;
          Profile.NumHashBytes := 4;
          Profile.MatchFinder := 'bt4-sdk-facade';
        end;
    else
      Profile.MatchFinderProfile := lmfpHashChain4;
      Profile.NumHashBytes := 4;
      Profile.MatchFinder := 'hc4-sdk-facade';
    end;
    if Normalized.Algo <> 0 then
      Profile.ParserMode := lpmSdkProfile
    else
      Profile.ParserMode := lpmHighSpeed;

    Input := TLzmaSdkSeqInStreamAdapter.Create(Source);
    OutputAdapter := TLzmaSdkSeqOutStreamAdapter.Create(Destination);
    Output := OutputAdapter;
    ProgressAdapter := MakeProgressAdapter(Progress, ProgressBridge);
    try
      try
        try
          TLzmaRawEncoder.Encode(Input, Output, Profile, Props,
            Normalized.WriteEndMark <> 0, ProgressAdapter);
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

function TLzmaSdkLzmaDec.PendingDecodedSize: SizeT;
begin
  if FDecodedPos >= SizeT(Length(FDecoded)) then
    Exit(0);
  Result := SizeT(Length(FDecoded)) - FDecodedPos;
end;

procedure TLzmaSdkLzmaDec.CompactPendingDecoded;
var
  Remaining: SizeT;
begin
  if FDecodedPos = 0 then
    Exit;

  Remaining := PendingDecodedSize;
  if Remaining <> 0 then
    Move(FDecoded[NativeInt(FDecodedPos)], FDecoded[0], NativeInt(Remaining));
  SetLength(FDecoded, NativeInt(Remaining));
  FDecodedPos := 0;
end;

function TLzmaSdkLzmaDec.CopyPendingToBuf(var Dest; const Capacity: SizeT): SizeT;
var
  Available: SizeT;
begin
  Available := PendingDecodedSize;
  Result := Capacity;
  if Result > Available then
    Result := Available;
  if Result <> 0 then
  begin
    Move(FDecoded[NativeInt(FDecodedPos)], Dest, NativeInt(Result));
    Inc(FDecodedPos, Result);
  end;
end;

function TLzmaSdkLzmaDec.CopyPendingToDic(const DicLimit: SizeT; out Copied: SizeT): SRes;
var
  Available: SizeT;
  Capacity: SizeT;
begin
  Copied := 0;
  if FDicPos >= DicLimit then
    Exit(SZ_OK);

  Capacity := DicLimit - FDicPos;
  Available := PendingDecodedSize;
  Copied := Capacity;
  if Copied > Available then
    Copied := Available;
  if Copied <> 0 then
  begin
    if FDicPos + Copied > SizeT(High(NativeInt)) then
      Exit(SZ_ERROR_MEM);
    if SizeT(Length(FDic)) < FDicPos + Copied then
      SetLength(FDic, NativeInt(FDicPos + Copied));
    Move(FDecoded[NativeInt(FDecodedPos)], FDic[NativeInt(FDicPos)], NativeInt(Copied));
    Inc(FDicPos, Copied);
    Inc(FDecodedPos, Copied);
  end;
  Result := SZ_OK;
end;

function TLzmaSdkLzmaDec.ProduceKnownSizeDecoded(const Src; var SrcLen: SizeT;
  const RequestedOutput: SizeT; const FinishMode: TLzmaFinishMode;
  out NeedsMoreInput: Boolean): SRes;
var
  AddLen: SizeT;
  ConsumedBytes: NativeUInt;
  Finished: Boolean;
  OldLen: SizeT;
  OldInputLen: SizeT;
  Output: TMemoryStream;
  OutputBytes: UInt64;
  SourceLen: SizeT;
  State: TLzmaDecoderState;
  SuffixOffset: UInt64;
  TargetOutput: UInt64;
begin
  NeedsMoreInput := False;
  SourceLen := SrcLen;
  SrcLen := 0;

  if FKnownSizeFinished then
    Exit(SZ_OK);
  if not FAllocated then
    Exit(SZ_ERROR_PARAM);

  Result := AppendDecodeInput(FInputBuffer, Src, SourceLen, OldInputLen);
  if Result <> SZ_OK then
    Exit;

  try
    Output := TMemoryStream.Create;
    try
      TargetOutput := FKnownSizeDecodedBytes + UInt64(RequestedOutput);
      if TargetOutput > FUnpackSize then
        TargetOutput := FUnpackSize;

      State := TLzmaDecoderState.Create(FProps.DictionarySize);
      try
        State.SetProperties(FProps);
        State.ResetDictionary;
        State.ResetState;
        State.DecodeKnownSizePartial(FInputBuffer, 0, NativeUInt(Length(FInputBuffer)),
          FUnpackSize, TargetOutput, Output, ConsumedBytes, Finished, NeedsMoreInput);
      finally
        State.Free;
      end;

      if Finished then
      begin
        SrcLen := ConsumedFromCurrentCall(SizeT(ConsumedBytes), OldInputLen, SourceLen);
        if ConsumedBytes < NativeUInt(Length(FInputBuffer)) then
          SetLength(FInputBuffer, NativeInt(ConsumedBytes));
      end
      else
        SrcLen := SourceLen;
      FKnownSizeFinished := Finished;

      OutputBytes := UInt64(Output.Size);
      if OutputBytes < FKnownSizeDecodedBytes then
        Exit(SZ_ERROR_DATA);
      if OutputBytes > FKnownSizeDecodedBytes then
      begin
        SuffixOffset := FKnownSizeDecodedBytes;
        if SuffixOffset > UInt64(High(NativeInt)) then
          Exit(SZ_ERROR_MEM);
        AddLen := SizeT(OutputBytes - SuffixOffset);
        CompactPendingDecoded;
        OldLen := SizeT(Length(FDecoded));
        if AddLen > SizeT(High(NativeInt)) - OldLen then
          Exit(SZ_ERROR_MEM);
        SetLength(FDecoded, NativeInt(OldLen + AddLen));
        Output.Position := Int64(SuffixOffset);
        Output.ReadBuffer(FDecoded[NativeInt(OldLen)], NativeInt(AddLen));
        FKnownSizeDecodedBytes := OutputBytes;
      end;

      Result := SZ_OK;
    finally
      Output.Free;
    end;
  except
    on E: Exception do
    begin
      Result := ExceptionToSRes(E);
      if Result = SZ_ERROR_INPUT_EOF then
      begin
        NeedsMoreInput := True;
        Result := SZ_OK;
      end;
    end;
  end;
end;

function TLzmaSdkLzmaDec.Allocate(const Props: TBytes): SRes;
var
  DecodedProps: TLzmaProps;
begin
  try
    if Length(Props) <> LZMA_PROPS_SIZE then
      Exit(SZ_ERROR_UNSUPPORTED);
    if not TLzmaRawDecoder.DecodeProperties(Props, DecodedProps) then
      Exit(SZ_ERROR_UNSUPPORTED);
    FProps := DecodedProps;
    SetLength(FPropsBytes, Length(Props));
    if Length(Props) <> 0 then
      Move(Props[0], FPropsBytes[0], Length(Props));
    FAllocated := True;
    FHasUnpackSize := False;
    FUnpackSize := 0;
    Init;
    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToSRes(E);
  end;
end;

procedure TLzmaSdkLzmaDec.Init;
begin
  SetLength(FDecoded, 0);
  FDecodedPos := 0;
  FDecodedReady := False;
  FKnownSizeDecodedBytes := 0;
  FKnownSizeFinished := False;
  SetLength(FDic, 0);
  FDicPos := 0;
  SetLength(FInputBuffer, 0);
end;

procedure TLzmaSdkLzmaDec.SetUnpackSize(const UnpackSize: UInt64);
begin
  FUnpackSize := UnpackSize;
  FHasUnpackSize := True;
  SetLength(FDecoded, 0);
  FDecodedPos := 0;
  FDecodedReady := False;
  FKnownSizeDecodedBytes := 0;
  FKnownSizeFinished := False;
  SetLength(FInputBuffer, 0);
end;

function TLzmaSdkLzmaDec.EnsureDecoded(const Src; var SrcLen: SizeT;
  const FinishMode: TLzmaFinishMode): SRes;
var
  ConsumedBytes: SizeT;
  OldInputLen: SizeT;
  Output: TMemoryStream;
  SourceLen: SizeT;
  UsedBytes: NativeUInt;
  State: TLzmaDecoderState;
begin
  SourceLen := SrcLen;
  SrcLen := 0;

  if FDecodedReady then
    Exit(SZ_OK);
  if not FAllocated then
    Exit(SZ_ERROR_PARAM);

  Result := AppendDecodeInput(FInputBuffer, Src, SourceLen, OldInputLen);
  if Result <> SZ_OK then
    Exit;

  try
    Output := TMemoryStream.Create;
    try
      if FHasUnpackSize then
      begin
        Result := DecodeKnownSizeLzmaPrefix(FInputBuffer, FProps, FUnpackSize, FDecoded, ConsumedBytes);
        if Result <> SZ_OK then
        begin
          if Result = SZ_ERROR_INPUT_EOF then
            SrcLen := SourceLen;
          Exit;
        end;
        SrcLen := ConsumedFromCurrentCall(ConsumedBytes, OldInputLen, SourceLen);
        if ConsumedBytes < SizeT(Length(FInputBuffer)) then
          SetLength(FInputBuffer, NativeInt(ConsumedBytes));
        FDecodedPos := 0;
        FDecodedReady := True;
        Exit(SZ_OK);
      end
      else
      begin
        State := TLzmaDecoderState.Create(FProps.DictionarySize);
        try
          State.SetProperties(FProps);
          State.ResetDictionary;
          State.ResetState;
          UsedBytes := State.DecodeUntilEndMarker(FInputBuffer, 0, NativeUInt(Length(FInputBuffer)), Output);
          SrcLen := ConsumedFromCurrentCall(SizeT(UsedBytes), OldInputLen, SourceLen);
          if UsedBytes < NativeUInt(Length(FInputBuffer)) then
            SetLength(FInputBuffer, NativeInt(UsedBytes));
        finally
          State.Free;
        end;
      end;

      Result := CopyStreamBytes(Output, FDecoded);
      if Result <> SZ_OK then
        Exit;
      FDecodedPos := 0;
      FDecodedReady := True;
      Result := SZ_OK;
    finally
      Output.Free;
    end;
  except
    on E: Exception do
    begin
      if ExceptionToSRes(E) = SZ_ERROR_INPUT_EOF then
        SrcLen := SourceLen;
      Result := ExceptionToSRes(E);
    end;
  end;
end;

procedure TLzmaSdkLzmaDec.SetDecodeStatus(const StatusForFinished: TLzmaStatus;
  out Status: TLzmaStatus);
begin
  if not FDecodedReady then
    Status := lsNeedsMoreInput
  else if FDecodedPos >= SizeT(Length(FDecoded)) then
    Status := StatusForFinished
  else
    Status := lsNotFinished;
end;

function TLzmaSdkLzmaDec.DecodeToBuf(var Dest; var DestLen: SizeT; const Src;
  var SrcLen: SizeT; const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
var
  Available: SizeT;
  Copied: SizeT;
  NeedsMoreInput: Boolean;
  Requested: SizeT;
  SourceLen: SizeT;
  ToCopy: SizeT;
begin
  Status := lsNotSpecified;
  if FHasUnpackSize then
  begin
    Requested := DestLen;
    SourceLen := SrcLen;
    DestLen := 0;
    SrcLen := 0;
    NeedsMoreInput := False;

    Copied := CopyPendingToBuf(Dest, Requested);
    Inc(DestLen, Copied);
    if (DestLen < Requested) and not FKnownSizeFinished then
    begin
      SrcLen := SourceLen;
      Result := ProduceKnownSizeDecoded(Src, SrcLen, Requested - DestLen, FinishMode, NeedsMoreInput);
      if Result <> SZ_OK then
      begin
        Status := lsNotFinished;
        Exit;
      end;
      Copied := CopyPendingToBuf(PByte(@Dest)[NativeInt(DestLen)], Requested - DestLen);
      Inc(DestLen, Copied);
    end;

    if FKnownSizeFinished and (PendingDecodedSize = 0) then
      Status := lsMaybeFinishedWithoutMark
    else if NeedsMoreInput and (DestLen < Requested) then
      Status := lsNeedsMoreInput
    else
      Status := lsNotFinished;
    Exit(SZ_OK);
  end;

  Result := EnsureDecoded(Src, SrcLen, FinishMode);
  if Result <> SZ_OK then
  begin
    if Result = SZ_ERROR_INPUT_EOF then
    begin
      Status := lsNeedsMoreInput;
      Result := SZ_OK;
      DestLen := 0;
    end
    else
      Status := lsNotFinished;
    Exit;
  end;

  Available := SizeT(Length(FDecoded)) - FDecodedPos;
  ToCopy := DestLen;
  if ToCopy > Available then
    ToCopy := Available;
  if ToCopy <> 0 then
    Move(FDecoded[NativeInt(FDecodedPos)], Dest, NativeInt(ToCopy));
  Inc(FDecodedPos, ToCopy);
  DestLen := ToCopy;
  if FHasUnpackSize then
    SetDecodeStatus(lsMaybeFinishedWithoutMark, Status)
  else
    SetDecodeStatus(lsFinishedWithMark, Status);
end;

function TLzmaSdkLzmaDec.DecodeToDic(const DicLimit: SizeT; const Src; var SrcLen: SizeT;
  const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
var
  Available: SizeT;
  Capacity: SizeT;
  Copied: SizeT;
  NeedsMoreInput: Boolean;
  SourceLen: SizeT;
  ToCopy: SizeT;
begin
  Status := lsNotSpecified;
  if FHasUnpackSize then
  begin
    SourceLen := SrcLen;
    SrcLen := 0;
    NeedsMoreInput := False;

    Result := CopyPendingToDic(DicLimit, Copied);
    if Result <> SZ_OK then
    begin
      Status := lsNotFinished;
      Exit;
    end;

    if (FDicPos < DicLimit) and not FKnownSizeFinished then
    begin
      SrcLen := SourceLen;
      Result := ProduceKnownSizeDecoded(Src, SrcLen, DicLimit - FDicPos, FinishMode, NeedsMoreInput);
      if Result <> SZ_OK then
      begin
        Status := lsNotFinished;
        Exit;
      end;
      Result := CopyPendingToDic(DicLimit, Copied);
      if Result <> SZ_OK then
      begin
        Status := lsNotFinished;
        Exit;
      end;
    end;

    if FKnownSizeFinished and (PendingDecodedSize = 0) then
      Status := lsMaybeFinishedWithoutMark
    else if NeedsMoreInput and (FDicPos < DicLimit) then
      Status := lsNeedsMoreInput
    else
      Status := lsNotFinished;
    Exit(SZ_OK);
  end;

  Result := EnsureDecoded(Src, SrcLen, FinishMode);
  if Result <> SZ_OK then
  begin
    if Result = SZ_ERROR_INPUT_EOF then
    begin
      Status := lsNeedsMoreInput;
      Result := SZ_OK;
    end
    else
      Status := lsNotFinished;
    Exit;
  end;

  if FDicPos >= DicLimit then
    ToCopy := 0
  else
  begin
    Capacity := DicLimit - FDicPos;
    Available := SizeT(Length(FDecoded)) - FDecodedPos;
    ToCopy := Capacity;
    if ToCopy > Available then
      ToCopy := Available;
  end;

  if ToCopy <> 0 then
  begin
    if FDicPos + ToCopy > SizeT(High(NativeInt)) then
      Exit(SZ_ERROR_MEM);
    if SizeT(Length(FDic)) < FDicPos + ToCopy then
      SetLength(FDic, NativeInt(FDicPos + ToCopy));
    Move(FDecoded[NativeInt(FDecodedPos)], FDic[NativeInt(FDicPos)], NativeInt(ToCopy));
    Inc(FDicPos, ToCopy);
    Inc(FDecodedPos, ToCopy);
  end;
  if FHasUnpackSize then
    SetDecodeStatus(lsMaybeFinishedWithoutMark, Status)
  else
    SetDecodeStatus(lsFinishedWithMark, Status);
end;

function TLzmaSdkLzmaDec.DicData: TBytes;
begin
  SetLength(Result, NativeInt(FDicPos));
  if FDicPos <> 0 then
    Move(FDic[0], Result[0], NativeInt(FDicPos));
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
  Options: TLzma2Options;
  Output: TStream;
  OutputAdapter: TLzmaSdkSeqOutStreamAdapter;
  ProgressAdapter: TLzma2ProgressEvent;
  ProgressBridge: TLzmaSdkProgressBridge;
begin
  try
    if (Source = nil) or (Destination = nil) then
      Exit(SZ_ERROR_PARAM);

    Options := BuildOptionsFromLzma2Props(FProps);
    Input := TLzmaSdkSeqInStreamAdapter.Create(Source);
    OutputAdapter := TLzmaSdkSeqOutStreamAdapter.Create(Destination);
    Output := OutputAdapter;
    try
      ProgressAdapter := MakeProgressAdapter(Progress, ProgressBridge);
      try
        try
          TLzma2Encoder.EncodeRaw(Input, Output, Options, ProgressAdapter);
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

function TLzmaSdkLzma2Dec.Allocate(const Prop: Byte): SRes;
begin
  try
    if Prop > LZMA2_DIC_PROP_MAX then
      Exit(SZ_ERROR_UNSUPPORTED);
    FProp := Prop;
    FDictionarySize := Lzma2DictionaryFromProperty(Prop);
    FAllocated := True;
    Init;
    Result := SZ_OK;
  except
    on E: Exception do
      Result := ExceptionToSRes(E);
  end;
end;

procedure TLzmaSdkLzma2Dec.Init;
begin
  SetLength(FDecoded, 0);
  FDecodedPos := 0;
  FDecodedReady := False;
  SetLength(FDic, 0);
  FDicPos := 0;
  SetLength(FInputBuffer, 0);
end;

function TLzmaSdkLzma2Dec.EnsureDecoded(const Src; var SrcLen: SizeT;
  const FinishMode: TLzmaFinishMode): SRes;
var
  ConsumedBytes: UInt64;
  Input: TBytesStream;
  OldInputLen: SizeT;
  Options: TLzma2Options;
  Output: TMemoryStream;
  PrefixDecoded: TBytes;
  PrefixFinished: Boolean;
  PrefixConsumedBytes: UInt64;
  SourceLen: SizeT;
  ProducedBytes: UInt64;

  function StoreDecodedOutput(const Source: TMemoryStream): SRes;
  var
    NewDecoded: TBytes;
  begin
    Result := CopyStreamBytes(Source, NewDecoded);
    if Result <> SZ_OK then
      Exit;
    FDecoded := NewDecoded;
    if FDecodedPos > SizeT(Length(FDecoded)) then
      FDecodedPos := SizeT(Length(FDecoded));
    Result := SZ_OK;
  end;

  function TryDecodeCopyOnlyPrefix(out Decoded: TBytes; out ParsedBytes: UInt64;
    out Finished: Boolean): Boolean;
  var
    Available: NativeInt;
    Control: Byte;
    CopyCount: NativeInt;
    OutputOffset: NativeInt;
    Pos: NativeInt;
    ToCopy: NativeInt;
  begin
    Result := True;
    SetLength(Decoded, 0);
    ParsedBytes := UInt64(Length(FInputBuffer));
    Finished := False;
    Pos := 0;
    while Pos < Length(FInputBuffer) do
    begin
      Control := FInputBuffer[Pos];
      Inc(Pos);
      if Control = LZMA2_CONTROL_EOF then
      begin
        ParsedBytes := UInt64(Pos);
        Finished := True;
        Exit(True);
      end;
      if (Control <> LZMA2_CONTROL_COPY_RESET_DIC) and (Control <> LZMA2_CONTROL_COPY_NO_RESET) then
        Exit(False);
      if Pos + 2 > Length(FInputBuffer) then
      begin
        ParsedBytes := UInt64(Length(FInputBuffer));
        Exit(True);
      end;

      CopyCount := ((Integer(FInputBuffer[Pos]) shl 8) or Integer(FInputBuffer[Pos + 1])) + 1;
      Inc(Pos, 2);
      Available := Length(FInputBuffer) - Pos;
      ToCopy := CopyCount;
      if ToCopy > Available then
        ToCopy := Available;
      if ToCopy > 0 then
      begin
        OutputOffset := Length(Decoded);
        SetLength(Decoded, OutputOffset + ToCopy);
        Move(FInputBuffer[Pos], Decoded[OutputOffset], ToCopy);
        Inc(Pos, ToCopy);
      end;
      if ToCopy < CopyCount then
      begin
        ParsedBytes := UInt64(Length(FInputBuffer));
        Exit(True);
      end;
    end;
  end;
begin
  SourceLen := SrcLen;
  SrcLen := 0;

  if FDecodedReady then
    Exit(SZ_OK);
  if not FAllocated then
    Exit(SZ_ERROR_PARAM);

  Result := AppendDecodeInput(FInputBuffer, Src, SourceLen, OldInputLen);
  if Result <> SZ_OK then
    Exit;

  try
    if TryDecodeCopyOnlyPrefix(PrefixDecoded, PrefixConsumedBytes, PrefixFinished) then
    begin
      if PrefixConsumedBytes > UInt64(High(NativeInt)) then
        Exit(SZ_ERROR_MEM);
      SrcLen := ConsumedFromCurrentCall(SizeT(PrefixConsumedBytes), OldInputLen, SourceLen);
      if SizeT(PrefixConsumedBytes) < SizeT(Length(FInputBuffer)) then
        SetLength(FInputBuffer, NativeInt(PrefixConsumedBytes));
      FDecoded := PrefixDecoded;
      if FDecodedPos > SizeT(Length(FDecoded)) then
        FDecodedPos := SizeT(Length(FDecoded));
      FDecodedReady := PrefixFinished;
      Exit(SZ_OK);
    end;

    Input := TBytesStream.Create(FInputBuffer);
    Output := TMemoryStream.Create;
    try
      Options := TLzma2.DefaultOptions;
      Options.Container := lcRawLzma2;
      Options.DictionarySize := FDictionarySize;
      Options.ThreadCount := 1;
      try
        TLzma2Decoder.DecodeRawEmbedded(Input, Output, Options, ConsumedBytes, ProducedBytes);
      except
        on E: Exception do
        begin
          Result := ExceptionToSRes(E);
          if Result <> SZ_ERROR_INPUT_EOF then
            raise;
          SrcLen := SourceLen;
          Result := StoreDecodedOutput(Output);
          if Result <> SZ_OK then
            Exit;
          FDecodedReady := False;
          Exit(SZ_OK);
        end;
      end;
      if ConsumedBytes > UInt64(High(NativeInt)) then
        Exit(SZ_ERROR_MEM);
      SrcLen := ConsumedFromCurrentCall(SizeT(ConsumedBytes), OldInputLen, SourceLen);
      if SizeT(ConsumedBytes) < SizeT(Length(FInputBuffer)) then
        SetLength(FInputBuffer, NativeInt(ConsumedBytes));

      Result := StoreDecodedOutput(Output);
      if Result <> SZ_OK then
        Exit;
      FDecodedReady := True;
      Result := SZ_OK;
    finally
      Output.Free;
      Input.Free;
    end;
  except
    on E: Exception do
    begin
      if ExceptionToSRes(E) = SZ_ERROR_INPUT_EOF then
        SrcLen := SourceLen;
      Result := ExceptionToSRes(E);
    end;
  end;
end;

procedure TLzmaSdkLzma2Dec.SetDecodeStatus(out Status: TLzmaStatus);
begin
  if (not FDecodedReady) and (FDecodedPos < SizeT(Length(FDecoded))) then
    Status := lsNotFinished
  else if not FDecodedReady then
    Status := lsNeedsMoreInput
  else if FDecodedPos >= SizeT(Length(FDecoded)) then
    Status := lsFinishedWithMark
  else
    Status := lsNotFinished;
end;

function TLzmaSdkLzma2Dec.DecodeToBuf(var Dest; var DestLen: SizeT; const Src;
  var SrcLen: SizeT; const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
var
  Available: SizeT;
  ToCopy: SizeT;
begin
  Status := lsNotSpecified;
  Result := EnsureDecoded(Src, SrcLen, FinishMode);
  if Result <> SZ_OK then
  begin
    if Result = SZ_ERROR_INPUT_EOF then
    begin
      Status := lsNeedsMoreInput;
      Result := SZ_OK;
      DestLen := 0;
    end
    else
      Status := lsNotFinished;
    Exit;
  end;

  Available := SizeT(Length(FDecoded)) - FDecodedPos;
  ToCopy := DestLen;
  if ToCopy > Available then
    ToCopy := Available;
  if ToCopy <> 0 then
    Move(FDecoded[NativeInt(FDecodedPos)], Dest, NativeInt(ToCopy));
  Inc(FDecodedPos, ToCopy);
  DestLen := ToCopy;
  SetDecodeStatus(Status);
end;

function TLzmaSdkLzma2Dec.DecodeToDic(const DicLimit: SizeT; const Src; var SrcLen: SizeT;
  const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
var
  Available: SizeT;
  Capacity: SizeT;
  ToCopy: SizeT;
begin
  Status := lsNotSpecified;
  Result := EnsureDecoded(Src, SrcLen, FinishMode);
  if Result <> SZ_OK then
  begin
    if Result = SZ_ERROR_INPUT_EOF then
    begin
      Status := lsNeedsMoreInput;
      Result := SZ_OK;
    end
    else
      Status := lsNotFinished;
    Exit;
  end;

  if FDicPos >= DicLimit then
    ToCopy := 0
  else
  begin
    Capacity := DicLimit - FDicPos;
    Available := SizeT(Length(FDecoded)) - FDecodedPos;
    ToCopy := Capacity;
    if ToCopy > Available then
      ToCopy := Available;
  end;

  if ToCopy <> 0 then
  begin
    if FDicPos + ToCopy > SizeT(High(NativeInt)) then
      Exit(SZ_ERROR_MEM);
    if SizeT(Length(FDic)) < FDicPos + ToCopy then
      SetLength(FDic, NativeInt(FDicPos + ToCopy));
    Move(FDecoded[NativeInt(FDecodedPos)], FDic[NativeInt(FDicPos)], NativeInt(ToCopy));
    Inc(FDicPos, ToCopy);
    Inc(FDecodedPos, ToCopy);
  end;
  SetDecodeStatus(Status);
end;

function TLzmaSdkLzma2Dec.Parse(const Src; var SrcLen: SizeT;
  const FinishMode: TLzmaFinishMode; out Status: TLzmaStatus): SRes;
var
  ConsumedBytes: UInt64;
  OldInputLen: SizeT;
  SourceLen: SizeT;
begin
  Status := lsNotSpecified;
  SourceLen := SrcLen;
  SrcLen := 0;

  if not FAllocated then
    Exit(SZ_ERROR_PARAM);

  Result := AppendDecodeInput(FInputBuffer, Src, SourceLen, OldInputLen);
  if Result <> SZ_OK then
    Exit;

  try
    Result := ParseRawLzma2Embedded(FInputBuffer, ConsumedBytes);
    if Result <> SZ_OK then
      Exit;
    if ConsumedBytes > UInt64(High(NativeInt)) then
      Exit(SZ_ERROR_MEM);
    SrcLen := ConsumedFromCurrentCall(SizeT(ConsumedBytes), OldInputLen, SourceLen);
    SetLength(FInputBuffer, 0);
    SetLength(FDecoded, 0);
    FDecodedPos := 0;
    FDecodedReady := False;
    Status := lsFinishedWithMark;
  except
    on E: Exception do
    begin
      Result := ExceptionToSRes(E);
    end
  end;

  if Result = SZ_ERROR_INPUT_EOF then
  begin
    SrcLen := SourceLen;
    Status := lsNeedsMoreInput;
    Result := SZ_OK;
  end
  else if Result <> SZ_OK then
    Status := lsNotFinished;
end;

function TLzmaSdkLzma2Dec.DicData: TBytes;
begin
  SetLength(Result, NativeInt(FDicPos));
  if FDicPos <> 0 then
    Move(FDic[0], Result[0], NativeInt(FDicPos));
end;

end.
