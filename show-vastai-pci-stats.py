#!/usr/bin/env python3
"""Vast.ai PCIe configuration distribution stats.

Pulls rentable on-demand offers (verified-or-not, reliability > 0.8) for a set
of GPU models, grouped by GPU count (1x/2x/4x/8x), and reports the PCIe
gen x lane distribution for each. Prints one table per GPU count plus a
combined TOTAL table at the bottom.

Stdlib only. Uses the public /bundles/ endpoint, so no API key is required.
Note: the API caps results at 64 per query; rows flagged with * are truncated,
so their totals are lower bounds.
"""
import json
import urllib.request

API = "https://console.vast.ai/api/v0/bundles/"
GPUS = ["RTX 5080", "RTX 5070 Ti", "RTX 5060 Ti", "RTX 4090", "RTX 3090"]
COLS = [("5.0", 16), ("5.0", 8), ("5.0", 4),
        ("4.0", 16), ("4.0", 8), ("4.0", 4),
        ("3.0", 16), ("3.0", 8), ("3.0", 4)]
COUNTS = [1, 2, 4, 8]
CAP = 64
RELIABILITY_MIN = 0.8


def fetch(gpu, n):
    q = {"gpu_name": {"eq": gpu}, "num_gpus": {"eq": n},
         "reliability": {"gt": RELIABILITY_MIN}, "rentable": {"eq": True},
         "order": [["score", "desc"]], "type": "on-demand", "allocated_storage": 5.0}
    req = urllib.request.Request(API, data=json.dumps(q).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)["offers"]


def gstr(v):
    return None if v is None else ("%.1f" % float(v))


def key_of(o):
    return (gstr(o.get("pci_gen")), o.get("gpu_lanes"))


def print_table(title, header, rows):
    print("\n===== %s =====" % title)
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    fmt = lambda r: "  ".join(str(r[i]).rjust(widths[i]) for i in range(len(header)))
    print(fmt(header))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(fmt(r))


def main():
    header = ["GPU", "offers"] + ["%sx%d" % (g, l) for g, l in COLS]
    combined = {g: {c: 0 for c in COLS} for g in GPUS}
    combined_total = {g: 0 for g in GPUS}
    combined_capped = {g: False for g in GPUS}

    for n in COUNTS:
        rows = []
        for g in GPUS:
            off = fetch(g, n)
            cnt = {c: 0 for c in COLS}
            other = {}
            for o in off:
                k = key_of(o)
                if k in cnt:
                    cnt[k] += 1
                else:
                    label = "%sx%s" % (k[0], k[1])
                    other[label] = other.get(label, 0) + 1
            for c in COLS:
                combined[g][c] += cnt[c]
            combined_total[g] += len(off)
            if len(off) >= CAP:
                combined_capped[g] = True
            flag = "*" if len(off) >= CAP else ""
            rows.append([g, "%d%s" % (len(off), flag)] + [cnt[c] for c in COLS])
            if other:
                print("    note %s: outside columns %s" % (g, other))
        print_table("%dx GPU offers  (verified-or-not, reliability>%d%%)" % (n, int(RELIABILITY_MIN * 100)),
                    header, rows)

    rows = []
    for g in GPUS:
        flag = "*" if combined_capped[g] else ""
        rows.append([g, "%d%s" % (combined_total[g], flag)] + [combined[g][c] for c in COLS])
    print_table("TOTAL (1x+2x+4x+8x, combined)", header, rows)
    print("\n(* = a component hit the %d-offer cap, so that total is a lower bound)" % CAP)


if __name__ == "__main__":
    main()
