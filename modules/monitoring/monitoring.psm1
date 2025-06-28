# ==========================
# Monitoring Module
# ==========================

#Requires -Version 5.1
using module ..\common\common.psm1

# Module variables
$script:MonitoringConfig = $null
$script:LastPerformanceLogTime = $null
$script:LastPerformanceStatus = ""
$script:PerformanceHistory = @()
$script:HealthCheckHistory = @()
$script:LogFilePath = $null

function Initialize-MonitoringModule {
    <#
    .SYNOPSIS
    Initialize monitoring module
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
    
    Write-Log "[Monitoring] Module initialized with log path: $($script:LogFilePath)"
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
    'Update-MonitoringMetrics'
)
