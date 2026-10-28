#!/usr/bin/env bash
# otest - smoke-test every model on a chosen ollama server
#
# examples:
#   otest --list                      # list models on default host
#   otest -H 11435                    # test every model on :11435
#   otest -H 11434 -m 'qwen|gemma'    # only matching models
#   otest -H 11435 -p "say hi" -n     # dry run: show plan, don't execute
#   otest -H 11436 -k                 # leave models loaded after testing

HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
PROMPT="hello"
PROMPT_FILE=""
MATCH=""
SORT="name"
LIST_ONLY=0
DRY_RUN=0
VERBOSE=1
HIDE_THINKING=""
THINK=""
KEEP_LOADED=0
TIMEOUT=180
TEST_TOOLS=0
LOGIC_TEST=0

usage() {
  cat <<'EOF'
usage: otest [options] [prompt]

targets one ollama server and runs the same smoke test against every model.

options:
  -H, --host HOST      server to test: port, host:port, or URL
                       (default $OLLAMA_HOST or 127.0.0.1:11434)
  -p, --prompt TEXT    prompt to send (default "hello"; also accepts one
                       positional argument)
  -f, --prompt-file F  read prompt from file (implies --no-verbose)
  -m, --match REGEX    only test models whose name matches REGEX
  -s, --sort HOW       order models: name | size | none  (default name)
  -l, --list           show model capabilities and supported thinking/default
  -n, --dry-run        show what would run, execute nothing
  -t, --timeout SECS   kill a run after SECS (default 180)
  -k, --keep           do not stop each model after its test (the pre-test
                       loaded check then only warns instead of stopping)
      --no-verbose     drop --verbose (no timing report)
      --hidethinking   hide thinking output
      --show-thinking  drop --hidethinking (print thinking tokens)
      --think[=MODE]   request a supported model-specific thinking mode
                       (bare --think = true; unsupported -> omit flag)
                       without this flag: use false where supported, else true
                       when supported; models without thinking remain unchanged
      --test-tools     run tool-calling tests instead of prompt benchmark
      --logic-test     run 5 JSON-graded infrastructure reasoning scenarios
  -h, --help           show this help and exit

every test verifies the server has no model loaded first; leftovers from a
previous run (or another client) are stopped before the test starts.

PASS requires exit status 0 AND a real response: at least three consecutive
letters/digits. Whitespace-only, asterisk/punctuation spam (" * * [,]...")
or a missing reply counts as FAIL ("no response").

environment:
  OLLAMA_HOST          same as --host; flag wins

exit status: 0 all passed, 1 usage/server error, 2 one or more runs failed
EOF
}

die() { echo "otest: $*" >&2; exit 1; }

(( $# == 0 )) && { usage; exit 0; }

while (( $# )); do
  case "$1" in
    -H|--host)     [[ $# -ge 2 ]] || die "$1 needs a value"; HOST="$2"; shift 2 ;;
    -p|--prompt)   [[ $# -ge 2 ]] || die "$1 needs a value"; PROMPT="$2"; shift 2 ;;
    -f|--prompt-file) [[ $# -ge 2 ]] || die "$1 needs a value"; PROMPT_FILE="$2"; shift 2 ;;
    -m|--match)    [[ $# -ge 2 ]] || die "$1 needs a value"; MATCH="$2"; shift 2 ;;
    -s|--sort)     [[ $# -ge 2 ]] || die "$1 needs a value"; SORT="$2"; shift 2 ;;
    -t|--timeout)  [[ $# -ge 2 ]] || die "$1 needs a value"; TIMEOUT="$2"; shift 2 ;;
    -l|--list)     LIST_ONLY=1; shift ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -k|--keep)     KEEP_LOADED=1; shift ;;
    --no-verbose)  VERBOSE=0; shift ;;
    --show-thinking) HIDE_THINKING=""; shift ;;
    --hidethinking) HIDE_THINKING=1; shift ;;
    --think)         if [[ $# -ge 2 && "$2" =~ ^(true|false|high|medium|low|max)$ ]]; then
                       THINK="$2"; shift 2
                     else
                       THINK="true"; shift
                     fi ;;
    --think=*)       VAL="${1#--think=}"
                     case "$VAL" in ""|true|false|high|medium|low|max) ;; *) die "invalid value for --think: \"$VAL\"" ;; esac
                     THINK="${VAL:-true}"; shift ;;
    -h|--help)     usage; exit 0 ;;
    --test-tools)  TEST_TOOLS=1; shift ;;
    --logic-test)  LOGIC_TEST=1; shift ;;
    --)            shift; break ;;
    -*)            die "unknown option: $1 (try --help)" ;;
    *)             PROMPT="$1"; shift ;;
  esac
