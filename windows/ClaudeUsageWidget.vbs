' Лаунчер виджета: запускает ClaudeUsageWidget.ps1 из этой же папки без окна консоли.
' Хост — PowerShell 7 (pwsh.exe: Program Files, алиас Store-версии, PATH); если его нет — Windows PowerShell 5.1.
' Флаг скрытого окна (0) передаётся через STARTUPINFO — его уважает и Windows Terminal.
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = ""
cands = Array(sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe", _
              sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\WindowsApps\pwsh.exe")
For Each c In cands
    If ps = "" Then
        If fso.FileExists(c) Then ps = c
    End If
Next
If ps = "" Then
    For Each d In Split(sh.ExpandEnvironmentStrings("%PATH%"), ";")
        If ps = "" And d <> "" Then
            If fso.FileExists(d & "\pwsh.exe") Then ps = d & "\pwsh.exe"
        End If
    Next
End If
If ps = "" Then ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
sh.Run """" & ps & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & dir & "\ClaudeUsageWidget.ps1""", 0, False