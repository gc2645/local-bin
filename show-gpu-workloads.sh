#!/usr/bin/env bash
# show-gpu-workloads.sh — clean table of what each Vast renter is doing
#
# Usage:
#   ./show-gpu-workloads.sh                  # all hosts (table)
#   ./show-gpu-workloads.sh node11 node13    # specific hosts
#   ./show-gpu-workloads.sh --json           # machine-readable JSON
#   ./show-gpu-workloads.sh --save           # table + append to JSONL log (for cron)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Host list ---
HOSTS=("${@}")
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    HOSTS=(node11 node12 node13 node14 node15 node16 node17 node18 node19)
fi

# --- JSON output mode ---
if [[ "${1:-}" == "--json" ]]; then
    shift
    HOSTS=("${@}")
    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        HOSTS=(node11 node12 node13 node14 node15 node16 node17 node18 node19)
    fi
fi

# --- Save mode: append to JSONL log ---
SAVE_MODE=0
if [[ "${1:-}" == "--save" ]]; then
    SAVE_MODE=1
    shift
    HOSTS=("${@}")
    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        HOSTS=(node11 node12 node13 node14 node15 node16 node17 node18 node19)
    fi
fi

# --- Run embedded Python (does SSH + formatting) ---
exec python3 - "${HOSTS[@]}" "${SAVE_MODE}" <<'PYTHON_SCRIPT'
import subprocess, sys, json, datetime, os

HOSTS = sys.argv[1:-1] if len(sys.argv) > 2 else []
SAVE_MODE = sys.argv[-1] == "1" if len(sys.argv) > 1 else False
JSON_MODE = "--json" in sys.argv

# Save log path
SAVE_LOG = "/Users/gcox/src/local-bin/data/gpu-workloads.jsonl"

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
# Fetch + enhance snapshot for a host
# ============================================================

def fetch_host(host):
    """Fetch snapshot and enhance with fan, GPU cmdlines, AI cmdlines."""
    # Fetch latest snapshot
    snap_raw = ssh_cmd(host, "sudo -n tail -1 /var/log/vast-monitor/snapshots.jsonl")
    if not snap_raw:
        return None

    try:
        snap = json.loads(snap_raw.strip())
    except json.JSONDecodeError:
        return None

    snap["host"] = host

    # Enhance: fan speed
    fans_raw = ssh_cmd(host, "sudo -n nvidia-smi --query-gpu=fan.speed --format=csv,noheader,nounits")
    if fans_raw:
        fans = []
        for line in fans_raw.strip().splitlines():
            line = line.strip()
            if line:
                try:
                    fans.append(float(line))
                except ValueError:
                    pass
        for i, g in enumerate(snap.get("gpu", [])):
            if i < len(fans):
                g["fan_pct"] = fans[i]

    # Enhance: GPU process cmdlines (nvidia-smi PIDs → ps -f)
    pids_raw = ssh_cmd(host, "sudo -n sh -c 'nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null'")
    if pids_raw and pids_raw.strip():
        pids = []
        for line in pids_raw.strip().splitlines():
            line = line.strip()
            if line:
                try:
                    pids.append(int(line))
                except ValueError:
                    pass
        if pids:
            pid_str = " ".join(str(p) for p in pids)
            ps_out = ssh_cmd(host, f"sudo -n ps -f {pid_str}")
            if ps_out:
                gpu_cmdlines = []
                for line in ps_out.splitlines()[1:]:  # skip header
                    parts = line.split(None, 8)
                    if len(parts) >= 9:
                        gpu_cmdlines.append({"pid": parts[1], "user": parts[0], "cmdline": parts[8]})
                    elif len(parts) >= 2:
                        gpu_cmdlines.append({"pid": parts[1], "user": parts[0], "cmdline": parts[-1]})
                snap["gpu_cmdlines"] = gpu_cmdlines

    # Enhance: AI process scan (may be idle, not in nvidia-smi)
    aip_raw = ssh_cmd(host, "sudo -n ps -eo pid,comm,args --no-headers 2>/dev/null | grep -iE 'vllm|ollama|llama[.]cpp|llama-server|sglang|text-generation|lmdeploy|tensorrt|train[.]py|torchrun|accelerate|deepspeed|finetune|--epochs|--pretrain' | grep -v grep")
    ai_cmdlines = []
    if aip_raw and aip_raw.strip():
        for line in aip_raw.strip().splitlines():
            parts = line.split(None, 2)
            if len(parts) >= 3:
                ai_cmdlines.append({"pid": parts[0], "comm": parts[1], "cmdline": parts[2]})

    # Also scan inside running containers (isolated PID ns)
    for c in snap.get("containers", []):
        cname = c.get("name", "")
        if cname.startswith("C."):
            dock_out = ssh_cmd(host, f"sudo -n docker exec {cname} ps -eo pid,comm,args --no-headers 2>/dev/null | grep -iE 'vllm|ollama|llama[.]cpp|sglang|text-generation|lmdeploy|tensorrt|train[.]py|torchrun|accelerate|deepspeed|finetune|--epochs|--pretrain' | grep -v grep")
            if dock_out and dock_out.strip():
                for line in dock_out.strip().splitlines():
                    parts = line.split(None, 2)
                    if len(parts) >= 3:
                        ai_cmdlines.append({"pid": parts[0], "comm": parts[1], "cmdline": parts[2]})

    if ai_cmdlines:
        snap["ai_cmdlines"] = ai_cmdlines

    return snap

