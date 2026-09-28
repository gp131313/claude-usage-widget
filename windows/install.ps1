# install.ps1 — установка Claude Usage Widget для текущего пользователя (без прав администратора).
# Запускается из Setup.cmd. Что делает:
#   1) копирует виджет в %LOCALAPPDATA%\ClaudeUsageWidget;
#   2) если нет входа в Claude Code — предлагает поставить Claude Code (официальный установщик) и войти;
#   3) включает автозапуск, создаёт ярлыки в меню «Пуск», запускает виджет.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$Title = 'Claude Usage Widget'
function Say([string]$m, [string]$icon = 'Information') { [void][System.Windows.Forms.MessageBox]::Show($m, $Title, 'OK', $icon) }
function Ask([string]$m) { [System.Windows.Forms.MessageBox]::Show($m, $Title, 'YesNo', 'Question') -eq 'Yes' }

try {
    $src = $PSScriptRoot
    $dst = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
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
        Copy-Item (Join-Path $src $f) (Join-Path $dst $f) -Force
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
    if (-not (Test-Path $cred)) {
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
    Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'ClaudeUsageWidget' -Value ('wscript.exe "{0}"' -f $vbs)
    $sh = New-Object -ComObject WScript.Shell
    $programs = [Environment]::GetFolderPath('Programs')
    $lnk = $sh.CreateShortcut((Join-Path $programs 'Claude Usage Widget.lnk'))
    $lnk.TargetPath = 'wscript.exe'; $lnk.Arguments = '"{0}"' -f $vbs; $lnk.WorkingDirectory = $dst
    $lnk.Description = 'Расход квоты Claude на панели задач'; $lnk.Save()
    $lnk = $sh.CreateShortcut((Join-Path $programs 'Удалить Claude Usage Widget.lnk'))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $dst 'uninstall.ps1')
    $lnk.WorkingDirectory = $dst; $lnk.Save()

    # 5. запуск
    Start-Process wscript.exe -ArgumentList ('"{0}"' -f $vbs)
    Say ("Готово!`n`nВиджет появится на панели задач — слева от значков у часов.`n`n" +
         "Правый клик по виджету — настройки (вид, выравнивание, вход в аккаунт).`n" +
         "Удалить: меню «Пуск» → «Удалить Claude Usage Widget».")
}
catch {
    Say ("Установка не удалась:`n`n" + $_.Exception.Message) 'Error'
    exit 1
}
