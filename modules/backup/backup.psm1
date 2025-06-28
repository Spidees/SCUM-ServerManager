# ==========================
# Backup Management Module
# ==========================

#Requires -Version 5.1
using module ..\common\common.psm1

# Module variables
$script:backupConfig = $null

function Initialize-BackupModule {
    <#
    .SYNOPSIS
    Initialize the backup module
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:backupConfig = $Config
    Write-Log "[Backup] Module initialized"
}

function Invoke-GameBackup {
    <#
    .SYNOPSIS
    Create backup of SCUM server saved data
    .PARAMETER SourcePath
    Source directory to backup (Saved folder)
    .PARAMETER BackupRoot
    Root directory for backups
    .PARAMETER MaxBackups
    Maximum number of backups to keep
    .PARAMETER CompressBackups
    Whether to compress backups
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        
        [Parameter()]
        [int]$MaxBackups = 10,
        
        [Parameter()]
        [bool]$CompressBackups = $true
    )
    
    Write-Log "[Backup] Starting backup process"
    
    # Resolve paths using centralized management if available
    $resolvedSourcePath = Get-ConfigPath "serverSavedPath" -ErrorAction SilentlyContinue
    if (-not $resolvedSourcePath) {
        $resolvedSourcePath = $SourcePath
    }
    
    $resolvedBackupRoot = Get-ConfigPath "backupDirectory" -ErrorAction SilentlyContinue
    if (-not $resolvedBackupRoot) {
        $resolvedBackupRoot = $BackupRoot
    }
    
    # Validate source path
    if (-not (Test-PathExists $resolvedSourcePath)) {
        Write-Log "[Backup] Source path does not exist: $resolvedSourcePath" -Level Error
        return $false
    }
    
    # Ensure backup root exists
    if (-not (Test-PathExists $resolvedBackupRoot)) {
        try {
            New-Item -Path $resolvedBackupRoot -ItemType Directory -Force | Out-Null
            Write-Log "[Backup] Created backup root directory: $resolvedBackupRoot"
        }
        catch {
            Write-Log "[Backup] Failed to create backup root: $($_.Exception.Message)" -Level Error
            return $false
        }
    }
    
    # Generate backup filename
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupName = "SCUM_Saved_BACKUP_$timestamp"
    $backupPath = Join-Path $resolvedBackupRoot $backupName
    
    try {
        if ($CompressBackups) {
            # Create compressed backup
            $zipPath = "$backupPath.zip"
            Write-Log "[Backup] Creating compressed backup: $zipPath"
            
            # Use PowerShell's Compress-Archive with exclusions for locked files
            try {
                # Get all items except potentially locked log files
                $itemsToBackup = Get-ChildItem -Path $resolvedSourcePath -Recurse | Where-Object { 
                    -not ($_.Name -eq "SCUM.log" -and $_.Directory.Name -eq "Logs") 
                }
                
                if ($itemsToBackup.Count -gt 0) {
                    # Create temporary directory structure for backup
                    $tempBackupDir = Join-Path $env:TEMP "SCUMBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    New-Item -ItemType Directory -Path $tempBackupDir -Force | Out-Null
                    
                    # Copy items safely, skipping locked files
                    foreach ($item in $itemsToBackup) {
                        $relativePath = $item.FullName.Substring($resolvedSourcePath.Length + 1)
                        $destPath = Join-Path $tempBackupDir $relativePath
                        $destDir = Split-Path $destPath -Parent
                        
                        if (-not (Test-Path $destDir)) {
                            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                        }
                        
                        try {
                            if ($item.PSIsContainer) {
                                if (-not (Test-Path $destPath)) {
                                    New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                                }
                            } else {
                                Copy-Item -Path $item.FullName -Destination $destPath -Force
                            }
                        } catch {
                            Write-Log "[Backup] Skipping locked file: $($item.Name)" -Level Warning
                        }
                    }
                    
                    # Create archive from temp directory
                    Compress-Archive -Path "$tempBackupDir\*" -DestinationPath $zipPath -CompressionLevel Optimal -Force
                    
                    # Clean up temp directory
                    Remove-Item -Path $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
                } else {
                    throw "No files available for backup"
                }
            } catch {
                # Fallback: try backup excluding the active log file
                Write-Log "[Backup] Primary backup failed, trying fallback method" -Level Warning
                Write-Log "[Backup] Fallback error: $($_.Exception.Message)" -Level Debug
                
                try {
                    # Create a copy of the source directory structure excluding active logs
                    $tempBackupDir = Join-Path $env:TEMP "SCUMBackup_Fallback_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    New-Item -ItemType Directory -Path $tempBackupDir -Force | Out-Null
                    
                    # Use robocopy to exclude locked files
                    $robocopyArgs = @(
                        $resolvedSourcePath, 
                        $tempBackupDir, 
                        "/E", 
                        "/R:0", 
                        "/W:0", 
                        "/XF", "SCUM.log",
                        "/NP", 
                        "/NJH", 
                        "/NJS"
                    )
                    
                    $robocopyResult = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru
                    
                    # Robocopy exit codes 0-7 are success (0=no files, 1=files copied, etc.)
                    if ($robocopyResult.ExitCode -le 7) {
                        # Create archive from robocopy result
                        Compress-Archive -Path "$tempBackupDir\*" -DestinationPath $zipPath -CompressionLevel Optimal -Force
                        Remove-Item -Path $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log "[Backup] Fallback backup completed successfully" -Level Info
                    } else {
                        throw "Robocopy failed with exit code: $($robocopyResult.ExitCode)"
                    }
                } catch {
                    # Final fallback: manual copy with error handling
                    Write-Log "[Backup] Robocopy fallback failed, trying manual copy" -Level Warning
                    
                    $tempBackupDir = Join-Path $env:TEMP "SCUMBackup_Manual_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    New-Item -ItemType Directory -Path $tempBackupDir -Force | Out-Null
                    
                    Get-ChildItem -Path $resolvedSourcePath -Recurse | ForEach-Object {
                        $relativePath = $_.FullName.Substring($resolvedSourcePath.Length + 1)
                        $destPath = Join-Path $tempBackupDir $relativePath
                        
                        if ($_.PSIsContainer) {
                            New-Item -ItemType Directory -Path $destPath -Force -ErrorAction SilentlyContinue | Out-Null
                        } else {
                            # Skip known problematic files
                            if ($_.Name -eq "SCUM.log" -and $_.Directory.Name -eq "Logs") {
                                Write-Log "[Backup] Skipping active log file: $($_.Name)" -Level Debug
                                return
                            }
                            
                            try {
                                $destDir = Split-Path $destPath -Parent
                                if (-not (Test-Path $destDir)) {
                                    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                                }
                                Copy-Item -Path $_.FullName -Destination $destPath -Force
                            } catch {
                                Write-Log "[Backup] Skipping locked file: $($_.Name)" -Level Debug
                            }
                        }
                    }
                    
                    # Create final archive
                    if ((Get-ChildItem $tempBackupDir -Recurse).Count -gt 0) {
                        Compress-Archive -Path "$tempBackupDir\*" -DestinationPath $zipPath -CompressionLevel Optimal -Force
                        Remove-Item -Path $tempBackupDir -Recurse -Force -ErrorAction SilentlyContinue
                        Write-Log "[Backup] Manual fallback backup completed" -Level Info
                    } else {
                        throw "No files were successfully copied for backup"
                    }
                }
            }
            
            $backupSize = (Get-Item $zipPath).Length
            $backupSizeText = ConvertTo-HumanReadableSize $backupSize
            
            Write-Log "[Backup] Compressed backup created successfully: $backupSizeText"
            
            # Send success notification
            Send-Notification admin "backupCompleted" @{
                backupFile = Split-Path $zipPath -Leaf
                backupSize = $backupSizeText
            }
        }
        else {
            # Create uncompressed backup
            Write-Log "[Backup] Creating uncompressed backup: $backupPath"
            
            Copy-Item -Path $resolvedSourcePath -Destination $backupPath -Recurse -Force
            
            $backupSize = (Get-ChildItem $backupPath -Recurse | Measure-Object -Property Length -Sum).Sum
            $backupSizeText = ConvertTo-HumanReadableSize $backupSize
            
            Write-Log "[Backup] Uncompressed backup created successfully: $backupSizeText"
            
            # Send success notification
            Send-Notification admin "backupCompleted" @{
                backupFile = Split-Path $backupPath -Leaf
                backupSize = $backupSizeText
            }
        }
        
        # Clean up old backups
        Remove-OldBackups -BackupRoot $resolvedBackupRoot -MaxBackups $MaxBackups
        
        return $true
    }
    catch {
        Write-Log "[Backup] Backup failed: $($_.Exception.Message)" -Level Error
        
        # Send failure notification
        Send-Notification admin "backupFailed" @{
            error = $_.Exception.Message
        }
        
        return $false
    }
}

