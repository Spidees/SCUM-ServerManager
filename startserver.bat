@echo off
:: Check if running as administrator
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo This script must be run as administrator.
    echo Relaunching with elevated privileges...
    powershell -Command "Start-Process '%~f0' -Verb runAs"
    exit /b
)

:: Run the PowerShell script with ExecutionPolicy Bypass and save PID
powershell -ExecutionPolicy Bypass -Command "& { $process = Start-Process powershell -ArgumentList '-ExecutionPolicy', 'Bypass', '-File', '%~dp0SCUMServer.ps1' -PassThru; $process.Id | Out-File '%~dp0scum_automation.pid' -Encoding ascii }"

echo PowerShell automation script started.
echo Use stopserver.bat to stop the automation.
echo This window will close automatically in 3 seconds...
timeout /t 3 /nobreak >nul
