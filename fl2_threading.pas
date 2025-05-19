unit FL2Threading;

interface

const

  FL2_MAXTHREADS = 256;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
function FL2_processorCount: Cardinal;
uses
  Classes, SysUtils;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;


implementation

uses
  {$IFDEF MSWINDOWS}Windows{$ENDIF},
  Classes;

function FL2_processorCount: Cardinal;
begin
  {$IFDEF MSWINDOWS}
  Result := Windows.GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  {$ELSE}
  Result := TThread.ProcessorCount;
  {$ENDIF}

  System.Classes;
function UTIL_countPhysicalCores: Integer;
begin
{$IFDEF FPC}
  Result := System.GetCPUCount;
{$ELSE}
  Result := TThread.ProcessorCount;
{$ENDIF}
  if Result <= 0 then
    Result := 1;
end;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  if nbThreads = 0 then

    nbThreads := FL2_processorCount;
    nbThreads := TThread.ProcessorCount;

  if nbThreads = 0 then
    nbThreads := 1;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;

  begin
    nbThreads := UTIL_countPhysicalCores();
    if nbThreads = 0 then
      nbThreads := 1;
  end;
  if nbThreads > 200 then
    nbThreads := 200;
  Result := nbThreads;
end;

end.