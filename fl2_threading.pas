unit FL2Threading;

interface

const
  FL2_MAXTHREADS = 200;

function FL2_countPhysicalCores: Integer;
function FL2_checkNbThreads(nbThreads: Integer): Integer;

implementation

uses
  System.Classes;

function FL2_countPhysicalCores: Integer;
begin
  Result := TThread.ProcessorCount;
  if Result <= 0 then
    Result := 1;
end;

function FL2_checkNbThreads(nbThreads: Integer): Integer;
begin
  if nbThreads = 0 then
    nbThreads := FL2_countPhysicalCores;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;

end.
