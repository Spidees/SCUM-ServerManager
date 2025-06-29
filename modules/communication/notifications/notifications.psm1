# ==========================
# Notifications Module
# ==========================

#Requires -Version 5.1

# Set UTF-8 encoding for proper emoji support
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Import common module with new structure
$ModulesRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$CommonModulePath = Join-Path $ModulesRoot "core\common\common.psm1"
if (Test-Path $CommonModulePath) {
    Import-Module $CommonModulePath -Force -Global
}

# Module variables
$script:moduleConfig = $null
$script:lastNotifications = @{}

# Note: All notifications now use rich embeds from config
# Legacy templates removed - using config-driven embeds only

function Initialize-NotificationModule {
    <#
    .SYNOPSIS
    Initialize the notification module
    .PARAMETER Config
    Configuration object with Discord settings
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:moduleConfig = $Config
    
    # Initialize tracking if it doesn't exist
    if (-not $global:LastNotifications) {
        $global:LastNotifications = @{}
    }
    
    Write-Log "[Notifications] Module initialized"
}

function Send-Notification {
    <#
    .SYNOPSIS
    Send Discord notification with template support
    .PARAMETER Type
    Notification type: 'admin' or 'player'
    .PARAMETER MessageKey
    Template message key
    .PARAMETER Vars
    Template variables
    .PARAMETER SkipRateLimit
    Skip rate limiting for critical messages
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('admin', 'player')]
        [string]$Type,
        
        [Parameter(Mandatory)]
        [string]$MessageKey,
        
        [Parameter()]
        [hashtable]$Vars = @{},
        
        [Parameter()]
        [switch]$SkipRateLimit
    )
    
    if (-not $script:moduleConfig) {
        Write-Log "[Notifications] Module not initialized" -Level Warning
        return
    }
    
    # Get notification configuration
    $notificationConfig = if ($Type -eq 'admin') {
        $script:moduleConfig.admin_notification
    } else {
        $script:moduleConfig.player_notification
    }
    
    if (-not $notificationConfig -or -not $notificationConfig.enabled) {
        Write-Log "[Notifications] $Type notifications disabled"
        return
    }
    
    # Check if specific notification type is enabled
    $messageConfig = $notificationConfig.messages.$MessageKey
    if ($messageConfig -and $messageConfig.PSObject.Properties['enabled'] -and -not $messageConfig.enabled) {
        Write-Log "[Notifications] $Type.$MessageKey notification disabled by user"
        return
    }
    
    # Rate limiting - skip for admin commands
    $rateLimitMinutes = Get-SafeConfigValue $script:moduleConfig "notificationRateLimitMinutes" 1
    $notificationKey = "$Type-$MessageKey"
    $now = Get-Date
    
    # Admin commands should never be rate limited
    $isAdminCommand = ($Type -eq "admin" -and ($MessageKey -eq "adminCommandExecuted" -or $MessageKey -eq "otherEvent"))
    
    if (-not $SkipRateLimit -and -not $isAdminCommand -and $global:LastNotifications[$notificationKey]) {
        $timeSince = ($now - $global:LastNotifications[$notificationKey]).TotalMinutes
        if ($timeSince -lt $rateLimitMinutes) {
            Write-Log "[Notifications] Rate limited: $MessageKey ($([Math]::Round($timeSince, 1))min ago)"
            return
        }
    }
    
    # Update tracking (admin commands update tracking only if not duplicate within 10 seconds)
    if ($isAdminCommand) {
        # For admin commands, only update tracking if it's not a very recent duplicate
        if (-not $global:LastNotifications[$notificationKey] -or 
            ($now - $global:LastNotifications[$notificationKey]).TotalSeconds -gt 10) {
            $global:LastNotifications[$notificationKey] = $now
            Write-Log "[Notifications] Admin command ${MessageKey}: executor='$($Vars.executor)', command='$($Vars.command)', result='$($Vars.result)'"
        } else {
            Write-Log "[Notifications] Admin command duplicate detected within 10s, skipping: ${notificationKey} (executor: $($Vars.executor))"
            return
        }
    } else {
        # For non-admin commands, always update tracking
        $global:LastNotifications[$notificationKey] = $now
    }
    
    # Check if we have rich configuration in config (required)
    if (-not $messageConfig -or -not $messageConfig.title) {
        Write-Log "[Notifications] No config found for $Type.$MessageKey - notification skipped" -Level Warning
        return
    }
    
    # Use rich embed from config
    $title = $messageConfig.title
    $text = if ($messageConfig.text) { $messageConfig.text } else { "Notification: $MessageKey" }
    $color = if ($messageConfig.color) { $messageConfig.color } else { 3447003 }
    
    # Replace template variables in title and text
    foreach ($key in $Vars.Keys) {
        $value = $Vars[$key]
        $title = $title -replace "\{$key\}", $value
        $text = $text -replace "\{$key\}", $value
    }
    
    # Add timestamp if not provided
    if ($title -like "*{timestamp}*") {
        $title = $title -replace "\{timestamp\}", (Get-TimeStamp)
    }
    if ($text -like "*{timestamp}*") {
        $text = $text -replace "\{timestamp\}", (Get-TimeStamp)
    }
    
    # Create embed object
    $embed = @{
        title = $title
        description = $text
        color = $color
        timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        footer = @{
            text = "SCUM Server Automation"
            icon_url = "https://playhub.cz/scum/manager/server_automation_discord.png"
        }
    }
    
    # Send to Discord as rich embed
    Send-DiscordEmbed -ChannelIds $notificationConfig.channelIds -Embed $embed -RoleMentions $notificationConfig.roleIds
}