# ============================================================
# Mining pool IP -> (pool_name, coin_info)
# ============================================================

POOL_IPS = {}
def _add_pool(ip, name, coins):
    POOL_IPS[ip] = (name, coins)

for i in range(218, 256):
    _add_pool(f"142.171.3.{i}", "Unmineable", "ETHASH (ETH/ETC/etc)")
_add_pool("80.241.218.206", "Unmineable", "ETHASH (ETH/ETC/etc)")

_add_pool("40.160.29.14", "NiceHash", "RandomX (XMR) / Scrypt (XVG)")
_add_pool("172.241.31.200", "NiceHash", "RandomX (XMR) / KawPow (RVN)")
for ip in ["162.55.14.228", "104.244.76.13", "198.98.56.47", "45.33.32.156"]:
    _add_pool(ip, "NiceHash", "Various (check miner binary)")

for i in range(166, 256):
    _add_pool(f"185.235.165.{i}", "2Miners", "Various (check miner binary)")
for i in range(166, 256):
    _add_pool(f"159.65.136.{i}", "2Miners", "Various (check miner binary)")

for i in range(130, 132):
    _add_pool(f"194.163.154.{i}", "Herominers", "Various (check miner binary)")
for i in range(172, 176):
    _add_pool(f"45.140.111.{i}", "Herominers", "Various (check miner binary)")

for i in range(164, 256):
    _add_pool(f"116.202.76.{i}", "F2Pool", "Various (check miner binary)")

for i in range(120, 256):
    _add_pool(f"104.192.42.{i}", "Foundry", "Various (check miner binary)")

MINING_PORTS = {
    3333, 3334, 3335, 3336,
    45560, 45561,
    5555, 5556, 5557,
    7777,
    8333, 8888,
    1200, 1201, 1202, 1203, 1204, 1205, 1206, 1207, 1208, 1209, 1210,
    7048, 7049, 7050, 7051, 7052, 7053, 7054, 7055, 7056, 7057, 7058, 7059, 7060, 7061, 7062, 7063, 7064, 7065,
}

POOL_DOMAINS = {
    ".kryptex.network": ("Kryptex", "PRL/ARRS (Pirate Chain)"),
    ".unmineable.com": ("Unmineable", "Various (auto-switched)"),
    ".2miners.com": ("2Miners", "Check miner binary"),
    ".herominers.com": ("Herominers", "Various"),
    ".f2pool.com": ("F2Pool", "Various"),
    ".foundry.dev": ("Foundry", "Various"),
    ".nicehash.com": ("NiceHash", "Various"),
    ".pool.hashvault.pro": ("NiceHash", "Various"),
}

