unit Lzma.Test.Process;

interface

uses
  System.SysUtils;

type
  EExternalProcessError = class(Exception);

procedure RunExternalProcessChecked(const ExePath: string; const Args: array of string; const WorkingDir: string;
  const TimeoutMs: Cardinal = 60000);

implementation

uses
  Winapi.Windows;

function QuoteArg(const Value: string): string;
begin
  Result := '"' + StringReplace(Value, '"', '\"', [rfReplaceAll]) + '"';
end;

procedure RunExternalProcessChecked(const ExePath: string; const Args: array of string; const WorkingDir: string;
  const TimeoutMs: Cardinal);
var
  CommandLine: string;
  Arg: string;
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  WaitResult: DWORD;
  ExitCode: DWORD;
  WorkDirPtr: PChar;
begin
  CommandLine := QuoteArg(ExePath);
  for Arg in Args do
    CommandLine := CommandLine + ' ' + QuoteArg(Arg);
  UniqueString(CommandLine);

  FillChar(StartupInfo, SizeOf(StartupInfo), 0);
  StartupInfo.cb := SizeOf(StartupInfo);
  StartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  StartupInfo.wShowWindow := SW_HIDE;
  FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);

  if WorkingDir <> '' then
    WorkDirPtr := PChar(WorkingDir)
  else
    WorkDirPtr := nil;

  if not CreateProcess(nil, PChar(CommandLine), nil, nil, False, CREATE_NO_WINDOW, nil, WorkDirPtr,
    StartupInfo, ProcessInfo) then
    RaiseLastOSError;
  try
    WaitResult := WaitForSingleObject(ProcessInfo.hProcess, TimeoutMs);
    if WaitResult = WAIT_TIMEOUT then
    begin
      TerminateProcess(ProcessInfo.hProcess, DWORD(1));
      WaitForSingleObject(ProcessInfo.hProcess, 5000);
      raise EExternalProcessError.CreateFmt('external command timed out: %s', [CommandLine]);
    end;
    if WaitResult = WAIT_FAILED then
      RaiseLastOSError;
    if not GetExitCodeProcess(ProcessInfo.hProcess, ExitCode) then
      RaiseLastOSError;
    if ExitCode <> 0 then
      raise EExternalProcessError.CreateFmt('external command failed with exit code %d: %s', [ExitCode, CommandLine]);
  finally
    CloseHandle(ProcessInfo.hThread);
    CloseHandle(ProcessInfo.hProcess);
  end;
end;

end.
