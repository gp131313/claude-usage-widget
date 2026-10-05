# install.ps1 — установка Claude Usage Widget для текущего пользователя (без прав администратора).
# Запускается из Setup.cmd. Что делает:
#   1) копирует виджет в %LOCALAPPDATA%\ClaudeUsageWidget;
#   2) если нет входа в Claude Code — предлагает поставить Claude Code (официальный установщик) и войти;
#   3) включает автозапуск, создаёт ярлыки в меню «Пуск», регистрирует виджет в «Приложениях», запускает его.
# -Silent: без единого окна и без шага входа в Claude (ошибка — в %TEMP%\ClaudeUsageWidget-install.log).
# -NoFinishBox: без итогового окна «Готово» (его показывает мастер установки). -NoAutostart: без автозапуска.
# -Dir: папка установки (по умолчанию %LOCALAPPDATA%\ClaudeUsageWidget).
param([switch]$Silent, [switch]$NoFinishBox, [switch]$NoAutostart, [string]$Dir)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$Title = 'Claude Usage Widget'
$Version = '1.3.1'
function Say([string]$m, [string]$icon = 'Information') { if ($Silent) { return }; [void][System.Windows.Forms.MessageBox]::Show($m, $Title, 'OK', $icon) }
function Ask([string]$m) { if ($Silent) { return $false }; [System.Windows.Forms.MessageBox]::Show($m, $Title, 'YesNo', 'Question') -eq 'Yes' }

try {
    $src = $PSScriptRoot
    $dst = if ($Dir) { $Dir } else { Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget' }
    $inPlace = ([IO.Path]::GetFullPath($src).TrimEnd('\') -eq [IO.Path]::GetFullPath($dst).TrimEnd('\'))   # exe-установщик распаковывает сразу в папку установки
    foreach ($f in 'ClaudeUsageWidget.ps1', 'ClaudeUsageWidget.vbs', 'uninstall.ps1') {
        if (-not (Test-Path (Join-Path $src $f))) { throw "Не найден файл $f. Распакуйте архив целиком и запустите Setup.cmd из распакованной папки." }
    }

    # 1. остановить запущенный виджет (повторная установка / обновление)
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -like '*ClaudeUsageWidget.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500

    # 2. скопировать файлы (настройки ClaudeUsageWidget.json при обновлении сохраняются)
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($f in 'ClaudeUsageWidget.ps1', 'ClaudeUsageWidget.vbs', 'uninstall.ps1') {
        if (-not $inPlace) { Copy-Item (Join-Path $src $f) (Join-Path $dst $f) -Force }
    }
    Get-ChildItem $dst -File | Unblock-File   # снять пометку «скачано из интернета»

    # 3. вход в Claude: виджет берёт данные из файла входа Claude Code
    $credBase = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    $cred = Join-Path $credBase '.credentials.json'
    function Find-Claude {
        $p = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
        if (Test-Path $p) { return $p }
        $c = Get-Command claude -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        return $null
    }
    if (-not $Silent -and -not (Test-Path $cred)) {
        $claude = Find-Claude
        if (-not $claude) {
            $ok = Ask ("Виджету нужен вход в ваш аккаунт Claude через программу Claude Code (официальная, от Anthropic).`n`n" +
                       "Claude Code не найден. Установить его сейчас? Потребуется интернет, 1–2 минуты.")
            if ($ok) {
                if (-not (Get-Command git -ErrorAction SilentlyContinue) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                    # Claude Code под Windows использует Git for Windows
                    Start-Process winget -ArgumentList 'install', '--id', 'Git.Git', '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements' -Wait
                }
                Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://claude.ai/install.ps1 | iex' -Wait
                $claude = Find-Claude
                if (-not $claude) { Say 'Не удалось установить Claude Code. Виджет будет установлен, но покажет «Войдите в Claude», пока вы не войдёте (правый клик по виджету → «Войти в аккаунт Claude…»).' 'Warning' }
            }
        }
        if ($claude) {
            Say ("Сейчас откроется окно Claude Code.`n`n" +
                 "1. Выберите вход через аккаунт Claude (подписка Pro/Max).`n" +
                 "2. Войдите в браузере и разрешите доступ.`n" +
                 "3. Когда увидите приглашение Claude Code — закройте его окно и нажмите здесь OK.")
            Start-Process $claude -WorkingDirectory $env:USERPROFILE
            Say 'Нажмите OK, когда вход будет выполнен.'
            while (-not (Test-Path $cred)) {
                if (-not (Ask 'Вход пока не обнаружен. Подождать ещё? (Нет — продолжить без входа; войти можно позже через правый клик по виджету.)')) { break }
            }
        }
    }

    # 4. автозапуск и ярлыки в меню «Пуск»
    $vbs = Join-Path $dst 'ClaudeUsageWidget.vbs'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($NoAutostart) { Remove-ItemProperty -Path $runKey -Name 'ClaudeUsageWidget' -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $runKey -Name 'ClaudeUsageWidget' -Value ('wscript.exe "{0}"' -f $vbs) }
    $sh = New-Object -ComObject WScript.Shell
    $programs = [Environment]::GetFolderPath('Programs')
    $lnk = $sh.CreateShortcut((Join-Path $programs 'Claude Usage Widget.lnk'))
    $lnk.TargetPath = 'wscript.exe'; $lnk.Arguments = '"{0}"' -f $vbs; $lnk.WorkingDirectory = $dst
    $lnk.Description = 'Расход квоты Claude на панели задач'; $lnk.Save()
    $lnk = $sh.CreateShortcut((Join-Path $programs 'Удалить Claude Usage Widget.lnk'))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $dst 'uninstall.ps1')
    $lnk.WorkingDirectory = $dst; $lnk.Save()

    # 5. запись в «Параметры → Приложения» (удаление штатным способом)
    $un = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $dst 'uninstall.ps1')
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeUsageWidget'
    New-Item -Path $reg -Force | Out-Null
    Set-ItemProperty -Path $reg -Name DisplayName -Value $Title
    Set-ItemProperty -Path $reg -Name DisplayVersion -Value $Version
    Set-ItemProperty -Path $reg -Name Publisher -Value 'gp131313'
    Set-ItemProperty -Path $reg -Name URLInfoAbout -Value 'https://github.com/gp131313/claude-usage-widget'
    Set-ItemProperty -Path $reg -Name InstallLocation -Value $dst
    Set-ItemProperty -Path $reg -Name UninstallString -Value $un
    Set-ItemProperty -Path $reg -Name QuietUninstallString -Value ($un + ' -Silent')
    Set-ItemProperty -Path $reg -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $reg -Name NoRepair -Value 1 -Type DWord
    Set-ItemProperty -Path $reg -Name EstimatedSize -Value 64 -Type DWord   # КБ

    # 6. запуск
    Start-Process wscript.exe -ArgumentList ('"{0}"' -f $vbs)
    if (-not $NoFinishBox) { Say ("Готово!`n`nВиджет появится на панели задач — слева от значков у часов.`n`n" +
         "Правый клик по виджету — настройки (выравнивание, вход в аккаунт).`n" +
         "Удалить: «Параметры» → «Приложения» или меню «Пуск» → «Удалить Claude Usage Widget».") }
}
catch {
    if ($Silent) { try { Add-Content -Path (Join-Path $env:TEMP 'ClaudeUsageWidget-install.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $_.Exception.Message) -Encoding UTF8 } catch {} }
    Say ("Установка не удалась:`n`n" + $_.Exception.Message) 'Error'
    exit 1
}
