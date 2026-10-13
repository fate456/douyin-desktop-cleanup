@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
title Fix Douyin shortcut

rem ============================================================
rem  Point the Start Menu "Douyin" icon at this folder's
rem  one-click launcher (Start-Douyin.bat), keeping the icon.
rem
rem    Install-DouyinShortcut.bat            install
rem    Install-DouyinShortcut.bat -Revert    undo
rem    Install-DouyinShortcut.bat -Verify    check only
rem ============================================================

if /i "%~1"=="-Verify" goto run
"%PS%" -NoProfile -Command "exit ([int](-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))" >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    set "DOUYIN_LAUNCHER=%~f0"
    set "DOUYIN_INSTALL_ARGS=%*"
    "%PS%" -NoProfile -Command "try { $opts = @{ FilePath = $env:DOUYIN_LAUNCHER; Verb = 'RunAs'; PassThru = $true; ErrorAction = 'Stop' }; if ($env:DOUYIN_INSTALL_ARGS) { $opts.ArgumentList = $env:DOUYIN_INSTALL_ARGS }; $p = Start-Process @opts; $p.WaitForExit(); exit $p.ExitCode } catch { Write-Host $_.Exception.Message; exit 1 }"
    if errorlevel 1 exit /b 1
    exit /b 0
)

:run
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DouyinShortcut.ps1" %*
set RC=%errorlevel%
echo.
pause
exit /b %RC%
