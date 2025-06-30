# Discord Cache Module
# Provides caching for Discord objects to improve performance and reduce API calls

# Import required modules
Import-Module "$PSScriptRoot\..\..\..\core\logging\logging.psm1" -Force

# Cache storage
$script:Cache = @{
    Guilds = @{}
    Channels = @{}
    Users = @{}
    Members = @{}
    Roles = @{}
    Messages = @{}
}

# Cache settings
$script:CacheSettings = @{
    MaxAge = @{
        Guilds = 3600      # 1 hour
        Channels = 1800    # 30 minutes
        Users = 3600       # 1 hour
        Members = 1800     # 30 minutes
        Roles = 3600       # 1 hour
        Messages = 300     # 5 minutes
    }
    MaxSize = @{
        Guilds = 100
        Channels = 1000
        Users = 10000
        Members = 10000
        Roles = 1000
        Messages = 1000
    }
}

# Cache statistics
$script:CacheStats = @{
    Hits = 0
    Misses = 0
    Evictions = 0
    LastCleanup = Get-Date
}

function Initialize-DiscordCache {
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Settings = @{}
    )
    
    try {
        Write-LogMessage -Message "Initializing Discord cache..." -Level "INFO"
        
        # Apply custom settings
        foreach ($category in $Settings.Keys) {
            if ($script:CacheSettings.ContainsKey($category)) {
                foreach ($setting in $Settings[$category].Keys) {
                    $script:CacheSettings[$category][$setting] = $Settings[$category][$setting]
                }
            }
        }
        
        # Start cleanup timer
        Start-CacheCleanupTimer
        
        Write-LogMessage -Message "Discord cache initialized successfully" -Level "INFO"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Failed to initialize Discord cache: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Get-CachedGuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuildId
    )
    
    return Get-CachedObject -Category "Guilds" -Id $GuildId
}

function Set-CachedGuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuildId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Guild
    )
    
    return Set-CachedObject -Category "Guilds" -Id $GuildId -Object $Guild
}

function Get-CachedChannel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId
    )
    
    return Get-CachedObject -Category "Channels" -Id $ChannelId
}

function Set-CachedChannel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Channel
    )
    
    return Set-CachedObject -Category "Channels" -Id $ChannelId -Object $Channel
}

function Get-CachedUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )
    
    return Get-CachedObject -Category "Users" -Id $UserId
}

function Set-CachedUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$User
    )
    
    return Set-CachedObject -Category "Users" -Id $UserId -Object $User
}

function Get-CachedMember {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuildId,
        
        [Parameter(Mandatory = $true)]
        [string]$UserId
    )
    
    $memberId = "$GuildId`:$UserId"
    return Get-CachedObject -Category "Members" -Id $memberId
}

function Set-CachedMember {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GuildId,
        
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Member
    )
    
    $memberId = "$GuildId`:$UserId"
    return Set-CachedObject -Category "Members" -Id $memberId -Object $Member
}

function Get-CachedRole {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleId
    )
    
    return Get-CachedObject -Category "Roles" -Id $RoleId
}

function Set-CachedRole {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Role
    )
    
    return Set-CachedObject -Category "Roles" -Id $RoleId -Object $Role
}

function Get-CachedMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MessageId
    )
    
    return Get-CachedObject -Category "Messages" -Id $MessageId
}

function Set-CachedMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MessageId,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Message
    )
    
    return Set-CachedObject -Category "Messages" -Id $MessageId -Object $Message
}

function Get-CachedObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,
        
        [Parameter(Mandatory = $true)]
        [string]$Id
    )
    
    try {
        if (-not $script:Cache.ContainsKey($Category)) {
            $script:CacheStats.Misses++
            return $null
        }
        
        $categoryCache = $script:Cache[$Category]
        
        if (-not $categoryCache.ContainsKey($Id)) {
            $script:CacheStats.Misses++
            return $null
        }
        
        $cachedItem = $categoryCache[$Id]
        
        # Check if item has expired
        $maxAge = $script:CacheSettings.MaxAge[$Category]
        $age = ((Get-Date) - $cachedItem.CachedAt).TotalSeconds
        
        if ($age -ge $maxAge) {
            # Item expired, remove it
            $categoryCache.Remove($Id)
            $script:CacheStats.Misses++
            $script:CacheStats.Evictions++
            return $null
        }
        
        # Update access time
        $cachedItem.LastAccessed = Get-Date
        $script:CacheStats.Hits++
        
        return $cachedItem.Object
        
    } catch {
        Write-LogMessage -Message "Error getting cached object: $($_.Exception.Message)" -Level "ERROR"
        $script:CacheStats.Misses++
        return $null
    }
}

