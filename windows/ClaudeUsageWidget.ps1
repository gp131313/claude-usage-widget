# ClaudeUsageWidget.ps1 — мини-виджет расхода квоты Claude поверх панели задач.
# Данные: http://<CT 102>:8766/usage.json. Две строки: 5-часовое окно и неделя (Fable).
# Режимы (двойной клик / меню): 'light' — светофор-кружок, 'bar' — убывающий прогресс-бар (100% = пусто).
# Окно без рамки, поверх всех, перетаскивается; позиция и режим — в ClaudeUsageWidget.json рядом.

param(
    [string]$Url = '',   # если пусто — берётся из ClaudeUsageWidget.json (ключ url)
    [int]$IntervalSec = 60
)

$ErrorActionPreference = 'Stop'
# Add-Type компилирует P/Invoke во временную DLL; %TEMP% не в исключениях Kaspersky — уводим в C:\ClaudeScripts\tmp
$TmpDir = Join-Path $PSScriptRoot 'tmp'; if (-not (Test-Path $TmpDir)) { New-Item -ItemType Directory -Path $TmpDir | Out-Null }
$env:TEMP = $TmpDir; $env:TMP = $TmpDir
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# прячем консоль pwsh (запускать БЕЗ -WindowStyle Hidden, иначе скрытой родится и форма)
Add-Type -Name Con -Namespace Win32 -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
[Win32.Con]::ShowWindow([Win32.Con]::GetConsoleWindow(), 0) | Out-Null
# per-monitor DPI awareness v2 — иначе при масштабе >100% Windows растягивает окно битмапом (мыло)
Add-Type -Name Dpi -Namespace Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);'
[Win32.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null

$mutex = New-Object System.Threading.Mutex -ArgumentList $false, 'Local\ClaudeUsageWidget'
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

$CfgPath = Join-Path $PSScriptRoot 'ClaudeUsageWidget.json'
$LogPath = Join-Path $PSScriptRoot 'ClaudeUsageWidget.log'
function Log([string]$m) { try { Add-Content -Path $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) -Encoding utf8 } catch {} }

$script:Cfg = @{ mode = 'bar'; x = -1; y = -1; auto = $true; align = 'left'; url = 'http://SERVER:8766/usage.json' }   # align: left|right — выравнивание текста   # auto — сам встаёт на панель задач левее трея
if (Test-Path $CfgPath) { try { (Get-Content $CfgPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $script:Cfg[$_.Name] = $_.Value } } catch {} }
if (-not $Url) { $Url = [string]$script:Cfg.url }
function Save-Cfg { try { $script:Cfg | ConvertTo-Json | Set-Content $CfgPath -Encoding utf8 } catch {} }

$Colors = @{
    green  = [System.Drawing.Color]::FromArgb(46, 204, 64)
    yellow = [System.Drawing.Color]::FromArgb(255, 220, 0)
    red    = [System.Drawing.Color]::FromArgb(255, 65, 54)
    gray   = [System.Drawing.Color]::FromArgb(150, 150, 150)
}
$BgColor   = [System.Drawing.Color]::FromArgb(32, 32, 36)
$TextColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
$DimColor  = [System.Drawing.Color]::FromArgb(160, 160, 165)
$BarBack   = [System.Drawing.Color]::FromArgb(60, 60, 66)
$BarFill   = [System.Drawing.Color]::FromArgb(90, 150, 230)

function Fmt([object]$v) { if ($null -eq $v) { return '—' }; return ([math]::Round([double]$v)).ToString() }
function Signed([object]$v) { if ($null -eq $v) { return '—' }; $x = [math]::Round([double]$v); if ($x -gt 0) { "+$x" } else { "$x" } }
function Day-Genitive([datetime]$dt) {
    @{ Monday = 'понедельника'; Tuesday = 'вторника'; Wednesday = 'среды'; Thursday = 'четверга'; Friday = 'пятницы'; Saturday = 'субботы'; Sunday = 'воскресенья' }[[string]$dt.DayOfWeek]
}
function ToLocal($ra) { if ($ra -is [datetime]) { $ra.ToLocalTime() } else { ([datetimeoffset]::Parse([string]$ra)).LocalDateTime } }

$script:Data = $null; $script:Err = $null
function Get-Usage {
    try { $script:Data = Invoke-RestMethod -Uri $Url -TimeoutSec 8; $script:Err = $null }
    catch { $script:Err = $_.Exception.Message; Log "fetch error: $($script:Err)" }
}

