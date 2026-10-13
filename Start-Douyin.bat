@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
chcp 65001 >nul
title Douyin

rem ============================================================
rem  One-click Douyin session launcher
rem    1. opens the firewall for Douyin
rem    2. launches the detected Douyin installation
rem    3. attaches a hidden watcher
rem    4. after background exit -> blocks net + cleans verified residue
rem
rem  Pin this file to the taskbar / Start Menu for one-click use.
rem ============================================================

"%PS%" -NoProfile -Command "exit ([int](-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))" >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    set "DOUYIN_LAUNCHER=%~f0"
    "%PS%" -NoProfile -Command "try { $p = Start-Process -FilePath $env:DOUYIN_LAUNCHER -Verb RunAs -PassThru -ErrorAction Stop; $p.WaitForExit(); exit $p.ExitCode } catch { Write-Host $_.Exception.Message; exit 1 }"
    if errorlevel 1 exit /b 1
    exit /b 0
)

set "KILLER=%~dp0DouyinKiller.ps1"

if not exist "%KILLER%" (
    echo.
    echo   ERROR: DouyinKiller.ps1 not found next to this script.
    echo   Expected: %KILLER%
    echo.
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%KILLER%" -Action Session
if errorlevel 1 (
    echo.
    echo   ERROR: Douyin session failed. Check the error above and the log.
    pause
    exit /b 1
)

echo.
echo   Douyin is running. Nothing else to do.
echo   After you fully exit Douyin from the tray/background,
echo   the network will be blocked again
echo   and all residual processes will be cleaned automatically.
echo.
"%PS%" -NoProfile -Command "Start-Sleep -Seconds 2"
exit /b 0
