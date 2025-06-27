![SCUM Server Automation](http://playhub.cz/scum/manager/repository-open-graph-template.jpg)

# 🎮 SCUM Server Automation

**SCUM Dedicated Server Management for Windows**

This project provides a complete automation solution for running SCUM dedicated servers on Windows. Features include:

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
- **SCUM Dedicated Server** files
- **Discord Bot** (optional, for notifications and admin commands)

## 🚀 Installation Steps

### 1. Download Required Tools

| Tool | Purpose | Download Link |
|------|---------|---------------|
| **SteamCMD** | Server updates | [Download](https://developer.valvesoftware.com/wiki/SteamCMD#Downloading_SteamCMD) |
| **NSSM** | Service manager | [Download](https://nssm.cc/download) |

### 2. Directory Structure

Current project structure:

```
📁 scum/
├── 📄 SCUMServer.ps1              # Main automation script
├── 📄 SCUMServer.config.json      # Configuration file
├── 📄 startserver.bat             # Start automation
├── 📄 stopserver.bat              # Stop automation
├── 📄 nssm.exe                    # Service manager
├── 📄 README.md                   # This documentation
├── 📄 SCUMServer.log              # Log file (auto-created)
├── 📁 server/                     # SCUM server files
│   ├── 📁 SCUM/                   # Main server folder
│   │   ├── 📁 Binaries/Win64/     # Server executable
│   │   ├── 📁 Saved/              # Save files
│   │   └── 📁 Config/             # Server configuration
│   └── 📁 steamapps/              # Steam manifest files
├── 📁 steamcmd/                   # SteamCMD installation
│   └── 📄 steamcmd.exe
└── 📁 backups/                    # Automatic backups (auto-created)
```

### 3. Setup Instructions

1. **Extract SteamCMD** into the `steamcmd/` folder
2. **Extract NSSM** and place `nssm.exe` in the root folder
3. **Install your SCUM server** files in the `server/` folder
4. **Copy the automation files** (`SCUMServer.ps1`, `SCUMServer.config.json`, `*.bat`) to the root folder

# 🔧 NSSM Service Configuration

**NSSM (Non-Sucking Service Manager)** allows your SCUM server to run as a Windows service.

## Step-by-Step Setup

### 1. Install Service
Open **Command Prompt as Administrator** in your SCUM folder and run:
```cmd
nssm.exe install SCUMSERVER
```

### 2. Configure Service Settings

The NSSM GUI will open. Configure each tab as follows:

#### 📋 Application Tab
- **Path**: `C:\YourPath\SCUM-Server\server\SCUM\Binaries\Win64\SCUMServer.exe`
- **Startup directory**: `C:\YourPath\SCUM-Server\server\SCUM\Binaries\Win64`
- **Arguments**: `-port=7777 -log` (adjust port as needed)

#### ⚙️ Details Tab  
- **Display name**: `SCUMSERVER`
- **Description**: `SCUM Dedicated Server`
- **Startup type**: `Manual` (automation will control it)

#### 🔐 Log On Tab
- **Account**: `Local System account`
- ✅ **Allow service to interact with desktop**

#### ⚡ Process Tab
- **Priority class**: `Realtime`
- ✅ **Console window**
- **Processor affinity**: `All processors`

#### 🛑 Shutdown Tab
- **Shutdown method**: `Generate Ctrl+C`
- **Kill processes in console session**: ✅
- **Timeouts**: `300000 ms` for all fields

#### 🔄 Exit Actions Tab
- **On Exit**: `No action`
- ✅ **srvany compatible exit code**
- **Restart delay**: `3000 ms`

### 3. Install and Test
1. Click **"Install service"**
2. Test manually: `net start SCUMSERVER`
3. Verify in Windows Services that it starts correctly
4. Stop it: `net stop SCUMSERVER`

> ⚠️ **Important**: The automation script will control the service - don't set it to "Automatic" startup!

### 📸 Visual Configuration Guide

For visual reference, here are the NSSM configuration screenshots:

| Tab | Screenshot |
|-----|------------|
| **Application** | ![Application Tab](https://playhub.cz/scum/manager/nssm1.png) |
| **Details** | ![Details Tab](https://playhub.cz/scum/manager/nssm6.png) |
| **Log On** | ![Log On Tab](https://playhub.cz/scum/manager/nssm2.png) |
| **Process** | ![Process Tab](https://playhub.cz/scum/manager/nssm3.png) |
| **Shutdown** | ![Shutdown Tab](https://playhub.cz/scum/manager/nssm4.png) |
| **Exit Actions** | ![Exit Actions Tab](https://playhub.cz/scum/manager/nssm5.png) |

---

# ⚙️ Configuration Guide

The automation is fully controlled via `SCUMServer.config.json`. Here's how to configure it:

## 🔧 Basic Server Settings

```json
{
  "serviceName": "SCUMSERVER",           // NSSM service name
  "backupRoot": "./backups",             // Backup storage location  
  "savedDir": "./server/SCUM/Saved",     // Server save files
  "steamCmd": "./steamcmd/steamcmd.exe", // SteamCMD path
  "serverDir": "./server",               // Server installation
  "appId": "3792580",                    // SCUM Steam App ID
  
  // Schedule & Timing Settings
  "restartTimes": ["02:00", "14:00", "20:00"], // Daily restart schedule
  "backupIntervalMinutes": 60,           // How often to backup
  "updateCheckIntervalMinutes": 10,      // Update check frequency
  "updateDelayMinutes": 15,              // Update delay when server running
  
  // Backup Settings
  "maxBackups": 10,                      // Backup retention count
  "compressBackups": true,               // Compress backup files
  "periodicBackupEnabled": true,         // Enable automatic backups
  "runBackupOnStart": false,             // Backup on script start
  "runUpdateOnStart": true,              // Check updates on start
  
  // Performance & Stability
  "autoRestartCooldownMinutes": 2,       // Cooldown between restart attempts
  "maxConsecutiveRestartAttempts": 3,    // Max restart attempts before giving up
  "serverStartupTimeoutMinutes": 10,     // How long to wait for server startup
  "fpsAlertThreshold": 15,               // FPS threshold for alerts
  "fpsWarningThreshold": 20,             // FPS threshold for warnings
  
  // Performance Thresholds (FPS Categories)
  "performanceThresholds": {
    "excellent": 30,                     // Excellent performance >= 30 FPS
    "good": 20,                          // Good performance >= 20 FPS  
    "fair": 15,                          // Fair performance >= 15 FPS
    "poor": 10,                          // Poor performance >= 10 FPS
    "critical": 0                        // Critical performance < 10 FPS
  }
}
```

## 🔔 Discord Integration Setup

### Option 1: Discord Bot (Recommended)

**Why use a bot?** Better control, admin commands, and more reliable delivery.

1. **Create Discord Bot**:
   - Go to [Discord Developer Portal](https://discord.com/developers/applications)
   - Create New Application → Bot tab → Create Bot
   - Copy the **Bot Token**

2. **Add Bot to Server**:
   - In Bot tab, click **Reset Token** and copy it
   - Go to OAuth2 → URL Generator
   - Select scopes: `bot` and permissions: `View Channels`, `Send Messages`, `Manage Messages`, `Read Messages History`, `Mention Everyone`, `Use External Emojis`, `Add Reactions`, `Use Slash Commands`, `Use Embedded Activities`
   - Use generated URL to add bot to your Discord server (permission 551903767616)

3. **Configure Bot in JSON**:
```json
{
  "botToken": "YOUR_BOT_TOKEN_HERE",
  "admin_notification": {
    "method": "bot",
    "channelIds": ["123456789012345678"],    // Admin channel ID
    "roleIds": ["987654321098765432"]        // Admin role ID
  },
  "player_notification": {  
    "method": "bot",
    "channelIds": ["123456789012345679"],    // Player channel ID
    "roleIds": ["987654321098765433"]        // Player role ID (optional)
  },
  "admin_command_channel": {
    "channelIds": ["123456789012345678"],    // Where admins can use !commands
    "roleIds": ["987654321098765432"],       // Required role for commands
    "commandPrefix": "!"                     // Command prefix
  }
}
```

### Option 2: Discord Webhooks (Simple)

**Good for:** Basic notifications only (no admin commands).

1. **Create Webhook**:
   - Discord channel → Settings → Integrations → Webhooks → New Webhook
   - Copy the Webhook URL

2. **Configure Webhook in JSON**:
```json
{
  "admin_notification": {
    "method": "webhook", 
    "webhooks": ["https://discord.com/api/webhooks/YOUR_WEBHOOK_URL"]
  },
  "player_notification": {
    "method": "webhook",
    "webhooks": ["https://discord.com/api/webhooks/YOUR_WEBHOOK_URL"]  
  }
}
```

### 🎯 Finding Discord IDs

**Enable Developer Mode**: Discord Settings → Advanced → Developer Mode ✅

- **Channel ID**: Right-click channel → Copy ID
- **Role ID**: Server Settings → Roles → Right-click role → Copy ID  
- **User ID**: Right-click user → Copy ID
## 🔧 Advanced Notification Customization

### Individual Notification Toggle

**NEW FEATURE!** You can now enable/disable any notification type individually:

```json
{
  "admin_notification": {
    "messages": {
      "serverStarted": { 
        "title": "Server Started", 
        "text": "SCUM server is online! Reason: {reason}", 
        "color": 3066993,
        "enabled": true     // ← Toggle this notification on/off
      },
      "backupCreated": {
        "title": "Backup Created",
        "text": "Backup saved: {path}",
        "color": 3447003,
        "enabled": false    // ← This notification is disabled
      }
    }
  }
}
```

### Message Template Variables

All messages support dynamic variables that get replaced automatically:

| Variable | Description | Example |
|----------|-------------|---------|
| `{reason}` | Why action occurred | "Admin command", "Scheduled restart" |
| `{result}` | Action outcome | "completed successfully", "failed" |
| `{status}` | Server status | "ONLINE", "OFFLINE" |
| `{admin}` | Admin who triggered action | Discord user ID |
| `{delayMinutes}` | Delay time | "15", "30" |
| `{path}` | File/backup location | "./backups/backup.zip" |
| `{installed}` | Current build ID | "12345678" |
| `{latest}` | Latest build ID | "12345679" |

### Notification Categories

**Admin Notifications** (detailed, technical):
- Server status changes with reasons
- Backup creation/failure reports  
- Update process details with build IDs
- Error messages with exit codes
- Action result confirmations

**Player Notifications** (user-friendly):
- Restart warnings (15min, 5min, 1min)
- Update announcements with timings
- Server online/offline status
- Crash notifications

## 🎮 Discord Admin Commands

Control your server directly from Discord! Send these commands in your configured admin channel:

### 🔄 Server Control Commands

| Command | Description | Example |
|---------|-------------|---------|
| `!server_restart` | Restart server immediately | `!server_restart` |
| `!server_restart [min]` | Schedule restart with warnings | `!server_restart 15` |
| `!server_stop` | Stop server immediately | `!server_stop` |
| `!server_stop [min]` | Schedule stop with warnings | `!server_stop 10` |  
| `!server_start` | Start stopped server | `!server_start` |
| `!server_status` | Get detailed server status report | `!server_status` |

### 📥 Update Commands

| Command | Description | Example |
|---------|-------------|---------|
| `!server_update` | Smart update (delay if running) | `!server_update` |
| `!server_update [min]` | Custom delay update | `!server_update 30` |
| `!server_update_now` | Force immediate update | `!server_update_now` |
| `!server_cancel_update` | Cancel scheduled update | `!server_cancel_update` |

### 💾 Utility Commands

| Command | Description | Example |
|---------|-------------|---------|
| `!server_backup` | Create manual backup | `!server_backup` |

### 🔐 Security Features

- **Role-based permissions**: Only users with configured roles can use commands
- **Channel restrictions**: Commands only work in designated channels  
- **Action confirmations**: All commands send result notifications
- **Audit logging**: All admin actions are logged with timestamps

> **Note**: Commands with delay parameters (like `!server_restart 15`) automatically send player warnings at appropriate intervals.

---

# 🚀 Running the Automation

## 🎯 Easy Start/Stop (Recommended Method)

The simplest way to manage your automation:

### ▶️ Starting the Automation
1. **Double-click** `startserver.bat`
2. ✅ Automatically runs as Administrator
3. ✅ Starts PowerShell automation script
4. ✅ Server begins running with full automation

### ⏹️ Stopping the Automation  
1. **Double-click** `stopserver.bat`
2. ✅ Gracefully stops SCUM server service
3. ✅ Terminates PowerShell automation script
4. ✅ Clean shutdown with final backup

## 🔧 Manual PowerShell Method

For advanced users or troubleshooting:

1. **Open PowerShell as Administrator**
2. **Navigate** to your SCUM folder: `cd "C:\Path\To\Your\SCUM-Server"`
3. **Run** the script: `.\SCUMServer.ps1`
4. **Monitor** the console output for status updates

## ✅ Verification Steps

After starting, verify everything is working:

1. **Check Service Status**:
   ```cmd
   net query SCUMSERVER
   ```

2. **Monitor Log File**:
   - Check `SCUMServer.log` for any errors
   - Look for Discord notification confirmations

3. **Test Discord Integration**:
   - Send a test admin command: `!server_backup`
   - Verify notifications appear in configured channels

4. **Check Automated Backups**:
   - Backups should appear in `./backups/` folder
   - Compressed .zip files with timestamps

---

# 🧠 Intelligent Automation Features

## 🔄 Smart Update System

### Server Running → Delayed Updates
When your server has active players:
1. **📢 Initial notification**: "Update available, server will restart in X minutes"
2. **⚠️ 5-minute warning**: "Update starting in 5 minutes!" (if delay ≥ 5 min)  
3. **🔄 Update execution**: Server restarts and updates automatically
4. **✅ Completion notice**: "Update completed, server is back online!"

### Server Offline → Immediate Updates  
When server is empty or stopped:
- ✅ **No waiting time** - updates immediately
- ✅ **No player disruption** - since nobody is playing
- ✅ **Faster maintenance** - efficient update process

### Admin Update Controls
- `!server_update` → Smart delay (default config) or immediate if offline
- `!server_update 30` → Custom 30-minute delay with player warnings  
- `!server_update_now` → Force immediate update regardless of status
- `!server_cancel_update` → Cancel any pending update

## 🛡️ Crash Recovery & Health Monitoring

### Automatic Crash Detection
- **🔍 Continuous monitoring**: Service status checked every few seconds
- **⚡ Instant detection**: Crashes detected immediately  
- **🔄 Smart recovery**: Automatic restart with crash reason logging

### Intelligent Auto-Restart Logic
- **✅ Auto-restart crashes**: When server dies unexpectedly
- **❌ Respect manual stops**: Won't restart if admin stopped it intentionally
- **📢 Player notifications**: Players informed about crashes and recovery
- **📝 Detailed logging**: Crash reasons and recovery actions logged

### Health Status Tracking
- **Real-time status**: Continuous server health monitoring
- **Performance logging**: Resource usage and uptime tracking
- **Predictive alerts**: Early warning for potential issues
- **FPS monitoring**: Real-time FPS tracking with configurable thresholds
- **SCUM log analysis**: Deep analysis of server logs for status detection
- **Player count tracking**: Monitor player activity and server population

## 📊 Performance Monitoring System

### Real-time FPS Tracking
The automation continuously monitors server performance by analyzing SCUM server logs:

- **Automatic FPS detection**: Parses Global Stats from SCUM.log
- **Performance categorization**: Classifies performance into 5 levels
- **Configurable thresholds**: Customize FPS thresholds for your hardware
- **Performance alerts**: Automatic notifications when FPS drops below thresholds
- **Status reporting**: Include performance data in admin status reports

### Performance Categories

| Category | Default FPS Threshold | Description |
|----------|----------------------|-------------|
| **Excellent** | ≥ 30 FPS | Optimal performance |
| **Good** | ≥ 20 FPS | Good performance |
| **Fair** | ≥ 15 FPS | Acceptable performance |
| **Poor** | ≥ 10 FPS | Performance issues detected |
| **Critical** | < 10 FPS | Severe performance problems |

### Performance Configuration

Configure thresholds in `SCUMServer.config.json`:

```json
{
  "performanceThresholds": {
    "excellent": 30,    // Adjust based on your server hardware
    "good": 20,         // Higher values = stricter requirements
    "fair": 15,         // Lower values = more lenient
    "poor": 10,
    "critical": 0
  },
  "fpsAlertThreshold": 15,      // Send alerts when FPS drops below this
  "fpsWarningThreshold": 20,    // Send warnings when FPS drops below this
  "performanceLogIntervalMinutes": 5  // How often to log performance
}
```

## 📊 Professional Notification System

### Universal Status Tracking
Every server action automatically triggers appropriate notifications:

| Action | Admin Notification | Player Notification |
|--------|-------------------|-------------------|
| **Server Start** | Detailed start reason & status | "Server is now online!" |
| **Server Stop** | Stop reason & confirmation | "Server has been stopped" |
| **Scheduled Restart** | Restart execution details | Progressive warnings (15m→5m→1m) |
| **Update Available** | Technical details with build IDs | User-friendly update notice |
| **Crash Detected** | Error details & recovery status | "Server crashed, restarting..." |
| **Backup Created** | File location & compression info | *(Optional - can be disabled)* |

### Notification Intelligence
- **📱 Role-based delivery**: Different content for admins vs players
- **🎯 Context-aware**: Messages adapt based on situation
- **⚙️ Fully configurable**: Enable/disable any notification type
- **🔧 Template system**: Customize all message content and formatting

---

# 💡 Best Practices & Tips

## 🎯 Recommended Settings

### For Small Communities (< 20 players)
```json
{
  "restartTimes": ["06:00", "18:00"],      // Twice daily
  "updateDelayMinutes": 5,                 // Short delays
  "backupIntervalMinutes": 30,             // Frequent backups
  "maxBackups": 20,                        // More backup retention
  "performanceThresholds": {               // More lenient for smaller servers
    "excellent": 25,
    "good": 18,
    "fair": 12,
    "poor": 8,
    "critical": 0
  },
  "fpsAlertThreshold": 12                  // Lower alert threshold
}
```

### For Large Communities (> 50 players)  
```json
{
  "restartTimes": ["04:00", "16:00"],      // Off-peak hours
  "updateDelayMinutes": 30,                // Longer warnings
  "backupIntervalMinutes": 60,             // Standard backups
  "maxBackups": 10,                        // Storage efficiency
  "performanceThresholds": {               // Stricter for performance servers
    "excellent": 35,
    "good": 25,
    "fair": 20,
    "poor": 15,
    "critical": 0
  },
  "fpsAlertThreshold": 20                  // Higher alert threshold
}
```

## 🔧 Configuration Tips

### Discord Setup
1. **Test notifications** in a private channel first
2. **Use separate channels** for admin vs player notifications
3. **Set appropriate role permissions** to prevent command abuse
4. **Monitor the log file** for Discord API issues

### Performance Optimization
- **Use SSD storage** for backup directory if possible
- **Schedule restarts** during low-activity periods
- **Monitor backup sizes** and adjust retention accordingly
- **Test update delays** with your community
- **Adjust FPS thresholds** based on your server hardware capabilities
- **Monitor performance logs** to identify optimal threshold settings
- **Use performance alerts** to proactively address server issues

### Security Considerations
- **Limit admin roles** to trusted community members only
- **Use unique bot tokens** (don't share across servers)
- **Regularly check logs** for unauthorized command attempts
- **Keep backup files secure** and test restoration procedures

## 🔍 Troubleshooting Guide

### Common Issues & Solutions

| Problem | Likely Cause | Solution |
|---------|--------------|----------|
| **Notifications not sending** | Bot token or channel ID incorrect | Verify Discord configuration and check logs |
| **"Get-ServerPerformanceStats not recognized"** | Script corruption or incomplete load | Restart PowerShell and reload script |
| **Server won't start** | NSSM service misconfigured | Check NSSM settings and server paths |
| **Updates failing** | SteamCMD permissions issue | Run as Administrator, check steamcmd path |
| **Backups not working** | Insufficient disk space or permissions | Check available storage and folder permissions |
| **Commands ignored** | Missing role permissions | Verify Discord role IDs in config |
| **Performance monitoring not working** | SCUM.log not accessible | Check savedDir path and log file permissions |
| **"Critical performance" false alerts** | FPS thresholds too high for hardware | Adjust performanceThresholds in config |

## 📋 Maintenance Checklist

### Daily
- [ ] Check `SCUMServer.log` for errors and performance alerts
- [ ] Verify backup files are being created
- [ ] Monitor Discord notifications
- [ ] Review performance status reports
- [ ] Check for any critical FPS alerts

### Weekly  
- [ ] Test admin commands functionality
- [ ] Review backup retention (delete old backups manually if needed)
- [ ] Check server performance metrics and trends
- [ ] Verify Discord bot permissions and connectivity
- [ ] Review and adjust FPS thresholds if needed

### Monthly
- [ ] Update SCUM server manually to latest version
- [ ] Review and optimize restart schedule
- [ ] Test disaster recovery procedures
- [ ] Update Discord bot permissions if needed
- [ ] Analyze performance logs for optimization opportunities
- [ ] Review and update notification templates if needed

---

# 🔧 Advanced Features

## 📊 Logging & Monitoring

All automation activity is logged to `SCUMServer.log` with timestamps:

```
2025-06-27 16:04:02 [INFO] Starting main server monitoring loop...
2025-06-27 16:04:02 [PERFORMANCE] FPS: 5 avg, Frame: 199.8ms, Players: 0, Status: Critical
2025-06-27 16:04:02 [INFO] Server performance status changed:  -> Critical
2025-06-27 16:04:02 [ALERT] Critical performance detected! FPS: 5 avg, Frame: 199.8ms, Players: 0, Status: Critical
2025-06-27 16:04:02 [ALERT] Very low FPS detected: 5 avg (threshold: 15)
```

### Log Features
- **Automatic log rotation**: When logs exceed configured size limit
- **Performance tracking**: Real-time FPS and frame time logging
- **Server state changes**: Detailed logging of all server status transitions
- **Admin command audit**: All Discord commands logged with user IDs
- **Error tracking**: Comprehensive error logging with stack traces

## 🔄 Backup System Features

- **Automatic compression** with configurable retention
- **Incremental cleanup** - old backups auto-deleted based on `maxBackups` setting
- **Pre-update backups** - automatic backup before every update
- **Manual backup command** - `!server_backup` for instant backups
- **Integrity verification** - backup success/failure notifications
- **Smart backup timing** - backups only when server is stable

## ⚡ Performance Features

- **Minimal resource usage** - optimized PowerShell scripting
- **Non-blocking operations** - server performance unaffected
- **Intelligent scheduling** - operations during low-activity periods
- **Crash recovery** - automatic restart without manual intervention
- **Smart update detection** - compares Steam build IDs for accurate update detection
- **SCUM log parsing** - deep analysis of server logs for status and performance data

## 🛡️ Stability & Recovery Features

- **Intelligent crash detection** - distinguishes between crashes and intentional stops
- **Restart cooldown system** - prevents restart loops with configurable delays
- **Maximum restart attempts** - stops trying after configured number of failed attempts
- **Intentional stop detection** - analyzes Windows event logs and SCUM logs
- **Service health monitoring** - continuously monitors Windows service status
- **Startup timeout handling** - fails gracefully if server doesn't start within timeout

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
