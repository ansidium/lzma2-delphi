unit Lzma2.Sdk.Encoder26;

// SDK 26.05 Lzma2Enc.c, Igor Pavlov, public domain. RTL worker scheduling.
{$POINTERMATH ON}
{$B-}
interface
uses Lzma.Types, Lzma.Sdk.Contracts, Lzma.Sdk.Properties;
type
  CLzma2EncProps = TLzmaSdkLzma2EncProps26;
  CLzma2EncHandle = Pointer;
  PLzmaSizeT = ^SizeT;
procedure Lzma2EncProps_Init(out Props: CLzma2EncProps);
procedure Lzma2EncProps_Normalize(var Props: CLzma2EncProps);
function Lzma2Enc_Create(const Alloc, AllocBig: ILzmaAllocator): CLzma2EncHandle;
procedure Lzma2Enc_Destroy(Handle: CLzma2EncHandle);
function Lzma2Enc_SetProps(Handle: CLzma2EncHandle; const Props: CLzma2EncProps): SRes;
procedure Lzma2Enc_SetDataSize(Handle: CLzma2EncHandle; ExpectedDataSize: UInt64);
function Lzma2Enc_WriteProperties(Handle: CLzma2EncHandle): Byte;
function Lzma2Enc_Encode2(Handle: CLzma2EncHandle;
  const OutStream: ILzmaSeqOutStream; OutBuf: PByte; OutBufSize: PLzmaSizeT;
  const InStream: ILzmaSeqInStream; InData: PByte; InDataSize: SizeT;
  const Progress: ILzmaCompressProgress): SRes;
implementation
uses System.SysUtils, Winapi.Windows, Lzma.Errors, Lzma.Sdk.Encoder26,
  Lzma.Sdk.Threads26, Lzma.Sdk.Memory;
const ChunkCapacity = 65536+16; KeepWindow = 1 shl 21;
{$IFDEF Z7_ST}
  CoderCount = 1;
{$ELSE}
  CoderCount = LZMA_SDK_BLOCK_THREADS_MAX;
{$ENDIF}
type
  TEncoderInt = record
    Enc: CLzmaEncHandle;
    PropsSet, NeedState, NeedProp: Boolean;
    PropsByte: Byte;
    SrcPos: UInt64;
  end;
  PEncoderInt = ^TEncoderInt;
  PEncoder = ^TEncoder;
  TEncoder = record
    Props: CLzma2EncProps;
    ExpectedDataSize: UInt64;
    Alloc, AllocBig: ILzmaAllocator;
    Temp: PByte;
    Coders: array[0..CoderCount-1] of TEncoderInt;
  end;
  TLimitedInput = class(TInterfacedObject,ILzmaSeqInStream)
    Source: ILzmaSeqInStream;
    Limit, Processed: UInt64;
    Finished: Boolean;
    function Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
  end;

function Allocate(const Alloc: ILzmaAllocator; Size: SizeT): Pointer;
begin
  try
    if Alloc = nil then Result := LzmaDefaultAllocate(Size) else Result := Alloc.Alloc(Size);
  except on E: EOutOfMemory do Result := nil; end;
end;
procedure Release(const Alloc: ILzmaAllocator; Address: Pointer);
begin if Alloc = nil then LzmaDefaultFree(Address) else Alloc.FreeMem(Address); end;
function TLimitedInput.Read(var Buffer; const Count: SizeT; out ProcessedSize: SizeT): SRes;
var N: SizeT;
begin
  N := Count;
  if (Limit <> High(UInt64)) and (UInt64(N) > Limit-Processed) then N := SizeT(Limit-Processed);
  ProcessedSize := 0; Result := SZ_OK;
  if N <> 0 then
  begin
    try Result := Source.Read(Buffer,N,ProcessedSize);
    except
      on E: EOutOfMemory do Result := SZ_ERROR_MEM;
      on E: Exception do Result := SZ_ERROR_READ;
    end;
    if ProcessedSize > N then begin ProcessedSize := 0; Exit(SZ_ERROR_READ); end;
    Finished := ProcessedSize = 0; Inc(Processed,ProcessedSize);
  end;
