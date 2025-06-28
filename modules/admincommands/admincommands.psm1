# ==========================
# Admin Commands Module
# ==========================

# Import common utilities
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "common\common.psm1") -Force -Global
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "service\service.psm1") -Force -Global
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "backup\backup.psm1") -Force -Global
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "update\update.psm1") -Force -Global
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "monitoring\monitoring.psm1") -Force -Global
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "logreader\logreader.psm1") -Force -Global

# Module variables
$script:ProcessedMessageIds = @{}
$script:BaselineMessageId = $null
$script:LastDiscordAPICall = $null
$script:LastCommandErrorTime = $null
$script:AdminConfig = $null
$script:LogFilePath = $null

function Initialize-AdminCommandModule {
    <#
    .SYNOPSIS
    Initialize admin command module using centralized path management
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:AdminConfig = $Config
    
    # Get log file path for performance monitoring
    $savedDir = Get-ConfigPath -PathKey "savedDir" -ErrorAction SilentlyContinue
    if ($savedDir) {
        $script:LogFilePath = Join-Path $savedDir "Logs\SCUM.log"
    } else {
        $script:LogFilePath = $null
    }
    
    # Use centralized path cache from common module instead of local cache
    Write-Log "[AdminCommands] Module initialized using centralized path management"
    Write-Log "[AdminCommands] Log file path: $($script:LogFilePath)"
}

function Initialize-AdminCommandBaseline {
    <#
    .SYNOPSIS
    Initialize Discord message baseline to process only new messages
    .PARAMETER BotToken
    Discord bot token
    .PARAMETER ChannelIds
    Array of Discord channel IDs to monitor
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotToken,
        
        [Parameter(Mandatory)]
        [string[]]$ChannelIds
    )
    
    if (-not $BotToken -or -not $ChannelIds) {
        Write-Log "[AdminCommands] Cannot initialize baseline - missing bot token or channels" -Level Warning
        return
    }
    
    $headers = @{ 
        Authorization = "Bot $BotToken"
        "User-Agent" = "SCUM-Server-Manager/1.0"
        "Content-Type" = "application/json"
    }
    
    foreach ($channelId in $ChannelIds) {
        if (-not $channelId -or $channelId -eq "") { continue }
        
        try {
            $uri = "https://discord.com/api/v10/channels/$channelId/messages?limit=1"
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            
            if ($response -and $response.Count -gt 0) {
                $script:BaselineMessageId = $response[0].id
                Write-Log "[AdminCommands] Baseline message ID set to: $($script:BaselineMessageId) for channel $channelId"
            }
        } catch {
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "Unknown" }
            Write-Log "[AdminCommands] Could not initialize baseline for channel $channelId (Status: $statusCode)" -Level Warning
        }
    }
}

