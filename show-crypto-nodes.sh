#!/bin/bash
# show-crypto-nodes.sh — Full crypto node health check
# Usage: show-crypto-nodes.sh
#
# Checks: process, RPC sync + height, peer count, disk usage.
#
# Access: talks to each guest directly over SSH (gcox + passwordless sudo).
# It does NOT need node10 / hypervisor access (no `pct exec`).
#
# Peers come from the PRIVATE RPCs. Monero's restricted RPC (18089) always
# reports 0 connections BY DESIGN — never use 18089 as a peer source.
# Sync is read live from the daemons (no hardcoded network heights).

MONERO_HOST="10.10.10.25"
ZANO_HOST="10.10.10.26"
ZCASH_HOST="10.10.10.31"
SSH="ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=no"

MONERO_RPC='sudo curl -fsS --max-time 8 -H "Content-Type: application/json" -d "{\"jsonrpc\":\"2.0\",\"id\":\"0\",\"method\":\"get_info\"}" http://127.0.0.1:18081/json_rpc'
ZANO_RPC='sudo curl -fsS --max-time 8 http://127.0.0.1:11211/getinfo'

# ── Colors (ANSI) ──────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
DIM=$'\033[0;90m'
BOLD=$'\033[1m'
NONE=$'\033[0m'

# Color helper: c "$COLOR" "text"  →  prints text in COLOR
c() { printf "${1}%s${NONE}" "$2"; }

# ── Helpers ────────────────────────────────────────────────

# Run a command on a guest over direct SSH (stderr suppressed)
ct_run() { $SSH "gcox@$1" "$2" 2>/dev/null; }

# Read one JSON field from stdin; unwraps a top-level "result" object if present
jr() {
    python3 -c '
import sys, json
d = json.load(sys.stdin)
if isinstance(d, dict) and "result" in d:
    d = d["result"]
v = d.get(sys.argv[1], "") if isinstance(d, dict) else ""
print("" if v is None else v)' "$1" 2>/dev/null
}

# Strip ANSI escape codes — returns visible text only
strip_ansi() { printf '%s' "$1" | sed $'s/\x1b\[[0-9;]*m//g'; }

