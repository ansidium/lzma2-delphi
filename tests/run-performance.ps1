param(
  [string]$CliExe = $env:LZMA2_CLI_EXE,
  [string]$SevenZip = $env:LZMA_TEST_7Z,
  [string]$LzmaExe = $env:LZMA_TEST_LZMA,
  [string]$Xz = $env:LZMA_TEST_XZ,
  [int]$RepeatSize = 1048576,
  [int]$LargeRepeatSize = 4194304,
  [int]$ReleaseCorpusSize = 268435456,
  [string]$WorkRoot = $env:LZMA_PERF_WORKROOT,
  [string]$RamWorkRoot = $env:LZMA_PERF_RAMROOT,
  [string]$MatrixMaxDictionary = $env:LZMA_PERF_MATRIX_MAX_DICTIONARY,
  [switch]$ReleaseCorpus
)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tests\qa-tools.ps1')
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
  -RequireExternalTools:$false `
  -InstallMissing:$ReleaseCorpus `
  -SetEnvironment
$SevenZip = if ($script:ResolvedQATools.sevenZip.available) { [string]$script:ResolvedQATools.sevenZip.path } else { '' }
$LzmaExe = if ($script:ResolvedQATools.lzma.available) { [string]$script:ResolvedQATools.lzma.path } else { '' }
$Xz = if ($script:ResolvedQATools.xz.available) { [string]$script:ResolvedQATools.xz.path } else { '' }
$script:LzmaSdkVersion = [string]$script:ResolvedQATools.sevenZip.expectedVersion
$script:LzmaSdkLabel = "LZMA SDK $script:LzmaSdkVersion"

$matrixMaxDictionaryBytes = [int64]536870912
if (-not [string]::IsNullOrWhiteSpace($MatrixMaxDictionary)) {
  $parsedMatrixMaxDictionary = [int64]::Parse($MatrixMaxDictionary, [System.Globalization.CultureInfo]::InvariantCulture)
  if ($parsedMatrixMaxDictionary -gt 0) {
    $matrixMaxDictionaryBytes = $parsedMatrixMaxDictionary
  }
}
if ($matrixMaxDictionaryBytes -lt 536870912) {
  throw "MatrixMaxDictionary must be at least 536870912 (512 MiB). Current: $matrixMaxDictionaryBytes"
}
if ([uint64]$matrixMaxDictionaryBytes -gt [uint64]4294967295) {
  throw "MatrixMaxDictionary must not exceed the LZMA2 dictionary maximum 0xFFFFFFFF. Current: $matrixMaxDictionaryBytes"
}

function Assert-BenchmarkWorkRoot([string]$Path, [bool]$RamBacked = $false) {
  $full = [IO.Path]::GetFullPath($Path)
  if ($full -match '^\\\\\?\\([A-Za-z]:\\.*)$') {
    $full = $Matches[1]
  }
  $repoRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
  if ($full.TrimEnd('\').Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Performance work root must not be the repository root: $full"
  }
  $pathRoot = [IO.Path]::GetPathRoot($full)
  if ([string]::IsNullOrWhiteSpace($pathRoot) -or $pathRoot.Length -lt 2 -or $pathRoot[1] -ne ':') {
    throw "Performance work dir must be on a local drive C:, D:, or explicit RAM root. Current: $full"
  }

  $drive = [char]::ToUpperInvariant($pathRoot[0])
  if ((-not $RamBacked) -and $drive -ne 'C' -and $drive -ne 'D') {
    throw "Performance work dir must be on SSD drive C: or D:. Set -WorkRoot or LZMA_PERF_WORKROOT. Current: $full"
  }
  if ($full.TrimEnd('\') -eq $pathRoot.TrimEnd('\')) {
    throw "Performance work root must be a dedicated directory, not a drive root: $full"
  }

  $driveRoot = "$drive`:\"
  $driveInfo = [IO.DriveInfo]::new($driveRoot)
  if ($RamBacked -and $driveInfo.DriveType -ne [IO.DriveType]::Ram) {
    throw "RAM performance work dir must be on a RAM drive. Current drive $driveRoot is $($driveInfo.DriveType). Use -WorkRoot or LZMA_PERF_WORKROOT for fixed SSD roots."
  }
  if ((-not $RamBacked) -and $driveInfo.DriveType -ne [IO.DriveType]::Fixed) {
    throw "Performance work dir must be on a local fixed SSD drive C: or D:. Current drive $driveRoot is $($driveInfo.DriveType)."
  }
  if ($RamBacked) {
    return $full
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
    throw "Could not confirm that benchmark drive $driveRoot is a local SSD. Set -WorkRoot or LZMA_PERF_WORKROOT to SSD drive C: or D:. $($_.Exception.Message)"
  }

  if (-not $physicalDisk) {
    throw "Could not map benchmark drive $driveRoot to a physical disk with SSD media type."
  }
  if ([string]$physicalDisk.MediaType -ne 'SSD') {
    throw "Performance work dir must be on SSD drive C: or D:. Drive $driveRoot maps to disk $diskNumber with media type '$($physicalDisk.MediaType)'."
  }

  return $full
}

function Initialize-BenchmarkWorkDir([string]$RootPath, [bool]$RamBacked = $false) {
  $workRoot = Assert-BenchmarkWorkRoot $RootPath $RamBacked
  $workDir = [IO.Path]::GetFullPath((Join-Path $workRoot 'lzma2-delphi-work'))
  $rootPrefix = $workRoot.TrimEnd('\') + '\'
  if (-not $workDir.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved benchmark work dir escapes the requested root: $workDir"
  }

  if (Test-Path -LiteralPath $workDir) {
    $sentinel = Join-Path $workDir '.lzma2-delphi-benchmark-workdir'
    if (-not (Test-Path -LiteralPath $sentinel)) {
      $children = @(Get-ChildItem -LiteralPath $workDir -Force -ErrorAction SilentlyContinue)
      if ($children.Count -gt 0) {
        throw "Refusing to reuse non-empty benchmark work dir without sentinel: $workDir"
      }
    }
  }

  New-Item -ItemType Directory -Force -Path $workDir | Out-Null
  $sentinel = Join-Path $workDir '.lzma2-delphi-benchmark-workdir'
  "Owned by tests/run-performance.ps1. Files in this directory may be overwritten by benchmark runs." |
    Set-Content -LiteralPath $sentinel -Encoding ASCII
  return $workDir
}

function Initialize-BenchmarkCorpusCache([string]$RootPath, [bool]$RamBacked = $false) {
  $validatedRoot = Assert-BenchmarkWorkRoot $RootPath $RamBacked
  $cacheDir = [IO.Path]::GetFullPath((Join-Path $validatedRoot 'lzma2-delphi-corpus-cache'))
  $rootPrefix = $validatedRoot.TrimEnd('\') + '\'
  if (-not $cacheDir.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved benchmark corpus cache escapes the requested root: $cacheDir"
  }

  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
  $sentinel = Join-Path $cacheDir '.lzma2-delphi-corpus-cache'
  "Owned by tests/run-performance.ps1. Deterministic benchmark corpora may be reused across runs." |
    Set-Content -LiteralPath $sentinel -Encoding ASCII
  return $cacheDir
}

function Get-DefaultBenchmarkWorkRoot {
  foreach ($drive in @('D:', 'C:')) {
    $driveRoot = "$drive\"
    if (Test-Path -LiteralPath $driveRoot) {
      return (Join-Path $driveRoot 'lzma2-delphi-perf')
    }
  }
  throw 'Performance work dir must be on local SSD drive C: or D:. Set -WorkRoot or LZMA_PERF_WORKROOT.'
}

function Invoke-GitText([string[]]$Arguments) {
  try {
    $output = & git -C $root @Arguments 2>$null
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -eq 0) {
      return ([string]$output).Trim()
    }
  } catch {
    $global:LASTEXITCODE = 0
  }
  return ''
}

function Get-GitCommit {
  return Invoke-GitText @('rev-parse', 'HEAD')
}

function Get-GitBranch {
  return Invoke-GitText @('rev-parse', '--abbrev-ref', 'HEAD')
}

function Get-GitRef([string]$Branch) {
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF)) {
    return $env:GITHUB_REF
  }
  if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch -ne 'HEAD') {
    return "refs/heads/$Branch"
  }
  return $Branch
}

$workRootIsRamBacked = $false
if (-not [string]::IsNullOrWhiteSpace($RamWorkRoot)) {
  $workRoot = [IO.Path]::GetFullPath($RamWorkRoot)
  $workRootIsRamBacked = $true
} elseif ([string]::IsNullOrWhiteSpace($WorkRoot)) {
  $workRoot = Get-DefaultBenchmarkWorkRoot
} else {
  $workRoot = [IO.Path]::GetFullPath($WorkRoot)
}
$work = Initialize-BenchmarkWorkDir $workRoot $workRootIsRamBacked
$corpusCacheRoot = Initialize-BenchmarkCorpusCache $workRoot $workRootIsRamBacked
$script:BenchmarkCorpusRecords = New-Object System.Collections.ArrayList
$outDir = Join-Path (Join-Path $root 'artifacts') 'perf'
$ciOutDir = Join-Path (Join-Path $root 'artifacts') 'ci'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
New-Item -ItemType Directory -Force -Path $ciOutDir | Out-Null
Write-Host "Performance work dir: $work"
Write-Host "Performance corpus cache: $corpusCacheRoot"
Write-Host "Performance work root is RAM-backed: $workRootIsRamBacked"