MINER_COIN = {
    "xmrig": "Monero (XMR)",
    "xmrig-nvidia": "Monero (XMR)",
    "xmrig-amd": "Monero (XMR)",
    "minergate": "Multi (MGW)",
    "minergate-desktop": "Multi (MGW)",
    "minergate-daemon": "Multi (MGW)",
    "minexmr": "Monero (XMR)",
    "SRBMiner-MULTI": "Multi-algorithm",
    "SRBMiner": "Multi-algorithm",
    "SRBMiner-AMD": "Multi-algorithm",
    "SRBMiner-NVIDIA": "Multi-algorithm",
    "forgeminer": "Multi-coin (Unmineable)",
    "minerd": "Bitcoin (BTC)",
    "ccminer": "Multi (LTC/QRK/ZEC)",
    "bfgminer": "Bitcoin (BTC)",
    "cgminer": "Bitcoin (BTC)",
    "ethminer": "ETC/ETH",
    "nbminer": "Multi-algorithm",
    "lolminer": "Multi-algorithm",
    "teamredminer": "Multi-algorithm",
    "autolykos": "ETC",
    "progpow": "ZIL/ETHW",
}

COIN_NAMES = {
    "BTX": "BitTorrent",
    "XMR": "Monero",
    "ETH": "Ethereum",
    "ETC": "Ethereum Classic",
    "LTC": "Litecoin",
    "DOGE": "Dogecoin",
    "DCR": "Decred",
    "RVN": "Ravencoin",
    "KAS": "Kaspa",
    "PRL": "Pirate Chain",
    "ARRS": "Arrr",
    "ZEC": "Zcash",
    "BTC": "Bitcoin",
    "SOL": "Solana",
    "AVAX": "Avalanche",
    "ALGO": "Algorand",
    "NANO": "Nano",
    "XTZ": "Tezos",
    "FLOW": "Flow",
    "Multi": "Multi-coin",
    "ETH/ETC": "ETH/ETC",
    "XMR/ETC": "XMR/ETC",
}

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

def _parse_cmdline_for_mining(cmdlines):
    if not cmdlines:
        return None, None
    coins = set()
    pools = set()
    for entry in cmdlines:
        args = entry.get("cmdline", "")
        parts = args.split()
        if not parts:
            continue
        # Skip known non-mining process names (check both bin name and full cmdline)
        bin_name = parts[0].split("/")[-1]
        full_lower = args.lower()
        if "celery" in full_lower or "daphne" in full_lower or "gunicorn" in full_lower or "uvicorn" in full_lower:
            # Task queue / web server processes — not miners
            continue
        if bin_name in ("supervisord", "systemd", "bash", "sh", "python",
                        "python3", "node", "ruby", "java"):
            # Only check for explicit miner binaries, skip --pool/--algorithm
            if "/forgeminer" in args:
                coins.add("Multi")
            elif "/xmrig" in args:
                coins.add("XMR")
            elif "/ethminer" in args or "/miner" in args:
                if not coins:
                    coins.add("ETH/ETC")
            continue
        for i, p in enumerate(parts):
            if p == "--algorithm" and i + 1 < len(parts):
                coins.add(parts[i + 1].upper())
            elif p.startswith("--algorithm="):
                coins.add(p.split("=", 1)[1].upper())
        for i, p in enumerate(parts):
            if p == "--pool" and i + 1 < len(parts):
                pools.add(parts[i + 1])
            elif p.startswith("--pool="):
                pools.add(p.split("=", 1)[1])
        if "/forgeminer" in args:
            coins.add("Multi")
        elif "/xmrig" in args:
            coins.add("XMR")
        elif "/ethminer" in args or "/miner" in args:
            if not coins:
                coins.add("ETH/ETC")
        if parts:
            bin_name = parts[0].split("/")[-1]
            if bin_name == "btx":
                coins.add("BTX")
            elif bin_name in ("xmrig", "xmrig-proxy"):
                coins.add("XMR")
            elif bin_name in ("ethminer", "eth", "ethminer64"):
                coins.add("ETH/ETC")
            elif bin_name in ("minerd", "cpuminer", "mining-proxy"):
                coins.add("Multi")
            elif bin_name in ("tlbminer", "tftminer", "xhminer"):
                coins.add("Multi")

    pool_names = set()
    pool_coins = set()
    for pool in pools:
        host = pool.split(":")[0]
        for ip, (name, coin) in POOL_IPS.items():
            if ip == host:
                pool_names.add(name)
                pool_coins.add(coin)
                break
        else:
            for domain, (name, coin) in POOL_DOMAINS.items():
                if host.endswith(domain):
                    pool_names.add(name)
                    pool_coins.add(coin)
                    break
            else:
                pool_names.add(host)

    coin_full_parts = []
    for abbr in sorted(coins | pool_coins):
        full = COIN_NAMES.get(abbr, abbr)
        if abbr == full:
            coin_full_parts.append(abbr)
        else:
            coin_full_parts.append(f"{abbr} {full}")
    coin_str = ", ".join(coin_full_parts) if coin_full_parts else ""
    pool_str = ", ".join(sorted(pool_names)) if pool_names else ""
    return coin_str, pool_str

