program Lzma2_GUI;

uses
  System.SysUtils,
  Vcl.Forms,
  Vcl.Themes,
  Vcl.Styles,
  Lzma2GUIMain in 'Lzma2GUIMain.pas';

{$R Lzma2GUIManifest.res}

const
  PreferredStyleName = 'Windows11 Polar Dark';

function StyleIsAvailable(const StyleName: string): Boolean;
var
  RegisteredStyle: string;
begin
  Result := False;
  for RegisteredStyle in TStyleManager.StyleNames do
    if SameText(RegisteredStyle, StyleName) then
      Exit(True);
end;

function ApplyStyleIfAvailable(const StyleName: string): Boolean;
begin
  Result := False;
  if not StyleIsAvailable(StyleName) then
    Exit;
  try
    Result := TStyleManager.TrySetStyle(StyleName);
  except
    Result := False;
  end;
end;

procedure ApplyPreferredStyle;
begin
  if ApplyStyleIfAvailable(PreferredStyleName) then
    Exit;
  if ApplyStyleIfAvailable('Windows Modern Dark SE') then
    Exit;
  if ApplyStyleIfAvailable('Windows Modern Dark') then
    Exit;
  ApplyStyleIfAvailable('Windows');
end;

begin
  Application.Title := 'LZMA2 GUI';
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  ApplyPreferredStyle;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
