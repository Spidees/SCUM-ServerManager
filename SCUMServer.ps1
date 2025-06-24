# ==========================
# SCUM SERVER MANAGER (ENGLISH, UTF-8, SAFE)
# ==========================
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- LOAD CONFIG ---
$configPath = Join-Path $PSScriptRoot 'SCUMServer.config.json'
if (!(Test-Path $configPath)) {
    Write-Host "[FATAL] Config file $configPath not found!"; exit 1
}
$config = Get-Content $configPath | ConvertFrom-Json

$serviceName = $config.serviceName
$backupRoot = if ($config.backupRoot.StartsWith('./')) { Join-Path $PSScriptRoot ($config.backupRoot.Substring(2)) } else { $config.backupRoot }
$savedDir = if ($config.savedDir.StartsWith('./')) { Join-Path $PSScriptRoot ($config.savedDir.Substring(2)) } else { $config.savedDir }
$steamCmd = if ($config.steamCmd.StartsWith('./')) { Join-Path $PSScriptRoot ($config.steamCmd.Substring(2)) } else { $config.steamCmd }
$serverDir = if ($config.serverDir.StartsWith('./')) { Join-Path $PSScriptRoot ($config.serverDir.Substring(2)) } else { $config.serverDir }
$appId = $config.appId
$discordWebhook = $config.discordWebhook
$restartTimes = $config.restartTimes
$backupIntervalMinutes = $config.backupIntervalMinutes
$updateCheckIntervalMinutes = $config.updateCheckIntervalMinutes
$maxBackups = $config.maxBackups
$compressBackups = $config.compressBackups
$runBackupOnStart = $config.runBackupOnStart
$runUpdateOnStart = $config.runUpdateOnStart

# --- LOGGING & NOTIFY ---
function Write-Log {
    param([string]$msg)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp $msg"
    $line | Out-File -FilePath "SCUMServer.log" -Append -Encoding utf8
    Write-Host $line
}

function Send-Discord {
    param([string]$title, [string]$desc = "", [string]$color = 3447003)
    if (-not $discordWebhook) { Write-Log "[ERROR] Discord webhook is empty!"; return }
    $embed = @{
        title = $title
        description = $desc
        color = $color
        timestamp = (Get-Date).ToString("o")
        footer = @{ text = "SCUM Server Manager" }
    }
    $payload = @{ embeds = @($embed) } | ConvertTo-Json -Depth 4
    try {
        Invoke-RestMethod -Uri $discordWebhook -Method Post -ContentType 'application/json' -Body $payload
        Write-Log "[INFO] Discord notification sent (embed): $title"
    } catch {
        Write-Log "[ERROR] Discord notification failed (embed): $_"
        # Fallback: try only content
        try {
            $payload2 = @{ content = "$title - $desc" } | ConvertTo-Json
            Invoke-RestMethod -Uri $discordWebhook -Method Post -ContentType 'application/json' -Body $payload2
            Write-Log "[INFO] Discord notification fallback sent: $title"
        } catch {
            Write-Log "[ERROR] Discord notification fallback failed: $_"
        }
    }
}

# --- BACKUP ---
function Backup-Saved {
    if (!(Test-Path $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot | Out-Null }
    if (Test-Path $savedDir) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupDir = Join-Path $backupRoot "Saved_BACKUP_$timestamp"
        try {
            Copy-Item $savedDir $backupDir -Recurse -ErrorAction Stop
            if ($compressBackups) {
                $zipPath = "$backupDir.zip"
                Compress-Archive -Path $backupDir -DestinationPath $zipPath -Force
                Remove-Item $backupDir -Recurse -Force
                Write-Log "[INFO] Backup created and compressed: $zipPath"
                Send-Discord "Backup Created" "A new backup was created and compressed: $zipPath" 3447003
            } else {
                Write-Log "[INFO] Backup created: $backupDir"
                Send-Discord "Backup Created" "A new backup was created: $backupDir" 3447003
            }
            # Remove old backups if over maxBackups
            $backups = Get-ChildItem $backupRoot | Where-Object { $_.Name -like 'Saved_BACKUP_*' -or $_.Name -like 'Saved_BACKUP_*.zip' } | Sort-Object LastWriteTime -Descending
            if ($backups.Count -gt $maxBackups) {
                $toRemove = $backups | Select-Object -Skip $maxBackups
                foreach ($b in $toRemove) { Remove-Item $b.FullName -Recurse -Force }
            }
            return $true
        } catch {
            Write-Log "[ERROR] Backup of Saved folder failed: $_"
            Send-Discord "Backup Error" "Backup of the Saved folder failed. Update will not proceed." 15158332
            return $false
        }
    } else {
        Write-Log "[WARNING] Saved folder not found, backup skipped."
        Send-Discord "Backup Warning" "The Saved folder was not found, backup was skipped." 15105570
        return $false
    }
}

# Check if the service is running
function Check-ServiceRunning {
    param([string]$name)
    $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $false }
    return $svc.Status -eq 'Running'
}