def _extract_ai_info(cmdlines):
    if not cmdlines:
        return None, None
    for entry in cmdlines:
        args = entry.get("cmdline", "")
        parts = args.split()
        if not parts:
            continue
        comm = entry.get("comm", "").lower()
        engine = None
        search_text = f"{comm} {parts[0]} {args}"
        if "vllm" in search_text:
            engine = "VLLM"
        elif "ollama" in search_text:
            engine = "Ollama"
        elif "llama" in search_text:
            engine = "llama.cpp"
        elif "sglang" in search_text:
            engine = "SGLang"
        elif "text-generation" in search_text:
            engine = "TGI"
        elif "lmdeploy" in search_text:
            engine = "LMDeploy"
        elif "tensorrt" in search_text:
            engine = "TensorRT"
        if engine is None:
            continue

        model = None
        for i, p in enumerate(parts):
            if p == "--served-model-name" and i + 1 < len(parts):
                model = parts[i + 1]
                break
            elif p.startswith("--served-model-name="):
                model = p.split("=", 1)[1]
                break
        if model is None:
            for i, p in enumerate(parts):
                if p == "--model" and i + 1 < len(parts):
                    model = parts[i + 1].split("/")[-1]
                    break
                elif p.startswith("--model="):
                    model = p.split("=", 1)[1].split("/")[-1]
                    break
                elif p == "-m" and i + 1 < len(parts):
                    model = parts[i + 1].split("/")[-1]
                    break
                elif p.startswith("-m="):
                    model = p.split("=", 1)[1].split("/")[-1]
                    break
        if model is None:
            for p in parts:
                if p.startswith("/") and ("model" in p.lower() or "merged" in p.lower() or "checkpoint" in p.lower()):
                    model = p.split("/")[-1]
                    break
            if model is None and len(parts) > 2:
                candidate = parts[2]
                if not candidate.startswith("-") and len(candidate) < 80:
                    model = candidate.split("/")[-1]
        return engine, model
    return None, None

def _extract_training_info(cmdlines):
    """Extract training project path and model name from cmdlines.

    Returns (project_path, model_name) or (None, None).
    """
    if not cmdlines:
        return None, None
    for entry in cmdlines:
        args = entry.get("cmdline", "")
        parts = args.split()
        if not parts:
            continue
        project = None
        model = None
        for i, p in enumerate(parts):
            # Find the script path (with or without leading path)
            if p.endswith("/train.py") or p == "train.py" or p.endswith("/finetune.py") or p.endswith("/sft.py"):
                # Look backwards for a workspace/project directory
                # Priority: 1) cd path, 2) absolute path with workspace/data/projects, 3) other path
                for j in range(i - 1, max(0, i - 20), -1):
                    candidate = parts[j]
                    if candidate == "cd" and j + 1 < len(parts):
                        # "cd /workspace/foo/bar" — take last 2-3 components
                        cd_path = parts[j + 1]
                        segs = cd_path.rstrip("/").split("/")
                        if len(segs) >= 3:
                            project = "/".join(segs[-3:])
                        elif len(segs) >= 2:
                            project = "/".join(segs[-2:])
                        break
                    if candidate in ("python", "PYTHONUNBUFFERED=1", "&&", "1", "2", ">", "&"):
                        continue
                    # Skip .venv, node_modules, and similar noise dirs
                    if candidate.startswith(".venv") or candidate.startswith("node_modules"):
                        continue
                    if "/" in candidate and not candidate.startswith("--"):
                        segs = candidate.rstrip("/").split("/")
                        if len(segs) >= 2:
                            project = "/".join(segs[-3:])
                        else:
                            project = segs[-1]
                        break
                    elif candidate.startswith("/"):
                        segs = candidate.rstrip("/").split("/")
                        if len(segs) >= 3:
                            project = "/".join(segs[-3:])
                        elif len(segs) >= 2:
                            project = "/".join(segs[-2:])
                        break

            # Find --encoder_name, --model, --architecture, --backbone
            if p == "--encoder_name" and i + 1 < len(parts):
                model = parts[i + 1]
            elif p.startswith("--encoder_name="):
                model = p.split("=", 1)[1]
            elif p == "--model" and i + 1 < len(parts):
                model = parts[i + 1].split("/")[-1]
            elif p.startswith("--model="):
                model = p.split("=", 1)[1].split("/")[-1]
            elif p == "--architecture" and i + 1 < len(parts):
                model = parts[i + 1]
            elif p.startswith("--architecture="):
                model = p.split("=", 1)[1]
            elif p == "--backbone" and i + 1 < len(parts):
                model = parts[i + 1]
            elif p.startswith("--backbone="):
                model = p.split("=", 1)[1]

        if project or model:
            return project, model
    return None, None

