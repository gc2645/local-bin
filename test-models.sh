#!/usr/bin/env bash
# test-models - smoke-test models on ollama or llama.cpp
#
# examples:
#   test-models.sh -b llama                     # test llama.cpp models
#   test-models.sh -b ollama -H 11435           # test ollama on :11435
#   test-models.sh -b llama -m 'qwen'           # only matching models
#   test-models.sh -b ollama -p "say hi" -n     # dry run
#   test-models.sh -b llama -k                  # leave models loaded
#   test-models.sh -b ollama --test-tools        # tool-calling tests
#   test-models.sh -b llama --logic-test         # logic reasoning tests
#
set -euo pipefail

# ------------------------------------------------------------------
# Defaults and Variables
# ------------------------------------------------------------------
BACKEND=""
HOST=""
PROMPT="hello"
PROMPT_FILE=""
MATCH=""
SORT="name"
LIST_ONLY=0
DRY_RUN=0
KEEP_LOADED=0
TIMEOUT=180
VERBOSE=1
TEST_TOOLS=0
LOGIC_TEST=0

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
usage: test-models.sh -b ollama|llama [options] [prompt]

targets one server and runs the same smoke test against every model.

required:
  -b, --backend ollama|llama   which backend to test (required)

options:
  -H, --host HOST          server to test: port, host:port, or URL
                           (ollama: default 127.0.0.1:11434, llama: default 127.0.0.1:8080)
  -p, --prompt TEXT        prompt to send (default "hello"; also accepts one
                           positional argument)
  -f, --prompt-file F      read prompt from file (implies --no-verbose)
  -m, --match REGEX        only test models whose name matches REGEX
  -s, --sort HOW           order models: name | size | none  (default name)
  -l, --list               show model list and capabilities
  -n, --dry-run            show what would run, execute nothing
  -k, --keep               do not unload models after testing
  -t, --timeout SECS       kill a run after SECS (default 180)
       --no-verbose        drop --verbose (no timing report)
       --test-tools         run tool-calling tests instead of prompt benchmark
       --logic-test         run 5 JSON-graded infrastructure reasoning scenarios
  -h, --help               show this help and exit

every test verifies the server has no model loaded first; leftovers from a
previous run (or another client) are stopped before the test starts.

PASS requires exit status 0 AND a real response: at least three consecutive
letters/digits. Whitespace-only, asterisk/punctuation spam (" * * [,]...")
or a missing reply counts as FAIL ("no response").

exit status: 0 all passed, 1 usage/server error, 2 one or more runs failed
EOF
}

die() { error "$*"; exit 1; }

(( $# == 0 )) && { usage; exit 0; }

while (( $# )); do
  case "$1" in
    -b|--backend)    [[ $# -ge 2 ]] || die "$1 needs a value"; BACKEND="$2"; shift 2 ;;
    -H|--host)       [[ $# -ge 2 ]] || die "$1 needs a value"; HOST="$2"; shift 2 ;;
    -p|--prompt)     [[ $# -ge 2 ]] || die "$1 needs a value"; PROMPT="$2"; shift 2 ;;
    -f|--prompt-file) [[ $# -ge 2 ]] || die "$1 needs a value"; PROMPT_FILE="$2"; shift 2 ;;
    -m|--match)      [[ $# -ge 2 ]] || die "$1 needs a value"; MATCH="$2"; shift 2 ;;
    -s|--sort)       [[ $# -ge 2 ]] || die "$1 needs a value"; SORT="$2"; shift 2 ;;
    -t|--timeout)    [[ $# -ge 2 ]] || die "$1 needs a value"; TIMEOUT="$2"; shift 2 ;;
    -l|--list)       LIST_ONLY=1; shift ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    -k|--keep)       KEEP_LOADED=1; shift ;;
    --no-verbose)    VERBOSE=0; shift ;;
    -h|--help)       usage; exit 0 ;;
    --test-tools)    TEST_TOOLS=1; shift ;;
    --logic-test)    LOGIC_TEST=1; shift ;;
    --)              shift; break ;;
    -*)              die "unknown option: $1 (try --help)" ;;
    *)               PROMPT="$1"; shift ;;
  esac
done

# Validate backend
[[ -z "$BACKEND" ]] && die "missing -b ollama|llama (try --help)"
case "$BACKEND" in
  ollama|llama) ;;
  *) die "unknown backend: $BACKEND (must be ollama or llama)" ;;
esac

(( TEST_TOOLS && LOGIC_TEST )) && die "--test-tools and --logic-test cannot be combined"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be seconds"

# Set default host based on backend
if [[ -z "$HOST" ]]; then
  case "$BACKEND" in
    ollama) HOST="127.0.0.1:11434" ;;
    llama)  HOST="127.0.0.1:8080" ;;
  esac
fi

# Normalize Host
HOST="${HOST#*//}"; HOST="${HOST%/}"
case "$BACKEND" in
  ollama) [[ "$HOST" =~ ^[0-9]+$ ]] && HOST="127.0.0.1:$HOST" ;;
  llama)  ;;
esac
[[ "$HOST" != *:* ]] && HOST="$HOST:${HOST##*:}"

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
  PROMPT="$(cat "$PROMPT_FILE")"
  VERBOSE=0
  echo "[bench] prompt loaded from $PROMPT_FILE" >&2
fi

# Dependencies
command -v jq >/dev/null || die "jq is required"
command -v python3 >/dev/null || die "python3 is required"

# Backend-specific dependency checks
case "$BACKEND" in
  ollama)
    command -v ollama >/dev/null || die "ollama is required"
    curl -sf -o /dev/null --max-time 5 "http://$HOST/api/tags" \
      || die "cannot reach ollama at http://$HOST"
    ;;
  llama)
    curl -sf -o /dev/null --max-time 5 "http://$HOST/v1/models" \
      || die "cannot reach llama-server at http://$HOST"
    ;;
esac

# ------------------------------------------------------------------
# Backend Adapters
# ------------------------------------------------------------------

