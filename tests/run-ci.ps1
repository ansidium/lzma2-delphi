param(
  [ValidateSet('inner', 'quick', 'release', 'soak')]
  [string]$Mode = 'quick',
  [string]$Dcc64 = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\dcc64.exe',
  [string]$MsBuild = 'C:\Program Files\Microsoft Visual Studio\18\Enterprise\MSBuild\Current\Bin\MSBuild.exe',
  [string]$Bds = 'C:\Program Files (x86)\Embarcadero\Studio\37.0',
  [string]$SevenZip = $env:LZMA_TEST_7Z,
  [string]$Xz = $env:LZMA_TEST_XZ,
  [string]$LzmaExe = $env:LZMA_TEST_LZMA,
  [string]$PerformanceWorkRoot = $env:LZMA_PERF_WORKROOT,
  [string]$RamWorkRoot = $env:LZMA_PERF_RAMROOT,
  [bool]$RequireExternalTools = $false,
  [bool]$ReleasePerformance = $false,
  [int]$BuildParallelism = [Math]::Max(1, [Environment]::ProcessorCount),
  [int]$WarningBudget = 0,
  [string]$ApprovedWarningsPath = $env:LZMA_APPROVED_WARNINGS
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tests\qa-tools.ps1')
$srcPath = Join-Path $root 'src'
$rtlPath = Join-Path $Bds 'lib\win64\release'
$testBin = Join-Path (Join-Path $root 'build') 'test-bin'
$toolBin = Join-Path (Join-Path $root 'build') 'tool-bin'
$dcuPath = Join-Path (Join-Path $root 'build') 'dcu'
$artifactsDir = Join-Path $root 'artifacts'
$testResultsDir = Join-Path $artifactsDir 'test-results'
$dunitxConsolePath = Join-Path $testResultsDir 'Lzma.Tests.console.txt'
$memoryDir = Join-Path $artifactsDir 'memory'
$ciDir = Join-Path $artifactsDir 'ci'
$compilerLogPath = Join-Path $ciDir 'compiler-messages.txt'
$compilerSummaryPath = Join-Path $ciDir 'compiler-warnings.json'

$Mode = $Mode.ToLowerInvariant()
if ($Mode -eq 'release' -or $Mode -eq 'soak') {
  $RequireExternalTools = $true
  $ReleasePerformance = $true
} else {
  $ReleasePerformance = $false
}
$ShouldRunPerformanceScript = $Mode -in @('release', 'soak')
$ShouldRunMSBuild = $Mode -ne 'inner'
$InnerModeDisablesExternalTools = ($Mode -eq 'inner')
if ($InnerModeDisablesExternalTools) {
  Write-Host 'inner mode ignores LZMA_TEST_7Z/LZMA_TEST_XZ/LZMA_TEST_LZMA and optional external-tool parameters.'
  $RequireExternalTools = $false
  $SevenZip = ''
  $Xz = ''
  $LzmaExe = ''
  Remove-Item Env:\LZMA_TEST_7Z -ErrorAction SilentlyContinue
  Remove-Item Env:\LZMA_TEST_XZ -ErrorAction SilentlyContinue
  Remove-Item Env:\LZMA_TEST_LZMA -ErrorAction SilentlyContinue
}
$script:CompilerMessageLines = New-Object System.Collections.Generic.List[string]
if ($Mode -eq 'quick') {
  $script:RunPerformanceCommandLine = 'quick mode skips tests/run-performance.ps1; the performance matrix runs only in release/soak.'
} elseif ($Mode -eq 'inner') {
  $script:RunPerformanceCommandLine = 'inner mode skips tests/run-performance.ps1.'
} else {
  $script:RunPerformanceCommandLine = ''
}
$script:ValidationStartUtc = ''
$script:TrackedTreeStartStatus = @()
$script:TrackedTreeCleanAtStart = $true
$script:ResolvedQATools = $null
$script:CrossToolWorkRoot = ''

function Join-CommandLine([string]$Command, [object[]]$Arguments) {
  $items = @($Command) + @($Arguments | ForEach-Object { [string]$_ })
  return ($items | ForEach-Object {
    $text = [string]$_
    if ($text -match '[\s''"]') {
      "'" + ($text -replace "'", "''") + "'"
    } else {
      $text
    }
  }) -join ' '
}

function Get-DUnitXCategoryArgs([string]$CiMode) {
  switch ($CiMode) {
    'inner' {
      return @(
        '--include:unit',
        '--exclude:container,compat,perf-smoke,perf-release,soak,fuzz'
      )
    }
    'quick' {
      return @(
        '--include:unit,container,compat,perf-smoke',
        '--exclude:perf-release,soak,fuzz'
      )
    }
    'release' {
      return @('--exclude:soak,fuzz')
    }
    'soak' {
      return @('--exclude:fuzz')
    }
    default {
      throw "Unknown CI mode for DUnitX category filtering: $CiMode"
    }
  }
}

function Test-ScriptParameter([string]$ScriptPath, [string]$ParameterName) {
  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    return $false
  }

  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $ScriptPath,
    [ref]$tokens,
    [ref]$parseErrors)
  if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw "Could not parse script parameters for $ScriptPath"
  }
  if (-not $ast.ParamBlock) {
    return $false
  }

  foreach ($parameter in $ast.ParamBlock.Parameters) {
    if ($parameter.Name.VariablePath.UserPath -eq $ParameterName) {
      return $true
    }
  }
  return $false
}

