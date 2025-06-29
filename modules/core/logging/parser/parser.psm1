# ==========================
# Log Reader Module
# ==========================

#Requires -Version 5.1

# Import common utilities with new structure
$ModulesRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
Import-Module (Join-Path $ModulesRoot "core\common\common.psm1") -Force -Global

# Module variables - focused on log reading only
$script:LogLinePosition = 0
$script:LastLogFileSize = $null
$script:LogMonitoringEnabled = $false
$script:LogFilePath = $null
$script:LogReaderConfig = $null

# Event tracking for parsed data
$script:LastParsedEvents = @()
$script:MaxEventHistory = 100

# State tracking to prevent duplicate logging
$script:LastLoggedEventType = $null
$script:LastEventTimestamp = $null
$script:EventCount = @{}

function Initialize-LogReaderModule {
    <#
    .SYNOPSIS
    Initialize log reader module for parsing logs only
    .PARAMETER Config
    Configuration object
    .PARAMETER LogPath
    Path to SCUM server log file
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        
        [Parameter()]
        [string]$LogPath
    )
    
    $script:LogReaderConfig = $Config
    
    if ($LogPath -and (Test-PathExists $LogPath)) {
        $script:LogMonitoringEnabled = $true
        $script:LogFilePath = $LogPath
        
        # Initialize file position - start from end to avoid replaying old events
        $fileInfo = Get-ItemSafe $LogPath
        if ($fileInfo) {
            $script:LastLogFileSize = $fileInfo.Length
            # Start from end of file to only process new log entries
            $allLines = Get-Content $LogPath -ErrorAction SilentlyContinue
            $script:LogLinePosition = if ($allLines) { $allLines.Count } else { 0 }
        }
        
        Write-Log "[LogReader] Log monitoring initialized for: $LogPath"
        
        # Reset state to prevent spam on initialization
        $script:LastLoggedEventType = $null
        $script:LastEventTimestamp = $null
        $script:EventCount = @{}
    } else {
        $script:LogMonitoringEnabled = $false
        $script:LogFilePath = $null
        Write-Log "[LogReader] Log file not found, monitoring disabled: $LogPath" -Level Warning
    }
    
    Write-Log "[LogReader] Module initialized - focused on log parsing only"
}

