#!/usr/bin/env bash
# run-workload-sweep.sh — Full workload matrix sweep for inteliLB.
#
# Starts 3 local backends with GOMAXPROCS 1/2/4 to simulate compute asymmetry,
# then runs 5 workload profiles × 6 algorithms, followed by an open-loop
# saturation ramp for 4 key algorithms.  Everything runs on the local machine.
#
# Usage:
#   ./scripts/run-workload-sweep.sh [OPTIONS]
#
# Options:
#   --duration  Xs    per-algorithm run duration      (default: 90s)
#   --results   DIR   override results directory
#   -h, --help

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
DURATION="90s"
RESULTS_DIR=""

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALGORITHMS=(round_robin lowest_latency least_connections lowest_cpu intelligent adaptive)

# ── Logging ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo ""; echo "ERROR: $*" >&2; exit 1; }
hr()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# ── File descriptor limit ─────────────────────────────────────────────────────
ulimit -n 65535 2>/dev/null || ulimit -n 4096 2>/dev/null || true

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration) DURATION="$2";    shift 2 ;;
    --results)  RESULTS_DIR="$2"; shift 2 ;;
    -h|--help)  sed -n '3,17p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

RESULTS_DIR="${RESULTS_DIR:-$PROJECT_ROOT/results/$(date +%Y%m%d_%H%M%S)_workload_sweep}"
mkdir -p "$RESULTS_DIR"