function Remove-BenchmarkItem([string[]]$Paths, [switch]$Recurse) {
  $workPrefix = $work.TrimEnd('\') + '\'
  foreach ($path in $Paths) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($workPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to delete outside benchmark work dir: $full"
    }
    if (Test-Path -LiteralPath $full) {
      if ($Recurse) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
      } else {
        Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function New-RepeatingFile([string]$Path, [int64]$Size) {
  $chunkSize = 1048576
  $bytes = New-Object byte[] $chunkSize
  $pattern = [byte[]](65, 66, 67, 68, 69)
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    $bytes[$i] = $pattern[$i % $pattern.Length]
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

function New-PatternFile([string]$Path, [int64]$Size, [string]$Kind) {
  $chunkSize = [int][Math]::Min([int64]1048576, [Math]::Max([int64]1, $Size))
  $bytes = New-Object byte[] $chunkSize
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($Kind -eq 'zero') {
      $bytes[$i] = 0
    } elseif ($Kind -eq 'ff') {
      $bytes[$i] = 255
    } elseif ($Kind -eq 'randomish') {
      $bytes[$i] = [byte]((17 + ($i * 131) + (($i -shr 4) * 29)) -band 0xff)
    } elseif ($Kind -eq 'mixed') {
      if (($i % 4096) -lt 2048) {
        $bytes[$i] = [byte](65 + ($i % 7))
      } else {
        $bytes[$i] = [byte](($i * 73 + 19) -band 0xff)
      }
    } else {
      $bytes[$i] = [byte](65 + ($i % 5))
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

function New-VaryingMixedFile([string]$Path, [int64]$Size) {
  $chunkSize = 1048576
  $bytes = New-Object byte[] $chunkSize
  $state = [uint32]0x12345678
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $remaining = $Size
    $written = [int64]0
    while ($remaining -gt 0) {
      $count = [int][Math]::Min([int64]$bytes.Length, $remaining)
      for ($i = 0; $i -lt $count; $i++) {
        $absolute = $written + [int64]$i
        if (($absolute % 8192) -lt 2048) {
          $bytes[$i] = [byte](65 + ($absolute % 7))
        } else {
          $nextState = ([uint64]$state * 1664525 + 1013904223) % 4294967296
          $state = [uint32]$nextState
          $bytes[$i] = [byte](($state -shr 24) -band 0xff)
        }
      }
      $stream.Write($bytes, 0, $count)
      $written += $count
      $remaining -= $count
    }
  }
  finally {
    $stream.Dispose()
  }
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-RelativePath([string]$BasePath, [string]$Path) {
  $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($base.Length).Replace('\', '/')
  }
  return $full.Replace('\', '/')
}

function ConvertTo-OrderedCorpusOptions($Options) {
  $ordered = [ordered]@{}
  if ($null -eq $Options) {
    return $ordered
  }

  if ($Options -is [System.Collections.IDictionary]) {
    foreach ($key in @($Options.Keys | Sort-Object)) {
      $ordered[[string]$key] = $Options[$key]
    }
    return $ordered
  }

  foreach ($property in @($Options.PSObject.Properties | Sort-Object Name)) {
    $ordered[[string]$property.Name] = $property.Value
  }
  return $ordered
}

function Get-BenchmarkCorpusCacheKey([string]$Kind, [int64]$Size, $Options = $null) {
  $identity = [ordered]@{
    schemaVersion = 1
    generator = $Kind
    sizeBytes = $Size
    options = ConvertTo-OrderedCorpusOptions $Options
    script = 'tests/run-performance.ps1'
    generatorVersion = 1
  }
  $json = $identity | ConvertTo-Json -Compress -Depth 8
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
  }
  finally {
    $sha.Dispose()
  }
}

function Assert-BenchmarkCorpusCachePath([string]$Path) {
  $cachePrefix = $corpusCacheRoot.TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify a path outside benchmark corpus cache: $full"
  }
  return $full
}

function Remove-BenchmarkCorpusCacheItem([string]$Path) {
  $full = Assert-BenchmarkCorpusCachePath $Path
  if (Test-Path -LiteralPath $full) {
    Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
  }
}

function Copy-BenchmarkCorpusFromCache([string]$CachePath, [string]$DestinationPath) {
  $parent = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  Remove-BenchmarkItem @($DestinationPath)
  try {
    New-Item -ItemType HardLink -Path $DestinationPath -Target $CachePath -ErrorAction Stop | Out-Null
  }
  catch {
    Copy-Item -LiteralPath $CachePath -Destination $DestinationPath -Force
  }
}

function Use-BenchmarkCorpusFile(
  [string]$Path,
  [int64]$Size,
  [string]$Kind,
  [scriptblock]$Generator,
  $Options = $null
) {
  $cacheKey = Get-BenchmarkCorpusCacheKey $Kind $Size $Options
  $cachePath = Join-Path $corpusCacheRoot "$cacheKey.bin"
  $cachePath = Assert-BenchmarkCorpusCachePath $cachePath
  $cacheHit = $false

  if (Test-Path -LiteralPath $cachePath) {
    $cacheItem = Get-Item -LiteralPath $cachePath
    if ([int64]$cacheItem.Length -eq $Size) {
      $cacheHit = $true
    } else {
      Remove-BenchmarkCorpusCacheItem $cachePath
    }
  }

  if (-not $cacheHit) {
    $tempPath = Join-Path $corpusCacheRoot "$cacheKey.tmp"
    $tempPath = Assert-BenchmarkCorpusCachePath $tempPath
    Remove-BenchmarkCorpusCacheItem $tempPath
    & $Generator $tempPath $Size
    $tempItem = Get-Item -LiteralPath $tempPath
    if ([int64]$tempItem.Length -ne $Size) {
      throw "Benchmark corpus generator wrote an unexpected byte count for $Kind. Expected $Size, got $($tempItem.Length)."
    }
    Move-Item -LiteralPath $tempPath -Destination $cachePath -Force
  }

  Copy-BenchmarkCorpusFromCache $cachePath $Path
  $cacheHash = Get-Sha256 $cachePath
  $relativeWorkPath = Get-RelativePath $workRoot $Path
  $relativeCachePath = Get-RelativePath $workRoot $cachePath
  for ($i = $script:BenchmarkCorpusRecords.Count - 1; $i -ge 0; $i--) {
    $existing = $script:BenchmarkCorpusRecords[$i]
    if ([string]$existing.workPath -eq $relativeWorkPath -and
        [int64]$existing.sizeBytes -eq $Size -and
        [string]$existing.kind -eq $Kind) {
      $script:BenchmarkCorpusRecords.RemoveAt($i)
    }
  }
  [void]$script:BenchmarkCorpusRecords.Add([pscustomobject][ordered]@{
    name = Split-Path -Leaf $Path
    kind = $Kind
    sizeBytes = $Size
    cacheKey = $cacheKey
    cacheHit = [bool]$cacheHit
    sha256 = $cacheHash
    cachePath = $relativeCachePath
    workPath = $relativeWorkPath
    options = ConvertTo-OrderedCorpusOptions $Options
  })
}

function Join-ProcessArguments([string[]]$Arguments) {
  $parts = @()
  foreach ($arg in $Arguments) {
    if ($arg -match '[\s"]') {
      $parts += '"' + ($arg -replace '"', '\"') + '"'
    } else {
      $parts += $arg
    }
  }
  return ($parts -join ' ')
}

function Invoke-TimedProcess([string]$Exe, [string[]]$Arguments, [string]$LogPath, [string]$WorkingDirectory) {
  $memorySampleIntervalMs = 100
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = Join-ProcessArguments $Arguments
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $psi
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $peak = 0L
  $peakPaged = 0L
  function Update-PeakMemory([Diagnostics.Process]$TargetProcess, [ref]$PeakValue, [ref]$PeakPagedValue) {
    try {
      $TargetProcess.Refresh()
      if ($TargetProcess.PeakWorkingSet64 -gt $PeakValue.Value) {
        $PeakValue.Value = $TargetProcess.PeakWorkingSet64
      }
      if ($TargetProcess.WorkingSet64 -gt $PeakValue.Value) {
        $PeakValue.Value = $TargetProcess.WorkingSet64
      }
      if ($TargetProcess.PeakPagedMemorySize64 -gt $PeakPagedValue.Value) {
        $PeakPagedValue.Value = $TargetProcess.PeakPagedMemorySize64
      }
      if ($TargetProcess.PagedMemorySize64 -gt $PeakPagedValue.Value) {
        $PeakPagedValue.Value = $TargetProcess.PagedMemorySize64
      }
    } catch {}
  }
  try {
    [void]$process.Start()
    Update-PeakMemory $process ([ref]$peak) ([ref]$peakPaged)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit($memorySampleIntervalMs)) {
      Update-PeakMemory $process ([ref]$peak) ([ref]$peakPaged)
    }
    $process.WaitForExit()
    $sw.Stop()
    Update-PeakMemory $process ([ref]$peak) ([ref]$peakPaged)
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    ($stdout + $stderr) | Set-Content -LiteralPath $LogPath -Encoding UTF8
    $exitCode = $process.ExitCode
  }
  finally {
    $process.Dispose()
  }
  if ($exitCode -ne 0) {
    $log = ''
    if (Test-Path -LiteralPath $LogPath) {
      $log = Get-Content -Raw -LiteralPath $LogPath
    }
    throw "$Exe failed with exit code $exitCode. Log: $log"
  }
  if ($peakPaged -lt 0) {
    $peakPaged = 0
  }
  return [pscustomobject]@{
    elapsedMs = $sw.ElapsedMilliseconds
    peakWorkingSetBytes = $peak
    peakPagedMemoryBytes = $peakPaged
    memoryMeasurementStatus = if ($peak -gt 0) { 'measured' } else { 'unavailable' }
  }
}

function Get-CliElapsedMs([string]$LogPath) {
  if (-not (Test-Path -LiteralPath $LogPath)) {
    return $null
  }
  $text = Get-Content -Raw -LiteralPath $LogPath
  $match = [regex]::Match($text, '(?m)^Elapsed ms:\s*(\d+)\s*$')
  if ($match.Success) {
    return [int64]$match.Groups[1].Value
  }
  return $null
}

function Get-CliDecodeDiagnostics([string]$LogPath) {
  $diagnostics = [ordered]@{
    requestedThreadCount = $null
    actualDecodeThreadCount = $null
    decodeIndependentUnitCount = $null
    actualMtDecode = $null
    inputSnapshot = $null
    decodeFallback = ''
  }
  if (-not (Test-Path -LiteralPath $LogPath)) {
    return [pscustomobject]$diagnostics
  }

  $text = Get-Content -Raw -LiteralPath $LogPath
  $patterns = @{
    requestedThreadCount = '(?m)^Decode requested threads:\s*(\d+)\s*$'
    actualDecodeThreadCount = '(?m)^Decode actual threads:\s*(\d+)\s*$'
    decodeIndependentUnitCount = '(?m)^Decode independent units:\s*(\d+)\s*$'
    actualMtDecode = '(?m)^Decode used MT:\s*(True|False)\s*$'
    inputSnapshot = '(?m)^Decode input snapshot:\s*(True|False)\s*$'
    decodeFallback = '(?m)^Decode fallback:\s*(\S+)\s*$'
  }

  foreach ($key in $patterns.Keys) {
    $match = [regex]::Match($text, $patterns[$key])
    if (-not $match.Success) {
      continue
    }
    if ($key -eq 'actualMtDecode' -or $key -eq 'inputSnapshot') {
      $diagnostics[$key] = [bool]::Parse($match.Groups[1].Value)
    } elseif ($key -eq 'decodeFallback') {
      $diagnostics[$key] = $match.Groups[1].Value
    } else {
      $diagnostics[$key] = [int]$match.Groups[1].Value
    }
  }
  return [pscustomobject]$diagnostics
}

function Get-CliEncodeDiagnostics([string]$LogPath) {
  $diagnostics = [ordered]@{
    requestedEncodeThreadCount = $null
    actualEncodeThreadCount = $null
    encodeBatchCount = $null
    encodeBlockCount = $null
    fastBytes = $null
    niceLen = $null
    cutValue = $null
    xzBlockSize = $null
    parserMode = ''
    matchFinderProfile = ''
    numHashBytes = $null
    copyFastPathCount = $null
    incompressibleFastPathCount = $null
    optimumParserEnabled = $null
    fullOptimumDecisionCount = $null
    encodeFallback = ''
  }
  if (-not (Test-Path -LiteralPath $LogPath)) {
    return [pscustomobject]$diagnostics
  }

  $text = Get-Content -Raw -LiteralPath $LogPath
  $patterns = @{
    requestedEncodeThreadCount = '(?m)^Encode requested threads:\s*(\d+)\s*$'
    actualEncodeThreadCount = '(?m)^Encode actual threads:\s*(\d+)\s*$'
    encodeBatchCount = '(?m)^Encode batches:\s*(\d+)\s*$'
    encodeBlockCount = '(?m)^Encode blocks:\s*(\d+)\s*$'
    fastBytes = '(?m)^Encode fast bytes:\s*(\d+)\s*$'
    niceLen = '(?m)^Encode nice len:\s*(\d+)\s*$'
    cutValue = '(?m)^Encode cut value:\s*(\d+)\s*$'
    xzBlockSize = '(?m)^Encode XZ block size:\s*(\d+)\s*$'
    parserMode = '(?m)^Encode parser mode:\s*(\S+)\s*$'
    matchFinderProfile = '(?m)^Encode match finder profile:\s*(\S+)\s*$'
    numHashBytes = '(?m)^Encode num hash bytes:\s*(\d+)\s*$'
    copyFastPathCount = '(?m)^Encode copy fast paths:\s*(\d+)\s*$'
    incompressibleFastPathCount = '(?m)^Encode incompressible fast paths:\s*(\d+)\s*$'
    optimumParserEnabled = '(?m)^Encode optimum parser enabled:\s*(True|False)\s*$'
    fullOptimumDecisionCount = '(?m)^Encode full optimum decisions:\s*(\d+)\s*$'
    encodeFallback = '(?m)^Encode fallback:\s*(\S+)\s*$'
  }

  foreach ($key in $patterns.Keys) {
    $match = [regex]::Match($text, $patterns[$key])
    if (-not $match.Success) {
      continue
    }
    if ($key -eq 'optimumParserEnabled') {
      $diagnostics[$key] = [bool]::Parse($match.Groups[1].Value)
    } elseif ($key -in @('parserMode', 'matchFinderProfile', 'encodeFallback')) {
      $diagnostics[$key] = $match.Groups[1].Value
    } else {
      $diagnostics[$key] = [int64]$match.Groups[1].Value
    }
  }
  return [pscustomobject]$diagnostics
}

function New-ElapsedStats([int64[]]$Values, [int]$WarmupCount = 0) {
  $cleanValues = @($Values | Where-Object { $_ -ge 0 })
  if ($cleanValues.Count -eq 0) {
    $cleanValues = @(0)
  }
  $sorted = @($cleanValues | Sort-Object)
  $count = $sorted.Count
  $median = if (($count % 2) -eq 1) {
    [double]$sorted[[int][Math]::Floor($count / 2)]
  } else {
    ([double]$sorted[($count / 2) - 1] + [double]$sorted[$count / 2]) / 2.0
  }
  $average = ($cleanValues | Measure-Object -Average).Average
  $variance = 0.0
  foreach ($value in $cleanValues) {
    $delta = [double]$value - [double]$average
    $variance += $delta * $delta
  }
  $stdev = if ($count -gt 1) { [Math]::Sqrt($variance / [double]$count) } else { 0.0 }

  return [pscustomobject]@{
    warmupCount = $WarmupCount
    measuredRunCount = $count
    bestElapsedMs = [int64]$sorted[0]
    medianElapsedMs = [Math]::Round($median, 3)
    minElapsedMs = [int64]$sorted[0]
    maxElapsedMs = [int64]$sorted[$count - 1]
    stdevElapsedMs = [Math]::Round($stdev, 3)
  }
}

function Get-ToolFirstLineVersion([string]$Path, [string[]]$Arguments, [string]$Fallback) {
  try {
    $output = & $Path @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    $lines = @($output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($exitCode -eq 0 -and $lines.Count -gt 0) {
      return $lines[0].Trim()
    }
  } catch {}
  return $Fallback
}

function Get-Throughput([long]$Bytes, [long]$ElapsedMs) {
  if ($ElapsedMs -le 0) {
    return 0
  }
  return [Math]::Round(($Bytes / 1048576.0) / ($ElapsedMs / 1000.0), 3)
}

function Get-DecimalThroughput([long]$Bytes, [double]$ElapsedMs) {
  if ($ElapsedMs -le 0) {
    return 0
  }
  return [Math]::Round(($Bytes / 1000000.0) / ($ElapsedMs / 1000.0), 3)
}

function ConvertTo-InvariantDouble([string]$Value) {
  return [double]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
}

$script:BenchmarkRowSequence = 0
$script:BenchmarkSamples = New-Object System.Collections.ArrayList
$script:BenchmarkInputHashCache = @{}

function Get-BenchmarkContainer([string]$Mode) {
  if ($Mode -like 'xz*' -or $Mode -like '*-xz-*') {
    return 'xz'
  }
  if ($Mode -like 'raw-lzma2*') {
    return 'raw-lzma2'
  }
  if ($Mode -like 'raw-lzma*') {
    return 'raw-lzma'
  }
  return 'raw'
}

function Get-BenchmarkCodec([string]$Mode) {
  if ($Mode -like '*lzma2*' -or $Mode -like 'xz-*') {
    return 'lzma2'
  }
  if ($Mode -like '*lzma*') {
    return 'lzma'
  }
  return 'lzma2'
}

function Format-BenchmarkSampleList([object[]]$Values) {
  return (@($Values | ForEach-Object {
      if ($_ -is [double] -or $_ -is [single] -or $_ -is [decimal]) {
        ([double]$_).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
      } else {
        ([int64]$_).ToString([System.Globalization.CultureInfo]::InvariantCulture)
      }
    }) -join ';')
}

function Get-BenchmarkRowId([string]$Tool, [string]$Operation, [string]$Mode, [int]$Threads) {
  $script:BenchmarkRowSequence++
  $suffix = "$Tool-$Operation-$Mode-${Threads}t" -replace '[^A-Za-z0-9_.-]+', '-'
  return ('{0:000000}-{1}' -f $script:BenchmarkRowSequence, $suffix.Trim('-'))
}

function Get-BenchmarkInputSha256([string]$InputName) {
  if ([string]::IsNullOrWhiteSpace($InputName)) {
    return ''
  }

  $candidates = @()
  if ([IO.Path]::IsPathRooted($InputName)) {
    $candidates += $InputName
  } else {
    $candidates += (Join-Path $work $InputName)
    $candidates += (Join-Path $root $InputName)
  }

  foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      continue
    }
    $full = [IO.Path]::GetFullPath($candidate)
    if (-not $script:BenchmarkInputHashCache.ContainsKey($full)) {
      $script:BenchmarkInputHashCache[$full] = Get-Sha256 $full
    }
    return $script:BenchmarkInputHashCache[$full]
  }

  return ''
}

function Get-NormalizedBenchmarkCommand([string]$Tool, [string]$Operation, [string]$Container) {
  $verb = if ($Operation -eq 'encode') { 'compress' } elseif ($Operation -eq 'decode') { 'decompress' } else { $Operation }
  switch ($Tool) {
    'delphi-native' { return "Lzma2.exe $verb $Container" }
    '7zr-sdk' {
      if ($Operation -eq 'encode') {
        return "7zr.exe a -t$Container"
      }
      return '7zr.exe x'
    }
    'xz-utils' {
      if ($Operation -eq 'encode') {
        return "xz --format=$Container"
      }
      return "xz --decompress --format=$Container"
    }
    'lzma-sdk' {
      if ($Operation -eq 'encode') {
        return 'lzma.exe e'
      }
      return 'lzma.exe d'
    }
    default { return "$Tool $Operation $Container" }
  }
}

function Format-NormalizedOptionValue($Value) {
  if ($null -eq $Value) {
    return 'null'
  }
  if ($Value -is [bool]) {
    return ([string]$Value).ToLowerInvariant()
  }
  return (([string]$Value) -replace '\s+', ' ' -replace ';', ',').Trim()
}

function Get-NormalizedBenchmarkOptions(
  [string]$Operation,
  [string]$Mode,
  [string]$Container,
  [string]$Codec,
  [int]$Level,
  [int]$Threads,
  [int64]$Dictionary,
  [string]$Check,
  [object]$DecodeDiagnostics,
  [object]$EncodeDiagnostics
) {
  $options = [ordered]@{
    operation = $Operation
    mode = $Mode
    container = $Container
    codec = $Codec
    level = $Level
    dictionary = $Dictionary
    lc = 3
    lp = 0
    pb = 2
    threads = $Threads
    check = $Check
  }
  if ($EncodeDiagnostics) {
    $options['requestedEncodeThreadCount'] = $EncodeDiagnostics.requestedEncodeThreadCount
    $options['actualEncodeThreadCount'] = $EncodeDiagnostics.actualEncodeThreadCount
    $options['parserMode'] = $EncodeDiagnostics.parserMode
    $options['matchFinderProfile'] = $EncodeDiagnostics.matchFinderProfile
    $options['numHashBytes'] = $EncodeDiagnostics.numHashBytes
    $options['fastBytes'] = $EncodeDiagnostics.fastBytes
    $options['niceLen'] = $EncodeDiagnostics.niceLen
    $options['cutValue'] = $EncodeDiagnostics.cutValue
    $options['xzBlockSize'] = $EncodeDiagnostics.xzBlockSize
  }
  if ($DecodeDiagnostics) {
    $options['requestedDecodeThreadCount'] = $DecodeDiagnostics.requestedThreadCount
    $options['actualDecodeThreadCount'] = $DecodeDiagnostics.actualDecodeThreadCount
    $options['actualMtDecode'] = $DecodeDiagnostics.actualMtDecode
    $options['decodeIndependentUnitCount'] = $DecodeDiagnostics.decodeIndependentUnitCount
    $options['decodeFallback'] = $DecodeDiagnostics.decodeFallback
  }

  return (($options.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$(Format-NormalizedOptionValue $_.Value)"
      }) -join ';')
}

function Add-BenchmarkSampleRows(
  [pscustomobject]$Row,
  [int64[]]$ProcessElapsedSamples,
  [int64]$ThroughputBytes
) {
  for ($sampleIndex = 0; $sampleIndex -lt $ProcessElapsedSamples.Count; $sampleIndex++) {
    $sampleElapsedMs = [int64]$ProcessElapsedSamples[$sampleIndex]
    [void]$script:BenchmarkSamples.Add([pscustomobject][ordered]@{
      rowId = $Row.rowId
      sampleIndex = $sampleIndex + 1
      timestamp = $Row.timestamp
      tool = $Row.tool
      toolVersion = $Row.toolVersion
      operation = $Row.operation
      mode = $Row.mode
      container = $Row.container
      codec = $Row.codec
      level = $Row.level
      dictionary = $Row.dictionary
      lc = $Row.lc
      lp = $Row.lp
      pb = $Row.pb
      parserMode = $Row.parserMode
      matchFinderProfile = $Row.matchFinderProfile
      threads = $Row.threads
      threadCount = $Row.threadCount
      inputName = $Row.inputName
      inputSha256 = $Row.inputSha256
      inputBytes = $Row.inputBytes
      outputBytes = $Row.outputBytes
      elapsedMs = $sampleElapsedMs
      elapsedSource = 'process-wall-sample'
      throughputMiBs = Get-Throughput $ThroughputBytes $sampleElapsedMs
      throughputMBs = Get-DecimalThroughput $ThroughputBytes $sampleElapsedMs
      normalizedCommand = $Row.normalizedCommand
      normalizedOptions = $Row.normalizedOptions
    })
  }
}

function Add-Row(
  [System.Collections.ArrayList]$Rows,
  [string]$Tool,
  [string]$ToolVersion,
  [string]$Operation,
  [string]$Mode,
  [int]$Level,
  [int]$Threads,
  [int64]$Dictionary,
  [string]$InputName,
  [int64]$InputBytes,
  [int64]$OutputBytes,
  [int64]$ElapsedMs,
  [int64]$PeakWorkingSetBytes,
  [int64]$PeakPagedMemoryBytes,
  [string]$Check,
  [string]$Notes,
  [pscustomobject]$Metadata,
  [object]$ProcessElapsedMs = $null,
  [string]$ElapsedSource = 'process-wall',
  [string]$Acceptance = '',
  [object]$DecodeDiagnostics = $null,
  [object]$EncodeDiagnostics = $null,
  [object]$Stats = $null,
  [object[]]$ProcessElapsedSamples = $null
) {
  $throughputBytes = $InputBytes
  $ratio = $null
  $memoryMeasurementStatus = if ($PeakWorkingSetBytes -gt 0) { 'measured' } else { 'unavailable' }
  $effectiveProcessElapsedMs = if ($null -eq $ProcessElapsedMs) { $ElapsedMs } else { [int64]$ProcessElapsedMs }
  $sampleElapsedValues = @()
  if ($null -ne $ProcessElapsedSamples) {
    $sampleElapsedValues = @($ProcessElapsedSamples | ForEach-Object { [int64]$_ } | Where-Object { $_ -ge 0 })
  }
  if ($sampleElapsedValues.Count -eq 0) {
    $sampleElapsedValues = @([int64]$effectiveProcessElapsedMs)
  }
  if ($null -eq $Stats) {
    $Stats = New-ElapsedStats $sampleElapsedValues
  }
  if ($InputBytes -gt 0) {
    $ratio = [Math]::Round($OutputBytes / [double]$InputBytes, 6)
  }
  if ($Operation -eq 'decode') {
    $throughputBytes = $OutputBytes
  }
  $sampleThroughputValues = @($sampleElapsedValues | ForEach-Object { Get-Throughput $throughputBytes ([int64]$_) })
  $sampleDecimalThroughputValues = @($sampleElapsedValues | ForEach-Object { Get-DecimalThroughput $throughputBytes ([int64]$_) })
  $rowId = Get-BenchmarkRowId $Tool $Operation $Mode $Threads
  $container = Get-BenchmarkContainer $Mode
  $codec = Get-BenchmarkCodec $Mode
  $inputSha256 = Get-BenchmarkInputSha256 $InputName
  $normalizedCommand = Get-NormalizedBenchmarkCommand $Tool $Operation $container
  $normalizedOptions = Get-NormalizedBenchmarkOptions $Operation $Mode $container $codec $Level $Threads $Dictionary $Check $DecodeDiagnostics $EncodeDiagnostics
  $row = [pscustomobject][ordered]@{
    rowId = $rowId
    timestamp = (Get-Date -Format 'yyyy-MM-dd')
    tool = $Tool
    toolVersion = $ToolVersion
    operation = $Operation
    mode = $Mode
    container = $container
    codec = $codec
    level = $Level
    threads = $Threads
    threadCount = $Threads
    dictionary = $Dictionary
    lc = 3
    lp = 0
    pb = 2
    inputName = $InputName
    inputSha256 = $inputSha256
    inputBytes = $InputBytes
    outputBytes = $OutputBytes
    compressionRatio = $ratio
    elapsedMs = $ElapsedMs
    processElapsedMs = $effectiveProcessElapsedMs
    elapsedSource = $ElapsedSource
    peakWorkingSetBytes = $PeakWorkingSetBytes
    peakPagedMemoryBytes = $PeakPagedMemoryBytes
    memoryMeasurementStatus = $memoryMeasurementStatus
    throughputMiBs = (Get-Throughput $throughputBytes $ElapsedMs)
    processThroughputMiBs = (Get-Throughput $throughputBytes $effectiveProcessElapsedMs)
    throughputMBs = (Get-DecimalThroughput $throughputBytes $ElapsedMs)
    processThroughputMBs = (Get-DecimalThroughput $throughputBytes $effectiveProcessElapsedMs)
    baselineTool = ''
    baselineThroughputMiBs = $null
    throughputRatioPct = $null
    comparisonMetric = ''
    normalizedCommand = $normalizedCommand
    normalizedOptions = $normalizedOptions
    acceptance = $Acceptance
    check = $Check
    notes = $Notes
    buildConfig = $Metadata.buildConfig
    gitCommit = $Metadata.gitCommit
    gitBranch = $Metadata.gitBranch
    gitRef = $Metadata.gitRef
    allocationCount = $null
    allocationCountStatus = 'unavailable'
    allocationCountUnavailableReason = 'FastMM allocation hook is not enabled for process-level benchmark rows.'
    elapsedSamplesMs = Format-BenchmarkSampleList $sampleElapsedValues
    throughputSamplesMiBs = Format-BenchmarkSampleList $sampleThroughputValues
    throughputSamplesMBs = Format-BenchmarkSampleList $sampleDecimalThroughputValues
    warmupCount = $Stats.warmupCount
    measuredRunCount = $Stats.measuredRunCount
    bestElapsedMs = $Stats.bestElapsedMs
    medianElapsedMs = $Stats.medianElapsedMs
    minElapsedMs = $Stats.minElapsedMs
    maxElapsedMs = $Stats.maxElapsedMs
    stdevElapsedMs = $Stats.stdevElapsedMs
    cpu = $Metadata.cpu
    logicalProcessorCount = $Metadata.logicalProcessorCount
    physicalCoreCount = $Metadata.physicalCoreCount
    os = $Metadata.os
    compiler = $Metadata.compiler
    sdkVersion = $Metadata.sdkVersion
    requestedThreadCount = if ($DecodeDiagnostics -and $null -ne $DecodeDiagnostics.requestedThreadCount) { $DecodeDiagnostics.requestedThreadCount } else { $Threads }
    actualDecodeThreadCount = if ($DecodeDiagnostics) { $DecodeDiagnostics.actualDecodeThreadCount } else { $null }
    decodeIndependentUnitCount = if ($DecodeDiagnostics) { $DecodeDiagnostics.decodeIndependentUnitCount } else { $null }
    actualMtDecode = if ($DecodeDiagnostics) { $DecodeDiagnostics.actualMtDecode } else { $null }
    inputSnapshot = if ($DecodeDiagnostics) { $DecodeDiagnostics.inputSnapshot } else { $null }
    decodeFallback = if ($DecodeDiagnostics) { $DecodeDiagnostics.decodeFallback } else { '' }
    requestedEncodeThreadCount = if ($EncodeDiagnostics -and $null -ne $EncodeDiagnostics.requestedEncodeThreadCount) { $EncodeDiagnostics.requestedEncodeThreadCount } else { $Threads }
    actualEncodeThreadCount = if ($EncodeDiagnostics) { $EncodeDiagnostics.actualEncodeThreadCount } else { $null }
    encodeBatchCount = if ($EncodeDiagnostics) { $EncodeDiagnostics.encodeBatchCount } else { $null }
    encodeBlockCount = if ($EncodeDiagnostics) { $EncodeDiagnostics.encodeBlockCount } else { $null }
    fastBytes = if ($EncodeDiagnostics) { $EncodeDiagnostics.fastBytes } else { $null }
    niceLen = if ($EncodeDiagnostics) { $EncodeDiagnostics.niceLen } else { $null }
    cutValue = if ($EncodeDiagnostics) { $EncodeDiagnostics.cutValue } else { $null }
    xzBlockSize = if ($EncodeDiagnostics) { $EncodeDiagnostics.xzBlockSize } else { $null }
    parserMode = if ($EncodeDiagnostics) { $EncodeDiagnostics.parserMode } else { '' }
    matchFinderProfile = if ($EncodeDiagnostics) { $EncodeDiagnostics.matchFinderProfile } else { '' }
    numHashBytes = if ($EncodeDiagnostics) { $EncodeDiagnostics.numHashBytes } else { $null }
    copyFastPathCount = if ($EncodeDiagnostics) { $EncodeDiagnostics.copyFastPathCount } else { $null }
    incompressibleFastPathCount = if ($EncodeDiagnostics) { $EncodeDiagnostics.incompressibleFastPathCount } else { $null }
    optimumParserEnabled = if ($EncodeDiagnostics) { $EncodeDiagnostics.optimumParserEnabled } else { $null }
    fullOptimumDecisionCount = if ($EncodeDiagnostics) { $EncodeDiagnostics.fullOptimumDecisionCount } else { $null }
    encodeFallback = if ($EncodeDiagnostics) { $EncodeDiagnostics.encodeFallback } else { '' }
  }
  [void]$Rows.Add($row)
  Add-BenchmarkSampleRows $row $sampleElapsedValues $throughputBytes
}

function Find-PerfRow(
  [System.Collections.ArrayList]$Rows,
  [string]$Tool,
  [string]$Operation,
  [string]$Mode,
  [int]$Threads,
  [string]$InputName = '',
  [int]$Level = -1,
  [int64]$Dictionary = -1,
  [string]$Check = ''
) {
  foreach ($row in $Rows) {
    if ($row.tool -eq $Tool -and
        $row.operation -eq $Operation -and
        $row.mode -eq $Mode -and
        [int]$row.threads -eq $Threads -and
        ($InputName -eq '' -or $row.inputName -eq $InputName) -and
        ($Level -lt 0 -or [int]$row.level -eq $Level) -and
        ($Dictionary -lt 0 -or [int64]$row.dictionary -eq $Dictionary) -and
        ($Check -eq '' -or $row.check -eq $Check)) {
      return $row
    }
  }
  return $null
}

function Set-PerfComparison(
  [pscustomobject]$Row,
  [pscustomobject]$Baseline,
  [string]$BaselineTool,
  [double]$ThresholdPct,
  [string]$PassLabel,
  [string]$FailLabel,
  [string]$Metric = 'throughputMiBs'
) {
  if (-not $Row -or -not $Baseline -or [double]$Baseline.$Metric -le 0) {
    return
  }

  $ratio = [Math]::Round(([double]$Row.$Metric / [double]$Baseline.$Metric) * 100.0, 1)
  $Row.baselineTool = $BaselineTool
  $Row.baselineThroughputMiBs = [double]$Baseline.$Metric
  $Row.throughputRatioPct = $ratio
  $Row.comparisonMetric = $Metric
  if ($ratio -ge $ThresholdPct) {
    $Row.acceptance = $PassLabel
  } else {
    $Row.acceptance = $FailLabel
  }
}

function Set-PerfComparisonBestOf(
  [pscustomobject]$Row,
  [object[]]$Baselines,
  [string]$BaselineTool,
  [double]$ThresholdPct,
  [string]$PassLabel,
  [string]$FailLabel,
  [string]$Metric = 'throughputMiBs'
) {
  $bestBaseline = $null
  foreach ($baseline in $Baselines) {
    if ($baseline -and [double]$baseline.$Metric -gt 0) {
      if ((-not $bestBaseline) -or ([double]$baseline.$Metric -gt [double]$bestBaseline.$Metric)) {
        $bestBaseline = $baseline
      }
    }
  }

  Set-PerfComparison $Row $bestBaseline $BaselineTool $ThresholdPct $PassLabel $FailLabel $Metric
}

function Set-ReleaseRepeatMtComparison(
  [pscustomobject]$Row,
  [pscustomobject]$Baseline,
  [pscustomobject]$SdkBaseline
) {
  Set-PerfComparison $Row $Baseline 'delphi-native level1 1-thread encode on repeat5-256m.bin' 100.0 'mt-release-speedup' 'mt-release-no-speedup' 'processThroughputMiBs'
  if (-not $Row -or -not $Baseline -or -not $SdkBaseline) {
    return
  }
  if ($Row.acceptance -ne 'mt-release-no-speedup') {
    return
  }
  if ([double]$SdkBaseline.processThroughputMiBs -le 0) {
    return
  }

  $sdkThroughput = [double]$SdkBaseline.processThroughputMiBs
  if ([double]$Baseline.processThroughputMiBs -ge $sdkThroughput -and
      [double]$Row.processThroughputMiBs -ge $sdkThroughput) {
    $Row.acceptance = 'mt-release-fastpath-saturated'
    $note = 'Single-thread repeat fast path is already above the SDK baseline; this threaded run remains above SDK but below the saturated 1-thread fast path.'
    if ([string]::IsNullOrWhiteSpace([string]$Row.notes)) {
      $Row.notes = $note
    } else {
      $Row.notes = "$($Row.notes) $note"
    }
  }
}

function Set-ReleaseMixedMtComparison(
  [pscustomobject]$Row,
  [pscustomobject]$Baseline,
  [int]$Threads
) {
  Set-PerfComparison $Row $Baseline 'delphi-native level1 1-thread encode on mixed-256m.bin' 80.0 'mt-release-mixed-overhead-bounded' 'mt-release-mixed-no-speedup' 'processThroughputMiBs'
  if ($Row -and $Row.acceptance -eq 'mt-release-mixed-overhead-bounded') {
    Add-PerfRowNote $Row 'The mixed-corpus MT release gate records bounded scheduler overhead when active worker throughput stays within 80% of the 1-thread baseline; this is not reported as MT speedup.'
  }
}

function Add-PerfRowNote([pscustomobject]$Row, [string]$Note) {
  if (-not $Row -or [string]::IsNullOrWhiteSpace($Note)) {
    return
  }
  if ([string]::IsNullOrWhiteSpace([string]$Row.notes)) {
    $Row.notes = $Note
  } else {
    $Row.notes = "$($Row.notes) $Note"
  }
}

function Add-PerformanceComparisons([System.Collections.ArrayList]$Rows) {
  $delphiEncode = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' 1 'repeat5-256m.bin' 1 1048576 'crc32'
  if (-not $delphiEncode) {
    $delphiEncode = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' 1 'repeat5-4m.bin' 1 1048576 'crc32'
  }
  if (-not $delphiEncode) {
    $delphiEncode = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' 1 'repeat5-1m.bin' 1 1048576 'crc32'
  }
  $delphiDecode = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-level1' 1 'repeat5-256m.7zr.xz' 1 1048576 'crc32'
  if (-not $delphiDecode) {
    $delphiDecode = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-level1' 1 'repeat5-4m.7zr.xz' 1 1048576 'crc32'
  }
  $delphiMtBaseline = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' 1 'repeat5-4m.bin' 1 1048576 'crc64'
  $delphiMtEncode = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' 4 'repeat5-4m.bin' 1 1048576 'crc64'
  $sevenEncode = Find-PerfRow $Rows '7zr-sdk' 'encode' 'xz-lzma2-level1' 1 'repeat5-256m.bin' 1 1048576 'crc32'
  if (-not $sevenEncode) {
    $sevenEncode = Find-PerfRow $Rows '7zr-sdk' 'encode' 'xz-lzma2-level1' 1 'repeat5-4m.bin' 1 1048576 'crc32'
  }
  if (-not $sevenEncode) {
    $sevenEncode = Find-PerfRow $Rows '7zr-sdk' 'encode' 'xz-lzma2-level1' 1 'repeat5-1m.bin' 1 1048576 'crc32'
  }
  $sevenDecode = Find-PerfRow $Rows '7zr-sdk' 'decode' 'xz-lzma2-level1' 1 'repeat5-256m.7zr.xz' 1 1048576 'crc32'
  if (-not $sevenDecode) {
    $sevenDecode = Find-PerfRow $Rows '7zr-sdk' 'decode' 'xz-lzma2-level1' 1 'repeat5-4m.7zr.xz' 1 1048576 'crc32'
  }
  $delphiRawDecode = Find-PerfRow $Rows 'delphi-native' 'decode' 'raw-lzma2-level1' 1 'repeat5-256m.xzraw-src.bin.rawlzma2' 1 1048576 'none'
  $delphiRawMtBaseline = Find-PerfRow $Rows 'delphi-native' 'decode' 'raw-lzma2-level1' 1 'raw-repeat5-256m-l1-1t.delphi.lzma2' 1 1048576 'none'
  $delphiRawMtDecode = Find-PerfRow $Rows 'delphi-native' 'decode' 'raw-lzma2-level1' 4 'raw-repeat5-256m-l1-4t.delphi.lzma2' 1 1048576 'none'
  $delphiXzMtBaseline = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-multiblock-level1' 1 '' 1 1048576 'crc32'
  $delphiGeneratedXzMtBaseline = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-delphi-multiblock-level1' 1 '' 1 1048576 'crc32'
  $delphiPatternedXzMtBaseline = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-delphi-patterned-multiblock-level1' 1 '' 1 1048576 'crc32'
  $xzRawDecode = Find-PerfRow $Rows 'xz-utils' 'decode' 'raw-lzma2-level1' 1 'repeat5-256m.xzraw-src.bin.rawlzma2' 1 1048576 'none'
  $xzRawBaselineTool = 'xz-utils raw LZMA2 decode on repeat5-256m corpus'
  if ($xzRawDecode -and $xzRawDecode.toolVersion) {
    $xzRawBaselineTool = "$($xzRawDecode.toolVersion) raw LZMA2 decode on repeat5-256m corpus"
  }

  $sdkEncodePassLabel = 'meets-100pct-sdk-smoke'
  $sdkEncodeFailLabel = 'below-100pct-sdk-smoke'
  if ($delphiEncode -and
      [string]$delphiEncode.inputName -like 'repeat5-*' -and
      [string]$delphiEncode.parserMode -eq 'sdk-profile' -and
      [string]$delphiEncode.optimumParserEnabled -eq 'False' -and
      [int64]$delphiEncode.fullOptimumDecisionCount -eq 0) {
    $sdkEncodePassLabel = 'meets-100pct-sdk-periodic-fastpath'
    $sdkEncodeFailLabel = 'below-100pct-sdk-periodic-fastpath'
    Add-PerfRowNote $delphiEncode 'Comparison uses the repeated-corpus periodic fast path; it is not SDK-profile optimum-parser parity evidence.'
  }
  Set-PerfComparison $delphiEncode $sevenEncode "7zr-sdk $script:LzmaSdkVersion xz level1 encode" 100.0 $sdkEncodePassLabel $sdkEncodeFailLabel 'processThroughputMiBs'
  Set-PerfComparison $delphiDecode $sevenDecode "7zr-sdk $script:LzmaSdkVersion xz level1 decode on repeat5 corpus" 100.0 'meets-100pct-sdk-codec' 'below-100pct-sdk-codec' 'throughputMiBs'
  Set-PerfComparison $delphiRawDecode $xzRawDecode $xzRawBaselineTool 80.0 'meets-80pct-xz-raw-lzma2' 'below-80pct-xz-raw-lzma2' 'throughputMiBs'
  if ($delphiRawMtDecode -and
      [string]$delphiRawMtDecode.actualMtDecode -eq 'False' -and
      [string]$delphiRawMtDecode.decodeFallback -eq 'insufficient-work') {
    $delphiRawMtDecode.acceptance = 'mt-decode-fallback-insufficient-work'
    $delphiRawMtDecode.comparisonMetric = 'processThroughputMiBs'
    if ($delphiRawMtBaseline -and [double]$delphiRawMtBaseline.processThroughputMiBs -gt 0) {
      $delphiRawMtDecode.baselineTool = 'delphi-native raw LZMA2 1-thread decode on repeat5-256m corpus'
      $delphiRawMtDecode.baselineThroughputMiBs = [double]$delphiRawMtBaseline.processThroughputMiBs
      $delphiRawMtDecode.throughputRatioPct = [Math]::Round(
        ([double]$delphiRawMtDecode.processThroughputMiBs / [double]$delphiRawMtBaseline.processThroughputMiBs) * 100.0,
        1)
    }
  } else {
    Set-PerfComparison $delphiRawMtDecode $delphiRawMtBaseline 'delphi-native raw LZMA2 1-thread decode on repeat5-256m corpus' 100.0 'mt-decode-speedup' 'mt-decode-no-speedup' 'processThroughputMiBs'
  }
  Set-PerfComparison $delphiMtEncode $delphiMtBaseline 'delphi-native level1 1-thread encode on repeat5-4m.bin' 50.0 'mt-smoke-overhead-bounded' 'mt-smoke-overhead-regression'
  foreach ($xzMtThreads in @(2, 4, 8, 16)) {
    $delphiXzMtDecode = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-multiblock-level1' $xzMtThreads '' 1 1048576 'crc32'
    if ($delphiXzMtDecode) {
      if ([string]$delphiXzMtDecode.actualMtDecode -eq 'True' -and
          [int]$delphiXzMtDecode.actualDecodeThreadCount -gt 1 -and
          [int]$delphiXzMtDecode.decodeIndependentUnitCount -gt 1 -and
          [string]$delphiXzMtDecode.decodeFallback -eq 'none') {
        $xzMtBaselineName = if ($delphiXzMtBaseline -and $delphiXzMtBaseline.inputName) { $delphiXzMtBaseline.inputName } else { 'multi-block XZ corpus' }
        Set-PerfComparison $delphiXzMtDecode $delphiXzMtBaseline "delphi-native XZ 1-thread decode on $xzMtBaselineName" 100.0 'xz-mt-decode-speedup' 'xz-mt-decode-no-speedup' 'processThroughputMiBs'
        if (-not $delphiXzMtDecode.acceptance) {
          $delphiXzMtDecode.acceptance = 'xz-mt-decode-no-comparison'
        }
      } else {
        $delphiXzMtDecode.acceptance = 'xz-mt-decode-inactive'
      }
    }
  }
  foreach ($xzMtThreads in @(2, 4, 8, 16)) {
    $delphiGeneratedXzMtDecode = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-delphi-multiblock-level1' $xzMtThreads '' 1 1048576 'crc32'
    if ($delphiGeneratedXzMtDecode) {
      if ([string]$delphiGeneratedXzMtDecode.actualMtDecode -eq 'True' -and
          [int]$delphiGeneratedXzMtDecode.actualDecodeThreadCount -gt 1 -and
          [int]$delphiGeneratedXzMtDecode.decodeIndependentUnitCount -gt 1 -and
          [string]$delphiGeneratedXzMtDecode.decodeFallback -eq 'none') {
        $xzMtBaselineName = if ($delphiGeneratedXzMtBaseline -and $delphiGeneratedXzMtBaseline.inputName) { $delphiGeneratedXzMtBaseline.inputName } else { 'Delphi-generated multi-block XZ corpus' }
        Set-PerfComparison $delphiGeneratedXzMtDecode $delphiGeneratedXzMtBaseline "delphi-native XZ 1-thread decode on $xzMtBaselineName" 100.0 'xz-delphi-mt-decode-speedup' 'xz-delphi-mt-decode-no-speedup' 'processThroughputMiBs'
        if (-not $delphiGeneratedXzMtDecode.acceptance) {
          $delphiGeneratedXzMtDecode.acceptance = 'xz-delphi-mt-decode-no-comparison'
        }
      } else {
        $delphiGeneratedXzMtDecode.acceptance = 'xz-delphi-mt-decode-inactive'
      }
    }
  }
  foreach ($xzMtThreads in @(2, 4, 8, 16)) {
    $delphiPatternedXzMtDecode = Find-PerfRow $Rows 'delphi-native' 'decode' 'xz-delphi-patterned-multiblock-level1' $xzMtThreads '' 1 1048576 'crc32'
    if ($delphiPatternedXzMtDecode) {
      if ([string]$delphiPatternedXzMtDecode.actualMtDecode -eq 'True' -and
          [int]$delphiPatternedXzMtDecode.actualDecodeThreadCount -gt 1 -and
          [int]$delphiPatternedXzMtDecode.decodeIndependentUnitCount -gt 1 -and
          [string]$delphiPatternedXzMtDecode.decodeFallback -eq 'none') {
        $xzMtBaselineName = if ($delphiPatternedXzMtBaseline -and $delphiPatternedXzMtBaseline.inputName) { $delphiPatternedXzMtBaseline.inputName } else { 'Delphi-generated patterned multi-block XZ corpus' }
        Set-PerfComparison $delphiPatternedXzMtDecode $delphiPatternedXzMtBaseline "delphi-native XZ 1-thread decode on $xzMtBaselineName" 100.0 'xz-delphi-patterned-mt-decode-speedup' 'xz-delphi-patterned-mt-decode-no-speedup' 'processThroughputMiBs'
        if (-not $delphiPatternedXzMtDecode.acceptance) {
          $delphiPatternedXzMtDecode.acceptance = 'xz-delphi-patterned-mt-decode-no-comparison'
        }
      } else {
        $delphiPatternedXzMtDecode.acceptance = 'xz-delphi-patterned-mt-decode-inactive'
      }
    }
  }

  $releaseMtBaseline = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' 1 'repeat5-256m.bin' 1 1048576 'crc64'
  $releaseMixedMtBaseline = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' 1 'mixed-256m.bin' 1 1048576 'crc64'
  $releaseComparisonThreads = @(2, 4, 8, 16)
  if ([Environment]::ProcessorCount -gt 16) {
    $releaseComparisonThreads = @($releaseComparisonThreads + [Environment]::ProcessorCount | Sort-Object -Unique)
  }
  foreach ($releaseThreads in $releaseComparisonThreads) {
    $releaseMtEncode = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' $releaseThreads 'repeat5-256m.bin' 1 1048576 'crc64'
    Set-ReleaseRepeatMtComparison $releaseMtEncode $releaseMtBaseline $sevenEncode
  }

  foreach ($releaseThreads in $releaseComparisonThreads) {
    $releaseMixedMtEncode = Find-PerfRow $Rows 'delphi-native' 'encode' 'xz-level1' $releaseThreads 'mixed-256m.bin' 1 1048576 'crc64'
    Set-ReleaseMixedMtComparison $releaseMixedMtEncode $releaseMixedMtBaseline $releaseThreads
  }
}

function Write-OptimizationPlan(
  [System.Collections.ArrayList]$Rows,
  [string]$Path,
  [pscustomobject]$Metadata
) {
  $flagged = @($Rows | Where-Object {
    $_.acceptance -like 'below-*' -or
    $_.acceptance -like '*-no-speedup' -or
    $_.acceptance -like '*-inactive' -or
    $_.acceptance -like '*-no-comparison'
  })
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# Performance Optimization Plan')
  $lines.Add('')
  $lines.Add("Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').")
  $lines.Add('')
  $lines.Add("CPU: $($Metadata.cpu)")
  $lines.Add("Logical processors: $($Metadata.logicalProcessorCount)")
  $lines.Add("Physical cores: $($Metadata.physicalCoreCount)")
  $lines.Add("RAM bytes: $($Metadata.ramBytes)")
  $lines.Add("OS: $($Metadata.os)")
  $lines.Add("Compiler: $($Metadata.compiler)")
  $lines.Add("Build config: $($Metadata.buildConfig)")
  $lines.Add("SDK baseline: $($Metadata.sdkVersion)")
  $lines.Add("Benchmark work root: $($Metadata.benchmarkWorkRoot)")
  $lines.Add("Benchmark work dir: $($Metadata.benchmarkWorkDir)")
  $lines.Add("RAM-backed work root: $($Metadata.ramBackedWorkRoot)")
  $lines.Add('')

  if ($flagged.Count -eq 0) {
    $lines.Add('All smoke comparison rows met their configured thresholds.')
  } else {
    $lines.Add('Smoke comparison rows below target:')
    $lines.Add('')
    $lines.Add('| Tool | Operation | Mode | Threads | Throughput | Baseline | Ratio | Status |')
    $lines.Add('|---|---|---|---:|---:|---|---:|---|')
    foreach ($row in $flagged) {
      $metric = if ($row.comparisonMetric) { $row.comparisonMetric } else { 'throughputMiBs' }
      $lines.Add("| $($row.tool) | $($row.operation) | $($row.mode) | $($row.threads) | $($row.$metric) MiB/s | $($row.baselineTool) $($row.baselineThroughputMiBs) MiB/s | $($row.throughputRatioPct)% | $($row.acceptance) |")
    }
    $lines.Add('')
    $lines.Add('Optimization work items:')
    $lines.Add('')
    $workItem = 1
    if (@($flagged | Where-Object { $_.operation -eq 'decode' }).Count -ne 0) {
      $lines.Add("${workItem}. Continue optimizing the LZMA decode hot path against the aligned ``LZMA2:20 CRC32`` SDK baseline, especially range decoding, match copy, and checksum/output streaming.")
      $workItem++
    }
    if (@($flagged | Where-Object { $_.mode -in @('xz-delphi-multiblock-level1', 'xz-delphi-patterned-multiblock-level1') -and $_.operation -eq 'decode' }).Count -ne 0) {
      $lines.Add("${workItem}. Tune the Delphi-generated XZ MT decode scheduler and worker granularity so the generated corpora beat their own 1-thread baselines while keeping ``inputSnapshot=false``.")
      $workItem++
    }
    $lines.Add("${workItem}. Tune the active SDK-profile optimum parser and price tables against the failing rows, then rerun this suite.")
    $workItem++
    $lines.Add("${workItem}. Tune the active HC5/BT4 match-finder paths against the SDK ``C/LzFind.c`` traces for the failing corpus/options.")
    $workItem++
    $lines.Add("${workItem}. Continue reworking multi-threaded encode splitting/checksum scheduling and align the match-finder path with SDK block scheduling.")
    $workItem++
    $lines.Add("${workItem}. Keep the 256 MiB release-corpus mode in CI evidence and add release hardware baselines for future release candidates.")
  }

  $lines | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Write-BenchmarkSummary(
  [object[]]$Rows,
  [object[]]$Samples,
  [string]$Path,
  [pscustomobject]$Metadata
) {
  $toolCounts = [ordered]@{}
  foreach ($row in $Rows) {
    $toolName = [string]$row.tool
    if (-not $toolCounts.Contains($toolName)) {
      $toolCounts[$toolName] = 0
    }
    $toolCounts[$toolName] = [int]$toolCounts[$toolName] + 1
  }

  $summary = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    benchmark = 'lzma2-data-only'
    metadata = [ordered]@{
      cpu = $Metadata.cpu
      logicalProcessorCount = $Metadata.logicalProcessorCount
      physicalCoreCount = $Metadata.physicalCoreCount
      ramBytes = $Metadata.ramBytes
      os = $Metadata.os
      compiler = $Metadata.compiler
      sdkVersion = $Metadata.sdkVersion
      buildConfig = $Metadata.buildConfig
      benchmarkWorkRoot = $Metadata.benchmarkWorkRoot
      benchmarkWorkDir = $Metadata.benchmarkWorkDir
      corpusCacheRoot = $Metadata.corpusCacheRoot
      ramBackedWorkRoot = $Metadata.ramBackedWorkRoot
      gitCommit = $Metadata.gitCommit
      gitBranch = $Metadata.gitBranch
      gitRef = $Metadata.gitRef
    }
    artifacts = [ordered]@{
      csv = 'artifacts/perf/lzma2-benchmark.csv'
      json = 'artifacts/perf/lzma2-benchmark.json'
      samplesCsv = 'artifacts/perf/lzma2-benchmark.samples.csv'
      summaryJson = 'artifacts/perf/lzma2-benchmark.summary.json'
      optimizationPlan = 'artifacts/ci/optimization-plan.md'
    }
    corpusCache = [ordered]@{
      root = $Metadata.corpusCacheRoot
      recordCount = @($Metadata.corpusCacheRecords).Count
      records = @($Metadata.corpusCacheRecords)
    }
    rows = [ordered]@{
      count = @($Rows).Count
      operations = @($Rows | Select-Object -ExpandProperty operation -Unique)
      tools = $toolCounts
    }
    samples = [ordered]@{
      count = @($Samples).Count
      rowIdField = 'rowId'
      elapsedField = 'elapsedMs'
      throughputField = 'throughputMiBs'
      decimalThroughputField = 'throughputMBs'
    }
    policy = [ordered]@{
      dataOnly = $true
      graphArtifactsForbidden = 'artifacts/perf/lzma2-delphi-graph.*'
      visualizationsGeneratedByCi = $false
    }
  }

  $summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Invoke-DelphiRoundTrip(
  [System.Collections.ArrayList]$Rows,
  [string]$Name,
  [string]$Source,
  [int]$Level,
  [int]$Threads,
  [pscustomobject]$Metadata,
  [int64]$Dictionary = 1048576,
  [string]$Check = 'crc64',
  [int]$EncodeSamples = 1
) {
  $archive = Join-Path $work "$Name.delphi.xz"
  $decoded = Join-Path $work "$Name.delphi.out"
  $compressLog = Join-Path $work "$Name.delphi.compress.log"
  $decompressLog = Join-Path $work "$Name.delphi.decompress.log"
  $bestArchive = $null
  $bestCompressLog = $null
  $bestCodecElapsed = $null
  $bestElapsedSource = 'process-wall'
  $bestMeasurement = $null
  $codecElapsed = $null
  $elapsedSource = 'process-wall'
  $sampleArchives = @()
  $sampleProcessElapsedValues = @()
  if ($EncodeSamples -lt 1) {
    $EncodeSamples = 1
  }
  Remove-BenchmarkItem @($archive, $decoded)

  for ($sampleIndex = 1; $sampleIndex -le $EncodeSamples; $sampleIndex++) {
    if ($EncodeSamples -eq 1) {
      $sampleArchive = $archive
      $sampleCompressLog = $compressLog
    } else {
      $sampleArchive = Join-Path $work "$Name.sample$sampleIndex.delphi.xz"
      $sampleCompressLog = Join-Path $work "$Name.sample$sampleIndex.delphi.compress.log"
      $sampleArchives += $sampleArchive
      Remove-BenchmarkItem @($sampleArchive)
    }

    $measurement = Invoke-TimedProcess $CliExe @('compress', $Source, $sampleArchive, 'xz', "$Level", "$Dictionary", "$Threads", $Check) $sampleCompressLog $root
    $sampleProcessElapsedValues += [int64]$measurement.elapsedMs
    $sampleCodecElapsed = Get-CliElapsedMs $sampleCompressLog
    $sampleElapsedSource = 'cli-internal'
    if (($null -eq $sampleCodecElapsed) -or ([int64]$sampleCodecElapsed -le 0)) {
      $sampleCodecElapsed = $measurement.elapsedMs
      $sampleElapsedSource = 'process-wall'
    }

    if (($null -eq $bestMeasurement) -or ([int64]$measurement.elapsedMs -lt [int64]$bestMeasurement.elapsedMs)) {
      $bestArchive = $sampleArchive
      $bestCompressLog = $sampleCompressLog
      $bestCodecElapsed = $sampleCodecElapsed
      $bestElapsedSource = $sampleElapsedSource
      $bestMeasurement = $measurement
    }
  }

  if ($EncodeSamples -gt 1) {
    Copy-Item -LiteralPath $bestArchive -Destination $archive -Force
    Remove-BenchmarkItem $sampleArchives
  }

  $measurement = $bestMeasurement
  $codecElapsed = $bestCodecElapsed
  $elapsedSource = $bestElapsedSource
  $encodeNotes = "Native Delphi XZ $Check encode smoke."
  if ($EncodeSamples -gt 1) {
    $encodeNotes += " Best of $EncodeSamples encode samples by process wall time."
  }
  $encodeDiagnostics = Get-CliEncodeDiagnostics $bestCompressLog
  $encodeStats = New-ElapsedStats $sampleProcessElapsedValues
  Add-Row $Rows 'delphi-native' '13.1' 'encode' "xz-level$Level" $Level $Threads $Dictionary `
    (Split-Path -Leaf $Source) (Get-Item -LiteralPath $Source).Length (Get-Item -LiteralPath $archive).Length `
    $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes $Check $encodeNotes $Metadata `
    $measurement.elapsedMs $elapsedSource '' $null $encodeDiagnostics $encodeStats $sampleProcessElapsedValues

  $measurement = Invoke-TimedProcess $CliExe @('decompress', $archive, $decoded, 'xz', "$Level", "$Dictionary", "$Threads", $Check) $decompressLog $root
  $codecElapsed = Get-CliElapsedMs $decompressLog
  $decodeDiagnostics = Get-CliDecodeDiagnostics $decompressLog
  if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
    $codecElapsed = $measurement.elapsedMs
    $elapsedSource = 'process-wall'
  } else {
    $elapsedSource = 'cli-internal'
  }
  if ((Get-Sha256 $Source) -ne (Get-Sha256 $decoded)) {
    throw "Delphi round-trip SHA-256 mismatch for $Name"
  }
  Add-Row $Rows 'delphi-native' '13.1' 'decode' "xz-level$Level" $Level $Threads $Dictionary `
    (Split-Path -Leaf $archive) (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $decoded).Length `
    $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes $Check "Native Delphi XZ $Check decode smoke." $Metadata `
    $measurement.elapsedMs $elapsedSource '' $decodeDiagnostics
}

function Invoke-DelphiRawLzma2RoundTrip(
  [System.Collections.ArrayList]$Rows,
  [string]$Name,
  [string]$Source,
  [int]$Level,
  [int]$Threads,
  [pscustomobject]$Metadata,
  [int64]$Dictionary = 1048576
) {
  $archive = Join-Path $work "$Name.delphi.lzma2"
  $decoded = Join-Path $work "$Name.delphi.raw.out"
  $xzDecoded = Join-Path $work ([System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $archive)))
  $compressLog = Join-Path $work "$Name.delphi.raw.compress.log"
  $decompressLog = Join-Path $work "$Name.delphi.raw.decompress.log"
  $xzDecodeLog = Join-Path $work "$Name.xz-raw-decode.log"
  $codecElapsed = $null
  $elapsedSource = 'process-wall'
  Remove-BenchmarkItem @($archive, $decoded, $xzDecoded)

  $measurement = Invoke-TimedProcess $CliExe @('compress', $Source, $archive, 'raw', "$Level", "$Dictionary", "$Threads", 'none') $compressLog $root
  $codecElapsed = Get-CliElapsedMs $compressLog
  $encodeDiagnostics = Get-CliEncodeDiagnostics $compressLog
  $encodeStats = New-ElapsedStats @([int64]$measurement.elapsedMs)
  if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
    $codecElapsed = $measurement.elapsedMs
    $elapsedSource = 'process-wall'
  } else {
    $elapsedSource = 'cli-internal'
  }
  Add-Row $Rows 'delphi-native' '13.1' 'encode' "raw-lzma2-level$Level" $Level $Threads $Dictionary `
    (Split-Path -Leaf $Source) (Get-Item -LiteralPath $Source).Length (Get-Item -LiteralPath $archive).Length `
    $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' "Native Delphi raw LZMA2 encode smoke." $Metadata `
    $measurement.elapsedMs $elapsedSource '' $null $encodeDiagnostics $encodeStats

  $measurement = Invoke-TimedProcess $CliExe @('decompress', $archive, $decoded, 'raw', "$Level", "$Dictionary", "$Threads", 'none') $decompressLog $root
  $codecElapsed = Get-CliElapsedMs $decompressLog
  $decodeDiagnostics = Get-CliDecodeDiagnostics $decompressLog
  if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
    $codecElapsed = $measurement.elapsedMs
    $elapsedSource = 'process-wall'
  } else {
    $elapsedSource = 'cli-internal'
  }
  if ((Get-Sha256 $Source) -ne (Get-Sha256 $decoded)) {
    throw "Delphi raw LZMA2 round-trip SHA-256 mismatch for $Name"
  }
  Add-Row $Rows 'delphi-native' '13.1' 'decode' "raw-lzma2-level$Level" $Level $Threads $Dictionary `
    (Split-Path -Leaf $archive) (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $decoded).Length `
    $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' "Native Delphi raw LZMA2 decode smoke." $Metadata `
    $measurement.elapsedMs $elapsedSource '' $decodeDiagnostics

  if ($Xz) {
    if (-not (Test-Path -LiteralPath $Xz)) {
      throw "LZMA_TEST_XZ is set but does not exist: $Xz"
    }
    Remove-BenchmarkItem @($xzDecoded)
    $xzVersion = Get-ToolFirstLineVersion $Xz @('--version') 'xz-utils'
    $measurement = Invoke-TimedProcess $Xz @('--decompress', '--format=raw', '--lzma2=dict=1MiB',
      '--suffix=.lzma2', '-k', '-f', (Split-Path -Leaf $archive)) $xzDecodeLog $work
    if ((Get-Sha256 $Source) -ne (Get-Sha256 $xzDecoded)) {
      throw "xz-utils decode SHA-256 mismatch for Delphi raw LZMA2 archive $archive"
    }
    Add-Row $Rows 'xz-utils' $xzVersion 'decode' "raw-lzma2-level$Level" $Level 1 $Dictionary `
      (Split-Path -Leaf $archive) (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $xzDecoded).Length `
      $measurement.elapsedMs $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' "xz-utils decode of Delphi raw LZMA2 stream." $Metadata `
      $measurement.elapsedMs 'process-wall' 'xz-decodes-delphi-raw-lzma2'
  }
}

