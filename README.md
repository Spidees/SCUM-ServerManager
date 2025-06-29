![SCUM Server Automation](http://playhub.cz/scum/manager/repository-open-graph-template.jpg)

# 🎮 SCUM Server Automation

**SCUM Dedicated Server Management for Windows**

This project provides a complete automation solution for running SCUM dedicated servers on Windows. Features include:

- ✅ **Automatic First Install** – Fully automated first-time setup, including SteamCMD download and server installation
- ✅ **Automatic Updates** – Smart update system with player notifications and pre-update backups
- ✅ **Scheduled Restarts** – Customizable restart times with advance warnings via Discord
- ✅ **Automated Backups** – Compressed backups with retention management and cleanup
- ✅ **Discord Integration** – Rich embed notifications and role-based admin commands
- ✅ **Crash Recovery** – Automatic server recovery with intelligent health monitoring
- ✅ **Performance Monitoring** – Real-time FPS tracking with configurable alert thresholds
- ✅ **Log Analysis** – Advanced log parsing for real-time server state detection
- ✅ **Service Management** – Runs as Windows service via NSSM with automatic startup
- ✅ **Configurable Notifications** – Granular control over notification types and spam prevention
- ✅ **Comprehensive Logging** – Detailed logs with automatic rotation and size management
- ✅ **Modular Architecture** – Clean, extensible PowerShell module system
- ✅ **Rate Limiting** – Anti-spam mechanisms for notifications and commands
- ✅ **Health Monitoring** – Multi-layered server health detection and recovery

---

# 📁 Quick Setup Guide

## Prerequisites

Before starting, make sure you have:

- **Windows 10/11** with Administrator access
- **PowerShell 5.1+** (pre-installed on Windows)
- **Discord Bot** (optional, for notifications and admin commands)

> 📋 **No manual SCUM server installation required** – the script automatically downloads SteamCMD (if missing) and server files!

## 🚀 Installation Steps

### 1. Download Required Tools

| Tool      | Purpose         | Download Link                       |
|-----------|----------------|-------------------------------------|
| **NSSM**  | Service manager | [Download](https://nssm.cc/download) |

> **Note:** SteamCMD is downloaded and extracted automatically by the script if not present. No manual download needed!

### 2. Directory Structure

Current project structure:

```
📁 SCUMServer/
├── 📄 SCUM-Server-Automation.ps1          # Main automation script
├── 📄 SCUM-Server-Automation.config.json  # Configuration file
├── 📄 start_scum_server_automation.bat    # Start automation system
├── 📄 start_server.bat                    # Start SCUM server service
├── 📄 stop_server.bat                     # Stop SCUM server service
├── 📄 nssm.exe                            # Service manager
├── 📄 README.md                           # This documentation
├── 📄 SCUM-Server-Automation.log          # Log file (auto-created)
├── 📄 scum_automation.pid                 # Process ID tracking (auto-created)
├── 📁 server/                             # SCUM server files (auto-created)
│   ├── 📁 SCUM/                           # Main server folder
│   │   ├── 📁 Binaries/Win64/             # Server executable
│   │   ├── 📁 Saved/                      # Save files & configuration
│   │   │   ├── 📁 Config/WindowsServer/   # Server settings (*.ini files)
│   │   │   ├── 📁 SaveFiles/              # Game world saves
│   │   │   └── 📁 Logs/                   # Server logs
│   │   ├── 📁 Content/                    # Game content files
│   │   └── 📁 Shaders/                    # Shader cache
│   ├── 📁 steamapps/                      # Steam manifest files
│   ├── 📁 Engine/                         # Unreal Engine files
│   └── 📁 BattlEye/                       # Anti-cheat system
├── 📁 steamcmd/                           # SteamCMD installation (auto-created)
│   ├── 📄 steamcmd.exe                    # Steam command line tool
│   ├── 📁 steamapps/                      # Steam app cache
│   ├── 📁 logs/                           # SteamCMD logs
│   └── 📁 appcache/                       # Application cache
├── 📁 backups/                            # Automatic backups (auto-created)
└── 📁 modules/                            # PowerShell modules (modular architecture)
    ├── 📁 automation/                     # Automation systems
    │   ├── 📁 backup/                     # Backup management
    │   ├── 📁 scheduling/                 # Scheduled operations
    │   └── 📁 update/                     # Update management
    ├── 📁 communication/                  # Communication systems
    │   ├── 📄 adapters.psm1               # Event system integration
    │   ├── 📁 admin/                      # Admin command handling
    │   ├── 📁 events/                     # Event management system
    │   └── 📁 notifications/              # Discord notifications
    ├── 📁 core/                           # Core functionality
    │   ├── 📁 common/                     # Common utilities
    │   └── 📁 logging/                    # Logging and parsing
    ├── 📁 extensions/                     # Extensibility framework
    ├── 📁 monitoring/                     # Monitoring systems
    │   └── 📄 monitoring.psm1             # Performance monitoring
    └── 📁 server/                         # Server management
        ├── 📁 installation/               # Server installation
        ├── 📁 monitoring/                 # Server health monitoring
        └── 📁 service/                    # Windows service management
```

### 3. Setup Instructions

1. **Extract NSSM** and place `nssm.exe` in the root folder
2. **Copy the automation files** (`SCUM-Server-Automation.ps1`, `SCUM-Server-Automation.config.json`, `*.bat` files and `modules` folder) to the root folder

---

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
  "periodicBackupEnabled": true,          // Enable auto-backups
  "updateCheckIntervalMinutes": 10,       // Update check frequency
  "updateDelayMinutes": 15,               // Update delay if server running
  "maxBackups": 10,                       // Backup retention
  "compressBackups": true,                // Compress backups
  "runBackupOnStart": false,              // Backup on script start
  "runUpdateOnStart": true,               // Check updates on start
  "autoRestartCooldownMinutes": 2,        // Cooldown between restarts
  "maxConsecutiveRestartAttempts": 3,     // Max restart attempts
  "serverStartupTimeoutMinutes": 10,      // Startup timeout
  "serverShutdownTimeoutMinutes": 5,      // Shutdown timeout
  
  // Performance monitoring settings
  "performanceAlertThreshold": "Poor",    // When to send alerts
  "performanceAlertCooldownMinutes": 30,  // Alert cooldown
  "performanceLogIntervalMinutes": 5,     // Performance logging
  "performanceThresholds": {
    "excellent": 30,
    "good": 20,
    "fair": 10,
    "poor": 5,
    "critical": 3
  },
  
  // Notification behavior
  "suppressDuplicateNotifications": true, // Prevent spam
  "notificationRateLimitMinutes": 0,      // Rate limit (0 = disabled)
  "adminNotificationAlways": true,        // Always send admin notifications  
  "playerNotificationMinimumPlayers": 0,  // Min players for notifications
  
  // Logging settings
  "enableDetailedLogging": true,          // Detailed logs
  "maxLogFileSizeMB": 100,               // Log rotation size
  "logRotationEnabled": true,            // Auto log rotation
  "consoleLogLevel": "Warning",          // Console verbosity
  
  // Log monitoring
  "customLogPath": null,                 // Custom log path (null = auto-detect)
  "logMonitoringEnabled": true,          // Enable log monitoring
  "logMonitoringIntervalSeconds": 1,     // Log check interval
  "preventStatusRegression": true,       // Prevent status downgrades
  
  // Discord config (see Discord Integration section below)
  "botToken": "YOUR_BOT_TOKEN_HERE",
  "admin_notification": {
    "enabled": true,
    "method": "bot",
    "channelIds": ["123456789012345678"],
    "roleIds": ["987654321098765432"],
    "messages": {
      // Extensive notification configuration with rich embeds
      // See actual config file for complete message definitions
    }
  },
  "player_notification": {
    "enabled": true,
    "method": "bot", 
    "channelIds": ["123456789012345679"],
    "messages": {
      // Player-friendly notification messages
      // See actual config file for complete message definitions
    }
  },
  "admin_command_channel": {
    "channelIds": ["123456789012345678"],
    "roleIds": ["987654321098765432"],
    "commandPrefix": "!",
    "guildId": "523456785012345679"
  }
}
```

> **Note:** All Discord fields must use empty arrays (`[]`) if not used. The script handles missing/empty arrays gracefully.

---

# 🔔 Discord Integration Setup

## Discord Bot (Recommended)

**Why use a bot?** Better control, rich embed notifications, admin commands with role security, and more reliable delivery.

1. **Create Discord Bot:**
   - Go to [Discord Developer Portal](https://discord.com/developers/applications)
   - Create New Application → Bot tab → Create Bot
   - Copy the **Bot Token**
2. **Add Bot to Server:**
   - In Bot tab, copy the **Bot Token**
   - Go to OAuth2 → URL Generator
   - Select scopes: `bot` and permissions: `View Channels`, `Send Messages`, `Manage Messages`, `Read Message History`, `Mention Everyone`, `Use External Emojis`, `Add Reactions`, `Use Slash Commands`, `Use Embedded Activities`
   - Use generated URL to add bot to your Discord server (permission 551903767616)
3. **Configure Bot in Script:**
   - Paste the **Bot Token** in `SCUM-Server-Automation.config.json`
   - Set up admin notification and command channel IDs and role IDs
   - Configure message settings for both admin and player notifications
4. **Run the Script:**
   - Start the script (`start_scum_server_automation.bat`)
   - Test admin commands in Discord

> **Note:** Bot permissions are crucial for functionality. Adjust channel permissions to allow bot actions.

---

### First Run

1. **Run `start_scum_server_automation.bat`**
2. On first run:
   - The script will automatically download and extract SteamCMD if missing
   - All required directories are created automatically
   - SCUM server files are downloaded via SteamCMD (no manual installation needed)
   - After successful install, the script exits.

> 📝 **Note:** The automation script detects if SteamCMD or SCUM server files are missing and downloads them as needed. You don't need to manually install SteamCMD or the server—just run the script!

---

# 🔧 NSSM Service Configuration

**NSSM (Non-Sucking Service Manager)** allows your SCUM server to run as a Windows service.

## 1. Install Service

Open **Command Prompt as Administrator** in your SCUM folder and run:

```cmd
nssm.exe install SCUMSERVER
```

## 2. Configure Service Settings

The NSSM GUI will open. Configure each tab as follows:

### 📋 Application Tab
- **Path:** `C:\YourPath\SCUMServer\server\SCUM\Binaries\Win64\SCUMServer.exe`
- **Startup directory:** `C:\YourPath\SCUMServer\server\SCUM\Binaries\Win64`
- **Arguments:** `-port=7777 -log` (adjust port as needed)
  
  > **Known parameters:**
  > - `-port=` (game port)
  > - `-QueryPort=` (query port)
  > - `-MaxPlayers=` (max players)
  > - `-nobattleye` (disable BattlEye)
  > - `-log` (**always required!**)
  >
  > **Note:**
  > - Adding the `-port=7777` argument will start the server on the specified port. When connecting, use the format `IP:port`.
  > - **Important:** The response port for client connections is always the defined port +2. For example, if you start the server with `-port=7777`, players must connect using `IP:7779`.
  > - If no port is defined, the server uses the default port `7779`.
  
### ⚙️ Details Tab
- **Display name:** `SCUMSERVER`
- **Description:** `SCUM Dedicated Server`
- **Startup type:** `Manual` (automation will control it)

### 🔐 Log On Tab
- **Account:** `Local System account`
- ✅ **Allow service to interact with desktop**

### ⚡ Process Tab
- **Priority class:** `Realtime`
- ✅ **Console window**
- **Processor affinity:** `All processors`

### 🛑 Shutdown Tab
- **Shutdown method:** `Generate Ctrl+C`
- **Timeouts:** `300000 ms` for first field
- ✅ **Terminate process**

### 🔄 Exit Actions Tab
- ✅ **On Exit:** `No action (srvany compatible)`
- **Delay restart by:** `3000 ms`

## 3. Install

- Click **"Install service"**

> ⚠️ **Important:** The automation script will control the service – don't set it to "Automatic" startup!

### 📸 Visual Configuration Guide

For visual reference, here are the NSSM configuration screenshots:

| Tab              | Screenshot                                              |
|------------------|--------------------------------------------------------|
| **Application**  | ![Application Tab](https://playhub.cz/scum/manager/nssm1.png) |
| **Details**      | ![Details Tab](https://playhub.cz/scum/manager/nssm6.png)     |
| **Log On**       | ![Log On Tab](https://playhub.cz/scum/manager/nssm2.png)      |
| **Process**      | ![Process Tab](https://playhub.cz/scum/manager/nssm3.png)     |
| **Shutdown**     | ![Shutdown Tab](https://playhub.cz/scum/manager/nssm4.png)    |
| **Exit Actions** | ![Exit Actions Tab](https://playhub.cz/scum/manager/nssm5.png) |

---

# ✅ Your Server and Configuration Are Ready!

Once you have completed the steps above, you are ready to start your SCUM server:

1. **Run `start_scum_server_automation.bat`**
   - This will launch the automation script and manage your SCUM server with all automation features enabled.
2. **Monitor the console and log file**
   - The script will display status messages in the console window.
   - All actions and errors are logged in `SCUM-Server-Automation.log`.
3. **Test Discord notifications and admin commands**
   - If you have configured Discord integration, try sending a command or check for notifications in your configured channels.
4. **Enjoy automated server management!**
   - The script will handle updates, restarts, backups, and monitoring automatically.

> **Tips:**
> - You can always stop the server using `stop_server.bat` or by stopping the NSSM service if running as a service.
> - Use `start_server.bat` to start the SCUM server service directly without automation (if automation is already running).

---

# 🔔 Discord Integration

All notifications and admin commands are handled exclusively via a **Discord bot** (requires bot token). Rich embed notifications provide detailed server information.

- **Bot method:** Full functionality – admin commands, role/channel security, rich embed notifications, performance metrics

**Available batch files:**
- `start_scum_server_automation.bat` – Launch automation system (recommended)
- `start_server.bat` – Start SCUM server service only
- `stop_server.bat` – Stop SCUM server service only

**Admin commands** (via Discord):

- `!server_restart [minutes]` – Restart server (immediate or delayed)
- `!server_stop [minutes]` – Stop server (immediate or delayed)  
- `!server_start` – Start server
- `!server_status` – Status report with performance metrics
- `!server_update [minutes]` – Smart update (delayed if running, immediate if no delay specified)
- `!server_backup` – Manual backup
- `!server_cancel` – Cancel all scheduled admin actions (restart, stop, update)
- `!server_restart_skip` – Skip next automatic restart from schedule

> **Security:** Only users with configured roles in allowed channels can use commands. All actions are logged.

---

# 🛠️ Server Configuration After First Start

After the initial start of your server, the necessary configuration files will be generated. These include all the `.ini` and `.json` files you can edit to customize your server.

To access these files, navigate to:

```
...\server\SCUM\Saved\Config\WindowsServer
```

Below is a summary of the most important files and their purposes:

### AdminUsers.ini
Placing SteamIDs into this file gives players admin rights (basic commands). You can grant access to additional commands by adding arguments in brackets next to the SteamID:

- `[SetGodMode]` — Access to `#SetGodMode True/False` (instant building)
- `[RestartServer]` — Access to `#RestartServer pretty please` (shutdown sequence)

**Examples:**
```
76561199637135087                        # admin commands
76561199637135087[SetGodMode]            # admin + setgodmode  
76561199637135087[SetGodMode,RestartServer] # admin + setgodmode + restartserver
```

### BannedUsers.ini
All banned players are listed here. You can also manually add SteamIDs to ban users.

### EconomyOverride.json
Adjust prices of items and services at traders in safe zones. Examples are included in the file—replace the item/service name and assign to the correct trader.
- More info: [Economy Update News](https://store.steampowered.com/news/app/513710/view/3131696199142015448)
- Tool: [SCUM Trader Economy Tool](https://trader.scum-global.com/)

### ExclusiveUsers.ini
Add SteamIDs of players who should have exclusive access. Only listed players can join. This is active after the first SteamID is added.

### GameUserSettings.ini & Input.ini
These files are not used by the server and can be ignored.

### RaidTimes.json
Set global raid times. More info: [Raid Times Guide](https://store.steampowered.com/news/app/513710/view/4202497395525190702)

### ServerSettings.ini
Contains all server settings. You can manually configure your server here without entering the game.

### ServerSettingsAdminUsers.ini
Add SteamIDs to grant access to in-game server settings configuration.

### SilencedUsers.ini
Lists silenced players and the duration of their silence.

### WhitelistedUsers.ini
Add SteamIDs for players who should have priority access. Whitelisted players can join even if the server is full (one non-whitelisted player will be kicked if needed).

---

## Additional Resources

- **Loot Modification Guide:** [Google Doc](https://docs.google.com/document/d/1TIxj5OUnyrOvnXyEn3aigxLzTUQ-o-695luaaK2PTW0)
- **Custom Quests Guide:** [Google Doc](https://docs.google.com/document/d/1B1qooypdebE2xvJ33cb-BIH5MEEsvi9w4v-vrgcYO1k/edit?tab=t.0#heading=h.o19tfspdpkw9)

---

## Server Logs

- The output from the server window is saved in the `Logs` folder:
  - `...\server\SCUM\Saved\Logs`
- Additional logs:
  - `...\server\SCUM\Saved\SaveFiles\Logs`
- Automation system logs:
  - `SCUM-Server-Automation.log` (in root directory)
- SteamCMD logs:
  - `...\steamcmd\logs\`

---

# 🔄 Update & Backup Logic

- **First install:**
  - SteamCMD is downloaded/extracted if missing
  - All required directories are created
  - SCUM server files are downloaded
  - After install, script can be restarted to begin monitoring
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
- **Log Monitoring:**
  - Real-time log analysis for server state detection
  - Smart health monitoring with performance tracking
  - Automatic crash detection and recovery

---

# 🛡️ Error Handling & Logging

- All errors are logged with details and stack traces
- Discord notifications for critical failures
- All paths are absolute and quoted for safety
- All directories are auto-created if missing
- Log file: `SCUM-Server-Automation.log` (rotated by size)
- Configurable log levels (Debug, Info, Warning, Error)
- Automatic log rotation to prevent disk space issues
- Performance metrics logging and alerting
- Rate limiting to prevent notification spam

---

# 🧠 Automation Workflow

1. **Start script** (`start_scum_server_automation.bat`)
2. **Script checks/install dependencies** (SteamCMD, server files, directories)
3. **If first install:**
   - Download/install everything
   - Script can be restarted to begin monitoring
4. **Main monitoring loop:**
   - Monitor server/service health via logs and service status
   - Check for updates on schedule
   - Perform scheduled restarts with player warnings
   - Run scheduled/manual backups with compression
   - Monitor performance (FPS, frame time, log analysis)
   - Send Discord notifications with rich embeds
   - Respond to admin commands with role-based security
   - Log all actions and errors with rotation
   - Handle automatic crash recovery
   - Prevent duplicate notifications and spam

---

# 📝 Best Practices & Troubleshooting

- Always run as Administrator
- Use `start_scum_server_automation.bat` for automated server management
- Use `start_server.bat` and `stop_server.bat` for manual service control
- Configure Discord fields with empty arrays (`[]`) if not used
- Monitor `SCUM-Server-Automation.log` for errors and status
- Test Discord commands and notifications after setup
- Adjust performance thresholds for your community size and hardware
- Configure notification settings to avoid spam

**Common issues:**

| Problem                      | Solution                                                      |
|------------------------------|---------------------------------------------------------------|
| Notifications not sending    | Check bot token/channel IDs, use empty arrays if not used    |
| Server won't start           | Check NSSM/service config, verify paths                      |
| Updates failing              | Run as Admin, check SteamCMD path, check log                 |
| Backups not working          | Check disk space/permissions                                  |
| Commands ignored             | Check Discord role/channel config                            |
| Performance alerts spam     | Adjust performance thresholds and cooldown settings          |
| Log file growing too large   | Enable log rotation in configuration                         |
| Automation not detecting crashes | Check log monitoring settings and server log path        |

---

## 💬 Community & Contact

Got questions, feedback, or just want to hang out?
You can contact me or join the community here:

[![Discord Badge](https://img.shields.io/badge/Join%20us%20on-Discord-5865F2?style=flat&logo=discord&logoColor=white)](https://playhub.cz/discord)

---

## 🙌 Support

If you enjoy this project, consider supporting:

[![Ko-fi Badge](https://img.shields.io/badge/Support%20me%20on-Ko--fi-ff5e5b?style=flat&logo=ko-fi&logoColor=white)](https://ko-fi.com/playhub)
[![PayPal Badge](https://img.shields.io/badge/Donate-PayPal-0070ba?style=flat&logo=paypal&logoColor=white)](https://paypal.me/spidees)

Thanks for your support!