function Get-ApprovedWarningsReport {
  if ([string]::IsNullOrWhiteSpace($ApprovedWarningsPath)) {
    return [pscustomobject]@{
      Path = ''
      Sha256 = ''
      Entries = @()
    }
  }

  if (-not (Test-Path -LiteralPath $ApprovedWarningsPath)) {
    throw "Approved compiler warning list is missing: $ApprovedWarningsPath"
  }

  $fullPath = [IO.Path]::GetFullPath($ApprovedWarningsPath)
  $entries = @(Get-Content -LiteralPath $fullPath | ForEach-Object {
    $line = ([string]$_).Trim()
    if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith('#')) {
      $line
    }
  })
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fullPath).Hash.ToLowerInvariant()
  return [pscustomobject]@{
    Path = Get-RelativePath $root $fullPath
    Sha256 = $hash
    Entries = @($entries)
  }
}

function Clear-OwnedDirectory([string]$Path) {
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a path outside the repository: $Path"
  }
  if (Test-Path -LiteralPath $full) {
    Remove-Item -LiteralPath $full -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $full | Out-Null
}

function Remove-OwnedFile([string]$Path) {
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove a path outside the repository: $Path"
  }
  Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
}

function Assert-Tool([string]$Path, [string]$Name, [bool]$Required) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    return
  }
  if ($Required) {
    throw "$Name was not found: $Path"
  }
  Write-Host "Skipping $Name-dependent checks: tool not configured."
}

function Get-DefaultPerformanceWorkRoot {
  foreach ($drive in @('D:', 'C:')) {
    $driveRoot = "$drive\"
    if (Test-Path -LiteralPath $driveRoot) {
      return (Join-Path $driveRoot 'lzma2-delphi-perf')
    }
  }
  throw 'Performance work root must be on local SSD drive C: or D:. Set -PerformanceWorkRoot, -RamWorkRoot, LZMA_PERF_WORKROOT, or LZMA_PERF_RAMROOT.'
}

if ($ShouldRunPerformanceScript -and
    [string]::IsNullOrWhiteSpace($PerformanceWorkRoot) -and
    [string]::IsNullOrWhiteSpace($RamWorkRoot)) {
  $PerformanceWorkRoot = Get-DefaultPerformanceWorkRoot
}

function Invoke-Checked([scriptblock]$Action, [string]$Name) {
  Write-Host "==> $Name"
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed with exit code $LASTEXITCODE"
  }
}

