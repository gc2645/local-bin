#!/bin/bash
set -euo pipefail
export VASTAI="${VASTAI:-$HOME/.local/bin/vastai}"
python3 - <<'PY'
# EDIT STREET PRICES HERE: USD for ONE GPU; None means not entered.
STREET_PRICES = {
    'RTX 5090': 4000,
    'RTX 5080': 1400,
    'RTX 5070 Ti': 1100,
    'RTX 5060 Ti': 700,
    'RTX 4090': 2500,
    'RTX 4080S': 1100,
    'RTX 4080': 950,
    'RTX 4070S Ti': 900,
    'RTX 3090': 950,
}
# Calculation assumptions; no automatic fee adjustment.
RENTED_HOURS_PER_DAY = 24
# Owner confirmed API medians are per GPU-hour.

import math
import datetime
import json
import os
import subprocess
import sys

names = ['RTX 5090', 'RTX 5080', 'RTX 5070 Ti', 'RTX 5060 Ti', 'RTX 4090',
         'RTX 4080S', 'RTX 4080', 'RTX 4070S Ti', 'RTX 3090']
for name, price in STREET_PRICES.items():
    if price is not None and (not isinstance(price, (int, float)) or
                              not math.isfinite(price) or price <= 0):
        sys.exit(f'Invalid street price for {name}: use a positive USD amount or None')
if not isinstance(RENTED_HOURS_PER_DAY, (int, float)) or not 0 < RENTED_HOURS_PER_DAY <= 24:
    sys.exit('RENTED_HOURS_PER_DAY must be greater than 0 and at most 24')
data = {}
try:
    for count in (1, 2):
        result = subprocess.run([os.environ['VASTAI'], 'metrics', 'gpu',
                                 '--num-gpus', str(count), '--raw'],
                                capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError(f'{count}x market request failed (exit {result.returncode})')
        payload = json.loads(result.stdout)
        if payload.get('success') is not True:
            raise ValueError(f'{count}x market request was unsuccessful')
        data[count] = {r['gpu_name']: r for r in payload['gpus']}
except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
    sys.exit(f'Unable to load market data: {error}')

def median(row):
    value = row.get('price_median') if row else None
    return value if isinstance(value, (int, float)) and math.isfinite(value) and value > 0 else None

def cells(row, count):
    price = median(row)
    total = f"{row['total_gpus']:,}" if row else '—'
    return [total, f'{price:.3f}' if price is not None else '—',
            f'{price * RENTED_HOURS_PER_DAY:.2f}' if price is not None else '—']

def break_even(one, two, street):
    a, b = median(one), median(two)
    if a is None or b is None or street is None:
        return '—'
    annual = ((a + b) / 2) * RENTED_HOURS_PER_DAY * 365
    return str(math.ceil(street / annual * 365))

widths = [13, 8, 9, 9, 3, 8, 8, 9, 3, 9, 7]
def line(values):
    assert len(values) == len(widths)
    return ' '.join(f'{v:<{w}}' if i == 0 else f'{v:>{w}}'
                    for i, (v, w) in enumerate(zip(values, widths)))

print('\nVast.ai GPU Overview — ' + datetime.datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z'))
print('Current market medians; all verification statuses and hosting types.\n')
print(line(['GPU', '1x Total', '1x Median', '1x $/Day', '',
            '2x Total', '2x Media', '2x $/Day', '', 'Street $', 'Days BE']))
print(line(['' if i in (4, 8) else '-' * width for i, width in enumerate(widths)]))
for name in names:
    street = STREET_PRICES.get(name)
    one, two = data[1].get(name), data[2].get(name)
    print(line([name.replace(' ', '_')] + cells(one, 1) + [''] + cells(two, 2) + ['']
               + [f'${street:,.0f}' if street is not None else '—', break_even(one, two, street)]))
print('\nMedians are per GPU-hour/GPU, Annual GPU = average(1x, 2x).')
print('Excludes fees, electricity and other hardware costs.\n')
PY
