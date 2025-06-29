# ==========================
# Update Management Module
# ==========================

#Requires -Version 5.1
using module ..\..\core\common\common.psm1
using module ..\..\communication\adapters.psm1

# Module variables
$script:updateConfig = $null

function Initialize-UpdateModule {
    <#
    .SYNOPSIS
    Initialize the update module
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:updateConfig = $Config
    Write-Log "[Update] Module initialized" -Level Debug
}

function Get-InstalledBuildId {
    <#
    .SYNOPSIS
    Get installed build ID from Steam manifest
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter(Mandatory)]
        [string]$AppId
    )
    
    $manifestPath = Join-Path $ServerDirectory "steamapps/appmanifest_$AppId.acf"
    
    if (-not (Test-PathExists $manifestPath)) {
        Write-Log "[Update] Manifest file not found: $manifestPath"
        return $null
    }
    
    try {
        $content = Get-Content $manifestPath -Raw
        if ($content -match '"buildid"\s+"(\d+)"') {
            return $matches[1]
        }
        else {
            Write-Log "[Update] buildid not found in manifest" -Level Warning
            return $null
        }
    }
    catch {
        Write-Log "[Update] Failed to read manifest: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Get-LatestBuildId {
    <#
    .SYNOPSIS
    Query Steam for latest build ID
    .PARAMETER SteamCmdPath
    Path to steamcmd.exe
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ScriptRoot
    Script root directory
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SteamCmdPath,
        
        [Parameter(Mandatory)]
        [string]$AppId,
        
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )
    
    try {
        # First try local appinfo.vdf if exists - use the provided SteamCmdPath
        if ($SteamCmdPath -and (Test-Path $SteamCmdPath)) {
            $steamCmdDir = Split-Path $SteamCmdPath -Parent
            $vdfPath = Join-Path $steamCmdDir "steamapps\appinfo.vdf"
        } else {
            $vdfPath = Join-Path $ScriptRoot "steamcmd\steamapps\appinfo.vdf"
        }
        if (Test-PathExists $vdfPath) {
            try {
                $vdfContent = Get-Content $vdfPath -Raw
                if ($vdfContent -match '"buildid"\s+"(\d+)"') {
                    Write-Log "[Update] Found build ID in local appinfo.vdf: $($matches[1])"
                    return $matches[1]
                }
            }
            catch {
                Write-Log "[Update] Failed to read local appinfo.vdf: $($_.Exception.Message)"
            }
        }
        
        # Fallback: use SteamCMD to get latest
        Write-Log "[Update] Using SteamCMD to check latest build"
        
        $tempFile = Join-Path $env:TEMP "steamcmd_output_$(Get-Random).txt"
        try {
            $cmd = "`"$SteamCmdPath`" +login anonymous +app_info_update 1 +app_info_print $AppId +quit"
            $result = cmd /c $cmd 2>`&1
            
            if ($result) {
                # Parse SteamCMD output for build ID
                $buildIdPattern = '"buildid"\s+"(\d+)"'
                $allOutput = $result -join "`n"
                
                # Try multiple patterns for different SteamCMD output formats
                if ($allOutput -match $buildIdPattern) {
                    Write-Log "[Update] Found latest build ID: $($matches[1])"
                    return $matches[1]
                }
                
                # Alternative pattern
                if ($allOutput -match 'buildid.*?(\d{8,})') {
                    Write-Log "[Update] Found latest build ID (alt pattern): $($matches[1])"
                    return $matches[1]
                }
            }
            
            # If SteamCMD fails, try to get from installed version and assume no update
            $installedBuild = Get-InstalledBuildId -ServerDirectory $ServerDirectory -AppId $AppId
            if ($installedBuild) {
                Write-Log "[Update] SteamCMD failed, using installed build ID as latest: $installedBuild" -Level Warning
                return $installedBuild
            }
        }
        finally {
            if (Test-Path $tempFile) {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
        
        Write-Log "[Update] Could not determine latest build ID" -Level Warning
        return $null
    }
    catch {
        Write-Log "[Update] Error getting latest build ID: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Test-UpdateAvailable {
    <#
    .SYNOPSIS
    Check if update is available
    .PARAMETER SteamCmdPath
    Path to steamcmd.exe
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ScriptRoot
    Script root directory
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SteamCmdPath,
        
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter(Mandatory)]
        [string]$AppId,
        
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )
    
    try {
        $installedBuild = Get-InstalledBuildId -ServerDirectory $ServerDirectory -AppId $AppId
        $latestBuild = Get-LatestBuildId -SteamCmdPath $SteamCmdPath -AppId $AppId -ScriptRoot $ScriptRoot
        
        return @{
            InstalledBuild = $installedBuild
            LatestBuild = $latestBuild
            UpdateAvailable = ($null -ne $installedBuild -and $null -ne $latestBuild -and $installedBuild -ne $latestBuild)
        }
    }
    catch {
        Write-Log "[Update] Error checking for updates: $($_.Exception.Message)" -Level Error
        return @{
            InstalledBuild = $null
            LatestBuild = $null
            UpdateAvailable = $false
            Error = $_.Exception.Message
        }
    }
}

