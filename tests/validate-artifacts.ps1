param(
  [switch]$RequireExternalTools,
  [switch]$RequireReleaseCorpus
)

$expectedLzmaSdkVersionPattern = ''
$sdkCompressedSizeRatioGate = 1.001

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'tests\qa-tools.ps1')
$script:QAToolConfig = Get-LzmaQAToolsConfig
$expectedLzmaSdkVersionPattern = [string]$script:QAToolConfig.tools.sevenZip.versionPattern
$artifacts = Join-Path $root 'artifacts'
$ForbiddenGraphArtifactPatterns = @(
  'artifacts/perf/lzma2-delphi-graph.*',
  'artifacts/perf/*graph*',
  'artifacts/perf/*.png',
  'artifacts/perf/*.svg',
  'artifacts/perf/*.jpg',
  'artifacts/perf/*.jpeg',
  'artifacts/perf/*.webp'
)

function Require-File([string]$RelativePath) {
  $path = Join-Path $root $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required artifact is missing: $RelativePath"
  }
  return $path
}

function Get-RepoRelativePath([string]$Path) {
  $base = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath($Path)
  if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($base.Length).Replace('\', '/')
  }
  return $full
}

function Get-CurrentGitCommit {
  try {
    $commit = & git -C $root rev-parse HEAD 2>$null
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -eq 0) {
      return ([string]$commit).Trim()
    }
  } catch {
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
      return @($status)
    }
  } catch {
    $global:LASTEXITCODE = 0
  }
  return @()
}

function Get-ReleaseBenchmarkWorkRoot($Configuration) {
  if ($null -eq $Configuration) {
    return [pscustomobject]@{
      Path = ''
      RamBacked = $false
    }
  }

  $ramWorkRoot = [string]$Configuration.ramWorkRoot
  if (-not [string]::IsNullOrWhiteSpace($ramWorkRoot)) {
    return [pscustomobject]@{
      Path = $ramWorkRoot
      RamBacked = $true
    }
  }

  $performanceWorkRoot = [string]$Configuration.performanceWorkRoot
  if (-not [string]::IsNullOrWhiteSpace($performanceWorkRoot)) {
    return [pscustomobject]@{
      Path = $performanceWorkRoot
      RamBacked = $false
    }
  }

  return [pscustomobject]@{
    Path = ''
    RamBacked = $false
  }
}

function Assert-DriveIsFixedSsd([char]$Drive, [string]$DriveRoot, [string]$Context) {
  $driveInfo = [IO.DriveInfo]::new($DriveRoot)
  if ($driveInfo.DriveType -ne [IO.DriveType]::Fixed) {
    throw "$Context must be on a local fixed SSD drive C: or D:. Current drive $DriveRoot is $($driveInfo.DriveType)."
  }

  try {
    $partition = Get-Partition -DriveLetter $Drive -ErrorAction Stop | Select-Object -First 1
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
  } catch {
    throw "Could not confirm that CI manifest benchmark drive $DriveRoot is a local SSD. $($_.Exception.Message)"
  }

  if (-not $physicalDisk) {
    throw "Could not map CI manifest benchmark drive $DriveRoot to a physical disk with SSD media type."
  }
  if ([string]$physicalDisk.MediaType -ne 'SSD') {
    throw "$Context must be on SSD drive C: or D:. Drive $DriveRoot maps to disk $diskNumber with media type '$($physicalDisk.MediaType)'."
  }
}

function Assert-CiBenchmarkWorkRoot([string]$WorkRoot, [bool]$RamBacked) {
  if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    throw 'CI manifest is missing the release performance work root or RAM work root.'
  }

  try {
    $full = [IO.Path]::GetFullPath($WorkRoot)
  } catch {
    throw "CI manifest benchmark work root is not a valid path: $WorkRoot"
  }
  if ($full -match '^\\\\\?\\([A-Za-z]:\\.*)$') {
    $full = $Matches[1]
  }

  $repoRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
  if ($full.TrimEnd('\').Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'CI manifest benchmark work root must not be the repository root.'
  }

  $pathRoot = [IO.Path]::GetPathRoot($full)
  if ([string]::IsNullOrWhiteSpace($pathRoot)) {
    throw 'CI manifest benchmark work root must be an absolute local path.'
  }
  if ($full.TrimEnd('\').Equals($pathRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'CI manifest benchmark work root must be a dedicated directory, not a drive root.'
  }

  if ($RamBacked) {
    $driveInfo = [IO.DriveInfo]::new($pathRoot)
    if ($driveInfo.DriveType -ne [IO.DriveType]::Ram) {
      throw "CI manifest benchmark work root is marked RAM-backed but drive $pathRoot is $($driveInfo.DriveType)."
    }
    return
  }

  if (-not $RamBacked -and $pathRoot -notmatch '^[CD]:\\$') {
    throw 'CI manifest performance work root must be on SSD drive C: or D:.'
  }
  $drive = [char]::ToUpperInvariant($pathRoot[0])
  Assert-DriveIsFixedSsd $drive $pathRoot 'CI manifest performance work root'
}

function Assert-ReferencedSourceFilesTracked {
  $referenceRoots = @('tools', 'tests')
  $referenced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($referenceRoot in $referenceRoots) {
    $dir = Join-Path $root $referenceRoot
    if (-not (Test-Path -LiteralPath $dir)) {
      continue
    }
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object {
      $_.Extension.ToLowerInvariant() -in @('.dpr', '.dproj', '.pas')
    })
    foreach ($file in $files) {
      $text = Get-Content -LiteralPath $file.FullName -Raw
      foreach ($match in [regex]::Matches($text, '(?:\.\.[\\/])?src[\\/][^''"<>\r\n]+?\.(?:pas|inc)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $candidate = [string]$match.Value
        $full = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $candidate))
        $relative = Get-RepoRelativePath $full
        if ($relative -like 'src/*') {
          [void]$referenced.Add($relative)
        }
      }
    }
  }

  foreach ($relative in $referenced) {
    $path = Join-Path $root ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Referenced source file is missing: $relative"
    }
    $tracked = @(& git -C $root ls-files -- $relative 2>$null)
    $exitCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($exitCode -ne 0 -or $tracked.Count -eq 0) {
      throw "Referenced source file is not tracked by git: $relative"
    }
  }
}

function ConvertTo-StringList($Value) {
  if ($null -eq $Value) {
    return @()
  }
  return @($Value | ForEach-Object {
    if ($null -ne $_) {
      [string]$_
    }
  } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-PinnedQAToolEvidence($ToolRecord, [string]$ToolId, [bool]$Required, [string]$Context) {
  $toolConfig = Get-LzmaQAToolConfig $ToolId
  if ($null -eq $ToolRecord) {
    if ($Required) {
      throw "$Context is missing required $ToolId pinned QA tool record."
    }
    return
  }

  if ($Required -and -not [bool]$ToolRecord.available) {
    throw "$Context is missing a working $ToolId pinned QA tool record."
  }
  if (-not [bool]$ToolRecord.available) {
    return
  }

  foreach ($propertyName in @('resolvedFrom', 'expectedExecutable', 'expectedVersion', 'versionPattern', 'pinMode', 'source')) {
    if (@($ToolRecord.PSObject.Properties.Name) -notcontains $propertyName -or
        [string]::IsNullOrWhiteSpace([string]$ToolRecord.$propertyName)) {
      throw "$Context $ToolId tool record is missing pinned QA metadata: $propertyName."
    }
  }

  $expectedExecutable = [string]$toolConfig.expectedExecutable
  if ([string]$ToolRecord.expectedExecutable -ne $expectedExecutable) {
    throw "$Context $ToolId tool record has stale expected executable metadata."
  }
  if ((Split-Path -Leaf ([string]$ToolRecord.path)) -ne $expectedExecutable) {
    throw "$Context $ToolId tool path must resolve to $expectedExecutable."
  }
  if ([string]$ToolRecord.version -notmatch [string]$toolConfig.versionPattern) {
    throw "$Context $ToolId tool version does not match pinned config."
  }
  $expectedPinMode = if ($toolConfig.PSObject.Properties.Name -contains 'pinMode') { [string]$toolConfig.pinMode } else { 'version-pattern' }
  if ([string]$ToolRecord.pinMode -ne $expectedPinMode) {
    throw "$Context $ToolId tool record has stale pin mode metadata."
  }
  if ($expectedPinMode -eq 'archive-sha256') {
    $reference = Get-LzmaQAToolsReference ([string]$toolConfig.sourceRef)
    $expectedArchiveHash = if ($reference.PSObject.Properties.Name -contains 'archiveSha256') { [string]$reference.archiveSha256 } else { '' }
    if ([string]::IsNullOrWhiteSpace([string]$ToolRecord.archiveSha256) -or
        [string]$ToolRecord.archiveSha256 -ne $expectedArchiveHash) {
      throw "$Context $ToolId tool record is missing pinned archive SHA-256 metadata."
    }
  }
  if ($expectedPinMode -eq 'source-path') {
    $expectedSource = Get-LzmaQAToolSource $toolConfig
    if ([string]$ToolRecord.source -ne $expectedSource) {
      throw "$Context $ToolId tool record has stale source-path pin metadata."
    }
    $reference = Get-LzmaQAToolsReference ([string]$toolConfig.sourceRef)
    $expectedUpstream = if ($reference.PSObject.Properties.Name -contains 'upstreamVersion') { [string]$reference.upstreamVersion } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($expectedUpstream) -and
        [string]$ToolRecord.upstreamVersion -ne $expectedUpstream) {
      throw "$Context $ToolId tool record has stale upstream reference metadata."
    }
  }
  if ($toolConfig.PSObject.Properties.Name -contains 'pathPattern' -and
      -not [string]::IsNullOrWhiteSpace([string]$toolConfig.pathPattern) -and
      [string]$ToolRecord.path -notmatch [string]$toolConfig.pathPattern) {
    throw "$Context $ToolId tool path does not match the pinned source path pattern."
  }
  if ($toolConfig.PSObject.Properties.Name -contains 'pathPatternTemplate') {
    $expectedVersion = Get-LzmaQAToolExpectedVersion $toolConfig
    $pathPattern = ([string]$toolConfig.pathPatternTemplate).Replace('{version}', $expectedVersion)
    if (-not [string]::IsNullOrWhiteSpace($pathPattern) -and
        [string]$ToolRecord.path -notmatch $pathPattern) {
      throw "$Context $ToolId tool path does not match the pinned source path pattern."
    }
  }
}

function Require-RawLzmaFixtureCacheEvidence([object[]]$Cases, [string]$Label) {
  foreach ($case in $Cases) {
    $propertyNames = @($case.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'cacheKey' -or
        $propertyNames -notcontains 'cacheHit' -or
        $propertyNames -notcontains 'cachePath') {
      throw "$Label fixture cache evidence is missing."
    }
    if ([string]$case.cacheKey -notmatch '^[0-9a-f]{64}$') {
      throw "$Label fixture cache key is invalid."
    }
    $cachePathText = ([string]$case.cachePath) -replace '\\', '/'
    if ($cachePathText -notlike 'tests/fixtures/cache/*.lzma') {
      throw "$Label fixture cache path is outside the fixture cache."
    }
    $cachePath = Join-Path $root ($cachePathText -replace '/', '\')
    if (-not (Test-Path -LiteralPath $cachePath)) {
      throw "$Label fixture cache file is missing."
    }
    $cacheHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cachePath).Hash.ToLowerInvariant()
    if ($propertyNames -contains 'compressedSha256' -and
        $cacheHash -ne ([string]$case.compressedSha256).ToLowerInvariant()) {
      throw "$Label fixture cache hash does not match the compressed fixture."
    }
  }
}

function Test-ApprovedWarningEntry([string]$WarningLine, $Entry) {
  if ($null -eq $Entry) {
    return $false
  }

  $pattern = ''
  if ($Entry -is [string]) {
    $pattern = [string]$Entry
  } else {
    foreach ($propertyName in @('pattern', 'regex', 'message', 'text', 'id')) {
      if ($Entry.PSObject.Properties.Name -contains $propertyName) {
        $pattern = [string]$Entry.$propertyName
        if (-not [string]::IsNullOrWhiteSpace($pattern)) {
          break
        }
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($pattern)) {
    return $false
  }
  if ($WarningLine -eq $pattern) {
    return $true
  }
  if ($WarningLine -like $pattern) {
    return $true
  }
  try {
    return ($WarningLine -match $pattern)
  } catch {
    return $false
  }
}

function Get-LineNumber([string]$Text, [int]$Index) {
  if ($Index -le 0) {
    return 1
  }
  return ([regex]::Matches($Text.Substring(0, $Index), "`r`n|`n|`r").Count + 1)
}

function Remove-DelphiCommentsAndStrings([string]$Text) {
  $builder = [System.Text.StringBuilder]::new($Text)
  $i = 0
  while ($i -lt $Text.Length) {
    $ch = $Text[$i]

    if ($ch -eq [char]39) {
      $builder[$i] = [char]' '
      $i++
      while ($i -lt $Text.Length) {
        $builder[$i] = [char]' '
        if ($Text[$i] -eq [char]39) {
          if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]39) {
            $i += 2
            continue
          }
          $i++
          break
        }
        $i++
      }
      continue
    }

    if ($ch -eq [char]'/' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]'/') {
      while ($i -lt $Text.Length -and $Text[$i] -ne [char]"`r" -and $Text[$i] -ne [char]"`n") {
        $builder[$i] = [char]' '
        $i++
      }
      continue
    }

    if ($ch -eq [char]'{') {
      $builder[$i] = [char]' '
      $i++
      while ($i -lt $Text.Length) {
        if ($Text[$i] -ne [char]"`r" -and $Text[$i] -ne [char]"`n") {
          $builder[$i] = [char]' '
        }
        if ($Text[$i] -eq [char]'}') {
          $i++
          break
        }
        $i++
      }
      continue
    }

    if ($ch -eq [char]'(' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]'*') {
      $builder[$i] = [char]' '
      $builder[$i + 1] = [char]' '
      $i += 2
      while ($i -lt $Text.Length) {
        if ($Text[$i] -ne [char]"`r" -and $Text[$i] -ne [char]"`n") {
          $builder[$i] = [char]' '
        }
        if ($Text[$i] -eq [char]'*' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]')') {
          $builder[$i] = [char]' '
          $builder[$i + 1] = [char]' '
          $i += 2
          break
        }
        $i++
      }
      continue
    }

    $i++
  }
  return $builder.ToString()
}

function Remove-DelphiCommentsPreserveStrings([string]$Text) {
  $builder = [System.Text.StringBuilder]::new($Text)
  $i = 0
  while ($i -lt $Text.Length) {
    $ch = $Text[$i]

    if ($ch -eq [char]39) {
      $i++
      while ($i -lt $Text.Length) {
        if ($Text[$i] -eq [char]39) {
          if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]39) {
            $i += 2
            continue
          }
          $i++
          break
        }
        $i++
      }
      continue
    }

    if ($ch -eq [char]'/' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]'/') {
      while ($i -lt $Text.Length -and $Text[$i] -ne [char]"`r" -and $Text[$i] -ne [char]"`n") {
        $builder[$i] = [char]' '
        $i++
      }
      continue
    }

    if ($ch -eq [char]'{') {
      $builder[$i] = [char]' '
      $i++
      while ($i -lt $Text.Length) {
        if ($Text[$i] -ne [char]"`r" -and $Text[$i] -ne [char]"`n") {
          $builder[$i] = [char]' '
        }
        if ($Text[$i] -eq [char]'}') {
          $i++
          break
        }
        $i++
      }
      continue
    }

    if ($ch -eq [char]'(' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]'*') {
      $builder[$i] = [char]' '
      $builder[$i + 1] = [char]' '
      $i += 2
      while ($i -lt $Text.Length) {
        if ($Text[$i] -ne [char]"`r" -and $Text[$i] -ne [char]"`n") {
          $builder[$i] = [char]' '
        }
        if ($Text[$i] -eq [char]'*' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq [char]')') {
          $builder[$i] = [char]' '
          $builder[$i + 1] = [char]' '
          $i += 2
          break
        }
        $i++
      }
      continue
    }

    $i++
  }
  return $builder.ToString()
}

