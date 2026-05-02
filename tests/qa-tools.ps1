$ErrorActionPreference = 'Stop'

$script:LzmaQAToolsScriptDir = Split-Path -Parent $PSCommandPath
$script:LzmaQAToolsConfig = $null

function Get-LzmaQAToolsConfig {
  if ($null -ne $script:LzmaQAToolsConfig) {
    return $script:LzmaQAToolsConfig
  }

  $configPath = Join-Path $script:LzmaQAToolsScriptDir 'qa-tools.json'
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Pinned QA tool config is missing: $configPath"
  }
  $script:LzmaQAToolsConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  return $script:LzmaQAToolsConfig
}

function Get-LzmaQAToolsRoot {
  $config = Get-LzmaQAToolsConfig
  $envName = [string]$config.cache.envName
  if (-not [string]::IsNullOrWhiteSpace($envName)) {
    $envValue = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
      return [IO.Path]::GetFullPath($envValue)
    }
  }

  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    $localAppData = Join-Path $env:USERPROFILE 'AppData\Local'
  }
  return [IO.Path]::GetFullPath((Join-Path $localAppData ([string]$config.cache.defaultLocalAppDataSubdir)))
}

function Assert-LzmaQAToolsOwnedPath([string]$Path) {
  $root = [IO.Path]::GetFullPath((Get-LzmaQAToolsRoot)).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
  if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify a path outside the pinned QA tools root: $Path"
  }
}

function Get-LzmaQAToolsReference([string]$ReferenceName) {
  $config = Get-LzmaQAToolsConfig
  if ($ReferenceName -eq 'lzmaSdk') { return $config.references.lzmaSdk }
  if ($ReferenceName -eq 'sevenZip') { return $config.references.sevenZip }
  if ($ReferenceName -eq 'xzUtils') { return $config.references.xzUtils }
  throw "Unknown QA tool reference: $ReferenceName"
}

function Get-LzmaQAToolExpectedVersion([object]$ToolConfig) {
  $reference = Get-LzmaQAToolsReference ([string]$ToolConfig.expectedVersionRef)
  if ($reference.PSObject.Properties.Name -contains 'version') {
    return [string]$reference.version
  }
  if ($reference.PSObject.Properties.Name -contains 'upstreamVersion') {
    return [string]$reference.upstreamVersion
  }
  return ''
}

function Get-LzmaQAToolSource([object]$ToolConfig) {
  $reference = Get-LzmaQAToolsReference ([string]$ToolConfig.sourceRef)
  if ($reference.PSObject.Properties.Name -contains 'toolSource') {
    return [string]$reference.toolSource
  }
  if ($reference.PSObject.Properties.Name -contains 'source') {
    return [string]$reference.source
  }
  return [string]$ToolConfig.sourceRef
}

function Expand-LzmaQAToolTemplate([string]$Template, [object]$ToolConfig) {
  if ([string]::IsNullOrWhiteSpace($Template)) {
    return ''
  }
  $reference = Get-LzmaQAToolsReference ([string]$ToolConfig.sourceRef)
  $version = Get-LzmaQAToolExpectedVersion $ToolConfig
  $archiveFile = if ($reference.PSObject.Properties.Name -contains 'archiveFile') { [string]$reference.archiveFile } else { '' }
  return $Template.Replace('{version}', $version).Replace('{archiveFile}', $archiveFile)
}

function Get-LzmaQAToolConfig([string]$ToolId) {
  $config = Get-LzmaQAToolsConfig
  if ($ToolId -eq 'sevenZip') { return $config.tools.sevenZip }
  if ($ToolId -eq 'lzma') { return $config.tools.lzma }
  if ($ToolId -eq 'xz') { return $config.tools.xz }
  throw "Unknown QA tool id: $ToolId"
}