function Invoke-XzRawLzma2Baseline(
  [System.Collections.ArrayList]$Rows,
  [string]$Source,
  [pscustomobject]$Metadata
) {
  if (-not $Xz) {
    return
  }
  if (-not (Test-Path -LiteralPath $Xz)) {
    throw "LZMA_TEST_XZ is set but does not exist: $Xz"
  }

  $sourceName = Split-Path -Leaf $Source
  $sourceBase = [System.IO.Path]::GetFileNameWithoutExtension($sourceName)
  $rawSourceName = "$sourceBase.xzraw-src.bin"
  $archiveName = "$rawSourceName.rawlzma2"
  $rawSource = Join-Path $work $rawSourceName
  $archive = Join-Path $work $archiveName
  $delphiDecoded = Join-Path $work "$sourceBase.xzraw.delphi.out"
  $encodeLog = Join-Path $work "$sourceBase.xzraw.encode.log"
  $decodeLog = Join-Path $work "$sourceBase.xzraw.decode.log"
  $delphiDecodeLog = Join-Path $work "$sourceBase.xzraw.delphi-decode.log"
  $codecElapsed = $null
  $elapsedSource = 'process-wall'

  Remove-BenchmarkItem @($rawSource, $archive, $delphiDecoded)
  Copy-Item -LiteralPath $Source -Destination $rawSource -Force

  $xzVersion = Get-ToolFirstLineVersion $Xz @('--version') 'xz-utils'
  $measurement = Invoke-TimedProcess $Xz @('-1', '--format=raw', '--lzma2=dict=1MiB',
    '--suffix=.rawlzma2', '-k', '-f', $rawSourceName) $encodeLog $work
  Add-Row $Rows 'xz-utils' $xzVersion 'encode' 'raw-lzma2-level1' 1 1 1048576 `
    $rawSourceName (Get-Item -LiteralPath $rawSource).Length (Get-Item -LiteralPath $archive).Length `
    $measurement.elapsedMs $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' 'xz-utils raw LZMA2 encode baseline.' $Metadata

  Remove-BenchmarkItem @($rawSource)
  $measurement = Invoke-TimedProcess $Xz @('--decompress', '--format=raw', '--lzma2=dict=1MiB',
    '--suffix=.rawlzma2', '-k', '-f', $archiveName) $decodeLog $work
  if ((Get-Sha256 $Source) -ne (Get-Sha256 $rawSource)) {
    throw "xz-utils raw LZMA2 baseline SHA-256 mismatch"
  }
  Add-Row $Rows 'xz-utils' $xzVersion 'decode' 'raw-lzma2-level1' 1 1 1048576 `
    $archiveName (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $rawSource).Length `
    $measurement.elapsedMs $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' 'xz-utils raw LZMA2 decode baseline.' $Metadata

  Remove-BenchmarkItem @($delphiDecoded)
  $measurement = Invoke-TimedProcess $CliExe @('decompress', $archive, $delphiDecoded, 'raw', '1', '1048576', '1', 'none') $delphiDecodeLog $root
  $codecElapsed = Get-CliElapsedMs $delphiDecodeLog
  $decodeDiagnostics = Get-CliDecodeDiagnostics $delphiDecodeLog
  if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
    $codecElapsed = $measurement.elapsedMs
    $elapsedSource = 'process-wall'
  } else {
    $elapsedSource = 'cli-internal'
  }
  if ((Get-Sha256 $Source) -ne (Get-Sha256 $delphiDecoded)) {
    throw "Delphi decode SHA-256 mismatch for xz-utils raw LZMA2 baseline $archiveName"
  }
  Add-Row $Rows 'delphi-native' '13.1' 'decode' 'raw-lzma2-level1' 1 1 1048576 `
    $archiveName (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $delphiDecoded).Length `
    $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' 'Native Delphi decode of the same xz-utils raw LZMA2 stream.' $Metadata `
    $measurement.elapsedMs $elapsedSource '' $decodeDiagnostics
}

