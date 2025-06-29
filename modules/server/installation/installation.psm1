# ==========================
# Installation Management Module
# ==========================

#Requires -Version 5.1
using module ..\..\core\common\common.psm1
using module ..\..\communication\adapters.psm1

# Module variables
$script:installationConfig = $null

# No additional helper functions needed - using common module functions

function Initialize-InstallationModule {
    <#
    .SYNOPSIS
    Initialize the installation module
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:installationConfig = $Config
    Write-Log "[Installation] Module initialized" -Level Debug
}

function Test-FirstInstall {
    <#
    .SYNOPSIS
    Check if this is a first installation
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .RETURNS
    Boolean indicating if first install is needed
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter(Mandatory)]
        [string]$AppId
    )
    
    # Check for Steam manifest file (most important indicator of complete installation)
    $manifestPath = Join-Path $ServerDirectory "steamapps/appmanifest_$AppId.acf"
    $hasManifest = Test-PathExists $manifestPath
    
    # Check for key server files
    $scumExe = Join-Path $ServerDirectory "SCUM\Binaries\Win64\SCUMServer.exe"
    $hasServerExe = Test-PathExists $scumExe
    
    # Check for saved directory structure
    $savedDir = Join-Path $ServerDirectory "SCUM\Saved"
    $hasSavedDir = Test-PathExists $savedDir
    
    # Check for steamapps directory (indicates Steam installation attempt)
    $steamAppsDir = Join-Path $ServerDirectory "steamapps"
    $hasSteamAppsDir = Test-PathExists $steamAppsDir
    
    # Check for SCUM game directory structure
    $scumGameDir = Join-Path $ServerDirectory "SCUM"
    $hasScumGameDir = Test-PathExists $scumGameDir
    
    # Get SteamCMD path from configuration (with fallback logic)
    $steamCmdPath = $null
    $hasSteamCmd = $false
    $steamCmdExe = ""
    
    # Try to get from cached configuration paths first
    $steamCmdPath = Get-ConfigPath -PathKey "steamCmd" -ErrorAction SilentlyContinue
    
    # If not found in cache, try direct config access with backward compatibility
    if (-not $steamCmdPath) {
        $steamCmdPathConfig = if ($script:installationConfig.SteamCmdPath) { 
            $script:installationConfig.SteamCmdPath 
        } elseif ($script:installationConfig.steamCmd) { 
            $script:installationConfig.steamCmd 
        } else { 
            $null 
        }
        
        if ($steamCmdPathConfig) {
            # Resolve relative paths manually
            if ($steamCmdPathConfig -like "./*") {
                $basePath = $PSScriptRoot
                # Go up to find the root directory
                $parentPath = $basePath
                for ($i = 0; $i -lt 5; $i++) {
                    $parentPath = Split-Path $parentPath -Parent
                    if (Test-Path (Join-Path $parentPath "SCUM-Server-Automation.config.json")) {
                        $basePath = $parentPath
                        break
                    }
                }
                $steamCmdPath = Join-Path $basePath ($steamCmdPathConfig -replace "^\./", "")
            } elseif (-not [System.IO.Path]::IsPathRooted($steamCmdPathConfig)) {
                # Handle other relative paths
                $basePath = $PSScriptRoot
                $parentPath = $basePath
                for ($i = 0; $i -lt 5; $i++) {
                    $parentPath = Split-Path $parentPath -Parent
                    if (Test-Path (Join-Path $parentPath "SCUM-Server-Automation.config.json")) {
                        $basePath = $parentPath
                        break
                    }
                }
                $steamCmdPath = Join-Path $basePath $steamCmdPathConfig
            } else {
                $steamCmdPath = $steamCmdPathConfig
            }
        }
    }
    
    if ($steamCmdPath) {
        $steamCmdExe = if ($steamCmdPath -like "*steamcmd.exe") {
            $steamCmdPath
        } else {
            Join-Path $steamCmdPath "steamcmd.exe"
        }
        $hasSteamCmd = Test-PathExists $steamCmdExe
    }
    
    # CRITICAL: Installation is complete ONLY if ALL essential components exist:
    # 1. Steam manifest file (proves Steam installation completed)
    # 2. Server executable (proves game files are present)
    # 3. Steam apps directory (proves Steam installation structure)
    # 4. SCUM Saved directory (proves server has been run and configured)
    # 5. SteamCMD executable (required for updates and maintenance)
    $isComplete = $hasManifest -and $hasServerExe -and $hasSteamAppsDir -and $hasSavedDir -and $hasSteamCmd
    
    if (-not $isComplete) {
        Write-Log "[Installation] First install required - checking installation status:"
        Write-Log "[Installation]   Steam manifest file: $(if($hasManifest){'✓'}else{'✗'}) $manifestPath"
        Write-Log "[Installation]   Steam apps directory: $(if($hasSteamAppsDir){'✓'}else{'✗'}) $steamAppsDir"
        Write-Log "[Installation]   Server executable: $(if($hasServerExe){'✓'}else{'✗'}) $scumExe"
        Write-Log "[Installation]   SCUM game directory: $(if($hasScumGameDir){'✓'}else{'✗'}) $scumGameDir"
        Write-Log "[Installation]   Saved directory: $(if($hasSavedDir){'✓'}else{'✗'}) $savedDir"
        Write-Log "[Installation]   SteamCMD executable: $(if($hasSteamCmd){'✓'}else{'✗'}) $steamCmdExe"
        
        # Analyze the situation and provide user guidance
        if ($hasManifest -and $hasServerExe -and -not $hasSteamCmd) {
            Write-Log "[Installation] DETECTED: Server files exist but SteamCMD is missing" -Level Warning
            Write-Log "[Installation] SteamCMD is required for server updates and maintenance" -Level Warning
        } elseif ($hasSteamCmd -and -not $hasManifest -and -not $hasServerExe -and -not $hasSteamAppsDir) {
            Write-Log "[Installation] DETECTED: SteamCMD exists but no server files found" -Level Warning
            Write-Log "[Installation] SteamCMD is ready - will download SCUM server files" -Level Warning
        } elseif ($hasSavedDir -and -not $hasManifest -and -not $hasServerExe) {
            Write-Log "[Installation] DETECTED: Only user data exists - Steam server installation required" -Level Warning
            Write-Log "[Installation] This appears to be copied user data without game files" -Level Warning
        } elseif ($hasServerExe -and -not $hasManifest) {
            Write-Log "[Installation] DETECTED: Server executable exists but Steam manifest missing" -Level Warning
            Write-Log "[Installation] Incomplete or corrupted Steam installation - will reinstall" -Level Warning
        } elseif ($hasSteamAppsDir -and -not $hasManifest -and -not $hasServerExe) {
            Write-Log "[Installation] DETECTED: Steam apps directory exists but no game files found" -Level Warning
            Write-Log "[Installation] Incomplete Steam installation - will download server files" -Level Warning
        } elseif ($hasScumGameDir -and -not $hasServerExe) {
            Write-Log "[Installation] DETECTED: SCUM directory exists but server executable missing" -Level Warning
            Write-Log "[Installation] Incomplete game installation - will complete download" -Level Warning
        } elseif (Test-PathExists $ServerDirectory) {
            $dirItems = Get-ChildItem $ServerDirectory -ErrorAction SilentlyContinue
            if ($dirItems -and $dirItems.Count -gt 0) {
                Write-Log "[Installation] DETECTED: Server directory contains files but installation incomplete" -Level Warning
                Write-Log "[Installation] Will preserve existing data and complete installation" -Level Warning
            } else {
                Write-Log "[Installation] DETECTED: Empty server directory - will perform fresh installation" -Level Info
            }
        } else {
            Write-Log "[Installation] DETECTED: No server directory - will perform fresh installation" -Level Info
        }
    } else {
        Write-Log "[Installation] Server installation found and verified complete"
        Write-Log "[Installation] Steam manifest verified: $manifestPath"
    }
    
    return (-not $isComplete)
}