function Get-LzmaQAToolVersion([string]$Path, [object]$ToolConfig) {
  $args = @($ToolConfig.versionArgs | ForEach-Object { [string]$_ })
  $output = ''
  $exitCode = 0
  try {
    $output = & $Path @args 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
  }
  finally {
    $global:LASTEXITCODE = 0
  }

  $lines = @($output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
    Select-Object -First 10
  return [pscustomobject]@{
    exitCode = $exitCode
    version = ($lines -join "`n")
    commandArgs = @($args)
  }
}

function Install-LzmaSdkQATools {
  $config = Get-LzmaQAToolsConfig
  $sdk = $config.references.lzmaSdk
  $toolsRoot = Get-LzmaQAToolsRoot
  $sdkDir = Join-Path $toolsRoot ("lzma-sdk-{0}" -f $sdk.version)
  $sevenZipPath = Join-Path $sdkDir 'bin\x64\7zr.exe'
  $lzmaPath = Join-Path $sdkDir 'bin\x64\lzma.exe'
  if ((Test-Path -LiteralPath $sevenZipPath) -and (Test-Path -LiteralPath $lzmaPath)) {
    return [pscustomobject]@{
      root = $sdkDir
      sevenZip = $sevenZipPath
      lzma = $lzmaPath
      installed = $false
    }
  }

  New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
  $archivePath = Join-Path $toolsRoot ([string]$sdk.archiveFile)
  if (-not (Test-Path -LiteralPath $archivePath)) {
    Write-Host "Downloading pinned LZMA SDK $($sdk.version): $($sdk.archiveUrl)"
    Invoke-WebRequest -Uri ([string]$sdk.archiveUrl) -OutFile $archivePath
  }
  $expectedArchiveHash = ''
  if ($sdk.PSObject.Properties.Name -contains 'archiveSha256') {
    $expectedArchiveHash = [string]$sdk.archiveSha256
  }
  if (-not [string]::IsNullOrWhiteSpace($expectedArchiveHash)) {
    $actualArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    if ($actualArchiveHash -ne $expectedArchiveHash.ToLowerInvariant()) {
      throw "Pinned LZMA SDK archive hash mismatch. Expected $expectedArchiveHash, got $actualArchiveHash."
    }
  }

  $extractDir = Join-Path $toolsRoot ("lzma-sdk-{0}.extracting" -f $sdk.version)
  Assert-LzmaQAToolsOwnedPath $extractDir
  if (Test-Path -LiteralPath $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

  $sevenZipExtractor = @(
    (Get-Command 7z.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Get-Command 7za.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    (Get-Command 7zr.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    'C:\Program Files\7-Zip\7z.exe',
    'C:\Program Files (x86)\7-Zip\7z.exe'
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } |
    Select-Object -First 1

  if (-not [string]::IsNullOrWhiteSpace($sevenZipExtractor)) {
    & $sevenZipExtractor x $archivePath "-o$extractDir" -y | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "$sevenZipExtractor failed to extract $archivePath"
    }
  } else {
    $tar = (Get-Command tar.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    if ([string]::IsNullOrWhiteSpace($tar)) {
      throw '7-Zip or tar.exe is required to extract the pinned LZMA SDK archive.'
    }
    & $tar -xf $archivePath -C $extractDir
    if ($LASTEXITCODE -ne 0) {
      throw "tar.exe failed to extract $archivePath"
    }
  }

  if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'bin\x64\7zr.exe')) -or
      -not (Test-Path -LiteralPath (Join-Path $extractDir 'bin\x64\lzma.exe'))) {
    throw 'Extracted LZMA SDK archive does not contain bin\x64\7zr.exe and bin\x64\lzma.exe.'
  }

  Assert-LzmaQAToolsOwnedPath $sdkDir
  if (Test-Path -LiteralPath $sdkDir) {
    Remove-Item -LiteralPath $sdkDir -Recurse -Force
  }
  Move-Item -LiteralPath $extractDir -Destination $sdkDir

  $archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
  [ordered]@{
    schemaVersion = 1
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    version = [string]$sdk.version
    releaseDate = [string]$sdk.releaseDate
    officialPage = [string]$sdk.officialPage
    archiveUrl = [string]$sdk.archiveUrl
    expectedArchiveSha256 = [string]$sdk.archiveSha256
    archiveSha256 = $archiveHash
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $sdkDir 'lzma-sdk-install.json') -Encoding UTF8

  return [pscustomobject]@{
    root = $sdkDir
    sevenZip = $sevenZipPath
    lzma = $lzmaPath
    installed = $true
  }
}

function Install-XzUtilsQATools {
  $config = Get-LzmaQAToolsConfig
  $xz = $config.references.xzUtils
  $toolsRoot = Get-LzmaQAToolsRoot
  $installDir = if ($xz.PSObject.Properties.Name -contains 'defaultInstallDir') {
    ([string]$xz.defaultInstallDir).Replace('{version}', [string]$xz.version)
  } else {
    "xz-utils-$($xz.version)"
  }
  $xzDir = Join-Path $toolsRoot $installDir
  $xzPath = Join-Path $xzDir 'bin_x86-64\xz.exe'
  $dllPath = Join-Path $xzDir 'bin_x86-64\liblzma.dll'
  if ((Test-Path -LiteralPath $xzPath) -and (Test-Path -LiteralPath $dllPath)) {
    return [pscustomobject]@{
      root = $xzDir
      xz = $xzPath
      installed = $false
    }
  }

  New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null
  $archivePath = Join-Path $toolsRoot ([string]$xz.archiveFile)
  if (-not (Test-Path -LiteralPath $archivePath)) {
    Write-Host "Downloading pinned XZ Utils $($xz.version) Windows binaries: $($xz.archiveUrl)"
    Invoke-WebRequest -Uri ([string]$xz.archiveUrl) -OutFile $archivePath
  }

  $expectedArchiveHash = ''
  if ($xz.PSObject.Properties.Name -contains 'archiveSha256') {
    $expectedArchiveHash = [string]$xz.archiveSha256
  }
  if (-not [string]::IsNullOrWhiteSpace($expectedArchiveHash)) {
    $actualArchiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
    if ($actualArchiveHash -ne $expectedArchiveHash.ToLowerInvariant()) {
      throw "Pinned XZ Utils Windows archive hash mismatch. Expected $expectedArchiveHash, got $actualArchiveHash."
    }
  }

  $extractDir = Join-Path $toolsRoot ("xz-utils-{0}.extracting" -f $xz.version)
  Assert-LzmaQAToolsOwnedPath $extractDir
  if (Test-Path -LiteralPath $extractDir) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force

  if (-not (Test-Path -LiteralPath (Join-Path $extractDir 'bin_x86-64\xz.exe')) -or
      -not (Test-Path -LiteralPath (Join-Path $extractDir 'bin_x86-64\liblzma.dll'))) {
    throw 'Extracted XZ Utils archive does not contain bin_x86-64\xz.exe and bin_x86-64\liblzma.dll.'
  }

  Assert-LzmaQAToolsOwnedPath $xzDir
  if (Test-Path -LiteralPath $xzDir) {
    Remove-Item -LiteralPath $xzDir -Recurse -Force
  }
  Move-Item -LiteralPath $extractDir -Destination $xzDir

  $archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
  [ordered]@{
    schemaVersion = 1
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    version = [string]$xz.version
    releaseDate = [string]$xz.releaseDate
    officialPage = [string]$xz.officialPage
    archiveUrl = [string]$xz.archiveUrl
    expectedArchiveSha256 = [string]$xz.archiveSha256
    archiveSha256 = $archiveHash
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $xzDir 'xz-utils-install.json') -Encoding UTF8

  return [pscustomobject]@{
    root = $xzDir
    xz = $xzPath
    installed = $true
  }
}

function New-LzmaQAToolRecord(
  [string]$ToolId,
  [string]$Path,
  [bool]$Available,
  [string]$ResolvedFrom,
  [object]$VersionInfo
) {
  $toolConfig = Get-LzmaQAToolConfig $ToolId
  $reference = Get-LzmaQAToolsReference ([string]$toolConfig.sourceRef)
  $record = [ordered]@{
    id = $ToolId
    displayName = [string]$toolConfig.displayName
    path = if ($Path) { [IO.Path]::GetFullPath($Path) } else { '' }
    available = [bool]$Available
    resolvedFrom = $ResolvedFrom
    expectedExecutable = [string]$toolConfig.expectedExecutable
    expectedVersion = Get-LzmaQAToolExpectedVersion $toolConfig
    versionPattern = [string]$toolConfig.versionPattern
    pinMode = if ($toolConfig.PSObject.Properties.Name -contains 'pinMode') { [string]$toolConfig.pinMode } else { 'version-pattern' }
    source = Get-LzmaQAToolSource $toolConfig
    officialPage = if ($reference.PSObject.Properties.Name -contains 'officialPage') { [string]$reference.officialPage } else { '' }
    releaseDate = if ($reference.PSObject.Properties.Name -contains 'releaseDate') { [string]$reference.releaseDate } else { '' }
    archiveUrl = if ($reference.PSObject.Properties.Name -contains 'archiveUrl') { [string]$reference.archiveUrl } else { '' }
    archiveSha256 = if ($reference.PSObject.Properties.Name -contains 'archiveSha256') { [string]$reference.archiveSha256 } else { '' }
    upstreamVersion = if ($reference.PSObject.Properties.Name -contains 'upstreamVersion') { [string]$reference.upstreamVersion } else { '' }
    githubRelease = if ($reference.PSObject.Properties.Name -contains 'githubRelease') { [string]$reference.githubRelease } else { '' }
    sourceForgeArchive = if ($reference.PSObject.Properties.Name -contains 'sourceForgeArchive') { [string]$reference.sourceForgeArchive } else { '' }
    cacheRoot = Get-LzmaQAToolsRoot
  }
  if ($null -ne $VersionInfo) {
    $record.exitCode = [int]$VersionInfo.exitCode
    $record.version = [string]$VersionInfo.version
    $record.versionCommandArgs = @($VersionInfo.commandArgs)
  } else {
    $record.exitCode = $null
    $record.version = ''
    $record.versionCommandArgs = @()
  }
  return [pscustomobject]$record
}

function Assert-LzmaQAToolRecord([object]$Record) {
  if ($null -eq $Record -or -not [bool]$Record.available) {
    return
  }

  $toolConfig = Get-LzmaQAToolConfig ([string]$Record.id)
  $leaf = Split-Path -Leaf ([string]$Record.path)
  if ($leaf -ne [string]$toolConfig.expectedExecutable) {
    throw "$($toolConfig.displayName) must resolve to $($toolConfig.expectedExecutable), got $leaf"
  }
  if ([string]::IsNullOrWhiteSpace([string]$Record.version) -or
      [string]$Record.version -notmatch [string]$toolConfig.versionPattern) {
    throw "$($toolConfig.displayName) version does not match pinned pattern $($toolConfig.versionPattern). Version output: $($Record.version)"
  }
  if ($toolConfig.PSObject.Properties.Name -contains 'pathPattern' -and
      -not [string]::IsNullOrWhiteSpace([string]$toolConfig.pathPattern) -and
      [string]$Record.path -notmatch [string]$toolConfig.pathPattern) {
    throw "$($toolConfig.displayName) must come from the pinned source path pattern $($toolConfig.pathPattern), got $($Record.path)"
  }
  if ($toolConfig.PSObject.Properties.Name -contains 'pathPatternTemplate') {
    $pathPattern = Expand-LzmaQAToolTemplate ([string]$toolConfig.pathPatternTemplate) $toolConfig
    if (-not [string]::IsNullOrWhiteSpace($pathPattern) -and
        [string]$Record.path -notmatch $pathPattern) {
      throw "$($toolConfig.displayName) must come from the pinned source path pattern $pathPattern, got $($Record.path)"
    }
  }
}

function Resolve-LzmaQATool(
  [string]$ToolId,
  [string]$ExplicitPath,
  [bool]$Required = $false,
  [bool]$InstallMissing = $false
) {
  $toolConfig = Get-LzmaQAToolConfig $ToolId
  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    if (-not (Test-Path -LiteralPath $ExplicitPath)) {
      throw "$($toolConfig.envName) was configured but does not exist: $ExplicitPath"
    }
    $versionInfo = Get-LzmaQAToolVersion $ExplicitPath $toolConfig
    $record = New-LzmaQAToolRecord $ToolId $ExplicitPath $true 'parameter-or-environment' $versionInfo
    Assert-LzmaQAToolRecord $record
    return $record
  }

  if (($ToolId -eq 'sevenZip' -or $ToolId -eq 'lzma') -and $InstallMissing) {
    [void](Install-LzmaSdkQATools)
  }
  if ($ToolId -eq 'xz' -and $InstallMissing) {
    [void](Install-XzUtilsQATools)
  }

  $candidates = New-Object System.Collections.Generic.List[object]
  if ($toolConfig.PSObject.Properties.Name -contains 'defaultRelativePath') {
    $candidates.Add([pscustomobject]@{
      path = Join-Path (Get-LzmaQAToolsRoot) ([string]$toolConfig.defaultRelativePath)
      resolvedFrom = 'pinned-cache'
    })
  }
  if ($toolConfig.PSObject.Properties.Name -contains 'defaultRelativePathTemplate') {
    $candidates.Add([pscustomobject]@{
      path = Join-Path (Get-LzmaQAToolsRoot) (Expand-LzmaQAToolTemplate ([string]$toolConfig.defaultRelativePathTemplate) $toolConfig)
      resolvedFrom = 'pinned-cache'
    })
  }
  if ($toolConfig.PSObject.Properties.Name -contains 'defaultPaths') {
    foreach ($path in @($toolConfig.defaultPaths)) {
      $candidates.Add([pscustomobject]@{
        path = [string]$path
        resolvedFrom = 'pinned-default-path'
      })
    }
  }

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate.path)) {
      continue
    }
    if (-not (Test-Path -LiteralPath ([string]$candidate.path))) {
      continue
    }
    $versionInfo = Get-LzmaQAToolVersion ([string]$candidate.path) $toolConfig
    $record = New-LzmaQAToolRecord $ToolId ([string]$candidate.path) $true ([string]$candidate.resolvedFrom) $versionInfo
    Assert-LzmaQAToolRecord $record
    return $record
  }

  $missing = New-LzmaQAToolRecord $ToolId '' $false 'not-configured' $null
  if ($Required) {
    $hint = if ($ToolId -eq 'sevenZip' -or $ToolId -eq 'lzma') {
      "Run tests\install-qa-tools.ps1 or set $($toolConfig.envName)."
    } else {
      "Run tests\install-qa-tools.ps1 or set $($toolConfig.envName) to the pinned official XZ Utils xz.exe."
    }
    throw "$($toolConfig.displayName) was not found. $hint"
  }
  return $missing
}

