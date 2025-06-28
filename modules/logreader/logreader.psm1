# ==========================
# Log Reader Module
# ==========================

#Requires -Version 5.1

# Import common utilities
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) "common\common.psm1") -Force -Global

# Module variables
$script:LogLinePosition = 0
$script:LastLogFileSize = $null
$script:LogMonitoringEnabled = $false
$script:LogFilePath = $null
$script:CurrentServerStatus = @{
    Status = "Unknown"
    Phase = "Unknown"
    LastActivity = $null
    PlayerCount = 0
    IsOnline = $false
    Message = "Initial state"
    TimeSinceLastActivity = 999
    PerformanceStats = $null
    PerformanceSummary = $null
}
$script:LogReaderConfig = $null
$script:HighestStatusReached = "Unknown"
$script:FirstOnlineNotificationSent = $false
$script:ManagerStartTime = Get-Date

function Initialize-LogReaderModule {
    <#
    .SYNOPSIS
    Initialize log reader module
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
        
        # Determine initial status from recent log entries
        $recentLines = Get-Content $LogPath -Tail 20 -ErrorAction SilentlyContinue
        if ($recentLines) {
            $initialStatus = Get-StatusFromLogLines $recentLines
            $script:CurrentServerStatus.Status = $initialStatus
            Write-Log "[LogReader] Initial status determined from recent logs: $initialStatus"
            
            # Also process recent Global Stats for performance data
            $globalStatsLines = $recentLines | Where-Object { $_ -match 'LogSCUM: Global Stats:' }
            if ($globalStatsLines) {
                $latestGlobalStats = $globalStatsLines[-1]
                Write-Log "[LogReader] Processing recent Global Stats for initial performance data"
                Read-LogLine -LogLine $latestGlobalStats
                
                if ($script:CurrentServerStatus.PerformanceStats) {
                    Write-Log "[LogReader] Initial performance data loaded: FPS=$($script:CurrentServerStatus.PerformanceStats.AverageFPS), Players=$($script:CurrentServerStatus.PlayerCount)"
                }
            }
        } else {
            # No log entries, assume offline
            $script:CurrentServerStatus.Status = "Offline"
            Write-Log "[LogReader] No recent log entries found, status set to: Offline"
        }
        
        Write-Log "[LogReader] Log monitoring initialized for: $LogPath"
    } else {
        $script:LogMonitoringEnabled = $false
        $script:LogFilePath = $null
        Write-Log "[LogReader] Log file not found, monitoring disabled: $LogPath" -Level Warning
    }
    
    Write-Log "[LogReader] Module initialized"
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

