@echo off
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
chcp 65001 >nul
title Douyin Killer

"%PS%" -NoProfile -Command "exit ([int](-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))" >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    set "DOUYIN_LAUNCHER=%~f0"
    "%PS%" -NoProfile -Command "try { $p = Start-Process -FilePath $env:DOUYIN_LAUNCHER -Verb RunAs -PassThru -ErrorAction Stop; $p.WaitForExit(); exit $p.ExitCode } catch { Write-Host $_.Exception.Message; exit 1 }"
    if errorlevel 1 exit /b 1
    exit /b 0
)

:menu
cls
echo ============================================================
echo   Douyin Killer
echo   Target directory: auto-detected; DOUYIN_ROOT overrides it
echo ============================================================
echo.
echo   --- DAILY USE ---
echo   [1] Open Douyin  - allow net + launch + auto-clean on exit
echo                      (same as Start-Douyin.bat, one UAC)
echo   [2] Finish       - block net + kill residue (if you launched
echo                      Douyin by some other way)
echo.
echo   --- DIAGNOSTICS ---
echo   [3] Status       - health check only, changes nothing
echo.
echo   --- SINGLE ACTIONS ---
echo   [4] Clean        - kill residual processes only
echo   [5] Block        - block network only
echo   [6] Allow        - open network only
echo.
echo   --- SETUP ---
echo   [7] Lockdown     - first-time setup (autostart off + net block)
echo   [8] Unlock       - restore recorded settings + remove isolation
echo   [S] Fix shortcut - point the Start Menu "Douyin" icon here
echo                      (keeps the original Douyin icon)
echo.
echo   [9] Exit
echo.
choice /c 12345678S9 /n /m "Choose [1-9, S]: "
if errorlevel 10 exit /b 0
if errorlevel 9 goto shortcut
if errorlevel 8 goto unlock
if errorlevel 7 goto lockdown
if errorlevel 6 goto allow
if errorlevel 5 goto block
if errorlevel 4 goto clean
if errorlevel 3 goto status
if errorlevel 2 goto finish
if errorlevel 1 goto session
goto menu

:session
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Session
if errorlevel 1 goto failed
echo.
echo   Douyin is starting. Fully exit from the tray/background --
echo   cleanup will happen automatically.
echo.
pause
goto menu

:finish
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Finish
if errorlevel 1 goto failed
echo.
pause
goto menu

:status
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Status
echo.
pause
goto menu

:clean
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Clean
echo.
pause
goto menu

:block
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Block
echo.
pause
goto menu

:allow
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Allow
if errorlevel 1 goto failed
echo.
echo   Network is OPEN. Launch Douyin now.
echo.
pause
goto menu

:failed
echo.
echo   Operation failed. Check the error above and the log.
pause
goto menu

:lockdown
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Lockdown
echo.
pause
goto menu

:shortcut
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-DouyinShortcut.ps1"
echo.
pause
goto menu

:unlock
echo.
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0DouyinKiller.ps1" -Action Unlock
echo.
pause
goto menu
