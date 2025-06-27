# ==========================
# SCUM Server Automation - SCUM Dedicated Server Management for Windows
# ==========================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- CONFIG LOADING ---
# Load configuration file
$configPath = Join-Path $PSScriptRoot 'SCUMServer.config.json'
if (!(Test-Path $configPath)) {
    Write-Host "[FATAL] Config file $configPath not found!"; exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

# Extract config values and resolve paths

$serviceName = $config.serviceName
$backupRoot = if ($config.backupRoot.StartsWith('./')) { Join-Path $PSScriptRoot ($config.backupRoot.Substring(2)) } else { $config.backupRoot }
$savedDir = if ($config.savedDir.StartsWith('./')) { Join-Path $PSScriptRoot ($config.savedDir.Substring(2)) } else { $config.savedDir }
$steamCmd = if ($config.steamCmd.StartsWith('./')) { Join-Path $PSScriptRoot ($config.steamCmd.Substring(2)) } else { $config.steamCmd }
$serverDir = if ($config.serverDir.StartsWith('./')) { Join-Path $PSScriptRoot ($config.serverDir.Substring(2)) } else { $config.serverDir }
$appId = $config.appId
$restartTimes = $config.restartTimes
$backupIntervalMinutes = $config.backupIntervalMinutes
$periodicBackupEnabled = $config.periodicBackupEnabled
$updateCheckIntervalMinutes = $config.updateCheckIntervalMinutes
$updateDelayMinutes = $config.updateDelayMinutes
$maxBackups = $config.maxBackups
$compressBackups = $config.compressBackups
$runBackupOnStart = $config.runBackupOnStart
$runUpdateOnStart = $config.runUpdateOnStart

# --- DISCORD NOTIFICATIONS ---
$adminNotification = $config.admin_notification
$playerNotification = $config.player_notification
$adminCommandChannel = $config.admin_command_channel
$botToken = $config.botToken

# Get command prefix from config (default to "!" if not set)
$commandPrefix = if ($adminCommandChannel.commandPrefix) { $adminCommandChannel.commandPrefix } else { "!" }

# --- PERFORMANCE THRESHOLDS ---
# Load performance thresholds from config with defaults
$performanceThresholds = @{
    excellent = if ($config.performanceThresholds.excellent) { $config.performanceThresholds.excellent } else { 30 }
    good = if ($config.performanceThresholds.good) { $config.performanceThresholds.good } else { 20 }
    fair = if ($config.performanceThresholds.fair) { $config.performanceThresholds.fair } else { 15 }
    poor = if ($config.performanceThresholds.poor) { $config.performanceThresholds.poor } else { 10 }
    critical = if ($null -ne $config.performanceThresholds.critical) { $config.performanceThresholds.critical } else { 0 }
}

# Send Discord notifications with role mentions and template variables
function Send-Notification {
    param(
        [Parameter(Mandatory)] [string]$type, # 'admin' or 'player'
        [Parameter(Mandatory)] [string]$messageKey, # Message template key
        [Parameter()] [hashtable]$vars = @{} # Template variables
    )
    
    # Anti-spam and rate limiting check
    $suppressDuplicates = if ($config.suppressDuplicateNotifications -ne $null) { $config.suppressDuplicateNotifications } else { $true }
    $rateLimitMinutes = if ($config.notificationRateLimitMinutes) { $config.notificationRateLimitMinutes } else { 1 }
    $adminAlways = if ($config.adminNotificationAlways -ne $null) { $config.adminNotificationAlways } else { $true }
    $minPlayersForPlayerNotif = if ($config.playerNotificationMinimumPlayers) { $config.playerNotificationMinimumPlayers } else { 0 }
    
    # Create key for tracking duplicate messages
    $notificationKey = "$type-$messageKey"
    $now = Get-Date
    
    # Initialize global tracking hash if not exists
    if (-not $global:LastNotifications) {
        $global:LastNotifications = @{}
    }
    
    # Check rate limiting
    if ($global:LastNotifications[$notificationKey]) {
        $timeSinceLastMinutes = ($now - $global:LastNotifications[$notificationKey]).TotalMinutes
        if ($timeSinceLastMinutes -lt $rateLimitMinutes) {
            if ($type -eq 'admin' -and -not $adminAlways) {
                Write-Log "[INFO] Rate limit: Skipping $messageKey for $type (last sent $([Math]::Round($timeSinceLastMinutes, 1)) min ago)"
                return
            } elseif ($type -eq 'player') {
                Write-Log "[INFO] Rate limit: Skipping $messageKey for $type (last sent $([Math]::Round($timeSinceLastMinutes, 1)) min ago)"
                return
            }
        }
    }
    
    # Check minimum player count for player notifications
    if ($type -eq 'player' -and $vars.ContainsKey('playerCount')) {
        $currentPlayers = [int]$vars['playerCount']
        if ($currentPlayers -lt $minPlayersForPlayerNotif) {
            Write-Log "[INFO] Player notification skipped: Only $currentPlayers players online (minimum: $minPlayersForPlayerNotif)"
            return
        }
    }
    
    # Update tracking
    $global:LastNotifications[$notificationKey] = $now
    
    # Get notification config section
    $section = if ($type -eq 'admin') { $adminNotification } else { $playerNotification }
    $method = $section.method
    $messages = $section.messages
    $msgObj = $messages.$messageKey
    if (-not $msgObj) { Write-Log "[WARN] Message template $messageKey not found for $type"; return }
    
    # Check if notification is enabled
    if ($msgObj.enabled -eq $false) { 
        Write-Log "[INFO] Notification $messageKey for $type is disabled, skipping"
        return 
    }
    $title = $msgObj.title
    $msg = $msgObj.text
    $color = $msgObj.color
    # Replace template variables
    foreach ($k in $vars.Keys) { $msg = $msg -replace "\{$k\}", [string]$vars[$k] }
    
    # Build Discord embed
    $embed = @{ description = $msg }
    if ($title) { $embed.title = $title }
    if ($color) { $embed.color = $color }
    $embed.footer = @{ text = "SCUM Server Manager | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"; icon_url = "https://playhub.cz/scum/playhub_icon.png" }
    # Prepare role mentions
    $content = ""
    $roleIdArr = $null
    if ($type -eq 'admin') {
        if ($adminNotification -and $adminNotification.roleIds) {
            $roleIdArr = $adminNotification.roleIds | Where-Object { $_ -and $_ -ne '' }
        }
    } elseif ($type -eq 'player') {
        if ($playerNotification -and $playerNotification.roleIds) {
            $roleIdArr = $playerNotification.roleIds | Where-Object { $_ -and $_ -ne '' }
        }
    }
    if ($roleIdArr -and $roleIdArr.Count -gt 0) {
        $mentions = $roleIdArr | ForEach-Object { "<@&$_>" }
        $content = $mentions -join ' '
    }
    # Send via webhook or bot API
    if ($method -eq 'webhook') {
        $webhooks = $section.webhooks
        foreach ($webhook in $webhooks) {
            if ($webhook -and $webhook -ne "") {
                try {
                    $payload = @{ embeds = @($embed) }
                    if ($content -ne "") { $payload.content = $content }
                    $payloadJson = $payload | ConvertTo-Json -Depth 4
                    Invoke-RestMethod -Uri $webhook -Method Post -ContentType 'application/json' -Body $payloadJson
                    Write-Log "[INFO] Webhook embed notification sent: $msg"
                } catch {
                    Write-Log "[ERROR] Webhook embed notification failed: $_"
                }
            }
        }
    } elseif ($method -eq 'bot') {
        $channelIds = $section.channelIds
        if ($botToken -and $channelIds) {
            foreach ($channelId in $channelIds) {
                if ($channelId -and $channelId -ne "") {
                    try {
                        $uri = "https://discord.com/api/v10/channels/$channelId/messages"
                        $headers = @{ 
                            Authorization = "Bot $botToken"
                            "User-Agent" = "SCUM-Server-Manager/1.0"
                        }
                        
                        # Send simple fallback first, then embed
                        $simpleBody = @{ content = "[BOT] **$title** - $msg" }
                        if ($content -ne "") { $simpleBody.content = "$content`n$($simpleBody.content)" }
                        
                        # Try embed, use simple message on error
                        try {
                            $body = @{ embeds = @($embed) }
                            if ($content -ne "") { $body.content = $content }
                            $bodyJson = $body | ConvertTo-Json -Depth 4
                            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -ContentType 'application/json' -Body $bodyJson -ErrorAction Stop
                            Write-Log ("[INFO] Bot embed notification sent to channel {0}: {1}" -f $channelId, $msg)
                        } catch {
                            # Fallback to simple message
                            $simpleBodyJson = $simpleBody | ConvertTo-Json -Depth 2
                            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -ContentType 'application/json' -Body $simpleBodyJson -ErrorAction Stop
                            Write-Log ("[INFO] Bot simple notification sent to channel {0}: {1}" -f $channelId, $msg)
                        }
                    } catch {
                        Write-Log ("[ERROR] Bot notification failed for channel {0}: {1}" -f $channelId, $_)
                    }
                }
            }
        } else {
            Write-Log "[ERROR] Bot notification config missing botToken or channelIds."
        }
    } else {
        Write-Log "[ERROR] Unknown notification method: $method"
    }
}

# --- LOGGING ---
# Write timestamped log messages
function Write-Log {
    param([string]$msg)
    
    # Check if detailed logging is enabled
    $enableDetailedLogging = if ($config.enableDetailedLogging -ne $null) { $config.enableDetailedLogging } else { $true }
    
    # If logging is disabled, only show on console
    if (-not $enableDetailedLogging -and $msg -like "*[INFO]*") {
        Write-Host $msg
        return
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp $msg"
    $logPath = Join-Path -Path $PSScriptRoot -ChildPath "SCUMServer.log"
    
    # Check log file size and rotate if needed
    $maxLogFileSizeMB = if ($config.maxLogFileSizeMB) { $config.maxLogFileSizeMB } else { 100 }
    if ($config.logRotationEnabled -and (Test-Path $logPath)) {
        $fileSize = (Get-Item $logPath).Length / 1MB
        if ($fileSize -gt $maxLogFileSizeMB) {
            $rotatedPath = $logPath -replace "\.log$", "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Move-Item $logPath $rotatedPath
            Write-Host "Log rotated: $rotatedPath"
        }
    }
    
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host $line
}

# --- ENHANCED NOTIFICATION SYSTEM ---
# Unified server status notifications based on SCUM log analysis
function Notify-ServerStatusChange {
    param(
        [Parameter(Mandatory)] [string]$newState,   # "Starting", "Loading", "Online", "Offline", "Crashed"
        [Parameter(Mandatory)] [string]$reason,     # Why the change happened
        [Parameter()] [hashtable]$extraData = @{}  # Additional data (player count, etc.)
    )
    
    switch ($newState) {
        "Starting" {
            Send-Notification admin "serverStarting" @{ reason = $reason }
            Send-Notification player "serverStarting" @{ reason = $reason }
            Write-Log "[NOTIFY] Server STARTING - Reason: $reason"
        }
        "Loading" {
            Send-Notification admin "serverLoading" @{ reason = $reason }
            Send-Notification player "serverLoading" @{ reason = $reason }
            Write-Log "[NOTIFY] Server LOADING - Reason: $reason"
        }
        "Online" {
            $playerCount = if ($extraData.PlayerCount) { $extraData.PlayerCount } else { 0 }
            Send-Notification admin "serverOnline" @{ reason = $reason; playerCount = $playerCount }
            Send-Notification player "serverOnline" @{ reason = $reason; playerCount = $playerCount }
            Write-Log "[NOTIFY] Server ONLINE ($playerCount players) - Reason: $reason"
        }
        "Offline" {
            Send-Notification admin "serverOffline" @{ reason = $reason }
            Send-Notification player "serverOffline" @{ reason = $reason }
            Write-Log "[NOTIFY] Server OFFLINE - Reason: $reason"
        }
        "Crashed" {
            Send-Notification admin "serverCrashed" @{ reason = $reason }
            Send-Notification player "serverCrashed" @{ reason = $reason }
            Write-Log "[NOTIFY] Server CRASHED - Reason: $reason"
        }
        "Hanging" {
            Send-Notification admin "serverHanging" @{ reason = $reason }
            # Players don't need to know about technical hanging state
            Write-Log "[NOTIFY] Server HANGING - Reason: $reason"
        }
    }
}

# Legacy notification functions for compatibility - now use enhanced system
function Notify-ServerOnline {
    param([string]$reason = "Unknown")
    Notify-ServerStatusChange "Online" $reason
}

function Notify-ServerOffline {
    param([string]$reason = "Unknown")
    Notify-ServerStatusChange "Offline" $reason
}

function Notify-ServerRestarting {
    param([string]$reason = "Unknown")
    Send-Notification admin "serverRestarting" @{ reason = $reason }
    Send-Notification player "serverRestarting" @{ reason = $reason }
    Write-Log "[NOTIFY] Server RESTARTING - Reason: $reason"
}

function Notify-UpdateInProgress {
    param([string]$reason = "Unknown")
    Send-Notification admin "updateInProgress" @{ reason = $reason }
    Send-Notification player "updateInProgress" @{ reason = $reason }
    Write-Log "[NOTIFY] UPDATE IN PROGRESS - Reason: $reason"
}

function Notify-ServerCrashed {
    param([string]$reason = "Unexpected crash")
    Notify-ServerStatusChange "Crashed" $reason
}

function Notify-AdminActionResult {
    param(
        [string]$action,    # "restart", "start", "stop", "update"
        [string]$result,    # "completed successfully", "failed"
        [string]$status     # "ONLINE", "OFFLINE", etc.
    )
    $message = "Admin $action $result. Server status: $status"
    Send-Notification admin "otherEvent" @{ event = $message }
    Write-Log "[NOTIFY] Admin action result: $message"
}

# --- BACKUP SYSTEM ---
# Create backup with compression and retention management
function Backup-Saved {
    if (!(Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot | Out-Null }
    if (Test-Path $savedDir) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupDir = Join-Path $backupRoot "Saved_BACKUP_$timestamp"
        try {
            Copy-Item $savedDir $backupDir -Recurse -ErrorAction Stop
            if ($compressBackups) {
                $zipPath = "$backupDir.zip"
                Compress-Archive -Path $backupDir -DestinationPath $zipPath -Force
                Remove-Item $backupDir -Recurse -Force
                Write-Log "[INFO] Backup created and compressed: $zipPath"
                Send-Notification admin "backupCreated" @{ path = $zipPath }
                # Player notification removed for backupCreated
            } else {
                Write-Log "[INFO] Backup created: $backupDir"
                Send-Notification admin "backupCreated" @{ path = $backupDir }
                # Player notification removed for backupCreated
            }
            # Cleanup old backups
            $backups = Get-ChildItem $backupRoot | Where-Object { $_.Name -like 'Saved_BACKUP_*' -or $_.Name -like 'Saved_BACKUP_*.zip' } | Sort-Object LastWriteTime -Descending
            if ($backups.Count -gt $maxBackups) {
                $toRemove = $backups | Select-Object -Skip $maxBackups
                foreach ($b in $toRemove) { Remove-Item $b.FullName -Recurse -Force }
            }
            return $true
        } catch {
            Write-Log "[ERROR] Backup of Saved folder failed: $_"
            Send-Notification admin "backupError" @{ error = "Backup of the Saved folder failed. Update will not proceed." }
            # Player notification removed for backupError
            return $false
        }
    } else {
        Write-Log "[WARNING] Saved folder not found, backup skipped."
        Send-Notification admin "backupWarning" @{ warning = "The Saved folder was not found, backup was skipped." }
        # Player notification removed for backupWarning
        return $false
    }
}

# --- SCUM LOG MONITORING SYSTEM ---
# Analyzes SCUM.log and determines exact server state
function Get-SCUMServerStatus {
    $scumLogPath = Join-Path $savedDir "Logs\SCUM.log"
    
    if (!(Test-Path $scumLogPath)) {
        return @{
            Status = "LogNotFound"
            Phase = "Unknown"
            LastActivity = $null
            PlayerCount = 0
            IsOnline = $false
            Message = "SCUM.log not found"
            PerformanceStats = $null
            PerformanceSummary = $null
        }
    }
    
    try {
        # Read configurable number of last lines for analysis
        $maxLines = if ($config.logAnalysisMaxLines) { $config.logAnalysisMaxLines } else { 1000 }
        $logLines = Get-Content $scumLogPath -Tail $maxLines -ErrorAction Stop
        if ($logLines.Count -eq 0) {
            return @{
                Status = "LogEmpty"
                Phase = "Unknown" 
                LastActivity = $null
                PlayerCount = 0
                IsOnline = $false
                Message = "SCUM.log is empty"
                PerformanceStats = $null
                PerformanceSummary = $null
            }
        }
        
        # Analyze log patterns
        $lastTimestamp = $null
        $serverPhase = "Unknown"
        $playerCount = 0
        $isOnline = $false
        $crashDetected = $false
        $hangDetected = $false
        
        # Get performance statistics
        $performanceStats = Get-ServerPerformanceStats -logPath $scumLogPath -maxLines 200
        
        # If we have performance stats, server is definitely online
        if ($null -ne $performanceStats) {
            $serverPhase = "Online"
            $isOnline = $true
            $playerCount = $performanceStats.PlayerCount
        }
        
        # Process lines backwards (newest first)
        for ($i = $logLines.Count - 1; $i -ge 0; $i--) {
            $line = $logLines[$i]
            
            # Extract timestamp
            if ($line -match '^\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3})') {
                if ($null -eq $lastTimestamp) {
                    try {
                        $timestampStr = $matches[1] -replace '(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2}):(\d{3})', '$1-$2-$3 $4:$5:$6.$7'
                        $lastTimestamp = [DateTime]::ParseExact($timestampStr, 'yyyy-MM-dd HH:mm:ss.fff', $null)
                    } catch {
                        # If parsing fails, use approximation
                        $lastTimestamp = (Get-Date).AddMinutes(-1)
                    }
                }
            }
            
            # Detect key states (newest pattern wins)
            if ($line -match 'Match State Changed to InProgress') {
                $serverPhase = "Online"
                $isOnline = $true
                break
            } elseif ($line -match 'Global Stats:.*\|\s*C:\s*\d+.*P:\s*(\d+)') {
                # Server is running and generating statistics - this means it's online
                $serverPhase = "Online"
                $isOnline = $true
                if ($matches.Count -ge 2) {
                    $playerCount = [int]$matches[1]
                }
                # Don't break - continue looking for newer records
            } elseif ($line -match 'Match State Changed to') {
                $serverPhase = "Loading"
                # Don't break - Global Stats has higher priority
            } elseif ($line -match 'LogWorld:.*Bringing World.*online') {
                $serverPhase = "Loading"
                # Don't break - Global Stats has higher priority  
            } elseif ($line -match 'LogGameState:.*Match State.*WaitingToStart') {
                $serverPhase = "Loading"
                # Don't break - Global Stats has higher priority
            } elseif ($line -match 'LogWorld:.*World.*initialized') {
                $serverPhase = "Loading"
                # Don't break - Global Stats has higher priority
            } elseif ($line -match 'LogInit:.*Engine is initialized') {
                $serverPhase = "Starting"
                # Don't break - Global Stats has higher priority
            } elseif ($line -match 'LogSCUMServer:.*Server.*starting') {
                $serverPhase = "Starting"
                # Don't break - Global Stats has higher priority
            } elseif ($line -match 'BeginPlay.*World') {
                $serverPhase = "Starting"
                # Don't break - Global Stats has higher priority
            }
            
            # Detect crash/error patterns - but not common SCUM warnings and errors
            # Only consider it a crash if we have recent activity and real fatal errors
            if ($line -match '(Fatal|Critical|Crash|Exception)' -and 
                $line -notmatch 'LogStreaming|LogTexture|LogSCUM|LogQuadTree|LogEntitySystem|LogNet.*Very long time|LogStats|LogCore.*packagename|LogUObjectGlobals|LogAssetRegistry') {
                # Only mark as crashed if this is a recent error (not just startup noise)
                if ($lastTimestamp -and ((Get-Date) - $lastTimestamp).TotalMinutes -lt 5) {
                    $crashDetected = $true
                }
            }
            
            # Extract player count (from Global Stats)
            if ($line -match 'Global Stats:.*\|\s*C:\s*\d+.*P:\s*(\d+)') {
                $playerCount = [int]$matches[1]
            } elseif ($line -match 'Players.*?(\d+)') {
                $playerCount = [int]$matches[1]
            }
        }
        
        # Detect hang (no activity in last 30 minutes during expected online state)
        $timeSinceLastActivity = if ($lastTimestamp) { ((Get-Date) - $lastTimestamp).TotalMinutes } else { 999 }
        if ($timeSinceLastActivity -gt 30 -and $serverPhase -in @("Loading", "Online")) {
            # But only if service is actually not running
            if (!(Check-ServiceRunning $serviceName)) {
                $hangDetected = $true
            }
        }
        
        # Determine final state
        $finalStatus = "Unknown"
        if ($crashDetected -and $lastTimestamp) {  # Only mark as crashed if we have logs and detected crash
            $finalStatus = "Crashed"
            $isOnline = $false
        } elseif ($hangDetected) {
            $finalStatus = "Hanging"
            $isOnline = $false
        } elseif ($serverPhase -eq "Online") {
            $finalStatus = "Online"
            $isOnline = $true
        } elseif ($serverPhase -eq "Loading") {
            $finalStatus = "Loading"
            $isOnline = $false
        } elseif ($serverPhase -eq "Starting") {
            $finalStatus = "Starting"
            $isOnline = $false
        } else {
            # If state is unclear, check Windows service
            if (Check-ServiceRunning $serviceName) {
                # If service is running but log is old, probably server is running but not writing logs
                if ($timeSinceLastActivity -le 180) { # 3 hours tolerance
                    # If we have very recent service start but no clear logs yet, assume starting
                    if ($timeSinceLastActivity -le 10) {
                        $finalStatus = "Starting"
                        $isOnline = $false
                    } else {
                        $finalStatus = "Online"
                        $isOnline = $true
                    }
                } else {
                    $finalStatus = "Starting"
                    $isOnline = $false
                }
            } else {
                $finalStatus = "Offline"
                $isOnline = $false
            }
        }
        
        return @{
            Status = $finalStatus
            Phase = $serverPhase
            LastActivity = $lastTimestamp
            PlayerCount = $playerCount
            IsOnline = $isOnline
            Message = "Status determined from SCUM.log analysis"
            TimeSinceLastActivity = $timeSinceLastActivity
            PerformanceStats = $performanceStats
            PerformanceSummary = if ($performanceStats) { Get-PerformanceSummary $performanceStats } else { $null }
        }
        
    } catch {
        Write-Log "[ERROR] Failed to analyze SCUM.log: $_"
        return @{
            Status = "LogError"
            Phase = "Unknown"
            LastActivity = $null
            PlayerCount = 0
            IsOnline = $false
            Message = "Error reading SCUM.log: $_"
            PerformanceStats = $null
            PerformanceSummary = $null
        }
    }
}

# Monitors server startup based on log until actual online state
function Monitor-SCUMServerStartup {
    param(
        [string]$context = "startup",
        [int]$maxWaitMinutes = 0,  # 0 = use config value
        [int]$checkIntervalSeconds = 15
    )
    
    # Use configurable timeout
    if ($maxWaitMinutes -eq 0) {
        $maxWaitMinutes = if ($config.serverStartupTimeoutMinutes) { $config.serverStartupTimeoutMinutes } else { 10 }
    }
    
    Write-Log "[INFO] Starting SCUM server log-based startup monitoring for $context..."
    Write-Log "[INFO] Will monitor for up to $maxWaitMinutes minutes, checking every $checkIntervalSeconds seconds"
    
    $startTime = Get-Date
    $maxWaitTime = $startTime.AddMinutes($maxWaitMinutes)
    $lastReportedStatus = ""
    
    while ((Get-Date) -lt $maxWaitTime) {
        $status = Get-SCUMServerStatus
        
        # Report status change
        if ($status.Status -ne $lastReportedStatus) {
            $statusMsg = "Server status changed: $($status.Status) (Phase: $($status.Phase), Players: $($status.PlayerCount))"
            if ($status.PerformanceSummary) {
                $statusMsg += " - Performance: $($status.PerformanceSummary)"
            }
            Write-Log "[INFO] $statusMsg"
            $lastReportedStatus = $status.Status
        }
        
        # Check successful startup
        if ($status.IsOnline -and $status.Status -eq "Online") {
            $elapsedMinutes = [Math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-Log "[SUCCESS] Server is truly ONLINE after $elapsedMinutes minutes! (Match State: InProgress)"
            return @{
                Success = $true
                Status = $status
                ElapsedMinutes = $elapsedMinutes
            }
        }
        
        # Check crash/hang
        if ($status.Status -in @("Crashed", "Hanging")) {
            $elapsedMinutes = [Math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-Log "[ERROR] Server startup failed after $elapsedMinutes minutes - Status: $($status.Status)"
            return @{
                Success = $false
                Status = $status
                ElapsedMinutes = $elapsedMinutes 
                Reason = "Server $($status.Status.ToLower()) during startup"
            }
        }
        
        # Check that service is still running
        if (!(Check-ServiceRunning $serviceName)) {
            $elapsedMinutes = [Math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
            Write-Log "[ERROR] Windows service stopped running during startup monitoring after $elapsedMinutes minutes"
            return @{
                Success = $false
                Status = $status
                ElapsedMinutes = $elapsedMinutes
                Reason = "Windows service stopped during startup"
            }
        }
        
        Start-Sleep -Seconds $checkIntervalSeconds
    }
    
    # Timeout
    $elapsedMinutes = [Math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
    $finalStatus = Get-SCUMServerStatus
    Write-Log "[ERROR] Server startup monitoring timed out after $elapsedMinutes minutes. Final status: $($finalStatus.Status)"
    
    return @{
        Success = $false
        Status = $finalStatus
        ElapsedMinutes = $elapsedMinutes
        Reason = "Startup timeout after $maxWaitMinutes minutes"
    }
}

# --- SERVICE MANAGEMENT ---
# Check if the Windows service is running
function Check-ServiceRunning {
    param([string]$name)
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $false }
    return $svc.Status -eq 'Running'
}

# Check if server was stopped intentionally (not a crash) - Enhanced detection
function Test-IntentionalStop {
    param(
        [string]$serviceName,
        [int]$minutesToCheck = 10
    )
    
    $since = (Get-Date).AddMinutes(-$minutesToCheck)
    
    try {
        # Method 1: Check Application Event Log for service wrapper (NSSM) events
        $serviceEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$serviceName*" -and (
                $_.Message -like "*received STOP control*" -or
                $_.Message -like "*service*stopping*" -or
                $_.Message -like "*Killing process*service*stopping*"
            )
        }
        
        if ($serviceEvents) {
            Write-Log "[DEBUG] Application log shows service received stop control - intentional stop"
            return $true
        }
        
        # Method 2: Check System Event Log for service control events
        $systemEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ID = @(7036, 7040) # Service state change, service start type change
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$serviceName*" -and $_.Message -like "*stopped*"
        }
        
        if ($systemEvents) {
            Write-Log "[DEBUG] System log shows service stop event - likely intentional stop"
            return $true
        }
        
        # Method 3: Check for clean shutdown pattern in SCUM log
        $logPath = Join-Path $serverDir "SCUM\Saved\Logs\SCUM.log"
        if (Test-Path $logPath) {
            $logContent = Get-Content $logPath -Tail 20 -ErrorAction SilentlyContinue
            $cleanShutdownPatterns = @(
                "LogExit: Exiting.",
                "Log file closed",
                "Shutting down and abandoning module"
            )
            
            foreach ($pattern in $cleanShutdownPatterns) {
                if ($logContent -match [regex]::Escape($pattern)) {
                    Write-Log "[DEBUG] SCUM log shows clean shutdown pattern - intentional stop"
                    return $true
                }
            }
        }
        
        # Method 4: Consider timing - stops during normal hours are more likely intentional
        $currentHour = (Get-Date).Hour
        if ($currentHour -ge 8 -and $currentHour -le 22) {
            Write-Log "[DEBUG] Service stopped during normal hours - more likely intentional"
            # Don't return true based on timing alone, but it's a strong hint
        }
        
    } catch {
        Write-Log "[DEBUG] Error checking intentional stop: $($_.Exception.Message)"
    }
    
    # Default to false - treat as unintentional unless we have clear evidence
    Write-Log "[DEBUG] No clear evidence of intentional stop found - treating as unintentional"
    return $false
}

# --- BUILD VERSION TRACKING ---
# Get installed build ID from Steam manifest
function Get-InstalledBuildId {
    $manifestPath = Join-Path $serverDir "steamapps/appmanifest_$appId.acf"
    if (!(Test-Path $manifestPath)) {
        Write-Log "[DEBUG] Manifest file not found: $manifestPath"
        return $null
    }
    $content = Get-Content $manifestPath -Raw
    if ($content -match '"buildid"\s+"(\d+)"') {
        if ($matches.Count -ge 2) { return $matches[1] } else { Write-Log "[DEBUG] buildid match failed in manifest content"; return $null }
    } else {
        Write-Log "[DEBUG] buildid not found in manifest. Content: $content"
    }
    return $null
}

# Query Steam for latest build ID
function Get-LatestBuildId {
    $cmd = "$steamCmd +login anonymous +app_info_update 1 +app_info_print $appId +quit"
    $outputArr = & cmd /c $cmd
    $output = $outputArr -join "`n"
    $output | Out-File -FilePath "steamcmd_buildid_output.log" -Encoding utf8
    # Search for build ID in Steam output
    if ($output -match '"branches"[\s\S]*?"public"[\s\S]*?"buildid"\s+"(\d+)"') {
        if ($matches.Count -ge 2) { return $matches[1] } else { Write-Log "[DEBUG] buildid match failed in steamcmd output"; return $null }
    } elseif ($output -match '"buildid"\s+"(\d+)"') {
        if ($matches.Count -ge 2) { return $matches[1] } else { Write-Log "[DEBUG] buildid match failed in steamcmd output (fallback)"; return $null }
    } else {
        Write-Log "[DEBUG] buildid not found in steamcmd output. Output: $output"
    }
    return $null
}

# --- UPDATE SYSTEM ---
# Handle server updates with delayed scheduling for online servers
function Update-Server {
    $manifestPath = Join-Path $serverDir "steamapps/appmanifest_$appId.acf"
    $firstInstall = -not (Test-Path $manifestPath)
    
    # Handle first installation
    if ($firstInstall) {
        Write-Log "[INFO] First installation - downloading server files via SteamCMD"
        # Stop service for safety during first install
        if (Check-ServiceRunning $serviceName) {
            Write-Log "[INFO] Stopping server service before first install..."
            cmd /c "net stop $serviceName"
            Start-Sleep -Seconds 10
        }
        $cmd = "$steamCmd +force_install_dir $serverDir +login anonymous +app_update $appId validate +quit"
        Write-Log "[INFO] Downloading server files (first install)..."
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -Wait -NoNewWindow -PassThru
        $exitCode = $process.ExitCode
        if ($exitCode -eq 0) {
            Write-Log "[INFO] First install/update successful. Starting service..."
            Send-Notification admin "firstInstallComplete" @{}
            cmd /c "net start $serviceName"
            
            # Enhanced startup monitoring for first install
            $startupResult = Monitor-SCUMServerStartup "first install" 8 15
            if ($startupResult.Success) {
                Write-Log "[INFO] SCUM server is online after first install."
                Notify-ServerOnline "First install completed"
                Notify-AdminActionResult "first install" "completed successfully" "ONLINE"
            } else {
                Write-Log "[ERROR] SCUM server failed to start after first install: $($startupResult.Reason)"
                Send-Notification admin "installError" @{ error = "Server failed to start after first install: $($startupResult.Reason)" }
                Notify-AdminActionResult "first install" "failed - $($startupResult.Reason)" "OFFLINE"
            }
            return $true
        } else {
            Write-Log "[ERROR] First install/update failed (code $exitCode)."
            Send-Notification admin "installFailed" @{ exitCode = $exitCode }
            Notify-AdminActionResult "first install" "failed with exit code $exitCode" "OFFLINE"
            return $false
        }
    }
    # Check for updates on existing installation
    $installedBuild = Get-InstalledBuildId
    $latestBuild = Get-LatestBuildId
    if ($null -eq $installedBuild -or $null -eq $latestBuild) {
        Write-Log "[WARNING] Could not determine buildid, skipping update. Will retry on next check."
        Send-Notification admin "updateWarning" @{ warning = "Could not determine buildid (SteamCMD error or timeout). Update skipped, will retry on next check." }
        # Player notification removed for updateWarning
        return $false
    } elseif ($installedBuild -eq $latestBuild) {
        Write-Log "[INFO] No new update available. Skipping update."
        # No Discord notification to avoid spam
        return $true
    } else {
        Write-Log "[INFO] New update available! Installed: $installedBuild, Latest: $latestBuild"
        Send-Notification admin "updateAvailable" @{ installed = $installedBuild; latest = $latestBuild }
        
        # Intelligent update scheduling: immediate if offline, delayed if online
        if (-not (Check-ServiceRunning $serviceName)) {
            Write-Log "[INFO] Server is not running, performing immediate update..."
            # Don't schedule delay, proceed with immediate update below
        } else {
            # Schedule delayed update with player notifications
            if ($null -eq $global:UpdateScheduledTime) {
                $global:UpdateScheduledTime = (Get-Date).AddMinutes($updateDelayMinutes)
                $global:UpdateWarning5Sent = $false
                $global:UpdateAvailableNotificationSent = $false
                Write-Log ("[INFO] Server is running, update scheduled for: {0}" -f $global:UpdateScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))
                
                # Send player notification about upcoming update
                Send-Notification player "updateAvailable" @{ delayMinutes = $updateDelayMinutes }
                $global:UpdateAvailableNotificationSent = $true
                
                return $false # Wait for scheduled time
            }
        }
    }
    # Execute immediate update (server offline or first install)
    # Stop server service before update
    Write-Log "[INFO] Stopping server service before update..."
    cmd /c "net stop $serviceName"
    Start-Sleep -Seconds 10
    $cmd = "$steamCmd +force_install_dir $serverDir +login anonymous +app_update $appId validate +quit"
    Write-Log "[INFO] Checking for update..."
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -Wait -NoNewWindow -PassThru
    $exitCode = $process.ExitCode
    if ($exitCode -eq 0) {
        Write-Log "[INFO] Server update successful. Starting service..."
        cmd /c "net start $serviceName"
        
        # Enhanced startup monitoring after update
        $startupResult = Monitor-SCUMServerStartup "update" 8 15
        if ($startupResult.Success) {
            Write-Log "[INFO] SCUM server is online after update."
            Send-Notification admin "updateSuccess" @{}
            Notify-ServerOnline "Update completed"
            Notify-AdminActionResult "update" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] SCUM server failed to start after update: $($startupResult.Reason)"
            Send-Notification admin "updateError" @{ error = "Server failed to start after update: $($startupResult.Reason)" }
            Notify-AdminActionResult "update" "failed - $($startupResult.Reason)" "OFFLINE"
        }
        return $true
    } else {
        Write-Log "[ERROR] Server update failed (code $exitCode)."
        Send-Notification admin "updateFailed" @{ exitCode = $exitCode }
        Notify-AdminActionResult "update" "failed with exit code $exitCode" "OFFLINE"
        return $false
    }
}

