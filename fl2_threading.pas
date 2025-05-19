unit FL2Threading;

interface

uses
  System.Classes;

const
  // Максимальное количество потоков по умолчанию
  FL2_MAXTHREADS = 200;

// ----------------------------------------------------------------------------
// Returns the number of physical cores (or logical processors under FPC)
// ----------------------------------------------------------------------------
function FL2_countPhysicalCores: Cardinal;

// ----------------------------------------------------------------------------
// Returns the active processor count (Windows groups aware)
// ----------------------------------------------------------------------------
function FL2_processorCount: Cardinal;

// ----------------------------------------------------------------------------
// Validates and clamps requested thread count:
//  - if 0, uses processorCount
//  - max FL2_MAXTHREADS
//  - min 1
// ----------------------------------------------------------------------------
function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation

uses
  {$IFDEF MSWINDOWS}
  Winapi.Windows,
  {$ENDIF}
  System.Classes;

function FL2_countPhysicalCores: Cardinal;
begin
  {$IFDEF FPC}
  Result := System.CPUCount;
  {$ELSE}
  Result := TThread.ProcessorCount;
  {$ENDIF}
  if Result = 0 then
    Result := 1;
end;

function FL2_processorCount: Cardinal;
begin
  {$IFDEF MSWINDOWS}
  // Get count across all processor groups
  Result := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  {$ELSE}
  Result := TThread.ProcessorCount;
  {$ENDIF}
  if Result = 0 then
    Result := FL2_countPhysicalCores;
end;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  if nbThreads = 0 then
    nbThreads := FL2_processorCount;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  if nbThreads = 0 then
    nbThreads := 1;
  Result := nbThreads;
end;

end.