function Assert-NativeRuntimeSource {
  $runtimeSourceDir = Join-Path $root 'src'
  if (-not (Test-Path -LiteralPath $runtimeSourceDir)) {
    throw 'Runtime source directory is missing: src'
  }

  $forbiddenExtensions = @(
    '.c', '.cc', '.cpp', '.cxx',
    '.h', '.hh', '.hpp', '.hxx',
    '.obj', '.o', '.lib', '.dll', '.a', '.so', '.dylib'
  )
  $runtimeDependencyDirs = @($runtimeSourceDir)
  $toolsSourceDir = Join-Path $root 'tools'
  if (Test-Path -LiteralPath $toolsSourceDir) {
    $runtimeDependencyDirs += $toolsSourceDir
  }
  $forbiddenFiles = @($runtimeDependencyDirs | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Recurse -File | Where-Object {
      $forbiddenExtensions -contains $_.Extension.ToLowerInvariant()
    }
  })
  if ($forbiddenFiles.Count -gt 0) {
    throw "forbidden runtime dependency file: $(Get-RepoRelativePath $forbiddenFiles[0].FullName)"
  }

  $sourceExtensions = @('.pas', '.dpr', '.inc')
  $sourceFiles = @($runtimeDependencyDirs | ForEach-Object {
    Get-ChildItem -LiteralPath $_ -Recurse -File | Where-Object {
      $sourceExtensions -contains $_.Extension.ToLowerInvariant()
    }
  })
  $directivePatterns = @(
    [pscustomobject]@{ Pattern = '\{\$\s*L\b'; Description = 'Delphi object-link directive' },
    [pscustomobject]@{ Pattern = '\{\$\s*LINK\b'; Description = 'Delphi link directive' },
    [pscustomobject]@{ Pattern = '\{\$\s*LINKLIB\b'; Description = 'Delphi native library-link directive' }
  )
  $runtimeCallPatterns = @(
    [pscustomobject]@{ Pattern = '\bexternal\b'; Description = 'external DLL import declaration' },
    [pscustomobject]@{ Pattern = '\bLoadLibrary[A-Z]*\s*\('; Description = 'runtime DLL loader' },
    [pscustomobject]@{ Pattern = '\bGetProcAddress\s*\('; Description = 'runtime DLL symbol lookup' },
    [pscustomobject]@{ Pattern = '\bFreeLibrary\s*\('; Description = 'runtime DLL unload' },
    [pscustomobject]@{ Pattern = '\bCreateProcess[A-Z]*\s*\('; Description = 'runtime external process launch' },
    [pscustomobject]@{ Pattern = '\bShellExecute[A-Z]*\s*\('; Description = 'runtime shell process launch' },
    [pscustomobject]@{ Pattern = '\bWinExec\s*\('; Description = 'runtime process launch' },
    [pscustomobject]@{ Pattern = '\bExecuteProcess\s*\('; Description = 'runtime process launch' },
    [pscustomobject]@{ Pattern = '\bTProcess\b'; Description = 'runtime external process launch' },
    [pscustomobject]@{ Pattern = '\bCreateOleObject\s*\('; Description = 'runtime COM shell automation' }
  )
  $runtimeReferencePatterns = @(
    [pscustomobject]@{ Pattern = '(?<![\w.-])(?:cmd|powershell|7z|7zr|xz|lzma|tar)\.exe(?![\w.-])'; Description = 'runtime external executable reference' },
    [pscustomobject]@{ Pattern = '\b(?:WScript\.Shell|Shell\.Application)\b'; Description = 'runtime COM shell automation' }
  )
  foreach ($sourceFile in $sourceFiles) {
    $text = Get-Content -LiteralPath $sourceFile.FullName -Raw
    foreach ($directivePattern in $directivePatterns) {
      $match = [regex]::Match($text, $directivePattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($match.Success) {
        $lineNumber = Get-LineNumber $text $match.Index
        throw "forbidden runtime dependency in $(Get-RepoRelativePath $sourceFile.FullName):$lineNumber ($($directivePattern.Description))"
      }
    }

    $semanticText = Remove-DelphiCommentsAndStrings $text
    foreach ($runtimeCallPattern in $runtimeCallPatterns) {
      $match = [regex]::Match($semanticText, $runtimeCallPattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($match.Success) {
        $lineNumber = Get-LineNumber $text $match.Index
        throw "forbidden runtime dependency in $(Get-RepoRelativePath $sourceFile.FullName):$lineNumber ($($runtimeCallPattern.Description))"
      }
    }

    $referenceText = Remove-DelphiCommentsPreserveStrings $text
    foreach ($runtimeReferencePattern in $runtimeReferencePatterns) {
      $match = [regex]::Match($referenceText, $runtimeReferencePattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($match.Success) {
        $lineNumber = Get-LineNumber $text $match.Index
        throw "forbidden runtime dependency in $(Get-RepoRelativePath $sourceFile.FullName):$lineNumber ($($runtimeReferencePattern.Description))"
      }
    }
  }

  $projectSourceDir = $toolsSourceDir
  if (Test-Path -LiteralPath $projectSourceDir) {
    $projectExtensions = @('.dproj', '.dpr', '.pas')
    $projectFiles = @(Get-ChildItem -LiteralPath $projectSourceDir -Recurse -File | Where-Object {
      $projectExtensions -contains $_.Extension.ToLowerInvariant()
    })
    $projectPatterns = @(
      [pscustomobject]@{
        Pattern = '\.(?:c|cc|cpp|cxx|h|hh|hpp|hxx|obj|o|lib|a|dll|so|dylib)(?=[''"<>\s;/\\])'
        Description = 'native dependency reference in project metadata'
      },
      [pscustomobject]@{
        Pattern = '<\s*(?:ObjFiles|LibFiles|BCCReference)\b'
        Description = 'native linker project field'
      }
    )
    foreach ($projectFile in $projectFiles) {
      $text = Get-Content -LiteralPath $projectFile.FullName -Raw
      foreach ($projectPattern in $projectPatterns) {
        $match = [regex]::Match($text, $projectPattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
          $lineNumber = Get-LineNumber $text $match.Index
          throw "forbidden runtime dependency in $(Get-RepoRelativePath $projectFile.FullName):$lineNumber ($($projectPattern.Description))"
        }
      }
      $referenceText = Remove-DelphiCommentsPreserveStrings $text
      foreach ($runtimeReferencePattern in $runtimeReferencePatterns) {
        $match = [regex]::Match($referenceText, $runtimeReferencePattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
          $lineNumber = Get-LineNumber $text $match.Index
          throw "forbidden runtime dependency in $(Get-RepoRelativePath $projectFile.FullName):$lineNumber ($($runtimeReferencePattern.Description))"
        }
      }
      if ($projectFile.Extension.ToLowerInvariant() -in @('.dpr', '.pas')) {
        $semanticText = Remove-DelphiCommentsAndStrings $text
        foreach ($runtimeCallPattern in $runtimeCallPatterns) {
          $match = [regex]::Match($semanticText, $runtimeCallPattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
          if ($match.Success) {
            $lineNumber = Get-LineNumber $text $match.Index
            throw "forbidden runtime dependency in $(Get-RepoRelativePath $projectFile.FullName):$lineNumber ($($runtimeCallPattern.Description))"
          }
        }
      }
    }
  }
}

function Assert-NoPrematureFullSdkCloneDocs {
  $docFiles = @()
  $readmePath = Join-Path $root 'README.md'
  if (Test-Path -LiteralPath $readmePath) {
    $docFiles += Get-Item -LiteralPath $readmePath
  }

  $docsDir = Join-Path $root 'docs'
  if (Test-Path -LiteralPath $docsDir) {
    $docFiles += @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File)
  }

  $claimPatterns = @(
    [pscustomobject]@{
      Pattern = '\b(?:full|release-grade)\s+SDK(?:-style)?(?:\s+encoder)?\s+parity\s+(?:is\s+|has\s+been\s+)?(?:accepted|achieved|complete|completed|passed|validated|ready)\b'
      Message = 'Documentation must not claim completed SDK-clone encoder behavior before the release matrix passes'
    },
    [pscustomobject]@{
      Pattern = '\b(?:unrestricted|general-purpose|complete)\s+7z\s+support\b|\b7z\s+support\s+(?:is\s+|has\s+been\s+)?(?:unrestricted|general-purpose|complete)\b'
      Message = 'Documentation must not claim unrestricted 7z support'
    },
    [pscustomobject]@{
      Pattern = '\bXZ\s+filter[- ]chain\s+support\s+(?:is\s+|has\s+been\s+)?(?:available|enabled|complete|completed|supported)\b'
      Message = 'Documentation must not claim XZ filter-chain support'
    },
    [pscustomobject]@{
      Pattern = '\b(?:benchmark|performance)\s+(?:success|acceptance|pass(?:es|ed)?)\b[^\r\n.]{0,80}\b(?:graph|visual(?:ization)?s?)\b|\b(?:graph|visual(?:ization)?s?)\b[^\r\n.]{0,80}\b(?:benchmark|performance)\s+(?:success|acceptance|pass(?:es|ed)?)\b'
      Message = 'Documentation must not claim benchmark success from graph visuals'
    }
  )
  foreach ($docFile in $docFiles) {
    $text = Get-Content -LiteralPath $docFile.FullName -Raw
    foreach ($claimPattern in $claimPatterns) {
      $match = [regex]::Match($text, $claimPattern.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($match.Success) {
        $lineNumber = Get-LineNumber $text $match.Index
        throw "$($claimPattern.Message): $(Get-RepoRelativePath $docFile.FullName):$lineNumber"
      }
    }
  }
}

function Assert-RequiredDocPattern([string]$RelativePath, [string]$Pattern, [string]$Description) {
  $path = Join-Path $root $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required documentation file is missing: $RelativePath"
  }

  $text = Get-Content -LiteralPath $path -Raw
  if ($text -notmatch $Pattern) {
    throw "Required documentation contract is missing from ${RelativePath}: $Description"
  }
}

function Assert-BenchmarkCorpusCacheEvidence($Summary, [bool]$ReleaseRequired) {
  if ($null -eq $Summary.corpusCache -or
      [string]::IsNullOrWhiteSpace([string]$Summary.corpusCache.root)) {
    throw 'Performance summary is missing benchmark corpus cache evidence.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$Summary.metadata.benchmarkWorkRoot)) {
    throw 'Performance summary is missing benchmark work-root evidence for corpus cache validation.'
  }

  $cacheRoot = [IO.Path]::GetFullPath([string]$Summary.corpusCache.root)
  $workRoot = [IO.Path]::GetFullPath([string]$Summary.metadata.benchmarkWorkRoot)
  $workPrefix = $workRoot.TrimEnd('\') + '\'
  if (-not $cacheRoot.StartsWith($workPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Performance corpus cache root must live under the benchmark work root.'
  }
  if ([IO.Path]::GetFileName($cacheRoot.TrimEnd('\')) -ne 'lzma2-delphi-corpus-cache') {
    throw 'Performance corpus cache root must use the owned lzma2-delphi-corpus-cache directory.'
  }

  $records = @($Summary.corpusCache.records)
  if ([int]$Summary.corpusCache.recordCount -ne $records.Count -or $records.Count -lt 1) {
    throw 'Performance summary corpus cache record count is invalid.'
  }
  foreach ($record in $records) {
    if ([string]::IsNullOrWhiteSpace([string]$record.name) -or
        [string]::IsNullOrWhiteSpace([string]$record.kind) -or
        [string]$record.cacheKey -notmatch '^[0-9a-f]{64}$' -or
        [string]$record.sha256 -notmatch '^[0-9a-f]{64}$' -or
        [int64]$record.sizeBytes -lt 1 -or
        [string]::IsNullOrWhiteSpace([string]$record.cachePath) -or
        [string]::IsNullOrWhiteSpace([string]$record.workPath) -or
        @($record.PSObject.Properties.Name) -notcontains 'cacheHit') {
      throw 'Performance summary corpus cache record is missing required metadata.'
    }
    $cachePathText = ([string]$record.cachePath) -replace '\\', '/'
    if ($cachePathText -notlike 'lzma2-delphi-corpus-cache/*.bin') {
      throw 'Performance summary corpus cache record points outside the owned cache.'
    }
  }

  if ($ReleaseRequired) {
    foreach ($requiredCorpus in @(
        [pscustomobject]@{ Name = 'repeat5-256m.bin'; Size = [int64]268435456 },
        [pscustomobject]@{ Name = 'mixed-256m.bin'; Size = [int64]268435456 },
        [pscustomobject]@{ Name = 'xz-mt-mixed-256m.bin'; Size = [int64]268435456 },
        [pscustomobject]@{ Name = 'xz-mt-patterned-256m.bin'; Size = [int64]268435456 }
      )) {
      $matches = @($records | Where-Object {
        $_.name -eq $requiredCorpus.Name -and [int64]$_.sizeBytes -ge [int64]$requiredCorpus.Size
      })
      if ($matches.Count -ne 1) {
        throw "Performance summary is missing release corpus cache evidence for $($requiredCorpus.Name)."
      }
    }
  }
}

function Assert-PositiveDocumentationContracts {
  foreach ($requiredDoc in @(
    'README.md',
    'docs\api.md',
    'docs\options.md',
    'docs\compatibility.md',
    'docs\performance.md',
    'docs\memory.md',
    'docs\release-scope.md',
    'docs\release-acceptance.md'
  )) {
    $requiredDocPath = Join-Path $root $requiredDoc
    if (-not (Test-Path -LiteralPath $requiredDocPath)) {
      throw "Required documentation file is missing: $requiredDoc"
    }
  }

  Assert-RequiredDocPattern 'README.md' `
    'native\s+Delphi|pure\s+Delphi' `
    'README documents the native Delphi runtime scope'
  Assert-RequiredDocPattern 'docs\api.md' `
    'TStream|SDK\s+facade' `
    'API docs cover stream ownership and the SDK facade'
  Assert-RequiredDocPattern 'docs\options.md' `
    'MatchFinderProfile|ParserMode' `
    'options docs cover parser and match-finder controls'
  Assert-RequiredDocPattern 'docs\compatibility.md' `
    'LZMA2-only|LZMA/LZMA2' `
    'compatibility docs cover the constrained container codec scope'
  Assert-RequiredDocPattern 'docs\memory.md' `
    'MemoryLimit|memory limit' `
    'memory docs cover resource limits'

  Assert-RequiredDocPattern 'docs\release-acceptance.md' `
    'tests/run-ci\.ps1\s+-Mode\s+release\s+-PerformanceWorkRoot\s+<SSD_WORKROOT>' `
    'release SSD work-root command'
  Assert-RequiredDocPattern 'docs\release-acceptance.md' `
    '-RamWorkRoot\s+<RAM_WORKROOT>' `
    'release RAM work-root command'
  Assert-RequiredDocPattern 'docs\release-acceptance.md' `
    '`quick`\s+mode\s+does\s+not\s+run\s+`tests/run-performance\.ps1`' `
    'quick does not run the performance matrix'
  Assert-RequiredDocPattern 'docs\release-acceptance.md' `
    '7zr\.exe' `
    'runtime executable audit includes 7zr.exe'
  Assert-RequiredDocPattern 'docs\release-acceptance.md' `
    'data-only benchmark' `
    'release performance evidence is data-only'
  Assert-RequiredDocPattern 'docs\release-acceptance.md' `
    'lzma2-delphi-graph\.\*' `
    'release graph artifacts are absent'

  Assert-RequiredDocPattern 'docs\release-scope.md' `
    'does\s+not\s+run\s+`tests/run-performance\.ps1`' `
    'quick mode skips the performance script'
  Assert-RequiredDocPattern 'docs\release-scope.md' `
    'absence\s+of\s+`lzma2-delphi-graph\.\*`' `
    'release scope documents forbidden graph artifacts'

  Assert-RequiredDocPattern 'docs\performance.md' `
    '`quick`\s+does\s+not\s+run\s+`tests/run-performance\.ps1`' `
    'quick mode skips the performance script'
  Assert-RequiredDocPattern 'docs\performance.md' `
    'Release\s+and\s+soak\s+modes\s+run\s+`tests/run-performance\.ps1`' `
    'release and soak own the performance matrix'
}

Assert-NativeRuntimeSource
Assert-ReferencedSourceFilesTracked
Assert-NoPrematureFullSdkCloneDocs
Assert-PositiveDocumentationContracts

$junitPath = Require-File 'artifacts\test-results\Lzma.Tests.junit.xml'
$dunitxConsolePath = Require-File 'artifacts\test-results\Lzma.Tests.console.txt'
$compatCandidatePath = Join-Path $root 'artifacts\compat\xz-cross-tool-report.json'
if ($RequireExternalTools) {
  $compatPath = Require-File 'artifacts\compat\xz-cross-tool-report.json'
} elseif (Test-Path -LiteralPath $compatCandidatePath) {
  $compatPath = $compatCandidatePath
} else {
  $compatPath = ''
}
$fixtureManifestPath = Require-File 'artifacts\fixtures\sha256-fixtures.json'
$matchFinderTracePath = Require-File 'artifacts\match-finder\sdk-trace-parity.json'
$memoryPath = Require-File 'artifacts\memory\fastmm-report.txt'
$compilerWarningsPath = Require-File 'artifacts\ci\compiler-warnings.json'
$ciManifestPath = Require-File 'artifacts\ci\ci-artifacts-manifest.json'
$ciManifest = Get-Content -LiteralPath $ciManifestPath -Raw | ConvertFrom-Json
$manifestArtifactPaths = @($ciManifest.artifacts | ForEach-Object {
  ([string]$_.path) -replace '\\', '/'
})
$requiredPerformanceArtifactPaths = @(
  'artifacts/perf/lzma2-benchmark.csv',
  'artifacts/perf/lzma2-benchmark.json',
  'artifacts/perf/lzma2-benchmark.samples.csv',
  'artifacts/perf/lzma2-benchmark.summary.json'
)
$performanceManifestArtifactsPresent = @($manifestArtifactPaths | Where-Object {
  $requiredPerformanceArtifactPaths -contains $_
}).Count -gt 0
$existingPerformanceArtifactPaths = @($requiredPerformanceArtifactPaths | Where-Object {
  Test-Path -LiteralPath (Join-Path $root ($_ -replace '/', '\'))
})
$performanceFilesPresent = $existingPerformanceArtifactPaths.Count -gt 0
$manifestReleasePerformance = $false
if ($null -ne $ciManifest.configuration) {
  $manifestReleasePerformance = [bool]$ciManifest.configuration.releasePerformance
}
$ShouldValidatePerformanceArtifacts = [bool]$RequireReleaseCorpus -or
  $manifestReleasePerformance -or
  $performanceManifestArtifactsPresent -or
  $performanceFilesPresent
if ($ShouldValidatePerformanceArtifacts) {
  $perfJsonPath = Require-File 'artifacts\perf\lzma2-benchmark.json'
  $perfCsvPath = Require-File 'artifacts\perf\lzma2-benchmark.csv'
  $perfSamplesPath = Require-File 'artifacts\perf\lzma2-benchmark.samples.csv'
  $perfSummaryPath = Require-File 'artifacts\perf\lzma2-benchmark.summary.json'
  $perfOptimizationPath = Require-File 'artifacts\ci\optimization-plan.md'
} else {
  $perfJsonPath = ''
  $perfCsvPath = ''
  $perfSamplesPath = ''
  $perfSummaryPath = ''
  $perfOptimizationPath = ''
}

[xml]$junit = Get-Content -LiteralPath $junitPath -Raw
$suite = $junit.testsuites
if ([int]$suite.tests -le 0) {
  throw 'JUnit report has no tests.'
}
if ([int]$suite.tests -lt 52) {
  throw "JUnit report has fewer tests than the current TZ smoke floor: $($suite.tests)."
}
if ([int]$suite.failures -ne 0 -or [int]$suite.errors -ne 0) {
  throw "JUnit report has failures=$($suite.failures), errors=$($suite.errors)."
}
$testCaseNames = @($junit.testsuites.testsuite.testcase | ForEach-Object { $_.name })
foreach ($requiredTestCase in
  'XzDecodeAvoidsFullArchiveMemoryLimit',
  'XzEncodeAvoidsFullSourceMemoryLimit',
  'XzDecodeRejectsDictionaryOverMemoryLimit',
  'XzDecodeRejectsMaxDictionaryPropertyOverMemoryLimit',
  'DictionaryPropertyRejectsAboveMaxStrict',
  'MultiThreadedRawMemoryLimit',
  'HashChain4MatchFinderReadMatchesInsertsCurrentPosition',
  'HashChain5MatchFinderUsesFiveByteMainHash',
  'HashChain5MatchFinderUsesSdkCrcHashShape',
  'HashChain5MatchFinderSkipsTailBelowFiveBytesLikeSdk',
  'HashChain5MatchFinderHonorsDictionaryLimit',
  'HashChain4MatchFinderUsesDictionaryCyclicChainStorage',
  'HashChain5MatchFinderUsesDictionaryCyclicChainStorage',
  'HashChain4SkipRangeMonotonicMatchesClassicInsertRange',
  'HashChain4SkipRangeMonotonicMarksSkippedPositionsInserted',
  'HashChain5SkipRangeMonotonicMatchesClassicInsertRange',
  'HashChain5SkipRangeMonotonicMarksSkippedPositionsInserted',
  'BinaryTree4SkipRangeMonotonicMatchesClassicInsertRange',
  'Lzma2CompressedOptionsUseSdkTwoMiBChunkLimit',
  'BinaryTree4MatchFinderReadMatchesInsertsCurrentPosition',
  'BinaryTree4MatchFinderUsesDictionaryCyclicSonStorage',
  'MatchFindersIgnoreOutOfRangePositions',
  'MatchFinderReadMatchesIsIdempotent',
  'HashChain4MatchesSdkReferenceTrace',
  'HashChain5MatchesSdkReferenceTrace',
  'BinaryTree4MatchesSdkReferenceTrace',
  'MatchFinderSdkReferenceTraceArtifactIsWritten',
  'FastParserLookaheadCacheReusesReadMatchesOnce',
  'RawLzmaStreamEncoderUsesSinkBackedRangeOutput',
  'RawLzmaStreamEncoderUsesProfileMatchFinder',
  'RawLzmaStreamProgressReportsCommittedOutput',
  'RawLzmaStreamFinalCancellationPrecedesRangeFlush',
  'SdkFacadeLzmaEncoderStreamsEndMarkerPath',
  'RawLzmaEndMarkerRoundTripsUnknownSize',
  'RawLzmaEndMarkerRejectsDirtyTail',
  'RawLzmaEndMarkerInsideLzma2ChunkFails',
  'RawLzmaInvalidPropsFails',
  'RawLzma2DecodeReadFailureRaisesTypedReadError',
  'RawLzma2EncodeReadFailureRaisesTypedReadError',
  'SdkFacadeLzma2EncoderDoesNotSnapshotFullInput',
  'SdkFacadeLzma2DecoderDoesNotSnapshotFullInput',
  'SdkFacadeLzma2EncoderSupportsPartialSeqOutWrites',
  'SdkFacadeLzma2EncoderPropagatesSeqOutSRes',
  'RawLzma2TruncatedCopyChunkFails',
  'RawLzma2InvalidControlFails',
  'RawLzma2CompressedChunkWithoutPropsFails',
  'RawLzma2InvalidLcLpPropsFails',
  'RawLzma2CorruptRangeFlushTailFails',
  'RawLzma2CorruptExactRangeTailFails',
  'SevenZipSingleFileRoundTrips',
  'SevenZipLzmaCoderSingleFileDecodes',
  'SevenZipEncodedHeaderLzma2SingleFileDecodes',
  'SevenZipEncodedHeaderLzmaSingleFileDecodes',
  'SevenZipEncodedHeaderUnsupportedCoderFailsClosed',
  'SevenZipMultiFolderLzma2ArchiveExtractsAllEntries',
  'SevenZipMultiFolderLzmaArchiveExtractsAllEntries',
  'SevenZipMultiFileLzma2EncodeListsAndExtractsAllEntries',
  'SevenZipMultiFileLzmaEncodeListsAndExtractsAllEntries',
  'SevenZipMultiFileFailsSingleStreamDecode',
  'SevenZipSolidLzma2SubstreamsExtractAsSeparateFiles',
  'SevenZipSolidLzmaSubstreamsExtractAsSeparateFiles',
  'SevenZipDecodeLeavesSourceAfterArchive',
  'SevenZipHeaderCrcCorruptionFails',
  'XzPackedBlockRejectsRawTrailingBytes',
  'XzBadStreamPaddingFails',
  'CorruptedSecondXzBlockCheckFails',
  'CorruptedXzCheckFails',
  'XzTruncatedFooterFails',
  'Crc32XzKnownVectorAndSplitUpdate',
  'Crc64XzKnownVectorAndSplitUpdate',
  'HashChain4AndBinaryTree4ExposeLowHashMatchThroughFourByteCollision',
  'HashChain4AndBinaryTree4SkipTailBelowFourBytesLikeSdk',
  'MtDecodeStreamsReadyUnitsBeforeSlowWorkersFinish',
  'MtDecodeWriteFailureSignalsWorkersToCancel',
  'RawLzma2MtDecodeUsesIndependentResetChunks',
  'RawLzma2MtDecodeFallsBackForSingleIndependentStream',
  'RawLzma2MtDecodeFallsBackForTinyPackedIndependentUnits',
  'RawLzma2MtDecodeFallsBackForHighlyExpandedTinyPackedUnits',
  'RawLzma2MtDecodeCancellationDoesNotWriteOutput',
  'RawLzma2MtDecodeFallsBackWhenOutputExceedsMemoryLimit',
  'RawLzma2MtDecodeChecksMemoryLimitBeforePayloadSnapshot',
  'RawLzma2MtDecodeWriteFailurePropagates',
  'XzDeltaFilterFailsUnsupported',
  'XzBcjFilterFailsUnsupported',
  'XzFilterChainFailsUnsupported',
  'DecompressAsyncReturnsBeforeProgressCallbackCompletes',
  'XzMtDecodeUsesIndependentBlocks',
  'XzMtDecodeDoesNotReadAllPayloadsBeforeFirstOutput',
  'XzMtDecodeWriteFailurePropagatesAndPreservesDiagnostics',
  'XzMtDecodeUsesIndexPackedSizeWhenHeaderOmitsIt',
  'XzMtDecodeUsesIndexUnpackedSizeWhenHeaderOmitsIt',
  'XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutPackedSize',
  'XzMtDecodeFallsBackForSingleIndexSizedBlockWithoutUnpackedSize',
  'XzMtDecodeFallsBackWhenOutputExceedsMemoryLimit',
  'XzMtDecodeChecksMemoryLimitBeforePayloadSnapshot',
  'XzMtDecodeUsesNonzeroMemoryLimit',
  'XzMultiBlockEncodeDiagnosticsAggregatesRawFastPathCounts',
  'XzMultiBlockEncodeDiagnosticsReportsTuningForEmptyInput',
  'MixedBenchmarkCorpusRawEncodeCompressesRepeatingStripes',
  'MixedBenchmarkCorpusRawMtEncodeCompressesRepeatingStripes',
  'IncompressibleProbeDoesNotCopyCompressibleTail',
  'PeriodicRawEncodeUsesFastPath',
  'PeriodicFastPathRejectsChunkedPhaseReset',
  'PeriodicPhaseResetRawEncodeUsesSubchunkFastPath',
  'FastLzma2StyleBenchmarkContractIsDocumented',
  'PerformanceRunnerWritesDataOnlyBenchmarkArtifacts',
  'PerformanceValidatorEnforcesDataOnlyArtifacts',
  'PerformanceSummaryRequiresBenchmarkMetadata',
  'RawLzmaSdkReleaseCorpusFixturesDecode',
  'RawLzmaEncoderOptInWindowPathRoundTripsAndWiresDriver',
  'OptimumReplayRejectsUnreachableEndNode',
  'OptimumReplayRejectsUnreachableIntermediateNode',
  'OptimumReplayRejectsUnreachablePrev1LiteralNode',
  'OptimumReplayPathReturnsMatchLiteralRep0Commands',
  'OptimumReplayRejectsPrev1LiteralRootNonLiteralBackPrev2',
  'OptimumReplayRejectsPrev1LiteralRootMultiByteLiteralCommand',
  'OptimumReplayRejectsPathLenMismatchedPosPrev',
  'OptimumReplayRejectsPathLenMismatchedBackPrev',
  'OptimumReplayRejectsExtraPathNonRep0BackPrev',
  'OptimumReplayRejectsExtraPathWithPrev1LiteralFlag',
  'OptimumReplayRejectsPathLenExtraRep0WithBackPrev2Set',
  'OptimumReplayRejectsPathLenExtraRep0WithPosPrev2Set',
  'OptimumReplayRejectsPathLenExtraOneWithNonLiteralBack',
  'OptimumReplayRejectsPathLenExtraOneWithBackPrev2Set',
  'OptimumReplayRejectsPathLenExtraOneWithPosPrev2Set',
  'OptimumReplayRejectsMultiByteLiteralRootCommand',
  'OptimumReplayRejectsSingleByteMatchRootCommand',
  'OptimumReplayRejectsIntermediateMultiByteLiteralCommand',
  'OptimumReplayRejectsPathLenMultiByteLiteralCommand',
  'OptimumReplayRejectsPathLenSingleByteMatchCommand',
  'OptimumReplayRejectsUnreachableStartNode',
  'OptimumSeedCandidatesIncludePreparedStartPrice',
  'OptimumPrepareNodesSeedsStartStateAndReps',
  'OptimumSeedCandidatesRejectOverflowingStartPrice',
  'OptimumSeedMatchCandidatesRejectOverflowingBackDistance',
  'OptimumSeedMatchCandidatesRejectZeroBackDistance',
  'OptimumShortRepVsLiteralRejectsOverflowingShortRepPrice',
  'OptimumRepVsMatchRejectsOverflowingRepPrice',
  'OptimumRepVsMatchRejectsOverflowingMatchBackDistance',
  'OptimumRepVsMatchRejectsOneByteNormalMatchLength',
  'OptimumRepVsMatchRejectsOneByteRepLength',
  'OptimumRepVsMatchRejectsZeroMatchDistance',
  'OptimumLiteralThenMatchRejectsOverflowingLookaheadPrice',
  'OptimumLiteralThenMatchRejectsOverflowingCurrentMatchBackDistance',
  'OptimumLiteralThenMatchRejectsOverflowingNextMatchBackDistance',
  'OptimumLiteralThenMatchRejectsOneByteNextMatchLength',
  'OptimumLiteralThenMatchRejectsOneByteCurrentMatchLength',
  'OptimumLiteralThenMatchRejectsZeroNextMatchDistance',
  'OptimumLiteralThenMatchRejectsZeroCurrentMatchDistance',
  'OptimumLiteralThenRepRejectsOverflowingLookaheadPrice',
  'OptimumLiteralThenRepRejectsOverflowingCurrentMatchBackDistance',
  'OptimumLiteralThenRepRejectsOneByteNextRepLength',
  'OptimumLiteralThenRepRejectsOneByteCurrentMatchLength',
  'OptimumLiteralThenRepRejectsZeroCurrentMatchDistance',
  'OptimumMatchLiteralRep0RejectsOverflowingLookaheadPrice',
  'OptimumMatchLiteralRep0RejectsOverflowingFirstMatchDecisionBackDistance',
  'OptimumMatchLiteralRep0RejectsOverflowingCurrentMatchDecisionBackDistance',
  'OptimumMatchLiteralRep0RejectsOneByteFirstMatchLength',
  'OptimumMatchLiteralRep0RejectsOneByteRepLength',
  'OptimumMatchLiteralRep0RejectsOneByteCurrentMatchLength',
  'OptimumMatchLiteralRep0RejectsZeroFirstMatchDistance',
  'OptimumMatchLiteralRep0RejectsZeroCurrentMatchDistance',
  'OptimumLiteralCandidateRejectsOverflowingPreviousPrice',
  'OptimumShortRepCandidateRejectsOverflowingPreviousPrice',
  'OptimumRepCandidatesRejectOverflowingPreviousPrice',
  'OptimumMatchCandidatesRejectOverflowingPreviousPrice',
  'OptimumRelaxMatchCandidatesRejectOverflowingBackDistance',
  'OptimumRelaxMatchCandidatesRejectZeroBackDistance',
  'OptimumRelaxCandidatesCarryStateAndRepsAcrossParserNodes',
  'OptimumWindowReplaysCheaperTwoStepPathOverDirectMatch',
  'OptimumWindowRelaxesLiteralThenMatchPath',
  'OptimumWindowUsesReachedNodeStateForLaterProbabilityInputs',
  'OptimumWindowResolvesRepLensFromReachedNodeReps',
  'OptimumWindowResolvesLiteralFromReachedNodeContext',
  'OptimumWindowRelaxesShortRepFromResolvedRepLens',
  'OptimumWindowRelaxesMatchLiteralRep0ExtraPath',
  'OptimumMatchLiteralRep0CandidateRejectsOverflowingPreviousPrice',
  'OptimumMatchLiteralRep0CandidateRejectsOverflowingFirstMatchBackDistance',
  'OptimumMatchLiteralRep0CandidateRejectsZeroFirstMatchDistance',
  'LzmaStandaloneRoundTripsKnownSize',
  'LzmaStandaloneEncodeCanWriteUnknownSizeEndMarker',
  'LzmaStandaloneDecodesUnknownSizeEndMarker',
  'LzmaStandaloneEncodeRejectsInputOverMemoryLimit',
  'LzmaStandaloneDecodeRejectsPackedInputOverMemoryLimit',
  'LzmaStandaloneRejectsShortHeader',
  'LzmaStandaloneRejectsInvalidProps',
  'LzmaStandaloneRejectsTrailingBytesAfterEndMarker',
  'LzmaStandaloneRejectsKnownSizeTruncation',
  'LzmaStandaloneRejectsUnpackSizeMismatch',
  'LzmaStandaloneRejectsUnknownSizeWithoutEndMarker',
  'LzmaStandaloneEncodeCancellation',
  'LzmaStandaloneDecodeCancellation',
  'SdkFacadePropsNormalizeSdkDependencyVectors',
  'SdkFacadeProgressPreservesCallbackSRes',
  'SdkFacadeLzmaDecoderLifecycleDecodeToBuf',
  'SdkFacadeLzmaDecoderLifecycleTruncatedInputNeedsMoreInput',
  'SdkFacadeLzma2DecoderLifecycleRejectsInvalidProperty',
  'SdkFacadeLzma2DecoderLifecycleDecodeToBufAndDic',
  'GitHubWorkflowRunsReleaseCiMode',
  'CliSafeStoredOutputNameRejectsUnsafeStoredNames',
  'ReleasePerformanceRequiresSixteenThreadMtEncodeEvidence',
  'EncoderPathSeedsOptimumNodesWithCurrentStateAndReps',
  'CorruptXzRegressionFixturesFailWithExpectedErrors') {
  if ($testCaseNames -notcontains $requiredTestCase) {
    throw "JUnit report is missing required test case: $requiredTestCase"
  }
}

$matchFinderTrace = Get-Content -LiteralPath $matchFinderTracePath -Raw | ConvertFrom-Json
if ([int]$matchFinderTrace.schemaVersion -ne 1) {
  throw 'Match-finder SDK trace parity artifact has an unsupported schemaVersion.'
}
if ([string]$matchFinderTrace.sdk -notmatch 'LZMA SDK 26\.01') {
  throw 'Match-finder SDK trace parity artifact is missing the SDK 26.01 source label.'
}
$matchFinderTraceRows = @($matchFinderTrace.traces)
$requiredMatchFinderTraceIds = @(
  'hc4-basic-two-heads',
  'hc4-boundary-tail',
  'hc4-skip-range',
  'hc4-dictionary-limit',
  'hc4-four-byte-collision',
  'hc5-basic-two-heads',
  'hc5-boundary-tail',
  'hc5-skip-range',
  'hc5-dictionary-limit',
  'hc5-crc-hash-collision',
  'bt4-basic-two-heads',
  'bt4-boundary-tail',
  'bt4-skip-range',
  'bt4-dictionary-limit',
  'bt4-four-byte-collision'
)
foreach ($requiredTraceId in $requiredMatchFinderTraceIds) {
  $rows = @($matchFinderTraceRows | Where-Object { [string]$_.id -eq $requiredTraceId })
  if ($rows.Count -ne 1) {
    throw "Match-finder SDK trace parity artifact is missing trace: $requiredTraceId"
  }
  $row = $rows[0]
  if ([string]$row.status -ne 'passed') {
    throw "Match-finder SDK trace parity artifact reports non-passing trace: $requiredTraceId"
  }
  $expected = @($row.expected)
  $actual = @($row.actual)
  if ($expected.Count -ne $actual.Count) {
    throw "Match-finder SDK trace parity artifact has invalid pair counts for trace: $requiredTraceId"
  }
  for ($i = 0; $i -lt $expected.Count; $i++) {
    if ([int]$expected[$i].length -ne [int]$actual[$i].length -or
        [int]$expected[$i].distance -ne [int]$actual[$i].distance) {
      throw "Match-finder SDK trace parity artifact mismatch for trace: $requiredTraceId"
    }
  }
}

if ($RequireExternalTools -and ($testCaseNames -notcontains 'CrossToolDelphiRawLzmaEndMarkerDecodesWithSdk')) {
  throw 'JUnit report is missing required SDK raw LZMA end-marker interop test case.'
}
if ($RequireExternalTools -and ($testCaseNames -notcontains 'CrossToolDelphiSevenZipIsAcceptedBySevenZip')) {
  throw 'JUnit report is missing required Delphi 7z archive interop test case.'
}
if ($RequireExternalTools -and ($testCaseNames -notcontains 'CrossToolSevenZip7zDecodes')) {
  throw 'JUnit report is missing required 7-Zip single-file 7z decode interop test case.'
}
if ($RequireExternalTools) {
  $consoleText = Get-Content -LiteralPath $dunitxConsolePath -Raw
  $skippedExternalLines = @($consoleText -split "`r?`n" | Where-Object {
    $_ -match '^SKIP .*\bLZMA_TEST_(7Z|XZ|LZMA)\b'
  })
  if ($skippedExternalLines.Count -gt 0) {
    throw "required external tool test was skipped: $($skippedExternalLines[0])"
  }
}

if ($compatPath) {
  $compat = Get-Content -LiteralPath $compatPath -Raw | ConvertFrom-Json
  $compatWorkRootIsRamBacked = $false
  if ($null -ne $ciManifest.configuration) {
    $configuredBenchmarkRoot = Get-ReleaseBenchmarkWorkRoot $ciManifest.configuration
    if ([bool]$configuredBenchmarkRoot.RamBacked -and
        -not [string]::IsNullOrWhiteSpace([string]$configuredBenchmarkRoot.Path)) {
      $configuredRamRoot = [IO.Path]::GetFullPath([string]$configuredBenchmarkRoot.Path).TrimEnd('\') + '\'
      $compatRootFull = [IO.Path]::GetFullPath([string]$compat.workRoot).TrimEnd('\') + '\'
      $compatWorkRootIsRamBacked = $compatRootFull.StartsWith($configuredRamRoot, [StringComparison]::OrdinalIgnoreCase)
    }
  }
  Assert-CiBenchmarkWorkRoot ([string]$compat.workRoot) $compatWorkRootIsRamBacked
  if ([string]::IsNullOrWhiteSpace([string]$compat.workDir)) {
    throw 'Compatibility report is missing cross-tool workDir evidence.'
  }
  $compatWorkRoot = [IO.Path]::GetFullPath([string]$compat.workRoot).TrimEnd('\')
  $compatWorkDir = [IO.Path]::GetFullPath([string]$compat.workDir)
  if (-not $compatWorkDir.StartsWith($compatWorkRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Compatibility report workDir escapes the configured workRoot.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$compat.workDirSentinel) -or
      [IO.Path]::GetFileName([string]$compat.workDirSentinel) -ne '.lzma2-delphi-cross-tool-workdir') {
    throw 'Compatibility report is missing cross-tool sentinel evidence.'
  }
  function Require-CompatCase([string]$Encoder, [string]$Name, [int]$Level, [string]$Check) {
    $matches = @($compat.cases | Where-Object {
      $_.encoder -eq $Encoder -and
      $_.name -eq $Name -and
      $_.status -eq 'passed' -and
      [int]$_.level -eq $Level -and
      ([string]$_.check) -eq $Check
    })
    if ($matches.Count -ne 1) {
      throw "Compatibility report is missing exact case: encoder=$Encoder name=$Name level=$Level check=$Check"
    }
  }

  if ($RequireExternalTools -and (-not $compat.tools.sevenZip.available)) {
    throw 'Compatibility report is missing a working 7-Zip tool record.'
  }
  Assert-PinnedQAToolEvidence $compat.tools.sevenZip 'sevenZip' ([bool]$RequireExternalTools) 'Compatibility report'
  if ($compat.tools.sevenZip -and $compat.tools.sevenZip.available -and $compat.tools.sevenZip.version -notmatch '7-Zip') {
    throw 'Compatibility report has an unexpected 7-Zip version record.'
  }
  if ($compat.tools.sevenZip -and $compat.tools.sevenZip.available -and
      $compat.tools.sevenZip.version -notmatch $expectedLzmaSdkVersionPattern) {
    throw 'Compatibility report must use 7-Zip/LZMA SDK 26.01.'
  }
  if ($RequireExternalTools -and (-not $compat.tools.xz -or -not $compat.tools.xz.available)) {
    throw 'Compatibility report is missing a working xz-utils tool record.'
  }
  Assert-PinnedQAToolEvidence $compat.tools.xz 'xz' ([bool]$RequireExternalTools) 'Compatibility report'
  if ($compat.tools.xz -and $compat.tools.xz.available -and $compat.tools.xz.version -notmatch 'XZ Utils|xz') {
    throw 'Compatibility report has an unexpected xz-utils version record.'
  }
  if ($RequireExternalTools -and (-not $compat.tools.lzma -or -not $compat.tools.lzma.available)) {
    throw 'Compatibility report is missing a working LZMA SDK lzma.exe tool record.'
  }
  Assert-PinnedQAToolEvidence $compat.tools.lzma 'lzma' ([bool]$RequireExternalTools) 'Compatibility report'
  if ($compat.tools.lzma -and $compat.tools.lzma.available -and $compat.tools.lzma.version -notmatch 'LZMA') {
    throw 'Compatibility report has an unexpected LZMA SDK lzma.exe version record.'
  }
  if ($compat.tools.lzma -and $compat.tools.lzma.available -and
      $compat.tools.lzma.version -notmatch $expectedLzmaSdkVersionPattern) {
    throw 'Compatibility report must use LZMA SDK 26.01 lzma.exe.'
  }
  if ($RequireExternalTools -and ($compat.cases.status -contains 'skipped')) {
    throw 'Compatibility report contains skipped cases in required external tool mode.'
  }
  $delphiMatrixCases = @($compat.cases | Where-Object { $_.encoder -eq 'Delphi' -and $_.name -like 'delphi-l*-*' -and $_.status -eq 'passed' })
  if ($RequireExternalTools -and $delphiMatrixCases.Count -lt 24) {
    throw 'Compatibility report does not include the required Delphi encoder level/check matrix.'
  }
  $sevenZipMatrixCases = @($compat.cases | Where-Object { $_.encoder -eq '7-Zip' -and $_.name -like '7zip-mx*' -and $_.status -eq 'passed' })
  if ($RequireExternalTools -and $sevenZipMatrixCases.Count -lt 6) {
    throw 'Compatibility report does not include the required 7-Zip encoder level matrix.'
  }
  $xzMatrixCases = @($compat.cases | Where-Object { $_.encoder -eq 'xz-utils' -and $_.status -eq 'passed' })
  if ($RequireExternalTools -and $xzMatrixCases.Count -lt 24) {
    throw 'Compatibility report does not include the required xz-utils decoder matrix.'
  }
  $standaloneLzmaCases = @($compat.cases | Where-Object {
    $_.container -eq 'lzma' -and
    $_.status -eq 'passed' -and
    $_.sourceSha256 -and
    $_.decodedSha256 -and
    $_.sourceSha256 -eq $_.decodedSha256
  })
  if ($RequireExternalTools -and $standaloneLzmaCases.Count -lt 2) {
    throw 'Compatibility report does not include the required standalone .lzma SHA-256 interop rows.'
  }
  $cliCancellationCases = @($compat.cases | Where-Object {
    $_.name -eq 'cli-cancel-cleans-partial-output' -and
    $_.encoder -eq 'Delphi' -and
    $_.verifier -eq 'Delphi' -and
    $_.status -eq 'passed'
  })
  if ($RequireExternalTools -and $cliCancellationCases.Count -ne 1) {
    throw 'Compatibility report is missing required CLI cancellation cleanup smoke case.'
  }
  if ($RequireExternalTools) {
    foreach ($requiredPathMode in 'spod', 'spoc', 'spor') {
      $pathModeCases = @($compat.cases | Where-Object {
        $_.name -eq "cli-output-path-mode-$requiredPathMode" -and
        $_.encoder -eq 'Delphi' -and
        $_.verifier -eq 'Delphi' -and
        $_.container -eq '7z' -and
        $_.status -eq 'passed'
      })
      if ($pathModeCases.Count -ne 1) {
        throw "Compatibility report is missing required CLI output path mode smoke case: $requiredPathMode"
      }
    }
  }
  if ($RequireExternalTools) {
    $multiEntryCases = @($compat.cases | Where-Object {
      $_.name -eq 'cli-7z-multi-entry-extract' -and
      $_.encoder -eq '7-Zip' -and
      $_.verifier -eq 'Delphi' -and
      $_.container -eq '7z' -and
      $_.status -eq 'passed'
    })
    if ($multiEntryCases.Count -ne 1) {
      throw 'Compatibility report is missing required CLI multi-entry 7z extract smoke case.'
    }
    foreach ($requiredSevenZipEncode in @(
        @{ name = 'cli-7z-multi-file-lzma2-encode'; method = 'LZMA2' },
        @{ name = 'cli-7z-multi-file-lzma-encode'; method = 'LZMA' })) {
      $multiFileEncodeCases = @($compat.cases | Where-Object {
        $_.name -eq $requiredSevenZipEncode.name -and
        $_.encoder -eq 'Delphi' -and
        $_.verifier -eq '7z+Delphi' -and
        $_.container -eq '7z' -and
        $_.method -eq $requiredSevenZipEncode.method -and
        $_.status -eq 'passed' -and
        [int]$_.entryCount -ge 3
      })
      if ($multiFileEncodeCases.Count -ne 1) {
        throw "Compatibility report is missing required Delphi multi-file 7z encode smoke case: $($requiredSevenZipEncode.name)"
      }
    }
    foreach ($requiredSevenZipSolid in @(
        @{ name = 'cli-7z-solid-lzma2-extract'; method = 'LZMA2' },
        @{ name = 'cli-7z-solid-lzma-extract'; method = 'LZMA' })) {
      $solidCases = @($compat.cases | Where-Object {
        $_.name -eq $requiredSevenZipSolid.name -and
        $_.encoder -eq '7-Zip' -and
        $_.verifier -eq 'Delphi' -and
        $_.container -eq '7z' -and
        $_.method -eq $requiredSevenZipSolid.method -and
        $_.status -eq 'passed' -and
        [int]$_.entryCount -ge 2
      })
      if ($solidCases.Count -ne 1) {
        throw "Compatibility report is missing required 7-Zip solid 7z extract smoke case: $($requiredSevenZipSolid.name)"
      }
    }
  }
  if ($RequireExternalTools) {
    foreach ($requiredLzmaCase in 'delphi-standalone-lzma-sdk-decode', 'sdk-standalone-lzma-delphi-decode') {
      $matches = @($standaloneLzmaCases | Where-Object { $_.name -eq $requiredLzmaCase })
      if ($matches.Count -ne 1) {
        throw "Compatibility report is missing required standalone .lzma interop case: $requiredLzmaCase"
      }
    }
  }
  if ($RequireExternalTools) {
    foreach ($level in 0, 1, 3, 5, 7, 9) {
      foreach ($check in 'none', 'crc32', 'crc64', 'sha256') {
        Require-CompatCase 'Delphi' "delphi-l$level-$check" $level $check
        Require-CompatCase 'xz-utils' "xz-utils-$level-$check" $level $check
      }
      Require-CompatCase '7-Zip' "7zip-mx$level-crc32" $level 'crc32'
    }
  }
}

$fixtureManifest = Get-Content -LiteralPath $fixtureManifestPath -Raw | ConvertFrom-Json
if (($fixtureManifest.fixtures | Measure-Object).Count -lt 4) {
  throw 'Fixture SHA-256 manifest does not include enough generated fixtures.'
}
$rawLzmaCorpusFixtures = @($fixtureManifest.fixtures | Where-Object { $_.path -like 'tests/fixtures/raw/raw-lzma-sdk-corpus-*.lzma' })
if ($RequireExternalTools -and $rawLzmaCorpusFixtures.Count -lt 9) {
  throw 'Fixture SHA-256 manifest does not include the required SDK raw LZMA corpus fixtures.'
}
$rawLzmaCorpusManifests = @($fixtureManifest.manifests | Where-Object { $_.path -eq 'tests/fixtures/manifests/raw-lzma-sdk-corpus.json' })
if ($RequireExternalTools -and $rawLzmaCorpusManifests.Count -ne 1) {
  throw 'Fixture SHA-256 manifest is missing the SDK raw LZMA corpus manifest.'
}
$rawLzmaReleaseCorpusFixtures = @($fixtureManifest.fixtures | Where-Object { $_.path -like 'tests/fixtures/raw/raw-lzma-sdk-release-corpus-*.lzma' })
if ($RequireReleaseCorpus -and $rawLzmaReleaseCorpusFixtures.Count -lt 5) {
  throw 'Fixture SHA-256 manifest does not include the required SDK raw LZMA release corpus fixtures.'
}
$rawLzmaReleaseCorpusManifests = @($fixtureManifest.manifests | Where-Object { $_.path -eq 'tests/fixtures/manifests/raw-lzma-sdk-release-corpus.json' })
if ($RequireReleaseCorpus -and $rawLzmaReleaseCorpusManifests.Count -ne 1) {
  throw 'Fixture SHA-256 manifest is missing the SDK raw LZMA release corpus manifest.'
}
$corruptXzManifests = @($fixtureManifest.manifests | Where-Object { $_.path -eq 'tests/fixtures/manifests/corrupt-xz-regressions.json' })
if ($corruptXzManifests.Count -ne 1) {
  throw 'Fixture SHA-256 manifest does not include corrupt XZ regression manifest.'
}
$rawLzmaCorpusManifestPath = Join-Path $root 'tests\fixtures\manifests\raw-lzma-sdk-corpus.json'
if ($RequireExternalTools) {
  if (-not (Test-Path -LiteralPath $rawLzmaCorpusManifestPath)) {
    throw 'SDK raw LZMA corpus manifest file is missing.'
  }
  $rawLzmaCorpusManifest = Get-Content -LiteralPath $rawLzmaCorpusManifestPath -Raw | ConvertFrom-Json
  $rawLzmaCorpusCases = @($rawLzmaCorpusManifest.cases)
  if ($rawLzmaCorpusCases.Count -lt 9) {
    throw 'SDK raw LZMA corpus manifest does not include enough cases.'
  }
  foreach ($nameFragment in 'random', 'zero', 'ff', 'text', 'exe', 'mixed', 'small-batch') {
    $matchingCases = @($rawLzmaCorpusCases | Where-Object { $_.name -like "*$nameFragment*" })
    if ($matchingCases.Count -eq 0) {
      throw "SDK raw LZMA corpus manifest is missing a $nameFragment case."
    }
  }
  foreach ($switch in '-a0', '-a1', '-d16', '-d20', '-d22', '-fb16', '-fb32', '-fb64') {
    $matchingCases = @($rawLzmaCorpusCases | Where-Object { $_.commandLine -like "*$switch*" })
    if ($matchingCases.Count -eq 0) {
      throw "SDK raw LZMA corpus manifest is missing switch coverage for $switch."
    }
  }
  Require-RawLzmaFixtureCacheEvidence $rawLzmaCorpusCases 'SDK raw LZMA corpus'
}
$rawLzmaReleaseCorpusManifestPath = Join-Path $root 'tests\fixtures\manifests\raw-lzma-sdk-release-corpus.json'
if ($RequireReleaseCorpus) {
  if (-not (Test-Path -LiteralPath $rawLzmaReleaseCorpusManifestPath)) {
    throw 'SDK raw LZMA release corpus manifest file is missing.'
  }
  $rawLzmaReleaseCorpusManifest = Get-Content -LiteralPath $rawLzmaReleaseCorpusManifestPath -Raw | ConvertFrom-Json
  $rawLzmaReleaseCorpusCases = @($rawLzmaReleaseCorpusManifest.cases)
  if ($rawLzmaReleaseCorpusCases.Count -lt 5) {
    throw 'SDK raw LZMA release corpus manifest does not include enough cases.'
  }
  $releaseTotalUnpackSize = 0L
  $releaseMaxUnpackSize = 0L
  foreach ($case in $rawLzmaReleaseCorpusCases) {
    $releaseTotalUnpackSize += [int64]$case.unpackSize
    if ([int64]$case.unpackSize -gt $releaseMaxUnpackSize) {
      $releaseMaxUnpackSize = [int64]$case.unpackSize
    }
  }
  if ($releaseTotalUnpackSize -lt 3145728 -or $releaseMaxUnpackSize -lt 1048576) {
    throw 'SDK raw LZMA release corpus manifest remains smoke-sized.'
  }
  foreach ($nameFragment in 'repeat', 'random', 'text', 'exe', 'mixed') {
    $matchingCases = @($rawLzmaReleaseCorpusCases | Where-Object { $_.name -like "*$nameFragment*" })
    if ($matchingCases.Count -eq 0) {
      throw "SDK raw LZMA release corpus manifest is missing a $nameFragment case."
    }
  }
  foreach ($switch in '-a0', '-a1', '-d20', '-d22', '-fb32', '-fb64') {
    $matchingCases = @($rawLzmaReleaseCorpusCases | Where-Object { $_.commandLine -like "*$switch*" })
    if ($matchingCases.Count -eq 0) {
      throw "SDK raw LZMA release corpus manifest is missing switch coverage for $switch."
    }
  }
  Require-RawLzmaFixtureCacheEvidence $rawLzmaReleaseCorpusCases 'SDK raw LZMA release corpus'
}
foreach ($requiredCorruptCase in @(
  [pscustomobject]@{
    fixturePath = 'tests/fixtures/corrupt/sevenzip-smoke-truncated-footer.xz'
    expectedError = 'ELzmaInputEof'
  },
  [pscustomobject]@{
    fixturePath = 'tests/fixtures/corrupt/sevenzip-smoke-corrupt-check.xz'
    expectedError = 'ELzmaChecksumError'
  }
)) {
  $fixtureRecords = @($fixtureManifest.fixtures | Where-Object { $_.path -eq $requiredCorruptCase.fixturePath })
  if ($fixtureRecords.Count -ne 1) {
    throw "Fixture SHA-256 manifest missing required corrupt XZ fixture: $($requiredCorruptCase.fixturePath)"
  }
}
foreach ($fixture in $fixtureManifest.fixtures) {
  $fixturePath = Join-Path $root ($fixture.path -replace '/', '\')
  if (-not (Test-Path -LiteralPath $fixturePath)) {
    throw "Fixture listed in SHA-256 manifest is missing: $($fixture.path)"
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $fixturePath).Hash.ToLowerInvariant()
  if ($actual -ne $fixture.sha256) {
    throw "Fixture SHA-256 mismatch for $($fixture.path)"
  }
}
foreach ($manifest in $fixtureManifest.manifests) {
  $manifestPath = Join-Path $root ($manifest.path -replace '/', '\')
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Fixture manifest listed in SHA-256 manifest is missing: $($manifest.path)"
  }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash.ToLowerInvariant()
  if ($actual -ne $manifest.sha256) {
    throw "Fixture manifest SHA-256 mismatch for $($manifest.path)"
  }
}
$corruptXzManifestPath = Join-Path $root 'tests\fixtures\manifests\corrupt-xz-regressions.json'
$corruptXzManifest = Get-Content -LiteralPath $corruptXzManifestPath -Raw | ConvertFrom-Json
foreach ($requiredCorruptCase in @(
  [pscustomobject]@{
    fixturePath = 'tests/fixtures/corrupt/sevenzip-smoke-truncated-footer.xz'
    expectedError = 'ELzmaInputEof'
  },
  [pscustomobject]@{
    fixturePath = 'tests/fixtures/corrupt/sevenzip-smoke-corrupt-check.xz'
    expectedError = 'ELzmaChecksumError'
  }
)) {
  $cases = @($corruptXzManifest.cases | Where-Object { $_.fixturePath -eq $requiredCorruptCase.fixturePath })
  if ($cases.Count -ne 1) {
    throw "Corrupt XZ regression manifest missing case: $($requiredCorruptCase.fixturePath)"
  }
  if ([string]$cases[0].expectedError -ne $requiredCorruptCase.expectedError) {
    throw "Corrupt XZ regression case has unexpected expectedError for $($requiredCorruptCase.fixturePath)"
  }
}

$memoryText = Get-Content -LiteralPath $memoryPath -Raw
if ($memoryText -notmatch 'DUnitX leak tracking completed') {
  throw 'Memory diagnostics report does not include leak tracking summary.'
}
if ($memoryText -notmatch 'DUnitX console summary') {
  throw 'Memory diagnostics report does not include the captured DUnitX console summary.'
}
foreach ($leakSummaryPattern in
  'Tests Leaked\s*:\s*0',
  'Tests Failed\s*:\s*0',
  'Tests Errored\s*:\s*0') {
  if ($memoryText -notmatch $leakSummaryPattern) {
    throw "Memory diagnostics report does not prove clean DUnitX result: $leakSummaryPattern"
  }
}
foreach ($memoryPathName in
  'success encode/decode',
  'invalid properties',
  'corrupted input',
  'truncated input',
  'checksum mismatch',
  'cancellation callback',
  'memory limit failure',
  'worker thread memory/write failure') {
  if ($memoryText -notmatch [regex]::Escape($memoryPathName)) {
    throw "Memory diagnostics report does not include path coverage for: $memoryPathName"
  }
}

if ($ShouldValidatePerformanceArtifacts) {
$perfRows = Get-Content -LiteralPath $perfJsonPath -Raw | ConvertFrom-Json
if ($perfRows -is [System.Array]) {
  $perfRowsArray = $perfRows
} else {
  $perfRowsArray = @($perfRows)
}
$throughputs = @($perfRowsArray | ForEach-Object { $_.throughputMiBs })
if ($throughputs.Count -eq 0) {
  throw 'Performance JSON has no rows.'
}
foreach ($throughput in $throughputs) {
  if ([double]$throughput -le 0) {
    throw "Performance row has non-positive throughput: $throughput"
  }
}

$perfSamplesRows = @(Get-Content -LiteralPath $perfSamplesPath -Raw | ConvertFrom-Csv)
if ($perfSamplesRows.Count -eq 0) {
  throw 'Performance samples CSV must contain at least one raw sample row.'
}
$perfSummary = Get-Content -LiteralPath $perfSummaryPath -Raw | ConvertFrom-Json
if ($perfSummary.benchmark -ne 'lzma2-data-only' -or
    $null -eq $perfSummary.metadata -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.cpu) -or
    [int]$perfSummary.metadata.logicalProcessorCount -lt 1 -or
    $perfSummary.metadata.PSObject.Properties.Name -notcontains 'physicalCoreCount' -or
    [int]$perfSummary.metadata.physicalCoreCount -lt 0 -or
    [int64]$perfSummary.metadata.ramBytes -lt 1 -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.os) -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.compiler) -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.sdkVersion) -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.buildConfig) -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.benchmarkWorkRoot) -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.benchmarkWorkDir) -or
    [string]$perfSummary.metadata.gitCommit -notmatch '^[0-9a-fA-F]{40}$' -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.gitBranch) -or
    [string]::IsNullOrWhiteSpace([string]$perfSummary.metadata.gitRef) -or
    $perfSummary.metadata.PSObject.Properties.Name -notcontains 'ramBackedWorkRoot') {
  throw 'Performance summary JSON must include benchmark metadata.'
}
$summaryGitCommit = ([string]$perfSummary.metadata.gitCommit).ToLowerInvariant()
$currentGitCommitForSummary = Get-CurrentGitCommit
if (-not [string]::IsNullOrWhiteSpace($currentGitCommitForSummary) -and
    $summaryGitCommit -ne $currentGitCommitForSummary.ToLowerInvariant()) {
  throw "Performance summary git commit does not match current HEAD. Summary=$summaryGitCommit HEAD=$currentGitCommitForSummary"
}
if ($RequireReleaseCorpus -and $null -ne $ciManifest.configuration) {
  $releaseBenchmarkWorkRoot = Get-ReleaseBenchmarkWorkRoot $ciManifest.configuration
  if (-not [string]::IsNullOrWhiteSpace([string]$releaseBenchmarkWorkRoot.Path)) {
    $summaryBenchmarkWorkRoot = [IO.Path]::GetFullPath([string]$perfSummary.metadata.benchmarkWorkRoot)
    $manifestBenchmarkWorkRoot = [IO.Path]::GetFullPath([string]$releaseBenchmarkWorkRoot.Path)
    if (-not $summaryBenchmarkWorkRoot.Equals($manifestBenchmarkWorkRoot, [StringComparison]::OrdinalIgnoreCase)) {
      throw 'Performance summary benchmark work root does not match CI manifest work-root evidence.'
    }
    if ([bool]$perfSummary.metadata.ramBackedWorkRoot -ne [bool]$releaseBenchmarkWorkRoot.RamBacked) {
      throw 'Performance summary RAM-backed work-root flag does not match CI manifest work-root evidence.'
    }
  }
}
Assert-BenchmarkCorpusCacheEvidence $perfSummary ([bool]$RequireReleaseCorpus)
if ($null -eq $perfSummary.rows -or [int]$perfSummary.rows.count -ne $perfRowsArray.Count) {
  throw 'Performance summary row count must match benchmark JSON rows.'
}
if ($null -eq $perfSummary.samples -or [int]$perfSummary.samples.count -ne $perfSamplesRows.Count) {
  throw 'Performance summary sample count must match benchmark samples CSV rows.'
}
if ($null -eq $perfSummary.policy -or [bool]$perfSummary.policy.dataOnly -ne $true -or
    [bool]$perfSummary.policy.visualizationsGeneratedByCi -ne $false) {
  throw 'Performance summary JSON must declare the data-only benchmark artifact policy.'
}

$sampleRowsByRowId = @{}
foreach ($sampleRow in $perfSamplesRows) {
  if ([string]::IsNullOrWhiteSpace([string]$sampleRow.rowId) -or
      [string]::IsNullOrWhiteSpace([string]$sampleRow.elapsedMs) -or
      [string]::IsNullOrWhiteSpace([string]$sampleRow.throughputMiBs) -or
      [string]::IsNullOrWhiteSpace([string]$sampleRow.throughputMBs)) {
    throw 'Performance samples CSV rows must include rowId, elapsedMs, throughputMiBs and throughputMBs.'
  }
  if ([double]$sampleRow.elapsedMs -lt 0 -or
      [double]$sampleRow.throughputMiBs -le 0 -or
      [double]$sampleRow.throughputMBs -le 0) {
    throw 'Performance samples CSV rows must include positive throughput samples.'
  }
  if (-not $sampleRowsByRowId.ContainsKey([string]$sampleRow.rowId)) {
    $sampleRowsByRowId[[string]$sampleRow.rowId] = @()
  }
  $sampleRowsByRowId[[string]$sampleRow.rowId] += $sampleRow
}

$perfRowIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($row in $perfRowsArray) {
  foreach ($fieldName in @('rowId', 'operation', 'mode', 'container', 'codec', 'level', 'dictionary',
      'lc', 'lp', 'pb', 'parserMode', 'matchFinderProfile', 'numHashBytes', 'threads', 'threadCount',
      'inputBytes', 'inputSha256', 'outputBytes', 'compressionRatio', 'elapsedSamplesMs',
      'throughputMiBs', 'processThroughputMiBs', 'throughputMBs', 'processThroughputMBs',
      'throughputSamplesMiBs', 'throughputSamplesMBs', 'normalizedCommand', 'normalizedOptions',
      'logicalProcessorCount', 'physicalCoreCount')) {
    if ($row.PSObject.Properties.Name -notcontains $fieldName) {
      throw "Performance JSON rows must include data-only benchmark field: $fieldName"
    }
  }
  if ([string]$row.inputSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Performance JSON rows must include input SHA-256.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$row.normalizedCommand) -or
      [string]::IsNullOrWhiteSpace([string]$row.normalizedOptions)) {
    throw 'Performance JSON rows must include normalized command and options.'
  }
  if ([int]$row.logicalProcessorCount -lt 1 -or [int]$row.physicalCoreCount -lt 0) {
    throw 'Performance JSON rows must include logical and physical core counts.'
  }
  if ([double]$row.throughputMBs -le 0 -or
      [double]$row.processThroughputMBs -le 0) {
    throw 'Performance JSON rows must include positive decimal MB/s throughput fields.'
  }
  $rowId = [string]$row.rowId
  if ([string]::IsNullOrWhiteSpace($rowId) -or -not $perfRowIds.Add($rowId)) {
    throw 'Performance JSON rows must include unique rowId values.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$row.elapsedSamplesMs) -or
      [string]::IsNullOrWhiteSpace([string]$row.throughputSamplesMiBs) -or
      [string]::IsNullOrWhiteSpace([string]$row.throughputSamplesMBs)) {
    throw 'Performance JSON rows must include elapsed and throughput sample lists.'
  }
  if (-not $sampleRowsByRowId.ContainsKey($rowId)) {
    throw 'Performance samples CSV must include at least one sample for every benchmark row.'
  }
}

$comparisonRows = @($perfRows | Where-Object { $_.baselineTool -and $_.throughputRatioPct -ne $null -and $_.acceptance })
if ($comparisonRows.Count -lt 2) {
  throw 'Performance JSON does not include enough SDK comparison rows.'
}
$failingAcceptanceLabels = @(
  'below-100pct-sdk-smoke',
  'below-100pct-sdk-periodic-fastpath',
  'below-100pct-sdk-codec',
  'below-80pct-xz-raw-lzma2',
  'mt-decode-no-speedup',
  'xz-mt-decode-inactive',
  'xz-mt-decode-no-comparison',
  'xz-mt-decode-no-speedup',
  'mt-release-no-speedup',
  'mt-release-mixed-no-speedup',
  'failed'
)
$failingAcceptanceRows = @($perfRowsArray | Where-Object {
  $label = [string]$_.acceptance
  -not [string]::IsNullOrWhiteSpace($label) -and $label -in $failingAcceptanceLabels
})
if ($failingAcceptanceRows.Count -gt 0) {
  $labels = @($failingAcceptanceRows | Select-Object -ExpandProperty acceptance -Unique) -join ', '
  throw "Performance JSON includes failing acceptance label: $labels"
}
if ($RequireExternalTools) {
  $expectedSdkEncodeInput = if ($RequireReleaseCorpus) { 'repeat5-256m.bin' } else { 'repeat5-4m.bin' }
  $expectedSdkDecodeInput = if ($RequireReleaseCorpus) { 'repeat5-256m.7zr.xz' } else { 'repeat5-4m.7zr.xz' }
  $expectedSdkInputBytes = if ($RequireReleaseCorpus) { [int64]268435456 } else { [int64]4194304 }

  $sevenEncodeBaselineRows = @($perfRowsArray | Where-Object {
    $_.tool -eq '7zr-sdk' -and
    $_.operation -eq 'encode' -and
    $_.mode -eq 'xz-lzma2-level1' -and
    $_.inputName -eq $expectedSdkEncodeInput -and
    [int]$_.threads -eq 1 -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'crc32' -and
    [int64]$_.inputBytes -ge $expectedSdkInputBytes -and
    [double]$_.processThroughputMiBs -gt 0
  })
  if ($sevenEncodeBaselineRows.Count -ne 1) {
    throw "Performance JSON must include exactly one aligned 7zr SDK encode baseline row for $expectedSdkEncodeInput."
  }
  $sevenEncodeBaseline = $sevenEncodeBaselineRows[0]
  $sdkComparableCompressionRatioLimit = [double]$sevenEncodeBaseline.compressionRatio * $sdkCompressedSizeRatioGate

  $sdkEncodePassLabels = @(
    'meets-100pct-sdk-smoke',
    'meets-100pct-sdk-periodic-fastpath'
  )
  $sdkEncodeComparisonRows = @($perfRowsArray | Where-Object {
    $_.tool -eq 'delphi-native' -and
    $_.operation -eq 'encode' -and
    $_.mode -eq 'xz-level1' -and
    $_.inputName -eq $expectedSdkEncodeInput -and
    [int]$_.threads -eq 1 -and
    [int]$_.requestedThreadCount -eq 1 -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'crc32' -and
    [int64]$_.inputBytes -eq [int64]$sevenEncodeBaseline.inputBytes -and
    $null -ne $_.compressionRatio -and
    [double]$_.compressionRatio -gt 0 -and
    [double]$_.compressionRatio -le $sdkComparableCompressionRatioLimit -and
    $_.baselineTool -like '7zr-sdk*encode*' -and
    $_.acceptance -in $sdkEncodePassLabels -and
    (
      ($_.acceptance -eq 'meets-100pct-sdk-smoke' -and
        [string]$_.parserMode -eq 'sdk-profile' -and
        [bool]$_.optimumParserEnabled -eq $true -and
        [int64]$_.fullOptimumDecisionCount -gt 0) -or
      ($_.acceptance -eq 'meets-100pct-sdk-periodic-fastpath' -and
        [string]$_.parserMode -eq 'sdk-profile' -and
        [bool]$_.optimumParserEnabled -eq $false -and
        [int64]$_.fullOptimumDecisionCount -eq 0 -and
        [string]$_.inputName -like 'repeat5-*')
    ) -and
    $_.comparisonMetric -eq 'processThroughputMiBs' -and
    [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$sevenEncodeBaseline.processThroughputMiBs) -lt 0.001 -and
    [double]$_.processThroughputMiBs -ge [double]$sevenEncodeBaseline.processThroughputMiBs -and
    $null -ne $_.throughputRatioPct -and
    [double]$_.throughputRatioPct -ge 100.0 -and
    [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.processThroughputMiBs / [double]$sevenEncodeBaseline.processThroughputMiBs) * 100.0, 1))) -lt 0.1
  })
  if ($sdkEncodeComparisonRows.Count -ne 1) {
    throw 'Performance JSON does not prove aligned Delphi encode at or above 100% of the 7zr SDK baseline with comparable compression ratio and honest parser/fast-path evidence.'
  }

  $sevenDecodeBaselineRows = @($perfRowsArray | Where-Object {
    $_.tool -eq '7zr-sdk' -and
    $_.operation -eq 'decode' -and
    $_.mode -eq 'xz-lzma2-level1' -and
    $_.inputName -eq $expectedSdkDecodeInput -and
    [int]$_.threads -eq 1 -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'crc32' -and
    [int64]$_.outputBytes -ge $expectedSdkInputBytes -and
    [double]$_.throughputMiBs -gt 0
  })
  if ($sevenDecodeBaselineRows.Count -ne 1) {
    throw "Performance JSON must include exactly one aligned 7zr SDK decode baseline row for $expectedSdkDecodeInput."
  }
  $sevenDecodeBaseline = $sevenDecodeBaselineRows[0]

  $sdkDecodeComparisonRows = @($perfRowsArray | Where-Object {
    $_.tool -eq 'delphi-native' -and
    $_.operation -eq 'decode' -and
    $_.mode -eq 'xz-level1' -and
    $_.inputName -eq $expectedSdkDecodeInput -and
    [int]$_.threads -eq 1 -and
    [int]$_.requestedThreadCount -eq 1 -and
    [int]$_.actualDecodeThreadCount -eq 1 -and
    [bool]$_.actualMtDecode -eq $false -and
    $_.decodeFallback -eq 'thread-count-one' -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'crc32' -and
    [int64]$_.inputBytes -eq [int64]$sevenDecodeBaseline.inputBytes -and
    [int64]$_.outputBytes -eq [int64]$sevenDecodeBaseline.outputBytes -and
    $_.baselineTool -like '7zr-sdk*decode*' -and
    $_.acceptance -eq 'meets-100pct-sdk-codec' -and
    $_.comparisonMetric -eq 'throughputMiBs' -and
    [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$sevenDecodeBaseline.throughputMiBs) -lt 0.001 -and
    [double]$_.throughputMiBs -ge [double]$sevenDecodeBaseline.throughputMiBs -and
    $null -ne $_.throughputRatioPct -and
    [double]$_.throughputRatioPct -ge 100.0 -and
    [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.throughputMiBs / [double]$sevenDecodeBaseline.throughputMiBs) * 100.0, 1))) -lt 0.1
  })
  if ($sdkDecodeComparisonRows.Count -ne 1) {
    throw 'Performance JSON does not prove aligned Delphi decode codec throughput at or above 100% of the 7zr SDK baseline.'
  }
}
$memoryRows = @($perfRowsArray | Where-Object {
  $_.memoryMeasurementStatus -in @('measured', 'unavailable') -and
  [int64]$_.peakWorkingSetBytes -ge 0 -and
  [int64]$_.peakPagedMemoryBytes -ge 0 -and
  (
    ($_.memoryMeasurementStatus -eq 'measured' -and [int64]$_.peakWorkingSetBytes -gt 0) -or
    ($_.memoryMeasurementStatus -eq 'unavailable' -and [int64]$_.peakWorkingSetBytes -eq 0)
  )
})
if ($memoryRows.Count -ne $perfRowsArray.Count) {
  throw 'Performance JSON rows must include peak memory fields and memoryMeasurementStatus.'
}
$ratioRows = @($perfRowsArray | Where-Object { $_.compressionRatio -ne $null })
if ($ratioRows.Count -ne $perfRowsArray.Count) {
  throw 'Performance JSON rows must include compressionRatio.'
}
$buildRows = @($perfRowsArray | Where-Object { $_.buildConfig -and $_.allocationCountStatus })
if ($buildRows.Count -ne $perfRowsArray.Count) {
  throw 'Performance JSON rows must include buildConfig and allocation-count status.'
}
$allocationUnavailableRows = @($perfRowsArray | Where-Object {
  $_.allocationCountStatus -ne 'unavailable' -or
  -not [string]::IsNullOrWhiteSpace([string]$_.allocationCountUnavailableReason)
})
if ($allocationUnavailableRows.Count -ne $perfRowsArray.Count) {
  throw 'Performance JSON rows with unavailable allocation counts must include an explicit unavailable reason.'
}
$statRows = @($perfRowsArray | Where-Object {
  $_.PSObject.Properties.Name -contains 'warmupCount' -and
  $_.PSObject.Properties.Name -contains 'measuredRunCount' -and
  $_.PSObject.Properties.Name -contains 'bestElapsedMs' -and
  $_.PSObject.Properties.Name -contains 'medianElapsedMs' -and
  $_.PSObject.Properties.Name -contains 'minElapsedMs' -and
  $_.PSObject.Properties.Name -contains 'maxElapsedMs' -and
  $_.PSObject.Properties.Name -contains 'stdevElapsedMs' -and
  [int]$_.warmupCount -ge 0 -and
  [int]$_.measuredRunCount -ge 1 -and
  [double]$_.bestElapsedMs -ge 0 -and
  [double]$_.medianElapsedMs -ge 0 -and
  [double]$_.minElapsedMs -ge 0 -and
  [double]$_.maxElapsedMs -ge 0 -and
  [double]$_.stdevElapsedMs -ge 0
})
if ($statRows.Count -ne $perfRowsArray.Count) {
  throw 'Performance JSON rows must include warm-up and multi-run statistic fields.'
}
$delphiDecodeRows = @($perfRowsArray | Where-Object {
  $_.tool -eq 'delphi-native' -and $_.operation -eq 'decode'
})
$delphiDecodeDiagnosticRows = @($delphiDecodeRows | Where-Object {
  $_.PSObject.Properties.Name -contains 'requestedThreadCount' -and
  $_.PSObject.Properties.Name -contains 'actualDecodeThreadCount' -and
  $_.PSObject.Properties.Name -contains 'decodeIndependentUnitCount' -and
  $_.PSObject.Properties.Name -contains 'actualMtDecode' -and
  $_.PSObject.Properties.Name -contains 'inputSnapshot' -and
  $_.PSObject.Properties.Name -contains 'decodeFallback' -and
  $null -ne $_.requestedThreadCount -and
  $null -ne $_.actualDecodeThreadCount -and
  $null -ne $_.decodeIndependentUnitCount -and
  $null -ne $_.actualMtDecode -and
  $null -ne $_.inputSnapshot -and
  -not [string]::IsNullOrWhiteSpace([string]$_.decodeFallback)
})
if ($delphiDecodeDiagnosticRows.Count -ne $delphiDecodeRows.Count) {
  throw 'Delphi decode performance rows must include requested/actual MT decode diagnostics.'
}
$delphiEncodeRows = @($perfRowsArray | Where-Object {
  $_.tool -eq 'delphi-native' -and $_.operation -eq 'encode'
})
$delphiEncodeDiagnosticRows = @($delphiEncodeRows | Where-Object {
  $_.PSObject.Properties.Name -contains 'requestedEncodeThreadCount' -and
  $_.PSObject.Properties.Name -contains 'actualEncodeThreadCount' -and
  $_.PSObject.Properties.Name -contains 'encodeBatchCount' -and
  $_.PSObject.Properties.Name -contains 'encodeBlockCount' -and
  $_.PSObject.Properties.Name -contains 'parserMode' -and
  $_.PSObject.Properties.Name -contains 'matchFinderProfile' -and
  $_.PSObject.Properties.Name -contains 'numHashBytes' -and
  $_.PSObject.Properties.Name -contains 'optimumParserEnabled' -and
  $_.PSObject.Properties.Name -contains 'fullOptimumDecisionCount' -and
  $_.PSObject.Properties.Name -contains 'fastBytes' -and
  $_.PSObject.Properties.Name -contains 'niceLen' -and
  $_.PSObject.Properties.Name -contains 'cutValue' -and
  $_.PSObject.Properties.Name -contains 'xzBlockSize' -and
  $_.PSObject.Properties.Name -contains 'copyFastPathCount' -and
  $_.PSObject.Properties.Name -contains 'incompressibleFastPathCount' -and
  $_.PSObject.Properties.Name -contains 'encodeFallback' -and
  $null -ne $_.requestedEncodeThreadCount -and
  $null -ne $_.actualEncodeThreadCount -and
  $null -ne $_.encodeBatchCount -and
  $null -ne $_.encodeBlockCount -and
  -not [string]::IsNullOrWhiteSpace([string]$_.parserMode) -and
  -not [string]::IsNullOrWhiteSpace([string]$_.matchFinderProfile) -and
  $null -ne $_.numHashBytes -and
  $null -ne $_.optimumParserEnabled -and
  $null -ne $_.fullOptimumDecisionCount -and
  $null -ne $_.fastBytes -and
  $null -ne $_.niceLen -and
  $null -ne $_.cutValue -and
  $null -ne $_.xzBlockSize -and
  $null -ne $_.copyFastPathCount -and
  $null -ne $_.incompressibleFastPathCount -and
  [int64]$_.fastBytes -ge 0 -and
  [int64]$_.niceLen -ge 0 -and
  [int64]$_.cutValue -ge 0 -and
  [int64]$_.numHashBytes -ge 0 -and
  [int64]$_.xzBlockSize -ge 0 -and
  [int64]$_.copyFastPathCount -ge 0 -and
  [int64]$_.incompressibleFastPathCount -ge 0 -and
  [int64]$_.incompressibleFastPathCount -le [int64]$_.copyFastPathCount -and
  [int64]$_.fullOptimumDecisionCount -ge 0 -and
  -not [string]::IsNullOrWhiteSpace([string]$_.encodeFallback)
})
if ($delphiEncodeDiagnosticRows.Count -ne $delphiEncodeRows.Count) {
  throw 'Delphi encode performance rows must include parser/match-finder and MT encode diagnostics plus encode tuning and fast-path diagnostics.'
}
$inconsistentOptimumParserRows = @($delphiEncodeRows | Where-Object {
  [bool]$_.optimumParserEnabled -eq $true -and
  ([string]$_.parserMode -ne 'sdk-profile' -or [int]$_.encodeBlockCount -le 0 -or
    [int64]$_.fullOptimumDecisionCount -le 0)
})
if ($inconsistentOptimumParserRows.Count -gt 0) {
  throw 'Performance JSON must only report OptimumParserEnabled=True for active sdk-profile parser rows with full optimum decision evidence.'
}
$hiddenDecodeFallbackRows = @($delphiDecodeRows | Where-Object {
  [int]$_.requestedThreadCount -gt 1 -and
  [bool]$_.actualMtDecode -eq $false -and
  ([string]::IsNullOrWhiteSpace([string]$_.decodeFallback) -or $_.decodeFallback -eq 'none') -and
  $_.acceptance -notlike '*fallback*'
})
if ($hiddenDecodeFallbackRows.Count -gt 0) {
  throw 'Performance JSON contains a hidden MT decode fallback row.'
}
$hiddenEncodeFallbackRows = @($delphiEncodeRows | Where-Object {
  [int]$_.requestedEncodeThreadCount -gt 1 -and
  [int]$_.actualEncodeThreadCount -le 1 -and
  ([string]::IsNullOrWhiteSpace([string]$_.encodeFallback) -or $_.encodeFallback -eq 'none') -and
  $_.acceptance -notlike '*fallback*'
})
if ($hiddenEncodeFallbackRows.Count -gt 0) {
  throw 'Performance JSON contains a hidden MT encode fallback row.'
}
$delphiEncodeInputs = @($perfRowsArray |
  Where-Object { $_.tool -eq 'delphi-native' -and $_.operation -eq 'encode' } |
  Select-Object -ExpandProperty inputName -Unique)
