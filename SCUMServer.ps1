# ==========================
# SCUM SERVER MANAGER - Automated server management
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

# Send Discord notifications with role mentions and template variables
function Send-Notification {
    param(
        [Parameter(Mandatory)] [string]$type, # 'admin' or 'player'
        [Parameter(Mandatory)] [string]$messageKey, # Message template key
        [Parameter()] [hashtable]$vars = @{} # Template variables
    )
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
                        
                        # Pošli nejdříve jednoduchý fallback, pak embed
                        $simpleBody = @{ content = "[BOT] **$title** - $msg" }
                        if ($content -ne "") { $simpleBody.content = "$content`n$($simpleBody.content)" }
                        
                        # Pokus o embed, při chybě použij jednoduchou zprávu
                        try {
                            $body = @{ embeds = @($embed) }
                            if ($content -ne "") { $body.content = $content }
                            $bodyJson = $body | ConvertTo-Json -Depth 4
                            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -ContentType 'application/json' -Body $bodyJson -ErrorAction Stop
                            Write-Log ("[INFO] Bot embed notification sent to channel {0}: {1}" -f $channelId, $msg)
                        } catch {
                            # Fallback na jednoduchou zprávu
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
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp $msg"
    $line | Out-File -FilePath "SCUMServer.log" -Append -Encoding utf8
    Write-Host $line
}

# --- UNIVERSAL NOTIFICATION SYSTEM ---
# Konzistentní notifikace pro všechny stavy serveru - hráči dostanou VŽDY zprávu
function Notify-ServerOnline {
    param([string]$reason = "Unknown")
    Send-Notification admin "serverStarted" @{ reason = $reason }
    Send-Notification player "serverStarted" @{ reason = $reason }
    Write-Log "[NOTIFY] Server ONLINE - Reason: $reason"
}

function Notify-ServerOffline {
    param([string]$reason = "Unknown")
    Send-Notification admin "serverStopped" @{ reason = $reason }
    Send-Notification player "serverStopped" @{ reason = $reason }
    Write-Log "[NOTIFY] Server OFFLINE - Reason: $reason"
}

function Notify-ServerRestarting {
    param([string]$reason = "Unknown")
    Send-Notification admin "serverRestarted" @{ reason = $reason }
    Send-Notification player "serverRestarted" @{ reason = $reason }
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
    Send-Notification admin "serverCrashed" @{ reason = $reason }
    Send-Notification player "serverCrashed" @{ reason = $reason }
    Write-Log "[NOTIFY] Server CRASHED - Reason: $reason"
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

# --- SERVICE MANAGEMENT ---
# Check if the Windows service is running
function Check-ServiceRunning {
    param([string]$name)
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $false }
    return $svc.Status -eq 'Running'
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
            Start-Sleep -Seconds 10
            if (Check-ServiceRunning $serviceName) {
                Write-Log "[INFO] Server service is running after first install."
                Notify-ServerOnline "First install completed"
                Notify-AdminActionResult "first install" "completed successfully" "ONLINE"
            } else {
                Write-Log "[ERROR] Server service failed to start after first install!"
                Send-Notification admin "installError" @{ error = "The server service failed to start after first install!" }
                Notify-AdminActionResult "first install" "failed - service not running" "OFFLINE"
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
            if ($global:UpdateScheduledTime -eq $null) {
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
        Start-Sleep -Seconds 10
        if (Check-ServiceRunning $serviceName) {
            Write-Log "[INFO] Server service is running after update."
            Notify-ServerOnline "Update completed"
            Notify-AdminActionResult "update" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] Server service failed to start after update!"
            Send-Notification admin "updateError" @{ error = "The server service failed to start after update!" }
            Notify-AdminActionResult "update" "failed - service not running" "OFFLINE"
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
        Start-Sleep -Seconds 10
        if (Check-ServiceRunning $serviceName) {
            Write-Log "[INFO] Server service is running after update."
            Send-Notification player "updateCompleted" @{}
            # Clear intentionally stopped flag after successful update
            $global:ServerIntentionallyStopped = $false
            Notify-AdminActionResult "update" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] Server service failed to start after update!"
            Send-Notification admin "updateError" @{ error = "The server service failed to start after update!" }
            Notify-AdminActionResult "update" "failed - service not running" "OFFLINE"
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
                
                # Write-Log ("[DEBUG] Discord NEW msg: id={0}, content='{1}', authorId={2}, member={3}, roles={4}" -f $messageId, $content, $authorId, ($member | ConvertTo-Json -Compress), ($roles -join ', '))
                
                $isAllowed = $false
                if ($roles -and ($roles | Where-Object { $roleIds -contains $_ })) {
                    $isAllowed = $true
                } elseif (-not $roles) {
                    # Pokud nejsou role, povolíme pro test všem (nebo zadejte svůj userId pro omezení)
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
                    # Process individual admin commands using configurable prefix
                    if ($content -like "${commandPrefix}server_restart*") {
                        # Parse delay parameter
                        $parts = $content -split '\s+'
                        $delayMinutes = 0
                        if ($parts.Length -gt 1 -and [int]::TryParse($parts[1], [ref]$delayMinutes) -and $delayMinutes -gt 0) {
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
                            Backup-Saved | Out-Null
                            cmd /c "net stop $serviceName"
                            Start-Sleep -Seconds 10
                            cmd /c "net start $serviceName"
                            Start-Sleep -Seconds 10
                            
                            # Check result and notify accordingly
                            if (Check-ServiceRunning $serviceName) {
                                Notify-ServerOnline "Admin restart command"
                                Notify-AdminActionResult "restart" "completed successfully" "ONLINE"
                            } else {
                                Notify-ServerOffline "Admin restart failed"
                                Notify-AdminActionResult "restart" "failed - service not running" "OFFLINE"
                            }
                        }
                    } elseif ($content -like "${commandPrefix}server_stop*") {
                        # Parse delay parameter
                        $parts = $content -split '\s+'
                        $delayMinutes = 0
                        if ($parts.Length -gt 1 -and [int]::TryParse($parts[1], [ref]$delayMinutes) -and $delayMinutes -gt 0) {
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
                            cmd /c "net stop $serviceName"
                            Start-Sleep -Seconds 5
                            
                            # Always notify about server being stopped
                            Notify-ServerOffline "Admin stop command"
                            Notify-AdminActionResult "stop" "completed successfully" "OFFLINE"
                        }
                    } elseif ($content -like "${commandPrefix}server_start*") {
                        Write-Log "[ADMIN CMD] ${commandPrefix}server_start by $authorId"
                        Send-Notification admin "adminStart" @{ admin = $authorId }
                        Send-Notification player "adminStartNow" @{}
                        
                        # Clear the intentionally stopped flag
                        $global:ServerIntentionallyStopped = $false
                        Write-Log "[INFO] Auto-restart re-enabled after admin start command"
                        cmd /c "net start $serviceName"
                        Start-Sleep -Seconds 10
                        
                        # Check result and notify
                        if (Check-ServiceRunning $serviceName) {
                            Notify-ServerOnline "Admin start command"
                            Notify-AdminActionResult "start" "completed successfully" "ONLINE"
                        } else {
                            Notify-ServerOffline "Admin start failed"
                            Notify-AdminActionResult "start" "failed - service not running" "OFFLINE"
                        }
                    } elseif ($content -like "${commandPrefix}server_update*") {
                        # Parse delay parameter for update command
                        $parts = $content -split '\s+'
                        $delayMinutes = 0
                        $isDelayed = $false
                        
                        if ($parts.Length -gt 1 -and [int]::TryParse($parts[1], [ref]$delayMinutes) -and $delayMinutes -gt 0) {
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
                        if ($global:UpdateScheduledTime -ne $null) {
                            Write-Log "[INFO] Cancelling automatic scheduled update planned for $($global:UpdateScheduledTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                            $global:UpdateScheduledTime = $null
                            $global:UpdateWarning5Sent = $false
                            $global:UpdateAvailableNotificationSent = $false
                            $anyCancelled = $true
                        }
                        if ($global:AdminUpdateScheduledTime -ne $null) {
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
        Write-Log "[INFO] No new update available. Skipping update."        if (-not (Check-ServiceRunning $serviceName)) {
            Write-Log "[INFO] Starting server service after backup and update check."
            cmd /c "net start $serviceName"
            Start-Sleep -Seconds 10
            if (Check-ServiceRunning $serviceName) {
                Write-Log "[INFO] Server service started successfully after backup and update check."
                Notify-ServerOnline "Startup after update check"
                Notify-AdminActionResult "startup after update check" "completed successfully" "ONLINE"
            } else {
                Write-Log "[ERROR] Server service failed to start after backup and update check!"
                Send-Notification admin "startError" @{
                    error = "The SCUM server service failed to start after backup and update check!"
                }
                Notify-AdminActionResult "startup after update check" "failed - service not running" "OFFLINE"
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
        Start-Sleep -Seconds 10
        if (Check-ServiceRunning $serviceName) {
            Write-Log "[INFO] Server service started successfully after backup."
            Notify-ServerOnline "Startup after backup"
            Notify-AdminActionResult "startup after backup" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] Server service failed to start after backup!"
            Send-Notification admin "startError" @{
                error = "The SCUM server service failed to start after backup!"
            }
            Notify-AdminActionResult "startup after backup" "failed - service not running" "OFFLINE"
        }
    } else {
        Write-Log "[INFO] Server service is already running, no action needed."
    }
}

# --- CONTINUOUS MONITORING LOOP ---
while ($true) {
    $now = Get-Date
    $updateOrRestart = $false
    
    # Reduce log spam - debug info only every 10 minutes
    if ($now.Second -eq 0 -and $now.Minute % 10 -eq 0) {
        Write-Log ("[DEBUG] Next restart: {0}" -f $nextRestartTime.ToString('yyyy-MM-dd HH:mm'))
    }
    
    # --- DELAYED UPDATE PROCESSING ---
    if ($global:UpdateScheduledTime -ne $null) {
        # Send 5-minute warning if not sent yet and delay is >= 5 minutes
        $warningMinutes = [Math]::Min(5, [Math]::Floor($updateDelayMinutes / 2))
        if ($updateDelayMinutes -gt 5 -and -not $global:UpdateWarning5Sent -and $now -ge $global:UpdateScheduledTime.AddMinutes(-$warningMinutes) -and $now -lt $global:UpdateScheduledTime.AddMinutes(-$warningMinutes).AddSeconds(30)) {
            Send-Notification player "updateWarning5" @{ warningMinutes = $warningMinutes }
            Write-Log ("[INFO] Sent update {0}-minute warning at {1}" -f $warningMinutes, $now.ToString('HH:mm:ss'))
            $global:UpdateWarning5Sent = $true
        }
        
        # Execute update if time has come
        if ($now -ge $global:UpdateScheduledTime) {
            Write-Log ("[INFO] Delayed update time reached, executing update...")
            if (Execute-ImmediateUpdate) {
                $updateOrRestart = $true
                Write-Log "[INFO] Delayed update completed successfully."
            } else {
                Write-Log "[ERROR] Delayed update failed!"
            }
        }
    }
    
    # --- ADMIN ACTION PROCESSING ---
    # Admin Restart
    if ($global:AdminRestartScheduledTime -ne $null) {
        $restartDelay = ($global:AdminRestartScheduledTime - $now).TotalMinutes
        $warningMinutes = [Math]::Min(5, [Math]::Floor($restartDelay / 2))
        
        if ($restartDelay -gt 5 -and -not $global:AdminRestartWarning5Sent -and $now -ge $global:AdminRestartScheduledTime.AddMinutes(-$warningMinutes) -and $now -lt $global:AdminRestartScheduledTime.AddMinutes(-$warningMinutes).AddSeconds(30)) {
            Send-Notification player "adminRestartWarning5" @{ warningMinutes = $warningMinutes }
            Write-Log ("[INFO] Sent admin restart {0}-minute warning at {1}" -f $warningMinutes, $now.ToString('HH:mm:ss'))
            $global:AdminRestartWarning5Sent = $true
        }
        
        if ($now -ge $global:AdminRestartScheduledTime) {
            Write-Log "[INFO] Admin restart time reached, executing restart..."
            Send-Notification player "adminRestartNow" @{}
            
            # Clear the intentionally stopped flag
            $global:ServerIntentionallyStopped = $false
            # Backup and restart server
            Backup-Saved | Out-Null
            cmd /c "net stop $serviceName"
            Start-Sleep -Seconds 10
            cmd /c "net start $serviceName"
            Start-Sleep -Seconds 10
            
            # Check result and notify
            if (Check-ServiceRunning $serviceName) {
                Notify-ServerOnline "Admin scheduled restart"
                Notify-AdminActionResult "scheduled restart" "completed successfully" "ONLINE"
            } else {
                Notify-ServerOffline "Admin scheduled restart failed"
                Notify-AdminActionResult "scheduled restart" "failed - service not running" "OFFLINE"
            }
            
            # Clear scheduling
            $global:AdminRestartScheduledTime = $null
            $global:AdminRestartWarning5Sent = $false
            $updateOrRestart = $true
        }
    }
    
    # Admin Stop
    if ($global:AdminStopScheduledTime -ne $null) {
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
            cmd /c "net stop $serviceName"
            Start-Sleep -Seconds 5
            
            # Always notify about server being stopped
            Notify-ServerOffline "Admin scheduled stop"
            Notify-AdminActionResult "scheduled stop" "completed successfully" "OFFLINE"
            
            # Clear scheduling
            $global:AdminStopScheduledTime = $null
            $global:AdminStopWarning5Sent = $false
        }
    }
    
    # Admin Update
    if ($global:AdminUpdateScheduledTime -ne $null) {
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
        
        if (Check-ServiceRunning $serviceName) {
            Write-Log "[INFO] Server service is running after scheduled restart."
            # Clear intentionally stopped flag after successful restart
            $global:ServerIntentionallyStopped = $false
            
            # Notify that server is back online
            Notify-ServerOnline "Scheduled restart completed"
            Notify-AdminActionResult "scheduled restart" "completed successfully" "ONLINE"
        } else {
            Write-Log "[ERROR] Server service failed to start after scheduled restart!"
            Send-Notification admin "restartError" @{ error = "Server service failed to start after scheduled restart!" }
            Notify-ServerOffline "Scheduled restart failed"
            Notify-AdminActionResult "scheduled restart" "failed - service not running" "OFFLINE"
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
    if ($global:LastBackupTime -eq $null -or ((Get-Date) - $global:LastBackupTime).TotalMinutes -ge $backupIntervalMinutes) {
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
    if ($global:LastUpdateCheck -eq $null -or ((Get-Date) - $global:LastUpdateCheck).TotalMinutes -ge $updateCheckIntervalMinutes) {
        if (-not $updateOrRestart -and $global:UpdateScheduledTime -eq $null) {
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
                # Server crashed or stopped unexpectedly - attempt auto-restart
                Write-Log "[WARNING] Server service is not running! Attempting to start..."
                Notify-ServerCrashed "Service stopped unexpectedly"
                cmd /c "net start $serviceName"
                Start-Sleep -Seconds 10
                if (Check-ServiceRunning $serviceName) {
                    Write-Log "[INFO] Server service auto-restarted after crash."
                    Notify-ServerOnline "Auto-restart after crash"
                    Notify-AdminActionResult "auto-restart" "completed successfully" "ONLINE"
                } else {
                    Write-Log "[ERROR] Server service failed to auto-restart!"
                    Send-Notification admin "autoRestartError" @{ error = "The SCUM server service failed to auto-restart after a crash!" }
                    Notify-AdminActionResult "auto-restart" "failed - service not running" "OFFLINE"
                }
            }
        } else {
            # Service is running - clear the intentionally stopped flag if it was set
            if ($global:ServerIntentionallyStopped) {
                $global:ServerIntentionallyStopped = $false
                Write-Log "[INFO] Server is running - auto-restart protection cleared"
            }
            
            # Service healthy - reduce log frequency to avoid spam
            if ($now.Second -eq 0 -and $now.Minute % 10 -eq 0) { # Log every 10 minutes to avoid spam
                # Write-Log "[DEBUG] Server service running normally."
            }
        }
    }
    Start-Sleep -Seconds 1
}