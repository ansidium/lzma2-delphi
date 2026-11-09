unit Lzma.Sdk.Threads26;

// Native Windows part of SDK 26.05 C/Threads.c (Igor Pavlov, public domain).
// Windows/RTL thread primitives for the native SDK MT codecs.
// Delphi worker callbacks use System.TThreadFunc and RTL BeginThread so the
// Pascal runtime initializes and finalizes thread-local state correctly.
interface

uses Winapi.Windows, Lzma.Types;

type
  WRes = UInt32;
  CThread = THandle;
  CEvent = THandle;
  CAutoResetEvent = CEvent;
  CManualResetEvent = CEvent;
  CSemaphore = THandle;
  CCriticalSection = TRTLCriticalSection;
  CAffinityMask = NativeUInt;
  TSdkThreadFunc = System.TThreadFunc;
  CThreadNextGroup = record
    NumGroups, NextGroup: UInt32;
  end;

function SResFromWRes(Value: WRes): SRes;
function HandlePtr_Close(var Handle: THandle): WRes;
function Handle_WaitObject(Handle: THandle): WRes;
function Thread_Create(var Thread: CThread; Func: TSdkThreadFunc; Param: Pointer): WRes;
function Thread_Create_With_Affinity(var Thread: CThread; Func: TSdkThreadFunc;
  Param: Pointer; Affinity: CAffinityMask): WRes;
function Thread_Create_With_Group(var Thread: CThread; Func: TSdkThreadFunc;
  Param: Pointer; Group: UInt32; Affinity: CAffinityMask): WRes;
function Thread_Wait_Close(var Thread: CThread): WRes;
function Event_Set(var Event: CEvent): WRes;
function Event_Reset(var Event: CEvent): WRes;
function ManualResetEvent_Create(var Event: CManualResetEvent; Signaled: Int32): WRes;
function AutoResetEvent_Create(var Event: CAutoResetEvent; Signaled: Int32): WRes;
function ManualResetEvent_CreateNotSignaled(var Event: CManualResetEvent): WRes;
function AutoResetEvent_CreateNotSignaled(var Event: CAutoResetEvent): WRes;
function AutoResetEvent_OptCreate_And_Reset(var Event: CAutoResetEvent): WRes;
function Semaphore_Create(var Semaphore: CSemaphore; InitCount, MaxCount: UInt32): WRes;
function Semaphore_OptCreateInit(var Semaphore: CSemaphore; InitCount, MaxCount: UInt32): WRes;
function Semaphore_ReleaseN(var Semaphore: CSemaphore; Num: UInt32): WRes;
function Semaphore_Release1(var Semaphore: CSemaphore): WRes;
function CriticalSection_Init(var Section: CCriticalSection): WRes;
procedure ThreadNextGroup_Init(var Group: CThreadNextGroup; NumGroups, StartGroup: UInt32);
function ThreadNextGroup_GetNext(var Group: CThreadNextGroup): UInt32;

implementation

uses System.SysUtils;

// WRes/HRESULT conversions and LONG argument casts preserve C's bit patterns.
{$Q-}
{$R-}
{$B-}

const
  StackReserveSize = UInt32(1) shl 20;
  StackReserveFlag = UInt32($10000);

type
  TSdkGroupAffinity = record
    Mask: NativeUInt;
    Group: Word;
    Reserved: array[0..2] of Word;
  end;
  PGroupAffinity = ^TSdkGroupAffinity;
  TSetThreadGroupAffinity = function(Thread: THandle;
    Group, PreviousGroup: PGroupAffinity): BOOL; stdcall;

function LastErrorNonZero: WRes;
begin
  Result := Winapi.Windows.GetLastError;
  if Result = 0 then Result := 1;
end;

function BoolToWRes(Value: BOOL): WRes;
begin
  if Value then Result := 0 else Result := LastErrorNonZero;
end;

function SResFromWRes(Value: WRes): SRes;
begin
  Result := Int32(Value);
  if Result > 0 then Result := Int32((Value and $FFFF) or $80070000);
end;

function HandlePtr_Close(var Handle: THandle): WRes;
begin
  if Handle <> 0 then
  begin
    if not Winapi.Windows.CloseHandle(Handle) then Exit(LastErrorNonZero);
    Handle := 0;
  end;
  Result := 0;
end;

function Handle_WaitObject(Handle: THandle): WRes;
begin
  Result := Winapi.Windows.WaitForSingleObject(Handle, INFINITE);
  if Result = WAIT_FAILED then
  begin
    Result := Winapi.Windows.GetLastError;
    if Result = 0 then Result := WAIT_FAILED;
  end;
end;

function CreateWorker(var Thread: CThread; Func: TSdkThreadFunc;
  Param: Pointer; Flags: UInt32): WRes;
var Id: TThreadID;
begin
  try
    Thread := System.BeginThread(nil, StackReserveSize, Func, Param,
      Flags or StackReserveFlag, Id);
  except
    on E: EOutOfMemory do
    begin
      Thread := 0;
      Winapi.Windows.SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    end;
  end;
  if Thread <> 0 then Result := 0 else Result := LastErrorNonZero;
end;

function Thread_Create(var Thread: CThread; Func: TSdkThreadFunc; Param: Pointer): WRes;
begin Result := CreateWorker(Thread, Func, Param, 0); end;