# List model names (one per line)
list_models() {
  case "$BACKEND" in
    ollama)
      curl -s "http://$HOST/api/tags" | jq -r --arg s "$SORT" '
        .models as $m
        | (if   $s == "size" then ($m | sort_by(.size))
           elif $s == "name" then ($m | sort_by(.name))
           else $m end)
        | .[].name'
      ;;
    llama)
      curl -s "http://$HOST/v1/models" | jq -r --arg s "$SORT" '
        .data as $m
        | (if   $s == "size" then ($m | sort_by(.size))
           elif $s == "name" then ($m | sort_by(.id))
           else $m end)
        | .[].id'
      ;;
  esac
}

# Parse models.ini to get file path for a model alias
# Returns the full GGUF filename or empty if not found
models_ini_path() {
  local model="$1"
  local ini="${LLAMA_MODELS_INI:-$HOME/.config/llama.cpp/models.ini}"
  [[ -f "$ini" ]] || return
  # Extract model section matching alias, then get "model = path" line
  awk -v alias="$model" '
    /^\[/ { section = substr($0, 2, length($0)-2) }
    section == alias && /^model = / {
      sub(/^model = /, "")
      print
      exit
    }
  ' "$ini"
}

# Get model capabilities metadata
get_capabilities() {
  local model="$1"
  case "$BACKEND" in
    ollama)
      ollama show "$model" 2>/dev/null || echo "(no metadata)"
      ;;
    llama)
      local file_path
      file_path=$(models_ini_path "$model")
      if [[ -n "$file_path" ]]; then
        # Try llamactl first for formatted output
        if command -v llamactl >/dev/null 2>&1; then
          local found
          found=$(llamactl list 2>/dev/null | grep -E "$(basename "${file_path%.gguf}")" | head -1 || true)
          if [[ -n "$found" ]]; then
            echo "$found" | awk '{printf "  size: %s  ctx: %s  layers: %s  embed: %s\n", $2, $3, $4, $5}'
            echo "  file: $(basename "$file_path")"
            return
          fi
        fi
        # Fall back to showing file path and basic info
        echo "  file: $(basename "$file_path")"
        if [[ -f "$file_path" ]]; then
          local sz
          sz=$(du -h "$file_path" 2>/dev/null | cut -f1)
          echo "  size: ${sz:-?}"
        fi
      else
        # No models.ini entry — show /v1/models info
        curl -s "http://$HOST/v1/models" | jq -r --arg m "$model" '
          .data[] | select(.id == $m) |
          "  architecture: \(.[.architecture.input_modalities] | join("/"))\n  status: \(.status.value)\n  owned_by: \(.owned_by)"
        ' 2>/dev/null || echo "  (no metadata)"
      fi
      ;;
  esac
}

# List currently resident models
loaded_models() {
  case "$BACKEND" in
    ollama)
      ollama ps 2>/dev/null | awk 'NR > 1 && NF {print $1}'
      ;;
    llama)
      local model_info
      model_info=$(curl -s --max-time 5 "http://$HOST/v1/models" 2>/dev/null)
      if [ -z "$model_info" ]; then return; fi
      echo "$model_info" | jq -r '
        .data[] | select(.status.value == "loaded") | .id
      ' 2>/dev/null || true
      ;;
  esac
}

# Stop a specific model
stop_model() {
  local model="$1"
  case "$BACKEND" in
    ollama)
      ollama stop "$model" >/dev/null 2>&1 || warn "could not stop $model"
      ;;
    llama)
      # Kill the model's child process
      local model_info port pid
      model_info=$(curl -s --max-time 5 "http://$HOST/v1/models" 2>/dev/null)
      [ -z "$model_info" ] && return
      port=$(echo "$model_info" | jq -r '
        .data[] | select(.status.value == "loaded") | .id == $m
        | if . then .status.args as $a | [range($a | length) | select($a[.] == "--port") | $a[. + 1]] | first // empty else empty end
      ' 2>/dev/null) || true
      # Simpler: find the loaded model's port
      port=$(echo "$model_info" | jq -r '
        .data[] |
        select(.status.value == "loaded") |
        .status.args as $a |
        [range($a | length) | select($a[.] == "--port") | $a[. + 1]] |
        first // empty
      ' 2>/dev/null || echo "")
      [ -z "$port" ] && return
      pid=$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1) || true
      [ -z "$pid" ] && return
      kill "$pid" 2>/dev/null || true
      local retries=10
      while [ $retries -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.5; retries=$((retries - 1))
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      sleep 1
      ;;
  esac
}

# Wait until no models are resident
wait_idle() {
  local n
  for ((n=0; n<20; n++)); do
    [[ -z "$(loaded_models)" ]] && return 0
    sleep 0.25
  done
  return 1
}

# Ensure no model is loaded before a test
ensure_idle() {
  local loaded
  loaded=$(loaded_models)
  [[ -z "$loaded" ]] && return 0
  if (( KEEP_LOADED )); then
    echo "[bench] warning: model(s) already loaded (keep enabled): $(echo "$loaded" | paste -sd ' ' -)" >&2
    return 0
  fi
  info "stopping leftover model(s): $(echo "$loaded" | paste -sd ' ' -)"
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    stop_model "$model"
  done <<< "$loaded"
  wait_idle || echo "[bench] warning: model(s) remain resident" >&2
}

# Get GPU/memory usage for the currently loaded model
get_gpu_mem() {
  case "$BACKEND" in
    ollama)
      # Ollama: use 'ollama ps' — SIZE is $3, unit is $4 (GB/MB/KB)
      ollama ps 2>/dev/null | awk 'NR > 1 && NF {
        val = $3; unit = $4
        if (unit == "GB") printf "%d", val * 1073741824
        else if (unit == "MB") printf "%d", val * 1048576
        else if (unit == "KB") printf "%d", val * 1024
        else printf "%d", val
        exit
      }' || echo "0"
      ;;
    llama)
      # llama.cpp: measure the model child process's RSS
      local model_info port pid rss
      model_info=$(curl -s --max-time 5 "http://$HOST/v1/models" 2>/dev/null)
      [ -z "$model_info" ] && { echo "0"; return; }
      port=$(echo "$model_info" | jq -r '
        .data[] |
        select(.status.value == "loaded") |
        .status.args as $a |
        [range($a | length) | select($a[.] == "--port") | $a[. + 1]] |
        first // empty
      ' 2>/dev/null || echo "")
      [ -z "$port" ] && { echo "0"; return; }
      pid=$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -1) || true
      [ -z "$pid" ] && { echo "0"; return; }
      rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
      if [ -z "$rss" ] || ! [[ "$rss" =~ ^[0-9]+$ ]]; then
        echo "0"
      else
        echo $((rss * 1024))
      fi
      ;;
  esac
}

