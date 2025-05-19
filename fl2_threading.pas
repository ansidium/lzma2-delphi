unit FL2Threading;

interface

const
  FL2_MAXTHREADS = 200;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation

uses
  System.Classes;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  if nbThreads = 0 then
    nbThreads := TThread.ProcessorCount;
  if nbThreads = 0 then
    nbThreads := 1;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;

end.
