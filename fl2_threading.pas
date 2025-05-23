unit FL2Threading;

interface

function FL2_countPhysicalCores: Integer;
function FL2_checkNbThreads(nbThreads: Integer): Integer;
implementation

uses
  System.Classes;

const
  FL2_MAXTHREADS = 200;

function FL2_countPhysicalCores: Integer;
begin
  Result := TThread.ProcessorCount;
end;

function FL2_checkNbThreads(nbThreads: Integer): Integer;
begin
  if nbThreads = 0 then
    nbThreads := FL2_countPhysicalCores;
  if nbThreads <= 0 then
    nbThreads := 1;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;

end.
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
  // Учитываем все группы процессоров
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