function Install-SteamCmd {
    <#
    .SYNOPSIS
    Download and install SteamCMD if not present
    .PARAMETER SteamCmdPath
    Path to SteamCMD directory or steamcmd.exe
    .RETURNS
    Hashtable with Success and Error properties
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SteamCmdPath
    )
    
    $result = @{ Success = $false; Error = "" }
    
    try {
        # Get the directory part of steamCmd path
        $steamCmdDir = if ($SteamCmdPath -like "*steamcmd.exe") {
            Split-Path $SteamCmdPath -Parent
        } else {
            $SteamCmdPath
        }
        
        $steamCmdExe = Join-Path $steamCmdDir "steamcmd.exe"
        
        # Check if SteamCMD already exists
        if (Test-PathExists $steamCmdExe) {
            Write-Log "[Installation] SteamCMD found at: $steamCmdExe"
            
            # Test if SteamCMD is functional by checking its version
            try {
                $testResult = & $steamCmdExe "+quit" 2>&1
                Write-Log "[Installation] SteamCMD appears to be functional"
                $result.Success = $true
                return $result
            } catch {
                Write-Log "[Installation] WARNING: Existing SteamCMD may be corrupted - will re-download" -Level Warning
                try {
                    Remove-Item $steamCmdExe -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "[Installation] WARNING: Could not remove existing SteamCMD: $($_.Exception.Message)" -Level Warning
                }
            }
        }
        
        Write-Log "[Installation] SteamCMD not found, downloading from Steam..."
        
        # Create SteamCMD directory if it doesn't exist
        if (-not (Test-PathExists $steamCmdDir)) {
            try {
                New-Item -Path $steamCmdDir -ItemType Directory -Force | Out-Null
                Write-Log "[Installation] Created SteamCMD directory: $steamCmdDir"
            } catch {
                $result.Error = "Failed to create SteamCMD directory: $($_.Exception.Message)"
                return $result
            }
        }
        
        # Download SteamCMD
        $steamCmdZipUrl = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
        $steamCmdZipPath = Join-Path $steamCmdDir "steamcmd.zip"
        
        Write-Log "[Installation] Downloading SteamCMD from: $steamCmdZipUrl"
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($steamCmdZipUrl, $steamCmdZipPath)
        Write-Log "[Installation] SteamCMD downloaded successfully"
        
        # Extract SteamCMD
        Write-Log "[Installation] Extracting SteamCMD..."
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($steamCmdZipPath, $steamCmdDir)
        
        # Remove zip file
        Remove-Item $steamCmdZipPath -Force
        Write-Log "[Installation] SteamCMD extracted and ready"
        
        # Verify steamcmd.exe exists
        if (Test-PathExists $steamCmdExe) {
            Write-Log "[Installation] SteamCMD installation verified at: $steamCmdExe"
            $result.Success = $true
        } else {
            $result.Error = "SteamCMD executable not found after extraction"
        }
        
    } catch {
        $result.Error = "Failed to download/extract SteamCMD: $($_.Exception.Message)"
    }
    
    return $result
}

