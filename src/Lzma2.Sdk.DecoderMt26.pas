unit Lzma2.Sdk.DecoderMt26;

// SDK 26.05 Lzma2DecMt interfaces, native stateful decoder and RTL workers.
{$ALIGN 8}
{$POINTERMATH ON}
{$B-}
interface
uses Lzma.Types, Lzma.Sdk.Contracts;
type
  CLzma2DecMtProps = record
    InBufSize_ST,OutStep_ST: SizeT;
{$IFNDEF Z7_ST}
    NumThreads: UInt32;
    InBufSize_MT,OutBlockMax,InBlockMax: SizeT;
{$ENDIF}
  end;
  CLzma2DecMtHandle = Pointer;
  PLzmaUInt64 = ^UInt64;
procedure Lzma2DecMtProps_Init(out Props: CLzma2DecMtProps);
function Lzma2DecMt_Create(const Alloc,AllocMid: ILzmaAllocator): CLzma2DecMtHandle;
procedure Lzma2DecMt_Destroy(Handle: CLzma2DecMtHandle);
function Lzma2DecMt_Init(Handle: CLzma2DecMtHandle; Prop: Byte;
  const Props: CLzma2DecMtProps; OutDataSize: PLzmaUInt64; FinishMode: Int32;
  const Input: ILzmaSeqInStream): SRes;
function Lzma2DecMt_Read(Handle: CLzma2DecMtHandle; Data: PByte;
  var OutSize: SizeT; var InStreamProcessed: UInt64): SRes;
function Lzma2DecMt_Decode(Handle: CLzma2DecMtHandle; Prop: Byte;
  const Props: CLzma2DecMtProps; const Output: ILzmaSeqOutStream;
  OutDataSize: PLzmaUInt64; FinishMode: Int32; const Input: ILzmaSeqInStream;
  var InProcessed: UInt64; var IsMT: Int32; const Progress: ILzmaCompressProgress): SRes;
implementation
uses System.SysUtils, Winapi.Windows, Lzma2.Sdk.Decoder26, Lzma.Sdk.Memory,
  Lzma.Sdk.Threads26;
type
  PDecoder = ^TDecoder;
  TDecoder = record
    Alloc,AllocMid: ILzmaAllocator;
    Props: CLzma2DecMtProps;
    Prop: Byte;
    Input: ILzmaSeqInStream;
    Dec: TLzma2Dec26;
    Buffer: PByte;
    BufferSize,InPos,InLimit: SizeT;
    OutDefined,Finish: Boolean;
    OutSize,OutProcessed,InProcessed: UInt64;
    ReadFinished: Boolean;
    ReadResult: SRes;
  end;
function Allocate(const Alloc: ILzmaAllocator; Size: SizeT): Pointer;
begin
  try if Alloc = nil then Result := LzmaDefaultAllocate(Size) else Result := Alloc.Alloc(Size);
  except on E: EOutOfMemory do Result := nil; end;
end;
procedure Release(const Alloc: ILzmaAllocator; Address: Pointer);
begin if Alloc = nil then LzmaDefaultFree(Address) else Alloc.FreeMem(Address); end;
function ReadInput(const Input: ILzmaSeqInStream; Data: PByte; var Size: SizeT): SRes;
var Requested: SizeT;
begin
  Requested := Size; Size := 0;
  try Result := Input.Read(Data^,Requested,Size);
  except on E: Exception do Result := SZ_ERROR_READ; end;
  if Size > Requested then begin Size := 0; Result := SZ_ERROR_READ; end;
end;
function WriteOutput(const Output: ILzmaSeqOutStream; Data: PByte; Size: SizeT): SRes;
var Written: SizeT;
begin
  try Result := Output.Write(Data^,Size,Written);
    if (Result <> SZ_OK) or (Written <> Size) then Result := SZ_ERROR_WRITE;
  except on E: Exception do Result := SZ_ERROR_WRITE; end;