function Invoke-AdminCommandPolling {
    <#
    .SYNOPSIS
    Poll Discord channels for admin commands with enhanced error handling
    .PARAMETER BotToken
    Discord bot token
    .PARAMETER ChannelIds
    Array of channel IDs to monitor
    .PARAMETER RoleIds
    Array of role IDs allowed to execute commands
    .PARAMETER CommandPrefix
    Command prefix (e.g., "!")
    .PARAMETER ServiceName
    Windows service name
    .PARAMETER GuildId
    Discord guild/server ID (required for fetching member roles)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotToken,
        
        [Parameter(Mandatory)]
        [string[]]$ChannelIds,
        
        [Parameter(Mandatory)]
        [string[]]$RoleIds,
        
        [Parameter(Mandatory)]
        [string]$CommandPrefix,
        
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [string]$GuildId
    )
    
    # Rate limiting - only check Discord API every 30 seconds
    $now = Get-Date
    if ($script:LastDiscordAPICall) {
        $timeSinceLastCall = ($now - $script:LastDiscordAPICall).TotalSeconds
        if ($timeSinceLastCall -lt 30) {
            return # Skip to avoid rate limiting
        }
    }
    
    $script:LastDiscordAPICall = $now
    
    $headers = @{ 
        Authorization = "Bot $BotToken"
        "User-Agent" = "SCUM-Server-Manager/1.0"
        "Content-Type" = "application/json"
    }
    
    foreach ($channelId in $ChannelIds) {
        if (-not $channelId -or $channelId -eq "") { continue }
        
        try {
            $uri = if ($script:BaselineMessageId) {
                "https://discord.com/api/v10/channels/$channelId/messages?after=$($script:BaselineMessageId)&limit=10"
            } else {
                "https://discord.com/api/v10/channels/$channelId/messages?limit=1"
            }
            
            $messages = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
            
            Write-Log "[AdminCommands] Found $($messages.Count) messages in channel $channelId (baseline: $($script:BaselineMessageId))"
            
            # Sort messages chronologically (older first)
            $sortedMessages = $messages | Sort-Object { [uint64]$_.id }
            
            if ($sortedMessages.Count -gt 0) {
                Write-Log "[AdminCommands] Processing $($sortedMessages.Count) sorted messages"
            }
            
            foreach ($msg in $sortedMessages) {
                Process-DiscordMessage -Message $msg -RoleIds $RoleIds -CommandPrefix $CommandPrefix -ServiceName $ServiceName -BotToken $BotToken -GuildId $GuildId
            }
            
        } catch {
            Handle-DiscordAPIError -Exception $_ -ChannelId $channelId
        }
    }
}

function Process-DiscordMessage {
    <#
    .SYNOPSIS
    Process individual Discord message for admin commands
    .PARAMETER Message
    Discord message object
    .PARAMETER RoleIds
    Array of allowed role IDs
    .PARAMETER CommandPrefix
    Command prefix
    .PARAMETER ServiceName
    Service name
    .PARAMETER BotToken
    Discord bot token for fetching member info
    .PARAMETER GuildId
    Discord guild ID for fetching member info
    #>
    param($Message, $RoleIds, $CommandPrefix, $ServiceName, $BotToken, $GuildId)
    
    $content = $Message.content
    $authorId = $Message.author.id
    $messageId = $Message.id
    $member = $Message.member
    $roles = if ($member) { $member.roles } else { $null }
    
    Write-Log "[AdminCommands] Processing message: '$content' from user $authorId (ID: $messageId)"
    
    # If no roles found in message and we have GuildId, try to fetch member info
    if (-not $roles -and $GuildId -and $BotToken) {
        Write-Log "[AdminCommands] No roles in message, fetching member info from Guild API..."
        $roles = Get-DiscordMemberRoles -BotToken $BotToken -GuildId $GuildId -UserId $authorId
    }
    
    Write-Log "[AdminCommands] User roles: $(if ($roles) { $roles -join ', ' } else { 'NONE' })"
    Write-Log "[AdminCommands] Required roles: $($RoleIds -join ', ')"
    
    # Skip if already processed
    if ($script:ProcessedMessageIds.ContainsKey($messageId)) {
        Write-Log "[AdminCommands] Message already processed, skipping"
        return
    }
    
    # Check permissions
    $isAllowed = Test-AdminPermissions -Roles $roles -AllowedRoleIds $RoleIds
    Write-Log "[AdminCommands] Permission check result: $isAllowed"
    
    if ($isAllowed) {
        Write-Log "[AdminCommands] User has permission, processing command"
        # Mark as processed
        $script:ProcessedMessageIds[$messageId] = (Get-Date)
        $script:BaselineMessageId = $messageId
        
        # Clean up old processed messages
        Invoke-ProcessedMessageCleanup
        
        # Process the command
        Invoke-AdminCommand -Content $content -AuthorId $authorId -CommandPrefix $CommandPrefix -ServiceName $ServiceName
    } else {
        Write-Log "[AdminCommands] User lacks required permissions, ignoring command" -Level Warning
    }
}

function Test-AdminPermissions {
    <#
    .SYNOPSIS
    Test if user has admin permissions
    .PARAMETER Roles
    User roles
    .PARAMETER AllowedRoleIds
    Allowed role IDs
    #>
    param($Roles, $AllowedRoleIds)
    
    if ($Roles -and ($Roles | Where-Object { $AllowedRoleIds -contains $_ })) {
        return $true
    } elseif (-not $Roles -and $AllowedRoleIds.Count -eq 0) {
        # Allow for testing if no roles specified
        return $true
    }
    
    return $false
}