function Invoke-CompilerChecked([scriptblock]$Action, [string]$Name) {
  Write-Host "==> $Name"
  New-Item -ItemType Directory -Force -Path $ciDir | Out-Null
  Add-Content -LiteralPath $compilerLogPath -Encoding UTF8 -Value "==> $Name"
  $output = @(& $Action 2>&1)
  $exitCode = $LASTEXITCODE
  $global:LASTEXITCODE = $exitCode
  foreach ($line in $output) {
    $text = [string]$line
    $script:CompilerMessageLines.Add($text) | Out-Null
    Add-Content -LiteralPath $compilerLogPath -Encoding UTF8 -Value $text
    Write-Host $text
  }
  if ($exitCode -ne 0) {
    throw "$Name failed with exit code $exitCode"
  }
}

function Invoke-CompilerCheckedParallel([object[]]$Builds, [string]$Name) {
  if ($BuildParallelism -lt 1) {
    throw "BuildParallelism must be positive. Current: $BuildParallelism"
  }
  if ($Builds.Count -eq 0) {
    return
  }

  Write-Host "==> $Name ($($Builds.Count) jobs, parallelism $BuildParallelism)"
  New-Item -ItemType Directory -Force -Path $ciDir | Out-Null
  Add-Content -LiteralPath $compilerLogPath -Encoding UTF8 -Value "==> $Name ($($Builds.Count) jobs, parallelism $BuildParallelism)"

  $pending = New-Object System.Collections.Queue
  foreach ($build in $Builds) {
    $pending.Enqueue($build)
  }
  $running = @()
  $failed = @()

  while ($pending.Count -gt 0 -or $running.Count -gt 0) {
    while ($pending.Count -gt 0 -and $running.Count -lt $BuildParallelism) {
      $build = $pending.Dequeue()
      Write-Host "==> $($build.Name)"
      Add-Content -LiteralPath $compilerLogPath -Encoding UTF8 -Value "==> $($build.Name)"
      $job = Start-Job -Name $build.Name -ScriptBlock {
        param(
          [string]$Command,
          [string[]]$Arguments,
          [string]$WorkingDirectory
        )
        Set-Location -LiteralPath $WorkingDirectory
        $output = @(& $Command @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        [pscustomobject]@{
          ExitCode = $exitCode
          Lines = @($output | ForEach-Object { [string]$_ })
        }
      } -ArgumentList $build.Command, ([string[]]$build.Args), $root
      $job | Add-Member -NotePropertyName BuildName -NotePropertyValue $build.Name
      $running += $job
    }

    $finished = Wait-Job -Job $running -Any
    $result = Receive-Job -Job $finished
    $running = @($running | Where-Object { $_.Id -ne $finished.Id })

    $lines = @()
    $exitCode = 1
    if ($result) {
      $exitCode = [int]$result.ExitCode
      $lines = @($result.Lines | ForEach-Object { [string]$_ })
    }
    foreach ($line in $lines) {
      $script:CompilerMessageLines.Add($line) | Out-Null
      Add-Content -LiteralPath $compilerLogPath -Encoding UTF8 -Value $line
      Write-Host $line
    }
    if ($exitCode -ne 0) {
      $failed += "$($finished.BuildName) failed with exit code $exitCode"
    }
    Remove-Job -Job $finished -Force
  }

  if ($failed.Count -gt 0) {
    throw ($failed -join "`n")
  }
}

function Write-CompilerWarningsReport {
  New-Item -ItemType Directory -Force -Path $ciDir | Out-Null
  $warningLines = @($script:CompilerMessageLines | Where-Object {
    $_ -match '(?i)\bwarning\b' -or $_ -match '\bW\d{4}\b'
  })
  $deprecatedLines = @($script:CompilerMessageLines | Where-Object {
    $_ -match '(?i)\bdeprecated\b'
  })
  $approvedWarnings = Get-ApprovedWarningsReport

  $report = [ordered]@{
    schemaVersion = 1
    mode = $Mode
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    warningBudget = $WarningBudget
    warningCount = $warningLines.Count
    deprecatedCount = $deprecatedLines.Count
    messageLog = (Get-RelativePath $root $compilerLogPath)
    warnings = @($warningLines)
    deprecated = @($deprecatedLines)
    approvedWarningsPath = $approvedWarnings.Path
    approvedWarningsSha256 = $approvedWarnings.Sha256
    approvedWarningsCount = $approvedWarnings.Entries.Count
    approvedWarnings = @($approvedWarnings.Entries)
  }
  $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $compilerSummaryPath -Encoding UTF8
  Write-Host "Compiler warning report written: $compilerSummaryPath"

  if ($warningLines.Count -gt $WarningBudget) {
    throw "Compiler warning budget exceeded: warnings=$($warningLines.Count), budget=$WarningBudget"
  }
  if ($warningLines.Count -gt 0 -and $approvedWarnings.Entries.Count -eq 0) {
    throw 'Compiler warnings require an approved-warning list.'
  }
}

function Resolve-MSBuild([string]$Path) {
  if ($Path -and (Test-Path -LiteralPath $Path)) {
    return $Path
  }

  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (Test-Path -LiteralPath $vswhere) {
    $found = & $vswhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null |
      Select-Object -First 1
    if ($found -and (Test-Path -LiteralPath $found)) {
      return $found
    }
  }

  $candidates = @(
    'C:\Program Files\Microsoft Visual Studio\18\Enterprise\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe',
    'C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe'
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  return $Path
}

function Get-RelativePath([string]$BasePath, [string]$Path) {
  $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($base.Length).Replace('\', '/')
  }
  return $full.Replace('\', '/')
}

function Get-GitValue([string[]]$GitArgs) {
  try {
    $output = & git -C $root @GitArgs 2>$null | Select-Object -First 1
    $global:LASTEXITCODE = 0
    if (-not [string]::IsNullOrWhiteSpace([string]$output)) {
      return ([string]$output).Trim()
    }
  }
  catch {
    $global:LASTEXITCODE = 0
  }
  return ''
}

function Get-TrackedGitStatus {
  try {
    $status = & git -C $root status --short --untracked-files=all 2>$null
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -eq 0) {
      return @($status | ForEach-Object { [string]$_ })
    }
  }
  catch {
    $global:LASTEXITCODE = 0
  }
  return @()
}

function Get-GitBranch {
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_HEAD_REF)) {
    return $env:GITHUB_HEAD_REF
  }
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME) -and
      $env:GITHUB_REF_NAME -notmatch '^\d+/merge$') {
    return $env:GITHUB_REF_NAME
  }
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF) -and
      $env:GITHUB_REF -match '^refs/heads/(.+)$') {
    return $Matches[1]
  }

  $branch = Get-GitValue @('branch', '--show-current')
  if ([string]::IsNullOrWhiteSpace($branch)) {
    $branch = Get-GitValue @('rev-parse', '--abbrev-ref', 'HEAD')
  }
  if ($branch -eq 'HEAD') {
    return ''
  }
  return $branch
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

