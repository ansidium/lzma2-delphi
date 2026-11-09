unit Lzma2.SdkParser;
// Source-compatible parser adapter over the shared SDK state machine.
interface
uses Lzma.Sdk.Contracts,Lzma2.Sdk.Decoder26;
type
  TLzma2ParseStatus=Lzma.Sdk.Contracts.TLzma2ParseStatus;
  TLzma2ParserState=Lzma.Sdk.Contracts.TLzma2ParserState;
const
  lpsNotSpecified=Lzma.Sdk.Contracts.lpsNotSpecified;
  lpsFinishedWithMark=Lzma.Sdk.Contracts.lpsFinishedWithMark;
  lpsNotFinished=Lzma.Sdk.Contracts.lpsNotFinished;
  lpsNeedsMoreInput=Lzma.Sdk.Contracts.lpsNeedsMoreInput;
  lpsMaybeFinishedWithoutMark=Lzma.Sdk.Contracts.lpsMaybeFinishedWithoutMark;
  lpsNewBlock=Lzma.Sdk.Contracts.lpsNewBlock;lpsNewChunk=Lzma.Sdk.Contracts.lpsNewChunk;
  lzpsControl=Lzma.Sdk.Contracts.lzpsControl;lzpsUnpack0=Lzma.Sdk.Contracts.lzpsUnpack0;
  lzpsUnpack1=Lzma.Sdk.Contracts.lzpsUnpack1;lzpsPack0=Lzma.Sdk.Contracts.lzpsPack0;
  lzpsPack1=Lzma.Sdk.Contracts.lzpsPack1;lzpsProp=Lzma.Sdk.Contracts.lzpsProp;
  lzpsData=Lzma.Sdk.Contracts.lzpsData;lzpsDataCont=Lzma.Sdk.Contracts.lzpsDataCont;
  lzpsFinished=Lzma.Sdk.Contracts.lzpsFinished;lzpsError=Lzma.Sdk.Contracts.lzpsError;
type
  TLzma2SdkParser=record
  private
    FNative:TLzma2Dec26;
    function GetState:TLzma2ParserState;
    function GetControl:Byte;
    function GetNeedInit:Byte;
    function GetExtraMode:Boolean;
    function GetPackSize:UInt32;
    function GetUnpackSize:UInt32;
    function GetLc:Byte;
    function GetLp:Byte;
    function GetPb:Byte;
    function GetUnpackExtra:UInt32;
    function GetDictionaryPosition:NativeUInt;
    procedure SetDictionaryPosition(const Value:NativeUInt);
  public
    class function Create:TLzma2SdkParser;static;
    procedure Init;
    function Parse(const OutputSize:NativeUInt;const Source:Pointer;var SourceSize:NativeUInt;
      const CheckFinishBlock:Boolean):TLzma2ParseStatus;
    property State:TLzma2ParserState read GetState;
    property Control:Byte read GetControl;
    property NeedInitLevel:Byte read GetNeedInit;
    property ExtraMode:Boolean read GetExtraMode;
    property PackedRemaining:UInt32 read GetPackSize;
    property UnpackedRemaining:UInt32 read GetUnpackSize;
    property Lc:Byte read GetLc;
    property Lp:Byte read GetLp;
    property Pb:Byte read GetPb;
    property UnpackExtra:UInt32 read GetUnpackExtra;
    property DictionaryPosition:NativeUInt read GetDictionaryPosition write SetDictionaryPosition;
  end;
implementation
class function TLzma2SdkParser.Create:TLzma2SdkParser;
begin Result:=Default(TLzma2SdkParser);Result.FNative.Decoder.Prop.Lc:=4;Result.Init;end;
procedure TLzma2SdkParser.Init;
begin Lzma2Dec_Init(FNative);end;
function TLzma2SdkParser.Parse(const OutputSize:NativeUInt;const Source:Pointer;var SourceSize:NativeUInt;
  const CheckFinishBlock:Boolean):TLzma2ParseStatus;
begin Result:=Lzma2Dec_Parse(FNative,OutputSize,Source,SourceSize,CheckFinishBlock);end;
function TLzma2SdkParser.GetState:TLzma2ParserState;
begin Result:=TLzma2ParserState(FNative.State);end;
function TLzma2SdkParser.GetControl:Byte;
begin Result:=FNative.Control;end;
function TLzma2SdkParser.GetNeedInit:Byte;
begin Result:=FNative.NeedInitLevel;end;
function TLzma2SdkParser.GetExtraMode:Boolean;
begin Result:=FNative.IsExtraMode<>0;end;
function TLzma2SdkParser.GetPackSize:UInt32;
begin Result:=FNative.PackSize;end;
function TLzma2SdkParser.GetUnpackSize:UInt32;
begin Result:=FNative.UnpackSize;end;
function TLzma2SdkParser.GetLc:Byte;
begin Result:=FNative.Decoder.Prop.Lc;end;
function TLzma2SdkParser.GetLp:Byte;
begin Result:=FNative.Decoder.Prop.Lp;end;
function TLzma2SdkParser.GetPb:Byte;
begin Result:=FNative.Decoder.Prop.Pb;end;
function TLzma2SdkParser.GetUnpackExtra:UInt32;
begin Result:=Lzma2Dec_GetUnpackExtra(FNative);end;
function TLzma2SdkParser.GetDictionaryPosition:NativeUInt;
begin Result:=FNative.Decoder.DicPos;end;
procedure TLzma2SdkParser.SetDictionaryPosition(const Value:NativeUInt);
begin FNative.Decoder.DicPos:=Value;end;
end.