# --- DELAYED UPDATE EXECUTION ---
# Execute scheduled update with notifications
function Execute-ImmediateUpdate {
    Write-Log "[INFO] Executing scheduled update now..."
    Notify-UpdateInProgress "Scheduled update execution"
    Send-Notification player "updateStarting" @{}
    
    # Stop server service before update
    Write-Log "[INFO] Stopping server service before update..."
    cmd /c "net stop $serviceName"
    Start-Sleep -Seconds 10
    $cmd = "$steamCmd +force_install_dir $serverDir +login anonymous +app_update $appId validate +quit"
    Write-Log "[INFO] Installing update..."
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -Wait -NoNewWindow -PassThru
    $exitCode = $process.ExitCode
    if ($exitCode -eq 0) {
        Write-Log "[INFO] Server update successful. Starting service..."
        
        cmd /c "net start $serviceName"
        
        # Enhanced startup monitoring after delayed update
        $startupResult = Monitor-SCUMServerStartup "delayed update" 8 15
        if ($startupResult.Success) {
            Write-Log "[INFO] SCUM server is online after update."
            Notify-ServerOnline "Delayed update completed"
            Send-Notification admin "updateSuccess" @{}
            Send-Notification player "updateCompleted" @{}
            # Clear intentionally stopped flag after successful update
            $global:ServerIntentionallyStopped = $false
            Notify-AdminActionResult "update" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] SCUM server failed to start after update: $($startupResult.Reason)"
            Send-Notification admin "updateError" @{ error = "Server failed to start after update: $($startupResult.Reason)" }
            Notify-AdminActionResult "update" "failed - $($startupResult.Reason)" "OFFLINE"
        }
        
        # Reset update scheduling variables
        $global:UpdateScheduledTime = $null
        $global:UpdateWarning5Sent = $false
        $global:UpdateAvailableNotificationSent = $false
        
        return $true
    } else {
        Write-Log "[ERROR] Server update failed (code $exitCode)."
        Send-Notification admin "updateFailed" @{ exitCode = $exitCode }
        Notify-AdminActionResult "update" "failed with exit code $exitCode" "OFFLINE"
        
        # Reset update scheduling variables
        $global:UpdateScheduledTime = $null
        $global:UpdateWarning5Sent = $false
        $global:UpdateAvailableNotificationSent = $false
        
        return $false
    }
}

