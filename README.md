![SCUM Server Automation](http://playhub.cz/scum/manager/repository-open-graph-template.jpg)

# 🎮 SCUM Server Automation

**SCUM Dedicated Server Management for Windows**

This project provides a complete automation solution for running SCUM dedicated servers on Windows. Features include:

✅ **Automatic First Install** - Fully automated first-time setup, including SteamCMD download and server installation  
✅ **Automatic Updates** - Smart update system with player notifications (discord only)  
✅ **Scheduled Restarts** - Customizable restart times with advance warnings (discord only)  
✅ **Automated Backups** - Compressed backups with retention management  
✅ **Discord Integration** - Professional notifications and admin commands  
✅ **Crash Recovery** - Automatic server recovery with health monitoring  
✅ **Performance Monitoring** - Real-time FPS tracking with configurable thresholds  
✅ **Service Management** - Runs as Windows service via NSSM  
✅ **Configurable Notifications** - Enable/disable individual notification types  
✅ **Comprehensive Logging** - Detailed logs with rotation and size management  

# 📁 Quick Setup Guide

## Prerequisites

Before starting, make sure you have:
- **Windows 10/11** with Administrator access
- **PowerShell 5.1+** (pre-installed on Windows)
- **Discord Bot** (optional, for notifications and admin commands)

> 📋 **No manual SCUM server installation required** - the script automatically downloads SteamCMD (if missing) and server files!

## 🚀 Installation Steps

### 1. Download Required Tools

| Tool | Purpose | Download Link |
|------|---------|---------------|
| **NSSM** | Service manager | [Download](https://nssm.cc/download) |

> **Note:** SteamCMD is downloaded and extracted automatically by the script if not present. No manual download needed!

### 2. Directory Structure

Current project structure:

```
📁 scum/
├── 📄 SCUM-Server-Automation.ps1        # Main automation script
├── 📄 SCUM-Server-Automation.config.json # Configuration file
├── 📄 startserver.bat                   # Start automation
├── 📄 stopserver.bat                    # Stop automation
├── 📄 nssm.exe                          # Service manager
├── 📄 README.md                         # This documentation
├── 📄 SCUM-Server-Automation.log        # Log file (auto-created)
├── 📁 server/                           # SCUM server files (auto-created)
│   ├── 📁 SCUM/                         # Main server folder
│   │   ├── 📁 Binaries/Win64/           # Server executable
│   │   ├── 📁 Saved/                    # Save files
│   │   └── 📁 Config/                   # Server configuration
│   └── 📁 steamapps/                    # Steam manifest files
├── 📁 steamcmd/                         # SteamCMD installation (auto-created)
│   └── 📄 steamcmd.exe                  # Downloaded automatically
├── 📁 backups/                          # Automatic backups (auto-created)
└── 📁 modules/                          # PowerShell modules (core logic)
    ├── 📁 admincommands/                # Admin command handling
    ├── 📁 backup/                       # Backup logic
    ├── 📁 common/                       # Common utilities
    ├── 📁 logreader/                    # Log reading/parsing
    ├── 📁 monitoring/                   # Performance monitoring
    ├── 📁 notifications/                # Discord notification logic
    ├── 📁 service/                      # Service management
    └── 📁 update/                       # Update logic
```

### 3. Setup Instructions

1. **Extract NSSM** and place `nssm.exe` in the root folder
2. **Copy the automation files** (`SCUM-Server-Automation.ps1`, `SCUM-Server-Automation.config.json`, `*.bat`) to the root folder
3. **Run `startserver.bat`** or launch the script manually (see below)
4. **On first run:**
   - The script will automatically download and extract SteamCMD if missing
   - All required directories are created automatically
   - SCUM server files are downloaded via SteamCMD (no manual installation needed)
   - After successful install, the script exits and relaunches itself via `startserver.bat` (if present), or starts the server directly

> 📝 **Note**: The automation script detects if SteamCMD or SCUM server files are missing and downloads them as needed. You don't need to manually install SteamCMD or the server—just run the script!

# 🔧 NSSM Service Configuration

For advanced users who want to run the SCUM server as a Windows service, NSSM (Non-Sucking Service Manager) is used. This allows the server to run in the background as a service, with automatic restart on failure.

## Installing NSSM

1. Download NSSM from the [official website](https://nssm.cc/download).
2. Extract `nssm.exe` to the SCUM Server Automation folder.

## Configuring the Service

1. Open a Command Prompt as Administrator.
2. Navigate to the SCUM Server Automation folder.
3. Install the service:

   ```cmd
   nssm install SCUMSERVER "C:\Path\To\scum\SCUM-Server-Automation.ps1"
   ```

4. Configure the service settings (recovery, log on, etc.) as desired.

> ⚠️ **Important**: Running as a service requires proper configuration of the NSSM service. Ensure that the script works correctly in the foreground before installing as a service.

# ⚙️ Configuration

All settings are in `SCUM-Server-Automation.config.json`. Key fields:

```json
{
  "serviceName": "SCUMSERVER",           // NSSM service name
  "backupRoot": "./backups",             // Backup storage location
  "savedDir": "./server/SCUM/Saved",     // Server save files
  "steamCmd": "./steamcmd/steamcmd.exe", // SteamCMD path (auto-managed)
  "serverDir": "./server",               // Server installation
  "appId": "3792580",                    // SCUM Steam App ID
  "restartTimes": ["02:00", "14:00", "20:00"], // Daily restart schedule
  "backupIntervalMinutes": 60,            // Backup frequency
  "updateCheckIntervalMinutes": 10,       // Update check frequency
  "updateDelayMinutes": 15,               // Update delay if server running
  "maxBackups": 10,                       // Backup retention
  "compressBackups": true,                // Compress backups
  "periodicBackupEnabled": true,          // Enable auto-backups
  "runBackupOnStart": false,              // Backup on script start
  "runUpdateOnStart": true,               // Check updates on start
  "autoRestartCooldownMinutes": 2,        // Cooldown between restarts
  "maxConsecutiveRestartAttempts": 3,     // Max restart attempts
  "serverStartupTimeoutMinutes": 10,      // Startup timeout
  "fpsAlertThreshold": 15,                // FPS alert threshold
  "fpsWarningThreshold": 20,              // FPS warning threshold
  "performanceThresholds": {
    "excellent": 30,
    "good": 20,
    "fair": 15,
    "poor": 10,
    "critical": 0
  },
  // Discord config (see below)
  "botToken": "YOUR_BOT_TOKEN_HERE",
  "admin_notification": {
    "method": "bot",
    "channelIds": ["123456789012345678"],
    "roleIds": ["987654321098765432"]
  },
  "player_notification": {
    "method": "bot",
    "channelIds": ["123456789012345679"]
  },
  "admin_command_channel": {
    "channelIds": ["123456789012345678"],
    "roleIds": ["987654321098765432"],
    "commandPrefix": "!"
  }
}
```

> **Note:** All Discord fields must use empty arrays (`[]`) if not used. The script handles missing/empty arrays gracefully.

# 🔔 Discord Integration

All notifications and admin commands are handled exclusively via a **Discord bot** (requires bot token). Webhooks are not supported.

- **Bot method:** Full functionality – admin commands, role/channel security, rich notifications

**Admin commands** (via Discord):
- `!server_restart [min]` – Restart server (immediate or delayed)
- `!server_stop [min]` – Stop server (immediate or delayed)
- `!server_start` – Start server
- `!server_status` – Status report
- `!server_update [min]` – Smart update (delayed if running)
- `!server_update_now` – Force update
- `!server_cancel_update` – Cancel update
- `!server_backup` – Manual backup

> **Security:** Only users with configured roles in allowed channels can use commands. All actions are logged.

# 🔄 Update & Backup Logic

- **First install:**
  - SteamCMD is downloaded/extracted if missing
  - All required directories are created
  - SCUM server files are downloaded
  - After install, script exits and relaunches via `startserver.bat` (if present) for a clean start
  - If `startserver.bat` is missing, server is started directly
- **Updates:**
  - Checks for updates on schedule or on demand
  - If server is running, delays update and notifies players/admins
  - Accepts SteamCMD exit code 7 as success (with warning)
  - Pre-update backup is always performed
  - Verifies server executable after update/install
- **Backups:**
  - Compressed, timestamped backups with retention
  - Pre-update and scheduled backups
  - Manual backup via Discord command
  - All backup failures are logged and notified

# 🛡️ Error Handling & Logging

- All errors are logged with details and stack traces
- Discord notifications for critical failures
- All paths are absolute and quoted for safety
- All directories are auto-created if missing
- Log file: `SCUM-Server-Automation.log` (rotated by size)

# 🧠 Automation Workflow

1. **Start script** (`startserver.bat` or PowerShell)
2. **Script checks/install dependencies** (SteamCMD, server files, directories)
3. **If first install:**
   - Download/install everything
   - Exit and relaunch via `startserver.bat` (if present)
4. **Main loop:**
   - Monitor server/service health
   - Check for updates
   - Perform scheduled restarts
   - Run scheduled/manual backups
   - Monitor performance (FPS, logs)
   - Send Discord notifications
   - Respond to admin commands
   - Log all actions and errors

# 📝 Best Practices & Troubleshooting

- Always run as Administrator
- Use `startserver.bat` for clean startup/restart logic
- Configure Discord fields with empty arrays if not used
- Monitor `SCUM-Server-Automation.log` for errors and status
- Test Discord commands and notifications after setup
- Adjust FPS/backup/restart settings for your community size and hardware

**Common issues:**
| Problem | Solution |
|---------|----------|
| Notifications not sending | Check bot token/channel IDs, use empty arrays if not used |
| Server won't start | Check NSSM/service config, verify paths |
| Updates failing | Run as Admin, check SteamCMD path, check log |
| Backups not working | Check disk space/permissions |
| Commands ignored | Check Discord role/channel config |
| Performance alerts | Adjust FPS thresholds in config |

# 💬 Community & Support

- [Discord Support](https://playhub.cz/discord)
- [Ko-fi](https://ko-fi.com/playhub)
- [PayPal](https://paypal.me/spidees)

Thanks for using SCUM Server Automation!