function Invoke-XzMtDecodeFixture(
  [System.Collections.ArrayList]$Rows,
  [string]$Source,
  [pscustomobject]$Metadata
) {
  if (-not $Xz) {
    return
  }
  if (-not (Test-Path -LiteralPath $Xz)) {
    throw "LZMA_TEST_XZ is set but does not exist: $Xz"
  }

  $sourceName = Split-Path -Leaf $Source
  $sourceBase = [System.IO.Path]::GetFileNameWithoutExtension($sourceName)
  $archiveName = "$sourceBase.block8m.xz"
  $fixtureSource = $Source
  $defaultArchive = Join-Path $work "$sourceName.xz"
  $archive = Join-Path $work $archiveName
  $encodeLog = Join-Path $work "$sourceBase.block8m.xz-encode.log"
  $xzVersion = Get-ToolFirstLineVersion $Xz @('--version') 'xz-utils'

  Remove-BenchmarkItem @($archive, $defaultArchive)

  [void](Invoke-TimedProcess $Xz @('-1', '--threads=1', '--check=crc32',
    '--lzma2=dict=1MiB', '--block-size=8388608',
    '-k', '-f', $sourceName) $encodeLog $work)
  if (-not (Test-Path -LiteralPath $defaultArchive)) {
    throw "xz-utils did not produce the expected multi-block archive: $defaultArchive"
  }
  Move-Item -LiteralPath $defaultArchive -Destination $archive -Force

  foreach ($threads in @(1, 2, 4, 8, 16)) {
    $decoded = Join-Path $work "$sourceBase.block8m.${threads}t.delphi.out"
    $decodeLog = Join-Path $work "$sourceBase.block8m.${threads}t.delphi-decode.log"
    Remove-BenchmarkItem @($decoded)

    $measurement = Invoke-TimedProcess $CliExe @('decompress', $archive, $decoded, 'xz', '1', '1048576', "$threads", 'crc32') $decodeLog $root
    $codecElapsed = Get-CliElapsedMs $decodeLog
    $decodeDiagnostics = Get-CliDecodeDiagnostics $decodeLog
    if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
      $codecElapsed = $measurement.elapsedMs
      $elapsedSource = 'process-wall'
    } else {
      $elapsedSource = 'cli-internal'
    }
    if ((Get-Sha256 $Source) -ne (Get-Sha256 $decoded)) {
      throw "Delphi XZ MT decode fixture SHA-256 mismatch for threads=$threads"
    }
    Add-Row $Rows 'delphi-native' '13.1' 'decode' 'xz-multiblock-level1' 1 $threads 1048576 `
      $archiveName (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $decoded).Length `
      $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'crc32' "Native Delphi decode of xz-utils $xzVersion multi-block XZ fixture." $Metadata `
      $measurement.elapsedMs $elapsedSource '' $decodeDiagnostics
  }
}

function Invoke-DelphiXzMtDecodeFixture(
  [System.Collections.ArrayList]$Rows,
  [string]$Source,
  [pscustomobject]$Metadata,
  [string]$Mode = 'xz-delphi-multiblock-level1',
  [string]$Suffix = 'delphi-block8m',
  [int64]$BlockSize = 8388608,
  [string]$Notes = 'Native Delphi multi-block XZ CRC32 encode with an 8 MiB block size.'
) {
  $sourceName = Split-Path -Leaf $Source
  $sourceBase = [System.IO.Path]::GetFileNameWithoutExtension($sourceName)
  $archiveName = "$sourceBase.$Suffix.xz"
  $archive = Join-Path $work $archiveName
  $encodeLog = Join-Path $work "$sourceBase.$Suffix.xz-encode.log"
  $codecElapsed = $null
  $elapsedSource = 'process-wall'

  Remove-BenchmarkItem @($archive)

  $measurement = Invoke-TimedProcess $CliExe @('compress', $Source, $archive, 'xz', '1', '1048576', '1', 'crc32', "$BlockSize") $encodeLog $root
  $codecElapsed = Get-CliElapsedMs $encodeLog
  $encodeDiagnostics = Get-CliEncodeDiagnostics $encodeLog
  $encodeStats = New-ElapsedStats @([int64]$measurement.elapsedMs)
  if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
    $codecElapsed = $measurement.elapsedMs
    $elapsedSource = 'process-wall'
  } else {
    $elapsedSource = 'cli-internal'
  }

  Add-Row $Rows 'delphi-native' '13.1' 'encode' $Mode 1 1 1048576 `
    $sourceName (Get-Item -LiteralPath $Source).Length (Get-Item -LiteralPath $archive).Length `
    $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'crc32' $Notes $Metadata `
    $measurement.elapsedMs $elapsedSource '' $null $encodeDiagnostics $encodeStats

  foreach ($threads in @(1, 2, 4, 8, 16)) {
    $decoded = Join-Path $work "$sourceBase.$Suffix.${threads}t.delphi.out"
    $decodeLog = Join-Path $work "$sourceBase.$Suffix.${threads}t.delphi-decode.log"
    Remove-BenchmarkItem @($decoded)

    $measurement = Invoke-TimedProcess $CliExe @('decompress', $archive, $decoded, 'xz', '1', '1048576', "$threads", 'crc32') $decodeLog $root
    $codecElapsed = Get-CliElapsedMs $decodeLog
    $decodeDiagnostics = Get-CliDecodeDiagnostics $decodeLog
    if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
      $codecElapsed = $measurement.elapsedMs
      $elapsedSource = 'process-wall'
    } else {
      $elapsedSource = 'cli-internal'
    }
    if ((Get-Sha256 $Source) -ne (Get-Sha256 $decoded)) {
      throw "Delphi-generated XZ MT decode fixture SHA-256 mismatch for threads=$threads"
    }
    Add-Row $Rows 'delphi-native' '13.1' 'decode' $Mode 1 $threads 1048576 `
      $archiveName (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $decoded).Length `
      $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'crc32' $Notes $Metadata `
      $measurement.elapsedMs $elapsedSource '' $decodeDiagnostics
  }
}

function Invoke-SevenZipBaseline(
  [System.Collections.ArrayList]$Rows,
  [string]$Source,
  [pscustomobject]$Metadata
) {
  if (-not $SevenZip) {
    return
  }
  if (-not (Test-Path -LiteralPath $SevenZip)) {
    throw "LZMA_TEST_7Z is set but does not exist: $SevenZip"
  }

  $sourceName = Split-Path -Leaf $Source
  $sourceBase = [System.IO.Path]::GetFileNameWithoutExtension($sourceName)
  $archiveName = "$sourceBase.7zr.xz"
  $archive = Join-Path $work $archiveName
  $extractDir = Join-Path $work "$sourceBase.7zr-out"
  $encodeLog = Join-Path $work "$sourceBase.7zr.encode.log"
  $decodeLog = Join-Path $work "$sourceBase.7zr.decode.log"
  $delphiDecodeLog = Join-Path $work "$sourceBase.7zr.delphi-decode.log"
  $delphiDecoded = Join-Path $work "$sourceBase.7zr.delphi.out"
  $codecElapsed = $null
  $elapsedSource = 'process-wall'
  Remove-BenchmarkItem @($archive, $delphiDecoded)
  Remove-BenchmarkItem @($extractDir) -Recurse
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

  $measurement = Invoke-TimedProcess $SevenZip @('a', '-txz', '-mx=1', '-mmt=1', '-m0=LZMA2:d=1m', $archiveName, $sourceName) $encodeLog $work
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $listOutput = & $SevenZip l -slt $archive 2>&1 | Out-String
    $listExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($listExitCode -ne 0) {
    throw "7zr baseline listing failed for ${archiveName}: $listOutput"
  }
  if ($listOutput -notmatch 'Method = LZMA2:20 CRC32') {
    throw "7zr baseline settings mismatch for ${archiveName}. Expected LZMA2:20 CRC32. Listing: $listOutput"
  }
  Add-Row $Rows '7zr-sdk' $script:LzmaSdkVersion 'encode' 'xz-lzma2-level1' 1 1 1048576 `
    $sourceName (Get-Item -LiteralPath $Source).Length (Get-Item -LiteralPath $archive).Length `
    $measurement.elapsedMs $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'crc32' "$script:LzmaSdkLabel 7zr XZ encode smoke baseline, LZMA2:20 CRC32." $Metadata

  $measurement = Invoke-TimedProcess $SevenZip @('x', $archiveName, "-o$extractDir", '-y') $decodeLog $work
  $decodedFiles = @(Get-ChildItem -LiteralPath $extractDir -File)
  if ($decodedFiles.Count -ne 1) {
    throw "7zr baseline produced $($decodedFiles.Count) files; expected one decoded payload."
  }
  $decoded = $decodedFiles[0].FullName
  if ((Get-Sha256 $Source) -ne (Get-Sha256 $decoded)) {
    throw "7zr baseline SHA-256 mismatch"
  }
  Add-Row $Rows '7zr-sdk' $script:LzmaSdkVersion 'decode' 'xz-lzma2-level1' 1 1 1048576 `
    $archiveName (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $decoded).Length `
    $measurement.elapsedMs $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'crc32' "$script:LzmaSdkLabel 7zr XZ decode smoke baseline, LZMA2:20 CRC32." $Metadata

  $measurement = Invoke-TimedProcess $CliExe @('decompress', $archive, $delphiDecoded, 'xz', '1', '1048576', '1', 'crc32') $delphiDecodeLog $root
  $codecElapsed = Get-CliElapsedMs $delphiDecodeLog
  $decodeDiagnostics = Get-CliDecodeDiagnostics $delphiDecodeLog
  if (($null -eq $codecElapsed) -or ([int64]$codecElapsed -le 0)) {
    $codecElapsed = $measurement.elapsedMs
    $elapsedSource = 'process-wall'
  } else {
    $elapsedSource = 'cli-internal'
  }
  if ((Get-Sha256 $Source) -ne (Get-Sha256 $delphiDecoded)) {
    throw "Delphi decode SHA-256 mismatch for 7zr baseline $archiveName"
  }
  Add-Row $Rows 'delphi-native' '13.1' 'decode' 'xz-level1' 1 1 1048576 `
    $archiveName (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $delphiDecoded).Length `
    $codecElapsed $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'crc32' 'Native Delphi decode of the same 7zr SDK XZ CRC32 baseline archive.' $Metadata `
    $measurement.elapsedMs $elapsedSource '' $decodeDiagnostics
}