# ── Process tracking ──────────────────────────────────────────────────────────
LB_PID=""
BACKEND_PIDS=()
POLLER_PID=""

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
  echo ""
  hr
  log "Shutting down..."

  if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
    kill "$LB_PID" 2>/dev/null || true
    log "Load balancer stopped (PID $LB_PID)"
  fi
  LB_PID=""

  if [[ -n "${POLLER_PID:-}" ]] && kill -0 "$POLLER_PID" 2>/dev/null; then
    kill "$POLLER_PID" 2>/dev/null || true
  fi
  POLLER_PID=""

  if [[ ${#BACKEND_PIDS[@]} -gt 0 ]]; then
    for pid in "${BACKEND_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    log "Local backends stopped"
  fi

  hr
}

trap cleanup EXIT
trap 'log "Interrupted"; exit 130' INT TERM

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_healthy() {
  local url="$1" label="$2"
  local retries=40
  log "Waiting for $label..."
  for ((i=1; i<=retries; i++)); do
    if curl -sf --max-time 3 "$url/health" >/dev/null 2>&1; then
      log "  $label is healthy"
      return 0
    fi
    sleep 3
  done
  die "$label did not become healthy after $((retries * 3))s — check logs in $RESULTS_DIR"
}

switch_algorithm() {
  curl -sf -X POST http://localhost:8080/lb/algorithm \
    -H "Content-Type: application/json" \
    -d "{\"algorithm\":\"$1\"}" >/dev/null \
    || die "Failed to switch algorithm to $1"
}

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
  if [[ -n "$POLLER_PID" ]] && kill -0 "$POLLER_PID" 2>/dev/null; then
    kill "$POLLER_PID" 2>/dev/null || true
    wait "$POLLER_PID" 2>/dev/null || true
  fi
  POLLER_PID=""
}

# ── Prerequisites ─────────────────────────────────────────────────────────────
hr
log "inteliLB workload sweep — duration=$DURATION"
log "Results → $RESULTS_DIR"
hr

command -v go      >/dev/null || die "'go' not found in PATH"
command -v curl    >/dev/null || die "'curl' not found in PATH"
command -v python3 >/dev/null || die "'python3' not found — needed for summary"

# ── Build ─────────────────────────────────────────────────────────────────────
hr
log "Building binaries..."
cd "$PROJECT_ROOT"
go mod tidy
mkdir -p "$PROJECT_ROOT/bin"
go build -o "$PROJECT_ROOT/bin/loadbalancer" ./cmd/loadbalancer
go build -o "$PROJECT_ROOT/bin/backend"      ./cmd/backend
go build -o "$PROJECT_ROOT/bin/client"       ./cmd/client
log "Build complete"

# ── Start backends ─────────────────────────────────────────────────────────────
hr
log "Starting local backends (GOMAXPROCS 1/2/4)..."

MAX_PROCS=1 REGION=us-west   ID=backend-1 \
  "$PROJECT_ROOT/bin/backend" -port=8081 \
  >> "$RESULTS_DIR/backend-1.log" 2>&1 &
BACKEND_PIDS+=($!)

MAX_PROCS=2 REGION=us-central ID=backend-2 \
  "$PROJECT_ROOT/bin/backend" -port=8082 \
  >> "$RESULTS_DIR/backend-2.log" 2>&1 &
BACKEND_PIDS+=($!)

MAX_PROCS=4 REGION=us-east   ID=backend-3 \
  "$PROJECT_ROOT/bin/backend" -port=8083 \
  >> "$RESULTS_DIR/backend-3.log" 2>&1 &
BACKEND_PIDS+=($!)

wait_healthy http://localhost:8081 "backend-1 (GOMAXPROCS=1, us-west)"
wait_healthy http://localhost:8082 "backend-2 (GOMAXPROCS=2, us-central)"
wait_healthy http://localhost:8083 "backend-3 (GOMAXPROCS=4, us-east)"

BACKEND_URLS="http://localhost:8081,http://localhost:8082,http://localhost:8083"
log "Backends ready: $BACKEND_URLS"

# ── Workload profiles: "name workers intensity mix" ───────────────────────────
PROFILES=(
  "cpu_only    20   7  cpu:100"
  "high_conn   200  2  cpu:100"
  "io_bound    100  5  io:100"
  "bimodal     50   7  cpu_light:80,cpu_heavy:20"
  "realistic   100  5  cpu:40,io:40,mixed:20"
)

# ── Per-profile run function ───────────────────────────────────────────────────
run_profile() {
  local name="$1" workers="$2" intensity="$3" mix="$4"
  local profile_dir="$RESULTS_DIR/$name"
  mkdir -p "$profile_dir"

  hr
  log "PROFILE: $name  (workers=$workers intensity=$intensity mix=$mix)"
  hr

  # Write profile config
  cat > "$profile_dir/config.txt" <<EOF
name:       $name
workers:    $workers
intensity:  $intensity
mix:        $mix
algorithms: ${ALGORITHMS[*]}
date:       $(date)
EOF

  # Start LB
  log "Starting load balancer on :8080..."
  "$PROJECT_ROOT/bin/loadbalancer" \
    -port=8080 \
    -algorithm=round_robin \
    -backends="$BACKEND_URLS" \
    >> "$profile_dir/loadbalancer.log" 2>&1 &
  LB_PID=$!

  wait_healthy http://localhost:8080 "load-balancer"

  # Algorithm loop
  local total=${#ALGORITHMS[@]} current=0
  for algo in "${ALGORITHMS[@]}"; do
    current=$((current + 1))
    log "  [$current/$total] $algo"

    switch_algorithm "$algo"
    sleep 5  # let LB metrics settle after switch

    start_poller "$profile_dir/${algo}_utilization.csv" &
    POLLER_PID=$!

    log "    Running client (workers=$workers intensity=$intensity mix=$mix)..."
    "$PROJECT_ROOT/bin/client" \
      -url=http://localhost:8080 \
      -workers="$workers" \
      -duration="$DURATION" \
      -intensity="$intensity" \
      -mix="$mix" \
      -output="$profile_dir/${algo}.csv"

    stop_poller

    log "    Saving stats snapshot..."
    curl -sf http://localhost:8080/lb/stats \
      > "$profile_dir/${algo}_stats.json" 2>/dev/null \
      || log "    WARNING: could not fetch stats for $algo"

    if [[ "$current" -lt "$total" ]]; then
      log "    Cooling down 15s before next algorithm..."
      sleep 15
    fi
  done

  # Kill LB, let ports free up
  if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
    kill "$LB_PID" 2>/dev/null || true
    wait "$LB_PID" 2>/dev/null || true
    log "Load balancer stopped"
  fi
  LB_PID=""
  sleep 3

  log "Profile '$name' complete — results in $profile_dir"
}

# ── Run all profiles ──────────────────────────────────────────────────────────
hr
log "Running ${#PROFILES[@]} workload profiles × ${#ALGORITHMS[@]} algorithms"
hr

for entry in "${PROFILES[@]}"; do
  read -r p_name p_workers p_intensity p_mix <<< "$entry"
  run_profile "$p_name" "$p_workers" "$p_intensity" "$p_mix"
done

# ── Saturation ramp ───────────────────────────────────────────────────────────
hr
log "Starting open-loop saturation ramp..."
hr

SAT_ALGORITHMS=(round_robin least_connections lowest_latency intelligent)
SAT_RATES=(100 250 500 1000 2000 3000 5000)
SAT_DIR="$RESULTS_DIR/saturation"
mkdir -p "$SAT_DIR"

for algo in "${SAT_ALGORITHMS[@]}"; do
  hr
  log "Saturation ramp: $algo"

  # Fresh LB instance for each algorithm
  "$PROJECT_ROOT/bin/loadbalancer" \
    -port=8080 \
    -algorithm="$algo" \
    -backends="$BACKEND_URLS" \
    >> "$SAT_DIR/${algo}_lb.log" 2>&1 &
  LB_PID=$!

  wait_healthy http://localhost:8080 "load-balancer ($algo)"

  local_rate_idx=0
  for rate in "${SAT_RATES[@]}"; do
    local_rate_idx=$((local_rate_idx + 1))
    log "  rate=$rate req/s [${local_rate_idx}/${#SAT_RATES[@]}]"

    "$PROJECT_ROOT/bin/client" \
      -url=http://localhost:8080 \
      -mode=open \
      -rate="$rate" \
      -duration=60s \
      -intensity=2 \
      -output="$SAT_DIR/${algo}_rate${rate}.csv"

    curl -sf http://localhost:8080/lb/stats \
      > "$SAT_DIR/${algo}_rate${rate}_stats.json" 2>/dev/null \
      || log "  WARNING: could not fetch stats for $algo at rate=$rate"

    sleep 10
  done

  # Kill LB between algorithms
  if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
    kill "$LB_PID" 2>/dev/null || true
    wait "$LB_PID" 2>/dev/null || true
  fi
  LB_PID=""
  sleep 3
done

# ── Summary ───────────────────────────────────────────────────────────────────
hr
log "Computing summary..."
hr

python3 - "$RESULTS_DIR" "${ALGORITHMS[@]}" << 'PYEOF'
import csv, sys, os, json

results_dir = sys.argv[1]
algorithms  = sys.argv[2:]

sat_algorithms = ["round_robin", "least_connections", "lowest_latency", "intelligent"]
sat_rates      = [100, 250, 500, 1000, 2000, 3000, 5000]

profile_order = ["cpu_only", "high_conn", "io_bound", "bimodal", "realistic"]
profiles = [p for p in profile_order
            if os.path.isdir(os.path.join(results_dir, p))]

def pct(vals, p):
    if not vals:
        return 0.0
    s = sorted(vals)
    return s[max(0, int(len(s) * p / 100) - 1)]

def load_col(path, col):
    out = []
    try:
        for r in csv.DictReader(open(path)):
            if r.get('error', 'false') == 'true':
                continue
            try:
                v = float(r[col])
                if v >= 0:
                    out.append(v)
            except (KeyError, ValueError):
                pass
    except Exception:
        pass
    return out

def load_rows(path):
    try:
        return list(csv.DictReader(open(path)))
    except Exception:
        return []

def rps(rows):
    ts = []
    for r in rows:
        try:
            ts.append(int(r['timestamp_ms']))
        except (KeyError, ValueError):
            pass
    if len(ts) < 2:
        return 0.0
    return len(ts) / ((max(ts) - min(ts)) / 1000.0)

def err_pct(rows):
    if not rows:
        return 0.0
    errs = sum(1 for r in rows if r.get('error', 'false') == 'true')
    return errs / len(rows) * 100

output_lines = []

def emit(line=""):
    print(line)
    output_lines.append(line)

# ══════════════════════════════════════════════════════════════════════════════
# Section 1: Workload profile summary
# ══════════════════════════════════════════════════════════════════════════════
emit("=" * 80)
emit("SECTION 1: Workload profile summary")
emit("=" * 80)

col_hdr = "{:<22} {:>8} {:>8} {:>8} {:>8} {:>10}"
col_row = "{:<22} {:>8.1f} {:>8.1f} {:>8.1f} {:>7.1f}% {:>9.1f}%"

for prof in profiles:
    prof_dir = os.path.join(results_dir, prof)
    emit(f"\nProfile: {prof}")
    emit(col_hdr.format("Algorithm", "req/s", "p50ms", "p99ms", "err%", "b1 share%"))
    emit("-" * 70)
    for algo in algorithms:
        path = os.path.join(prof_dir, f"{algo}.csv")
        rows = load_rows(path)
        if not rows:
            emit(f"  {algo:<20}  (no data)")
            continue
        r     = rps(rows)
        total = load_col(path, 'total_ms')
        ep    = err_pct(rows)

        # backend-1 share from stats JSON
        b1_share = 0.0
        spath = os.path.join(prof_dir, f"{algo}_stats.json")
        try:
            data = json.load(open(spath))
            backs = data.get("backends", [])
            tot   = sum(b.get("total_requests", 0) for b in backs)
            b1    = next((b.get("total_requests", 0) for b in backs if b["id"] == "backend-1"), 0)
            b1_share = b1 / tot * 100 if tot > 0 else 0.0
        except Exception:
            pass

        emit(col_row.format(algo, r, pct(total, 50), pct(total, 99), ep, b1_share))

# ══════════════════════════════════════════════════════════════════════════════
# Section 2: Backend distribution by work_type
# ══════════════════════════════════════════════════════════════════════════════
emit("")
emit("=" * 80)
emit("SECTION 2: Backend distribution by work_type (cpu_only and realistic)")
emit("=" * 80)

for prof in ["cpu_only", "realistic"]:
    prof_dir = os.path.join(results_dir, prof)
    if not os.path.isdir(prof_dir):
        continue
    emit(f"\nProfile: {prof}")
    for algo in algorithms:
        path = os.path.join(prof_dir, f"{algo}.csv")
        rows = load_rows(path)
        if not rows:
            continue
        # collect per-backend, per-work_type counts
        dist = {}  # backend_id -> {work_type -> count}
        for r in rows:
            bid  = r.get("backend_id", "unknown")
            wt   = r.get("work_type", "unknown")
            dist.setdefault(bid, {}).setdefault(wt, 0)
            dist[bid][wt] += 1
        total_reqs = sum(sum(v.values()) for v in dist.values())
        if total_reqs == 0:
            continue
        emit(f"  {algo}:")
        for bid in sorted(dist.keys()):
            wtypes = dist[bid]
            parts  = ", ".join(f"{wt}={cnt}" for wt, cnt in sorted(wtypes.items()))
            share  = sum(wtypes.values()) / total_reqs * 100
            emit(f"    {bid:<12}  total={sum(wtypes.values())} ({share:.1f}%)  [{parts}]")

# ══════════════════════════════════════════════════════════════════════════════
# Section 3: Saturation ramp
# ══════════════════════════════════════════════════════════════════════════════
emit("")
emit("=" * 80)
emit("SECTION 3: Saturation ramp")
emit("=" * 80)

sat_dir = os.path.join(results_dir, "saturation")

sat_col_hdr = "{:>6} {:>9} {:>8} {:>8} {:>7} {:>10}"
sat_col_row = "{:>6} {:>9.1f} {:>8.1f} {:>8.1f} {:>6.1f}% {:>10.1f}"

for algo in sat_algorithms:
    emit(f"\nAlgorithm: {algo}")
    emit(sat_col_hdr.format("rate", "achieved/s", "p50ms", "p99ms", "err%", "in-flight"))
    emit("-" * 60)

    saturation_point = None

    for rate in sat_rates:
        path = os.path.join(sat_dir, f"{algo}_rate{rate}.csv")
        rows = load_rows(path)
        if not rows:
            emit(f"  {rate:>6}  (no data)")
            continue

        r      = rps(rows)
        total  = load_col(path, 'total_ms')
        ep     = err_pct(rows)
        p50    = pct(total, 50)
        p99    = pct(total, 99)

        # in-flight estimate: rate * (p50/1000)
        in_flight = rate * (p50 / 1000.0) if p50 > 0 else 0.0

        emit(sat_col_row.format(rate, r, p50, p99, ep, in_flight))

        if saturation_point is None and (ep > 1.0 or p99 > 5000.0):
            saturation_point = rate

    if saturation_point is not None:
        emit(f"  *** Saturation point: {saturation_point} req/s (err%>1% or p99>5000ms)")
    else:
        emit(f"  *** No saturation detected across tested rates")

emit("")
emit("=" * 80)
emit(f"Full results: {results_dir}/")
emit("=" * 80)

# Save summary to file
summary_path = os.path.join(results_dir, "summary.txt")
with open(summary_path, "w") as fh:
    fh.write("\n".join(output_lines) + "\n")

print(f"\nSummary saved to: {summary_path}")
PYEOF

hr
log "Sweep complete. Results in $RESULTS_DIR"
