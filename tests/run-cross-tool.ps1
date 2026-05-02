param(
  [string]$CliExe = $env:LZMA2_CLI_EXE,
  [string]$SevenZip = $env:LZMA_TEST_7Z,
  [string]$LzmaExe = $env:LZMA_TEST_LZMA,
  [string]$Xz = $env:LZMA_TEST_XZ,
  [string]$WorkRoot = $env:LZMA_TEST_WORKROOT,
  [switch]$RamBackedWorkRoot
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tests\qa-tools.ps1')
function Get-DefaultTestWorkRoot {
  foreach ($drive in @('D:', 'C:')) {
    $driveRoot = "$drive\"
    if (Test-Path -LiteralPath $driveRoot) {
      return (Join-Path $driveRoot 'lzma2-delphi-tests')
    }
  }
  throw 'Cross-tool test work dir must be on local drive C: or D:. Set -WorkRoot or LZMA_TEST_WORKROOT.'
}

function Assert-TestWorkRoot([string]$Path, [bool]$RamBacked = $false) {
  $full = [IO.Path]::GetFullPath($Path)
  if ($full -match '^\\\\\?\\([A-Za-z]:\\.*)$') {
    $full = $Matches[1]
  }
  $repoRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
  if ($full.TrimEnd('\').Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Cross-tool test work root must not be the repository root: $full"
  }
  $pathRoot = [IO.Path]::GetPathRoot($full)
  if ([string]::IsNullOrWhiteSpace($pathRoot) -or $pathRoot.Length -lt 2 -or $pathRoot[1] -ne ':') {
    throw "Cross-tool test work dir must be on local drive C: or D:. Current: $full"
  }
  if ($full.TrimEnd('\').Equals($pathRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Cross-tool test work root must be a dedicated directory, not a drive root: $full"
  }

  $drive = [char]::ToUpperInvariant($pathRoot[0])
  if ((-not $RamBacked) -and $drive -ne 'C' -and $drive -ne 'D') {
    throw "Cross-tool test work dir must be on SSD drive C: or D:. Current: $full"
  }
  $driveRoot = "$drive`:\"
  $driveInfo = [IO.DriveInfo]::new($driveRoot)
  if ($RamBacked) {
    if ($driveInfo.DriveType -ne [IO.DriveType]::Ram) {
      throw "Cross-tool test work dir marked as RAM-backed must be on a RAM drive. Current drive $driveRoot is $($driveInfo.DriveType). Use -WorkRoot for fixed SSD roots."
    }
    return $full
  }
  if ($driveInfo.DriveType -ne [IO.DriveType]::Fixed) {
    throw "Cross-tool test work dir must be on a local fixed SSD drive C: or D:. Current drive $driveRoot is $($driveInfo.DriveType)."
  }

  try {
    $partition = Get-Partition -DriveLetter $drive -ErrorAction Stop | Select-Object -First 1
    $diskNumber = [int]$partition.DiskNumber
    $disk = Get-Disk -Number $diskNumber -ErrorAction Stop
    $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop)
    $physicalDisk = $null

    if ($disk.SerialNumber) {
      $diskSerial = $disk.SerialNumber.Trim()
      $physicalDisk = $physicalDisks |
        Where-Object { $_.SerialNumber -and $_.SerialNumber.Trim() -eq $diskSerial } |
        Select-Object -First 1
    }

    if (-not $physicalDisk -and $disk.FriendlyName) {
      $physicalDisk = $physicalDisks |
        Where-Object { $_.FriendlyName -eq $disk.FriendlyName -and $_.BusType -eq $disk.BusType } |
        Select-Object -First 1
    }

    if (-not $physicalDisk) {
      $physicalDisk = $physicalDisks |
        Where-Object { [int]$_.DeviceId -eq $diskNumber } |
        Select-Object -First 1
    }
  }
  catch {
    throw "Could not confirm that cross-tool drive $driveRoot is a local SSD. Set -WorkRoot or LZMA_TEST_WORKROOT to SSD drive C: or D:. $($_.Exception.Message)"
  }

  if (-not $physicalDisk) {
    throw "Could not map cross-tool drive $driveRoot to a physical disk with SSD media type."
  }
  if ([string]$physicalDisk.MediaType -ne 'SSD') {
    throw "Cross-tool test work dir must be on SSD drive C: or D:. Drive $driveRoot maps to disk $diskNumber with media type '$($physicalDisk.MediaType)'."
  }
  return $full
}

function Initialize-CrossToolWorkDir([string]$RootPath, [bool]$RamBacked = $false) {
  $workRoot = Assert-TestWorkRoot $RootPath $RamBacked
  $workDir = [IO.Path]::GetFullPath((Join-Path $workRoot 'cross-tool'))
  $rootPrefix = $workRoot.TrimEnd('\') + '\'
  if (-not $workDir.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved cross-tool work dir escapes the requested root: $workDir"
  }

  if (Test-Path -LiteralPath $workDir) {
    $sentinel = Join-Path $workDir '.lzma2-delphi-cross-tool-workdir'
    if (-not (Test-Path -LiteralPath $sentinel)) {
      $children = @(Get-ChildItem -LiteralPath $workDir -Force -ErrorAction SilentlyContinue)
      if ($children.Count -gt 0) {
        throw "Refusing to reuse non-empty cross-tool work dir without sentinel: $workDir"
      }
    }
  }

  New-Item -ItemType Directory -Force -Path $workDir | Out-Null
  $sentinel = Join-Path $workDir '.lzma2-delphi-cross-tool-workdir'
  "Owned by tests/run-cross-tool.ps1. Files in this directory may be overwritten by compatibility runs." |
    Set-Content -LiteralPath $sentinel -Encoding ASCII
  return $workDir
}

if (-not $CliExe) {
  $CliExe = Join-Path (Join-Path $root 'build') (Join-Path 'tool-bin' 'Lzma2.exe')
}
if (-not (Test-Path -LiteralPath $CliExe)) {
  throw "Lzma2 CLI executable not found. Set LZMA2_CLI_EXE or build tools/Lzma2.dpr first."
}
$script:ResolvedQATools = Resolve-LzmaQATools `
  -SevenZip $SevenZip `
  -LzmaExe $LzmaExe `
  -Xz $Xz `
  -RequireSevenZip:$true `
  -RequireLzma:$false `
  -RequireXz:$false `
  -InstallMissing:$true `
  -SetEnvironment
$SevenZip = [string]$script:ResolvedQATools.sevenZip.path
$LzmaExe = if ($script:ResolvedQATools.lzma.available) { [string]$script:ResolvedQATools.lzma.path } else { '' }
$Xz = if ($script:ResolvedQATools.xz.available) { [string]$script:ResolvedQATools.xz.path } else { '' }
$script:LzmaSdkVersion = [string]$script:ResolvedQATools.sevenZip.expectedVersion

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
  $WorkRoot = Get-DefaultTestWorkRoot
}
$testWorkRoot = Assert-TestWorkRoot $WorkRoot ([bool]$RamBackedWorkRoot)
$work = Initialize-CrossToolWorkDir $testWorkRoot ([bool]$RamBackedWorkRoot)
$reportDir = Join-Path (Join-Path $root 'artifacts') 'compat'
$reportPath = Join-Path $reportDir 'xz-cross-tool-report.json'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

$script:Cases = @()

function Get-RelativePath([string]$BasePath, [string]$Path) {
  $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($base.Length).Replace('\', '/')
  }
  return $full.Replace('\', '/')
}

function Get-ToolVersion([string]$Path, [string[]]$ToolArgs) {
  if (-not $Path) {
    return $null
  }
  if (-not (Test-Path -LiteralPath $Path)) {
    return [ordered]@{
      path = $Path
      available = $false
      version = ''
    }
  }

  $output = & $Path @ToolArgs 2>&1 | Out-String
  $exitCode = $LASTEXITCODE
  $global:LASTEXITCODE = 0
  $lines = @($output -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 8
  [ordered]@{
    path = $Path
    available = $true
    exitCode = $exitCode
    version = ($lines -join "`n")
  }
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function New-RepeatingFile([string]$Path, [int]$Size) {
  $bytes = New-Object byte[] $Size
  $pattern = [byte[]](65, 66, 67, 68, 69)
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    $bytes[$i] = $pattern[$i % $pattern.Length]
  }
  [IO.File]::WriteAllBytes($Path, $bytes)
}

function New-MixedFile([string]$Path, [int64]$Size) {
  $chunkSize = 1048576
  $bytes = New-Object byte[] $chunkSize
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if (($i % 4096) -lt 2048) {
      $bytes[$i] = [byte](65 + ($i % 7))
    } else {
      $bytes[$i] = [byte](($i * 73 + 19) -band 0xff)
    }
  }
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $remaining = $Size
    while ($remaining -gt 0) {
      $count = [int][Math]::Min([int64]$bytes.Length, $remaining)
      $stream.Write($bytes, 0, $count)
      $remaining -= $count
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Get-TreeFileEntries([string]$RootPath) {
  $rootFull = [IO.Path]::GetFullPath($RootPath)
  @(Get-ChildItem -LiteralPath $rootFull -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{
      path = Get-RelativePath $rootFull $_.FullName
      size = [int64]$_.Length
      sha256 = Get-Sha256 $_.FullName
    }
  })
}

function Assert-ExtractedTreeMatches([string]$SourceRoot, [string]$DecodedRoot) {
  $sourceEntries = Get-TreeFileEntries $SourceRoot
  foreach ($entry in $sourceEntries) {
    $decodedPath = Join-Path $DecodedRoot (($entry.path) -replace '/', '\')
    if (-not (Test-Path -LiteralPath $decodedPath)) {
      throw "Extracted tree is missing $($entry.path)"
    }
    $decodedHash = Get-Sha256 $decodedPath
    if ($decodedHash -ne $entry.sha256) {
      throw "Extracted tree SHA-256 mismatch for $($entry.path): $decodedHash != $($entry.sha256)"
    }
  }
  return $sourceEntries
}

function Initialize-ConsoleControlHelper {
  if ('Lzma2Delphi.ConsoleControl' -as [type]) {
    return
  }

  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Lzma2Delphi {
  public static class ConsoleControl {
    const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
    const uint CTRL_BREAK_EVENT = 1;
    const uint WAIT_OBJECT_0 = 0;
    const uint WAIT_TIMEOUT = 0x00000102;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
      public int cb;
      public string lpReserved;
      public string lpDesktop;
      public string lpTitle;
      public uint dwX;
      public uint dwY;
      public uint dwXSize;
      public uint dwYSize;
      public uint dwXCountChars;
      public uint dwYCountChars;
      public uint dwFillAttribute;
      public uint dwFlags;
      public ushort wShowWindow;
      public ushort cbReserved2;
      public IntPtr lpReserved2;
      public IntPtr hStdInput;
      public IntPtr hStdOutput;
      public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION {
      public IntPtr hProcess;
      public IntPtr hThread;
      public uint dwProcessId;
      public uint dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(
      string lpApplicationName,
      StringBuilder lpCommandLine,
      IntPtr lpProcessAttributes,
      IntPtr lpThreadAttributes,
      bool bInheritHandles,
      uint dwCreationFlags,
      IntPtr lpEnvironment,
      string lpCurrentDirectory,
      ref STARTUPINFO lpStartupInfo,
      out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr hObject);

    public static int RunAndSendCtrlBreak(string commandLine, string workingDirectory, int delayMs, int timeoutMs) {
      STARTUPINFO startupInfo = new STARTUPINFO();
      startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
      PROCESS_INFORMATION processInfo;
      StringBuilder mutableCommandLine = new StringBuilder(commandLine);
      if (!CreateProcessW(null, mutableCommandLine, IntPtr.Zero, IntPtr.Zero, false,
          CREATE_NEW_PROCESS_GROUP, IntPtr.Zero, workingDirectory, ref startupInfo, out processInfo)) {
        throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessW failed");
      }

      try {
        uint initialWait = WaitForSingleObject(processInfo.hProcess, (uint)delayMs);
        if (initialWait == WAIT_OBJECT_0) {
          uint earlyExitCode;
          if (!GetExitCodeProcess(processInfo.hProcess, out earlyExitCode)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
          }
          return (int)earlyExitCode;
        }

        if (!GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, processInfo.dwProcessId)) {
          throw new Win32Exception(Marshal.GetLastWin32Error(), "GenerateConsoleCtrlEvent failed");
        }

        uint finalWait = WaitForSingleObject(processInfo.hProcess, (uint)timeoutMs);
        if (finalWait == WAIT_TIMEOUT) {
          TerminateProcess(processInfo.hProcess, 255);
          throw new TimeoutException("Process did not exit after CTRL_BREAK_EVENT.");
        }
        if (finalWait != WAIT_OBJECT_0) {
          throw new Win32Exception(Marshal.GetLastWin32Error(), "WaitForSingleObject failed");
        }

        uint exitCode;
        if (!GetExitCodeProcess(processInfo.hProcess, out exitCode)) {
          throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed");
        }
        return (int)exitCode;
      }
      finally {
        if (processInfo.hThread != IntPtr.Zero) {
          CloseHandle(processInfo.hThread);
        }
        if (processInfo.hProcess != IntPtr.Zero) {
          CloseHandle(processInfo.hProcess);
        }
      }
    }
  }
}
'@
}

function Quote-WindowsArgument([string]$Argument) {
  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }
  return '"' + ($Argument -replace '"', '\"') + '"'
}

function Join-WindowsCommandLine([string[]]$Arguments) {
  return (($Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' ')
}

function Invoke-CliSmoke {
  $help = & $CliExe '--help' 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "CLI --help failed with exit code $LASTEXITCODE" }
  if ($help -notmatch 'Usage:' -or $help -notmatch '-tlzma') {
    throw "CLI --help output does not document usage and -tlzma."
  }

  $version = & $CliExe '--version' 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "CLI --version failed with exit code $LASTEXITCODE" }
  if ($version -notmatch ([regex]::Escape("7-Zip/LZMA SDK $script:LzmaSdkVersion")) -or $version -notmatch 'lzma') {
    throw "CLI --version output does not include SDK $script:LzmaSdkVersion baseline and supported containers."
  }

  $source = Join-Path $work 'cli-progress-source.bin'
  $archive = Join-Path $work 'cli-progress-source.xz'
  New-RepeatingFile $source 131072
  Remove-Item -LiteralPath $archive -ErrorAction SilentlyContinue

  $progress = & $CliExe a $archive $source '-txz' '-mx=1' '--progress' 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "CLI progress encode failed with exit code $LASTEXITCODE" }
  if ($progress -notmatch 'Progress:') {
    throw "CLI progress encode did not emit a visible progress line."
  }

  $cancelSource = Join-Path $work 'cli-cancel-source.bin'
  $cancelArchive = Join-Path $work 'cli-cancel-source.xz'
  New-MixedFile $cancelSource (96 * 1024 * 1024)
  Remove-Item -LiteralPath $cancelArchive -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $work -Filter 'cli-cancel-source.xz.tmp.*' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

  Initialize-ConsoleControlHelper
  $cancelCommandLine = Join-WindowsCommandLine @(
    $CliExe, 'a', $cancelArchive, $cancelSource,
    '-txz', '-mx=9', '-md=16m', '-mmt=1', '--progress')
  $cancelExitCode = [Lzma2Delphi.ConsoleControl]::RunAndSendCtrlBreak(
    $cancelCommandLine, $work, 750, 30000)
  if ($cancelExitCode -ne 3) {
    throw "CLI console cancellation smoke expected exit code 3, got $cancelExitCode."
  }
  if (Test-Path -LiteralPath $cancelArchive) {
    throw "CLI console cancellation smoke left the final archive behind."
  }
  $partialOutputs = @(Get-ChildItem -LiteralPath $work -Filter 'cli-cancel-source.xz.tmp.*' -File -ErrorAction SilentlyContinue)
  if ($partialOutputs.Count -ne 0) {
    throw "CLI console cancellation smoke left temporary output behind: $($partialOutputs[0].FullName)"
  }

  $script:Cases += [ordered]@{
    name = 'cli-cancel-cleans-partial-output'
    encoder = 'Delphi'
    verifier = 'Delphi'
    container = 'xz'
    level = 1
    check = 'crc64'
    threadCount = 1
    status = 'passed'
  }

  Write-Host 'CLI help/version/progress/cancellation smoke passed.'
}

function Invoke-DelphiCase([string]$Name, [int]$Size, [int]$Level, [int]$Threads, [string]$Check) {
  $source = Join-Path $work "$Name.bin"
  $archive = Join-Path $work "$Name.xz"
  $decoded = Join-Path $work "$Name.out"

  New-RepeatingFile $source $Size

  & $CliExe a $archive $source '-txz' "-mx=$Level" '-md=1m' "-mmt=$Threads" "-mcheck=$Check"
  if ($LASTEXITCODE -ne 0) { throw "Delphi encoder failed for $Name with exit code $LASTEXITCODE" }

  & $CliExe t $archive '-txz'
  if ($LASTEXITCODE -ne 0) { throw "Delphi test command failed for $Name with exit code $LASTEXITCODE" }

  & $SevenZip t $archive
  if ($LASTEXITCODE -ne 0) { throw "7-Zip rejected Delphi-generated XZ for $Name with exit code $LASTEXITCODE" }

  if ($Xz) {
    if (-not (Test-Path -LiteralPath $Xz)) {
      throw "LZMA_TEST_XZ is set but does not exist: $Xz"
    }
    & $Xz -t $archive
    if ($LASTEXITCODE -ne 0) { throw "xz rejected Delphi-generated XZ for $Name with exit code $LASTEXITCODE" }
  }

  & $CliExe x $archive $decoded '-txz'
  if ($LASTEXITCODE -ne 0) { throw "Delphi decoder failed for $Name with exit code $LASTEXITCODE" }

  $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
  $decodedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $decoded).Hash
  if ($sourceHash -ne $decodedHash) {
    throw "Decoded SHA-256 mismatch for ${Name}: $sourceHash != $decodedHash"
  }

  $script:Cases += [ordered]@{
    name = $Name
    source = Get-RelativePath $root $source
    archive = Get-RelativePath $root $archive
    decoded = Get-RelativePath $root $decoded
    encoder = 'Delphi'
    verifier = if ($Xz) { '7z+xz+Delphi' } else { '7z+Delphi' }
    container = 'xz'
    level = $Level
    check = $Check
    threadCount = $Threads
    sourceSha256 = $sourceHash.ToLowerInvariant()
    archiveSha256 = Get-Sha256 $archive
    decodedSha256 = $decodedHash.ToLowerInvariant()
    status = 'passed'
  }

  Write-Host "Cross-tool smoke passed: $archive"
}

function Invoke-SmokeCase([string]$Name, [int]$Size, [int]$Threads) {
  Invoke-DelphiCase $Name $Size 1 $Threads 'crc64'
}

function Invoke-DelphiEncoderMatrix {
  $levels = @(0, 1, 3, 5, 7, 9)
  $checks = @('none', 'crc32', 'crc64', 'sha256')
  foreach ($level in $levels) {
    foreach ($check in $checks) {
      $name = "delphi-l$level-$check"
      $size = 16384 + ([array]::IndexOf($levels, $level) * 4096) + ([array]::IndexOf($checks, $check) * 1024)
      Invoke-DelphiCase $name $size $level 1 $check
    }
  }
  Write-Host "Delphi encoder matrix passed: levels $($levels -join ', '), checks $($checks -join ', ')"
}

function Invoke-SevenZipEncoderMatrix {
  $levels = @(0, 1, 3, 5, 7, 9)
  foreach ($level in $levels) {
    $name = "7zip-mx$level-crc32"
    $sourceName = "$name.bin"
    $archiveName = "$name.xz"
    $decodedName = "$name.out"
    $source = Join-Path $work $sourceName
    $archive = Join-Path $work $archiveName
    $decoded = Join-Path $work $decodedName
    $size = 24576 + ([array]::IndexOf($levels, $level) * 4096)

    New-RepeatingFile $source $size
    Remove-Item -LiteralPath $archive, $decoded -ErrorAction SilentlyContinue

    Push-Location $work
    try {
      & $SevenZip a '-txz' "-mx=$level" '-mmt=1' '-m0=LZMA2:d=1m' $archiveName $sourceName
      if ($LASTEXITCODE -ne 0) { throw "7-Zip encoder failed for $name with exit code $LASTEXITCODE" }
      & $SevenZip t $archiveName
      if ($LASTEXITCODE -ne 0) { throw "7-Zip test failed for $name with exit code $LASTEXITCODE" }
    }
    finally {
      Pop-Location
    }

    & $CliExe x $archive $decoded '-txz'
    if ($LASTEXITCODE -ne 0) { throw "Delphi decoder failed for 7-Zip case $name with exit code $LASTEXITCODE" }

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
    $decodedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $decoded).Hash
    if ($sourceHash -ne $decodedHash) {
      throw "Decoded SHA-256 mismatch for ${name}: $sourceHash != $decodedHash"
    }

    $script:Cases += [ordered]@{
      name = $name
      source = Get-RelativePath $root $source
      archive = Get-RelativePath $root $archive
      decoded = Get-RelativePath $root $decoded
      encoder = '7-Zip'
      verifier = '7z+Delphi'
      container = 'xz'
      level = $level
      check = 'crc32'
      sourceSha256 = $sourceHash.ToLowerInvariant()
      archiveSha256 = Get-Sha256 $archive
      decodedSha256 = $decodedHash.ToLowerInvariant()
      status = 'passed'
    }
  }

  Write-Host "7-Zip encoder matrix passed: levels $($levels -join ', ')"
}