done

(( TEST_TOOLS && LOGIC_TEST )) && die "--test-tools and --logic-test cannot be combined"

case "$SORT" in size|name|none) ;; *) die "--sort must be size, name, or none" ;; esac
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout must be seconds"

if [[ -n "$PROMPT_FILE" ]]; then
  [[ -f "$PROMPT_FILE" ]] || die "prompt file not found: $PROMPT_FILE"
  PROMPT="$(cat "$PROMPT_FILE")"
  VERBOSE=0
  echo "otest: prompt loaded from $PROMPT_FILE" >&2
fi

HOST="${HOST#*//}"; HOST="${HOST%/}"
[[ "$HOST" =~ ^[0-9]+$ ]] && HOST="127.0.0.1:$HOST"
[[ "$HOST" != *:* ]] && HOST="$HOST:11434"
export OLLAMA_HOST="$HOST"

command -v jq >/dev/null || die "jq is required"
command -v perl >/dev/null || die "perl is required"
curl -sf -o /dev/null --max-time 5 "http://$HOST/api/tags" \
  || die "cannot reach ollama at http://$HOST (server not running?)"

list_models() {
  curl -s "http://$HOST/api/tags" | jq -r --arg s "$SORT" '
    .models as $m
    | (if   $s == "size" then ($m | sort_by(.size))
       elif $s == "name" then ($m | sort_by(.name))
       else $m end)
    | .[].name'
}

