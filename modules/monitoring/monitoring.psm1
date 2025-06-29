# ==========================
# Monitoring Module
# ==========================

#Requires -Version 5.1
using module ..\..\core\common\common.psm1

# Module variables
$script:MonitoringConfig = $null
$script:LastPerformanceLogTime = $null
$script:LastPerformanceStatus = ""
$script:PerformanceHistory = @()
$script:HealthCheckHistory = @()
$script:LogFilePath = $null
$script:IsInitializing = $false

# Server status management variables - moved from logreader
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
$script:HighestStatusReached = "Unknown"
$script:FirstOnlineNotificationSent = $false
$script:ManagerStartTime = Get-Date

function Initialize-MonitoringModule {
    <#
    .SYNOPSIS
    Initialize monitoring module with server status management
    .PARAMETER Config
    Configuration object
    .PARAMETER LogPath
    Path to SCUM log file
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config,
        
        [Parameter()]
        [string]$LogPath
    )
    
    $script:MonitoringConfig = $Config
    
    # Use centralized path management if available
    $resolvedLogPath = Get-ConfigPath "logPath" -ErrorAction SilentlyContinue
    if ($resolvedLogPath) {
        $script:LogFilePath = $resolvedLogPath
    } else {
        $script:LogFilePath = $LogPath
    }
    
    # Check actual service status first to avoid false notifications from old logs
    $serviceName = Get-SafeConfigValue $Config "serviceName" "SCUMDedicatedServer"
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    $serviceIsRunning = $service -and $service.Status -eq 'Running'
    
    Write-Log "[Monitoring] Checking actual service status: $serviceName"
    Write-Log "[Monitoring] Service running: $serviceIsRunning"
    
    # Initialize server status based on actual service state
    if ($serviceIsRunning) {
        # Service is running - check recent logs for current state
        if ($script:LogFilePath -and (Test-PathExists $script:LogFilePath)) {
            $recentLines = Get-Content $script:LogFilePath -Tail 100 -ErrorAction SilentlyContinue
            if ($recentLines) {
                $analysis = Analyze-RecentLogLines -LogLines $recentLines
                if ($analysis.LastEventType -and $analysis.LastEventType -ne "Unknown") {
                    # Set initialization flag to prevent notifications during startup
                    $script:IsInitializing = $true
                    Update-ServerStatusFromEvent -EventType $analysis.LastEventType -EventData $analysis
                    $script:IsInitializing = $false
                    Write-Log "[Monitoring] Initial server status from logs (service running): $($script:CurrentServerStatus.Status)"
                } else {
                    # Service running but no recent log activity - assume starting
                    $script:CurrentServerStatus.Status = "Starting"
                    $script:CurrentServerStatus.Phase = "Unknown"
                    $script:CurrentServerStatus.IsOnline = $false
                    $script:CurrentServerStatus.Message = "Service running, status unknown"
                    Write-Log "[Monitoring] Service running but no recent log activity - status set to Starting"
                }
            }
        }
    } else {
        # Service is not running - set to offline regardless of old logs
        $script:CurrentServerStatus.Status = "Offline"
        $script:CurrentServerStatus.Phase = "Offline"
        $script:CurrentServerStatus.IsOnline = $false
        $script:CurrentServerStatus.Message = "Service not running"
        $script:CurrentServerStatus.PlayerCount = 0
        Write-Log "[Monitoring] Service not running - status set to Offline"
    }
    
    Write-Log "[Monitoring] Module initialized with server status management"
    Write-Log "[Monitoring] Log path: $($script:LogFilePath)"
    Write-Log "[Monitoring] Performance alert threshold: $(Get-SafeConfigValue $Config "performanceAlertThreshold" "Poor")"
}

