#!/usr/bin/env bash
# show-gpu-dashboard.sh — Format "vastai --raw show machines" as a readable table
set -euo pipefail

# Ensure jq is available
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed." >&2; exit 1; }

# Fetch metrics for 1-gpu and 2-gpu cards once
declare -A P10 MED
for ngpu in 1 2; do
  while IFS=$'\t' read -r gpu p10 med; do
    P10["${gpu}_${ngpu}"]="$p10"
    MED["${gpu}_${ngpu}"]="$med"
  done < <(
    vastai metrics gpu --num-gpus "$ngpu" --raw \
      | jq -r '.gpus[] | [.gpu_name, .price_p10, .price_median] | @tsv' \
      | awk -F'\t' '{ gsub(/ /, "_", $1); printf "%s\t%.4f\t%.4f\n", $1, $2, $3 }'
  )
done

# Format a dollar value
dollar() {
  printf '$%.2f' "$1"
}

# Fetch machines, enrich with metrics, and print table
vastai --raw show machines | jq -r '
  if type == "array" then .
  elif .machines != null then .machines
  elif .data != null then .data
  else .
  end
  | .[]
  | [
      (.hostname // "N/A"),
      (.machine_id // "N/A"),
      ((.gpu_name // "N/A") | gsub(" "; "_")),
      (.num_gpus // 1),
      ((.listed_gpu_cost // 0) * (.num_gpus // 1)),
      (.earn_hour // 0),
      (.earn_day // 0)
    ]
  | @tsv
' | sort -t$'\t' -k1,1 | {
  # Print header
  printf "%-10s %-8s %-16s %-12s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
    "NAME" "MACHINE" "GPU" "LISTED_HR" "LISTED_DAY" "EARN_HR" "EARN_DAY" "P10_HR" "MED_HR" "MED_DAY"
  printf "%-10s %-8s %-16s %-12s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
    "----" "-------" "---" "---------" "----------" "-------" "--------" "--------" "--------" "--------"

  # Print each row
  total_listed_hr=0
  total_listed_day=0
  total_earn_hr=0
  total_earn_day=0
  total_p10=0
  total_med=0
  total_med_day=0
  while IFS=$'\t' read -r name machine gpu ngpu listed earn_hr earn_day; do
    # Look up P10 and Med prices, multiply by num_gpus
    p10="${P10["${gpu}_${ngpu}"]:-0}"
    med="${MED["${gpu}_${ngpu}"]:-0}"
    p10_total=$(awk "BEGIN{printf \"%.4f\", $p10 * $ngpu}")
    med_total=$(awk "BEGIN{printf \"%.4f\", $med * $ngpu}")

    printf "%-10s %-8s %-16s %-12s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
      "$name" "$machine" "$gpu" \
      "$(dollar "$listed")" "$(dollar $(awk "BEGIN{printf \"%.2f\", $listed * 24}"))" \
      "$(dollar "$earn_hr")" "$(dollar "$earn_day")" \
      "$p10_total" "$med_total" \
      "$(dollar $(awk "BEGIN{printf \"%.2f\", $med_total * 24}"))"

    total_listed_hr=$(awk "BEGIN{printf \"%.2f\", $total_listed_hr + $listed}")
    total_listed_day=$(awk "BEGIN{printf \"%.2f\", $total_listed_day + $listed * 24}")
    total_earn_hr=$(awk "BEGIN{printf \"%.3f\", $total_earn_hr + $earn_hr}")
    total_earn_day=$(awk "BEGIN{printf \"%.2f\", $total_earn_day + $earn_day}")
    total_p10=$(awk "BEGIN{printf \"%.4f\", $total_p10 + $p10_total}")
    total_med=$(awk "BEGIN{printf \"%.4f\", $total_med + $med_total}")
    total_med_day=$(awk "BEGIN{printf \"%.2f\", $total_med_day + $med_total * 24}")
  done

  # Separator line
  printf "%-10s %-8s %-16s %-12s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
    "" "" "" "------------" "------------" "------------" "------------" "------------" "------------" "------------"

  # Totals row
  printf "%-10s %-8s %-16s %-12s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
    "" "" "" \
    "$(dollar "$total_listed_hr")" "$(dollar "$total_listed_day")" \
    "$(dollar "$total_earn_hr")" "$(dollar "$total_earn_day")" \
    "$total_p10" "$total_med" \
    "$(dollar "$total_med_day")"
}
