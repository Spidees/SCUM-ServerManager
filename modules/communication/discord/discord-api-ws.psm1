# Discord API WebSocket Module
# Provides WebSocket helpers and Discord REST API integration

# Import required modules
Import-Module "$PSScriptRoot\..\..\..\core\logging\logging.psm1" -Force

# API configuration
$script:DiscordApiBase = "https://discord.com/api/v10"
$script:BotToken = $null
$script:UserAgent = "SCUM-Server-Bot/1.0"
$script:RateLimitBuckets = @{}
$script:GlobalRateLimit = $null

function Initialize-DiscordAPI {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )
    
    try {
        $script:BotToken = $Token
        Write-LogMessage -Message "Discord API initialized" -Level "INFO"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to initialize Discord API: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Send-DiscordAPIRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Data,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Headers = @{},
        
        [Parameter(Mandatory = $false)]
        [int]$RetryCount = 3
    )
    
    if (-not $script:BotToken) {
        return @{ Success = $false; Error = "Discord API not initialized" }
    }
    
    try {
        $url = "$script:DiscordApiBase/$Endpoint"
        
        # Prepare headers
        $requestHeaders = @{
            "Authorization" = "Bot $script:BotToken"
            "User-Agent" = $script:UserAgent
            "Content-Type" = "application/json"
        }
        
        # Add custom headers
        foreach ($key in $Headers.Keys) {
            $requestHeaders[$key] = $Headers[$key]
        }
        
        # Check rate limits
        $rateLimitResult = Test-RateLimit -Endpoint $Endpoint
        if (-not $rateLimitResult.Allowed) {
            Write-LogMessage -Message "Rate limit hit for endpoint $Endpoint, waiting $($rateLimitResult.RetryAfter) seconds" -Level "WARNING"
            Start-Sleep -Seconds $rateLimitResult.RetryAfter
        }
        
        # Prepare request parameters
        $requestParams = @{
            Uri = $url
            Method = $Method
            Headers = $requestHeaders
            UseBasicParsing = $true
        }
        
        # Add body if data is provided
        if ($Data) {
            $jsonBody = ConvertTo-Json $Data -Depth 10 -Compress
            $requestParams.Body = $jsonBody
        }
        
        Write-LogMessage -Message "Discord API request: $Method $Endpoint" -Level "DEBUG"
        
        # Make request with retry logic
        $attempt = 0
        do {
            $attempt++
            
            try {
                $response = Invoke-RestMethod @requestParams
                
                # Update rate limit information from response headers
                Update-RateLimitInfo -Endpoint $Endpoint -Response $response
                
                Write-LogMessage -Message "Discord API request successful: $Method $Endpoint" -Level "DEBUG"
                return @{ Success = $true; Data = $response }
                
            } catch {
                $statusCode = $null
                $errorMessage = $_.Exception.Message
                
                # Extract status code if available
                if ($_.Exception.Response) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                
                # Handle rate limiting
                if ($statusCode -eq 429) {
                    $retryAfter = 1
                    
                    # Try to get retry-after header
                    if ($_.Exception.Response.Headers["Retry-After"]) {
                        $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"]
                    }
                    
                    Write-LogMessage -Message "Rate limited on $Endpoint, retrying after $retryAfter seconds" -Level "WARNING"
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
                
                # Handle server errors (5xx) with retry
                if ($statusCode -ge 500 -and $statusCode -lt 600 -and $attempt -lt $RetryCount) {
                    $delay = [math]::Pow(2, $attempt) # Exponential backoff
                    Write-LogMessage -Message "Server error ($statusCode) on $Endpoint, retrying in $delay seconds (attempt $attempt/$RetryCount)" -Level "WARNING"
                    Start-Sleep -Seconds $delay
                    continue
                }
                
                # Handle client errors (4xx) - don't retry
                if ($statusCode -ge 400 -and $statusCode -lt 500) {
                    Write-LogMessage -Message "Client error on Discord API request: $statusCode - $errorMessage" -Level "ERROR"
                    return @{ Success = $false; Error = "API Error $statusCode`: $errorMessage"; StatusCode = $statusCode }
                }
                
                # Other errors
                Write-LogMessage -Message "Error on Discord API request: $errorMessage" -Level "ERROR"
                return @{ Success = $false; Error = $errorMessage }
            }
            
        } while ($attempt -lt $RetryCount)
        
        return @{ Success = $false; Error = "Maximum retry attempts exceeded" }
        
    } catch {
        $errorMsg = "Failed to send Discord API request: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Send-DiscordMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        
        [Parameter(Mandatory = $false)]
        [string]$Content,
        
        [Parameter(Mandatory = $false)]
        [array]$Embeds,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Components,
        
        [Parameter(Mandatory = $false)]
        [bool]$TTS = $false
    )
    
    try {
        $messageData = @{}
        
        if ($Content) {
            $messageData.content = $Content
        }
        
        if ($Embeds -and $Embeds.Count -gt 0) {
            $messageData.embeds = $Embeds
        }
        
        if ($Components) {
            $messageData.components = $Components
        }
        
        if ($TTS) {
            $messageData.tts = $true
        }
        
        # Validate that we have some content
        if (-not $Content -and (-not $Embeds -or $Embeds.Count -eq 0)) {
            throw "Message must have content or embeds"
        }
        
        $result = Send-DiscordAPIRequest -Method "POST" -Endpoint "channels/$ChannelId/messages" -Data $messageData
        return $result
        
    } catch {
        $errorMsg = "Failed to send Discord message: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Edit-DiscordMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        
        [Parameter(Mandatory = $true)]
        [string]$MessageId,
        
        [Parameter(Mandatory = $false)]
        [string]$Content,
        
        [Parameter(Mandatory = $false)]
        [array]$Embeds,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Components
    )
    
    try {
        $messageData = @{}
        
        if ($Content) {
            $messageData.content = $Content
        }
        
        if ($Embeds -and $Embeds.Count -gt 0) {
            $messageData.embeds = $Embeds
        }
        
        if ($Components) {
            $messageData.components = $Components
        }
        
        $result = Send-DiscordAPIRequest -Method "PATCH" -Endpoint "channels/$ChannelId/messages/$MessageId" -Data $messageData
        return $result
        
    } catch {
        $errorMsg = "Failed to edit Discord message: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Remove-DiscordMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        
        [Parameter(Mandatory = $true)]
        [string]$MessageId
    )
    
    try {
        $result = Send-DiscordAPIRequest -Method "DELETE" -Endpoint "channels/$ChannelId/messages/$MessageId"
        return $result
        
    } catch {
        $errorMsg = "Failed to delete Discord message: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Send-InteractionResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InteractionId,
        
        [Parameter(Mandatory = $true)]
        [string]$Token,
        
        [Parameter(Mandatory = $false)]
        [string]$Content,
        
        [Parameter(Mandatory = $false)]
        [array]$Embeds,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Components,
        
        [Parameter(Mandatory = $false)]
        [int]$Type = 4, # CHANNEL_MESSAGE_WITH_SOURCE
        
        [Parameter(Mandatory = $false)]
        [bool]$Ephemeral = $false
    )
    
    try {
        $responseData = @{
            type = $Type
            data = @{}
        }
        
        if ($Content) {
            $responseData.data.content = $Content
        }
        
        if ($Embeds -and $Embeds.Count -gt 0) {
            $responseData.data.embeds = $Embeds
        }
        
        if ($Components) {
            $responseData.data.components = $Components
        }
        
        if ($Ephemeral) {
            $responseData.data.flags = 64 # EPHEMERAL
        }
        
        # Use interaction webhook endpoint (doesn't count against rate limits)
        $result = Send-DiscordAPIRequest -Method "POST" -Endpoint "interactions/$InteractionId/$Token/callback" -Data $responseData
        return $result
        
    } catch {
        $errorMsg = "Failed to send interaction response: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Test-RateLimit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )
    
    try {
        # Extract bucket key from endpoint
        $bucketKey = Get-RateLimitBucket -Endpoint $Endpoint
        
        # Check global rate limit
        if ($script:GlobalRateLimit -and (Get-Date) -lt $script:GlobalRateLimit) {
            $retryAfter = ($script:GlobalRateLimit - (Get-Date)).TotalSeconds
            return @{ Allowed = $false; RetryAfter = [math]::Ceiling($retryAfter) }
        }
        
        # Check bucket-specific rate limit
        if ($script:RateLimitBuckets.ContainsKey($bucketKey)) {
            $bucket = $script:RateLimitBuckets[$bucketKey]
            
            if ($bucket.ResetTime -and (Get-Date) -lt $bucket.ResetTime) {
                if ($bucket.Remaining -le 0) {
                    $retryAfter = ($bucket.ResetTime - (Get-Date)).TotalSeconds
                    return @{ Allowed = $false; RetryAfter = [math]::Ceiling($retryAfter) }
                }
            }
        }
        
        return @{ Allowed = $true }
        
    } catch {
        Write-LogMessage -Message "Error checking rate limit: $($_.Exception.Message)" -Level "ERROR"
        return @{ Allowed = $true } # Allow request if we can't check rate limits
    }
}

function Update-RateLimitInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory = $true)]
        $Response
    )
    
    try {
        # This would update rate limit information based on response headers
        # For now, this is a placeholder since Invoke-RestMethod doesn't easily expose headers
        
        $bucketKey = Get-RateLimitBucket -Endpoint $Endpoint
        
        # In a real implementation, we would parse headers like:
        # X-RateLimit-Limit, X-RateLimit-Remaining, X-RateLimit-Reset
        # X-RateLimit-Bucket, X-RateLimit-Global
        
        Write-LogMessage -Message "Rate limit info updated for bucket: $bucketKey" -Level "DEBUG"
        
    } catch {
        Write-LogMessage -Message "Error updating rate limit info: $($_.Exception.Message)" -Level "DEBUG"
    }
}

