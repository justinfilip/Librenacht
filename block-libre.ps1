# Requires: PowerShell 5+ (Windows PowerShell) or PowerShell 7+
# Usage:
#   .\block-libre.ps1  # Default: continuous monitoring every 3 seconds
#   .\block-libre.ps1 -MonitorInterval 1  # High-frequency monitoring every 1 second
#   .\block-libre.ps1 -BitcoinCliPath "bitcoin-cli.exe" -BitcoinArgs "-conf=C:\\path\\bitcoin.conf" -BanTimeSeconds 604800
#   .\block-libre.ps1 -SingleRun  # For single run mode (legacy)

[CmdletBinding()]
param(
    [string]$BitcoinCliPath = "bitcoin-cli",
    [string]$BitcoinArgs = "",
    [int]$BanTimeSeconds = 604800,
    [switch]$SingleRun = $false,
    [int]$MonitorInterval = 3
)

function Write-Info {
    param([string]$Message)
    Write-Host "[block-libre] $Message"
}
function Write-Err {
    param([string]$Message)
    Write-Error "[block-libre] $Message"
}

# Verify bitcoin-cli exists
try {
    $null = Get-Command $BitcoinCliPath -ErrorAction Stop
} catch {
    Write-Err "bitcoin-cli not found. Provide -BitcoinCliPath or add to PATH."
    exit 1
}

# Build argument array (split respecting quotes)
$cliArgs = @()
if ($BitcoinArgs -ne "") {
    $tokens = [System.Management.Automation.PSParser]::Tokenize($BitcoinArgs, [ref]$null)
    foreach ($t in $tokens) {
        if ($t.Type -eq 'String' -or $t.Type -eq 'CommandArgument') {
            $cliArgs += $t.Content
        }
    }
}

function Invoke-BtcCli {
    param([Parameter(ValueFromRemainingArguments=$true)] [string[]]$Rest)
    & $BitcoinCliPath @cliArgs @Rest
}

function Extract-HostFromAddr {
    param([string]$Addr)
    # Matches [IPv6]:port or IPv4:port
    if ($Addr -match '^\[([^\]]+)\]:\d+$') {
        return $Matches[1]
    }
    if ($Addr -match '^([^:]+):\d+$') {
        return $Matches[1]
    }
    return $Addr
}

# Signal handler for graceful shutdown
$script:shouldStop = $false
[Console]::TreatControlCAsInput = $false
[Console]::CancelKeyPress += {
    param($sender, $e)
    $e.Cancel = $true
    $script:shouldStop = $true
    if (-not $SingleRun) {
        Write-Info "monitoring stopped."
    }
}

# Main detection and blocking logic
function Invoke-PeerCheck {
    # Get peer info
    try {
        $peersJson = Invoke-BtcCli getpeerinfo 2>$null
    } catch {
        Write-Err "failed to run 'bitcoin-cli getpeerinfo'. Ensure bitcoind is running and arguments are correct."
        return $false
    }

    if (-not $peersJson) {
        if ($SingleRun) {
            Write-Info "no peers returned from getpeerinfo"
        }
        return $true
    }

    # Parse JSON (native)
    try {
        $peers = $peersJson | ConvertFrom-Json
    } catch {
        Write-Err "failed to parse getpeerinfo JSON"
        return $false
    }

    # Filter targets: connection_type == "libre" AND servicesnames contains "PREFERENTIAL_PEERING"
    $targets = @()
    foreach ($p in $peers) {
        $connType = $p.connection_type
        $hasPref = $false
        if ($p.PSObject.Properties.Name -contains 'servicesnames') {
            $sn = $p.servicesnames
            if ($sn -is [System.Array]) {
                foreach ($s in $sn) { if ($s -eq 'PREFERENTIAL_PEERING') { $hasPref = $true; break } }
            } else {
                if ("$sn" -match 'PREFERENTIAL_PEERING') { $hasPref = $true }
            }
        }
        if ($connType -eq 'libre' -and $hasPref) {
            $targets += $p.addr
        }
    }

    if ($targets.Count -eq 0) {
        if ($SingleRun) {
            # In single-run mode, report the result
            Write-Info "no peers with both libre connection type and PREFERENTIAL_PEERING service detected."
        }
        # In monitor mode, don't log every time - only log when action is taken
        return $true
    }

    Write-Info "detected $($targets.Count) suspect peer(s). disconnecting and banning for $BanTimeSeconds s..."
    $disconnected = 0
    $banned = 0

    foreach ($addr in $targets) {
        $host = Extract-HostFromAddr -Addr $addr
        try {
            Invoke-BtcCli disconnectnode $addr *> $null
            $disconnected++
            Write-Info "disconnected: $addr"
        } catch {}
        try {
            # Only ban if host appears to be an IP (IPv4 or IPv6). Skip hostnames (e.g., .onion)
            if ($host -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -or $host.Contains(':')) {
                # Use relative bantime (omit absolute flag)
                Invoke-BtcCli setban $host add $BanTimeSeconds *> $null
                $banned++
                Write-Info "banned host: $host"
            } else {
                Write-Info "skip ban (non-IP host): $host"
            }
        } catch {}
    }

    Write-Info "done. disconnected=$disconnected, banned=$banned"
    return $true
}

# Main execution logic
if ($SingleRun) {
    # Single run mode (legacy behavior)
    Invoke-PeerCheck | Out-Null
} else {
    # Continuous monitoring mode (default behavior)
    Write-Info "starting continuous monitoring mode (checking every $MonitorInterval seconds). Press Ctrl+C to stop."
    
    while (-not $script:shouldStop) {
        $checkStartTime = Get-Date
        
        if (-not (Invoke-PeerCheck)) {
            Write-Err "error during peer check, retrying in $MonitorInterval seconds..."
        }
        
        $checkEndTime = Get-Date
        $checkDuration = ($checkEndTime - $checkStartTime).TotalSeconds
        
        # Calculate remaining sleep time, ensuring we don't have negative sleep
        $remainingSleep = $MonitorInterval - $checkDuration
        if ($remainingSleep -gt 0 -and -not $script:shouldStop) {
            # Sleep in small chunks to allow for responsive Ctrl+C handling
            $sleepRemaining = $remainingSleep
            while ($sleepRemaining -gt 0 -and -not $script:shouldStop) {
                $sleepChunk = [Math]::Min($sleepRemaining, 1)
                Start-Sleep -Seconds $sleepChunk
                $sleepRemaining -= $sleepChunk
            }
        }
        # If check took longer than interval, proceed immediately to next check
    }
}


