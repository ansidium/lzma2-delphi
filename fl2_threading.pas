unit FL2Threading;

interface

uses
  System.Classes, System.SysUtils;

const
  // Максимальное количество потоков по умолчанию
  FL2_MAXTHREADS = 200;

// ----------------------------------------------------------------------------
// Возвращает число физических ядер (или логических процессоров под FPC)
// ----------------------------------------------------------------------------
function FL2_countPhysicalCores: Cardinal;

// ----------------------------------------------------------------------------
// Возвращает активное число процессоров в системе (с учётом групп Windows)
// ----------------------------------------------------------------------------
function FL2_processorCount: Cardinal;

// ----------------------------------------------------------------------------
// Проверяет и корректирует число потоков:
//  - если nbThreads = 0, используется processorCount
//  - ограничивается сверху FL2_MAXTHREADS
//  - снижается не ниже 1
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
  if nbThreads < 1 then
    nbThreads := 1;
  Result := nbThreads;
end;

end.
