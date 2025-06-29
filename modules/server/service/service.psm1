# ==========================
# Service Management Module
# ==========================

#Requires -Version 5.1
using module ..\..\core\common\common.psm1

# Import centralized event system
$AdaptersModulePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "communication\adapters.psm1"
if (Test-Path $AdaptersModulePath) {
    Import-Module $AdaptersModulePath -Force -Global -WarningAction SilentlyContinue
}

function Stop-GameService {
    <#
    .SYNOPSIS
    Stop the SCUM server service
    .PARAMETER ServiceName
    Name of the Windows service
    .PARAMETER Reason
    Reason for stop
    .PARAMETER SkipNotifications
    Skip sending stop notifications (for admin stops that handle their own notifications)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter()]
        [string]$Reason = "manual stop",
        
        [Parameter()]
        [switch]$SkipNotifications
    )
    
    Write-Log "[Service] Stopping service '$ServiceName' ($Reason)"
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        
        if ($service.Status -eq 'Stopped') {
            Write-Log "[Service] Service '$ServiceName' is already stopped"
            return $true
        }
        
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        Write-Log "[Service] Service '$ServiceName' stopped successfully"
        return $true
    }
    catch {
        Write-Log "[Service] Failed to stop service '$ServiceName': $($_.Exception.Message)" -Level Error
        return $false
    }
}

# --- MODULE VARIABLES ---
$script:serviceConfig = $null

function Initialize-ServiceModule {
    <#
    .SYNOPSIS
    Initialize the service module
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:serviceConfig = $Config
    Write-Log "[Service] Module initialized" -Level Debug
}

function Test-ServiceExists {
    <#
    .SYNOPSIS
    Check if Windows service exists
    .PARAMETER ServiceName
    Name of the Windows service
    .RETURNS
    Boolean indicating if service exists
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        return $true
    }
    catch {
        # Service not found or other error
        if ($_.Exception.Message -like "*Cannot find any service*" -or 
            $_.Exception.Message -like "*No service*" -or
            $_.Exception.GetType().Name -like "*ServiceNotFoundException*") {
            return $false
        }
        
        Write-Log "[Service] Error checking if service '$ServiceName' exists: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Test-ServiceRunning {
    <#
    .SYNOPSIS
    Check if Windows service is running
    .PARAMETER ServiceName
    Name of the Windows service
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        return $service.Status -eq 'Running'
    }
    catch [System.ServiceProcess.ServiceController+ServiceNotFoundException], [Microsoft.PowerShell.Commands.ServiceCommandException] {
        # Service doesn't exist - this is expected during first install or before service creation
        Write-Log "[Service] Service '$ServiceName' not found (may not be installed yet)" -Level Verbose
        return $false
    }
    catch {
        Write-Log "[Service] Error checking service '$ServiceName': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Start-GameService {
    <#
    .SYNOPSIS
    Start the SCUM server service
    .PARAMETER ServiceName
    Name of the Windows service
    .PARAMETER Context
    Context description for logging
    .PARAMETER SkipStartupMonitoring
    Skip startup monitoring
    .PARAMETER SkipNotifications
    Skip sending start notifications (for admin restarts that handle their own notifications)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter()]
        [string]$Context = "manual start",
        
        [Parameter()]
        [switch]$SkipStartupMonitoring,
        
        [Parameter()]
        [switch]$SkipNotifications
    )
    
    Write-Log "[Service] Starting service '$ServiceName' ($Context)"
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        
        if ($service.Status -eq 'Running') {
            Write-Log "[Service] Service '$ServiceName' is already running"
            return $true
        }
        
        Start-Service -Name $ServiceName -ErrorAction Stop
        
        if (-not $SkipStartupMonitoring) {
            # Set global startup tracking
            $global:ServiceStartInitiated = $true
            $global:ServiceStartContext = $Context
            $global:ServiceStartTime = Get-Date
        }
        
        Write-Log "[Service] Service '$ServiceName' start command sent successfully"
        return $true
    }
    catch [System.ComponentModel.Win32Exception] {
        # Handle Windows service access denied errors
        if ($_.Exception.NativeErrorCode -eq 5) {
            Write-Log "[Service] Access denied starting service '$ServiceName' - run as Administrator" -Level Error
        } else {
            Write-Log "[Service] Windows service error starting '$ServiceName': $($_.Exception.Message)" -Level Error
        }
        return $false
    }
    catch {
        # Handle all other exceptions including InvalidOperationException
        $exceptionType = $_.Exception.GetType().Name
        if ($exceptionType -like "*InvalidOperation*") {
            Write-Log "[Service] Service '$ServiceName' is in invalid state: $($_.Exception.Message)" -Level Error
        } else {
            Write-Log "[Service] Failed to start service '$ServiceName': $($_.Exception.Message)" -Level Error
        }
        return $false
    }
}

