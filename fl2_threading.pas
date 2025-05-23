unit FL2Threading;

interface

function FL2_countPhysicalCores: Integer;
function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

const
  FL2_MAXTHREADS = 200;

implementation

uses
  System.Classes, System.SysUtils;

function FL2_countPhysicalCores: Integer;
begin
  Result := TThread.ProcessorCount;
  if Result <= 0 then

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