end;
procedure Lzma2DecMtProps_Init(out Props: CLzma2DecMtProps);
begin
  Props := Default(CLzma2DecMtProps); Props.InBufSize_ST := 1 shl 20; Props.OutStep_ST := 1 shl 20;
{$IFNDEF Z7_ST}
  Props.NumThreads := 1; Props.InBufSize_MT := 1 shl 18;
  Props.OutBlockMax := 1 shl 28; Props.InBlockMax := Props.OutBlockMax+Props.OutBlockMax div 16;
{$ENDIF}
end;
function Lzma2DecMt_Create(const Alloc,AllocMid: ILzmaAllocator): CLzma2DecMtHandle;
var P: PDecoder;
begin
  P := Allocate(Alloc,SizeOf(TDecoder)); if P = nil then Exit(nil);
  FillChar(P^,SizeOf(TDecoder),0); Initialize(P^); P.Alloc := Alloc; P.AllocMid := AllocMid;
  Lzma2Dec_Construct(P.Dec); Lzma2DecMtProps_Init(P.Props); Result := P;
end;
procedure Lzma2DecMt_Destroy(Handle: CLzma2DecMtHandle);
var P: PDecoder; Alloc: ILzmaAllocator;
begin
  P := Handle; if P = nil then Exit; Alloc := P.Alloc;
  Lzma2Dec_Free(P.Dec,P.Alloc); Release(P.AllocMid,P.Buffer); Finalize(P^); Release(Alloc,P);
end;
function Prepare(P: PDecoder): SRes;
begin
  Result := Lzma2Dec_Allocate(P.Dec,P.Prop,P.Alloc); if Result <> SZ_OK then Exit;
  if (P.Buffer = nil) or (P.BufferSize <> P.Props.InBufSize_ST) then
  begin
    Release(P.AllocMid,P.Buffer); P.Buffer := nil; P.BufferSize := 0;
    P.Buffer := Allocate(P.AllocMid,P.Props.InBufSize_ST);
    if P.Buffer = nil then Exit(SZ_ERROR_MEM); P.BufferSize := P.Props.InBufSize_ST;
  end;
  Lzma2Dec_Init(P.Dec);
end;
procedure SetOptions(P: PDecoder; Prop: Byte; const Props: CLzma2DecMtProps;
  OutDataSize: PLzmaUInt64; FinishMode: Int32; const Input: ILzmaSeqInStream);
begin
  P.Prop := Prop; P.Props := Props; P.Input := Input; P.OutDefined := OutDataSize <> nil;
  P.OutSize := 0; if P.OutDefined then P.OutSize := OutDataSize^;
  P.Finish := FinishMode <> 0; P.InProcessed := 0; P.OutProcessed := 0; P.InPos := 0; P.InLimit := 0;
end;
function Lzma2DecMt_Init(Handle: CLzma2DecMtHandle; Prop: Byte;
  const Props: CLzma2DecMtProps; OutDataSize: PLzmaUInt64; FinishMode: Int32;
  const Input: ILzmaSeqInStream): SRes;
begin
  if Prop > 40 then Exit(SZ_ERROR_UNSUPPORTED);
  SetOptions(Handle,Prop,Props,OutDataSize,FinishMode,Input); Result := Prepare(Handle);
end;
function Lzma2DecMt_Read(Handle: CLzma2DecMtHandle; Data: PByte;
  var OutSize: SizeT; var InStreamProcessed: UInt64): SRes;
var P: PDecoder; Size,InCur,OutCur: SizeT; Mode: TLzmaFinishMode;
  Status: TLzmaStatus; ReadRes: SRes;