end;
function Report(const Progress: ILzmaCompressProgress; InSize,OutSize: UInt64): SRes;
begin
  Result := SZ_OK;
  if Progress <> nil then
    try
      if Progress.Progress(InSize,OutSize) <> SZ_OK then Result := SZ_ERROR_PROGRESS;
    except on E: Exception do Result := SZ_ERROR_PROGRESS; end;
end;
function Write(const Output: ILzmaSeqOutStream; Data: PByte; Size: SizeT): SRes;
var Written: SizeT;
begin
  try
    Result := Output.Write(Data^,Size,Written);
    if (Result <> SZ_OK) or (Written <> Size) then Result := SZ_ERROR_WRITE;
  except on E: Exception do Result := SZ_ERROR_WRITE; end;
end;
procedure Lzma2EncProps_Init(out Props: CLzma2EncProps);
begin Props := CLzma2EncProps.Init; end;
procedure Lzma2EncProps_Normalize(var Props: CLzma2EncProps);
begin Props.Normalize({$IFDEF Z7_ST}True{$ELSE}False{$ENDIF}); end;
function Lzma2Enc_Create(const Alloc, AllocBig: ILzmaAllocator): CLzma2EncHandle;
var P: PEncoder;
begin
  P := Allocate(Alloc,SizeOf(TEncoder));
  if P = nil then Exit(nil);
  FillChar(P^,SizeOf(TEncoder),0); Initialize(P^);
  P.Alloc := Alloc; P.AllocBig := AllocBig;
  Lzma2EncProps_Init(P.Props); Lzma2EncProps_Normalize(P.Props);
  P.ExpectedDataSize := High(UInt64); Result := P;
end;
procedure Lzma2Enc_Destroy(Handle: CLzma2EncHandle);
var P: PEncoder; Alloc: ILzmaAllocator; I: Integer;
begin
  P := Handle; if P = nil then Exit; Alloc := P.Alloc;
  for I := 0 to CoderCount-1 do
    if P.Coders[I].Enc <> nil then LzmaEnc_Destroy(P.Coders[I].Enc,P.Alloc,P.AllocBig);
  Release(P.Alloc,P.Temp); Finalize(P^); Release(Alloc,P);
end;
function Lzma2Enc_SetProps(Handle: CLzma2EncHandle; const Props: CLzma2EncProps): SRes;
var Lz: CLzmaEncProps;
begin
  Lz := Props.LzmaProps; LzmaEncProps_Normalize(Lz);
  if Int64(Lz.Lc)+Lz.Lp > 4 then Exit(SZ_ERROR_PARAM);
  PEncoder(Handle).Props := Props; Lzma2EncProps_Normalize(PEncoder(Handle).Props);
  Result := SZ_OK;
end;
procedure Lzma2Enc_SetDataSize(Handle: CLzma2EncHandle; ExpectedDataSize: UInt64);
begin PEncoder(Handle).ExpectedDataSize := ExpectedDataSize; end;
function Lzma2Enc_WriteProperties(Handle: CLzma2EncHandle): Byte;
begin Result := PEncoder(Handle).Props.WriteProperties({$IFDEF Z7_ST}True{$ELSE}False{$ENDIF}); end;

function EncodeSubblock(P: PEncoderInt; Buffer: PByte; var PackSize: SizeT;
  const Output: ILzmaSeqOutStream): SRes;