function Test-ServiceHealth {
    <#
    .SYNOPSIS
    Perform comprehensive service health check
    .PARAMETER ServiceName
    Windows service name
    .RETURNS
    Hashtable with health check results
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )
    
    $healthCheck = @{
        Timestamp = Get-Date
        ServiceRunning = $false
        ServiceStatus = "Unknown"
        ProcessHealth = @{
            Running = $false
            ProcessId = $null
            MemoryMB = 0
            CPUPercent = 0
        }
        OverallHealth = "Unknown"
        Issues = @()
        Recommendations = @()
    }
    
    try {
        # Check Windows service
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($service) {
            $healthCheck.ServiceRunning = ($service.Status -eq 'Running')
            $healthCheck.ServiceStatus = $service.Status
        } else {
            $healthCheck.Issues += "Service '$ServiceName' not found"
        }
        
        # Check associated processes
        $processes = Get-Process -Name "*SCUM*" -ErrorAction SilentlyContinue
        if ($processes) {
            $mainProcess = $processes | Sort-Object StartTime | Select-Object -First 1
            $healthCheck.ProcessHealth.Running = $true
            $healthCheck.ProcessHealth.ProcessId = $mainProcess.Id
            $healthCheck.ProcessHealth.MemoryMB = [Math]::Round($mainProcess.WorkingSet64 / 1MB, 0)
            
            # Get CPU usage (approximate)
            try {
                $cpuUsage = Get-Counter "\Process($($mainProcess.ProcessName))\% Processor Time" -SampleInterval 1 -MaxSamples 2 -ErrorAction SilentlyContinue
                if ($cpuUsage) {
                    $healthCheck.ProcessHealth.CPUPercent = [Math]::Round($cpuUsage.CounterSamples[-1].CookedValue, 1)
                }
            } catch {
                # CPU monitoring failed, not critical
            }
        } else {
            if ($healthCheck.ServiceRunning) {
                $healthCheck.Issues += "Service running but no SCUM processes found"
            }
        }
        
        # Determine overall health
        if ($healthCheck.ServiceRunning -and $healthCheck.ProcessHealth.Running) {
            $healthCheck.OverallHealth = "Healthy"
        } elseif ($healthCheck.ServiceRunning -and -not $healthCheck.ProcessHealth.Running) {
            $healthCheck.OverallHealth = "Service Running - Process Missing"
            $healthCheck.Issues += "Service is running but process not found"
            $healthCheck.Recommendations += "Restart service to restore process"
        } elseif (-not $healthCheck.ServiceRunning -and $healthCheck.ProcessHealth.Running) {
            $healthCheck.OverallHealth = "Process Running - Service Stopped"
            $healthCheck.Issues += "Process running but service is stopped"
            $healthCheck.Recommendations += "Start service or kill orphaned process"
        } else {
            $healthCheck.OverallHealth = "Offline"
        }
        
        # Memory usage warnings
        if ($healthCheck.ProcessHealth.MemoryMB -gt 8192) {
            $healthCheck.Issues += "High memory usage: $($healthCheck.ProcessHealth.MemoryMB) MB"
            $healthCheck.Recommendations += "Monitor memory usage, consider restart if increasing"
        }
        
        # Add to history
        $script:HealthCheckHistory += $healthCheck
        if ($script:HealthCheckHistory.Count -gt 100) {
            $script:HealthCheckHistory = $script:HealthCheckHistory[-50..-1]
        }
        
        return $healthCheck
        
    } catch {
        Write-Log "[Monitoring] Health check failed: $($_.Exception.Message)" -Level Error
        $healthCheck.OverallHealth = "Error"
        $healthCheck.Issues += "Health check failed: $($_.Exception.Message)"
        return $healthCheck
    }
}

