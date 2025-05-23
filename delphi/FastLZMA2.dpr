program FastLZMA2;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  FL2Common,
  FL2Pool,
  FL2Threading,
  FL2API;

begin
  try
    Writeln('FastLZMA2 version: ', string(FL2_versionString));
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
