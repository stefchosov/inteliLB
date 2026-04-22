#!/usr/bin/env bash
# run-experiment.sh — End-to-end experiment automation for inteliLB.
#
# Compiles binaries, provisions infrastructure, runs all 6 algorithms,
# saves results, tears down, and prints a summary table.
#
# Usage:
#   ./scripts/run-experiment.sh [OPTIONS]
#
# Options:
#   --mode      local|azure   local=go run on your machine (no CPU limits, code check only)
#                             azure=deploy VMs, run, tear down  (default: azure)
#   --workers   N             concurrent client workers         (default: 20)
#   --duration  Xs            duration per algorithm run        (default: 120s)
#   --intensity N             CPU work intensity 1-10           (default: 7)
#   --key-file  PATH          SSH public key for Azure          (default: ~/.ssh/id_rsa.pub)
#   --results   DIR           results directory                 (default: results/YYYYMMDD_HHMMSS_MODE)
#   -h, --help

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
MODE="azure"
WORKERS=20
DURATION="120s"
INTENSITY=7
KEY_FILE="$HOME/.ssh/id_rsa.pub"
RESULTS_DIR=""

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALGORITHMS=(round_robin lowest_latency least_connections lowest_cpu intelligent adaptive)
AZURE_STATE="/tmp/inteliLB-azure-instances.txt"

LB_PID=""
BACKEND_PIDS=()

# ── Logging ───────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo ""; echo "ERROR: $*" >&2; exit 1; }
hr()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  echo ""
  hr
  log "Shutting down..."

  if [[ -n "$LB_PID" ]] && kill -0 "$LB_PID" 2>/dev/null; then
    kill "$LB_PID" 2>/dev/null || true
    log "Load balancer stopped (PID $LB_PID)"
  fi

  if [[ ${#BACKEND_PIDS[@]} -gt 0 ]]; then
    for pid in "${BACKEND_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
    done
    log "Local backends stopped"
  fi

  if [[ "$MODE" == "azure" && -f "$AZURE_STATE" ]]; then
    log "Tearing down Azure infrastructure..."
    bash "$PROJECT_ROOT/scripts/azure/teardown.sh" || true
  fi

  hr
}

trap cleanup EXIT
trap 'echo ""; log "Interrupted."; exit 130' INT TERM

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

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      MODE="$2";        shift 2 ;;
    --workers)   WORKERS="$2";     shift 2 ;;
    --duration)  DURATION="$2";    shift 2 ;;
    --intensity) INTENSITY="$2";   shift 2 ;;
    --key-file)  KEY_FILE="$2";    shift 2 ;;
    --results)   RESULTS_DIR="$2"; shift 2 ;;
    -h|--help)   sed -n '3,22p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

[[ "$MODE" == "local" || "$MODE" == "azure" ]] \
  || die "--mode must be 'local' or 'azure'"

RESULTS_DIR="${RESULTS_DIR:-$PROJECT_ROOT/results/$(date +%Y%m%d_%H%M%S)_${MODE}}"
mkdir -p "$RESULTS_DIR"

# ── Prerequisites ─────────────────────────────────────────────────────────────
hr
log "inteliLB experiment — mode=$MODE workers=$WORKERS duration=$DURATION intensity=$INTENSITY"
log "Results → $RESULTS_DIR"
hr

command -v go     >/dev/null || die "'go' not found in PATH"
command -v curl   >/dev/null || die "'curl' not found in PATH"
command -v python3 >/dev/null 2>&1 || command -v python >/dev/null \
  || die "python3 not found — needed for summary"

if [[ "$MODE" == "azure" ]]; then
  command -v az >/dev/null || die "'az' not found — run: winget install Microsoft.AzureCLI"
  az account show &>/dev/null   || die "Not logged in to Azure — run: az login"
fi

# Save run config for reproducibility
cat > "$RESULTS_DIR/config.txt" <<EOF
date:      $(date)
mode:      $MODE
workers:   $WORKERS
duration:  $DURATION
intensity: $INTENSITY
algorithms: ${ALGORITHMS[*]}
EOF

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

# ── Infrastructure ────────────────────────────────────────────────────────────
hr
BACKEND_URLS=""

if [[ "$MODE" == "local" ]]; then
  log "Starting local backends (no CPU limits — code verification only)..."

  REGION=us-east ID=backend-1 "$PROJECT_ROOT/bin/backend" -port=8081 \
    >> "$RESULTS_DIR/backend-1.log" 2>&1 &
  BACKEND_PIDS+=($!)

  REGION=us-west ID=backend-2 "$PROJECT_ROOT/bin/backend" -port=8082 \
    >> "$RESULTS_DIR/backend-2.log" 2>&1 &
  BACKEND_PIDS+=($!)

  REGION=eu-west ID=backend-3 "$PROJECT_ROOT/bin/backend" -port=8083 \
    >> "$RESULTS_DIR/backend-3.log" 2>&1 &
  BACKEND_PIDS+=($!)

  sleep 2
  wait_healthy http://localhost:8081 "backend-1"
  wait_healthy http://localhost:8082 "backend-2"
  wait_healthy http://localhost:8083 "backend-3"

  BACKEND_URLS="http://localhost:8081,http://localhost:8082,http://localhost:8083"