function Invoke-XzUtilsMatrix {
  if (-not $Xz) {
    Write-Host "Skipping xz-utils encoder matrix: set LZMA_TEST_XZ to enable."
    $script:Cases += [ordered]@{
      name = 'xz-utils-level-check-matrix'
      encoder = 'xz-utils'
      status = 'skipped'
      reason = 'LZMA_TEST_XZ is not configured'
    }
    return
  }
  if (-not (Test-Path -LiteralPath $Xz)) {
    throw "LZMA_TEST_XZ is set but does not exist: $Xz"
  }

  $levels = @('-0', '-1', '-3', '-5', '-7', '-9')
  $checks = @('none', 'crc32', 'crc64', 'sha256')
  foreach ($level in $levels) {
    foreach ($check in $checks) {
      $name = "xz-utils-$($level.TrimStart('-'))-$check"
      $source = Join-Path $work "$name.bin"
      $archive = "$source.xz"
      $decoded = Join-Path $work "$name.out"
      $size = 32768 + ([array]::IndexOf($levels, $level) * 4096) + ([array]::IndexOf($checks, $check) * 1024)

      New-RepeatingFile $source $size
      Remove-Item -LiteralPath $archive, $decoded -ErrorAction SilentlyContinue

      & $Xz $level "--check=$check" '--block-size=16384' '-k' '-f' $source
      if ($LASTEXITCODE -ne 0) { throw "xz-utils encoder failed for $name with exit code $LASTEXITCODE" }

      & $CliExe x $archive $decoded '-txz'
      if ($LASTEXITCODE -ne 0) { throw "Delphi decoder failed for xz-utils case $name with exit code $LASTEXITCODE" }

      $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
      $decodedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $decoded).Hash
      if ($sourceHash -ne $decodedHash) {
        throw "Decoded SHA-256 mismatch for ${name}: $sourceHash != $decodedHash"
      }

      $script:Cases += [ordered]@{
        name = $name
        source = Get-RelativePath $root $source
        archive = Get-RelativePath $root $archive
        decoded = Get-RelativePath $root $decoded
        encoder = 'xz-utils'
        verifier = 'Delphi'
        container = 'xz'
        level = [int]$level.TrimStart('-')
        check = $check
        sourceSha256 = $sourceHash.ToLowerInvariant()
        archiveSha256 = Get-Sha256 $archive
        decodedSha256 = $decodedHash.ToLowerInvariant()
        status = 'passed'
      }
    }
  }

  Write-Host "xz-utils encoder matrix passed: levels $($levels -join ', '), checks $($checks -join ', ')"
}