function Get-InstalledBuildId {
    $manifestPath = Join-Path $serverDir "steamapps/appmanifest_$appId.acf"
    if (!(Test-Path $manifestPath)) {
        Write-Log "[DEBUG] Manifest file not found: $manifestPath"
        return $null
    }
    $content = Get-Content $manifestPath -Raw
    if ($content -match '"buildid"\s+"(\d+)"') {
        if ($matches.Count -ge 2) { return $matches[1] } else { Write-Log "[DEBUG] buildid match failed in manifest content"; return $null }
    } else {
        Write-Log "[DEBUG] buildid not found in manifest. Content: $content"
    }
    return $null
}

function Get-LatestBuildId {
    $cmd = "$steamCmd +login anonymous +app_info_update 1 +app_info_print $appId +quit"
    $outputArr = & cmd /c $cmd
    $output = $outputArr -join "`n"
    $output | Out-File -FilePath "steamcmd_buildid_output.log" -Encoding utf8
    # Search for buildid in branches/public section
    if ($output -match '"branches"[\s\S]*?"public"[\s\S]*?"buildid"\s+"(\d+)"') {
        if ($matches.Count -ge 2) { return $matches[1] } else { Write-Log "[DEBUG] buildid match failed in steamcmd output"; return $null }
    } elseif ($output -match '"buildid"\s+"(\d+)"') {
        if ($matches.Count -ge 2) { return $matches[1] } else { Write-Log "[DEBUG] buildid match failed in steamcmd output (fallback)"; return $null }
    } else {
        Write-Log "[DEBUG] buildid not found in steamcmd output. Output: $output"
    }
    return $null
}

# --- UPDATE ---
function Update-Server {
    $installedBuild = Get-InstalledBuildId
    $latestBuild = Get-LatestBuildId
    if ($null -eq $installedBuild -or $null -eq $latestBuild) {
        Write-Log "[WARNING] Could not determine buildid, running update as fallback."
        Send-Discord "Update Warning" "Could not determine buildid, running update as fallback." 15105570
    } elseif ($installedBuild -eq $latestBuild) {
        Write-Log "[INFO] No new update available. Skipping update."
        # No Discord notification to avoid spam
        return $true
    } else {
        Write-Log "[INFO] New update available! Installed: $installedBuild, Latest: $latestBuild"
        Send-Discord "Update Available" "A new server update is available! Installed: $installedBuild, Latest: $latestBuild" 15844367
    }
    # Stop server service before update
    Write-Log "[INFO] Stopping server service before update..."
    cmd /c "net stop $serviceName"
    Start-Sleep -Seconds 10
    $cmd = "$steamCmd +force_install_dir $serverDir +login anonymous +app_update $appId validate +quit"
    Write-Log "[INFO] Checking for update..."
    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -Wait -NoNewWindow -PassThru
    $exitCode = $process.ExitCode
    if ($exitCode -eq 0) {
        Write-Log "[INFO] Server update successful. Starting service..."
        Send-Discord "Update Successful" "The server was updated and restarted successfully." 3066993
        cmd /c "net start $serviceName"
        Start-Sleep -Seconds 10
        if (Check-ServiceRunning $serviceName) {
            Write-Log "[INFO] Server service is running after update."
            Send-Discord "Server Running" "The server service is running after update." 3447003
        } else {
            Write-Log "[ERROR] Server service failed to start after update!"
            Send-Discord "Update Error" "The server service failed to start after update!" 15158332
        }
        return $true
    } else {
        Write-Log "[ERROR] Server update failed (code $exitCode)."
        Send-Discord "Update Failed" "Server update failed with exit code $exitCode." 15158332
        return $false
    }
}

# --- SCHEDULED RESTART ---
function Is-TimeForScheduledRestart {
    param([string[]]$restartTimes)
    $now = Get-Date
    foreach ($t in $restartTimes) {
        $target = [datetime]::ParseExact($t, 'HH:mm', $null)
        $scheduled = (Get-Date -Hour $target.Hour -Minute $target.Minute -Second 0)
        if ($now -ge $scheduled -and $now -lt $scheduled.AddMinutes(1)) {
            return $true
        }
    }
    return $false
}

# --- MAIN LOOP ---
$global:LastBackupTime = $null
$global:LastUpdateCheck = $null
$global:LastRestartTime = $null

Write-Log "--- Script started ---"
Send-Discord "SCUM Manager Started"

# Only run initial backup if enabled
if ($runBackupOnStart) {
    Write-Log "[INFO] Running initial backup (runBackupOnStart enabled) before any update or service start."
    Backup-Saved | Out-Null
    $global:LastBackupTime = Get-Date
}

