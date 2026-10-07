# ClaudeUsageWidget.ps1 — виджет расхода квоты Claude прямо на панели задач Windows.
# Две строки: 5-часовое окно и неделя, убывающие прогресс-бары.
# Источник данных: автономно (API Anthropic + токен Claude Code) или сервер claude-usage (ключ url).
# Работает в Windows PowerShell 5.1 и PowerShell 7. Настройки — ClaudeUsageWidget.json рядом.

param(
    [string]$Url = '',   # если пусто — берётся из ClaudeUsageWidget.json (ключ url)
    [int]$IntervalSec = 60
)

$ErrorActionPreference = 'Stop'
# Add-Type компилирует P/Invoke во временную DLL; %TEMP% часто не в исключениях антивируса — уводим в подпапку tmp рядом со скриптом
$TmpDir = Join-Path $PSScriptRoot 'tmp'; if (-not (Test-Path $TmpDir)) { New-Item -ItemType Directory -Path $TmpDir | Out-Null }
$env:TEMP = $TmpDir; $env:TMP = $TmpDir
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# прячем консоль pwsh (запускать БЕЗ -WindowStyle Hidden, иначе скрытой родится и форма)
Add-Type -Name Con -Namespace Win32 -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
[Win32.Con]::ShowWindow([Win32.Con]::GetConsoleWindow(), 0) | Out-Null
# per-monitor DPI awareness v2 — иначе при масштабе >100% Windows растягивает окно битмапом (мыло)
Add-Type -Name Dpi -Namespace Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx); [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);'
[Win32.Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null

$mutex = New-Object System.Threading.Mutex -ArgumentList $false, 'Local\ClaudeUsageWidget'
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

$CfgPath = Join-Path $PSScriptRoot 'ClaudeUsageWidget.json'
$LogPath = Join-Path $PSScriptRoot 'ClaudeUsageWidget.log'
function Log([string]$m) { try { Add-Content -Path $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $m) -Encoding utf8 } catch {} }

$script:Cfg = @{ x = -1; y = -1; auto = $true; align = 'left'; url = ''
                 poll_sec = 300; plan_end_offset_hours = 9; day_end_hour = 22; yellow_over_pp = 4; red_over_pp = 10
                 session_window_hours = 5; session_yellow_pct = 80; session_red_pct = 95; session_yellow_over_pp = 10; session_red_over_pp = 25 }   # align: left|right — выравнивание текста   # auto — сам встаёт на панель задач левее трея
if (Test-Path $CfgPath) { try { (Get-Content $CfgPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $script:Cfg[$_.Name] = $_.Value } } catch {} }
if (-not $Url) { $Url = [string]$script:Cfg.url }
function Save-Cfg { try { $script:Cfg | ConvertTo-Json | Set-Content $CfgPath -Encoding utf8 } catch {} }
# язык интерфейса: ключ lang в настройках (ru|en) или язык Windows; всё, что не русский, — английский
$script:Lang = [string]$script:Cfg.lang; if ($script:Lang -notin 'ru', 'en') { $script:Lang = if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'ru') { 'ru' } else { 'en' } }
$script:Cult = [Globalization.CultureInfo]::GetCultureInfo($(if ($script:Lang -eq 'ru') { 'ru-RU' } else { 'en-US' }))
function T([string]$ru, [string]$en) { if ($script:Lang -eq 'ru') { $ru } else { $en } }

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
# ровный темп (остаток лимита / оставшиеся дни, пересчитывается при каждом опросе): округляем до 10%, мелкие значения — как есть
function Pace([object]$v) { $n = [double]$v; if ($n -ge 10) { $n = [math]::Round($n / 10, [MidpointRounding]::AwayFromZero) * 10 }; Fmt $n }
function Day-Genitive([datetime]$dt) {
    if ($script:Lang -ne 'ru') { return $dt.ToString('dddd', $script:Cult) }
    @{ Monday = 'понедельника'; Tuesday = 'вторника'; Wednesday = 'среды'; Thursday = 'четверга'; Friday = 'пятницы'; Saturday = 'субботы'; Sunday = 'воскресенья' }[[string]$dt.DayOfWeek]
}
function ToLocal($ra) { if ($ra -is [datetime]) { $ra.ToLocalTime() } else { ([datetimeoffset]::Parse([string]$ra)).LocalDateTime } }