function Invoke-ProcessedMessageCleanup {
    <#
    .SYNOPSIS
    Clean up old processed messages to prevent memory leaks
    #>
    if ($script:ProcessedMessageIds.Count -gt 50) {
        $oldestIds = $script:ProcessedMessageIds.GetEnumerator() | 
                    Sort-Object Value | Select-Object -First 25 | 
                    ForEach-Object { $_.Key }
        foreach ($oldId in $oldestIds) {
            $script:ProcessedMessageIds.Remove($oldId)
        }
    }
}

function Handle-DiscordAPIError {
    <#
    .SYNOPSIS
    Handle Discord API errors with proper logging and rate limiting
    .PARAMETER Exception
    Exception object
    .PARAMETER ChannelId
    Channel ID where error occurred
    #>
    param($Exception, $ChannelId)
    
    $statusCode = if ($Exception.Exception.Response) { $Exception.Exception.Response.StatusCode.value__ } else { "Unknown" }
    $errorMessage = if ($Exception.Exception.Message) { $Exception.Exception.Message } else { "Unknown error" }
    
    # Only log once per minute to avoid spam
    if (-not $script:LastCommandErrorTime -or 
        ((Get-Date) - $script:LastCommandErrorTime).TotalSeconds -ge 60) {
        
        $logMessage = switch ($statusCode) {
            429 { "Discord API rate limited for channel $ChannelId - command polling temporarily paused" }
            403 { "Discord API access denied for channel $ChannelId - check bot permissions" }
            404 { "Discord channel $ChannelId not found - check channel ID" }
            default { "Discord API error (status: $statusCode) for channel ${ChannelId}: $errorMessage" }
        }
        
        Write-Log "[AdminCommands] $logMessage" -Level Warning
        $script:LastCommandErrorTime = Get-Date
    }
}

# Helper function for getting next scheduled restart
function Get-NextScheduledRestart {
    <#
    .SYNOPSIS
    Get next scheduled restart time
    .PARAMETER RestartTimes
    Array of restart times in HH:mm format
    #>
    param([string[]]$RestartTimes)
    
    if (-not $RestartTimes -or $RestartTimes.Count -eq 0) {
        return $null
    }
    
    try {
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
    } catch {
        Write-Log "[AdminCommands] Error parsing restart times: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Invoke-AdminCommand {
    <#
    .SYNOPSIS
    Process individual admin command with enhanced validation
    .PARAMETER Content
    Message content
    .PARAMETER AuthorId
    Discord user ID who sent the command
    .PARAMETER CommandPrefix
    Command prefix
    .PARAMETER ServiceName
    Windows service name
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Content,
        
        [Parameter(Mandatory)]
        [string]$AuthorId,
        
        [Parameter(Mandatory)]
        [string]$CommandPrefix,
        
        [Parameter(Mandatory)]
        [string]$ServiceName
    )
    
    if ([string]::IsNullOrWhiteSpace($Content)) {
        Write-Log "[AdminCommands] Empty command received from $AuthorId" -Level Warning
        return
    }
    
    Write-Log "[AdminCommands] Processing command: $Content by $AuthorId"
    
    # Parse command and parameters
    $parts = $Content -split '\s+'
    $command = $parts[0]
    
    try {
        switch -Wildcard ($command) {
            "${CommandPrefix}server_restart*" {
                Invoke-RestartCommand -Parts $parts -AuthorId $AuthorId -ServiceName $ServiceName
            }
            "${CommandPrefix}server_start*" {
                Invoke-StartCommand -Parts $parts -AuthorId $AuthorId -ServiceName $ServiceName
            }
            "${CommandPrefix}server_stop*" {
                Invoke-StopCommand -Parts $parts -AuthorId $AuthorId -ServiceName $ServiceName
            }
            "${CommandPrefix}server_update*" {
                Invoke-UpdateCommand -Parts $parts -AuthorId $AuthorId -ServiceName $ServiceName
            }
            "${CommandPrefix}server_backup*" {
                Invoke-BackupCommand -Parts $parts -AuthorId $AuthorId
            }
            "${CommandPrefix}server_status*" {
                Invoke-StatusCommand -Parts $parts -AuthorId $AuthorId -ServiceName $ServiceName
            }
            "${CommandPrefix}server_restart_skip*" {
                Invoke-RestartSkipCommand -Parts $parts -AuthorId $AuthorId
            }
            default {
                Write-Log "[AdminCommands] Unknown command: $command" -Level Warning
            }
        }
    } catch {
        Write-Log "[AdminCommands] Error executing command '$command': $($_.Exception.Message)" -Level Error
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $parts -join ' '
            executor = "<@$AuthorId>"
            result = ":x: Command failed - check logs" 
        }
    }
}

