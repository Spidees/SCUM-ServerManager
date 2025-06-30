# Discord Bot Configuration Example
# This file shows how to configure the new Discord WebSocket-based bot system

@{
    # Discord Bot Configuration
    Discord = @{
        # Required: Your Discord bot token
        Token = "YOUR_BOT_TOKEN_HERE"
        
        # Bot presence configuration
        InitialActivity = @{
            name = "SCUM Server"
            type = "Watching"  # Game, Streaming, Listening, Watching, Custom, Competing
        }
        
        InitialStatus = "online"  # online, idle, dnd, invisible
        
        # Event handling configuration
        Events = @{
            # Command prefix for text commands
            CommandPrefix = "!"
            
            # Admin role IDs (users with these roles can use admin commands)
            AdminRoles = @(
                "123456789012345678",  # Admin role ID
                "234567890123456789"   # Moderator role ID
            )
            
            # Admin user IDs (these users can always use admin commands)
            AdminUsers = @(
                "345678901234567890",  # Your Discord user ID
                "456789012345678901"   # Another admin user ID
            )
            
            # Channels where bot commands are allowed (empty = all channels)
            AllowedChannels = @(
                "567890123456789012",  # #bot-commands channel ID
                "678901234567890123"   # #server-admin channel ID
            )
            
            # Command cooldown in seconds (prevents spam)
            CommandCooldown = 5
        }
        
        # Live embed configuration for real-time status updates
        LiveEmbeds = @{
            # Update interval in seconds
            UpdateInterval = 30
            
            # Channels where live embeds will be posted/updated
            Channels = @{
                # Channel ID = Configuration for that channel
                "789012345678901234" = @{  # #server-status channel
                    ThumbnailUrl = "https://example.com/scum-logo.png"
                }
                "890123456789012345" = @{  # #general channel
                    # Minimal configuration
                }
            }
        }
        
        # Notification system configuration
        Notifications = @{
            # Default channel for notifications
            DefaultChannel = "901234567890123456"  # #notifications channel
            
            # Channel overrides for specific notification types
            Channels = @{
                "Error" = "012345678901234567"      # #alerts channel for errors
                "Critical" = "123456789012345678"   # #critical-alerts channel
                "Success" = "234567890123456789"    # #good-news channel
                "Warning" = "345678901234567890"    # #warnings channel
                "Info" = "456789012345678901"       # #info channel
            }
        }
        
        # Cache configuration (optional tuning)
        Cache = @{
            MaxAge = @{
                Guilds = 3600      # 1 hour
                Channels = 1800    # 30 minutes
                Users = 3600       # 1 hour
                Members = 1800     # 30 minutes
                Roles = 3600       # 1 hour
                Messages = 300     # 5 minutes
            }
            MaxSize = @{
                Guilds = 100
                Channels = 1000
                Users = 10000
                Members = 10000
                Roles = 1000
                Messages = 1000
            }
        }
        
        # Gateway configuration (advanced)
        Gateway = @{
            # Reconnection settings
            MaxReconnectAttempts = 5
            ReconnectDelay = 5000  # milliseconds
            
            # Heartbeat settings
            HeartbeatTimeout = 60000  # milliseconds
            
            # Presence update frequency
            PresenceUpdateInterval = 300  # seconds (5 minutes)
        }
    }
    
    # Integration with existing automation settings
    Integration = @{
        # Enable Discord integration
        Enabled = $true
        
        # Update frequency for server status
        StatusUpdateInterval = 30  # seconds
        
        # Events to forward to Discord
        ForwardEvents = @(
            "ServerStart",
            "ServerStop", 
            "ServerCrash",
            "PlayerJoin",
            "PlayerLeave",
            "BackupComplete",
            "UpdateAvailable",
            "UpdateComplete"
        )
        
        # Critical events that should always be sent (ignores channel restrictions)
        CriticalEvents = @(
            "ServerCrash",
            "BackupFailed",
            "UpdateFailed"
        )
    }
}

<#
SETUP INSTRUCTIONS:

1. Create a Discord Application and Bot:
   - Go to https://discord.com/developers/applications
   - Create a "New Application"
   - Go to the "Bot" section
   - Create a bot and copy the token
   - Enable "Message Content Intent" if using text commands
   - Generate an invite URL with appropriate permissions

2. Get Discord IDs:
   - Enable Developer Mode in Discord (User Settings > Advanced > Developer Mode)
   - Right-click on servers, channels, roles, or users to copy their IDs
   - Fill in the IDs in this configuration file

3. Bot Permissions Required:
   - Read Messages/View Channels
   - Send Messages
   - Embed Links
   - Read Message History
   - Use Slash Commands (if implementing slash commands)
   - Manage Messages (for editing live embeds)

4. Integration Steps:
   - Copy this configuration to your main config file
   - Replace "YOUR_BOT_TOKEN_HERE" with your actual bot token
   - Update all the channel/role/user IDs with your server's IDs
   - Set Integration.Enabled = $true
   - Restart the automation script

5. Testing:
   - Use the Test-DiscordIntegration function to verify everything works
   - Try commands like "!status", "!help" in allowed channels
   - Check that live embeds update properly
   - Verify notifications are sent to correct channels

SECURITY NOTES:
- Keep your bot token secure and never commit it to version control
- Consider using environment variables or secure configuration files
- Regularly rotate your bot token if compromised
- Use role-based permissions rather than user-based when possible

TROUBLESHOOTING:
- Check logs for Discord-related errors
- Verify bot has proper permissions in Discord server
- Ensure all IDs are correct (18-19 digit numbers)
- Test with a simple configuration first, then add features
- Use Get-DiscordIntegrationStatus to check system health
#>
