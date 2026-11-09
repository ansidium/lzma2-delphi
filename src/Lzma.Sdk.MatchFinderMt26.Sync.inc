procedure MtSync_Construct(var P: CMtSync);
begin
  P.AffinityGroup := -1; P.AffinityInGroup := 0; P.Affinity := 0;
  P.WasCreated := 0; P.CsWasInitialized := 0; P.CsWasEntered := 0;
  P.Thread := 0; P.CanStart := 0; P.WasStopped := 0;
  P.FreeSemaphore := 0; P.FilledSemaphore := 0;
end;
procedure MtSync_Lock(var P: CMtSync); inline;
begin EnterCriticalSection(P.Cs); P.CsWasEntered := 1; end;
procedure MtSync_Unlock(var P: CMtSync); inline;
begin LeaveCriticalSection(P.Cs); P.CsWasEntered := 0; end;
function MtSync_GetNextBlock(var P: CMtSync): UInt32;
begin
  Result := 0;
  if P.NeedStart <> 0 then
  begin
    P.NumProcessedBlocks := 1; P.NeedStart := 0; P.StopWriting := 0; P.ExitRequested := 0;
    Event_Reset(P.WasStopped); Event_Set(P.CanStart);
  end
  else
  begin
    MtSync_Unlock(P); Result := P.NumProcessedBlocks; Inc(P.NumProcessedBlocks);
    Semaphore_Release1(P.FreeSemaphore);
  end;
  Handle_WaitObject(P.FilledSemaphore); MtSync_Lock(P);
end;
procedure MtSync_StopWriting(var P: CMtSync);
begin
  if (P.Thread = 0) or (P.NeedStart <> 0) then Exit;
  if P.CsWasEntered <> 0 then MtSync_Unlock(P);
  P.StopWriting := 1; Semaphore_Release1(P.FreeSemaphore); Handle_WaitObject(P.WasStopped);
  P.NeedStart := 1;
end;
procedure MtSync_Destruct(var P: CMtSync);
begin
  if P.Thread <> 0 then
  begin
    MtSync_StopWriting(P); P.ExitRequested := 1; Event_Set(P.CanStart); Thread_Wait_Close(P.Thread);
  end;
  if P.CsWasInitialized <> 0 then begin DeleteCriticalSection(P.Cs); P.CsWasInitialized := 0; end;
  P.CsWasEntered := 0;
  HandlePtr_Close(P.CanStart); HandlePtr_Close(P.WasStopped);
  HandlePtr_Close(P.FreeSemaphore); HandlePtr_Close(P.FilledSemaphore); P.WasCreated := 0;
end;
function MtSync_Init(var P: CMtSync; NumBlocks: UInt32): SRes;
var W: WRes;
begin
  if (P.NeedStart = 0) or (P.CsWasEntered <> 0) then Exit(SZ_ERROR_FAIL);
{$IFDEF LZMA_SDK_ENCODER_MT_QA}
  W := QaSemaphoreInit(P.FreeSemaphore,NumBlocks,NumBlocks);
  if W = 0 then W := QaSemaphoreInit(P.FilledSemaphore,0,NumBlocks);
{$ELSE}
  W := Semaphore_OptCreateInit(P.FreeSemaphore,NumBlocks,NumBlocks);
  if W = 0 then W := Semaphore_OptCreateInit(P.FilledSemaphore,0,NumBlocks);
{$ENDIF}
  Result := SResFromWRes(W);
end;
function MtSync_CreateWRes(var P: CMtSync; Start: TSdkThreadFunc; Obj: Pointer): WRes;
begin
  if P.WasCreated <> 0 then Exit(0);
{$IFDEF LZMA_SDK_ENCODER_MT_QA}
  Result := QaThreadCall;
  if Result = 0 then
{$ENDIF}
  Result := CriticalSection_Init(P.Cs); if Result <> 0 then Exit;
  P.CsWasInitialized := 1; P.CsWasEntered := 0;
{$IFDEF LZMA_SDK_ENCODER_MT_QA}
  Result := QaThreadCall;
  if Result = 0 then
{$ENDIF}
  Result := AutoResetEvent_CreateNotSignaled(P.CanStart); if Result <> 0 then Exit;
{$IFDEF LZMA_SDK_ENCODER_MT_QA}
  Result := QaThreadCall;
  if Result = 0 then
{$ENDIF}
  Result := AutoResetEvent_CreateNotSignaled(P.WasStopped); if Result <> 0 then Exit;
  P.NeedStart := 1; P.ExitRequested := 1;
{$IFDEF LZMA_SDK_ENCODER_MT_QA}
  Result := QaThreadCall; if Result <> 0 then Exit;
{$ENDIF}
  if P.AffinityGroup >= 0 then Result := Thread_Create_With_Group(P.Thread,Start,Obj,
    UInt32(P.AffinityGroup),NativeUInt(P.AffinityInGroup))
  else if P.Affinity <> 0 then Result := Thread_Create_With_Affinity(P.Thread,Start,Obj,NativeUInt(P.Affinity))
  else Result := Thread_Create(P.Thread,Start,Obj);
  if Result <> 0 then Exit;
  P.WasCreated := 1;
end;
function MtSync_Create(var P: CMtSync; Start: TSdkThreadFunc; Obj: Pointer): SRes;
var W: WRes;
begin
  W := MtSync_CreateWRes(P,Start,Obj); if W = 0 then Exit(SZ_OK);
  MtSync_Destruct(P); Result := SResFromWRes(W);
end;
