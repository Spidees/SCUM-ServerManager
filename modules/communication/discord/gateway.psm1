# ==========================
# Discord Gateway WebSocket Module
# ==========================

#Requires -Version 5.1

# Import dependencies
$ModulesRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
Import-Module (Join-Path $ModulesRoot "core\common\common.psm1") -Force -Global

# Module variables
$script:GatewayConnection = $null
$script:HeartbeatTimer = $null
$script:IsConnected = $false
$script:SessionId = $null
$script:LastSequence = $null
$script:BotToken = $null
$script:EventHandlers = @{}
$script:ReconnectAttempts = 0
$script:MaxReconnectAttempts = 5

# Discord Gateway opcodes
$script:GatewayOpcodes = @{
    DISPATCH = 0
    HEARTBEAT = 1
    IDENTIFY = 2
    PRESENCE_UPDATE = 3
    VOICE_STATE_UPDATE = 4
    RESUME = 6
    RECONNECT = 7
    REQUEST_GUILD_MEMBERS = 8
    INVALID_SESSION = 9
    HELLO = 10
    HEARTBEAT_ACK = 11
}

function Initialize-DiscordGateway {
    <#
    .SYNOPSIS
    Initialize Discord Gateway connection
    .PARAMETER BotToken
    Discord bot token
    .PARAMETER Intents
    Gateway intents (default: basic bot intents)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BotToken,
        
        [Parameter()]
        [int]$Intents = 513  # GUILDS + GUILD_MESSAGES
    )
    
    $script:BotToken = $BotToken
    $script:Intents = $Intents
    
    Write-Log "[Gateway] Initializing Discord Gateway connection..."
    
    try {
        # Get Gateway URL
        $gatewayUrl = Get-DiscordGatewayUrl
        if (-not $gatewayUrl) {
            throw "Failed to get Discord Gateway URL"
        }
        
        # Connect to Gateway
        Connect-DiscordGateway -GatewayUrl $gatewayUrl
        
        Write-Log "[Gateway] Discord Gateway initialized successfully"
        return $true
        
    } catch {
        Write-Log "[Gateway] Failed to initialize Discord Gateway: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Get-DiscordGatewayUrl {
    <#
    .SYNOPSIS
    Get Discord Gateway URL from API
    #>
    try {
        $headers = @{
            Authorization = "Bot $script:BotToken"
            "User-Agent" = "SCUM-Server-Manager/2.0"
        }
        
        $response = Invoke-RestMethod -Uri "https://discord.com/api/v10/gateway/bot" -Headers $headers -Method Get
        $gatewayUrl = $response.url + "?v=10&encoding=json"
        
        Write-Log "[Gateway] Gateway URL retrieved: $gatewayUrl"
        return $gatewayUrl
        
    } catch {
        Write-Log "[Gateway] Failed to get Gateway URL: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Connect-DiscordGateway {
    <#
    .SYNOPSIS
    Connect to Discord Gateway WebSocket
    .PARAMETER GatewayUrl
    Gateway WebSocket URL
    #>
    param(
        [Parameter(Mandatory)]
        [string]$GatewayUrl
    )
    
    try {
        # Create WebSocket client
        $script:GatewayConnection = New-Object System.Net.WebSockets.ClientWebSocket
        
        # Set up WebSocket options
        $script:GatewayConnection.Options.SetRequestHeader("User-Agent", "SCUM-Server-Manager/2.0")
        
        # Connect to Gateway
        $uri = [System.Uri]::new($GatewayUrl)
        $connectTask = $script:GatewayConnection.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
        
        # Wait for connection with timeout
        $timeout = [System.TimeSpan]::FromSeconds(10)
        if (-not $connectTask.Wait($timeout)) {
            throw "Connection timeout"
        }
        
        if ($script:GatewayConnection.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $script:IsConnected = $true
            Write-Log "[Gateway] Connected to Discord Gateway"
            
            # Start listening for messages
            Start-GatewayListener
            
        } else {
            throw "WebSocket not in Open state: $($script:GatewayConnection.State)"
        }
        
    } catch {
        Write-Log "[Gateway] Failed to connect to Gateway: $($_.Exception.Message)" -Level Error
        $script:IsConnected = $false
        throw
    }
}

function Start-GatewayListener {
    <#
    .SYNOPSIS
    Start listening for Gateway messages in background
    #>
    
    # Start background job for message listening
    $listenerScript = {
        param($ModulesRoot)
        
        # Import required modules in background job
        Import-Module (Join-Path $ModulesRoot "core\common\common.psm1") -Force
        Import-Module (Join-Path $ModulesRoot "communication\discord\gateway.psm1") -Force
        
        # Message listening loop
        while ($script:IsConnected -and $script:GatewayConnection.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try {
                $message = Receive-GatewayMessage
                if ($message) {
                    Process-GatewayMessage -Message $message
                }
                Start-Sleep -Milliseconds 100
                
            } catch {
                Write-Log "[Gateway] Error in listener loop: $($_.Exception.Message)" -Level Error
                break
            }
        }
        
        Write-Log "[Gateway] Message listener stopped"
    }
    
    # Start the background job
    $script:ListenerJob = Start-Job -ScriptBlock $listenerScript -ArgumentList $ModulesRoot
    Write-Log "[Gateway] Gateway message listener started"
}

function Receive-GatewayMessage {
    <#
    .SYNOPSIS
    Receive message from Gateway WebSocket
    #>
    
    if (-not $script:IsConnected -or $script:GatewayConnection.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        return $null
    }
    
    try {
        $buffer = [byte[]]::new(4096)
        $segment = [System.ArraySegment[byte]]::new($buffer)
        
        $receiveTask = $script:GatewayConnection.ReceiveAsync($segment, [System.Threading.CancellationToken]::None)
        
        # Non-blocking receive with short timeout
        if ($receiveTask.Wait(1000)) {
            $result = $receiveTask.Result
            
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Text) {
                $messageBytes = $buffer[0..($result.Count - 1)]
                $messageText = [System.Text.Encoding]::UTF8.GetString($messageBytes)
                
                return $messageText
            }
        }
        
        return $null
        
    } catch {
        Write-Log "[Gateway] Error receiving message: $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Process-GatewayMessage {
    <#
    .SYNOPSIS
    Process received Gateway message
    .PARAMETER Message
    JSON message from Gateway
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )
    
    try {
        $payload = $Message | ConvertFrom-Json
        
        # Update sequence number
        if ($payload.s) {
            $script:LastSequence = $payload.s
        }
        
        # Handle different opcodes
        switch ($payload.op) {
            $script:GatewayOpcodes.HELLO {
                Write-Log "[Gateway] Received HELLO, heartbeat interval: $($payload.d.heartbeat_interval)ms"
                Start-Heartbeat -IntervalMs $payload.d.heartbeat_interval
                Send-Identify
            }
            
            $script:GatewayOpcodes.HEARTBEAT_ACK {
                Write-Log "[Gateway] Heartbeat acknowledged" -Level Debug
            }
            
            $script:GatewayOpcodes.DISPATCH {
                # Handle Discord events
                Handle-DiscordEvent -EventType $payload.t -EventData $payload.d
                
                # Save session ID for resuming
                if ($payload.t -eq "READY") {
                    $script:SessionId = $payload.d.session_id
                    Write-Log "[Gateway] Bot ready, session ID: $script:SessionId"
                }
            }
            
            $script:GatewayOpcodes.RECONNECT {
                Write-Log "[Gateway] Gateway requested reconnect"
                Start-Reconnect
            }
            
            $script:GatewayOpcodes.INVALID_SESSION {
                Write-Log "[Gateway] Invalid session, reconnecting..." -Level Warning
                $script:SessionId = $null
                Start-Reconnect
            }
            
            default {
                Write-Log "[Gateway] Unknown opcode: $($payload.op)" -Level Debug
            }
        }
        
    } catch {
        Write-Log "[Gateway] Error processing message: $($_.Exception.Message)" -Level Error
    }
}

