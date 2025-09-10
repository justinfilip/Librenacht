# Requires: PowerShell 5+ (Windows PowerShell) or PowerShell 7+
# Usage:
#   .\block-libre.ps1 -BitcoinCliPath "bitcoin-cli.exe" -BitcoinArgs "-conf=C:\\path\\bitcoin.conf" -BanTimeSeconds 604800

[CmdletBinding()]
param(
    [string]$BitcoinCliPath = "bitcoin-cli",
    [string]$BitcoinArgs = "",
    [int]$BanTimeSeconds = 604800
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

# Get peer info
try {
    $peersJson = Invoke-BtcCli getpeerinfo 2>$null
} catch {
    Write-Err "failed to run 'bitcoin-cli getpeerinfo'. Ensure bitcoind is running and arguments are correct."
    exit 1
}

if (-not $peersJson) {
    Write-Info "no peers returned from getpeerinfo"
    exit 0
}

# Parse JSON (native)
try {
    $peers = $peersJson | ConvertFrom-Json
} catch {
    Write-Err "failed to parse getpeerinfo JSON"
    exit 1
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
    Write-Info "no libre or PREFERENTIAL_PEERING peers detected."
    exit 0
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