function Get-FileToolVersion([string]$Path) {
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

  $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
  [ordered]@{
    path = $Path
    available = $true
    productVersion = $info.ProductVersion
    fileVersion = $info.FileVersion
  }
}

function Write-MemoryReport([string]$DUnitXConsolePath) {
  New-Item -ItemType Directory -Force -Path $memoryDir | Out-Null
  if (-not (Test-Path -LiteralPath $DUnitXConsolePath)) {
    throw "DUnitX console output was not captured: $DUnitXConsolePath"
  }

  $consoleText = Get-Content -LiteralPath $DUnitXConsolePath -Raw
  foreach ($summaryPattern in
    'Tests Leaked\s*:\s*0',
    'Tests Failed\s*:\s*0',
    'Tests Errored\s*:\s*0') {
    if ($consoleText -notmatch $summaryPattern) {
      throw "DUnitX console output does not prove a clean memory/test result: $summaryPattern"
    }
  }

  $summaryLines = @($consoleText -split "`r?`n" | Where-Object { $_ -match '^\s*Tests (Found|Ignored|Passed|Leaked|Failed|Errored)\s*:' })
  $reportPath = Join-Path $memoryDir 'fastmm-report.txt'
  $lines = @(
    'LZMA2 Delphi memory diagnostics',
    "Generated UTC: $([DateTime]::UtcNow.ToString('o'))",
    "DUnitX console output: $DUnitXConsolePath",
    '',
    'DUnitX leak tracking completed with the test run.',
    'The current runner treats non-zero test, error, or leak results as CI failures.',
    '',
    'DUnitX console summary:'
  )
  $lines += $summaryLines
  $lines += @(
    '',
    'Covered memory paths:',
    '- success encode/decode',
    '- invalid properties',
    '- corrupted input',
    '- truncated input',
    '- checksum mismatch',
    '- cancellation callback',
    '- memory limit failure',
    '- worker thread memory/write failure'
  )
  $lines | Set-Content -LiteralPath $reportPath -Encoding UTF8
  Write-Host "Memory diagnostics report written: $reportPath"
}