if ($delphiEncodeInputs.Count -lt 5) {
  throw 'Performance JSON does not include enough Delphi input corpus variants.'
}
$rawLzma2DecodeRows = @($perfRowsArray | Where-Object {
  $_.tool -eq 'delphi-native' -and
  $_.operation -eq 'decode' -and
  $_.mode -like 'raw-lzma2-*'
})
if ($rawLzma2DecodeRows.Count -lt 1) {
  throw 'Performance JSON does not include a Delphi raw LZMA2 decode benchmark row.'
}
$rawLzma2MtDecodeRows = @($rawLzma2DecodeRows | Where-Object {
  [int]$_.threads -eq 4 -and
  [bool]$_.actualMtDecode -eq $true -and
  [int]$_.actualDecodeThreadCount -gt 1 -and
  [int]$_.decodeIndependentUnitCount -gt 1 -and
  $_.acceptance -eq 'mt-decode-speedup' -and
  $_.baselineTool -and
  [double]$_.baselineThroughputMiBs -gt 0 -and
  $null -ne $_.throughputRatioPct -and
  $_.comparisonMetric -eq 'processThroughputMiBs'
})
$rawLzma2MtFallbackRows = @($rawLzma2DecodeRows | Where-Object {
  [int]$_.threads -eq 4 -and
  [bool]$_.actualMtDecode -eq $false -and
  [int]$_.actualDecodeThreadCount -eq 1 -and
  [int]$_.decodeIndependentUnitCount -gt 1 -and
  $_.decodeFallback -eq 'insufficient-work' -and
  $_.acceptance -eq 'mt-decode-fallback-insufficient-work' -and
  $_.baselineTool -and
  [double]$_.baselineThroughputMiBs -gt 0 -and
  $null -ne $_.throughputRatioPct -and
  $_.comparisonMetric -eq 'processThroughputMiBs'
})
if (($rawLzma2MtDecodeRows.Count + $rawLzma2MtFallbackRows.Count) -lt 1) {
  throw 'Performance JSON must prove raw LZMA2 MT decode speedup or an explicit insufficient-work fallback.'
}
$delphiGeneratedXzEncodeRows = @($delphiEncodeRows | Where-Object {
  $_.mode -eq 'xz-delphi-multiblock-level1' -and
  [int]$_.threads -eq 1 -and
  [int]$_.level -eq 1 -and
  [int64]$_.dictionary -eq 1048576 -and
  $_.check -eq 'crc32' -and
  [int64]$_.xzBlockSize -eq 8388608 -and
  [int]$_.encodeBlockCount -ge 4 -and
  [double]$_.processThroughputMiBs -gt 0 -and
  [int64]$_.inputBytes -ge 67108864 -and
  [int64]$_.outputBytes -gt 0
})
if ($delphiGeneratedXzEncodeRows.Count -ne 1) {
  throw 'Performance JSON must include exactly one Delphi-generated multi-block XZ encode row with an 8 MiB block size.'
}
$delphiGeneratedXzMtBaselineRows = @($delphiDecodeRows | Where-Object {
  $_.mode -eq 'xz-delphi-multiblock-level1' -and
  [int]$_.threads -eq 1 -and
  [int]$_.actualDecodeThreadCount -eq 1 -and
  [bool]$_.actualMtDecode -eq $false -and
  [int]$_.decodeIndependentUnitCount -eq 1 -and
  [bool]$_.inputSnapshot -eq $false -and
  $_.decodeFallback -eq 'thread-count-one' -and
  [int]$_.level -eq 1 -and
  [int64]$_.dictionary -eq 1048576 -and
  $_.check -eq 'crc32' -and
  [double]$_.processThroughputMiBs -gt 0 -and
  [int64]$_.outputBytes -ge 67108864
})
if ($delphiGeneratedXzMtBaselineRows.Count -ne 1) {
  throw 'Performance JSON must include exactly one Delphi-generated XZ MT decode 1-thread baseline row.'
}
$delphiGeneratedXzMtBaseline = $delphiGeneratedXzMtBaselineRows[0]
$delphiGeneratedXzMtAcceptances = @('xz-delphi-mt-decode-speedup', 'xz-delphi-mt-decode-no-speedup')
foreach ($xzMtThreads in @(2, 4, 8, 16)) {
  $delphiGeneratedXzMtDecodeRows = @($delphiDecodeRows | Where-Object {
    $_.mode -eq 'xz-delphi-multiblock-level1' -and
    [int]$_.threads -eq $xzMtThreads -and
    $_.inputName -eq $delphiGeneratedXzMtBaseline.inputName -and
    [int64]$_.inputBytes -eq [int64]$delphiGeneratedXzMtBaseline.inputBytes -and
    [int64]$_.outputBytes -eq [int64]$delphiGeneratedXzMtBaseline.outputBytes -and
    [int]$_.level -eq [int]$delphiGeneratedXzMtBaseline.level -and
    [int64]$_.dictionary -eq [int64]$delphiGeneratedXzMtBaseline.dictionary -and
    $_.check -eq $delphiGeneratedXzMtBaseline.check -and
    [bool]$_.actualMtDecode -eq $true -and
    [int]$_.actualDecodeThreadCount -gt 1 -and
    [int]$_.decodeIndependentUnitCount -ge 4 -and
    [bool]$_.inputSnapshot -eq $false -and
    $_.decodeFallback -eq 'none' -and
    $_.acceptance -in $delphiGeneratedXzMtAcceptances -and
    $_.baselineTool -and
    [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$delphiGeneratedXzMtBaseline.processThroughputMiBs) -lt 0.001 -and
    ($_.acceptance -like '*no-speedup' -or [double]$_.processThroughputMiBs -gt [double]$delphiGeneratedXzMtBaseline.processThroughputMiBs) -and
    $null -ne $_.throughputRatioPct -and
    [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.processThroughputMiBs / [double]$delphiGeneratedXzMtBaseline.processThroughputMiBs) * 100.0, 1))) -lt 0.1 -and
    $_.comparisonMetric -eq 'processThroughputMiBs'
  })
  if ($delphiGeneratedXzMtDecodeRows.Count -lt 1) {
    throw "Performance JSON must prove Delphi-generated XZ MT decode active worker evidence for threads=$xzMtThreads."
  }
}
$delphiPatternedXzEncodeRows = @($delphiEncodeRows | Where-Object {
  $_.mode -eq 'xz-delphi-patterned-multiblock-level1' -and
  [int]$_.threads -eq 1 -and
  [int]$_.level -eq 1 -and
  [int64]$_.dictionary -eq 1048576 -and
  $_.check -eq 'crc32' -and
  [int64]$_.xzBlockSize -eq 8388608 -and
  [int]$_.encodeBlockCount -ge 4 -and
  [double]$_.processThroughputMiBs -gt 0 -and
  [int64]$_.inputBytes -ge 67108864 -and
  [int64]$_.outputBytes -gt 0
})
if ($delphiPatternedXzEncodeRows.Count -ne 1) {
  throw 'Performance JSON must include exactly one patterned Delphi-generated multi-block XZ encode row with an 8 MiB block size.'
}
$delphiPatternedXzMtBaselineRows = @($delphiDecodeRows | Where-Object {
  $_.mode -eq 'xz-delphi-patterned-multiblock-level1' -and
  [int]$_.threads -eq 1 -and
  [int]$_.actualDecodeThreadCount -eq 1 -and
  [bool]$_.actualMtDecode -eq $false -and
  [int]$_.decodeIndependentUnitCount -eq 1 -and
  [bool]$_.inputSnapshot -eq $false -and
  $_.decodeFallback -eq 'thread-count-one' -and
  [int]$_.level -eq 1 -and
  [int64]$_.dictionary -eq 1048576 -and
  $_.check -eq 'crc32' -and
  [double]$_.processThroughputMiBs -gt 0 -and
  [int64]$_.outputBytes -ge 67108864
})
if ($delphiPatternedXzMtBaselineRows.Count -ne 1) {
  throw 'Performance JSON must include exactly one patterned Delphi-generated XZ MT decode 1-thread baseline row.'
}
$delphiPatternedXzMtBaseline = $delphiPatternedXzMtBaselineRows[0]
$delphiPatternedXzMtAcceptances = @('xz-delphi-patterned-mt-decode-speedup', 'xz-delphi-patterned-mt-decode-no-speedup')
foreach ($xzMtThreads in @(2, 4, 8, 16)) {
  $delphiPatternedXzMtDecodeRows = @($delphiDecodeRows | Where-Object {
    $_.mode -eq 'xz-delphi-patterned-multiblock-level1' -and
    [int]$_.threads -eq $xzMtThreads -and
    $_.inputName -eq $delphiPatternedXzMtBaseline.inputName -and
    [int64]$_.inputBytes -eq [int64]$delphiPatternedXzMtBaseline.inputBytes -and
    [int64]$_.outputBytes -eq [int64]$delphiPatternedXzMtBaseline.outputBytes -and
    [int]$_.level -eq [int]$delphiPatternedXzMtBaseline.level -and
    [int64]$_.dictionary -eq [int64]$delphiPatternedXzMtBaseline.dictionary -and
    $_.check -eq $delphiPatternedXzMtBaseline.check -and
    [bool]$_.actualMtDecode -eq $true -and
    [int]$_.actualDecodeThreadCount -gt 1 -and
    [int]$_.decodeIndependentUnitCount -ge 4 -and
    [bool]$_.inputSnapshot -eq $false -and
    $_.decodeFallback -eq 'none' -and
    $_.acceptance -in $delphiPatternedXzMtAcceptances -and
    $_.baselineTool -and
    [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$delphiPatternedXzMtBaseline.processThroughputMiBs) -lt 0.001 -and
    ($_.acceptance -like '*no-speedup' -or [double]$_.processThroughputMiBs -gt [double]$delphiPatternedXzMtBaseline.processThroughputMiBs) -and
    $null -ne $_.throughputRatioPct -and
    [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.processThroughputMiBs / [double]$delphiPatternedXzMtBaseline.processThroughputMiBs) * 100.0, 1))) -lt 0.1 -and
    $_.comparisonMetric -eq 'processThroughputMiBs'
  })
  if ($delphiPatternedXzMtDecodeRows.Count -lt 1) {
    throw "Performance JSON must prove patterned Delphi-generated XZ MT decode active worker evidence for threads=$xzMtThreads."
  }
}
if ($RequireExternalTools) {
  $expectedXzMtOutputBytes = if ($RequireReleaseCorpus) { [int64]268435456 } else { [int64]67108864 }
  $xzMtBaselineRows = @($delphiDecodeRows | Where-Object {
    $_.mode -eq 'xz-multiblock-level1' -and
    [int]$_.threads -eq 1 -and
    [int]$_.actualDecodeThreadCount -eq 1 -and
    [bool]$_.actualMtDecode -eq $false -and
    [int]$_.decodeIndependentUnitCount -eq 1 -and
    $_.decodeFallback -eq 'thread-count-one' -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'crc32' -and
    [double]$_.processThroughputMiBs -gt 0 -and
    [int64]$_.outputBytes -ge $expectedXzMtOutputBytes
  })
  if ($xzMtBaselineRows.Count -ne 1) {
    throw 'Performance JSON must include exactly one XZ MT decode 1-thread baseline row.'
  }
  $xzMtBaseline = $xzMtBaselineRows[0]

  foreach ($xzMtThreads in @(2, 4, 8, 16)) {
    $xzMtDecodeRows = @($delphiDecodeRows | Where-Object {
      $_.mode -eq 'xz-multiblock-level1' -and
      [int]$_.threads -eq $xzMtThreads -and
      $_.inputName -eq $xzMtBaseline.inputName -and
      [int64]$_.inputBytes -eq [int64]$xzMtBaseline.inputBytes -and
      [int64]$_.outputBytes -eq [int64]$xzMtBaseline.outputBytes -and
      [int]$_.level -eq [int]$xzMtBaseline.level -and
      [int64]$_.dictionary -eq [int64]$xzMtBaseline.dictionary -and
      $_.check -eq $xzMtBaseline.check -and
      [bool]$_.actualMtDecode -eq $true -and
      [int]$_.actualDecodeThreadCount -gt 1 -and
      [int]$_.decodeIndependentUnitCount -ge 4 -and
      $_.decodeFallback -eq 'none' -and
      $_.acceptance -eq 'xz-mt-decode-speedup' -and
      $_.baselineTool -and
      [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$xzMtBaseline.processThroughputMiBs) -lt 0.001 -and
      [double]$_.processThroughputMiBs -gt [double]$xzMtBaseline.processThroughputMiBs -and
      $null -ne $_.throughputRatioPct -and
      [double]$_.throughputRatioPct -ge 100.0 -and
      [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.processThroughputMiBs / [double]$xzMtBaseline.processThroughputMiBs) * 100.0, 1))) -lt 0.1 -and
      $_.comparisonMetric -eq 'processThroughputMiBs'
    })
    if ($xzMtDecodeRows.Count -lt 1) {
      throw "Performance JSON must prove XZ MT decode speedup on independent blocks for threads=$xzMtThreads."
    }
  }

  $expectedXzRawArchive = 'repeat5-256m.xzraw-src.bin.rawlzma2'
  $xzRawLzma2DecodeRows = @($perfRowsArray | Where-Object {
    $_.tool -eq 'xz-utils' -and
    $_.operation -eq 'decode' -and
    $_.mode -eq 'raw-lzma2-level1' -and
    $_.inputName -eq $expectedXzRawArchive -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'none'
  })
  if ($xzRawLzma2DecodeRows.Count -lt 1) {
    throw "Performance JSON does not include the expected xz-utils raw LZMA2 decode benchmark row: $expectedXzRawArchive"
  }
  $expectedDelphiRawArchive = 'raw-repeat5-256m-l1-1t.delphi.lzma2'
  $xzDecodesDelphiRawRows = @($perfRowsArray | Where-Object {
    $_.tool -eq 'xz-utils' -and
    $_.operation -eq 'decode' -and
    $_.mode -eq 'raw-lzma2-level1' -and
    $_.inputName -eq $expectedDelphiRawArchive -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'none' -and
    $_.acceptance -eq 'xz-decodes-delphi-raw-lzma2'
  })
  if ($xzDecodesDelphiRawRows.Count -lt 1) {
    throw "Performance JSON does not prove xz-utils can decode Delphi raw LZMA2 output: $expectedDelphiRawArchive"
  }
  $rawLzma2ComparisonRows = @($rawLzma2DecodeRows | Where-Object {
    $_.inputName -eq $expectedXzRawArchive -and
    $_.mode -eq 'raw-lzma2-level1' -and
    [int]$_.level -eq 1 -and
    [int64]$_.dictionary -eq 1048576 -and
    $_.check -eq 'none' -and
    $_.baselineTool -like '*xz*' -and
    $_.throughputRatioPct -ne $null -and
    [double]$_.baselineThroughputMiBs -gt 0 -and
    $_.comparisonMetric -eq 'throughputMiBs' -and
    $_.acceptance -eq 'meets-80pct-xz-raw-lzma2'
  })
  if ($rawLzma2ComparisonRows.Count -lt 1) {
    throw "Performance JSON does not include the expected passing Delphi-vs-xz raw LZMA2 decode comparison row: $expectedXzRawArchive"
  }

  if ($RequireReleaseCorpus) {
    $sdkRawLzmaReleaseEncodeRows = @($perfRowsArray | Where-Object {
      $_.tool -eq 'lzma-sdk' -and
      $_.operation -eq 'encode' -and
      $_.mode -eq 'raw-lzma-level-default' -and
      $_.inputName -eq 'repeat5-256m.bin' -and
      [int]$_.threads -eq 1 -and
      [int64]$_.dictionary -eq 1048576 -and
      [int64]$_.inputBytes -ge 268435456 -and
      [double]$_.processThroughputMiBs -gt 0
    })
    if ($sdkRawLzmaReleaseEncodeRows.Count -ne 1) {
      throw 'Performance JSON must include exactly one SDK raw LZMA release-corpus encode baseline row.'
    }

    $sdkRawLzmaReleaseDecodeRows = @($perfRowsArray | Where-Object {
      $_.tool -eq 'lzma-sdk' -and
      $_.operation -eq 'decode' -and
      $_.mode -eq 'raw-lzma-level-default' -and
      $_.inputName -eq 'repeat5-256m.sdk.lzma' -and
      [int]$_.threads -eq 1 -and
      [int64]$_.dictionary -eq 1048576 -and
      [int64]$_.outputBytes -ge 268435456 -and
      [double]$_.processThroughputMiBs -gt 0
    })
    if ($sdkRawLzmaReleaseDecodeRows.Count -ne 1) {
      throw 'Performance JSON must include exactly one SDK raw LZMA release-corpus decode baseline row.'
    }
  }
}
foreach ($level in 0, 1, 3, 5, 7, 9) {
  foreach ($dictionary in 4096, 65536, 1048576, 16777216, 67108864, 268435456, 536870912) {
    $match = @($perfRowsArray | Where-Object {
      $_.tool -eq 'delphi-native' -and
      $_.operation -eq 'encode' -and
      [int]$_.level -eq $level -and
      [int64]$_.dictionary -eq $dictionary
    })
    if ($match.Count -eq 0) {
      throw "Performance JSON is missing Delphi smoke row for level=$level dictionary=$dictionary."
    }
  }
}
if ($RequireReleaseCorpus) {
  $releaseThreadMatrix = @(1, 2, 4, 8, 16)
  $summaryLogicalProcessors = [int]$perfSummary.metadata.logicalProcessorCount
  if ($summaryLogicalProcessors -gt 16) {
    $releaseThreadMatrix = @($releaseThreadMatrix + $summaryLogicalProcessors | Sort-Object -Unique)
  }
  foreach ($corpusSpec in @(
      [pscustomobject]@{ Name = 'repeat5-256m.bin'; RequiresSdkBaseline = $true; RatioLimit = 0.0 },
      [pscustomobject]@{ Name = 'mixed-256m.bin'; RequiresSdkBaseline = $false; RatioLimit = 0.05 }
    )) {
    $corpusName = [string]$corpusSpec.Name
    $corpusRatioLimit = [double]$corpusSpec.RatioLimit
    if ([bool]$corpusSpec.RequiresSdkBaseline) {
      $releaseReferenceRatioRows = @($perfRowsArray | Where-Object {
        $_.tool -eq '7zr-sdk' -and
        $_.operation -eq 'encode' -and
        $_.mode -eq 'xz-lzma2-level1' -and
        $_.inputName -eq $corpusName -and
        [int]$_.threads -eq 1 -and
        [int]$_.level -eq 1 -and
        [int64]$_.dictionary -eq 1048576 -and
        $_.check -eq 'crc32' -and
        $null -ne $_.compressionRatio -and
        [double]$_.compressionRatio -gt 0
      })
      if ($releaseReferenceRatioRows.Count -ne 1) {
        throw "Performance JSON must include exactly one aligned 7zr SDK release encode baseline row for $corpusName."
      }
      $corpusRatioLimit = [double]$releaseReferenceRatioRows[0].compressionRatio * $sdkCompressedSizeRatioGate
    }
    foreach ($threads in $releaseThreadMatrix) {
      $releaseMatch = @($perfRowsArray | Where-Object {
        $_.tool -eq 'delphi-native' -and
        $_.operation -eq 'encode' -and
        $_.inputName -eq $corpusName -and
        [int]$_.level -eq 1 -and
        [int]$_.threads -eq $threads -and
        [int64]$_.inputBytes -ge 268435456
      })
      if ($releaseMatch.Count -eq 0) {
        throw "Performance JSON is missing 256 MiB release-corpus Delphi encode row for $corpusName threads=$threads."
      }
      $releaseRatioMatch = @($releaseMatch | Where-Object {
        $_.compressionRatio -ne $null -and
        [double]$_.compressionRatio -gt 0 -and
        [double]$_.compressionRatio -le $corpusRatioLimit -and
        [double]$_.processThroughputMiBs -gt 0
      })
      if ($releaseRatioMatch.Count -eq 0) {
        if ([bool]$corpusSpec.RequiresSdkBaseline) {
          throw "Performance JSON release-corpus Delphi encode row must record usable SDK-comparable compression ratio and throughput for $corpusName threads=$threads."
        }
        throw "Performance JSON release-corpus Delphi encode row must record usable diagnostic compression ratio and throughput for $corpusName threads=$threads."
      }
    }
  }
  foreach ($releaseComparisonSpec in @(
      [pscustomobject]@{ Corpus = 'repeat5-256m.bin'; Acceptance = 'mt-release-speedup'; FastPathAcceptance = 'mt-release-fastpath-saturated'; BoundedAcceptance = ''; BoundedThresholdPct = 0.0; BaselineTool = 'repeat5-256m.bin' },
      [pscustomobject]@{ Corpus = 'mixed-256m.bin'; Acceptance = 'mt-release-mixed-speedup'; FastPathAcceptance = ''; BoundedAcceptance = 'mt-release-mixed-overhead-bounded'; BoundedThresholdPct = 80.0; BaselineTool = 'mixed-256m.bin' }
    )) {
    $sameCorpusBaseline = @($perfRowsArray | Where-Object {
      $_.tool -eq 'delphi-native' -and
      $_.operation -eq 'encode' -and
      $_.inputName -eq $releaseComparisonSpec.Corpus -and
      [int64]$_.inputBytes -ge 268435456 -and
      [int]$_.level -eq 1 -and
      [int]$_.threads -eq 1 -and
      [int]$_.requestedThreadCount -eq 1 -and
      $_.check -eq 'crc64' -and
      [double]$_.processThroughputMiBs -gt 0
    }) | Select-Object -First 1
    if (-not $sameCorpusBaseline) {
      throw "Performance JSON is missing same-corpus release MT baseline for $($releaseComparisonSpec.Corpus)."
    }

    foreach ($threads in @($releaseThreadMatrix | Where-Object { $_ -ne 1 })) {
      $releaseMtComparisons = @($perfRowsArray | Where-Object {
        $_.tool -eq 'delphi-native' -and
        $_.operation -eq 'encode' -and
        $_.inputName -eq $releaseComparisonSpec.Corpus -and
        [int64]$_.inputBytes -ge 268435456 -and
        [int]$_.threads -eq $threads -and
        $_.baselineTool -and
        $_.throughputRatioPct -ne $null -and
        [double]$_.baselineThroughputMiBs -gt 0 -and
        $_.comparisonMetric -eq 'processThroughputMiBs' -and
        $_.baselineTool -like "*$($releaseComparisonSpec.BaselineTool)*" -and
        [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$sameCorpusBaseline.processThroughputMiBs) -lt 0.001 -and
        [double]$_.processThroughputMiBs -gt [double]$sameCorpusBaseline.processThroughputMiBs -and
        [double]$_.throughputRatioPct -ge 100.0 -and
        [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.processThroughputMiBs / [double]$sameCorpusBaseline.processThroughputMiBs) * 100.0, 1))) -lt 0.1 -and
        $_.acceptance -eq $releaseComparisonSpec.Acceptance
      })
      if ($releaseMtComparisons.Count -lt 1) {
        if (-not [string]::IsNullOrWhiteSpace([string]$releaseComparisonSpec.BoundedAcceptance)) {
          $releaseMtComparisons = @($perfRowsArray | Where-Object {
            $_.tool -eq 'delphi-native' -and
            $_.operation -eq 'encode' -and
            $_.inputName -eq $releaseComparisonSpec.Corpus -and
            [int64]$_.inputBytes -ge 268435456 -and
            [int]$_.threads -eq $threads -and
            $_.baselineTool -and
            $_.throughputRatioPct -ne $null -and
            [double]$_.baselineThroughputMiBs -gt 0 -and
            $_.comparisonMetric -eq 'processThroughputMiBs' -and
            $_.baselineTool -like "*$($releaseComparisonSpec.BaselineTool)*" -and
            [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$sameCorpusBaseline.processThroughputMiBs) -lt 0.001 -and
            [double]$_.processThroughputMiBs -ge ([double]$sameCorpusBaseline.processThroughputMiBs * ([double]$releaseComparisonSpec.BoundedThresholdPct / 100.0)) -and
            [double]$_.throughputRatioPct -ge [double]$releaseComparisonSpec.BoundedThresholdPct -and
            [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.processThroughputMiBs / [double]$sameCorpusBaseline.processThroughputMiBs) * 100.0, 1))) -lt 0.1 -and
            $_.acceptance -eq $releaseComparisonSpec.BoundedAcceptance
          })
          if ($releaseMtComparisons.Count -ge 1) {
            continue
          }
        }

        if ([string]::IsNullOrWhiteSpace([string]$releaseComparisonSpec.FastPathAcceptance)) {
          throw "Performance JSON is missing a passing release-corpus MT comparison row for $($releaseComparisonSpec.Corpus) threads=$threads."
        }

        $sdkRepeatBaseline = @($perfRowsArray | Where-Object {
          $_.tool -eq '7zr-sdk' -and
          $_.operation -eq 'encode' -and
          $_.mode -eq 'xz-lzma2-level1' -and
          $_.inputName -eq $releaseComparisonSpec.Corpus -and
          [int]$_.threads -eq 1 -and
          [int64]$_.dictionary -eq [int64]$sameCorpusBaseline.dictionary -and
          $_.check -eq 'crc32' -and
          [double]$_.processThroughputMiBs -gt 0
        }) | Select-Object -First 1
        if (-not $sdkRepeatBaseline) {
          throw "Performance JSON is missing SDK baseline evidence for fast-path saturated release MT comparison on $($releaseComparisonSpec.Corpus)."
        }

        $releaseMtComparisons = @($perfRowsArray | Where-Object {
          $_.tool -eq 'delphi-native' -and
          $_.operation -eq 'encode' -and
          $_.inputName -eq $releaseComparisonSpec.Corpus -and
          [int64]$_.inputBytes -ge 268435456 -and
          [int]$_.threads -eq $threads -and
          $_.baselineTool -and
          $_.throughputRatioPct -ne $null -and
          [double]$_.baselineThroughputMiBs -gt 0 -and
          $_.comparisonMetric -eq 'processThroughputMiBs' -and
          $_.baselineTool -like "*$($releaseComparisonSpec.BaselineTool)*" -and
          [Math]::Abs([double]$_.baselineThroughputMiBs - [double]$sameCorpusBaseline.processThroughputMiBs) -lt 0.001 -and
          [double]$sameCorpusBaseline.processThroughputMiBs -ge [double]$sdkRepeatBaseline.processThroughputMiBs -and
          [double]$_.processThroughputMiBs -ge [double]$sdkRepeatBaseline.processThroughputMiBs -and
          [Math]::Abs([double]$_.throughputRatioPct - ([Math]::Round(([double]$_.processThroughputMiBs / [double]$sameCorpusBaseline.processThroughputMiBs) * 100.0, 1))) -lt 0.1 -and
          $_.acceptance -eq $releaseComparisonSpec.FastPathAcceptance
        })
        if ($releaseMtComparisons.Count -lt 1) {
          throw "Performance JSON is missing a passing release-corpus MT comparison row for $($releaseComparisonSpec.Corpus) threads=$threads."
        }
      }
    }
  }
}