function Get-RateLimitBucket {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )
    
    # Simplified bucket logic - in reality, Discord uses more complex bucket identification
    $endpoint = $Endpoint -replace '\d+', '{id}' # Replace IDs with placeholder
    return $endpoint
}

function Get-DiscordChannel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId
    )
    
    try {
        $result = Send-DiscordAPIRequest -Method "GET" -Endpoint "channels/$ChannelId"
        return $result
        
    } catch {
        $errorMsg = "Failed to get Discord channel: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Get-DiscordGuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuildId
    )
    
    try {
        $result = Send-DiscordAPIRequest -Method "GET" -Endpoint "guilds/$GuildId"
        return $result
        
    } catch {
        $errorMsg = "Failed to get Discord guild: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Get-DiscordUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )
    
    try {
        $result = Send-DiscordAPIRequest -Method "GET" -Endpoint "users/$UserId"
        return $result
        
    } catch {
        $errorMsg = "Failed to get Discord user: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Register-SlashCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuildId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Command
    )
    
    try {
        $result = Send-DiscordAPIRequest -Method "POST" -Endpoint "applications/@me/guilds/$GuildId/commands" -Data $Command
        return $result
        
    } catch {
        $errorMsg = "Failed to register slash command: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Get-DiscordAPIStatus {
    return @{
        ApiBase = $script:DiscordApiBase
        HasToken = $null -ne $script:BotToken
        UserAgent = $script:UserAgent
        RateLimitBuckets = $script:RateLimitBuckets.Keys.Count
        GlobalRateLimit = $script:GlobalRateLimit
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-DiscordAPI',
    'Send-DiscordAPIRequest',
    'Send-DiscordMessage',
    'Edit-DiscordMessage',
    'Remove-DiscordMessage',
    'Send-InteractionResponse',
    'Get-DiscordChannel',
    'Get-DiscordGuild',
    'Get-DiscordUser',
    'Register-SlashCommand',
    'Get-DiscordAPIStatus'
)
