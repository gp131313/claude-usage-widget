@echo off
rem Установка Claude Usage Widget — двойной клик по этому файлу. PowerShell 7, если есть; иначе Windows PowerShell 5.1.
set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PS%" set "PS=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if not exist "%PS%" for %%I in (pwsh.exe) do set "PS=%%~$PATH:I"
if "%PS%"=="" set "PS=powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"