def classify(proc_names, gpu_mem, connections, image="", cmdlines=None, ai_cmdlines=None):
    cmdlines = cmdlines or []
    ai_cmdlines = ai_cmdlines or []

    # AI inference from live process scan (most detailed)
    ai_engine, ai_model = _extract_ai_info(ai_cmdlines)
    if ai_engine:
        if ai_model:
            return f"Inference  {ai_engine} {ai_model}"
        return f"Inference  {ai_engine}"

    # Image name hints
    img = (image or "").lower()
    if any(k in img for k in ("vllm", "llama", "ollama", "sglang", "text-generation",
                               "tgi", "lmdeploy", "tensorrt")):
        if "vllm" in img:
            return "Inference  VLLM"
        if "ollama" in img:
            return "Inference  Ollama"
        if "sglang" in img:
            return "Inference  SGLang"
        if "text-generation" in img or "tgi" in img:
            return "Inference  TGI"
        if "lmdeploy" in img:
            return "Inference  LMDeploy"
        if "tensorrt" in img:
            return "Inference  TensorRT"
        if "llama" in img:
            return "Inference  llama.cpp"

    if "comfyui" in img or "stable-diffusion" in img or "sd-webui" in img:
        return "Image Generation"
    if "mining" in img or "miner" in img:
        return "Mining"
    if "otaiku" in img:
        return "GPU Compute  otaiku"

    # Cmdline-based mining
    coin_str, pool_str = _parse_cmdline_for_mining(cmdlines)
    if coin_str or pool_str:
        if coin_str and pool_str:
            return f"Mining  {coin_str} via {pool_str}"
        if coin_str:
            return f"Mining  {coin_str}"
        return f"Mining  via {pool_str}"

    # Mining via process names
    miner_procs = proc_names & set(MINER_COIN.keys())
    if miner_procs:
        coins = []
        for p in miner_procs:
            coins.append(MINER_COIN[p])
        pools = set()
        for conn in connections:
            if conn.get("state") != "ESTAB":
                continue
            peer_host = conn.get("peer_host", "")
            peer_port = conn.get("peer_port", "")
            try:
                peer_port_int = int(peer_port)
            except (ValueError, TypeError):
                peer_port_int = 0
            if peer_host in POOL_IPS:
                pools.add(POOL_IPS[peer_host][0])
            elif peer_port_int in MINING_PORTS:
                pools.add(f"pool:{peer_port}")
        pool_str = ", ".join(sorted(pools)) if pools else ""
        coin_str = ", ".join(sorted(set(coins)))
        if pool_str:
            return f"Mining  {coin_str} via {pool_str}"
        return f"Mining  {coin_str}"

    # Mining pool connections (no miner proc)
    for conn in connections:
        if conn.get("state") != "ESTAB":
            continue
        peer_host = conn.get("peer_host", "")
        peer_port = conn.get("peer_port", "")
        try:
            peer_port_int = int(peer_port)
        except (ValueError, TypeError):
            peer_port_int = 0
        if peer_host in POOL_IPS:
            pool_name, coin_info = POOL_IPS[peer_host]
            return f"Mining  {coin_info} via {pool_name}"
        elif peer_port_int in MINING_PORTS:
            return "Mining  Unknown coin (mining pool port)"

    # AI inference (process names)
    ai_procs = {"vllm","llama.cpp_server","sglang","text-generation",
                "tgi","ollama","lmdeploy","tensorrt_llm","rfc",
                "llama-server","llama.cpp","vllm-engine"}
    if proc_names & ai_procs:
        return "AI Inference"
    if gpu_mem > 1024 and "python3" in proc_names:
        return "AI Inference"

    # AI training (from cmdline — catches train.py, torchrun, etc.)
    t_project, t_model = _extract_training_info(ai_cmdlines)
    if t_project or t_model:
        detail = ""
        if t_project:
            detail = f": {t_project}"
        if t_model:
            detail += f" - {t_model.capitalize()}"
        return f"Training{detail}"
    for entry in ai_cmdlines:
        args = entry.get("cmdline", "")
        if any(k in args for k in ("train.py", "finetune.py", "sft.py", "dpo.py")):
            return "Training"
        if any(f in args for f in ("--epochs", "--pretrain_epochs", "--fold ", "--augment_prob")):
            return "Training"
        if any(k in args for k in ("torchrun", "accelerate launch", "deepspeed", "fsdp", "megatron")):
            return "Training"

    # Training (from process names)
    if proc_names & {"torchrun","accelerate","deepspeed","fsdp",
                     "megatron","train","finetune","sft","dpo"}:
        return "Training"

    # Whisper
    if proc_names & {"whisper","faster_whisper","openai_whisper"}:
        return "Speech Recognition"

    # Jupyter
    if proc_names & {"jupyter","notebook","lab"}:
        return "Jupyter Notebook"

    # Image gen (ComfyUI / Stable Diffusion)
    for entry in ai_cmdlines + cmdlines:
        args = entry.get("cmdline", "")
        if "ComfyUI" in args or ("main.py" in args and "8188" in args):
            return "Image Generation  ComfyUI"
    if proc_names & {"stable_diffusion","diffusers","comfyui",
                      "automatic1111","sd_webui"}:
        return "Image Generation"

    # Database
    if proc_names & {"postgres","mongod","redis-server","valkey-server",
                     "mariadbd","clickhouse","surrealdb","keydb-server"}:
        return "Database"

    # Web server
    if proc_names & {"nginx","caddy","httpd","apache2","traefik"}:
        return "Web Server"

    # Container runtime
    if proc_names & {"containerd","dockerd","kubelet"}:
        return "Container Runtime"

    # SSH/session
    if proc_names & {"sshd","ssh","tmux"}:
        return "SSH Session"

    # General compute
    if proc_names & {"python3","python","node","go","java","rust",
                     "gcc","make","cmake","cargo"}:
        return "General Compute"

    return "Unknown"

