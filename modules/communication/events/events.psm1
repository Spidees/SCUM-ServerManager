# ==========================
# Centralized Event System
# ==========================

#Requires -Version 5.1

# Set UTF-8 encoding for proper emoji support
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Import common module with new structure
$ModulesRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$CommonModulePath = Join-Path $ModulesRoot "core\common\common.psm1"
if (Test-Path $CommonModulePath) {
    Import-Module $CommonModulePath -Force -Global
}

# Import notification module
$NotificationModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "notifications\notifications.psm1"
if (Test-Path $NotificationModulePath) {
    Import-Module $NotificationModulePath -Force -Global
}

# Module variables
$script:eventConfig = $null
$script:eventHandlers = @{}
$script:eventHistory = @{}

# Event type definitions with default notification mappings
# CLEANED UP - Contains only events actually used by the system
$script:EventTypes = @{
    # Server lifecycle events
    "server.starting" = @{
        adminNotification = "serverStarting"
        playerNotification = "serverStarting"
        description = "Server is starting up"
        priority = "normal"
    }
    "server.loading" = @{
        adminNotification = "serverLoading"
        playerNotification = "serverLoading"
        description = "Server is loading world"
        priority = "normal"
    }
    "server.online" = @{
        adminNotification = "serverOnline"
        playerNotification = "serverOnline"
        description = "Server is online and ready"
        priority = "normal"
    }
    "server.offline" = @{
        adminNotification = "serverStopped"
        playerNotification = "serverOffline"
        description = "Server is offline"
        priority = "normal"
    }
    "server.restarting" = @{
        adminNotification = "serverRestarting"
        playerNotification = "serverRestarting"
        description = "Server is restarting"
        priority = "normal"
    }
    "server.restarted" = @{
        adminNotification = "serverRestarted"
        playerNotification = "serverOnline"
        description = "Server restart completed"
        priority = "normal"
    }
    "server.started" = @{
        adminNotification = "serverStarted"
        playerNotification = "serverOnline"
        description = "Server startup completed"
        priority = "normal"
    }
    "server.crashed" = @{
        adminNotification = "serverCrashed"
        playerNotification = $null
        description = "Server has crashed"
        priority = "critical"
    }
    
    # Admin action events
    "admin.restart.scheduled" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminRestartScheduled"
        description = "Admin scheduled server restart"
        priority = "high"
    }
    "admin.restart.immediate" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminRestartImmediate"
        description = "Admin initiated immediate restart"
        priority = "high"
    }
    "admin.restart.warning" = @{
        adminNotification = $null
        playerNotification = "adminRestartWarning"
        description = "Warning about upcoming restart"
        priority = "high"
    }
    "admin.stop.scheduled" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminStopScheduled"
        description = "Admin scheduled server stop"
        priority = "high"
    }
    "admin.stop.immediate" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminStopImmediate"
        description = "Admin initiated immediate stop"
        priority = "high"
    }
    "admin.stop.warning" = @{
        adminNotification = $null
        playerNotification = "adminStopWarning"
        description = "Warning about upcoming stop"
        priority = "high"
    }
    "admin.update.scheduled" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminUpdateScheduled"
        description = "Admin scheduled server update"
        priority = "high"
    }
    "admin.update.immediate" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminUpdateImmediate"
        description = "Admin initiated immediate update"
        priority = "high"
    }
    "admin.update.warning" = @{
        adminNotification = $null
        playerNotification = "adminUpdateWarning"
        description = "Warning about upcoming update"
        priority = "high"
    }
    "admin.action.cancelled" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminActionCancelled"
        description = "Admin cancelled scheduled action"
        priority = "normal"
    }
    "admin.actions.cancelled" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = "adminActionCancelled"
        description = "Admin cancelled multiple actions"
        priority = "normal"
    }
    "admin.command.executed" = @{
        adminNotification = "adminCommandExecuted"
        playerNotification = $null
        description = "Admin command executed"
        priority = "high"
    }
    
    # Restart warning events (keeping original names for scheduling compatibility)
    "restartWarning15" = @{
        adminNotification = $null
        playerNotification = "restartWarning15"
        description = "15 minute restart warning"
        priority = "high"
    }
    "restartWarning5" = @{
        adminNotification = $null
        playerNotification = "restartWarning5"
        description = "5 minute restart warning"
        priority = "high"
    }
    "restartWarning1" = @{
        adminNotification = $null
        playerNotification = "restartWarning1"
        description = "1 minute restart warning"
        priority = "critical"
    }
    
    # Update events
    "update.available" = @{
        adminNotification = "updateAvailable"
        playerNotification = $null
        description = "Server update is available"
        priority = "normal"
    }
    "update.inprogress" = @{
        adminNotification = "updateInProgress"
        playerNotification = $null
        description = "Server update in progress"
        priority = "normal"
    }
    "update.completed" = @{
        adminNotification = "updateCompleted"  
        playerNotification = $null
        description = "Server update completed"
        priority = "normal"
    }
    "update.failed" = @{
        adminNotification = "updateFailed"
        playerNotification = $null
        description = "Server update failed"
        priority = "high"
    }
    
    # System events
    "manager.started" = @{
        adminNotification = "managerStarted"
        playerNotification = $null
        description = "Server manager started"
        priority = "normal"
    }
    "startup.timeout" = @{
        adminNotification = "startupTimeout"
        playerNotification = $null
        description = "Server startup timeout"
        priority = "high"
    }
    
    # Backup events  
    "backup.completed" = @{
        adminNotification = "backupCompleted"
        playerNotification = $null
        description = "Backup process completed"
        priority = "normal"
    }
    "backup.failed" = @{
        adminNotification = "backupFailed"
        playerNotification = $null
        description = "Backup process failed"
        priority = "high"
    }
    
    # Installation events
    "installation.started" = @{
        adminNotification = "firstInstall"
        playerNotification = $null
        description = "Installation started"
        priority = "normal"
    }
    "installation.completed" = @{
        adminNotification = "firstInstallComplete"
        playerNotification = $null
        description = "Installation completed"
        priority = "normal"
    }
    "installation.failed" = @{
        adminNotification = "installFailed"
        playerNotification = $null
        description = "Installation failed"
        priority = "high"
    }
    
    # Restart events
    "restart.scheduled" = @{
        adminNotification = "scheduledRestart"
        playerNotification = $null
        description = "Scheduled restart executed"
        priority = "normal"
    }
    "restart.skipped" = @{
        adminNotification = "restartSkipped"
        playerNotification = $null
        description = "Scheduled restart skipped"
        priority = "normal"
    }
    "restart.failed" = @{
        adminNotification = "autoRestartError"
        playerNotification = $null
        description = "Server restart failed"
        priority = "high"
    }
    
    # Performance events
    "performance.excellent" = @{
        adminNotification = "performanceExcellent"
        playerNotification = $null
        description = "Excellent performance"
        priority = "normal"
    }
    "performance.good" = @{
        adminNotification = "performanceGood"
        playerNotification = $null
        description = "Good performance"
        priority = "normal"
    }
    "performance.fair" = @{
        adminNotification = "performanceFair"
        playerNotification = $null
        description = "Fair performance"
        priority = "normal"
    }
    "performance.poor" = @{
        adminNotification = "performancePoor"
        playerNotification = $null
        description = "Poor performance detected"
        priority = "high"
    }
    "performance.critical" = @{
        adminNotification = "performanceCritical"
        playerNotification = $null
        description = "Critical performance issue"
        priority = "critical"
    }
}

