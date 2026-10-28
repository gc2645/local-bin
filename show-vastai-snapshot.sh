#!/bin/bash

# Snapshot what a renter/workload is running on a vastai GPU host.
# Usage:
#   ./show-vastai-snapshot.sh                     # all vastai hosts, default top-3 processes
#   ./show-vastai-snapshot.sh <command>           # all vastai hosts, custom process command
#   ./show-vastai-snapshot.sh node11 node13       # specific hosts only
#
# Output is suitable for logging into ~/Nextcloud/OpenCode/vastai/WORKLOADS.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODES_FILE="${SCRIPT_DIR}/../etc/nodes.csv"
TIMEOUT=15

# --- Determine host list ---
HOSTS=()
if (( $# > 0 )); then
    if [[ "${1:-}" == "all" ]]; then
        # Explicit "all" arg with no command — just show all vastai hosts
        shift
    elif [[ ! "${1:-}" =~ ^node ]]; then
        # First non-flag arg looks like a command, not a host
        CMD="$*"
        # Parse hosts from nodes.csv (column 3 = platform, filter "vastai")
        while IFS=, read -r NAME TYPE PLATFORM ID OS GPU _ROLES; do
            NAME_LOWER="$(echo "$NAME" | tr '[:upper:]' '[:lower:]')"
            PLATFORM_LOWER="$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]')"
            [[ "$NAME_LOWER" == "name" || -z "$NAME" ]] && continue
            [[ "$PLATFORM_LOWER" == "vastai" ]] && HOSTS+=("$NAME")
        done < "$NODES_FILE"
    else
        # Specific hosts listed as args
        HOSTS=("$@")
    fi
else
    # No args — parse hosts from nodes.csv (column 3 = platform, filter "vastai")
    while IFS=, read -r NAME TYPE PLATFORM ID OS GPU _ROLES; do
        NAME_LOWER="$(echo "$NAME" | tr '[:upper:]' '[:lower:]')"
        PLATFORM_LOWER="$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]')"
        [[ "$NAME_LOWER" == "name" || -z "$NAME" ]] && continue
        [[ "$PLATFORM_LOWER" == "vastai" ]] && HOSTS+=("$NAME")
    done < "$NODES_FILE"
fi

if (( ${#HOSTS[@]} == 0 )); then
    echo "No vastai hosts found in $NODES_FILE" >&2
    exit 1
fi

# --- Determine command to run for process detail ---
PROC_CMD="COLUMNS=200 top -b -n 1 | head -10 | tail -3"
if (( $# > 0 )) && [[ ! "${1:-}" =~ ^node ]]; then
    # First arg is a custom command (not a host)
    PROC_CMD="$1"
fi

# --- Print header ---
printf 'Filter: vastai\n'
printf 'Command: %s\n' "$PROC_CMD"
printf 'Hosts: %s\n\n' "${HOSTS[*]}"

# --- Run snapshot on each host ---
for NODE in "${HOSTS[@]}"; do
    echo "=== $NODE — $(date '+%Y-%m-%d %H:%M %Z') ==="
    echo

    # Check reachability
    if ! ssh -o ConnectTimeout=$TIMEOUT -o BatchMode=yes "$NODE" true 2>/dev/null; then
        echo "$NODE: unreachable or no SSH key" >&2
        echo
        continue
    fi

    echo "--- containers ---"
    ssh "$NODE" 'docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}"' 2>&1

    echo
    echo "--- nvidia-smi ---"
    ssh "$NODE" 'nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw,power.limit --format=csv,noheader' 2>&1

    echo
    echo "--- GPU processes ---"
    ssh "$NODE" 'nvidia-smi --query-compute-apps=pid,used_memory,process_name --format=csv,noheader' 2>&1

    echo
    echo "--- top processes ---"
    ssh "$NODE" "$PROC_CMD" 2>&1

    echo
    echo "--- container command (first) ---"
    ssh "$NODE" 'docker ps --format "{{.Names}}" | head -3 | while read c; do [ -n "$c" ] && echo "== $c" && docker inspect "$c" --format "cmd: {{.Config.Cmd}}
entrypoint: {{.Config.Entrypoint}}" 2>/dev/null; done' 2>&1

    echo
done
