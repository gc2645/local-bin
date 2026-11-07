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

# Format a number as currency with thousands separators.
# Usage: money <decimals> <number>   e.g. money 4 0.123456 -> $0.1235
money() {
  awk -v n="$2" -v d="$1" 'BEGIN {
    s = sprintf("%." d "f", n)
    dot = index(s, ".")
    if (dot > 0) {
      intpart = substr(s, 1, dot - 1)
      frac = substr(s, dot + 1)
    } else {
      intpart = s
      frac = ""
    }
    out = ""
    while (length(intpart) > 3) {
      out = "," substr(intpart, length(intpart) - 2) out
      intpart = substr(intpart, 1, length(intpart) - 3)
    }
    if (frac != "")
      printf "$%s%s.%s", intpart, out, frac
    else
      printf "$%s%s", intpart, out
  }'
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
      (.listed_gpu_cost // 0),
      (.earn_hour // 0),
      (if (.current_rentals_running // 0) > 0 then "Running"
       elif (.current_rentals_resident // 0) > 0 then "Stopped"
       else "Idle" end)
    ]
  | @tsv
' | sort -t$'\t' -k1,1 | {
  printf "Rates per GPU/hour; average revenue includes storage and bandwidth.\n"
  # Print header
  printf "%-10s %-8s %-12s %-4s %-8s %10s %10s %10s %10s\n" \
    "NAME" "MACHINE" "GPU" "QTY" "STATUS" "AVG_REV_HR" "LISTED_HR" "P10_HR" "MED_HR"
  printf "%-10s %-8s %-12s %-4s %-8s %10s %10s %10s %10s\n" \
    "----------" "--------" "------------" "----" "--------" "----------" "----------" "----------" "----------"

  # Print each row
  total_listed_hr=0
  total_earn_hr=0
  total_p10=0
  total_med=0
  while IFS=$'\t' read -r name machine gpu ngpu listed earn_hr status; do
    # Look up P10 and Med prices (per-GPU); scale by num_gpus for fleet totals
    p10="${P10["${gpu}_${ngpu}"]:-0}"
    med="${MED["${gpu}_${ngpu}"]:-0}"
    earn_gpu=$(awk "BEGIN{printf \"%.4f\", $earn_hr / $ngpu}")
    listed_total=$(awk "BEGIN{printf \"%.4f\", $listed * $ngpu}")
    p10_total=$(awk "BEGIN{printf \"%.4f\", $p10 * $ngpu}")
    med_total=$(awk "BEGIN{printf \"%.4f\", $med * $ngpu}")

    # Per-GPU rates for display (average revenue includes storage/bandwidth)
    printf "%-10s %-8s %-12s %-4s %-8s %10s %10s %10s %10s\n" \
      "$name" "$machine" "$gpu" "$ngpu" "$status" \
      "$(money 3 "$earn_gpu")" \
      "$(money 3 "$listed")" \
      "$(money 3 "$p10")" \
      "$(money 3 "$med")"

    # Fleet totals (machine-wide: per-GPU rate x QTY)
    total_listed_hr=$(awk "BEGIN{printf \"%.2f\", $total_listed_hr + $listed_total}")
    total_earn_hr=$(awk "BEGIN{printf \"%.4f\", $total_earn_hr + $earn_hr}")
    total_p10=$(awk "BEGIN{printf \"%.4f\", $total_p10 + $p10_total}")
    total_med=$(awk "BEGIN{printf \"%.4f\", $total_med + $med_total}")
  done

  # Separator line
  printf "%-46s %10s %10s %10s %10s\n" \
    "" "----------" "----------" "----------" "----------"

  # Summary rows: hour/day totals; week/month/year projections
  summary_row() {
    local label="$1" hours="$2" decimals="$3"
    local e l p m
    e=$(awk "BEGIN{printf \"%.4f\", $total_earn_hr * $hours}")
    l=$(awk "BEGIN{printf \"%.4f\", $total_listed_hr * $hours}")
    p=$(awk "BEGIN{printf \"%.4f\", $total_p10 * $hours}")
    m=$(awk "BEGIN{printf \"%.4f\", $total_med * $hours}")
    printf "%-46s %10s %10s %10s %10s\n" \
      "$label" "$(money "$decimals" "$e")" "$(money "$decimals" "$l")" "$(money "$decimals" "$p")" "$(money "$decimals" "$m")"
  }
  summary_row "Total per Hour" 1 2
  summary_row "Total per Day" 24 2
  printf "\n"
  summary_row "Projected per Week" 168 0
  summary_row "Projected per Month" 720 0
  summary_row "Projected per Year" 8760 0
}