else
  log "Deploying Azure backends (8–12 min)..."
  KEY_FILE="$KEY_FILE" bash "$PROJECT_ROOT/scripts/deploy.sh" --key-file "$KEY_FILE" \
    | tee "$RESULTS_DIR/deploy.log"

  [[ -f "$AZURE_STATE" ]] || die "Azure state file not found after deploy"

  while IFS=' ' read -r ip id location rg; do
    BACKEND_URLS+="http://$ip:8080,"
    wait_healthy "http://$ip:8080" "$id ($location)"
  done < "$AZURE_STATE"
  BACKEND_URLS="${BACKEND_URLS%,}"
fi

# ── Start load balancer ───────────────────────────────────────────────────────
hr
log "Starting load balancer on :8080 → [$BACKEND_URLS]"

"$PROJECT_ROOT/bin/loadbalancer" \
  -port=8080 \
  -algorithm=round_robin \
  -backends="$BACKEND_URLS" \
  >> "$RESULTS_DIR/loadbalancer.log" 2>&1 &
LB_PID=$!

sleep 3
wait_healthy http://localhost:8080 "load-balancer"

# ── Experiment loop ────────────────────────────────────────────────────────────
hr
log "Running ${#ALGORITHMS[@]} algorithms × $DURATION each"
hr

TOTAL_ALGORITHMS=${#ALGORITHMS[@]}
CURRENT=0

for algo in "${ALGORITHMS[@]}"; do
  CURRENT=$((CURRENT + 1))
  hr
  log "[$CURRENT/$TOTAL_ALGORITHMS] Algorithm: $algo"

  switch_algorithm "$algo"
  sleep 5  # let LB metrics settle after switch

  log "  Running client..."
  "$PROJECT_ROOT/bin/client" \
    -url=http://localhost:8080 \
    -workers="$WORKERS" \
    -duration="$DURATION" \
    -intensity="$INTENSITY" \
    -output="$RESULTS_DIR/${algo}.csv"

  log "  Saving stats snapshot..."
  curl -sf http://localhost:8080/lb/stats \
    > "$RESULTS_DIR/${algo}_stats.json" 2>/dev/null \
    || log "  WARNING: could not fetch stats for $algo"

  if [[ "$CURRENT" -lt "$TOTAL_ALGORITHMS" ]]; then
    log "  Cooling down 30s before next algorithm..."
    sleep 30
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
hr
log "Computing summary..."
hr

PYTHON=$(command -v python3 2>/dev/null || command -v python)
"$PYTHON" - "$RESULTS_DIR" "${ALGORITHMS[@]}" <<'PYEOF'
import csv, sys, os, json

results_dir = sys.argv[1]
algorithms  = sys.argv[2:]

col = "{:<22} {:>6} {:>7} {:>6} {:>9} {:>9} {:>9} {:>8}"
print(col.format("Algorithm", "n", "errors", "err%", "p50(ms)", "p95(ms)", "p99(ms)", "req/s"))
print("-" * 82)

rows_by_algo = {}
for algo in algorithms:
    path = os.path.join(results_dir, f"{algo}.csv")
    if not os.path.exists(path):
        print(f"  {algo:<20}  (no data file)")
        continue

    rows = list(csv.DictReader(open(path)))
    if not rows:
        print(f"  {algo:<20}  (empty CSV)")
        continue

    lats = sorted(float(r['duration_ms']) for r in rows if r.get('error','false') == 'false')
    errs = sum(1 for r in rows if r.get('error','false') == 'true')
    n    = len(rows)
    nl   = len(lats)

    p50 = lats[max(0, int(nl * 0.50) - 1)] if nl else 0.0
    p95 = lats[max(0, int(nl * 0.95) - 1)] if nl else 0.0
    p99 = lats[max(0, int(nl * 0.99) - 1)] if nl else 0.0

    ts      = [int(r['timestamp_ms']) for r in rows if r.get('timestamp_ms','')]
    elapsed = (max(ts) - min(ts)) / 1000.0 if len(ts) > 1 else 1.0
    rps     = n / elapsed if elapsed > 0 else 0.0
    err_pct = errs / n * 100 if n > 0 else 0.0

    rows_by_algo[algo] = dict(n=n, errs=errs, err_pct=err_pct,
                               p50=p50, p95=p95, p99=p99, rps=rps)
    print(col.format(algo, n, errs, f"{err_pct:.1f}%",
                     f"{p50:.1f}", f"{p95:.1f}", f"{p99:.1f}", f"{rps:.1f}"))

print("")

# Per-algorithm backend breakdown from stats JSONs
print("Backend distribution (% of requests per algorithm):")
dist_col = "{:<22} {:<14} {:<14} {:<14}"
print(dist_col.format("Algorithm", "backend-1", "backend-2", "backend-3"))
print("-" * 60)
for algo in algorithms:
    spath = os.path.join(results_dir, f"{algo}_stats.json")
    if not os.path.exists(spath):
        continue
    try:
        data     = json.load(open(spath))
        backends = data.get("backends", [])
        total    = sum(b.get("total_requests", 0) for b in backends)
        if total == 0:
            continue
        pcts = [f"{b.get('total_requests',0)/total*100:.1f}%" for b in backends]
        while len(pcts) < 3:
            pcts.append("n/a")
        print(dist_col.format(algo, *pcts[:3]))
    except Exception:
        pass

print("")
print(f"All results saved to: {results_dir}")
PYEOF

hr
log "Experiment complete."