if ((Get-Item -LiteralPath $perfCsvPath).Length -le 0 -or
    (Get-Item -LiteralPath $perfJsonPath).Length -le 0 -or
    (Get-Item -LiteralPath $perfSamplesPath).Length -le 0 -or
    (Get-Item -LiteralPath $perfSummaryPath).Length -le 0) {
  throw 'Performance data-only benchmark artifacts must be non-empty.'
}
if ((Get-Item -LiteralPath $perfOptimizationPath).Length -le 0) {
  throw 'Performance optimization plan artifact must be non-empty.'
}
}
$ciManifest = Get-Content -LiteralPath $ciManifestPath -Raw | ConvertFrom-Json
if ($null -eq $ciManifest.configuration) {
  throw 'CI manifest is missing run configuration.'
}
if ($null -eq $ciManifest.commands) {
  throw 'CI manifest is missing command line evidence.'
}
$runCiCommandLine = [string]$ciManifest.commands.runCi
$runPerformanceCommandLine = [string]$ciManifest.commands.runPerformance
if ([string]::IsNullOrWhiteSpace($runCiCommandLine) -or
    $runCiCommandLine -notmatch 'run-ci\.ps1') {
  throw 'CI manifest is missing required run-ci command line.'
}
if ($ShouldValidatePerformanceArtifacts -and
    ([string]::IsNullOrWhiteSpace($runPerformanceCommandLine) -or
    $runPerformanceCommandLine -notmatch 'run-performance\.ps1')) {
  throw 'CI manifest is missing required performance command line.'
}
if (-not $ShouldValidatePerformanceArtifacts -and
    [string]$ciManifest.configuration.mode -eq 'quick' -and
    $runPerformanceCommandLine -notmatch 'quick mode skips tests/run-performance\.ps1') {
  throw 'CI manifest does not prove quick skipped the performance matrix.'
}
if ($RequireExternalTools -and [bool]$ciManifest.configuration.requireExternalTools -ne $true) {
  throw 'CI manifest does not prove required external-tool mode.'
}
if ($RequireReleaseCorpus -and [bool]$ciManifest.configuration.releasePerformance -ne $true) {
  throw 'CI manifest does not prove release performance mode.'
}
if ($RequireReleaseCorpus -and [string]$ciManifest.configuration.mode -notin @('release', 'soak')) {
  throw 'CI manifest does not prove release or soak CI mode.'
}
if ($RequireReleaseCorpus -and $runCiCommandLine -notmatch '-Mode\s+''?(release|soak)''?') {
  throw 'CI manifest is missing required release run-ci command line.'
}
if ($RequireReleaseCorpus -and $runPerformanceCommandLine -notmatch '-ReleaseCorpus') {
  throw 'CI manifest is missing required release performance command line.'
}
if ($RequireReleaseCorpus) {
  $releaseBenchmarkWorkRoot = Get-ReleaseBenchmarkWorkRoot $ciManifest.configuration
  Assert-CiBenchmarkWorkRoot ([string]$releaseBenchmarkWorkRoot.Path) ([bool]$releaseBenchmarkWorkRoot.RamBacked)
}
$configurationPropertyNames = @($ciManifest.configuration.PSObject.Properties.Name)
if ($configurationPropertyNames -notcontains 'dunitxCategoryArgs') {
  throw 'CI manifest is missing DUnitX category arguments.'
}
$dunitxCategoryArgs = ConvertTo-StringList $ciManifest.configuration.dunitxCategoryArgs
switch ([string]$ciManifest.configuration.mode) {
  'inner' {
    if ($dunitxCategoryArgs -notcontains '--include:unit' -or
        $dunitxCategoryArgs -notcontains '--exclude:container,compat,perf-smoke,perf-release,soak,fuzz') {
      throw 'CI manifest is missing inner DUnitX category arguments.'
    }
  }
  'quick' {
    if ($dunitxCategoryArgs -notcontains '--include:unit,container,compat,perf-smoke' -or
        $dunitxCategoryArgs -notcontains '--exclude:perf-release,soak,fuzz') {
      throw 'CI manifest is missing quick DUnitX category arguments.'
    }
  }
  'release' {
    if ($dunitxCategoryArgs -notcontains '--exclude:soak,fuzz') {
      throw 'CI manifest is missing release DUnitX category arguments.'
    }
  }
  'soak' {
    if ($dunitxCategoryArgs -notcontains '--exclude:fuzz') {
      throw 'CI manifest is missing soak DUnitX category arguments.'
    }
  }
  default {
    throw 'CI manifest has an unknown DUnitX category mode.'
  }
}
if ($RequireReleaseCorpus) {
  if ($configurationPropertyNames -notcontains 'trackedTreeCleanAtStart' -or
      $configurationPropertyNames -notcontains 'trackedTreeStartStatus') {
    throw 'CI manifest is missing tracked tree preflight evidence.'
  }
  $trackedTreeStartStatus = ConvertTo-StringList $ciManifest.configuration.trackedTreeStartStatus
  if ([bool]$ciManifest.configuration.trackedTreeCleanAtStart -ne $true -or
      $trackedTreeStartStatus.Count -gt 0) {
    $firstStartStatus = if ($trackedTreeStartStatus.Count -gt 0) { $trackedTreeStartStatus[0] } else { '<none recorded>' }
    throw "CI manifest does not prove a clean tracked tree at CI start. First change: $firstStartStatus"
  }
  if ($configurationPropertyNames -notcontains 'validationStartUtc' -or
      [string]::IsNullOrWhiteSpace([string]$ciManifest.configuration.validationStartUtc)) {
    throw 'CI manifest is missing validation start UTC.'
  }
  try {
    [void][DateTimeOffset]::Parse(
      [string]$ciManifest.configuration.validationStartUtc,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal)
  } catch {
    throw 'CI manifest has invalid validation start UTC.'
  }
}
$ciBenchmarkWorkRoot = Get-ReleaseBenchmarkWorkRoot $ciManifest.configuration
if (-not [string]::IsNullOrWhiteSpace([string]$ciBenchmarkWorkRoot.Path)) {
  Assert-CiBenchmarkWorkRoot ([string]$ciBenchmarkWorkRoot.Path) ([bool]$ciBenchmarkWorkRoot.RamBacked)
}
if ([string]::IsNullOrWhiteSpace([string]$ciManifest.configuration.branch) -or
    [string]$ciManifest.configuration.branch -eq 'HEAD') {
  throw 'CI manifest is missing the git branch.'
}
if ([string]$ciManifest.configuration.commit -notmatch '^[0-9a-fA-F]{40}$') {
  throw 'CI manifest is missing the git commit SHA.'
}
$manifestCommit = ([string]$ciManifest.configuration.commit).ToLowerInvariant()
$currentCommit = Get-CurrentGitCommit
if ($currentCommit -match '^[0-9a-fA-F]{40}$' -and $manifestCommit -ne $currentCommit.ToLowerInvariant()) {
  throw "CI manifest git commit does not match current HEAD. Manifest=$manifestCommit HEAD=$currentCommit"
}
if (-not [string]::IsNullOrWhiteSpace([string]$ciManifest.configuration.githubSha) -and
    [string]$ciManifest.configuration.githubSha -notmatch '^[0-9a-fA-F]{40}$') {
  throw 'CI manifest has an invalid GitHub SHA.'
}
if ([string]$ciManifest.configuration.githubSha -match '^[0-9a-fA-F]{40}$' -and
    ([string]$ciManifest.configuration.githubSha).ToLowerInvariant() -ne $manifestCommit) {
  throw 'CI manifest GitHub SHA does not match the git commit SHA.'
}
$githubContextFields = @(
  [string]$ciManifest.configuration.githubRunId,
  [string]$ciManifest.configuration.githubRunAttempt,
  [string]$ciManifest.configuration.githubRef,
  [string]$ciManifest.configuration.githubSha,
  [string]$ciManifest.configuration.workflowName
)
$hasGithubRunContext = @($githubContextFields | Where-Object {
  -not [string]::IsNullOrWhiteSpace($_)
}).Count -gt 0
if ($RequireReleaseCorpus -and $hasGithubRunContext) {
  if ([string]$ciManifest.configuration.githubRunId -notmatch '^\d+$') {
    throw 'CI manifest is missing required release GitHub run id.'
  }
  if ([string]$ciManifest.configuration.githubRunAttempt -notmatch '^\d+$') {
    throw 'CI manifest is missing required release GitHub run attempt.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$ciManifest.configuration.githubRef)) {
    throw 'CI manifest is missing required release GitHub ref.'
  }
  if ([string]$ciManifest.configuration.githubSha -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'CI manifest is missing required release GitHub SHA.'
  }
  if ([string]::IsNullOrWhiteSpace([string]$ciManifest.configuration.workflowName)) {
    throw 'CI manifest is missing required release workflow name.'
  }
}
if ($RequireReleaseCorpus) {
  if ([string]::IsNullOrWhiteSpace([string]$ciManifest.configuration.runnerName) -or
      [string]::IsNullOrWhiteSpace([string]$ciManifest.configuration.runnerOS)) {
    throw 'CI manifest is missing required release runner metadata.'
  }
}
$trackedStatus = @(Get-TrackedGitStatus)
if ($RequireReleaseCorpus -and $trackedStatus.Count -gt 0) {
  throw "CI artifacts must be validated from a clean tracked working tree. First change: $($trackedStatus[0])"
}
if ($null -eq $ciManifest.compilerMessages) {
  throw 'CI manifest is missing compiler warning metadata.'
}
$compilerMessages = $ciManifest.compilerMessages
$compilerWarningCount = [int]$compilerMessages.warningCount
$compilerWarningBudget = [int]$compilerMessages.warningBudget
$compilerDeprecatedCount = [int]$compilerMessages.deprecatedCount
if ($compilerWarningCount -gt $compilerWarningBudget) {
  throw 'CI manifest compiler warning count exceeds the approved warning budget.'
}
if ($compilerDeprecatedCount -gt 0) {
  throw 'CI manifest deprecated compiler message count must be zero.'
}
if ($compilerWarningCount -gt 0) {
  $warningLines = ConvertTo-StringList $compilerMessages.warnings
  if ($warningLines.Count -lt $compilerWarningCount) {
    throw 'CI manifest compiler warning metadata is missing warning lines.'
  }

  $approvedWarnings = @()
  if ($compilerMessages.PSObject.Properties.Name -contains 'approvedWarnings') {
    $approvedWarnings += @($compilerMessages.approvedWarnings)
  }
  if ($compilerMessages.PSObject.Properties.Name -contains 'approvedWarningList') {
    $approvedWarnings += @($compilerMessages.approvedWarningList)
  }
  if ($approvedWarnings.Count -eq 0) {
    throw 'CI manifest compiler warnings require an approved-warning list.'
  }

  if ($compilerMessages.PSObject.Properties.Name -contains 'approvedWarningsCount' -and
      [int]$compilerMessages.approvedWarningsCount -ne $approvedWarnings.Count) {
    throw 'CI manifest approved-warning count does not match the approved-warning list.'
  }

  if ($compilerMessages.PSObject.Properties.Name -contains 'approvedWarningsPath' -and
      -not [string]::IsNullOrWhiteSpace([string]$compilerMessages.approvedWarningsPath)) {
    $approvedWarningsPath = Join-Path $root ([string]$compilerMessages.approvedWarningsPath)
    if (-not (Test-Path -LiteralPath $approvedWarningsPath)) {
      throw 'CI manifest approved-warning list file is missing.'
    }
    if ($compilerMessages.PSObject.Properties.Name -contains 'approvedWarningsSha256' -and
        -not [string]::IsNullOrWhiteSpace([string]$compilerMessages.approvedWarningsSha256)) {
      $approvedWarningsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $approvedWarningsPath).Hash.ToLowerInvariant()
      if ($approvedWarningsHash -ne ([string]$compilerMessages.approvedWarningsSha256).ToLowerInvariant()) {
        throw 'CI manifest approved-warning list SHA-256 mismatch.'
      }
    }
  }

  foreach ($warningLine in $warningLines) {
    $covered = $false
    foreach ($approvedWarning in $approvedWarnings) {
      if (Test-ApprovedWarningEntry $warningLine $approvedWarning) {
        $covered = $true
        break
      }
    }
    if (-not $covered) {
      throw "CI manifest compiler warning is not covered by the approved-warning list: $warningLine"
    }
  }
}