# --- RESTART TIMING ---
function Is-TimeForScheduledRestart {
    param([string[]]$restartTimes)
    $now = Get-Date
    foreach ($t in $restartTimes) {
        $target = [datetime]::ParseExact($t, 'HH:mm', $null)
        $scheduled = (Get-Date -Hour $target.Hour -Minute $target.Minute -Second 0)
        if ($now -ge $scheduled -and $now -lt $scheduled.AddMinutes(1)) {
            return $true
        }
    }
    return $false
}

# --- ADMIN COMMANDS ---
# Poll Discord for admin commands with role permissions  
function Poll-AdminCommands {
    # Rate limiting - only check Discord API every 30 seconds to avoid 429 errors
    $now = Get-Date
    if ($global:LastDiscordAPICall -ne $null) {
        $timeSinceLastCall = ($now - $global:LastDiscordAPICall).TotalSeconds
        if ($timeSinceLastCall -lt 30) {
            return # Skip this check to avoid rate limiting
        }
    }
    
    # Verify bot configuration is complete
    $channelIds = $adminCommandChannel.channelIds
    $roleIds = $adminCommandChannel.roleIds
    if (-not $botToken -or -not $channelIds -or -not $roleIds) {
        return
    }
    
    # Update last API call time
    $global:LastDiscordAPICall = $now
    
    $headers = @{ 
        Authorization = "Bot $botToken"
        "User-Agent" = "SCUM-Server-Manager/1.0"
        "Content-Type" = "application/json"
    }
    foreach ($channelId in $channelIds) {
        if (-not $channelId -or $channelId -eq "") { continue }
        
        # Build URI - if we have baseline, get messages after it
        $uri = if ($global:BaselineMessageId) {
            "https://discord.com/api/v10/channels/$channelId/messages?after=$($global:BaselineMessageId)&limit=10"
        } else {
            "https://discord.com/api/v10/channels/$channelId/messages?limit=1"
        }
        
        try {
            $messages = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
            
            # Sort messages by ID (older first) to process in chronological order
            $sortedMessages = $messages | Sort-Object { [uint64]$_.id }
            
            foreach ($msg in $sortedMessages) {
                $content = $msg.content
                $authorId = $msg.author.id
                $messageId = $msg.id
                $member = $msg.member
                $roles = $null
                if ($member) { $roles = $member.roles }
                
                # Skip if message was already processed
                if ($global:ProcessedMessageIds.ContainsKey($messageId)) {
                    continue
                }
                
                $isAllowed = $false
                if ($roles -and ($roles | Where-Object { $roleIds -contains $_ })) {
                    $isAllowed = $true
                } elseif (-not $roles) {
                    # If no roles, allow for testing (or specify your userId for restriction)
                    $isAllowed = $true
                }
                if ($isAllowed) {
                    # Mark message as processed before executing command
                    $global:ProcessedMessageIds[$messageId] = (Get-Date)
                    
                    # Update baseline to this message ID
                    $global:BaselineMessageId = $messageId
                    
                    # Clean up old processed messages (keep only last 50)
                    if ($global:ProcessedMessageIds.Count -gt 50) {
                        $oldestIds = $global:ProcessedMessageIds.GetEnumerator() | Sort-Object Value | Select-Object -First 25 | ForEach-Object { $_.Key }
                        foreach ($oldId in $oldestIds) {
                            $global:ProcessedMessageIds.Remove($oldId)
                        }
                    }
                    
                    # Clean up old notification tracking (keep only last 100)
                    if ($global:LastNotifications -and $global:LastNotifications.Count -gt 100) {
                        $oldestNotifications = $global:LastNotifications.GetEnumerator() | 
                                             Sort-Object Value | Select-Object -First 50 | ForEach-Object { $_.Key }
                        foreach ($oldNotifKey in $oldestNotifications) {
                            $global:LastNotifications.Remove($oldNotifKey)
                        }
                    }
                    # Process individual admin commands using configurable prefix
                    if ($content -like "${commandPrefix}server_restart*") {
                        # Parse delay parameter
                        $parts = $content -split '\s+'
                        $delayMinutes = 0
                        if ($parts.Length -gt 1 -and [int]::TryParse($parts[1], [ref]$delayMinutes) -and $delayMinutes -gt 0 -and $delayMinutes -le 180) {
                            # Delayed restart
                            Write-Log "[ADMIN CMD] ${commandPrefix}server_restart $delayMinutes by $authorId"
                            $global:AdminRestartScheduledTime = (Get-Date).AddMinutes($delayMinutes)
                            $global:AdminRestartWarning5Sent = $false
                            
                            $delayText = " in $delayMinutes minutes"
                            Send-Notification admin "adminRestart" @{ admin = $authorId; delay = $delayText }
                            Send-Notification player "adminRestartWarning" @{ delayMinutes = $delayMinutes }
                            Write-Log ("[INFO] Admin restart scheduled for: {0}" -f $global:AdminRestartScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))
                        } else {
                            # Immediate restart
                            Write-Log "[ADMIN CMD] ${commandPrefix}server_restart (immediate) by $authorId"
                            Send-Notification admin "adminRestart" @{ admin = $authorId; delay = " immediately" }
                            Send-Notification player "adminRestartNow" @{}
                            
                            # Clear the intentionally stopped flag (restart means we want server running)
                            $global:ServerIntentionallyStopped = $false
                            # Backup and restart server
                            Notify-ServerRestarting "Admin immediate restart"
                            Backup-Saved | Out-Null
                            cmd /c "net stop $serviceName"
                            Start-Sleep -Seconds 10
                            cmd /c "net start $serviceName"
                            Start-Sleep -Seconds 5
                            
                            # Check result with SCUM log monitoring
                            $startupResult = Monitor-SCUMServerStartup "admin restart" 6 10
                            if ($startupResult.Success) {
                                Notify-ServerStatusChange "Online" "Admin restart command" @{ PlayerCount = $startupResult.Status.PlayerCount }
                                Notify-AdminActionResult "restart" "completed successfully" "ONLINE"
                            } else {
                                Notify-ServerOffline "Admin restart failed"
                                Notify-AdminActionResult "restart" "failed - $($startupResult.Reason)" "OFFLINE"
                            }
                        }
                    } elseif ($content -like "${commandPrefix}server_stop*") {
                        # Parse delay parameter
                        $parts = $content -split '\s+'
                        $delayMinutes = 0
                        if ($parts.Length -gt 1 -and [int]::TryParse($parts[1], [ref]$delayMinutes) -and $delayMinutes -gt 0 -and $delayMinutes -le 180) {
                            # Delayed stop
                            Write-Log "[ADMIN CMD] ${commandPrefix}server_stop $delayMinutes by $authorId"
                            $global:AdminStopScheduledTime = (Get-Date).AddMinutes($delayMinutes)
                            $global:AdminStopWarning5Sent = $false
                            
                            Send-Notification admin "adminStop" @{ admin = $authorId }
                            Send-Notification player "adminStopWarning" @{ delayMinutes = $delayMinutes }
                            Write-Log ("[INFO] Admin stop scheduled for: {0}" -f $global:AdminStopScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))
                        } else {
                            # Immediate stop
                            Write-Log "[ADMIN CMD] ${commandPrefix}server_stop (immediate) by $authorId"
                            Send-Notification admin "adminStop" @{ admin = $authorId }
                            Send-Notification player "adminStopNow" @{}
                            
                            # Set flag to prevent auto-restart
                            $global:ServerIntentionallyStopped = $true
                            Write-Log "[INFO] Server intentionally stopped by admin - auto-restart disabled until manual start"
                            
                            # Check if server is already stopped
                            if (-not (Check-ServiceRunning $serviceName)) {
                                Write-Log "[INFO] Server service is already stopped"
                                Send-Notification admin "otherEvent" @{ event = "Admin $authorId tried to stop server, but it's already stopped" }
                                Notify-AdminActionResult "stop" "already stopped" "OFFLINE"
                            } else {
                                cmd /c "net stop $serviceName"
                                Start-Sleep -Seconds 5
                                
                                # Verify stop was successful
                                if (-not (Check-ServiceRunning $serviceName)) {
                                    # Always notify about server being stopped
                                    Notify-ServerStatusChange "Offline" "Admin stop command"
                                    Notify-AdminActionResult "stop" "completed successfully" "OFFLINE"
                                } else {
                                    Write-Log "[ERROR] Failed to stop server service"
                                    Send-Notification admin "otherEvent" @{ event = "Admin $authorId tried to stop server, but service stop failed" }
                                    Notify-AdminActionResult "stop" "failed - service still running" "UNKNOWN"
                                }
                            }
                            Notify-ServerOffline "Admin stop command"
                            Notify-AdminActionResult "stop" "completed successfully" "OFFLINE"
                        }
                    } elseif ($content -like "${commandPrefix}server_start*") {
                        # Parse delay parameter
                        $parts = $content -split '\s+'
                        $delayMinutes = 0
                        if ($parts.Length -gt 1 -and [int]::TryParse($parts[1], [ref]$delayMinutes) -and $delayMinutes -gt 0 -and $delayMinutes -le 180) {
                            # Delayed start
                            Write-Log "[ADMIN CMD] ${commandPrefix}server_start $delayMinutes by $authorId"
                            Send-Notification admin "adminStart" @{ admin = $authorId }
                            Send-Notification player "adminStartWarning" @{ delayMinutes = $delayMinutes }
                            
                            # For start, we'll implement immediate start with notification (no scheduled delay)
                            Write-Log "[INFO] Admin requested delayed start - executing immediately with notification"
                            $delayText = " (delay ignored for start command)"
                        } else {
                            # Immediate start
                            Write-Log "[ADMIN CMD] ${commandPrefix}server_start (immediate) by $authorId"
                            $delayText = " immediately"
                        }
                        
                        Send-Notification admin "adminStart" @{ admin = $authorId; delay = $delayText }
                        Send-Notification player "adminStartNow" @{}
                        
                        # Clear the intentionally stopped flag
                        $global:ServerIntentionallyStopped = $false
                        Write-Log "[INFO] Auto-restart re-enabled after admin start command"
                        
                        # Check if server is already running
                        if (Check-ServiceRunning $serviceName) {
                            Write-Log "[INFO] Server service is already running"
                            Send-Notification admin "otherEvent" @{ event = "Admin $authorId tried to start server, but it's already running" }
                        } else {
                            cmd /c "net start $serviceName"
                            Start-Sleep -Seconds 5
                            
                            # Check result with SCUM log monitoring
                            $startupResult = Monitor-SCUMServerStartup "admin start" 6 10
                            if ($startupResult.Success) {
                                Notify-ServerStatusChange "Online" "Admin start command" @{ PlayerCount = $startupResult.Status.PlayerCount }
                                Notify-AdminActionResult "start" "completed successfully" "ONLINE"
                            } else {
                                Notify-ServerStatusChange "Offline" "Admin start failed"
                                Notify-AdminActionResult "start" "failed - $($startupResult.Reason)" "OFFLINE"
                            }
                        }
                    } elseif ($content -like "${commandPrefix}server_update*") {
                        # Parse delay parameter for update command
                        $parts = $content -split '\s+'
                        $delayMinutes = 0
                        $isDelayed = $false
                        
                        if ($parts.Length -gt 1 -and [int]::TryParse($parts[1], [ref]$delayMinutes) -and $delayMinutes -gt 0 -and $delayMinutes -le 180) {
                            $isDelayed = $true
                        }
                        
                        Write-Log "[ADMIN CMD] ${commandPrefix}server_update by $authorId"
                        
                        # Use intelligent scheduling (immediate if offline)
                        if (-not (Check-ServiceRunning $serviceName)) {
                            Write-Log "[INFO] Server is not running, performing immediate update..."
                            $delayText = if ($isDelayed) { " (requested delay ignored - server offline)" } else { "" }
                            Send-Notification admin "adminUpdate" @{ admin = $authorId; delay = $delayText }
                            Send-Notification player "adminUpdateNow" @{}
                            
                            if (Execute-ImmediateUpdate) {
                                Write-Log "[INFO] Admin-requested immediate update completed successfully (server was offline)."
                            } else {
                                Write-Log "[ERROR] Admin-requested immediate update failed (server was offline)!"
                            }
                        } else {
                            if ($isDelayed) {
                                # Use custom delay
                                $global:AdminUpdateScheduledTime = (Get-Date).AddMinutes($delayMinutes)
                                $global:AdminUpdateWarning5Sent = $false
                                $delayText = " in $delayMinutes minutes"
                                Send-Notification player "adminUpdateWarning" @{ delayMinutes = $delayMinutes }
                            } else {
                                # Use default delay
                                $global:AdminUpdateScheduledTime = (Get-Date).AddMinutes($updateDelayMinutes)
                                $global:AdminUpdateWarning5Sent = $false
                                $delayText = " in $updateDelayMinutes minutes"
                                Send-Notification player "adminUpdateWarning" @{ delayMinutes = $updateDelayMinutes }
                            }
                            
                            Send-Notification admin "adminUpdate" @{ admin = $authorId; delay = $delayText }
                            Write-Log ("[INFO] Server is running, admin-requested update scheduled for: {0}" -f $global:AdminUpdateScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))
                        }
                    } elseif ($content -like "${commandPrefix}server_update_now*") {
                        Write-Log "[ADMIN CMD] ${commandPrefix}server_update_now by $authorId"
                        Send-Notification admin "adminUpdate" @{ admin = $authorId; delay = " immediately" }
                        Send-Notification player "adminUpdateNow" @{}
                        
                        # Cancel any scheduled update and execute immediately
                        $global:UpdateScheduledTime = $null
                        $global:UpdateWarning5Sent = $false
                        $global:UpdateAvailableNotificationSent = $false
                        $global:AdminUpdateScheduledTime = $null
                        $global:AdminUpdateWarning5Sent = $false
                        
                        if (Execute-ImmediateUpdate) {
                            Write-Log "[INFO] Admin-requested immediate update completed successfully."
                        } else {
                            Write-Log "[ERROR] Admin-requested immediate update failed!"
                        }
                    } elseif ($content -like "${commandPrefix}server_cancel_update*") {
                        Write-Log "[ADMIN CMD] ${commandPrefix}server_cancel_update by $authorId"
                        
                        $anyCancelled = $false
                        if ($null -ne $global:UpdateScheduledTime) {
                            Write-Log "[INFO] Cancelling automatic scheduled update planned for $($global:UpdateScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                            $global:UpdateScheduledTime = $null
                            $global:UpdateWarning5Sent = $false
                            $global:UpdateAvailableNotificationSent = $false
                            $anyCancelled = $true
                        }
                        if ($null -ne $global:AdminUpdateScheduledTime) {
                            Write-Log "[INFO] Cancelling admin scheduled update planned for $($global:AdminUpdateScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                            $global:AdminUpdateScheduledTime = $null
                            $global:AdminUpdateWarning5Sent = $false
                            $anyCancelled = $true
                        }
                        
                        if ($anyCancelled) {
                            Send-Notification admin "otherEvent" @{ event = "Scheduled update cancelled by admin $authorId" }
                        } else {
                            Write-Log "[INFO] No update scheduled to cancel."
                            Send-Notification admin "otherEvent" @{ event = "Admin $authorId tried to cancel update, but no update was scheduled" }
                        }
                    } elseif ($content -like "${commandPrefix}server_backup*") {
                        Write-Log "[ADMIN CMD] ${commandPrefix}server_backup by $authorId"
                        Send-Notification admin "adminBackup" @{ admin = $authorId }
                        # Execute backup
                        Backup-Saved | Out-Null
                    } elseif ($content -like "${commandPrefix}server_reset_autorestart*") {
                        Write-Log "[ADMIN CMD] ${commandPrefix}server_reset_autorestart by $authorId"
                        $previousAttempts = $global:ConsecutiveRestartAttempts
                        $global:ConsecutiveRestartAttempts = 0
                        $global:LastAutoRestartAttempt = $null
                        $global:ServerIntentionallyStopped = $false
                        Write-Log "[INFO] Auto-restart counters reset by admin. Previous attempts: $previousAttempts"
                        Send-Notification admin "otherEvent" @{ event = "Admin $authorId reset auto-restart counters (was: $previousAttempts attempts). Auto-restart is now re-enabled." }
                    } elseif ($content -like "${commandPrefix}server_status*") {
                        Write-Log "[ADMIN CMD] ${commandPrefix}server_status by $authorId"
                        $serverStatus = Get-SCUMServerStatus
                        $serviceRunning = Check-ServiceRunning $serviceName
                        $timeSinceLastAttempt = if ($global:LastAutoRestartAttempt) { [Math]::Round(((Get-Date) - $global:LastAutoRestartAttempt).TotalMinutes, 1) } else { "N/A" }
                        $intentionallyStopped = if ($global:ServerIntentionallyStopped) { "YES" } else { "NO" }
                        
                        $statusReport = @"
**Server Status Report:**
• SCUM Server Status: $($serverStatus.Status) ($($serverStatus.Phase))
• Windows Service: $(if ($serviceRunning) { "RUNNING" } else { "STOPPED" })
• Players Online: $($serverStatus.PlayerCount)
• Last Activity: $($serverStatus.LastActivity)
• Intentionally Stopped: $intentionallyStopped
• Auto-restart Attempts: $($global:ConsecutiveRestartAttempts)/$($global:MaxConsecutiveRestartAttempts)
• Minutes Since Last Attempt: $timeSinceLastAttempt
• Cooldown Period: $($global:AutoRestartCooldownMinutes) minutes
• Performance Thresholds: Excellent >=$($performanceThresholds.excellent)fps, Good >=$($performanceThresholds.good)fps, Fair >=$($performanceThresholds.fair)fps, Poor >=$($performanceThresholds.poor)fps
"@
                        Send-Notification admin "otherEvent" @{ event = $statusReport }
                    }
                }
            }
        } catch {
            # Reduce error spam - log only every 60 seconds for channel access errors
            if (-not $global:LastCommandErrorTime -or ((Get-Date) - $global:LastCommandErrorTime).TotalSeconds -ge 60) {
                $errMsg = $_.Exception.Message
                $respBody = $null
                # PowerShell 7+ compatibility fix for HTTP response reading
                if ($_.Exception.Response) {
                    try {
                        # Try modern PowerShell 7+ approach first
                        if ($_.Exception.Response.Content -and $_.Exception.Response.Content.ReadAsStringAsync) {
                            $respBody = $_.Exception.Response.Content.ReadAsStringAsync().Result
                        }
                        # Fallback to Windows PowerShell approach
                        elseif ($_.Exception.Response.GetResponseStream) {
                            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                            $respBody = $reader.ReadToEnd()
                            $reader.Close()
                        }
                    } catch {
                        $respBody = "Unable to read response body"
                    }
                }
                Write-Log ("[ERROR] Discord API temporarily unavailable (rate limited) for channel {0}" -f $channelId)
                $global:LastCommandErrorTime = Get-Date
            }
        }
    }
}

