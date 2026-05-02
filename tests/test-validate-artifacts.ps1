param(
  [switch]$RequireExternalTools,
  [switch]$RequireReleaseCorpus,
  [switch]$ScriptContractOnly
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$perfJsonPath = Join-Path $root 'artifacts\perf\lzma2-benchmark.json'
$perfSamplesPath = Join-Path $root 'artifacts\perf\lzma2-benchmark.samples.csv'
$perfSummaryPath = Join-Path $root 'artifacts\perf\lzma2-benchmark.summary.json'
$junitPath = Join-Path $root 'artifacts\test-results\Lzma.Tests.junit.xml'
$consolePath = Join-Path $root 'artifacts\test-results\Lzma.Tests.console.txt'
$ciManifestPath = Join-Path $root 'artifacts\ci\ci-artifacts-manifest.json'
$compatPath = Join-Path $root 'artifacts\compat\xz-cross-tool-report.json'
$fixtureManifestPath = Join-Path $root 'artifacts\fixtures\sha256-fixtures.json'
$matchFinderTracePath = Join-Path $root 'artifacts\match-finder\sdk-trace-parity.json'
$corruptXzManifestPath = Join-Path $root 'tests\fixtures\manifests\corrupt-xz-regressions.json'
$rawLzmaReleaseManifestPath = Join-Path $root 'tests\fixtures\manifests\raw-lzma-sdk-release-corpus.json'
$backupPath = Join-Path ([IO.Path]::GetTempPath()) ("lzma2-benchmark.{0}.json" -f ([Guid]::NewGuid().ToString('N')))
$perfSamplesBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("lzma2-benchmark.{0}.samples.csv" -f ([Guid]::NewGuid().ToString('N')))
$perfSummaryBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("lzma2-benchmark.{0}.summary.json" -f ([Guid]::NewGuid().ToString('N')))
$junitBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("Lzma.Tests.{0}.junit.xml" -f ([Guid]::NewGuid().ToString('N')))
$consoleBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("Lzma.Tests.{0}.console.txt" -f ([Guid]::NewGuid().ToString('N')))
$ciManifestBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("ci-artifacts-manifest.{0}.json" -f ([Guid]::NewGuid().ToString('N')))
$compatBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("xz-cross-tool-report.{0}.json" -f ([Guid]::NewGuid().ToString('N')))
$fixtureManifestBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("sha256-fixtures.{0}.json" -f ([Guid]::NewGuid().ToString('N')))
$matchFinderTraceBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("sdk-trace-parity.{0}.json" -f ([Guid]::NewGuid().ToString('N')))
$corruptXzManifestBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("corrupt-xz-regressions.{0}.json" -f ([Guid]::NewGuid().ToString('N')))
$rawLzmaReleaseManifestBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("raw-lzma-sdk-release-corpus.{0}.json" -f ([Guid]::NewGuid().ToString('N')))
$projectBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("Lzma2.{0}.dproj" -f ([Guid]::NewGuid().ToString('N')))
$trackedBackupPath = Join-Path ([IO.Path]::GetTempPath()) ("tracked-evidence.{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
$script:HasPerformanceArtifacts = (Test-Path -LiteralPath $perfJsonPath) -and
  (Test-Path -LiteralPath $perfSamplesPath) -and
  (Test-Path -LiteralPath $perfSummaryPath)

function Assert-TextContains([string]$Name, [string]$Text, [string]$Needle) {
  if ($Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw "$Name is missing required contract text: $Needle"
  }
}

function Assert-TextMatches([string]$Name, [string]$Text, [string]$Pattern) {
  if ($Text -notmatch $Pattern) {
    throw "$Name is missing required contract pattern: $Pattern"
  }
}

function Assert-TextDoesNotContain([string]$Name, [string]$Text, [string]$Needle) {
  if ($Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw "$Name still contains stale contract text: $Needle"
  }
}

function Assert-TextBeforeAfterLast([string]$Name, [string]$Text, [string]$Anchor, [string]$Earlier, [string]$Later) {
  $anchorIndex = $Text.LastIndexOf($Anchor, [StringComparison]::OrdinalIgnoreCase)
  if ($anchorIndex -lt 0) {
    throw "$Name is missing required anchor text: $Anchor"
  }

  $earlierIndex = $Text.IndexOf($Earlier, $anchorIndex, [StringComparison]::OrdinalIgnoreCase)
  $laterIndex = $Text.IndexOf($Later, $anchorIndex, [StringComparison]::OrdinalIgnoreCase)
  if (($earlierIndex -lt 0) -or ($laterIndex -lt 0) -or ($earlierIndex -ge $laterIndex)) {
    throw "$Name must place '$Earlier' before '$Later' after '$Anchor'"
  }
}

function Assert-ScriptContracts {
  $runCi = Get-Content -LiteralPath (Join-Path $root 'tests\run-ci.ps1') -Raw
  $validator = Get-Content -LiteralPath (Join-Path $root 'tests\validate-artifacts.ps1') -Raw
  $releaseAcceptance = Get-Content -LiteralPath (Join-Path $root 'docs\release-acceptance.md') -Raw
  $releaseScope = Get-Content -LiteralPath (Join-Path $root 'docs\release-scope.md') -Raw
  $performanceDocs = Get-Content -LiteralPath (Join-Path $root 'docs\performance.md') -Raw
  $compatibilityDocs = Get-Content -LiteralPath (Join-Path $root 'docs\compatibility.md') -Raw
  $apiDocs = Get-Content -LiteralPath (Join-Path $root 'docs\api.md') -Raw
  $memoryDocs = Get-Content -LiteralPath (Join-Path $root 'docs\memory.md') -Raw
  $runCrossTool = Get-Content -LiteralPath (Join-Path $root 'tests\run-cross-tool.ps1') -Raw
  $runPerformance = Get-Content -LiteralPath (Join-Path $root 'tests\run-performance.ps1') -Raw
  $generateFixtures = Get-Content -LiteralPath (Join-Path $root 'tests\generate-fixtures.ps1') -Raw
  $qaTools = Get-Content -LiteralPath (Join-Path $root 'tests\qa-tools.ps1') -Raw
  $qaToolsConfig = Get-Content -LiteralPath (Join-Path $root 'tests\qa-tools.json') -Raw

  Assert-TextContains 'runtime executable audit' $validator '7zr'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"version": "26.01"'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"displayName": "XZ Utils'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"source": "XZ Utils official Windows binaries"'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"archiveSha256": "b860f17f9df3c0524dd2ef2c639ab5e43ad0006b77b8f7bb6d191bf528536885"'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"archiveSha256": "8d0048ee51177b11ef1613959c2a268c951f4e7f6fb3706e681e00e34bb6d5e3"'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"pinMode": "archive-sha256"'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"defaultRelativePathTemplate": "xz-utils-{version}\\bin_x86-64\\xz.exe"'
  Assert-TextContains 'pinned QA tool config' $qaToolsConfig '"pathPatternTemplate": "(?i)\\\\xz-utils-{version}\\\\bin_x86-64\\\\xz\\.exe$"'
  Assert-TextContains 'pinned QA tool bootstrap' $qaToolsConfig 'https://www.7-zip.org/a/lzma2601.7z'
  Assert-TextContains 'pinned QA tool bootstrap' $qaToolsConfig '"archiveUrl": "https://github.com/tukaani-project/xz/releases/download/'
  Assert-TextContains 'pinned QA tool bootstrap' $qaToolsConfig '"archiveFile": "xz-'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'Pinned LZMA SDK archive hash mismatch'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'Pinned XZ Utils Windows archive hash mismatch'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'Install-LzmaSdkQATools'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'Install-XzUtilsQATools'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'Expand-LzmaQAToolTemplate'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'C:\Program Files\7-Zip\7z.exe'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'tar.exe'
  Assert-TextContains 'pinned QA tool bootstrap' $qaTools 'Expand-Archive'
  Assert-TextContains 'pinned QA tool resolver' $runCi 'Resolve-LzmaQATools'
  Assert-TextContains 'pinned QA tool resolver' $runCrossTool 'Resolve-LzmaQATools'
  Assert-TextContains 'pinned QA tool resolver' $runPerformance 'Resolve-LzmaQATools'
  Assert-TextContains 'pinned QA tool resolver' $generateFixtures 'Resolve-LzmaQATool'
  Assert-TextContains 'pinned QA tool manifest validation' $validator 'Assert-PinnedQAToolEvidence'
  Assert-TextContains 'pinned QA tool manifest validation' $validator 'stale pin mode metadata'
  Assert-TextContains 'pinned QA tool manifest validation' $validator 'pinned archive SHA-256 metadata'
  Assert-TextContains 'pinned QA tool manifest validation' $validator 'pinned source path pattern'
  Assert-TextContains 'release work-root validation' $validator 'Get-ReleaseBenchmarkWorkRoot'
  Assert-TextContains 'release work-root validation' $validator 'release performance work root or RAM work root'
  Assert-TextContains 'release CI default work-root resolution' $runCi 'Get-DefaultPerformanceWorkRoot'
  Assert-TextContains 'release CI default work-root resolution' $runCi 'PerformanceWorkRoot = Get-DefaultPerformanceWorkRoot'
  Assert-TextContains 'cross-tool CI default work-root resolution' $runCi 'if ($SevenZip'
  Assert-TextContains 'cross-tool CI default work-root resolution' $runCi 'compat-work'
  Assert-TextContains 'inner CI external-tool isolation' $runCi '$InnerModeDisablesExternalTools'
  Assert-TextContains 'inner CI external-tool isolation' $runCi 'inner mode ignores LZMA_TEST_7Z/LZMA_TEST_XZ/LZMA_TEST_LZMA'
  Assert-TextContains 'inner CI external-tool isolation' $runCi '$RequireExternalTools = $false'
  Assert-TextContains 'inner CI external-tool isolation' $runCi 'Remove-Item Env:\LZMA_TEST_7Z'
  Assert-TextContains 'inner CI external-tool isolation' $runCi 'New-LzmaQAToolRecord ''sevenZip'' '''' $false ''inner-disabled'''
  Assert-TextContains 'inner CI MSBuild boundary' $runCi '$ShouldRunMSBuild = $Mode -ne ''inner'''
  Assert-TextContains 'inner CI MSBuild boundary' $runCi '$ShouldRunMSBuild -and -not (Test-Path -LiteralPath $MsBuild)'
  Assert-TextContains 'RAM-backed compat work root' $runCi '$compatWorkRootBase = if ($RamWorkRoot)'
  Assert-TextContains 'RAM-backed compat work root' $runCi '$crossRootIsRamBacked = -not [string]::IsNullOrWhiteSpace($RamWorkRoot)'
  Assert-TextContains 'RAM-backed compat work root' $runCi '$crossArgs += ''-RamBackedWorkRoot'''
  Assert-TextContains 'RAM-backed compat work root' $runCrossTool '[switch]$RamBackedWorkRoot'
  Assert-TextContains 'RAM-backed compat work root' $runCrossTool '[IO.DriveType]::Ram'
  Assert-TextContains 'RAM-backed performance work root' $runPerformance '[IO.DriveType]::Ram'
  Assert-TextContains 'RAM-backed compat work root validation' $validator '$compatWorkRootIsRamBacked'
  Assert-TextContains 'RAM-backed compat work root validation' $validator 'Assert-CiBenchmarkWorkRoot ([string]$compat.workRoot) $compatWorkRootIsRamBacked'
  Assert-TextContains 'RAM-backed compat work root validation' $validator 'marked RAM-backed but drive'
  Assert-TextContains 'fixed SSD work root validation' $validator 'Assert-DriveIsFixedSsd'
  Assert-TextContains 'fixed SSD work root validation' $validator 'Get-Partition -DriveLetter'
  Assert-TextContains 'fixed SSD work root validation' $validator '[string]$physicalDisk.MediaType -ne ''SSD'''
  Assert-TextContains 'quick performance validation contract' $validator '$ShouldValidatePerformanceArtifacts'
  Assert-TextContains 'quick performance validation contract' $validator 'unexpected performance artifact outside data-only allowlist'
  Assert-TextContains 'performance optimization plan location' $runPerformance 'artifacts/ci/optimization-plan.md'
  Assert-TextDoesNotContain 'performance optimization plan location' $runPerformance 'artifacts/perf/optimization-plan.md'
  Assert-TextDoesNotContain 'performance optimization plan allowlist' $validator 'artifacts/perf/optimization-plan.md'
  Assert-TextContains 'non-release image artifact validation' $validator 'artifacts/perf/*.png'
  Assert-TextContains 'non-release image artifact validation' $validator 'artifacts/perf/*.svg'
  Assert-TextContains 'positive docs validation' $validator 'Assert-PositiveDocumentationContracts'
  Assert-TextContains 'match-finder SDK trace artifact validation' $validator 'sdk-trace-parity.json'
  Assert-TextContains 'match-finder SDK trace artifact validation' $validator 'hc4-boundary-tail'
  Assert-TextContains 'match-finder SDK trace artifact validation' $validator 'hc5-skip-range'
  Assert-TextContains 'match-finder SDK trace artifact validation' $validator 'bt4-dictionary-limit'
  Assert-TextContains 'CI artifact manifest' $runCi 'artifactsDir ''match-finder'''
  Assert-TextBeforeAfterLast 'soak summary manifest contract' $runCi 'Write fixture SHA-256 manifest' 'soak-summary.txt' 'Write-CiArtifactsManifest'
  Assert-TextContains 'cross-tool work-root validation' $runCrossTool '.lzma2-delphi-cross-tool-workdir'
  Assert-TextContains 'cross-tool work-root validation' $runCrossTool 'must not be the repository root'
  Assert-TextContains 'cross-tool work-root validation' $validator 'Compatibility report is missing cross-tool workDir evidence'
  Assert-TextContains 'release clean source tree validation' $runCi '--untracked-files=all'
  Assert-TextContains 'release clean source tree validation' $validator '--untracked-files=all'
  Assert-TextContains 'release clean source tree validation' (Get-Content -LiteralPath (Join-Path $root '.github\workflows\windows-delphi.yml') -Raw) '--untracked-files=all'

  Assert-TextContains 'benchmark corpus cache contract' $runPerformance 'Initialize-BenchmarkCorpusCache'
  Assert-TextContains 'benchmark corpus cache contract' $runPerformance 'Get-BenchmarkCorpusCacheKey'
  Assert-TextContains 'benchmark corpus cache contract' $runPerformance 'Use-BenchmarkCorpusFile'
  Assert-TextContains 'benchmark corpus cache validation' $validator 'Assert-BenchmarkCorpusCacheEvidence'
  Assert-TextContains 'benchmark corpus cache validation' $validator 'release corpus cache evidence'
  Assert-TextContains 'optimum parser decision validation' $validator 'fullOptimumDecisionCount'
  Assert-TextContains 'optimum parser decision validation' (Get-Content -LiteralPath (Join-Path $root 'tools\Lzma2.dpr') -Raw) 'Encode full optimum decisions'
  Assert-TextContains 'release MT active-worker validation' $validator '$delphiGeneratedXzMtAcceptances = @(''xz-delphi-mt-decode-speedup'', ''xz-delphi-mt-decode-no-speedup'')'
  Assert-TextContains 'release MT active-worker validation' $validator '$delphiPatternedXzMtAcceptances = @(''xz-delphi-patterned-mt-decode-speedup'', ''xz-delphi-patterned-mt-decode-no-speedup'')'

  Assert-TextContains 'quick CI contract' $runCi '$ShouldRunPerformanceScript'
  Assert-TextMatches 'quick CI contract' $runCi '\$ShouldRunPerformanceScript\s*=\s*\$Mode\s+-in\s+@\(''release'',\s*''soak''\)'
  Assert-TextContains 'quick CI contract' $runCi 'quick mode skips tests/run-performance.ps1'

  Assert-TextContains 'release acceptance docs' $releaseAcceptance '-RamWorkRoot <RAM_WORKROOT>'
  Assert-TextContains 'release acceptance docs' $releaseAcceptance 'quick` mode does not run `tests/run-performance.ps1`'
  Assert-TextContains 'release acceptance docs' $releaseAcceptance 'GitHub Actions metadata when'
  Assert-TextContains 'release scope docs' $releaseScope 'does not run `tests/run-performance.ps1`'
  Assert-TextContains 'performance docs' $performanceDocs 'quick` does not run `tests/run-performance.ps1`'
  Assert-TextContains 'performance docs' $performanceDocs 'GitHub run id/SHA/ref/attempt and workflow name are required when the manifest contains GitHub Actions context'
  Assert-TextContains 'compatibility docs' $compatibilityDocs 'GitHub Actions metadata when'
  Assert-TextDoesNotContain 'public API docs' $apiDocs 'one-shot raw'
  Assert-TextDoesNotContain 'memory docs' $memoryDocs 'one-shot raw'
  Assert-TextDoesNotContain 'performance docs' $performanceDocs 'bounded `TThread` workers'
  Assert-TextDoesNotContain 'memory docs' $memoryDocs 'bounded output buffer'

  $legacySpecPath = Join-Path $root 'TZ_LZMA2_DELPHI_NATIVE_PORT.md'
  if (Test-Path -LiteralPath $legacySpecPath) {
    $legacySpec = Get-Content -LiteralPath $legacySpecPath -Raw
    Assert-TextDoesNotContain 'legacy native-port spec' $legacySpec 'lzma2-delphi-graph'
    Assert-TextDoesNotContain 'legacy native-port spec' $legacySpec 'README-style график'
  }
}

Assert-ScriptContracts
if ($ScriptContractOnly) {
  Write-Host 'Script contract tests passed.'
  return
}

function Invoke-Validator {
  $args = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $root 'tests\validate-artifacts.ps1')
  )
  if ($RequireExternalTools) {
    $args += '-RequireExternalTools'
  }
  if ($RequireReleaseCorpus) {
    $args += '-RequireReleaseCorpus'
  }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & powershell @args 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
  }
  finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
  }
}