function Add-XzRawLzma2SkipCase([string]$Name, [string]$Encoder, [string]$Verifier) {
  $script:Cases += [ordered]@{
    name = $Name
    encoder = $Encoder
    verifier = $Verifier
    container = 'raw-lzma2'
    sourceSha256 = ''
    archiveSha256 = ''
    decodedSha256 = ''
    status = 'skipped'
    reason = 'LZMA_TEST_XZ is not configured'
  }
}

function Invoke-XzRawLzma2Smoke {
  if (-not $Xz) {
    Write-Host "Skipping raw LZMA2 xz-utils smoke: set LZMA_TEST_XZ to enable."
    Add-XzRawLzma2SkipCase 'raw-lzma2-delphi-to-xz-utils' 'Delphi' 'xz-utils'
    Add-XzRawLzma2SkipCase 'raw-lzma2-xz-utils-to-delphi' 'xz-utils' 'Delphi'
    return
  }
  if (-not (Test-Path -LiteralPath $Xz)) {
    throw "LZMA_TEST_XZ is set but does not exist: $Xz"
  }

  $dictionary = 1048576
  $source = Join-Path $work 'raw-lzma2-cross-tool-source.bin'
  New-MixedFile $source 98304
  $sourceHash = Get-Sha256 $source

  $delphiArchive = Join-Path $work 'raw-lzma2-delphi-to-xz-utils.lzma2'
  $xzDecoded = Join-Path $work 'raw-lzma2-delphi-to-xz-utils'
  Remove-Item -LiteralPath $delphiArchive, $xzDecoded -ErrorAction SilentlyContinue

  & $CliExe a $delphiArchive $source '-traw' '-mx=1' '-md=1m' '-mmt=1'
  if ($LASTEXITCODE -ne 0) { throw "Delphi raw LZMA2 encoder failed with exit code $LASTEXITCODE" }

  Push-Location $work
  try {
    & $Xz '--decompress' '--format=raw' '--lzma2=dict=1MiB' '--suffix=.lzma2' '-k' '-f' (Split-Path -Leaf $delphiArchive)
    if ($LASTEXITCODE -ne 0) { throw "xz-utils rejected Delphi raw LZMA2 output with exit code $LASTEXITCODE" }
  }
  finally {
    Pop-Location
  }

  $decodedHash = Get-Sha256 $xzDecoded
  if ($sourceHash -ne $decodedHash) {
    throw "xz-utils decoded Delphi raw LZMA2 SHA-256 mismatch: $sourceHash != $decodedHash"
  }

  $script:Cases += [ordered]@{
    name = 'raw-lzma2-delphi-to-xz-utils'
    source = Get-RelativePath $root $source
    archive = Get-RelativePath $root $delphiArchive
    decoded = Get-RelativePath $root $xzDecoded
    encoder = 'Delphi'
    verifier = 'xz-utils'
    container = 'raw-lzma2'
    level = 1
    dictionary = $dictionary
    check = 'none'
    threadCount = 1
    sourceSha256 = $sourceHash
    archiveSha256 = Get-Sha256 $delphiArchive
    decodedSha256 = $decodedHash
    status = 'passed'
  }

  $xzSourceName = 'raw-lzma2-xz-utils-to-delphi.bin'
  $xzSource = Join-Path $work $xzSourceName
  $xzArchive = Join-Path $work "$xzSourceName.lzma2"
  $delphiDecoded = Join-Path $work 'raw-lzma2-xz-utils-to-delphi.out'
  Copy-Item -LiteralPath $source -Destination $xzSource -Force
  Remove-Item -LiteralPath $xzArchive, $delphiDecoded -ErrorAction SilentlyContinue

  Push-Location $work
  try {
    & $Xz '-1' '--format=raw' '--lzma2=dict=1MiB' '--suffix=.lzma2' '-k' '-f' $xzSourceName
    if ($LASTEXITCODE -ne 0) { throw "xz-utils raw LZMA2 encoder failed with exit code $LASTEXITCODE" }
  }
  finally {
    Pop-Location
  }

  & $CliExe x $xzArchive $delphiDecoded '-traw' '-md=1m' '-mmt=1'
  if ($LASTEXITCODE -ne 0) { throw "Delphi raw LZMA2 decoder failed with exit code $LASTEXITCODE" }

  $decodedHash = Get-Sha256 $delphiDecoded
  if ($sourceHash -ne $decodedHash) {
    throw "Delphi decoded xz-utils raw LZMA2 SHA-256 mismatch: $sourceHash != $decodedHash"
  }

  $script:Cases += [ordered]@{
    name = 'raw-lzma2-xz-utils-to-delphi'
    source = Get-RelativePath $root $xzSource
    archive = Get-RelativePath $root $xzArchive
    decoded = Get-RelativePath $root $delphiDecoded
    encoder = 'xz-utils'
    verifier = 'Delphi'
    container = 'raw-lzma2'
    level = 1
    dictionary = $dictionary
    check = 'none'
    threadCount = 1
    sourceSha256 = $sourceHash
    archiveSha256 = Get-Sha256 $xzArchive
    decodedSha256 = $decodedHash
    status = 'passed'
  }

  Write-Host 'Raw LZMA2 xz-utils interop smoke passed in both directions.'
}