function Invoke-StartCommand {
    <#
    .SYNOPSIS
    Handle server start command with enhanced validation
    .PARAMETER Parts
    Command parts
    .PARAMETER AuthorId
    Author ID
    .PARAMETER ServiceName
    Service name
    #>
    param($Parts, $AuthorId, $ServiceName)
    
    Write-Log "[AdminCommands] Start command initiated by $AuthorId"
    
    try {
        if (Test-ServiceRunning $ServiceName) {
            # Service is already running
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":white_check_mark: Server is already running" 
            }
        } else {
            # Start the service
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":arrow_forward: Server start initiated" 
            }
            
            # Notify players that server is starting
            Send-Notification player "serverStarting" @{}
            
            $global:ServerIntentionallyStopped = $false
            Start-GameService -ServiceName $ServiceName -Context "admin start"
            
            Write-Log "[AdminCommands] Server start command completed successfully"
        }
    } catch {
        Write-Log "[AdminCommands] Error in start command: $($_.Exception.Message)" -Level Error
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":x: Start command failed - check logs" 
        }
    }
}

function Invoke-RestartCommand {
    <#
    .SYNOPSIS
    Handle server restart command with enhanced validation
    .PARAMETER Parts
    Command parts
    .PARAMETER AuthorId
    Author ID
    .PARAMETER ServiceName
    Service name
    #>
    param($Parts, $AuthorId, $ServiceName)
    
    $delayMinutes = 0
    if ($Parts.Length -gt 1 -and [int]::TryParse($Parts[1], [ref]$delayMinutes) -and 
        $delayMinutes -gt 0 -and $delayMinutes -le 180) {
        # Delayed restart
        Write-Log "[AdminCommands] Restart scheduled for $delayMinutes minutes by $AuthorId"
        $global:AdminRestartScheduledTime = (Get-Date).AddMinutes($delayMinutes)
        $global:AdminRestartWarning10Sent = $false
        $global:AdminRestartWarning5Sent = $false
        $global:AdminRestartWarning1Sent = $false
        
        Send-Notification player "adminRestartScheduled" @{ delayMinutes = $delayMinutes }
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":clock3: Restart scheduled in $delayMinutes minutes" 
        }
    } else {
        # Immediate restart
        Write-Log "[AdminCommands] Immediate restart initiated by $AuthorId"
        
        try {
            Send-Notification player "adminRestartImmediate" @{}
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":arrows_counterclockwise: Immediate restart initiated" 
            }
            
            $global:ServerIntentionallyStopped = $false
            
            # Create backup before restart
            Invoke-PreActionBackup -Context "admin restart"
            
            # Restart service
            Restart-GameService -ServiceName $ServiceName -Reason "admin restart"
            
            Write-Log "[AdminCommands] Immediate restart command completed successfully"
        } catch {
            Write-Log "[AdminCommands] Error in restart command: $($_.Exception.Message)" -Level Error
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":x: Restart command failed - check logs" 
            }
        }
    }
}