function Resolve-LzmaQATools {
  param(
    [string]$SevenZip = '',
    [string]$LzmaExe = '',
    [string]$Xz = '',
    [bool]$RequireExternalTools = $false,
    [bool]$RequireSevenZip = $RequireExternalTools,
    [bool]$RequireLzma = $RequireExternalTools,
    [bool]$RequireXz = $RequireExternalTools,
    [bool]$InstallMissing = $false,
    [switch]$SetEnvironment
  )

  $sevenZipRecord = Resolve-LzmaQATool 'sevenZip' $SevenZip $RequireSevenZip $InstallMissing
  $lzmaRecord = Resolve-LzmaQATool 'lzma' $LzmaExe $RequireLzma $InstallMissing
  $xzRecord = Resolve-LzmaQATool 'xz' $Xz $RequireXz $InstallMissing

  if ($SetEnvironment) {
    if ($sevenZipRecord.available) { $env:LZMA_TEST_7Z = [string]$sevenZipRecord.path }
    if ($lzmaRecord.available) { $env:LZMA_TEST_LZMA = [string]$lzmaRecord.path }
    if ($xzRecord.available) { $env:LZMA_TEST_XZ = [string]$xzRecord.path }
  }

  return [pscustomobject]@{
    sevenZip = $sevenZipRecord
    lzma = $lzmaRecord
    xz = $xzRecord
  }
}

function ConvertTo-LzmaQAToolManifestRecord([object]$Record) {
  if ($null -eq $Record) {
    return $null
  }
  return [ordered]@{
    id = [string]$Record.id
    displayName = [string]$Record.displayName
    path = [string]$Record.path
    available = [bool]$Record.available
    exitCode = $Record.exitCode
    version = [string]$Record.version
    versionCommandArgs = @($Record.versionCommandArgs)
    resolvedFrom = [string]$Record.resolvedFrom
    expectedExecutable = [string]$Record.expectedExecutable
    expectedVersion = [string]$Record.expectedVersion
    versionPattern = [string]$Record.versionPattern
    pinMode = [string]$Record.pinMode
    source = [string]$Record.source
    officialPage = [string]$Record.officialPage
    releaseDate = [string]$Record.releaseDate
    archiveUrl = [string]$Record.archiveUrl
    archiveSha256 = [string]$Record.archiveSha256
    upstreamVersion = [string]$Record.upstreamVersion
    githubRelease = [string]$Record.githubRelease
    sourceForgeArchive = [string]$Record.sourceForgeArchive
    cacheRoot = [string]$Record.cacheRoot
  }
}