# Build the chat request payload (backend-adapted)
build_chat_request() {
  local model="$1" prompt="$2"
  case "$BACKEND" in
    ollama)
      jq -n --arg m "$model" --arg p "$prompt" \
        '{model:$m,messages:[{role:"user",content:$p}],stream:false}'
      ;;
    llama)
      jq -n --arg m "$model" --arg p "$prompt" \
        '{model:$m,messages:[{role:"user",content:$p}],stream:false}'
      ;;
  esac
}

# Run a chat completion and return response JSON
chat_completion() {
  local model="$1" prompt="$2" outfile="$3"
  local reqfile req_payload
  reqfile=$(mktemp)
  req_payload=$(build_chat_request "$model" "$prompt")
  echo "$req_payload" > "$reqfile"

  case "$BACKEND" in
    ollama)
      curl -s --max-time "$TIMEOUT" -X POST "http://${HOST}/api/chat" \
        -H "Content-Type: application/json" -d @"$reqfile" > "$outfile" 2>&1
      ;;
    llama)
      curl -s --max-time "$TIMEOUT" -X POST "http://${HOST}/v1/chat/completions" \
        -H "Content-Type: application/json" -d @"$reqfile" > "$outfile" 2>&1
      ;;
  esac
  rm -f "$reqfile"
}

# Parse metrics from response (backend-adapted)
parse_metrics() {
  local logfile="$1"
  case "$BACKEND" in
    ollama)
       # Ollama /api/chat returns flat fields (all durations in nanoseconds)
       python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
ec = d.get('eval_count', 0)
pc = d.get('prompt_eval_count', 0)
load_ns = d.get('load_duration', 0)
pev_ns = d.get('prompt_eval_duration', 0)
ev_ns = d.get('eval_duration', 0)
load = load_ns / 1e9 if load_ns else 0
inference = (pev_ns + ev_ns) / 1e9
ptps = pc / (pev_ns / 1e9) if pev_ns and pev_ns > 0 else 0
etps = ec / (ev_ns / 1e9) if ev_ns and ev_ns > 0 else 0
print(f'{load:.2f}|{inference:.2f}|{pc}|{ptps:.2f}|{ec}|{etps:.2f}')
" "$logfile" 2>/dev/null || echo "-|-|0|-|0|-"
      ;;
    llama)
      # llama.cpp: parse from /v1/chat/completions JSON response
      python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
u = d.get('usage', {})
t = d.get('timings', {})
pt = u.get('prompt_tokens', 0)
ct = u.get('completion_tokens', 0)
ptps = t.get('prompt_per_second', 0)
etps = t.get('predicted_per_second', 0)
total = t.get('total', 0)
load = t.get('prompt_n', 0)  # fallback
print(f'{total:.2f}|{load:.2f}|{pt}|{ptps:.2f}|{ct}|{etps:.2f}')
" "$logfile" 2>/dev/null || echo "0.00|0.00|0|0.00|0|0.00"
      ;;
  esac
}

# ------------------------------------------------------------------
# Tool-calling tests (shared logic, adapted per backend)
# ------------------------------------------------------------------

# JSON tool schema for Tests A/B/C (OpenAI-compatible format works for both)
TOOLS_JSON='[
  {
    "type": "function",
    "function": {
      "name": "get_host_status",
      "description": "Get the current status of a host machine",
      "parameters": {
        "type": "object",
        "properties": {
          "hostname": {
            "type": "string",
            "description": "The hostname of the machine to check"
          }
        },
        "required": ["hostname"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "get_gpu_status",
      "description": "Get the GPU status on a host machine",
      "parameters": {
        "type": "object",
        "properties": {
          "hostname": {
            "type": "string",
            "description": "The hostname of the machine to check"
          }
        },
        "required": ["hostname"]
      }
    }
  }
]'

# Build tool-calling request payload
build_tool_request() {
  local model="$1" prompt="$2"
  case "$BACKEND" in
    ollama)
      jq -n --arg m "$model" --arg p "$prompt" \
        --argjson tools "$TOOLS_JSON" \
        '{model:$m,messages:[{role:"user",content:$p}],tools:$tools,stream:false}'
      ;;
    llama)
      jq -n --arg m "$model" --arg p "$prompt" \
        --argjson tools "$TOOLS_JSON" \
        '{model:$m,messages:[{role:"user",content:$p}],tools:$tools,stream:false}'
      ;;
  esac
}

# Run a single tool test against a model
run_tool_test() {
  local model="$1" test_name="$2" prompt="$3"
  local outfile="$TEST_DIR/${test_name}.out"
  local reqfile="$TEST_DIR/${test_name}.json"

  build_tool_request "$model" "$prompt" > "$reqfile"

  case "$BACKEND" in
    ollama)
      curl -s --max-time "$TIMEOUT" -X POST "http://${HOST}/api/chat" \
        -H "Content-Type: application/json" -d @"$reqfile" > "$outfile" 2>&1
      ;;
    llama)
      curl -s --max-time "$TIMEOUT" -X POST "http://${HOST}/v1/chat/completions" \
        -H "Content-Type: application/json" -d @"$reqfile" > "$outfile" 2>&1
      ;;
  esac
}

