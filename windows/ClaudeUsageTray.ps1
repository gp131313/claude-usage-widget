# ClaudeUsageTray.ps1 — светофор расхода квоты Claude в трее.
# Берёт http://<CT 102>:8766/usage.json (сервис claude-usage на Сервере Claude Code),
# два кружка: «5ч» — осталось % в 5-часовом окне (цвет: линейный план к сбросу);
# «Неделя» — сколько% Fable ещё можно потратить сегодня (цвет: план 100 % к пт 22:00).
# Подсказка и меню: Fable / неделя / 5-часовое окно. Запуск: pwsh -WindowStyle Hidden -File <этот файл>.

param(
    [string]$Url = 'http://SERVER:8766/usage.json',
    [int]$IntervalSec = 60
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Name NativeIcon -Namespace Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);'

$LogPath = Join-Path $PSScriptRoot 'ClaudeUsageTray.log'
function Log([string]$m) {
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 512KB) { Remove-Item $LogPath -Force }
        Add-Content -Path $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) -Encoding utf8
    } catch {}
}

# один экземпляр
$mutex = New-Object System.Threading.Mutex -ArgumentList $false, 'Local\ClaudeUsageTray'
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

$Colors = @{
    green  = [System.Drawing.Color]::FromArgb(46, 204, 64)
    yellow = [System.Drawing.Color]::FromArgb(255, 220, 0)
    red    = [System.Drawing.Color]::FromArgb(255, 65, 54)
    gray   = [System.Drawing.Color]::FromArgb(160, 160, 160)
}

function New-CircleIcon([string]$colorName, [string]$text) {
    $bg = $Colors[$colorName]; if (-not $bg) { $bg = $Colors.gray }
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $bg
    $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
    $pen = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(90, 0, 0, 0)), ([single]1.5)
    $g.DrawEllipse($pen, 1, 1, $size - 3, $size - 3)
    if ($text) {
        $fontSize = if ($text.Length -ge 3) { 13 } else { 17 }
        $font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', ([single]$fontSize), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $fg = if ($colorName -eq 'yellow') { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
        $tb = New-Object System.Drawing.SolidBrush $fg
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $rect = New-Object System.Drawing.RectangleF -ArgumentList ([single]0), ([single]0), ([single]$size), ([single]$size)
        $g.DrawString($text, $font, $tb, $rect, $fmt)
        $font.Dispose(); $tb.Dispose(); $fmt.Dispose()
    }
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
    [Win32.NativeIcon]::DestroyIcon($h) | Out-Null
    $bmp.Dispose()
    return $icon
}

function New-TimeIcon([string]$colorName, [string]$hh, [string]$mm) {
    # значок-часы: две строки цифр (часы / минуты) цветом светофора, без кружка
    $fg = $Colors[$colorName]; if (-not $fg) { $fg = $Colors.gray }
    $size = 32
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)
    $font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', ([single]17), ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $tb = New-Object System.Drawing.SolidBrush $fg
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($hh, $font, $tb, (New-Object System.Drawing.RectangleF -ArgumentList ([single]0), ([single]-1), ([single]$size), ([single]17)), $fmt)
    $g.DrawString($mm, $font, $tb, (New-Object System.Drawing.RectangleF -ArgumentList ([single]0), ([single]15), ([single]$size), ([single]17)), $fmt)
    $font.Dispose(); $tb.Dispose(); $fmt.Dispose(); $g.Dispose()
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
    [Win32.NativeIcon]::DestroyIcon($h) | Out-Null
    $bmp.Dispose()
    return $icon
}

function Fmt([object]$v, [int]$d = 0) {
    if ($null -eq $v) { return '—' }
    return ([double]$v).ToString("F$d", [Globalization.CultureInfo]::GetCultureInfo('ru-RU'))
}
function Signed([object]$v) {
    if ($null -eq $v) { return '—' }
    $x = [math]::Round([double]$v)
    if ($x -gt 0) { return "+$x" } else { return "$x" }
}

$script:State = @{ data = $null; err = $null }