var Limit, Encoded, Header, DestPos: SizeT; Unpacked,U,Pm,Mode: UInt32;
begin
  Limit := PackSize; Header := 5+Ord(P.NeedProp); PackSize := 0;
  if Limit < Header then Exit(SZ_ERROR_OUTPUT_EOF);
  Encoded := Limit-Header; Unpacked := KeepWindow;
  LzmaEnc_SaveState(P.Enc);
  Result := LzmaEnc_CodeOneMemBlock(P.Enc,P.NeedState,Buffer+Header,Encoded,65536,Unpacked);
  if Unpacked = 0 then Exit;
  if (Result = SZ_ERROR_OUTPUT_EOF) or
    ((Result = SZ_OK) and ((Encoded+2 >= Unpacked) or (Encoded > 65536))) then
  begin
    DestPos := 0;
    while Unpacked <> 0 do
    begin
      U := Unpacked; if U > 65536 then U := 65536;
      if Limit-DestPos < SizeT(U)+3 then Exit(SZ_ERROR_OUTPUT_EOF);
      if P.SrcPos = 0 then Buffer[DestPos] := 1 else Buffer[DestPos] := 2;
      Buffer[DestPos+1] := Byte((U-1) shr 8); Buffer[DestPos+2] := Byte((U-1) and $FF);
      Inc(DestPos,3); LzmaSdkMove(Buffer+DestPos,LzmaEnc_GetCurBuf(P.Enc)-Unpacked,U);
      Dec(Unpacked,U); Inc(DestPos,U); Inc(P.SrcPos,U);
      if Output <> nil then
      begin
        Inc(PackSize,DestPos); Result := Write(Output,Buffer,DestPos);
        if Result <> SZ_OK then Exit; DestPos := 0;
      end else PackSize := DestPos;
    end;
    LzmaEnc_RestoreState(P.Enc); Exit(SZ_OK);
  end;
  if Result <> SZ_OK then Exit;
  U := Unpacked-1; Pm := UInt32(Encoded-1);
  if P.SrcPos = 0 then Mode := 3
  else if P.NeedState then Mode := 1+Ord(P.NeedProp) else Mode := 0;
  Buffer[0] := $80 or Byte(Mode shl 5) or Byte((U shr 16) and $1F);
  Buffer[1] := Byte((U shr 8) and $FF); Buffer[2] := Byte(U and $FF);
  Buffer[3] := Byte((Pm shr 8) and $FF); Buffer[4] := Byte(Pm and $FF);
  if P.NeedProp then Buffer[5] := P.PropsByte;
  P.NeedProp := False; P.NeedState := False;
  Inc(P.SrcPos,Unpacked); DestPos := Header+Encoded;
  if Output <> nil then begin Result := Write(Output,Buffer,DestPos); if Result <> SZ_OK then Exit; end;
  PackSize := DestPos;
end;

function EncodeOne(Me: PEncoder; P: PEncoderInt; const Output: ILzmaSeqOutStream;
  OutBuf: PByte; OutSize: PLzmaSizeT; const Input: ILzmaSeqInStream;
  InData: PByte; InSize: SizeT; Finished: Boolean;
  const Progress: ILzmaCompressProgress): SRes;
var UnpackTotal,PackTotal,Expected: UInt64; OutLimit,N,InputSize: SizeT;
  Limited: TLimitedInput; LimitedApi: ILzmaSeqInStream; Props: array[0..4] of Byte;
  Buf: PByte; B: Byte;