# --- MAIN EXECUTION LOOP ---
# Initialize state tracking variables
$global:LastBackupTime = $null
$global:LastUpdateCheck = $null
$global:LastRestartTime = $null

# Update scheduling variables
$global:UpdateScheduledTime = $null
$global:UpdateWarning5Sent = $false
$global:UpdateAvailableNotificationSent = $false
$global:LastCommandErrorTime = $null

# Track processed Discord messages to avoid duplicate command execution
$global:ProcessedMessageIds = @{}

# Initialize baseline message ID to only process new messages after script start
$global:BaselineMessageId = $null

# Track if server was intentionally stopped by admin (to prevent auto-restart)
$global:ServerIntentionallyStopped = $false

# Track last Discord API call time for rate limiting (minimum 30 seconds between calls)
$global:LastDiscordAPICall = $null

# Track scheduled admin actions
$global:AdminRestartScheduledTime = $null
$global:AdminRestartWarning5Sent = $false
$global:AdminStopScheduledTime = $null
$global:AdminStopWarning5Sent = $false
$global:AdminUpdateScheduledTime = $null
$global:AdminUpdateWarning5Sent = $false

# Track auto-restart attempts to prevent spam
$global:LastAutoRestartAttempt = $null
$global:AutoRestartCooldownMinutes = if ($config.autoRestartCooldownMinutes) { $config.autoRestartCooldownMinutes } else { 2 }
$global:MaxConsecutiveRestartAttempts = if ($config.maxConsecutiveRestartAttempts) { $config.maxConsecutiveRestartAttempts } else { 3 }
$global:ConsecutiveRestartAttempts = 0

