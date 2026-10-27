#!/usr/bin/env bash
# get-vastai-metrics.sh — availability/pricing snapshot for the cards we rent out
set -euo pipefail

CARDS='["RTX 4090","RTX 5080","RTX 5070 Ti","RTX 3090","RTX 3060"]'

show_metrics() {
  local label="$1" bucket="$2"

  echo "$label"
  vastai metrics gpu --num-gpus "$bucket" --raw \
    | jq -r --argjson cards "$CARDS" '
        .gpus[]
        | select(.gpu_name as $n | $cards | index($n))
        | [ .gpu_name, .total, .available, .usage, .price_p10, .price_median, .price_p90 ]
        | @tsv' \
    | awk -F'\t' '
        BEGIN {
          printf "%-14s %6s %6s %7s %9s %9s %9s\n", \
            "GPU", "Total", "Avail", "Usage%", "P10 $/hr", "Med $/hr", "P90 $/hr"
        }
        {
          gsub(/ /, "_", $1)
          printf "%-14s %6s %6s %7s %9.4f %9.4f %9.4f\n", $1, $2, $3, $4, $5, $6, $7
        }'
}

show_metrics "GPU = 1" 1
echo "────────────────────────────────────────────────────────────"
show_metrics "GPU = 2" 2
