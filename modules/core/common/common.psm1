# ==========================
# Common Utilities Module
# ==========================

#Requires -Version 5.1

# Module configuration
$script:logPath = $null
$script:config = $null
$script:ConfigPaths = @{}
$script:RootPath = $null

function Initialize-CommonModule {
    <#
    .SYNOPSIS
    Initialize the common module with configuration and path caching
    .PARAMETER Config
    Configuration object
    .PARAMETER LogPath
    Path to log file
    .PARAMETER RootPath
    Root path for resolving relative paths (defaults to script root)
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        
        [Parameter()]
        [string]$LogPath,
        
        [Parameter()]
        [string]$RootPath
    )
    
    $script:config = $Config
    $script:logPath = $LogPath
    $script:RootPath = if ($RootPath) { $RootPath } else { $PSScriptRoot }
    
    # Initialize centralized path cache
    Initialize-ConfigPaths -Config $Config
    
    Write-Verbose "[Common] Module initialized with path caching"
    Write-Log "[Common] Cached paths: savedDir=$($script:ConfigPaths.savedDir), backupRoot=$($script:ConfigPaths.backupRoot)"
}

function Initialize-ConfigPaths {
    <#
    .SYNOPSIS
    Initialize and cache all configuration paths
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    # Pre-calculate and cache all paths to avoid repeated processing
    $script:ConfigPaths = @{
        savedDir = if ($Config.savedDir) { Resolve-ConfigPath -Path $Config.savedDir } else { $null }
        backupRoot = if ($Config.backupRoot) { Resolve-ConfigPath -Path $Config.backupRoot } else { $null }
        steamCmd = if ($Config.steamCmd) { 
            Resolve-ConfigPath -Path $Config.steamCmd
        } else { 
            $null 
        }
        serverDir = if ($Config.serverDir) { Resolve-ConfigPath -Path $Config.serverDir } else { $null }
        logFile = if ($script:logPath) { $script:logPath } else { $null }
    }
    
    # Add derived paths that are commonly used
    if ($script:ConfigPaths.savedDir) {
        $script:ConfigPaths.logPath = Join-Path $script:ConfigPaths.savedDir "Logs\SCUM.log"
        $script:ConfigPaths.serverSavedPath = $script:ConfigPaths.savedDir
    }
    
    if ($script:ConfigPaths.backupRoot) {
        $script:ConfigPaths.backupDirectory = $script:ConfigPaths.backupRoot
    }
    
    if ($script:ConfigPaths.steamCmdPath) {
        $script:ConfigPaths.steamCmd = $script:ConfigPaths.steamCmdPath
    } elseif ($script:ConfigPaths.steamCmd) {
        $script:ConfigPaths.steamCmdPath = $script:ConfigPaths.steamCmd
    }
    
    # Add any additional paths from config
    $additionalPaths = @('customLogPath', 'tempDir', 'configDir')
    foreach ($pathKey in $additionalPaths) {
        $pathValue = Get-SafeConfigValue -Config $Config -Key $pathKey -Default $null
        if ($pathValue) {
            $script:ConfigPaths[$pathKey] = Resolve-ConfigPath -Path $pathValue
        }
    }
    
    Write-Log "[Common] Path cache initialized with $($script:ConfigPaths.Keys.Count) paths"
}

function Resolve-ConfigPath {
    <#
    .SYNOPSIS
    Resolve configuration path (relative or absolute) to absolute path
    .PARAMETER Path
    Path to resolve
    .PARAMETER BasePath
    Base path for relative path resolution (optional, uses script root by default)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [Parameter()]
        [string]$BasePath
    )
    
    if ([string]::IsNullOrEmpty($Path)) {
        return $null
    }
    
    # Use provided base path or fall back to cached root path or PSScriptRoot
    $baseForResolution = if ($BasePath) { 
        $BasePath 
    } elseif ($script:RootPath) { 
        $script:RootPath 
    } else { 
        $PSScriptRoot 
    }
    
    if ($Path.StartsWith('./')) {
        # Handle relative paths starting with ./
        $relativePath = $Path.Substring(2)
        return Join-Path $baseForResolution $relativePath
    } elseif ($Path.StartsWith('../')) {
        # Handle relative paths going up directories
        $relativePath = $Path
        $currentPath = $baseForResolution
        
        while ($relativePath.StartsWith('../')) {
            $currentPath = Split-Path $currentPath -Parent
            $relativePath = $relativePath.Substring(3)
        }
        
        if ($relativePath) {
            return Join-Path $currentPath $relativePath
        } else {
            return $currentPath
        }
    } elseif (-not [System.IO.Path]::IsPathRooted($Path)) {
        # Handle other relative paths
        return Join-Path $baseForResolution $Path
    } else {
        # Return absolute paths as-is
        return $Path
    }
}

