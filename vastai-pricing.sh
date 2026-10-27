#!/usr/bin/env bash
# Vast.ai asking-price calculator.
#
# WHY the cheapest N and not the median of everything: the bottom of the pile
# is what actually gets rented. A listing priced at the market median is not a
# price you can expect to transact at -- it is a price at which you sit
# unrented behind cheaper inventory. So TOP=10 approximates the *bottom of the
# pile*, which is the band worth competing in, and the host should list
# renter_price * $HOST_SHARE of it, where HOST_SHARE is what the host pockets
# after Vast's cut.
#
# Consequence: these numbers are deliberately lower than the $/HR MED on
# cloud.vast.ai/host/market, which is the midpoint of ALL offers including the
# slow and overpriced ones. That gap is expected, not a bug. Use the site for
# market size, % rented and DLPERF; use this for the price you can get rented.
#
# The 1x/2x columns exist to answer one question: is it worth building a
# dual-GPU rig rather than two single-GPU rigs? Compare 1x List against 2x
# List and weigh the premium against halving the rest-of-system cost. Read
# those rows with the supply count in the same row -- 2x supply is thin on
# most cards and a "premium" computed from two offers is noise.
#
# The -v per-offer table exists to read how competitors configure rigs: the
# PCIE column is generation x lanes (e.g. 3x4, 4x16), plus vCPU, RAM, disk,
# score, verification and geolocation per listing. A cheap offer is only worth
# having if the host behind it is configured sanely -- a 3x4 card does not rent
# like a 4x16 one regardless of the asking price, and PCIe 3.0 x4 is a common
# way to run 40-series parts cheaply.
#
# HOST_SHARE = fraction of the renter-facing price that you actually keep.
# Vast's docs are not self-consistent on this:
#   FAQ            "hosts receive 75% of revenue ... 25% kept by Vast"  -> 0.75
#   earnings post  "live GPU prices are ~25% above what hosts earn"     -> 0.80
#   Jun 2024 note  "hosting fees changed to 0% ... prices hosts set will
#                   be the prices they earn"                            -> 1.00
# Default 0.75 per the FAQ. Override to measure your real take:
#   HOST_SHARE=1.0 ./vastai-pricing.sh
# Do NOT confuse this with min_bid_price, which is the interruptible bid
# floor and is set independently of the on-demand price.
#
# usage: ./vastai-pricing.sh [-v]
#   -v   also print the per-offer detail table for each GPU
#
# env:   EXCLUDE_GEOS=CN   MIN_REL=0.90   TOP=10   MIN_N=5   HOST_SHARE=0.75

set -euo pipefail

TOP="${TOP:-5}"
MIN_N="${MIN_N:-3}"
EXCLUDE_GEOS="${EXCLUDE_GEOS:-CN}"
MIN_REL="${MIN_REL:-0.90}"
HOST_SHARE="${HOST_SHARE:-0.75}"
# Verification statuses to drop. "deverified" means the host was once
# verified and now is not -- hardware may have changed hands since the check
# ran, so the listing is not trustworthy regardless of its price. Unverified
# is kept: it only means no check was ever run, which is common and cheap.
EXCLUDE_STATUS="${EXCLUDE_STATUS:-deverified}"

excl_json() {
  if [ -z "$EXCLUDE_STATUS" ]; then printf '[]'
  else printf '%s\n' "$EXCLUDE_STATUS" | tr ',' '\n' | jq -R . | jq -s .
  fi
}
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# ordered by family (50-series, 40-series, 30-series) then by size within family
GPUS=(RTX_5090 RTX_4090 RTX_5080 RTX_4080S RTX_4080 RTX_5070_Ti RTX_4070_Ti RTX_3090 RTX_5060_Ti)

# verified=None is essential: the vastai CLI injects verified=true into every
# search unless overridden, and verified-only offers skew expensive (on a
# RTX 5080 the verified median is 0.488 vs 0.311 unverified).
filters=("verified=None" "reliability>$MIN_REL")
[ -n "$EXCLUDE_GEOS" ] && filters+=("geolocation notin [$EXCLUDE_GEOS]")
FILTERS="${filters[*]}"

dir=$(mktemp -d)
trap 'rm -f -r "$dir"' EXIT

for g in "${GPUS[@]}"; do
  for n in 1 2; do
    vastai search offers "$FILTERS gpu_name=$g num_gpus=$n" -o 'dph' --raw \
      >"$dir/$g.$n.json" || echo '[]' >"$dir/$g.$n.json"
  done
done