function Initialize-EventSystem {
    <#
    .SYNOPSIS
    Initialize the centralized event system
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:eventConfig = $Config
    
    # Initialize tracking
    if (-not $global:EventHistory) {
        $global:EventHistory = @{}
    }
    
    # Initialize notification module if not already done
    if (Get-Command "Initialize-NotificationModule" -ErrorAction SilentlyContinue) {
        Initialize-NotificationModule -Config $Config
    }
    
    Write-Log "[Events] Centralized event system initialized with $($script:EventTypes.Count) event types"
}

function Invoke-ServerEvent {
    <#
    .SYNOPSIS
    Dispatch a server event through the centralized system
    .PARAMETER EventType
    Type of event (e.g., "server.online", "admin.restart.scheduled")
    .PARAMETER Context
    Event context data (variables for templates)
    .PARAMETER SkipRateLimit
    Skip rate limiting for critical events
    .PARAMETER ForceNotification
    Force notification even if disabled
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EventType,
        
        [Parameter()]
        [hashtable]$Context = @{},
        
        [Parameter()]
        [switch]$SkipRateLimit,
        
        [Parameter()]
        [switch]$ForceNotification
    )
    
    if (-not $script:eventConfig) {
        Write-Log "[Events] Event system not initialized" -Level Warning
        return
    }
    
    # Check if event type is defined
    if (-not $script:EventTypes.ContainsKey($EventType)) {
        Write-Log "[Events] Unknown event type: $EventType" -Level Warning
        return
    }
    
    $eventDef = $script:EventTypes[$EventType]
    $timestamp = Get-Date
    
    # Log the event
    Write-Log "[Events] Processing event: $EventType - $($eventDef.description)" -Level Debug
    if ($Context.Count -gt 0) {
        $contextStr = ($Context.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
        Write-Log "[Events] Event context: $contextStr" -Level Debug
    }
    
    # Check rate limiting based on event priority
    if (-not $SkipRateLimit -and -not $ForceNotification -and $eventDef.priority -ne "critical") {
        $rateLimitKey = $EventType
        if ($global:EventHistory[$rateLimitKey]) {
            $timeSince = ($timestamp - $global:EventHistory[$rateLimitKey]).TotalMinutes
            $rateLimitMinutes = switch ($eventDef.priority) {
                "high" { 0.5 }    # 30 seconds for high priority
                "normal" { 1 }    # 1 minute for normal priority
                default { 1 }
            }
            
            if ($timeSince -lt $rateLimitMinutes) {
                Write-Log "[Events] Rate limited: $EventType ($([Math]::Round($timeSince, 1))min ago)" -Level Debug
                return
            }
        }
    }
    
    # Update event history
    $global:EventHistory[$EventType] = $timestamp
    
    # Send notifications
    $notificationsSent = 0
    
    # Admin notification
    if ($eventDef.adminNotification -and (Get-Command "Send-Notification" -ErrorAction SilentlyContinue)) {
        try {
            Send-Notification -Type "admin" -MessageKey $eventDef.adminNotification -Vars $Context -SkipRateLimit:$SkipRateLimit
            $notificationsSent++
        }
        catch {
            Write-Log "[Events] Failed to send admin notification for $EventType`: $($_.Exception.Message)" -Level Warning
        }
    }
    
    # Player notification
    if ($eventDef.playerNotification -and (Get-Command "Send-Notification" -ErrorAction SilentlyContinue)) {
        try {
            Send-Notification -Type "player" -MessageKey $eventDef.playerNotification -Vars $Context -SkipRateLimit:$SkipRateLimit
            $notificationsSent++
        }
        catch {
            Write-Log "[Events] Failed to send player notification for $EventType`: $($_.Exception.Message)" -Level Warning
        }
    }
    
    # Execute any custom handlers
    if ($script:eventHandlers[$EventType]) {
        foreach ($handler in $script:eventHandlers[$EventType]) {
            try {
                & $handler $EventType $Context
            }
            catch {
                Write-Log "[Events] Event handler failed for $EventType`: $($_.Exception.Message)" -Level Warning
            }
        }
    }
    
    Write-Log "[Events] Event $EventType processed - $notificationsSent notifications sent"
}