function Invoke-LzmaStandaloneInterop {
  if (-not $LzmaExe) {
    Write-Host "Skipping standalone .lzma interop: set LZMA_TEST_LZMA to enable."
    $script:Cases += [ordered]@{
      name = 'standalone-lzma-sdk-matrix'
      encoder = 'LZMA SDK'
      container = 'lzma'
      status = 'skipped'
      reason = 'LZMA_TEST_LZMA is not configured'
    }
    return
  }
  if (-not (Test-Path -LiteralPath $LzmaExe)) {
    throw "LZMA_TEST_LZMA is set but does not exist: $LzmaExe"
  }

  $source = Join-Path $work 'standalone-lzma-source.bin'
  $delphiArchive = Join-Path $work 'standalone-delphi.lzma'
  $delphiDecoded = Join-Path $work 'standalone-delphi-sdk.out'
  $sdkArchive = Join-Path $work 'standalone-sdk.lzma'
  $sdkDecoded = Join-Path $work 'standalone-sdk-delphi.out'
  New-RepeatingFile $source 98304
  Remove-Item -LiteralPath $delphiArchive, $delphiDecoded, $sdkArchive, $sdkDecoded -ErrorAction SilentlyContinue

  & $CliExe a $delphiArchive $source '-tlzma' '-mx=1' '-md=1m'
  if ($LASTEXITCODE -ne 0) { throw "Delphi standalone .lzma encoder failed with exit code $LASTEXITCODE" }
  & $LzmaExe d $delphiArchive $delphiDecoded
  if ($LASTEXITCODE -ne 0) { throw "LZMA SDK rejected Delphi standalone .lzma with exit code $LASTEXITCODE" }

  $sourceHash = Get-Sha256 $source
  $decodedHash = Get-Sha256 $delphiDecoded
  if ($sourceHash -ne $decodedHash) {
    throw "SDK-decoded standalone .lzma SHA-256 mismatch: $sourceHash != $decodedHash"
  }

  $script:Cases += [ordered]@{
    name = 'delphi-standalone-lzma-sdk-decode'
    source = Get-RelativePath $root $source
    archive = Get-RelativePath $root $delphiArchive
    decoded = Get-RelativePath $root $delphiDecoded
    encoder = 'Delphi'
    verifier = 'LZMA SDK'
    container = 'lzma'
    level = 1
    check = 'none'
    threadCount = 1
    sourceSha256 = $sourceHash
    archiveSha256 = Get-Sha256 $delphiArchive
    decodedSha256 = $decodedHash
    status = 'passed'
  }

  & $LzmaExe e $source $sdkArchive '-a0' '-d20' '-fb32'
  if ($LASTEXITCODE -ne 0) { throw "LZMA SDK standalone encoder failed with exit code $LASTEXITCODE" }
  & $CliExe x $sdkArchive $sdkDecoded '-tlzma'
  if ($LASTEXITCODE -ne 0) { throw "Delphi standalone .lzma decoder failed with exit code $LASTEXITCODE" }

  $decodedHash = Get-Sha256 $sdkDecoded
  if ($sourceHash -ne $decodedHash) {
    throw "Delphi-decoded standalone .lzma SHA-256 mismatch: $sourceHash != $decodedHash"
  }

  $script:Cases += [ordered]@{
    name = 'sdk-standalone-lzma-delphi-decode'
    source = Get-RelativePath $root $source
    archive = Get-RelativePath $root $sdkArchive
    decoded = Get-RelativePath $root $sdkDecoded
    encoder = 'LZMA SDK'
    verifier = 'Delphi'
    container = 'lzma'
    level = 1
    check = 'none'
    threadCount = 1
    sourceSha256 = $sourceHash
    archiveSha256 = Get-Sha256 $sdkArchive
    decodedSha256 = $decodedHash
    status = 'passed'
  }

  Write-Host 'Standalone .lzma interop passed.'
}