# ---------- источник данных ----------
# url пустой  -> автономный режим: виджет сам ходит в API Anthropic с токеном Claude Code
#                (%USERPROFILE%\.claude\.credentials.json) и сам считает план
# url задан   -> клиент сервера claude-usage (готовый usage.json)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:Data = $null; $script:Err = $null; $script:ErrShort = $null
$script:Raw = $null; $script:RawAt = [datetime]::MinValue; $script:NextFetch = [datetime]::MinValue
$OAuthClientId = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'          # client_id Claude Code
$TokenUrl      = 'https://platform.claude.com/v1/oauth/token'
$UsageApi      = 'https://api.anthropic.com/api/oauth/usage'

function Get-CredPath {
    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    Join-Path $base '.credentials.json'
}
function Read-Creds {
    $p = Get-CredPath
    if (-not (Test-Path $p)) { throw (New-Object System.IO.FileNotFoundException 'nocreds') }
    $j = Get-Content $p -Raw | ConvertFrom-Json
    if (-not $j.claudeAiOauth) { throw (New-Object System.IO.FileNotFoundException 'nocreds') }
    return $j
}
function Update-Token {
    # продлить access-токен по refresh-токену и записать обратно в файл Claude Code (формат сохраняется)
    $p = Get-CredPath
    $j = Read-Creds; $o = $j.claudeAiOauth
    $body = @{ grant_type = 'refresh_token'; refresh_token = [string]$o.refreshToken; client_id = $OAuthClientId; scope = (@($o.scopes) -join ' ') } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri $TokenUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 20
    if (-not $r.access_token) { throw (T 'refresh: пустой ответ' 'refresh: empty response') }
    $o.accessToken = [string]$r.access_token
    if ($r.refresh_token) { $o.refreshToken = [string]$r.refresh_token }
    $o.expiresAt = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [long]$r.expires_in * 1000)
    $json = $j | ConvertTo-Json -Depth 10 -Compress
    $tmp = "$p.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))   # без BOM — Claude Code читает JSON.parse
    [IO.File]::Replace($tmp, $p, $null)
    Log "token refreshed, expires in $($r.expires_in)s"
}
function Invoke-UsageApi([string]$token) {
    Invoke-RestMethod -Uri $UsageApi -TimeoutSec 20 -Headers @{ Authorization = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = 'claude-code/2.1.282' }
}
function Fetch-Raw {
    if ($script:Cfg.raw_url) { return Invoke-RestMethod -Uri ([string]$script:Cfg.raw_url) -TimeoutSec 8 }   # отладка: сырой ответ с сервера
    $o = (Read-Creds).claudeAiOauth
    if ([long]$o.expiresAt -lt ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 60000)) { Update-Token; $o = (Read-Creds).claudeAiOauth }
    try { return Invoke-UsageApi ([string]$o.accessToken) }
    catch {
        $code = $null; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 401) { Update-Token; return Invoke-UsageApi ([string](Read-Creds).claudeAiOauth.accessToken) }
        throw
    }
}

# ---------- расчёт плана (порт server/usage_server.py) ----------
function To-Utc($v) { if ($v -is [datetime]) { $v.ToUniversalTime() } else { ([DateTimeOffset]::Parse([string]$v)).UtcDateTime } }
function Frac([datetime]$t, [datetime]$a, [datetime]$b) { [math]::Max(0.0, [math]::Min(1.0, ($t - $a).TotalSeconds / ($b - $a).TotalSeconds)) }

