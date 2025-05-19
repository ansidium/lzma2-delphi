unit FL2Threading;

interface

function FL2_countPhysicalCores: Cardinal;
function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation

uses
  Classes;

const
  FL2_MAXTHREADS = 200;

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

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  if nbThreads = 0 then
    nbThreads := FL2_countPhysicalCores;
  if nbThreads = 0 then
    nbThreads := 1;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;

end.