function Read-NewLogLines {
    <#
    .SYNOPSIS
    Read new lines from log file since last check
    .PARAMETER LogPath
    Path to log file
    .RETURNS
    Array of new log lines
    #>
    param(
        [Parameter(Mandatory)]
        [string]$LogPath
    )
    
    if (-not $script:LogMonitoringEnabled -or -not (Test-PathExists $LogPath)) {
        return @()
    }
    
    try {
        $fileInfo = Get-ItemSafe $LogPath
        if (-not $fileInfo) {
            return @()
        }
        
        $currentSize = $fileInfo.Length
        
        # Check for log rotation (file got smaller)
        if ($script:LastLogFileSize -and $currentSize -lt $script:LastLogFileSize) {
            Write-Log "[LogReader] Log rotation detected, resetting position"
            $script:LogLinePosition = 0
            $script:LastLogFileSize = $currentSize
        }
        
        # No new content
        if ($currentSize -eq $script:LastLogFileSize) {
            return @()
        }
        
        # Read all lines and get new ones
        $allLines = Get-Content $LogPath -ErrorAction SilentlyContinue
        if (-not $allLines -or $allLines.Count -eq 0) {
            return @()
        }
        
        # Get new lines since last position
        $newLines = @()
        if ($script:LogLinePosition -lt $allLines.Count) {
            $newLines = $allLines[$script:LogLinePosition..($allLines.Count - 1)]
            $script:LogLinePosition = $allLines.Count
        }
        
        $script:LastLogFileSize = $currentSize
        return $newLines
        
    } catch {
        Write-Log "[LogReader] Error reading log file: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Parse-LogLine {
    <#
    .SYNOPSIS
    Parse a single log line and extract event data
    .PARAMETER LogLine
    Log line to parse
    .PARAMETER Silent
    If true, suppresses event logging
    .RETURNS
    Hashtable with parsed event data or $null if no relevant data
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LogLine,
        
        [Parameter()]
        [switch]$Silent
    )
    
    # Skip empty or whitespace-only lines
    if ([string]::IsNullOrWhiteSpace($LogLine)) { 
        return $null
    }

    $parsedEvent = @{
        RawLine = $LogLine
        Timestamp = $null
        EventType = "Unknown"
        Data = @{}
    }
    
    # Extract timestamp if available
    if ($LogLine -match '^[\[](\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3})') {
        try {
            $timeStr = $matches[1] -replace '\.', '/' -replace '-', ' ' -replace ':', '.'
            $parsedEvent.Timestamp = [datetime]::ParseExact($timeStr, 'yyyy/MM/dd HH.mm.ss.fff', $null)
        } catch {
            # If parsing fails, use current time
            $parsedEvent.Timestamp = Get-Date
        }
    } else {
        $parsedEvent.Timestamp = Get-Date
    }
    
    # Identify event types and extract relevant data
    if ($LogLine -match 'Log file open' -or $LogLine -match 'LogInit: Display: RandInit') {
        $parsedEvent.EventType = "ServerStarting"
        $parsedEvent.Data.Phase = "Initializing"
        
    } elseif ($LogLine -match 'LogGameState: Match State Changed from EnteringMap to WaitingToStart') {
        $parsedEvent.EventType = "ServerLoading"
        $parsedEvent.Data.Phase = "Loading World"
    
    } elseif ($LogLine -match 'LogSCUM: Global Stats:') {
        $parsedEvent.EventType = "ServerOnline"
        $parsedEvent.Data.Phase = "Online"
        
        # Parse performance data
        $perfStats = Parse-GlobalStatsLine $LogLine
        if ($perfStats) {
            $parsedEvent.Data.PerformanceStats = $perfStats
            $parsedEvent.Data.PlayerCount = $perfStats.PlayerCount
        }
        
    } elseif ($LogLine -match 'LogCore: Warning: \*\*\* INTERRUPTED \*\*\*.*SHUTTING DOWN') {
        $parsedEvent.EventType = "ServerShuttingDown"
        $parsedEvent.Data.Phase = "Shutting Down"
    
    } elseif ($LogLine -match 'LogExit: Exiting\.' -or $LogLine -match 'Log file closed') {
        $parsedEvent.EventType = "ServerOffline"
        $parsedEvent.Data.Phase = "Offline"
        
    } else {
        # Return null for lines that don't contain relevant events
        return $null
    }
    
    # Add to event history
    $script:LastParsedEvents += $parsedEvent
    if ($script:LastParsedEvents.Count -gt $script:MaxEventHistory) {
        $script:LastParsedEvents = $script:LastParsedEvents[-$script:MaxEventHistory..-1]
    }
    
    # Only log significant events if not in silent mode and reduce spam
    if (-not $Silent -and $parsedEvent.EventType -in @("ServerOnline", "ServerOffline", "ServerShuttingDown", "ServerRestarting", "ServerStarting", "ServerLoading")) {
        # Implement state change detection to prevent spam
        $shouldLog = $false
        $isStateChange = $false
        
        # Log if this is a different event type than the last logged one
        if ($script:LastLoggedEventType -ne $parsedEvent.EventType) {
            $shouldLog = $true
            $isStateChange = $true
            $script:LastLoggedEventType = $parsedEvent.EventType
            $script:LastEventTimestamp = $parsedEvent.Timestamp
        }
        # For repeated events, only log if significant time has passed (e.g., 5 minutes)
        elseif ($script:LastEventTimestamp -and 
                $parsedEvent.Timestamp.Subtract($script:LastEventTimestamp).TotalMinutes -gt 5) {
            # Count occurrences
            if (-not $script:EventCount.ContainsKey($parsedEvent.EventType)) {
                $script:EventCount[$parsedEvent.EventType] = 0
            }
            $script:EventCount[$parsedEvent.EventType]++
            
            # Only log summary of repeated events occasionally
            if ($script:EventCount[$parsedEvent.EventType] % 10 -eq 0) {
                Write-Log "[LogReader] Event summary: $($parsedEvent.EventType) occurred $($script:EventCount[$parsedEvent.EventType]) times" -Level Verbose
            }
            $script:LastEventTimestamp = $parsedEvent.Timestamp
        }
        
        # Add the IsStateChange property to the event
        $parsedEvent.IsStateChange = $isStateChange
        
        if ($shouldLog) {
            Write-Log "[LogReader] Server state change detected: $($parsedEvent.EventType)" -Level Info
        }
    } else {
        # For non-server events, mark as not a state change
        $parsedEvent.IsStateChange = $false
    }
    
    return $parsedEvent
}