function Invoke-StopCommand {
    <#
    .SYNOPSIS
    Handle server stop command with enhanced validation
    .PARAMETER Parts
    Command parts
    .PARAMETER AuthorId
    Author ID
    .PARAMETER ServiceName
    Service name
    #>
    param($Parts, $AuthorId, $ServiceName)
    
    $delayMinutes = 0
    if ($Parts.Length -gt 1 -and [int]::TryParse($Parts[1], [ref]$delayMinutes) -and 
        $delayMinutes -gt 0 -and $delayMinutes -le 180) {
        # Delayed stop
        Write-Log "[AdminCommands] Stop scheduled for $delayMinutes minutes by $AuthorId"
        $global:AdminStopScheduledTime = (Get-Date).AddMinutes($delayMinutes)
        $global:AdminStopWarning10Sent = $false
        $global:AdminStopWarning5Sent = $false
        $global:AdminStopWarning1Sent = $false
        
        Send-Notification player "adminStopScheduled" @{ delayMinutes = $delayMinutes }
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":clock3: Stop scheduled in $delayMinutes minutes" 
        }
    } else {
        # Immediate stop
        Write-Log "[AdminCommands] Immediate stop initiated by $AuthorId"
        
        try {
            Send-Notification player "adminStopImmediate" @{}
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":octagonal_sign: Immediate stop initiated" 
            }
            
            $global:ServerIntentionallyStopped = $true
            Stop-GameService -ServiceName $ServiceName -Reason "admin stop"
            
            Write-Log "[AdminCommands] Immediate stop command completed successfully"
        } catch {
            Write-Log "[AdminCommands] Error in stop command: $($_.Exception.Message)" -Level Error
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":x: Stop command failed - check logs" 
            }
        }
    }
}

function Invoke-UpdateCommand {
    <#
    .SYNOPSIS
    Handle server update command with enhanced validation and path handling
    .PARAMETER Parts
    Command parts
    .PARAMETER AuthorId
    Author ID
    .PARAMETER ServiceName
    Service name
    #>
    param($Parts, $AuthorId, $ServiceName)
    
    $delayMinutes = 0
    if ($Parts.Length -gt 1 -and [int]::TryParse($Parts[1], [ref]$delayMinutes) -and 
        $delayMinutes -gt 0 -and $delayMinutes -le 180) {
        # Delayed update
        Write-Log "[AdminCommands] Update scheduled for $delayMinutes minutes by $AuthorId"
        $global:AdminUpdateScheduledTime = (Get-Date).AddMinutes($delayMinutes)
        $global:AdminUpdateWarning10Sent = $false
        $global:AdminUpdateWarning5Sent = $false
        $global:AdminUpdateWarning1Sent = $false
        
        Send-Notification player "adminUpdateScheduled" @{ delayMinutes = $delayMinutes }
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":clock3: Update scheduled in $delayMinutes minutes" 
        }
    } else {
        # Immediate update
        Write-Log "[AdminCommands] Immediate update initiated by $AuthorId"
        
        try {
            Send-Notification player "adminUpdateImmediate" @{}
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":gear: Immediate update initiated" 
            }
            
            # Validate paths using centralized path management
            $steamCmd = Get-ConfigPath -PathKey "steamCmd"
            $serverDir = Get-ConfigPath -PathKey "serverDir"
            
            if (-not (Test-Path $steamCmd)) {
                throw "SteamCMD not found at: $steamCmd"
            }
            
            # Create backup before update
            Invoke-PreActionBackup -Context "admin update"
            
            # Stop service if running
            if (Test-ServiceRunning $ServiceName) {
                Stop-GameService -ServiceName $ServiceName -Reason "update"
            }
            
            # Perform update
            $updateResult = Update-GameServer -SteamCmdPath $steamCmd -ServerDirectory $serverDir -AppId $script:AdminConfig.appId -ServiceName $ServiceName
            
            if ($updateResult.Success) {
                Write-Log "[AdminCommands] Server updated successfully by $AuthorId"
                Send-Notification admin "updateCompleted" @{}
                
                # Start service after update
                Start-GameService -ServiceName $ServiceName -Context "post-update"
            } else {
                Write-Log "[AdminCommands] Update failed: $($updateResult.Error)" -Level Error
                Send-Notification admin "updateFailed" @{ error = $updateResult.Error }
            }
            
        } catch {
            Write-Log "[AdminCommands] Error in update command: $($_.Exception.Message)" -Level Error
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":x: Update command failed - check logs" 
            }
        }
    }
}

