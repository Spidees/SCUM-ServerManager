@echo off
echo.
echo ================================================================
echo                    SCUM Server - STOP
echo ================================================================
echo  This will stop the SCUM server service completely.
echo  All players will be disconnected from the server.
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
echo WARNING: This will stop the server service: %SERVICE_NAME%
echo WARNING: All connected players will be disconnected!
echo.
choice /c YN /m "Are you sure you want to stop the server"
if %errorLevel% neq 1 (
    echo.
    echo [INFO] Operation cancelled by user.
    pause
    exit /b
)

echo.
echo [INFO] Stopping SCUM server service: %SERVICE_NAME%
net stop "%SERVICE_NAME%"

if %errorLevel% equ 0 (
    echo.
    echo ================================================================
    echo  SUCCESS: SCUM Server stopped successfully
    echo ================================================================
    echo  * Service "%SERVICE_NAME%" has been stopped
    echo  * All players have been disconnected
    echo  * Use start_server.bat to restart the server
    echo ================================================================
) else (
    echo.
    echo ================================================================
    echo  WARNING: Server stop result
    echo ================================================================
    echo  * Service "%SERVICE_NAME%" was not running or failed to stop
    echo  * This might be normal if the server was already stopped
    echo ================================================================
)

echo.
pause
