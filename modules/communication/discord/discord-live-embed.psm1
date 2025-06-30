# Discord Live Embed Module
# Handles live updating status embeds with server information

# Import required modules
Import-Module "$PSScriptRoot\gateway.psm1" -Force
Import-Module "$PSScriptRoot\..\..\..\core\logging\logging.psm1" -Force

# Live embed state
$script:LiveEmbeds = @{}
$script:EmbedUpdateInterval = 30 # seconds
$script:LastEmbedUpdate = Get-Date
$script:EmbedColors = @{
    Online = 0x00FF00      # Green
    Offline = 0xFF0000     # Red
    Starting = 0xFFFF00    # Yellow
    Stopping = 0xFF8000    # Orange
    Error = 0xFF0080       # Pink
    Warning = 0xFFFF80     # Light Yellow
    Info = 0x0080FF        # Blue
}

function Initialize-LiveEmbeds {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    try {
        Write-LogMessage -Message "Initializing live embeds system..." -Level "INFO"
        
        # Validate configuration
        if (-not $Config.ContainsKey("Channels") -or $Config.Channels.Count -eq 0) {
            throw "No channels configured for live embeds"
        }
        
        # Initialize embed configurations
        foreach ($channelId in $Config.Channels.Keys) {
            $channelConfig = $Config.Channels[$channelId]
            
            $script:LiveEmbeds[$channelId] = @{
                Config = $channelConfig
                MessageId = $null
                LastUpdate = [DateTime]::MinValue
                LastContent = $null
                UpdatesPending = $false
            }
        }
        
        # Set update interval if specified
        if ($Config.ContainsKey("UpdateInterval")) {
            $script:EmbedUpdateInterval = $Config.UpdateInterval
        }
        
        Write-LogMessage -Message "Live embeds initialized for $($Config.Channels.Count) channels" -Level "INFO"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to initialize live embeds: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function New-ServerStatusEmbed {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerInfo,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Config = @{}
    )
    
    try {
        # Determine server status and color
        $status = "Unknown"
        $color = $script:EmbedColors.Error
        $statusIcon = "❓"
        
        if ($ServerInfo.ContainsKey("IsRunning")) {
            if ($ServerInfo.IsRunning) {
                $status = "Online"
                $color = $script:EmbedColors.Online
                $statusIcon = "🟢"
            } else {
                $status = "Offline"
                $color = $script:EmbedColors.Offline
                $statusIcon = "🔴"
            }
        }
        
        # Override status for special states
        if ($ServerInfo.ContainsKey("Status")) {
            switch ($ServerInfo.Status.ToLower()) {
                "starting" {
                    $status = "Starting"
                    $color = $script:EmbedColors.Starting
                    $statusIcon = "🟡"
                }
                "stopping" {
                    $status = "Stopping"
                    $color = $script:EmbedColors.Stopping
                    $statusIcon = "🟠"
                }
                "updating" {
                    $status = "Updating"
                    $color = $script:EmbedColors.Warning
                    $statusIcon = "⚙️"
                }
                "maintenance" {
                    $status = "Maintenance"
                    $color = $script:EmbedColors.Warning
                    $statusIcon = "🔧"
                }
            }
        }
        
        # Create embed
        $embed = @{
            title = "$statusIcon SCUM Server Status"
            color = $color
            timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            fields = @()
            footer = @{
                text = "Last updated"
            }
        }
        
        # Add server name if available
        if ($ServerInfo.ContainsKey("ServerName") -and $ServerInfo.ServerName) {
            $embed.description = "**$($ServerInfo.ServerName)**"
        }
        
        # Add status field
        $embed.fields += @{
            name = "Status"
            value = $status
            inline = $true
        }
        
        # Add player information if server is running
        if ($ServerInfo.IsRunning -and $ServerInfo.ContainsKey("PlayerCount")) {
            $playerCount = $ServerInfo.PlayerCount
            $maxPlayers = if ($ServerInfo.ContainsKey("MaxPlayers")) { $ServerInfo.MaxPlayers } else { "?" }
            
            $embed.fields += @{
                name = "Players"
                value = "$playerCount/$maxPlayers"
                inline = $true
            }
            
            # Add player utilization bar
            if ($ServerInfo.ContainsKey("MaxPlayers") -and $ServerInfo.MaxPlayers -gt 0) {
                $utilization = [math]::Round(($playerCount / $ServerInfo.MaxPlayers) * 100, 1)
                $barLength = 10
                $filledBars = [math]::Round(($utilization / 100) * $barLength)
                $emptyBars = $barLength - $filledBars
                
                $progressBar = "█" * $filledBars + "░" * $emptyBars
                
                $embed.fields += @{
                    name = "Utilization"
                    value = "$progressBar $utilization%"
                    inline = $false
                }
            }
        }
        
        # Add uptime if available
        if ($ServerInfo.ContainsKey("Uptime") -and $ServerInfo.Uptime) {
            $embed.fields += @{
                name = "Uptime"
                value = $ServerInfo.Uptime
                inline = $true
            }
        }
        
        # Add server version if available
        if ($ServerInfo.ContainsKey("Version") -and $ServerInfo.Version) {
            $embed.fields += @{
                name = "Version"
                value = $ServerInfo.Version
                inline = $true
            }
        }
        
        # Add performance metrics if available
        if ($ServerInfo.ContainsKey("Performance")) {
            $perf = $ServerInfo.Performance
            $perfFields = @()
            
            if ($perf.ContainsKey("CPU")) {
                $perfFields += "CPU: $($perf.CPU)%"
            }
            if ($perf.ContainsKey("Memory")) {
                $perfFields += "RAM: $($perf.Memory)%"
            }
            if ($perf.ContainsKey("FPS")) {
                $perfFields += "FPS: $($perf.FPS)"
            }
            
            if ($perfFields.Count -gt 0) {
                $embed.fields += @{
                    name = "Performance"
                    value = $perfFields -join " | "
                    inline = $false
                }
            }
        }
        
        # Add recent events if available
        if ($ServerInfo.ContainsKey("RecentEvents") -and $ServerInfo.RecentEvents.Count -gt 0) {
            $eventLines = @()
            $maxEvents = 5
            
            for ($i = 0; $i -lt [math]::Min($ServerInfo.RecentEvents.Count, $maxEvents); $i++) {
                $serverEvent = $ServerInfo.RecentEvents[$i]
                $eventLines += "• $($serverEvent.Message)"
            }
            
            $embed.fields += @{
                name = "Recent Events"
                value = $eventLines -join "`n"
                inline = $false
            }
        }
        
        # Add thumbnail if configured
        if ($Config.ContainsKey("ThumbnailUrl")) {
            $embed.thumbnail = @{
                url = $Config.ThumbnailUrl
            }
        }
        
        return @{ Success = $true; Embed = $embed }
        
    } catch {
        $errorMsg = "Failed to create server status embed: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Update-LiveEmbed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerInfo
    )
    
    try {
        if (-not $script:LiveEmbeds.ContainsKey($ChannelId)) {
            throw "Channel $ChannelId not configured for live embeds"
        }
        
        $embedConfig = $script:LiveEmbeds[$ChannelId]
        
        # Create new embed
        $embedResult = New-ServerStatusEmbed -ServerInfo $ServerInfo -Config $embedConfig.Config
        
        if (-not $embedResult.Success) {
            throw "Failed to create embed: $($embedResult.Error)"
        }
        
        $embed = $embedResult.Embed
        
        # Check if content has changed
        $embedJson = ConvertTo-Json $embed -Depth 10 -Compress
        if ($embedConfig.LastContent -eq $embedJson) {
            return @{ Success = $true; Message = "No changes detected" }
        }
        
        # Create message payload
        $messageData = @{
            embeds = @($embed)
        }
        
        # Send or update message
        if ($embedConfig.MessageId) {
            # Update existing message
            $result = Send-DiscordAPIRequest -Method "PATCH" -Endpoint "channels/$ChannelId/messages/$($embedConfig.MessageId)" -Data $messageData
        } else {
            # Send new message
            $result = Send-DiscordAPIRequest -Method "POST" -Endpoint "channels/$ChannelId/messages" -Data $messageData
            
            if ($result.Success -and $result.Data.ContainsKey("id")) {
                $embedConfig.MessageId = $result.Data.id
            }
        }
        
        if ($result.Success) {
            $embedConfig.LastUpdate = Get-Date
            $embedConfig.LastContent = $embedJson
            $embedConfig.UpdatesPending = $false
            
            Write-LogMessage -Message "Live embed updated for channel $ChannelId" -Level "DEBUG"
        }
        
        return $result
        
    } catch {
        $errorMsg = "Failed to update live embed for channel $ChannelId`: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Update-AllLiveEmbeds {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerInfo,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    
    try {
        $currentTime = Get-Date
        $timeSinceLastUpdate = ($currentTime - $script:LastEmbedUpdate).TotalSeconds
        
        # Check if update is needed
        if (-not $Force -and $timeSinceLastUpdate -lt $script:EmbedUpdateInterval) {
            return @{ Success = $true; Message = "Update interval not reached" }
        }
        
        $successCount = 0
        $errorCount = 0
        $errors = @()
        
        # Update each configured embed
        foreach ($channelId in $script:LiveEmbeds.Keys) {
            try {
                $result = Update-LiveEmbed -ChannelId $channelId -ServerInfo $ServerInfo
                
                if ($result.Success) {
                    $successCount++
                } else {
                    $errorCount++
                    $errors += "Channel $channelId`: $($result.Error)"
                }
                
            } catch {
                $errorCount++
                $errors += "Channel $channelId`: $($_.Exception.Message)"
            }
        }
        
        $script:LastEmbedUpdate = $currentTime
        
        $message = "Updated $successCount embeds"
        if ($errorCount -gt 0) {
            $message += ", $errorCount failed"
            Write-LogMessage -Message "Live embed update errors: $($errors -join '; ')" -Level "WARNING"
        }
        
        Write-LogMessage -Message $message -Level "INFO"
        
        return @{
            Success = $errorCount -eq 0
            Message = $message
            SuccessCount = $successCount
            ErrorCount = $errorCount
            Errors = $errors
        }
        
    } catch {
        $errorMsg = "Failed to update live embeds: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Remove-LiveEmbed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId
    )
    
    try {
        if (-not $script:LiveEmbeds.ContainsKey($ChannelId)) {
            return @{ Success = $true; Message = "Channel not configured" }
        }
        
        $embedConfig = $script:LiveEmbeds[$ChannelId]
        
        # Delete the message if it exists
        if ($embedConfig.MessageId) {
            $result = Send-DiscordAPIRequest -Method "DELETE" -Endpoint "channels/$ChannelId/messages/$($embedConfig.MessageId)"
            
            if (-not $result.Success) {
                Write-LogMessage -Message "Failed to delete embed message: $($result.Error)" -Level "WARNING"
            }
        }
        
        # Remove from configuration
        $script:LiveEmbeds.Remove($ChannelId)
        
        Write-LogMessage -Message "Live embed removed for channel $ChannelId" -Level "INFO"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to remove live embed for channel $ChannelId`: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Get-LiveEmbedStatus {
    $status = @{
        ConfiguredChannels = $script:LiveEmbeds.Keys.Count
        LastGlobalUpdate = $script:LastEmbedUpdate
        UpdateInterval = $script:EmbedUpdateInterval
        Channels = @{}
    }
    
    foreach ($channelId in $script:LiveEmbeds.Keys) {
        $config = $script:LiveEmbeds[$channelId]
        $status.Channels[$channelId] = @{
            HasMessage = $null -ne $config.MessageId
            MessageId = $config.MessageId
            LastUpdate = $config.LastUpdate
            UpdatesPending = $config.UpdatesPending
        }
    }
    
    return $status
}

# This function would need to be implemented in a separate API module
function Send-DiscordAPIRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Data
    )
    
    # Placeholder - this would use the Discord REST API
    Write-LogMessage -Message "Discord API request: $Method $Endpoint" -Level "DEBUG"
    return @{ Success = $true; Data = @{ id = "mock_message_id" } }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-LiveEmbeds',
    'New-ServerStatusEmbed',
    'Update-LiveEmbed',
    'Update-AllLiveEmbeds',
    'Remove-LiveEmbed',
    'Get-LiveEmbedStatus'
)