function Remove-OldBackups {
    <#
    .SYNOPSIS
    Remove old backup files to maintain backup count limit
    .PARAMETER BackupRoot
    Root directory containing backups
    .PARAMETER MaxBackups
    Maximum number of backups to keep
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        
        [Parameter()]
        [int]$MaxBackups = 10
    )
    
    try {
        if (-not (Test-PathExists $BackupRoot)) {
            return
        }
        
        # Get all backup files/folders sorted by creation time (newest first)
        $backupItems = Get-ChildItem -Path $BackupRoot -Name "SCUM_Saved_BACKUP_*" | 
                      ForEach-Object { Get-Item (Join-Path $BackupRoot $_) } |
                      Sort-Object CreationTime -Descending
        
        if ($backupItems.Count -le $MaxBackups) {
            Write-Log "[Backup] No cleanup needed ($($backupItems.Count)/$MaxBackups backups)"
            return
        }
        
        # Remove excess backups
        $toRemove = $backupItems | Select-Object -Skip $MaxBackups
        $removedCount = 0
        $freedSpace = 0
        
        foreach ($item in $toRemove) {
            try {
                if ($item.PSIsContainer) {
                    $itemSize = (Get-ChildItem $item.FullName -Recurse | Measure-Object -Property Length -Sum).Sum
                    Remove-Item $item.FullName -Recurse -Force
                }
                else {
                    $itemSize = $item.Length
                    Remove-Item $item.FullName -Force
                }
                
                $freedSpace += $itemSize
                $removedCount++
                
                Write-Log "[Backup] Removed old backup: $($item.Name)"
            }
            catch {
                Write-Log "[Backup] Failed to remove backup '$($item.Name)': $($_.Exception.Message)" -Level Warning
            }
        }
        
        if ($removedCount -gt 0) {
            $freedSpaceText = ConvertTo-HumanReadableSize $freedSpace
            Write-Log "[Backup] Cleanup completed: Removed $removedCount backups, freed $freedSpaceText"
        }
    }
    catch {
        Write-Log "[Backup] Backup cleanup failed: $($_.Exception.Message)" -Level Warning
    }
}