function Plan-Weekly($item, [datetime]$now) {
    if (-not $item -or $null -eq $item.percent -or -not $item.resets_at) { return $null }
    $c = $script:Cfg
    $used  = [double]$item.percent
    $reset = To-Utc $item.resets_at
    $start = $reset.AddDays(-7)
    $end   = $reset.AddHours(-[double]$c.plan_end_offset_hours)
    $target = (Frac $now $start $end) * 100
    $loc = $now.ToLocalTime()
    $dayEnd = $loc.Date.AddHours([double]$c.day_end_hour)
    if ($loc -ge $dayEnd) { $dayEnd = $dayEnd.AddDays(1) }
    $targetDay = (Frac $dayEnd.ToUniversalTime() $start $end) * 100
    $hoursLeft = [math]::Max(0.0, ($end - $now).TotalHours)
    @{
        used_pct = $used; remaining_pct = 100 - $used
        target_now_pct = $target; delta_pp = $used - $target
        available_today_pp = $targetDay - $used
        needed_per_day_pp = $(if ($hoursLeft -gt 0) { (100 - $used) / ($hoursLeft / 24) } else { $null })
        plan_end = $end; resets_at = $reset
    }
}
function Plan-Session($item, [datetime]$now) {
    if (-not $item -or $null -eq $item.percent) { return $null }
    $used = [double]$item.percent
    $s = @{ used_pct = $used; remaining_pct = 100 - $used; available_pct = 100 - $used; resets_at = $null; active = $false; delta_pp = 0 }
    if (-not $item.resets_at) { return $s }
    $reset = To-Utc $item.resets_at
    $s.resets_at = $reset
    if ($reset -le $now) { return $s }
    $start = $reset.AddHours(-[double]$script:Cfg.session_window_hours)
    $target = (Frac $now $start $reset) * 100
    $s.active = $true; $s.target_now_pct = $target; $s.delta_pp = $used - $target
    $s.minutes_to_reset = [int]($reset - $now).TotalMinutes
    return $s
}
function Color-Session($s) {
    $c = $script:Cfg
    if (-not $s -or -not $s.active) { return 'green' }
    $u = $s.used_pct; $d = $s.delta_pp
    if ($u -ge 100 -or $u -ge $c.session_red_pct -or $d -gt $c.session_red_over_pp) { return 'red' }
    if ($u -ge $c.session_yellow_pct -or $d -gt $c.session_yellow_over_pp) { return 'yellow' }
    return 'green'
}
function Color-Weekly($f, $w) {
    $c = $script:Cfg; $lvl = 0
    foreach ($p in @($f, $w)) {
        if (-not $p) { continue }
        if ($p.used_pct -ge 100 -or $p.delta_pp -gt $c.red_over_pp) { $lvl = 2 }
        elseif ($p.delta_pp -gt $c.yellow_over_pp -and $lvl -lt 1) { $lvl = 1 }
    }
    @('green', 'yellow', 'red')[$lvl]
}
function Convert-Raw($raw, [datetime]$now) {
    $sess = $null; $week = $null; $fab = $null
    foreach ($l in @($raw.limits)) {
        if (-not $l) { continue }
        $it = @{ percent = $l.percent; resets_at = $l.resets_at }
        if ($l.kind -eq 'session') { $sess = $it }
        elseif ($l.kind -eq 'weekly_all') { $week = $it }
        elseif ($l.kind -eq 'weekly_scoped' -and [string]$l.scope.model.display_name -eq 'Fable') { $fab = $it }
    }
    if (-not $sess -and $raw.five_hour) { $sess = @{ percent = $raw.five_hour.utilization; resets_at = $raw.five_hour.resets_at } }
    if (-not $week -and $raw.seven_day) { $week = @{ percent = $raw.seven_day.utilization; resets_at = $raw.seven_day.resets_at } }
    $w = Plan-Weekly $week $now
    $f = Plan-Weekly $fab $now                       # отдельный лимит Fable считаем, но не показываем
    $s = Plan-Session $sess $now
    if ($w) {   # «потрачено сегодня»: снимок недельного расхода на начало суток хранится в конфиге
        $u = [double]$w.used_pct; $loc = Get-Date; $today = $loc.ToString('yyyy-MM-dd')
        if ($script:Cfg.day_date -ne $today -or $null -eq $script:Cfg.day_start) {
            $script:Cfg.day_date = $today; $script:Cfg.day_start = $u; $script:Cfg.day_since = $loc.ToString('o'); Save-Cfg
        } elseif ($u -lt [double]$script:Cfg.day_start) {   # недельный сброс посреди дня
            $script:Cfg.day_start = 0; $script:Cfg.day_since = $loc.ToString('o'); Save-Cfg
        }
        $w.spent_today_pp = [math]::Round($u - [double]$script:Cfg.day_start, 1)
        $w.today_since = [string]$script:Cfg.day_since
    }
    @{ stale = $false; data_age_sec = 0; session = $s; fable = $f; weekly = $w
       color_session = (Color-Session $s); color_weekly = (Color-Weekly $null $w) }
}