if ($runUpdateOnStart) {
    Write-Log "[INFO] Running initial update check (runUpdateOnStart enabled)"
    $installedBuild = Get-InstalledBuildId
    $latestBuild = Get-LatestBuildId
    if ($null -eq $installedBuild -or $null -eq $latestBuild) {
        Write-Log "[WARNING] Could not determine buildid, running update as fallback."
        Send-Discord "Update Warning" "Could not determine buildid, running update as fallback." 15105570
        Update-Server | Out-Null
        $global:LastUpdateCheck = Get-Date
    } elseif ($installedBuild -eq $latestBuild) {
        Write-Log "[INFO] No new update available. Skipping update."        # Start service if not running (don't stop it if it's already running)
        if (-not (Check-ServiceRunning $serviceName)) {
            Write-Log "[INFO] Starting server service after backup and update check."
            cmd /c "net start $serviceName"
            Start-Sleep -Seconds 10
            if (Check-ServiceRunning $serviceName) {
                Write-Log "[INFO] Server service started successfully after backup and update check."
                Send-Discord "Server Started" "The SCUM server service was started after backup and update check." 3447003
            } else {
                Write-Log "[ERROR] Server service failed to start after backup and update check!"
                Send-Discord "Start Error" "The SCUM server service failed to start after backup and update check!" 15158332
            }
        } else {
            Write-Log "[INFO] Server service is already running after update check."
        }
        $global:LastUpdateCheck = Get-Date
    } else {
        Write-Log "[INFO] New update available! Installed: $installedBuild, Latest: $latestBuild"
        Send-Discord "Update Available" "A new server update is available! Installed: $installedBuild, Latest: $latestBuild" 15844367
        Update-Server | Out-Null
        $global:LastUpdateCheck = Get-Date
    }
} else {
    # If not updating on start, just start the service if not running
    if (-not (Check-ServiceRunning $serviceName)) {
        Write-Log "[INFO] Starting server service after backup (no update on start)."
        cmd /c "net start $serviceName"
        Start-Sleep -Seconds 10
        if (Check-ServiceRunning $serviceName) {
            Write-Log "[INFO] Server service started successfully after backup."
            Send-Discord "Server Started" "The SCUM server service was started after backup." 3447003
        } else {
            Write-Log "[ERROR] Server service failed to start after backup!"
            Send-Discord "Start Error" "The SCUM server service failed to start after backup!" 15158332
        }
    } else {
        Write-Log "[INFO] Server service is already running, no action needed."
    }
}

while ($true) {
    $now = Get-Date
    $updateOrRestart = $false
    # Regular backup
    if (-not $global:LastBackupTime -or ((New-TimeSpan -Start $global:LastBackupTime -End $now).TotalMinutes -ge $backupIntervalMinutes)) {
        Backup-Saved | Out-Null
        $global:LastBackupTime = $now
    }
    # Update check
    if (-not $global:LastUpdateCheck -or ((New-TimeSpan -Start $global:LastUpdateCheck -End $now).TotalMinutes -ge $updateCheckIntervalMinutes)) {
        $updateResult = Update-Server | Out-Null
        $global:LastUpdateCheck = $now
        $updateOrRestart = $true
    }
    # Scheduled restart
    if (Is-TimeForScheduledRestart $restartTimes) {
        if ($global:LastRestartTime -ne $now.Date.AddHours($now.Hour).AddMinutes($now.Minute)) {
            Write-Log "[INFO] Scheduled restart in progress."
            Send-Discord "SCUM Scheduled Restart" "Restarting server..." 15844367
            Backup-Saved | Out-Null
            cmd /c "net stop $serviceName"
            Start-Sleep -Seconds 10
            cmd /c "net start $serviceName"
            Start-Sleep -Seconds 10
            if (Check-ServiceRunning $serviceName) {
                Write-Log "[INFO] Server service is running after scheduled restart."
                Send-Discord "SCUM Restarted" "Server restarted after scheduled restart." 3447003
            } else {
                Write-Log "[ERROR] Server service failed to start after scheduled restart!"
                Send-Discord "SCUM ERROR" "Server service failed to start after scheduled restart!" 15158332
            }
            $global:LastRestartTime = $now.Date.AddHours($now.Hour).AddMinutes($now.Minute)
            $updateOrRestart = $true
        }
    }    # Check if the service is running if there was no update or restart
    if (-not $updateOrRestart) {
        if (-not (Check-ServiceRunning $serviceName)) {
            Write-Log "[WARNING] Server service is not running! Attempting to start..."
            cmd /c "net start $serviceName"
            Start-Sleep -Seconds 10
            if (Check-ServiceRunning $serviceName) {
                Write-Log "[INFO] Server service auto-restarted after crash."
                Send-Discord "Server Auto-Restarted" "The SCUM server service was not running and was automatically restarted after a crash." 15844367
            } else {
                Write-Log "[ERROR] Server service failed to auto-restart!"
                Send-Discord "Auto-Restart Error" "The SCUM server service failed to auto-restart after a crash!" 15158332
            }
        } else {
            # Service is running, no action needed
            Write-Log "[DEBUG] Server service is running normally."
        }
    }
    Start-Sleep -Seconds 30
}