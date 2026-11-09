program Lzma2GuiLayoutQA;

{$APPTYPE CONSOLE}
{$R Lzma2GUIManifest.res}

uses System.SysUtils, Winapi.Windows, Vcl.Forms, Lzma2GUIMain;

var Form: TMainForm;
begin
  try
    if ParamCount <> 1 then raise Exception.Create('Output file argument required');
    Winapi.Windows.SetEnvironmentVariable('LZMA2_GUI_SETTINGS_PATH',PChar(ExtractFilePath(ParamStr(1))+'layout-preferences.ini'));
    Application.Initialize;
    Form := TMainForm.Create(nil);
    try
      Form.RunLayoutAudit(ParamStr(1));
    finally Form.Free; end;
    Writeln('PASS layout audit');
  except
    on E: Exception do begin Writeln(E.ClassName+': '+E.Message); ExitCode:=1; end;
  end;
end.