mapfile -t MODELS < <(list_models)
if (( ${#MODELS[@]} )); then
  if [[ -n "$MATCH" ]]; then
    mapfile -t MODELS < <(printf '%s\n' "${MODELS[@]}" | grep -E "$MATCH" || true)
  fi
fi
(( ${#MODELS[@]} )) || die "no models matched on http://$HOST"

# Inspect each installed model once before running a benchmark.
# Never assume that thinking modes supported by other models are valid here.
declare -A THINK_LEVELS=() THINK_DEFAULTS=()
load_thinking_metadata() {
  local model details levels default
  for model in "${MODELS[@]}"; do
    details=$(ollama show "$model" 2>/dev/null) || details=""
    levels=$(printf '%s\n' "$details" | sed -nE 's/^[[:space:]]*levels[[:space:]]+([^[:space:]].*)$/\1/p' | head -n 1)
    default=$(printf '%s\n' "$details" | sed -nE 's/^[[:space:]]*default[[:space:]]+([^[:space:]]+).*$/\1/p' | head -n 1)
    THINK_LEVELS["$model"]="${levels//[[:space:]]/}"
    THINK_DEFAULTS["$model"]="${default:-none}"
  done
}

# If no explicit mode was requested, select false consistently wherever possible.
# Models without false support use true if available, otherwise no thinking option.
resolve_thinking() {
  local model="$1" levels="${THINK_LEVELS[$1]:-}" default="${THINK_DEFAULTS[$1]:-none}"
  THINK_MODE=""
  THINK_SKIP=0
  if [[ -n "$THINK" ]]; then
    if [[ ",$levels," == *",$THINK,"* ]]; then
      THINK_MODE="$THINK"
      THINK_LABEL="$THINK"
    else
      THINK_LABEL="none (unsupported:$THINK)"
    fi
  elif [[ ",$levels," == *",false,"* ]]; then
    THINK_MODE=false
    THINK_LABEL="auto:false (default=$default)"
  elif [[ ",$levels," == *",true,"* ]]; then
    THINK_MODE=true
    THINK_LABEL="auto:true (default=$default)"
  else
    THINK_LABEL="none"
  fi
}

response_text() {
  awk '/total duration:/ { exit } { print }' "$1" \
    | perl -CSD -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/[\x{2800}-\x{28FF}]//g' \
    | perl -CSD -ne '$t .= $_; END { exit !($t =~ /[\p{L}\p{N}]{3,}/) }'
}

has_response() {
  response_text "$1"
}

# Parse the Ollama CLI metrics block at the end of a run log.
# Outputs: total|load|prompt_count|prompt_rate|eval_count|eval_rate
parse_metrics() {
    local logfile="$1"
    local total load pc pr ec er

    # Duration: handle s, ms, and ns formats
    total=$(awk '/^total duration:/ {
        val=$3; gsub(/[^0-9.]/,"",val)
        if ($3~/ms/) printf "%.2f",val/1000
        else if ($3~/ns/) printf "%.2f",val/1e9
        else printf "%.2f",val+0
    }' "$logfile")

    load=$(awk '/^load duration:/ {
        val=$3; gsub(/[^0-9.]/,"",val)
        if ($3~/ms/) printf "%.2f",val/1000
        else if ($3~/ns/) printf "%.2f",val/1e9
        else printf "%.2f",val+0
    }' "$logfile")

    # Count fields: find first purely numeric field (skip unit labels like "token(s)")
    pc=$(awk '/prompt eval count:/ || /prompt count:/ {
        for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i;break}
    }' "$logfile")
    ec=$(awk '/^eval count:/ {
        for(i=1;i<=NF;i++) if($i~/^[0-9]+$/){print $i;break}
    }' "$logfile")

    # Rate fields: first field starting with a digit, strip non-numeric
    pr=$(awk '/prompt eval rate:/ || /prompt rate:/ {
        for(i=1;i<=NF;i++) if($i~/^[0-9]/){gsub(/[^0-9.]/,"",$i);print $i;break}
    }' "$logfile")
    er=$(awk '/^eval rate:/ {
        for(i=1;i<=NF;i++) if($i~/^[0-9]/){gsub(/[^0-9.]/,"",$i);print $i;break}
    }' "$logfile")

    echo "${total:--}|${load:--}|${pc:--}|${pr:--}|${ec:--}|${er:--}"
}

# Five independent, machine-scored infrastructure scenarios. Each answer is JSON.
# Only the final JSON object is graded; explanatory text is ignored.
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

# Extract a final JSON object even when a model includes prose or markdown fences.
# FORMAT means JSON couldn't be recovered; FAIL means parsed JSON is wrong.
# The grader does not need a predetermined textual solution for placement.
grade_logic() {
  local scenario="$1" logfile="$2"
  python3 - "$scenario" "$logfile" <<'PYGRADER'
import json, re, sys
scenario, path = sys.argv[1:]
s = open(path, errors='replace').read().split('total duration:')[0]
s = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', s)
# Remove only actual thinking blocks; never grade speculative JSON within them.
s = re.sub(r'<think>.*?</think>', '', s, flags=re.S|re.I)
decoder = json.JSONDecoder()
objects = []
for m in re.finditer(r'\{', s):
    try:
        obj, n = decoder.raw_decode(s[m.start():])
        if isinstance(obj, dict): objects.append(obj)
    except json.JSONDecodeError: pass
# Some terminal/model streams wrap a JSON string over physical lines.
# Retry with only those embedded newlines removed, leaving normal JSON alone.
if not objects:
    unwrapped = re.sub(r'(?<=[A-Za-z0-9_])\n(?=[A-Za-z0-9_])', '', s)
    for m in re.finditer(r'\{', unwrapped):
        try:
            obj, n = decoder.raw_decode(unwrapped[m.start():])
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
            and free['A']>=0 and free['B']>=0 and near(v['extra_watts'],0))
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

# Manage resident models between benchmarks. Never interpret the ollama ps
# header as a loaded model; keep the full ps table in benchmark output.
loaded_models() {
  ollama ps 2>/dev/null | awk 'NR > 1 && NF {print $1}'
}

stop_models() {
  local model
  while IFS= read -r model; do
    [[ -n "$model" ]] || continue
    ollama stop "$model" >/dev/null 2>&1 || echo "otest: warning: could not stop $model" >&2
  done
}

wait_idle() {
  local n
  for ((n=0; n<20; n++)); do
    [[ -z "$(loaded_models)" ]] && return 0
    sleep 0.25
  done
  return 1
}

ensure_idle() {
  local loaded
  loaded=$(loaded_models)
  [[ -z "$loaded" ]] && return 0
  if (( KEEP_LOADED )); then
    echo "otest: warning: model(s) already loaded (keep enabled): $(echo "$loaded" | paste -sd ' ' -)" >&2
    return 0
  fi
  echo "otest: pre-test, stopping leftover model(s): $(echo "$loaded" | paste -sd ' ' -)" >&2
  stop_models <<< "$loaded"
  wait_idle || echo "otest: warning: model(s) remain resident" >&2
}

# --- tool-calling tests -------------------------------------------------------

# JSON tool schema for Tests A/B/C
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

# Run a single tool test against a model via /api/chat
# Args: model test_name prompt
# Writes response JSON to $TEST_DIR/<test_name>.out
# Writes result line to $TEST_DIR/<test_name>.result
run_tool_test() {
  local model="$1" test_name="$2" prompt="$3"
  local reqfile="$TEST_DIR/${test_name}.json"
  local outfile="$TEST_DIR/${test_name}.out"

  # Construct valid JSON; the think key is optional and boolean.
  jq -n --arg model "$model" --arg prompt "$prompt" \
    --argjson tools "$TOOLS_JSON" --arg think "$THINK_MODE" \
    '{model:$model,messages:[{role:"user",content:$prompt}],tools:$tools,stream:false}
     + (if $think == "" then {} else {think:(if $think == "true" then true elif $think == "false" then false else $think end)} end)' > "$reqfile"

  local t0 t1
  t0=$(date +%s.%N)
  curl -s --max-time "$TIMEOUT" -X POST "http://${HOST}/api/chat" \
    -H "Content-Type: application/json" \
    -d @"$reqfile" > "$outfile" 2>&1
  t1=$(date +%s.%N)
  local elapsed
  elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')

  # Extract eval metrics from response
  local eval_count eval_dur_ns
  eval_count=$(jq -r '.eval_count // 0' "$outfile" 2>/dev/null)
  eval_dur_ns=$(jq -r '.eval_duration // 0' "$outfile" 2>/dev/null)
  [[ -z "$eval_count" || "$eval_count" == "null" ]] && eval_count=0
  [[ -z "$eval_dur_ns" || "$eval_dur_ns" == "null" ]] && eval_dur_ns=0

  local eval_rate="0.00"
  if (( eval_dur_ns > 0 )); then
    eval_rate=$(awk -v ec="$eval_count" -v ed="$eval_dur_ns" \
      'BEGIN { printf "%.2f", ec / (ed / 1e9) }')
  else
    # llama-swap may return eval_duration=0; use elapsed as fallback
    eval_rate=$(awk -v ec="$eval_count" -v el="$elapsed" \
      'BEGIN { if (el > 0) printf "%.2f", ec / el; else print "0.00" }')
  fi

  # Determine tool support and extract tool_calls length
  local tc_len
  tc_len=$(jq '.message.tool_calls | if type == "array" then length else 0 end' "$outfile" 2>/dev/null)
  [[ -z "$tc_len" ]] && tc_len=0

  local result
  if [[ "$tc_len" -gt 0 ]]; then
    result="HAS_TOOLS"
  elif grep -q '"does not support tools"' "$outfile" 2>/dev/null; then
    result="UNSUPPORTED"
  else
    result="NO_TOOLS"
  fi

  echo "${result}|${elapsed}|${eval_count}|${eval_rate}|${eval_dur_ns}" > "$TEST_DIR/${test_name}.result"
}

# Evaluate a single tool test result and return PASS/FAIL/UNSUPPORTED
evaluate_tool_test() {
  local test_name="$1" result_line="$2"
  local result
  IFS='|' read -r result _ _ _ <<< "$result_line"

  case "$test_name" in
    tool_a)
      if [[ "$result" == "UNSUPPORTED" ]]; then
        echo "UNSUPPORTED"; return
      elif [[ "$result" != "HAS_TOOLS" ]]; then
        echo "FAIL"; return
      fi
      local func_name args
      func_name=$(jq -r '.message.tool_calls[0].function.name // ""' "$TEST_DIR/tool_a.out" 2>/dev/null)
      args=$(jq -r '.message.tool_calls[0].function.arguments // ""' "$TEST_DIR/tool_a.out" 2>/dev/null)
      if [[ "$func_name" == "get_host_status" ]] && \
         echo "$args" | grep -q '"hostname"' && \
         echo "$args" | grep -q 'node20'; then
        echo "PASS"
      else
        echo "FAIL"
      fi
      ;;
    tool_b)
      if [[ "$result" == "UNSUPPORTED" ]]; then
        echo "UNSUPPORTED"; return
      elif [[ "$result" != "HAS_TOOLS" ]]; then
        echo "FAIL"; return
      fi
      local func_names arg_str
      func_names=$(jq -r '.message.tool_calls[].function.name' "$TEST_DIR/tool_b.out" 2>/dev/null)
      arg_str=$(jq -r '.message.tool_calls[].function.arguments' "$TEST_DIR/tool_b.out" 2>/dev/null)
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
      if [[ "$result" == "UNSUPPORTED" ]]; then
        echo "UNSUPPORTED"; return
      fi
      local tc_len response_text
      tc_len=$(jq '.message.tool_calls | if type == "array" then length else 0 end' "$TEST_DIR/tool_c.out" 2>/dev/null)
      [[ -z "$tc_len" ]] && tc_len=0
      if [[ "$tc_len" -gt 0 ]]; then
        echo "FAIL"; return
      fi
      response_text=$(jq -r '.message.content // ""' "$TEST_DIR/tool_c.out" 2>/dev/null)
      if echo "$response_text" | grep -qi "graphics processing unit"; then
        echo "PASS"
      else
        echo "FAIL"
      fi
      ;;
  esac
}

# Execute tool tests for a single model; prints "A|B|C|total_elapsed|total_eval_count|erate"
run_tool_tests_for_model() {
  local model="$1"
  local a_result b_result c_result

  run_tool_test "$model" "tool_a" \
    "Is node20 running normally? Check its current status before answering."
  run_tool_test "$model" "tool_b" \
    "Check GPU status on node14."
  run_tool_test "$model" "tool_c" \
    "What does GPU stand for?"

  a_result=$(evaluate_tool_test "tool_a" "$(cat "$TEST_DIR/tool_a.result")")
  b_result=$(evaluate_tool_test "tool_b" "$(cat "$TEST_DIR/tool_b.result")")
  c_result=$(evaluate_tool_test "tool_c" "$(cat "$TEST_DIR/tool_c.result")")

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

# --- end tool-calling tests ---------------------------------------------------

if [[ -z "$THINK" && "$LIST_ONLY" == 0 ]]; then
  echo 'otest: auto thinking policy: false where supported, true if false unavailable, else none'
fi
echo "otest: host=$HOST models=${#MODELS[@]} timeout=${TIMEOUT}s verbose=$VERBOSE hidethinking=$HIDE_THINKING think=${THINK:-none} prompt=\"${PROMPT:0:80}\""
echo "otest: $(date '+%Y-%m-%d %H:%M:%S %Z') flags: -H $HOST -t $TIMEOUT${THINK:+ --think=$THINK}${HIDE_THINKING:+ --hidethinking}${PROMPT_FILE:+ -f $PROMPT_FILE}"
(( DRY_RUN )) && echo "otest: dry run, nothing will execute"

SUMMARY_FILE="results-test-ollama"

# --- tool-calling test dispatch -----------------------------------------------
if (( TEST_TOOLS )); then
  TEST_DIR=$(mktemp -d)
  trap "rm -rf $TEST_DIR" EXIT

  echo
  echo "=== Tool-calling tests ==="
  if (( DRY_RUN )); then
    for m in "${MODELS[@]}"; do
      resolve_thinking "$m"
      if (( THINK_SKIP )); then
        echo "  $m: SKIP (unsupported --think=$THINK)"
      else
        echo "  $m: three API requests, think=${THINK_MODE:-omitted} [$THINK_LABEL]"
      fi
    done
    exit 0
  fi
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
    resolve_thinking "$m"
    echo "--- $m [thinking: $THINK_LABEL]"
    if (( THINK_SKIP )); then
      echo "  SKIP: --think=$THINK is not supported (levels: ${THINK_LEVELS[$m]:-none})"
      T_SUM_M+=("$m"); T_SUM_A+=("SKIP"); T_SUM_B+=("SKIP"); T_SUM_C+=("SKIP")
      T_SUM_TE+=("-"); T_SUM_TC+=("-"); T_SUM_ER+=("-")
      ((t_tools_skipped+=1))
      continue
    fi
    ensure_idle
    result_line=$(run_tool_tests_for_model "$m")
    IFS='|' read -r r_a r_b r_c r_total r_tokens r_erate <<< "$result_line"

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
  echo "otest: $(date '+%Y-%m-%d %H:%M:%S %Z') flags: --test-tools -H $HOST -t $TIMEOUT${THINK:+ --think=$THINK}"
  printf '%-26s %6s %6s %6s %8s %8s %7s\n' \
    "MODEL" "TestA" "TestB" "TestC" "Total(s)" "Eval#" "tok/s"
  printf '%-40s %6s %6s %6s %8s %8s %7s\n' \
    "----------------------------------------" "------" "------" "------" "--------" "-------" "-------"
  for i in "${!T_SUM_M[@]}"; do
    printf '%-40s %6s %6s %6s %8s %8s %7s\n' \
      "${T_SUM_M[$i]:0:40}" "${T_SUM_A[$i]}" "${T_SUM_B[$i]}" "${T_SUM_C[$i]}" \
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
  printf 'Unsupported tools: %d  skipped models (thinking): %d\n' "$t_tools_unsupported" "$t_tools_skipped"
  printf 'Total time: %.2fs · avg %.2f tok/s eval over %d passing run(s)\n' "$t_tools_total" "$avg_t_erate" "$t_tools_erate_n"
  if (( t_tools_fail )); then
    printf 'Failed: %s\n' "${t_tools_failed_models[*]}"
  fi
  echo "=============================================================================="
  } | tee -a "$SUMMARY_FILE"

  (( t_tools_fail )) && exit 2
  exit 0
fi
# --- end tool-calling test dispatch -------------------------------------------

pass=0; fail=0; skip=0; failed=()
total_sum=0.00; erate_sum=0.00; erate_n=0
SUM_M=(); SUM_S=(); SUM_R=(); SUM_SZ=()

if (( LOGIC_TEST )); then
  echo "otest: five independently graded infrastructure scenarios (JSON)"
  scenarios=(placement backup quorum storage incident)
  [[ -n "$(command -v python3)" ]] || die "python3 required for --logic-test"
  if (( DRY_RUN )); then
    for m in "${MODELS[@]}"; do
      resolve_thinking "$m"
      echo "$m: 5 scenarios, thinking=$THINK_LABEL"
    done
    exit 0
  fi
  declare -a L_MODELS=() L_THINK=() L_SCORES=() L_TIME=()
  total_pass=0; total_fail=0
  for m in "${MODELS[@]}"; do
    resolve_thinking "$m"
    echo; echo "=== $m [thinking: $THINK_LABEL]"
    L_MODELS+=("$m"); L_THINK+=("$THINK_LABEL")
    passed=0; elapsed_all=0.00; case_scores=()
    ensure_idle
    for scenario in "${scenarios[@]}"; do
      runlog=$(mktemp)
      args=(run)
      (( VERBOSE )) && args+=(--verbose)
      (( HIDE_THINKING )) && args+=(--hidethinking)
      [[ -n "$THINK_MODE" ]] && args+=("--think=$THINK_MODE")
      prompt=$(logic_prompt "$scenario")
      t0=$(date +%s.%N)
      timeout "$TIMEOUT" ollama "${args[@]}" "$m" "$prompt" > "$runlog" 2>&1
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
        awk '/^total duration:/ { exit } { print }' "$runlog" | tail -n 35
      fi
      rm -f "$runlog"
    done
    L_SCORES+=("$passed/5") L_TIME+=("$elapsed_all")
    ps_snapshot=$(ollama ps 2>&1)
    printf '%s\n' "$ps_snapshot"
    if (( ! KEEP_LOADED )); then
      stop_models <<< "$m"
      wait_idle || echo "otest: warning: $m still loaded" >&2
    fi
  done
  echo '=============================================================================='
  printf '%-40s %-27s %-8s %9s\n' MODEL THINK CORRECT 'TOTAL(s)'
  for i in "${!L_MODELS[@]}"; do
    printf '%-40s %-27s %-8s %9s\n' "${L_MODELS[$i]:0:40}" "${L_THINK[$i]}" "${L_SCORES[$i]}" "${L_TIME[$i]}"
  done
  echo "Scenarios passed: $total_pass; failed: $total_fail"
  echo '=============================================================================='
  (( total_fail == 0 )) || exit 2
  exit 0
fi

LOGIC_GRADES=()
THINK_LABELS=()

for m in "${MODELS[@]}"; do
  resolve_thinking "$m"
  THINK_LABELS+=("$THINK_LABEL")
  echo
  echo "=== $m [thinking: $THINK_LABEL]"
  if (( THINK_SKIP )); then
    echo "--- $m: SKIP (unsupported --think=$THINK; supports: ${THINK_LEVELS[$m]:-none})"
    SUM_M+=("$m"); SUM_S+=("SKIP"); SUM_R+=("-|-|-|-|-|-"); SUM_SZ+=("-")
    LOGIC_GRADES+=("-")
    ((skip+=1))
    continue
  fi
  if (( DRY_RUN )); then
    args=(run)
    (( VERBOSE )) && args+=(--verbose)
    (( HIDE_THINKING )) && args+=(--hidethinking)
    [[ -n "$THINK_MODE" ]] && args+=("--think=$THINK_MODE")
    echo "    ollama ${args[*]} $m "${PROMPT:0:80}...""
    continue
  fi

  ensure_idle

  runlog=$(mktemp)
  args=(run)
  (( VERBOSE )) && args+=(--verbose)
  (( HIDE_THINKING )) && args+=(--hidethinking)
  [[ -n "$THINK_MODE" ]] && args+=("--think=$THINK_MODE")

  t0=$(date +%s.%N)
  timeout "$TIMEOUT" ollama "${args[@]}" "$m" "$PROMPT" 2>&1 | tee "$runlog"
  rc=${PIPESTATUS[0]}
  t1=$(date +%s.%N)
  elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }')

  metrics=$(parse_metrics "$runlog")
  reason=""
  if (( rc == 124 )); then
    reason="timeout after ${TIMEOUT}s"
    echo "otest: timed out after ${TIMEOUT}s" >&2
  elif (( rc != 0 )); then
    reason="exit code $rc"
  elif ! has_response "$runlog"; then
    reason="no response"
  fi
  logic_grade="-"
  if (( LOGIC_TEST )) && [[ -z "$reason" ]]; then
    logic_grade=$(grade_logic "$runlog")
  fi
  LOGIC_GRADES+=("$logic_grade")
  rm -f "$runlog"

  if [[ -z "$reason" ]]; then
    if (( LOGIC_TEST )) && [[ "$logic_grade" != "PASS" ]]; then
      status=FAIL; fail=$((fail + 1)); failed+=("$m [logic: $logic_grade]")
    else
      status=PASS; pass=$((pass + 1))
    fi
  else
    status=FAIL; fail=$((fail + 1)); failed+=("$m [$reason]")
  fi

  ps_snapshot=$(ollama ps 2>&1)
  loaded_size=$(printf '%s\n' "$ps_snapshot" | tail -n +2 | awk -v model="$m" '$1 == model {print $3, $4; exit}')
  [[ -z "$loaded_size" ]] && loaded_size="-"
  if (( LOGIC_TEST )); then
    echo "--- $m: $status (${elapsed}s)${reason:+ - $reason} [thinking: $THINK_LABEL, logic: $logic_grade] [loaded: $loaded_size]"
  else
    echo "--- $m: $status (${elapsed}s)${reason:+ - $reason} [thinking: $THINK_LABEL] [loaded: $loaded_size]"
  fi

  SUM_M+=("$m"); SUM_S+=("$status"); SUM_R+=("$metrics"); SUM_SZ+=("$loaded_size")
  printf '%s\n' "$ps_snapshot"
  if (( ! KEEP_LOADED )); then
    stop_models <<< "$m"
    wait_idle || echo "otest: warning: $m still loaded" >&2
  fi
  IFS='|' read -r m_total _ _ _ _ m_erate <<< "$metrics"
  if [[ "$m_total" != "-" ]]; then
    total_sum=$(awk -v a="$total_sum" -v b="$m_total" 'BEGIN { printf "%.2f", a + b }')
  fi
  if [[ "$status" == "PASS" && "$m_erate" != "-" ]]; then
    erate_sum=$(awk -v a="$erate_sum" -v b="$m_erate" 'BEGIN { printf "%.2f", a + b }')
    erate_n=$((erate_n + 1))
  fi
done

if (( DRY_RUN )); then
  echo
  echo "otest: dry run complete, ${#MODELS[@]} models listed"
  exit 0
fi

avg_erate="-"
if (( erate_n )); then
  avg_erate=$(awk -v s="$erate_sum" -v n="$erate_n" 'BEGIN { printf "%.2f", s / n }')
fi

SUMMARY_FILE="results-test-ollama"

{
echo "=============================================================================="
echo "otest: $(date '+%Y-%m-%d %H:%M:%S %Z') flags: -H $HOST -t $TIMEOUT${THINK:+ --think=$THINK}${HIDE_THINKING:+ --hidethinking}${PROMPT_FILE:+ -f $PROMPT_FILE}"
printf '%-26s %-6s %9s %8s %7s %9s %6s %8s %8s %-25s %s\n' \
  "MODEL" "RESULT" "TOTAL(s)" "LOAD(s)" "PROMPT#" "PROMPT/s" "EVAL#" "EVAL/s" "SIZE" "THINK" "LOGIC"
printf '%-40s %-6s %9s %8s %7s %9s %6s %8s %8s %-25s %s\n' \
  "----------------------------------------" "------" "--------" "-------" "-------" "--------" "------" "-------" "--------" "-------------------------" "-----"
for i in "${!SUM_M[@]}"; do
  IFS='|' read -r t l pc pr ec er <<< "${SUM_R[$i]}"
  printf '%-40s %-6s %9s %8s %7s %9s %6s %8s %8s %-25s %s\n' \
    "${SUM_M[$i]:0:40}" "${SUM_S[$i]}" "$t" "$l" "$pc" "$pr" "$ec" "$er" "${SUM_SZ[$i]}" "${THINK_LABELS[$i]}" "${LOGIC_GRADES[$i]}"
done
echo "------------------------------------------------------------------------------"
printf '%d models: %d passed, %d failed, %d skipped\n' "${#SUM_M[@]}" "$pass" "$fail" "$skip"
printf 'total %.2fs · avg %s tok/s eval over %d passing run(s)\n' "$total_sum" "$avg_erate" "$erate_n"
if (( fail )); then
  printf 'failed: %s\n' "${failed[*]}"
fi
echo "=============================================================================="
} | tee -a "$SUMMARY_FILE"

if (( fail )); then
  exit 2
fi