function Require-CiToolPath($ToolRecord, [string]$ToolName, [bool]$Required) {
  if ($null -eq $ToolRecord) {
    if ($Required) {
      throw "CI manifest is missing required $ToolName tool record."
    }
    return
  }

  if ($Required -and -not [bool]$ToolRecord.available) {
    throw "CI manifest is missing required $ToolName tool record."
  }

  if ([bool]$ToolRecord.available -and
      [string]::IsNullOrWhiteSpace([string]$ToolRecord.path)) {
    throw "CI manifest is missing required $ToolName tool path."
  }
}

if (-not $ciManifest.tools.dcc64.available -or -not $ciManifest.tools.msbuild.available) {
  throw 'CI manifest is missing compiler/MSBuild tool versions.'
}
Require-CiToolPath $ciManifest.tools.dcc64 'Delphi compiler' $true
Require-CiToolPath $ciManifest.tools.msbuild 'MSBuild' $true
Require-CiToolPath $ciManifest.tools.sevenZip '7-Zip' ([bool]$RequireExternalTools)
Require-CiToolPath $ciManifest.tools.xz 'external xz-utils' ([bool]$RequireExternalTools)
Require-CiToolPath $ciManifest.tools.lzma 'external lzma.exe' ([bool]$RequireExternalTools)
Assert-PinnedQAToolEvidence $ciManifest.tools.sevenZip 'sevenZip' ([bool]$RequireExternalTools) 'CI manifest'
Assert-PinnedQAToolEvidence $ciManifest.tools.xz 'xz' ([bool]$RequireExternalTools) 'CI manifest'
Assert-PinnedQAToolEvidence $ciManifest.tools.lzma 'lzma' ([bool]$RequireExternalTools) 'CI manifest'