function Invoke-LzmaBaseline(
  [System.Collections.ArrayList]$Rows,
  [string]$Source,
  [pscustomobject]$Metadata
) {
  if (-not $LzmaExe) {
    return
  }
  if (-not (Test-Path -LiteralPath $LzmaExe)) {
    throw "LZMA_TEST_LZMA is set but does not exist: $LzmaExe"
  }

  $sourceBase = [IO.Path]::GetFileNameWithoutExtension($Source)
  $archiveName = "$sourceBase.sdk.lzma"
  $archive = Join-Path $work $archiveName
  $decoded = Join-Path $work "$archiveName.out"
  $encodeLog = Join-Path $work "$sourceBase.lzma.encode.log"
  $decodeLog = Join-Path $work "$sourceBase.lzma.decode.log"
  Remove-BenchmarkItem @($archive, $decoded)

  $measurement = Invoke-TimedProcess $LzmaExe @('e', $Source, $archive, '-d20', '-mt1') $encodeLog $root
  Add-Row $Rows 'lzma-sdk' $script:LzmaSdkVersion 'encode' 'raw-lzma-level-default' 5 1 1048576 `
    (Split-Path -Leaf $Source) (Get-Item -LiteralPath $Source).Length (Get-Item -LiteralPath $archive).Length `
    $measurement.elapsedMs $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' "$script:LzmaSdkLabel lzma.exe raw LZMA encode smoke baseline." $Metadata

  $measurement = Invoke-TimedProcess $LzmaExe @('d', $archive, $decoded) $decodeLog $root
  if ((Get-Sha256 $Source) -ne (Get-Sha256 $decoded)) {
    throw "lzma.exe baseline SHA-256 mismatch"
  }
  Add-Row $Rows 'lzma-sdk' $script:LzmaSdkVersion 'decode' 'raw-lzma-level-default' 5 1 1048576 `
    $archiveName (Get-Item -LiteralPath $archive).Length (Get-Item -LiteralPath $decoded).Length `
    $measurement.elapsedMs $measurement.peakWorkingSetBytes $measurement.peakPagedMemoryBytes 'none' "$script:LzmaSdkLabel lzma.exe raw LZMA decode smoke baseline." $Metadata
}

