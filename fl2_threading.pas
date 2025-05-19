unit FL2Threading;

interface

uses
  System.Classes;

const
  // Максимальное количество потоков по умолчанию
  FL2_MAXTHREADS = 200;

// Возвращает число физических ядер (или логических процессоров для FPC)
function FL2_countPhysicalCores: Cardinal;
// Возвращает активное число процессоров в системе (для Windows с группами)
function FL2_processorCount: Cardinal;
// Проверяет и корректирует число потоков: не больше FL2_MAXTHREADS, минимум 1
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
  // Получаем число активных процессоров во всех группах
  Result := GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  {$ELSE}
  Result := TThread.ProcessorCount;
  {$ENDIF}
  if Result = 0 then
    // Падать обратно на физические ядра
    Result := FL2_countPhysicalCores;
end;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  // Если передано 0 — берём оптимальное число
  if nbThreads = 0 then
    nbThreads := FL2_processorCount;
  // Ограничиваем максимумом
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  // Гарантируем минимум
  if nbThreads = 0 then
    nbThreads := 1;
  Result := nbThreads;
end;

end.