if ($ciManifest.tools.dcc64.version -notmatch 'Delphi') {
  throw 'CI manifest has an unexpected Delphi compiler version record.'
}
if ($ciManifest.tools.sevenZip.available -and $ciManifest.tools.sevenZip.version -notmatch '7-Zip') {
  throw 'CI manifest has an unexpected 7-Zip version record.'
}
if ($ciManifest.tools.sevenZip.available -and
    $ciManifest.tools.sevenZip.version -notmatch $expectedLzmaSdkVersionPattern) {
  throw 'CI manifest must use 7-Zip/LZMA SDK 26.01.'
}
if ($ciManifest.tools.xz.available -and $ciManifest.tools.xz.version -notmatch 'XZ Utils|xz') {
  throw 'CI manifest has an unexpected xz-utils version record.'
}
if ($ciManifest.tools.lzma.available -and $ciManifest.tools.lzma.version -notmatch 'LZMA') {
  throw 'CI manifest has an unexpected lzma.exe version record.'
}
if ($ciManifest.tools.lzma.available -and
    $ciManifest.tools.lzma.version -notmatch $expectedLzmaSdkVersionPattern) {
  throw 'CI manifest must use LZMA SDK 26.01 lzma.exe.'
}
$requiredManifestArtifactPaths = @(
  'artifacts/fixtures/sha256-fixtures.json',
  'artifacts/memory/fastmm-report.txt',
  'artifacts/test-results/Lzma.Tests.console.txt',
  'artifacts/test-results/Lzma.Tests.junit.xml',
  'artifacts/ci/compiler-warnings.json'
)
if ($ShouldValidatePerformanceArtifacts) {
  $requiredManifestArtifactPaths = $requiredManifestArtifactPaths + $requiredPerformanceArtifactPaths
}
if ($RequireExternalTools -or $compatPath) {
  $requiredManifestArtifactPaths = @('artifacts/compat/xz-cross-tool-report.json') + $requiredManifestArtifactPaths
}
$manifestArtifactPaths = @($ciManifest.artifacts | ForEach-Object {
  ([string]$_.path) -replace '\\', '/'
})
foreach ($artifactPath in $manifestArtifactPaths) {
  foreach ($forbiddenPattern in $ForbiddenGraphArtifactPatterns) {
    if ($artifactPath -like $forbiddenPattern) {
      throw "CI manifest must not include graph artifact record: $artifactPath"
    }
  }
}
$perfArtifactDir = Join-Path $artifacts 'perf'
if (Test-Path -LiteralPath $perfArtifactDir) {
  $leftoverForbiddenArtifacts = @(Get-ChildItem -LiteralPath $perfArtifactDir -Recurse -File | Where-Object {
    $artifactPath = Get-RepoRelativePath $_.FullName
    $matchesForbiddenArtifact = $false
    foreach ($forbiddenPattern in $ForbiddenGraphArtifactPatterns) {
      if ($artifactPath -like $forbiddenPattern) {
        $matchesForbiddenArtifact = $true
        break
      }
    }
    $matchesForbiddenArtifact
  })
  if ($leftoverForbiddenArtifacts.Count -gt 0) {
    throw 'Validation must not leave graph artifacts in artifacts/perf or image artifacts in artifacts/perf.'
  }
  if (Test-Path -LiteralPath (Join-Path $perfArtifactDir 'lzma2-benchmark.md')) {
    throw 'Validation must not leave benchmark Markdown artifacts in artifacts/perf.'
  }
  $actualPerfArtifactPaths = @(Get-ChildItem -LiteralPath $perfArtifactDir -Recurse -File | ForEach-Object {
    Get-RepoRelativePath $_.FullName
  })
  foreach ($artifactPath in $actualPerfArtifactPaths) {
    if ($requiredPerformanceArtifactPaths -notcontains $artifactPath) {
      throw "Validation found unexpected performance artifact outside data-only allowlist: $artifactPath"
    }
  }
}
foreach ($artifactPath in $manifestArtifactPaths) {
  if ($artifactPath -like 'artifacts/perf/*' -and
      $requiredPerformanceArtifactPaths -notcontains $artifactPath) {
    throw "CI manifest violates performance artifact allowlist: $artifactPath"
  }
}
if ($RequireReleaseCorpus) {
  $releasePerfArtifactAllowlist = @(
    'artifacts/perf/lzma2-benchmark.csv',
    'artifacts/perf/lzma2-benchmark.json',
    'artifacts/perf/lzma2-benchmark.samples.csv',
    'artifacts/perf/lzma2-benchmark.summary.json'
  )
  foreach ($artifactPath in $manifestArtifactPaths) {
    if ($artifactPath -like 'artifacts/perf/*' -and
        $releasePerfArtifactAllowlist -notcontains $artifactPath) {
      throw "CI manifest violates release performance artifact allowlist: $artifactPath"
    }
  }
  if (Test-Path -LiteralPath $perfArtifactDir) {
    $actualPerfArtifactPaths = @(Get-ChildItem -LiteralPath $perfArtifactDir -Recurse -File | ForEach-Object {
      Get-RepoRelativePath $_.FullName
    })
    foreach ($artifactPath in $actualPerfArtifactPaths) {
      if ($releasePerfArtifactAllowlist -notcontains $artifactPath) {
        throw "Release validation violates release performance artifact allowlist: $artifactPath"
      }
    }
  }
}
foreach ($requiredArtifactPath in $requiredManifestArtifactPaths) {
  if ($manifestArtifactPaths -notcontains $requiredArtifactPath) {
    throw "CI manifest is missing required artifact record: $requiredArtifactPath"
  }
}
if (($ciManifest.artifacts | Measure-Object).Count -lt $requiredManifestArtifactPaths.Count) {
  throw 'CI manifest does not enumerate the expected artifact bundle.'
}
foreach ($artifactRecord in $ciManifest.artifacts) {
  $artifactPath = Join-Path $root ([string]$artifactRecord.path -replace '/', '\')
  if (-not (Test-Path -LiteralPath $artifactPath)) {
    throw "CI manifest artifact is missing: $($artifactRecord.path)"
  }
  $artifactFile = Get-Item -LiteralPath $artifactPath
  if ([int64]$artifactRecord.bytes -ne [int64]$artifactFile.Length) {
    throw "CI manifest artifact byte count mismatch for $($artifactRecord.path)"
  }
  $actualArtifactHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()
  if ($actualArtifactHash -ne ([string]$artifactRecord.sha256).ToLowerInvariant()) {
    throw "CI manifest artifact hash mismatch for $($artifactRecord.path)"
  }
}

Write-Host "Artifact validation passed for $artifacts"