function Update-GameServer {
    <#
    .SYNOPSIS
    Update SCUM server using SteamCMD
    .PARAMETER SteamCmdPath
    Path to steamcmd.exe
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ServiceName
    Windows service name
    .PARAMETER SkipServiceStart
    If true, do not start the service or send related notifications after update (used for first install)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SteamCmdPath,
        
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter(Mandatory)]
        [string]$AppId,
        
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter()]
        [bool]$SkipServiceStart = $false
    )
    
    Write-Log "[Update] Starting server update process"
    
    try {
        if (-not $SkipServiceStart) {
            # Check if service is running and stop it
            if (Test-ServiceRunning $ServiceName) {
                Write-Log "[Update] Stopping server service before update"
                Stop-GameService -ServiceName $ServiceName -Reason "update"
                Start-Sleep -Seconds 10
            }
            else {
                Write-Log "[Update] Service is not running, proceeding with update"
            }
        } else {
            Write-Log "[Update] Skipping service status checks due to SkipServiceStart flag"
        }
        
        # Resolve paths - use provided parameters directly
        $resolvedSteamCmd = $SteamCmdPath
        $resolvedServerDir = $ServerDirectory
        
        # Ensure SteamCMD path includes the executable
        if (-not $resolvedSteamCmd.EndsWith("steamcmd.exe")) {
            $resolvedSteamCmd = Join-Path $resolvedSteamCmd "steamcmd.exe"
        }
        
        # Convert to absolute paths
        $resolvedSteamCmd = [System.IO.Path]::GetFullPath($resolvedSteamCmd)
        $resolvedServerDir = [System.IO.Path]::GetFullPath($resolvedServerDir)
        
        # Verify SteamCMD exists
        if (-not (Test-Path $resolvedSteamCmd)) {
            throw "SteamCMD not found at: $resolvedSteamCmd"
        }
        
        Write-Log "[Update] SteamCMD path verified: $resolvedSteamCmd"
        Write-Log "[Update] Server directory: $resolvedServerDir"
        
        # Create server directory if it doesn't exist
        if (-not (Test-Path $resolvedServerDir)) {
            New-Item -Path $resolvedServerDir -ItemType Directory -Force | Out-Null
            Write-Log "[Update] Created server directory: $resolvedServerDir"
        }
        
        # Build SteamCMD arguments (fix quoting for paths with spaces)
        $steamCmdArgs = @(
            "+force_install_dir"
            $resolvedServerDir
            "+login"
            "anonymous"
            "+app_update"
            $AppId
            "validate"
            "+quit"
        )
        
        Write-Log "[Update] Executing SteamCMD update command"
        Write-Log "[Update] SteamCMD: $resolvedSteamCmd"
        Write-Log "[Update] Arguments: $($steamCmdArgs -join ' ')"
        
        # Check if this is first run of SteamCMD (might need to accept EULA)
        $steamCmdDir = Split-Path $resolvedSteamCmd -Parent
        $steamCmdLogPath = Join-Path $steamCmdDir "logs"
        if (-not (Test-Path $steamCmdLogPath)) {
            Write-Log "[Update] First SteamCMD run detected, may take longer for initialization"
        }
        
        # Execute update directly
        try {
            $process = Start-Process -FilePath $resolvedSteamCmd -ArgumentList $steamCmdArgs -Wait -NoNewWindow -PassThru -WorkingDirectory $steamCmdDir
            $exitCode = $process.ExitCode
        } catch {
            Write-Log "[Update] Failed to start SteamCMD: $($_.Exception.Message)" -Level Error
            throw "Failed to execute SteamCMD: $($_.Exception.Message)"
        }
        
        if ($exitCode -eq 0 -or $exitCode -eq 7) {
            if ($exitCode -eq 7) {
                Write-Log "[Update] Server update completed with warnings (exit code 7)"
            } else {
                Write-Log "[Update] Server update completed successfully"
            }
            
            # Give SteamCMD a moment to finalize file operations
            Start-Sleep -Seconds 2
            
            # Verify installation by checking for server executable in correct path
            $scumExePath = Join-Path $resolvedServerDir "SCUM\Binaries\Win64\SCUMServer.exe"
            $serverFound = Test-Path $scumExePath
            
            if ($serverFound) {
                Write-Log "[Update] Server executable found: $scumExePath"
            } else {
                Write-Log "[Update] Server executable not found at expected path: $scumExePath"
                
                # Fallback - check for legacy locations
                $serverExecutables = @("SCUMServerEXE.exe", "SCUM_Server.exe", "SCUMServer.exe")
                
                foreach ($exe in $serverExecutables) {
                    $exePath = Join-Path $resolvedServerDir $exe
                    if (Test-Path $exePath) {
                        Write-Log "[Update] Server executable found at legacy location: $exePath"
                        $serverFound = $true
                        break
                    }
                }
                
                # If still not found, list what's actually in the directory for diagnostics
                if (-not $serverFound) {
                    $scumBinariesDir = Join-Path $resolvedServerDir "SCUM\Binaries\Win64"
                    if (Test-Path $scumBinariesDir) {
                        $files = Get-ChildItem -Path $scumBinariesDir -Filter "*.exe" -ErrorAction SilentlyContinue
                        if ($files) {
                            Write-Log "[Update] Found executables in SCUM\Binaries\Win64: $($files.Name -join ', ')"
                        } else {
                            Write-Log "[Update] No executables found in SCUM\Binaries\Win64 directory"
                        }
                    } else {
                        Write-Log "[Update] SCUM\Binaries\Win64 directory does not exist"
                    }
                }
            }
            
            if (-not $serverFound) {
                Write-Log "[Update] Warning: No server executable found in installation directory" -Level Warning
                Write-Log "[Update] This may be normal for some installation states - continuing anyway" -Level Info
            }
            
            if (-not $SkipServiceStart) {
                # Start service after successful update
                Write-Log "[Update] Starting server service after update"
                Start-GameService -ServiceName $ServiceName -Context "update"
                
                # Send success notification with centralized path for build ID lookup
                $newBuild = Get-InstalledBuildId -ServerDirectory $resolvedServerDir -AppId $AppId
                Send-UpdateCompletedEvent @{ newBuild = $newBuild }
            } else {
                Write-Log "[Update] Skipping service start and notifications due to SkipServiceStart flag"
            }
            
            return @{ Success = $true; Error = $null }
        }
        else {
            Write-Log "[Update] Server update failed with exit code: $exitCode" -Level Error
            Write-Log "[Update] Common SteamCMD exit codes: 1=General error, 2=Invalid arguments, 5=Cannot write to directory, 6=Steam client not running, 7=Success with warnings" -Level Error
            
            # Check for common issues
            if ($exitCode -eq 5) {
                Write-Log "[Update] Exit code 5 suggests permission or disk space issues" -Level Error
            } elseif ($exitCode -eq 2) {
                Write-Log "[Update] Exit code 2 suggests invalid command arguments" -Level Error
            } elseif ($exitCode -eq 7) {
                Write-Log "[Update] Exit code 7 usually means success with warnings, but treating as error due to context" -Level Error
            }
            
            # Send failure notification
            Send-UpdateFailedEvent @{ exitCode = $exitCode }
            
            return @{ Success = $false; Error = "SteamCMD failed with exit code: $exitCode" }
        }
    }
    catch {
        Write-Log "[Update] Update process failed: $($_.Exception.Message)" -Level Error
        
        # Send failure notification
        Send-UpdateFailedEvent @{ error = $_.Exception.Message }
        
        return @{ Success = $false; Error = $_.Exception.Message }
    }
}