function Restart-GameService {
    <#
    .SYNOPSIS
    Restart the SCUM server service
    .PARAMETER ServiceName
    Name of the Windows service
    .PARAMETER Reason
    Reason for restart
    .PARAMETER SkipNotifications
    Skip sending restart notifications (for admin restarts that handle their own notifications)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter()]
        [string]$Reason = "restart",
        
        [Parameter()]
        [switch]$SkipNotifications
    )
    
    Write-Log "[Service] Restarting service '$ServiceName' ($Reason)"
    
    try {
        if (Stop-GameService -ServiceName $ServiceName -Reason $Reason) {
            Start-Sleep -Seconds 5
            return Start-GameService -ServiceName $ServiceName -Context $Reason
        }
        return $false
    }
    catch {
        Write-Log "[Service] Failed to restart service '$ServiceName': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Test-IntentionalStop {
    <#
    .SYNOPSIS
    Check if server was stopped intentionally (not crashed)
    .PARAMETER ServiceName
    Name of the Windows service
    .PARAMETER ServerDirectory
    Server directory path
    .PARAMETER MinutesToCheck
    How many minutes back to check
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
        # Check Application Event Log for service events
        $serviceEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'Application'
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$ServiceName*" -and (
                $_.Message -like "*stop*" -or 
                $_.Message -like "*shutdown*" -or
                $_.Message -like "*terminated*"
            )
        }
        
        if ($serviceEvents) {
            Write-Log "[Service] Application log shows service stop event - likely intentional"
            return $true
        }
        
        # Check System Event Log for service control events
        $systemEvents = Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            ID = @(7036, 7040) # Service state change, service start type change
            StartTime = $since
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$ServiceName*" -and $_.Message -like "*stopped*"
        }
        
        if ($systemEvents) {
            Write-Log "[Service] System log shows service stop event - likely intentional"
            return $true
        }
        
        # Check for clean shutdown pattern in SCUM log
        $logPath = Join-Path $ServerDirectory "SCUM\Saved\Logs\SCUM.log"
        if (Test-PathExists $logPath) {
            $logContent = Get-Content $logPath -Tail 20 -ErrorAction SilentlyContinue
            $cleanShutdownPatterns = @(
                "LogExit:",
                "Shutdown requested",
                "Engine exit requested",
                "Game thread exit",
                "Clean shutdown"
            )
            
            foreach ($pattern in $cleanShutdownPatterns) {
                if ($logContent -match $pattern) {
                    Write-Log "[Service] Clean shutdown pattern found in log: $pattern"
                    return $true
                }
            }
        }
        
        # Consider timing - stops during normal hours are more likely intentional
        $currentHour = (Get-Date).Hour
        if ($currentHour -ge 8 -and $currentHour -le 22) {
            Write-Log "[Service] Service stopped during normal hours - more likely intentional"
        }
        
    }
    catch {
        Write-Log "[Service] Error checking intentional stop: $($_.Exception.Message)" -Level Error
    }
    
    # Default to false - treat as unintentional unless we have clear evidence
    Write-Log "[Service] No clear evidence of intentional stop found"
    return $false
}

function Get-ServiceInfo {
    <#
    .SYNOPSIS
    Get detailed service information
    .PARAMETER ServiceName
    Name of the Windows service
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )
    
    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop
        
        return @{
            Name = $service.Name
            DisplayName = $service.DisplayName
            Status = $service.Status
            StartType = $service.StartType
            CanStop = $service.CanStop
            CanRestart = $service.CanStop
        }
    }
    catch {
        Write-Log "[Service] Failed to get service info for '$ServiceName': $($_.Exception.Message)" -Level Error
        return @{
            Name = $ServiceName
            Status = "NotFound"
            Error = $_.Exception.Message
        }
    }
}

function Watch-ServiceStartup {
    <#
    .SYNOPSIS
    Monitor service startup progress
    .PARAMETER ServiceName
    Name of the Windows service
    .PARAMETER TimeoutMinutes
    Startup timeout in minutes
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter()]
        [int]$TimeoutMinutes = 10
    )
    
    $startTime = Get-Date
    $timeoutTime = $startTime.AddMinutes($TimeoutMinutes)
    
    Write-Log "[Service] Monitoring startup of '$ServiceName' (timeout: $TimeoutMinutes min)"
    
    while ((Get-Date) -lt $timeoutTime) {
        $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        
        if ($service -and $service.Status -eq 'Running') {
            $elapsed = ((Get-Date) - $startTime).TotalMinutes
            Write-Log "[Service] Service '$ServiceName' started successfully after $([Math]::Round($elapsed, 1)) minutes"
            return $true
        }
        
        Start-Sleep -Seconds 5
    }
    
    Write-Log "[Service] Service '$ServiceName' startup timeout after $TimeoutMinutes minutes" -Level Warning
    return $false
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-ServiceModule',
    'Test-ServiceExists',
    'Test-ServiceRunning',
    'Start-GameService',
    'Stop-GameService', 
    'Restart-GameService',
    'Test-IntentionalStop',
    'Get-ServiceInfo',
    'Watch-ServiceStartup'
)
