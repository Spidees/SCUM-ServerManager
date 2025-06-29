# ==========================
# Scheduling Module
# ==========================

#Requires -Version 5.1
using module ..\..\core\common\common.psm1
using module ..\..\communication\adapters.psm1

# Module variables
$script:SchedulingConfig = $null
$script:RestartWarningDefs = @(
    @{ key = 'restartWarning15'; minutes = 15 },
    @{ key = 'restartWarning5'; minutes = 5 },
    @{ key = 'restartWarning1'; minutes = 1 }
)

function Initialize-SchedulingModule {
    <#
    .SYNOPSIS
    Initialize the scheduling module
    .PARAMETER Config
    Configuration object
    #>
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    
    $script:SchedulingConfig = $Config
    Write-Log "[Scheduling] Module initialized" -Level Debug
}

function Get-NextScheduledRestart {
    <#
    .SYNOPSIS
    Get the next scheduled restart time
    .PARAMETER RestartTimes
    Array of restart times in HH:mm format
    .RETURNS
    DateTime object representing next restart time
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

function Initialize-RestartWarningSystem {
    <#
    .SYNOPSIS
    Initialize restart warning system with tracking
    .PARAMETER RestartTimes
    Array of restart times in HH:mm format
    .RETURNS
    Hashtable with warning system state
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$RestartTimes
    )
    
    $nextRestartTime = Get-NextScheduledRestart -RestartTimes $RestartTimes
    $restartWarningSent = @{}
    
    foreach ($def in $script:RestartWarningDefs) { 
        $restartWarningSent[$def.key] = $false 
    }
    
    Write-Log "[Scheduling] Next scheduled restart: $($nextRestartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    
    return @{
        NextRestartTime = $nextRestartTime
        WarningSent = $restartWarningSent
        RestartPerformedTime = $null
        RestartTimes = $RestartTimes
    }
}

function Update-RestartWarnings {
    <#
    .SYNOPSIS
    Process restart warnings and check if any should be sent
    .PARAMETER WarningState
    Warning system state hashtable
    .PARAMETER CurrentTime
    Current date/time
    .RETURNS
    Updated warning state
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$WarningState,
        
        [Parameter()]
        [datetime]$CurrentTime = (Get-Date)
    )
    
    foreach ($def in $script:RestartWarningDefs) {
        $warnTime = $WarningState.NextRestartTime.AddMinutes(-$def.minutes)
        
        if (-not $WarningState.WarningSent[$def.key] -and 
            $CurrentTime -ge $warnTime -and 
            $CurrentTime -lt $warnTime.AddSeconds(30)) {
            
            $timeStr = $WarningState.NextRestartTime.ToString('HH:mm')
            Invoke-ServerEvent -EventType $def.key -Context @{ time = $timeStr }
            Write-Log "[Scheduling] Sent restart warning: $($def.key)"
            $WarningState.WarningSent[$def.key] = $true
        }
    }
    
    return $WarningState
}

function Test-ScheduledRestartDue {
    <#
    .SYNOPSIS
    Check if scheduled restart is due
    .PARAMETER WarningState
    Warning system state hashtable
    .PARAMETER CurrentTime
    Current date/time
    .RETURNS
    Boolean indicating if restart should be executed
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$WarningState,
        
        [Parameter()]
        [datetime]$CurrentTime = (Get-Date)
    )
    
    return ($WarningState.RestartPerformedTime -ne $WarningState.NextRestartTime) -and 
           $CurrentTime -ge $WarningState.NextRestartTime -and 
           $CurrentTime -lt $WarningState.NextRestartTime.AddMinutes(1)
}