function Send-DiscordMessage {
    <#
    .SYNOPSIS
    Send message to Discord channels
    .PARAMETER ChannelIds
    Array of Discord channel IDs
    .PARAMETER Message
    Message content
    #>
    param(
        [Parameter()]
        [string[]]$ChannelIds = @(),
        
        [Parameter(Mandatory)]
        [string]$Message
    )
    
    # Check if any channels are configured
    if (-not $ChannelIds -or $ChannelIds.Count -eq 0 -or ($ChannelIds.Count -eq 1 -and [string]::IsNullOrWhiteSpace($ChannelIds[0]))) {
        Write-Log "[Notifications] No Discord channels configured - skipping message" -Level Warning
        return
    }
    
    if (-not $script:moduleConfig.botToken) {
        Write-Log "[Notifications] No bot token configured" -Level Warning
        return
    }
    
    $headers = @{
        Authorization = "Bot $($script:moduleConfig.botToken)"
        "User-Agent" = "SCUM-Server-Manager/2.0"
        "Content-Type" = "application/json"
    }
    
    foreach ($channelId in $ChannelIds) {
        if (-not $channelId -or $channelId -eq "") { continue }
        
        $body = @{
            content = $Message
        } | ConvertTo-Json -Depth 2
        
        try {
            $uri = "https://discord.com/api/v10/channels/$channelId/messages"
            Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $body | Out-Null
            Write-Log "[Notifications] Message sent to channel $channelId"
        }
        catch {
            $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode } else { "Unknown" }
            if ($statusCode -eq 429) {
                Write-Log "[Notifications] Discord API rate limited for channel $channelId" -Level Warning
            } elseif ($statusCode -eq 403) {
                Write-Log "[Notifications] Discord API access denied for channel $channelId" -Level Warning  
            } else {
                Write-Log "[Notifications] Discord API temporarily unavailable for channel $channelId" -Level Warning
            }
        }
    }
}

