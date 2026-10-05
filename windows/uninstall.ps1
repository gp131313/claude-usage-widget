# uninstall.ps1 — удаление Claude Usage Widget. Claude Code и вход в аккаунт не трогает.
# -Silent: без вопросов и окон (тихое удаление из «Приложений» / winget).
param([switch]$Silent)
Add-Type -AssemblyName System.Windows.Forms
$Title = 'Claude Usage Widget'
if (-not $Silent -and [System.Windows.Forms.MessageBox]::Show('Удалить Claude Usage Widget?', $Title, 'YesNo', 'Question') -ne 'Yes') { exit 0 }

$dst = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
    Where-Object { $_.CommandLine -like '*ClaudeUsageWidget.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ClaudeUsageWidget' -ErrorAction SilentlyContinue
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeUsageWidget' -Recurse -Force -ErrorAction SilentlyContinue
$programs = [Environment]::GetFolderPath('Programs')
Remove-Item (Join-Path $programs 'Claude Usage Widget.lnk'), (Join-Path $programs 'Удалить Claude Usage Widget.lnk') -Force -ErrorAction SilentlyContinue

# папку удаляем после выхода этого скрипта (он сам лежит внутри неё)
Start-Process cmd.exe -ArgumentList '/c', ('timeout /t 2 /nobreak >nul & rmdir /s /q "{0}"' -f $dst) -WindowStyle Hidden
if (-not $Silent) { [void][System.Windows.Forms.MessageBox]::Show('Claude Usage Widget удалён.', $Title, 'OK', 'Information') }
