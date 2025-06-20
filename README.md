# SCUM Server Automation

This project provides a complete automation solution for running a SCUM dedicated server on Windows. It handles automatic updates, scheduled restarts, regular backups (with compression and retention), Discord notifications, robust logging, and auto-recovery. The server runs as a Windows service managed by NSSM, and all automation is fully configurable via a JSON file.

# Directory Structure

Recommended folder structure for SCUM server automation:

```
SCUM
│   SCUMServer.ps1
│   SCUMServer.config.json
│   nssm.exe
├── server
├── steamcmd
└── backups
```

- Place all files and folders as shown above in a main folder (e.g., `C:/SCUM`).
- The `server` folder contains your SCUM dedicated server files.
- The `steamcmd` folder contains SteamCMD.
- `nssm.exe`, `SCUMServer.ps1`, and `SCUMServer.config.json` should be in the root of the SCUM folder.

# NSSM Service Setup

To run your SCUM server as a Windows service using NSSM:

1. Open a command prompt as administrator in the SCUM folder and run:
   ```
   nssm.exe install SCUMSERVER
   ```
2. In the NSSM service editor, set the following (see screenshots below for reference):
   - **Path:**
     - `C:\SCUM\server\SCUM\Binaries\Win64\SCUMServer.exe` (adjust to your actual path)
   - **Startup directory:**
     - `C:\SCUM\server\SCUM\Binaries\Win64`
   - **Arguments like you want, ex.:**
     - `port=XXXX -log` 
   - **Service name:**
     - `SCUMSERVER` (or your chosen name, must match config)

3. Other settings (see screenshots):
   - **Log on:** Local System account, allow service to interact with desktop.
   - **Process:** Priority = Realtime, Console window checked, All processors selected.
   - **Shutdown:** Generate Control-C, Terminate process, timeouts as shown.
   - **Exit actions:** No action (srvany compatible), delay restart by 3000 ms.

4. Click "Install service" to save.

5. Start the service from Windows Services or with:
   ```
   net start SCUMSERVER
   ```

### NSSM Configuration Screenshots

Below are example screenshots for each NSSM tab:

**Application Tab**

![NSSM Application Tab](https://playhub.cz/scum/manager/nssm1.png)

**Log On Tab**

![NSSM Log On Tab](https://playhub.cz/scum/manager/nssm2.png)

**Process Tab**

![NSSM Process Tab](https://playhub.cz/scum/manager/nssm3.png)

**Shutdown Tab**

![NSSM Shutdown Tab](https://playhub.cz/scum/manager/nssm4.png)

**Exit Actions Tab**

![NSSM Exit Actions Tab](https://playhub.cz/scum/manager/nssm5.png)

---
# SCUM Server Automation – Guide

This script automates the management of a SCUM dedicated server on Windows (backups, updates, restarts, Discord notifications, logging). Everything is controlled via the `SCUMServer.config.json` configuration file.

## 1. Configuration

Open `SCUMServer.config.json` and adjust as needed:

- `serviceName`: Name of the NSSM service (as installed, e.g., "SCUMSERVER").
- `backupRoot`: Where to store backups (e.g., `./backups`).
- `savedDir`: Path to the server's saved data (e.g., `./server/SCUM/Saved`).
- `steamCmd`: Path to SteamCMD (e.g., `./steamcmd/steamcmd.exe`).
- `serverDir`: Root folder of the server (e.g., `./server`).
- `appId`: Steam AppID for the SCUM server (should be 3792580).
- `discordWebhook`: URL for Discord notifications (optional, leave empty if not used).
- `restartTimes`: Automatic restart times (format HH:mm, e.g., ["02:00", "12:00", "18:00", "00:00"]).

- `backupIntervalMinutes`: Backup interval in minutes (e.g., 60).
- `updateCheckIntervalMinutes`: How often to check for updates (e.g., 10).
- `maxBackups`: How many backups to keep (e.g., 10).
- `compressBackups`: Compress backups (true/false).
- `runBackupOnStart`: Run backup when the script starts (true/false).
- `runUpdateOnStart`: Check for updates when the script starts (true/false).

## 2. Running the Script

1. Make sure your server is running as a service via NSSM (see: above # NSSM Service Setup).
2. Run the PowerShell script `SCUMServer.ps1` as administrator. (Tested and recommended for proper operation.)
3. The script will automatically perform backups, updates, restarts, and send notifications according to the config.

## 3. Notes
- A backup is always performed before every server update.
- If a new version is detected, a backup is made before the update.
- Discord notifications are optional and can be disabled.
- Logs and errors are saved in `SCUMServer.log`.

## 4. Recommendations
- Regularly check your backups and logs.
- To simulate an update, you can manually change the `buildid` in `server/steamapps/appmanifest_3792580.acf`.
- All paths can be set relative to the script folder.

---