function Send-DiscordEmbed {
    <#
    .SYNOPSIS
    Send rich embed message to Discord channels
    .PARAMETER ChannelIds
    Array of Discord channel IDs
    .PARAMETER Embed
    Embed object with title, description, color
    .PARAMETER RoleMentions
    Array of role IDs to mention
    #>
    param(
        [Parameter()]
        [string[]]$ChannelIds = @(),
        
        [Parameter(Mandatory)]
        [hashtable]$Embed,
        
        [Parameter()]
        [string[]]$RoleMentions = @()
    )
    
    # Check if any channels are configured
    if (-not $ChannelIds -or $ChannelIds.Count -eq 0 -or ($ChannelIds.Count -eq 1 -and [string]::IsNullOrWhiteSpace($ChannelIds[0]))) {
        Write-Log "[Notifications] No Discord channels configured - skipping embed" -Level Warning
        return
    }
    
    if (-not $script:moduleConfig.botToken) {
        Write-Log "[Notifications] No bot token configured" -Level Warning
        return
    }
    
    # Rate limiting - wait between Discord API calls
    if ($script:lastDiscordCall) {
        $timeSince = (Get-Date) - $script:lastDiscordCall
        if ($timeSince.TotalMilliseconds -lt 1000) {
            $waitTime = 1000 - $timeSince.TotalMilliseconds
            Start-Sleep -Milliseconds $waitTime
        }
    }
    $script:lastDiscordCall = Get-Date
    
    $headers = @{
        Authorization = "Bot $($script:moduleConfig.botToken)"
        "User-Agent" = "SCUM-Server-Manager/2.0"
        "Content-Type" = "application/json"
    }
    
    # Prepare content with role mentions
    $content = ""
    if ($RoleMentions -and $RoleMentions.Count -gt 0) {
        $content = ($RoleMentions | ForEach-Object { "<@&$_>" }) -join " "
    }
    
    foreach ($channelId in $ChannelIds) {
        if (-not $channelId -or $channelId -eq "") { continue }
        
        $body = @{
            content = $content
            embeds = @($Embed)
        } | ConvertTo-Json -Depth 4
        
        $maxRetries = 5
        $retryCount = 0
        $success = $false
        
        while (-not $success -and $retryCount -lt $maxRetries) {
            try {
                $uri = "https://discord.com/api/v10/channels/$channelId/messages"
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $body -TimeoutSec 30
                Write-Log "[Notifications] Embed sent to channel $channelId"
                $success = $true
            }
            catch {
                $retryCount++
                $statusCode = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { "Unknown" }
                $errorMessage = if ($_.Exception.Message) { $_.Exception.Message } else { "Unknown error" }
                
                if ($statusCode -eq 429) {
                    # Parse rate limit headers if available
                    $retryAfter = 1
                    try {
                        $responseHeaders = $_.Exception.Response.Headers
                        if ($responseHeaders -and $responseHeaders['Retry-After']) {
                            $retryAfter = [int]$responseHeaders['Retry-After'][0]
                        }
                    } catch { 
                        # Fallback to exponential backoff
                        $retryAfter = [Math]::Min([Math]::Pow(2, $retryCount), 30)
                    }
                    
                    $waitTime = ($retryAfter + 1) * 1000 # Add 1 second buffer
                    Write-Log "[Notifications] Discord API rate limited for channel $channelId, waiting $($waitTime/1000)s (attempt $retryCount/$maxRetries)" -Level Warning
                    Start-Sleep -Milliseconds $waitTime
                    
                } elseif ($statusCode -eq 403) {
                    Write-Log "[Notifications] Discord API access denied for channel $channelId (status: $statusCode)" -Level Warning
                    break # Don't retry on permission errors
                    
                } elseif ($statusCode -eq 404) {
                    Write-Log "[Notifications] Discord channel $channelId not found (status: $statusCode)" -Level Warning
                    break # Don't retry on not found errors
                    
                } elseif ($statusCode -eq 400) {
                    Write-Log "[Notifications] Discord API bad request for channel $channelId (status: $statusCode): $errorMessage" -Level Warning
                    break # Don't retry on bad request errors
                    
                } else {
                    # Generic error with exponential backoff
                    if ($retryCount -lt $maxRetries) {
                        $waitTime = [Math]::Min(1000 * [Math]::Pow(2, $retryCount), 30000)
                        Write-Log "[Notifications] Discord API error (status: $statusCode) for channel $channelId, retrying in $($waitTime/1000)s (attempt $retryCount/$maxRetries): $errorMessage" -Level Warning
                        Start-Sleep -Milliseconds $waitTime
                    } else {
                        Write-Log "[Notifications] Discord API permanently unavailable for channel $channelId after $maxRetries attempts (final status: $statusCode): $errorMessage" -Level Error
                    }
                }
            }
        }
        
        # Small delay between channels to avoid hitting rate limits
        if ($ChannelIds.Count -gt 1) {
            Start-Sleep -Milliseconds 500
        }
    }
}

