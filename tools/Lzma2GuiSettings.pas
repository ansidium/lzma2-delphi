unit Lzma2GuiSettings;

interface

type
  TGuiPackingPreferences = record
    Container, DictionaryMode, Check: string;
    Level, DictionaryMiB, Threads: Integer;
  end;

function GuiSettingsPath: string;
function DefaultPackingPreferences: TGuiPackingPreferences;
function LoadPackingPreferences: TGuiPackingPreferences;
procedure SavePackingPreferences(const Preferences: TGuiPackingPreferences);

implementation

uses System.SysUtils, System.IniFiles, System.IOUtils, Lzma2GuiCatalog;

function GuiSettingsPath: string;
begin
  Result:=GetEnvironmentVariable('LZMA2_GUI_SETTINGS_PATH');
  if Result<>'' then Exit(TPath.GetFullPath(Result));
  Result:=TPath.GetCachePath;
  if Result<>'' then Result:=TPath.Combine(TPath.Combine(Result,'Lzma2GUI'),'gui.ini');
end;

function DefaultPackingPreferences: TGuiPackingPreferences;
begin
  Result.Container:=GuiDefaultString('container');
  Result.Level:=GuiDefaultInteger('level');
  Result.DictionaryMode:=GuiDefaultString('dictionary');
  Result.DictionaryMiB:=GuiDefaultInteger('customDictionaryMiB');
  Result.Threads:=GuiDefaultInteger('threads');
  Result.Check:=GuiDefaultString('xzCheck');
end;

function Valid(const P: TGuiPackingPreferences): Boolean;
var Candidate: Integer;
begin
  Result:=((P.Container='7z') or (P.Container='xz') or (P.Container='lzma') or (P.Container='lzma2')) and
    (P.Level>=0) and (P.Level<=9) and (P.Threads>=0) and
    ((P.DictionaryMode='auto') or (P.DictionaryMode='preset') or (P.DictionaryMode='custom')) and
    (P.DictionaryMiB>=1) and (P.DictionaryMiB<=4095) and
    ((P.Check='none') or (P.Check='CRC32') or (P.Check='CRC64') or (P.Check='SHA256'));
  if Result and (P.DictionaryMode='preset') then
  begin
    Result:=False;
    for Candidate in GuiChoices('dictionaryMiB') do
      if P.DictionaryMiB=Candidate then begin Result:=True;Break;end;
  end;
end;

function LoadPackingPreferences: TGuiPackingPreferences;
var Ini: TMemIniFile; FileName: string; P: TGuiPackingPreferences;
begin
  Result:=DefaultPackingPreferences;
  FileName:=GuiSettingsPath;
  if (FileName='') or not TFile.Exists(FileName) then Exit;
  try
    Ini:=TMemIniFile.Create(FileName,TEncoding.UTF8);
    try
      if Ini.ReadInteger('Packing','Version',0)<>1 then Exit;
      P:=Result;
      P.Container:=Ini.ReadString('Packing','Container',P.Container);
      P.Level:=Ini.ReadInteger('Packing','Level',P.Level);
      P.DictionaryMode:=Ini.ReadString('Packing','DictionaryMode',P.DictionaryMode);
      P.DictionaryMiB:=Ini.ReadInteger('Packing','DictionaryMiB',P.DictionaryMiB);
      P.Threads:=Ini.ReadInteger('Packing','Threads',P.Threads);
      P.Check:=Ini.ReadString('Packing','Check',P.Check);
      if Valid(P) then Result:=P;
    finally Ini.Free;end;
  except
    Result:=DefaultPackingPreferences;
  end;
end;

procedure SavePackingPreferences(const Preferences: TGuiPackingPreferences);
var Ini: TMemIniFile; FileName: string;
begin
  if not Valid(Preferences) then raise EArgumentException.Create('Invalid GUI packing preferences');
  FileName:=GuiSettingsPath;
  if FileName='' then Exit;
  TDirectory.CreateDirectory(ExtractFileDir(FileName));
  Ini:=TMemIniFile.Create(FileName,TEncoding.UTF8);
  try
    Ini.WriteInteger('Packing','Version',1);
    Ini.WriteString('Packing','Container',Preferences.Container);
    Ini.WriteInteger('Packing','Level',Preferences.Level);
    Ini.WriteString('Packing','DictionaryMode',Preferences.DictionaryMode);
    Ini.WriteInteger('Packing','DictionaryMiB',Preferences.DictionaryMiB);
    Ini.WriteInteger('Packing','Threads',Preferences.Threads);
    Ini.WriteString('Packing','Check',Preferences.Check);
    Ini.UpdateFile;
  finally Ini.Free;end;
end;

end.