begin
  P := Handle; Size := OutSize; OutSize := 0; InStreamProcessed := 0; Mode := lfmAny;
  if P.OutDefined and (UInt64(Size) >= P.OutSize-P.OutProcessed) then
  begin Size := SizeT(P.OutSize-P.OutProcessed); if P.Finish then Mode := lfmEnd; end;
  ReadRes := SZ_OK;
  repeat
    if (P.InPos = P.InLimit) and (ReadRes = SZ_OK) then
    begin P.InPos := 0; P.InLimit := P.Props.InBufSize_ST; ReadRes := ReadInput(P.Input,P.Buffer,P.InLimit); end;
    InCur := P.InLimit-P.InPos; OutCur := Size;
    Result := Lzma2Dec_DecodeToBuf(P.Dec,Data,OutCur,P.Buffer+P.InPos,InCur,Mode,Status);
    Inc(P.InPos,InCur); Inc(P.InProcessed,InCur); Inc(InStreamProcessed,InCur);
    Inc(P.OutProcessed,OutCur); Inc(OutSize,OutCur); Dec(Size,OutCur); Inc(Data,OutCur);
    if Result <> SZ_OK then Exit;
    if (InCur = 0) and (OutCur = 0) then Exit(ReadRes);
  until False;
end;
function DecodeSt(P: PDecoder; const Output: ILzmaSeqOutStream;
  const Progress: ILzmaCompressProgress): SRes;
var WritePos,DicPos,Next,Size,InCur,OutCur,WriteSize: SizeT;
  Mode: TLzmaFinishMode; Status: TLzmaStatus; NeedStop,OutFinished: Boolean;
  InPrev,OutPrev: UInt64; W: SRes;
begin
  W := SZ_OK; Result := Prepare(P); if Result <> SZ_OK then Exit;
  WritePos := P.Dec.Decoder.DicPos; InPrev := P.InProcessed; OutPrev := P.OutProcessed;
  repeat
    if (P.InPos = P.InLimit) and not P.ReadFinished then
    begin
      P.InPos := 0; P.InLimit := P.BufferSize; P.ReadResult := ReadInput(P.Input,P.Buffer,P.InLimit);
      P.ReadFinished := (P.InLimit = 0) or (P.ReadResult <> SZ_OK);
    end;
    DicPos := P.Dec.Decoder.DicPos; Next := P.Dec.Decoder.DicBufSize;
    if Next-WritePos > P.Props.OutStep_ST then Next := WritePos+P.Props.OutStep_ST;
    Size := Next-DicPos; Mode := lfmAny;
    if P.OutDefined and (UInt64(Size) >= P.OutSize-P.OutProcessed) then
    begin Size := SizeT(P.OutSize-P.OutProcessed); if P.Finish then Mode := lfmEnd; end;
    InCur := P.InLimit-P.InPos;
    Result := Lzma2Dec_DecodeToDic(P.Dec,DicPos+Size,P.Buffer+P.InPos,InCur,Mode,Status);
    Inc(P.InPos,InCur); Inc(P.InProcessed,InCur); OutCur := P.Dec.Decoder.DicPos-DicPos; Inc(P.OutProcessed,OutCur);
    OutFinished := P.OutDefined and (P.OutSize <= P.OutProcessed);
    NeedStop := (Result <> SZ_OK) or ((InCur = 0) and (OutCur = 0)) or
      (Status = lsFinishedWithMark) or (not P.Finish and OutFinished);
    if NeedStop or (OutCur >= Size) then
    begin
      WriteSize := P.Dec.Decoder.DicPos-WritePos;
      W := WriteOutput(Output,P.Dec.Decoder.Dic+WritePos,WriteSize);
      if P.Dec.Decoder.DicPos = P.Dec.Decoder.DicBufSize then P.Dec.Decoder.DicPos := 0;
      WritePos := P.Dec.Decoder.DicPos; if W <> SZ_OK then Exit(W);
      if NeedStop then
      begin
        if Result <> SZ_OK then Exit;
        if Status = lsFinishedWithMark then
        begin if P.Finish and P.OutDefined and (P.OutSize <> P.OutProcessed) then Exit(SZ_ERROR_DATA); Exit(SZ_OK); end;
        if not P.Finish and OutFinished then Exit(SZ_OK);
        if Status = lsNeedsMoreInput then Exit(SZ_ERROR_INPUT_EOF);
        Exit(SZ_ERROR_DATA);
      end;
    end;
    if (Progress <> nil) and ((P.InProcessed-InPrev >= UInt64(1) shl 22) or
      (P.OutProcessed-OutPrev >= UInt64(1) shl 22)) then
    begin
      try W := Progress.Progress(P.InProcessed,P.OutProcessed); except on E: Exception do W := SZ_ERROR_PROGRESS; end;
      if W <> SZ_OK then Exit(W); InPrev := P.InProcessed; OutPrev := P.OutProcessed;
    end;
  until False;