# Evaluate a single tool test result
evaluate_tool_test() {
  local test_name="$1" outfile="$2"
  local tc_len result

  # Normalize jq path: ollama uses .message, llama uses .choices[0].message
  local mp='.choices[0].message'
  [[ "$BACKEND" == "ollama" ]] && mp='.message'

  tc_len=$(jq "$mp.tool_calls | if type == \"array\" then length else 0 end" "$outfile" 2>/dev/null)
  [[ -z "$tc_len" ]] && tc_len=0

  if [[ "$tc_len" -gt 0 ]]; then
    result="HAS_TOOLS"
  elif grep -q '"does not support tools"' "$outfile" 2>/dev/null; then
    result="UNSUPPORTED"
  else
    result="NO_TOOLS"
  fi

  case "$test_name" in
    tool_a)
      [[ "$result" == "UNSUPPORTED" ]] && { echo "UNSUPPORTED"; return; }
      [[ "$result" != "HAS_TOOLS" ]] && { echo "FAIL"; return; }
      local func_name args
      func_name=$(jq -r "$mp.tool_calls[0].function.name // \"\"" "$outfile" 2>/dev/null)
      args=$(jq -r "$mp.tool_calls[0].function.arguments // \"\"" "$outfile" 2>/dev/null)
      if [[ "$func_name" == "get_host_status" ]] && \
         echo "$args" | grep -q '"hostname"' && \
         echo "$args" | grep -q 'node20'; then
        echo "PASS"
      else
        echo "FAIL"
      fi
      ;;
    tool_b)
      [[ "$result" == "UNSUPPORTED" ]] && { echo "UNSUPPORTED"; return; }
      [[ "$result" != "HAS_TOOLS" ]] && { echo "FAIL"; return; }
      local func_names arg_str
      func_names=$(jq -r "$mp.tool_calls[].function.name" "$outfile" 2>/dev/null)
      arg_str=$(jq -r "$mp.tool_calls[].function.arguments" "$outfile" 2>/dev/null)
      if echo "$func_names" | grep -q 'get_gpu_status' && \
         echo "$arg_str" | grep -q '"hostname"' && \
         echo "$arg_str" | grep -q 'node14' && \
         ! echo "$func_names" | grep -q 'get_host_status'; then
        echo "PASS"
      else
        echo "FAIL"
      fi
      ;;
    tool_c)
      [[ "$result" == "UNSUPPORTED" ]] && { echo "UNSUPPORTED"; return; }
      [[ "$result" == "HAS_TOOLS" ]] && { echo "FAIL"; return; }
      local response_text
      response_text=$(jq -r "$mp.content // \"\"" "$outfile" 2>/dev/null)
      if echo "$response_text" | grep -qi "graphics processing unit"; then
        echo "PASS"
      else
        echo "FAIL"
      fi
      ;;
  esac
}

# Execute tool tests for a single model
run_tool_tests_for_model() {
  local model="$1"
  local a_result b_result c_result

  run_tool_test "$model" "tool_a" \
    "Is node20 running normally? Check its current status before answering."
  run_tool_test "$model" "tool_b" \
    "Check GPU status on node14."
  run_tool_test "$model" "tool_c" \
    "What does GPU stand for?"

  a_result=$(evaluate_tool_test "tool_a" "$TEST_DIR/tool_a.out")
  b_result=$(evaluate_tool_test "tool_b" "$TEST_DIR/tool_b.out")
  c_result=$(evaluate_tool_test "tool_c" "$TEST_DIR/tool_c.out")

  # Aggregate timing and tokens
  local a_r b_r c_r
  IFS='|' read -r _ a_elapsed a_ec a_er a_ed <<< "$(cat "$TEST_DIR/tool_a.result")"
  IFS='|' read -r _ b_elapsed b_ec b_er b_ed <<< "$(cat "$TEST_DIR/tool_b.result")"
  IFS='|' read -r _ c_elapsed c_ec c_er c_ed <<< "$(cat "$TEST_DIR/tool_c.result")"

  local total_elapsed total_eval_count total_eval_dur
  total_elapsed=$(awk -v a="$a_elapsed" -v b="$b_elapsed" -v c="$c_elapsed" \
    'BEGIN { printf "%.2f", a + b + c }')
  total_eval_count=$((a_ec + b_ec + c_ec))
  total_eval_dur=$(awk -v a="${a_ed:-0}" -v b="${b_ed:-0}" -v c="${c_ed:-0}" \
    'BEGIN { printf "%.0f", a + b + c }')

  local total_erate="0.00"
  if (( total_eval_count > 0 )); then
    if (( total_eval_dur > 0 )); then
      total_erate=$(awk -v tc="$total_eval_count" -v td="$total_eval_dur" \
        'BEGIN { printf "%.2f", tc / (td / 1e9) }')
    else
      total_erate=$(awk -v tc="$total_eval_count" -v el="$total_elapsed" \
        'BEGIN { if (el > 0) printf "%.2f", tc / el; else print "0.00" }')
    fi
  fi

  echo "${a_result}|${b_result}|${c_result}|${total_elapsed}|${total_eval_count}|${total_erate}"
}

# ------------------------------------------------------------------
# Logic testing (5 infrastructure reasoning scenarios)
# ------------------------------------------------------------------

logic_prompt() {
  case "$1" in
    placement) cat <<'EOF'
Three servers: node11 (16GB VRAM,32GB RAM,420W), node12 (24GB VRAM,32GB RAM,550W), node14 (24GB VRAM,64GB RAM,480W). Jobs: X needs 24GB VRAM/32GB RAM; Y 16GB VRAM/32GB RAM; Z 16GB VRAM/64GB RAM. One job per server. Circuit A capacity 1800W with 950W existing load; B capacity 1800W with 600W existing load. Assign jobs and servers to circuits, using every server exactly once. Output ONLY a JSON object with keys: "jobs" (object with X,Y,Z mapped to node names), "circuits" (object with A and B arrays of node names), "free_watts" (object with numeric A and B), and numeric "extra_watts". Calculate all fields. Any valid circuit assignment is accepted.
EOF
;;
    backup) cat <<'EOF'
