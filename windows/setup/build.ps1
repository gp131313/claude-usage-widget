# build.ps1 - builds ClaudeUsageWidget-Setup.exe (single-file installer) with the C# compiler
# that ships with Windows (.NET Framework 4.x); no SDK needed. Output: windows\setup\out\.
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\setup\build.ps1
param([string[]]$Files = @('install.ps1', 'uninstall.ps1', 'ClaudeUsageWidget.ps1', 'ClaudeUsageWidget.vbs'))
$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe (.NET Framework 4.x) not found' }

$win = Split-Path $PSScriptRoot -Parent
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$exe = Join-Path $out 'ClaudeUsageWidget-Setup.exe'

# embedded resource name = file name the installer extracts
$res = foreach ($f in $Files) {
    $p = Join-Path $win $f
    if (-not (Test-Path $p)) { throw "missing $p" }
    '/resource:"{0}",{1}' -f $p, $f
}
& $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "/out:$exe" @res (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
# the silent installer is the same binary: it switches mode by its own file name
$silent = Join-Path $out 'ClaudeUsageWidget-Setup-Silent.exe'
Copy-Item $exe $silent -Force
foreach ($f in $exe, $silent) { '{0}  {1} bytes  sha256 {2}' -f $f, (Get-Item $f).Length, (Get-FileHash $f -Algorithm SHA256).Hash.ToLower() }