begin
  OutLimit := 0; UnpackTotal := 0; PackTotal := 0;
  if OutBuf <> nil then begin OutLimit := OutSize^; OutSize^ := 0; end;
  if P.Enc = nil then
  begin P.PropsSet := False; P.Enc := LzmaEnc_Create(Me.Alloc); if P.Enc = nil then Exit(SZ_ERROR_MEM); end;
  Limited := TLimitedInput.Create; LimitedApi := Limited; Limited.Source := Input;
  if OutBuf = nil then
  begin
    if Me.Temp = nil then Me.Temp := Allocate(Me.Alloc,ChunkCapacity);
    if Me.Temp = nil then Exit(SZ_ERROR_MEM);
  end;
  if not P.PropsSet then
  begin
    Result := LzmaEnc_SetProps(P.Enc,Me.Props.LzmaProps); if Result <> SZ_OK then Exit;
    N := 5; Result := LzmaEnc_WriteProperties(P.Enc,@Props[0],N); if Result <> SZ_OK then Exit;
    P.PropsByte := Props[0]; P.PropsSet := True;
  end;
  try
    repeat
      P.SrcPos := 0; P.NeedState := True; P.NeedProp := True;
      Limited.Limit := Me.Props.BlockSize; Limited.Processed := 0; Limited.Finished := False;
      InputSize := 0;
      if Input <> nil then
      begin
        Expected := High(UInt64);
        if (Me.ExpectedDataSize <> High(UInt64)) and (Me.ExpectedDataSize >= UnpackTotal) then
          Expected := Me.ExpectedDataSize-UnpackTotal;
        if (Me.Props.BlockSize <> High(UInt64)) and (Expected > Me.Props.BlockSize) then Expected := Me.Props.BlockSize;
        LzmaEnc_SetDataSize(P.Enc,Expected);
        Result := LzmaEnc_PrepareForLzma2(P.Enc,LimitedApi,KeepWindow,Me.Alloc,Me.AllocBig);
      end
      else
      begin
        InputSize := InSize-SizeT(UnpackTotal);
        if (Me.Props.BlockSize <> High(UInt64)) and (UInt64(InputSize) > Me.Props.BlockSize) then InputSize := SizeT(Me.Props.BlockSize);
        Result := LzmaEnc_MemPrepare(P.Enc,InData+SizeT(UnpackTotal),InputSize,KeepWindow,Me.Alloc,Me.AllocBig);
      end;
      if Result <> SZ_OK then Exit;
      repeat
        if OutBuf <> nil then begin N := OutLimit-SizeT(PackTotal); Buf := OutBuf+SizeT(PackTotal); end
        else begin N := ChunkCapacity; Buf := Me.Temp; end;
        Result := EncodeSubblock(P,Buf,N,Output); if Result <> SZ_OK then Break;
        Inc(PackTotal,N); if OutBuf <> nil then OutSize^ := SizeT(PackTotal);
        Result := Report(Progress,UnpackTotal+P.SrcPos,PackTotal);
        if (Result <> SZ_OK) or (N = 0) then Break;
      until False;
      LzmaEnc_Finish(P.Enc); Inc(UnpackTotal,P.SrcPos);
      if Result <> SZ_OK then Exit;
      if Input <> nil then Expected := Limited.Processed else Expected := InputSize;
      if P.SrcPos <> Expected then Exit(SZ_ERROR_FAIL);
      if ((Input <> nil) and Limited.Finished) or ((Input = nil) and (UnpackTotal = InSize)) then
      begin
        if Finished then
        begin
          if OutBuf <> nil then
          begin
            N := OutSize^; if N >= OutLimit then Exit(SZ_ERROR_OUTPUT_EOF);
            OutBuf[N] := 0; OutSize^ := N+1;
          end
          else begin B := 0; Result := Write(Output,@B,1); end;
        end;
        Exit;
      end;
    until False;
  finally LzmaEnc_Finish(P.Enc); end;
end;

{$IFNDEF Z7_ST}
type
  TBatchProgress = class(TInterfacedObject)
    Lock: TRTLCriticalSection;
    Callback: ILzmaCompressProgress;
    InBase,OutBase: UInt64;
    Inputs,Outputs: array[0..CoderCount-1] of UInt64;
    Failed: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Update(Index: Integer; InSize,OutSize: UInt64): SRes;
  end;
  TWorkerProgress = class(TInterfacedObject,ILzmaCompressProgress)
    Batch: TBatchProgress; Index: Integer;
    function Progress(const InSize,OutSize: UInt64): SRes;
  end;
  TWork = record
    Me: PEncoder; Index: Integer; Input,Encoded: PByte;
    InputSize,OutputSize: SizeT; Finished,OwnInput: Boolean;
    Callback: ILzmaCompressProgress; Thread: CThread; Code: SRes;
  end;
  PWork = ^TWork;
