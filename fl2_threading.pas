unit FL2Threading;

interface

const
  FL2_MAXTHREADS = 256;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
function FL2_processorCount: Cardinal;

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
end;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;
begin
  if nbThreads = 0 then
    nbThreads := FL2_processorCount;
  if nbThreads = 0 then
    nbThreads := 1;
  if nbThreads > FL2_MAXTHREADS then
    nbThreads := FL2_MAXTHREADS;
  Result := nbThreads;
end;

end.
