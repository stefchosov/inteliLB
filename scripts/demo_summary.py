#!/usr/bin/env python3
# Usage: python3 scripts/demo_summary.py results/demo
import csv, sys, os, json

ALGORITHMS = [
    "round_robin", "lowest_latency", "least_connections",
    "lowest_cpu", "intelligent", "adaptive",
]

results_dir = sys.argv[1] if len(sys.argv) > 1 else "results/demo"

def p(vals, pct):
    if not vals:
        return 0.0
    return sorted(vals)[max(0, int(len(vals) * pct / 100) - 1)]

col = "{:<22} {:>6} {:>7} {:>9} {:>9} {:>9}"
print(col.format("Algorithm", "n", "err%", "p50 ms", "p95 ms", "p99 ms"))
print("-" * 66)

for algo in ALGORITHMS:
    path = os.path.join(results_dir, f"{algo}.csv")
    if not os.path.exists(path):
        print(f"  {algo:<20}  (no data)")
        continue
    rows = list(csv.DictReader(open(path)))
    n    = len(rows)
    errs = sum(1 for r in rows if r.get("error", "false") == "true")
    lats = sorted(
        float(r.get("duration_ms", r.get("total_ms", 0)))
        for r in rows if r.get("error", "false") == "false"
    )
    print(col.format(
        algo, n, f"{errs/n*100:.1f}%",
        f"{p(lats,50):.1f}", f"{p(lats,95):.1f}", f"{p(lats,99):.1f}",
    ))

print()

# Read backend distribution from per-request CSVs (not stats JSON, which is
# cumulative across the LB process lifetime and will show misleading splits
# if the LB was not restarted between algorithm switches).
dist = "{:<22} {:<14} {:<14} {:<14}"
print(dist.format("Algorithm", "backend-1 %", "backend-2 %", "backend-3 %"))
print("-" * 62)

for algo in ALGORITHMS:
    path = os.path.join(results_dir, f"{algo}.csv")
    if not os.path.exists(path):
        continue
    rows = list(csv.DictReader(open(path)))
    total = len(rows)
    if total == 0:
        continue
    counts = {}
    for r in rows:
        b = r.get("backend_id", "?")
        counts[b] = counts.get(b, 0) + 1
    pcts = []
    for b in ["backend-1", "backend-2", "backend-3"]:
        pcts.append(f"{counts.get(b, 0) / total * 100:.1f}%")
    print(dist.format(algo, *pcts))
