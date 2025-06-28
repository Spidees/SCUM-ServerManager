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
    # Import modules in dependency order
    Import-Module (Join-Path $ModulesPath "common\common.psm1") -Force -Global
    Import-Module (Join-Path $ModulesPath "notifications\notifications.psm1") -Force
    Import-Module (Join-Path $ModulesPath "service\service.psm1") -Force
    Import-Module (Join-Path $ModulesPath "backup\backup.psm1") -Force
    Import-Module (Join-Path $ModulesPath "update\update.psm1") -Force
    Import-Module (Join-Path $ModulesPath "admincommands\admincommands.psm1") -Force
    Import-Module (Join-Path $ModulesPath "logreader\logreader.psm1") -Force
    Import-Module (Join-Path $ModulesPath "monitoring\monitoring.psm1") -Force
    
    Write-Host "[INFO] All modules loaded successfully" -ForegroundColor Green
    
    # Verify critical functions are available
    $requiredFunctions = @('Initialize-CommonModule', 'Write-Log', 'Get-SafeConfigValue', 'Test-PathExists', 'Get-TimeStamp', 'Update-MonitoringMetrics', 'Read-GameLogs', 'Process-LogEvent')
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
Show-NotificationSettings
Initialize-ServiceModule -Config $config
Initialize-BackupModule -Config $config
Initialize-UpdateModule -Config $config
Initialize-AdminCommandModule -Config $config

# Initialize LogReader with proper log path
$scumLogPath = Get-SafeConfigValue $config "customLogPath" $null
if (-not $scumLogPath) {
    # Default SCUM server log path
    $scumLogPath = Join-Path $savedDir "Logs\SCUM.log"
}
Initialize-LogReaderModule -Config $config -LogPath $scumLogPath

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

# Send startup notification
Send-Notification admin "managerStarted" @{ timestamp = Get-TimeStamp }

# --- HELPER FUNCTIONS ---
function Get-NextScheduledRestart {
    param([string[]]$RestartTimes)
    
    $now = Get-Date
    $todayRestarts = $RestartTimes | ForEach-Object {
        $t = [datetime]::ParseExact($_, 'HH:mm', $null)
        $scheduled = (Get-Date -Hour $t.Hour -Minute $t.Minute -Second 0)
        if ($scheduled -gt $now) { $scheduled } else { $null }
    } | Where-Object { $_ -ne $null }
    
    if ($todayRestarts.Count -gt 0) {
        return ($todayRestarts | Sort-Object)[0]
    } else {
        # Next day's first restart
        $t = [datetime]::ParseExact($RestartTimes[0], 'HH:mm', $null)
        return ((Get-Date).AddDays(1).Date.AddHours($t.Hour).AddMinutes($t.Minute))
    }
}

# --- RESTART WARNING SYSTEM ---
$restartWarningDefs = @(
    @{ key = 'restartWarning15'; minutes = 15 },
    @{ key = 'restartWarning5'; minutes = 5 },
    @{ key = 'restartWarning1'; minutes = 1 }
)

$restartWarningSent = @{}
$nextRestartTime = Get-NextScheduledRestart $restartTimes
foreach ($def in $restartWarningDefs) { $restartWarningSent[$def.key] = $false }
$restartPerformedTime = $null

Write-Log "[INFO] Next scheduled restart: $($nextRestartTime.ToString('yyyy-MM-dd HH:mm:ss'))"

# --- HELPER FUNCTIONS FOR MAIN LOOP ---
function Invoke-ImmediateUpdate {
    param(
        [string]$SteamCmdPath,
        [string]$ServerDirectory,
        [string]$AppId,
        [string]$ServiceName
    )
    
    Write-Log "[UPDATE] Starting immediate update"
    
    # Ensure SteamCMD path is directory format for Update-GameServer
    $steamCmdDirectory = if ($SteamCmdPath -like "*steamcmd.exe") {
        Split-Path $SteamCmdPath -Parent
    } else {
        $SteamCmdPath
    }
    
    # Create backup before update
    Write-Log "[UPDATE] Creating backup before update"
    $backupResult = Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $maxBackups -CompressBackups $compressBackups
    
    if ($backupResult.Success) {
        Write-Log "[UPDATE] Backup created successfully"
        
        # Stop service if running
        if (Test-ServiceRunning $ServiceName) {
            Stop-GameService -ServiceName $ServiceName -Reason "update"
        }
        
        # Perform update
        $updateResult = Update-GameServer -SteamCmdPath $steamCmdDirectory -ServerDirectory $ServerDirectory -AppId $AppId -ServiceName $ServiceName
        
        if ($updateResult.Success) {
            Write-Log "[UPDATE] Server updated successfully"
            Send-Notification admin "updateCompleted" @{}
            
            # Start service after update
            Start-GameService -ServiceName $ServiceName -Context "post-update"
        } else {
            Write-Log "[ERROR] Update failed: $($updateResult.Error)" -Level Error
            Send-Notification admin "updateFailed" @{ error = $updateResult.Error }
        }
    } else {
        Write-Log "[ERROR] Pre-update backup failed: $($backupResult.Error)" -Level Error
        Send-Notification admin "backupFailed" @{ error = $backupResult.Error }
    }
}