function Invoke-BackupCommand {
    <#
    .SYNOPSIS
    Handle backup command with enhanced validation and path handling
    .PARAMETER Parts
    Command parts
    .PARAMETER AuthorId
    Author ID
    #>
    param($Parts, $AuthorId)
    
    Write-Log "[AdminCommands] Backup initiated by $AuthorId"
    
    try {
        # Validate paths using centralized path management
        $savedDir = Get-ConfigPath -PathKey "savedDir"
        $backupRoot = Get-ConfigPath -PathKey "backupRoot"
        
        if (-not (Test-Path $savedDir)) {
            throw "Saved directory not found at: $savedDir"
        }
        
        $backupResult = Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $script:AdminConfig.maxBackups -CompressBackups $script:AdminConfig.compressBackups
        
        if ($backupResult) {
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":white_check_mark: Backup completed successfully" 
            }
            Write-Log "[AdminCommands] Backup command completed successfully"
        } else {
            Send-Notification admin "adminCommandExecuted" @{ 
                command = $Parts -join ' '
                executor = "<@$AuthorId>"
                result = ":x: Backup failed - check logs" 
            }
            Write-Log "[AdminCommands] Backup command failed" -Level Warning
        }
    } catch {
        Write-Log "[AdminCommands] Error in backup command: $($_.Exception.Message)" -Level Error
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":x: Backup command failed - $($_.Exception.Message)" 
        }
    }
}