function Initialize-ServerDirectory {
    <#
    .SYNOPSIS
    Create server directory if it doesn't exist
    .PARAMETER ServerDirectory
    Path to server directory
    .RETURNS
    Hashtable with Success and Error properties
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerDirectory
    )
    
    $result = @{ Success = $false; Error = "" }
    
    try {
        if (-not (Test-PathExists $ServerDirectory)) {
            Write-Log "[Installation] Creating server directory: $ServerDirectory"
            New-Item -Path $ServerDirectory -ItemType Directory -Force | Out-Null
            Write-Log "[Installation] Server directory created successfully"
        } else {
            Write-Log "[Installation] Server directory already exists: $ServerDirectory"
        }
        
        $result.Success = $true
        
    } catch {
        $result.Error = "Failed to create server directory: $($_.Exception.Message)"
    }
    
    return $result
}

function Start-FirstTimeServerGeneration {
    <#
    .SYNOPSIS
    Start server briefly to generate configuration files
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER TimeoutSeconds
    Timeout for waiting for config generation
    .RETURNS
    Hashtable with Success and Error properties
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter()]
        [int]$TimeoutSeconds = 120
    )
    
    $result = @{ Success = $false; Error = "" }
    
    try {
        $scumExe = Join-Path $ServerDirectory "SCUM\Binaries\Win64\SCUMServer.exe"
        
        # Essential configuration files that should be generated
        $configDir = Join-Path $ServerDirectory "SCUM\Saved\Config\WindowsServer"
        $essentialConfigFiles = @(
            "ServerSettings.ini",
            "GameUserSettings.ini",
            "AdminUsers.ini",
            "BannedUsers.ini"
        )
        
        $logFile = Join-Path $ServerDirectory "SCUM\Saved\Logs\SCUM.log"
        $saveFilesDir = Join-Path $ServerDirectory "SCUM\Saved\SaveFiles"
        
        if (-not (Test-PathExists $scumExe)) {
            $result.Error = "SCUMServer.exe not found at: $scumExe"
            return $result
        }
        
        Write-Log "[Installation] Launching SCUMServer.exe to generate configuration files..."
        $proc = Start-Process -FilePath $scumExe -ArgumentList "-log" -PassThru
        
        $elapsed = 0
        $allConfigsGenerated = $false
        
        while (-not $allConfigsGenerated -and $elapsed -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 2
            $elapsed += 2
            
            # Check if config directory exists
            $hasConfigDir = Test-PathExists $configDir
            
            # Check essential config files
            $configFilesExist = $true
            if ($hasConfigDir) {
                foreach ($configFile in $essentialConfigFiles) {
                    $configPath = Join-Path $configDir $configFile
                    if (-not (Test-PathExists $configPath)) {
                        $configFilesExist = $false
                        break
                    }
                }
            } else {
                $configFilesExist = $false
            }
            
            # Check other required items
            $hasLogFile = Test-PathExists $logFile
            $hasSaveFilesDir = Test-PathExists $saveFilesDir
            
            $allConfigsGenerated = $hasConfigDir -and $configFilesExist -and $hasLogFile -and $hasSaveFilesDir
        }
        
        if ($allConfigsGenerated) {
            Write-Log "[Installation] All required files and folders have been generated:"
            Write-Log "[Installation]   Config directory: checkmark $configDir"
            foreach ($configFile in $essentialConfigFiles) {
                Write-Log "[Installation]   $configFile : checkmark"
            }
            Write-Log "[Installation]   Log file: checkmark $logFile"
            Write-Log "[Installation]   Save files directory: checkmark $saveFilesDir"
            Write-Log "[Installation] Stopping server."
            $result.Success = $true
        } else {
            Write-Log "[Installation] Not all required files/folders were generated within $TimeoutSeconds seconds:" -Level Warning
            $configDirStatus = if(Test-PathExists $configDir){"checkmark"}else{"cross"}
            Write-Log "[Installation]   Config directory: $configDirStatus $configDir" -Level Warning
            foreach ($configFile in $essentialConfigFiles) {
                $configPath = Join-Path $configDir $configFile
                $fileStatus = if(Test-PathExists $configPath){"checkmark"}else{"cross"}
                Write-Log "[Installation]   $configFile : $fileStatus" -Level Warning
            }
            $logFileStatus = if(Test-PathExists $logFile){"checkmark"}else{"cross"}
            $saveFilesDirStatus = if(Test-PathExists $saveFilesDir){"checkmark"}else{"cross"}
            Write-Log "[Installation]   Log file: $logFileStatus $logFile" -Level Warning
            Write-Log "[Installation]   Save files directory: $saveFilesDirStatus $saveFilesDir" -Level Warning
            Write-Log "[Installation] Stopping server."
            $result.Error = "Configuration generation timeout after $TimeoutSeconds seconds"
        }
        
        # Stop the server process
        if (-not $proc.HasExited) {
            try {
                Stop-Process -Id $proc.Id -Force
                Write-Log "[Installation] SCUMServer.exe has been stopped."
            } catch {
                Write-Log "[Installation] Failed to stop SCUMServer.exe: $($_.Exception.Message)" -Level Warning
            }
        }
        
    } catch {
        $result.Error = "Failed to start server for config generation: $($_.Exception.Message)"
    }
    
    return $result
}

