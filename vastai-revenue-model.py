#!/usr/bin/env python3
"""Parameterized net-revenue model for Vast.ai hardware consolidation decisions.

Compares candidate fleet configs on DAILY/ANNUAL NET revenue
(revenue - electricity - fixed per-box overhead).

Market medians are REAL (2026-09-29 market pull, $/GPU/day when rented).
Electricity rate, utilization, and per-box overhead are ASSUMPTIONS.
Edit the DEFAULTS block to match your actual numbers, then re-run.
"""

# ---------------- DEFAULTS (edit these to your real numbers) ----------------
RATE      = 0.15    # $/kWh
UTIL      = 0.60    # fraction of time rented (0.0 - 1.0)
GPU_TDP   = {"4090": 450, "3090": 350}  # W, under load
GPU_IDLE  = 25      # W, GPU draw when not rented
BOX_W     = 60      # W, per-box non-GPU draw (CPU/RAM/NIC/NVMe/fans), always on
BOX_FIXED = 0.50    # $/day/box, amortization + network + misc (non-electricity)

# REAL market medians ($/GPU/day, when rented) - 2026-09-29 pull
MEDIAN = {
    ("4090", 1): 8.28,
    ("4090", 2): 8.16,
    ("3090", 1): 4.08,
    ("3090", 2): 3.60,
}


def net_per_day(gpu, n_gpu, n_box, per_gpu_median, util, rate):
    revenue = n_gpu * per_gpu_median * util
    gpu_kwh = n_gpu * (util * 24 * GPU_TDP[gpu] + (1 - util) * 24 * GPU_IDLE) / 1000.0
    box_kwh = n_box * 24 * BOX_W / 1000.0
    elec = (gpu_kwh + box_kwh) * rate
    fixed = n_box * BOX_FIXED
    return revenue - elec - fixed


def show(configs, util, rate):
    print(f"  {'config':40} {'rev/d':>7} {'elec/d':>8} {'fix/d':>7} {'NET/d':>8} {'NET/yr':>9}")
    for name, gpu, n_gpu, n_box, med in configs:
        net = net_per_day(gpu, n_gpu, n_box, med, util, rate)
        rev = n_gpu * med * util
        gpu_kwh = n_gpu * (util * 24 * GPU_TDP[gpu] + (1 - util) * 24 * GPU_IDLE) / 1000.0
        box_kwh = n_box * 24 * BOX_W / 1000.0
        elec = (gpu_kwh + box_kwh) * rate
        fix = n_box * BOX_FIXED
        print(f"  {name:40} {rev:7.2f} {elec:8.2f} {fix:7.2f} {net:8.2f} {net * 365:9.0f}")


configs = [
    ("4090  2x rig (1 box, 48GB)",            "4090", 2, 1, MEDIAN[("4090", 2)]),
    ("4090  two 1x (2 box)",                  "4090", 2, 2, MEDIAN[("4090", 1)]),
    ("3090  keep 2x (1 box, 48GB+NVLink)",    "3090", 2, 1, MEDIAN[("3090", 2)]),
    ("3090  two 1x (2 box)",                  "3090", 2, 2, MEDIAN[("3090", 1)]),
]

print(f"Assumptions: ${RATE}/kWh, {UTIL * 100:.0f}% util, "
      f"box ${BOX_FIXED}/day + {BOX_W}W, GPU idle {GPU_IDLE}W\n")
print("BASE CASE")
show(configs, UTIL, RATE)

# ---- decision deltas ----
print("\nDECISION DELTAS (net/day, net/yr)")
d4090 = (net_per_day("4090", 2, 1, MEDIAN[("4090", 2)], UTIL, RATE)
         - net_per_day("4090", 2, 2, MEDIAN[("4090", 1)], UTIL, RATE))
print(f"  4090: 2x rig - two 1x = {d4090:+.2f}/day ({d4090 * 365:+.0f}/yr)"
      f"  ->  {'2x rig wins' if d4090 > 0 else 'two 1x win'}")
d3090 = (net_per_day("3090", 2, 1, MEDIAN[("3090", 2)], UTIL, RATE)
         - net_per_day("3090", 2, 2, MEDIAN[("3090", 1)], UTIL, RATE))
print(f"  3090: keep 2x - two 1x = {d3090:+.2f}/day ({d3090 * 365:+.0f}/yr)"
      f"  ->  {'keep 2x wins' if d3090 > 0 else 'two 1x win'}")
if d3090 < 0:
    prem = -d3090 / (2 * UTIL)
    print(f"    48GB premium needed on 2x 3090 to break even: +${prem:.2f}/GPU/day"
          f"  (${MEDIAN[('3090', 2)]:.2f} -> ${MEDIAN[('3090', 2)] + prem:.2f})")

# ---- sensitivity: 4090 delta across util x rate ----
print("\nSENSITIVITY: 4090 (2x rig - two 1x) net/day delta")
rates = (0.10, 0.15, 0.25)
print("  util \\ rate " + "".join(f"{r:>8}" for r in rates))
for u in (0.40, 0.60, 0.80):
    cells = []
    for r in rates:
        d = (net_per_day("4090", 2, 1, MEDIAN[("4090", 2)], u, r)
             - net_per_day("4090", 2, 2, MEDIAN[("4090", 1)], u, r))
        cells.append(f"{d:8.2f}")
    print(f"  {u * 100:5.0f}%    " + "".join(cells))

# ---- sensitivity: 3090 delta across util x rate ----
print("\nSENSITIVITY: 3090 (keep 2x - two 1x) net/day delta")
print("  util \\ rate " + "".join(f"{r:>8}" for r in rates))
for u in (0.40, 0.60, 0.80):
    cells = []
    for r in rates:
        d = (net_per_day("3090", 2, 1, MEDIAN[("3090", 2)], u, r)
             - net_per_day("3090", 2, 2, MEDIAN[("3090", 1)], u, r))
        cells.append(f"{d:8.2f}")
    print(f"  {u * 100:5.0f}%    " + "".join(cells))