function Get-Usage {
    try {
        $r = Invoke-RestMethod -Uri $Url -TimeoutSec 8
        $script:State.data = $r; $script:State.err = $null
    } catch {
        $script:State.err = $_.Exception.Message
        Log "fetch error: $($_.Exception.Message)"
    }
}

function Lines-Session {
    $d = $script:State.data
    if ($null -eq $d) { return @("Нет связи с сервером usage", "$($script:State.err)") }
    $s = $d.session; $lines = @()
    if (-not $s) { return @("5-часовое окно: нет данных") }
    if (-not $s.active) { return @("5-часовое окно не начато (0%)") }
    $ra = $s.resets_at
    $resetLocal = if ($ra -is [datetime]) { $ra.ToLocalTime() } else { ([datetimeoffset]::Parse([string]$ra)).LocalDateTime }
    $lines += "Осталось {0}% до {1}" -f (Fmt $s.remaining_pct), $resetLocal.ToString('HH:mm')
    if ($d.stale) { $lines += "ДАННЫЕ УСТАРЕЛИ ({0} мин): {1}" -f [math]::Round($d.data_age_sec / 60), $d.error }
    return $lines
}

function Lines-Weekly {
    $d = $script:State.data
    if ($null -eq $d) { return @("Нет связи с сервером usage", "$($script:State.err)") }
    $lines = @()
    if ($d.fable) {
        $f = $d.fable
        $lines += "Fable: {0}% (план {1}%, {2}%)" -f (Fmt $f.used_pct), (Fmt $f.target_now_pct), (Signed $f.delta_pp)
        $lines += "Сегодня до {0}: ещё {1}% · не больше {2}%/сут до пт" -f ([datetime]$f.day_end_local).ToString('HH:mm'), (Fmt $f.available_today_pp 1), (Fmt $f.needed_per_day_pp 1)
    }
    if ($d.weekly) {
        $w = $d.weekly
        $lines += "Неделя (все модели): {0}% (план {1}%, {2}%) · сегодня ещё {3}%" -f (Fmt $w.used_pct), (Fmt $w.target_now_pct), (Signed $w.delta_pp), (Fmt $w.available_today_pp 1)
    }
    if ($d.stale) { $lines += "ДАННЫЕ УСТАРЕЛИ ({0} мин): {1}" -f [math]::Round($d.data_age_sec / 60), $d.error }
    if ($d.breakdown) {
        $lines += "Неделя по поверхностям: " + (($d.breakdown | Where-Object { $_.percent -gt 0 } | ForEach-Object { "$($_.display_name) $($_.percent)%" }) -join ', ')
    }
    return $lines
}

function Set-Tray($tray, [string]$color, [string]$text, [string[]]$lines, [string]$prefix) {
    $old = $tray.Icon.Icon
    $tray.Icon.Icon = New-CircleIcon $color $text
    if ($old) { $old.Dispose() }
    $tip = $prefix + (($lines | Select-Object -First 3) -join "`n")
    if ($tip.Length -gt 127) { $tip = $tip.Substring(0, 124) + '...' }
    $tray.Icon.Text = $tip
    for ($i = 0; $i -lt $tray.Info.Count; $i++) {
        $tray.Info[$i].Text = if ($i -lt $lines.Count) { $lines[$i] } else { '' }
        $tray.Info[$i].Visible = ($i -lt $lines.Count)
    }
    if ($tray.LastColor -and $color -ne $tray.LastColor -and $color -in @('red', 'yellow')) {
        $tray.Icon.ShowBalloonTip(8000, "Claude: $prefix", ($lines | Select-Object -First 3) -join "`n", 'Warning')
    }
    $tray.LastColor = $color
}

