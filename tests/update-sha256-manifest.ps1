param(
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$fixtureRoot = Join-Path $root 'tests\fixtures'
$manifestRoot = Join-Path $fixtureRoot 'manifests'

if (-not $OutputPath) {
  $OutputPath = Join-Path (Join-Path $root 'artifacts') 'fixtures\sha256-fixtures.json'
}

function Get-RelativePath([string]$BasePath, [string]$Path) {
  $base = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($base.Length).Replace('\', '/')
  }
  return $full.Replace('\', '/')
}

function New-HashRecord([IO.FileInfo]$File, [string]$Kind) {
  $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $File.FullName
  [ordered]@{
    kind = $Kind
    path = Get-RelativePath $root $File.FullName
    bytes = $File.Length
    sha256 = $hash.Hash.ToLowerInvariant()
    lastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
  }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null

$fixtureFiles = @()
if (Test-Path -LiteralPath $fixtureRoot) {
  $fixtureFiles = Get-ChildItem -LiteralPath $fixtureRoot -File -Recurse |
    Where-Object { $_.FullName -notlike "$manifestRoot*" } |
    Sort-Object FullName
}

$manifestFiles = @()
if (Test-Path -LiteralPath $manifestRoot) {
  $manifestFiles = Get-ChildItem -LiteralPath $manifestRoot -File -Filter '*.json' |
    Where-Object { $_.FullName -ne [IO.Path]::GetFullPath($OutputPath) } |
    Sort-Object FullName
}

$report = [ordered]@{
  schemaVersion = 1
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  fixtureRoot = 'tests/fixtures'
  fixtures = @($fixtureFiles | ForEach-Object { New-HashRecord $_ 'fixture' })
  manifests = @($manifestFiles | ForEach-Object { New-HashRecord $_ 'manifest' })
}

$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "SHA-256 fixture manifest written: $OutputPath"