function Invoke-FirstInstall {
    <#
    .SYNOPSIS
    Perform complete first installation of SCUM server
    .PARAMETER SteamCmdPath
    Path to SteamCMD directory or executable
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ServiceName
    Windows service name
    .RETURNS
    Hashtable with Success and Error properties
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
    
    $result = @{ Success = $false; Error = "" }
    
    try {
        Write-Log "[Installation] Starting first install process"
        Send-FirstInstallStartedEvent @{}
        
        # Pre-installation cleanup and validation
        Write-Log "[Installation] Performing pre-installation validation..."
        
        # Check if server directory exists and has content
        if (Test-PathExists $ServerDirectory) {
            $serverDirItems = Get-ChildItem $ServerDirectory -ErrorAction SilentlyContinue
            if ($serverDirItems -and $serverDirItems.Count -gt 0) {
                Write-Log "[Installation] Server directory contains existing files - will attempt to preserve and complete installation" -Level Warning
            }
        }
        
        # Step 1: Install SteamCMD
        Write-Log "[Installation] Step 1/4: Installing SteamCMD..."
        $steamCmdResult = Install-SteamCmd -SteamCmdPath $SteamCmdPath
        if (-not $steamCmdResult.Success) {
            $result.Error = "SteamCMD installation failed: $($steamCmdResult.Error)"
            Send-FirstInstallFailedEvent @{ error = $result.Error }
            return $result
        }
        
        # Step 2: Create server directory
        Write-Log "[Installation] Step 2/4: Preparing server directory..."
        $serverDirResult = Initialize-ServerDirectory -ServerDirectory $ServerDirectory
        if (-not $serverDirResult.Success) {
            $result.Error = "Server directory setup failed: $($serverDirResult.Error)"
            Send-FirstInstallFailedEvent @{ error = $result.Error }
            return $result
        }
        
        # Step 3: Download server files
        Write-Log "[Installation] Step 3/4: Downloading SCUM server files via SteamCMD..."
        
        # Get the directory part of steamCmd path for Update-GameServer
        $steamCmdDirectory = if ($SteamCmdPath -like "*steamcmd.exe") {
            Split-Path $SteamCmdPath -Parent
        } else {
            $SteamCmdPath
        }
        
        $updateResult = Update-GameServer -SteamCmdPath $steamCmdDirectory -ServerDirectory $ServerDirectory -AppId $AppId -ServiceName $ServiceName -SkipServiceStart:$true
        
        if (-not $updateResult.Success) {
            $result.Error = "Server download failed: $($updateResult.Error)"
            Send-FirstInstallFailedEvent @{ error = $result.Error }
            
            # Check if partial download occurred
            $scumExe = Join-Path $ServerDirectory "SCUM\Binaries\Win64\SCUMServer.exe"
            if (Test-PathExists $scumExe) {
                Write-Log "[Installation] Server executable found despite download error - installation may have partially succeeded" -Level Warning
                Write-Log "[Installation] You may want to verify installation manually before proceeding" -Level Warning
            }
            
            return $result
        }
        
        # Verify critical files after download
        $scumExe = Join-Path $ServerDirectory "SCUM\Binaries\Win64\SCUMServer.exe"
        if (-not (Test-PathExists $scumExe)) {
            $result.Error = "Server executable not found after download: $scumExe"
            Send-FirstInstallFailedEvent @{ error = $result.Error }
            return $result
        }
        
        # Step 4: Generate configuration files
        Write-Log "[Installation] Step 4/4: Generating initial configuration files..."
        $configResult = Start-FirstTimeServerGeneration -ServerDirectory $ServerDirectory
        if (-not $configResult.Success) {
            Write-Log "[Installation] Config generation failed: $($configResult.Error)" -Level Warning
            Write-Log "[Installation] This is not critical - you can configure the server manually" -Level Warning
        } else {
            Write-Log "[Installation] Configuration files generated successfully"
        }
        
        # Final verification
        Write-Log "[Installation] Performing final installation verification..."
        $manifestPath = Join-Path $ServerDirectory "steamapps/appmanifest_$AppId.acf"
        $scumExe = Join-Path $ServerDirectory "SCUM\Binaries\Win64\SCUMServer.exe"
        $savedDir = Join-Path $ServerDirectory "SCUM\Saved"
        
        $finalCheck = @{
            "Steam manifest" = Test-PathExists $manifestPath
            "Server executable" = Test-PathExists $scumExe  
            "Saved directory" = Test-PathExists $savedDir
        }
        
        $failedChecks = $finalCheck.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }
        
        if ($failedChecks.Count -gt 0) {
            Write-Log "[Installation] WARNING: Some components may be missing: $($failedChecks -join ', ')" -Level Warning
            Write-Log "[Installation] Installation completed with warnings - manual verification recommended" -Level Warning
        } else {
            Write-Log "[Installation] All components verified successfully"
        }
        
        Write-Log "[Installation] First install completed successfully"
        Send-FirstInstallCompletedEvent @{
            serverDirectory = $ServerDirectory
            steamCmdPath = $SteamCmdPath
        }
        
        $result.Success = $true
        $result.RequireRestart = $true
        
    } catch {
        $result.Error = "First install failed: $($_.Exception.Message)"
        Write-Log "[Installation] $($result.Error)" -Level Error
        Write-Log "[Installation] Error details: $($_.ScriptStackTrace)" -Level Error
        
        # Provide recovery suggestions
        Write-Log "[Installation] Recovery suggestions:" -Level Warning
        Write-Log "[Installation] 1. Check if SteamCMD directory is writable: $(Split-Path $SteamCmdPath -Parent)" -Level Warning
        Write-Log "[Installation] 2. Check if server directory is writable: $ServerDirectory" -Level Warning
        Write-Log "[Installation] 3. Ensure stable internet connection for downloads" -Level Warning
        Write-Log "[Installation] 4. Try running script as Administrator if permission errors occur" -Level Warning
        
        Send-FirstInstallFailedEvent @{ error = $result.Error }
    }
    
    return $result
}