function Get-Usage {
    if ($Url) {   # режим клиента сервера
        try { $script:Data = Invoke-RestMethod -Uri $Url -TimeoutSec 8; $script:Err = $null; $script:ErrShort = $null }
        catch { $script:Err = $_.Exception.Message; $script:ErrShort = (T 'Нет связи с сервером usage' 'Usage server unreachable'); Log "fetch error: $($script:Err)" }
        return
    }
    $now = [datetime]::UtcNow
    if ($now -ge $script:NextFetch) {
        try {
            $script:Raw = Fetch-Raw; $script:RawAt = $now; $script:Err = $null; $script:ErrShort = $null
            $script:NextFetch = $now.AddSeconds([double]$script:Cfg.poll_sec)
        }
        catch [System.IO.FileNotFoundException] {
            $script:Err = 'nocreds'; $script:ErrShort = (T 'Войдите в Claude (правый клик)' 'Sign in to Claude (right-click)')
            $script:NextFetch = $now.AddSeconds(30)
        }
        catch {
            $script:Err = $_.Exception.Message; $script:ErrShort = (T 'Ошибка запроса к Anthropic' 'Anthropic request failed'); Log "fetch error: $($script:Err)"
            $script:NextFetch = $now.AddSeconds(120)
        }
    }
    if ($script:Raw) {
        $script:Data = Convert-Raw $script:Raw $now
        $age = ($now - $script:RawAt).TotalSeconds
        $script:Data.data_age_sec = [int]$age
        $script:Data.stale = ($age -gt 1800)
    } else { $script:Data = $null }
}

# строки для отрисовки: @{ color; remaining; main; sub }
function Build-Rows {
    $d = $script:Data
    if ($null -eq $d) { return @(@{ color = 'gray'; remaining = 0; main = $(if ($script:ErrShort) { $script:ErrShort } else { (T 'Нет данных' 'No data') }); sub = '' }) }
    $rows = @()
    $s = $d.session
    if ($s -and $s.active) {
        $rows += @{ color = $(if ($d.stale) { 'gray' } else { [string]$d.color_session }); remaining = [double]$s.remaining_pct
                    main = (T 'Осталось {0}% до {1}' '{0}% left until {1}') -f (Fmt $s.remaining_pct), (ToLocal $s.resets_at).ToString('HH:mm'); sub = (T '5-часовое окно' '5-hour window') }
    } else {
        $rows += @{ color = 'green'; remaining = 100; main = (T 'Окно не начато · 100%' 'Window not started · 100%'); sub = (T '5-часовое окно' '5-hour window') }
    }
    $f = $d.weekly                                   # вторая строка — общий недельный лимит (все модели)
    if ($f) {
        $reset = ToLocal $f.plan_end
        $rows += @{ color = $(if ($d.stale) { 'gray' } else { [string]$d.color_weekly }); remaining = [double]$f.remaining_pct
                    main = (T 'Осталось {0}% до {1} {2}' '{0}% left until {1} {2}') -f (Fmt $f.remaining_pct), (Day-Genitive $reset), $reset.ToString('HH:mm')
                    sub = $(if ($null -ne $f.needed_per_day_pp) { (T 'Неделя · {0}% в день' 'Week · {0}%/day') -f (Pace $f.needed_per_day_pp) } else { (T 'Неделя' 'Week') }) }
    }
    if ($d.stale) { $rows[0].sub = (T 'ДАННЫЕ УСТАРЕЛИ ({0} мин)' 'STALE DATA ({0} min)') -f [math]::Round($d.data_age_sec / 60) }
    return $rows
}

