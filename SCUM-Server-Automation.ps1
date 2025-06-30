# ==========================
# SCUM Server Automation - Dedicated Server Management for Windows
# ==========================
param(
    [hashtable]$ScriptArgs = @{}
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "=== SCUM Server Automation - Dedicated Server Management for Windows ===" -ForegroundColor Green

# --- MODULE IMPORT ---
$ModulesPath = Join-Path $PSScriptRoot "modules"

try {
    # Suppress PowerShell verb warnings for cleaner output
    $WarningPreference = 'SilentlyContinue'
    
    # Import modules in dependency order with new structure
    Import-Module (Join-Path $ModulesPath "core\common\common.psm1") -Force -Global -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "communication\notifications\notifications.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "communication\events\events.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "communication\adapters.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "server\service\service.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "automation\backup\backup.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "automation\update\update.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "server\installation\installation.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "automation\scheduling\scheduling.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "communication\admin\commands.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "core\logging\parser\parser.psm1") -Force -WarningAction SilentlyContinue
    Import-Module (Join-Path $ModulesPath "server\monitoring\monitoring.psm1") -Force -WarningAction SilentlyContinue
    
    # Restore warning preference
    $WarningPreference = 'Continue'
    
    Write-Host "[INFO] All modules loaded successfully" -ForegroundColor Green
    
    # Verify critical functions are available
    $requiredFunctions = @('Initialize-CommonModule', 'Write-Log', 'Get-SafeConfigValue', 'Test-PathExists', 'Get-TimeStamp', 'Update-MonitoringMetrics', 'Update-ServerMonitoring', 'Get-ServerStatus')
    $missingFunctions = $requiredFunctions | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
    
    if ($missingFunctions.Count -gt 0) {
        Write-Host "[ERROR] Missing functions: $($missingFunctions -join ', ')" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "[FATAL] Failed to load modules: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- CONFIG LOADING ---
$configPath = Join-Path $PSScriptRoot 'SCUM-Server-Automation.config.json'
if (!(Test-Path $configPath)) {
    Write-Host "[FATAL] Config file $configPath not found!" -ForegroundColor Red
    exit 1
}

try {
    $config = Get-Content $configPath | ConvertFrom-Json
    Write-Host "[INFO] Configuration loaded successfully" -ForegroundColor Green
} catch {
    Write-Host "[FATAL] Failed to load config: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- INITIALIZE LOGGING ---
$logPath = Join-Path $PSScriptRoot "SCUM-Server-Automation.log"
Initialize-CommonModule -Config $config -LogPath $logPath -RootPath $PSScriptRoot

Write-Log "=== SCUM Server Manager - Modular Edition Started ==="

# --- EXTRACT AND VALIDATE CONFIG USING CENTRALIZED PATH MANAGEMENT ---
$serviceName = Get-SafeConfigValue $config "serviceName" "SCUMServer"

# Get all paths from centralized cache
$backupRoot = Get-ConfigPath -PathKey "backupRoot"
$savedDir = Get-ConfigPath -PathKey "savedDir" 
$steamCmd = Get-ConfigPath -PathKey "steamCmd"
$serverDir = Get-ConfigPath -PathKey "serverDir"

$appId = Get-SafeConfigValue $config "appId" "3792580"
$restartTimes = Get-SafeConfigValue $config "restartTimes" @("02:00", "14:00", "20:00")
$backupIntervalMinutes = Get-SafeConfigValue $config "backupIntervalMinutes" 60
$periodicBackupEnabled = Get-SafeConfigValue $config "periodicBackupEnabled" $true
$updateCheckIntervalMinutes = Get-SafeConfigValue $config "updateCheckIntervalMinutes" 60
$updateDelayMinutes = Get-SafeConfigValue $config "updateDelayMinutes" 5
$maxBackups = Get-SafeConfigValue $config "maxBackups" 10
$compressBackups = Get-SafeConfigValue $config "compressBackups" $true
$runBackupOnStart = Get-SafeConfigValue $config "runBackupOnStart" $false
$runUpdateOnStart = Get-SafeConfigValue $config "runUpdateOnStart" $false

# Validate critical paths
$criticalPaths = @{
    "SteamCMD" = $steamCmd
    "Server Directory" = $serverDir
    "Saved Directory" = $savedDir
    "Backup Root" = $backupRoot
}

foreach ($pathName in $criticalPaths.Keys) {
    $path = $criticalPaths[$pathName]
    if (-not (Test-PathExists $path)) {
        Write-Log "[WARNING] $pathName path does not exist: $path" -Level Warning
    } else {
        Write-Log "[INFO] $pathName path validated: $path"
    }
}

# --- INITIALIZE MODULES ---
Initialize-NotificationModule -Config $config
Initialize-EventSystem -Config $config
Show-NotificationSettings
Initialize-ServiceModule -Config $config
Initialize-BackupModule -Config $config
Initialize-UpdateModule -Config $config
Initialize-InstallationModule -Config $config
Initialize-SchedulingModule -Config $config
Initialize-AdminCommandModule -Config $config

# Initialize LogReader with proper log path (parsing only)
$scumLogPath = Get-SafeConfigValue $config "customLogPath" $null
if (-not $scumLogPath) {
    # Default SCUM server log path
    $scumLogPath = Join-Path $savedDir "Logs\SCUM.log"
}
Initialize-LogReaderModule -Config $config -LogPath $scumLogPath

# Reset parser state to prevent log spam on startup
Reset-LogParserState

# Initialize Monitoring with server status management
Initialize-MonitoringModule -Config $config -LogPath $scumLogPath

# Initialize Discord admin command baseline to avoid processing old messages
$adminConfig = Get-SafeConfigValue $config "admin_command_channel" $null
if ($adminConfig -and $adminConfig.channelIds) {
    $botToken = Get-SafeConfigValue $config "botToken" ""
    if ($botToken) {
        Write-Log "[INFO] *** Initializing Discord admin command baseline ***"
        Write-Log "[INFO] Admin channels: $($adminConfig.channelIds -join ', ')"
        Initialize-AdminCommandBaseline -BotToken $botToken -ChannelIds $adminConfig.channelIds
        Write-Log "[INFO] *** Discord baseline initialization completed ***"
    } else {
        Write-Log "[WARNING] Bot token not configured - admin commands disabled"
    }
} else {
    Write-Log "[WARNING] Admin command channels not configured"
}

Write-Log "[INFO] All modules initialized successfully"

# --- LOG STARTUP INFO ---
Write-Log "[INFO] Service Name: $serviceName"
Write-Log "[INFO] Restart Times: $($restartTimes -join ', ')"
$backupStatus = if ($periodicBackupEnabled) { "ENABLED (every $backupIntervalMinutes min)" } else { "DISABLED" }
Write-Log "[INFO] Periodic Backup: $backupStatus"
Write-Log "[INFO] Update Check Interval: $updateCheckIntervalMinutes minutes"

# --- INITIALIZE GLOBAL STATE ---
$global:LastBackupTime = $null
$global:LastUpdateCheck = $null
$global:LastRestartTime = $null 
$global:UpdateScheduledTime = $null
$global:UpdateWarning5Sent = $false
$global:ServerIntentionallyStopped = $false
$global:LastAutoRestartAttempt = $null
$global:SkipNextScheduledRestart = $false

# Admin scheduled actions
$global:AdminRestartScheduledTime = $null
$global:AdminRestartScheduleTime = $null  # When the restart was scheduled
$global:AdminRestartWarning10Sent = $false
$global:AdminRestartWarning5Sent = $false
$global:AdminRestartWarning1Sent = $false
$global:AdminStopScheduledTime = $null
$global:AdminStopScheduleTime = $null  # When the stop was scheduled
$global:AdminStopWarning10Sent = $false
$global:AdminStopWarning5Sent = $false
$global:AdminStopWarning1Sent = $false
$global:AdminUpdateScheduledTime = $null
$global:AdminUpdateScheduleTime = $null  # When the update was scheduled
$global:AdminUpdateWarning10Sent = $false
$global:AdminUpdateWarning5Sent = $false
$global:AdminUpdateWarning1Sent = $false

$global:AutoRestartCooldownMinutes = Get-SafeConfigValue $config "autoRestartCooldownMinutes" 2
$global:MaxConsecutiveRestartAttempts = Get-SafeConfigValue $config "maxConsecutiveRestartAttempts" 3
$global:ConsecutiveRestartAttempts = 0

# Monitoring state
$global:LastServerStatus = "Unknown"
$global:MonitoringInitialized = $false
$global:ScriptStartTime = Get-Date

# Service startup tracking
$global:ServiceStartInitiated = $false
$global:ServiceStartContext = ""
$global:ServiceStartTime = $null
$global:AdminRestartInProgress = $false  # Track admin restart completion

# Send startup notification
Send-ManagerStartedEvent @{ timestamp = Get-TimeStamp }

# --- INITIALIZE RESTART WARNING SYSTEM ---
$restartWarningSystem = Initialize-RestartWarningSystem -RestartTimes $restartTimes

# --- STARTUP INITIALIZATION ---
# Check for first install using installation module
if (Test-FirstInstall -ServerDirectory $serverDir -AppId $appId) {
    Write-Log "[INFO] First install required, starting installation process"
    
    $installResult = Invoke-FirstInstall -SteamCmdPath $steamCmd -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName
    
    if ($installResult.Success) {
        if ($installResult.RequireRestart) {
            Write-Log "[INFO] =========================================="
            Write-Log "[INFO] FIRST INSTALLATION COMPLETED SUCCESSFULLY!"
            Write-Log "[INFO] =========================================="
            Write-Log "[INFO] "
            Write-Log "[INFO] IMPORTANT NEXT STEPS:"
            Write-Log "[INFO] "
            Write-Log "[INFO] 1. Configure your server in file:" 
            Write-Log "[INFO]    C:\scum\server\SCUM\Saved\Config\WindowsServer\ServerSettings.ini"
            Write-Log "[INFO] "
            Write-Log "[INFO] 2. Create Windows service using nssm.exe:"
            Write-Log "[INFO]    nssm.exe install SCUMSERVER C:\scum\server\SCUM\Binaries\Win64\SCUMServer.exe"
            Write-Log "[INFO] "
            Write-Log "[INFO] 3. Run this script again to start server monitoring"
            Write-Log "[INFO] "
            Write-Log "[INFO] =========================================="
            
            # Give a moment for notifications to be sent and user to read
            Start-Sleep -Seconds 3
            Write-Host ""
            Write-Host "Press ENTER to exit..." -ForegroundColor Yellow
            Read-Host
            exit 0
        }
    } else {
        Write-Log "[ERROR] First install failed: $($installResult.Error)" -Level Error
        # Don't exit on failure, allow manual intervention
    }
    
    $firstInstall = $true
} else {
    $firstInstall = $false
}

# Initialize SteamCMD directory for later use
$global:SteamCmdDirectory = if ($steamCmd -like "*steamcmd.exe") {
    Split-Path $steamCmd -Parent
} else {
    $steamCmd
}

# Run initial backup if enabled
if ($runBackupOnStart -and -not $firstInstall) {
    Write-Log "[INFO] Running startup backup"
    $backupResult = Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $maxBackups -CompressBackups $compressBackups
    $global:LastBackupTime = Get-Date
} elseif ($periodicBackupEnabled) {
    $global:LastBackupTime = Get-Date
    Write-Log "[INFO] Periodic backup timer initialized"
}

# Run initial update check if enabled
if ($runUpdateOnStart -and -not $firstInstall) {
    Write-Log "[INFO] Running startup update check"
    
    # Create backup before update only if not already done
    if (-not $runBackupOnStart) {
        Write-Log "[INFO] Creating backup before update check"
        Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $maxBackups -CompressBackups $compressBackups
        $global:LastBackupTime = Get-Date
    }
    
    $updateCheck = Test-UpdateAvailable -SteamCmdPath $steamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ScriptRoot $PSScriptRoot
    
    if ($updateCheck.UpdateAvailable) {
        Write-Log "[INFO] Update available! Installed: $($updateCheck.InstalledBuild) → Latest: $($updateCheck.LatestBuild)"
        Send-UpdateAvailableEvent @{ 
            installed = $updateCheck.InstalledBuild
            latest = $updateCheck.LatestBuild 
        }
        $updateResult = Invoke-ImmediateUpdate -SteamCmdPath $steamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName
    } else {
        Write-Log "[INFO] No update available"
    }
    
    $global:LastUpdateCheck = Get-Date
} elseif (-not $firstInstall) {
    # Start service if not running and not during first install
    if ($serviceExists) {
        if (-not (Test-ServiceRunning $serviceName)) {
            Write-Log "[INFO] Starting server service (normal startup)"
            Start-GameService -ServiceName $serviceName -Context "startup"
        } else {
            Write-Log "[INFO] Server service is already running"
        }
    } else {
        Write-Log "[INFO] Windows service '$serviceName' not found - skipping automatic start"
    }
}

Write-Log "[INFO] Initialization completed, starting main monitoring loop"

# Check if main loop should run
if ($ScriptArgs.RunLoop -eq $false) {
    Write-Log "[INFO] Main loop skipped (RunLoop = false)"
    return
}

# --- MAIN MONITORING LOOP ---
try {
    # Performance optimization
    $logCheckInterval = Get-SafeConfigValue $config "logCheckIntervalMs" 1000
    $statusCheckInterval = Get-SafeConfigValue $config "statusCheckIntervalMs" 2000
    $lastLogCheck = Get-Date
    $lastStatusCheck = Get-Date
    
    # Check if service exists before monitoring
    $serviceExists = Test-ServiceExists $serviceName
    if (-not $serviceExists) {
        Write-Log "[WARNING] Windows service '$serviceName' does not exist!" -Level Warning
        Write-Log "[WARNING] Monitoring will be limited. Create service using nssm.exe" -Level Warning
        Write-Log "[WARNING] Continuing in basic mode..." -Level Warning
    }
    
    # Initialize service status
    $serviceRunning = if ($serviceExists) { Test-ServiceRunning $serviceName } else { $false }
    
    while ($true) {
        try {
            $now = Get-Date
            $updateOrRestart = $false
        
        # --- STATUS MONITORING ---
        $shouldCheckStatus = ($now - $lastStatusCheck).TotalMilliseconds -ge $statusCheckInterval
        if ($shouldCheckStatus -and $serviceExists) {
            $serviceRunning = Test-ServiceRunning $serviceName
            $lastStatusCheck = $now
            
            # Log service status changes
            if (-not $global:MonitoringInitialized -or ($serviceRunning -and $global:LastServerStatus -eq "Stopped") -or (-not $serviceRunning -and $global:LastServerStatus -eq "Running")) {
                Write-Log "[INFO] Service status change: $serviceName = $serviceRunning"
            }
            
            # Initialize monitoring on first run
            if (-not $global:MonitoringInitialized) {
                $global:MonitoringInitialized = $true
                $global:LastServerStatus = if ($serviceRunning) { "Running" } else { "Stopped" }
                Write-Log "[INFO] Monitoring initialized - Service status: $($global:LastServerStatus)"
            }
            
            # Detect status changes
            $currentStatus = if ($serviceRunning) { "Running" } else { "Stopped" }
            if ($currentStatus -ne $global:LastServerStatus) {
                Write-Log "[STATUS] Service $($global:LastServerStatus) → $currentStatus"
                $global:LastServerStatus = $currentStatus
                
                # Reset restart counters on successful start
                if ($currentStatus -eq "Running") {
                    $global:ConsecutiveRestartAttempts = 0
                    $global:LastAutoRestartAttempt = $null
                    $global:ServerIntentionallyStopped = $false
                }
            }
            
            # Update performance metrics only if server is running
            if ($serviceRunning) {
                Update-MonitoringMetrics
            }
        }
        
        # --- SERVER MONITORING ---
        $shouldCheckLogs = ($now - $lastLogCheck).TotalMilliseconds -ge $logCheckInterval
        if ($shouldCheckLogs) {
            Write-Log "[Main] Calling Update-ServerMonitoring (serviceRunning=$serviceRunning, interval=$logCheckInterval)" -Level Debug
            # Use monitoring module to update server status and process events
            # NOTE: This now monitors both service status AND logs, so we call it regardless of service status
            $processedEvents = Update-ServerMonitoring -ServiceName $serviceName
            Write-Log "[Main] Update-ServerMonitoring returned $($processedEvents.Count) events" -Level Debug
            
            if ($processedEvents -and $processedEvents.Count -gt 0) {
                # Debug: Log all events before filtering
                Write-Log "[Main] Processing $($processedEvents.Count) events from monitoring:" -Level Debug
                foreach ($event in $processedEvents) {
                    Write-Log "[Main]   Event: $($event.EventType), IsStateChange: $($event.IsStateChange)" -Level Debug
                }
                
                # Only log state changes and important events (not routine monitoring)
                $stateChangeEvents = $processedEvents | Where-Object { 
                    $_.EventType -in @('ServerOnline', 'ServerStarting', 'ServerLoading', 'ServerShuttingDown', 'AdminAction') -and $_.IsStateChange
                }
                
                Write-Log "[Main] Found $($stateChangeEvents.Count) state change events" -Level Debug
                if ($stateChangeEvents -and $stateChangeEvents.Count -gt 0) {
                    # Only log state changes, not all events
                    foreach ($event in $stateChangeEvents) {
                        Write-Log "[SERVER] $($event.EventType): $($event.Message)"
                        
                        # Reset admin restart tracking when server comes online
                        if ($event.EventType -eq 'ServerOnline' -and $global:AdminRestartInProgress) {
                            Write-Log "[AdminCommands] Server came online after admin restart - tracking completed"
                            $global:AdminRestartInProgress = $false
                        }
                        
                        # Reset service start tracking when server comes online  
                        if ($event.EventType -eq 'ServerOnline' -and $global:ServiceStartInitiated -and -not $global:AdminRestartInProgress) {
                            Write-Log "[Main] Server came online after startup - tracking completed"
                            $global:ServiceStartInitiated = $false
                            $global:ServiceStartContext = ""
                            $global:ServiceStartTime = $null
                        }
                    }
                }
            }
            $lastLogCheck = $now
        } elseif ($shouldCheckLogs) {
            Write-Log "[Main] No events from monitoring - service not running" -Level Info
            $lastLogCheck = $now
        }
        
        # --- ADMIN COMMAND PROCESSING ---
        $adminConfig = Get-SafeConfigValue $config "admin_command_channel" $null
        if ($adminConfig -and $adminConfig.channelIds -and $adminConfig.roleIds) {
            $botToken = Get-SafeConfigValue $config "botToken" ""
            if ($botToken) {
                try {
                    Invoke-AdminCommandPolling -BotToken $botToken -ChannelIds $adminConfig.channelIds -RoleIds $adminConfig.roleIds -CommandPrefix $adminConfig.commandPrefix -ServiceName $serviceName -GuildId $adminConfig.guildId
                } catch {
                    Write-Log "[AdminCommands] Error processing admin commands: $($_.Exception.Message)" -Level Warning
                }
            }
        }
        
        # --- ADMIN SCHEDULED ACTIONS ---
        # Check for delayed admin restart
        if ($global:AdminRestartScheduledTime -and $now -ge $global:AdminRestartScheduledTime) {
            Write-Log "[AdminCommands] Executing scheduled restart"
            try {
                Send-AdminRestartImmediateEvent @{}
                $global:ServerIntentionallyStopped = $false
                
                # Create backup before restart
                try {
                    $savedDir = Get-ConfigPath -PathKey "savedDir"
                    $backupRoot = Get-ConfigPath -PathKey "backupRoot"
                    if ((Test-Path $savedDir) -and (Get-SafeConfigValue $config "compressBackups" $true)) {
                        Write-Log "[AdminCommands] Creating backup before scheduled restart"
                        Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups (Get-SafeConfigValue $config "maxBackups" 10) -CompressBackups $true
                    }
                } catch {
                    Write-Log "[AdminCommands] Warning: Could not create backup before scheduled restart - $($_.Exception.Message)" -Level Warning
                }
                
                Restart-GameService -ServiceName $serviceName -Reason "scheduled admin restart" 
                $global:AdminRestartInProgress = $true  # Mark admin restart in progress
            } catch {
                Write-Log "[AdminCommands] Error executing scheduled restart: $($_.Exception.Message)" -Level Error
                Send-ServerRestartFailedEvent @{ error = $_.Exception.Message }
            }
            $global:AdminRestartScheduledTime = $null
            $global:AdminRestartScheduleTime = $null
            $global:AdminRestartWarning10Sent = $false
            $global:AdminRestartWarning5Sent = $false
            $global:AdminRestartWarning1Sent = $false
        }
        
        # Check for delayed admin stop
        if ($global:AdminStopScheduledTime -and $now -ge $global:AdminStopScheduledTime) {
            Write-Log "[AdminCommands] Executing scheduled stop"
            try {
                Send-AdminStopImmediateEvent @{}
                $global:ServerIntentionallyStopped = $true
                Stop-GameService -ServiceName $serviceName -Reason "scheduled admin stop"
            } catch {
                Write-Log "[AdminCommands] Error executing scheduled stop: $($_.Exception.Message)" -Level Error
            }
            $global:AdminStopScheduledTime = $null
            $global:AdminStopScheduleTime = $null
            $global:AdminStopWarning10Sent = $false
            $global:AdminStopWarning5Sent = $false
            $global:AdminStopWarning1Sent = $false
        }
        
        # Check for delayed admin update
        if ($global:AdminUpdateScheduledTime -and $now -ge $global:AdminUpdateScheduledTime) {
            Write-Log "[AdminCommands] Executing scheduled update"
            try {
                Send-AdminUpdateImmediateEvent @{}
                
                # Validate paths
                $steamCmd = Get-ConfigPath -PathKey "steamCmd"
                $serverDir = Get-ConfigPath -PathKey "serverDir"
                
                if (-not (Test-Path $steamCmd)) {
                    throw "SteamCMD not found at: $steamCmd"
                }
                
                # Create backup before update
                try {
                    $savedDir = Get-ConfigPath -PathKey "savedDir"
                    $backupRoot = Get-ConfigPath -PathKey "backupRoot"
                    if ((Test-Path $savedDir) -and (Get-SafeConfigValue $config "compressBackups" $true)) {
                        Write-Log "[AdminCommands] Creating backup before scheduled update"
                        Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups (Get-SafeConfigValue $config "maxBackups" 10) -CompressBackups $true
                    }
                } catch {
                    Write-Log "[AdminCommands] Warning: Could not create backup before scheduled update - $($_.Exception.Message)" -Level Warning
                }
                
                # Stop service if running
                if (Test-ServiceRunning $serviceName) {
                    Stop-GameService -ServiceName $serviceName -Reason "scheduled update"
                }
                
                # Perform update
                $updateResult = Update-GameServer -SteamCmdPath $steamCmd -ServerDirectory $serverDir -AppId (Get-SafeConfigValue $config "appId" "3792580") -ServiceName $serviceName
                
                if ($updateResult.Success) {
                    Write-Log "[AdminCommands] Scheduled update completed successfully"
                    Send-UpdateCompletedEvent @{}
                    
                    # Start service after update
                    Start-GameService -ServiceName $serviceName -Context "post-scheduled-update"
                } else {
                    Write-Log "[AdminCommands] Scheduled update failed: $($updateResult.Error)" -Level Error
                    Send-UpdateFailedEvent @{ error = $updateResult.Error }
                }
            } catch {
                Write-Log "[AdminCommands] Error executing scheduled update: $($_.Exception.Message)" -Level Error
                Send-UpdateFailedEvent @{ error = $_.Exception.Message }
            }
            $global:AdminUpdateScheduledTime = $null
            $global:AdminUpdateScheduleTime = $null
            $global:AdminUpdateWarning10Sent = $false
            $global:AdminUpdateWarning5Sent = $false
            $global:AdminUpdateWarning1Sent = $false
        }
        
        # --- WARNING SYSTEM FOR SCHEDULED ACTIONS ---
        # Warning notifications for scheduled restart
        if ($global:AdminRestartScheduledTime) {
            $minutesLeft = ($global:AdminRestartScheduledTime - $now).TotalMinutes
            $originalDelayMinutes = ($global:AdminRestartScheduledTime - $global:AdminRestartScheduleTime).TotalMinutes
            
            # Send warnings based on original schedule duration to avoid duplicates:
            # - For 15+ minute schedules: warn at 10, 5, 1 minute
            # - For 6-14 minute schedules: warn at 5, 1 minute  
            # - For 2-5 minute schedules: warn only at 1 minute (no 5-minute warning to avoid duplicate)
            
            if ($originalDelayMinutes -gt 14 -and $minutesLeft -le 10 -and $minutesLeft -gt 8 -and -not $global:AdminRestartWarning10Sent) {
                $global:AdminRestartWarning10Sent = $true
                Send-AdminRestartWarningEvent @{ minutesLeft = 10 }
            } elseif ($originalDelayMinutes -gt 5 -and $minutesLeft -le 5 -and $minutesLeft -gt 3 -and -not $global:AdminRestartWarning5Sent) {
                $global:AdminRestartWarning5Sent = $true
                Send-AdminRestartWarningEvent @{ minutesLeft = 5 }
            } elseif ($minutesLeft -le 1 -and -not $global:AdminRestartWarning1Sent) {
                $global:AdminRestartWarning1Sent = $true
                Send-AdminRestartWarningEvent @{ minutesLeft = 1 }
            }
        }
        
        # Warning notifications for scheduled stop
        if ($global:AdminStopScheduledTime) {
            $minutesLeft = ($global:AdminStopScheduledTime - $now).TotalMinutes
            $originalDelayMinutes = ($global:AdminStopScheduledTime - $global:AdminStopScheduleTime).TotalMinutes
            
            if ($originalDelayMinutes -gt 14 -and $minutesLeft -le 10 -and $minutesLeft -gt 8 -and -not $global:AdminStopWarning10Sent) {
                $global:AdminStopWarning10Sent = $true
                Send-AdminStopWarningEvent @{ minutesLeft = 10 }
            } elseif ($originalDelayMinutes -gt 5 -and $minutesLeft -le 5 -and $minutesLeft -gt 3 -and -not $global:AdminStopWarning5Sent) {
                $global:AdminStopWarning5Sent = $true
                Send-AdminStopWarningEvent @{ minutesLeft = 5 }
            } elseif ($minutesLeft -le 1 -and -not $global:AdminStopWarning1Sent) {
                $global:AdminStopWarning1Sent = $true
                Send-AdminStopWarningEvent @{ minutesLeft = 1 }
            }
        }
        
        # Warning notifications for scheduled update
        if ($global:AdminUpdateScheduledTime) {
            $minutesLeft = ($global:AdminUpdateScheduledTime - $now).TotalMinutes
            $originalDelayMinutes = ($global:AdminUpdateScheduledTime - $global:AdminUpdateScheduleTime).TotalMinutes
            
            if ($originalDelayMinutes -gt 14 -and $minutesLeft -le 10 -and $minutesLeft -gt 8 -and -not $global:AdminUpdateWarning10Sent) {
                $global:AdminUpdateWarning10Sent = $true
                Send-AdminUpdateWarningEvent @{ minutesLeft = 10 }
            } elseif ($originalDelayMinutes -gt 5 -and $minutesLeft -le 5 -and $minutesLeft -gt 3 -and -not $global:AdminUpdateWarning5Sent) {
                $global:AdminUpdateWarning5Sent = $true
                Send-AdminUpdateWarningEvent @{ minutesLeft = 5 }
            } elseif ($minutesLeft -le 1 -and -not $global:AdminUpdateWarning1Sent) {
                $global:AdminUpdateWarning1Sent = $true
                Send-AdminUpdateWarningEvent @{ minutesLeft = 1 }
            }
        }
        
        # --- SERVICE STARTUP TIMEOUT MONITORING ---
        if ($global:ServiceStartInitiated) {
            $startupElapsed = ($now - $global:ServiceStartTime).TotalMinutes
            $maxStartupMinutes = Get-SafeConfigValue $config "serverStartupTimeoutMinutes" 10
            
            # Only check for timeout - success is handled by ServerOnline event processing above
            if ($startupElapsed -gt $maxStartupMinutes) {
                Write-Log "[ERROR] Service startup timeout after $maxStartupMinutes minutes" -Level Error
                Send-StartupTimeoutEvent @{ 
                    timeout = $maxStartupMinutes
                    context = $global:ServiceStartContext 
                }
                $global:ServiceStartInitiated = $false
                $global:ServiceStartContext = ""
                $global:ServiceStartTime = $null
            }
        }
        
        # --- AUTO-RESTART LOGIC ---
        if (-not $updateOrRestart -and -not $global:ServiceStartInitiated) {
            if (-not $serviceRunning -and -not $global:ServerIntentionallyStopped) {
                $timeSinceLastAttempt = if ($global:LastAutoRestartAttempt) { 
                    ($now - $global:LastAutoRestartAttempt).TotalMinutes 
                } else { 999 }
                
                $canRestart = ($global:ConsecutiveRestartAttempts -lt $global:MaxConsecutiveRestartAttempts) -and 
                             ($timeSinceLastAttempt -ge $global:AutoRestartCooldownMinutes)
                
                if ($canRestart) {
                    # Check if stop was intentional
                    if (Test-IntentionalStop -ServiceName $serviceName -ServerDirectory $serverDir) {
                        Write-Log "[INFO] Detected intentional stop - disabling auto-restart"
                        $global:ServerIntentionallyStopped = $true
                        $global:ConsecutiveRestartAttempts = 0
                        $global:LastAutoRestartAttempt = $null
                    } else {
                        # Attempt auto-restart
                        $global:LastAutoRestartAttempt = $now
                        $global:ConsecutiveRestartAttempts++
                        
                        Write-Log "[AUTO-RESTART] Attempt $($global:ConsecutiveRestartAttempts)/$($global:MaxConsecutiveRestartAttempts)"
                        Send-ServerCrashedEvent @{ 
                            restartAttempt = $global:ConsecutiveRestartAttempts 
                        }
                        Start-GameService -ServiceName $serviceName -Context "auto-restart"
                    }
                }
            }
        }
        
        # --- SCHEDULED RESTART WARNINGS ---
        # Ensure $restartWarningSystem is a hashtable (fix for System.Object[] error)
        if ($restartWarningSystem -is [array]) {
            Write-Log "[WARNING] restartWarningSystem is an array, taking first element"
            $restartWarningSystem = $restartWarningSystem[0]
        }
        if ($restartWarningSystem -isnot [hashtable]) {
            Write-Log "[ERROR] restartWarningSystem is not a hashtable, reinitializing"
            $restartWarningSystem = Initialize-RestartWarningSystem -RestartTimes $restartTimes
        }
        $restartWarningSystem = Update-RestartWarnings -WarningState $restartWarningSystem -CurrentTime $now
        
        # --- SCHEDULED RESTART EXECUTION ---
        # Ensure $restartWarningSystem is still a hashtable
        if ($restartWarningSystem -is [array]) {
            Write-Log "[WARNING] restartWarningSystem is an array before restart check, taking first element"
            $restartWarningSystem = $restartWarningSystem[0]
        }
        if (Test-ScheduledRestartDue -WarningState $restartWarningSystem -CurrentTime $now) {
            $skipThisRestart = $global:SkipNextScheduledRestart
            $restartWarningSystem = Invoke-ScheduledRestart -WarningState $restartWarningSystem -ServiceName $serviceName -SkipRestart $skipThisRestart
            
            # Ensure the return value is still a hashtable
            if ($restartWarningSystem -is [array]) {
                Write-Log "[WARNING] restartWarningSystem is an array after Invoke-ScheduledRestart, taking first element"
                $restartWarningSystem = $restartWarningSystem[0]
            }
            
            if ($skipThisRestart) {
                $global:SkipNextScheduledRestart = $false
            } else {
                $global:LastRestartTime = $now
                $updateOrRestart = $true
            }
        }
        
        # --- PERIODIC BACKUP ---
        if ($periodicBackupEnabled -and ($null -ne $global:LastBackupTime) -and 
            (($now - $global:LastBackupTime).TotalMinutes -ge $backupIntervalMinutes) -and 
            (-not $updateOrRestart)) {
            Write-Log "[BACKUP] Creating periodic backup"
            Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $maxBackups -CompressBackups $compressBackups
            $global:LastBackupTime = $now
        }
        
        # --- PERIODIC UPDATE CHECK ---
        if (($null -eq $global:LastUpdateCheck -or 
            (($now - $global:LastUpdateCheck).TotalMinutes -ge $updateCheckIntervalMinutes)) -and 
            (-not $updateOrRestart) -and ($null -eq $global:UpdateScheduledTime)) {
            
            Write-Log "[UPDATE] Checking for updates"
            
            $updateCheck = Test-UpdateAvailable -SteamCmdPath $global:SteamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ScriptRoot $PSScriptRoot
            
            if ($updateCheck.UpdateAvailable) {
                Write-Log "[UPDATE] Available! Installed: $($updateCheck.InstalledBuild) → Latest: $($updateCheck.LatestBuild)"
                
                if (-not $serviceRunning) {
                    # Server is offline, update immediately
                    Send-UpdateAvailableEvent @{ 
                        installed = $updateCheck.InstalledBuild
                        latest = $updateCheck.LatestBuild 
                    }
                    $updateResult = Invoke-ImmediateUpdate -SteamCmdPath $global:SteamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName
                } else {
                    # Server is online, schedule update
                    $global:UpdateScheduledTime = $now.AddMinutes($updateDelayMinutes)
                    Send-UpdateAvailableEvent @{ 
                        installed = $updateCheck.InstalledBuild
                        latest = $updateCheck.LatestBuild 
                        delayMinutes = $updateDelayMinutes
                    }
                }
            }
            $global:LastUpdateCheck = $now
        }
        
        # --- UPDATE WARNINGS AND EXECUTION ---
        if ($global:UpdateScheduledTime) {
            $updateDelay = ($global:UpdateScheduledTime - $now).TotalMinutes
            
            if ($updateDelay -le 5.5 -and $updateDelay -gt 4.5 -and -not $global:UpdateWarning5Sent) {
                Send-AdminUpdateWarningEvent @{ delayMinutes = 5 }
                $global:UpdateWarning5Sent = $true
            } elseif ($now -ge $global:UpdateScheduledTime) {
                Write-Log "[UPDATE] Executing scheduled update"
                $updateResult = Invoke-ImmediateUpdate -SteamCmdPath $global:SteamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName
                $global:UpdateScheduledTime = $null
                $global:UpdateWarning5Sent = $false
                $updateOrRestart = $true
            }
        }
        
        # --- ADAPTIVE SLEEP ---
        $sleepMs = switch ($true) {
            ($global:ServiceStartInitiated -eq $true) { 500 }  # Fast monitoring during startup
            ($updateOrRestart -eq $true) { 500 }  # Fast monitoring during updates/restarts
            ($serviceRunning -eq $true) { 2000 }  # Slower monitoring when stable
            default { 1000 }  # Default monitoring speed
        }
        
        # Ensure $sleepMs is a single integer value
        if ($sleepMs -is [array]) {
            $sleepMs = [int]($sleepMs[0])
        } else {
            $sleepMs = [int]$sleepMs
        }
        Start-Sleep -Milliseconds $sleepMs
        
        } catch {
            Write-Log "[ERROR] Error in main loop iteration: $($_.Exception.Message)" -Level Error
            Write-Log "[ERROR] Stack trace: $($_.ScriptStackTrace)" -Level Error
            
            # Sleep and continue to next iteration
            Start-Sleep -Seconds 5
        }
    }
} catch {
    Write-Log "[ERROR] Critical error in main loop: $($_.Exception.Message)" -Level Error
    Write-Log "[ERROR] Stack trace: $($_.ScriptStackTrace)" -Level Error
    
    # Try to continue after error
    Start-Sleep -Seconds 30
}

Write-Log "[INFO] Main monitoring loop ended"