def build_gpu_str(gpus):
    def fmt(g):
        gpu_name = format_gpu_name(g.get("name", "?"))
        mem_used_mib = g.get("mem_used_mib", 0)
        mem_total_mib = g.get("mem_total_mib", 0)
        fan = g.get("fan_pct", 0)
        temp = g.get("temp_c", 0)
        util = g.get("util_pct", 0)
        power = g.get("power_w", 0)
        try:
            fan = f"{float(fan):.0f}%"
        except (ValueError, TypeError):
            fan = "0%"
        try:
            mem_pct = float(mem_used_mib) / float(mem_total_mib) * 100.0 if mem_total_mib else 0
            mem_pct = f"{mem_pct:.0f}%"
        except (ValueError, TypeError):
            mem_pct = "0%"
        try:
            temp = f"{float(temp):.1f}"
        except (ValueError, TypeError):
            temp = "0.0"
        try:
            util = f"{float(util):.0f}"
        except (ValueError, TypeError):
            util = "0"
        try:
            power = f"{float(power):.1f}"
        except (ValueError, TypeError):
            power = "0.0"
        return (gpu_name, mem_pct, fan, temp, util, power, 1)

    if not gpus:
        return None, None
    first = fmt(gpus[0])
    second = fmt(gpus[1]) if len(gpus) > 1 else None
    if second:
        first = (first[0] + "(2)", first[1], first[2], first[3], first[4], first[5], 2)
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

if JSON_MODE:
    print(json.dumps(results, indent=2))
    sys.exit(0)

