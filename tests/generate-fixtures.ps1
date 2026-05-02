param(
  [switch]$ReleaseCorpus
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tests\qa-tools.ps1')
$resolvedLzmaTool = Resolve-LzmaQATool 'lzma' $env:LZMA_TEST_LZMA $false $false
if ($resolvedLzmaTool.available) {
  $env:LZMA_TEST_LZMA = [string]$resolvedLzmaTool.path
}
$script:LzmaSdkVersion = [string]$resolvedLzmaTool.expectedVersion
$sourceDir = Join-Path $root 'tests\fixtures\sources'
$xzDir = Join-Path $root 'tests\fixtures\xz'
$rawDir = Join-Path $root 'tests\fixtures\raw'
$corruptDir = Join-Path $root 'tests\fixtures\corrupt'
$cacheDir = Join-Path $root 'tests\fixtures\cache'
$manifestDir = Join-Path $root 'tests\fixtures\manifests'
$manifestPath = Join-Path $root 'tests\fixtures\manifests\sevenzip-smoke-xz.json'
$rawLzmaCorpusManifestPath = Join-Path $manifestDir 'raw-lzma-sdk-corpus.json'
$rawLzmaReleaseCorpusManifestPath = Join-Path $manifestDir 'raw-lzma-sdk-release-corpus.json'

New-Item -ItemType Directory -Force -Path $sourceDir, $xzDir, $rawDir, $corruptDir, $cacheDir, $manifestDir | Out-Null
Remove-Item -LiteralPath $rawLzmaCorpusManifestPath, $rawLzmaReleaseCorpusManifestPath -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $sourceDir -Filter 'raw-lzma-sdk-corpus-*-source.bin' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -LiteralPath $sourceDir -Filter 'raw-lzma-sdk-release-corpus-*-source.bin' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -LiteralPath $rawDir -Filter 'raw-lzma-sdk-corpus-*.lzma' -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem -LiteralPath $rawDir -Filter 'raw-lzma-sdk-release-corpus-*.lzma' -ErrorAction SilentlyContinue | Remove-Item -Force

function Get-RelativePath([string]$Path) {
  $base = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($base.Length).Replace('\', '/')
  }
  return $full.Replace('\', '/')
}

function Get-Sha256([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-JsonManifest([string]$Path, [hashtable]$Data) {
  $Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-LzmaToolVersion([string]$Lzma) {
  $output = ''
  try {
    $output = (@(& $Lzma 2>&1) -join "`n")
  } catch {
    return 'unknown'
  }
  $match = [regex]::Match($output, '\b(?<version>\d+\.\d+)\b')
  if ($match.Success) {
    return $match.Groups['version'].Value
  }
  return 'unknown'
}

function Get-FixtureCacheKey(
  [string]$ToolName,
  [string]$ToolVersion,
  [string[]]$Switches,
  [string]$SourceSha256,
  [string]$Tier
) {
  $identity = @(
    "tool=$ToolName",
    "version=$ToolVersion",
    "tier=$Tier",
    "sourceSha256=$SourceSha256",
    "switches=$($Switches -join ' ')"
  ) -join "`n"
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($identity)
    $hash = $sha.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Invoke-CachedLzmaEncode(
  [string]$Lzma,
  [string]$ToolVersion,
  [string]$SourcePath,
  [string]$ArchivePath,
  [string[]]$Switches,
  [string]$Tier
) {
  $sourceSha256 = Get-Sha256 $SourcePath
  $cacheKey = Get-FixtureCacheKey 'lzma' $ToolVersion $Switches $sourceSha256 $Tier
  $cachePath = Join-Path $cacheDir "$cacheKey.lzma"
  if (Test-Path -LiteralPath $cachePath) {
    Copy-Item -LiteralPath $cachePath -Destination $ArchivePath -Force
    return [ordered]@{
      cacheKey = $cacheKey
      cacheHit = $true
      cachePath = Get-RelativePath $cachePath
    }
  }

  & $Lzma e $SourcePath $ArchivePath @Switches | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "lzma.exe failed while generating $(Split-Path -Leaf $ArchivePath)"
  }
  Copy-Item -LiteralPath $ArchivePath -Destination $cachePath -Force
  return [ordered]@{
    cacheKey = $cacheKey
    cacheHit = $false
    cachePath = Get-RelativePath $cachePath
  }
}

function New-PatternBytes([int]$Size, [int]$Seed, [string]$Kind) {
  $bytes = New-Object byte[] $Size
  $textPattern = [Text.Encoding]::UTF8.GetBytes("LZMA2 Delphi UTF-8 text corpus line $Seed with repeated words and punctuation.`r`n")
  $exePattern = [byte[]](
    0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00,
    0x50, 0x45, 0x00, 0x00, 0x64, 0x86, 0x06, 0x00,
    0x2E, 0x74, 0x65, 0x78, 0x74, 0x00, 0x00, 0x00,
    0x2E, 0x72, 0x64, 0x61, 0x74, 0x61, 0x00, 0x00,
    0x55, 0x48, 0x89, 0xE5, 0x48, 0x83, 0xEC, 0x20,
    0x48, 0x8D, 0x0D, 0x34, 0x12, 0x00, 0x00, 0xE8
  )
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($Kind -eq 'zero') {
      $bytes[$i] = 0
    } elseif ($Kind -eq 'ff') {
      $bytes[$i] = 255
    } elseif ($Kind -eq 'repeat') {
      $bytes[$i] = [byte](65 + (($i + $Seed) % 5))
    } elseif ($Kind -eq 'text') {
      $bytes[$i] = $textPattern[$i % $textPattern.Length]
    } elseif ($Kind -eq 'exe') {
      if ($i -lt $exePattern.Length) {
        $bytes[$i] = $exePattern[$i]
      } else {
        $bytes[$i] = [byte](($Seed + ($i * 17) + (($i -shr 5) * 3)) -band 0xff)
      }
    } elseif ($Kind -eq 'mixed') {
      if (($i % 4096) -lt 2048) {
        $bytes[$i] = [byte](65 + (($i + $Seed) % 7))
      } else {
        $bytes[$i] = [byte](($Seed + ($i * 73) + (($i -shr 4) * 29)) -band 0xff)
      }
    } elseif ($Kind -eq 'small-batch') {
      $block = $i % 530
      if ($block -lt 1) {
        $bytes[$i] = [byte](0xA0 + $Seed)
      } elseif ($block -lt 3) {
        $bytes[$i] = [byte](0x30 + $block)
      } elseif ($block -lt 18) {
        $bytes[$i] = [byte](0x41 + ($block % 13))
      } elseif ($block -lt 34) {
        $bytes[$i] = [byte](0x61 + ($block % 19))
      } elseif ($block -lt 289) {
        $bytes[$i] = [byte](($Seed + $block * 5) -band 0xff)
      } else {
        $bytes[$i] = [byte](($Seed + $block * 11) -band 0xff)
      }
    } else {
      $bytes[$i] = [byte](($Seed + ($i * 131) + (($i -shr 3) * 17)) -band 0xff)
    }
  }
  return $bytes
}

function Write-RawLzmaSdkCorpus {
  $lzma = $env:LZMA_TEST_LZMA
  if (-not $lzma -or -not (Test-Path -LiteralPath $lzma)) {
    Write-Host 'Skipping generated raw LZMA SDK corpus: set LZMA_TEST_LZMA to enable.'
    return
  }
  $toolVersion = Get-LzmaToolVersion $lzma

  $cases = @(
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a0-d16-fb16'
      bytes = New-PatternBytes 4096 11 'repeat'
      switches = @('-a0', '-d16', '-fb16')
      algorithm = 0
      dictionarySize = 65536
      fastBytes = 16
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a0-d20-fb32-random'
      bytes = New-PatternBytes 8192 23 'random'
      switches = @('-a0', '-d20', '-fb32')
      algorithm = 0
      dictionarySize = 1048576
      fastBytes = 32
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a1-d20-fb64'
      bytes = New-PatternBytes 12288 37 'repeat'
      switches = @('-a1', '-d20', '-fb64')
      algorithm = 1
      dictionarySize = 1048576
      fastBytes = 64
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a1-d22-fb64-zero'
      bytes = New-PatternBytes 6144 0 'zero'
      switches = @('-a1', '-d22', '-fb64')
      algorithm = 1
      dictionarySize = 4194304
      fastBytes = 64
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a0-d16-fb16-ff'
      bytes = New-PatternBytes 4096 5 'ff'
      switches = @('-a0', '-d16', '-fb16')
      algorithm = 0
      dictionarySize = 65536
      fastBytes = 16
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a1-d20-fb32-text'
      bytes = New-PatternBytes 10000 7 'text'
      switches = @('-a1', '-d20', '-fb32')
      algorithm = 1
      dictionarySize = 1048576
      fastBytes = 32
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a1-d20-fb64-exe'
      bytes = New-PatternBytes 16384 19 'exe'
      switches = @('-a1', '-d20', '-fb64')
      algorithm = 1
      dictionarySize = 1048576
      fastBytes = 64
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a1-d22-fb64-mixed'
      bytes = New-PatternBytes 32768 31 'mixed'
      switches = @('-a1', '-d22', '-fb64')
      algorithm = 1
      dictionarySize = 4194304
      fastBytes = 64
    },
    [ordered]@{
      name = 'raw-lzma-sdk-corpus-a0-d16-fb16-small-batch'
      bytes = New-PatternBytes 4096 3 'small-batch'
      switches = @('-a0', '-d16', '-fb16')
      algorithm = 0
      dictionarySize = 65536
      fastBytes = 16
    }
  )

  $records = @()
  foreach ($case in $cases) {
    $caseSourcePath = Join-Path $sourceDir "$($case.name)-source.bin"
    $caseArchivePath = Join-Path $rawDir "$($case.name).lzma"
    [IO.File]::WriteAllBytes($caseSourcePath, [byte[]]$case.bytes)
    Remove-Item -LiteralPath $caseArchivePath -ErrorAction SilentlyContinue
    $cacheEvidence = Invoke-CachedLzmaEncode `
      -Lzma $lzma `
      -ToolVersion $toolVersion `
      -SourcePath $caseSourcePath `
      -ArchivePath $caseArchivePath `
      -Switches @($case.switches) `
      -Tier 'quick'

    $records += [ordered]@{
      name = "$($case.name).lzma"
      sourcePath = Get-RelativePath $caseSourcePath
      compressedPath = Get-RelativePath $caseArchivePath
      sourceSha256 = Get-Sha256 $caseSourcePath
      compressedSha256 = Get-Sha256 $caseArchivePath
      commandLine = "lzma.exe e $($case.name)-source.bin $($case.name).lzma $($case.switches -join ' ')"
      algorithm = $case.algorithm
      dictionarySize = $case.dictionarySize
      fastBytes = $case.fastBytes
      cacheKey = $cacheEvidence.cacheKey
      cacheHit = $cacheEvidence.cacheHit
      cachePath = $cacheEvidence.cachePath
      unpackSize = $case.bytes.Length
    }
  }

  Write-JsonManifest $rawLzmaCorpusManifestPath ([ordered]@{
    name = 'raw-lzma-sdk-corpus'
    tool = 'lzma'
    toolVersion = $toolVersion
    commandLine = 'Generated by tests/generate-fixtures.ps1 with LZMA_TEST_LZMA'
    container = 'raw-lzma'
    method = 'lzma'
    cases = $records
  })
}

function Write-RawLzmaSdkReleaseCorpus {
  $lzma = $env:LZMA_TEST_LZMA
  if (-not $lzma -or -not (Test-Path -LiteralPath $lzma)) {
    Write-Host 'Skipping generated raw LZMA SDK release corpus: set LZMA_TEST_LZMA to enable.'
    return
  }
  $toolVersion = Get-LzmaToolVersion $lzma

  $cases = @(
    [ordered]@{
      name = 'raw-lzma-sdk-release-corpus-a0-d20-fb32-repeat'
      bytes = New-PatternBytes 262144 41 'repeat'
      switches = @('-a0', '-d20', '-fb32')
      algorithm = 0
      dictionarySize = 1048576
      fastBytes = 32
      pattern = 'repeat'
    },
    [ordered]@{
      name = 'raw-lzma-sdk-release-corpus-a0-d20-fb32-random'
      bytes = New-PatternBytes 524288 53 'random'
      switches = @('-a0', '-d20', '-fb32')
      algorithm = 0
      dictionarySize = 1048576
      fastBytes = 32
      pattern = 'random'
    },
    [ordered]@{
      name = 'raw-lzma-sdk-release-corpus-a1-d20-fb32-text'
      bytes = New-PatternBytes 786432 67 'text'
      switches = @('-a1', '-d20', '-fb32')
      algorithm = 1
      dictionarySize = 1048576
      fastBytes = 32
      pattern = 'text'
    },
    [ordered]@{
      name = 'raw-lzma-sdk-release-corpus-a1-d22-fb64-exe'
      bytes = New-PatternBytes 1048576 79 'exe'
      switches = @('-a1', '-d22', '-fb64')
      algorithm = 1
      dictionarySize = 4194304
      fastBytes = 64
      pattern = 'exe'
    },
    [ordered]@{
      name = 'raw-lzma-sdk-release-corpus-a1-d22-fb64-mixed'
      bytes = New-PatternBytes 1048576 83 'mixed'
      switches = @('-a1', '-d22', '-fb64')
      algorithm = 1
      dictionarySize = 4194304
      fastBytes = 64
      pattern = 'mixed'
    }
  )

  $records = @()
  foreach ($case in $cases) {
    $caseSourcePath = Join-Path $sourceDir "$($case.name)-source.bin"
    $caseArchivePath = Join-Path $rawDir "$($case.name).lzma"
    [IO.File]::WriteAllBytes($caseSourcePath, [byte[]]$case.bytes)
    Remove-Item -LiteralPath $caseArchivePath -ErrorAction SilentlyContinue
    $cacheEvidence = Invoke-CachedLzmaEncode `
      -Lzma $lzma `
      -ToolVersion $toolVersion `
      -SourcePath $caseSourcePath `
      -ArchivePath $caseArchivePath `
      -Switches @($case.switches) `
      -Tier 'release'

    $records += [ordered]@{
      name = "$($case.name).lzma"
      sourcePath = Get-RelativePath $caseSourcePath
      compressedPath = Get-RelativePath $caseArchivePath
      sourceSha256 = Get-Sha256 $caseSourcePath
      compressedSha256 = Get-Sha256 $caseArchivePath
      commandLine = "lzma.exe e $($case.name)-source.bin $($case.name).lzma $($case.switches -join ' ')"
      algorithm = $case.algorithm
      dictionarySize = $case.dictionarySize
      fastBytes = $case.fastBytes
      pattern = $case.pattern
      tier = 'release'
      cacheKey = $cacheEvidence.cacheKey
      cacheHit = $cacheEvidence.cacheHit
      cachePath = $cacheEvidence.cachePath
      unpackSize = $case.bytes.Length
    }
  }

  Write-JsonManifest $rawLzmaReleaseCorpusManifestPath ([ordered]@{
    name = 'raw-lzma-sdk-release-corpus'
    tool = 'lzma'
    toolVersion = $toolVersion
    commandLine = 'Generated by tests/generate-fixtures.ps1 with LZMA_TEST_LZMA'
    container = 'raw-lzma'
    method = 'lzma'
    tier = 'release'
    minimumTotalUnpackSize = 3145728
    cases = $records
  })
}

$sourcePath = Join-Path $sourceDir 'sevenzip-smoke.txt'
$archivePath = Join-Path $xzDir 'sevenzip-smoke.xz'
$rawLzmaSourcePath = Join-Path $sourceDir 'raw-lzma-sdk-source.txt'
$rawLzmaPath = Join-Path $rawDir 'raw-lzma-sdk.lzma'
$rawLzma2SourcePath = Join-Path $sourceDir 'raw-lzma2-copy-source.bin'
$rawLzma2Path = Join-Path $rawDir 'raw-lzma2-copy.lzma2'
$truncatedXzPath = Join-Path $corruptDir 'sevenzip-smoke-truncated-footer.xz'
$corruptCheckXzPath = Join-Path $corruptDir 'sevenzip-smoke-corrupt-check.xz'

$sourceBytes = [byte[]](
  0xEF, 0xBB, 0xBF, 0x4C, 0x5A, 0x4D, 0x41, 0x32, 0x20, 0x44, 0x65, 0x6C, 0x70, 0x68, 0x69, 0x20,
  0x6E, 0x61, 0x74, 0x69, 0x76, 0x65, 0x20, 0x73, 0x6D, 0x6F, 0x6B, 0x65, 0x20, 0x73, 0x61, 0x6D,
  0x70, 0x6C, 0x65, 0x20, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x20, 0x72,
  0x65, 0x70, 0x65, 0x61, 0x74, 0x65, 0x64, 0x20, 0x72, 0x65, 0x70, 0x65, 0x61, 0x74, 0x65, 0x64,
  0x20, 0x72, 0x65, 0x70, 0x65, 0x61, 0x74, 0x65, 0x64, 0x0D, 0x0A
)

$archiveBytes = [byte[]](
  0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00, 0x01, 0x69, 0x22, 0xDE, 0x36, 0x02, 0x00, 0x21, 0x01,
  0x00, 0x00, 0x00, 0x00, 0x37, 0x27, 0x97, 0xD6, 0xE0, 0x00, 0x4A, 0x00, 0x3F, 0x5D, 0x00, 0x77,
  0xAE, 0xD3, 0xE4, 0x9C, 0xD0, 0x8C, 0xF5, 0x2A, 0x33, 0x88, 0xA8, 0x0C, 0x21, 0x72, 0xDE, 0xAD,
  0x6D, 0xFB, 0xEC, 0x97, 0x5C, 0x86, 0x0E, 0xC9, 0xBF, 0xE7, 0x5E, 0x08, 0x7F, 0x5A, 0xC1, 0x0D,
  0x6F, 0x72, 0x9D, 0xD4, 0x30, 0x2C, 0x60, 0x3A, 0x26, 0xD8, 0xF3, 0x08, 0x61, 0x0F, 0x95, 0xC1,
  0xDF, 0xB0, 0x5A, 0x16, 0x07, 0xA7, 0x63, 0x6F, 0x73, 0x05, 0x34, 0x30, 0x00, 0x00, 0x00, 0x00,
  0x20, 0x4A, 0x88, 0x40, 0x00, 0x01, 0x57, 0x4B, 0xA0, 0xE6, 0x72, 0x34, 0x90, 0x42, 0x99, 0x0D,
  0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x59, 0x5A
)

$rawLzmaSourceBytes = [byte[]](
  0x4C, 0x5A, 0x4D, 0x41, 0x20, 0x72, 0x61, 0x77, 0x20, 0x53, 0x44, 0x4B, 0x20, 0x66, 0x69, 0x78,
  0x74, 0x75, 0x72, 0x65, 0x20, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x20,
  0x72, 0x65, 0x70, 0x65, 0x61, 0x74, 0x65, 0x64, 0x20, 0x72, 0x65, 0x70, 0x65, 0x61, 0x74, 0x65,
  0x64, 0x20, 0x72, 0x65, 0x70, 0x65, 0x61, 0x74, 0x65, 0x64, 0x0D, 0x0A
)

$rawLzmaBytes = [byte[]](
  0x5D, 0x00, 0x00, 0x10, 0x00, 0x3C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x26, 0x16,
  0x85, 0xBC, 0x45, 0xF1, 0x28, 0xC0, 0xF7, 0xBC, 0x90, 0x0C, 0x25, 0x43, 0xA7, 0x9C, 0x14, 0x0B,
  0xE2, 0x2C, 0xF2, 0x02, 0xCF, 0x76, 0xE8, 0xE0, 0xB7, 0x3A, 0x50, 0xC5, 0xF5, 0x94, 0x1E, 0x84,
  0xAA, 0x64, 0x8D, 0x1E, 0xD4, 0x5A, 0x92, 0x42, 0x20, 0x57, 0xFE, 0xE4, 0x0A, 0xC0, 0x00, 0x00
)

$rawLzma2SourceBytes = [Text.Encoding]::ASCII.GetBytes('raw-lzma2-copy-fixture')
$rawLzma2Bytes = New-Object byte[] ($rawLzma2SourceBytes.Length + 4)
$rawLzma2Bytes[0] = 1
$rawLzma2Bytes[1] = [byte](($rawLzma2SourceBytes.Length - 1) -shr 8)
$rawLzma2Bytes[2] = [byte](($rawLzma2SourceBytes.Length - 1) -band 0xff)
[Array]::Copy($rawLzma2SourceBytes, 0, $rawLzma2Bytes, 3, $rawLzma2SourceBytes.Length)
$rawLzma2Bytes[$rawLzma2Bytes.Length - 1] = 0

[IO.File]::WriteAllBytes($sourcePath, $sourceBytes)
[IO.File]::WriteAllBytes($archivePath, $archiveBytes)
[IO.File]::WriteAllBytes($rawLzmaSourcePath, $rawLzmaSourceBytes)
[IO.File]::WriteAllBytes($rawLzmaPath, $rawLzmaBytes)
[IO.File]::WriteAllBytes($rawLzma2SourcePath, $rawLzma2SourceBytes)
[IO.File]::WriteAllBytes($rawLzma2Path, $rawLzma2Bytes)

$truncatedBytes = New-Object byte[] ($archiveBytes.Length - 1)
[Array]::Copy($archiveBytes, $truncatedBytes, $truncatedBytes.Length)
[IO.File]::WriteAllBytes($truncatedXzPath, $truncatedBytes)

$corruptCheckBytes = [byte[]]$archiveBytes.Clone()
$corruptCheckBytes[96] = $corruptCheckBytes[96] -bxor 0x55
[IO.File]::WriteAllBytes($corruptCheckXzPath, $corruptCheckBytes)

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$sourceHash = Get-Sha256 $sourcePath
$archiveHash = Get-Sha256 $archivePath

if ($sourceHash -ne $manifest.sourceSha256.ToLowerInvariant()) {
  throw "Generated source fixture hash mismatch: $sourceHash != $($manifest.sourceSha256)"
}
if ($archiveHash -ne $manifest.compressedSha256.ToLowerInvariant()) {
  throw "Generated XZ fixture hash mismatch: $archiveHash != $($manifest.compressedSha256)"
}

Write-JsonManifest (Join-Path $manifestDir 'raw-lzma-sdk.json') ([ordered]@{
  name = 'raw-lzma-sdk.lzma'
  sourcePath = Get-RelativePath $rawLzmaSourcePath
  compressedPath = Get-RelativePath $rawLzmaPath
  sourceSha256 = Get-Sha256 $rawLzmaSourcePath
  compressedSha256 = Get-Sha256 $rawLzmaPath
  tool = 'lzma'
  toolVersion = $script:LzmaSdkVersion
  commandLine = 'lzma.exe e raw-lzma-sdk-source.txt raw-lzma-sdk.lzma -d20'
  container = 'raw-lzma'
  method = 'lzma'
  level = 5
  dictionarySize = 1048576
  unpackSize = $rawLzmaSourceBytes.Length
})

Write-RawLzmaSdkCorpus
if ($ReleaseCorpus) {
  Write-RawLzmaSdkReleaseCorpus
} else {
  Write-Host 'Skipping generated raw LZMA SDK release corpus: pass -ReleaseCorpus to enable.'
}

Write-JsonManifest (Join-Path $manifestDir 'raw-lzma2-copy.json') ([ordered]@{
  name = 'raw-lzma2-copy.lzma2'
  sourcePath = Get-RelativePath $rawLzma2SourcePath
  compressedPath = Get-RelativePath $rawLzma2Path
  sourceSha256 = Get-Sha256 $rawLzma2SourcePath
  compressedSha256 = Get-Sha256 $rawLzma2Path
  tool = 'delphi-native'
  toolVersion = '13.1'
  commandLine = 'TLzma2Encoder level 0 raw LZMA2 copy chunk'
  container = 'raw-lzma2'
  method = 'lzma2'
  level = 0
  dictionarySize = 1048576
  unpackSize = $rawLzma2SourceBytes.Length
})

Write-JsonManifest (Join-Path $manifestDir 'corrupt-xz-regressions.json') ([ordered]@{
  name = 'corrupt-xz-regressions'
  basePath = Get-RelativePath $archivePath
  baseSha256 = Get-Sha256 $archivePath
  tool = 'delphi-native'
  toolVersion = '13.1'
  commandLine = 'Derived from sevenzip-smoke.xz by truncating footer and flipping check byte'
  container = 'xz'
  method = 'lzma2'
  cases = @(
    [ordered]@{
      fixturePath = Get-RelativePath $truncatedXzPath
      fixtureSha256 = Get-Sha256 $truncatedXzPath
      expectedError = 'ELzmaInputEof'
    },
    [ordered]@{
      fixturePath = Get-RelativePath $corruptCheckXzPath
      fixtureSha256 = Get-Sha256 $corruptCheckXzPath
      expectedError = 'ELzmaChecksumError'
    }
  )
})

Write-Host "Fixtures generated: $sourcePath, $archivePath"