# Initialize baseline - get the latest message ID when script starts
function Initialize-MessageBaseline {
    if (-not $botToken -or -not $adminCommandChannel.channelIds) {
        return
    }
    
    $headers = @{ 
        Authorization = "Bot $botToken"
        "User-Agent" = "SCUM-Server-Manager/1.0"
        "Content-Type" = "application/json"
    }
    
    foreach ($channelId in $adminCommandChannel.channelIds) {
        if (-not $channelId -or $channelId -eq "") { continue }
        try {
            $uri = "https://discord.com/api/v10/channels/$channelId/messages?limit=1"
            $messages = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
            if ($messages -and $messages.Count -gt 0) {
                $global:BaselineMessageId = $messages[0].id
                Write-Log ("[INFO] Baseline message ID set to: {0} (only newer messages will be processed)" -f $global:BaselineMessageId)
                break
            }
        } catch {
            # Suppress baseline initialization errors to reduce startup noise
            # Write-Log ("[WARN] Could not initialize Discord baseline for channel {0}: rate limited" -f $channelId)
        }
    }
}

Write-Log "--- Script started ---"
Write-Log ("[INFO] Restart times configured: {0}" -f ($restartTimes -join ', '))
Write-Log ("[INFO] Admin command prefix: '{0}'" -f $commandPrefix)
$periodicBackupStatus = if ($periodicBackupEnabled) { "ENABLED (every $backupIntervalMinutes minutes)" } else { "DISABLED" }
Write-Log ("[INFO] Periodic backup: {0}" -f $periodicBackupStatus)
Write-Log ("[INFO] Performance thresholds: Excellent >={0}fps, Good >={1}fps, Fair >={2}fps, Poor >={3}fps, Critical <{3}fps" -f $performanceThresholds.excellent, $performanceThresholds.good, $performanceThresholds.fair, $performanceThresholds.poor)

