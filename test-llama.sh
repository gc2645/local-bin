#!/usr/bin/env bash
# test-llama - smoke-test models on a llama.cpp llama-server instance
#
# examples:
#   ./test-llama.sh                      # test every model on default host
#   ./test-llama.sh -H 127.0.0.1:8080    # test every model on specific host
#   ./test-llama.sh -m 'qwen'              # only matching models
#   ./test-llama.sh -p "say hi" -n        # dry run: show plan, don't execute
#   ./test-llama.sh -k                    # leave models loaded after testing
#
set -euo pipefail

# ------------------------------------------------------------------
# Defaults and Variables
# ------------------------------------------------------------------
HOST="127.0.0.1:8080"
PROMPT="hello"
PROMPT_FILE=""
MATCH=""
SORT="name"
LIST_ONLY=0
DRY_RUN=0
KEEP_LOADED=0
TIMEOUT=180
VERBOSE=1
RESULTS_FILE=""

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[bench]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
info() { echo -e "${CYAN}[info]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

usage() {
  cat <<'EOF'
usage: test-llama [options] [prompt]

targets one llama-server instance and runs the same smoke test against every model.

options:
  -H, --host HOST      server to test: host:port, or URL
                       (default 127.0.0.1:8080)
  -p, --prompt TEXT    prompt to send (default "hello"; also accepts one
                       positional argument)
  -f, --prompt-file F read prompt from file
  -m, --match REGEX    only test models whose name matches REGEX
  -s, --sort HOW       order models: name | size | none  (default name)
  -l, --list           show model list and capabilities
  -n, --dry-run        show what would run, execute nothing
  -k, --keep           do not unload models after testing
  -t, --timeout SECS   kill a run after SECS (default 180)
      --no-verbose     drop --verbose (no timing report)
  -h, --help           show this help and exit

EOF
}

die() { error "$*"; exit 1; }

# No args: proceed with defaults

while (( $# )); do
  case "$1" in
    -H|--host)     [[ $# -ge 2 ]] || die "$1 needs a value"; HOST="$2"; shift 2 ;;
    -p|--prompt)   [[ $# -ge 2 ]] || die "$1 needs a value"; PROMPT="$2"; shift 2 ;;
    -f|--prompt-file) [[ $# -ge 2 ]] || die "$1 needs a value"; PROMPT_FILE="$2"; shift 2 ;;
    -m|--match)    [[ $# -ge 2 ]] || die "$1 needs a value"; MATCH="$2"; shift 2 ;;
    -s|--sort)     [[ $# -ge 2 ]] || die "$1 needs a value"; SORT="$2"; shift 2 ;;
    -l|--list)     LIST_ONLY=1; shift ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -k|--keep)     KEEP_LOADED=1; shift ;;
    -t|--timeout)  [[ $# -ge 2 ]] || die "$1 needs a value"; TIMEOUT="$2"; shift 2 ;;
    --no-verbose) VERBOSE=0; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             PROMPT="$1"; shift ;;
  esac
done

# Normalize Host
HOST="${HOST#*//}"; HOST="${HOST%/}"
[[ "$HOST" != *:* ]] && HOST="$HOST:8080"

# Dependencies
command -v jq >/dev/null || die "jq is required"
command -v python3 >/dev/null || die "python3 is required"
curl -sf -o /dev/null --max-time 5 "http://$HOST/v1/models" || die "cannot reach llama-server at http://$HOST"

# ------------------------------------------------------------------
# Core Functions
# ------------------------------------------------------------------

get_gpu_mem() {
    local bytes=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        bytes=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | python3 -c "
import sys
total = 0.0
n = 0
for line in sys.stdin:
    line = line.strip()
    if line:
        total += float(line) * 1048576
        n += 1
if not n:
    raise SystemExit(1)
print(int(total))
" 2>/dev/null || true)
    fi
    # macOS: measure llama-server process RSS via ps
    if [ -z "$bytes" ] && command -v ps >/dev/null 2>&1; then
        # Try to find the llama-server process listening on the target port
        local port="${HOST##*:}"
        bytes=$(ps -o rss= -p "$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)" 2>/dev/null | tr -d ' ' || true)
        if [ -n "$bytes" ] && [[ "$bytes" =~ ^[0-9]+$ ]]; then
            # RSS is in KB, convert to bytes
            bytes=$((bytes * 1024))
        else
            bytes="0"
        fi
    fi
    # Fallback to /metrics if nvidia-smi is not available or returns nothing
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        bytes=$(curl -s --max-time 5 "http://$HOST/metrics" 2>/dev/null | python3 -c "
import sys
total = 0.0
n = 0
for line in sys.stdin:
    if 'llamaswap_gpu_memory_used_bytes{' in line:
        total += float(line.strip().split()[-1])
        n += 1
if not n:
    raise SystemExit(1)
print(int(total))
" 2>/dev/null || true)
    fi
    echo "${bytes:-0}"
}

bytes_to_human() {
    python3 -c "
b = int(${1:-0})
if b < 0:
    print(f'{b/1024:.0f} KB')
elif b >= 1073741824:
    print(f'{b/1073741824:.2f} GB')
elif b >= 1048576:
    print(f'{b/1048576:.2f} MB')
else:
    print(f'{b/1024:.0f} KB')
"
}

list_models() {
  curl -s "http://$HOST/v1/models" | jq -r --arg s "$SORT" '
    .data as $m
    | (if   $s == "size" then ($m | sort_by(.size))
       elif $s == "name" then ($m | sort_by(.id))
       else $m end)
    | .[].id'
}

# ------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
  PROMPT="$(cat "$PROMPT_FILE")"
  VERBOSE=0
fi

# Fetch models
mapfile -t MODELS < <(list_models)
if (( ${#MODELS[@]} )); then
  if [[ -n "$MATCH" ]]; then
    mapfile -t MODELS < <(printf '%s\n' "${MODELS[@]}" | grep -E "$MATCH" || true)
  fi
fi
(( ${#MODELS[@]} )) || die "no models matched on http://$HOST"

if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "Models on http://$HOST:"
  for m in "${MODELS[@]}"; do echo "  - $m"; done
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: the following models would be tested:"
  for m in "${MODELS[@]}"; do echo "  - $m"; done
  exit 0
fi

RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT

# --- Benchmark Loop ---

echo
echo "Starting benchmark for ${#MODELS[@]} model(s) on http://$HOST"
echo "============================================================"

for m in "${MODELS[@]}"; do
    echo "Testing model: $m"

    # 1. Measure memory before
    MEM_BEFORE=$(get_gpu_mem)
    
    # 2. Trigger load (send a tiny prompt)
    # We use the /v1/chat/completions endpoint as it's standard
    # We send a very short prompt to minimize time
    START_TIME=$(date +%s%N)
    
    # Using python to construct the JSON to avoid shell escaping hell
    resp=$(python3 -c "
import json, subprocess, os
payload = json.dumps({'model': '$m', 'messages': [{'role': 'user', 'content': 'hi'}], 'max_tokens': 5})
r = subprocess.run(['curl', '-s', '--max-time', '$TIMEOUT', '-X', 'POST', 'http://$HOST/v1/chat/completions', '-H', 'Content-Type: application/json', '-d', payload], capture_output=True, text=True)
print(r.stdout)
")

    if [ -z "$resp" ] || [ "$resp" == "{}" ]; then
        warn "Model $m failed to load. Skipping."
        echo "$m|SKIPPED|N/A|N/A|N/A" >> "$RESULTS_FILE"
        continue
    fi

    # 3. Run actual user prompt
    USER_RESP=$(python3 -c "
import json, subprocess, os
payload = json.dumps({'model': '$m', 'messages': [{'role': 'user', 'content': \"$PROMPT\"}], 'max_tokens': 512})
r = subprocess.run(['curl', '-s', '--max-time', '$TIMEOUT', '-X', 'POST', 'http://$HOST/v1/chat/completions', '-H', 'Content-Type: application/json', '-d', payload], capture_output=True, text=True)
print(r.stdout)
")

    if [ -z "$USER_RESP" ] || [ "$USER_RESP" == "{}" ]; then
        warn "Model $m user prompt failed. Skipping."
        echo "$m|SKIPPED|N/A|N/A|N/A" >> "$RESULTS_FILE"
        continue
    fi

    END_TIME=$(date +%s%N)
    
    # 4. Measure memory after
    # Wait a moment for the router to settle/finish any async cleanup
    sleep 1
    MEM_AFTER=$(get_gpu_mem)

    # 5. Parse Metrics
    # We extract: total_time, prompt_tokens, completion_tokens, prompt_tps, eval_tps
    metrics=$(echo "$USER_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
t = data.get('usage', {})
timings = data.get('timings', {})
# If llama-server uses standard OpenAI format, timings might be in a different place 
# or not present. We fallback to basic calculations if needed.
prompt_tokens = t.get('prompt_tokens', 0)
completion_tokens = t.get('completion_tokens', 0)
# If timings exists:
p_tps = timings.get('prompt_per_second', 0)
e_tps = timings.get('predicted_per_second', 0)
print(f'{prompt_tokens}|{completion_tokens}|{p_tps:.2f}|{e_tps:.2f}')
" 2>/dev/null || echo "0|0|0.00|0.00")

    IFS='|' read -r p_tokens c_tokens p_tps e_tps <<< "$metrics"
    
    ELAPSED_NS=$((END_TIME - START_TIME))
    ELAPSED_SEC=$(awk -v n="$ELAPSED_NS" 'BEGIN {printf "%.2f", n/1e9}')

    # 6. Memory Delta
    MEM_DELTA=$((MEM_AFTER - MEM_BEFORE))
    if [ "$MEM_DELTA" -lt 0 ]; then
        # If negative, it might be a baseline drift or timing issue. 
        # We report it but don't let it break the script.
        MEM_HUMAN=$(bytes_to_human "$MEM_DELTA")
        MEM_VAL_STR="$MEM_HUMAN"
        # For the table, we'll use 0 as the numeric value to avoid issues
        MEM_NUM=0
    else
        MEM_HUMAN=$(bytes_to_human "$MEM_DELTA")
        MEM_NUM=$MEM_DELTA
    fi

    echo "  Result: $m | Memory: $MEM_HUMAN | Time: ${ELAPSED_SEC}s | Eval: ${e_tps} t/s"
    echo "$m|$MEM_HUMAN|$p_tps|$e_tps|$ELAPSED_SEC" >> "$RESULTS_FILE"

    # 7. Cleanup (only if NOT keeping loaded)
    if [[ "$KEEP_LOADED" -eq 0 ]]; then
        # In a router setup, we can't easily "unload" one model. 
        # We just wait for the next one to load.
        # If we wanted to be aggressive, we could restart the service, 
        # but that's too much for a benchmark.
        sleep 1
    fi
done

# ------------------------------------------------------------------
# Final Report
# ------------------------------------------------------------------
echo
echo "============================================================"
echo "BENCHMARK SUMMARY"
echo "============================================================"

# Find max model name length
MAX_NAME_LEN=16
while IFS='|' read -r name _rest; do
    [[ ${#name} -gt $MAX_NAME_LEN ]] && MAX_NAME_LEN=${#name}
done < "$RESULTS_FILE"

printf "%-${MAX_NAME_LEN}s │ %-10s │ %-10s │ %-10s │ %-10s\n" "Model" "Memory" "Prompt/s" "Eval/s" "Wall (s)"
echo "╪────────────╪────────────╪────────────╪────────────╪────────────"

while IFS='|' read -r name mem p_tps e_tps wall; do
    printf "%-${MAX_NAME_LEN}s │ %-10s │ %-10s │ %-10s │ %-10s\n" "$name" "$mem" "$p_tps" "$e_tps" "$wall"
done < "$RESULTS_FILE"
echo "============================================================"
echo "Benchmark complete."
