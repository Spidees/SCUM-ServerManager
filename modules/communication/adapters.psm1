# ==========================
# Event System Integration
# ==========================

#Requires -Version 5.1

# Import event system
$EventModulePath = Join-Path $PSScriptRoot "events\events.psm1"
if (Test-Path $EventModulePath) {
    Import-Module $EventModulePath -Force -Global
}

# Compatibility wrapper functions that map legacy calls to new event system
# These allow gradual migration from direct Send-Notification calls to centralized events

function Send-ServerStartingEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.starting" -Context $Context
}

function Send-ServerLoadingEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.loading" -Context $Context
}

function Send-ServerOnlineEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.online" -Context $Context
}

function Send-ServerOfflineEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.offline" -Context $Context
}

function Send-ServerRestartingEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.restarting" -Context $Context
}

function Send-ServerRestartedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.restarted" -Context $Context
}

function Send-ServerCrashedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.crashed" -Context $Context -SkipRateLimit
}

function Send-AdminRestartScheduledEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.restart.scheduled" -Context $Context
}

function Send-AdminRestartImmediateEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.restart.immediate" -Context $Context
}

function Send-AdminRestartWarningEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.restart.warning" -Context $Context
}

function Send-AdminStopScheduledEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.stop.scheduled" -Context $Context
}

function Send-AdminStopImmediateEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.stop.immediate" -Context $Context
}

function Send-AdminStopWarningEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.stop.warning" -Context $Context
}

function Send-AdminUpdateScheduledEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.update.scheduled" -Context $Context
}

function Send-AdminUpdateImmediateEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.update.immediate" -Context $Context
}

function Send-AdminUpdateWarningEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.update.warning" -Context $Context
}

function Send-AdminActionCancelledEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.action.cancelled" -Context $Context
}

function Send-UpdateAvailableEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "update.available" -Context $Context
}

function Send-UpdateInProgressEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "update.inprogress" -Context $Context
}

function Send-UpdateCompletedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "update.completed" -Context $Context
}

function Send-UpdateFailedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "update.failed" -Context $Context
}

function Send-ManagerStartedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "manager.started" -Context $Context
}

function Send-StartupTimeoutEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "startup.timeout" -Context $Context
}

function Send-BackupCompletedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "backup.completed" -Context $Context
}

function Send-BackupFailedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "backup.failed" -Context $Context
}

function Send-FirstInstallStartedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "installation.started" -Context $Context
}

function Send-FirstInstallCompletedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "installation.completed" -Context $Context
}

function Send-FirstInstallFailedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "installation.failed" -Context $Context
}

function Send-ScheduledRestartEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "restart.scheduled" -Context $Context
}

function Send-RestartSkippedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "restart.skipped" -Context $Context
}

function Send-AdminActionsCancelledEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "admin.actions.cancelled" -Context $Context
}

function Send-ServerStartedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "server.started" -Context $Context
}

function Send-ServerRestartFailedEvent {
    param([hashtable]$Context = @{})
    Invoke-ServerEvent -EventType "restart.failed" -Context $Context
}

# Generic admin command handler that can route to appropriate events
function Send-AdminCommandEvent {
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        
        [Parameter()]
        [hashtable]$Context = @{}
    )
    
    # Ensure required context keys are present and not empty
    if (-not $Context.ContainsKey('command') -or [string]::IsNullOrWhiteSpace($Context['command'])) {
        $Context['command'] = $Command
    }
    if (-not $Context.ContainsKey('executor') -or [string]::IsNullOrWhiteSpace($Context['executor'])) {
        $Context['executor'] = "Unknown User"
    }
    if (-not $Context.ContainsKey('result') -or [string]::IsNullOrWhiteSpace($Context['result'])) {
        $Context['result'] = "Command processed"
    }
    
    # Route admin commands to appropriate events
    $eventType = switch -Regex ($Command) {
        "restart.*scheduled" { "admin.restart.scheduled" }
        "restart.*immediate" { "admin.restart.immediate" }
        "stop.*scheduled" { "admin.stop.scheduled" }
        "stop.*immediate" { "admin.stop.immediate" }
        "update.*scheduled" { "admin.update.scheduled" }
        "update.*immediate" { "admin.update.immediate" }
        "cancel" { "admin.action.cancelled" }
        default { $null }
    }
    
    if ($eventType) {
        Invoke-ServerEvent -EventType $eventType -Context $Context
    } else {
        # Use generic admin command event
        Invoke-ServerEvent -EventType "admin.command.executed" -Context $Context
    }
}