constructor TBatchProgress.Create;
begin inherited; InitializeCriticalSection(Lock); end;
destructor TBatchProgress.Destroy;
begin DeleteCriticalSection(Lock); inherited; end;
function TBatchProgress.Update(Index: Integer; InSize,OutSize: UInt64): SRes;
var I: Integer; InputTotal,OutputTotal: UInt64;
begin
  EnterCriticalSection(Lock);
  try
    if Failed then Exit(SZ_ERROR_PROGRESS);
    Inputs[Index] := InSize; Outputs[Index] := OutSize;
    InputTotal := InBase; OutputTotal := OutBase;
    for I := 0 to CoderCount-1 do begin Inc(InputTotal,Inputs[I]); Inc(OutputTotal,Outputs[I]); end;
    Result := Report(Callback,InputTotal,OutputTotal); Failed := Result <> SZ_OK;
  finally LeaveCriticalSection(Lock); end;
end;
function TWorkerProgress.Progress(const InSize,OutSize: UInt64): SRes;
begin Result := Batch.Update(Index,InSize,OutSize); end;
function Worker(Param: Pointer): Integer;
var W: PWork;
begin
  W := Param;
  try W.Code := EncodeOne(W.Me,@W.Me.Coders[W.Index],nil,W.Encoded,@W.OutputSize,
    nil,W.Input,W.InputSize,W.Finished,W.Callback);
  except
    on E: EOutOfMemory do W.Code := SZ_ERROR_MEM;
    on E: Exception do W.Code := SZ_ERROR_FAIL;
  end;
  Result := 0;
end;
function EncodeMt(Me: PEncoder; const Output: ILzmaSeqOutStream; OutBuf: PByte;
  OutSize: PLzmaSizeT; const Input: ILzmaSeqInStream; InData: PByte;
  InSize: SizeT; const Progress: ILzmaCompressProgress): SRes;
var Work: array[0..CoderCount-1] of TWork; Batch: TBatchProgress; BatchLife: IInterface;
  Callback: TWorkerProgress; Count,I,J,Threads: Integer; BlockSize,DestBlockSize,N,Got,
  InputPos,OutputPos,OutLimit: SizeT; Eof: Boolean; Group: CThreadNextGroup; Wr: WRes;
  ReadResult: SRes;
