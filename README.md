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
# Default (bitcoin-cli in PATH, 7 days bantime)
./block-libre.sh

# Specify config and bantime (seconds)
BITCOIN_ARGS="-conf=/path/to/bitcoin.conf" BAN_TIME_SECONDS=7200 ./block-libre.sh
```

### Usage (Windows)
```powershell
# Default (bitcoin-cli in PATH, 7 days bantime)
PowerShell -ExecutionPolicy Bypass -File .\block-libre.ps1

# Specify config and bantime (seconds)
PowerShell -ExecutionPolicy Bypass -File .\block-libre.ps1 `
  -BitcoinCliPath "C:\Program Files\Bitcoin\daemon\bitcoin-cli.exe" `
  -BitcoinArgs "-conf=C:\Users\you\AppData\Roaming\Bitcoin\bitcoin.conf" `
  -BanTimeSeconds 7200
```

### What the scripts do
- Detect peers where `connection_type == "libre"` AND `servicesnames` contains `"PREFERENTIAL_PEERING"` (per [076012a](https://github.com/chrisguida/bitcoin/commit/076012a86503527956112b89c3f5df974dbce788)).
- Disconnects the specific connection (address with port).
- Bans the host for a relative duration (IPv4/IPv6 only; hostnames such as `.onion` are skipped to avoid collateral).

### Scheduling (optional)
- macOS/Linux (cron): `* * * * * /full/path/block-libre.sh >/dev/null 2>&1`
- systemd timer: run the script every minute.
- Windows Task Scheduler: run the PowerShell command above every minute.

### Verification
```bash
bitcoin-cli -netinfo 4 | cat
bitcoin-cli getpeerinfo | jq -r '.[] | select(.connection_type=="libre" and ((.servicesnames//[])|any(.=="PREFERENTIAL_PEERING"))) | [.id,.addr,.subver] | @tsv'
```

### Security & Readiness
- **Maximum security posture**: AND-only detection prevents false positives; only bans IP literals (skips .onion); uses safe JSON parsing.
- **Production ready**: Cross-platform compatible, proper error handling, executable permissions set.
- **Operational**: Clear logging, configurable via environment/parameters, suitable for automated scheduling.
- Adjust `BAN_TIME_SECONDS` / `-BanTimeSeconds` as needed after initial validation.