function Send-RichEmbed {
    <#
    .SYNOPSIS
    Send complex Discord embed with components (buttons, etc.)
    .PARAMETER Config
    Configuration object
    .PARAMETER NotificationType
    Type of notification (admin/player)
    .PARAMETER EmbedData
    Complete embed data including components
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        
        [Parameter(Mandatory)]
        [string]$NotificationType,
        
        [Parameter(Mandatory)]
        [hashtable]$EmbedData
    )
    
    # Get notification config
    $notificationConfig = switch ($NotificationType) {
        "admin" { $Config.admin_notification }
        "player" { $Config.player_notification }
        default { $null }
    }
    
    if (-not $notificationConfig -or -not $notificationConfig.enabled) {
        Write-Log "[Notifications] $NotificationType notifications disabled"
        return
    }
    
    if (-not $Config.botToken) {
        Write-Log "[Notifications] No bot token configured" -Level Warning
        return
    }
    
    $headers = @{
        Authorization = "Bot $($Config.botToken)"
        "User-Agent" = "SCUM-Server-Manager/2.0"
        "Content-Type" = "application/json"
    }
    
    # Prepare content with role mentions
    $content = ""
    if ($notificationConfig.roleIds -and $notificationConfig.roleIds.Count -gt 0) {
        $content = ($notificationConfig.roleIds | ForEach-Object { "<@&$_>" }) -join " "
    }
    
    foreach ($channelId in $notificationConfig.channelIds) {
        if (-not $channelId -or $channelId -eq "") { continue }
        
        $body = @{
            content = $content
            embeds = @($EmbedData)
        }
        
        # Add components if present
        if ($EmbedData.components) {
            $body.components = $EmbedData.components
        }
        
        $jsonBody = $body | ConvertTo-Json -Depth 10
        
        try {
            $uri = "https://discord.com/api/v10/channels/$channelId/messages"
            Invoke-RestMethod -Uri $uri -Headers $headers -Method Post -Body $jsonBody
            Write-Log "[Notifications] Rich embed sent to channel $channelId"
        } catch {
            Write-Log "[Notifications] Failed to send rich embed to channel $channelId : $($_.Exception.Message)" -Level Warning
        }
    }
}

function Clear-NotificationHistory {
    <#
    .SYNOPSIS
    Clean up old notification tracking data
    #>
    $cutoffTime = (Get-Date).AddHours(-24)
    $keysToRemove = @()
    
    foreach ($key in $global:LastNotifications.Keys) {
        if ($global:LastNotifications[$key] -lt $cutoffTime) {
            $keysToRemove += $key
        }
    }
    
    foreach ($key in $keysToRemove) {
        $global:LastNotifications.Remove($key)
    }
    
    Write-Log "[Notifications] Cleaned up $($keysToRemove.Count) old entries"
}