$repeat = Join-Path $work 'repeat5-1m.bin'
$largeRepeat = Join-Path $work 'repeat5-4m.bin'
$rawComparisonRepeat = Join-Path $work 'repeat5-256m.bin'
$zeroes = Join-Path $work 'zeroes-1m.bin'
$ff = Join-Path $work 'ff-1m.bin'
$randomish = Join-Path $work 'randomish-1m.bin'
$mixed = Join-Path $work 'mixed-1m.bin'
$xzMtSize = if ($ReleaseCorpus) { $ReleaseCorpusSize } else { 67108864 }
$xzMtName = if ($ReleaseCorpus) { 'xz-mt-mixed-256m.bin' } else { 'xz-mt-mixed-64m.bin' }
$xzMtMixed = Join-Path $work $xzMtName
$xzMtPatternedName = if ($ReleaseCorpus) { 'xz-mt-patterned-256m.bin' } else { 'xz-mt-patterned-64m.bin' }
$xzMtPatterned = Join-Path $work $xzMtPatternedName
$matrixRepeat = Join-Path $work 'repeat5-64k.bin'
$rawComparisonRepeatOptions = $null
if ($ReleaseCorpus) {
  $rawComparisonRepeatOptions = [ordered]@{ releaseCorpus = $true }
}
$matrixDictionaries = @(4096, 65536, 1048576, 16777216, 67108864, 268435456, 536870912)
if (-not ($matrixDictionaries -contains $matrixMaxDictionaryBytes)) {
  $matrixDictionaries = @($matrixDictionaries + $matrixMaxDictionaryBytes | Sort-Object -Unique)
}
Use-BenchmarkCorpusFile $repeat $RepeatSize 'repeat5' {
  param($path, $size)
  New-RepeatingFile $path $size
}
Use-BenchmarkCorpusFile $largeRepeat $LargeRepeatSize 'repeat5' {
  param($path, $size)
  New-RepeatingFile $path $size
}
Use-BenchmarkCorpusFile $rawComparisonRepeat 268435456 'repeat5' {
  param($path, $size)
  New-RepeatingFile $path $size
} $rawComparisonRepeatOptions
Use-BenchmarkCorpusFile $zeroes $RepeatSize 'pattern' {
  param($path, $size)
  New-PatternFile $path $size 'zero'
} ([ordered]@{ pattern = 'zero' })
Use-BenchmarkCorpusFile $ff $RepeatSize 'pattern' {
  param($path, $size)
  New-PatternFile $path $size 'ff'
} ([ordered]@{ pattern = 'ff' })
Use-BenchmarkCorpusFile $randomish $RepeatSize 'pattern' {
  param($path, $size)
  New-PatternFile $path $size 'randomish'
} ([ordered]@{ pattern = 'randomish' })
Use-BenchmarkCorpusFile $mixed $RepeatSize 'pattern' {
  param($path, $size)
  New-PatternFile $path $size 'mixed'
} ([ordered]@{ pattern = 'mixed' })
Use-BenchmarkCorpusFile $xzMtMixed $xzMtSize 'varying-mixed' {
  param($path, $size)
  New-VaryingMixedFile $path $size
}
Use-BenchmarkCorpusFile $xzMtPatterned $xzMtSize 'pattern' {
  param($path, $size)
  New-PatternFile $path $size 'mixed'
} ([ordered]@{ pattern = 'mixed'; purpose = 'xz-mt-patterned' })
Use-BenchmarkCorpusFile $matrixRepeat 65536 'repeat5' {
  param($path, $size)
  New-RepeatingFile $path $size
}