# Compatibility function for existing code that uses Send-Notification directly
# This allows existing code to work while new code uses events
function Send-NotificationViaEvent {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('admin', 'player')]
        [string]$Type,
        
        [Parameter(Mandatory)]
        [string]$MessageKey,
        
        [Parameter()]
        [hashtable]$Vars = @{},
        
        [Parameter()]
        [switch]$SkipRateLimit
    )
    
    # Map message keys to event types where possible
    $eventType = $null
    
    # Server state mappings
    switch ($MessageKey) {
        "serverStarting" { $eventType = "server.starting" }
        "serverLoading" { $eventType = "server.loading" }
        "serverOnline" { $eventType = "server.online" }
        "serverOffline" { $eventType = "server.offline" }
        "serverStopped" { $eventType = "server.offline" }
        "serverRestarting" { $eventType = "server.restarting" }
        "serverRestarted" { $eventType = "server.restarted" }
        "serverCrashed" { $eventType = "server.crashed" }
        
        # Admin action mappings
        "adminRestartScheduled" { $eventType = "admin.restart.scheduled" }
        "adminRestartImmediate" { $eventType = "admin.restart.immediate" }
        "adminRestartWarning" { $eventType = "admin.restart.warning" } 
        "adminStopScheduled" { $eventType = "admin.stop.scheduled" }
        "adminStopImmediate" { $eventType = "admin.stop.immediate" }
        "adminStopWarning" { $eventType = "admin.stop.warning" }
        "adminUpdateScheduled" { $eventType = "admin.update.scheduled" }
        "adminUpdateImmediate" { $eventType = "admin.update.immediate" }
        "adminUpdateWarning" { $eventType = "admin.update.warning" }
        
        # Update mappings
        "updateAvailable" { $eventType = "update.available" }
        "updateInProgress" { $eventType = "update.inprogress" }
        "updateCompleted" { $eventType = "update.completed" }
        "updateFailed" { $eventType = "update.failed" }
        
        # System mappings
        "managerStarted" { $eventType = "manager.started" }
        "startupTimeout" { $eventType = "startup.timeout" }
    }
    
    if ($eventType) {
        # Use centralized event system
        Invoke-ServerEvent -EventType $eventType -Context $Vars -SkipRateLimit:$SkipRateLimit
    } else {
        # Fallback to direct notification for unmapped message keys
        if (Get-Command "Send-Notification" -ErrorAction SilentlyContinue) {
            Send-Notification -Type $Type -MessageKey $MessageKey -Vars $Vars -SkipRateLimit:$SkipRateLimit
        }
    }
}

# Export all functions
Export-ModuleMember -Function @(
    'Send-ServerStartingEvent',
    'Send-ServerLoadingEvent',
    'Send-ServerOnlineEvent',
    'Send-ServerOfflineEvent',
    'Send-ServerRestartingEvent',
    'Send-ServerRestartedEvent',
    'Send-ServerCrashedEvent',
    'Send-AdminRestartScheduledEvent',
    'Send-AdminRestartImmediateEvent',
    'Send-AdminRestartWarningEvent',
    'Send-AdminStopScheduledEvent',
    'Send-AdminStopImmediateEvent',
    'Send-AdminStopWarningEvent',
    'Send-AdminUpdateScheduledEvent',
    'Send-AdminUpdateImmediateEvent',
    'Send-AdminUpdateWarningEvent',
    'Send-AdminActionCancelledEvent',
    'Send-UpdateAvailableEvent',
    'Send-UpdateInProgressEvent',
    'Send-UpdateCompletedEvent',
    'Send-UpdateFailedEvent',
    'Send-ManagerStartedEvent',
    'Send-StartupTimeoutEvent',
    'Send-BackupCompletedEvent',
    'Send-BackupFailedEvent',
    'Send-FirstInstallStartedEvent',
    'Send-FirstInstallCompletedEvent',
    'Send-FirstInstallFailedEvent',
    'Send-ScheduledRestartEvent',
    'Send-RestartSkippedEvent',
    'Send-AdminActionsCancelledEvent',
    'Send-ServerStartedEvent',
    'Send-ServerRestartFailedEvent',
    'Send-AdminCommandEvent',
    'Send-NotificationViaEvent'
)
