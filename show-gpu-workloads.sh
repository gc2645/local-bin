#!/usr/bin/env bash
# show-gpu-workloads.sh — clean table of what each Vast renter is doing
#
# Usage:
#   ./show-gpu-workloads.sh                  # all hosts (table)
#   ./show-gpu-workloads.sh node11 node13    # specific hosts
#   ./show-gpu-workloads.sh --json           # machine-readable JSON
#   ./show-gpu-workloads.sh --save           # table + append to JSONL log (for cron)
#
# Default host list is read from nodes.csv (column 3 = platform, keep vastai rows).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODES_CSV="${SCRIPT_DIR}/../operations/etc/nodes.csv"

# Parse options before selecting hosts; --json and --save can be combined.
JSON_MODE=0
SAVE_MODE=0
HOSTS=()
for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=1 ;;
        --save) SAVE_MODE=1 ;;
        --*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) HOSTS+=("$arg") ;;
    esac
done
if [[ ${#HOSTS[@]} -eq 0 && -f "$NODES_CSV" ]]; then
    while IFS=',' read -r name type platform id rest; do
        [[ "$platform" == "vastai" ]] && HOSTS+=("$name")
    done < <(tail -n +2 "$NODES_CSV")
fi
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    HOSTS=(node11 node12 node13 node14 node15 node16v1 node16v2 node17 node18 node19)
fi

# --- Run embedded Python (reads enriched snapshots, renders table) ---
exec python3 - "${HOSTS[@]}" "${SAVE_MODE}" "${JSON_MODE}" <<'PYTHON_SCRIPT'
import subprocess, sys, json, datetime, os, re

HOSTS = sys.argv[1:-2] if len(sys.argv) > 3 else []
SAVE_MODE = sys.argv[-2] == "1" if len(sys.argv) > 2 else False
JSON_MODE = sys.argv[-1] == "1" if len(sys.argv) > 2 else False

SAVE_LOG = os.environ.get("GPU_WORKLOADS_LOG", os.path.expanduser("~/src/local-bin/data/gpu-workloads.jsonl"))

# ============================================================
# SSH helper
# ============================================================

def ssh_cmd(host, cmd, timeout=15):
    """Run cmd on host via SSH. Returns stdout or None."""
    try:
        r = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={timeout}",
             f"gcox@{host}.cox.lan", cmd],
            capture_output=True, text=True, timeout=timeout
        )
        return r.stdout if r.returncode == 0 else None
    except (subprocess.TimeoutExpired, OSError):
        return None

# ============================================================
# Fetch enriched snapshot for a host
# ============================================================

def fetch_host(host):
    """Fetch latest enriched snapshot from vast-monitor."""
    snap_raw = ssh_cmd(host, "sudo -n cat /var/log/vast-monitor/latest.json 2>/dev/null || sudo -n tail -1 /var/log/vast-monitor/snapshots.jsonl")
    if not snap_raw:
        return None
    try:
        snap = json.loads(snap_raw.strip())
    except json.JSONDecodeError:
        return None
    snap["host"] = host
    try:
        stamp = datetime.datetime.fromisoformat(snap["ts"].replace("Z", "+00:00"))
        age = (datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds()
        snap["snapshot_age_s"] = round(age, 1)
        snap["stale"] = age > max(180, 3 * snap.get("interval_s", 60)) or age < -60
    except (KeyError, TypeError, ValueError):
        snap["stale"] = True
    return snap

# ============================================================
# Helpers
# ============================================================

def parse_uptime(s):
    s = int(s)
    if s > 86400:
        d = s // 86400
        h = (s % 86400) // 3600
        return f"{d}d{h:02d}h"
    elif s > 3600:
        h = s // 3600
        m = (s % 3600) // 60
        return f"{h}h{m:02d}m"
    else:
        m = s // 60
        return f"{m}m"

def container_uptime(started_at):
    try:
        ts = started_at.replace("Z", "+00:00")
        if "." in ts:
            parts = ts.split(".")
            frac_and_tz = parts[1]
            tz_idx = -1
            for i, ch in enumerate(frac_and_tz):
                if ch in ("+", "-"):
                    tz_idx = i
                    break
            if tz_idx > 0:
                frac = frac_and_tz[:tz_idx][:6]
                tz = frac_and_tz[tz_idx:]
            else:
                frac = frac_and_tz[:6]
                tz = ""
            ts = f"{parts[0]}.{frac}{tz}"
        dt = datetime.datetime.fromisoformat(ts)
        now = datetime.datetime.now(datetime.timezone.utc)
        delta = now - dt
        return parse_uptime(int(delta.total_seconds()))
    except Exception:
        return "-"

def format_gpu_name(raw):
    name = raw.strip()
    for prefix in ("NVIDIA GeForce ", "GeForce "):
        if name.startswith(prefix):
            name = name[len(prefix):]
    name = name.replace(" ", "_")
    return name

def build_gpu_str(gpus, fan_speed=None):
    def fmt(g):
        gpu_name = format_gpu_name(g.get("name", "?"))
        mem_used_mib = g.get("mem_used_mib", 0)
        mem_total_mib = g.get("mem_total_mib", 0)
        temp = g.get("temp_c", 0)
        util = g.get("util_pct", 0)
        power = g.get("power_w", 0)
        fan_raw = g.get("fan_pct", 0)
        try:
            fan = f"{float(fan_raw):.0f}%"
        except (ValueError, TypeError):
            fan = "N/A"
        try:
            mem_pct = float(mem_used_mib) / float(mem_total_mib) * 100.0 if mem_total_mib else 0
            mem_pct = f"{mem_pct:.0f}%"
        except (ValueError, TypeError):
            mem_pct = "N/A"
        try:
            temp = f"{float(temp):.1f}"
        except (ValueError, TypeError):
            temp = "N/A"
        try:
            util = f"{float(util):.0f}%"
        except (ValueError, TypeError):
            util = "N/A"
        # Power: round to int, format as "275/360"
        try:
            p = round(float(power))
        except (ValueError, TypeError):
            p = "N/A"
        try:
            limit = float(g.get("power_limit_w", 0))
            if limit > 0:
                power = f"{p}/{int(limit)}"
            else:
                power = str(p)
        except (ValueError, TypeError):
            power = str(p)
        return (gpu_name, mem_pct, fan, temp, util, power, 1)

    if not gpus:
        return None, None
    first = fmt(gpus[0])
    second = fmt(gpus[1]) if len(gpus) > 1 else None
    if second:
        first = (first[0], first[1], first[2], first[3], first[4], first[5], 2)
    return first, second

# ============================================================
# Main
# ============================================================

results = []
for host in HOSTS:
    snap = fetch_host(host)
    if snap is None:
        results.append({"host": host, "error": "no snapshot"})
    else:
        results.append(snap)


# --- Save mode: append one JSON line per host/container ---
if SAVE_MODE:
    os.makedirs(os.path.dirname(SAVE_LOG), exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
    for r in results:
        host = r.get("host", "?")
        if "error" in r:
            with open(SAVE_LOG, "a") as f:
                f.write(json.dumps({"ts": ts, "host": host, "error": r["error"]}) + "\n")
            continue
        containers = r.get("containers", [])
        gpus = r.get("gpu", [])
        fan_speed = r.get("fan_speed", [])
        if not containers:
            with open(SAVE_LOG, "a") as f:
                f.write(json.dumps({
                    "ts": ts, "host": host, "container": None,
                    "label": "no renter container; host/VM workload unclassified", "gpu": gpus,
                    "snapshot_ts": r.get("ts"), "stale": r.get("stale"), "fan_speed": fan_speed,
                    "process_summary": {},
                }) + "\n")
        else:
            for c in containers:
                cname = c.get("name", "?")
                if cname.endswith("/ssh"):
                    cname = cname[:-4]
                label = c.get("workload", "Unknown")
                gpu_info = c.get("gpu", {})
                proc_summary = c.get("process_summary", {})
                with open(SAVE_LOG, "a") as f:
                    f.write(json.dumps({
                        "ts": ts, "host": host, "container": cname,
                        "label": label, "gpu": gpu_info,
                        "snapshot_ts": r.get("ts"), "stale": r.get("stale"),
                        "workload_details": c.get("workload_details", {}),
                        "image": c.get("image", ""),
                        "process_summary": proc_summary,
                    }) + "\n")

if JSON_MODE:
    print(json.dumps(results, indent=2))
    sys.exit(0)

# --- Table output ---
hdr = f"{'HOST':<8s} {'CONTAINER':<15s} {'UPTIME':>6s}  {'GPU_NAME':<15s} {'FAN':<6s} {'TEMP':<8s} {'MEM':<5s} {'UTIL':<4s} {'POWER':<8s} {'WORKLOAD':<25s}"
print(hdr)
print("-" * len(hdr))

for r in results:
    if "error" in r:
        host = r["host"]
        print(f"{host:<8s} {'-':<15s} {'-':>6s}  {'-':<15s} {'-':<6s} {'-':<8s} {'-':<5s} {'-':<4s} {'-':<8s} {'snapshot unavailable':<25s}")
        continue

    host = r.get("host", "?")
    uptime_s = r.get("uptime_s", 0)
    host_uptime_str = parse_uptime(uptime_s)
    gpus = r.get("gpu", [])
    containers = [c for c in r.get("containers", []) if c.get("container_type") == "renter"]
    fan_speed = r.get("fan_speed", [])

    if r.get("stale"):
        print(f"{host:<8s} STALE SNAPSHOT ({r.get('snapshot_age_s', '?')}s old); workload unverified")
        continue

    if not containers:
        gpu_data, _ = build_gpu_str(gpus, fan_speed)
        # When idle, show idle duration instead of host uptime
        idle_s = r.get("idle_s")
        if idle_s is not None:
            idle_str = parse_uptime(int(idle_s))
        else:
            idle_str = host_uptime_str
        if gpu_data is None:
            print(f"{host:<8s} {'-':<15s} {idle_str:>6s}  {'-':<15s} {'-':<6s} {'-':<8s} {'-':<5s} {'-':<4s} {'-':<8s} {'no renter container; host/VM workload unclassified':<25s}")
        else:
            gpu_name, mem_pct, fan, temp, util, power, _ = gpu_data
            print(f"{host:<8s} {'-':<15s} {idle_str:>6s}  {gpu_name:<15s} {fan:<6s}{temp:<8s}{mem_pct:<5s}{util:<4s} {power:<8s} {'no renter container; host/VM workload unclassified':<25s}")
        continue

    for c in containers:
        name = c.get("name", "?")
        if name.endswith("/ssh"):
            name = name[:-4]

        started_at = c.get("started_at", "")
        up_str = container_uptime(started_at) if started_at else "-"

        label = re.sub(r"[\x00-\x1f\x7f-\x9f]", "?", c.get("workload", "Unknown"))

        uuids = c.get("gpu", {}).get("uuids", [])
        cards = [g for g in gpus if g.get("uuid") in uuids]
        # No GPU PID means card ownership cannot be established from this sample.
        if not cards:
            print(f"{host:<8s} {name:<15s} {up_str:>6s}  {'-':<15s} {'-':<6s} {'-':<8s} {'-':<5s} {'-':<4s} {'-':<8s} {label:<25s}")
            continue
        for card in cards:
            g, _ = build_gpu_str([card], fan_speed)
            print(f"{host:<8s} {name:<15s} {up_str:>6s}  {g[0]:<15s} {g[2]:<6s}{g[3]:<8s}{g[1]:<5s}{g[4]:<4s} {g[5]:<8s} {label:<25s}")

PYTHON_SCRIPT