function Read-LogLine {
    <#
    .SYNOPSIS
    Process a single log line and update server status
    .PARAMETER LogLine
    Log line to process
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LogLine
    )
    
    # Skip empty or whitespace-only lines
    if ([string]::IsNullOrWhiteSpace($LogLine)) { 
        return $null
    }
    
    $previousStatus = $script:CurrentServerStatus.Status
    
    # Extract timestamp if available
    $timestamp = $null
    if ($LogLine -match '^\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d{3})') {
        try {
            $timeStr = $matches[1] -replace '\.', '/' -replace '-', ' ' -replace ':', '.'
            $timestamp = [datetime]::ParseExact($timeStr, 'yyyy/MM/dd HH.mm.ss.fff', $null)
            $script:CurrentServerStatus.LastActivity = $timestamp
        } catch {
            # If parsing fails, use current time
            $script:CurrentServerStatus.LastActivity = Get-Date
        }
    }
    
    # Initialize status priority if needed
    if (-not $script:HighestStatusReached) {
        $script:HighestStatusReached = "Unknown"
    }
    
    $statusPriority = @{
        "Unknown" = 0
        "Offline" = 1
        "Starting" = 2
        "Loading" = 3
        "Online" = 4
        "Shutting Down" = 5
    }
    
    $detectedStatus = $null
    
    # Check for status-changing patterns
    if ($LogLine -match 'Log file open' -or 
        $LogLine -match 'LogInit: Display: RandInit') {
        $detectedStatus = "Starting"
        $script:CurrentServerStatus.Phase = "Initializing"
        $script:CurrentServerStatus.Message = "Server starting up"
        
    } elseif ($LogLine -match 'LogInit: Display: Game Engine Initialized\.' -or 
              $LogLine -match 'LogWorld: Bringing World') {
        $detectedStatus = "Loading"
        $script:CurrentServerStatus.Phase = "Loading World"
        $script:CurrentServerStatus.Message = "Loading game world"
        
    } elseif ($LogLine -match 'LogSCUM: Global Stats:') {
        $detectedStatus = "Online"
        $script:CurrentServerStatus.Phase = "Online"
        $script:CurrentServerStatus.Message = "Server running normally"
        $script:CurrentServerStatus.IsOnline = $true
        
        # Parse performance data
        $perfStats = Read-GlobalStatsLine $LogLine
        if ($perfStats) {
            $script:CurrentServerStatus.PerformanceStats = $perfStats
            $script:CurrentServerStatus.PlayerCount = $perfStats.PlayerCount
        }
        
        # Only send online notification if server actually transitioned to online
        # Don't send notification just because manager started and found existing Global Stats
        if (-not $script:FirstOnlineNotificationSent) {
            # Check if this is a real transition or just manager startup detection
            $timeSinceManagerStart = (Get-Date) - $script:ManagerStartTime
            $isRecentManagerStart = $timeSinceManagerStart.TotalMinutes -lt 2
            
            # Only send if we detected a real transition from a lower status
            # OR if enough time has passed since manager start to be sure it's a real transition
            if ($previousStatus -and $previousStatus -notin @("Online", "Unknown") -and -not $isRecentManagerStart) {
                Write-Log "[LogReader] Server transitioned to Online from $previousStatus - sending notifications"
                Send-Notification admin "serverOnline" @{ reason = "server transitioned to online from $previousStatus" }
                Send-Notification player "serverOnline" @{}
                $script:FirstOnlineNotificationSent = $true
            } elseif ($isRecentManagerStart) {
                Write-Log "[LogReader] Global Stats found but manager just started - assuming server was already online"
                # Set flag to prevent duplicate notifications later
                $script:FirstOnlineNotificationSent = $true
            } else {
                Write-Log "[LogReader] Global Stats found but no clear status transition detected"
            }
            $script:FirstOnlineNotificationSent = $true
        }
        
    } elseif ($LogLine -match 'LogCore: Warning: \*\*\* INTERRUPTED \*\*\*.*SHUTTING DOWN') {
        $detectedStatus = "Shutting Down"
        $script:CurrentServerStatus.Phase = "Shutting Down"
        $script:CurrentServerStatus.Message = "Server shutting down"
        $script:CurrentServerStatus.IsOnline = $false
        
    } elseif ($LogLine -match 'LogExit: Exiting\.' -or $LogLine -match 'Log file closed') {
        $detectedStatus = "Offline"
        $script:CurrentServerStatus.Phase = "Offline"
        $script:CurrentServerStatus.Message = "Server stopped"
        $script:CurrentServerStatus.IsOnline = $false
        $script:CurrentServerStatus.PlayerCount = 0
    }
    
    # Apply status change with regression prevention
    if ($detectedStatus) {
        $currentPriority = $statusPriority[$detectedStatus]
        $highestPriority = $statusPriority[$script:HighestStatusReached]
        
        # Allow progression or specific transitions
        if ($currentPriority -ge $highestPriority -or 
            $detectedStatus -eq "Shutting Down" -or 
            $detectedStatus -eq "Offline") {
            
            $script:CurrentServerStatus.Status = $detectedStatus
            
            # Update highest reached status (but not for shutdowns)
            if ($detectedStatus -notin @("Shutting Down", "Offline")) {
                $script:HighestStatusReached = $detectedStatus
            }
            
            # Log status change and send notification
            if ($detectedStatus -ne $previousStatus) {
                Write-Log "[LogReader] Status change: $previousStatus → $detectedStatus"
                
                # Check if this is a manager startup scenario for Online status
                $timeSinceManagerStart = (Get-Date) - $script:ManagerStartTime
                $isRecentManagerStart = $timeSinceManagerStart.TotalMinutes -lt 2
                $skipOnlineNotification = ($detectedStatus -eq "Online" -and $previousStatus -eq "Unknown" -and $isRecentManagerStart)
                
                if ($skipOnlineNotification) {
                    Write-Log "[LogReader] Skipping general Online notification due to manager startup"
                } else {
                    # Send notification based on the new status
                    switch ($detectedStatus) {
                        "Starting" {
                            Write-Log "[LogReader] Server startup detected from log"
                            Send-Notification admin "serverStarting" @{ reason = "server initialization detected in logs" }
                            Send-Notification player "serverStarting" @{}
                        }
                        "Loading" {
                            Write-Log "[LogReader] Server loading detected from log"
                            Send-Notification admin "serverLoading" @{ reason = "world loading detected in logs" }
                            Send-Notification player "serverLoading" @{}
                        }
                        "Online" {
                            Write-Log "[LogReader] Server online detected from log"
                            Send-Notification admin "serverOnline" @{ reason = "server ready for connections (logs)" }
                            Send-Notification player "serverOnline" @{}
                        }
                        "Shutting Down" {
                            Write-Log "[LogReader] Server shutting down detected from log"
                            Send-Notification admin "serverStopped" @{ context = "shutdown detected in logs" }
                            Send-Notification player "serverOffline" @{}
                        }
                        "Offline" {
                            Write-Log "[LogReader] Server offline detected from log"
                            Send-Notification admin "serverOffline" @{ reason = "server shutdown confirmed (logs)" }
                            Send-Notification player "serverOffline" @{}
                        }
                        default {
                            Write-Log "[LogReader] DEBUG: Status changed to unhandled status: '$detectedStatus'"
                        }
                    }
                }
            }
        }
    }
    
    # Update time since last activity
    if ($script:CurrentServerStatus.LastActivity) {
        $timeDiff = (Get-Date) - $script:CurrentServerStatus.LastActivity
        $script:CurrentServerStatus.TimeSinceLastActivity = $timeDiff.TotalMinutes
    }
}