function Write-CiArtifactsManifest {
  New-Item -ItemType Directory -Force -Path $ciDir | Out-Null
  $manifestPath = Join-Path $ciDir 'ci-artifacts-manifest.json'
  $manifestRoots = @(
    (Join-Path $artifactsDir 'compat')
    (Join-Path $artifactsDir 'fixtures')
    (Join-Path $artifactsDir 'match-finder')
    (Join-Path $artifactsDir 'memory')
    (Join-Path $artifactsDir 'perf')
    (Join-Path $artifactsDir 'test-results')
  )
  $files = @($manifestRoots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -File -Recurse
  })
  if (Test-Path -LiteralPath $compilerSummaryPath) {
    $files += Get-Item -LiteralPath $compilerSummaryPath
  }
  $files = @($files | Sort-Object FullName -Unique)
  $artifactRecords = @($files | ForEach-Object {
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    [ordered]@{
      path = Get-RelativePath $root $_.FullName
      bytes = $_.Length
      sha256 = $hash.Hash.ToLowerInvariant()
    }
  })

  $manifest = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    configuration = [ordered]@{
      mode = $Mode
      dunitxCategoryArgs = @(Get-DUnitXCategoryArgs $Mode)
      requireExternalTools = [bool]$RequireExternalTools
      releasePerformance = [bool]$ReleasePerformance
      performanceWorkRoot = if ($PerformanceWorkRoot) { $PerformanceWorkRoot } else { '' }
      ramWorkRoot = if ($RamWorkRoot) { $RamWorkRoot } else { '' }
      branch = (Get-GitBranch)
      commit = (Get-GitValue @('rev-parse', 'HEAD'))
      githubRunId = if ($env:GITHUB_RUN_ID) { $env:GITHUB_RUN_ID } else { '' }
      githubSha = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { '' }
      githubRef = if ($env:GITHUB_REF) { $env:GITHUB_REF } else { '' }
      githubRunAttempt = if ($env:GITHUB_RUN_ATTEMPT) { $env:GITHUB_RUN_ATTEMPT } else { '' }
      workflowName = if ($env:GITHUB_WORKFLOW) { $env:GITHUB_WORKFLOW } else { '' }
      runnerName = if ($env:RUNNER_NAME) { $env:RUNNER_NAME } elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
      runnerOS = if ($env:RUNNER_OS) { $env:RUNNER_OS } elseif ($env:OS) { $env:OS } else { [System.Environment]::OSVersion.Platform.ToString() }
      trackedTreeCleanAtStart = [bool]$script:TrackedTreeCleanAtStart
      trackedTreeStartStatus = @($script:TrackedTreeStartStatus)
      validationStartUtc = $script:ValidationStartUtc
    }
    compilerMessages = if (Test-Path -LiteralPath $compilerSummaryPath) {
      Get-Content -LiteralPath $compilerSummaryPath -Raw | ConvertFrom-Json
    } else {
      [ordered]@{
        warningBudget = $WarningBudget
        warningCount = 0
        deprecatedCount = 0
      }
    }
    commands = [ordered]@{
      runCi = [Environment]::CommandLine
      runPerformance = $script:RunPerformanceCommandLine
    }
    tools = [ordered]@{
      dcc64 = Get-ToolVersion $Dcc64 @('--version')
      msbuild = Get-FileToolVersion $MsBuild
      sevenZip = ConvertTo-LzmaQAToolManifestRecord $script:ResolvedQATools.sevenZip
      xz = ConvertTo-LzmaQAToolManifestRecord $script:ResolvedQATools.xz
      lzma = ConvertTo-LzmaQAToolManifestRecord $script:ResolvedQATools.lzma
    }
    artifacts = $artifactRecords
  }

  $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  Write-Host "CI artifacts manifest written: $manifestPath"
}