function Send-GatewayMessage {
    <#
    .SYNOPSIS
    Send message to Discord Gateway
    .PARAMETER Payload
    Hashtable payload to send
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Payload
    )
    
    if (-not $script:IsConnected -or $script:GatewayConnection.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        Write-Log "[Gateway] Cannot send message - not connected" -Level Warning
        return $false
    }
    
    try {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = [System.ArraySegment[byte]]::new($bytes)
        
        $sendTask = $script:GatewayConnection.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
        
        if ($sendTask.Wait(5000)) {
            Write-Log "[Gateway] Message sent successfully" -Level Debug
            return $true
        } else {
            Write-Log "[Gateway] Send timeout" -Level Warning
            return $false
        }
        
    } catch {
        Write-Log "[Gateway] Error sending message: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Send-Identify {
    <#
    .SYNOPSIS
    Send IDENTIFY payload to authenticate bot
    #>
    
    $identifyPayload = @{
        op = $script:GatewayOpcodes.IDENTIFY
        d = @{
            token = $script:BotToken
            intents = $script:Intents
            properties = @{
                os = "windows"
                browser = "SCUM-Server-Manager"
                device = "SCUM-Server-Manager"
            }
        }
    }
    
    Write-Log "[Gateway] Sending IDENTIFY"
    Send-GatewayMessage -Payload $identifyPayload
}