# Initialize Discord message baseline to only process new messages
Initialize-MessageBaseline

Send-Notification admin "managerStarted" @{}

# Calculate next restart time helper
function Get-NextScheduledRestart {
    param([string[]]$restartTimes)
    $now = Get-Date
    $todayRestarts = $restartTimes | ForEach-Object {
        $t = [datetime]::ParseExact($_, 'HH:mm', $null)
        $scheduled = (Get-Date -Hour $t.Hour -Minute $t.Minute -Second 0)
        if ($scheduled -gt $now) { $scheduled } else { $null }
    } | Where-Object { $_ -ne $null }
    if ($todayRestarts.Count -gt 0) {
        return ($todayRestarts | Sort-Object)[0]
    } else {
        # Next day's first restart
        $t = [datetime]::ParseExact($restartTimes[0], 'HH:mm', $null)
        return ((Get-Date).AddDays(1).Date.AddHours($t.Hour).AddMinutes($t.Minute))
    }
}

# --- RESTART WARNING SYSTEM ---
$restartWarningDefs = @(
    @{ key = 'restartWarning15'; minutes = 15 },
    @{ key = 'restartWarning5'; minutes = 5 },
    @{ key = 'restartWarning1'; minutes = 1 },
    @{ key = 'restartNow'; minutes = 0 }
)
$restartWarningSent = @{}
$nextRestartTime = Get-NextScheduledRestart $restartTimes
foreach ($def in $restartWarningDefs) { $restartWarningSent[$def.key] = $false }
$restartPerformedTime = $null

Write-Log ("[INFO] Next scheduled restart: {0}" -f $nextRestartTime.ToString('yyyy-MM-dd HH:mm:ss'))

# --- STARTUP INITIALIZATION ---
# Check for first install (missing manifest or server directory)
$manifestPath = Join-Path $serverDir "steamapps/appmanifest_$appId.acf"
$firstInstall = $false
if (!(Test-Path $manifestPath) -or !(Test-Path $serverDir)) {
    Write-Log "[INFO] Server files or manifest not found, performing first install/update."
    Send-Notification admin "firstInstall" @{
        }
    Update-Server | Out-Null
    $global:LastUpdateCheck = Get-Date
    $firstInstall = $true
}

# Run initial backup if enabled (not on first install)
if ($runBackupOnStart -and -not $firstInstall) {
    Write-Log "[INFO] Running initial backup (runBackupOnStart enabled) before any update or service start."
    Backup-Saved | Out-Null
    $global:LastBackupTime = Get-Date
} elseif ($periodicBackupEnabled) {
    # Initialize LastBackupTime to prevent immediate periodic backup
    $global:LastBackupTime = Get-Date
    Write-Log "[INFO] Periodic backup enabled, timer initialized"
}

# Run initial update check if enabled
if ($runUpdateOnStart -and -not $firstInstall) {
    Write-Log "[INFO] Running initial update check (runUpdateOnStart enabled)"
    $installedBuild = Get-InstalledBuildId
    $latestBuild = Get-LatestBuildId
    if ($null -eq $installedBuild -or $null -eq $latestBuild) {
        Write-Log "[WARNING] Could not determine buildid, running update as fallback."
        Send-Notification admin "updateWarning" @{
            warning = "Could not determine buildid, running update as fallback."
        }
        Update-Server | Out-Null
        $global:LastUpdateCheck = Get-Date
    } elseif ($installedBuild -eq $latestBuild) {
        Write-Log "[INFO] No new update available. Skipping update."
        if (-not (Check-ServiceRunning $serviceName)) {
            Write-Log "[INFO] Starting server service after backup and update check."
            cmd /c "net start $serviceName"
            
            # Enhanced startup monitoring
            $startupResult = Monitor-SCUMServerStartup "startup after update check" 8 15
            if ($startupResult.Success) {
                Write-Log "[INFO] SCUM server started successfully after backup and update check."
                Notify-ServerStatusChange "Online" "Startup after update check" @{ PlayerCount = $startupResult.Status.PlayerCount }
                Notify-AdminActionResult "startup after update check" "completed successfully" "ONLINE"
            } else {
                Write-Log "[ERROR] SCUM server failed to start after backup and update check: $($startupResult.Reason)"
                Send-Notification admin "restartError" @{
                    error = "The SCUM server failed to start after backup and update check: $($startupResult.Reason)"
                }
                Notify-AdminActionResult "startup after update check" "failed - $($startupResult.Reason)" "OFFLINE"
            }
        } else {
            Write-Log "[INFO] Server service is already running after update check."
        }
        $global:LastUpdateCheck = Get-Date
    } else {
        Write-Log "[INFO] New update available! Installed: $installedBuild, Latest: $latestBuild"
        Send-Notification admin "updateAvailable" @{
            installed = $installedBuild
            latest = $latestBuild
        }
        # Player notification removed for updateAvailable
        Update-Server | Out-Null
        $global:LastUpdateCheck = Get-Date
    }
} elseif (-not $firstInstall) {
    # If not updating on start, just start the service if not running
    if (-not (Check-ServiceRunning $serviceName)) {
        Write-Log "[INFO] Starting server service after backup (no update on start)."
        cmd /c "net start $serviceName"
        
        # Enhanced startup monitoring
        $startupResult = Monitor-SCUMServerStartup "startup after backup" 8 15
        if ($startupResult.Success) {
            Write-Log "[INFO] SCUM server started successfully after backup."
            Notify-ServerStatusChange "Online" "Startup after backup" @{ PlayerCount = $startupResult.Status.PlayerCount }
            Notify-AdminActionResult "startup after backup" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] SCUM server failed to start after backup: $($startupResult.Reason)"
            Send-Notification admin "restartError" @{
                error = "The SCUM server failed to start after backup: $($startupResult.Reason)"
            }
            Notify-AdminActionResult "startup after backup" "failed - $($startupResult.Reason)" "OFFLINE"
        }
    } else {
        Write-Log "[INFO] Server service is already running, no action needed."
    }
}

# --- MAIN MONITORING LOOP ---
# Performance monitoring variables
$global:LastPerformanceLogTime = $null
$global:LastPerformanceStatus = ""
$performanceLogInterval = if ($config.performanceLogIntervalMinutes) { $config.performanceLogIntervalMinutes } else { 5 }
$fpsAlertThreshold = if ($config.fpsAlertThreshold) { $config.fpsAlertThreshold } else { 15 }
$fpsWarningThreshold = if ($config.fpsWarningThreshold) { $config.fpsWarningThreshold } else { 20 }

# --- PERFORMANCE HELPER FUNCTIONS ---
# Determine performance status based on configurable thresholds
function Get-PerformanceStatus {
    param([double]$fps)
    
    if ($fps -le 0) { return "Unknown" }
    
    if ($fps -ge $performanceThresholds.excellent) {
        return "Excellent"
    } elseif ($fps -ge $performanceThresholds.good) {
        return "Good"
    } elseif ($fps -ge $performanceThresholds.fair) {
        return "Fair"
    } elseif ($fps -ge $performanceThresholds.poor) {
        return "Poor"
    } else {
        return "Critical"
    }
}

# Parse FPS and performance data from SCUM server log
function Get-ServerPerformanceStats {
    param(
        [string]$logPath,
        [int]$maxLines = 100
    )
    
    if (!(Test-Path $logPath)) {
        return $null
    }
    
    try {
        $logLines = Get-Content $logPath -Tail $maxLines -ErrorAction Stop
        
        # Find the most recent Global Stats entry
        for ($i = $logLines.Count - 1; $i -ge 0; $i--) {
            $line = $logLines[$i]
            
            if ($line -match 'LogSCUM: Global Stats:') {
                # Extract timestamp
                $timestamp = $null
                if ($line -match '^\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3})') {
                    try {
                        $timestampStr = $matches[1] -replace '(\d{4})\.(\d{2})\.(\d{2})-(\d{2})\.(\d{2})\.(\d{2}):(\d{3})', '$1-$2-$3 $4:$5:$6.$7'
                        $timestamp = [DateTime]::ParseExact($timestampStr, 'yyyy-MM-dd HH:mm:ss.fff', $null)
                    } catch {
                        $timestamp = Get-Date
                    }
                }
                
                # Parse FPS values
                $fpsValues = @()
                $frameTimeValues = @()
                
                [regex]::Matches($line, '(\d+\.?\d*)ms\s*\(\s*(\d+\.?\d*)FPS\)') | ForEach-Object {
                    $frameTime = [double]$_.Groups[1].Value
                    $fps = [double]$_.Groups[2].Value
                    $frameTimeValues += $frameTime
                    $fpsValues += $fps
                }
                
                # Extract player count
                $playerCount = 0
                if ($line -match 'P:\s*(\d+)\s*\(\s*(\d+)\)') {
                    $playerCount = [int]$matches[1]
                }
                
                # Extract entity counts
                $entities = @{
                }
                if ($line -match 'C:\s*(\d+)') { $entities['Characters'] = [int]$matches[1] }
                if ($line -match 'P:\s*(\d+)') { $entities['Players'] = [int]$matches[1] }
                if ($line -match 'Z:\s*(\d+)') { $entities['Zombies'] = [int]$matches[1] }
                if ($line -match 'R:\s*(\d+)') { $entities['Replicated'] = [int]$matches[1] }
                if ($line -match 'S:\s*(\d+)') { $entities['Static'] = [int]$matches[1] }
                if ($line -match 'A:\s*(\d+)') { $entities['Actors'] = [int]$matches[1] }
                if ($line -match 'V:\s*(\d+)') { $entities['Vehicles'] = [int]$matches[1] }
                
                # Calculate performance metrics
                $avgFPS = if ($fpsValues.Count -gt 0) { [Math]::Round(($fpsValues | Measure-Object -Average).Average, 1) } else { 0 }
                $minFPS = if ($fpsValues.Count -gt 0) { [Math]::Round(($fpsValues | Measure-Object -Minimum).Minimum, 1) } else { 0 }
                $maxFPS = if ($fpsValues.Count -gt 0) { [Math]::Round(($fpsValues | Measure-Object -Maximum).Maximum, 1) } else { 0 }
                $avgFrameTime = if ($frameTimeValues.Count -gt 0) { [Math]::Round(($frameTimeValues | Measure-Object -Average).Average, 1) } else { 0 }
                
                # Determine performance status using configurable thresholds
                $performanceStatus = Get-PerformanceStatus $avgFPS
                
                return @{
                    Timestamp = $timestamp
                    AverageFPS = $avgFPS
                    MinFPS = $minFPS
                    MaxFPS = $maxFPS
                    AverageFrameTime = $avgFrameTime
                    FPSValues = $fpsValues
                    FrameTimeValues = $frameTimeValues
                    PlayerCount = $playerCount
                    Entities = $entities
                    PerformanceStatus = $performanceStatus
                    RawLine = $line
                }
            }
        }
        
        return $null
        
    } catch {
        Write-Log "[DEBUG] Error parsing performance stats: $($_.Exception.Message)"
        return $null
    }
}

