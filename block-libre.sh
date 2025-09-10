#!/usr/bin/env bash
set -euo pipefail

# Environment overrides:
#   BITCOIN_CLI: path to bitcoin-cli (default: bitcoin-cli)
#   BITCOIN_ARGS: extra args for bitcoin-cli (e.g. -conf=/path/bitcoin.conf)
#   BAN_TIME_SECONDS: ban duration in seconds (default: 604800 = 7 days)
#   MONITOR_INTERVAL: seconds between checks when monitoring (default: 3)
#   MONITOR_MODE: set to "false" to run once and exit (default: true)

BITCOIN_CLI=${BITCOIN_CLI:-bitcoin-cli}
BAN_TIME_SECONDS=${BAN_TIME_SECONDS:-604800}
MONITOR_INTERVAL=${MONITOR_INTERVAL:-3}
MONITOR_MODE=${MONITOR_MODE:-true}

# Parse BITCOIN_ARGS (space-separated) into array if provided
BITCOIN_ARGS_ARRAY=()
if [[ -n "${BITCOIN_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    BITCOIN_ARGS_ARRAY=( ${BITCOIN_ARGS} )
fi

error() { echo "[block-libre] $*" 1>&2; }
info() { echo "[block-libre] $*"; }

# Dependency checks
if ! command -v "${BITCOIN_CLI}" >/dev/null 2>&1; then
    error "bitcoin-cli not found. Put it in PATH or set BITCOIN_CLI=/path/to/bitcoin-cli"
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    error "jq is required. Install: macOS: brew install jq; Debian/Ubuntu: sudo apt-get install -y jq; Fedora: sudo dnf install -y jq"
    exit 1
fi

# Wrapper to call bitcoin-cli with optional args
btc() {
    "${BITCOIN_CLI}" "${BITCOIN_ARGS_ARRAY[@]}" "$@"
}

# Extract host portion from Bitcoin Core peer addr string
# Supports: 1.2.3.4:8333 and [2001:db8::1]:8333
extract_host() {
    local addr="$1"
    if [[ "$addr" =~ ^\[([^\]]+)\]:[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$addr" =~ ^([^:]+):[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        # Fallback: return as-is
        printf '%s\n' "$addr"
    fi
}

# Signal handler for graceful shutdown
cleanup() {
    if [[ "${MONITOR_MODE}" != "false" ]]; then
        info "monitoring stopped."
    fi
    exit 0
}
trap cleanup SIGINT SIGTERM

# Main detection and blocking logic
check_and_block_peers() {

    # Fetch peer info
    if ! peers_json=$(btc getpeerinfo 2>/dev/null); then
        error "failed to run 'bitcoin-cli getpeerinfo'. Ensure bitcoind is running and credentials/args are correct."
        return 1
    fi

    # Select peers that are 'libre' AND advertise PREFERENTIAL_PEERING
    # Use a while-read loop for better compatibility with macOS's older bash (no mapfile)
    target_addrs=()
    while IFS= read -r addr; do
        [[ -n "$addr" ]] && target_addrs+=("$addr")
    done < <(printf '%s' "$peers_json" | jq -r '
      .[]
      | select((.connection_type? == "libre") and ((.servicesnames? // []) | any(. == "PREFERENTIAL_PEERING")))
      | .addr
    ')

    if [[ ${#target_addrs[@]} -eq 0 ]]; then
        if [[ "${MONITOR_MODE}" == "false" ]]; then
            # In single-run mode, report the result
            info "no peers with both libre connection type and PREFERENTIAL_PEERING service detected."
        fi
        # In monitor mode, don't log every time - only log when action is taken
        return 0
    fi

    info "detected ${#target_addrs[@]} suspect peer(s). disconnecting and banning for ${BAN_TIME_SECONDS}s..."

    disconnected=0
    banned=0

    for addr in "${target_addrs[@]}"; do
        host=$(extract_host "$addr")

        # Disconnect specific connection (addr includes port)
        if btc disconnectnode "$addr" >/dev/null 2>&1; then
            disconnected=$((disconnected + 1))
            info "disconnected: $addr"
        fi

        # Ban by host (no port). Use relative bantime (omit absolute flag)
        # Only attempt to ban if host looks like an IP (IPv4 or IPv6). Skip hostnames (e.g. .onion)
        if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$host" == *:* ]]; then
            if btc setban "$host" add "$BAN_TIME_SECONDS" >/dev/null 2>&1; then
                banned=$((banned + 1))
                info "banned host: $host"
            fi
        else
            info "skip ban (non-IP host): $host"
        fi
    done

    info "done. disconnected=$disconnected, banned=$banned"
    return 0
}

# Main execution logic
if [[ "${MONITOR_MODE}" == "false" ]]; then
    # Single run mode (legacy behavior)
    check_and_block_peers
else
    # Continuous monitoring mode (default behavior)
    info "starting continuous monitoring mode (checking every ${MONITOR_INTERVAL}s). Press Ctrl+C to stop."
    
    while true; do
        check_start_time=$(date +%s)
        
        if ! check_and_block_peers; then
            error "error during peer check, retrying in ${MONITOR_INTERVAL}s..."
        fi
        
        check_end_time=$(date +%s)
        check_duration=$((check_end_time - check_start_time))
        
        # Calculate remaining sleep time, ensuring we don't have negative sleep
        remaining_sleep=$((MONITOR_INTERVAL - check_duration))
        if [[ $remaining_sleep -gt 0 ]]; then
            sleep "$remaining_sleep"
        fi
        # If check took longer than interval, proceed immediately to next check
    done
fi