$cpu = 'unknown'
$os = 'unknown'
$logicalProcessorCount = [Environment]::ProcessorCount
$physicalCoreCount = 0
$ramBytes = 0L
try { $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name).Trim() } catch {}
try { $physicalCoreCount = [int](@(Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum) } catch {}
try { $os = (Get-CimInstance Win32_OperatingSystem | Select-Object -First 1 -ExpandProperty Caption).Trim() } catch {}
try { $ramBytes = [int64](Get-CimInstance Win32_ComputerSystem | Select-Object -First 1 -ExpandProperty TotalPhysicalMemory) } catch {}
$gitCommit = Get-GitCommit
$gitBranch = Get-GitBranch
$gitRef = Get-GitRef $gitBranch
$metadata = [pscustomobject]@{
  cpu = $cpu
  logicalProcessorCount = $logicalProcessorCount
  physicalCoreCount = $physicalCoreCount
  ramBytes = $ramBytes
  os = $os
  compiler = 'Delphi 13.1 Win64'
  sdkVersion = $script:LzmaSdkLabel
  buildConfig = if ($ReleaseCorpus) { 'Win64 release-corpus' } else { 'Win64 smoke' }
  benchmarkWorkRoot = $workRoot
  benchmarkWorkDir = $work
  corpusCacheRoot = $corpusCacheRoot
  corpusCacheRecords = @($script:BenchmarkCorpusRecords)
  ramBackedWorkRoot = [bool]$workRootIsRamBacked
  gitCommit = $gitCommit
  gitBranch = $gitBranch
  gitRef = $gitRef
}

$rows = New-Object System.Collections.ArrayList
Invoke-DelphiRoundTrip $rows 'repeat5-1m-l0-1t' $repeat 0 1 $metadata
Invoke-DelphiRoundTrip $rows 'repeat5-1m-l1-1t' $repeat 1 1 $metadata
Invoke-DelphiRoundTrip $rows 'repeat5-1m-l1-1t-crc32' $repeat 1 1 $metadata 1048576 'crc32'
Invoke-DelphiRoundTrip $rows 'repeat5-4m-l1-1t' $largeRepeat 1 1 $metadata
Invoke-DelphiRoundTrip $rows 'repeat5-4m-l1-1t-crc32' $largeRepeat 1 1 $metadata 1048576 'crc32' 3
Invoke-DelphiRoundTrip $rows 'repeat5-4m-l1-4t' $largeRepeat 1 4 $metadata
Invoke-DelphiRoundTrip $rows 'zeroes-1m-l1-1t' $zeroes 1 1 $metadata
Invoke-DelphiRoundTrip $rows 'ff-1m-l1-1t' $ff 1 1 $metadata
Invoke-DelphiRoundTrip $rows 'randomish-1m-l1-1t' $randomish 1 1 $metadata
Invoke-DelphiRoundTrip $rows 'mixed-1m-l1-1t' $mixed 1 1 $metadata
Invoke-DelphiRawLzma2RoundTrip $rows 'raw-repeat5-256m-l1-1t' $rawComparisonRepeat 1 1 $metadata
Invoke-DelphiRawLzma2RoundTrip $rows 'raw-repeat5-256m-l1-4t' $rawComparisonRepeat 1 4 $metadata
Invoke-XzRawLzma2Baseline $rows $rawComparisonRepeat $metadata
Invoke-XzMtDecodeFixture $rows $xzMtMixed $metadata
Invoke-DelphiXzMtDecodeFixture $rows $xzMtMixed $metadata
Invoke-DelphiXzMtDecodeFixture $rows $xzMtPatterned $metadata `
  'xz-delphi-patterned-multiblock-level1' 'delphi-patterned-block8m' 8388608 `
  'Native Delphi patterned multi-block XZ CRC32 encode/decode with an 8 MiB block size.'
foreach ($matrixLevel in @(0, 1, 3, 5, 7, 9)) {
  foreach ($matrixDictionary in $matrixDictionaries) {
    Invoke-DelphiRoundTrip $rows "matrix-repeat64k-l$matrixLevel-d$matrixDictionary" `
      $matrixRepeat $matrixLevel 1 $metadata $matrixDictionary
  }
}
if ($ReleaseCorpus) {
  $releaseRepeat = Join-Path $work 'repeat5-256m.bin'
  $releaseMixed = Join-Path $work 'mixed-256m.bin'
  $releaseEncodeSamples = 5
  $releaseThreadMatrix = @(1, 2, 4, 8, 16)
  if ($logicalProcessorCount -gt 16) {
    $releaseThreadMatrix = @($releaseThreadMatrix + $logicalProcessorCount | Sort-Object -Unique)
  }
  Use-BenchmarkCorpusFile $releaseRepeat $ReleaseCorpusSize 'repeat5' {
    param($path, $size)
    New-RepeatingFile $path $size
  } ([ordered]@{ releaseCorpus = $true })
  Use-BenchmarkCorpusFile $releaseMixed $ReleaseCorpusSize 'pattern' {
    param($path, $size)
    New-PatternFile $path $size 'mixed'
  } ([ordered]@{ pattern = 'mixed'; releaseCorpus = $true })
  Invoke-DelphiRoundTrip $rows 'release-repeat5-256m-l1-1t-crc32' `
    $releaseRepeat 1 1 $metadata 1048576 'crc32' $releaseEncodeSamples
  foreach ($releaseThreads in $releaseThreadMatrix) {
    Invoke-DelphiRoundTrip $rows "release-repeat5-256m-l1-${releaseThreads}t" `
      $releaseRepeat 1 $releaseThreads $metadata 1048576 'crc64' $releaseEncodeSamples
    Invoke-DelphiRoundTrip $rows "release-mixed-256m-l1-${releaseThreads}t" `
      $releaseMixed 1 $releaseThreads $metadata 1048576 'crc64' $releaseEncodeSamples
  }
}
Invoke-SevenZipBaseline $rows $repeat $metadata
Invoke-SevenZipBaseline $rows $largeRepeat $metadata
if ($ReleaseCorpus) {
  Invoke-SevenZipBaseline $rows $releaseRepeat $metadata
  Invoke-LzmaBaseline $rows $releaseRepeat $metadata
}
Invoke-LzmaBaseline $rows $repeat $metadata
Add-PerformanceComparisons $rows

$csvPath = Join-Path $outDir 'lzma2-benchmark.csv'
$jsonPath = Join-Path $outDir 'lzma2-benchmark.json'
$samplesPath = Join-Path $outDir 'lzma2-benchmark.samples.csv'
$summaryPath = Join-Path $outDir 'lzma2-benchmark.summary.json'
$optimizationPath = Join-Path $ciOutDir 'optimization-plan.md'
$sampleRows = @($script:BenchmarkSamples)

$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $csvPath
$rows | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath $jsonPath
$sampleRows | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath $samplesPath
$metadata.corpusCacheRecords = @($script:BenchmarkCorpusRecords)
Write-BenchmarkSummary $rows $sampleRows $summaryPath $metadata
Write-OptimizationPlan $rows $optimizationPath $metadata

Write-Host "Wrote $csvPath"
Write-Host "Wrote $jsonPath"
Write-Host "Wrote $samplesPath"
Write-Host "Wrote $summaryPath"
Write-Host "Wrote $optimizationPath"