if (-not (Test-Path -LiteralPath $Dcc64)) {
  throw "dcc64.exe was not found: $Dcc64"
}
$MsBuild = Resolve-MSBuild $MsBuild
if ($ShouldRunMSBuild -and -not (Test-Path -LiteralPath $MsBuild)) {
  throw "MSBuild.exe was not found: $MsBuild"
}
if (-not (Test-Path -LiteralPath $Bds)) {
  throw "RAD Studio BDS path was not found: $Bds"
}

if ($InnerModeDisablesExternalTools) {
  $script:ResolvedQATools = [pscustomobject]@{
    sevenZip = New-LzmaQAToolRecord 'sevenZip' '' $false 'inner-disabled' $null
    xz = New-LzmaQAToolRecord 'xz' '' $false 'inner-disabled' $null
    lzma = New-LzmaQAToolRecord 'lzma' '' $false 'inner-disabled' $null
  }
} else {
  $script:ResolvedQATools = Resolve-LzmaQATools `
    -SevenZip $SevenZip `
    -LzmaExe $LzmaExe `
    -Xz $Xz `
    -RequireExternalTools:$RequireExternalTools `
    -InstallMissing:$RequireExternalTools `
    -SetEnvironment
}

$SevenZip = if ($script:ResolvedQATools.sevenZip.available) { [string]$script:ResolvedQATools.sevenZip.path } else { '' }
$Xz = if ($script:ResolvedQATools.xz.available) { [string]$script:ResolvedQATools.xz.path } else { '' }
$LzmaExe = if ($script:ResolvedQATools.lzma.available) { [string]$script:ResolvedQATools.lzma.path } else { '' }
if ($SevenZip -and
    [string]::IsNullOrWhiteSpace($PerformanceWorkRoot) -and
    [string]::IsNullOrWhiteSpace($RamWorkRoot)) {
  $PerformanceWorkRoot = Get-DefaultPerformanceWorkRoot
}
$compatWorkRootBase = if ($RamWorkRoot) { $RamWorkRoot } else { $PerformanceWorkRoot }
if ($SevenZip -and -not [string]::IsNullOrWhiteSpace($compatWorkRootBase)) {
  $script:CrossToolWorkRoot = Join-Path $compatWorkRootBase 'compat-work'
}
Assert-Tool $SevenZip 'LZMA_TEST_7Z' $RequireExternalTools
Assert-Tool $Xz 'LZMA_TEST_XZ' $RequireExternalTools
Assert-Tool $LzmaExe 'LZMA_TEST_LZMA' $RequireExternalTools

$env:BDS = $Bds
if ($SevenZip) { $env:LZMA_TEST_7Z = $SevenZip }
if ($Xz) { $env:LZMA_TEST_XZ = $Xz }
if ($LzmaExe) { $env:LZMA_TEST_LZMA = $LzmaExe }

$script:ValidationStartUtc = [DateTime]::UtcNow.ToString('o')
$script:TrackedTreeStartStatus = @(Get-TrackedGitStatus)
$script:TrackedTreeCleanAtStart = ($script:TrackedTreeStartStatus.Count -eq 0)
if (($Mode -eq 'release' -or $Mode -eq 'soak') -and -not $script:TrackedTreeCleanAtStart) {
  throw "Release/soak CI requires a clean source tree before artifact cleanup. First change: $($script:TrackedTreeStartStatus[0])"
}

