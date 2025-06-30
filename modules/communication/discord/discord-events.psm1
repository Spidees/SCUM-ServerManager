# Discord Events Module
# Handles event routing, command processing, and event-driven functionality

# Import required modules
Import-Module "$PSScriptRoot\gateway.psm1" -Force
Import-Module "$PSScriptRoot\..\..\..\core\logging\logging.psm1" -Force

# Event processing state
$script:CommandPrefix = "!"
$script:AdminRoleIds = @()
$script:AdminUserIds = @()
$script:AllowedChannelIds = @()
$script:EventHandlers = @{}
$script:CommandCooldowns = @{}
$script:CommandCooldownDuration = 5 # seconds

function Initialize-DiscordEvents {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    try {
        Write-LogMessage -Message "Initializing Discord events system..." -Level "INFO"
        
        # Configure command prefix
        if ($Config.ContainsKey("CommandPrefix")) {
            $script:CommandPrefix = $Config.CommandPrefix
        }
        
        # Configure admin roles
        if ($Config.ContainsKey("AdminRoles")) {
            $script:AdminRoleIds = $Config.AdminRoles
        }
        
        # Configure admin users
        if ($Config.ContainsKey("AdminUsers")) {
            $script:AdminUserIds = $Config.AdminUsers
        }
        
        # Configure allowed channels
        if ($Config.ContainsKey("AllowedChannels")) {
            $script:AllowedChannelIds = $Config.AllowedChannels
        }
        
        # Configure command cooldown
        if ($Config.ContainsKey("CommandCooldown")) {
            $script:CommandCooldownDuration = $Config.CommandCooldown
        }
        
        # Register core event handlers
        Register-DiscordEventHandler -EventType "MESSAGE_CREATE" -Handler { param($data) Invoke-MessageCreateHandler -Data $data }
        Register-DiscordEventHandler -EventType "INTERACTION_CREATE" -Handler { param($data) Invoke-InteractionCreateHandler -Data $data }
        
        Write-LogMessage -Message "Discord events system initialized" -Level "INFO"
        Write-LogMessage -Message "Command prefix: $script:CommandPrefix" -Level "DEBUG"
        Write-LogMessage -Message "Admin roles: $($script:AdminRoleIds.Count)" -Level "DEBUG"
        Write-LogMessage -Message "Allowed channels: $($script:AllowedChannelIds.Count)" -Level "DEBUG"
        
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to initialize Discord events: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Invoke-MessageCreateHandler {
    param([hashtable]$Data)
    
    try {
        # Skip bot messages
        if ($Data.author.bot -eq $true) {
            return
        }
        
        # Check if message is in allowed channel
        if ($script:AllowedChannelIds.Count -gt 0 -and $Data.channel_id -notin $script:AllowedChannelIds) {
            return
        }
        
        # Check if message starts with command prefix
        if (-not $Data.content.StartsWith($script:CommandPrefix)) {
            return
        }
        
        # Parse command
        $commandText = $Data.content.Substring($script:CommandPrefix.Length).Trim()
        if ([string]::IsNullOrEmpty($commandText)) {
            return
        }
        
        $commandParts = $commandText -split '\s+', 2
        $commandName = $commandParts[0].ToLower()
        $commandArgs = if ($commandParts.Length -gt 1) { $commandParts[1] } else { "" }
        
        # Check command cooldown
        $userId = $Data.author.id
        $cooldownKey = "$userId`:$commandName"
        
        if ($script:CommandCooldowns.ContainsKey($cooldownKey)) {
            $timeSinceLastCommand = (Get-Date) - $script:CommandCooldowns[$cooldownKey]
            if ($timeSinceLastCommand.TotalSeconds -lt $script:CommandCooldownDuration) {
                $remainingCooldown = $script:CommandCooldownDuration - [math]::Floor($timeSinceLastCommand.TotalSeconds)
                Send-DiscordMessage -ChannelId $Data.channel_id -Content "⏱️ Command on cooldown. Please wait $remainingCooldown seconds."
                return
            }
        }
        
        # Set cooldown
        $script:CommandCooldowns[$cooldownKey] = Get-Date
        
        # Clean up old cooldowns (older than 1 hour)
        $oldCooldowns = $script:CommandCooldowns.Keys | Where-Object {
            (Get-Date) - $script:CommandCooldowns[$_] -gt (New-TimeSpan -Hours 1)
        }
        foreach ($oldKey in $oldCooldowns) {
            $script:CommandCooldowns.Remove($oldKey)
        }
        
        # Check permissions
        $isAdmin = Test-UserPermissions -UserId $userId -UserRoles $Data.member.roles -RequiredLevel "Admin"
        
        # Process command
        $commandContext = @{
            CommandName = $commandName
            Arguments = $commandArgs
            UserId = $userId
            ChannelId = $Data.channel_id
            GuildId = $Data.guild_id
            MessageId = $Data.id
            Author = $Data.author
            Member = $Data.member
            IsAdmin = $isAdmin
            RawMessage = $Data
        }
        
        Write-LogMessage -Message "Processing command '$commandName' from user $($Data.author.username)" -Level "INFO"
        
        # Route command to appropriate handler
        $result = Invoke-DiscordCommand -Context $commandContext
        
        if (-not $result.Success) {
            Send-DiscordMessage -ChannelId $Data.channel_id -Content "❌ Error: $($result.Error)"
        }
        
    } catch {
        Write-LogMessage -Message "Error processing MESSAGE_CREATE event: $($_.Exception.Message)" -Level "ERROR"
        
        if ($Data.ContainsKey("channel_id")) {
            Send-DiscordMessage -ChannelId $Data.channel_id -Content "❌ An error occurred while processing your command."
        }
    }
}

function Invoke-InteractionCreateHandler {
    param([hashtable]$Data)
    
    try {
        Write-LogMessage -Message "Received interaction: $($Data.type)" -Level "DEBUG"
        
        # Handle slash commands
        if ($Data.type -eq 2) { # APPLICATION_COMMAND
            $commandName = $Data.data.name
            $userId = $Data.member.user.id
            
            # Check permissions
            $isAdmin = Test-UserPermissions -UserId $userId -UserRoles $Data.member.roles -RequiredLevel "Admin"
            
            # Create command context
            $commandContext = @{
                CommandName = $commandName
                Arguments = $Data.data.options
                UserId = $userId
                ChannelId = $Data.channel_id
                GuildId = $Data.guild_id
                InteractionId = $Data.id
                InteractionToken = $Data.token
                Author = $Data.member.user
                Member = $Data.member
                IsAdmin = $isAdmin
                IsSlashCommand = $true
                RawInteraction = $Data
            }
            
            Write-LogMessage -Message "Processing slash command '$commandName' from user $($Data.member.user.username)" -Level "INFO"
            
            # Route command to appropriate handler
            $result = Invoke-DiscordCommand -Context $commandContext
            
            if (-not $result.Success) {
                Send-InteractionResponse -InteractionId $Data.id -Token $Data.token -Content "❌ Error: $($result.Error)"
            }
        }
        
    } catch {
        Write-LogMessage -Message "Error processing INTERACTION_CREATE event: $($_.Exception.Message)" -Level "ERROR"
        
        if ($Data.ContainsKey("id") -and $Data.ContainsKey("token")) {
            Send-InteractionResponse -InteractionId $Data.id -Token $Data.token -Content "❌ An error occurred while processing your command."
        }
    }
}

function Test-UserPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        
        [Parameter(Mandatory = $false)]
        [array]$UserRoles = @(),
        
        [Parameter(Mandatory = $true)]
        [string]$RequiredLevel
    )
    
    try {
        # Check if user is in admin users list
        if ($UserId -in $script:AdminUserIds) {
            return $true
        }
        
        # Check if user has admin role
        if ($UserRoles.Count -gt 0) {
            foreach ($roleId in $UserRoles) {
                if ($roleId -in $script:AdminRoleIds) {
                    return $true
                }
            }
        }
        
        # For now, only admin level is supported
        return $false
        
    } catch {
        Write-LogMessage -Message "Error checking user permissions: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

function Invoke-DiscordCommand {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Context
    )
    
    try {
        $commandName = $Context.CommandName
        
        # Route to specific command handlers
        switch ($commandName) {
            "status" {
                return Invoke-StatusCommand -Context $Context
            }
            "start" {
                return Invoke-StartCommand -Context $Context
            }
            "stop" {
                return Invoke-StopCommand -Context $Context
            }
            "restart" {
                return Invoke-RestartCommand -Context $Context
            }
            "players" {
                return Invoke-PlayersCommand -Context $Context
            }
            "help" {
                return Invoke-HelpCommand -Context $Context
            }
            "admin" {
                return Invoke-AdminCommand -Context $Context
            }
            default {
                return @{
                    Success = $false
                    Error = "Unknown command: $commandName. Use `$script:CommandPrefix`help for available commands."
                }
            }
        }
        
    } catch {
        $errorMsg = "Error executing command '$($Context.CommandName)': $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Invoke-StatusCommand {
    param([hashtable]$Context)
    
    try {
        # Get server status (this would integrate with server monitoring)
        $serverInfo = Get-ServerStatus
        
        if ($Context.IsSlashCommand) {
            $embed = New-ServerStatusEmbed -ServerInfo $serverInfo
            Send-InteractionResponse -InteractionId $Context.InteractionId -Token $Context.InteractionToken -Embeds @($embed.Embed)
        } else {
            $statusText = Format-ServerStatusText -ServerInfo $serverInfo
            Send-DiscordMessage -ChannelId $Context.ChannelId -Content $statusText
        }
        
        return @{ Success = $true }
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-StartCommand {
    param([hashtable]$Context)
    
    if (-not $Context.IsAdmin) {
        return @{ Success = $false; Error = "This command requires administrator permissions." }
    }
    
    try {
        # Start server (this would integrate with server management)
        $result = Start-SCUMServer
        
        $message = if ($result.Success) {
            "🟢 Server start command executed successfully."
        } else {
            "❌ Failed to start server: $($result.Error)"
        }
        
        if ($Context.IsSlashCommand) {
            Send-InteractionResponse -InteractionId $Context.InteractionId -Token $Context.InteractionToken -Content $message
        } else {
            Send-DiscordMessage -ChannelId $Context.ChannelId -Content $message
        }
        
        return $result
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-StopCommand {
    param([hashtable]$Context)
    
    if (-not $Context.IsAdmin) {
        return @{ Success = $false; Error = "This command requires administrator permissions." }
    }
    
    try {
        # Stop server (this would integrate with server management)
        $result = Stop-SCUMServer
        
        $message = if ($result.Success) {
            "🔴 Server stop command executed successfully."
        } else {
            "❌ Failed to stop server: $($result.Error)"
        }
        
        if ($Context.IsSlashCommand) {
            Send-InteractionResponse -InteractionId $Context.InteractionId -Token $Context.InteractionToken -Content $message
        } else {
            Send-DiscordMessage -ChannelId $Context.ChannelId -Content $message
        }
        
        return $result
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-RestartCommand {
    param([hashtable]$Context)
    
    if (-not $Context.IsAdmin) {
        return @{ Success = $false; Error = "This command requires administrator permissions." }
    }
    
    try {
        # Restart server (this would integrate with server management)
        $result = Restart-SCUMServer
        
        $message = if ($result.Success) {
            "🔄 Server restart command executed successfully."
        } else {
            "❌ Failed to restart server: $($result.Error)"
        }
        
        if ($Context.IsSlashCommand) {
            Send-InteractionResponse -InteractionId $Context.InteractionId -Token $Context.InteractionToken -Content $message
        } else {
            Send-DiscordMessage -ChannelId $Context.ChannelId -Content $message
        }
        
        return $result
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-PlayersCommand {
    param([hashtable]$Context)
    
    try {
        # Get player list (this would integrate with server monitoring)
        $players = Get-ServerPlayers
        
        if ($Context.IsSlashCommand) {
            $embed = New-PlayersEmbed -Players $players
            Send-InteractionResponse -InteractionId $Context.InteractionId -Token $Context.InteractionToken -Embeds @($embed.Embed)
        } else {
            $playerText = Format-PlayersText -Players $players
            Send-DiscordMessage -ChannelId $Context.ChannelId -Content $playerText
        }
        
        return @{ Success = $true }
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-HelpCommand {
    param([hashtable]$Context)
    
    try {
        $helpText = @"
**Available Commands:**

**Public Commands:**
• `$script:CommandPrefix`status - Show server status
• `$script:CommandPrefix`players - Show online players
• `$script:CommandPrefix`help - Show this help message

$(if ($Context.IsAdmin) {
"**Admin Commands:**
• `$script:CommandPrefix`start - Start the server
• `$script:CommandPrefix`stop - Stop the server  
• `$script:CommandPrefix`restart - Restart the server
• `$script:CommandPrefix`admin <command> - Execute admin commands"
} else {
"*Admin commands are available for authorized users*"
})
"@
        
        if ($Context.IsSlashCommand) {
            Send-InteractionResponse -InteractionId $Context.InteractionId -Token $Context.InteractionToken -Content $helpText
        } else {
            Send-DiscordMessage -ChannelId $Context.ChannelId -Content $helpText
        }
        
        return @{ Success = $true }
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-AdminCommand {
    param([hashtable]$Context)
    
    if (-not $Context.IsAdmin) {
        return @{ Success = $false; Error = "This command requires administrator permissions." }
    }
    
    try {
        # This would integrate with the existing admin command system
        if ([string]::IsNullOrEmpty($Context.Arguments)) {
            return @{ Success = $false; Error = "Please specify an admin command. Example: `$script:CommandPrefix`admin broadcast Hello everyone!" }
        }
        
        # Execute admin command (placeholder - would integrate with existing system)
        $result = Invoke-AdminServerCommand -Command $Context.Arguments
        
        $message = if ($result.Success) {
            "✅ Admin command executed: $($Context.Arguments)"
        } else {
            "❌ Admin command failed: $($result.Error)"
        }
        
        if ($Context.IsSlashCommand) {
            Send-InteractionResponse -InteractionId $Context.InteractionId -Token $Context.InteractionToken -Content $message
        } else {
            Send-DiscordMessage -ChannelId $Context.ChannelId -Content $message
        }
        
        return $result
        
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

# Placeholder functions that would be implemented in other modules
function Get-ServerStatus { return @{ IsRunning = $true; PlayerCount = 5; MaxPlayers = 64 } }
function Start-SCUMServer { return @{ Success = $true } }
function Stop-SCUMServer { return @{ Success = $true } }
function Restart-SCUMServer { return @{ Success = $true } }
function Get-ServerPlayers { return @() }
function Invoke-AdminServerCommand { param($Command); return @{ Success = $true } }
function Send-DiscordMessage { param($ChannelId, $Content); Write-LogMessage -Message "Discord message: $Content" -Level "DEBUG" }
function Send-InteractionResponse { param($InteractionId, $Token, $Content, $Embeds); Write-LogMessage -Message "Discord interaction response: $Content" -Level "DEBUG" }
function New-PlayersEmbed { param($Players); return @{ Embed = @{ title = "Players"; description = "No players online" } } }
function Format-ServerStatusText { param($ServerInfo); return "Server Status: Running" }
function Format-PlayersText { param($Players); return "No players online" }

# Export functions
Export-ModuleMember -Function @(
    'Initialize-DiscordEvents',
    'Test-UserPermissions',
    'Invoke-DiscordCommand'
)