Three backups of a VM exist: full F1 Sunday 01:00, incremental I1 Monday 01:00 based on F1, incremental I2 Tuesday 01:00 based on I1. Tuesday 03:00 VM is lost. F1 and I1 are intact; I2 is corrupted. Restore to latest recoverable point. Output JSON only with keys "restore_order" (array of backup IDs), "restore_point" (day and HH:MM), and "use_corrupt" (boolean).
EOF
;;
    quorum) cat <<'EOF'
A five-node cluster (a,b,c,d,e) needs strict majority for quorum. Alive nodes a,b,c; d,e are unreachable. Node b then crashes. Calculate before/after quorate status, the number of votes needed, and the minimum number of failed nodes that must return to restore quorum after b crashes. Output JSON only with keys "votes_required" (number), "before_quorate" (boolean), "after_quorate" (boolean), "nodes_to_recover" (number).
EOF
;;
    storage) cat <<'EOF'
A storage pool has 3 drives of 2TB each in RAIDZ1 (single parity). Usable nominal capacity is (N-1)*smallest_drive_size. The pool currently stores 3.3TB and must maintain 20% of usable capacity free. Can it accept a 0.2TB new dataset without violating that reserve? Calculate usable capacity, free space after the proposed write, and whether permitted. Output JSON only with keys "usable_tb" (number), "free_after_tb" (number), and "allow_write" (boolean).
EOF
;;
    incident) cat <<'EOF'
Monitoring shows a DNS virtual IP 10.0.0.53 answers ping, but DNS queries to 10.0.0.53 time out. A separate direct query to active node dns2 at 10.0.0.22 also times out. Passive node dns1 at 10.0.0.21 answers DNS queries. Keepalived reports dns2 as VIP owner. Decide whether the evidence proves routing/VIP failure, whether the active DNS service is healthy, and the safest first troubleshooting action. Choose action from ["check_dns_service_on_dns2","restart_entire_cluster","change_firewall_everywhere"]. Output JSON only with keys "vip_routing_proven_broken" (boolean), "active_dns_healthy" (boolean), and "first_action" (one of the listed actions).
EOF
;;
  esac
}

# Grader: extract JSON and grade the model's answer
grade_logic() {
  local scenario="$1" logfile="$2"
  python3 - "$scenario" "$logfile" <<'PYGRADER'
import json, re, sys
scenario, path = sys.argv[1:]
s = open(path, errors='replace').read()
# Strip ANSI escape codes
s = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', s)

# Try to extract content from OpenAI-compatible API response
try:
    d = json.loads(s)
    content = d.get('choices', [{}])[0].get('message', {}).get('content', '')
    if content:
        s = content
except (json.JSONDecodeError, KeyError, IndexError):
    pass

# Strip thinking/reasoning tags (both tags and markdown code fences)
s = re.sub(r'</think>.*?(?=\n)', '', s, flags=re.S|re.I)
s = re.sub(r'```(?:json)?\s*', '', s, flags=re.I)
s = re.sub(r'```', '', s, flags=re.I)

decoder = json.JSONDecoder()
objects = []
for m in re.finditer(r'\{', s):
    try:
        obj, n = decoder.raw_decode(s[m.start():])
        if isinstance(obj, dict): objects.append(obj)
    except json.JSONDecodeError: pass
if not objects:
    print('FORMAT'); sys.exit()
v = max(objects, key=lambda obj: len(obj))
def numeric(x):
    return isinstance(x, (int,float)) and not isinstance(x,bool)
def near(x, y):
    return numeric(x) and abs(x-y)<1e-5
def boolean(x, y):
    return type(x) is bool and x == y
ok = False
try:
    if scenario == 'placement':
        jobs=v['jobs']; circ=v['circuits']; free=v['free_watts']
        watts={'node11':420,'node12':550,'node14':480}
        ok=(jobs == {'X':'node12','Y':'node11','Z':'node14'}
            and isinstance(circ['A'],list) and isinstance(circ['B'],list)
            and sorted(circ['A']+circ['B'])==sorted(watts)
            and all(isinstance(n,str) and n in watts for n in circ['A']+circ['B'])
            and near(free['A'],1800-950-sum(watts[n] for n in circ['A']))
            and near(free['B'],1800-600-sum(watts[n] for n in circ['B']))
            and free['A']>=0 and free['B']>=0
            and near(v['extra_watts'], free['A']+free['B']))
    elif scenario == 'backup':
        ok=(v['restore_order']==['F1','I1'] and v['restore_point']=='Monday 01:00'
            and boolean(v['use_corrupt'],False))
    elif scenario == 'quorum':
        ok=(v['votes_required']==3 and boolean(v['before_quorate'],True)
            and boolean(v['after_quorate'],False) and v['nodes_to_recover']==1)
    elif scenario == 'storage':
        ok=(near(v['usable_tb'],4) and near(v['free_after_tb'],0.5)
            and boolean(v['allow_write'],False))
    elif scenario == 'incident':
        ok=(boolean(v['vip_routing_proven_broken'],False)
            and boolean(v['active_dns_healthy'],False)
            and v['first_action']=='check_dns_service_on_dns2')
except (KeyError, TypeError, ValueError):
    pass
print('PASS' if ok else 'FAIL')
PYGRADER
}

# ------------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------------

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

# Generate a table separator line given column widths
table_sep() {
  local sep=""
  for w in "$@"; do
    [[ -n "$sep" ]] && sep+=" "
    sep+=$(printf "%-${w}s" "" | tr ' ' '-')
  done
  echo "$sep"
}