function Test-IntentionalStop {
    <#
    .SYNOPSIS
    Check if server was stopped intentionally
    .PARAMETER ServiceName
    Windows service name
    .PARAMETER ServerDirectory
    Server installation directory
    .PARAMETER MinutesToCheck
    How many minutes back to check
    .RETURNS
    Boolean indicating if stop was intentional
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter(Mandatory)]
        [string]$ServerDirectory,
        
        [Parameter()]
        [int]$MinutesToCheck = 10
    )
    
    $since = (Get-Date).AddMinutes(-$MinutesToCheck)
    
    try {
        # Method 1: Check Application Event Log for service events
        $serviceEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$ServiceName*" -and (
                $_.Message -like "*stop*" -or 
                $_.Message -like "*terminate*" -or
                $_.Message -like "*shutdown*"
            )
        }
        
        if ($serviceEvents) {
            Write-Log "[Monitoring] Application log shows service control event - likely intentional stop"
            return $true
        }
        
        # Method 2: Check System Event Log for service state changes
        $systemEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ID = @(7036, 7040) # Service state change events
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$ServiceName*" -and $_.Message -like "*stopped*"
        }
        
        if ($systemEvents) {
            Write-Log "[Monitoring] System log shows service stop event - likely intentional stop"
            return $true
        }
        
        # Method 3: Check for clean shutdown in SCUM log
        $logPath = Join-Path $ServerDirectory "SCUM\Saved\Logs\SCUM.log"
        if (Test-PathExists $logPath) {
            $recentLines = Get-Content $logPath -Tail 20 -ErrorAction SilentlyContinue
            $cleanShutdownPatterns = @(
                'LogExit: Exiting\.',
                'SHUTTING DOWN',
                'Log file closed'
            )
            
            foreach ($pattern in $cleanShutdownPatterns) {
                $matches = $recentLines | Where-Object { $_ -match $pattern }
                if ($matches) {
                    Write-Log "[Monitoring] Clean shutdown pattern found in log - intentional stop"
                    return $true
                }
            }
        }
        
        # Method 4: Time-based heuristic
        $currentHour = (Get-Date).Hour
        if ($currentHour -ge 8 -and $currentHour -le 22) {
            Write-Log "[Monitoring] Service stopped during normal hours - more likely intentional"
            # Don't return true based on timing alone, but it's a hint
        }
        
    } catch {
        Write-Log "[Monitoring] Error checking intentional stop: $($_.Exception.Message)" -Level Error
    }
    
    # Default to false - treat as unintentional unless clear evidence
    Write-Log "[Monitoring] No clear evidence of intentional stop - treating as crash"
    return $false
}

function Get-PerformanceMetrics {
    <#
    .SYNOPSIS
    Get current performance metrics from log or system
    .PARAMETER LogPath
    Path to SCUM log file
    .RETURNS
    Hashtable with performance metrics
    #>
    param(
        [Parameter()]
        [string]$LogPath
    )
    
    $metrics = @{
        Timestamp = Get-Date
        FPS = @{
            Average = 0
            Min = 0
            Max = 0
        }
        FrameTime = 0
        Players = 0
        Entities = @{
            Characters = 0
            Zombies = 0
            Vehicles = 0
        }
        Status = "Unknown"
        Source = "Unknown"
    }
    
    if ($LogPath -and (Test-PathExists $LogPath)) {
        # Get recent Global Stats from log
        $recentLines = Get-Content $LogPath -Tail 50 -ErrorAction SilentlyContinue
        $globalStatsLines = $recentLines | Where-Object { $_ -match 'LogSCUM: Global Stats:' }
        
        if ($globalStatsLines) {
            $latestStats = $globalStatsLines[-1]
            
            # Parse FPS data from SCUM Global Stats format:
            # LogSCUM: Global Stats: 199.2ms (  5.0FPS), 200.0ms (  5.0FPS), 201.2ms (  5.0FPS) | C:   0 (  0), P:   0 (  0), ...
            
            # Extract all FPS values from the line
            $fpsMatches = [regex]::Matches($latestStats, '\(\s*([0-9.]+)FPS\)')
            if ($fpsMatches.Count -gt 0) {
                $fpsValues = @()
                foreach ($match in $fpsMatches) {
                    $fpsValues += [double]$match.Groups[1].Value
                }
                
                $metrics.FPS.Average = [Math]::Round(($fpsValues | Measure-Object -Average).Average, 1)
                $metrics.FPS.Min = [Math]::Round(($fpsValues | Measure-Object -Minimum).Minimum, 1)
                $metrics.FPS.Max = [Math]::Round(($fpsValues | Measure-Object -Maximum).Maximum, 1)
            }
            
            # Extract frame time from the first frame time value
            if ($latestStats -match '([0-9.]+)ms\s+\(') {
                $metrics.FrameTime = [Math]::Round([double]$matches[1], 2)
            }
            
            # Parse entity counts from the abbreviated format: C: characters, P: players, Z: zombies, V: vehicles
            if ($latestStats -match 'P:\s*(\d+)') {
                $metrics.Players = [int]$matches[1]
            }
            if ($latestStats -match 'C:\s*(\d+)') {
                $metrics.Entities.Characters = [int]$matches[1]
            }
            if ($latestStats -match 'Z:\s*(\d+)') {
                $metrics.Entities.Zombies = [int]$matches[1]
            }
            if ($latestStats -match 'V:\s*(\d+)') {
                $metrics.Entities.Vehicles = [int]$matches[1]
            }
            
            $metrics.Status = Get-PerformanceStatus $metrics.FPS.Average
            $metrics.Source = "GameLog"
        } else {
            # Only log if we previously had data but now don't
            if ($script:PerformanceHistory.Count -gt 0 -and $script:PerformanceHistory[-1].Source -eq "GameLog") {
                Write-Log "[Monitoring] No Global Stats found in log file" -Level Warning
            }
        }
    } else {
        # Only log if path was previously available
        if ($script:LogFilePath -and $script:LogFilePath -ne $LogPath) {
            Write-Log "[Monitoring] Log path not available or file doesn't exist: $LogPath" -Level Warning
        }
    }
    
    # Add to performance history
    $script:PerformanceHistory += $metrics
    if ($script:PerformanceHistory.Count -gt 100) {
        $script:PerformanceHistory = $script:PerformanceHistory[-50..-1]
    }
    
    return $metrics
}