# строки для отрисовки: @{ color; remaining; main; sub }
function Build-Rows {
    $d = $script:Data
    if ($null -eq $d) { return @(@{ color = 'gray'; remaining = 0; main = 'Нет связи с сервером usage'; sub = '' }) }
    $rows = @()
    $s = $d.session
    if ($s -and $s.active) {
        $rows += @{ color = $(if ($d.stale) { 'gray' } else { [string]$d.color_session }); remaining = [double]$s.remaining_pct
                    main = "Осталось {0}% до {1}" -f (Fmt $s.remaining_pct), (ToLocal $s.resets_at).ToString('HH:mm'); sub = '5-часовое окно' }
    } else {
        $rows += @{ color = 'green'; remaining = 100; main = 'Окно не начато · 100%'; sub = '5-часовое окно' }
    }
    $f = $d.fable
    if ($f) {
        $reset = ToLocal $f.plan_end
        $rows += @{ color = $(if ($d.stale) { 'gray' } else { [string]$d.color_weekly }); remaining = [double]$f.remaining_pct
                    main = "Осталось {0}% до {1} {2}" -f (Fmt $f.remaining_pct), (Day-Genitive $reset), $reset.ToString('HH:mm')
                    sub = "Неделя Fable · сегодня {0}%" -f (Signed $f.available_today_pp) }
    }
    if ($d.stale) { $rows[0].sub = "ДАННЫЕ УСТАРЕЛИ ({0} мин)" -f [math]::Round($d.data_age_sec / 60) }
    return $rows
}

# ---------- окно ----------
$KeyColor = [System.Drawing.Color]::FromArgb(1, 2, 3)   # цветовой ключ прозрачности — фон окна не рисуется
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = $KeyColor
$form.TransparencyKey = $KeyColor
$form.Text = 'Claude usage'
$typ = $form.GetType(); $typ.GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
$form.CreateControl() | Out-Null
$S = [double]$form.DeviceDpi / 96.0            # масштаб DPI
function L([double]$v) { [int][math]::Round($v * $S) }   # логические px -> физические
$Pad = L 3; $W = L 185; $BarH = L 3
$script:RowH = L 17
$form.Size = New-Object System.Drawing.Size -ArgumentList $W, ($RowH * 2 + $Pad * 2)

$FontMain = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', ([single]8), ([System.Drawing.FontStyle]::Bold)
$FontSub  = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', ([single]6.5)
$SF = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
$SF.FormatFlags = $SF.FormatFlags -bor [System.Drawing.StringFormatFlags]::NoWrap
function Draw-Text($g, [string]$t, $font, $color, [int]$x, [int]$y) { $b = New-Object System.Drawing.SolidBrush $color; $g.DrawString($t, $font, $b, [single]$x, [single]$y, $SF); $b.Dispose() }
function Text-W($g, [string]$t, $font) { [int][math]::Ceiling($g.MeasureString($t, $font, 10000, $SF).Width) }

