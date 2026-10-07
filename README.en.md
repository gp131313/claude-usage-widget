# Claude Usage Widget

[Русский](README.md) | **English**

Your real Claude (Pro / Max) usage — right on the Windows taskbar, with a spend plan.

**The widget itself spends none of your limit:** it only reads usage statistics and never sends a request to a model.

The usage page on claude.ai says "On track" by counting linearly to the reset. This project counts differently:
how much you can spend to land at exactly 100% **by Friday evening** (weekly limit) and **by the end of the
5-hour window** — and shows the result on the taskbar.

![The widget on the Windows taskbar: what is left of the 5-hour window and of the weekly limit](docs/widget-taskbar-en.png)

The top row is the 5-hour window, the bottom row is the week. The bar shrinks as you spend and changes colour:
green — on plan, yellow and red — spending is ahead of plan.

The widget and the installer are in English or Russian, picked by the Windows display language.

> [!WARNING]
> **Unofficial tool — use at your own risk.** The widget is not affiliated with Anthropic. It reads the Claude Code
> sign-in token on your computer, uses it to call an undocumented usage endpoint, and refreshes the token itself
> when it expires. Anthropic [intends subscription sign-in](https://code.claude.com/docs/en/legal-and-compliance) for Claude Code and its own apps only and
> restricts its use by third-party software. The terms make no exception for reading usage statistics, so
> Anthropic may cut off the widget's access to the data or take action on the account. The token is never sent
> anywhere except Anthropic's servers; all the code is open.

## Quick install (Windows)

1. Download **[ClaudeUsageWidget-Setup.exe](https://github.com/gp131313/claude-usage-widget/releases/latest/download/ClaudeUsageWidget-Setup.exe)**.
2. Run it and click through the wizard: Next → Install → Finish.

<p><img src="docs/setup-wizard-en.png" width="420" alt="Setup wizard: welcome page"> <img src="docs/setup-options-en.png" width="420" alt="Setup wizard: options page"></p>

If you are not signed in to Claude Code yet, the installer offers to install Claude Code and sign in to your
Claude account (Pro/Max).

There is also a silent installer — **[ClaudeUsageWidget-Setup-Silent.exe](https://github.com/gp131313/claude-usage-widget/releases/latest/download/ClaudeUsageWidget-Setup-Silent.exe)**:
run it and the widget appears, with no windows at all (`ClaudeUsageWidget-Setup.exe /silent` does the same;
`/dir=<folder>` sets the install folder). It skips the Claude sign-in step: if you are not signed in, the widget
shows "Sign in to Claude" — right-click it → "Sign in to Claude…".

That's it. The widget sits on the taskbar to the left of the tray icons and starts with Windows. No server and
no administrator rights are needed. To uninstall, use Settings → Apps, or the uninstall shortcut in the Start menu.

If Windows shows "Windows protected your PC", click "More info" → "Run anyway" (the installer is not signed).
If you would rather not run an exe, the same release has `ClaudeUsageWidget-Setup-*.zip`: unpack it and
double-click `Setup.cmd` — the result is the same. An antivirus may flag `Add-Type` with WinAPI calls; this is a
false positive, and you can add `%LOCALAPPDATA%\ClaudeUsageWidget` to its exclusions.

## How it works

```
Claude Code (signed in) --.credentials.json--> server/usage_server.py --HTTP JSON--> windows/ClaudeUsageWidget.ps1
      (any Linux host)                           /usage.json  /raw.json                (taskbar widget)
```

Two modes:

- **Standalone** (the default, what the installer sets up): every 5 minutes the widget calls the Anthropic API
  with the Claude Code token from `%USERPROFILE%\.claude\.credentials.json` and computes the plan itself. When the
  token expires, the widget refreshes it with the refresh token (`platform.claude.com/v1/oauth/token`, the same
  way Claude Code does) and writes it back to the same file.
- **Server client**: if `url` is set in `ClaudeUsageWidget.json`, the widget takes a ready-made result from the server:

1. **The server** (Python 3, stdlib only) polls the same endpoint as `/usage` in Claude Code every 5 minutes —
   `GET https://api.anthropic.com/api/oauth/usage` — with the Claude Code OAuth token from
   `~/.claude/.credentials.json`. It computes the plan and serves `http://<host>:8766/usage.json` on the LAN.
2. **The widget** (PowerShell + WinForms) reads the JSON once a minute and draws two rows with no background
   directly over the taskbar, left of the notification area. Position and height follow the taskbar automatically.

The endpoint is undocumented and its response format may change. The server is written not to crash on unknown fields.

## Plan logic

| Counter | Plan | Colour |
|---|---|---|
| Week (overall limit, all models) | linear from the reset (Sat 07:00) to Fri 22:00 (`plan_end_offset_hours: 9`) | green <= +4% over plan, yellow up to +10%, red above |
| 5-hour window | linear from the window start (`resets_at - 5 h`) to the reset | green <= +10%, yellow up to +25% or >= 80% spent, red above / >= 95% |

All percentages are **absolute percent of the limit** (0–100), not relative. Thresholds live in
`server/config.json` and apply without a restart.

## Installation

### Server (Linux, where Claude Code is signed in)

```bash
git clone https://github.com/gp131313/claude-usage-widget.git
cd claude-usage-widget/server
cp config.example.json config.json      # adjust thresholds / time zone if you like
./install.sh                            # crontab: @reboot + a watchdog every 5 min; starts the service
curl -s localhost:8766/usage.json | python3 -m json.tool
```

Root is not needed. Port 8766 must be reachable from the Windows machine (LAN/VPN).

The Claude Code token lives for about 8 hours and is refreshed only when Claude Code itself talks to the API. If
Claude Code stays idle for long, the server gets a 401, the JSON gets `stale: true`, and the widget turns grey.
The server **deliberately does not refresh the token itself**, so as not to break the Claude Code session (the
refresh token rotates).

### Widget by hand (Windows 10/11, PowerShell 7; falls back to Windows PowerShell 5.1)

1. Copy `windows/ClaudeUsageWidget.ps1` and `windows/ClaudeUsageWidget.vbs` into one folder.
2. First run: `wscript.exe ClaudeUsageWidget.vbs`. With no settings it runs standalone (requires a Claude Code
   sign-in). For server-client mode, a `ClaudeUsageWidget.json` appears next to it — set
   `"url": "http://<host>:8766/usage.json"` in it and restart.
3. Right-click the widget → the autostart item.

The `.vbs` launcher finds PowerShell 7 itself (`pwsh.exe` in Program Files, the Store alias or PATH) and uses
Windows PowerShell 5.1 only when it is absent. It starts through `.vbs` rather than `pwsh -WindowStyle Hidden`: Windows Terminal, when it is the default
terminal, ignores that flag and shows a console window; it does respect the hidden-window flag passed through
`WScript.Shell.Run(..., 0)`.

### Widget menu (right-click)

- **On the taskbar (auto position)**: places itself left of the tray, height = taskbar height. Dragging it with
  the mouse turns auto mode off.
- **Right-aligned text**.
- **Summary** (at the top of the menu and in the hover tooltip): the 5-hour window, the week and the separate
  Fable limit; for the weekly limits — an even pace for the rest of the week (% per day, rounded to 10%).
- **Sign in to Claude…** (standalone mode): opens Claude Code to sign in.
- **Autostart** (HKCU\...\Run).

## Technical notes

- **Language**: English or Russian, by the Windows display language; to force one, set `"lang": "en"` or
  `"lang": "ru"` in `ClaudeUsageWidget.json`.
- **DPI**: the process declares per-monitor DPI awareness v2; all sizes are logical px x DPI. Without it, at
  scaling above 100% Windows stretches the window as a bitmap and it gets blurry.
- **Transparency**: `TransparencyKey`. A side effect is that ClearType produces colour fringes on colour-keyed
  windows, so the text is smoothed in greyscale (GDI+ `AntiAliasGridFit`).
- **Z-order**: the taskbar is topmost too and floats above the widget after each of its own updates. A watchdog
  checks `WindowFromPoint` on an opaque pixel of the widget once a second and brings the window back on top when
  needed. While Start or the notification centre is open, the widget stays under the taskbar — on purpose.
- **Full-screen windows**: while the active window (RDP client, SmartPSS, video, game) covers the widget's whole monitor, the
  widget hides so that it does not hang over it; it comes back by itself. The desktop and maximized windows do not count as full-screen.
- **Antivirus**: `Add-Type` with P/Invoke (`ShowWindow`, `SetWindowPos`, `FindWindow`) is a classic false
  positive for heuristics. The widget moves `TEMP` to a `tmp` subfolder next to the script; it is worth adding
  the script folder to the exclusions.

## Layout

```
server/
  usage_server.py        API polling, plan calculation, HTTP serving (stdlib)
  config.example.json    thresholds, time zone, plan end
  watchdog.sh            start/restart of the service (for cron)
  install.sh             crontab @reboot + */5, start
windows/
  Setup.cmd              installer from the archive (runs install.ps1)
  install.ps1            copy to %LOCALAPPDATA%, Claude Code + sign-in, autostart, shortcuts
  uninstall.ps1          uninstall (does not touch Claude Code)
  ClaudeUsageWidget.ps1  the taskbar widget
  ClaudeUsageWidget.vbs  launcher with a hidden console
  ClaudeUsageTray.ps1    the old variant: three tray icons (5h %, reset time, week)
  setup/Setup.cs         single-file installer: wizard and silent variant (the same files inside the exe)
  setup/build.ps1        builds it with the C# compiler that ships with Windows, no SDK
docs/                    screenshots for the README
```

## Limitations

- Subscription accounts only (Claude Code OAuth). The endpoint returns nothing for API keys.
- The usage and token-refresh endpoints are undocumented; Anthropic may change them.
- Standalone mode refreshes the token itself. If Claude Code is running on the same PC at that moment, a race for
  the refresh token is possible (it is single-use): in the worst case Claude Code asks you to sign in again. The
  widget refreshes the token only once it has already expired, to keep this to a minimum.
- The Windows 11 taskbar does not accept third-party deskbands, so the widget is a separate borderless topmost
  window rather than a part of the taskbar.
- Windows Widgets (Win+W) require an MSIX package with `IWidgetProvider` — not worth the effort.

## Support

If the widget turned out useful, you can buy me a coffee:

- **Dogecoin**: `D7z9UaBsmcV7EqJo5Y5fdLG9xUNw47dNgr`

## License

MIT.