function Get-PerformanceStatus {
    <#
    .SYNOPSIS
    Determine performance status based on FPS
    .PARAMETER Fps
    Average FPS
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
    
    $thresholds = Get-SafeConfigValue $script:MonitoringConfig "performanceThresholds" @{
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

function Get-PerformanceSummary {
    <#
    .SYNOPSIS
    Get formatted performance summary string
    .PARAMETER Metrics
    Performance metrics hashtable
    .RETURNS
    Formatted summary string
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Metrics
    )
    
    if (-not $Metrics -or $Metrics.FPS.Average -eq 0) {
        return "No performance data available"
    }
    
    $summary = "FPS: $($Metrics.FPS.Average) avg"
    if ($Metrics.FPS.Min -ne $Metrics.FPS.Max -and $Metrics.FPS.Min -gt 0) {
        $summary += " ($($Metrics.FPS.Min)-$($Metrics.FPS.Max))"
    }
    $summary += ", Frame: $($Metrics.FrameTime)ms"
    $summary += ", Status: $($Metrics.Status)"
    
    if ($Metrics.Entities.Characters -gt 0 -or $Metrics.Entities.Zombies -gt 0) {
        $summary += ", Entities: C:$($Metrics.Entities.Characters) Z:$($Metrics.Entities.Zombies)"
        if ($Metrics.Entities.Vehicles -gt 0) {
            $summary += " V:$($Metrics.Entities.Vehicles)"
        }
    }
    
    return $summary
}

function Test-PerformanceAlert {
    <#
    .SYNOPSIS
    Check if performance alert should be sent
    .PARAMETER Metrics
    Performance metrics
    .RETURNS
    Boolean indicating if alert should be sent
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Metrics
    )
    
    $alertThreshold = Get-SafeConfigValue $script:MonitoringConfig "performanceAlertThreshold" "Poor"
    $alertCooldown = Get-SafeConfigValue $script:MonitoringConfig "performanceAlertCooldownMinutes" 30
    
    # Check if performance is below threshold
    $shouldAlert = switch ($alertThreshold) {
        "Critical" { $Metrics.Status -eq "Critical" }
        "Poor" { $Metrics.Status -in @("Critical", "Poor") }
        "Fair" { $Metrics.Status -in @("Critical", "Poor", "Fair") }
        default { $false }
    }
    
    if (-not $shouldAlert) {
        return $false
    }
    
    # Check cooldown
    if ($script:LastPerformanceLogTime) {
        $timeSinceLastAlert = ((Get-Date) - $script:LastPerformanceLogTime).TotalMinutes
        if ($timeSinceLastAlert -lt $alertCooldown) {
            return $false
        }
    }
    
    # Check if status has changed
    if ($Metrics.Status -eq $script:LastPerformanceStatus) {
        return $false
    }
    
    Write-Log "[Monitoring] Performance alert conditions met - sending alert for status: $($Metrics.Status)"
    return $true
}