function Get-ConfigPath {
    <#
    .SYNOPSIS
    Get cached configuration path
    .PARAMETER PathKey
    Key for the cached path
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PathKey
    )
    
    if ($script:ConfigPaths.ContainsKey($PathKey)) {
        return $script:ConfigPaths[$PathKey]
    } else {
        Write-Log "[Common] Warning: Path key '$PathKey' not found in cache" -Level Warning
        return $null
    }
}

function Set-ConfigPath {
    <#
    .SYNOPSIS
    Set or update a cached configuration path
    .PARAMETER PathKey
    Key for the path
    .PARAMETER Path
    Path value to cache
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PathKey,
        
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $resolvedPath = Resolve-ConfigPath -Path $Path
    $script:ConfigPaths[$PathKey] = $resolvedPath
    Write-Log "[Common] Updated cached path: $PathKey = $resolvedPath"
}

function Get-AllConfigPaths {
    <#
    .SYNOPSIS
    Get all cached configuration paths
    #>
    return $script:ConfigPaths.Clone()
}

function Test-ConfigPath {
    <#
    .SYNOPSIS
    Test if a cached configuration path exists
    .PARAMETER PathKey
    Key for the cached path
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PathKey
    )
    
    $path = Get-ConfigPath -PathKey $PathKey
    if ($path) {
        return Test-PathExists -Path $path
    } else {
        return $false
    }
}

function Write-Log {
    <#
    .SYNOPSIS
    Write message to log file and console with configurable log levels
    .PARAMETER Message
    Message to log
    .PARAMETER Level
    Log level (Debug, Info, Warning, Error)
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "$timestamp $Message"
    
    # Always write to log file (all levels)
    if ($script:logPath) {
        try {
            # Check log rotation if needed
            if ($script:config -and $script:config.logRotationEnabled -and (Test-Path $script:logPath)) {
                $maxSizeMB = if ($script:config.maxLogFileSizeMB) { $script:config.maxLogFileSizeMB } else { 100 }
                $fileSize = (Get-Item $script:logPath).Length / 1MB
                
                if ($fileSize -gt $maxSizeMB) {
                    $backupPath = $script:logPath -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
                    Move-Item $script:logPath $backupPath -ErrorAction SilentlyContinue
                    Write-Host "[LOG] Rotated log file to: $backupPath"
                }
            }
            
            Add-Content -Path $script:logPath -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch {
            # Silently ignore log file errors to prevent recursion
        }
    }
    
    # Console output based on configured level
    $consoleLogLevel = if ($script:config -and $script:config.consoleLogLevel) { 
        $script:config.consoleLogLevel 
    } else { 
        "Info"  # Default console level
    }
    
    # Log level priority: Debug=0, Info=1, Warning=2, Error=3
    $levelPriority = @{
        'Debug' = 0
        'Info' = 1  
        'Warning' = 2
        'Error' = 3
    }
    
    $currentLevelPriority = $levelPriority[$Level]
    $consoleLevelPriority = $levelPriority[$consoleLogLevel]
    
    # Only output to console if message level >= console level
    if ($currentLevelPriority -ge $consoleLevelPriority) {
        switch ($Level) {
            'Debug' { Write-Host $logLine -ForegroundColor Gray }
            'Info' { Write-Host $logLine }
            'Warning' { Write-Warning $logLine }
            'Error' { Write-Error $logLine }
        }
    }
}

function Get-TimeStamp {
    <#
    .SYNOPSIS
    Get formatted timestamp
    .PARAMETER Format
    Timestamp format
    #>
    param(
        [Parameter()]
        [string]$Format = "yyyy-MM-dd HH:mm:ss"
    )
    
    return Get-Date -Format $Format
}

function Test-PathExists {
    <#
    .SYNOPSIS
    Test if path exists with better error handling
    .PARAMETER Path
    Path to test
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    try {
        return Test-Path $Path -ErrorAction Stop
    }
    catch {
        Write-Log "[ERROR] Failed to test path '$Path': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Invoke-SafeCommand {
    <#
    .SYNOPSIS
    Execute command with error handling and logging
    .PARAMETER ScriptBlock
    Script block to execute
    .PARAMETER Description
    Description of the operation for logging
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [Parameter()]
        [string]$Description = "Command"
    )
    
    try {
        Write-Log "[INFO] Executing: $Description"
        $result = & $ScriptBlock
        Write-Log "[SUCCESS] Completed: $Description"
        return $result
    }
    catch {
        Write-Log "[ERROR] Failed $Description`: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function ConvertTo-HumanReadableSize {
    <#
    .SYNOPSIS
    Convert bytes to human readable size
    .PARAMETER Bytes
    Size in bytes
    #>
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )
    
    $sizes = @("B", "KB", "MB", "GB", "TB")
    $index = 0
    $size = [double]$Bytes
    
    while ($size -ge 1024 -and $index -lt $sizes.Count - 1) {
        $size = $size / 1024
        $index++
    }
    
    return "{0:N2} {1}" -f $size, $sizes[$index]
}

function Get-SafeConfigValue {
    <#
    .SYNOPSIS
    Get configuration value with default fallback
    .PARAMETER Config
    Configuration object
    .PARAMETER Key
    Configuration key
    .PARAMETER Default
    Default value if key not found
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        
        [Parameter(Mandatory)]
        [string]$Key,
        
        [Parameter()]
        [object]$Default = $null
    )
    
    try {
        $value = $Config
        $keyParts = $Key -split '\.'
        
        foreach ($part in $keyParts) {
            if ($value -is [PSCustomObject] -or $value -is [hashtable]) {
                $value = $value.$part
            } else {
                return $Default
            }
            
            if ($null -eq $value) {
                return $Default
            }
        }
        
        return $value
    }
    catch {
        return $Default
    }
}