function Invoke-ScheduledRestart {
    <#
    .SYNOPSIS
    Execute scheduled restart with backup
    .PARAMETER WarningState
    Warning system state hashtable
    .PARAMETER ServiceName
    Windows service name
    .PARAMETER SkipRestart
    Skip this restart if requested
    .RETURNS
    Updated warning state
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$WarningState,
        
        [Parameter(Mandatory)]
        [string]$ServiceName,
        
        [Parameter()]
        [bool]$SkipRestart = $false
    )
    
    if ($SkipRestart) {
        Write-Log "[Scheduling] Skipping scheduled restart as requested"
        Send-RestartSkippedEvent @{ 
            event = ":fast_forward: Scheduled restart at $($WarningState.NextRestartTime.ToString('HH:mm:ss')) was skipped as requested" 
        }
    } else {
        Write-Log "[Scheduling] Executing scheduled restart"
        Send-ScheduledRestartEvent @{ time = $WarningState.NextRestartTime.ToString('HH:mm:ss') }
        
        # Create backup before restart
        $savedDir = Get-ConfigPath -PathKey "savedDir" -ErrorAction SilentlyContinue
        $backupRoot = Get-ConfigPath -PathKey "backupRoot" -ErrorAction SilentlyContinue
        $maxBackups = Get-SafeConfigValue $script:SchedulingConfig "maxBackups" 10
        $compressBackups = Get-SafeConfigValue $script:SchedulingConfig "compressBackups" $true
        
        if ($savedDir -and $backupRoot) {
            Invoke-GameBackup -SourcePath $savedDir -BackupRoot $backupRoot -MaxBackups $maxBackups -CompressBackups $compressBackups
        }
        
        # Restart service
        Restart-GameService -ServiceName $ServiceName -Reason "scheduled restart"
    }
    
    # Update restart tracking and move to next restart
    $WarningState.RestartPerformedTime = $WarningState.NextRestartTime
    $WarningState.NextRestartTime = Get-NextScheduledRestart -RestartTimes $WarningState.RestartTimes
    
    # Reset warning flags
    foreach ($def in $script:RestartWarningDefs) { 
        $WarningState.WarningSent[$def.key] = $false 
    }
    
    Write-Log "[Scheduling] Next scheduled restart: $($WarningState.NextRestartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
    
    return $WarningState
}

function Get-RestartWarningDefinitions {
    <#
    .SYNOPSIS
    Get restart warning definitions
    .RETURNS
    Array of warning definitions
    #>
    
    return $script:RestartWarningDefs
}

function Set-RestartWarningDefinitions {
    <#
    .SYNOPSIS
    Set custom restart warning definitions
    .PARAMETER Definitions
    Array of warning definitions
    #>
    param(
        [Parameter(Mandatory)]
        [array]$Definitions
    )
    
    $script:RestartWarningDefs = $Definitions
    Write-Log "[Scheduling] Updated restart warning definitions: $($Definitions.Count) warnings configured"
}

function Get-SchedulingStats {
    <#
    .SYNOPSIS
    Get scheduling statistics and information
    .PARAMETER WarningState
    Warning system state hashtable
    .RETURNS
    Hashtable with scheduling information
    #>
    param(
        [Parameter()]
        [hashtable]$WarningState
    )
    
    if (-not $WarningState) {
        return @{
            Initialized = $false
            NextRestart = $null
            WarningsConfigured = $script:RestartWarningDefs.Count
        }
    }
    
    $now = Get-Date
    $timeToRestart = if ($WarningState.NextRestartTime) {
        ($WarningState.NextRestartTime - $now).TotalMinutes
    } else { $null }
    
    return @{
        Initialized = $true
        NextRestart = $WarningState.NextRestartTime
        TimeToRestartMinutes = $timeToRestart
        WarningsConfigured = $script:RestartWarningDefs.Count
        WarningSentStatus = $WarningState.WarningSent
        LastRestartPerformed = $WarningState.RestartPerformedTime
    }
}

# Export module functions
Export-ModuleMember -Function @(
    'Initialize-SchedulingModule',
    'Get-NextScheduledRestart',
    'Initialize-RestartWarningSystem',
    'Update-RestartWarnings',
    'Test-ScheduledRestartDue',
    'Invoke-ScheduledRestart',
    'Get-RestartWarningDefinitions',
    'Set-RestartWarningDefinitions',
    'Get-SchedulingStats'
)