function Invoke-ExtractionErgonomicsSmoke {
  $source = Join-Path $work 'stored-name.bin'
  $archive = Join-Path $work 'renamed-archive.7z'
  $outputDir = Join-Path $work 'extract-out'
  $explicitOut = Join-Path $work 'explicit-7z.out'
  $spodDir = Join-Path $work 'extract-spod'
  $sporDir = Join-Path $work 'extract-spor'
  $spocPrefix = Join-Path $work 'extract-spoc-'
  $spocOut = $spocPrefix + 'stored-name.bin'
  $multiRoot = Join-Path $work 'multi-entry-src'
  $multiArchive = Join-Path $work 'multi-entry.7z'
  $multiOut = Join-Path $work 'multi-entry-out'
  $lzmaArchive = Join-Path $work 'named-standalone.lzma'
  $lzmaOutDir = Join-Path $work 'lzma-out'

  New-RepeatingFile $source 8192
  Remove-Item -LiteralPath $archive, $explicitOut, $spocOut, $multiArchive, $lzmaArchive -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $outputDir, $spodDir, $sporDir, $multiRoot, $multiOut, $lzmaOutDir -Recurse -Force -ErrorAction SilentlyContinue

  & $CliExe a $archive $source '-t7z' '-mx=1' '-md=1m'
  if ($LASTEXITCODE -ne 0) { throw "7z CLI encode for extraction smoke failed with exit code $LASTEXITCODE" }
  & $CliExe x $archive '-t7z' "-o$outputDir"
  if ($LASTEXITCODE -ne 0) { throw "7z CLI -o extract smoke failed with exit code $LASTEXITCODE" }
  $storedOut = Join-Path $outputDir 'stored-name.bin'
  if (-not (Test-Path -LiteralPath $storedOut)) {
    throw "7z CLI -o extract did not use the stored single-file archive name."
  }
  if ((Get-Sha256 $source) -ne (Get-Sha256 $storedOut)) {
    throw "7z CLI -o extracted bytes do not match source."
  }

  & $CliExe x $archive $explicitOut '-t7z' "-o$outputDir"
  if ($LASTEXITCODE -ne 0) { throw "7z CLI explicit output extract failed with exit code $LASTEXITCODE" }
  if (-not (Test-Path -LiteralPath $explicitOut)) {
    throw "7z CLI explicit output path was ignored when -o was also supplied."
  }

  foreach ($modeCase in @(
      @{ mode = '-spod'; dir = $spodDir; expected = (Join-Path $spodDir 'stored-name.bin') },
      @{ mode = '-spor'; dir = $sporDir; expected = (Join-Path $sporDir 'stored-name.bin') })) {
    & $CliExe x $archive '-t7z' "-o$($modeCase.dir)" $modeCase.mode
    if ($LASTEXITCODE -ne 0) { throw "7z CLI $($modeCase.mode) extract failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $modeCase.expected)) {
      throw "7z CLI $($modeCase.mode) did not write the expected output path."
    }
    if ((Get-Sha256 $source) -ne (Get-Sha256 $modeCase.expected)) {
      throw "7z CLI $($modeCase.mode) extracted bytes do not match source."
    }
    $script:Cases += [ordered]@{
      name = "cli-output-path-mode-$($modeCase.mode.TrimStart('-'))"
      encoder = 'Delphi'
      verifier = 'Delphi'
      container = '7z'
      status = 'passed'
    }
  }

  & $CliExe x $archive '-t7z' "-o$spocPrefix" '-spoc'
  if ($LASTEXITCODE -ne 0) { throw "7z CLI -spoc extract failed with exit code $LASTEXITCODE" }
  if (-not (Test-Path -LiteralPath $spocOut)) {
    throw "7z CLI -spoc did not concatenate the output prefix and stored name."
  }
  if ((Get-Sha256 $source) -ne (Get-Sha256 $spocOut)) {
    throw "7z CLI -spoc extracted bytes do not match source."
  }
  $script:Cases += [ordered]@{
    name = 'cli-output-path-mode-spoc'
    encoder = 'Delphi'
    verifier = 'Delphi'
    container = '7z'
    status = 'passed'
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $multiRoot 'dir') | Out-Null
  New-RepeatingFile (Join-Path (Join-Path $multiRoot 'dir') 'a.bin') 6144
  New-MixedFile (Join-Path $multiRoot 'b.bin') 7168
  [IO.File]::WriteAllBytes((Join-Path (Join-Path $multiRoot 'dir') 'empty.txt'), [byte[]]@())
  Push-Location $multiRoot
  try {
    & $SevenZip a '-t7z' '-mx=1' '-mmt=1' '-m0=LZMA2:d=1m' '-ms=off' $multiArchive 'dir' 'b.bin'
    if ($LASTEXITCODE -ne 0) { throw "7-Zip multi-entry archive creation failed with exit code $LASTEXITCODE" }
  }
  finally {
    Pop-Location
  }
  & $CliExe x $multiArchive '-t7z' "-o$multiOut"
  if ($LASTEXITCODE -ne 0) { throw "Delphi CLI multi-entry 7z extract failed with exit code $LASTEXITCODE" }
  foreach ($relative in 'dir/a.bin', 'b.bin', 'dir/empty.txt') {
    $sourcePath = Join-Path $multiRoot $relative
    $decodedPath = Join-Path $multiOut $relative
    if (-not (Test-Path -LiteralPath $decodedPath)) {
      throw "Delphi CLI multi-entry 7z extract missed $relative"
    }
    if ((Get-Sha256 $sourcePath) -ne (Get-Sha256 $decodedPath)) {
      throw "Delphi CLI multi-entry 7z extract hash mismatch for $relative"
    }
  }
  $script:Cases += [ordered]@{
    name = 'cli-7z-multi-entry-extract'
    encoder = '7-Zip'
    verifier = 'Delphi'
    container = '7z'
    status = 'passed'
  }

  & $CliExe a $lzmaArchive $source '-tlzma' '-mx=1' '-md=1m'
  if ($LASTEXITCODE -ne 0) { throw ".lzma CLI encode for extraction smoke failed with exit code $LASTEXITCODE" }
  & $CliExe x $lzmaArchive '-tlzma' "-o$lzmaOutDir"
  if ($LASTEXITCODE -ne 0) { throw ".lzma CLI -o extract smoke failed with exit code $LASTEXITCODE" }
  $lzmaOut = Join-Path $lzmaOutDir 'named-standalone'
  if (-not (Test-Path -LiteralPath $lzmaOut)) {
    throw ".lzma CLI -o extract did not use the archive basename."
  }
  if ((Get-Sha256 $source) -ne (Get-Sha256 $lzmaOut)) {
    throw ".lzma CLI -o extracted bytes do not match source."
  }

  Write-Host 'CLI extraction ergonomics smoke passed.'
}