function Invoke-StatusCommand {
    <#
    .SYNOPSIS
    Handle status command with enhanced information including monitoring data
    .PARAMETER Parts
    Command parts
    .PARAMETER AuthorId
    Author ID
    .PARAMETER ServiceName
    Service name
    #>
    param($Parts, $AuthorId, $ServiceName)
    
    Write-Log "[AdminCommands] Status requested by $AuthorId"
    
    try {
        $serviceRunning = Test-ServiceRunning $ServiceName
        
        # Get basic server status
        $serverStatus = @{
            Status = if ($serviceRunning) { "Online" } else { "Offline" }
            PlayerCount = "N/A"  # Will be updated from monitoring data
        }
        
        # Get monitoring data including FPS and performance metrics
        $performanceData = $null
        $monitoringText = "Performance: No data available"
        
        try {
            # First try to get performance data from Monitoring module (more reliable)
            $performanceData = Get-PerformanceMetrics -LogPath $script:LogFilePath
            
            if ($performanceData -and $performanceData.FPS.Average -gt 0) {
                # Create custom performance summary without Players (since it's shown separately)
                $monitoringText = Get-StatusPerformanceSummary -Metrics $performanceData
                $serverStatus.PlayerCount = $performanceData.Players
                Write-Log "[AdminCommands] Performance data from Monitoring: FPS=$($performanceData.FPS.Average), Players=$($performanceData.Players)"
            } else {
                # Fallback to LogReader data
                $serverStatusData = Get-ServerStatus -ErrorAction SilentlyContinue
                
                if ($serverStatusData) {
                    # Update player count from LogReader data
                    if ($serverStatusData.PlayerCount -gt 0) {
                        $serverStatus.PlayerCount = $serverStatusData.PlayerCount
                    }
                    
                    # Try to get performance summary from LogReader
                    if ($serverStatusData.PerformanceSummary) {
                        $monitoringText = "Performance: $($serverStatusData.PerformanceSummary)"
                    }
                    
                    # Update main server status from LogReader if available
                    if ($serverStatusData.Status -and $null -ne $serverStatusData.IsOnline) {
                        $serverStatus.Status = $serverStatusData.Status
                    }
                    
                    Write-Log "[AdminCommands] Performance data from LogReader: Status=$($serverStatusData.Status), Players=$($serverStatusData.PlayerCount)"
                } else {
                    Write-Log "[AdminCommands] No performance data available from either Monitoring or LogReader"
                }
            }
        } catch {
            Write-Log "[AdminCommands] Could not get performance data: $($_.Exception.Message)" -Level Warning
            $monitoringText = "Performance: Data unavailable"
        }
        
        # Get service health information
        $healthData = $null
        $healthText = "Health: Unknown"
        
        try {
            $healthData = Test-ServiceHealth -ServiceName $ServiceName
            if ($healthData) {
                $memoryMB = $healthData.ProcessHealth.MemoryMB
                $cpuPercent = $healthData.ProcessHealth.CPUPercent
                $healthText = "Health: $($healthData.OverallHealth)"
                
                if ($memoryMB -gt 0) {
                    $healthText += ", RAM: ${memoryMB}MB"
                }
                if ($cpuPercent -gt 0) {
                    $healthText += ", CPU: ${cpuPercent}%"
                }
            }
        } catch {
            Write-Log "[AdminCommands] Could not get health data: $($_.Exception.Message)" -Level Warning
        }
        
        $restartTimes = Get-SafeConfigValue $script:AdminConfig "restartTimes" @("02:00", "14:00", "20:00")
        $nextRestart = Get-NextScheduledRestart $restartTimes
        
        # Determine status emoji based on server state
        $statusEmoji = switch ($serverStatus.Status) {
            "Online" { ":green_circle:" }
            "Offline" { ":red_circle:" }
            "Starting" { ":hourglass_flowing_sand:" }
            "Loading" { ":gear:" }
            "Restarting" { ":arrows_counterclockwise:" }
            "Crashed" { ":boom:" }
            "Hanging" { ":warning:" }
            default { ":question:" }
        }
        
        # Create comprehensive status report with monitoring data
        $nextRestartText = if ($nextRestart) { $nextRestart.ToString('HH:mm') } else { "N/A" }
        
        $statusLines = @(
            "$statusEmoji **Server Status: $($serverStatus.Status)** | Service: $(if ($serviceRunning) { 'RUNNING' } else { 'STOPPED' })",
            ":busts_in_silhouette: Players: $($serverStatus.PlayerCount)",
            ":chart_with_upwards_trend: $monitoringText",
            ":heart: $healthText",
            ":clock3: Next restart: $nextRestartText",
            ":arrows_counterclockwise: Auto-restart: $($global:ConsecutiveRestartAttempts)/$($global:MaxConsecutiveRestartAttempts)",
            "",
            ":gear: **Available Commands:**",
            "``!server_start`` ``!server_restart [minutes]`` ``!server_stop [minutes]``",
            "``!server_update [minutes]`` ``!server_backup`` ``!server_restart_skip``"
        )
        
        $statusReport = $statusLines -join "`n"
        
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = $statusReport 
        }
        
        Write-Log "[AdminCommands] Status command completed successfully"
    } catch {
        Write-Log "[AdminCommands] Error in status command: $($_.Exception.Message)" -Level Error
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":x: Status command failed - check logs" 
        }
    }
}

function Invoke-RestartSkipCommand {
    <#
    .SYNOPSIS
    Handle restart skip command
    .PARAMETER Parts
    Command parts
    .PARAMETER AuthorId
    Author ID
    #>
    param($Parts, $AuthorId)
    
    try {
        # Set global flag to skip next restart
        $global:SkipNextScheduledRestart = $true
        
        Write-Log "[AdminCommands] Next scheduled restart will be skipped by $AuthorId"
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":fast_forward: Next scheduled restart will be skipped" 
        }
        
        Write-Log "[AdminCommands] Restart skip command completed successfully"
    } catch {
        Write-Log "[AdminCommands] Error in restart skip command: $($_.Exception.Message)" -Level Error
        Send-Notification admin "adminCommandExecuted" @{ 
            command = $Parts -join ' '
            executor = "<@$AuthorId>"
            result = ":x: Restart skip command failed - check logs" 
        }
    }
}

