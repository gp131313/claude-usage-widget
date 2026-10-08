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
$Version = '1.7.0'
# язык окон — по языку Windows: русский или английский
$Ru = ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru')
function T([string]$ru, [string]$en) { if ($Ru) { $ru } else { $en } }
# хост для ярлыков и деинсталлятора: PowerShell 7, если установлен; иначе Windows PowerShell 5.1
function Find-Pwsh {
    foreach ($p in (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')) { if (Test-Path $p) { return $p } }
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue; if ($c) { return $c.Source }
    return 'powershell.exe'
}
$PsExe = Find-Pwsh
function Say([string]$m, [string]$icon = 'Information') { if ($Silent) { return }; [void][System.Windows.Forms.MessageBox]::Show($m, $Title, 'OK', $icon) }
function Ask([string]$m) { if ($Silent) { return $false }; [System.Windows.Forms.MessageBox]::Show($m, $Title, 'YesNo', 'Question') -eq 'Yes' }

try {
    $src = $PSScriptRoot
    $dst = if ($Dir) { $Dir } else { Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget' }
    $inPlace = ([IO.Path]::GetFullPath($src).TrimEnd('\') -eq [IO.Path]::GetFullPath($dst).TrimEnd('\'))   # exe-установщик распаковывает сразу в папку установки
    foreach ($f in 'ClaudeUsageWidget.ps1', 'ClaudeUsageWidget.vbs', 'uninstall.ps1') {
        if (-not (Test-Path (Join-Path $src $f))) { throw (T "Не найден файл $f. Распакуйте архив целиком и запустите Setup.cmd из распакованной папки." "File $f not found. Unpack the whole archive and run Setup.cmd from the unpacked folder.") }
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
            $ok = Ask (T ("Виджету нужен вход в ваш аккаунт Claude через программу Claude Code (официальная, от Anthropic).`n`n" +
                          "Claude Code не найден. Установить его сейчас? Потребуется интернет, 1–2 минуты.") `
                         ("The widget needs you to be signed in to your Claude account through Claude Code (the official app by Anthropic).`n`n" +
                          "Claude Code was not found. Install it now? This needs an internet connection and takes 1–2 minutes."))
            if ($ok) {
                if (-not (Get-Command git -ErrorAction SilentlyContinue) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                    # Claude Code под Windows использует Git for Windows
                    Start-Process winget -ArgumentList 'install', '--id', 'Git.Git', '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements' -Wait
                }
                Start-Process $PsExe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'irm https://claude.ai/install.ps1 | iex' -Wait
                $claude = Find-Claude
                if (-not $claude) { Say (T 'Не удалось установить Claude Code. Виджет будет установлен, но покажет «Войдите в Claude», пока вы не войдёте (правый клик по виджету → «Войти в аккаунт Claude…»).' 'Claude Code could not be installed. The widget will be installed, but it will show "Sign in to Claude" until you sign in (right-click the widget → "Sign in to Claude…").') 'Warning' }
            }
        }
        if ($claude) {
            Say (T ("Сейчас откроется окно Claude Code.`n`n" +
                    "1. Выберите вход через аккаунт Claude (подписка Pro/Max).`n" +
                    "2. Войдите в браузере и разрешите доступ.`n" +
                    "3. Когда увидите приглашение Claude Code — закройте его окно и нажмите здесь OK.") `
                   ("A Claude Code window will open now.`n`n" +
                    "1. Choose to sign in with your Claude account (Pro/Max subscription).`n" +
                    "2. Sign in in the browser and allow access.`n" +
                    "3. When you see the Claude Code prompt, close its window and click OK here."))
            Start-Process $claude -WorkingDirectory $env:USERPROFILE
            Say (T 'Нажмите OK, когда вход будет выполнен.' 'Click OK once you have signed in.')
            while (-not (Test-Path $cred)) {
                if (-not (Ask (T 'Вход пока не обнаружен. Подождать ещё? (Нет — продолжить без входа; войти можно позже через правый клик по виджету.)' 'No sign-in detected yet. Keep waiting? (No — continue without signing in; you can sign in later by right-clicking the widget.)'))) { break }
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
    $lnk.Description = (T 'Расход квоты Claude на панели задач' 'Claude usage on the taskbar'); $lnk.Save()
    Remove-Item (Join-Path $programs 'Удалить Claude Usage Widget.lnk'), (Join-Path $programs 'Uninstall Claude Usage Widget.lnk') -Force -ErrorAction SilentlyContinue   # ярлык на другом языке от прошлой установки
    $lnk = $sh.CreateShortcut((Join-Path $programs (T 'Удалить Claude Usage Widget.lnk' 'Uninstall Claude Usage Widget.lnk')))
    $lnk.TargetPath = $PsExe
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $dst 'uninstall.ps1')
    $lnk.WorkingDirectory = $dst; $lnk.Save()

    # 5. запись в «Параметры → Приложения» (удаление штатным способом)
    $un = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $PsExe, (Join-Path $dst 'uninstall.ps1')
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
    if (-not $NoFinishBox) { Say (T ("Готово!`n`nВиджет появится на панели задач — слева от значков у часов.`n`n" +
         "Правый клик по виджету — настройки (выравнивание, вход в аккаунт).`n" +
         "Удалить: «Параметры» → «Приложения» или меню «Пуск» → «Удалить Claude Usage Widget».") `
        ("Done!`n`nThe widget will appear on the taskbar, to the left of the icons near the clock.`n`n" +
         "Right-click the widget for settings (alignment, sign-in).`n" +
         "To uninstall: Settings → Apps, or Start menu → Uninstall Claude Usage Widget.")) }
}
catch {
    if ($Silent) { try { Add-Content -Path (Join-Path $env:TEMP 'ClaudeUsageWidget-install.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $_.Exception.Message) -Encoding UTF8 } catch {} }
    Say ((T "Установка не удалась:`n`n" "Installation failed:`n`n") + $_.Exception.Message) 'Error'
    exit 1
}