foreach ($artifactSubdir in 'test-results', 'memory', 'ci', 'compat', 'fixtures', 'match-finder', 'perf') {
  Clear-OwnedDirectory (Join-Path $artifactsDir $artifactSubdir)
}
foreach ($fixtureSubdir in 'corrupt', 'raw', 'sources', 'xz') {
  Clear-OwnedDirectory (Join-Path (Join-Path $root 'tests\fixtures') $fixtureSubdir)
}
foreach ($fixtureManifest in 'corrupt-xz-regressions.json', 'raw-lzma-sdk-corpus.json', 'raw-lzma-sdk-release-corpus.json', 'raw-lzma-sdk.json', 'raw-lzma2-copy.json') {
  Remove-OwnedFile (Join-Path (Join-Path $root 'tests\fixtures\manifests') $fixtureManifest)
}
New-Item -ItemType Directory -Force -Path $testBin, $toolBin, $dcuPath | Out-Null

$commonDccArgs = @(
  '--no-config',
  '-Q',
  '-B',
  '-NSSystem;System.Win;Winapi;Vcl;Data;Xml',
  "-I$srcPath",
  "-U$srcPath;$rtlPath",
  "-N0$dcuPath",
  "-NH$dcuPath",
  "-NO$dcuPath",
  "-NB$dcuPath"
)

Invoke-Checked {
  $fixtureArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\generate-fixtures.ps1')
  )
  if ($ReleasePerformance) {
    $fixtureArgs += '-ReleaseCorpus'
  }
  & powershell @fixtureArgs
} 'Generate compatibility fixtures'

Invoke-CompilerChecked {
  & $Dcc64 @commonDccArgs "-E$testBin" (Join-Path $root 'tests\Lzma.Tests.dpr')
} 'Compile DUnitX tests'

Invoke-Checked {
  $dunitxArgs = @(Get-DUnitXCategoryArgs $Mode)
  & (Join-Path $testBin 'Lzma.Tests.exe') @dunitxArgs 2>&1 | Tee-Object -FilePath $dunitxConsolePath
  $testExitCode = $LASTEXITCODE
  $global:LASTEXITCODE = $testExitCode
} 'Run DUnitX tests'
Write-MemoryReport $dunitxConsolePath

if ($Mode -eq 'inner') {
  Write-CompilerWarningsReport
  Invoke-Checked {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\update-sha256-manifest.ps1')
  } 'Write fixture SHA-256 manifest'
  Write-CiArtifactsManifest
  Write-Host 'CI inner completed.'
  return
}

Invoke-CompilerChecked {
  & $Dcc64 @commonDccArgs "-E$toolBin" (Join-Path $root 'tools\Lzma2.dpr')
} 'Compile Lzma2 CLI for scripts'

$msBuilds = @()
foreach ($config in @('Debug', 'Release')) {
  foreach ($project in @(
    @{ Label = 'Lzma2 CLI'; Path = (Join-Path $root 'tools\Lzma2.dproj'); Output = 'lzma2-cli' },
    @{ Label = 'Lzma2 GUI tool'; Path = (Join-Path $root 'tools\Lzma2_GUI.dproj'); Output = 'lzma2-gui' }
  )) {
    $projectDcuPath = Join-Path $dcuPath (Join-Path 'msbuild' (Join-Path $config $project.Output))
    $projectOutPath = Join-Path $toolBin (Join-Path 'msbuild' (Join-Path $config $project.Output))
    $projectBrccPath = Join-Path $projectDcuPath 'brcc'
    $projectBrccOutputDir = $projectBrccPath.TrimEnd('\') + '\'
    New-Item -ItemType Directory -Force -Path $projectDcuPath, $projectOutPath, $projectBrccPath | Out-Null
    $msBuilds += [pscustomobject]@{
      Name = "MSBuild $($project.Label) $config Win64"
      Command = $MsBuild
      Args = @(
        $project.Path,
        '/t:Build',
        "/p:Config=$config",
        '/p:Platform=Win64',
        "/p:DCC_DcuOutput=$projectDcuPath",
        "/p:DCC_ExeOutput=$projectOutPath",
        "/p:BRCC_OutputDir=$projectBrccOutputDir",
        '/v:minimal'
      )
    }
  }
}
Invoke-CompilerCheckedParallel $msBuilds 'MSBuild Lzma2 CLI/VCL Debug/Release Win64'

Write-CompilerWarningsReport

if ($SevenZip) {
  Invoke-Checked {
    $crossArgs = @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', (Join-Path $root 'tests\run-cross-tool.ps1'),
      '-CliExe', (Join-Path $toolBin 'Lzma2.exe'),
      '-SevenZip', $SevenZip
    )
    if ($LzmaExe) {
      $crossArgs += @('-LzmaExe', $LzmaExe)
    }
    if ($Xz) {
      $crossArgs += @('-Xz', $Xz)
    }
    if ($script:CrossToolWorkRoot) {
      $crossArgs += @('-WorkRoot', $script:CrossToolWorkRoot)
      $crossRootIsRamBacked = -not [string]::IsNullOrWhiteSpace($RamWorkRoot)
      if ($crossRootIsRamBacked) {
        $crossArgs += '-RamBackedWorkRoot'
      }
    }
    & powershell @crossArgs
  } 'Run cross-tool compatibility smoke'
}