# --- STARTUP INITIALIZATION ---
# Check for first install
$manifestPath = Join-Path $serverDir "steamapps/appmanifest_$appId.acf"
$firstInstall = $false

# Initialize SteamCMD directory for later use
$global:SteamCmdDirectory = if ($steamCmd -like "*steamcmd.exe") {
    Split-Path $steamCmd -Parent
} else {
    $steamCmd
}

if (!(Test-PathExists $manifestPath) -or !(Test-PathExists $serverDir)) {
    Write-Log "[INFO] Server files not found, performing first install"
    Send-Notification admin "firstInstall" @{}
    
    # Check if SteamCMD exists, if not download it
    $steamCmdExe = Join-Path $steamCmd "steamcmd.exe"
    if (!(Test-PathExists $steamCmdExe)) {
        Write-Log "[INFO] SteamCMD not found, downloading from Steam..."
        
        # Get the directory part of steamCmd path (remove steamcmd.exe if present)
        $steamCmdDir = if ($steamCmd -like "*steamcmd.exe") {
            Split-Path $steamCmd -Parent
        } else {
            $steamCmd
        }
        
        # Create SteamCMD directory if it doesn't exist
        if (!(Test-PathExists $steamCmdDir)) {
            try {
                New-Item -Path $steamCmdDir -ItemType Directory -Force | Out-Null
                Write-Log "[INFO] Created SteamCMD directory: $steamCmdDir"
            } catch {
                Write-Log "[ERROR] Failed to create SteamCMD directory: $($_.Exception.Message)" -Level Error
                Send-Notification admin "firstInstallFailed" @{ error = "Failed to create SteamCMD directory" }
                return
            }
        }
        
        # Download SteamCMD
        try {
            $steamCmdZipUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
            $steamCmdZipPath = Join-Path $steamCmdDir "steamcmd.zip"
            
            Write-Log "[INFO] Downloading SteamCMD from: $steamCmdZipUrl"
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($steamCmdZipUrl, $steamCmdZipPath)
            Write-Log "[INFO] SteamCMD downloaded successfully"
            
            # Extract SteamCMD
            Write-Log "[INFO] Extracting SteamCMD..."
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($steamCmdZipPath, $steamCmdDir)
            
            # Remove zip file
            Remove-Item $steamCmdZipPath -Force
            Write-Log "[INFO] SteamCMD extracted and ready"
            
            # Update steamCmdExe path for verification
            $steamCmdExe = Join-Path $steamCmdDir "steamcmd.exe"
            
            # Verify steamcmd.exe exists
            if (Test-PathExists $steamCmdExe) {
                Write-Log "[INFO] SteamCMD installation verified at: $steamCmdExe"
            } else {
                throw "SteamCMD executable not found after extraction"
            }
            
        } catch {
            Write-Log "[ERROR] Failed to download/extract SteamCMD: $($_.Exception.Message)" -Level Error
            Send-Notification admin "firstInstallFailed" @{ error = "Failed to download SteamCMD: $($_.Exception.Message)" }
            return
        }
    } else {
        Write-Log "[INFO] SteamCMD found at: $steamCmdExe"
    }
    
    # Create server directory if it doesn't exist
    if (!(Test-PathExists $serverDir)) {
        Write-Log "[INFO] Creating server directory: $serverDir"
        try {
            New-Item -Path $serverDir -ItemType Directory -Force | Out-Null
            Write-Log "[INFO] Server directory created successfully"
        } catch {
            Write-Log "[ERROR] Failed to create server directory: $($_.Exception.Message)" -Level Error
            Send-Notification admin "firstInstallFailed" @{ error = "Failed to create server directory" }
            return
        }
    }
    
    # Now download the server
    Write-Log "[INFO] Downloading SCUM server files via SteamCMD..."
    
    # Get the directory part of steamCmd path for Update-GameServer
    $steamCmdDirectory = if ($steamCmd -like "*steamcmd.exe") {
        Split-Path $steamCmd -Parent
    } else {
        $steamCmd
    }
    
    $updateResult = Update-GameServer -SteamCmdPath $steamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName -SkipServiceStart:$true
    
    if ($updateResult.Success) {
        Write-Log "[INFO] First install completed successfully"
        Send-Notification admin "firstInstallComplete" @{
        }
        
        # After successful first install, restart the script instead of starting server
        Write-Log "[INFO] First install completed - restarting script to reload all functions"
        Write-Log "[INFO] Exiting PowerShell"
        
        # Give a moment for notifications to be sent
        Start-Sleep -Seconds 2
        
        # Exit PowerShell after first install
        Write-Log "[INFO] PowerShell exiting for restart after first install"
        Read-Host "[INFO] Press Enter to exit..."
        exit 0
    } else {
        Write-Log "[ERROR] First install failed: $($updateResult.Error)" -Level Error
        Send-Notification admin "firstInstallFailed" @{ error = $updateResult.Error }
        # Don't exit on failure, allow manual intervention
        return
    }
    
    # This code will only be reached if startserver.bat was not found
    $global:LastUpdateCheck = Get-Date
    $firstInstall = $true
    
    # Store the SteamCMD directory for later use
    $global:SteamCmdDirectory = $steamCmdDirectory
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
        Send-Notification admin "updateAvailable" @{ 
            installed = $updateCheck.InstalledBuild
            latest = $updateCheck.LatestBuild 
        }
        Update-GameServer -SteamCmdPath $steamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName
    } else {
        Write-Log "[INFO] No update available"
    }
    
    $global:LastUpdateCheck = Get-Date
} elseif (-not $firstInstall) {
    # Start service if not running and not during first install
    if (-not (Test-ServiceRunning $serviceName)) {
        Write-Log "[INFO] Starting server service (normal startup)"
        Start-GameService -ServiceName $serviceName -Context "startup"
    } else {
        Write-Log "[INFO] Server service is already running"
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
    
    # Initialize service status
    $serviceRunning = Test-ServiceRunning $serviceName
    
    while ($true) {
        $now = Get-Date
        $updateOrRestart = $false
        
        # --- STATUS MONITORING ---
        $shouldCheckStatus = ($now - $lastStatusCheck).TotalMilliseconds -ge $statusCheckInterval
        if ($shouldCheckStatus) {
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
            
            # Update performance metrics
            Update-MonitoringMetrics
        }
        
        # --- LOG MONITORING ---
        $shouldCheckLogs = ($now - $lastLogCheck).TotalMilliseconds -ge $logCheckInterval
        if ($shouldCheckLogs -and $serviceRunning) {
            $logEvents = Read-GameLogs
            if ($logEvents -and $logEvents.Count -gt 0) {
                foreach ($logLine in $logEvents) {
                    # Process-LogEvent now expects raw log lines, not structured events
                    Process-LogEvent -LogEvent $logLine
                }
            }
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
        
        # --- SERVICE STARTUP MONITORING ---
        if ($global:ServiceStartInitiated) {
            $startupElapsed = ($now - $global:ServiceStartTime).TotalMinutes
            $maxStartupMinutes = Get-SafeConfigValue $config "serverStartupTimeoutMinutes" 10
            
            if ($serviceRunning) {
                Write-Log "[SUCCESS] Service startup completed after $([Math]::Round($startupElapsed, 1)) min ($($global:ServiceStartContext))"
                Send-Notification admin "serverStarted" @{ context = $global:ServiceStartContext }
                $global:ServiceStartInitiated = $false
                $global:ServiceStartContext = ""
                $global:ServiceStartTime = $null
            } elseif ($startupElapsed -gt $maxStartupMinutes) {
                Write-Log "[ERROR] Service startup timeout after $maxStartupMinutes minutes" -Level Error
                Send-Notification admin "startupTimeout" @{ 
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
                        Send-Notification admin "serverCrashed" @{ 
                            restartAttempt = $global:ConsecutiveRestartAttempts 
                        }
                        Start-GameService -ServiceName $serviceName -Context "auto-restart"
                    }
                }
            }
        }
        
        # --- SCHEDULED RESTART WARNINGS ---
        foreach ($def in $restartWarningDefs) {
            $warnTime = $nextRestartTime.AddMinutes(-$def.minutes)
            if (-not $restartWarningSent[$def.key] -and $now -ge $warnTime -and $now -lt $warnTime.AddSeconds(30)) {
                $timeStr = $nextRestartTime.ToString('HH:mm')
                Send-Notification player $def.key @{ time = $timeStr }
                Write-Log "[WARN] Sent restart warning: $($def.key)"
                $restartWarningSent[$def.key] = $true
            }
        }
        
        # --- SCHEDULED RESTART EXECUTION ---
        if (($restartPerformedTime -ne $nextRestartTime) -and $now -ge $nextRestartTime -and $now -lt $nextRestartTime.AddMinutes(1)) {
            # Check if restart should be skipped
            if ($global:SkipNextScheduledRestart) {
                Write-Log "[RESTART] Skipping scheduled restart as requested"
                Send-Notification admin "otherEvent" @{ 
                    event = ":fast_forward: Scheduled restart at $($nextRestartTime.ToString('HH:mm:ss')) was skipped as requested" 
                }
                
                # Reset skip flag and move to next restart
                $global:SkipNextScheduledRestart = $false
                $restartPerformedTime = $nextRestartTime
                $nextRestartTime = Get-NextScheduledRestart $restartTimes
                foreach ($def in $restartWarningDefs) { $restartWarningSent[$def.key] = $false }
                
                Write-Log "[RESTART] Next scheduled restart: $($nextRestartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
            } else {
                Write-Log "[RESTART] Executing scheduled restart"
                Send-Notification admin "scheduledRestart" @{ time = $nextRestartTime.ToString('HH:mm:ss') }
                
                # Create backup before restart
                Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $maxBackups -CompressBackups $compressBackups
                
                # Restart service
                Restart-GameService -ServiceName $serviceName -Reason "scheduled restart"
                
                # Update restart tracking
                $restartPerformedTime = $nextRestartTime
                $nextRestartTime = Get-NextScheduledRestart $restartTimes
                foreach ($def in $restartWarningDefs) { $restartWarningSent[$def.key] = $false }
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
                    Send-Notification admin "updateAvailable" @{ 
                        installed = $updateCheck.InstalledBuild
                        latest = $updateCheck.LatestBuild 
                    }
                    Invoke-ImmediateUpdate -SteamCmdPath $global:SteamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName
                } else {
                    # Server is online, schedule update
                    $global:UpdateScheduledTime = $now.AddMinutes($updateDelayMinutes)
                    Send-Notification admin "updateAvailable" @{ 
                        installed = $updateCheck.InstalledBuild
                        latest = $updateCheck.LatestBuild 
                    }
                    Send-Notification player "updateAvailable" @{ delayMinutes = $updateDelayMinutes }
                }
            }
            $global:LastUpdateCheck = $now
        }
        
        # --- UPDATE WARNINGS AND EXECUTION ---
        if ($global:UpdateScheduledTime) {
            $updateDelay = ($global:UpdateScheduledTime - $now).TotalMinutes
            
            if ($updateDelay -le 5.5 -and $updateDelay -gt 4.5 -and -not $global:UpdateWarning5Sent) {
                Send-Notification player "updateWarning" @{ delayMinutes = 5 }
                $global:UpdateWarning5Sent = $true
            } elseif ($now -ge $global:UpdateScheduledTime) {
                Write-Log "[UPDATE] Executing scheduled update"
                Invoke-ImmediateUpdate -SteamCmdPath $global:SteamCmdDirectory -ServerDirectory $serverDir -AppId $appId -ServiceName $serviceName
                $global:UpdateScheduledTime = $null
                $global:UpdateWarning5Sent = $false
                $updateOrRestart = $true
            }
        }
        
        # --- ADAPTIVE SLEEP ---
        $sleepMs = switch ($true) {
            ($global:ServiceStartInitiated) { 500 }  # Fast monitoring during startup
            ($updateOrRestart) { 500 }  # Fast monitoring during updates/restarts
            ($serviceRunning) { 2000 }  # Slower monitoring when stable
            default { 1000 }  # Default monitoring speed
        }
        
        Start-Sleep -Milliseconds $sleepMs
    }
} catch {
    Write-Log "[ERROR] Critical error in main loop: $($_.Exception.Message)" -Level Error
    Write-Log "[ERROR] Stack trace: $($_.ScriptStackTrace)" -Level Error
    
    # Try to continue after error
    Start-Sleep -Seconds 30
}

Write-Log "[INFO] Main monitoring loop ended"