function Update-Ui {
    Get-Usage
    $d = $script:State.data
    # --- 5-часовое окно: цифра = осталось % до сброса
    $cs = 'gray'; $ts = '?'
    if ($d -and $d.session) {
        $cs = if ($d.stale) { 'gray' } elseif ($d.color_session) { [string]$d.color_session } else { 'gray' }
        $n = [math]::Round([double]$d.session.remaining_pct); if ($n -gt 99) { $n = 99 }
        $ts = "$n"
    }
    Set-Tray $script:TraySession $cs $ts (Lines-Session) ""
    # --- значок-часы: время сброса 5-часового окна
    $hh = '--'; $mm = '--'
    if ($d -and $d.session -and $d.session.active -and $d.session.resets_at) {
        $ra = $d.session.resets_at
        $rl = if ($ra -is [datetime]) { $ra.ToLocalTime() } else { ([datetimeoffset]::Parse([string]$ra)).LocalDateTime }
        $hh = $rl.ToString('HH'); $mm = $rl.ToString('mm')
    }
    $old = $script:TrayTime.Icon.Icon
    $script:TrayTime.Icon.Icon = New-TimeIcon $cs $hh $mm
    if ($old) { $old.Dispose() }
    $script:TrayTime.Icon.Text = ((Lines-Session) | Select-Object -First 1)
    # --- неделя: цифра = сколько% Fable ещё можно потратить сегодня
    $cw = 'gray'; $tw = '?'
    if ($d -and $d.fable) {
        $cw = if ($d.stale) { 'gray' } elseif ($d.color_weekly) { [string]$d.color_weekly } else { 'gray' }
        $n = [math]::Round([double]$d.fable.available_today_pp); if ($n -gt 99) { $n = 99 }; if ($n -lt -99) { $n = -99 }
        $tw = "$n"
    }
    Set-Tray $script:TrayWeek $cw $tw (Lines-Weekly) "Неделя: "
}

# ---------- UI ----------
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName = 'ClaudeUsageTray'
$PwshExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'   # стабильный алиас Store-версии
if (-not (Test-Path $PwshExe)) { $PwshExe = (Get-Process -Id $PID).Path }
$RunCmd = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $PwshExe, $PSCommandPath

function New-Tray([string]$title) {
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = New-CircleIcon 'gray' '…'
    $ni.Text = "${title}: загрузка"
    $ni.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $hdr = New-Object System.Windows.Forms.ToolStripMenuItem $title
    $hdr.Enabled = $false; $hdr.Font = New-Object System.Drawing.Font -ArgumentList $menu.Font, ([System.Drawing.FontStyle]::Bold)
    $menu.Items.Add($hdr) | Out-Null
    $info = @()
    for ($i = 0; $i -lt 6; $i++) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem
        $it.Enabled = $false
        $menu.Items.Add($it) | Out-Null
        $info += $it
    }
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Обновить сейчас'; $mi.Add_Click({ Update-Ui }); $menu.Items.Add($mi) | Out-Null
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Открыть панель usage на claude.ai'; $mi.Add_Click({ Start-Process 'https://claude.ai/settings/usage' }); $menu.Items.Add($mi) | Out-Null
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Открыть usage.json'; $mi.Add_Click({ Start-Process $Url }); $menu.Items.Add($mi) | Out-Null
    $miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Автозапуск'
    $miAuto.CheckOnClick = $true
    $miAuto.Checked = [bool](Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue)
    $miAuto.Add_Click({
        if ($this.Checked) { Set-ItemProperty -Path $RunKey -Name $RunName -Value $RunCmd }
        else { Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue }
    })
    $menu.Items.Add($miAuto) | Out-Null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Выход'; $mi.Add_Click({ [System.Windows.Forms.Application]::Exit() }); $menu.Items.Add($mi) | Out-Null
    $ni.ContextMenuStrip = $menu
    $ni.Add_DoubleClick({ Start-Process 'https://claude.ai/settings/usage' })
    return [pscustomobject]@{ Icon = $ni; Info = $info; LastColor = $null }
}

# порядок создания = порядок в трее (обычно): сначала неделя, потом 5ч
$script:TrayWeek = New-Tray 'Неделя (Fable / все модели)'
$script:TraySession = New-Tray '5-часовое окно'
$script:TrayTime = New-Tray 'Сброс 5-часового окна'

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalSec * 1000
$timer.Add_Tick({ Update-Ui })
$timer.Start()

Log "start pid=$PID url=$Url"
Update-Ui
try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    foreach ($t in @($script:TrayWeek, $script:TraySession, $script:TrayTime)) { $t.Icon.Visible = $false; $t.Icon.Dispose() }
    $mutex.ReleaseMutex() | Out-Null
    Log 'exit'
}
