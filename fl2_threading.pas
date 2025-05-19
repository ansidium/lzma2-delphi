unit FL2Threading;

interface

uses
  Classes, SysUtils;

function FL2_checkNbThreads(nbThreads: Cardinal): Cardinal;

implementation

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