if ($ShouldRunPerformanceScript) {
  Invoke-Checked {
    $performanceScript = Join-Path $root 'tests\run-performance.ps1'
    $perfArgs = @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', $performanceScript,
      '-CliExe', (Join-Path $toolBin 'Lzma2.exe')
    )
    if ($SevenZip) {
      $perfArgs += @('-SevenZip', $SevenZip)
    }
    if ($LzmaExe) {
      $perfArgs += @('-LzmaExe', $LzmaExe)
    }
    if ($Xz) {
      $perfArgs += @('-Xz', $Xz)
    }
    if ($PerformanceWorkRoot) {
      $perfArgs += @('-WorkRoot', $PerformanceWorkRoot)
    }
    if ($RamWorkRoot -and (Test-ScriptParameter $performanceScript 'RamWorkRoot')) {
      $perfArgs += @('-RamWorkRoot', $RamWorkRoot)
    }
    if ($ReleasePerformance) {
      $perfArgs += '-ReleaseCorpus'
    }
    $script:RunPerformanceCommandLine = Join-CommandLine 'powershell' $perfArgs
    & powershell @perfArgs
  } 'Run performance evidence'
} else {
  Write-Host $script:RunPerformanceCommandLine
}

Remove-OwnedFile (Join-Path $artifactsDir 'perf\lzma2-benchmark.md')

Invoke-Checked {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\update-sha256-manifest.ps1')
} 'Write fixture SHA-256 manifest'

if ($Mode -eq 'soak') {
  $soakSummaryPath = Join-Path $ciDir 'soak-summary.txt'
  @(
    'LZMA2 Delphi soak mode completed.',
    "Generated UTC: $([DateTime]::UtcNow.ToString('o'))",
    'This mode runs the release corpus and external-tool gates; long-running fuzz/large-file suites remain optional jobs documented in docs/release-acceptance.md.'
  ) | Set-Content -LiteralPath $soakSummaryPath -Encoding UTF8
}

Write-CiArtifactsManifest

Invoke-Checked {
  $negativeValidateArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\test-validate-artifacts.ps1')
  )
  if ($Mode -eq 'quick') {
    $negativeValidateArgs += '-ScriptContractOnly'
  }
  if ($Mode -ne 'quick' -and $RequireExternalTools) {
    $negativeValidateArgs += '-RequireExternalTools'
  }
  if ($Mode -ne 'quick' -and $ReleasePerformance) {
    $negativeValidateArgs += '-RequireReleaseCorpus'
  }
  & powershell @negativeValidateArgs
} 'Run artifact validator contract tests'

Invoke-Checked {
  $validateArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\validate-artifacts.ps1')
  )
  if ($RequireExternalTools) {
    $validateArgs += '-RequireExternalTools'
  }
  if ($ReleasePerformance) {
    $validateArgs += '-RequireReleaseCorpus'
  }
  & powershell @validateArgs
} 'Validate CI artifacts'

Write-Host "CI $Mode completed."
