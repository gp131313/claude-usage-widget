' Лаунчер виджета: запускает ClaudeUsageWidget.ps1 из этой же папки без окна консоли.
' Флаг скрытого окна (0) передаётся через STARTUPINFO — его уважает и Windows Terminal.
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps  = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
sh.Run """" & ps & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\ClaudeUsageWidget.ps1""", 0, False