function Parse-GlobalStatsLine {
    <#
    .SYNOPSIS
    Parse Global Stats line for performance data
    .PARAMETER Line
    Log line containing global stats
    .RETURNS
    Hashtable with performance statistics
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )
    
    try {
        $stats = @{
            AverageFPS = 0
            MinFPS = 0
            MaxFPS = 0
            AverageFrameTime = 0
            PlayerCount = 0
            PerformanceStatus = "Unknown"
            Entities = @{
                Characters = 0
                Zombies = 0
                Vehicles = 0
            }
        }
        
        # Parse FPS values
        if ($Line -match 'AvgFPS=([0-9.]+)') {
            $stats.AverageFPS = [Math]::Round([double]$matches[1], 1)
        }
        if ($Line -match 'MinFPS=([0-9.]+)') {
            $stats.MinFPS = [Math]::Round([double]$matches[1], 1)
        }
        if ($Line -match 'MaxFPS=([0-9.]+)') {
            $stats.MaxFPS = [Math]::Round([double]$matches[1], 1)
        }
        if ($Line -match 'AvgFrameTime=([0-9.]+)') {
            $stats.AverageFrameTime = [Math]::Round([double]$matches[1], 2)
        }
        
        # Parse player count
        if ($Line -match 'Players=(\d+)') {
            $stats.PlayerCount = [int]$matches[1]
        }
        
        # Parse entity counts
        if ($Line -match 'Characters=(\d+)') {
            $stats.Entities.Characters = [int]$matches[1]
        }
        if ($Line -match 'Zombies=(\d+)') {
            $stats.Entities.Zombies = [int]$matches[1]
        }
        if ($Line -match 'Vehicles=(\d+)') {
            $stats.Entities.Vehicles = [int]$matches[1]
        }
        
        # Determine performance status
        $stats.PerformanceStatus = Get-PerformanceStatus $stats.AverageFPS
        
        return $stats
        
    } catch {
        Write-Log "[LogReader] Error parsing global stats: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Get-PerformanceStatus {
    <#
    .SYNOPSIS
    Determine performance status based on FPS
    .PARAMETER Fps
    Average FPS value
    .RETURNS
    Performance status string
    #>
    param(
        [Parameter(Mandatory)]
        [double]$Fps
    )
    
    if ($Fps -le 0) { 
        return "Unknown" 
    }
    
    $thresholds = @{
        excellent = 30
        good = 20
        fair = 15
        poor = 10
    }
    
    # Use config if available
    if ($script:LogReaderConfig) {
        $thresholds = Get-SafeConfigValue $script:LogReaderConfig "performanceThresholds" $thresholds
    }
    
    if ($Fps -ge $thresholds.excellent) {
        return "Excellent"
    } elseif ($Fps -ge $thresholds.good) {
        return "Good"
    } elseif ($Fps -ge $thresholds.fair) {
        return "Fair"
    } elseif ($Fps -ge $thresholds.poor) {
        return "Poor"
    } else {
        return "Critical"
    }
}