function Show-NotificationSettings {
    <#
    .SYNOPSIS
    Display current notification settings for user review
    #>
    
    if (-not $script:moduleConfig) {
        Write-Log "[Notifications] Module not initialized" -Level Warning
        return
    }
    
    Write-Log "[Notifications] === Current Notification Settings ==="
    
    # Admin notifications
    $adminConfig = $script:moduleConfig.admin_notification
    if ($adminConfig) {
        Write-Log "[Notifications] Admin Notifications: $($adminConfig.enabled)"
        if ($adminConfig.enabled -and $adminConfig.messages) {
            $enabledCount = 0
            $totalCount = 0
            foreach ($msgKey in $adminConfig.messages.PSObject.Properties.Name) {
                if ($msgKey -notlike "_comment*") {
                    $totalCount++
                    $msgConfig = $adminConfig.messages.$msgKey
                    if ($msgConfig.enabled) {
                        $enabledCount++
                    }
                }
            }
            Write-Log "[Notifications] Admin Message Types: $enabledCount/$totalCount enabled"
        }
    }
    
    # Player notifications  
    $playerConfig = $script:moduleConfig.player_notification
    if ($playerConfig) {
        Write-Log "[Notifications] Player Notifications: $($playerConfig.enabled)"
        if ($playerConfig.enabled -and $playerConfig.messages) {
            $enabledCount = 0
            $totalCount = 0
            foreach ($msgKey in $playerConfig.messages.PSObject.Properties.Name) {
                if ($msgKey -notlike "_comment*") {
                    $totalCount++
                    $msgConfig = $playerConfig.messages.$msgKey
                    if ($msgConfig.enabled) {
                        $enabledCount++
                    }
                }
            }
            Write-Log "[Notifications] Player Message Types: $enabledCount/$totalCount enabled"
        }
    }
    
    Write-Log "[Notifications] === End Settings ==="
}

# Legacy compatibility functions
function Notify-ServerOnline { 
    param([hashtable]$Context = @{})
    Send-Notification -Type "player" -MessageKey "serverOnline" -Vars $Context
}

function Notify-ServerOffline { 
    param([hashtable]$Context = @{})
    Send-Notification -Type "player" -MessageKey "serverOffline" -Vars $Context
}

function Notify-ServerRestarting { 
    param([hashtable]$Context = @{})
    Send-Notification -Type "player" -MessageKey "restartWarning5" -Vars $Context
}

function Notify-UpdateInProgress { 
    param([hashtable]$Context = @{})
    Send-Notification -Type "admin" -MessageKey "updateInProgress" -Vars $Context
}

function Notify-ServerCrashed { 
    param([hashtable]$Context = @{})
    Send-Notification -Type "admin" -MessageKey "serverCrashed" -Vars $Context -SkipRateLimit
}

function Notify-AdminActionResult { 
    param([hashtable]$Context = @{})
    Send-Notification -Type "admin" -MessageKey "adminCommandExecuted" -Vars $Context
}

function Notify-ServerStatusChange {
    param(
        [Parameter(Mandatory)]
        [string]$NewStatus,
        
        [Parameter()]
        [string]$PreviousStatus,
        
        [Parameter()]
        [hashtable]$Context = @{}
    )
    
    # LEGACY FUNCTION - DISABLED
    # This function has been replaced by the centralized event system
    # All status change notifications are now handled by monitoring.psm1 and events.psm1
    Write-Log "[Notifications] Legacy Notify-ServerStatusChange called - skipping (handled by event system)" -Level Debug
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-NotificationModule',
    'Send-Notification',
    'Send-DiscordMessage',
    'Send-DiscordEmbed', 
    'Send-RichEmbed',
    'Clear-NotificationHistory',
    'Notify-ServerOnline',
    'Notify-ServerOffline',
    'Notify-ServerRestarting',
    'Notify-UpdateInProgress', 
    'Notify-ServerCrashed',
    'Notify-AdminActionResult',
    'Notify-ServerStatusChange',
    'Show-NotificationSettings'
)