function Get-BackupStatistics {
    <#
    .SYNOPSIS
    Get backup statistics and information
    .PARAMETER BackupRoot
    Root directory containing backups
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BackupRoot
    )
    
    try {
        if (-not (Test-PathExists $BackupRoot)) {
            return @{
                BackupCount = 0
                TotalSize = 0
                TotalSizeText = "0 B"
                LatestBackup = $null
                OldestBackup = $null
            }
        }
        
        $backupItems = Get-ChildItem -Path $BackupRoot -Name "SCUM_Saved_BACKUP_*" | 
                      ForEach-Object { Get-Item (Join-Path $BackupRoot $_) }
        
        if ($backupItems.Count -eq 0) {
            return @{
                BackupCount = 0
                TotalSize = 0
                TotalSizeText = "0 B"
                LatestBackup = $null
                OldestBackup = $null
            }
        }
        
        $totalSize = 0
        foreach ($item in $backupItems) {
            if ($item.PSIsContainer) {
                $totalSize += (Get-ChildItem $item.FullName -Recurse | Measure-Object -Property Length -Sum).Sum
            }
            else {
                $totalSize += $item.Length
            }
        }
        
        $sortedByDate = $backupItems | Sort-Object CreationTime
        
        return @{
            BackupCount = $backupItems.Count
            TotalSize = $totalSize
            TotalSizeText = ConvertTo-HumanReadableSize $totalSize
            LatestBackup = $sortedByDate[-1]
            OldestBackup = $sortedByDate[0]
        }
    }
    catch {
        Write-Log "[Backup] Failed to get backup statistics: $($_.Exception.Message)" -Level Error
        return @{
            BackupCount = 0
            TotalSize = 0
            TotalSizeText = "Error"
            LatestBackup = $null
            OldestBackup = $null
            Error = $_.Exception.Message
        }
    }
}

function Test-BackupIntegrity {
    <#
    .SYNOPSIS
    Test backup integrity (for compressed backups)
    .PARAMETER BackupPath
    Path to backup file
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BackupPath
    )
    
    try {
        if (-not (Test-PathExists $BackupPath)) {
            return $false
        }
        
        if ($BackupPath -like "*.zip") {
            # Test ZIP integrity
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [System.IO.Compression.ZipFile]::OpenRead($BackupPath)
            $entryCount = $zip.Entries.Count
            $zip.Dispose()
            
            Write-Log "[Backup] Backup integrity test passed: $entryCount entries in $BackupPath"
            return $true
        }
        else {
            # For uncompressed backups, just check if directory exists and has content
            $itemCount = (Get-ChildItem $BackupPath -Recurse).Count
            Write-Log "[Backup] Backup integrity test passed: $itemCount items in $BackupPath"
            return $true
        }
    }
    catch {
        Write-Log "[Backup] Backup integrity test failed for '$BackupPath': $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-BackupModule',
    'Invoke-GameBackup',
    'Remove-OldBackups',
    'Get-BackupStatistics',
    'Test-BackupIntegrity'
)