JQ_LIB=$(cat <<'EOF'
def r3: (. * 1000 | round) / 1000;
def f3: if . == null then "n/a" else (r3 | tostring) end;
def ms($s): if . == null then null else (. * $s) end;
def gb: if . == null or . == 0 then "n/a" else ((. / 1024 | round) | tostring) end;
def keep: map(select((.verification // "") as $v
                     | ($excl | length) == 0 or ($excl | index($v)) == null));
def norm: keep | map({id: .ask_contract_id, total: .dph_total, n: .num_gpus,
               model: .gpu_name, pcie: .pci_gen, lanes: .gpu_lanes,
               vcpu: .cpu_cores_effective,
               ram: (.cpu_ram / 1024), disk: .disk_space, score: .score,
               status: .verification, geo: .geolocation, rel: .reliability,
               per_gpu: (.dph_total / .num_gpus)});
def stats:
  if length == 0 then {med: null}
  else {med: (add / length)} end;
def collect:
  reduce inputs as $x ({};
    (input_filename | split("/") | last | sub("[.][0-9]+[.]json$"; "")) as $g
    | (input_filename | capture("[.](?<n>[0-9]+)[.]json$").n) as $n
    | .[$g][$n] = $x);
EOF
)

echo
echo "Average of the cheapest $TOP offers. Averages are renter-facing \$/hr;"
echo "suggested list = renter price x $HOST_SHARE (Vast cut is $(awk -v s=$HOST_SHARE 'BEGIN{printf "%.0f%%", (1-s)*100}'))."
echo "filters: $FILTERS"
echo
printf '%-12s %4s %4s %8s %4s %8s %9s %9s %9s\n' \
  GPU 'VR' '1x' '1x Med' '2x' '2x Med' '1x List' '2x List' '2x Prem'
printf '%-12s %4s %4s %8s %4s %8s %9s %9s %9s\n' \
  '------------' '----' '----' '--------' '----' '--------' \
  '---------' '---------' '---------'

GPU_JSON=$(printf '%s\n' "${GPUS[@]}" | jq -R . | jq -s .)

stars=0
while IFS=$'\t' read -r gpu vram n1 med1 n2 med2pg lst1 lst2pg prem; do
  printf '%-12s %4s %4s %8s %4s %8s %9s %9s %9s\n' \
    "$gpu" "$vram" "$n1" "$med1" "$n2" "$med2pg" "$lst1" "$lst2pg" "$prem"
  case "$med1$med2pg$lst1$lst2pg" in *\**) stars=1 ;; esac
done < <(jq -nr --argjson top "$TOP" --argjson share "$HOST_SHARE" --argjson minn "$MIN_N" \
      --argjson excl "$(excl_json)" --argjson gpus "$GPU_JSON" "$JQ_LIB"'
  collect as $data
  | $gpus[]
  | . as $g
  | (($data[$g]["1"] // []) | keep) as $one
  | (($data[$g]["2"] // []) | keep) as $two
   | ($one[:$top] | map(.dph_total)             | stats) as $a
   | ($two[:$top] | map(.dph_total / .num_gpus) | stats) as $c
   | (if ($one|length) < $minn then "*" else "" end) as $t1
   | (if ($two|length) < $minn then "*" else "" end) as $t2
  | [ $g,
      ($one[:$top] | map(.gpu_ram) | sort | .[length / 2 | floor] | gb),
      ($one|length|tostring),
      ($a.med | f3) + $t1,
      ($two|length|tostring),
       ($c.med | f3) + $t2,
       ($a.med | ms($share) | f3) + $t1,
      ($c.med | ms($share) | f3) + $t2,
      (if $a.med == null or $a.med == 0 or $c.med == null then "n/a"
       else (((($c.med / $a.med) - 1) * 1000 | round) / 10 | tostring) + "%"
       end) ]
  | @tsv
' "$dir"/*.json)
if [ "$stars" = 1 ]; then
  echo
  echo "* fewer than $MIN_N unrented offers, so the median rests on a small"
  echo "  sample and is not a reliable price. Treat as a direction, not a quote."
fi

if [ "$VERBOSE" = 1 ]; then
  for g in "${GPUS[@]}"; do
    echo
    echo "--- $g (cheapest $TOP each, sorted by \$/GPU/hr) ---"
    printf '%-10s %3s %-12s %9s %11s %6s %6s %7s %6s %7s %7s %-10s %s\n' \
      ID N MODEL 'TOTAL/hr' 'PER-GPU/hr' 'PCIE' VCPU 'RAM(GB)' 'DISK(GB)' SCORE RELIAB STATUS LOCATION
    printf '%-10s %3s %-12s %9s %11s %6s %6s %7s %6s %7s %7s %-10s %s\n' \
      '----------' '---' '------------' '---------' '-----------' '------' '------' \
      '-------' '--------' '-------' '-------' '----------' '---------'
    jq -s -r --argjson top "$TOP" --argjson excl "$(excl_json)" "$JQ_LIB"'
      def f1: if . == null then "-" else (((. * 10   | round) / 10)   | tostring) end;
      def f3: if . == null then "-" else (((. * 1000 | round) / 1000) | tostring) end;
      def f0: if . == null then "-" else ((. | round) | tostring) end;
      def lane: if .pcie == null then "-"
                else ((.pcie | f0) + "x" + ((.lanes // null) | f0)) end;
      ((.[0]|norm)[:$top] + (.[1]|norm)[:$top]) | sort_by(.per_gpu) | .[]
      | [ (.id|tostring), ("x" + (.n|tostring)), .model,
          (.total|f3), (.per_gpu|f3),
          (.|lane), (.vcpu|f1), (.ram|f1), (.disk|f0), (.score|f1),
          (.rel|f3), (.status // "-"), .geo ] | @tsv
    ' "$dir/$g.1.json" "$dir/$g.2.json" |
    while IFS=$'\t' read -r id n model total pgpu pcie vcpu ram disk score rel st geo; do
      printf '%-10s %3s %-12s %9s %11s %6s %6s %7s %6s %7s %7s %-10s %s\n' \
        "$id" "$n" "$model" "$total" "$pgpu" "$pcie" "$vcpu" "$ram" "$disk" \
        "$score" "$rel" "$st" "$geo"
    done
  done
fi
echo