function Invoke-DelphiSevenZipMultiFileEncodeInterop {
  foreach ($case in @(
      @{ name = 'cli-7z-multi-file-lzma2-encode'; method = 'LZMA2'; methodSwitch = '-m0=LZMA2:d=1m' },
      @{ name = 'cli-7z-multi-file-lzma-encode'; method = 'LZMA'; methodSwitch = '-m0=LZMA:d=1m' })) {
    $sourceRoot = Join-Path $work "$($case.name)-src"
    $archive = Join-Path $work "$($case.name).7z"
    $decodedRoot = Join-Path $work "$($case.name)-7z-out"
    $storedRootName = Split-Path -Leaf $sourceRoot
    $storedDecodedRoot = Join-Path $decodedRoot $storedRootName

    Remove-Item -LiteralPath $sourceRoot, $decodedRoot, $archive -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot 'dir') | Out-Null
    New-RepeatingFile (Join-Path (Join-Path $sourceRoot 'dir') 'a.bin') 12288
    New-MixedFile (Join-Path $sourceRoot 'b.bin') 13312
    [IO.File]::WriteAllBytes((Join-Path (Join-Path $sourceRoot 'dir') 'empty.txt'), [byte[]]@())

    & $CliExe a $archive $sourceRoot '-t7z' '-mx=1' '-md=1m' $case.methodSwitch
    if ($LASTEXITCODE -ne 0) { throw "Delphi CLI multi-file 7z $($case.method) encode failed with exit code $LASTEXITCODE" }

    & $SevenZip t $archive
    if ($LASTEXITCODE -ne 0) { throw "7-Zip rejected Delphi-generated multi-file 7z $($case.method) archive with exit code $LASTEXITCODE" }

    & $CliExe t $archive '-t7z'
    if ($LASTEXITCODE -ne 0) { throw "Delphi CLI rejected its multi-file 7z $($case.method) archive with exit code $LASTEXITCODE" }

    & $SevenZip x "-o$decodedRoot" '-y' $archive
    if ($LASTEXITCODE -ne 0) { throw "7-Zip failed to extract Delphi-generated multi-file 7z $($case.method) archive with exit code $LASTEXITCODE" }

    $entries = Assert-ExtractedTreeMatches $sourceRoot $storedDecodedRoot
    $script:Cases += [ordered]@{
      name = $case.name
      source = Get-RelativePath $root $sourceRoot
      archive = Get-RelativePath $root $archive
      decoded = Get-RelativePath $root $storedDecodedRoot
      encoder = 'Delphi'
      verifier = '7z+Delphi'
      container = '7z'
      method = $case.method
      level = 1
      check = 'crc32'
      entryCount = $entries.Count
      archiveSha256 = Get-Sha256 $archive
      entries = $entries
      status = 'passed'
    }
  }

  Write-Host 'Delphi multi-file 7z encode interop passed for LZMA2 and LZMA.'
}