function Send-PerformanceAlert {
    <#
    .SYNOPSIS
    Send performance alert notification
    .PARAMETER Metrics
    Performance metrics
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Metrics
    )
    
    $script:LastPerformanceLogTime = Get-Date
    $script:LastPerformanceStatus = $Metrics.Status
    
    $summary = Get-PerformanceSummary $Metrics
    
    # Map performance status to notification key
    $notificationKey = switch ($Metrics.Status) {
        "Excellent" { "performanceExcellent" }
        "Good" { "performanceGood" }
        "Fair" { "performanceFair" }
        "Poor" { "performancePoor" }
        "Critical" { "performanceCritical" }
        default { "performanceCritical" }
    }
    
    Send-Notification admin $notificationKey @{
        performanceSummary = $summary
        status = $Metrics.Status
        fps = $Metrics.FPS.Average
        frameTime = $Metrics.FrameTime
        players = $Metrics.Players
    }
    
    Write-Log "[Monitoring] Performance alert sent: $summary" -Level Warning
}

function Update-MonitoringMetrics {
    <#
    .SYNOPSIS
    Update monitoring metrics and check performance
    #>
    
    if (-not $script:MonitoringConfig) {
        Write-Log "[Monitoring] Module not initialized, skipping metrics update"
        return
    }
    
    try {
        # Get current performance metrics with stored log path
        $metrics = Get-PerformanceMetrics -LogPath $script:LogFilePath
        
        if ($metrics -and $metrics.FPS.Average -gt 0) {
            # Only log if FPS changed significantly or status changed
            $fpsChanged = $script:PerformanceHistory.Count -eq 0 -or 
                         [Math]::Abs($metrics.FPS.Average - $script:PerformanceHistory[-1].FPS.Average) -ge 2
            
            if ($fpsChanged -or $metrics.Status -ne $script:LastPerformanceStatus) {
                Write-Log "[Monitoring] Performance: FPS=$($metrics.FPS.Average), Status=$($metrics.Status)"
            }
            
            # Update performance history
            $script:PerformanceHistory += $metrics
            
            # Keep only last 10 entries to prevent memory bloat
            if ($script:PerformanceHistory.Count -gt 10) {
                $script:PerformanceHistory = $script:PerformanceHistory[-10..-1]
            }
            
            # Check for performance alerts
            if (Test-PerformanceAlert -Metrics $metrics) {
                Write-Log "[Monitoring] Sending performance alert for status: $($metrics.Status)"
                Send-PerformanceAlert -Metrics $metrics
            }
            
            # Log performance status periodically
            $performanceLogInterval = Get-SafeConfigValue $script:MonitoringConfig "performanceLogIntervalMinutes" 5
            $now = Get-Date
            
            if (-not $script:LastPerformanceLogTime -or 
                ($now - $script:LastPerformanceLogTime).TotalMinutes -ge $performanceLogInterval) {
                
                $avgFps = if ($metrics.FPS -and $metrics.FPS.Average) { $metrics.FPS.Average } else { 0 }
                $status = Get-PerformanceStatus -Fps $avgFps
                if ($status -ne $script:LastPerformanceStatus) {
                    Write-Log "[Monitoring] Performance status: $status (FPS: $avgFps)"
                    $script:LastPerformanceStatus = $status
                }
                $script:LastPerformanceLogTime = $now
            }
        } else {
            # Only log once when data becomes unavailable
            if ($script:PerformanceHistory.Count -gt 0 -and $script:PerformanceHistory[-1].FPS.Average -gt 0) {
                Write-Log "[Monitoring] Performance data no longer available" -Level Warning
            }
        }
    }
    catch {
        Write-Log "[Monitoring] Error updating metrics: $($_.Exception.Message)" -Level Warning
    }
}

