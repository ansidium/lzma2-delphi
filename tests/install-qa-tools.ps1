param(
  [switch]$ResolveOnly
)

$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSCommandPath) 'qa-tools.ps1')

if (-not $ResolveOnly) {
  [void](Install-LzmaSdkQATools)
  [void](Install-XzUtilsQATools)
}

$tools = Resolve-LzmaQATools -RequireExternalTools:$false -InstallMissing:$false
$report = [ordered]@{
  schemaVersion = 1
  resolvedAtUtc = [DateTime]::UtcNow.ToString('o')
  cacheRoot = Get-LzmaQAToolsRoot
  tools = [ordered]@{
    sevenZip = ConvertTo-LzmaQAToolManifestRecord $tools.sevenZip
    lzma = ConvertTo-LzmaQAToolManifestRecord $tools.lzma
    xz = ConvertTo-LzmaQAToolManifestRecord $tools.xz
  }
}

$report | ConvertTo-Json -Depth 8
