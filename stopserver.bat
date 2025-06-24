@echo off
setlocal enabledelayedexpansion
:: Check if running as administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo This script must be run as administrator.
    echo Relaunching with elevated privileges...
    powershell -Command "Start-Process '%~f0' -Verb runAs"
    exit /b
)

echo Stopping SCUM server service...
net stop SCUMSERVER

if %errorLevel% equ 0 (
    echo SCUM server service stopped successfully.
) else (
    echo Failed to stop SCUM server service or service was not running.
)

echo.
echo Stopping PowerShell automation script...
if exist "%~dp0scum_automation.pid" (
    set /p PID=<"%~dp0scum_automation.pid"
    taskkill /f /pid !PID! >nul 2>&1
    if !errorLevel! equ 0 (
        echo PowerShell automation script stopped ^(PID: !PID!^).
        del "%~dp0scum_automation.pid" >nul 2>&1
    ) else (
        echo PowerShell automation script was not running or already stopped.
        del "%~dp0scum_automation.pid" >nul 2>&1
    )
) else (
    echo No PowerShell automation script PID file found.
)

pause