begin
  if (Me.Props.BlockSize > High(SizeT)) or (Me.Props.BlockSize = 0) then Exit(SZ_ERROR_PARAM);
  BlockSize := SizeT(Me.Props.BlockSize);
  if BlockSize > High(SizeT)-(BlockSize shr 10)-16 then Exit(SZ_ERROR_PARAM);
  DestBlockSize := BlockSize+(BlockSize shr 10)+16;
  Threads := Me.Props.NumBlockThreadsMax;
  if Threads < 1 then Threads := 1;
  if Threads > CoderCount then Threads := CoderCount;
  InputPos := 0; OutputPos := 0; OutLimit := 0; Eof := False;
  if Output = nil then begin OutLimit := OutSize^; OutSize^ := 0; end;
  ThreadNextGroup_Init(Group,Me.Props.NumThreadGroups,0);
  repeat
    for I := 0 to CoderCount-1 do Work[I] := Default(TWork);
    Batch := TBatchProgress.Create; BatchLife := Batch; Batch.Callback := Progress;
    Batch.InBase := InputPos; Batch.OutBase := OutputPos; Count := 0; Result := SZ_OK;
    try
      for I := 0 to Threads-1 do
      begin
        Work[I].Me := Me; Work[I].Index := I; Work[I].OutputSize := DestBlockSize;
        Work[I].Encoded := Allocate(Me.Alloc,DestBlockSize);
        if Work[I].Encoded = nil then begin Result := SZ_ERROR_MEM; Break; end;
        if Input <> nil then
        begin
          Work[I].Input := Allocate(Me.AllocBig,BlockSize); Work[I].OwnInput := True;
          if Work[I].Input = nil then begin Result := SZ_ERROR_MEM; Break; end;
          N := 0; ReadResult := SZ_OK;
          while N < BlockSize do
          begin
            Got := 0;
            try ReadResult := Input.Read((Work[I].Input+N)^,BlockSize-N,Got);
            except on E: Exception do ReadResult := SZ_ERROR_READ; end;
            if Got > BlockSize-N then begin ReadResult := SZ_ERROR_READ; Got := 0; end;
            Inc(N,Got);
            if ReadResult <> SZ_OK then begin Result := ReadResult; Break; end;
            if Got = 0 then begin Eof := True; Break; end;
          end;
          if Result <> SZ_OK then Break;
        end
        else
        begin
          N := InSize-InputPos; if N > BlockSize then N := BlockSize;
          Work[I].Input := InData+InputPos; Eof := N = InSize-InputPos;
        end;
        Work[I].InputSize := N; Work[I].Finished := Eof; Inc(InputPos,N);
        Callback := TWorkerProgress.Create; Callback.Batch := Batch; Callback.Index := I;
        Work[I].Callback := Callback;
        if Me.Props.NumThreadGroups <> 0 then Wr := Thread_Create_With_Group(Work[I].Thread,Worker,@Work[I],ThreadNextGroup_GetNext(Group),0)
        else Wr := Thread_Create(Work[I].Thread,Worker,@Work[I]);
        if Wr <> 0 then begin Result := SZ_ERROR_THREAD; Break; end;
        Inc(Count); if Eof then Break;
      end;
      // Every started worker reaches terminal state before buffers/callbacks die.
      for I := 0 to Count-1 do
      begin
        Wr := Thread_Wait_Close(Work[I].Thread);
        if (Wr <> 0) and (Result = SZ_OK) then Result := SZ_ERROR_THREAD;
        if (Work[I].Code <> SZ_OK) and (Result = SZ_OK) then Result := Work[I].Code;
        if Result <> SZ_OK then Continue;
        N := Work[I].OutputSize;
        if Output <> nil then Result := Write(Output,Work[I].Encoded,N)
        else if N > OutLimit-OutputPos then Result := SZ_ERROR_OUTPUT_EOF
        else LzmaSdkMove(OutBuf+OutputPos,Work[I].Encoded,N);
        if Result = SZ_OK then begin Inc(OutputPos,N); if Output = nil then OutSize^ := OutputPos; end;
      end;
    finally
      for J := 0 to CoderCount-1 do
      begin
        if Work[J].Thread <> 0 then Thread_Wait_Close(Work[J].Thread);
        Work[J].Callback := nil; Release(Me.Alloc,Work[J].Encoded);
        if Work[J].OwnInput then Release(Me.AllocBig,Work[J].Input);
      end;
      BatchLife := nil;
    end;
    if (Result <> SZ_OK) or Eof then Exit;
  until False;
end;
{$ENDIF}

function Lzma2Enc_Encode2(Handle: CLzma2EncHandle;
  const OutStream: ILzmaSeqOutStream; OutBuf: PByte; OutBufSize: PLzmaSizeT;
  const InStream: ILzmaSeqInStream; InData: PByte; InDataSize: SizeT;
  const Progress: ILzmaCompressProgress): SRes;
var Me: PEncoder; I: Integer;
begin
  if ((InStream <> nil) and (InData <> nil)) or ((OutStream <> nil) and (OutBuf <> nil)) then Exit(SZ_ERROR_PARAM);
  if (OutStream = nil) and ((OutBuf = nil) or (OutBufSize = nil)) then Exit(SZ_ERROR_PARAM);
  Me := Handle;
  for I := 0 to CoderCount-1 do Me.Coders[I].PropsSet := False;
{$IFNDEF Z7_ST}
  if Me.Props.NumBlockThreadsReduced > 1 then
    Exit(EncodeMt(Me,OutStream,OutBuf,OutBufSize,InStream,InData,InDataSize,Progress));
{$ENDIF}
  Result := EncodeOne(Me,@Me.Coders[0],OutStream,OutBuf,OutBufSize,InStream,InData,InDataSize,True,Progress);
end;
end.
