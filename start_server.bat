@echo off
echo.
echo ================================================================
echo                   SCUM Server - START  
echo ================================================================
echo  This will start the SCUM server service.
echo  Players will be able to connect to your server.
echo.
echo  RECOMMENDATION: Start the automation first for best results:
echo  - Run start_scum_server_automation.bat before this script
echo  - The automation will manage server health and restarts
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

:: Read service name from config
echo [INFO] Reading server configuration...
for /f "delims=" %%i in ('powershell -Command "(Get-Content '%~dp0SCUM-Server-Automation.config.json' | ConvertFrom-Json).serviceName 2>$null"') do set "SERVICE_NAME=%%i"
if "%SERVICE_NAME%"=="" (
    echo [WARNING] Could not read service name from config, using default: SCUMSERVER
    set "SERVICE_NAME=SCUMSERVER"
) else (
    echo [INFO] Service name from config: %SERVICE_NAME%
)

echo.
echo [INFO] Starting SCUM server service: %SERVICE_NAME%
net start "%SERVICE_NAME%"

if %errorLevel% equ 0 (
    echo.
    echo ================================================================
    echo  SUCCESS: SCUM Server started successfully
    echo ================================================================
    echo  * Service "%SERVICE_NAME%" is now running
    echo  * Players can connect to your server
    echo  * Server is ready for gameplay
    echo ================================================================
    echo.
    echo [REMINDER] Don't forget to start the automation:
    echo            start_scum_server_automation.bat
    echo            (This manages automatic restarts, backups, updates)
) else (
    echo.
    echo ================================================================
    echo  ERROR: Failed to start SCUM Server
    echo ================================================================
    echo  * Service "%SERVICE_NAME%" failed to start
    echo  * Check Windows Event Log for details
    echo  * Verify server configuration and files
    echo ================================================================
    echo.
    echo Common solutions:
    echo * Check if server files are corrupted
    echo * Verify port availability  
    echo * Review server configuration
    echo * Check Windows Services manually
    echo * Make sure no other instance is running
)

echo.
pause
