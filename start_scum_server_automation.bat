@echo off
echo.
echo ================================================================
echo               SCUM Server Automation Launcher
echo ================================================================
echo  This will start the PowerShell automation script that manages
echo  your SCUM server automatically (restarts, backups, updates).
echo ================================================================
echo.

:: Check if running as administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] This script must be run as administrator.
    echo.
    echo Relaunching with elevated privileges...
    powershell -Command "Start-Process '%~f0' -Verb runAs"
    exit /b
)

echo [INFO] Starting SCUM Server Automation...
echo.

:: Run the PowerShell script with ExecutionPolicy Bypass and save PID
powershell -ExecutionPolicy Bypass -Command "& { $process = Start-Process powershell -ArgumentList '-ExecutionPolicy', 'Bypass', '-File', '%~dp0SCUM-Server-Automation.ps1' -PassThru; $process.Id | Out-File '%~dp0scum_automation.pid' -Encoding ascii; Write-Host '[SUCCESS] PowerShell automation started (PID:' $process.Id ')' }"

if %errorLevel% equ 0 (
    echo.
    echo ================================================================
    echo  SCUM Server Automation is now running!
    echo ================================================================
    echo  * You should see a PowerShell window with live logs
    echo  * The automation will manage your server automatically  
    echo  * Check SCUM-Server-Automation.log for detailed history
    echo ================================================================
    echo.
    echo This window will close in 5 seconds...
    timeout /t 5 /nobreak >nul
) else (
    echo.
    echo [ERROR] Failed to start SCUM Server Automation
    echo Please check the PowerShell script and try again.
    echo.
    pause
)
