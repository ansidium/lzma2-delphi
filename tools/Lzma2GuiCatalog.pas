unit Lzma2GuiCatalog;

interface

uses System.SysUtils;

function GuiText(const Language: Integer; const Key: string): string;
function GuiApplicationValue(const Key: string): string;
function GuiDefaultString(const Key: string): string;
function GuiDefaultInteger(const Key: string): Integer;
function GuiProfileDictionaryMiB(const Level: Integer): Integer;
function GuiLanguageCode(const Language: Integer): string;
function GuiLanguageName(const Language: Integer): string;
function GuiLanguageCount: Integer;
function GuiNumberFormat(const Language: Integer): TFormatSettings;
function GuiByteUnit(const Language, UnitIndex: Integer): string;
function GuiChoices(const Key: string): TArray<Integer>;
function GuiBenchmarkDefault(const Key: string): Integer;

implementation

uses System.Classes, System.JSON, Winapi.Windows;

var Catalog: TJSONObject;

function Data: TJSONObject;
var Stream: TResourceStream; Bytes: TBytes; Parsed: TJSONValue;
begin
  if Catalog=nil then
  begin
    Stream:=TResourceStream.Create(HInstance,'GUI_CATALOG',RT_RCDATA);
    try
      SetLength(Bytes,Stream.Size);
      if Length(Bytes)>0 then Stream.ReadBuffer(Bytes[0],Length(Bytes));
      Parsed:=TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(Bytes));
      if not (Parsed is TJSONObject) then
      begin Parsed.Free;raise EConvertError.Create('Invalid GUI catalog resource');end;
      Catalog:=TJSONObject(Parsed);
      if Catalog.GetValue<Integer>('schema')<>1 then
        raise EConvertError.Create('Unsupported GUI catalog schema');
    finally Stream.Free;end;
  end;
  Result:=Catalog;
end;

function Section(const Name: string): TJSONObject;
begin Result:=Data.GetValue<TJSONObject>(Name);end;

function LanguageData(const Language: Integer): TJSONObject;
var Languages: TJSONArray;
begin
  Languages:=Data.GetValue<TJSONArray>('languages');
  if (Language<0) or (Language>=Languages.Count) then
    raise EArgumentOutOfRangeException.Create('Invalid GUI language index');
  Result:=TJSONObject(Languages.Items[Language]);
end;

function GuiLanguageCount: Integer;
begin Result:=Data.GetValue<TJSONArray>('languages').Count;end;

function GuiLanguageCode(const Language: Integer): string;
begin Result:=LanguageData(Language).GetValue<string>('code');end;

function GuiLanguageName(const Language: Integer): string;
begin Result:=LanguageData(Language).GetValue<string>('name');end;

function GuiNumberFormat(const Language: Integer): TFormatSettings;
begin Result:=TFormatSettings.Create(LanguageData(Language).GetValue<string>('locale'));end;

function GuiByteUnit(const Language, UnitIndex: Integer): string;
begin
  Result:=Data.GetValue<TJSONObject>('units').GetValue<TJSONArray>(GuiLanguageCode(Language)).Items[UnitIndex].Value;
end;

function GuiText(const Language: Integer; const Key: string): string;
var Entry: TJSONObject;
begin
  Entry:=Section('strings').GetValue(Key) as TJSONObject;
  if Entry=nil then raise EConvertError.Create('Unknown GUI text key: '+Key);
  if not Entry.TryGetValue<string>(GuiLanguageCode(Language),Result) or (Result='') then
    raise EConvertError.Create('Missing GUI translation: '+Key+'/'+GuiLanguageCode(Language));
end;

function GuiApplicationValue(const Key: string): string;
begin Result:=Section('application').GetValue<string>(Key);end;

function GuiDefaultString(const Key: string): string;
begin Result:=Section('defaults').GetValue<string>(Key);end;

function GuiDefaultInteger(const Key: string): Integer;
begin Result:=Section('defaults').GetValue<Integer>(Key);end;

function GuiBenchmarkDefault(const Key: string): Integer;
begin Result:=Section('benchmarkDefaults').GetValue<Integer>(Key);end;

function GuiChoices(const Key: string): TArray<Integer>;
var Values: TJSONArray; I: Integer;
begin
  Values:=Section('choices').GetValue<TJSONArray>(Key);
  SetLength(Result,Values.Count);
  for I:=0 to High(Result) do Result[I]:=TJSONNumber(Values.Items[I]).AsInt;
end;

function GuiProfileDictionaryMiB(const Level: Integer): Integer;
var Values: TJSONArray;
begin
  Values:=Section('defaults').GetValue<TJSONArray>('dictionaryByLevelMiB');
  if (Level<0) or (Level>=Values.Count) then
    raise EArgumentOutOfRangeException.Create('Invalid compression level');
  Result:=TJSONNumber(Values.Items[Level]).AsInt;
end;

initialization
  Catalog:=nil;
finalization
  Catalog.Free;
end.
