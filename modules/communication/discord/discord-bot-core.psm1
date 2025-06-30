# Discord Bot Core Module
# Handles bot presence, activity management, and core bot functionality

# Import required modules
Import-Module "$PSScriptRoot\gateway.psm1" -Force
Import-Module "$PSScriptRoot\..\..\..\core\logging\logging.psm1" -Force

# Bot state variables
$script:BotUser = $null
$script:CurrentActivity = $null
$script:CurrentStatus = "online"
$script:LastActivityUpdate = Get-Date

# Activity types for Discord
$script:ActivityTypes = @{
    Game = 0
    Streaming = 1
    Listening = 2
    Watching = 3
    Custom = 4
    Competing = 5
}

# Status types for Discord
$script:StatusTypes = @{
    Online = "online"
    DoNotDisturb = "dnd"
    Idle = "idle"
    Invisible = "invisible"
    Offline = "offline"
}

function Initialize-DiscordBot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Config = @{}
    )
    
    try {
        Write-LogMessage -Message "Initializing Discord bot core..." -Level "INFO"
        
        # Initialize gateway connection
        $gatewayResult = Initialize-DiscordGateway -Token $Token -Config $Config
        
        if (-not $gatewayResult.Success) {
            throw "Failed to initialize Discord gateway: $($gatewayResult.Error)"
        }
        
        # Register event handlers
        Register-DiscordEventHandler -EventType "READY" -Handler { param($data) Invoke-ReadyEventHandler -Data $data }
        Register-DiscordEventHandler -EventType "RESUMED" -Handler { param($data) Invoke-ResumedEventHandler -Data $data }
        Register-DiscordEventHandler -EventType "GUILD_CREATE" -Handler { param($data) Invoke-GuildCreateEventHandler -Data $data }
        
        # Set initial presence if configured
        if ($Config.ContainsKey("InitialActivity")) {
            Set-BotActivity -Activity $Config.InitialActivity
        }
        
        if ($Config.ContainsKey("InitialStatus")) {
            Set-BotStatus -Status $Config.InitialStatus
        }
        
        Write-LogMessage -Message "Discord bot core initialized successfully" -Level "INFO"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to initialize Discord bot core: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Set-BotActivity {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Activity
    )
    
    try {
        # Validate activity structure
        if (-not $Activity.ContainsKey("name") -or -not $Activity.ContainsKey("type")) {
            throw "Activity must contain 'name' and 'type' properties"
        }
        
        # Convert type name to number if needed
        if ($Activity.type -is [string]) {
            if ($script:ActivityTypes.ContainsKey($Activity.type)) {
                $Activity.type = $script:ActivityTypes[$Activity.type]
            } else {
                throw "Invalid activity type: $($Activity.type)"
            }
        }
        
        # Create presence payload
        $presence = @{
            op = 3  # Presence Update
            d = @{
                since = $null
                activities = @($Activity)
                status = $script:CurrentStatus
                afk = $false
            }
        }
        
        # Send presence update
        $result = Send-DiscordGatewayMessage -Message $presence
        
        if ($result.Success) {
            $script:CurrentActivity = $Activity
            $script:LastActivityUpdate = Get-Date
            Write-LogMessage -Message "Bot activity updated: $($Activity.name)" -Level "INFO"
        } else {
            throw "Failed to send presence update: $($result.Error)"
        }
        
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to set bot activity: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Set-BotStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )
    
    try {
        # Validate status
        if (-not $script:StatusTypes.ContainsValue($Status)) {
            throw "Invalid status: $Status. Valid statuses: $($script:StatusTypes.Values -join ', ')"
        }
        
        # Create presence payload
        $presence = @{
            op = 3  # Presence Update
            d = @{
                since = $null
                activities = if ($script:CurrentActivity) { @($script:CurrentActivity) } else { @() }
                status = $Status
                afk = $false
            }
        }
        
        # Send presence update
        $result = Send-DiscordGatewayMessage -Message $presence
        
        if ($result.Success) {
            $script:CurrentStatus = $Status
            Write-LogMessage -Message "Bot status updated: $Status" -Level "INFO"
        } else {
            throw "Failed to send presence update: $($result.Error)"
        }
        
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to set bot status: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Update-ServerActivity {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$ServerInfo
    )
    
    try {
        # Create activity based on server status
        $activityName = "SCUM Server"
        $activityType = "Watching"
        
        if ($ServerInfo.IsRunning) {
            $playerCount = if ($ServerInfo.ContainsKey("PlayerCount")) { $ServerInfo.PlayerCount } else { 0 }
            $maxPlayers = if ($ServerInfo.ContainsKey("MaxPlayers")) { $ServerInfo.MaxPlayers } else { 64 }
            
            $activityName = "$playerCount/$maxPlayers players"
            $activityType = "Watching"
        } else {
            $activityName = "Server Offline"
            $activityType = "Watching"
        }
        
        # Only update if activity has changed or it's been more than 5 minutes
        $timeSinceLastUpdate = (Get-Date) - $script:LastActivityUpdate
        $activityChanged = $null -eq $script:CurrentActivity -or 
                          $script:CurrentActivity.name -ne $activityName
        
        if ($activityChanged -or $timeSinceLastUpdate.TotalMinutes -gt 5) {
            $activity = @{
                name = $activityName
                type = $activityType
            }
            
            # Add server details to activity state if server is running
            if ($ServerInfo.IsRunning -and $ServerInfo.ContainsKey("ServerName")) {
                $activity.state = $ServerInfo.ServerName
            }
            
            $result = Set-BotActivity -Activity $activity
            
            if ($result.Success) {
                Write-LogMessage -Message "Server activity updated: $activityName" -Level "DEBUG"
            }
            
            return $result
        }
        
        return @{ Success = $true; Message = "Activity update skipped - no changes" }
        
    } catch {
        $errorMsg = "Failed to update server activity: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Get-BotInfo {
    return @{
        User = $script:BotUser
        CurrentActivity = $script:CurrentActivity
        CurrentStatus = $script:CurrentStatus
        LastActivityUpdate = $script:LastActivityUpdate
        IsConnected = Test-DiscordGatewayConnection
    }
}

function Invoke-ReadyEventHandler {
    param([hashtable]$Data)
    
    try {
        $script:BotUser = $Data.user
        Write-LogMessage -Message "Bot logged in as: $($Data.user.username)#$($Data.user.discriminator)" -Level "INFO"
        Write-LogMessage -Message "Bot is in $($Data.guilds.Count) guilds" -Level "INFO"
        
        # Log guild information
        foreach ($guild in $Data.guilds) {
            Write-LogMessage -Message "Connected to guild: $($guild.name) (ID: $($guild.id))" -Level "DEBUG"
        }
        
    } catch {
        Write-LogMessage -Message "Error handling READY event: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Invoke-ResumedEventHandler {
    param([hashtable]$Data)
    
    try {
        Write-LogMessage -Message "Discord connection resumed successfully" -Level "INFO"
        
        # Restore current activity if we have one
        if ($script:CurrentActivity) {
            Set-BotActivity -Activity $script:CurrentActivity | Out-Null
        }
        
    } catch {
        Write-LogMessage -Message "Error handling RESUMED event: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Invoke-GuildCreateEventHandler {
    param([hashtable]$Data)
    
    try {
        Write-LogMessage -Message "Guild available: $($Data.name) (ID: $($Data.id), Members: $($Data.member_count))" -Level "INFO"
        
    } catch {
        Write-LogMessage -Message "Error handling GUILD_CREATE event: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Stop-DiscordBot {
    try {
        Write-LogMessage -Message "Stopping Discord bot..." -Level "INFO"
        
        # Set offline status before disconnecting
        Set-BotStatus -Status "offline" | Out-Null
        
        # Close gateway connection
        Close-DiscordGateway
        
        # Clear bot state
        $script:BotUser = $null
        $script:CurrentActivity = $null
        $script:CurrentStatus = "online"
        
        Write-LogMessage -Message "Discord bot stopped successfully" -Level "INFO"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Error stopping Discord bot: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-DiscordBot',
    'Set-BotActivity',
    'Set-BotStatus',
    'Update-ServerActivity',
    'Get-BotInfo',
    'Stop-DiscordBot'
)