function Start-Heartbeat {
    <#
    .SYNOPSIS
    Start heartbeat timer
    .PARAMETER IntervalMs
    Heartbeat interval in milliseconds
    #>
    param(
        [Parameter(Mandatory)]
        [int]$IntervalMs
    )
    
    # Stop existing timer
    if ($script:HeartbeatTimer) {
        $script:HeartbeatTimer.Stop()
        $script:HeartbeatTimer.Dispose()
    }
    
    # Create new timer
    $script:HeartbeatTimer = New-Object System.Timers.Timer
    $script:HeartbeatTimer.Interval = $IntervalMs
    $script:HeartbeatTimer.AutoReset = $true
    
    # Register timer event
    Register-ObjectEvent -InputObject $script:HeartbeatTimer -EventName Elapsed -Action {
        $heartbeatPayload = @{
            op = 1  # HEARTBEAT
            d = $script:LastSequence
        }
        
        if ($script:IsConnected) {
            Send-GatewayMessage -Payload $heartbeatPayload
        }
    } | Out-Null
    
    $script:HeartbeatTimer.Start()
    Write-Log "[Gateway] Heartbeat started with interval: $($IntervalMs)ms"
}

function Handle-DiscordEvent {
    <#
    .SYNOPSIS
    Handle Discord event from Gateway
    .PARAMETER EventType
    Discord event type (MESSAGE_CREATE, etc.)
    .PARAMETER EventData
    Event data
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EventType,
        
        [Parameter(Mandatory)]
        [object]$EventData
    )
    
    Write-Log "[Gateway] Received Discord event: $EventType" -Level Debug
    
    # Call registered event handlers
    if ($script:EventHandlers.ContainsKey($EventType)) {
        foreach ($handler in $script:EventHandlers[$EventType]) {
            try {
                & $handler $EventData
            } catch {
                Write-Log "[Gateway] Error in event handler for $EventType : $($_.Exception.Message)" -Level Error
            }
        }
    }
}

function Register-DiscordEventHandler {
    <#
    .SYNOPSIS
    Register event handler for Discord events
    .PARAMETER EventType
    Discord event type to handle
    .PARAMETER Handler
    ScriptBlock to execute when event occurs
    #>
    param(
        [Parameter(Mandatory)]
        [string]$EventType,
        
        [Parameter(Mandatory)]
        [scriptblock]$Handler
    )
    
    if (-not $script:EventHandlers.ContainsKey($EventType)) {
        $script:EventHandlers[$EventType] = @()
    }
    
    $script:EventHandlers[$EventType] += $Handler
    Write-Log "[Gateway] Registered handler for event: $EventType"
}

function Start-Reconnect {
    <#
    .SYNOPSIS
    Start reconnection process
    #>
    
    if ($script:ReconnectAttempts -ge $script:MaxReconnectAttempts) {
        Write-Log "[Gateway] Max reconnect attempts reached, giving up" -Level Error
        return
    }
    
    $script:ReconnectAttempts++
    Write-Log "[Gateway] Starting reconnect attempt $script:ReconnectAttempts/$script:MaxReconnectAttempts"
    
    # Disconnect first
    Disconnect-DiscordGateway
    
    # Wait before reconnecting
    Start-Sleep -Seconds (2 * $script:ReconnectAttempts)
    
    # Try to reconnect
    try {
        $gatewayUrl = Get-DiscordGatewayUrl
        if ($gatewayUrl) {
            Connect-DiscordGateway -GatewayUrl $gatewayUrl
            $script:ReconnectAttempts = 0  # Reset on successful connection
        }
    } catch {
        Write-Log "[Gateway] Reconnect failed: $($_.Exception.Message)" -Level Error
    }
}

function Disconnect-DiscordGateway {
    <#
    .SYNOPSIS
    Disconnect from Discord Gateway
    #>
    
    Write-Log "[Gateway] Disconnecting from Discord Gateway..."
    
    $script:IsConnected = $false
    
    # Stop heartbeat timer
    if ($script:HeartbeatTimer) {
        $script:HeartbeatTimer.Stop()
        $script:HeartbeatTimer.Dispose()
        $script:HeartbeatTimer = $null
    }
    
    # Stop listener job
    if ($script:ListenerJob) {
        Stop-Job -Job $script:ListenerJob -PassThru | Remove-Job
        $script:ListenerJob = $null
    }
    
    # Close WebSocket connection
    if ($script:GatewayConnection -and $script:GatewayConnection.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        try {
            $closeTask = $script:GatewayConnection.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Disconnecting", [System.Threading.CancellationToken]::None)
            $closeTask.Wait(5000) | Out-Null
        } catch {
            Write-Log "[Gateway] Error closing WebSocket: $($_.Exception.Message)" -Level Warning
        }
    }
    
    if ($script:GatewayConnection) {
        $script:GatewayConnection.Dispose()
        $script:GatewayConnection = $null
    }
    
    Write-Log "[Gateway] Disconnected from Discord Gateway"
}

function Test-GatewayConnection {
    <#
    .SYNOPSIS
    Test if Gateway connection is healthy
    #>
    
    return $script:IsConnected -and 
           $script:GatewayConnection -and 
           $script:GatewayConnection.State -eq [System.Net.WebSockets.WebSocketState]::Open
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-DiscordGateway',
    'Disconnect-DiscordGateway',
    'Test-GatewayConnection',
    'Register-DiscordEventHandler',
    'Send-GatewayMessage'
)
