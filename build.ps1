param(
    [ValidateSet('All','GUI','CLI')][string]$Target='All',
    [string]$DelphiRoot='C:\Program Files (x86)\Embarcadero\Studio\37.0',
    [string]$OutputRoot=(Join-Path $PSScriptRoot 'out'),
    [ValidateSet('Win32','Win64')][string]$Platform='Win64'
)
$ErrorActionPreference='Stop'
$compilerName=if($Platform -eq 'Win32'){'dcc32.exe'}else{'dcc64.exe'}
$compiler=Join-Path $DelphiRoot ('bin\'+$compilerName)
$resourceCompiler=Join-Path $DelphiRoot 'bin\brcc32.exe'
$library=Join-Path $DelphiRoot ('lib\'+$Platform.ToLowerInvariant()+'\release')
foreach($file in @($compiler,$resourceCompiler)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing Delphi 13.2 tool: $file"}}
$output=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $output){throw "Choose a fresh output directory: $output"}
New-Item -ItemType Directory -Path (Join-Path $output 'bin') -Force|Out-Null
$tools=Join-Path $PSScriptRoot 'tools'
$source=Join-Path $PSScriptRoot 'src'
$resource=Join-Path $tools 'Lzma2GUIManifest.res'
$createdResource=$false
Push-Location $tools
try {
    if($Target-in@('All','GUI')) {
        if(Test-Path -LiteralPath $resource){throw 'A generated GUI resource already exists; finish the other build first'}
        & $resourceCompiler (Join-Path $tools 'Lzma2GUIManifest.rc') *> (Join-Path $output 'resource.log')
        if($LASTEXITCODE-ne0){throw 'Resource build failed; see resource.log'}
        $createdResource=$true
    }
    $names=if($Target-eq'All'){@('Lzma2','Lzma2_GUI')}elseif($Target-eq'GUI'){@('Lzma2_GUI')}else{@('Lzma2')}
    foreach($name in $names) {
        $objects=Join-Path $output ('objects\'+$name)
        New-Item -ItemType Directory -Path $objects -Force|Out-Null
        $arguments=@('--no-config','-Q','-B','-NSSystem;System.Win;Winapi;Vcl;Data;Xml',
            ('-I'+$source),('-U'+$source+';'+$library),('-N0'+$objects),('-NH'+$objects),
            ('-NO'+$objects),('-NB'+$objects),'-DLZMA_MF_NATIVE_COMPACT_COLLECT',
            ('-E'+(Join-Path $output 'bin')),'-GD','-$O+','-$R-','-$Q-','-$C+',
            '-$D-','-$L-','-$Y-','-$W-',(Join-Path $tools ($name+'.dpr')))
        & $compiler @arguments *> (Join-Path $output ($name+'.log'))
        if($LASTEXITCODE-ne0){throw "Build failed: $name; see $output"}
        if([IO.File]::ReadAllText((Join-Path $output ($name+'.log')))-match'(?im)\b(?:Warning|Fatal|Error|deprecated)\b|\b[EFW]\d{4}\b'){throw "Compiler diagnostics require review: $name"}
    }
    Get-ChildItem -LiteralPath (Join-Path $output 'bin') -Filter '*.exe'|Get-FileHash -Algorithm SHA256
} finally {
    Pop-Location
    if($createdResource){Remove-Item -LiteralPath $resource}
}