function Thread_Create_With_Affinity(var Thread: CThread; Func: TSdkThreadFunc;
  Param: Pointer; Affinity: CAffinityMask): WRes;
begin
  Result := CreateWorker(Thread, Func, Param, CREATE_SUSPENDED);
  if Thread <> 0 then
  begin
    // SDK treats an affinity assignment failure as non-critical.
    Winapi.Windows.SetThreadAffinityMask(Thread, Affinity);
    if Winapi.Windows.ResumeThread(Thread) = DWORD($FFFFFFFF) then Result := LastErrorNonZero;
  end;
end;

function Thread_Create_With_Group(var Thread: CThread; Func: TSdkThreadFunc;
  Param: Pointer; Group: UInt32; Affinity: CAffinityMask): WRes;
var Fn: TSetThreadGroupAffinity; Current, Previous: TSdkGroupAffinity;
begin
  Result := CreateWorker(Thread, Func, Param, CREATE_SUSPENDED);
  if Thread <> 0 then
  begin
    Fn := TSetThreadGroupAffinity(Winapi.Windows.GetProcAddress(
      Winapi.Windows.GetModuleHandle('kernel32.dll'), 'SetThreadGroupAffinity'));
    if Assigned(Fn) then
    begin
      FillChar(Current, SizeOf(Current), 0);
      Current.Mask := Affinity; Current.Group := Word(Group and $FFFF);
      // Preserve the original non-critical affinity/group failure contract.
      Fn(Thread, @Current, @Previous);
    end;
    if Winapi.Windows.ResumeThread(Thread) = DWORD($FFFFFFFF) then Result := LastErrorNonZero;
  end;
end;

function Thread_Wait_Close(var Thread: CThread): WRes;
var CloseResult: WRes;
begin
  Result := Handle_WaitObject(Thread); CloseResult := HandlePtr_Close(Thread);
  if Result = 0 then Result := CloseResult;
end;

function CreateEventHandle(var Event: CEvent; Manual: BOOL; Signaled: Int32): WRes;
begin
  Event := Winapi.Windows.CreateEvent(nil, Manual, Signaled <> 0, nil);
  if Event <> 0 then Result := 0 else Result := LastErrorNonZero;
end;
function Event_Set(var Event: CEvent): WRes;
begin Result := BoolToWRes(Winapi.Windows.SetEvent(Event)); end;
function Event_Reset(var Event: CEvent): WRes;
begin Result := BoolToWRes(Winapi.Windows.ResetEvent(Event)); end;
function ManualResetEvent_Create(var Event: CManualResetEvent; Signaled: Int32): WRes;
begin Result := CreateEventHandle(Event, True, Signaled); end;
function AutoResetEvent_Create(var Event: CAutoResetEvent; Signaled: Int32): WRes;
begin Result := CreateEventHandle(Event, False, Signaled); end;
function ManualResetEvent_CreateNotSignaled(var Event: CManualResetEvent): WRes;
begin Result := ManualResetEvent_Create(Event, 0); end;
function AutoResetEvent_CreateNotSignaled(var Event: CAutoResetEvent): WRes;
begin Result := AutoResetEvent_Create(Event, 0); end;
function AutoResetEvent_OptCreate_And_Reset(var Event: CAutoResetEvent): WRes;
begin
  if Event <> 0 then Result := Event_Reset(Event)
  else Result := AutoResetEvent_CreateNotSignaled(Event);
end;

function Semaphore_Create(var Semaphore: CSemaphore; InitCount, MaxCount: UInt32): WRes;
begin
  Semaphore := Winapi.Windows.CreateSemaphore(nil, Int32(InitCount), Int32(MaxCount), nil);
  if Semaphore <> 0 then Result := 0 else Result := LastErrorNonZero;
end;
function Semaphore_OptCreateInit(var Semaphore: CSemaphore; InitCount, MaxCount: UInt32): WRes;
begin
  Result := HandlePtr_Close(Semaphore);
  if Result = 0 then Result := Semaphore_Create(Semaphore, InitCount, MaxCount);
end;
function Semaphore_ReleaseN(var Semaphore: CSemaphore; Num: UInt32): WRes;
begin Result := BoolToWRes(Winapi.Windows.ReleaseSemaphore(Semaphore, Int32(Num), nil)); end;
function Semaphore_Release1(var Semaphore: CSemaphore): WRes;
begin Result := Semaphore_ReleaseN(Semaphore, 1); end;
function CriticalSection_Init(var Section: CCriticalSection): WRes;
begin
  try
    Winapi.Windows.InitializeCriticalSection(Section); Result := 0;
  except
    Result := ERROR_NOT_ENOUGH_MEMORY;
  end;
end;

procedure ThreadNextGroup_Init(var Group: CThreadNextGroup; NumGroups, StartGroup: UInt32);
begin
  if NumGroups = 0 then NumGroups := 1;
  Group.NumGroups := NumGroups; Group.NextGroup := StartGroup mod NumGroups;
end;
function ThreadNextGroup_GetNext(var Group: CThreadNextGroup): UInt32;
begin
  Result := Group.NextGroup; Group.NextGroup := (Result + 1) mod Group.NumGroups;
end;

end.