# ANSI-aware right-pad: returns $1 padded with spaces to $2 visible-width
pad_field() {
    local text="$1" width="$2" visible vlen pad
    visible=$(strip_ansi "$text")
    vlen=${#visible}
    pad=$((width - vlen))
    if [ "$pad" -gt 0 ]; then printf '%s%*s' "$text" "$pad" ""
    else printf '%s' "$text"; fi
}

# Disk check — returns colored percentage of the container rootfs
check_disk() {
    local result pct
    result=$(ct_run "$1" "df / | tail -1 | awk '{print \$5}'")
    if [[ "$result" =~ ^([0-9]+)%$ ]]; then
        pct=${BASH_REMATCH[1]}
        if   [ "$pct" -gt 90 ]; then c "$RED"    "$result"
        elif [ "$pct" -gt 80 ]; then c "$YELLOW" "$result"
        else                         c "$GREEN"  "$result"
        fi
    else
        c "$DIM" "?"
    fi
}

# fmt_sync HEIGHT TARGET SYNCED_BOOL → colored "synced <height>" / "N behind"
fmt_sync() {
    local height=$1 target=$2 synced=$3
    if [ "$synced" = "True" ] || [ "$synced" = "true" ]; then
        printf '%s %s' "$(c "$GREEN" "synced")" "$(c "$DIM" "$height")"
    elif [ -n "$target" ] && [ "$target" -gt "$height" ] 2>/dev/null; then
        printf '%s %s' "$(c "$YELLOW" "$((target - height)) behind")" "$(c "$DIM" "$height")"
    else
        printf '%s %s' "$(c "$YELLOW" "syncing")" "$(c "$DIM" "$height")"
    fi
}

# ── Row printer ────────────────────────────────────────────
# ANSI-aware: pads on visible width, not byte count
print_row() {
    local name="$1" ct="$2" status="$3" sync="$4" peers="$5" disk="$6" notes="$7"
    printf "  "
    pad_field "$name" 16;   printf " "
    pad_field "$ct" 7;      printf " "
    pad_field "$status" 10; printf " "
    pad_field "$sync" 15;   printf " "
    pad_field "$peers" 7;   printf " "
    pad_field "$disk" 7;    printf " %s\n" "$notes"
}

# ── Header ─────────────────────────────────────────────────
printf "${BOLD}%s${NONE}\n" "═══════════════════════════════════════════════════════════"
printf "${BOLD}  Crypto Nodes Health Check  —  %s${NONE}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
printf "${BOLD}%s${NONE}\n" "═══════════════════════════════════════════════════════════"
echo ""

printf "  "
pad_field "Name" 16;   printf " "
pad_field "CT" 7;      printf " "
pad_field "Status" 10; printf " "
pad_field "Sync" 15;   printf " "
pad_field "Peers" 7;  printf " "
pad_field "Disk" 7;   printf " Notes\n"
printf "  "
pad_field "----------------" 16; printf " "
pad_field "-------" 7;          printf " "
pad_field "----------" 10;      printf " "
pad_field "---------------" 15; printf " "
pad_field "-------" 7;          printf " "
pad_field "-------" 7;          printf " ----------------\n"

# ─── Monero (CT125) ───────────────────────────────────────
status=$(ct_run "$MONERO_HOST" "pgrep -c -x monerod")
if [[ "$status" =~ ^[0-9]+$ ]] && [ "$status" -gt 0 ]; then
    rpc=$(ct_run "$MONERO_HOST" "$MONERO_RPC")
    if [ -n "$rpc" ]; then
        height=$(printf '%s' "$rpc" | jr height)
        target=$(printf '%s' "$rpc" | jr target_height)
        synced=$(printf '%s' "$rpc" | jr synchronized)
        pin=$(printf '%s' "$rpc"  | jr incoming_connections_count)
        pout=$(printf '%s' "$rpc" | jr outgoing_connections_count)
        peers=$(( ${pin:-0} + ${pout:-0} ))
        disk=$(check_disk "$MONERO_HOST")
        print_row "Monero_XMR" "CT125" "UP($status)" \
            "$(fmt_sync "$height" "$target" "$synced")" "$peers" "$disk" \
            "+${pin} -${pout} · public RPC 18089"
    else
        disk=$(check_disk "$MONERO_HOST")
        print_row "Monero_XMR" "CT125" "UP($status)" "$(c "$RED" "RPC fail")" "-" "$disk" \
            "private RPC 18081 unreachable"
    fi
else
    disk=$(check_disk "$MONERO_HOST")
    print_row "Monero_XMR" "CT125" "$(c "$RED" "DOWN")" "?" "-" "$disk" ""
fi

# ─── Zano (CT131) ─────────────────────────────────────────
status=$(ct_run "$ZANO_HOST" "pgrep -c -x zanod")
if [[ "$status" =~ ^[0-9]+$ ]] && [ "$status" -gt 0 ]; then
    rpc=$(ct_run "$ZANO_HOST" "$ZANO_RPC")
    if [ -n "$rpc" ]; then
        height=$(printf '%s' "$rpc" | jr height)
        tip=$(printf '%s' "$rpc"    | jr max_net_seen_height)
        pin=$(printf '%s' "$rpc"    | jr incoming_connections_count)
        pout=$(printf '%s' "$rpc"   | jr outgoing_connections_count)
        peers=$(( ${pin:-0} + ${pout:-0} ))
        disk=$(check_disk "$ZANO_HOST")
        if [ -n "$tip" ] && [ "$tip" -gt "$height" ] 2>/dev/null; then
            sync_str=$(printf '%s %s' "$(c "$YELLOW" "$((tip - height)) behind")" "$(c "$DIM" "$height")")
        else
            sync_str=$(printf '%s %s' "$(c "$GREEN" "synced")" "$(c "$DIM" "$height")")
        fi
        print_row "Zano_ZANO" "CT131" "UP($status)" "$sync_str" "$peers" "$disk" "+${pin} -${pout}"
    else
        disk=$(check_disk "$ZANO_HOST")
        print_row "Zano_ZANO" "CT131" "UP($status)" "$(c "$RED" "RPC fail")" "-" "$disk" ""
    fi
else
    disk=$(check_disk "$ZANO_HOST")
    print_row "Zano_ZANO" "CT131" "$(c "$RED" "DOWN")" "?" "-" "$disk" ""
fi

# ─── Zcash (CT132) ────────────────────────────────────────
# zebrad has no metrics/RPC listener by default: peers from established
# connections, sync from the journal (BSD-safe sed — this runs on macOS).
status=$(ct_run "$ZCASH_HOST" "pgrep -c -x zebrad")
if [[ "$status" =~ ^[0-9]+$ ]] && [ "$status" -gt 0 ]; then
    zlog=$(ct_run "$ZCASH_HOST" "sudo journalctl -u zebrad --no-pager -n 400")
    height=$(printf '%s\n' "$zlog" | sed -n 's/.*current_height=Height(\([0-9][0-9]*\)).*/\1/p' | tail -1)
    pct=$(printf '%s\n' "$zlog"    | sed -n 's/.*sync_percent=\([0-9][0-9.]*\)%.*/\1/p' | tail -1)
    peers=$(ct_run "$ZCASH_HOST" "sudo ss -tnp state established 2>/dev/null | grep -c zebrad")
    [[ "$peers" =~ ^[0-9]+$ ]] || peers="-"
    disk=$(check_disk "$ZCASH_HOST")
    if [ "$pct" = "100.000" ]; then
        sync_str=$(printf '%s %s' "$(c "$GREEN" "synced")" "$(c "$DIM" "$height")")
    elif [ -n "$pct" ]; then
        sync_str=$(printf '%s %s' "$(c "$YELLOW" "${pct}%")" "$(c "$DIM" "$height")")
    else
        sync_str=$(c "$YELLOW" "sync ?")
    fi
    print_row "ZCash_ZEC" "CT132" "UP($status)" "$sync_str" "$peers" "$disk" "zebrad (Rust) 8233"
else
    disk=$(check_disk "$ZCASH_HOST")
    print_row "ZCash_ZEC" "CT132" "$(c "$RED" "DOWN")" "?" "-" "$disk" ""
fi

echo ""
printf "${BOLD}Legend:${NONE} ${GREEN}UP=running${NONE}  ${RED}DOWN=not running${NONE}  ${YELLOW}warning${NONE}  ${DIM}unknown${NONE}\n"
printf "Peers: Monero/Zano = private-RPC connection counts (in+out); Zcash = established zebrad sockets.\n"
printf "Sync + height read live from each daemon (Monero restricted RPC 18089 always reports 0 peers — not used).\n"