function Get-NextScheduledRestart {
    <#
    .SYNOPSIS
    Calculate next scheduled restart time
    .PARAMETER RestartTimes
    Array of restart times in HH:mm format
    .RETURNS
    DateTime object of next scheduled restart
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$RestartTimes
    )
    
    $now = Get-Date
    $todayRestarts = $RestartTimes | ForEach-Object {
        $t = [datetime]::ParseExact($_, 'HH:mm', $null)
        $scheduled = (Get-Date -Hour $t.Hour -Minute $t.Minute -Second 0)
        if ($scheduled -gt $now) { $scheduled } else { $null }
    } | Where-Object { $_ -ne $null }
    
    if ($todayRestarts.Count -gt 0) {
        return ($todayRestarts | Sort-Object)[0]
    } else {
        # Next day's first restart
        $t = [datetime]::ParseExact($RestartTimes[0], 'HH:mm', $null)
        return ((Get-Date).AddDays(1).Date.AddHours($t.Hour).AddMinutes($t.Minute))
    }
}

function Invoke-ImmediateUpdate {
    <#
    .SYNOPSIS
    Execute immediate server update with backup
    .PARAMETER SteamCmdPath
    Path to SteamCMD directory
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER AppId
    Steam application ID
    .PARAMETER ServiceName
    Windows service name
    .PARAMETER BackupSettings
    Hashtable with backup configuration
    .RETURNS
    Hashtable with Success and Error properties
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
        [hashtable]$BackupSettings = @{}
    )
    
    $result = @{ Success = $false; Error = "" }
    
    try {
        Write-Log "[Installation] Starting immediate update"
        
        # Ensure SteamCMD path is directory format for Update-GameServer
        $steamCmdDirectory = if ($SteamCmdPath -like "*steamcmd.exe") {
            Split-Path $SteamCmdPath -Parent
        } else {
            $SteamCmdPath
        }
        
        # Create backup before update if settings provided
        if ($BackupSettings.Keys.Count -gt 0) {
            Write-Log "[Installation] Creating backup before update"
            $backupResult = Invoke-GameBackup -SourcePath $BackupSettings.SourcePath -BackupRoot $BackupSettings.BackupRoot -MaxBackups $BackupSettings.MaxBackups -CompressBackups $BackupSettings.CompressBackups
            
            if (-not $backupResult) {
                $result.Error = "Pre-update backup failed"
                Send-BackupFailedEvent @{ error = $result.Error }
                return $result
            }
            Write-Log "[Installation] Backup created successfully"
        }
        
        # Stop service if running
        if (Test-ServiceRunning $ServiceName) {
            Stop-GameService -ServiceName $ServiceName -Reason "update"
        }
        
        # Perform update
        $updateResult = Update-GameServer -SteamCmdPath $steamCmdDirectory -ServerDirectory $ServerDirectory -AppId $AppId -ServiceName $ServiceName
        
        if ($updateResult.Success) {
            Write-Log "[Installation] Server updated successfully"
            Send-UpdateCompletedEvent @{}
            
            # Start service after update
            Start-GameService -ServiceName $ServiceName -Context "post-update"
            $result.Success = $true
        } else {
            $result.Error = "Update failed: $($updateResult.Error)"
            Send-UpdateFailedEvent @{ error = $result.Error }
        }
        
    } catch {
        $result.Error = "Update process failed: $($_.Exception.Message)"
        Write-Log "[Installation] $($result.Error)" -Level Error
        Send-UpdateFailedEvent @{ error = $result.Error }
    }
    
    return $result
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-InstallationModule',
    'Test-FirstInstall',
    'Install-SteamCmd',
    'Initialize-ServerDirectory',
    'Start-FirstTimeServerGeneration',
    'Invoke-FirstInstall',
    'Get-NextScheduledRestart',
    'Invoke-ImmediateUpdate'
)