# Get performance summary for notifications and monitoring
function Get-PerformanceSummary {
    param([hashtable]$perfStats)
    
    if ($null -eq $perfStats) {
        return "Performance data not available"
    }
    
    $summary = "FPS: $($perfStats.AverageFPS) avg"
    if ($perfStats.MinFPS -ne $perfStats.MaxFPS) {
        $summary += " ($($perfStats.MinFPS)-$($perfStats.MaxFPS))"
    }
    $summary += ", Frame: $($perfStats.AverageFrameTime)ms"
    $summary += ", Players: $($perfStats.PlayerCount)"
    $summary += ", Status: $($perfStats.PerformanceStatus)"
    
    return $summary
}
# --- MAIN MONITORING LOOP ---
Write-Log "[INFO] Starting main server monitoring loop..."

# Performance monitoring variables
$global:LastPerformanceLogTime = $null
$global:LastPerformanceStatus = ""
$performanceLogInterval = if ($config.performanceLogIntervalMinutes) { $config.performanceLogIntervalMinutes } else { 5 }
$fpsAlertThreshold = if ($config.fpsAlertThreshold) { $config.fpsAlertThreshold } else { 15 }
$fpsWarningThreshold = if ($config.fpsWarningThreshold) { $config.fpsWarningThreshold } else { 20 }