function Set-CachedObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,
        
        [Parameter(Mandatory = $true)]
        [string]$Id,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Object
    )
    
    try {
        if (-not $script:Cache.ContainsKey($Category)) {
            $script:Cache[$Category] = @{}
        }
        
        $categoryCache = $script:Cache[$Category]
        $now = Get-Date
        
        # Check if we need to evict items to make room
        $maxSize = $script:CacheSettings.MaxSize[$Category]
        if ($categoryCache.Count -ge $maxSize) {
            Invoke-CacheEviction -Category $Category
        }
        
        # Store the object with metadata
        $categoryCache[$Id] = @{
            Object = $Object
            CachedAt = $now
            LastAccessed = $now
        }
        
        Write-LogMessage -Message "Cached $Category object: $Id" -Level "DEBUG"
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Error setting cached object: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Invoke-CacheEviction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category
    )
    
    try {
        $categoryCache = $script:Cache[$Category]
        $maxSize = $script:CacheSettings.MaxSize[$Category]
        
        # Calculate how many items to evict (25% of max size)
        $evictCount = [math]::Max(1, [math]::Floor($maxSize * 0.25))
        
        # Get items sorted by last access time (oldest first)
        $sortedItems = $categoryCache.GetEnumerator() | Sort-Object { $_.Value.LastAccessed }
        
        # Evict oldest items
        $evicted = 0
        foreach ($item in $sortedItems) {
            if ($evicted -ge $evictCount) {
                break
            }
            
            $categoryCache.Remove($item.Key)
            $evicted++
            $script:CacheStats.Evictions++
        }
        
        Write-LogMessage -Message "Evicted $evicted items from $Category cache" -Level "DEBUG"
        
    } catch {
        Write-LogMessage -Message "Error during cache eviction: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Clear-DiscordCache {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Category
    )
    
    try {
        if ($Category) {
            if ($script:Cache.ContainsKey($Category)) {
                $count = $script:Cache[$Category].Count
                $script:Cache[$Category].Clear()
                Write-LogMessage -Message "Cleared $count items from $Category cache" -Level "INFO"
            }
        } else {
            $totalCount = 0
            foreach ($cat in $script:Cache.Keys) {
                $totalCount += $script:Cache[$cat].Count
                $script:Cache[$cat].Clear()
            }
            Write-LogMessage -Message "Cleared $totalCount items from all caches" -Level "INFO"
        }
        
        return @{ Success = $true }
        
    } catch {
        $errorMsg = "Error clearing cache: $($_.Exception.Message)"
        Write-LogMessage -Message $errorMsg -Level "ERROR"
        return @{ Success = $false; Error = $errorMsg }
    }
}

function Start-CacheCleanupTimer {
    # This would ideally use a proper timer, but for now we'll rely on periodic cleanup
    # In a real implementation, you might use Register-ObjectEvent or a background job
    
    Write-LogMessage -Message "Cache cleanup timer started" -Level "DEBUG"
}

