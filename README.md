## Libre Relay Blocker

Scripts to detect, disconnect, and ban Bitcoin peers that signal Libre relay.

- Identifiers (from the Libre fork commit [076012a](https://github.com/chrisguida/bitcoin/commit/076012a86503527956112b89c3f5df974dbce788)):
  - **connection_type**: `"libre"`
  - **servicesnames** contains: `"PREFERENTIAL_PEERING"`
- Both conditions must be true; this avoids blocking other preferential peering.

### Detection policy (AND-only)
- The blocker is intentionally strict and will act only when BOTH identifiers are present:
  - **connection_type == "libre"**
  - **servicesnames includes "PREFERENTIAL_PEERING"**

- Exact checks used by the scripts:
  - Bash (jq):
    ```jq
    .[] | select((.connection_type? == "libre") and ((.servicesnames? // []) | any(. == "PREFERENTIAL_PEERING")))
    ```
  - PowerShell:
    ```powershell
    if ($connType -eq 'libre' -and $hasPref) { $targets += $p.addr }
    ```

- We do not block on only one of these signals. This AND-only policy is derived from the identifiers introduced in the cited commit [076012a](https://github.com/chrisguida/bitcoin/commit/076012a86503527956112b89c3f5df974dbce788) and is intended to minimize false positives and preserve normal preferential peering that is not Libre.

### Files
- `block-libre.sh` (macOS/Linux)
- `block-libre.ps1` (Windows PowerShell)

### Requirements
- Common: Running `bitcoind` with RPC enabled, `bitcoin-cli` available.
- macOS/Linux: `jq`.
- Windows: PowerShell 5+ or PowerShell 7+.

### Usage (macOS/Linux)
```bash
# Default continuous monitoring (checks every 3 seconds - recommended)
./block-libre.sh

# High-frequency monitoring (checks every 1 second - maximum protection)
MONITOR_INTERVAL=1 ./block-libre.sh

# Conservative monitoring (checks every 10 seconds - lower resource usage)
MONITOR_INTERVAL=10 ./block-libre.sh

# Specify config and bantime (seconds)
BITCOIN_ARGS="-conf=/path/to/bitcoin.conf" BAN_TIME_SECONDS=7200 ./block-libre.sh

# Single run mode (legacy behavior - for cron/scripts)
MONITOR_MODE=false ./block-libre.sh
```

### Usage (Windows)
```powershell
# Default continuous monitoring (checks every 3 seconds - recommended)
PowerShell -ExecutionPolicy Bypass -File .\block-libre.ps1

# High-frequency monitoring (checks every 1 second - maximum protection)
PowerShell -ExecutionPolicy Bypass -File .\block-libre.ps1 -MonitorInterval 1

# Conservative monitoring (checks every 10 seconds - lower resource usage)
PowerShell -ExecutionPolicy Bypass -File .\block-libre.ps1 -MonitorInterval 10

# Specify config and bantime (seconds)
PowerShell -ExecutionPolicy Bypass -File .\block-libre.ps1 `
  -BitcoinCliPath "C:\Program Files\Bitcoin\daemon\bitcoin-cli.exe" `
  -BitcoinArgs "-conf=C:\Users\you\AppData\Roaming\Bitcoin\bitcoin.conf" `
  -BanTimeSeconds 7200

# Single run mode (legacy behavior - for scheduled tasks)
PowerShell -ExecutionPolicy Bypass -File .\block-libre.ps1 -SingleRun
```

### What the scripts do
- **Real-time monitoring**: Continuously monitors Bitcoin peers every 3 seconds by default
- **Smart detection**: Identifies peers where `connection_type == "libre"` AND `servicesnames` contains `"PREFERENTIAL_PEERING"` (per [076012a](https://github.com/chrisguida/bitcoin/commit/076012a86503527956112b89c3f5df974dbce788))
- **Immediate action**: Disconnects the specific connection (address with port) and bans the host
- **Safe banning**: Bans for a relative duration (IPv4/IPv6 only; hostnames such as `.onion` are skipped to avoid collateral)
- **Overlap prevention**: Ensures checks don't overlap - if a check takes longer than the interval, the next check starts immediately without stacking

### Timing & Performance

#### Default Behavior (3-Second Monitoring)
- **Detection speed**: Libre peers are detected and blocked within 3 seconds of connection
- **System load**: Optimized for responsiveness while maintaining low resource usage
- **Adaptive timing**: If a peer check takes longer than 3 seconds, the next check starts immediately

#### Smart Overlap Prevention
The scripts use intelligent timing to prevent overlapping checks:

```
Timeline Example (3-second interval):
T=0s:  Check starts
T=1s:  Check completes → Sleep 2s
T=3s:  Next check starts

Timeline Example (slow check):
T=0s:  Check starts  
T=5s:  Check completes → No sleep, immediate next check
T=5s:  Next check starts
```

#### Performance Characteristics
- **Fast networks**: Maintains consistent 3-second rhythm
- **Slow networks**: Adapts automatically, no check stacking
- **High load**: Gracefully handles delays without resource waste
- **Low latency**: Near real-time protection against libre relay attacks

#### Interval Selection Guide
| Interval | Use Case | Protection Level | Resource Usage |
|----------|----------|------------------|----------------|
| 1 second | Maximum security, high-risk environments | Highest (1s detection) | Higher CPU/network |
| 3 seconds | **Recommended default** - balanced protection | High (3s detection) | Moderate |
| 10 seconds | Lower resource usage, stable networks | Good (10s detection) | Low |
| 60+ seconds | Legacy compatibility, scheduled runs | Basic (up to 60s+ detection) | Minimal |

### Logging Behavior

#### Normal Operation (Silent Monitoring)
When no libre peers are detected, the script runs silently after the initial startup message:
```bash
[block-libre] starting continuous monitoring mode (checking every 3s). Press Ctrl+C to stop.
# ... silence during normal monitoring (this is expected and good!)
```

#### When Libre Peers Are Detected
The script immediately logs detailed action when libre relay peers are found:
```bash
[block-libre] detected 2 suspect peer(s). disconnecting and banning for 604800s...
[block-libre] disconnected: 192.168.1.100:8333
[block-libre] banned host: 192.168.1.100
[block-libre] disconnected: 203.0.113.45:8333
[block-libre] banned host: 203.0.113.45
[block-libre] done. disconnected=2, banned=2
```

#### Other Log Messages
```bash
[block-libre] skip ban (non-IP host): example.onion     # .onion addresses aren't banned
[block-libre] error during peer check, retrying in 3s...   # RPC connection issues
[block-libre] monitoring stopped.                          # Graceful shutdown (Ctrl+C)
```

**Note**: Silence during monitoring means your node is libre-relay-free - exactly what you want!

### Scheduling (optional)

#### Option 1: Built-in Monitoring Mode (Default Behavior)
The scripts now run in continuous monitoring mode by default. To run as a background service:
```bash
# Linux/macOS: Run in background with nohup (default 3s interval)
nohup ./block-libre.sh >/dev/null 2>&1 &

# Linux/macOS: Custom interval
nohup env MONITOR_INTERVAL=10 ./block-libre.sh >/dev/null 2>&1 &

# Windows: Run as background job
Start-Job -ScriptBlock { .\block-libre.ps1 }
```

#### Option 2: External Scheduling (Legacy)
Only needed if you prefer single-run mode with external scheduling:
- macOS/Linux (cron): `* * * * * /full/path/block-libre.sh MONITOR_MODE=false >/dev/null 2>&1`
- systemd timer: run `MONITOR_MODE=false ./block-libre.sh` every minute.
- Windows Task Scheduler: run `.\block-libre.ps1 -SingleRun` every minute.

### Verification
```bash
bitcoin-cli -netinfo 4 | cat
bitcoin-cli getpeerinfo | jq -r '.[] | select(.connection_type=="libre" and ((.servicesnames//[])|any(.=="PREFERENTIAL_PEERING"))) | [.id,.addr,.subver] | @tsv'
```

### Security & Readiness
- **Maximum security posture**: AND-only detection prevents false positives; only bans IP literals (skips .onion); uses safe JSON parsing.
- **Real-time protection**: 3-second default detection provides near-instantaneous response to libre relay connections.
- **Production ready**: Cross-platform compatible, proper error handling, smart timing, graceful shutdown.
- **Resource efficient**: Intelligent overlap prevention ensures optimal system resource usage under all conditions.
- **Operational excellence**: Silent monitoring with action-based logging, configurable intervals, suitable for 24/7 background operation.
- **Adaptive performance**: Automatically adjusts to network conditions and system load without manual tuning.
- Adjust `BAN_TIME_SECONDS` / `-BanTimeSeconds` and `MONITOR_INTERVAL` / `-MonitorInterval` as needed for your environment.