function Test-ValidatorOutputMatches([string]$Output, [string]$ExpectedPattern) {
  if ($Output -match $ExpectedPattern) {
    return $true
  }

  $normalizedOutput = $Output -replace '\s+', ' '
  if ($normalizedOutput -match $ExpectedPattern) {
    return $true
  }

  $compactOutput = $Output -replace '\s+', ''
  $compactPattern = $ExpectedPattern -replace '\s+', ''
  return $compactOutput -match $compactPattern
}

function Assert-ValidatorFailureMessage([string]$Name, [string]$Output, [string]$ExpectedPattern) {
  if (-not (Test-ValidatorOutputMatches $Output $ExpectedPattern)) {
    throw "Artifact validator failed for $Name with unexpected message: $Output"
  }
}

function Restore-BackupFile([string]$BackupPath, [string]$TargetPath) {
  if (Test-Path -LiteralPath $TargetPath) {
    Remove-Item -LiteralPath $TargetPath -Force
  }
  Move-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
}

function Invoke-NegativeCase([string]$Name, [scriptblock]$MutateRows, [string]$ExpectedPattern) {
  if (-not $script:HasPerformanceArtifacts) {
    return
  }
  Copy-Item -LiteralPath $perfJsonPath -Destination $backupPath -Force
  Copy-Item -LiteralPath $perfSummaryPath -Destination $perfSummaryBackupPath -Force
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    $rows = Get-Content -LiteralPath $perfJsonPath -Raw | ConvertFrom-Json
    $mutatedRows = & $MutateRows $rows
    if ($null -ne $mutatedRows) {
      $rows = @($mutatedRows)
    }
    $rows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $perfJsonPath -Encoding UTF8
    Sync-CiManifestArtifact $perfJsonPath
    $summary = Get-Content -LiteralPath $perfSummaryPath -Raw | ConvertFrom-Json
    if ($null -ne $summary.rows -and $summary.rows.PSObject.Properties.Name -contains 'count') {
      $summary.rows.count = @($rows).Count
      $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $perfSummaryPath -Encoding UTF8
      Sync-CiManifestArtifact $perfSummaryPath
    }

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $backupPath $perfJsonPath
    Restore-BackupFile $perfSummaryBackupPath $perfSummaryPath
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Invoke-MissingArtifactNegativeCase([string]$Name, [string]$ArtifactPath, [string]$ArtifactBackupPath, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $ArtifactPath -Destination $ArtifactBackupPath -Force
  try {
    Remove-Item -LiteralPath $ArtifactPath -Force

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $ArtifactBackupPath $ArtifactPath
  }
}

function Invoke-MatchFinderTraceNegativeCase([string]$Name, [scriptblock]$MutateTrace, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $matchFinderTracePath -Destination $matchFinderTraceBackupPath -Force
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    $trace = Get-Content -LiteralPath $matchFinderTracePath -Raw | ConvertFrom-Json
    $mutatedTrace = & $MutateTrace $trace
    if ($null -ne $mutatedTrace) {
      $trace = $mutatedTrace
    }
    $trace | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $matchFinderTracePath -Encoding UTF8
    Sync-CiManifestArtifact $matchFinderTracePath

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $matchFinderTraceBackupPath $matchFinderTracePath
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Invoke-SummaryJsonNegativeCase([string]$Name, [scriptblock]$MutateSummary, [string]$ExpectedPattern) {
  if (-not $script:HasPerformanceArtifacts) {
    return
  }
  Copy-Item -LiteralPath $perfSummaryPath -Destination $perfSummaryBackupPath -Force
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    $summary = Get-Content -LiteralPath $perfSummaryPath -Raw | ConvertFrom-Json
    $mutatedSummary = & $MutateSummary $summary
    if ($null -ne $mutatedSummary) {
      $summary = $mutatedSummary
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $perfSummaryPath -Encoding UTF8
    Sync-CiManifestArtifact $perfSummaryPath

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $perfSummaryBackupPath $perfSummaryPath
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Invoke-CiManifestAndSummaryNegativeCase([string]$Name, [scriptblock]$MutateEvidence, [string]$ExpectedPattern) {
  if (-not $script:HasPerformanceArtifacts) {
    return
  }
  Copy-Item -LiteralPath $perfSummaryPath -Destination $perfSummaryBackupPath -Force
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    $manifest = Get-Content -LiteralPath $ciManifestPath -Raw | ConvertFrom-Json
    $summary = Get-Content -LiteralPath $perfSummaryPath -Raw | ConvertFrom-Json
    & $MutateEvidence $manifest $summary
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ciManifestPath -Encoding UTF8
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $perfSummaryPath -Encoding UTF8
    Sync-CiManifestArtifact $perfSummaryPath

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $perfSummaryBackupPath $perfSummaryPath
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Sync-CiManifestArtifact([string]$ArtifactPath) {
  $manifest = Get-Content -LiteralPath $ciManifestPath -Raw | ConvertFrom-Json
  $relativePath = $ArtifactPath.Substring($root.Length).TrimStart('\') -replace '\\', '/'
  $artifactRecord = @($manifest.artifacts | Where-Object { $_.path -eq $relativePath }) | Select-Object -First 1
  if (-not $artifactRecord) {
    throw "CI manifest does not track mutated artifact: $relativePath"
  }
  $artifactInfo = Get-Item -LiteralPath $ArtifactPath
  $artifactHash = Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256
  $artifactRecord.bytes = [int64]$artifactInfo.Length
  $artifactRecord.sha256 = $artifactHash.Hash.ToLowerInvariant()
  $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ciManifestPath -Encoding UTF8
}

function Invoke-CompatReportNegativeCase([string]$Name, [scriptblock]$MutateReport, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $compatPath -Destination $compatBackupPath -Force
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    $report = Get-Content -LiteralPath $compatPath -Raw | ConvertFrom-Json
    $mutatedReport = & $MutateReport $report
    if ($null -ne $mutatedReport) {
      $report = $mutatedReport
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $compatPath -Encoding UTF8
    Sync-CiManifestArtifact $compatPath

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $compatBackupPath $compatPath
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Invoke-JUnitNegativeCase([string]$Name, [string]$TestCaseName, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $junitPath -Destination $junitBackupPath -Force
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    [xml]$junit = Get-Content -LiteralPath $junitPath -Raw
    $target = @($junit.testsuites.testsuite.testcase | Where-Object { $_.name -eq $TestCaseName }) |
      Select-Object -First 1
    if (-not $target) {
      throw "Could not find JUnit test case to remove: $TestCaseName"
    }
    [void]$target.ParentNode.RemoveChild($target)
    $junit.Save($junitPath)
    Sync-CiManifestArtifact $junitPath

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $junitBackupPath $junitPath
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Invoke-FixtureManifestNegativeCase([string]$Name, [scriptblock]$MutateManifest, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $fixtureManifestPath -Destination $fixtureManifestBackupPath -Force
  try {
    $manifest = Get-Content -LiteralPath $fixtureManifestPath -Raw | ConvertFrom-Json
    $mutatedManifest = & $MutateManifest $manifest
    if ($null -ne $mutatedManifest) {
      $manifest = $mutatedManifest
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifestPath -Encoding UTF8

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $fixtureManifestBackupPath $fixtureManifestPath
  }
}

function Invoke-CorruptXzManifestNegativeCase([string]$Name, [scriptblock]$MutateManifest, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $corruptXzManifestPath -Destination $corruptXzManifestBackupPath -Force
  Copy-Item -LiteralPath $fixtureManifestPath -Destination $fixtureManifestBackupPath -Force
  try {
    $manifest = Get-Content -LiteralPath $corruptXzManifestPath -Raw | ConvertFrom-Json
    $mutatedManifest = & $MutateManifest $manifest
    if ($null -ne $mutatedManifest) {
      $manifest = $mutatedManifest
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $corruptXzManifestPath -Encoding UTF8

    $fixtureManifest = Get-Content -LiteralPath $fixtureManifestPath -Raw | ConvertFrom-Json
    $record = @($fixtureManifest.manifests | Where-Object { $_.path -eq 'tests/fixtures/manifests/corrupt-xz-regressions.json' }) |
      Select-Object -First 1
    if (-not $record) {
      throw 'Could not find corrupt XZ regression manifest record to update.'
    }
    $file = Get-Item -LiteralPath $corruptXzManifestPath
    $record.bytes = $file.Length
    $record.sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $corruptXzManifestPath).Hash.ToLowerInvariant()
    $fixtureManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifestPath -Encoding UTF8

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $corruptXzManifestBackupPath $corruptXzManifestPath
    Restore-BackupFile $fixtureManifestBackupPath $fixtureManifestPath
  }
}

function Invoke-RawLzmaReleaseManifestNegativeCase([string]$Name, [scriptblock]$MutateManifest, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $rawLzmaReleaseManifestPath -Destination $rawLzmaReleaseManifestBackupPath -Force
  Copy-Item -LiteralPath $fixtureManifestPath -Destination $fixtureManifestBackupPath -Force
  try {
    $manifest = Get-Content -LiteralPath $rawLzmaReleaseManifestPath -Raw | ConvertFrom-Json
    $mutatedManifest = & $MutateManifest $manifest
    if ($null -ne $mutatedManifest) {
      $manifest = $mutatedManifest
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rawLzmaReleaseManifestPath -Encoding UTF8

    $fixtureManifest = Get-Content -LiteralPath $fixtureManifestPath -Raw | ConvertFrom-Json
    $record = @($fixtureManifest.manifests | Where-Object { $_.path -eq 'tests/fixtures/manifests/raw-lzma-sdk-release-corpus.json' }) |
      Select-Object -First 1
    if (-not $record) {
      throw 'Could not find raw LZMA release corpus manifest record to update.'
    }
    $file = Get-Item -LiteralPath $rawLzmaReleaseManifestPath
    $record.bytes = $file.Length
    $record.sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawLzmaReleaseManifestPath).Hash.ToLowerInvariant()
    $fixtureManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureManifestPath -Encoding UTF8

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $rawLzmaReleaseManifestBackupPath $rawLzmaReleaseManifestPath
    Restore-BackupFile $fixtureManifestBackupPath $fixtureManifestPath
  }
}

function Invoke-ConsoleNegativeCase([string]$Name, [scriptblock]$MutateText, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $consolePath -Destination $consoleBackupPath -Force
  try {
    $text = Get-Content -LiteralPath $consolePath -Raw
    $mutatedText = & $MutateText $text
    if ($null -ne $mutatedText) {
      $text = [string]$mutatedText
    }
    Set-Content -LiteralPath $consolePath -Encoding UTF8 -Value $text

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $consoleBackupPath $consolePath
  }
}

function Invoke-RuntimeSourceNegativeCase([string]$Name, [string]$RelativePath, [string]$Content, [string]$ExpectedPattern) {
  $probePath = Join-Path $root $RelativePath
  if (Test-Path -LiteralPath $probePath) {
    throw "Runtime dependency negative-test probe already exists: $RelativePath"
  }
  try {
    Set-Content -LiteralPath $probePath -Encoding UTF8 -Value $Content

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    if (Test-Path -LiteralPath $probePath) {
      Remove-Item -LiteralPath $probePath -Force
    }
  }
}

function Invoke-RuntimeSourceAcceptedCase([string]$Name, [string]$RelativePath, [string]$Content) {
  $probePath = Join-Path $root $RelativePath
  if (Test-Path -LiteralPath $probePath) {
    throw "Runtime dependency accepted-case probe already exists: $RelativePath"
  }
  try {
    Set-Content -LiteralPath $probePath -Encoding UTF8 -Value $Content

    $result = Invoke-Validator
    if ($result.ExitCode -ne 0) {
      throw "Artifact validator unexpectedly rejected accepted case ${Name}: $($result.Output)"
    }
  }
  finally {
    if (Test-Path -LiteralPath $probePath) {
      Remove-Item -LiteralPath $probePath -Force
    }
  }
}

function Invoke-DocsNegativeCase([string]$Name, [string]$RelativePath, [string]$Content, [string]$ExpectedPattern) {
  $probePath = Join-Path $root $RelativePath
  if (Test-Path -LiteralPath $probePath) {
    throw "Documentation negative-test probe already exists: $RelativePath"
  }
  try {
    Set-Content -LiteralPath $probePath -Encoding UTF8 -Value $Content

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    if (Test-Path -LiteralPath $probePath) {
      Remove-Item -LiteralPath $probePath -Force
    }
  }
}

function Invoke-ProjectNegativeCase([string]$Name, [string]$RelativePath, [scriptblock]$MutateText, [string]$ExpectedPattern) {
  $projectPath = Join-Path $root $RelativePath
  Copy-Item -LiteralPath $projectPath -Destination $projectBackupPath -Force
  try {
    $text = Get-Content -LiteralPath $projectPath -Raw
    $mutatedText = & $MutateText $text
    Set-Content -LiteralPath $projectPath -Encoding UTF8 -Value ([string]$mutatedText)

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $projectBackupPath $projectPath
  }
}

function Invoke-UntrackedReferencedSourceNegativeCase([string]$Name, [string]$ExpectedPattern) {
  $relativeSourcePath = 'src\__untracked_source_probe.pas'
  $sourcePath = Join-Path $root $relativeSourcePath
  $projectPath = Join-Path $root 'tools\Lzma2.dproj'
  Copy-Item -LiteralPath $projectPath -Destination $projectBackupPath -Force
  if (Test-Path -LiteralPath $sourcePath) {
    throw "Untracked source negative-test probe already exists: $relativeSourcePath"
  }
  try {
    Set-Content -LiteralPath $sourcePath -Encoding UTF8 -Value @'
unit __untracked_source_probe;

interface

implementation

end.
'@
    $text = Get-Content -LiteralPath $projectPath -Raw
    $replacement = '    <DCCReference Include="..\src\__untracked_source_probe.pas"/>' + "`r`n" + '  </ItemGroup>'
    $text = $text -replace '</ItemGroup>', $replacement
    Set-Content -LiteralPath $projectPath -Encoding UTF8 -Value $text

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $projectBackupPath $projectPath
    if (Test-Path -LiteralPath $sourcePath) {
      Remove-Item -LiteralPath $sourcePath -Force
    }
  }
}

function Invoke-CiManifestNegativeCase([string]$Name, [scriptblock]$MutateManifest, [string]$ExpectedPattern) {
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    $manifest = Get-Content -LiteralPath $ciManifestPath -Raw | ConvertFrom-Json
    $mutatedManifest = & $MutateManifest $manifest
    if ($null -ne $mutatedManifest) {
      $manifest = $mutatedManifest
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ciManifestPath -Encoding UTF8

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Invoke-CiManifestAcceptedCase([string]$Name, [scriptblock]$MutateManifest) {
  Copy-Item -LiteralPath $ciManifestPath -Destination $ciManifestBackupPath -Force
  try {
    $manifest = Get-Content -LiteralPath $ciManifestPath -Raw | ConvertFrom-Json
    $mutatedManifest = & $MutateManifest $manifest
    if ($null -ne $mutatedManifest) {
      $manifest = $mutatedManifest
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ciManifestPath -Encoding UTF8

    $result = Invoke-Validator
    if ($result.ExitCode -ne 0) {
      throw "Artifact validator rejected accepted case ${Name}: $($result.Output)"
    }
  }
  finally {
    Restore-BackupFile $ciManifestBackupPath $ciManifestPath
  }
}

function Invoke-ForbiddenArtifactFileNegativeCase([string]$Name, [string]$RelativePath, [string]$Content, [string]$ExpectedPattern) {
  $probePath = Join-Path $root $RelativePath
  if (Test-Path -LiteralPath $probePath) {
    throw "Forbidden artifact negative-test probe already exists: $RelativePath"
  }
  try {
    $parent = Split-Path -Parent $probePath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Set-Content -LiteralPath $probePath -Encoding UTF8 -Value $Content

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    if (Test-Path -LiteralPath $probePath) {
      Remove-Item -LiteralPath $probePath -Force
    }
  }
}

function Invoke-TrackedTreeNegativeCase([string]$Name, [string]$RelativePath, [scriptblock]$MutateText, [string]$ExpectedPattern) {
  $trackedPath = Join-Path $root $RelativePath
  Copy-Item -LiteralPath $trackedPath -Destination $trackedBackupPath -Force
  try {
    $text = Get-Content -LiteralPath $trackedPath -Raw
    $mutatedText = & $MutateText $text
    Set-Content -LiteralPath $trackedPath -Encoding UTF8 -Value ([string]$mutatedText)

    $result = Invoke-Validator
    if ($result.ExitCode -eq 0) {
      throw "Artifact validator unexpectedly accepted negative case: $Name"
    }
    Assert-ValidatorFailureMessage $Name $result.Output $ExpectedPattern
  }
  finally {
    Restore-BackupFile $trackedBackupPath $trackedPath
  }
}

Invoke-JUnitNegativeCase 'missing raw LZMA end-marker JUnit evidence' `
  'RawLzmaEndMarkerRoundTripsUnknownSize' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA malformed JUnit evidence' `
  'RawLzmaInvalidPropsFails' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA2 malformed JUnit evidence' `
  'RawLzma2InvalidControlFails' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z round-trip JUnit evidence' `
  'SevenZipSingleFileRoundTrips' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z LZMA coder JUnit evidence' `
  'SevenZipLzmaCoderSingleFileDecodes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z LZMA2 encoded-header JUnit evidence' `
  'SevenZipEncodedHeaderLzma2SingleFileDecodes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z LZMA encoded-header JUnit evidence' `
  'SevenZipEncodedHeaderLzmaSingleFileDecodes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z encoded-header unsupported-coder JUnit evidence' `
  'SevenZipEncodedHeaderUnsupportedCoderFailsClosed' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z multi-folder LZMA2 JUnit evidence' `
  'SevenZipMultiFolderLzma2ArchiveExtractsAllEntries' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z multi-folder LZMA JUnit evidence' `
  'SevenZipMultiFolderLzmaArchiveExtractsAllEntries' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z multi-file LZMA2 encode JUnit evidence' `
  'SevenZipMultiFileLzma2EncodeListsAndExtractsAllEntries' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z multi-file LZMA encode JUnit evidence' `
  'SevenZipMultiFileLzmaEncodeListsAndExtractsAllEntries' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z multi-file stream rejection JUnit evidence' `
  'SevenZipMultiFileFailsSingleStreamDecode' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z solid substream JUnit evidence' `
  'SevenZipSolidLzma2SubstreamsExtractAsSeparateFiles' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z solid LZMA substream JUnit evidence' `
  'SevenZipSolidLzmaSubstreamsExtractAsSeparateFiles' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z source-position JUnit evidence' `
  'SevenZipDecodeLeavesSourceAfterArchive' 'missing required test case'

Invoke-JUnitNegativeCase 'missing native 7z CRC failure JUnit evidence' `
  'SevenZipHeaderCrcCorruptionFails' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA container JUnit evidence' `
  'LzmaStandaloneRoundTripsKnownSize' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA end-marker encode JUnit evidence' `
  'LzmaStandaloneEncodeCanWriteUnknownSizeEndMarker' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA encode memory-limit JUnit evidence' `
  'LzmaStandaloneEncodeRejectsInputOverMemoryLimit' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA decode memory-limit JUnit evidence' `
  'LzmaStandaloneDecodeRejectsPackedInputOverMemoryLimit' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA encode cancellation JUnit evidence' `
  'LzmaStandaloneEncodeCancellation' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA decode cancellation JUnit evidence' `
  'LzmaStandaloneDecodeCancellation' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA known-size truncation JUnit evidence' `
  'LzmaStandaloneRejectsKnownSizeTruncation' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA unpack-size mismatch JUnit evidence' `
  'LzmaStandaloneRejectsUnpackSizeMismatch' 'missing required test case'

Invoke-JUnitNegativeCase 'missing standalone LZMA missing end-marker JUnit evidence' `
  'LzmaStandaloneRejectsUnknownSizeWithoutEndMarker' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ malformed JUnit evidence' `
  'XzBadStreamPaddingFails' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ Delta filter rejection JUnit evidence' `
  'XzDeltaFilterFailsUnsupported' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ BCJ filter rejection JUnit evidence' `
  'XzBcjFilterFailsUnsupported' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ filter-chain rejection JUnit evidence' `
  'XzFilterChainFailsUnsupported' 'missing required test case'

Invoke-JUnitNegativeCase 'missing fast-parser lookahead cache JUnit evidence' `
  'FastParserLookaheadCacheReusesReadMatchesOnce' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA native array cap JUnit evidence' `
  'RawLzmaStreamEncoderUsesSinkBackedRangeOutput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA stream profile match-finder JUnit evidence' `
  'RawLzmaStreamEncoderUsesProfileMatchFinder' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA stream committed progress JUnit evidence' `
  'RawLzmaStreamProgressReportsCommittedOutput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA stream final cancellation JUnit evidence' `
  'RawLzmaStreamFinalCancellationPrecedesRangeFlush' 'missing required test case'

Invoke-JUnitNegativeCase 'missing SDK raw LZMA end-marker streaming JUnit evidence' `
  'SdkFacadeLzmaEncoderStreamsEndMarkerPath' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA2 typed decode read-error JUnit evidence' `
  'RawLzma2DecodeReadFailureRaisesTypedReadError' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA2 typed encode read-error JUnit evidence' `
  'RawLzma2EncodeReadFailureRaisesTypedReadError' 'missing required test case'

Invoke-JUnitNegativeCase 'missing strict dictionary max JUnit evidence' `
  'DictionaryPropertyRejectsAboveMaxStrict' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC5 five-byte main hash JUnit evidence' `
  'HashChain5MatchFinderUsesFiveByteMainHash' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC5 SDK CRC hash-shape JUnit evidence' `
  'HashChain5MatchFinderUsesSdkCrcHashShape' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC5 SDK tail-gating JUnit evidence' `
  'HashChain5MatchFinderSkipsTailBelowFiveBytesLikeSdk' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC4/BT4 collision low-hash JUnit evidence' `
  'HashChain4AndBinaryTree4ExposeLowHashMatchThroughFourByteCollision' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC4/BT4 SDK tail-gating JUnit evidence' `
  'HashChain4AndBinaryTree4SkipTailBelowFourBytesLikeSdk' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC4 cyclic chain storage JUnit evidence' `
  'HashChain4MatchFinderUsesDictionaryCyclicChainStorage' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC5 cyclic chain storage JUnit evidence' `
  'HashChain5MatchFinderUsesDictionaryCyclicChainStorage' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC4 monotonic skip JUnit evidence' `
  'HashChain4SkipRangeMonotonicMatchesClassicInsertRange' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC4 monotonic skip inserted-marker JUnit evidence' `
  'HashChain4SkipRangeMonotonicMarksSkippedPositionsInserted' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC5 monotonic skip JUnit evidence' `
  'HashChain5SkipRangeMonotonicMatchesClassicInsertRange' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC5 monotonic skip inserted-marker JUnit evidence' `
  'HashChain5SkipRangeMonotonicMarksSkippedPositionsInserted' 'missing required test case'

Invoke-JUnitNegativeCase 'missing BT4 monotonic skip JUnit evidence' `
  'BinaryTree4SkipRangeMonotonicMatchesClassicInsertRange' 'missing required test case'

Invoke-JUnitNegativeCase 'missing LZMA2 2MiB chunk limit JUnit evidence' `
  'Lzma2CompressedOptionsUseSdkTwoMiBChunkLimit' 'missing required test case'

Invoke-JUnitNegativeCase 'missing BT4 cyclic son storage JUnit evidence' `
  'BinaryTree4MatchFinderUsesDictionaryCyclicSonStorage' 'missing required test case'

Invoke-JUnitNegativeCase 'missing match-finder idempotence JUnit evidence' `
  'MatchFinderReadMatchesIsIdempotent' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC4 SDK trace parity JUnit evidence' `
  'HashChain4MatchesSdkReferenceTrace' 'missing required test case'

Invoke-JUnitNegativeCase 'missing HC5 SDK trace parity JUnit evidence' `
  'HashChain5MatchesSdkReferenceTrace' 'missing required test case'

Invoke-JUnitNegativeCase 'missing BT4 SDK trace parity JUnit evidence' `
  'BinaryTree4MatchesSdkReferenceTrace' 'missing required test case'

Invoke-JUnitNegativeCase 'missing SDK trace parity artifact JUnit evidence' `
  'MatchFinderSdkReferenceTraceArtifactIsWritten' 'missing required test case'

Invoke-MissingArtifactNegativeCase 'missing SDK trace parity artifact' `
  $matchFinderTracePath $matchFinderTraceBackupPath 'Required artifact is missing: artifacts\\match-finder\\sdk-trace-parity.json'

Invoke-MatchFinderTraceNegativeCase 'SDK trace parity artifact only has smoke traces' {
  param($Trace)
  $Trace.traces = @($Trace.traces | Where-Object {
    [string]$_.id -in @('hc4-basic-two-heads', 'hc5-basic-two-heads', 'bt4-basic-two-heads')
  })
  return $Trace
} 'missing trace: hc4-boundary-tail'

Invoke-MatchFinderTraceNegativeCase 'SDK trace parity artifact has a failing trace' {
  param($Trace)
  $row = @($Trace.traces | Where-Object { [string]$_.id -eq 'hc4-basic-two-heads' }) | Select-Object -First 1
  if (-not $row) {
    throw 'Could not find match-finder trace to mutate.'
  }
  $row.status = 'failed'
  return $Trace
} 'non-passing trace: hc4-basic-two-heads'

Invoke-JUnitNegativeCase 'missing raw MT decode memory fallback JUnit evidence' `
  'RawLzma2MtDecodeFallsBackWhenOutputExceedsMemoryLimit' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw MT memory preflight JUnit evidence' `
  'RawLzma2MtDecodeChecksMemoryLimitBeforePayloadSnapshot' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw MT decode write-failure JUnit evidence' `
  'RawLzma2MtDecodeWriteFailurePropagates' 'missing required test case'

Invoke-JUnitNegativeCase 'missing streaming LZMA2 SDK facade JUnit evidence' `
  'SdkFacadeLzma2EncoderDoesNotSnapshotFullInput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing streaming LZMA2 SDK decoder facade JUnit evidence' `
  'SdkFacadeLzma2DecoderDoesNotSnapshotFullInput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing partial-output LZMA2 SDK facade JUnit evidence' `
  'SdkFacadeLzma2EncoderSupportsPartialSeqOutWrites' 'missing required test case'

Invoke-JUnitNegativeCase 'missing output SRes LZMA2 SDK facade JUnit evidence' `
  'SdkFacadeLzma2EncoderPropagatesSeqOutSRes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing CRC32 slicing JUnit evidence' `
  'Crc32XzKnownVectorAndSplitUpdate' 'missing required test case'

Invoke-JUnitNegativeCase 'missing CRC64 slicing JUnit evidence' `
  'Crc64XzKnownVectorAndSplitUpdate' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw MT decode tiny-work fallback JUnit evidence' `
  'RawLzma2MtDecodeFallsBackForTinyPackedIndependentUnits' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw MT decode high-expansion fallback JUnit evidence' `
  'RawLzma2MtDecodeFallsBackForHighlyExpandedTinyPackedUnits' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw MT decode cancellation JUnit evidence' `
  'RawLzma2MtDecodeCancellationDoesNotWriteOutput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing ordered streaming MT decode JUnit evidence' `
  'MtDecodeStreamsReadyUnitsBeforeSlowWorkersFinish' 'missing required test case'

Invoke-JUnitNegativeCase 'missing MT decode write-failure cancellation JUnit evidence' `
  'MtDecodeWriteFailureSignalsWorkersToCancel' 'missing required test case'

Invoke-JUnitNegativeCase 'missing non-blocking async decompress JUnit evidence' `
  'DecompressAsyncReturnsBeforeProgressCallbackCompletes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT decode write-failure diagnostics JUnit evidence' `
  'XzMtDecodeWriteFailurePropagatesAndPreservesDiagnostics' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT streaming payload JUnit evidence' `
  'XzMtDecodeDoesNotReadAllPayloadsBeforeFirstOutput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT decode Index packed-size JUnit evidence' `
  'XzMtDecodeUsesIndexPackedSizeWhenHeaderOmitsIt' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT decode Index unpacked-size JUnit evidence' `
  'XzMtDecodeUsesIndexUnpackedSizeWhenHeaderOmitsIt' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT decode single-block packed-size fallback JUnit evidence' `
  'XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutPackedSize' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT decode single-block unpacked-size fallback JUnit evidence' `
  'XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutUnpackedSize' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT decode memory fallback JUnit evidence' `
  'XzMtDecodeFallsBackWhenOutputExceedsMemoryLimit' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT memory preflight JUnit evidence' `
  'XzMtDecodeChecksMemoryLimitBeforePayloadSnapshot' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ MT nonzero memory-limit JUnit evidence' `
  'XzMtDecodeUsesNonzeroMemoryLimit' 'missing required test case'

Invoke-JUnitNegativeCase 'missing XZ multi-block encode diagnostics aggregation JUnit evidence' `
  'XzMultiBlockEncodeDiagnosticsAggregatesRawFastPathCounts' 'missing required test case'

Invoke-JUnitNegativeCase 'missing empty XZ multi-block diagnostics tuning JUnit evidence' `
  'XzMultiBlockEncodeDiagnosticsReportsTuningForEmptyInput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing mixed benchmark corpus ST subchunk fallback JUnit evidence' `
  'MixedBenchmarkCorpusRawEncodeCompressesRepeatingStripes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing mixed benchmark corpus MT subchunk fallback JUnit evidence' `
  'MixedBenchmarkCorpusRawMtEncodeCompressesRepeatingStripes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing incompressible-tail fallback JUnit evidence' `
  'IncompressibleProbeDoesNotCopyCompressibleTail' 'missing required test case'

Invoke-JUnitNegativeCase 'missing periodic raw fast-path JUnit evidence' `
  'PeriodicRawEncodeUsesFastPath' 'missing required test case'

Invoke-JUnitNegativeCase 'missing periodic chunked fast-path guard JUnit evidence' `
  'PeriodicFastPathRejectsChunkedPhaseReset' 'missing required test case'

Invoke-JUnitNegativeCase 'missing periodic phase-reset subchunk fast-path JUnit evidence' `
  'PeriodicPhaseResetRawEncodeUsesSubchunkFastPath' 'missing required test case'

Invoke-JUnitNegativeCase 'missing fast-lzma2 benchmark CLI contract JUnit evidence' `
  'FastLzma2StyleBenchmarkContractIsDocumented' 'missing required test case'

Invoke-JUnitNegativeCase 'missing data-only benchmark writer contract JUnit evidence' `
  'PerformanceRunnerWritesDataOnlyBenchmarkArtifacts' 'missing required test case'

Invoke-JUnitNegativeCase 'missing data-only artifact validator contract JUnit evidence' `
  'PerformanceValidatorEnforcesDataOnlyArtifacts' 'missing required test case'

Invoke-JUnitNegativeCase 'missing benchmark summary metadata contract JUnit evidence' `
  'PerformanceSummaryRequiresBenchmarkMetadata' 'missing required test case'

Invoke-JUnitNegativeCase 'missing corrupt XZ regression fixture JUnit evidence' `
  'CorruptXzRegressionFixturesFailWithExpectedErrors' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw LZMA release corpus fixture JUnit evidence' `
  'RawLzmaSdkReleaseCorpusFixturesDecode' 'missing required test case'

Invoke-JUnitNegativeCase 'missing raw encoder opt-in optimum-window JUnit evidence' `
  'RawLzmaEncoderOptInWindowPathRoundTripsAndWiresDriver' 'missing required test case'

Invoke-JUnitNegativeCase 'missing unreachable optimum replay JUnit evidence' `
  'OptimumReplayRejectsUnreachableEndNode' 'missing required test case'

Invoke-JUnitNegativeCase 'missing unreachable intermediate optimum replay JUnit evidence' `
  'OptimumReplayRejectsUnreachableIntermediateNode' 'missing required test case'

Invoke-JUnitNegativeCase 'missing unreachable Prev1 literal optimum replay JUnit evidence' `
  'OptimumReplayRejectsUnreachablePrev1LiteralNode' 'missing required test case'

Invoke-JUnitNegativeCase 'missing full optimum path replay JUnit evidence' `
  'OptimumReplayPathReturnsMatchLiteralRep0Commands' 'missing required test case'

Invoke-JUnitNegativeCase 'missing Prev1 root non-literal back optimum replay JUnit evidence' `
  'OptimumReplayRejectsPrev1LiteralRootNonLiteralBackPrev2' 'missing required test case'

Invoke-JUnitNegativeCase 'missing Prev1 root multi-byte literal optimum replay JUnit evidence' `
  'OptimumReplayRejectsPrev1LiteralRootMultiByteLiteralCommand' 'missing required test case'

Invoke-JUnitNegativeCase 'missing path-len predecessor mismatch optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenMismatchedPosPrev' 'missing required test case'

Invoke-JUnitNegativeCase 'missing path-len back mismatch optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenMismatchedBackPrev' 'missing required test case'

Invoke-JUnitNegativeCase 'missing extra-path non-rep0 optimum replay JUnit evidence' `
  'OptimumReplayRejectsExtraPathNonRep0BackPrev' 'missing required test case'

Invoke-JUnitNegativeCase 'missing extra-path Prev1 literal optimum replay JUnit evidence' `
  'OptimumReplayRejectsExtraPathWithPrev1LiteralFlag' 'missing required test case'

Invoke-JUnitNegativeCase 'missing extra-path BackPrev2 optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenExtraRep0WithBackPrev2Set' 'missing required test case'

Invoke-JUnitNegativeCase 'missing extra-path PosPrev2 optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenExtraRep0WithPosPrev2Set' 'missing required test case'

Invoke-JUnitNegativeCase 'missing extra-one non-literal back optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenExtraOneWithNonLiteralBack' 'missing required test case'

Invoke-JUnitNegativeCase 'missing extra-one BackPrev2 optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenExtraOneWithBackPrev2Set' 'missing required test case'

Invoke-JUnitNegativeCase 'missing extra-one PosPrev2 optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenExtraOneWithPosPrev2Set' 'missing required test case'

Invoke-JUnitNegativeCase 'missing multi-byte root literal optimum replay JUnit evidence' `
  'OptimumReplayRejectsMultiByteLiteralRootCommand' 'missing required test case'

Invoke-JUnitNegativeCase 'missing one-byte root match optimum replay JUnit evidence' `
  'OptimumReplayRejectsSingleByteMatchRootCommand' 'missing required test case'

Invoke-JUnitNegativeCase 'missing intermediate multi-byte literal optimum replay JUnit evidence' `
  'OptimumReplayRejectsIntermediateMultiByteLiteralCommand' 'missing required test case'

Invoke-JUnitNegativeCase 'missing path-len multi-byte literal optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenMultiByteLiteralCommand' 'missing required test case'

Invoke-JUnitNegativeCase 'missing path-len one-byte match optimum replay JUnit evidence' `
  'OptimumReplayRejectsPathLenSingleByteMatchCommand' 'missing required test case'

Invoke-JUnitNegativeCase 'missing unreachable start optimum replay JUnit evidence' `
  'OptimumReplayRejectsUnreachableStartNode' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum seed start-price JUnit evidence' `
  'OptimumSeedCandidatesIncludePreparedStartPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum prepare state/reps JUnit evidence' `
  'OptimumPrepareNodesSeedsStartStateAndReps' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum seed overflow guard JUnit evidence' `
  'OptimumSeedCandidatesRejectOverflowingStartPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum seed match back-distance overflow JUnit evidence' `
  'OptimumSeedMatchCandidatesRejectOverflowingBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum seed match zero back-distance JUnit evidence' `
  'OptimumSeedMatchCandidatesRejectZeroBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum short-rep price-decision overflow guard JUnit evidence' `
  'OptimumShortRepVsLiteralRejectsOverflowingShortRepPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum rep-vs-match overflow guard JUnit evidence' `
  'OptimumRepVsMatchRejectsOverflowingRepPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum rep-vs-match match back-distance overflow guard JUnit evidence' `
  'OptimumRepVsMatchRejectsOverflowingMatchBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum rep-vs-match one-byte normal match guard JUnit evidence' `
  'OptimumRepVsMatchRejectsOneByteNormalMatchLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum rep-vs-match one-byte rep guard JUnit evidence' `
  'OptimumRepVsMatchRejectsOneByteRepLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum rep-vs-match zero normal-match distance guard JUnit evidence' `
  'OptimumRepVsMatchRejectsZeroMatchDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-match overflow guard JUnit evidence' `
  'OptimumLiteralThenMatchRejectsOverflowingLookaheadPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-match current-match back-distance overflow guard JUnit evidence' `
  'OptimumLiteralThenMatchRejectsOverflowingCurrentMatchBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-match next-match back-distance overflow guard JUnit evidence' `
  'OptimumLiteralThenMatchRejectsOverflowingNextMatchBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-match one-byte next match guard JUnit evidence' `
  'OptimumLiteralThenMatchRejectsOneByteNextMatchLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-match one-byte current match guard JUnit evidence' `
  'OptimumLiteralThenMatchRejectsOneByteCurrentMatchLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-match zero next-match distance guard JUnit evidence' `
  'OptimumLiteralThenMatchRejectsZeroNextMatchDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-match zero current-match distance guard JUnit evidence' `
  'OptimumLiteralThenMatchRejectsZeroCurrentMatchDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-rep overflow guard JUnit evidence' `
  'OptimumLiteralThenRepRejectsOverflowingLookaheadPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-rep current-match back-distance overflow guard JUnit evidence' `
  'OptimumLiteralThenRepRejectsOverflowingCurrentMatchBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-rep one-byte next rep guard JUnit evidence' `
  'OptimumLiteralThenRepRejectsOneByteNextRepLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-rep one-byte current match guard JUnit evidence' `
  'OptimumLiteralThenRepRejectsOneByteCurrentMatchLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal-then-rep zero current-match distance guard JUnit evidence' `
  'OptimumLiteralThenRepRejectsZeroCurrentMatchDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 price-decision overflow guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsOverflowingLookaheadPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 first-match decision back-distance overflow guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsOverflowingFirstMatchDecisionBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 current-match decision back-distance overflow guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsOverflowingCurrentMatchDecisionBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 one-byte first match guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsOneByteFirstMatchLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 one-byte rep guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsOneByteRepLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 one-byte current match guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsOneByteCurrentMatchLength' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 zero first-match distance guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsZeroFirstMatchDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 zero current-match distance guard JUnit evidence' `
  'OptimumMatchLiteralRep0RejectsZeroCurrentMatchDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum literal overflow guard JUnit evidence' `
  'OptimumLiteralCandidateRejectsOverflowingPreviousPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum short-rep overflow guard JUnit evidence' `
  'OptimumShortRepCandidateRejectsOverflowingPreviousPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum relax match back-distance overflow JUnit evidence' `
  'OptimumRelaxMatchCandidatesRejectOverflowingBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum relax match zero back-distance JUnit evidence' `
  'OptimumRelaxMatchCandidatesRejectZeroBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum rep overflow guard JUnit evidence' `
  'OptimumRepCandidatesRejectOverflowingPreviousPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match overflow guard JUnit evidence' `
  'OptimumMatchCandidatesRejectOverflowingPreviousPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 overflow guard JUnit evidence' `
  'OptimumMatchLiteralRep0CandidateRejectsOverflowingPreviousPrice' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 first-match back-distance overflow JUnit evidence' `
  'OptimumMatchLiteralRep0CandidateRejectsOverflowingFirstMatchBackDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum match-literal-rep0 zero first-match distance JUnit evidence' `
  'OptimumMatchLiteralRep0CandidateRejectsZeroFirstMatchDistance' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum state/reps propagation JUnit evidence' `
  'OptimumRelaxCandidatesCarryStateAndRepsAcrossParserNodes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum window relaxation JUnit evidence' `
  'OptimumWindowReplaysCheaperTwoStepPathOverDirectMatch' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum window literal relaxation JUnit evidence' `
  'OptimumWindowRelaxesLiteralThenMatchPath' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum window state probability JUnit evidence' `
  'OptimumWindowUsesReachedNodeStateForLaterProbabilityInputs' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum window reached-node rep resolver JUnit evidence' `
  'OptimumWindowResolvesRepLensFromReachedNodeReps' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum window reached-node literal resolver JUnit evidence' `
  'OptimumWindowResolvesLiteralFromReachedNodeContext' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum window resolved short-rep JUnit evidence' `
  'OptimumWindowRelaxesShortRepFromResolvedRepLens' 'missing required test case'

Invoke-JUnitNegativeCase 'missing optimum window match-literal-rep0 extra path JUnit evidence' `
  'OptimumWindowRelaxesMatchLiteralRep0ExtraPath' 'missing required test case'

Invoke-JUnitNegativeCase 'missing SDK props dependency-vector JUnit evidence' `
  'SdkFacadePropsNormalizeSdkDependencyVectors' 'missing required test case'

Invoke-JUnitNegativeCase 'missing SDK progress SRes preservation JUnit evidence' `
  'SdkFacadeProgressPreservesCallbackSRes' 'missing required test case'

Invoke-JUnitNegativeCase 'missing LZMA decoder lifecycle facade JUnit evidence' `
  'SdkFacadeLzmaDecoderLifecycleDecodeToBuf' 'missing required test case'

Invoke-JUnitNegativeCase 'missing LZMA decoder lifecycle needs-input JUnit evidence' `
  'SdkFacadeLzmaDecoderLifecycleTruncatedInputNeedsMoreInput' 'missing required test case'

Invoke-JUnitNegativeCase 'missing LZMA2 decoder lifecycle invalid-prop JUnit evidence' `
  'SdkFacadeLzma2DecoderLifecycleRejectsInvalidProperty' 'missing required test case'

Invoke-JUnitNegativeCase 'missing LZMA2 decoder lifecycle facade JUnit evidence' `
  'SdkFacadeLzma2DecoderLifecycleDecodeToBufAndDic' 'missing required test case'

Invoke-JUnitNegativeCase 'missing GitHub release workflow mode JUnit evidence' `
  'GitHubWorkflowRunsReleaseCiMode' 'missing required test case'

Invoke-JUnitNegativeCase 'missing CLI unsafe stored-name JUnit evidence' `
  'CliSafeStoredOutputNameRejectsUnsafeStoredNames' 'missing required test case'

Invoke-JUnitNegativeCase 'missing release MT 16-thread JUnit evidence' `
  'ReleasePerformanceRequiresSixteenThreadMtEncodeEvidence' 'missing required test case'

Invoke-JUnitNegativeCase 'missing encoder optimum context seeding JUnit evidence' `
  'EncoderPathSeedsOptimumNodesWithCurrentStateAndReps' 'missing required test case'

Invoke-FixtureManifestNegativeCase 'missing corrupt XZ regression manifest evidence' {
  param($manifest)
  $manifest.manifests = @($manifest.manifests | Where-Object {
    $_.path -ne 'tests/fixtures/manifests/corrupt-xz-regressions.json'
  })
  $manifest
} 'does not include corrupt XZ regression manifest'

Invoke-FixtureManifestNegativeCase 'missing corrupt XZ checksum fixture evidence' {
  param($manifest)
  $manifest.fixtures = @($manifest.fixtures | Where-Object {
    $_.path -ne 'tests/fixtures/corrupt/sevenzip-smoke-corrupt-check.xz'
  })
  $manifest
} 'missing required corrupt XZ fixture'

Invoke-CorruptXzManifestNegativeCase 'wrong corrupt XZ expected error evidence' {
  param($manifest)
  $case = @($manifest.cases | Where-Object {
    $_.fixturePath -eq 'tests/fixtures/corrupt/sevenzip-smoke-corrupt-check.xz'
  }) | Select-Object -First 1
  if (-not $case) {
    throw 'Could not find corrupt-check case to mutate.'
  }
  $case.expectedError = 'ELzmaDataError'
  $manifest
} 'unexpected expectedError'

if ($RequireReleaseCorpus) {
  Invoke-FixtureManifestNegativeCase 'missing raw LZMA release corpus manifest evidence' {
    param($manifest)
    $manifest.manifests = @($manifest.manifests | Where-Object {
      $_.path -ne 'tests/fixtures/manifests/raw-lzma-sdk-release-corpus.json'
    })
    $manifest
  } 'SDK raw LZMA release corpus manifest'

  Invoke-FixtureManifestNegativeCase 'missing raw LZMA release corpus fixture evidence' {
    param($manifest)
    $manifest.fixtures = @($manifest.fixtures | Where-Object {
      $_.path -ne 'tests/fixtures/raw/raw-lzma-sdk-release-corpus-a1-d22-fb64-mixed.lzma'
    })
    $manifest
  } 'SDK raw LZMA release corpus fixtures'

  Invoke-RawLzmaReleaseManifestNegativeCase 'raw LZMA release corpus remains smoke-sized' {
    param($manifest)
    foreach ($case in $manifest.cases) {
      $case.unpackSize = 32768
    }
    $manifest
  } 'remains smoke-sized'

  Invoke-RawLzmaReleaseManifestNegativeCase 'raw LZMA release corpus missing mixed case' {
    param($manifest)
    foreach ($case in $manifest.cases) {
      if ($case.name -like '*mixed*') {
        $case.name = ([string]$case.name).Replace('mixed', 'repeat-alt')
        $case.pattern = 'repeat'
      }
    }
    $manifest
  } 'missing a mixed case'

  Invoke-RawLzmaReleaseManifestNegativeCase 'raw LZMA release corpus missing fb64 switch coverage' {
    param($manifest)
    foreach ($case in $manifest.cases) {
      $case.commandLine = ([string]$case.commandLine).Replace('-fb64', '-fb32')
    }
    $manifest
  } 'missing switch coverage for -fb64'

  Invoke-RawLzmaReleaseManifestNegativeCase 'raw LZMA release corpus missing fixture cache evidence' {
    param($manifest)
    $case = @($manifest.cases) | Select-Object -First 1
    if (-not $case) {
      throw 'Could not find raw LZMA release case to mutate.'
    }
    $case.PSObject.Properties.Remove('cacheKey')
    $manifest
  } 'fixture cache evidence'
}

Invoke-RuntimeSourceNegativeCase 'runtime OBJ link directive' 'src\__runtime_dependency_probe.pas' @'
unit __runtime_dependency_probe;

interface

implementation

{$L forbidden.obj}

end.
'@ 'forbidden runtime dependency'

Invoke-RuntimeSourceNegativeCase 'runtime external import alias' 'src\__runtime_dependency_probe.pas' @'
unit __runtime_dependency_probe;

interface

implementation

const BadDll = 'bad.dll';
procedure BadImport; external BadDll name 'BadImport';

end.
'@ 'forbidden runtime dependency'

if (-not $RequireReleaseCorpus) {
Invoke-RuntimeSourceAcceptedCase 'runtime dependency names in comments and strings' 'src\__runtime_dependency_comment_probe.pas' @'
unit __runtime_dependency_comment_probe;

interface

implementation

const Example = 'external LoadLibrary(GetProcAddress)';

// external LoadLibrary('example.dll')
{ GetProcAddress(SomeHandle, 'Symbol') }
(* ShellExecute(0, nil, 'tool.exe', nil, nil, 0) *)

end.
'@
}

$runtimePurityNegativeCases = @(
  [pscustomobject]@{
    Name = 'runtime TProcess launch helper'
    RelativePath = 'src\__runtime_process_probe.pas'
    ExpectedPattern = 'runtime external process launch'
    Content = @'
unit __runtime_process_probe;

interface

implementation

procedure Run;
var
  Process: TProcess;
begin
  Process := TProcess.Create(nil);
  Process.Free;
end;

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime cmd shell reference'
    RelativePath = 'src\__runtime_cmd_probe.pas'
    ExpectedPattern = 'runtime external executable reference'
    Content = @'
unit __runtime_cmd_probe;

interface

implementation

const ShellName = 'cmd.exe';

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime PowerShell shell reference'
    RelativePath = 'src\__runtime_powershell_probe.pas'
    ExpectedPattern = 'runtime external executable reference'
    Content = @'
unit __runtime_powershell_probe;

interface

implementation

const ShellName = 'powershell.exe';

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime 7z executable reference'
    RelativePath = 'src\__runtime_7z_probe.pas'
    ExpectedPattern = 'runtime external executable reference'
    Content = @'
unit __runtime_7z_probe;

interface

implementation

const ToolName = '7z.exe';

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime 7zr executable reference'
    RelativePath = 'src\__runtime_7zr_probe.pas'
    ExpectedPattern = 'runtime external executable reference'
    Content = @'
unit __runtime_7zr_probe;

interface

implementation

const ToolName = '7zr.exe';

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime xz executable reference'
    RelativePath = 'src\__runtime_xz_probe.pas'
    ExpectedPattern = 'runtime external executable reference'
    Content = @'
unit __runtime_xz_probe;

interface

implementation

const ToolName = 'xz.exe';

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime lzma executable reference'
    RelativePath = 'src\__runtime_lzma_probe.pas'
    ExpectedPattern = 'runtime external executable reference'
    Content = @'
unit __runtime_lzma_probe;

interface

implementation

const ToolName = 'lzma.exe';

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime tar executable reference'
    RelativePath = 'src\__runtime_tar_probe.pas'
    ExpectedPattern = 'runtime external executable reference'
    Content = @'
unit __runtime_tar_probe;

interface

implementation

const ToolName = 'tar.exe';

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime CreateOleObject shell automation'
    RelativePath = 'src\__runtime_com_probe.pas'
    ExpectedPattern = 'runtime COM shell automation'
    Content = @'
unit __runtime_com_probe;

interface

implementation

procedure Run;
begin
  CreateOleObject('WScript.Shell');
end;

end.
'@
  },
  [pscustomobject]@{
    Name = 'runtime Shell.Application automation'
    RelativePath = 'src\__runtime_shell_application_probe.pas'
    ExpectedPattern = 'runtime COM shell automation'
    Content = @'
unit __runtime_shell_application_probe;

interface

implementation

const ShellAutomation = 'Shell.Application';

end.
'@
  },
  [pscustomobject]@{
    Name = 'tool native object file'
    RelativePath = 'tools\__runtime_dependency_probe.obj'
    ExpectedPattern = 'forbidden runtime dependency file'
    Content = 'native object probe'
  }
)
foreach ($case in $runtimePurityNegativeCases) {
  Invoke-RuntimeSourceNegativeCase $case.Name $case.RelativePath $case.Content $case.ExpectedPattern
}

Invoke-DocsNegativeCase 'premature SDK-clone docs claim' 'docs\__parity_claim_probe.md' @'
# Probe

Full SDK parity accepted.
'@ 'must not claim completed SDK-clone encoder behavior'

Invoke-DocsNegativeCase 'premature SDK encoder parity docs claim' 'docs\__encoder_parity_claim_probe.md' @'
# Probe

Full SDK encoder parity achieved.
'@ 'must not claim completed SDK-clone encoder behavior'

Invoke-DocsNegativeCase 'unrestricted 7z docs claim' 'docs\__unrestricted_7z_claim_probe.md' @'
# Probe

The library now provides unrestricted 7z support.
'@ 'must not claim unrestricted 7z support'

Invoke-DocsNegativeCase 'XZ filter-chain docs claim' 'docs\__xz_filter_chain_claim_probe.md' @'
# Probe

XZ filter-chain support is available.
'@ 'must not claim XZ filter-chain support'

Invoke-DocsNegativeCase 'graph benchmark success docs claim' 'docs\__graph_benchmark_claim_probe.md' @'
# Probe

Benchmark success is proven by graph visuals.
'@ 'must not claim benchmark success from graph visuals'

Invoke-TrackedTreeNegativeCase 'release acceptance docs missing quick performance contract' `
  'docs\release-acceptance.md' {
  param($Text)
  return $Text -replace '`quick` mode does not run `tests/run-performance\.ps1`',
    '`quick` mode runs the performance matrix'
} 'Required documentation contract'

Invoke-ProjectNegativeCase 'tool project native object reference' 'tools\Lzma2.dproj' {
  param($Text)
  return $Text -replace '</Project>', '  <PropertyGroup><ObjFiles>forbidden.obj</ObjFiles></PropertyGroup></Project>'
} 'forbidden runtime dependency'

Invoke-UntrackedReferencedSourceNegativeCase 'untracked referenced source dependency' `
  'Referenced source file is not tracked by git'

Invoke-CiManifestNegativeCase 'missing CI run configuration manifest evidence' {
  param($Manifest)
  $Manifest.PSObject.Properties.Remove('configuration')
  return $Manifest
} 'CI manifest is missing run configuration'

Invoke-CiManifestNegativeCase 'detached HEAD branch manifest evidence' {
  param($Manifest)
  $Manifest.configuration.branch = 'HEAD'
  return $Manifest
} 'CI manifest is missing the git branch'

Invoke-CiManifestNegativeCase 'stale CI commit manifest evidence' {
  param($Manifest)
  $Manifest.configuration.commit = '0000000000000000000000000000000000000000'
  return $Manifest
} 'CI manifest git commit does not match current HEAD'

Invoke-CiManifestNegativeCase 'mismatched GitHub SHA manifest evidence' {
  param($Manifest)
  $Manifest.configuration.githubSha = '1111111111111111111111111111111111111111'
  return $Manifest
} 'CI manifest GitHub SHA does not match the git commit SHA'

Invoke-CiManifestNegativeCase 'CI manifest artifact byte count mismatch' {
  param($Manifest)
  $Manifest.artifacts[0].bytes = [int64]$Manifest.artifacts[0].bytes + 1
  return $Manifest
} 'CI manifest artifact byte count mismatch'

Invoke-CiManifestNegativeCase 'CI manifest artifact hash mismatch' {
  param($Manifest)
  $Manifest.artifacts[0].sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
  return $Manifest
} 'CI manifest artifact hash mismatch'

Invoke-CiManifestNegativeCase 'CI manifest missing DUnitX category evidence' {
  param($Manifest)
  $Manifest.configuration.PSObject.Properties.Remove('dunitxCategoryArgs')
  return $Manifest
} 'DUnitX category arguments'

if (-not $RequireReleaseCorpus) {
  Invoke-CiManifestNegativeCase 'quick CI manifest missing DUnitX include categories' {
    param($Manifest)
    $Manifest.configuration.mode = 'quick'
    $Manifest.commands.runPerformance = 'quick mode skips tests/run-performance.ps1'
    $Manifest.configuration | Add-Member -NotePropertyName dunitxCategoryArgs `
      -NotePropertyValue @('--exclude:perf-release,soak,fuzz') -Force
    return $Manifest
  } 'quick DUnitX category arguments'

  Invoke-CiManifestNegativeCase 'quick CI manifest missing DUnitX exclude categories' {
    param($Manifest)
    $Manifest.configuration.mode = 'quick'
    $Manifest.commands.runPerformance = 'quick mode skips tests/run-performance.ps1'
    $Manifest.configuration | Add-Member -NotePropertyName dunitxCategoryArgs `
      -NotePropertyValue @('--include:unit,container,compat,perf-smoke') -Force
    return $Manifest
  } 'quick DUnitX category arguments'
}

if ($script:HasPerformanceArtifacts) {
  Invoke-CiManifestNegativeCase 'CI manifest missing benchmark CSV artifact record' {
    param($Manifest)
    $Manifest.artifacts = @($Manifest.artifacts | Where-Object {
      $_.path -ne 'artifacts/perf/lzma2-benchmark.csv'
    })
    return $Manifest
  } 'missing required artifact record: artifacts/perf/lzma2-benchmark.csv'

  Invoke-CiManifestNegativeCase 'CI manifest missing benchmark samples CSV artifact record' {
    param($Manifest)
    $Manifest.artifacts = @($Manifest.artifacts | Where-Object {
      $_.path -ne 'artifacts/perf/lzma2-benchmark.samples.csv'
    })
    return $Manifest
  } 'missing required artifact record: artifacts/perf/lzma2-benchmark.samples.csv'

  Invoke-CiManifestNegativeCase 'CI manifest missing benchmark summary JSON artifact record' {
    param($Manifest)
    $Manifest.artifacts = @($Manifest.artifacts | Where-Object {
      $_.path -ne 'artifacts/perf/lzma2-benchmark.summary.json'
    })
    return $Manifest
  } 'missing required artifact record: artifacts/perf/lzma2-benchmark.summary.json'

  Invoke-MissingArtifactNegativeCase 'missing benchmark samples CSV artifact' `
    $perfSamplesPath $perfSamplesBackupPath 'Required artifact is missing: artifacts\\perf\\lzma2-benchmark.samples.csv'

  Invoke-MissingArtifactNegativeCase 'missing benchmark summary JSON artifact' `
    $perfSummaryPath $perfSummaryBackupPath 'Required artifact is missing: artifacts\\perf\\lzma2-benchmark.summary.json'
}

Invoke-CiManifestNegativeCase 'CI manifest still contains graph artifact record' {
  param($Manifest)
  $Manifest.artifacts = @($Manifest.artifacts + [pscustomobject]@{
    path = 'artifacts/perf/lzma2-delphi-graph.csv'
    bytes = 0
    sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
  })
  return $Manifest
} 'CI manifest must not include graph artifact record'

Invoke-ForbiddenArtifactFileNegativeCase 'quick validation rejects leftover graph artifact file' `
  'artifacts\perf\lzma2-delphi-graph.csv' 'operation,throughput' `
  'Validation must not leave graph artifacts in artifacts/perf'

Invoke-ForbiddenArtifactFileNegativeCase 'quick validation rejects leftover PNG performance image' `
  'artifacts\perf\benchmark-plot.png' 'not a real png' `
  'Validation must not leave graph artifacts'

Invoke-ForbiddenArtifactFileNegativeCase 'quick validation rejects nested PNG performance image' `
  'artifacts\perf\nested\benchmark-plot.png' 'not a real png' `
  'Validation must not leave graph artifacts'

Invoke-ForbiddenArtifactFileNegativeCase 'quick validation rejects leftover SVG performance image' `
  'artifacts\perf\benchmark-plot.svg' '<svg></svg>' `
  'Validation must not leave graph artifacts'

Invoke-ForbiddenArtifactFileNegativeCase 'quick validation rejects leftover benchmark markdown artifact file' `
  'artifacts\perf\lzma2-benchmark.md' '# report' `
  'Validation must not leave benchmark Markdown artifacts in artifacts/perf'

Invoke-ForbiddenArtifactFileNegativeCase 'quick validation rejects perf optimization markdown sidecar' `
  'artifacts\perf\optimization-plan.md' '# plan' `
  'unexpected performance artifact outside data-only allowlist'

Invoke-ForbiddenArtifactFileNegativeCase 'quick validation rejects unexpected performance artifact file' `
  'artifacts\perf\unexpected.txt' 'unexpected performance sidecar' `
  'unexpected performance artifact outside data-only allowlist'

Invoke-SummaryJsonNegativeCase 'summary JSON row-count mismatch' {
  param($Summary)
  $Summary.rows.count = [int]$Summary.rows.count + 1
  return $Summary
} 'Performance summary row count must match benchmark JSON rows'

Invoke-SummaryJsonNegativeCase 'summary JSON missing benchmark metadata' {
  param($Summary)
  if ($Summary.PSObject.Properties.Name -contains 'metadata') {
    $Summary.PSObject.Properties.Remove('metadata')
  }
  return $Summary
} 'Performance summary JSON must include benchmark metadata'

Invoke-SummaryJsonNegativeCase 'summary JSON missing git metadata' {
  param($Summary)
  if ($Summary.metadata -and $Summary.metadata.PSObject.Properties.Name -contains 'gitCommit') {
    $Summary.metadata.PSObject.Properties.Remove('gitCommit')
  }
  return $Summary
} 'Performance summary JSON must include benchmark metadata'

Invoke-SummaryJsonNegativeCase 'summary JSON missing corpus cache evidence' {
  param($Summary)
  if ($Summary.PSObject.Properties.Name -contains 'corpusCache') {
    $Summary.PSObject.Properties.Remove('corpusCache')
  }
  return $Summary
} 'benchmark corpus cache evidence'

Invoke-SummaryJsonNegativeCase 'summary JSON stale corpus cache key' {
  param($Summary)
  $record = @($Summary.corpusCache.records) | Select-Object -First 1
  if ($record) {
    $record.cacheKey = 'not-a-cache-key'
  }
  return $Summary
} 'corpus cache record is missing required metadata'

Invoke-NegativeCase 'inconsistent optimum parser enabled flag' {
  param($Rows)
  $row = @($Rows | Where-Object { $_.tool -eq 'delphi-native' -and $_.operation -eq 'encode' }) |
    Select-Object -First 1
  if ($row) {
    $row.parserMode = 'high-speed'
    $row.optimumParserEnabled = $true
    $row.fullOptimumDecisionCount = 1
  }
  return $Rows
} 'active sdk-profile parser rows with full optimum decision evidence'

Invoke-NegativeCase 'optimum parser enabled without encoded blocks' {
  param($Rows)
  $row = @($Rows | Where-Object { $_.tool -eq 'delphi-native' -and $_.operation -eq 'encode' }) |
    Select-Object -First 1
  if ($row) {
    $row.parserMode = 'sdk-profile'
    $row.optimumParserEnabled = $true
    $row.encodeBlockCount = 0
    $row.fullOptimumDecisionCount = 0
  }
  return $Rows
} 'active sdk-profile parser rows with full optimum decision evidence'

Invoke-CiManifestNegativeCase 'compiler warning budget exceeded' {
  param($Manifest)
  if ($null -eq $Manifest.compilerMessages) {
    $Manifest | Add-Member -NotePropertyName compilerMessages -NotePropertyValue ([pscustomobject]@{})
  }
  $Manifest.compilerMessages.warningBudget = 0
  $Manifest.compilerMessages.warningCount = 1
  return $Manifest
} 'compiler warning count exceeds the approved warning budget'

Invoke-CiManifestNegativeCase 'compiler warning missing approved list' {
  param($Manifest)
  if ($null -eq $Manifest.compilerMessages) {
    $Manifest | Add-Member -NotePropertyName compilerMessages -NotePropertyValue ([pscustomobject]@{})
  }
  $Manifest.compilerMessages.warningBudget = 1
  $Manifest.compilerMessages.warningCount = 1
  $Manifest.compilerMessages | Add-Member -NotePropertyName warnings -NotePropertyValue @('Lzma.Tests.dpr(1) Warning: W1000 sample') -Force
  foreach ($propertyName in @('approvedWarnings', 'approvedWarningList', 'approvedWarningsPath',
      'approvedWarningsSha256', 'approvedWarningsCount')) {
    if ($Manifest.compilerMessages.PSObject.Properties.Name -contains $propertyName) {
      $Manifest.compilerMessages.PSObject.Properties.Remove($propertyName)
    }
  }
  return $Manifest
} 'compiler warnings require an approved-warning list'

Invoke-CiManifestNegativeCase 'deprecated compiler message count exceeded' {
  param($Manifest)
  if ($null -eq $Manifest.compilerMessages) {
    $Manifest | Add-Member -NotePropertyName compilerMessages -NotePropertyValue ([pscustomobject]@{})
  }
  $Manifest.compilerMessages | Add-Member -NotePropertyName deprecatedCount -NotePropertyValue 1 -Force
  $Manifest.compilerMessages | Add-Member -NotePropertyName deprecated -NotePropertyValue @('Lzma.Tests.dpr(1) Warning: W1000 deprecated sample') -Force
  return $Manifest
} 'deprecated compiler message count must be zero'

Invoke-CiManifestNegativeCase 'CI manifest missing run-ci command line evidence' {
  param($Manifest)
  if ($null -eq $Manifest.commands) {
    $Manifest | Add-Member -NotePropertyName commands -NotePropertyValue ([pscustomobject]@{})
  }
  $Manifest.commands | Add-Member -NotePropertyName runCi -NotePropertyValue '' -Force
  return $Manifest
} 'required run-ci command line'

if ($script:HasPerformanceArtifacts -or $RequireReleaseCorpus) {
  Invoke-CiManifestNegativeCase 'CI manifest missing run-performance command line evidence' {
    param($Manifest)
    if ($null -eq $Manifest.commands) {
      $Manifest | Add-Member -NotePropertyName commands -NotePropertyValue ([pscustomobject]@{})
    }
    $Manifest.commands | Add-Member -NotePropertyName runPerformance -NotePropertyValue '' -Force
    return $Manifest
  } 'required performance command line'
}

$currentManifestForToolGates = Get-Content -LiteralPath $ciManifestPath -Raw | ConvertFrom-Json
if ($RequireExternalTools -or [bool]$currentManifestForToolGates.tools.sevenZip.available) {
  Invoke-CiManifestNegativeCase 'available 7-Zip path missing from CI manifest' {
    param($Manifest)
    $Manifest.tools.sevenZip.path = ''
    return $Manifest
  } 'required 7-Zip tool path'

  Invoke-CiManifestNegativeCase 'available 7-Zip SDK version mismatch' {
    param($Manifest)
    $Manifest.tools.sevenZip.version = '7-Zip (r) 26.00 (x64)'
    return $Manifest
  } 'pinned config'

  Invoke-CiManifestNegativeCase 'available 7-Zip missing pinned resolver metadata' {
    param($Manifest)
    $Manifest.tools.sevenZip.resolvedFrom = ''
    return $Manifest
  } 'pinned QA metadata'

  Invoke-CiManifestNegativeCase 'available 7-Zip wrong executable family' {
    param($Manifest)
    $Manifest.tools.sevenZip.expectedExecutable = '7z.exe'
    return $Manifest
  } 'stale expected executable'

  Invoke-CiManifestNegativeCase 'available 7-Zip missing SDK archive SHA pin' {
    param($Manifest)
    $Manifest.tools.sevenZip.archiveSha256 = ''
    return $Manifest
  } 'pinned archive SHA-256 metadata'
}
if ($RequireExternalTools -or [bool]$currentManifestForToolGates.tools.lzma.available) {
  Invoke-CiManifestNegativeCase 'available lzma.exe SDK version mismatch' {
    param($Manifest)
    $Manifest.tools.lzma.version = 'LZMA 26.00 (x64)'
    return $Manifest
  } 'pinned config'
}
if ($RequireExternalTools -or [bool]$currentManifestForToolGates.tools.xz.available) {
  Invoke-CiManifestNegativeCase 'available xz.exe outside pinned official package path' {
    param($Manifest)
    $Manifest.tools.xz.path = 'C:\tools\xz.exe'
    return $Manifest
  } 'pinned source path pattern'

  Invoke-CiManifestNegativeCase 'available xz.exe official version mismatch' {
    param($Manifest)
    $Manifest.tools.xz.version = 'xz (XZ Utils) 5.8.2'
    return $Manifest
  } 'pinned config'

  Invoke-CiManifestNegativeCase 'available xz.exe missing archive SHA pin' {
    param($Manifest)
    $Manifest.tools.xz.archiveSha256 = ''
    return $Manifest
  } 'pinned archive SHA-256 metadata'

  Invoke-CiManifestNegativeCase 'available xz.exe wrong pin mode' {
    param($Manifest)
    $Manifest.tools.xz.pinMode = 'version-pattern'
    return $Manifest
  } 'stale pin mode metadata'
}
if ($RequireExternalTools) {
  Invoke-NegativeCase 'SDK encode comparison ratio too weak' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.mode -eq 'xz-level1' -and
          $row.baselineTool -like '7zr-sdk*encode*' -and
          $row.acceptance -in @('meets-100pct-sdk-smoke', 'meets-100pct-sdk-periodic-fastpath')) {
        $row.compressionRatio = 0.50
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the SDK encode comparison row to mutate.'
    }
  } 'comparable compression ratio'
}

Invoke-CiManifestAndSummaryNegativeCase 'performance work root on non-SSD drive' {
  param($Manifest, $Summary)
  $slowWorkRoot = 'E:\slow-hdd\lzma2-delphi-perf'
  $Manifest.configuration.performanceWorkRoot = $slowWorkRoot
  $Manifest.configuration.ramWorkRoot = ''
  $Summary.metadata.benchmarkWorkRoot = $slowWorkRoot
  $Summary.metadata.ramBackedWorkRoot = $false
  $Summary.metadata.corpusCacheRoot = Join-Path $slowWorkRoot 'lzma2-delphi-corpus-cache'
  $Summary.corpusCache.root = Join-Path $slowWorkRoot 'lzma2-delphi-corpus-cache'
} 'performance work root must be on SSD drive C: or D:'

Invoke-NegativeCase 'missing raw LZMA2 MT decode speedup-or-fallback evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'decode' -and
        $row.mode -eq 'raw-lzma2-level1' -and
        [int]$row.threads -eq 4) {
      $row.acceptance = 'mt-decode-no-speedup'
      $row.decodeFallback = 'none'
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the raw MT decode evidence row to mutate.'
  }
} 'failing acceptance label'

Invoke-NegativeCase 'raw LZMA2 MT fallback missing comparison evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'decode' -and
        $row.mode -eq 'raw-lzma2-level1' -and
        [int]$row.threads -eq 4 -and
        $row.acceptance -eq 'mt-decode-fallback-insufficient-work') {
      $row.baselineTool = ''
      $row.baselineThroughputMiBs = $null
      $row.throughputRatioPct = $null
      $row.comparisonMetric = ''
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the raw MT fallback evidence row to mutate.'
  }
} 'raw LZMA2 MT decode speedup or an explicit insufficient-work fallback'

Invoke-NegativeCase 'missing Delphi-generated XZ multi-block encode evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'encode' -and
        $row.mode -eq 'xz-delphi-multiblock-level1') {
      $row.xzBlockSize = 0
      $row.encodeBlockCount = 1
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the Delphi-generated XZ multi-block encode row to mutate.'
  }
} 'Delphi-generated multi-block XZ encode row'

Invoke-NegativeCase 'Delphi-generated XZ MT decode inactive diagnostics' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'decode' -and
        $row.mode -eq 'xz-delphi-multiblock-level1' -and
        [int]$row.threads -eq 4) {
      $row.actualMtDecode = $false
      $row.actualDecodeThreadCount = 1
      $row.decodeIndependentUnitCount = 1
      $row.inputSnapshot = $true
      $row.decodeFallback = 'single-independent-unit'
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the Delphi-generated XZ MT decode row to mutate.'
  }
} 'Delphi-generated XZ MT decode active worker evidence'

Invoke-NegativeCase 'Delphi-generated XZ MT decode missing comparison evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'decode' -and
        $row.mode -eq 'xz-delphi-multiblock-level1' -and
        [int]$row.threads -eq 4) {
      $row.baselineTool = ''
      $row.baselineThroughputMiBs = $null
      $row.throughputRatioPct = $null
      $row.comparisonMetric = ''
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the Delphi-generated XZ MT decode row to mutate.'
  }
} 'Delphi-generated XZ MT decode active worker evidence'

Invoke-NegativeCase 'missing patterned Delphi-generated XZ multi-block encode evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'encode' -and
        $row.mode -eq 'xz-delphi-patterned-multiblock-level1') {
      $row.xzBlockSize = 0
      $row.encodeBlockCount = 1
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the patterned Delphi-generated XZ multi-block encode row to mutate.'
  }
} 'patterned Delphi-generated multi-block XZ encode row'

Invoke-NegativeCase 'patterned Delphi-generated XZ MT decode inactive diagnostics' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'decode' -and
        $row.mode -eq 'xz-delphi-patterned-multiblock-level1' -and
        [int]$row.threads -eq 4) {
      $row.actualMtDecode = $false
      $row.actualDecodeThreadCount = 1
      $row.decodeIndependentUnitCount = 1
      $row.inputSnapshot = $true
      $row.decodeFallback = 'single-independent-unit'
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the patterned Delphi-generated XZ MT decode row to mutate.'
  }
} 'patterned Delphi-generated XZ MT decode active worker evidence'

Invoke-NegativeCase 'patterned Delphi-generated XZ MT decode missing comparison evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and
        $row.operation -eq 'decode' -and
        $row.mode -eq 'xz-delphi-patterned-multiblock-level1' -and
        [int]$row.threads -eq 4) {
      $row.baselineTool = ''
      $row.baselineThroughputMiBs = $null
      $row.throughputRatioPct = $null
      $row.comparisonMetric = ''
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find the patterned Delphi-generated XZ MT decode row to mutate.'
  }
} 'patterned Delphi-generated XZ MT decode active worker evidence'

Invoke-NegativeCase 'missing benchmark statistics fields' {
  param($Rows)
  $Rows[0].PSObject.Properties.Remove('medianElapsedMs')
} 'warm-up and multi-run statistic fields'

Invoke-NegativeCase 'missing benchmark input SHA-256 field' {
  param($Rows)
  $Rows[0].PSObject.Properties.Remove('inputSha256')
} 'data-only benchmark field: inputSha256'

Invoke-NegativeCase 'missing benchmark normalized command fields' {
  param($Rows)
  $Rows[0].normalizedCommand = ''
  $Rows[0].normalizedOptions = ''
} 'Performance JSON rows must include normalized command and options'

Invoke-NegativeCase 'missing Delphi encode parser diagnostics' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and $row.operation -eq 'encode') {
      $row.parserMode = ''
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find a Delphi encode row to mutate.'
  }
} 'parser/match-finder and MT encode diagnostics'

Invoke-NegativeCase 'missing Delphi encode tuning diagnostics' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and $row.operation -eq 'encode') {
      $row.fastBytes = $null
      $row.niceLen = $null
      $row.cutValue = $null
      $row.numHashBytes = $null
      $row.xzBlockSize = $null
      $row.copyFastPathCount = $null
      $row.incompressibleFastPathCount = $null
      $row.fullOptimumDecisionCount = $null
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find a Delphi encode row to mutate.'
  }
} 'encode tuning and fast-path diagnostics'

Invoke-NegativeCase 'hidden MT decode fallback evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and $row.operation -eq 'decode' -and [int]$row.threads -gt 1) {
      $row.requestedThreadCount = 4
      $row.actualMtDecode = $false
      $row.decodeFallback = 'none'
      $row.acceptance = ''
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find a Delphi MT decode row to mutate.'
  }
} 'hidden MT decode fallback row'

Invoke-NegativeCase 'hidden MT encode fallback evidence' {
  param($Rows)
  $mutated = $false
  foreach ($row in $Rows) {
    if ($row.tool -eq 'delphi-native' -and $row.operation -eq 'encode' -and [int]$row.threads -gt 1) {
      $row.requestedEncodeThreadCount = 4
      $row.actualEncodeThreadCount = 1
      $row.encodeFallback = 'none'
      $row.acceptance = ''
      $mutated = $true
      break
    }
  }
  if (-not $mutated) {
    throw 'Could not find a Delphi MT encode row to mutate.'
  }
} 'hidden MT encode fallback row'

if ($RequireExternalTools) {
  Invoke-CiManifestNegativeCase 'required external xz path missing from CI manifest' {
    param($Manifest)
    $Manifest.tools.xz.path = ''
    return $Manifest
  } 'required external xz-utils tool path'

  Invoke-CiManifestNegativeCase 'required external lzma path missing from CI manifest' {
    param($Manifest)
    $Manifest.tools.lzma.path = ''
    return $Manifest
  } 'required external lzma.exe tool path'

  Invoke-JUnitNegativeCase 'missing SDK raw LZMA end-marker interop evidence' `
    'CrossToolDelphiRawLzmaEndMarkerDecodesWithSdk' 'missing required SDK raw LZMA end-marker interop test case'

  Invoke-CompatReportNegativeCase 'missing Delphi multi-file 7z LZMA2 encode compatibility evidence' {
    param($Report)
    $Report.cases = @($Report.cases | Where-Object { $_.name -ne 'cli-7z-multi-file-lzma2-encode' })
    return $Report
  } 'missing required Delphi multi-file 7z encode smoke case'

  Invoke-CompatReportNegativeCase 'missing Delphi multi-file 7z LZMA encode compatibility evidence' {
    param($Report)
    $Report.cases = @($Report.cases | Where-Object { $_.name -ne 'cli-7z-multi-file-lzma-encode' })
    return $Report
  } 'missing required Delphi multi-file 7z encode smoke case'

  Invoke-CompatReportNegativeCase 'missing 7-Zip solid 7z LZMA2 extract compatibility evidence' {
    param($Report)
    $Report.cases = @($Report.cases | Where-Object { $_.name -ne 'cli-7z-solid-lzma2-extract' })
    return $Report
  } 'missing required 7-Zip solid 7z extract smoke case'

  Invoke-CompatReportNegativeCase 'missing 7-Zip solid 7z LZMA extract compatibility evidence' {
    param($Report)
    $Report.cases = @($Report.cases | Where-Object { $_.name -ne 'cli-7z-solid-lzma-extract' })
    return $Report
  } 'missing required 7-Zip solid 7z extract smoke case'

  Invoke-CompatReportNegativeCase 'missing cross-tool work-root evidence' {
    param($Report)
    $Report.PSObject.Properties.Remove('workRoot')
    return $Report
  } 'missing the release performance work root or RAM work root'

  Invoke-ConsoleNegativeCase 'required external test logged as skipped' {
    param($Text)
    return $Text + "`r`nSKIP CrossToolDelphiRawLzmaEndMarkerDecodesWithSdk: set LZMA_TEST_LZMA to enable this cross-tool test.`r`n"
  } 'required external tool test was skipped'

  Invoke-NegativeCase 'SDK encode below-threshold acceptance' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.mode -eq 'xz-level1') {
        if ($row.acceptance -eq 'meets-100pct-sdk-smoke') {
          $row.acceptance = 'below-100pct-sdk-smoke'
          $mutated = $true
          break
        }
        if ($row.acceptance -eq 'meets-100pct-sdk-periodic-fastpath') {
          $row.acceptance = 'below-100pct-sdk-periodic-fastpath'
          $mutated = $true
          break
        }
        if ($row.acceptance -in @('below-100pct-sdk-smoke', 'below-100pct-sdk-periodic-fastpath')) {
          $mutated = $true
          break
        }
      }
    }
    if (-not $mutated) {
      throw 'Could not find the SDK encode pass row to mutate.'
    }
  } 'failing acceptance label'

  Invoke-NegativeCase 'SDK decode below-threshold acceptance' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-level1') {
        if ($row.acceptance -eq 'meets-100pct-sdk-codec') {
          $row.acceptance = 'below-100pct-sdk-codec'
          $mutated = $true
          break
        }
        if ($row.acceptance -eq 'below-100pct-sdk-codec') {
          $mutated = $true
          break
        }
      }
    }
    if (-not $mutated) {
      throw 'Could not find the SDK decode pass row to mutate.'
    }
  } 'failing acceptance label'

  Invoke-NegativeCase 'SDK encode passing label below 100 percent' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.mode -eq 'xz-level1' -and
          $row.acceptance -in @('meets-100pct-sdk-smoke', 'meets-100pct-sdk-periodic-fastpath')) {
        $row.throughputRatioPct = 99.9
        $row.processThroughputMiBs = [double]$row.baselineThroughputMiBs * 0.999
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the SDK encode pass row to mutate.'
    }
  } 'Delphi encode at or above 100%'

  Invoke-NegativeCase 'SDK decode codec passing label below 100 percent' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-level1' -and
          $row.acceptance -eq 'meets-100pct-sdk-codec') {
        $row.throughputRatioPct = 99.9
        $row.throughputMiBs = [double]$row.baselineThroughputMiBs * 0.999
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the SDK decode pass row to mutate.'
    }
  } 'Delphi decode codec throughput at or above 100%'

  Invoke-NegativeCase 'SDK encode passing label wrong aligned settings' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.mode -eq 'xz-level1' -and
          $row.acceptance -in @('meets-100pct-sdk-smoke', 'meets-100pct-sdk-periodic-fastpath')) {
        $row.check = 'crc64'
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the SDK encode pass row to mutate.'
    }
  } 'aligned Delphi encode'

  Invoke-NegativeCase 'SDK decode passing label wrong aligned settings' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-level1' -and
          $row.acceptance -eq 'meets-100pct-sdk-codec') {
        $row.dictionary = 2097152
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the SDK decode pass row to mutate.'
    }
  } 'aligned Delphi decode codec throughput'

  Invoke-NegativeCase 'raw LZMA2 below-threshold acceptance' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.inputName -eq 'repeat5-256m.xzraw-src.bin.rawlzma2') {
        if ($row.acceptance -eq 'meets-80pct-xz-raw-lzma2') {
          $row.acceptance = 'below-80pct-xz-raw-lzma2'
          $mutated = $true
          break
        }
        if ($row.acceptance -eq 'below-80pct-xz-raw-lzma2') {
          $mutated = $true
          break
        }
      }
    }
    if (-not $mutated) {
      throw 'Could not find the raw LZMA2 pass row to mutate.'
    }
  } 'failing acceptance label'

  Invoke-NegativeCase 'raw LZMA2 fail label alongside passing acceptance' {
    param($Rows)
    $rowsArray = @($Rows)
    $passRow = $rowsArray | Where-Object {
      $_.tool -eq 'delphi-native' -and
        $_.operation -eq 'decode' -and
        $_.inputName -eq 'repeat5-256m.xzraw-src.bin.rawlzma2' -and
        $_.acceptance -eq 'meets-80pct-xz-raw-lzma2'
    } | Select-Object -First 1
    if (-not $passRow) {
      throw 'Could not find the raw LZMA2 pass row to duplicate.'
    }

    $failRow = $rowsArray | Where-Object {
      $_.tool -eq 'delphi-native' -and
        $_.operation -eq 'decode' -and
        $_.mode -eq 'raw-lzma2-level1' -and
        [string]::IsNullOrWhiteSpace([string]$_.acceptance)
    } | Select-Object -First 1
    if (-not $failRow) {
      throw 'Could not find the raw LZMA2 neutral row to mutate.'
    }

    $failRow.acceptance = 'below-80pct-xz-raw-lzma2'
  } 'failing acceptance label'

  Invoke-NegativeCase 'XZ MT decode no-speedup acceptance' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-multiblock-level1' -and
          [int]$row.threads -eq 4 -and
          $row.acceptance -eq 'xz-mt-decode-speedup') {
        $row.acceptance = 'xz-mt-decode-no-speedup'
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the XZ MT decode pass row to mutate.'
    }
  } 'failing acceptance label'

  Invoke-NegativeCase 'XZ MT decode inactive diagnostics' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-multiblock-level1' -and
          [int]$row.threads -eq 4 -and
          $row.acceptance -eq 'xz-mt-decode-speedup') {
        $row.actualMtDecode = $false
        $row.actualDecodeThreadCount = 1
        $row.decodeIndependentUnitCount = 1
        $row.decodeFallback = 'single-independent-unit'
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the XZ MT decode pass row to mutate.'
    }
  } 'XZ MT decode speedup on independent blocks'

  Invoke-NegativeCase 'XZ MT decode missing comparison evidence' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-multiblock-level1' -and
          [int]$row.threads -eq 4 -and
          $row.acceptance -eq 'xz-mt-decode-speedup') {
        $row.baselineTool = ''
        $row.baselineThroughputMiBs = $null
        $row.throughputRatioPct = $null
        $row.comparisonMetric = ''
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the XZ MT decode pass row to mutate.'
    }
  } 'XZ MT decode speedup on independent blocks'

  Invoke-NegativeCase 'XZ MT decode stale speedup math' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-multiblock-level1' -and
          [int]$row.threads -eq 4 -and
          $row.acceptance -eq 'xz-mt-decode-speedup') {
        $row.processThroughputMiBs = 1.0
        $row.baselineThroughputMiBs = 10.0
        $row.throughputRatioPct = 10.0
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the XZ MT decode pass row to mutate.'
    }
  } 'XZ MT decode speedup on independent blocks'

  Invoke-NegativeCase 'XZ MT decode mismatched fixture comparison' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'decode' -and
          $row.mode -eq 'xz-multiblock-level1' -and
          [int]$row.threads -eq 4 -and
          $row.acceptance -eq 'xz-mt-decode-speedup') {
        $row.inputName = 'other-xz-mt-fixture.xz'
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the XZ MT decode pass row to mutate.'
    }
  } 'XZ MT decode speedup on independent blocks'

}