Add-Type -Name Tb -Namespace Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, ref RECT r, uint f);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string name);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string cls, string name);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(System.Drawing.Point p);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
'@ -ReferencedAssemblies System.Drawing.Primitives
function Ensure-OnTop {
    # если в центре нашего окна видно чужое (панель задач всплыла выше) — вернуть себя поверх
    if (-not $form.Visible) { return }
    if (-not $script:Probe) { return }   # точка на непрозрачном пикселе (прозрачные пропускают hit-test)
    $c = New-Object System.Drawing.Point -ArgumentList ($form.Left + $script:Probe.X), ($form.Top + $script:Probe.Y)
    $h = [Win32.Tb]::WindowFromPoint($c)
    if ($h -ne [IntPtr]::Zero -and [Win32.Tb]::GetAncestor($h, 2) -ne $form.Handle) {
        [Win32.Tb]::SetWindowPos($form.Handle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0013) | Out-Null
    }
}
function Get-WorkArea { $r = New-Object Win32.Tb+RECT; [Win32.Tb]::SystemParametersInfo(0x30, 0, [ref]$r, 0) | Out-Null; $r }
function Get-Taskbar {
    # прямоугольники панели задач и области уведомлений (физические px)
    $tb = [Win32.Tb]::FindWindow('Shell_TrayWnd', $null); if ($tb -eq [IntPtr]::Zero) { return $null }
    $rt = New-Object Win32.Tb+RECT; [Win32.Tb]::GetWindowRect($tb, [ref]$rt) | Out-Null
    $tn = [Win32.Tb]::FindWindowEx($tb, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    $rn = New-Object Win32.Tb+RECT
    if ($tn -ne [IntPtr]::Zero) { [Win32.Tb]::GetWindowRect($tn, [ref]$rn) | Out-Null } else { $rn = $rt; $rn.L = $rt.R }
    return @{ bar = $rt; tray = $rn }
}
function Place-Auto {
    # на панели задач, левее области уведомлений; высота = высоте панели (минус поля)
    $t = Get-Taskbar
    if (-not $t) { Place-Default; return }
    $tbH = $t.bar.B - $t.bar.T
    $h = $tbH - (L 4); if ($h -lt (L 30)) { $h = L 30 }
    $script:RowH = [int](($h - $Pad * 2) / 2)
    $form.Size = New-Object System.Drawing.Size -ArgumentList $W, ($script:RowH * 2 + $Pad * 2)
    $x = $t.tray.L - $form.Width - (L 6)
    $y = $t.bar.B - $form.Height - [int](($tbH - $form.Height) / 2)
    $form.Location = New-Object System.Drawing.Point -ArgumentList $x, $y
    # панель задач тоже topmost — напоминаем системе, что мы выше
    [Win32.Tb]::SetWindowPos($form.Handle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0013) | Out-Null   # NOSIZE|NOMOVE|NOACTIVATE
}
function Place-Default {
    $wa = Get-WorkArea
    $form.Location = New-Object System.Drawing.Point -ArgumentList ($wa.R - $form.Width - (L 4)), ($wa.B - $form.Height - (L 4))
}
function Place-Window {
    if ($script:Cfg.auto) { Place-Auto; return }
    if ($script:Cfg.x -ge 0 -and $script:Cfg.y -ge 0) {
        $form.Location = New-Object System.Drawing.Point -ArgumentList ([int]$script:Cfg.x), ([int]$script:Cfg.y)
    } else { Place-Default }
}
Place-Window

# форму показываем явно (SW_SHOWNOACTIVATE) — на случай запуска со скрытым STARTUPINFO
$form.Add_Load({ [Win32.Con]::ShowWindow($form.Handle, 4) | Out-Null; Place-Window })

$form.Add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
    $rows = Build-Rows
    $y = $Pad
    $mode = [string]$script:Cfg.mode
    $RowH = $script:RowH
    $lineH = [int]$FontMain.GetHeight($g)
    foreach ($r in $rows) {
        $c = $Colors[$r.color]; if (-not $c) { $c = $Colors.gray }
        $textX = $Pad
        if ($mode -eq 'light') {
            $d = L 10
            $br = New-Object System.Drawing.SolidBrush $c
            $g.FillEllipse($br, $Pad, $y + [int](($RowH - $d) / 2), $d, $d); $br.Dispose()
            if ($y -eq $Pad) { $script:Probe = New-Object System.Drawing.Point -ArgumentList ($Pad + [int]($d / 2)), ($y + [int]($RowH / 2)) }
            $textX = $Pad + $d + (L 5)
            $tx = if ($script:Cfg.align -eq 'right') { $form.Width - $Pad - (Text-W $g $r.main $FontMain) } else { $textX }
            Draw-Text $g $r.main $FontMain $TextColor $tx ($y + [int](($RowH - $lineH) / 2))
        } else {
            $mainColor = if ($r.remaining -le 0 -or $r.color -eq 'red') { $Colors.red } else { $TextColor }
            $sw = Text-W $g $r.sub $FontSub; $mw = Text-W $g $r.main $FontMain
            $right = ($script:Cfg.align -eq 'right')
            $tx = if ($right) { $form.Width - $Pad - $mw } else { $textX }
            Draw-Text $g $r.main $FontMain $mainColor $tx $y
            # подпись — у противоположного края, если влезает
            if ($textX + $mw + (L 6) + $sw -le $form.Width - $Pad) {
                $sx = if ($right) { $textX } else { $form.Width - $Pad - $sw }
                Draw-Text $g $r.sub $FontSub $DimColor $sx ($y + [int](($lineH - $FontSub.GetHeight($g)) / 2))
            }
            $bx = $textX; $by = $y + $lineH + (L 1); $bw = $form.Width - $Pad * 2
            $bb = New-Object System.Drawing.SolidBrush $BarBack
            $g.FillRectangle($bb, $bx, $by, $bw, $BarH); $bb.Dispose()
            if ($y -eq $Pad) { $script:Probe = New-Object System.Drawing.Point -ArgumentList ($bx + (L 2)), ($by + [int]($BarH / 2)) }
            $fillW = [int]([math]::Max(0, [math]::Min(100, $r.remaining)) / 100 * $bw)
            $fb = New-Object System.Drawing.SolidBrush $c
            if ($fillW -gt 0) { $g.FillRectangle($fb, ($bx + $bw - $fillW), $by, $fillW, $BarH) }; $fb.Dispose()
        }
        $y += $RowH
    }
})