function Update-ServerStatusFromEvent {
    <#
    .SYNOPSIS
    Update server status based on parsed log event
    .PARAMETER EventType
    Type of event from log parser
    .PARAMETER EventData
    Additional event data
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$EventType,
        
        [Parameter()]
        [hashtable]$EventData = @{
        }
    )
    
    # Additional safety check
    if ([string]::IsNullOrWhiteSpace($EventType)) {
        Write-Log "[Monitoring] Update-ServerStatusFromEvent called with empty EventType, ignoring" -Level Warning
        return
    }
    
    $previousStatus = $script:CurrentServerStatus.Status
    
    # Status priority for regression prevention
    $statusPriority = @{
        "Unknown" = 0
        "Offline" = 1
        "Starting" = 2
        "Loading" = 3
        "Online" = 4
        "Shutting Down" = 5
    }
    
    $newStatus = $null
    
    switch ($EventType) {
        "ServerStarting" {
            $newStatus = "Starting"
            $script:CurrentServerStatus.Phase = "Initializing"
            $script:CurrentServerStatus.Message = "Server starting up"
            $script:CurrentServerStatus.IsOnline = $false
        }
        "ServerLoading" {
            $newStatus = "Loading"
            $script:CurrentServerStatus.Phase = "Loading World"
            $script:CurrentServerStatus.Message = "Loading game world"
            $script:CurrentServerStatus.IsOnline = $false
        }
        "ServerOnline" {
            $newStatus = "Online"
            $script:CurrentServerStatus.Phase = "Online"
            $script:CurrentServerStatus.Message = "Server running normally"
            $script:CurrentServerStatus.IsOnline = $true
            
            # Update performance data if available
            if ($EventData.PerformanceStats) {
                $script:CurrentServerStatus.PerformanceStats = $EventData.PerformanceStats
                $script:CurrentServerStatus.PlayerCount = $EventData.PerformanceStats.PlayerCount
            }
        }
        "ServerShuttingDown" {
            $newStatus = "Shutting Down"
            $script:CurrentServerStatus.Phase = "Shutting Down"
            $script:CurrentServerStatus.Message = "Server shutting down"
            $script:CurrentServerStatus.IsOnline = $false
        }
        "ServerOffline" {
            $newStatus = "Offline"
            $script:CurrentServerStatus.Phase = "Offline"
            $script:CurrentServerStatus.Message = "Server stopped"
            $script:CurrentServerStatus.IsOnline = $false
            $script:CurrentServerStatus.PlayerCount = 0
        }
    }
    
    # Apply status change with regression prevention
    if ($newStatus) {
        $currentPriority = $statusPriority[$newStatus]
        $highestPriority = $statusPriority[$script:HighestStatusReached]
        
        # Allow progression or specific transitions
        if ($currentPriority -ge $highestPriority -or 
            $newStatus -eq "Shutting Down" -or 
            $newStatus -eq "Offline") {
            
            $script:CurrentServerStatus.Status = $newStatus
            $script:CurrentServerStatus.LastActivity = Get-Date
            
            # Update highest reached status (but not for shutdowns)
            if ($newStatus -notin @("Shutting Down", "Offline")) {
                $script:HighestStatusReached = $newStatus
            }
            
            # Send notifications on status change
            if ($newStatus -ne $previousStatus) {
                Write-Log "[Monitoring] Server status change: $previousStatus → $newStatus"
                Send-StatusChangeNotification -NewStatus $newStatus -PreviousStatus $previousStatus -EventData $EventData
            }
        }
    }
    
    # Update time since last activity
    if ($script:CurrentServerStatus.LastActivity) {
        $timeDiff = (Get-Date) - $script:CurrentServerStatus.LastActivity
        $script:CurrentServerStatus.TimeSinceLastActivity = $timeDiff.TotalMinutes
    }
}