# Compute max model name length from an array of names, with padding
max_model_len() {
  local max=0 m p=2
  for m in "$@"; do
    (( ${#m} > max )) && max=${#m}
  done
  (( max + p > 10 )) || max=8
  echo $(( max + p ))
}

# ------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------

# Fetch models
mapfile -t MODELS < <(list_models)
if (( ${#MODELS[@]} )); then
  if [[ -n "$MATCH" ]]; then
    mapfile -t MODELS < <(printf '%s\n' "${MODELS[@]}" | grep -E "$MATCH" || true)
  fi
fi
(( ${#MODELS[@]} )) || die "no models matched on http://$HOST"

# -- List mode: show model list and capabilities
if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "Models on http://$HOST ($BACKEND):"
  echo "============================================================"
  for m in "${MODELS[@]}"; do
    echo "  $m"
    get_capabilities "$m" | sed 's/^/    /'
    echo
  done
  exit 0
fi

# -- Dry run
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: the following models would be tested:"
  for m in "${MODELS[@]}"; do echo "  - $m"; done
  exit 0
fi

# ------------------------------------------------------------------
# Tool-calling test dispatch
# ------------------------------------------------------------------
if (( TEST_TOOLS )); then
  TEST_DIR=$(mktemp -d)
  trap "rm -rf $TEST_DIR" EXIT

  echo
  echo "=== Tool-calling tests ($BACKEND) ==="
  echo "Models: ${#MODELS[@]}"
  echo

  t_tools_total=0.00
  t_tools_n=0
  t_tools_tokens=0
  t_tools_erate_sum=0.00
  t_tools_erate_n=0
  t_tools_support=0
  t_tools_pass=0
  t_tools_fail=0
  t_tools_unsupported=0
  t_tools_skipped=0
  t_tools_failed_models=()

  declare -a T_SUM_M=() T_SUM_A=() T_SUM_B=() T_SUM_C=()
  declare -a T_SUM_TE=() T_SUM_TC=() T_SUM_ER=()

  for m in "${MODELS[@]}"; do
    echo "--- $m"
    ensure_idle

    # Run tool tests and capture timing/tokens from response
    run_tool_test "$m" "tool_a" \
      "Is node20 running normally? Check its current status before answering."

    # Extract eval metrics from tool_a response
    a_eval_count=0; a_eval_dur_ns=0
    a_eval_count=$(jq -r '.eval_count // 0' "$TEST_DIR/tool_a.out" 2>/dev/null)
    a_eval_dur_ns=$(jq -r '.eval_duration // 0' "$TEST_DIR/tool_a.out" 2>/dev/null)
    [[ -z "$a_eval_count" || "$a_eval_count" == "null" ]] && a_eval_count=0
    [[ -z "$a_eval_dur_ns" || "$a_eval_dur_ns" == "null" ]] && a_eval_dur_ns=0
    # Write result line for timing
    echo "0|0.00|${a_eval_count}|0.00|${a_eval_dur_ns}" > "$TEST_DIR/tool_a.result"

    run_tool_test "$m" "tool_b" \
      "Check GPU status on node14."
    b_eval_count=0; b_eval_dur_ns=0
    b_eval_count=$(jq -r '.eval_count // 0' "$TEST_DIR/tool_b.out" 2>/dev/null)
    b_eval_dur_ns=$(jq -r '.eval_duration // 0' "$TEST_DIR/tool_b.out" 2>/dev/null)
    [[ -z "$b_eval_count" || "$b_eval_count" == "null" ]] && b_eval_count=0
    [[ -z "$b_eval_dur_ns" || "$b_eval_dur_ns" == "null" ]] && b_eval_dur_ns=0
    echo "0|0.00|${b_eval_count}|0.00|${b_eval_dur_ns}" > "$TEST_DIR/tool_b.result"

    run_tool_test "$m" "tool_c" \
      "What does GPU stand for?"
    c_eval_count=0; c_eval_dur_ns=0
    c_eval_count=$(jq -r '.eval_count // 0' "$TEST_DIR/tool_c.out" 2>/dev/null)
    c_eval_dur_ns=$(jq -r '.eval_duration // 0' "$TEST_DIR/tool_c.out" 2>/dev/null)
    [[ -z "$c_eval_count" || "$c_eval_count" == "null" ]] && c_eval_count=0
    [[ -z "$c_eval_dur_ns" || "$c_eval_dur_ns" == "null" ]] && c_eval_dur_ns=0
    echo "0|0.00|${c_eval_count}|0.00|${c_eval_dur_ns}" > "$TEST_DIR/tool_c.result"

    a_result=$(evaluate_tool_test "tool_a" "$TEST_DIR/tool_a.out")
    b_result=$(evaluate_tool_test "tool_b" "$TEST_DIR/tool_b.out")
    c_result=$(evaluate_tool_test "tool_c" "$TEST_DIR/tool_c.out")

    # Use run_tool_tests_for_model for proper timing
    IFS='|' read -r r_a r_b r_c r_total r_tokens r_erate <<< "$(run_tool_tests_for_model "$m")"

    T_SUM_M+=("$m")
    T_SUM_A+=("$r_a")
    T_SUM_B+=("$r_b")
    T_SUM_C+=("$r_c")
    T_SUM_TE+=("$r_total")
    T_SUM_TC+=("$r_tokens")
    T_SUM_ER+=("$r_erate")

    echo "  Test A (required call): $r_a"
    echo "  Test B (tool select):   $r_b"
    echo "  Test C (no tool):       $r_c"
    echo "  Total time: ${r_total}s, Tokens: ${r_tokens}, Rate: ${r_erate} tok/s"

    if [[ "$r_a" == "UNSUPPORTED" ]]; then
      t_tools_unsupported=$((t_tools_unsupported + 1))
    else
      t_tools_support=$((t_tools_support + 1))
    fi

    for r in "$r_a" "$r_b" "$r_c"; do
      case "$r" in PASS) ((t_tools_pass+=1)) ;; FAIL|ERROR) ((t_tools_fail+=1)) ;; esac
    done
    [[ "$r_a" == "FAIL" ]] && t_tools_failed_models+=("$m:TestA")
    [[ "$r_b" == "FAIL" ]] && t_tools_failed_models+=("$m:TestB")
    [[ "$r_c" == "FAIL" ]] && t_tools_failed_models+=("$m:TestC")

    t_tools_tokens=$((t_tools_tokens + r_tokens))
    if (( r_tokens > 0 )); then
      t_tools_erate_sum=$(awk -v a="$t_tools_erate_sum" -v b="$r_erate" 'BEGIN { printf "%.2f", a + b }')
      t_tools_erate_n=$((t_tools_erate_n + 1))
    fi
    t_tools_total=$(awk -v a="$t_tools_total" -v b="$r_total" 'BEGIN { printf "%.2f", a + b }')
    t_tools_n=$((t_tools_n + 1))
  done

  {
  echo
  echo "=============================================================================="
  echo "tool-calling tests ($BACKEND): $(date '+%Y-%m-%d %H:%M:%S %Z') -H $HOST -t $TIMEOUT"

  _mlen=$(max_model_len "${T_SUM_M[@]}")
  printf "%-${_mlen}s %-6s %-6s %-6s %-8s %-8s %-7s\n" \
    "MODEL" "TestA" "TestB" "TestC" "Total(s)" "Eval#" "tok/s"
  table_sep $_mlen 6 6 6 8 8 7

  for i in "${!T_SUM_M[@]}"; do
    printf "%-${_mlen}s %-6s %-6s %-6s %-8s %-8s %-7s\n" \
      "${T_SUM_M[$i]:0:$_mlen}" "${T_SUM_A[$i]}" "${T_SUM_B[$i]}" "${T_SUM_C[$i]}" \
      "${T_SUM_TE[$i]}" "${T_SUM_TC[$i]}" "${T_SUM_ER[$i]}"
  done
  echo "------------------------------------------------------------------------------"

  avg_t_erate="-"
  if (( t_tools_erate_n )); then
    avg_t_erate=$(awk -v s="$t_tools_erate_sum" -v n="$t_tools_erate_n" 'BEGIN { printf "%.2f", s / n }')
  fi

  printf 'Models tested: %d\n' "${#T_SUM_M[@]}"
  printf 'Models supporting tools: %d\n' "$t_tools_support"
  printf 'Tests passed: %d  failed: %d\n' "$t_tools_pass" "$t_tools_fail"
  printf 'Unsupported tools: %d\n' "$t_tools_unsupported"
  if [[ "$avg_t_erate" == "-" ]]; then
    printf 'Total time: %.2fs\n' "$t_tools_total"
  else
    printf 'Total time: %.2fs · avg %.2f tok/s eval over %d passing run(s)\n' "$t_tools_total" "$avg_t_erate" "$t_tools_erate_n"
  fi
  if (( t_tools_fail )); then
    printf 'Failed: %s\n' "${t_tools_failed_models[*]}"
  fi
  echo "=============================================================================="
  } | tee -a "results-test-models"

  (( t_tools_fail )) && exit 2
  exit 0
fi

# ------------------------------------------------------------------
# Logic test dispatch
# ------------------------------------------------------------------
if (( LOGIC_TEST )); then
  echo "$BACKEND: five independently graded infrastructure scenarios (JSON)"
  scenarios=(placement backup quorum storage incident)
  [[ -n "$(command -v python3)" ]] || die "python3 required for --logic-test"
  if (( DRY_RUN )); then
    for m in "${MODELS[@]}"; do
      echo "$m: 5 scenarios"
    done
    exit 0
  fi
  declare -a L_MODELS=() L_SCORES=() L_TIME=()
  total_pass=0; total_fail=0
  for m in "${MODELS[@]}"; do
    echo; echo "=== $m"
    L_MODELS+=("$m")
    passed=0; elapsed_all=0.00; case_scores=()
    ensure_idle
    for scenario in "${scenarios[@]}"; do
      runlog=$(mktemp)
      prompt=$(logic_prompt "$scenario")
      t0=$(date +%s.%N)

      # Run the model
      chat_completion "$m" "$prompt" "$runlog"
      rc=$?
      t1=$(date +%s.%N)
      elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.2f",b-a}')
      elapsed_all=$(awk -v a="$elapsed_all" -v b="$elapsed" 'BEGIN {printf "%.2f",a+b}')

      if (( rc == 124 )); then grade=TIMEOUT
      elif (( rc != 0 )); then grade=ERROR
      else grade=$(grade_logic "$scenario" "$runlog"); fi
      case_scores+=("$grade")
      if [[ "$grade" == PASS ]]; then ((passed+=1)); ((total_pass+=1));
      else ((total_fail+=1)); fi
      printf '  %-10s %-8s %7ss\n' "$scenario" "$grade" "$elapsed"
      if [[ "$grade" != PASS ]]; then
        echo "  --- model answer ($scenario) ---"
        head -n 35 "$runlog"
      fi
      rm -f "$runlog"
    done
    L_SCORES+=("$passed/5") L_TIME+=("$elapsed_all")
    if (( ! KEEP_LOADED )); then
      stop_model "$m"
      wait_idle || echo "[bench] warning: $m still loaded" >&2
    fi
  done
  echo '=============================================================================='

  _mlen=$(max_model_len "${L_MODELS[@]}")
  printf "%-${_mlen}s %-8s %9s\n" MODEL CORRECT 'TOTAL(s)'
  table_sep $_mlen 8 9
  for i in "${!L_MODELS[@]}"; do
    printf "%-${_mlen}s %-8s %9s\n" "${L_MODELS[$i]:0:$_mlen}" "${L_SCORES[$i]}" "${L_TIME[$i]}"
  done
  echo "Scenarios passed: $total_pass; failed: $total_fail"
  echo '=============================================================================='
  (( total_fail == 0 )) || exit 2
  exit 0
fi

# ------------------------------------------------------------------
# Benchmark dispatch (default mode)
# ------------------------------------------------------------------

pass=0; fail=0; skip=0; failed=()
total_sum=0.00; erate_sum=0.00; erate_n=0
SUM_M=(); SUM_S=(); SUM_R=(); SUM_SZ=()
# Per-model metrics for llama.cpp (ollama uses SUM_R)
LLAMA_PC=(); LLAMA_EC=(); LLAMA_ER=(); LLAMA_TOTAL=(); LLAMA_PR=(); LLAMA_LOAD=()

for m in "${MODELS[@]}"; do
  echo
  echo "=== $m ==="
  if (( DRY_RUN )); then
    echo "    $BACKEND: $m \"${PROMPT:0:80}...\""
    continue
  fi

  ensure_idle

  runlog=$(mktemp)
  t0=$(date +%s.%N)
  chat_completion "$m" "$PROMPT" "$runlog"
  rc=$?
  t1=$(date +%s.%N)
  elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')

  # Check response validity
  reason=""
  if (( rc == 124 )); then
    reason="timeout after ${TIMEOUT}s"
    echo "[bench] timed out after ${TIMEOUT}s" >&2
  elif (( rc != 0 )); then
    reason="exit code $rc"
  elif ! grep -qE '[a-zA-Z0-9]{3,}' "$runlog" 2>/dev/null; then
    reason="no response"
  fi

  if [[ -z "$reason" ]]; then
    status=PASS; pass=$((pass + 1))
  else
    status=FAIL; fail=$((fail + 1)); failed+=("$m [$reason]")
  fi

  # Get memory
  MEM=$(get_gpu_mem)
  MEM_HUMAN=$(bytes_to_human "$MEM")

  # Get metrics
  metrics=$(parse_metrics "$runlog")

  if [[ "$BACKEND" == "ollama" ]]; then
    IFS='|' read -r m_total m_load m_pc m_pr m_ec m_er <<< "$metrics"
    SUM_SZ+=("$MEM_HUMAN")
    echo "--- $m: $status (${elapsed}s)${reason:+ - $reason} [mem: $MEM_HUMAN]"
  else
    # llama.cpp metrics from JSON response
    llama_metrics=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    u = d.get('usage', {})
    t = d.get('timings', {})
    pt = u.get('prompt_tokens', 0)
    ct = u.get('completion_tokens', 0)
    ptbs = t.get('prompt_per_second', 0)
    etps = t.get('predicted_per_second', 0)
    total_ms = t.get('prompt_ms', 0) + t.get('predicted_ms', 0)
    total_s = total_ms / 1000.0
    print(f'{pt}|{ct}|{ptbs:.2f}|{etps:.2f}|{total_s:.2f}')
except Exception:
    print('0|0|0.00|0.00|0.00')
" "$runlog" 2>/dev/null || echo "0|0|0.00|0.00|0.00")
    IFS='|' read -r m_pc m_ec m_pr m_er m_total <<< "$llama_metrics"
    # LOAD(s) = total elapsed - inference time (model is loaded fresh each run)
    m_load=$(awk -v e="$elapsed" -v t="$m_total" 'BEGIN { printf "%.2f", e - t }')
    LLAMA_PC+=("$m_pc")
    LLAMA_EC+=("$m_ec")
    LLAMA_ER+=("$m_er")
    LLAMA_TOTAL+=("$m_total")
    LLAMA_PR+=("$m_pr")
    LLAMA_LOAD+=("$m_load")
    SUM_SZ+=("$MEM_HUMAN")
    echo "--- $m: $status (${elapsed}s)${reason:+ - $reason} [mem: $MEM_HUMAN]"
  fi

  SUM_M+=("$m"); SUM_S+=("$status"); SUM_R+=("$metrics")
  if (( ! KEEP_LOADED )); then
    stop_model "$m"
    wait_idle || echo "[bench] warning: $m still loaded" >&2
  fi

  rm -f "$runlog"
done

{
echo
echo "=============================================================================="
echo "$BACKEND benchmark: $(date '+%Y-%m-%d %H:%M:%S %Z') -H $HOST -t $TIMEOUT"

_mlen=$(max_model_len "${SUM_M[@]}")
printf "%-${_mlen}s %-6s %10s %9s %9s %7s %8s %7s %8s\n" \
  "MODEL" "RESULT" "MEMORY" "LOAD(s)" "TIME(s)" "PROMPT#" "PROMPT/s" "EVAL#" "EVAL/s"
table_sep $_mlen 6 10 9 9 7 8 7 8
for i in "${!SUM_M[@]}"; do
  if [[ "$BACKEND" == "ollama" ]]; then
    # parse_metrics output: load|inference|pc|ptps|ec|etps
    IFS='|' read -r m_load m_inference m_pc m_pr m_ec m_er <<< "${SUM_R[$i]}"
    printf "%-${_mlen}s %-6s %10s %9s %9s %7s %8s %7s %8s\n" \
      "${SUM_M[$i]:0:$_mlen}" "${SUM_S[$i]}" "${SUM_SZ[$i]}" "$m_load" "$m_inference" "$m_pc" "$m_pr" "$m_ec" "$m_er"
  else
    printf "%-${_mlen}s %-6s %10s %9s %9s %7s %8s %7s %8s\n" \
      "${SUM_M[$i]:0:$_mlen}" "${SUM_S[$i]}" "${SUM_SZ[$i]}" "${LLAMA_LOAD[$i]:--}" "${LLAMA_TOTAL[$i]:--}" "${LLAMA_PC[$i]:-0}" "${LLAMA_PR[$i]:-0.00}" "${LLAMA_EC[$i]:-0}" "${LLAMA_ER[$i]:-0.00}"
  fi
done
echo "------------------------------------------------------------------------------"
printf '%d models: %d passed, %d failed, %d skipped\n' "${#SUM_M[@]}" "$pass" "$fail" "$skip"
if (( fail )); then
  printf 'failed: %s\n' "${failed[*]}"
fi
echo "=============================================================================="
} | tee -a "results-test-models"

if (( fail )); then
  exit 2
fi