function Register-EventHandler {
    <#
    .SYNOPSIS
    Register a custom event handler
    .PARAMETER EventType
    Event type to handle
    .PARAMETER Handler
    Script block to execute when event fires
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EventType,
        
        [Parameter(Mandatory)]
        [scriptblock]$Handler
    )
    
    if (-not $script:eventHandlers[$EventType]) {
        $script:eventHandlers[$EventType] = @()
    }
    
    $script:eventHandlers[$EventType] += $Handler
    Write-Log "[Events] Registered handler for event type: $EventType"
}

function Get-EventTypes {
    <#
    .SYNOPSIS
    Get all available event types
    #>
    return $script:EventTypes.Keys | Sort-Object
}

function Get-EventDefinition {
    <#
    .SYNOPSIS
    Get definition for a specific event type
    .PARAMETER EventType
    Event type to get definition for
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EventType
    )
    
    return $script:EventTypes[$EventType]
}

function Clear-EventHistory {
    <#
    .SYNOPSIS
    Clean up old event history
    #>
    $cutoffTime = (Get-Date).AddHours(-24)
    $keysToRemove = @()
    
    foreach ($key in $global:EventHistory.Keys) {
        if ($global:EventHistory[$key] -lt $cutoffTime) {
            $keysToRemove += $key
        }
    }
    
    foreach ($key in $keysToRemove) {
        $global:EventHistory.Remove($key)
    }
    
    Write-Log "[Events] Cleaned up $($keysToRemove.Count) old event history entries"
}

function Show-EventSystemStatus {
    <#
    .SYNOPSIS
    Display current event system status
    #>
    Write-Log "[Events] === Event System Status ==="
    Write-Log "[Events] Registered event types: $($script:EventTypes.Count)"
    Write-Log "[Events] Active handlers: $($script:eventHandlers.Count)"
    Write-Log "[Events] Recent events (last 24h): $($global:EventHistory.Count)"
    
    if ($global:EventHistory.Count -gt 0) {
        $recentEvents = $global:EventHistory.GetEnumerator() | 
            Sort-Object Value -Descending | 
            Select-Object -First 10
        
        Write-Log "[Events] Most recent events:"
        foreach ($event in $recentEvents) {
            $timeAgo = [Math]::Round(((Get-Date) - $event.Value).TotalMinutes, 1)
            Write-Log "[Events]   $($event.Key) - ${timeAgo}min ago"
        }
    }
    
    Write-Log "[Events] === End Status ==="
}

# Legacy compatibility functions - these will gradually be replaced
function Send-ServerStatusChange {
    param(
        [Parameter(Mandatory)]
        [string]$NewStatus,
        
        [Parameter()]
        [string]$PreviousStatus,
        
        [Parameter()]
        [hashtable]$Context = @{}
    )
    
    $eventType = switch ($NewStatus) {
        "Starting" { "server.starting" }
        "Loading" { "server.loading" }
        "Online" { "server.online" }
        "Offline" { "server.offline" }
        "Restarting" { "server.restarting" }
        default { $null }
    }
    
    if ($eventType) {
        Invoke-ServerEvent -EventType $eventType -Context $Context
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-EventSystem',
    'Invoke-ServerEvent',
    'Register-EventHandler',
    'Get-EventTypes',
    'Get-EventDefinition',
    'Clear-EventHistory',
    'Show-EventSystemStatus',
    'Send-ServerStatusChange'
)