function Invoke-ImmediateUpdate {
    <#
    .SYNOPSIS
    Execute immediate update with backup and service management
    .PARAMETER SteamCmdPath
    Path to steamcmd.exe directory
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ServiceName
    Windows service name
    .RETURNS
    Hashtable with operation result
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SteamCmdPath,
        
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter(Mandatory)]
        [string]$AppId,
        
        [Parameter(Mandatory)]
        [string]$ServiceName
    )
    
    Write-Log "[Update] Starting immediate update process"
    
    $result = @{
        Success = $false
        Error = $null
        BackupCreated = $false
        UpdateCompleted = $false
        ServiceRestarted = $false
    }
    
    try {
        # Ensure SteamCMD path is directory format for Update-GameServer
        $steamCmdDirectory = if ($SteamCmdPath -like "*steamcmd.exe") {
            Split-Path $SteamCmdPath -Parent
        } else {
            $SteamCmdPath
        }
        
        # Get paths from centralized management
        $savedDir = Get-ConfigPath -PathKey "savedDir" -ErrorAction SilentlyContinue
        $backupRoot = Get-ConfigPath -PathKey "backupRoot" -ErrorAction SilentlyContinue
        $maxBackups = Get-SafeConfigValue $script:updateConfig "maxBackups" 10
        $compressBackups = Get-SafeConfigValue $script:updateConfig "compressBackups" $true
        
        # Create backup before update
        if ($savedDir -and $backupRoot) {
            Write-Log "[Update] Creating backup before update"
            $backupResult = Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $maxBackups -CompressBackups $compressBackups
            
            if ($backupResult) {
                Write-Log "[Update] Backup created successfully"
                $result.BackupCreated = $true
            } else {
                Write-Log "[Update] Backup failed, continuing with update anyway" -Level Warning
            }
        } else {
            Write-Log "[Update] Backup paths not available, skipping backup" -Level Warning
        }
        
        # Stop service if running
        if (Test-ServiceRunning $ServiceName) {
            Write-Log "[Update] Stopping service for update"
            Stop-GameService -ServiceName $ServiceName -Reason "update"
            
            # Wait a moment for service to stop
            Start-Sleep -Seconds 3
        }
        
        # Perform update
        Write-Log "[Update] Performing server update"
        $updateResult = Update-GameServer -SteamCmdPath $steamCmdDirectory -ServerDirectory $ServerDirectory -AppId $AppId -ServiceName $ServiceName
        
        if ($updateResult.Success) {
            Write-Log "[Update] Server updated successfully"
            Send-UpdateCompletedEvent @{
            }
            $result.UpdateCompleted = $true
            
            # Start service after update
            Write-Log "[Update] Starting service after update"
            Start-GameService -ServiceName $ServiceName -Context "post-update"
            $result.ServiceRestarted = $true
            $result.Success = $true
            
        } else {
            $result.Error = $updateResult.Error
            Write-Log "[Update] Update failed: $($result.Error)" -Level Error
            Send-UpdateFailedEvent @{ error = $result.Error }
            
            # Try to start service anyway
            if (-not (Test-ServiceRunning $ServiceName)) {
                Write-Log "[Update] Attempting to start service after failed update"
                Start-GameService -ServiceName $ServiceName -Context "post-failed-update"
            }
        }
        
    } catch {
        $result.Error = $_.Exception.Message
        Write-Log "[Update] Immediate update failed: $($result.Error)" -Level Error
        Send-UpdateFailedEvent @{ error = $result.Error }
        
        # Try to start service if it's not running
        if (-not (Test-ServiceRunning $ServiceName)) {
            Write-Log "[Update] Attempting to start service after update exception"
            Start-GameService -ServiceName $ServiceName -Context "post-exception"
        }
    }
    
    return $result
}