# всплывающая подсказка: подробности по окну, неделе и отдельному лимиту Fable
function Build-Tip {
    $d = $script:Data
    if ($null -eq $d) { return $(if ($script:Err) { ((T 'Нет данных' 'No data') + ": $($script:Err)") } else { (T 'Нет данных' 'No data') }) }
    $L = New-Object System.Collections.Generic.List[string]

    $s = $d.session
    $L.Add((T '5-часовое окно' '5-hour window'))
    if ($s -and $s.active -and $s.resets_at) {
        $r = ToLocal $s.resets_at
        $m = [int][math]::Max(0, ($r - (Get-Date)).TotalMinutes)
        $L.Add(((T '  Осталось {0}% · сброс в {1} (через {2} ч {3:D2} мин)' '  {0}% left · resets at {1} (in {2} h {3:D2} min)') -f (Fmt $s.remaining_pct), $r.ToString('HH:mm'), [math]::Floor($m / 60), ($m % 60)))
    } else { $L.Add((T '  Окно не начато — доступно 100%' '  Window not started — 100% available')) }

    foreach ($row in @(@((T 'Неделя (все модели)' 'Week (all models)'), $d.weekly, $true), @((T 'Fable (отдельный лимит)' 'Fable (separate limit)'), $d.fable, $false))) {
        $name = $row[0]; $p = $row[1]; $full = $row[2]
        if (-not $p) { continue }
        $L.Add(''); $L.Add($name)
        $reset = if ($p.resets_at) { (T ' · сброс ' ' · resets ') + (ToLocal $p.resets_at).ToString('ddd HH:mm', $script:Cult) } else { '' }
        $L.Add(((T '  Осталось {0}%{1}' '  {0}% left{1}') -f (Fmt $p.remaining_pct), $reset))
        if ($null -ne $p.needed_per_day_pp) { $L.Add(((T '  Ровный темп на остаток недели — {0}% в день' '  Even pace for the rest of the week — {0}% per day') -f (Pace $p.needed_per_day_pp))) }
    }

    return ($L -join "`n")
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
$S = [double]([Win32.Dpi]::GetDpiForWindow($form.Handle)) / 96.0   # Form.DeviceDpi в .NET Framework без манифеста всегда 96
if ($S -le 0) { $S = [double]$form.DeviceDpi / 96.0 }
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
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
'@ -ReferencedAssemblies $(if ($PSVersionTable.PSEdition -eq 'Core') { 'System.Drawing.Primitives' } else { 'System.Drawing' })
function Test-RdpFullscreen {
    # активное окно — клиент RDP (mstsc/msrdc) или SmartPSS, развёрнутое на весь монитор: локальной панели задач не видно
    $h = [Win32.Tb]::GetForegroundWindow(); if ($h -eq [IntPtr]::Zero) { return $false }
    $root = [Win32.Tb]::GetAncestor($h, 2); if ($root -eq [IntPtr]::Zero) { $root = $h }
    $procId = [uint32]0; [Win32.Tb]::GetWindowThreadProcessId($root, [ref]$procId) | Out-Null
    if ($procId -ne $script:FgPid) {   # имя процесса кэшируем до смены активного окна
        $script:FgPid = $procId
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $script:FgIsRdp = [bool]($p -and $p.ProcessName -match '^(mstsc|msrdc|SmartPSS.*)$')
    }
    if (-not $script:FgIsRdp) { return $false }
    $r = New-Object Win32.Tb+RECT; [Win32.Tb]::GetWindowRect($root, [ref]$r) | Out-Null
    $b = [System.Windows.Forms.Screen]::FromHandle($root).Bounds
    return ($r.L -le $b.Left -and $r.T -le $b.Top -and $r.R -ge $b.Right -and $r.B -ge $b.Bottom)
}
function Ensure-OnTop {
    # на полноэкранной RDP-сессии или в полноэкранном SmartPSS виджет прячем (иначе он висит поверх)
    $rdp = Test-RdpFullscreen
    if ($rdp -ne [bool]$script:RdpHidden) {
        $script:RdpHidden = $rdp
        [Win32.Con]::ShowWindow($form.Handle, $(if ($rdp) { 0 } else { 4 })) | Out-Null   # SW_HIDE / SW_SHOWNOACTIVATE
        if (-not $rdp) { Place-Window }
    }
    if ($rdp) { return }
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
    try { $rows = Build-Rows } catch { Log "rows: $_"; $rows = @(@{ color = 'gray'; remaining = 0; main = (T 'Ошибка отображения' 'Display error'); sub = '' }) }
    $y = $Pad
    $RowH = $script:RowH
    $lineH = [int]$FontMain.GetHeight($g)
    foreach ($r in $rows) {
        $c = $Colors[$r.color]; if (-not $c) { $c = $Colors.gray }
        $textX = $Pad
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
        $y += $RowH
    }
})

# перетаскивание
$script:Drag = $null
$form.Add_MouseDown({ param($s, $e) if ($e.Button -eq 'Left') { $script:Drag = $e.Location } })
$form.Add_MouseMove({ param($s, $e) if ($script:Drag) { $form.Location = New-Object System.Drawing.Point -ArgumentList ($form.Left + $e.X - $script:Drag.X), ($form.Top + $e.Y - $script:Drag.Y) } })
$form.Add_MouseUp({ param($s, $e) if ($script:Drag) { $script:Drag = $null; $script:Cfg.x = $form.Left; $script:Cfg.y = $form.Top; $script:Cfg.auto = $false; $miAuto2.Checked = $false; Save-Cfg } })


