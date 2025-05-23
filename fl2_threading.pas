unit FL2Threading;

interface

uses
  System.Classes;

const
  FL2_MAXTHREADS = 200;

function FL2_countPhysicalCores: Cardinal;
function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation
function FL2_countPhysicalCores: Cardinal;
begin
  Result := TThread.ProcessorCount;
  if Result = 0 then
    Result := 1;
end;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  if nbThreads = 0 then
    nbThreads := FL2_countPhysicalCores;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;
end.