# Main monitoring loop
try {
    while ($true) {
        $currentTime = Get-Date
        $now = Get-Date  # Define $now variable used throughout the loop
        $updateOrRestart = $false  # Initialize flag for update/restart operations
        
        # Check if server is running
        $serverRunning = Check-ServiceRunning $serviceName
    
    # Admin Restart
    if ($null -ne $global:AdminRestartScheduledTime) {
        $restartDelay = ($global:AdminRestartScheduledTime - $now).TotalMinutes
        $warningMinutes = [Math]::Min(5, [Math]::Floor($restartDelay / 2))
        
        if ($restartDelay -gt 5 -and -not $global:AdminRestartWarning5Sent -and $now -ge $global:AdminRestartScheduledTime.AddMinutes(-$warningMinutes) -and $now -lt $global:AdminRestartScheduledTime.AddMinutes(-$warningMinutes).AddSeconds(30)) {
            Send-Notification player "adminRestartWarning5" @{ warningMinutes = $warningMinutes }
            Write-Log ("[INFO] Sent admin restart {0}-minute warning at {1}" -f $warningMinutes, $now.ToString('HH:mm:ss'))
            $global:AdminRestartWarning5Sent = $true
        }
        
        if ($now -ge $global:AdminRestartScheduledTime) {
            Write-Log "[INFO] Admin restart time reached, restarting server..."
            Send-Notification admin "adminRestart" @{ admin = "System"; delay = " (scheduled)" }
            Send-Notification player "adminRestartNow" @{}
            
            # Clear the intentionally stopped flag (restart means we want server running)
            $global:ServerIntentionallyStopped = $false
            
            # Backup and restart server
            Backup-Saved | Out-Null
            cmd /c "net stop $serviceName"
            Start-Sleep -Seconds 10
            cmd /c "net start $serviceName"
            Start-Sleep -Seconds 5
            
            # Check result with SCUM log monitoring
            $startupResult = Monitor-SCUMServerStartup "admin scheduled restart" 6 10
            if ($startupResult.Success) {
                Notify-ServerStatusChange "Online" "Admin scheduled restart command" @{ PlayerCount = $startupResult.Status.PlayerCount }
                Notify-AdminActionResult "scheduled restart" "completed successfully" "ONLINE"
            } else {
                Notify-ServerStatusChange "Offline" "Admin scheduled restart failed"
                Notify-AdminActionResult "scheduled restart" "failed - $($startupResult.Reason)" "OFFLINE"
            }
            
            # Clear scheduling
            $global:AdminRestartScheduledTime = $null
            $global:AdminRestartWarning5Sent = $false
            $updateOrRestart = $true
        }
    }
    
    # Admin Stop
    if ($null -ne $global:AdminStopScheduledTime) {
        $stopDelay = ($global:AdminStopScheduledTime - $now).TotalMinutes
        $warningMinutes = [Math]::Min(5, [Math]::Floor($stopDelay / 2))
        
        if ($stopDelay -gt 5 -and -not $global:AdminStopWarning5Sent -and $now -ge $global:AdminStopScheduledTime.AddMinutes(-$warningMinutes) -and $now -lt $global:AdminStopScheduledTime.AddMinutes(-$warningMinutes).AddSeconds(30)) {
            Send-Notification player "adminStopWarning5" @{ warningMinutes = $warningMinutes }
            Write-Log ("[INFO] Sent admin stop {0}-minute warning at {1}" -f $warningMinutes, $now.ToString('HH:mm:ss'))
            $global:AdminStopWarning5Sent = $true
        }
        
        if ($now -ge $global:AdminStopScheduledTime) {
            Write-Log "[INFO] Admin stop time reached, stopping server..."
            Send-Notification player "adminStopNow" @{}
            
            # Set flag to prevent auto-restart
            $global:ServerIntentionallyStopped = $true
            
            # Check if server is already stopped
            if (-not (Check-ServiceRunning $serviceName)) {
                Write-Log "[INFO] Server service is already stopped during scheduled stop"
                Notify-AdminActionResult "scheduled stop" "already stopped" "OFFLINE"
            } else {
                cmd /c "net stop $serviceName"
                Start-Sleep -Seconds 5
                
                # Verify stop was successful
                if (-not (Check-ServiceRunning $serviceName)) {
                    # Always notify about server being stopped
                    Notify-ServerStatusChange "Offline" "Admin stop command"
                    Notify-AdminActionResult "scheduled stop" "completed successfully" "OFFLINE"
                } else {
                    Write-Log "[ERROR] Failed to stop server service during scheduled stop"
                    Notify-AdminActionResult "scheduled stop" "failed - service still running" "UNKNOWN"
                }
            }
            
            # Clear scheduling
            $global:AdminStopScheduledTime = $null
            $global:AdminStopWarning5Sent = $false
        }
    }
    
    # Admin Update
    if ($null -ne $global:AdminUpdateScheduledTime) {
        $updateDelay = ($global:AdminUpdateScheduledTime - $now).TotalMinutes
        $warningMinutes = [Math]::Min(5, [Math]::Floor($updateDelay / 2))
        
        if ($updateDelay -gt 5 -and -not $global:AdminUpdateWarning5Sent -and $now -ge $global:AdminUpdateScheduledTime.AddMinutes(-$warningMinutes) -and $now -lt $global:AdminUpdateScheduledTime.AddMinutes(-$warningMinutes).AddSeconds(30)) {
            Send-Notification player "adminUpdateWarning5" @{ warningMinutes = $warningMinutes }
            Write-Log ("[INFO] Sent admin update {0}-minute warning at {1}" -f $warningMinutes, $now.ToString('HH:mm:ss'))
            $global:AdminUpdateWarning5Sent = $true
        }
        
        if ($now -ge $global:AdminUpdateScheduledTime) {
            Write-Log "[INFO] Admin update time reached, executing update..."
            Send-Notification player "adminUpdateNow" @{}
            
            if (Execute-ImmediateUpdate) {
                $updateOrRestart = $true
                Write-Log "[INFO] Admin scheduled update completed successfully."
            } else {
                Write-Log "[ERROR] Admin scheduled update failed!"
            }
            
            # Clear scheduling
            $global:AdminUpdateScheduledTime = $null
            $global:AdminUpdateWarning5Sent = $false
        }
    }
    
    # --- RESTART WARNING NOTIFICATIONS ---
    foreach ($def in $restartWarningDefs) {
        $warnTime = $nextRestartTime.AddMinutes(-$def.minutes)
        # Wider warning window (30 seconds) to ensure warnings are sent
        if (-not $restartWarningSent[$def.key] -and $now -ge $warnTime -and $now -lt $warnTime.AddSeconds(30)) {
            $timeStr = $nextRestartTime.ToString('HH:mm')
            $roleIdArr = $null
            if ($playerNotification -and $playerNotification.roleIds) {
                $roleIdArr = $playerNotification.roleIds | Where-Object { $_ -and $_ -ne '' }
            }
            $roleId = if ($roleIdArr -and $roleIdArr.Count -gt 0) { $roleIdArr[0] } else { '' }
            $vars = @{ time = $timeStr; roleId = $roleId }
            Send-Notification player $def.key $vars
            Write-Log ("[INFO] Sent player notification: {0} at {1} (scheduled for {2})" -f $def.key, $now.ToString('HH:mm:ss'), $warnTime.ToString('HH:mm:ss'))
            $restartWarningSent[$def.key] = $true
        }
    }
    
    # --- SCHEDULED RESTART EXECUTION ---
    # Check if restart should happen (within 60 seconds of scheduled time)
    if (($restartPerformedTime -ne $nextRestartTime) -and $now -ge $nextRestartTime -and $now -lt $nextRestartTime.AddMinutes(1)) {
        Write-Log ("[INFO] Scheduled restart triggered at {0} (scheduled for {1})" -f $now.ToString('HH:mm:ss'), $nextRestartTime.ToString('HH:mm:ss'))
        Send-Notification admin "scheduledRestart" @{}
        
        # Perform restart
        Backup-Saved | Out-Null
        Write-Log "[INFO] Stopping server service for scheduled restart..."
        cmd /c "net stop $serviceName"
        Start-Sleep -Seconds 10
        Write-Log "[INFO] Starting server service after scheduled restart..."
        cmd /c "net start $serviceName"
        Start-Sleep -Seconds 10
        
        # Check result with SCUM log monitoring
        $startupResult = Monitor-SCUMServerStartup "scheduled restart" 8 15
        if ($startupResult.Success) {
            Write-Log "[INFO] SCUM server is online after scheduled restart."
            # Clear intentionally stopped flag after successful restart
            $global:ServerIntentionallyStopped = $false
            
            # Notify that server is back online
            Notify-ServerStatusChange "Online" "Scheduled restart completed" @{ PlayerCount = $startupResult.Status.PlayerCount }
            Notify-AdminActionResult "scheduled restart" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] SCUM server failed to start after scheduled restart: $($startupResult.Reason)"
            Send-Notification admin "restartError" @{ error = "SCUM server failed to start after scheduled restart: $($startupResult.Reason)" }
            Notify-ServerStatusChange "Offline" "Scheduled restart failed"
            Notify-AdminActionResult "scheduled restart" "failed - $($startupResult.Reason)" "OFFLINE"
        }
        
        # Mark restart as performed and calculate next restart
        $restartPerformedTime = $nextRestartTime
        $nextRestartTime = Get-NextScheduledRestart $restartTimes
        foreach ($def in $restartWarningDefs) { $restartWarningSent[$def.key] = $false }
        $global:LastRestartTime = $now
        $updateOrRestart = $true
        
        Write-Log ("[INFO] Next scheduled restart set to: {0}" -f $nextRestartTime.ToString('yyyy-MM-dd HH:mm:ss'))
    }
    
    # --- PERIODIC BACKUP EXECUTION ---
    if ($periodicBackupEnabled -and ($null -ne $global:LastBackupTime) -and ((Get-Date) - $global:LastBackupTime).TotalMinutes -ge $backupIntervalMinutes) {
        if (-not $updateOrRestart) {
            Write-Log "[INFO] Running periodic backup..."
            if (Backup-Saved) {
                $global:LastBackupTime = Get-Date
                Write-Log "[INFO] Periodic backup completed successfully."
            } else {
                Write-Log "[ERROR] Periodic backup failed!"
            }
        }
    }
    
    # --- PERIODIC UPDATE CHECK ---
    if ($null -eq $global:LastUpdateCheck -or ((Get-Date) - $global:LastUpdateCheck).TotalMinutes -ge $updateCheckIntervalMinutes) {
        if (-not $updateOrRestart -and $null -eq $global:UpdateScheduledTime) {
            Write-Log "[INFO] Running periodic update check..."
            $installedBuild = Get-InstalledBuildId
            $latestBuild = Get-LatestBuildId
            if ($null -eq $installedBuild -or $null -eq $latestBuild) {
                Write-Log "[WARNING] Could not determine buildid during periodic check, skipping."
                Send-Notification admin "updateWarning" @{ warning = "Could not determine buildid during periodic update check." }
            } elseif ($installedBuild -ne $latestBuild) {
                Write-Log "[INFO] Update available during periodic check! Installed: $installedBuild, Latest: $latestBuild"
                
                # INTELLIGENT UPDATE SCHEDULING:
                if (-not (Check-ServiceRunning $serviceName)) {
                    Write-Log "[INFO] Server is not running, performing immediate update..."
                    Send-Notification admin "updateAvailable" @{ installed = $installedBuild; latest = $latestBuild }
                    Send-Notification player "updateStarting" @{}
                    
                    if (Execute-ImmediateUpdate) {
                        Write-Log "[INFO] Immediate update completed successfully (server was offline)."
                    } else {
                        Write-Log "[ERROR] Immediate update failed (server was offline)!"
                    }
                } else {
                    # Server is running, schedule delayed update
                    $global:UpdateScheduledTime = (Get-Date).AddMinutes($updateDelayMinutes)
                    $global:UpdateWarning5Sent = $false
                    $global:UpdateAvailableNotificationSent = $false
                    Write-Log ("[INFO] Server is running, update scheduled for: {0}" -f $global:UpdateScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))
                    
                    # Send notifications
                    Send-Notification admin "updateAvailable" @{ installed = $installedBuild; latest = $latestBuild }
                    Send-Notification player "updateAvailable" @{ delayMinutes = $updateDelayMinutes }
                    $global:UpdateAvailableNotificationSent = $true
                }
            } else {
                # Write-Log "[DEBUG] No update available during periodic check."
            }
            $global:LastUpdateCheck = Get-Date
        }
    }
    
    # --- ADMIN COMMAND PROCESSING ---
    # Poll Discord channels for admin commands
    Poll-AdminCommands
    
    # --- SERVICE HEALTH MONITORING ---
    if (-not $updateOrRestart) {
        if (-not (Check-ServiceRunning $serviceName)) {
            # Check if server was intentionally stopped by admin
            if ($global:ServerIntentionallyStopped) {
                # Log only occasionally to avoid spam
                if ($now.Second -eq 0 -and $now.Minute % 10 -eq 0) {
                    Write-Log "[INFO] Server is intentionally stopped by admin command - auto-restart disabled"
                }
            } else {
                # Check auto-restart rate limiting
                $canAttemptRestart = $true
                $timeSinceLastAttempt = if ($global:LastAutoRestartAttempt) { ((Get-Date) - $global:LastAutoRestartAttempt).TotalMinutes } else { 999 }
                
                if ($global:ConsecutiveRestartAttempts -ge $global:MaxConsecutiveRestartAttempts) {
                    # Too many failed attempts - give up until manual intervention
                    if ($now.Second -eq 0 -and $now.Minute % 10 -eq 0) {
                        Write-Log "[WARNING] Auto-restart disabled after $($global:ConsecutiveRestartAttempts) failed attempts. Manual intervention required."
                    }
                    $canAttemptRestart = $false
                } elseif ($timeSinceLastAttempt -lt $global:AutoRestartCooldownMinutes) {
                    # Still in cooldown period
                    if ($now.Second -eq 0 -and $now.Minute -eq 0) {
                        $waitMinutes = [Math]::Ceiling($global:AutoRestartCooldownMinutes - $timeSinceLastAttempt)
                        Write-Log "[INFO] Auto-restart cooldown: waiting $waitMinutes more minutes before next attempt"
                    }
                    $canAttemptRestart = $false
                }
                
                if ($canAttemptRestart) {
                    # Check if this might be an intentional stop
                    $intentionalStop = Test-IntentionalStop $serviceName
                    if ($intentionalStop) {
                        Write-Log "[INFO] Server appears to be intentionally stopped - setting intentional stop flag"
                        $global:ServerIntentionallyStopped = $true
                        # Reset restart attempt counters
                        $global:ConsecutiveRestartAttempts = 0
                        $global:LastAutoRestartAttempt = $null
                    } else {
                        # Server crashed or stopped unexpectedly - attempt auto-restart
                        $global:LastAutoRestartAttempt = Get-Date
                        $global:ConsecutiveRestartAttempts++
                        
                        # Get more detailed service information for debugging
                        try {
                            $serviceInfo = Get-Service -Name $serviceName -ErrorAction Stop
                            $serviceStatus = $serviceInfo.Status
                            Write-Log "[WARNING] Server service is not running! Service status: $serviceStatus, Attempt: $($global:ConsecutiveRestartAttempts)/$($global:MaxConsecutiveRestartAttempts)"
                        } catch {
                            Write-Log "[WARNING] Server service '$serviceName' not found or inaccessible: $_"
                        }
                        
                        Write-Log "[INFO] Attempting to start server service (cooldown period: $($global:AutoRestartCooldownMinutes) minutes)..."
                        Notify-ServerCrashed "Service stopped unexpectedly"
                        
                        # Try to start the service and monitor the result
                        try {
                            $startResult = cmd /c "net start $serviceName" 2>&1
                            Write-Log "[DEBUG] Service start command output: $startResult"
                        } catch {
                            Write-Log "[ERROR] Service start command failed: $_"
                        }
                        
                        # Monitor auto-restart result with SCUM log monitoring  
                        $startupResult = Monitor-SCUMServerStartup "auto-restart after crash" 6 10
                        if ($startupResult.Success) {
                            Write-Log "[INFO] SCUM server auto-restarted successfully after crash."
                            # Reset consecutive failure counter on success
                            $global:ConsecutiveRestartAttempts = 0
                            $global:LastAutoRestartAttempt = $null
                            Notify-ServerStatusChange "Online" "Auto-restart after crash" @{ PlayerCount = $startupResult.Status.PlayerCount }
                            Notify-AdminActionResult "auto-restart" "completed successfully" "ONLINE"
                        } else {
                            Write-Log "[ERROR] SCUM server failed to auto-restart after crash: $($startupResult.Reason)"
                            # Try to get more info about why it failed
                            try {
                                $serviceInfo = Get-Service -Name $serviceName -ErrorAction Stop
                                Write-Log "[ERROR] Service status after failed restart: $($serviceInfo.Status)"
                            } catch {
                                Write-Log "[ERROR] Could not get service status after failed restart: $_"
                            }
                            
                            # Only send admin notification if this is the final attempt
                            if ($global:ConsecutiveRestartAttempts -ge $global:MaxConsecutiveRestartAttempts) {
                                Send-Notification admin "autoRestartError" @{ error = "The SCUM server failed to auto-restart after $($global:ConsecutiveRestartAttempts) attempts: $($startupResult.Reason). Manual intervention required." }
                            }
                            Notify-AdminActionResult "auto-restart" "failed - $($startupResult.Reason)" "OFFLINE"
                        }
                    }
                }
            }
        } else {
            # Service is running - clear flags and reset counters
            if ($global:ServerIntentionallyStopped) {
                $global:ServerIntentionallyStopped = $false
                Write-Log "[INFO] Server is running - auto-restart protection cleared"
            }
            
            # Reset restart attempt counters when service is running normally
            if ($global:ConsecutiveRestartAttempts -gt 0 -or $null -ne $global:LastAutoRestartAttempt) {
                Write-Log "[INFO] Server running normally - resetting auto-restart counters"
                $global:ConsecutiveRestartAttempts = 0
                $global:LastAutoRestartAttempt = $null
            }
            
            # Service healthy - reduce log frequency to avoid spam
            if ($now.Second -eq 0 -and $now.Minute % 30 -eq 0) { # Log every 30 minutes to avoid spam
                # Write-Log "[DEBUG] Server service running normally."
            }
        }
    }
        
        # --- PERFORMANCE MONITORING ---
        # FPS and performance monitoring (if enabled and server is running)
        if ($config.enablePerformanceMonitoring -and $serverRunning) {
            $shouldLogPerformance = $false
            
            # Check if it's time to log performance
            if ($null -eq $global:LastPerformanceLogTime) {
                $shouldLogPerformance = $true
            } else {
                $timeSinceLastLog = ($currentTime - $global:LastPerformanceLogTime).TotalMinutes
                if ($timeSinceLastLog -ge $performanceLogInterval) {
                    $shouldLogPerformance = $true
                }
            }
            
            if ($shouldLogPerformance) {
                $logPath = Join-Path $serverDir "SCUM\Saved\Logs\SCUM.log"
                $perfStats = Get-ServerPerformanceStats -logPath $logPath -maxLines 200
                
                if ($null -ne $perfStats -and $perfStats.AverageFPS -gt 0) {
                    $perfSummary = Get-PerformanceSummary $perfStats
                    Write-Log "[PERFORMANCE] $perfSummary"
                    
                    # Check for performance alerts
                    $currentPerfStatus = $perfStats.PerformanceStatus
                    
                    # Only send notifications for status changes or critical/poor performance
                    if ($currentPerfStatus -ne $global:LastPerformanceStatus) {
                        Write-Log "[INFO] Server performance status changed: $($global:LastPerformanceStatus) -> $currentPerfStatus"
                        
                        # Send notifications based on performance status
                        switch ($currentPerfStatus) {
                            "Critical" {
                                Send-Notification admin "performanceCritical" @{ performanceSummary = $perfSummary }
                                Write-Log "[ALERT] Critical performance detected! $perfSummary"
                            }
                            "Poor" {
                                Send-Notification admin "performancePoor" @{ performanceSummary = $perfSummary }
                                Write-Log "[WARNING] Poor performance detected! $perfSummary"
                            }
                            "Fair" {
                                # Only send if previous status was good/excellent (degradation)
                                if ($global:LastPerformanceStatus -in @("Good", "Excellent")) {
                                    Send-Notification admin "performanceFair" @{ performanceSummary = $perfSummary }
                                    Write-Log "[NOTICE] Performance degraded to fair: $perfSummary"
                                }
                            }
                            "Good" {
                                # Only send if recovering from poor/critical
                                if ($global:LastPerformanceStatus -in @("Poor", "Critical")) {
                                    Send-Notification admin "performanceGood" @{ performanceSummary = $perfSummary }
                                    Write-Log "[INFO] Performance improved to good: $perfSummary"
                                }
                            }
                            "Excellent" {
                                # Only send if recovering from poor/critical/fair
                                if ($global:LastPerformanceStatus -in @("Poor", "Critical", "Fair")) {
                                    Send-Notification admin "performanceExcellent" @{ performanceSummary = $perfSummary }
                                    Write-Log "[INFO] Performance improved to excellent: $perfSummary"
                                }
                            }
                        }
                        
                        $global:LastPerformanceStatus = $currentPerfStatus
                    }
                    
                    # Additional logging for very low FPS (regardless of status change)
                    if ($perfStats.AverageFPS -le $fpsAlertThreshold) {
                        Write-Log "[ALERT] Very low FPS detected: $($perfStats.AverageFPS) avg (threshold: $fpsAlertThreshold)"
                    } elseif ($perfStats.AverageFPS -le $fpsWarningThreshold) {
                        Write-Log "[WARNING] Low FPS detected: $($perfStats.AverageFPS) avg (threshold: $fpsWarningThreshold)"
                    }
                    
                    $global:LastPerformanceLogTime = $currentTime
                } else {
                    # No performance data available
                    if ($null -eq $global:LastPerformanceLogTime) {
                        Write-Log "[DEBUG] No performance data available yet (server may still be starting)"
                        $global:LastPerformanceLogTime = $currentTime
                    }
                }
            }
        }
        
        # Sleep before next iteration
        Start-Sleep -Seconds 1
    }
} catch {
    Write-Log "[ERROR] Critical error in main monitoring loop: $($_.Exception.Message)"
    Write-Log "[ERROR] Stack trace: $($_.ScriptStackTrace)"
    
    # Try to continue after a brief pause
    Start-Sleep -Seconds 30
    
    # Reset some variables to recover
    $global:LastPerformanceLogTime = $null
    $global:LastPerformanceStatus = ""
}

Write-Log "[INFO] Main monitoring loop ended"
