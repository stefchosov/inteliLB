#!/usr/bin/env bash
# run-latency-sweep.sh — Sweeps simulated one-way network latency across
# 5 profiles while holding compute asymmetry fixed, showing how each
# algorithm responds as the high-compute backends get progressively farther away.
#
# Compute layout (local simulation):
#   backend-1  port 8081  GOMAXPROCS=1  "near"   — weakest, closest
#   backend-2  port 8082  GOMAXPROCS=2  varies   — medium compute
#   backend-3  port 8083  GOMAXPROCS=4  varies   — most compute, farthest
#
# Latency profiles (one-way ms added to b1 / b2 / b3):
#   none      0 /   0 /   0   — all equidistant (baseline)
#   light     0 /  25 /  50   — slight geographic spread
#   medium    0 /  75 / 150   — realistic cross-region (e.g. US East↔West↔EU)
#   heavy     0 / 150 / 300   — cross-continent
#   extreme   0 / 300 / 600   — intercontinental (e.g. US↔Asia)
#
# Usage:
#   ./scripts/run-latency-sweep.sh [OPTIONS]
#
# Options:
#   --workers   N     concurrent client workers       (default: 20)
#   --duration  Xs    per-algorithm run duration      (default: 60s)
#   --intensity N     CPU work intensity 1-10         (default: 7)
#   --profiles  LIST  comma-separated subset to run   (default: all 5)
#   --results   DIR   output directory                (default: results/DATE_latency_sweep)
#   -h, --help

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALGORITHMS=(round_robin lowest_latency least_connections lowest_cpu intelligent adaptive)

WORKERS=20
DURATION="60s"
INTENSITY=7
RESULTS_DIR=""
PROFILE_FILTER=""

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
hr()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)   WORKERS="$2";        shift 2 ;;
    --duration)  DURATION="$2";       shift 2 ;;
    --intensity) INTENSITY="$2";      shift 2 ;;
    --profiles)  PROFILE_FILTER="$2"; shift 2 ;;
    --results)   RESULTS_DIR="$2";    shift 2 ;;
    -h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

RESULTS_DIR="${RESULTS_DIR:-$PROJECT_ROOT/results/$(date +%Y%m%d_%H%M%S)_latency_sweep}"
mkdir -p "$RESULTS_DIR"

# ── Latency profiles: name b1_delay b2_delay b3_delay ──────────────────────
declare -a PROFILES=(
  "none    0    0    0"
  "light   0   25   50"
  "medium  0   75  150"
  "heavy   0  150  300"
  "extreme 0  300  600"
)

# Filter to requested subset
if [[ -n "$PROFILE_FILTER" ]]; then
  IFS=',' read -ra WANTED <<< "$PROFILE_FILTER"
  FILTERED=()
  for entry in "${PROFILES[@]}"; do
    name=$(awk '{print $1}' <<< "$entry")
    for w in "${WANTED[@]}"; do
      [[ "$name" == "$w" ]] && FILTERED+=("$entry") && break
    done
  done
  PROFILES=("${FILTERED[@]}")
fi