end;

{$IFNDEF Z7_ST}
const DecoderThreadsMax = 32; // SDK 26.05 MtDec.h
type
  TBlockReader = class(TInterfacedObject,ILzmaSeqInStream)
    Owner: PDecoder; Source: ILzmaSeqInStream; Buffer,Prefix: PByte;
    Pos,Limit,Capacity,PrefixPos,PrefixSize: SizeT;
    Error: SRes; Eof: Boolean;
    constructor Create(P: PDecoder);
    destructor Destroy; override;
    function Ensure: Boolean;
    function Read(var Dest; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;
  TDecodeWork = record
    Owner: PDecoder; Input,Output: PByte;
    InputSize,OutputSize,Consumed,Made: SizeT;
    FinalBlock,Partial,Truncated: Boolean;
    Code: SRes; Thread: CThread;
  end;
  PDecodeWork = ^TDecodeWork;
  TOffsetProgress = class(TInterfacedObject,ILzmaCompressProgress)
    Callback: ILzmaCompressProgress;
    InBase,OutBase: UInt64;
    function Progress(const InSize,OutSize: UInt64): SRes;
  end;
function TOffsetProgress.Progress(const InSize,OutSize: UInt64): SRes;
begin
  try
    Result := Callback.Progress(InBase+InSize,OutBase+OutSize);
    if Result <> SZ_OK then Result := SZ_ERROR_PROGRESS;
  except on E: Exception do Result := SZ_ERROR_PROGRESS; end;
end;
constructor TBlockReader.Create(P: PDecoder);
begin inherited Create; Owner := P; Source := P.Input; Capacity := P.Props.InBufSize_MT; Buffer := Allocate(P.AllocMid,Capacity); end;
destructor TBlockReader.Destroy;
begin Release(Owner.AllocMid,Buffer); inherited; end;
function TBlockReader.Ensure: Boolean;
begin
  if Pos < Limit then Exit(True);
  if Eof then Exit(False);
  Pos := 0; Limit := Capacity; Error := ReadInput(Source,Buffer,Limit);
  Eof := (Error <> SZ_OK) or (Limit = 0); Result := Limit <> 0;
end;
function TBlockReader.Read(var Dest; const Count: SizeT; out ProcessedSize: SizeT): SRes;
var N: SizeT; D: PByte;
begin
  ProcessedSize := 0; D := @Dest; Result := SZ_OK;
  if PrefixPos < PrefixSize then
  begin
    N := PrefixSize-PrefixPos; if N > Count then N := Count;
    LzmaSdkMove(D,Prefix+PrefixPos,N); Inc(PrefixPos,N); Inc(ProcessedSize,N); Exit;
  end;
  if not Ensure then Exit(Error);
  N := Limit-Pos; if N > Count then N := Count;
  LzmaSdkMove(D,Buffer+Pos,N); Inc(Pos,N); ProcessedSize := N;
end;

// A block begins at a dictionary reset. Bounded parsing retains exact bytes;
// oversized independent blocks are handed to the persistent ST decoder.
function CollectBlock(R: TBlockReader; var Data: PByte; var Size,Capacity,OutputSize: SizeT;
  out FinalBlock,Overflow,Truncated: Boolean): SRes;
var Header: array[0..5] of Byte; H,I: Integer; Control: Byte; Payload,Unpack,N,Need,NewCap: SizeT; NewData: PByte;
  function Append(Source: PByte; Count: SizeT): Boolean;
  begin
    Result := False;
    // InBlockMax is reserved/unused in SDK 26.05 Lzma2DecMt.c. Output block
    // bounds and actual allocation failure govern MT-to-ST admission.
    if Count > High(SizeT)-Size-1 then Exit;
    Need := Size+Count+1;
    if Need > Capacity then
    begin
      NewCap := Capacity;
      if NewCap < 65536 then NewCap := 65536;
      while NewCap < Need do
        if NewCap > High(SizeT) div 2 then begin NewCap := Need; Break; end else NewCap := NewCap*2;
      NewData := Allocate(R.Owner.AllocMid,NewCap); if NewData = nil then Exit;
      if Size <> 0 then LzmaSdkMove(NewData,Data,Size);
      Release(R.Owner.AllocMid,Data); Data := NewData; Capacity := NewCap;
    end;
    if Count <> 0 then LzmaSdkMove(Data+Size,Source,Count); Inc(Size,Count); Result := True;
  end;
begin
  Size := 0; OutputSize := 0; FinalBlock := False; Overflow := False; Truncated := False;
  repeat
    if not R.Ensure then begin Truncated := True; Exit(R.Error); end;
    Control := R.Buffer[R.Pos];
    if (Size <> 0) and ((Control = 1) or (Control >= $E0)) then Exit(SZ_OK);
    // Copy control before any bounds fallback, so prefix replay is exact.
    if not Append(@Control,1) then begin Overflow := True; Exit(SZ_OK); end;
    Inc(R.Pos);
    if Control = 0 then begin FinalBlock := True; Exit(SZ_OK); end;
    if (Control <> 1) and (Control <> 2) and (Control < $80) then Exit(SZ_ERROR_DATA);
    if Control < $80 then H := 2 else H := 4+Ord(Control >= $C0);
    for I := 0 to H-1 do
    begin
      if not R.Ensure then begin Truncated := True; Exit(R.Error); end;
      Header[I] := R.Buffer[R.Pos];
      if not Append(@Header[I],1) then begin Overflow := True; Exit(SZ_OK); end;
      Inc(R.Pos);
    end;
    Unpack := SizeT(Header[0])*256+Header[1]+1;
    if Control >= $80 then
    begin Unpack := Unpack+SizeT(Control and $1F)*65536; Payload := SizeT(Header[2])*256+Header[3]+1; end
    else Payload := Unpack;
    if (Unpack > High(SizeT)-OutputSize) or (OutputSize+Unpack > R.Owner.Props.OutBlockMax) then
    begin Overflow := True; Exit(SZ_OK); end;
    Inc(OutputSize,Unpack);
    while Payload <> 0 do
    begin
      if not R.Ensure then begin Truncated := True; Exit(R.Error); end;
      N := R.Limit-R.Pos; if N > Payload then N := Payload;
      if not Append(R.Buffer+R.Pos,N) then begin Overflow := True; Exit(SZ_OK); end;
      Inc(R.Pos,N); Dec(Payload,N);
    end;
  until False;
end;
function DecodeWorker(Param: Pointer): Integer;
var W: PDecodeWork; InSize: SizeT; Mode: TLzmaFinishMode; Status: TLzmaStatus; Dec: TLzma2Dec26;
begin
  W := Param; W.Consumed := W.InputSize; W.Made := W.OutputSize; Mode := lfmEnd;
  if W.Partial or W.Truncated then Mode := lfmAny;
  InSize := W.InputSize;
  Dec := Default(TLzma2Dec26); Lzma2Dec_Construct(Dec);
  try
    W.Code := Lzma2Dec_AllocateProbs(Dec,W.Owner.Prop,W.Owner.Alloc);
    if W.Code = SZ_OK then
    begin
      Dec.Decoder.Dic := W.Output; Dec.Decoder.DicBufSize := W.OutputSize;
      Lzma2Dec_Init(Dec);
      W.Code := Lzma2Dec_DecodeToDic(Dec,W.OutputSize,W.Input,InSize,Mode,Status);
      W.Consumed := InSize; W.Made := Dec.Decoder.DicPos;
      if (W.Code = SZ_OK) and not W.Partial and not W.Truncated and
        ((W.Made <> W.OutputSize) or (W.Consumed <> W.InputSize)) then W.Code := SZ_ERROR_FAIL;
    end else begin W.Consumed := 0; W.Made := 0; end;
  except
    on E: EOutOfMemory do W.Code := SZ_ERROR_MEM;
    on E: Exception do W.Code := SZ_ERROR_FAIL;
  end;
  Lzma2Dec_FreeProbs(Dec,W.Owner.Alloc); Result := 0;
end;
function DecodeMt(P: PDecoder; const Output: ILzmaSeqOutStream;
  var IsMT: Int32; const Progress: ILzmaCompressProgress): SRes;
var R: TBlockReader; ReaderLife: ILzmaSeqInStream; Work: array[0..DecoderThreadsMax-1] of TDecodeWork;
  Capacities: array[0..DecoderThreadsMax-1] of SizeT;
  I,J,Count,Threads,Fallback: Integer; Eof,Overflow,Partial,Stop,Truncated: Boolean;
  N,OutSize: SizeT; Remaining,OutBase,InBase: UInt64; OldInput: ILzmaSeqInStream; W: WRes;
  OffsetCallback: TOffsetProgress; CallbackApi: ILzmaCompressProgress;
begin
  R := TBlockReader.Create(P); ReaderLife := R;
  if R.Buffer = nil then Exit(SZ_ERROR_MEM);
  Threads := Integer(P.Props.NumThreads); if P.Props.NumThreads > DecoderThreadsMax then Threads := DecoderThreadsMax;
  for I := 0 to DecoderThreadsMax-1 do begin Work[I] := Default(TDecodeWork); Capacities[I] := 0; end;
  IsMT := 1; Eof := False; Stop := False; Result := SZ_OK;
  try
    repeat
      Count := 0; Fallback := -1; Remaining := High(UInt64);
      if P.OutDefined then Remaining := P.OutSize-P.OutProcessed;
      for I := 0 to Threads-1 do
      begin
        Work[I].Owner := P;
        Result := CollectBlock(R,Work[I].Input,Work[I].InputSize,Capacities[I],OutSize,Eof,Overflow,Truncated);
        if Result <> SZ_OK then Break;
        if Overflow then begin Fallback := I; Break; end;
        Work[I].OutputSize := OutSize; Work[I].FinalBlock := Eof;
        if (Count = 0) and (P.OutProcessed = 0) and (OutSize = 0) and Eof then begin Fallback := I; Break; end;
        Partial := P.OutDefined and (UInt64(OutSize) > Remaining);
        if Partial and P.Finish then begin Fallback := I; Break; end;
        if Partial then Work[I].OutputSize := SizeT(Remaining);
        Work[I].Partial := Partial and not P.Finish; Work[I].Truncated := Truncated;
        Release(P.AllocMid,Work[I].Output); N := Work[I].OutputSize; if N = 0 then N := 1;
        Work[I].Output := Allocate(P.AllocMid,N);
        if Work[I].Output = nil then begin Result := SZ_ERROR_MEM; Break; end;
        W := Thread_Create(Work[I].Thread,DecodeWorker,@Work[I]);
        if W <> 0 then begin Result := SZ_ERROR_THREAD; Break; end;
        Inc(Count); if P.OutDefined then Dec(Remaining,Work[I].OutputSize);
        if Eof or Truncated or Partial or (P.OutDefined and (Remaining = 0) and not P.Finish) then begin Stop := True; Break; end;
      end;
      for I := 0 to Count-1 do
      begin
        W := Thread_Wait_Close(Work[I].Thread); if (W <> 0) and (Result = SZ_OK) then Result := SZ_ERROR_THREAD;
        if Result <> SZ_OK then Continue;
        Inc(P.InProcessed,Work[I].Consumed);
        N := 0;
        repeat
          OutSize := Work[I].Made-N; if OutSize > UInt32(1) shl 24 then OutSize := UInt32(1) shl 24;
          Result := WriteOutput(Output,Work[I].Output+N,OutSize); Inc(N,OutSize); Inc(P.OutProcessed,OutSize);
          if Result <> SZ_OK then Break;
        until N = Work[I].Made;
        if Result <> SZ_OK then Continue;
        Result := Work[I].Code;
        if (Result = SZ_OK) and (Progress <> nil) then
        begin
          try if Progress.Progress(P.InProcessed,P.OutProcessed) <> SZ_OK then Result := SZ_ERROR_PROGRESS;
          except on E: Exception do Result := SZ_ERROR_PROGRESS; end;
        end;
      end;
      if Result <> SZ_OK then Exit;
      if Fallback >= 0 then
      begin
        R.Prefix := Work[Fallback].Input; R.PrefixSize := Work[Fallback].InputSize; R.PrefixPos := 0;
        OldInput := P.Input; P.Input := ReaderLife; InBase := P.InProcessed; OutBase := P.OutProcessed;
        if P.OutDefined then Dec(P.OutSize,OutBase);
        P.InPos := 0; P.InLimit := 0; P.InProcessed := 0; P.OutProcessed := 0; P.ReadFinished := False; P.ReadResult := SZ_OK;
        CallbackApi := nil;
        if Progress <> nil then
        begin
          OffsetCallback := TOffsetProgress.Create; OffsetCallback.Callback := Progress;
          OffsetCallback.InBase := InBase; OffsetCallback.OutBase := OutBase; CallbackApi := OffsetCallback;
        end;
        try
          Result := DecodeSt(P,Output,CallbackApi);
          if ((Result = SZ_OK) or (Result = SZ_ERROR_INPUT_EOF)) and (P.ReadResult <> SZ_OK) then Result := P.ReadResult;
        finally
          Inc(P.InProcessed,InBase); Inc(P.OutProcessed,OutBase); if P.OutDefined then Inc(P.OutSize,OutBase); P.Input := OldInput;
        end;
        IsMT := 0; Exit;
      end;
      if Stop then
      begin
        if (R.Error <> SZ_OK) then Result := R.Error;
        Exit;
      end;
    until False;
  finally
    for J := 0 to DecoderThreadsMax-1 do
    begin
      if Work[J].Thread <> 0 then Thread_Wait_Close(Work[J].Thread);
      Release(P.AllocMid,Work[J].Output); Release(P.AllocMid,Work[J].Input);
    end;
    ReaderLife := nil;
  end;
end;
{$ENDIF}
function Lzma2DecMt_Decode(Handle: CLzma2DecMtHandle; Prop: Byte;
  const Props: CLzma2DecMtProps; const Output: ILzmaSeqOutStream;
  OutDataSize: PLzmaUInt64; FinishMode: Int32; const Input: ILzmaSeqInStream;
  var InProcessed: UInt64; var IsMT: Int32; const Progress: ILzmaCompressProgress): SRes;
var P: PDecoder;
begin
  InProcessed := 0;
  if Prop > 40 then Exit(SZ_ERROR_UNSUPPORTED);
  P := Handle; SetOptions(P,Prop,Props,OutDataSize,FinishMode,Input);
  P.ReadFinished := False; P.ReadResult := SZ_OK; IsMT := 0;
{$IFNDEF Z7_ST}
  if Props.NumThreads > 1 then
  begin
    if P.OutDefined and (P.OutSize = 0) and not P.Finish then begin IsMT := 1; Exit(SZ_OK); end;
    Result := DecodeMt(P,Output,IsMT,Progress); InProcessed := P.InProcessed; Exit;
  end;
{$ENDIF}
  Result := DecodeSt(P,Output,Progress); InProcessed := P.InProcessed;
  if ((Result = SZ_OK) or (Result = SZ_ERROR_INPUT_EOF)) and (P.ReadResult <> SZ_OK) then Result := P.ReadResult;
end;
end.