function Send-StatusChangeNotification {
    <#
    .SYNOPSIS
    Send notifications based on server status changes
    .PARAMETER NewStatus
    New server status
    .PARAMETER PreviousStatus
    Previous server status
    .PARAMETER EventData
    Additional event data
    #>
    param(
        [Parameter(Mandatory)]
        [string]$NewStatus,
        
        [Parameter()]
        [string]$PreviousStatus = "",
        
        [Parameter()]
        [hashtable]$EventData = @{
        }
    )
    
    # Skip notifications during module initialization to prevent false alerts from old logs
    if ($script:IsInitializing) {
        Write-Log "[Monitoring] Skipping notification during initialization: $NewStatus"
        return
    }
    
    # Check if this is a manager startup scenario for Online status
    $timeSinceManagerStart = (Get-Date) - $script:ManagerStartTime
    $isRecentManagerStart = $timeSinceManagerStart.TotalMinutes -lt 2
    $skipOnlineNotification = ($NewStatus -eq "Online" -and $PreviousStatus -eq "Unknown" -and $isRecentManagerStart -and -not $script:FirstOnlineNotificationSent)
    
    if ($skipOnlineNotification) {
        Write-Log "[Monitoring] Skipping first Online notification due to manager startup"
        $script:FirstOnlineNotificationSent = $true
        return
    }
    
    # Send notification based on the new status
    switch ($NewStatus) {
        "Starting" {
            Write-Log "[Monitoring] Server startup detected from logs"
            Send-Notification admin "serverStarting" @{ reason = "server initialization detected in logs" }
            Send-Notification player "serverStarting" @{
            }
        }
        "Loading" {
            Write-Log "[Monitoring] Server loading detected from logs"
            Send-Notification admin "serverLoading" @{ reason = "world loading detected in logs" }
            Send-Notification player "serverLoading" @{
            }
        }
        "Online" {
            Write-Log "[Monitoring] Server online detected from logs"
            Send-Notification admin "serverOnline" @{ reason = "server ready for connections (logs)" }
            Send-Notification player "serverOnline" @{
            }
            $script:FirstOnlineNotificationSent = $true
        }
        "Shutting Down" {
            Write-Log "[Monitoring] Server shutting down detected from logs"
            Send-Notification admin "serverStopped" @{ context = "shutdown detected in logs" }
            Send-Notification player "serverOffline" @{
            }
        }
        "Offline" {
            # Double-check service status before sending offline notification to prevent false alerts
            $serviceName = Get-SafeConfigValue $script:MonitoringConfig "serviceName" "SCUMDedicatedServer"
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            $serviceIsRunning = $service -and $service.Status -eq 'Running'
            
            if ($serviceIsRunning) {
                Write-Log "[Monitoring] Service still running despite offline log - not sending offline notification"
            } else {
                Write-Log "[Monitoring] Server offline confirmed (logs + service check)"
                Send-Notification admin "serverOffline" @{ reason = "server shutdown confirmed (logs + service)" }
                Send-Notification player "serverOffline" @{
                }
            }
        }
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

function Update-ServerMonitoring {
    <#
    .SYNOPSIS
    Update server monitoring by processing new log events
    .RETURNS
    Array of processed events with IsStateChange property
    #>
    
    if (-not (Get-Command "Read-GameLogs" -ErrorAction SilentlyContinue)) {
        Write-Log "[Monitoring] LogReader module functions not available" -Level Warning
        return @()
    }
    
    try {
        # Get new parsed events from log reader
        $newEvents = Read-GameLogs
        
        # Track previous status for state change detection
        $previousStatus = $script:CurrentServerStatus.Status
        
        # Process each event to update server status and add IsStateChange property
        $processedEvents = @()
        foreach ($event in $newEvents) {
            # Update server status first (with protection against empty EventType)
            if ($event.EventType -and $event.EventType.Trim() -ne "") {
                Update-ServerStatusFromEvent -EventType $event.EventType -EventData $event.Data
            } else {
                Write-Log "[Monitoring] Skipping event with empty EventType" -Level Warning
                continue
            }
            
            # Check if this event caused a state change
            $currentStatus = $script:CurrentServerStatus.Status
            $isStateChange = ($currentStatus -ne $previousStatus)
            
            # Create enhanced event with IsStateChange property
            $enhancedEvent = @{
                EventType = $event.EventType
                Data = $event.Data
                RawLine = $event.RawLine
                Timestamp = $event.Timestamp
                IsStateChange = $isStateChange
                Message = "Server status: $currentStatus"
            }
            
            $processedEvents += $enhancedEvent
            
            # Check for performance alerts if this is a performance event
            if ($event.EventType -eq "ServerOnline" -and $event.Data.PerformanceStats) {
                Test-PerformanceAlert -Metrics $event.Data.PerformanceStats
            }
            
            # Update previous status for next iteration
            $previousStatus = $currentStatus
        }
        
        return $processedEvents
        
    } catch {
        Write-Log "[Monitoring] Error updating server monitoring: $($_.Exception.Message)" -Level Error
        return @()
    }
}

# ...existing code...
# Export functions
Export-ModuleMember -Function @(
    'Initialize-MonitoringModule',
    'Test-ServiceHealth',
    'Test-IntentionalStop',
    'Get-PerformanceMetrics',
    'Get-PerformanceStatus',
    'Get-PerformanceSummary',
    'Test-PerformanceAlert',
    'Send-PerformanceAlert',
    'Update-MonitoringMetrics',
    'Update-ServerStatusFromEvent',
    'Send-StatusChangeNotification',
    'Get-ServerStatus',
    'Update-ServerMonitoring'
)