function Invoke-SevenZipSolidArchiveInterop {
  foreach ($case in @(
      @{ name = 'cli-7z-solid-lzma2-extract'; method = 'LZMA2'; methodSwitch = '-m0=LZMA2:d=1m' },
      @{ name = 'cli-7z-solid-lzma-extract'; method = 'LZMA'; methodSwitch = '-m0=LZMA:d=1m' })) {
    $sourceRoot = Join-Path $work "$($case.name)-src"
    $archive = Join-Path $work "$($case.name).7z"
    $decodedRoot = Join-Path $work "$($case.name)-delphi-out"

    Remove-Item -LiteralPath $sourceRoot, $decodedRoot, $archive -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
    New-RepeatingFile (Join-Path $sourceRoot 'a.bin') 18432
    New-MixedFile (Join-Path $sourceRoot 'b.bin') 19456

    Push-Location $sourceRoot
    try {
      & $SevenZip a '-t7z' '-mx=1' '-mmt=1' $case.methodSwitch '-ms=on' $archive 'a.bin' 'b.bin'
      if ($LASTEXITCODE -ne 0) { throw "7-Zip solid $($case.method) archive creation failed with exit code $LASTEXITCODE" }
    }
    finally {
      Pop-Location
    }

    & $CliExe x $archive '-t7z' "-o$decodedRoot"
    if ($LASTEXITCODE -ne 0) { throw "Delphi CLI solid 7z $($case.method) extract failed with exit code $LASTEXITCODE" }

    $entries = Assert-ExtractedTreeMatches $sourceRoot $decodedRoot
    $script:Cases += [ordered]@{
      name = $case.name
      source = Get-RelativePath $root $sourceRoot
      archive = Get-RelativePath $root $archive
      decoded = Get-RelativePath $root $decodedRoot
      encoder = '7-Zip'
      verifier = 'Delphi'
      container = '7z'
      method = $case.method
      level = 1
      check = 'crc32'
      entryCount = $entries.Count
      archiveSha256 = Get-Sha256 $archive
      entries = $entries
      status = 'passed'
    }
  }

  Write-Host '7-Zip solid 7z extract interop passed for LZMA2 and LZMA.'
}

