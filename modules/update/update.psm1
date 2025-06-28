# ==========================
# Update Management Module
# ==========================

#Requires -Version 5.1
using module ..\common\common.psm1

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
    Write-Log "[Update] Module initialized"
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
        # First try local appinfo.vdf if exists - using centralized path for SteamCMD if available
        $steamCmdRoot = Get-ConfigPath "steamCmdPath" -ErrorAction SilentlyContinue
        if ($steamCmdRoot) {
            $steamCmdDir = Split-Path $steamCmdRoot -Parent
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
    
    Write-Log "[Update] Starting server update process"
    
    try {
        # Check if service is running and stop it
        if (Test-ServiceRunning $ServiceName) {
            Write-Log "[Update] Stopping server service before update"
            Stop-GameService -ServiceName $ServiceName -Reason "update"
            Start-Sleep -Seconds 10
        }
        else {
            Write-Log "[Update] Service is not running, proceeding with update"
        }
        
        # Resolve paths using centralized management
        $resolvedSteamCmd = Get-ConfigPath "steamCmdPath" -ErrorAction SilentlyContinue
        if (-not $resolvedSteamCmd) {
            $resolvedSteamCmd = $SteamCmdPath
        }
        
        $resolvedServerDir = Get-ConfigPath "serverDirectory" -ErrorAction SilentlyContinue
        if (-not $resolvedServerDir) {
            $resolvedServerDir = $ServerDirectory
        }
        
        # Build SteamCMD command
        $cmd = "`"$resolvedSteamCmd`" +force_install_dir `"$resolvedServerDir`" +login anonymous +app_update $AppId validate +quit"
        Write-Log "[Update] Executing SteamCMD update command"
        
        # Execute update
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $cmd -Wait -NoNewWindow -PassThru
        $exitCode = $process.ExitCode
        
        if ($exitCode -eq 0) {
            Write-Log "[Update] Server update completed successfully"
            
            # Start service after successful update
            Write-Log "[Update] Starting server service after update"
            Start-GameService -ServiceName $ServiceName -Context "update"
            
            # Send success notification with centralized path for build ID lookup
            $newBuild = Get-InstalledBuildId -ServerDirectory $resolvedServerDir -AppId $AppId
            Send-Notification admin "updateCompleted" @{ newBuild = $newBuild }
            
            return $true
        }
        else {
            Write-Log "[Update] Server update failed with exit code: $exitCode" -Level Error
            
            # Send failure notification
            Send-Notification admin "updateFailed" @{ exitCode = $exitCode }
            
            return $false
        }
    }
    catch {
        Write-Log "[Update] Update process failed: $($_.Exception.Message)" -Level Error
        
        # Send failure notification
        Send-Notification admin "updateFailed" @{ error = $_.Exception.Message }
        
        return $false
    }
}

function Invoke-ImmediateUpdate {
    <#
    .SYNOPSIS
    Execute immediate update with notifications
    .PARAMETER SteamCmdPath
    Path to steamcmd.exe
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ServiceName
    Windows service name
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
    
    Write-Log "[Update] Executing immediate update"
    
    # Get current build for notifications
    $currentBuild = Get-InstalledBuildId -ServerDirectory $ServerDirectory -AppId $AppId
    
    # Send update starting notifications
    Send-Notification admin "updateInProgress" @{ currentBuild = $currentBuild }
    Send-Notification player "updateWarning" @{ delayMinutes = 0 }
    
    # Perform update
    $result = Update-GameServer -SteamCmdPath $SteamCmdPath -ServerDirectory $ServerDirectory -AppId $AppId -ServiceName $ServiceName
    
    # Reset scheduling variables
    $global:UpdateScheduledTime = $null
    $global:UpdateWarning5Sent = $false
    $global:UpdateAvailableNotificationSent = $false
    
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
