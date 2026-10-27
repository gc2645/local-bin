#!/usr/bin/env bash
#
# llama-swap-benchmark.sh
# Benchmark all models on a llama-swap instance (default: localhost:8080)
#
# Usage:
#   ./llama-swap-benchmark.sh [BASE_URL] [USER_PROMPT]
#
# Examples:
#   ./llama-swap-benchmark.sh
#   ./llama-swap-benchmark.sh http://localhost:8080 "Summarize the history of Rome in 3 sentences."
#   ./llama-swap-benchmark.sh http://my-server:8080 "What is quantum entanglement?"
#

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
USER_PROMPT="${2:-Hello, can you tell me a short fun fact about space?}"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[bench]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
info() { echo -e "${CYAN}[info]${NC} $*"; }

# Get total GPU memory used across ALL GPUs (returns plain integer bytes).
# Prefers nvidia-smi (instant, exact VRAM on NVIDIA hosts). On hosts without
# it (e.g. macOS / Apple Silicon) it falls back to llama-swap's /metrics
# gauge, which reads the current model's memory but is refreshed on llama-swap's
# own polling interval -- so the caller must wait for it to settle (see
# unload_all) before treating a reading as the idle baseline.
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
    if [ -z "$bytes" ]; then
        bytes=$(curl -s --max-time 5 "${BASE_URL}/metrics" 2>/dev/null | python3 -c "
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

# Convert bytes to human-readable using Python (handles large numbers and negatives)
bytes_to_human() {
    python3 -c "
b = int(${1:-0})
if b < 0:
    print(f'{b/1024:.0f} KB (neg baseline drift)')
elif b >= 1073741824:
    print(f'{b/1073741824:.2f} GB')
elif b >= 1048576:
    print(f'{b/1048576:.2f} MB')
else:
    print(f'{b/1024:.0f} KB')
"
}

# Unload all models, then wait until GPU memory settles back to the idle
# baseline. A fixed sleep is not enough: large models free memory asynchronously
# and llama-swap's /metrics gauge is refreshed on its own polling interval, so
# the next model's "before" reading could otherwise include memory that is still
# being freed. Because the two platforms report different idle floors (near-zero
# VRAM on NVIDIA vs a ~0.5-0.6 GB noisy Metal baseline on macOS), we poll until
# the reading stops dropping near its own low-water mark rather than using one
# absolute threshold.
unload_all() {
    curl -s -X POST --max-time 10 "${BASE_URL}/api/models/unload" >/dev/null 2>&1 || true
    # wait a beat for the unload to start, then poll until it settles
    sleep 1
    PREV=-1
    MIN=-1
    IDLE=0
    for _ in $(seq 1 30); do
        CUR=$(get_gpu_mem)
        # NVIDIA idle is essentially zero, so a couple of MB per GPU is done
        if [ "$CUR" -le $((512 * 1024 * 1024)) ]; then
            break
        fi
        if [ "$MIN" -lt 0 ] || [ "$CUR" -lt "$MIN" ]; then
            MIN=$CUR
        fi
        # bottomed out: near the low-water mark AND not dropping quickly anymore
        if [ "$PREV" -ge 0 ] \
        && [ $((CUR - MIN)) -le $((256 * 1024 * 1024)) ] \
        && [ $((PREV - CUR)) -lt $((256 * 1024 * 1024)) ]; then
            IDLE=$((IDLE + 1))
            [ "$IDLE" -ge 2 ] && break
        else
            IDLE=0
        fi
        PREV=$CUR
        sleep 2
    done
    sleep 2
}

# ------------------------------------------------------------------
# Step 1: Get model list
# ------------------------------------------------------------------
log "Fetching model list from ${BASE_URL}/v1/models ..."
MODELS_JSON=$(curl -s --max-time 10 "${BASE_URL}/v1/models")

if [ -z "$MODELS_JSON" ]; then
    echo "ERROR: Could not fetch model list. Is llama-swap running at ${BASE_URL}?"
    exit 1
fi

# Extract model IDs
MODEL_IDS=$(echo "$MODELS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', []):
    print(m['id'])
")

if [ -z "$MODEL_IDS" ]; then
    echo "ERROR: No models found."
    exit 1
fi

MODEL_COUNT=$(echo "$MODEL_IDS" | wc -l | tr -d ' ')
info "Found ${MODEL_COUNT} model(s):"
echo "$MODEL_IDS" | while read -r id; do echo "  - $id"; done
echo

# ------------------------------------------------------------------
# Step 2: Unload everything to start clean
# ------------------------------------------------------------------
unload_all
log "All models unloaded. Starting benchmark..."
echo

# ------------------------------------------------------------------
# Step 3: Benchmark each model
# ------------------------------------------------------------------
# Collect results in a temp file
RESULTS_FILE=$(mktemp)
trap 'rm -f "$RESULTS_FILE"' EXIT

FIRST=true
while IFS= read -r MODEL_ID; do
    echo "============================================================"
    echo "  Model: ${MODEL_ID}"
    echo "============================================================"

    # Measure GPU memory before loading
    MEM_BEFORE=$(get_gpu_mem)
    info "GPU memory before: $(bytes_to_human "$MEM_BEFORE")"

    # Record start time
    START_TIME=$(date +%s%N)

    # Send "hello" to trigger model load
    info "Loading model with greeting..."
    HELLO_RESP=""
    HELLO_RESP=$(PROMPT_MODEL="$MODEL_ID" BASE="$BASE_URL" python3 -c "
import json, subprocess, os
payload = json.dumps({'model': os.environ['PROMPT_MODEL'], 'messages': [{'role': 'user', 'content': 'Hello'}], 'max_tokens': 20})
r = subprocess.run(['curl', '-s', '--max-time', '120', '-X', 'POST', os.environ['BASE']+'/v1/chat/completions', '-H', 'Content-Type: application/json', '-d', payload], capture_output=True, text=True)
print(r.stdout)
" 2>/dev/null)

    if [ -z "$HELLO_RESP" ]; then
        warn "Model ${MODEL_ID} failed to load (corrupted GGUF or incompatible). Skipping."
        echo
        echo "  Results for ${MODEL_ID}:"
        echo "  ─────────────────────────────────────────"
        echo "  Status: SKIPPED (model failed to load)"
        echo "  ─────────────────────────────────────────"
        echo
        echo "${MODEL_ID}|SKIPPED|N/A|N/A|N/A" >> "$RESULTS_FILE"
        info "Unloading ${MODEL_ID}..."
        unload_all
        continue
    fi

    # Now send the user prompt (this may benefit from cached KV cache)
    info "Running user prompt..."
    USER_RESP=""
    USER_RESP=$(PROMPT_MODEL="$MODEL_ID" BASE="$BASE_URL" PROMPT="$USER_PROMPT" python3 -c "
import json, subprocess, os
payload = json.dumps({'model': os.environ['PROMPT_MODEL'], 'messages': [{'role': 'user', 'content': os.environ['PROMPT']}], 'max_tokens': 512})
r = subprocess.run(['curl', '-s', '--max-time', '300', '-X', 'POST', os.environ['BASE']+'/v1/chat/completions', '-H', 'Content-Type: application/json', '-d', payload], capture_output=True, text=True)
print(r.stdout)
" 2>/dev/null)

    if [ -z "$USER_RESP" ]; then
        warn "Model ${MODEL_ID} user prompt failed. Skipping."
        echo
        echo "  Results for ${MODEL_ID}:"
        echo "  ─────────────────────────────────────────"
        echo "  Status: SKIPPED (prompt failed)"
        echo "  ─────────────────────────────────────────"
        echo
        echo "${MODEL_ID}|SKIPPED|N/A|N/A|N/A" >> "$RESULTS_FILE"
        info "Unloading ${MODEL_ID}..."
        unload_all
        continue
    fi

    # Record end time
    END_TIME=$(date +%s%N)

    # Measure GPU memory after
    sleep 1
    MEM_AFTER=$(get_gpu_mem)

    # Calculate delta
    MEM_DELTA=$(python3 -c "print(int(${MEM_AFTER:-0} - ${MEM_BEFORE:-0}))")

    # Elapsed time in seconds
    ELAPSED_NS=$((END_TIME - START_TIME))
    ELAPSED_SEC=$(echo "scale=2; $ELAPSED_NS / 1000000000" | bc)

    # Parse timings from the last response (user prompt)
    TIMINGS=$(echo "$USER_RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
t = data.get('timings', {})
print(f'{t.get(\"prompt_per_second\", 0):.2f}')
print(f'{t.get(\"predicted_per_second\", 0):.2f}')
print(t.get('prompt_ms', 0))
print(t.get('predicted_ms', 0))
print(round(t.get('prompt_ms', 0) + t.get('predicted_ms', 0), 1))
print(data.get('usage', {}).get('prompt_tokens', 0))
print(data.get('usage', {}).get('completion_tokens', 0))
" 2>/dev/null || echo -e "0.00\n0.00\n0\n0\n0\n0\n0")

    PREFILL_TPS=$(echo "$TIMINGS" | sed -n '1p')
    EVAL_TPS=$(echo "$TIMINGS" | sed -n '2p')
    PREFILL_MS=$(echo "$TIMINGS" | sed -n '3p')
    EVAL_MS=$(echo "$TIMINGS" | sed -n '4p')
    TOTAL_MS=$(echo "$TIMINGS" | sed -n '5p')
    PROMPT_TOKENS=$(echo "$TIMINGS" | sed -n '6p')
    COMPLETION_TOKENS=$(echo "$TIMINGS" | sed -n '7p')

    # Print per-model results
    echo
    echo "  Results for ${MODEL_ID}:"
    echo "  ─────────────────────────────────────────"
    echo "  Memory used:       $(bytes_to_human "$MEM_DELTA")"
    echo "  Prefill tokens/s:  ${PREFILL_TPS}"
    echo "  Eval tokens/s:     ${EVAL_TPS}"
    echo "  Prefill time:      ${PREFILL_MS} ms"
    echo "  Eval time:         ${EVAL_MS} ms"
    echo "  Total time:        ${TOTAL_MS} ms"
    echo "  Prompt tokens:     ${PROMPT_TOKENS}"
    echo "  Completion tokens: ${COMPLETION_TOKENS}"
    echo "  Wall clock time:   ${ELAPSED_SEC} s"
    echo "  ─────────────────────────────────────────"
    echo

    # Store result for final report
    echo "${MODEL_ID}|$(bytes_to_human "$MEM_DELTA")|${PREFILL_TPS}|${EVAL_TPS}|${ELAPSED_SEC}" >> "$RESULTS_FILE"

    # Unload before next model
    info "Unloading ${MODEL_ID}..."
    unload_all

done <<< "$MODEL_IDS"

# ------------------------------------------------------------------
# Step 4: Final report table
# ------------------------------------------------------------------
# Size the Model column to the longest model id so long names don't
# overflow the fixed-width frame.
MODEL_W=16
while IFS='|' read -r model _rest; do
    [ "${#model}" -gt "$MODEL_W" ] && MODEL_W=${#model}
done < "$RESULTS_FILE"

WIDS=( "$MODEL_W" 10 12 11 12 )
WALL_W=${WIDS[4]}

pad() { local s; printf -v s '%*s' "$1" ''; printf '%s' "${s// /$2}"; }

box_line() { # $1 left  $2 tee  $3 horiz  $4 right
    printf '%s' "$1"
    for ((i = 0; i < ${#WIDS[@]}; i++)); do
        pad $(( WIDS[$i] + 2 )) "$3"
        if [ "$i" -lt $((${#WIDS[@]} - 1)) ]; then
            printf '%s' "$2"
        else
            printf '%s' "$4"
        fi
    done
    printf '\n'
}

echo
box_line "╔" "╦" "═" "╗"
TITLE="BENCHMARK SUMMARY"
IW=$((MODEL_W + 59))
LP=$(( (IW - ${#TITLE}) / 2 ))
RP=$(( IW - ${#TITLE} - LP ))
printf "║%s%s%s║\n" "$(pad "$LP" ' ')" "$TITLE" "$(pad "$RP" ' ')"
box_line "╠" "╪" "═" "╣"
printf "║ %-${MODEL_W}s │ %-10s │ %-12s │ %-11s │ %-${WALL_W}s ║\n" \
    "Model" "Memory" "Prefill t/s" "Eval t/s" "Wall Time"
box_line "╠" "╪" "─" "╣"

while IFS='|' read -r model mem prefill_tps eval_tps wall_time; do
    printf "║ %-${MODEL_W}s │ %-10s │ %-12s │ %-11s │ %-${WALL_W}s ║\n" \
        "$model" "$mem" "$prefill_tps" "$eval_tps" "${wall_time}s"
done < "$RESULTS_FILE"

box_line "╚" "╧" "═" "╝"
echo

log "Benchmark complete."
