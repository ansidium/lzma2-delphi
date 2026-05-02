unit Lzma.CliPaths;

interface

uses
  System.SysUtils,
  System.IOUtils,
  Lzma.Types;

function DefaultExtractPath(const ArchivePath: string; const Container: TLzma2Container): string;
function SafeStoredOutputName(const StoredName, FallbackPath: string): string;
function SafeStoredRelativePath(const StoredName, FallbackPath: string; const PreservePaths: Boolean): string;

implementation

function DefaultExtractPath(const ArchivePath: string; const Container: TLzma2Container): string;
begin
  Result := ChangeFileExt(ArchivePath, '');
  if SameText(Result, ArchivePath) or (Result = '') then
    Result := ArchivePath + '.out';
end;

function TrimWindowsFileNameTail(const Value: string): string;
begin
  Result := Value;
  while (Result <> '') and CharInSet(Result[Length(Result)], [' ', '.']) do
    Delete(Result, Length(Result), 1);
end;

function IsReservedWindowsFileName(const Value: string): Boolean;
var
  Base: string;
  DotPos: Integer;
begin
  Base := UpperCase(TrimWindowsFileNameTail(Value));
  DotPos := Pos('.', Base);
  if DotPos > 0 then
    Base := Copy(Base, 1, DotPos - 1);

  Result :=
    (Base = 'CON') or (Base = 'PRN') or (Base = 'AUX') or (Base = 'NUL') or
    ((Length(Base) = 4) and ((Copy(Base, 1, 3) = 'COM') or (Copy(Base, 1, 3) = 'LPT')) and
      CharInSet(Base[4], ['1'..'9']));
end;

function HasInvalidWindowsFileNameChar(const Value: string): Boolean;
var
  Ch: Char;
begin
  for Ch in Value do
    if (Ord(Ch) < 32) or CharInSet(Ch, ['<', '>', ':', '"', '/', '\', '|', '?', '*']) then
      Exit(True);
  Result := False;
end;

function NormalizeSafeOutputName(const Value: string): string;
begin
  Result := TrimWindowsFileNameTail(Value);
  if (Result = '') or (Result = '.') or (Result = '..') then
    Exit('');
  if HasInvalidWindowsFileNameChar(Result) or IsReservedWindowsFileName(Result) then
    Exit('');
end;

function SafeStoredOutputName(const StoredName, FallbackPath: string): string;
begin
  Result := NormalizeSafeOutputName(ExtractFileName(StringReplace(StoredName, '/', '\', [rfReplaceAll])));
  if Result = '' then
    Result := NormalizeSafeOutputName(ExtractFileName(FallbackPath));
  if Result = '' then
    Result := 'output.bin';
end;

function SafeStoredRelativePath(const StoredName, FallbackPath: string; const PreservePaths: Boolean): string;
var
  Normalized: string;
  Parts: TArray<string>;
  Part: string;
  SafePart: string;
begin
  if not PreservePaths then
    Exit(SafeStoredOutputName(StoredName, FallbackPath));

  Normalized := StringReplace(StoredName, '/', '\', [rfReplaceAll]);
  if (Normalized = '') or (ExtractFileDrive(Normalized) <> '') or
    (Copy(Normalized, 1, 1) = '\') then
    Exit(SafeStoredOutputName('', FallbackPath));

  Parts := Normalized.Split(['\'], TStringSplitOptions.ExcludeEmpty);
  Result := '';
  for Part in Parts do
  begin
    SafePart := NormalizeSafeOutputName(Part);
    if SafePart = '' then
      Exit(SafeStoredOutputName('', FallbackPath));
    if Result = '' then
      Result := SafePart
    else
      Result := TPath.Combine(Result, SafePart);
  end;

  if Result = '' then
    Result := SafeStoredOutputName('', FallbackPath);
end;

end.