function Get-UpdateStatus {
    <#
    .SYNOPSIS
    Get current update status and information
    .PARAMETER SteamCmdPath
    Path to steamcmd.exe
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ScriptRoot
    Script root directory
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SteamCmdPath,
        
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter(Mandatory)]
        [string]$AppId,
        
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )
    
    try {
        $updateCheck = Test-UpdateAvailable -SteamCmdPath $SteamCmdPath -ServerDirectory $ServerDirectory -AppId $AppId -ScriptRoot $ScriptRoot
        
        return @{
            InstalledBuild = $updateCheck.InstalledBuild
            LatestBuild = $updateCheck.LatestBuild
            UpdateAvailable = $updateCheck.UpdateAvailable
            LastCheck = Get-Date
            Status = if ($updateCheck.UpdateAvailable) { "Update Available" } else { "Up to Date" }
        }
    }
    catch {
        Write-Log "[Update] Failed to get update status: $($_.Exception.Message)" -Level Error
        return @{
            Status = "Error"
            Error = $_.Exception.Message
            LastCheck = Get-Date
        }
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-UpdateModule',
    'Get-InstalledBuildId',
    'Get-LatestBuildId',
    'Test-UpdateAvailable',
    'Update-GameServer',
    'Invoke-ImmediateUpdate',
    'Get-UpdateStatus'
)