function Invoke-CacheCleanup {
    try {
        $now = Get-Date
        $timeSinceLastCleanup = ($now - $script:CacheStats.LastCleanup).TotalMinutes
        
        # Only cleanup if it's been more than 5 minutes since last cleanup
        if ($timeSinceLastCleanup -lt 5) {
            return
        }
        
        $totalEvicted = 0
        
        foreach ($category in $script:Cache.Keys) {
            $categoryCache = $script:Cache[$category]
            $maxAge = $script:CacheSettings.MaxAge[$category]
            $expiredItems = @()
            
            # Find expired items
            foreach ($item in $categoryCache.GetEnumerator()) {
                $age = ($now - $item.Value.CachedAt).TotalSeconds
                if ($age -ge $maxAge) {
                    $expiredItems += $item.Key
                }
            }
            
            # Remove expired items
            foreach ($itemId in $expiredItems) {
                $categoryCache.Remove($itemId)
                $totalEvicted++
                $script:CacheStats.Evictions++
            }
        }
        
        $script:CacheStats.LastCleanup = $now
        
        if ($totalEvicted -gt 0) {
            Write-LogMessage -Message "Cache cleanup: evicted $totalEvicted expired items" -Level "DEBUG"
        }
        
    } catch {
        Write-LogMessage -Message "Error during cache cleanup: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Get-CacheStatistics {
    $totalItems = 0
    $categoryStats = @{}
    
    foreach ($category in $script:Cache.Keys) {
        $count = $script:Cache[$category].Count
        $totalItems += $count
        $categoryStats[$category] = $count
    }
    
    $totalRequests = $script:CacheStats.Hits + $script:CacheStats.Misses
    $hitRate = if ($totalRequests -gt 0) { 
        [math]::Round(($script:CacheStats.Hits / $totalRequests) * 100, 2) 
    } else { 
        0 
    }
    
    return @{
        TotalItems = $totalItems
        CategoryStats = $categoryStats
        Hits = $script:CacheStats.Hits
        Misses = $script:CacheStats.Misses
        Evictions = $script:CacheStats.Evictions
        HitRate = $hitRate
        LastCleanup = $script:CacheStats.LastCleanup
        Settings = $script:CacheSettings
    }
}

function Update-CacheFromGatewayEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EventType,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$EventData
    )
    
    try {
        switch ($EventType) {
            "GUILD_CREATE" {
                Set-CachedGuild -GuildId $EventData.id -Guild $EventData
                
                # Cache channels
                if ($EventData.ContainsKey("channels")) {
                    foreach ($channel in $EventData.channels) {
                        Set-CachedChannel -ChannelId $channel.id -Channel $channel
                    }
                }
                
                # Cache roles
                if ($EventData.ContainsKey("roles")) {
                    foreach ($role in $EventData.roles) {
                        Set-CachedRole -RoleId $role.id -Role $role
                    }
                }
                
                # Cache members
                if ($EventData.ContainsKey("members")) {
                    foreach ($member in $EventData.members) {
                        Set-CachedMember -GuildId $EventData.id -UserId $member.user.id -Member $member
                        Set-CachedUser -UserId $member.user.id -User $member.user
                    }
                }
            }
            
            "GUILD_UPDATE" {
                Set-CachedGuild -GuildId $EventData.id -Guild $EventData
            }
            
            { $_ -in @("CHANNEL_CREATE", "CHANNEL_UPDATE") } {
                Set-CachedChannel -ChannelId $EventData.id -Channel $EventData
            }
            
            { $_ -in @("GUILD_MEMBER_ADD", "GUILD_MEMBER_UPDATE") } {
                Set-CachedMember -GuildId $EventData.guild_id -UserId $EventData.user.id -Member $EventData
                Set-CachedUser -UserId $EventData.user.id -User $EventData.user
            }
            
            { $_ -in @("GUILD_ROLE_CREATE", "GUILD_ROLE_UPDATE") } {
                Set-CachedRole -RoleId $EventData.role.id -Role $EventData.role
            }
            
            { $_ -in @("MESSAGE_CREATE", "MESSAGE_UPDATE") } {
                Set-CachedMessage -MessageId $EventData.id -Message $EventData
                if ($EventData.ContainsKey("author")) {
                    Set-CachedUser -UserId $EventData.author.id -User $EventData.author
                }
            }
        }
        
    } catch {
        Write-LogMessage -Message "Error updating cache from gateway event: $($_.Exception.Message)" -Level "ERROR"
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Initialize-DiscordCache',
    'Get-CachedGuild',
    'Set-CachedGuild',
    'Get-CachedChannel',
    'Set-CachedChannel',
    'Get-CachedUser',
    'Set-CachedUser',
    'Get-CachedMember',
    'Set-CachedMember',
    'Get-CachedRole',
    'Set-CachedRole',
    'Get-CachedMessage',
    'Set-CachedMessage',
    'Clear-DiscordCache',
    'Invoke-CacheCleanup',
    'Get-CacheStatistics',
    'Update-CacheFromGatewayEvent'
)