# перетаскивание
$script:Drag = $null
$form.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:Drag = $e.Location } })
$form.Add_MouseMove({ param($s, $e) if ($script:Drag) { $form.Location = New-Object System.Drawing.Point -ArgumentList ($form.Left + $e.X - $script:Drag.X), ($form.Top + $e.Y - $script:Drag.Y) } })
$form.Add_MouseUp({ param($s, $e) if ($script:Drag) { $script:Drag = $null; $script:Cfg.x = $form.Left; $script:Cfg.y = $form.Top; $script:Cfg.auto = $false; $miAuto2.Checked = $false; Save-Cfg } })
$form.Add_MouseDoubleClick({ param($s, $e) if ($e.Button -eq 'Left') { Toggle-Mode } })

function Toggle-Mode { $script:Cfg.mode = if ($script:Cfg.mode -eq 'light') { 'bar' } else { 'light' }; Save-Cfg; $miMode.Text = Mode-Label; $form.Invalidate() }
function Mode-Label { if ($script:Cfg.mode -eq 'light') { 'Режим: светофор → переключить на прогресс-бар' } else { 'Режим: прогресс-бар → переключить на светофор' } }

# меню
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; $RunName = 'ClaudeUsageWidget'
$PwshExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'; if (-not (Test-Path $PwshExe)) { $PwshExe = (Get-Process -Id $PID).Path }
$RunCmd = 'wscript.exe "{0}"' -f (Join-Path $PSScriptRoot 'ClaudeUsageWidget.vbs')   # автозапуск через VBS-лаунчер (скрытая консоль)
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miMode = New-Object System.Windows.Forms.ToolStripMenuItem (Mode-Label); $miMode.Add_Click({ Toggle-Mode }); $menu.Items.Add($miMode) | Out-Null
$mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Обновить сейчас'; $mi.Add_Click({ Get-Usage; $form.Invalidate() }); $menu.Items.Add($mi) | Out-Null
$mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Открыть панель usage на claude.ai'; $mi.Add_Click({ Start-Process 'https://claude.ai/settings/usage' }); $menu.Items.Add($mi) | Out-Null
$miAuto2 = New-Object System.Windows.Forms.ToolStripMenuItem 'На панели задач (авто-позиция)'; $miAuto2.CheckOnClick = $true; $miAuto2.Checked = [bool]$script:Cfg.auto
$miAuto2.Add_Click({ $script:Cfg.auto = $this.Checked; Save-Cfg; Place-Window; $form.Invalidate() }); $menu.Items.Add($miAuto2) | Out-Null
$miAlign = New-Object System.Windows.Forms.ToolStripMenuItem 'Текст по правому краю'; $miAlign.CheckOnClick = $true; $miAlign.Checked = ($script:Cfg.align -eq 'right')
$miAlign.Add_Click({ $script:Cfg.align = if ($this.Checked) { 'right' } else { 'left' }; Save-Cfg; $form.Invalidate() }); $menu.Items.Add($miAlign) | Out-Null
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Автозапуск'; $miAuto.CheckOnClick = $true
$miAuto.Checked = [bool](Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue)
$miAuto.Add_Click({ if ($this.Checked) { Set-ItemProperty -Path $RunKey -Name $RunName -Value $RunCmd } else { Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue } })
$menu.Items.Add($miAuto) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$mi = New-Object System.Windows.Forms.ToolStripMenuItem 'Выход'; $mi.Add_Click({ $form.Close() }); $menu.Items.Add($mi) | Out-Null
$form.ContextMenuStrip = $menu

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalSec * 1000
$timer.Add_Tick({ Get-Usage; Place-Window; $form.Invalidate() })
$timer.Start()
# сторож z-order: панель задач тоже topmost и периодически всплывает над нами
$topTimer = New-Object System.Windows.Forms.Timer
$topTimer.Interval = 1000
$topTimer.Add_Tick({ try { Ensure-OnTop } catch {} })
$topTimer.Start()

Log "start pid=$PID mode=$($script:Cfg.mode)"
Get-Usage
try { [System.Windows.Forms.Application]::Run($form) }
finally { $timer.Stop(); $mutex.ReleaseMutex() | Out-Null; Log 'exit' }