# меню
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; $RunName = 'ClaudeUsageWidget'
$PwshExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'; if (-not (Test-Path $PwshExe)) { $PwshExe = (Get-Process -Id $PID).Path }
$RunCmd = 'wscript.exe "{0}"' -f (Join-Path $PSScriptRoot 'ClaudeUsageWidget.vbs')   # автозапуск через VBS-лаунчер (скрытая консоль)
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$mi = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Обновить сейчас' 'Refresh now'); $mi.Add_Click({ Get-Usage; $form.Invalidate() }); $menu.Items.Add($mi) | Out-Null
$mi = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Открыть панель usage на claude.ai' 'Open the usage page on claude.ai'); $mi.Add_Click({ Start-Process 'https://claude.ai/settings/usage' }); $menu.Items.Add($mi) | Out-Null
$miAuto2 = New-Object System.Windows.Forms.ToolStripMenuItem (T 'На панели задач (авто-позиция)' 'On the taskbar (auto position)'); $miAuto2.CheckOnClick = $true; $miAuto2.Checked = [bool]$script:Cfg.auto
$miAuto2.Add_Click({ $script:Cfg.auto = $this.Checked; Save-Cfg; Place-Window; $form.Invalidate() }); $menu.Items.Add($miAuto2) | Out-Null
$miAlign = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Текст по правому краю' 'Right-aligned text'); $miAlign.CheckOnClick = $true; $miAlign.Checked = ($script:Cfg.align -eq 'right')
$miAlign.Add_Click({ $script:Cfg.align = if ($this.Checked) { 'right' } else { 'left' }; Save-Cfg; $form.Invalidate() }); $menu.Items.Add($miAlign) | Out-Null
$miLogin = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Войти в аккаунт Claude…' 'Sign in to Claude…')
$miLogin.Add_Click({
    $exe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (-not (Test-Path $exe)) { $c = Get-Command claude -ErrorAction SilentlyContinue; if ($c) { $exe = $c.Source } }
    if (Test-Path $exe) { Start-Process $exe } else { Start-Process 'https://docs.claude.com/en/docs/claude-code/setup' }
    $script:NextFetch = [datetime]::UtcNow.AddSeconds(20)
})
$miLogin.Visible = -not $Url
$menu.Items.Add($miLogin) | Out-Null
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Автозапуск' 'Start with Windows'); $miAuto.CheckOnClick = $true
$miAuto.Checked = [bool](Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue)
$miAuto.Add_Click({ if ($this.Checked) { Set-ItemProperty -Path $RunKey -Name $RunName -Value $RunCmd } else { Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue } })
$menu.Items.Add($miAuto) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$mi = New-Object System.Windows.Forms.ToolStripMenuItem (T 'Выход' 'Exit'); $mi.Add_Click({ $form.Close() }); $menu.Items.Add($mi) | Out-Null
$form.ContextMenuStrip = $menu
# сводка (та же, что в подсказке) — вверху меню, собирается заново при каждом открытии
$script:InfoItems = @()
$script:BoldFont = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
$menu.Add_Opening({
    try {
        foreach ($it in $script:InfoItems) { $menu.Items.Remove($it); $it.Dispose() }
        $list = New-Object System.Collections.Generic.List[System.Windows.Forms.ToolStripItem]
        foreach ($line in ((Build-Tip) -split "`n")) {
            if ($line -eq '') { $list.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
            $it = New-Object System.Windows.Forms.ToolStripMenuItem $line
            if ($line -notmatch '^\s') { $it.Font = $script:BoldFont }
            $list.Add($it)
        }
        $list.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        for ($i = 0; $i -lt $list.Count; $i++) { $menu.Items.Insert($i, $list[$i]) }
        $script:InfoItems = $list.ToArray()
    } catch { Log "menu: $_" }
})


$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalSec * 1000
$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:Tip.InitialDelay = 300; $script:Tip.AutoPopDelay = 30000; $script:Tip.ReshowDelay = 100; $script:Tip.ShowAlways = $true   # ShowAlways: окно не активируется
function Update-Tip { try { $script:Tip.SetToolTip($form, (Build-Tip)) } catch { Log "tip: $_" } }
$timer.Add_Tick({ try { Get-Usage; Place-Window; Update-Tip; $form.Invalidate() } catch { Log "tick: $_" } })
$timer.Start()
# сторож z-order: панель задач тоже topmost и периодически всплывает над нами
$topTimer = New-Object System.Windows.Forms.Timer
$topTimer.Interval = 1000
$topTimer.Add_Tick({ try { Ensure-OnTop } catch {} })
$topTimer.Start()

Log "start pid=$PID"
Get-Usage
Update-Tip
try { [System.Windows.Forms.Application]::Run($form) }
finally { $timer.Stop(); $mutex.ReleaseMutex() | Out-Null; Log 'exit' }