# --- Save mode: append one JSON line per host/container ---
if SAVE_MODE:
    os.makedirs(os.path.dirname(SAVE_LOG), exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat()
    save_records = []
    for r in results:
        host = r.get("host", "?")
        if "error" in r:
            save_records.append({"ts": ts, "host": host, "error": r["error"]})
            continue
        containers = r.get("containers", [])
        gpus = r.get("gpu", [])
        if not containers:
            save_records.append({"ts": ts, "host": host, "container": None, "label": "idle",
                                  "gpu": gpus, "process_summary": r.get("process_summary", {})})
        else:
            for c in containers:
                cname = c.get("name", "?")
                if cname.endswith("/ssh"):
                    cname = cname[:-4]
                gpu_info = c.get("gpu", {})
                connections = c.get("connections", [])
                proc_summary = c.get("process_summary", {})
                proc_names = set(proc_summary.keys())
                label = classify(proc_names, gpu_info.get("mem_mib", 0), connections,
                                 image=c.get("image", ""),
                                 cmdlines=r.get("gpu_cmdlines", []),
                                 ai_cmdlines=r.get("ai_cmdlines", []))
                save_records.append({
                    "ts": ts, "host": host, "container": cname, "label": label,
                    "gpu": gpu_info, "image": c.get("image", ""),
                    "process_summary": proc_summary,
                })
    with open(SAVE_LOG, "a") as f:
        for rec in save_records:
            f.write(json.dumps(rec) + "\n")

# --- Table output ---
hdr = f"{'HOST':<8s} {'INSTANCE':<15s} {'UPTIME':>6s}  {'GPU_NAME':<15s} {'FAN':<6s} {'TEMP':<8s} {'MEM':<5s} {'UTIL':<4s} {'POWER':<10s} {'CLASS':<25s}"
print(hdr)
print("-" * len(hdr))

for r in results:
    if "error" in r:
        host = r["host"]
        print(f"{host:<8s} {'-':<15s} {'-':>6s}  {'-':<15s} {'-':<6s} {'-':<8s} {'-':<5s} {'-':<4s} {'-':<10s} {'unreachable':<25s}")
        continue

    host = r.get("host", "?")
    uptime_s = r.get("uptime_s", 0)
    host_uptime_str = parse_uptime(uptime_s)
    gpus = r.get("gpu", [])
    containers = r.get("containers", [])

    if not containers:
        gpu_data, _ = build_gpu_str(gpus)
        if gpu_data is None:
            print(f"{host:<8s} {'-':<15s} {host_uptime_str:>6s}  {'-':<15s} {'-':<6s} {'-':<8s} {'-':<5s} {'-':<4s} {'-':<10s} {'idle':<25s}")
        else:
            gpu_name, mem_pct, fan, temp, util, power, _ = gpu_data
            print(f"{host:<8s} {'-':<15s} {host_uptime_str:>6s}  {gpu_name:<15s} {fan:<6s}{temp:<8s}{mem_pct:<5s}{util:<4s}{power:<10s} {'idle':<25s}")
        continue

    for c in containers:
        name = c.get("name", "?")
        if name.endswith("/ssh"):
            name = name[:-4]

        started_at = c.get("started_at", "")
        up_str = container_uptime(started_at) if started_at else "-"

        gpu_info = c.get("gpu", {})
        gpu_mem = gpu_info.get("mem_mib", 0)
        connections = c.get("connections", [])
        proc_summary = c.get("process_summary", {})
        proc_names = set(proc_summary.keys())

        label = classify(proc_names, gpu_mem, connections,
                         image=c.get("image", ""),
                         cmdlines=r.get("gpu_cmdlines", []),
                         ai_cmdlines=r.get("ai_cmdlines", []))

        gpu_data, gpu_data2 = build_gpu_str(gpus)
        if gpu_data is None:
            print(f"{host:<8s} {name:<15s} {up_str:>6s}  {'-':<15s} {'-':<6s} {'-':<8s} {'-':<5s} {'-':<4s} {'-':<10s} {label:<25s}")
            continue

        if gpu_data2 is None:
            g = gpu_data
            print(f"{host:<8s} {name:<15s} {up_str:>6s}  {g[0]:<15s} {g[2]:<6s}{g[3]:<8s}{g[1]:<5s}{g[4]:<4s}{g[5]:<10s} {label:<25s}")
        else:
            g1, g2 = gpu_data, gpu_data2
            print(f"{host:<8s} {name:<15s} {up_str:>6s}  {g1[0]:<15s} {g1[2]:<6s}{g1[3]:<8s}{g1[1]:<5s}{g1[4]:<4s}{g1[5]:<10s} {label:<25s}")
PYTHON_SCRIPT
