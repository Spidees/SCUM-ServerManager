# Discord Integration Module
# Main integration point for all Discord bot functionality

# Import all Discord modules
Import-Module "$PSScriptRoot\gateway.psm1" -Force
Import-Module "$PSScriptRoot\discord-bot-core.psm1" -Force
Import-Module "$PSScriptRoot\discord-live-embed.psm1" -Force
Import-Module "$PSScriptRoot\discord-events.psm1" -Force
Import-Module "$PSScriptRoot\discord-api-ws.psm1" -Force
Import-Module "$PSScriptRoot\discord-cache.psm1" -Force
Import-Module "$PSScriptRoot\..\..\..\core\logging\logging.psm1" -Force

# Integration state
$script:DiscordConfig = $null
$script:IsInitialized = $false
$script:IntegrationTimer = $null

function Initialize-DiscordIntegration {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    try {
        Write-LogMessage -Message "Initializing Discord integration..." -Level "INFO"
        
        $script:DiscordConfig = $Config
        
        # Validate required configuration
        if (-not $Config.ContainsKey("Token") -or [string]::IsNullOrEmpty($Config.Token)) {
            throw "Discord bot token is required"
        }
        
        # Initialize Discord API
        Write-LogMessage -Message "Initializing Discord API..." -Level "INFO"
        $apiResult = Initialize-DiscordAPI -Token $Config.Token
        if (-not $apiResult.Success) {
            throw "Failed to initialize Discord API: $($apiResult.Error)"
        }
        
        # Initialize cache
        Write-LogMessage -Message "Initializing Discord cache..." -Level "INFO"
        $cacheConfig = if ($Config.ContainsKey("Cache")) { $Config.Cache } else { @{} }
        $cacheResult = Initialize-DiscordCache -Settings $cacheConfig
        if (-not $cacheResult.Success) {
            throw "Failed to initialize Discord cache: $($cacheResult.Error)"
        }
        
        # Initialize events system
        Write-LogMessage -Message "Initializing Discord events..." -Level "INFO"
        $eventsConfig = if ($Config.ContainsKey("Events")) { $Config.Events } else { @{} }
        $eventsResult = Initialize-DiscordEvents -Config $eventsConfig
        if (-not $eventsResult.Success) {
            throw "Failed to initialize Discord events: $($eventsResult.Error)"
        }
        
        # Initialize live embeds if configured
        if ($Config.ContainsKey("LiveEmbeds")) {
            Write-LogMessage -Message "Initializing live embeds..." -Level "INFO"
            $embedResult = Initialize-LiveEmbeds -Config $Config.LiveEmbeds
            if (-not $embedResult.Success) {
                throw "Failed to initialize live embeds: $($embedResult.Error)"
            }
        }
        
        # Initialize bot core
        Write-LogMessage -Message "Initializing Discord bot..." -Level "INFO"
        $botResult = Initialize-DiscordBot -Token $Config.Token -Config $Config
        if (-not $botResult.Success) {
            throw "Failed to initialize Discord bot: $($botResult.Error)"
        }
        
        # Register cache update handler for gateway events
        Register-DiscordEventHandler -EventType "*" -Handler { 
            param($eventType, $data) 
            Update-CacheFromGatewayEvent -EventType $eventType -EventData $data 
        }
        
        # Start integration timer for periodic updates
        Start-IntegrationTimer
        
        $script:IsInitialized = $true
        Write-LogMessage -Message "Discord integration initialized successfully" -Level "INFO"
        
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to initialize Discord integration: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Update-DiscordStatus {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerInfo
    )
    
    if (-not $script:IsInitialized) {
        return @{ Success = $false; Error = "Discord integration not initialized" }
    }
    
    try {
        $results = @{}
        
        # Update bot activity
        $activityResult = Update-ServerActivity -ServerInfo $ServerInfo
        $results.ActivityUpdate = $activityResult
        
        # Update live embeds if configured
        if ($script:DiscordConfig.ContainsKey("LiveEmbeds")) {
            $embedResult = Update-AllLiveEmbeds -ServerInfo $ServerInfo
            $results.EmbedUpdate = $embedResult
        }
        
        # Cleanup cache periodically
        Invoke-CacheCleanup
        
        $allSuccessful = $true
        foreach ($result in $results.Values) {
            if (-not $result.Success) {
                $allSuccessful = $false
                break
            }
        }
        
        return @{
            Success = $allSuccessful
            Results = $results
        }
        
    } catch {
        $errorMsg = "Error updating Discord status: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Send-DiscordNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [string]$Type = "Info",
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Details = @{}
    )
    
    if (-not $script:IsInitialized) {
        return @{ Success = $false; Error = "Discord integration not initialized" }
    }
    
    try {
        # Get notification configuration
        $notificationConfig = if ($script:DiscordConfig.ContainsKey("Notifications")) {
            $script:DiscordConfig.Notifications
        } else {
            @{}
        }
        
        # Determine target channel
        $channelId = $null
        if ($notificationConfig.ContainsKey("DefaultChannel")) {
            $channelId = $notificationConfig.DefaultChannel
        }
        
        # Override channel based on notification type
        if ($notificationConfig.ContainsKey("Channels")) {
            $typeChannels = $notificationConfig.Channels
            if ($typeChannels.ContainsKey($Type)) {
                $channelId = $typeChannels[$Type]
            }
        }
        
        if (-not $channelId) {
            return @{ Success = $false; Error = "No channel configured for notifications" }
        }
        
        # Create notification embed
        $embed = New-NotificationEmbed -Message $Message -Type $Type -Details $Details
        
        # Send notification
        $result = Send-DiscordMessage -ChannelId $channelId -Embeds @($embed.Embed)
        
        if ($result.Success) {
            Write-LogMessage -Message "Discord notification sent: $Message" -Level "INFO"
        }
        
        return $result
        
    } catch {
        $errorMsg = "Error sending Discord notification: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function New-NotificationEmbed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [string]$Type = "Info",
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Details = @{}
    )
    
    # Color mapping for notification types
    $colors = @{
        "Info" = 0x0080FF      # Blue
        "Success" = 0x00FF00   # Green
        "Warning" = 0xFFFF00   # Yellow
        "Error" = 0xFF0000     # Red
        "Critical" = 0xFF0080  # Pink
    }
    
    # Icon mapping for notification types
    $icons = @{
        "Info" = "ℹ️"
        "Success" = "✅"
        "Warning" = "⚠️"
        "Error" = "❌"
        "Critical" = "🚨"
    }
    
    $color = if ($colors.ContainsKey($Type)) { $colors[$Type] } else { $colors["Info"] }
    $icon = if ($icons.ContainsKey($Type)) { $icons[$Type] } else { $icons["Info"] }
    
    $embed = @{
        title = "$icon $Type"
        description = $Message
        color = $color
        timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        footer = @{
            text = "SCUM Server Automation"
        }
    }
    
    # Add details as fields
    if ($Details.Count -gt 0) {
        $embed.fields = @()
        foreach ($key in $Details.Keys) {
            $embed.fields += @{
                name = $key
                value = $Details[$key].ToString()
                inline = $true
            }
        }
    }
    
    return @{ Success = $true; Embed = $embed }
}

function Start-IntegrationTimer {
    # In a real implementation, this would set up a proper timer
    # For now, we'll rely on periodic calls to Update-DiscordStatus
    Write-LogMessage -Message "Discord integration timer started" -Level "DEBUG"
}

function Stop-DiscordIntegration {
    try {
        Write-LogMessage -Message "Stopping Discord integration..." -Level "INFO"
        
        # Stop bot
        Stop-DiscordBot | Out-Null
        
        # Clear cache
        Clear-DiscordCache | Out-Null
        
        # Reset state
        $script:IsInitialized = $false
        $script:DiscordConfig = $null
        
        Write-LogMessage -Message "Discord integration stopped" -Level "INFO"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Error stopping Discord integration: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Get-DiscordIntegrationStatus {
    $botInfo = Get-BotInfo
    $cacheStats = Get-CacheStatistics
    $apiStatus = Get-DiscordAPIStatus
    
    return @{
        IsInitialized = $script:IsInitialized
        BotInfo = $botInfo
        CacheStatistics = $cacheStats
        APIStatus = $apiStatus
        Configuration = @{
            HasToken = $null -ne $script:DiscordConfig -and $script:DiscordConfig.ContainsKey("Token")
            LiveEmbedsEnabled = $null -ne $script:DiscordConfig -and $script:DiscordConfig.ContainsKey("LiveEmbeds")
            NotificationsEnabled = $null -ne $script:DiscordConfig -and $script:DiscordConfig.ContainsKey("Notifications")
        }
    }
}

function Test-DiscordIntegration {
    param(
        [Parameter(Mandatory = $false)]
        [switch]$Detailed
    )
    
    try {
        $results = @{
            IsInitialized = $script:IsInitialized
            Tests = @{}
        }
        
        if (-not $script:IsInitialized) {
            $results.Tests.Initialization = @{ Success = $false; Error = "Integration not initialized" }
            return $results
        }
        
        # Test bot connection
        $results.Tests.BotConnection = @{ Success = Test-DiscordGatewayConnection }
        
        # Test API access
        if ($Detailed) {
            # This would perform more comprehensive tests
            $results.Tests.APIAccess = @{ Success = $true; Message = "API tests not implemented yet" }
            $results.Tests.CacheHealth = @{ Success = $true; Statistics = Get-CacheStatistics }
        }
        
        return $results
        
    } catch {
        return @{
            IsInitialized = $false
            Error = $_.Exception.Message
        }
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-DiscordIntegration',
    'Update-DiscordStatus',
    'Send-DiscordNotification',
    'Stop-DiscordIntegration',
    'Get-DiscordIntegrationStatus',
    'Test-DiscordIntegration'
)
