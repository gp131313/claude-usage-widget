' Лаунчер виджета: запускает pwsh со скрытым окном консоли (флаг 0 через STARTUPINFO, его уважает и Windows Terminal).
Set sh = CreateObject("WScript.Shell")
pwsh = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\WindowsApps\pwsh.exe"
sh.Run """" & pwsh & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""C:\ClaudeScripts\ClaudeUsageWidget.ps1""", 0, False