Invoke-CliSmoke
Invoke-ExtractionErgonomicsSmoke
Invoke-DelphiSevenZipMultiFileEncodeInterop
Invoke-SevenZipSolidArchiveInterop
Invoke-SmokeCase 'repeat5-64k-1t' 65536 1
Invoke-SmokeCase 'repeat5-200k-4t' 200000 4
Invoke-DelphiEncoderMatrix
Invoke-SevenZipEncoderMatrix
Invoke-XzUtilsMatrix
Invoke-XzRawLzma2Smoke
Invoke-LzmaStandaloneInterop

$report = [ordered]@{
  schemaVersion = 1
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  cliExe = Get-RelativePath $root $CliExe
  workRoot = $testWorkRoot
  workDir = $work
  workDirSentinel = Join-Path $work '.lzma2-delphi-cross-tool-workdir'
  tools = [ordered]@{
    sevenZip = ConvertTo-LzmaQAToolManifestRecord $script:ResolvedQATools.sevenZip
    lzma = ConvertTo-LzmaQAToolManifestRecord $script:ResolvedQATools.lzma
    xz = ConvertTo-LzmaQAToolManifestRecord $script:ResolvedQATools.xz
  }
  cases = $script:Cases
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "Cross-tool compatibility report written: $reportPath"