function Get-ItemSafe {
    <#
    .SYNOPSIS
    Safely get file/directory information without throwing errors
    .PARAMETER Path
    Path to file or directory
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    try {
        if (Test-Path $Path) {
            return Get-Item $Path
        }
        return $null
    }
    catch {
        return $null
    }
}

function Get-NextScheduledRestart {
    <#
    .SYNOPSIS
    Get next scheduled restart time
    .PARAMETER RestartTimes
    Array of restart times in HH:mm format
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$RestartTimes
    )
    
    $now = Get-Date
    $todayRestarts = $RestartTimes | ForEach-Object {
        try {
            $t = [datetime]::ParseExact($_, 'HH:mm', $null)
            $scheduled = (Get-Date -Hour $t.Hour -Minute $t.Minute -Second 0)
            if ($scheduled -gt $now) { $scheduled } else { $null }
        } catch {
            Write-Log "[ERROR] Invalid restart time format: $_" -Level Warning
            $null
        }
    } | Where-Object { $_ -ne $null }
    
    if ($todayRestarts.Count -gt 0) {
        return ($todayRestarts | Sort-Object)[0]
    } else {
        # Next day's first restart
        try {
            $t = [datetime]::ParseExact($RestartTimes[0], 'HH:mm', $null)
            return ((Get-Date).AddDays(1).Date.AddHours($t.Hour).AddMinutes($t.Minute))
        } catch {
            # Default to tomorrow 02:00 if parsing fails
            return (Get-Date).AddDays(1).Date.AddHours(2)
        }
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-CommonModule',
    'Write-Log',
    'Get-TimeStamp',
    'Test-PathExists',
    'Invoke-SafeCommand',
    'ConvertTo-HumanReadableSize',
    'Get-SafeConfigValue',
    'Get-ItemSafe',
    'Get-NextScheduledRestart',
    'Initialize-ConfigPaths',
    'Initialize-PathCache',
    'Resolve-ConfigPath',
    'Get-ConfigPath',
    'Set-ConfigPath',
    'Get-AllConfigPaths',
    'Test-ConfigPath'
)