function Analyze-RecentLogLines {
    <#
    .SYNOPSIS
    Analyze recent log lines to determine current server state
    .PARAMETER LogLines
    Array of recent log lines
    .RETURNS
    Hashtable with analysis results
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$LogLines
    )
    
    $analysis = @{
        LastEventType = "Unknown"
        HasGlobalStats = $false
        HasShutdown = $false
        HasExit = $false
        LatestPerformanceStats = $null
        EventsDetected = @()
    }
    
    # Check recent lines for status indicators
    foreach ($line in $LogLines) {
        $parsedEvent = Parse-LogLine -LogLine $line -Silent
        if ($parsedEvent) {
            $analysis.EventsDetected += $parsedEvent
            $analysis.LastEventType = $parsedEvent.EventType
            
            if ($parsedEvent.EventType -eq "ServerOnline" -and $parsedEvent.Data.PerformanceStats) {
                $analysis.LatestPerformanceStats = $parsedEvent.Data.PerformanceStats
            }
        }
        
        # Legacy checks for compatibility
        if ($line -match 'LogSCUM: Global Stats:') {
            $analysis.HasGlobalStats = $true
        }
        if ($line -match 'SHUTTING DOWN' -or $line -match 'INTERRUPTED') {
            $analysis.HasShutdown = $true
        }
        if ($line -match 'LogExit: Exiting\.' -or $line -match 'Log file closed') {
            $analysis.HasExit = $true
        }
    }
    
    return $analysis
}

function Get-ParsedEvents {
    <#
    .SYNOPSIS
    Get recently parsed events from log
    .PARAMETER Count
    Number of recent events to return (default: all)
    .RETURNS
    Array of parsed event objects
    #>
    param(
        [Parameter()]
        [int]$Count = 0
    )
    
    if ($Count -gt 0 -and $script:LastParsedEvents.Count -gt $Count) {
        return $script:LastParsedEvents[-$Count..-1]
    }
    
    return $script:LastParsedEvents
}

function Read-GameLogs {
    <#
    .SYNOPSIS
    Read new lines from SCUM game log since last check and parse them
    .RETURNS
    Array of parsed event objects
    #>
    
    if (-not $script:LogMonitoringEnabled -or -not $script:LogFilePath) {
        return @()
    }
    
    try {
        $newLines = Read-NewLogLines -LogPath $script:LogFilePath
        
        # Parse each new line into events
        $parsedEvents = @()
        foreach ($line in $newLines) {
            $parsedEvent = Parse-LogLine -LogLine $line
            if ($parsedEvent) {
                $parsedEvents += $parsedEvent
            }
        }
        
        return $parsedEvents
        
    } catch {
        Write-Log "[LogReader] Error in Read-GameLogs: $($_.Exception.Message)" -Level Warning
        return @()
    }
}

function Get-LogReaderStats {
    <#
    .SYNOPSIS
    Get statistics about log reader operation
    .RETURNS
    Hashtable with statistics
    #>
    
    return @{
        LogMonitoringEnabled = $script:LogMonitoringEnabled
        LogFilePath = $script:LogFilePath
        CurrentPosition = $script:LogLinePosition
        LastFileSize = $script:LastLogFileSize
        EventsInHistory = $script:LastParsedEvents.Count
        MaxEventHistory = $script:MaxEventHistory
        LastLoggedEventType = $script:LastLoggedEventType
        EventCounts = $script:EventCount
    }
}

function Reset-LogParserState {
    <#
    .SYNOPSIS
    Reset parser state to prevent log spam on restart
    #>
    
    $script:LastLoggedEventType = $null
    $script:LastEventTimestamp = $null
    $script:EventCount = @{}
    Write-Log "[LogReader] Parser state reset - event tracking cleared" -Level Info
}

# Export functions - focused on log parsing only
Export-ModuleMember -Function @(
    'Initialize-LogReaderModule',
    'Read-NewLogLines',
    'Parse-LogLine',
    'Parse-GlobalStatsLine',
    'Get-PerformanceStatus',
    'Analyze-RecentLogLines',
    'Get-ParsedEvents',
    'Read-GameLogs',
    'Get-LogReaderStats',
    'Reset-LogParserState'
)