if ($RequireReleaseCorpus) {
  Invoke-CiManifestAcceptedCase 'local release manifest without GitHub Actions metadata' {
    param($Manifest)
    $Manifest.configuration.githubRunId = ''
    $Manifest.configuration.githubRunAttempt = ''
    $Manifest.configuration.githubRef = ''
    $Manifest.configuration.githubSha = ''
    $Manifest.configuration.workflowName = ''
    $Manifest.configuration.runnerName = 'local-runner'
    $Manifest.configuration.runnerOS = 'Windows_NT'
    return $Manifest
  }

  Invoke-CiManifestNegativeCase 'release CI manifest missing DUnitX exclude categories' {
    param($Manifest)
    $Manifest.configuration.mode = 'release'
    $Manifest.configuration | Add-Member -NotePropertyName dunitxCategoryArgs -NotePropertyValue @() -Force
    return $Manifest
  } 'release DUnitX category arguments'

  Invoke-CiManifestNegativeCase 'soak CI manifest missing DUnitX exclude categories' {
    param($Manifest)
    $Manifest.configuration.mode = 'soak'
    $Manifest.configuration | Add-Member -NotePropertyName dunitxCategoryArgs `
      -NotePropertyValue @('--exclude:soak,fuzz') -Force
    return $Manifest
  } 'soak DUnitX category arguments'

  Invoke-CiManifestNegativeCase 'release mode metadata missing GitHub run id' {
    param($Manifest)
    $Manifest.configuration.githubRunAttempt = '1'
    $Manifest.configuration.githubRef = 'refs/heads/main'
    $Manifest.configuration.githubSha = $Manifest.configuration.commit
    $Manifest.configuration.workflowName = 'Release'
    $Manifest.configuration.githubRunId = ''
    return $Manifest
  } 'required release GitHub run id'

  Invoke-CiManifestNegativeCase 'release mode metadata missing GitHub run attempt' {
    param($Manifest)
    $Manifest.configuration.githubRunId = '12345'
    $Manifest.configuration.githubRef = 'refs/heads/main'
    $Manifest.configuration.githubSha = $Manifest.configuration.commit
    $Manifest.configuration.workflowName = 'Release'
    $Manifest.configuration.githubRunAttempt = ''
    return $Manifest
  } 'required release GitHub run attempt'

  Invoke-CiManifestNegativeCase 'release mode metadata missing GitHub ref' {
    param($Manifest)
    $Manifest.configuration.githubRunId = '12345'
    $Manifest.configuration.githubRunAttempt = '1'
    $Manifest.configuration.githubSha = $Manifest.configuration.commit
    $Manifest.configuration.workflowName = 'Release'
    $Manifest.configuration.githubRef = ''
    return $Manifest
  } 'required release GitHub ref'

  Invoke-CiManifestNegativeCase 'release mode metadata missing GitHub SHA' {
    param($Manifest)
    $Manifest.configuration.githubRunId = '12345'
    $Manifest.configuration.githubRunAttempt = '1'
    $Manifest.configuration.githubRef = 'refs/heads/main'
    $Manifest.configuration.workflowName = 'Release'
    $Manifest.configuration.githubSha = ''
    return $Manifest
  } 'required release GitHub SHA'

  Invoke-CiManifestNegativeCase 'release mode metadata missing GitHub workflow name' {
    param($Manifest)
    $Manifest.configuration.githubRunId = '12345'
    $Manifest.configuration.githubRunAttempt = '1'
    $Manifest.configuration.githubRef = 'refs/heads/main'
    $Manifest.configuration.githubSha = $Manifest.configuration.commit
    $Manifest.configuration.workflowName = ''
    return $Manifest
  } 'required release workflow name'

  Invoke-CiManifestNegativeCase 'release mode metadata nonnumeric GitHub run id' {
    param($Manifest)
    $Manifest.configuration.githubRunId = 'run-12345'
    $Manifest.configuration.githubRunAttempt = '1'
    $Manifest.configuration.githubRef = 'refs/heads/main'
    $Manifest.configuration.githubSha = $Manifest.configuration.commit
    $Manifest.configuration.workflowName = 'Release'
    return $Manifest
  } 'required release GitHub run id'

  Invoke-CiManifestNegativeCase 'release mode metadata nonnumeric GitHub run attempt' {
    param($Manifest)
    $Manifest.configuration.githubRunId = '12345'
    $Manifest.configuration.githubRunAttempt = 'attempt-1'
    $Manifest.configuration.githubRef = 'refs/heads/main'
    $Manifest.configuration.githubSha = $Manifest.configuration.commit
    $Manifest.configuration.workflowName = 'Release'
    return $Manifest
  } 'required release GitHub run attempt'

  Invoke-CiManifestNegativeCase 'release mode metadata missing runner details' {
    param($Manifest)
    $Manifest.configuration.runnerName = ''
    return $Manifest
  } 'required release runner metadata'

  $releasePreflightNegativeCases = @(
    [pscustomobject]@{
      Name = 'release mode metadata missing tracked tree clean flag'
      ExpectedPattern = 'tracked tree preflight evidence'
      Mutate = {
        param($Manifest)
        $Manifest.configuration.PSObject.Properties.Remove('trackedTreeCleanAtStart')
        return $Manifest
      }
    },
    [pscustomobject]@{
      Name = 'release mode metadata dirty tracked tree at start'
      ExpectedPattern = 'clean tracked tree at CI start'
      Mutate = {
        param($Manifest)
        $Manifest.configuration.trackedTreeCleanAtStart = $false
        $Manifest.configuration.trackedTreeStartStatus = @(' M src/Lzma.pas')
        return $Manifest
      }
    },
    [pscustomobject]@{
      Name = 'release mode metadata missing validation start UTC'
      ExpectedPattern = 'validation start UTC'
      Mutate = {
        param($Manifest)
        $Manifest.configuration.validationStartUtc = ''
        return $Manifest
      }
    },
    [pscustomobject]@{
      Name = 'release mode missing SSD or RAM work root'
      ExpectedPattern = 'release performance work root or RAM work root'
      Mutate = {
        param($Manifest)
        $Manifest.configuration.performanceWorkRoot = ''
        $Manifest.configuration.ramWorkRoot = ''
        return $Manifest
      }
    },
    [pscustomobject]@{
      Name = 'release manifest contains benchmark markdown artifact'
      ExpectedPattern = 'performance artifact allowlist'
      Mutate = {
        param($Manifest)
        $Manifest.artifacts = @($Manifest.artifacts + [pscustomobject]@{
          path = 'artifacts/perf/lzma2-benchmark.md'
          bytes = 1
          sha256 = '0000000000000000000000000000000000000000000000000000000000000000'
        })
        return $Manifest
      }
    }
  )
  foreach ($case in $releasePreflightNegativeCases) {
    Invoke-CiManifestNegativeCase $case.Name $case.Mutate $case.ExpectedPattern
  }

  Invoke-TrackedTreeNegativeCase 'dirty tracked tree manifest evidence' 'README.md' {
    param($Text)
    return $Text + "`r`n"
  } 'clean tracked working tree'

  Invoke-NegativeCase 'release MT no-speedup acceptance' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.inputName -eq 'repeat5-256m.bin' -and
          [int]$row.threads -eq 2 -and
          $row.acceptance -in @('mt-release-speedup', 'mt-release-fastpath-saturated')) {
        $row.acceptance = 'mt-release-no-speedup'
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the release MT pass row to mutate.'
    }
  } 'failing acceptance label'

  Invoke-NegativeCase 'release mixed MT no-speedup acceptance' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.inputName -eq 'mixed-256m.bin' -and
          [int]$row.threads -eq 2 -and
          $row.acceptance -in @('mt-release-mixed-speedup', 'mt-release-mixed-overhead-bounded')) {
        $row.acceptance = 'mt-release-mixed-no-speedup'
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the mixed release MT pass row to mutate.'
    }
  } 'failing acceptance label'

  Invoke-NegativeCase 'release MT stale baseline comparison' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.inputName -eq 'repeat5-256m.bin' -and
          [int]$row.threads -eq 4 -and
          $row.acceptance -in @('mt-release-speedup', 'mt-release-fastpath-saturated')) {
        $row.baselineTool = 'delphi-native level1 1-thread encode on mixed-256m.bin'
        $row.baselineThroughputMiBs = 1.0
        $row.throughputRatioPct = 9999.0
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the release MT pass row to corrupt.'
    }
  } 'missing a passing release-corpus MT comparison row'

  Invoke-NegativeCase 'release mixed MT stale ratio math' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.inputName -eq 'mixed-256m.bin' -and
          [int]$row.threads -eq 4 -and
          $row.acceptance -in @('mt-release-mixed-speedup', 'mt-release-mixed-overhead-bounded')) {
        $row.throughputRatioPct = 1000.0
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the mixed release MT pass row to corrupt.'
    }
  } 'missing a passing release-corpus MT comparison row'

  Invoke-NegativeCase 'release encode ratio missing' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.inputName -eq 'repeat5-256m.bin' -and
          [int]$row.threads -eq 2 -and
          [int64]$row.inputBytes -ge 268435456) {
        $row.compressionRatio = $null
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the release encode ratio row to mutate.'
    }
  } 'Performance JSON rows must include compressionRatio'

  Invoke-NegativeCase 'release encode ratio too weak' {
    param($Rows)
    $mutated = $false
    foreach ($row in $Rows) {
      if ($row.tool -eq 'delphi-native' -and
          $row.operation -eq 'encode' -and
          $row.inputName -eq 'mixed-256m.bin' -and
          [int]$row.threads -eq 1 -and
          [int64]$row.inputBytes -ge 268435456) {
        $row.compressionRatio = 0.50
        $mutated = $true
        break
      }
    }
    if (-not $mutated) {
      throw 'Could not find the release encode ratio row to mutate.'
    }
  } 'usable diagnostic compression ratio and throughput'

  Invoke-NegativeCase 'missing mixed release corpus MT row' {
    param($Rows)
    $rowsArray = @($Rows)
    $filteredRows = @($rowsArray | Where-Object {
      -not ($_.tool -eq 'delphi-native' -and
        $_.operation -eq 'encode' -and
        $_.inputName -eq 'mixed-256m.bin' -and
        [int]$_.threads -eq 8)
    })
    if ($filteredRows.Count -eq $rowsArray.Count) {
      throw 'Could not find the mixed release MT row to remove.'
    }
    return $filteredRows
  } 'missing 256 MiB release-corpus Delphi encode row'

  Invoke-NegativeCase 'missing 16-thread release corpus MT row' {
    param($Rows)
    $rowsArray = @($Rows)
    $filteredRows = @($rowsArray | Where-Object {
      -not ($_.tool -eq 'delphi-native' -and
        $_.operation -eq 'encode' -and
        $_.inputName -eq 'mixed-256m.bin' -and
        [int]$_.threads -eq 16)
    })
    if ($filteredRows.Count -eq $rowsArray.Count) {
      throw 'Could not find the 16-thread mixed release MT row to remove.'
    }
    return $filteredRows
  } 'missing 256 MiB release-corpus Delphi encode row'

  Invoke-NegativeCase 'missing SDK raw LZMA release encode baseline' {
    param($Rows)
    $rowsArray = @($Rows)
    $filteredRows = @($rowsArray | Where-Object {
      -not ($_.tool -eq 'lzma-sdk' -and
        $_.operation -eq 'encode' -and
        $_.mode -eq 'raw-lzma-level-default' -and
        $_.inputName -eq 'repeat5-256m.bin')
    })
    if ($filteredRows.Count -eq $rowsArray.Count) {
      throw 'Could not find the SDK raw LZMA release encode baseline row to remove.'
    }
    return $filteredRows
  } 'SDK raw LZMA release-corpus encode baseline'

  Invoke-NegativeCase 'missing SDK raw LZMA release decode baseline' {
    param($Rows)
    $rowsArray = @($Rows)
    $filteredRows = @($rowsArray | Where-Object {
      -not ($_.tool -eq 'lzma-sdk' -and
        $_.operation -eq 'decode' -and
        $_.mode -eq 'raw-lzma-level-default' -and
        $_.inputName -eq 'repeat5-256m.sdk.lzma')
    })
    if ($filteredRows.Count -eq $rowsArray.Count) {
      throw 'Could not find the SDK raw LZMA release decode baseline row to remove.'
    }
    return $filteredRows
  } 'SDK raw LZMA release-corpus decode baseline'
}

Write-Host 'Artifact validator negative tests passed.'