[[ ${#PROFILES[@]} -gt 0 ]] || die "No profiles selected"

# ── State ──────────────────────────────────────────────────────────────────
B1_PID="" B2_PID="" B3_PID="" LB_PID=""

stop_all() {
  for pid in "$B1_PID" "$B2_PID" "$B3_PID" "$LB_PID"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  B1_PID="" B2_PID="" B3_PID="" LB_PID=""
}
trap 'stop_all' EXIT INT TERM

# ── Prerequisites ──────────────────────────────────────────────────────────
hr
log "inteliLB latency sweep — workers=$WORKERS duration=$DURATION intensity=$INTENSITY"
log "Profiles: $(for p in "${PROFILES[@]}"; do awk '{printf "%s(%s/%s/%s) ",$1,$2,$3,$4}' <<< "$p"; done)"
log "Results → $RESULTS_DIR"
hr

command -v go     >/dev/null || die "'go' not found"
command -v curl   >/dev/null || die "'curl' not found"
command -v python3 >/dev/null || die "'python3' not found"

log "Building binaries..."
cd "$PROJECT_ROOT"
go mod tidy
mkdir -p "$PROJECT_ROOT/bin"
go build -o "$PROJECT_ROOT/bin/loadbalancer" ./cmd/loadbalancer
go build -o "$PROJECT_ROOT/bin/backend"      ./cmd/backend
go build -o "$PROJECT_ROOT/bin/client"       ./cmd/client
log "Build complete"

# ── Helpers ────────────────────────────────────────────────────────────────
wait_healthy() {
  local url="$1" label="$2"
  for ((i=1; i<=20; i++)); do
    curl -sf --max-time 2 "$url/health" >/dev/null 2>&1 && { log "  $label ready"; return 0; }
    sleep 1
  done
  die "$label did not become healthy"
}

switch_algorithm() {
  curl -sf -X POST http://localhost:8080/lb/algorithm \
    -H "Content-Type: application/json" \
    -d "{\"algorithm\":\"$1\"}" >/dev/null \
    || die "Failed to switch algorithm to $1"
}

# ── Utilization poller (same as run-experiment.sh) ─────────────────────────
POLLER_PID=""

start_poller() {
  local outfile="$1"
  echo "elapsed_s,backend_id,cpu_percent,avg_latency_ms,active_connections,total_requests" > "$outfile"
  local t0; t0=$(date +%s)
  while true; do
    local snap elapsed
    elapsed=$(( $(date +%s) - t0 ))
    snap=$(curl -sf --max-time 2 http://localhost:8080/lb/stats 2>/dev/null) || { sleep 5; continue; }
    python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
for b in d.get('backends',[]):
    print(f\"{sys.argv[1]},{b['id']},{b['cpu_percent']:.2f},{b['avg_latency_ms']:.1f},{b['active_connections']},{b.get('total_requests',0)}\")
" "$elapsed" <<< "$snap" >> "$outfile" 2>/dev/null || true
    sleep 5
  done
}

stop_poller() {
  [[ -n "$POLLER_PID" ]] && kill "$POLLER_PID" 2>/dev/null && wait "$POLLER_PID" 2>/dev/null || true
  POLLER_PID=""
}

# ── Per-profile run ────────────────────────────────────────────────────────
run_profile() {
  local name="$1" delay_b1="$2" delay_b2="$3" delay_b3="$4"
  local profile_dir="$RESULTS_DIR/$name"
  mkdir -p "$profile_dir"

  hr
  log "PROFILE: $name  (b1=+${delay_b1}ms  b2=+${delay_b2}ms  b3=+${delay_b3}ms)"
  hr

  # Write profile config
  cat > "$profile_dir/config.txt" <<EOF
profile:    $name
date:       $(date)
workers:    $WORKERS
duration:   $DURATION
intensity:  $INTENSITY
b1_delay:   ${delay_b1}ms  (GOMAXPROCS=1)
b2_delay:   ${delay_b2}ms  (GOMAXPROCS=2)
b3_delay:   ${delay_b3}ms  (GOMAXPROCS=4)
algorithms: ${ALGORITHMS[*]}
EOF

  # Start backends
  log "Starting backends..."
  MAX_PROCS=1 SIMULATED_LATENCY_MS="$delay_b1" REGION=local-near   ID=backend-1 \
    "$PROJECT_ROOT/bin/backend" -port=8081 \
    >> "$profile_dir/backend-1.log" 2>&1 &
  B1_PID=$!

  MAX_PROCS=2 SIMULATED_LATENCY_MS="$delay_b2" REGION=local-medium ID=backend-2 \
    "$PROJECT_ROOT/bin/backend" -port=8082 \
    >> "$profile_dir/backend-2.log" 2>&1 &
  B2_PID=$!

  MAX_PROCS=4 SIMULATED_LATENCY_MS="$delay_b3" REGION=local-far    ID=backend-3 \
    "$PROJECT_ROOT/bin/backend" -port=8083 \
    >> "$profile_dir/backend-3.log" 2>&1 &
  B3_PID=$!

  sleep 1
  wait_healthy http://localhost:8081 "backend-1 (+${delay_b1}ms, 1 proc)"
  wait_healthy http://localhost:8082 "backend-2 (+${delay_b2}ms, 2 procs)"
  wait_healthy http://localhost:8083 "backend-3 (+${delay_b3}ms, 4 procs)"

  # Start LB
  "$PROJECT_ROOT/bin/loadbalancer" \
    -port=8080 -algorithm=round_robin \
    -backends="http://localhost:8081,http://localhost:8082,http://localhost:8083" \
    >> "$profile_dir/loadbalancer.log" 2>&1 &
  LB_PID=$!
  sleep 2
  wait_healthy http://localhost:8080 "load-balancer"

  # Algorithm loop
  local total=${#ALGORITHMS[@]} current=0
  for algo in "${ALGORITHMS[@]}"; do
    current=$((current + 1))
    log "  [$current/$total] $algo"

    switch_algorithm "$algo"
    sleep 3

    start_poller "$profile_dir/${algo}_utilization.csv" &
    POLLER_PID=$!

    "$PROJECT_ROOT/bin/client" \
      -url=http://localhost:8080 \
      -workers="$WORKERS" \
      -duration="$DURATION" \
      -intensity="$INTENSITY" \
      -output="$profile_dir/${algo}.csv"

    stop_poller

    curl -sf http://localhost:8080/lb/stats \
      > "$profile_dir/${algo}_stats.json" 2>/dev/null \
      || log "  WARNING: could not fetch stats for $algo"

    if [[ "$current" -lt "$total" ]]; then
      sleep 15  # shorter cooldown for sweep
    fi
  done

  stop_all
  log "Profile '$name' complete — results in $profile_dir"
  sleep 3  # let ports free up before next profile
}

# ── Run all profiles ────────────────────────────────────────────────────────
for entry in "${PROFILES[@]}"; do
  read -r name d1 d2 d3 <<< "$entry"
  run_profile "$name" "$d1" "$d2" "$d3"
done

# ── Cross-profile summary ──────────────────────────────────────────────────
hr
log "Computing cross-profile summary..."
hr

python3 - "$RESULTS_DIR" "${ALGORITHMS[@]}" << 'PYEOF'
import csv, sys, os, json, statistics

results_dir = sys.argv[1]
algorithms  = sys.argv[2:]
_order = ["none", "light", "medium", "heavy", "extreme"]
profiles = [d for d in _order
            if os.path.isdir(os.path.join(results_dir, d))]
# fall back to alphabetical for any unrecognised profile names
profiles += sorted(
    d for d in os.listdir(results_dir)
    if os.path.isdir(os.path.join(results_dir, d))
    and not d.startswith('.') and d not in _order
)

def load(path, col):
    out = []
    try:
        for r in csv.DictReader(open(path)):
            if r.get('error','false') != 'true':
                try: out.append(float(r[col]))
                except: pass
    except: pass
    return out

def p(vals, pct):
    if not vals: return 0
    s = sorted(vals)
    return s[max(0, int(len(s)*pct/100)-1)]

def rps(path):
    ts = []
    try:
        for r in csv.DictReader(open(path)):
            try: ts.append(int(r['timestamp_ms']))
            except: pass
    except: pass
    if len(ts) < 2: return 0
    return len(ts) / ((max(ts)-min(ts))/1000)

# ── Throughput table ───────────────────────────────────────────────────────
print("\n=== req/s by algorithm and latency profile ===")
hdr = f"{'Algorithm':<22}" + "".join(f"  {p:>9}" for p in profiles)
print(hdr)
print("-" * len(hdr))
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        val = rps(f"{results_dir}/{prof}/{algo}.csv")
        row += f"  {val:>8.1f} " if val else f"  {'n/a':>9}"
    print(row)

# ── p99 RTT table ──────────────────────────────────────────────────────────
print("\n=== p99 total RTT (ms) by algorithm and latency profile ===")
print(hdr)
print("-" * len(hdr))
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        vals = load(f"{results_dir}/{prof}/{algo}.csv", 'total_ms')
        val  = p(vals, 99)
        row += f"  {val:>8.0f} " if vals else f"  {'n/a':>9}"
    print(row)

# ── p50 network_ms table ───────────────────────────────────────────────────
print("\n=== p50 network RTT (ms) by algorithm and latency profile ===")
print(hdr)
print("-" * len(hdr))
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        vals = load(f"{results_dir}/{prof}/{algo}.csv", 'network_ms')
        val  = p(vals, 50)
        row += f"  {val:>8.0f} " if vals else f"  {'n/a':>9}"
    print(row)

# ── Backend distribution shift ─────────────────────────────────────────────
# Show how each algorithm's b1 share changes with increasing latency
print("\n=== backend-1 share % as latency increases (true per-algo, delta from prev snapshot) ===")
print(f"{'Algorithm':<22}" + "".join(f"  {p:>9}" for p in profiles))
print("-" * len(hdr))

for algo in algorithms:
    row = f"  {algo:<22}"
    prev = {"backend-1":0,"backend-2":0,"backend-3":0}
    for prof in profiles:
        spath = f"{results_dir}/{prof}/{algo}_stats.json"
        try:
            data = json.load(open(spath))
            # Each profile has its own fresh LB instance, so no cumulative issue
            backends = data.get("backends",[])
            total = sum(b["total_requests"] for b in backends)
            b1 = next((b["total_requests"] for b in backends if b["id"]=="backend-1"),0)
            share = b1/total*100 if total > 0 else 0
            row += f"  {share:>8.1f}%"
        except:
            row += f"  {'n/a':>9}"
    print(row)

# ── Per-backend p50 total_ms (from backend_id column in CSVs) ─────────────
print("\n=== p50 total RTT per backend per profile (least_connections only, shows routing quality) ===")
for algo in ["least_connections", "round_robin", "lowest_latency"]:
    print(f"\n  {algo}:")
    print(f"  {'Profile':<10}  {'b1 p50':>8}  {'b2 p50':>8}  {'b3 p50':>8}  {'b1 n':>6}  {'b2 n':>6}  {'b3 n':>6}")
    print(f"  {'-'*62}")
    for prof in profiles:
        path = f"{results_dir}/{prof}/{algo}.csv"
        by_backend = {"backend-1":[], "backend-2":[], "backend-3":[]}
        try:
            for r in csv.DictReader(open(path)):
                bid = r.get("backend_id","")
                if bid in by_backend and r.get("error","false") != "true":
                    try: by_backend[bid].append(float(r["total_ms"]))
                    except: pass
        except: pass
        cols = ""
        ns   = ""
        for bid in ["backend-1","backend-2","backend-3"]:
            v = by_backend[bid]
            cols += f"  {p(v,50):>7.0f}ms" if v else f"  {'n/a':>8}"
            ns   += f"  {len(v):>6}"
        print(f"  {prof:<10}{cols}{ns}")

# ── Traffic shift over time (utilization CSV, b1 total_requests at 0s/30s/60s) ─
print("\n=== backend-1 request share over time (from utilization CSV, 60s window) ===")
print("  Shows whether algorithms shift routing mid-run as latency signal builds up")
for algo in algorithms:
    row_parts = []
    for prof in profiles:
        upath = f"{results_dir}/{prof}/{algo}_utilization.csv"
        snapshots = {}  # elapsed_s -> {bid: total_reqs}
        try:
            for r in csv.DictReader(open(upath)):
                t = int(float(r["elapsed_s"]))
                bid = r["backend_id"]
                tr = int(float(r.get("total_requests", 0)))
                if t not in snapshots: snapshots[t] = {}
                snapshots[t][bid] = tr
        except: pass
        if not snapshots:
            row_parts.append("n/a")
            continue
        times = sorted(snapshots.keys())
        def b1_share_at(target):
            closest = min(times, key=lambda t: abs(t - target))
            snap = snapshots[closest]
            total = sum(snap.values())
            b1 = snap.get("backend-1", 0)
            return f"{b1/total*100:.0f}%" if total > 0 else "n/a"
        early = b1_share_at(10)
        mid   = b1_share_at(30)
        late  = b1_share_at(55)
        row_parts.append(f"{early}→{mid}→{late}")
    print(f"  {algo:<22}  " + "  ".join(f"{prof:>7}:{v:<14}" for prof, v in zip(profiles, row_parts)))

print(f"\nFull results: {results_dir}/")
PYEOF

hr
log "Sweep complete."
