program Lzma2GuiPreviewQA;

uses System.SysUtils, System.Math, Vcl.Forms, Vcl.Controls, Lzma2GUIMain;

{$R Lzma2GUIManifest.res}

var Dpi: Integer;
begin
  if ParamCount<>1 then Halt(2);
  Dpi:=StrToInt(ParamStr(1));
  if (Dpi<96) or (Dpi>192) then Halt(3);
  Application.Initialize;
  Application.Title:='LZMA2';
  Application.MainFormOnTaskbar:=True;
  Application.CreateForm(TMainForm,MainForm);
  MainForm.Show;
  MainForm.ScaleForPPI(Dpi);
  MainForm.Width:=Min(MainForm.Width,MainForm.Monitor.WorkareaRect.Width);
  MainForm.Height:=Min(MainForm.Height,MainForm.Monitor.WorkareaRect.Height);
  MainForm.Position:=poDesigned;
  MainForm.Left:=MainForm.Monitor.WorkareaRect.Left+(MainForm.Monitor.WorkareaRect.Width-MainForm.Width) div 2;
  MainForm.Top:=MainForm.Monitor.WorkareaRect.Top+(MainForm.Monitor.WorkareaRect.Height-MainForm.Height) div 2;
  Application.Run;
end.