function Read-GlobalStatsLine {
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
    
    $thresholds = Get-SafeConfigValue $script:LogReaderConfig "performanceThresholds" @{
        excellent = 30
        good = 20
        fair = 15
        poor = 10
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

function Get-StatusFromLogLines {
    <#
    .SYNOPSIS
    Determine server status from recent log lines
    .PARAMETER LogLines
    Array of recent log lines
    .RETURNS
    Server status string
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$LogLines
    )
    
    $hasGlobalStats = $false
    $hasShutdown = $false
    $hasExit = $false
    
    # Check recent lines for status indicators
    foreach ($line in $LogLines) {
        if ($line -match 'LogSCUM: Global Stats:') {
            $hasGlobalStats = $true
        }
        if ($line -match 'SHUTTING DOWN' -or $line -match 'INTERRUPTED') {
            $hasShutdown = $true
        }
        if ($line -match 'LogExit: Exiting\.' -or $line -match 'Log file closed') {
            $hasExit = $true
        }
    }
    
    # Determine status based on indicators
    if ($hasExit) {
        return "Offline"
    } elseif ($hasShutdown) {
        return "Shutting Down"
    } elseif ($hasGlobalStats) {
        return "Online"
    } else {
        return "Unknown"
    }
}

function Get-ServerStatus {
    <#
    .SYNOPSIS
    Get current server status
    .RETURNS
    Hashtable with current server status
    #>
    
    return @{
        Status = $script:CurrentServerStatus.Status
        Phase = $script:CurrentServerStatus.Phase
        LastActivity = $script:CurrentServerStatus.LastActivity
        PlayerCount = $script:CurrentServerStatus.PlayerCount
        IsOnline = $script:CurrentServerStatus.IsOnline
        Message = $script:CurrentServerStatus.Message
        TimeSinceLastActivity = $script:CurrentServerStatus.TimeSinceLastActivity
        PerformanceStats = $script:CurrentServerStatus.PerformanceStats
        PerformanceSummary = $script:CurrentServerStatus.PerformanceSummary
    }
}

function Read-GameLogs {
    <#
    .SYNOPSIS
    Read new lines from SCUM game log since last check
    .RETURNS
    Array of new log lines
    #>
    
    if (-not $script:LogMonitoringEnabled -or -not $script:LogFilePath) {
        return @()
    }
    
    try {
        $newLines = Read-NewLogLines -LogPath $script:LogFilePath
        
        # Filter out empty or whitespace-only lines
        $validLines = $newLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        
        # Process each valid line to update internal status
        foreach ($line in $validLines) {
            Read-LogLine -LogLine $line
        }
        
        # Return the valid lines for further processing
        return $validLines
        
    } catch {
        Write-Log "[LogReader] Error in Read-GameLogs: $($_.Exception.Message)" -Level Warning
        return @()
    }
}

function Process-LogEvent {
    <#
    .SYNOPSIS
    Process a log event from the game (raw log line)
    .PARAMETER LogEvent
    Log line to process for status changes and notifications
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LogEvent
    )
    
    if ([string]::IsNullOrWhiteSpace($LogEvent)) {
        return
    }
    
    try {
        # Process the log line to update internal status
        # Notifications are now sent directly from Read-LogLine when status changes
        Read-LogLine -LogLine $LogEvent
        
        # Also process specific log patterns for additional events
        if ($LogEvent -match 'LogInit: Display: RandInit' -or $LogEvent -match 'Log file open') {
            Write-Log "[LogReader] Server initialization pattern detected"
        } elseif ($LogEvent -match 'LogWorld: Bringing World' -or $LogEvent -match 'LogInit: Display: Game Engine Initialized\.') {
            Write-Log "[LogReader] World loading pattern detected"
        } elseif ($LogEvent -match 'LogSCUM: Global Stats:') {
            Write-Log "[LogReader] Server running normally"
        } elseif ($LogEvent -match 'LogCore: Warning: \*\*\* INTERRUPTED \*\*\*.*SHUTTING DOWN') {
            Write-Log "[LogReader] Server shutdown signal detected"
        } elseif ($LogEvent -match 'LogExit: Exiting\.' -or $LogEvent -match 'Log file closed') {
            Write-Log "[LogReader] Server exit confirmed"
        }
        
    } catch {
        Write-Log "[LogReader] Error processing log event: $($_.Exception.Message)" -Level Warning
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-LogReaderModule',
    'Read-NewLogLines',
    'Read-LogLine',
    'Read-GlobalStatsLine',
    'Get-PerformanceStatus',
    'Get-StatusFromLogLines',
    'Get-ServerStatus',
    'Read-GameLogs',
    'Process-LogEvent'
)