function Invoke-PreActionBackup {
    <#
    .SYNOPSIS
    Create backup before critical operations
    .PARAMETER Context
    Context for the backup
    #>
    param([string]$Context = "admin action")
    
    try {
        $savedDir = Get-ConfigPath -PathKey "savedDir"
        $backupRoot = Get-ConfigPath -PathKey "backupRoot"
        
        if ((Test-Path $savedDir) -and $script:AdminConfig.compressBackups) {
            Write-Log "[AdminCommands] Creating backup before $Context"
            Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $script:AdminConfig.maxBackups -CompressBackups $script:AdminConfig.compressBackups
        }
    } catch {
        Write-Log "[AdminCommands] Warning: Could not create backup before $Context - $($_.Exception.Message)" -Level Warning
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-AdminCommandModule',
    'Initialize-AdminCommandBaseline',
    'Invoke-AdminCommandPolling',
    'Invoke-AdminCommand',
    'Invoke-StartCommand',
    'Invoke-RestartCommand',
    'Invoke-StopCommand',
    'Invoke-UpdateCommand',
    'Invoke-BackupCommand',
    'Invoke-StatusCommand',
    'Invoke-RestartSkipCommand'
)

function Get-DiscordMemberRoles {
    <#
    .SYNOPSIS
    Fetch Discord member roles from Guild API
    .PARAMETER BotToken
    Discord bot token
    .PARAMETER GuildId
    Discord guild/server ID
    .PARAMETER UserId
    Discord user ID
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotToken,
        
        [Parameter(Mandatory)]
        [string]$GuildId,
        
        [Parameter(Mandatory)]
        [string]$UserId
    )
    
    try {
        $headers = @{ 
            Authorization = "Bot $BotToken"
            "User-Agent" = "SCUM-Server-Manager/1.0"
            "Content-Type" = "application/json"
        }
        
        $memberUri = "https://discord.com/api/v10/guilds/$GuildId/members/$UserId"
        $memberInfo = Invoke-RestMethod -Uri $memberUri -Headers $headers -Method GET -TimeoutSec 10 -ErrorAction Stop
        
        if ($memberInfo -and $memberInfo.roles) {
            Write-Log "[AdminCommands] Successfully fetched member roles: $($memberInfo.roles -join ', ')"
            return $memberInfo.roles
        } else {
            Write-Log "[AdminCommands] Member info fetched but no roles found"
            return @()
        }
    } catch {
        $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "Unknown" }
        Write-Log "[AdminCommands] Failed to fetch member roles for user $UserId (Status: $statusCode): $($_.Exception.Message)" -Level Warning
        
        if ($statusCode -eq 403) {
            Write-Log "[AdminCommands] Bot lacks permission to read member information. Ensure 'Server Members Intent' is enabled and bot has 'Read Member List' permission." -Level Warning
        }
        
        return @()
    }
}

function Get-StatusPerformanceSummary {
    <#
    .SYNOPSIS
    Get formatted performance summary for status display (without player count)
    .PARAMETER Metrics
    Performance metrics hashtable
    .RETURNS
    Formatted summary string without player count
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Metrics
    )
    
    if (-not $Metrics -or $Metrics.FPS.Average -eq 0) {
        return "No performance data available"
    }
    
    $summary = "FPS: $($Metrics.FPS.Average) avg"
    if ($Metrics.FPS.Min -ne $Metrics.FPS.Max -and $Metrics.FPS.Min -gt 0) {
        $summary += " ($($Metrics.FPS.Min)-$($Metrics.FPS.Max))"
    }
    $summary += ", Frame: $($Metrics.FrameTime)ms"
    $summary += ", Status: $($Metrics.Status)"
    
    # Include entity information if available
    if ($Metrics.Entities.Characters -gt 0 -or $Metrics.Entities.Zombies -gt 0) {
        $summary += ", Entities: C:$($Metrics.Entities.Characters) Z:$($Metrics.Entities.Zombies)"
        if ($Metrics.Entities.Vehicles -gt 0) {
            $summary += " V:$($Metrics.Entities.Vehicles)"
        }
    }
    
    return $summary
}
