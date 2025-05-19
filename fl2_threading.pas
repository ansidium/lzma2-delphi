unit FL2Threading;

interface

uses
  System.Classes, System.SysUtils;

function FL2_countPhysicalCores: Cardinal;
function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation

function FL2_countPhysicalCores: Cardinal;
begin
  {$IFDEF MSWINDOWS}
  Result := TThread.ProcessorCount;
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
  if nbThreads > 64 then
    nbThreads := 64;
  Result := nbThreads;
end;

end.
