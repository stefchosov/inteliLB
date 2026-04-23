#!/usr/bin/env bash
# run-latency-sweep-azure.sh — Latency sweep on real Azure infrastructure.
#
# Deploys 3 asymmetric backends once, then for each latency profile SSHs
# into each VM and restarts the backend with a new SIMULATED_LATENCY_MS,
# avoiding re-provisioning between profiles.
#
# Real compute layout (from launch.sh / deploy-backend.sh):
#   backend-1  westus2         Standard_D2s_v3  2-vCPU, pinned to 1 core (taskset)
#   backend-2  northcentralus  Standard_D2s_v3  2-vCPU, all cores available
#   backend-3  eastus2         Standard_D4s_v3  4-vCPU, all cores available
#
# Geographic base RTT (measured in prior experiment, LB runs locally):
#   backend-1  westus2:         ~40ms
#   backend-2  northcentralus:  ~40ms
#   backend-3  eastus2:         ~60ms
#
# Simulated latency profiles (one-way ms, added on top of geographic RTT):
#   none      b1=+0    b2=+0    b3=+0    baseline — geography only
#   light     b1=+0    b2=+25   b3=+50   slight spread
#   medium    b1=+0    b2=+75   b3=+150  realistic cross-region
#   heavy     b1=+0    b2=+150  b3=+300  cross-continent
#   extreme   b1=+0    b2=+300  b3=+600  intercontinental
#
# Usage:
#   ./scripts/run-latency-sweep-azure.sh [OPTIONS]
#
# Options:
#   --workers   N     concurrent client workers       (default: 20)
#   --duration  Xs    per-algorithm run duration      (default: 60s)
#   --intensity N     CPU work intensity 1-10         (default: 7)
#   --key-file  PATH  SSH private key                 (default: ~/.ssh/id_rsa)
#   --profiles  LIST  comma-separated subset to run   (default: all 5)
#   --results   DIR   output directory
#   --skip-deploy     skip provisioning (reuse running VMs)
#   -h, --help

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALGORITHMS=(round_robin lowest_latency least_connections lowest_cpu intelligent adaptive)
AZURE_STATE="/tmp/inteliLB-azure-instances.txt"

WORKERS=20
DURATION="60s"
INTENSITY=7
KEY_FILE="$HOME/.ssh/id_rsa"
RESULTS_DIR=""
PROFILE_FILTER=""
SKIP_DEPLOY=false

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
hr()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workers)      WORKERS="$2";        shift 2 ;;
    --duration)     DURATION="$2";       shift 2 ;;
    --intensity)    INTENSITY="$2";      shift 2 ;;
    --key-file)     KEY_FILE="$2";       shift 2 ;;
    --profiles)     PROFILE_FILTER="$2"; shift 2 ;;
    --results)      RESULTS_DIR="$2";    shift 2 ;;
    --skip-deploy)  SKIP_DEPLOY=true;    shift   ;;
    -h|--help) sed -n '3,32p' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

RESULTS_DIR="${RESULTS_DIR:-$PROJECT_ROOT/results/$(date +%Y%m%d_%H%M%S)_latency_sweep_azure}"
mkdir -p "$RESULTS_DIR"

SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30"
SSH_USER="azureuser"

# ── Latency profiles ───────────────────────────────────────────────────────
declare -a PROFILES=(
  "none    0    0    0"
  "light   0   25   50"
  "medium  0   75  150"
  "heavy   0  150  300"
  "extreme 0  300  600"
)

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
LB_PID=""

cleanup() {
  [[ -n "$LB_PID" ]] && kill "$LB_PID" 2>/dev/null || true
  if [[ -f "$AZURE_STATE" ]]; then
    log "Tearing down Azure infrastructure..."
    bash "$PROJECT_ROOT/scripts/azure/teardown.sh" || true
  fi
}
trap cleanup EXIT INT TERM

# ── Prerequisites ──────────────────────────────────────────────────────────
hr
log "inteliLB Azure latency sweep"
log "workers=$WORKERS  duration=$DURATION  intensity=$INTENSITY"
log "Profiles: $(for p in "${PROFILES[@]}"; do awk '{printf "%s(+%s/+%s/+%sms) ",$1,$2,$3,$4}' <<< "$p"; done)"
log "Results → $RESULTS_DIR"
hr

command -v go      >/dev/null || die "'go' not found"
command -v az      >/dev/null || die "'az' not found"
command -v curl    >/dev/null || die "'curl' not found"
command -v python3 >/dev/null || die "'python3' not found"
[[ -f "$KEY_FILE" ]] || die "SSH key not found: $KEY_FILE (pass --key-file)"
az account show &>/dev/null  || die "Not logged in to Azure — run: az login"

log "Building binaries..."
cd "$PROJECT_ROOT"
go mod tidy
mkdir -p "$PROJECT_ROOT/bin"
go build -o "$PROJECT_ROOT/bin/loadbalancer" ./cmd/loadbalancer
go build -o "$PROJECT_ROOT/bin/backend"      ./cmd/backend
go build -o "$PROJECT_ROOT/bin/client"       ./cmd/client
log "Build complete"

# ── Deploy Azure backends ──────────────────────────────────────────────────
if ! $SKIP_DEPLOY; then
  hr
  log "Deploying Azure backends (8-12 min)..."
  KEY_FILE="$KEY_FILE" bash "$PROJECT_ROOT/scripts/deploy.sh" --key-file "${KEY_FILE}.pub" \
    | tee "$RESULTS_DIR/deploy.log"
fi

[[ -f "$AZURE_STATE" ]] || die "Azure state file not found: $AZURE_STATE"

# Parse state file: ip id location rg
declare -A BACKEND_IPS BACKEND_REGIONS
while IFS=' ' read -r ip id location rg; do
  BACKEND_IPS[$id]="$ip"
  BACKEND_REGIONS[$id]="$location"
done < "$AZURE_STATE"

for id in backend-1 backend-2 backend-3; do
  [[ -n "${BACKEND_IPS[$id]:-}" ]] || die "Missing $id in state file $AZURE_STATE"
done

BACKEND_URLS="http://${BACKEND_IPS[backend-1]}:8080,http://${BACKEND_IPS[backend-2]}:8080,http://${BACKEND_IPS[backend-3]}:8080"

# ── Helpers ────────────────────────────────────────────────────────────────
wait_healthy() {
  local url="$1" label="$2"
  for ((i=1; i<=40; i++)); do
    curl -sf --max-time 3 "$url/health" >/dev/null 2>&1 && { log "  $label ready"; return 0; }
    sleep 3
  done
  die "$label did not become healthy after 120s"
}

switch_algorithm() {
  curl -sf -X POST http://localhost:8080/lb/algorithm \
    -H "Content-Type: application/json" \
    -d "{\"algorithm\":\"$1\"}" >/dev/null \
    || die "Failed to switch algorithm to $1"
}

# Restart a backend on its VM with a new simulated latency.
# Uses the binary already deployed in /tmp from the initial deploy.
restart_backend_with_latency() {
  local id="$1" latency_ms="$2"
  local ip="${BACKEND_IPS[$id]}"
  local region="${BACKEND_REGIONS[$id]}"

  # Determine taskset prefix (backend-1 is CPU-pinned, others are not)
  local taskset_prefix=""
  [[ "$id" == "backend-1" ]] && taskset_prefix="taskset -c 0 "

  log "  Restarting $id ($region) with +${latency_ms}ms simulated latency..."
  ssh $SSH_OPTS "$SSH_USER@$ip" bash <<REMOTE
set -e
pkill -f inteliLB-backend 2>/dev/null || true
sleep 1
nohup env REGION="$region" ID="$id" SIMULATED_LATENCY_MS="$latency_ms" \
  ${taskset_prefix}/tmp/inteliLB-backend -port=8080 \
  > /tmp/inteliLB-backend.log 2>&1 &
echo "Restarted $id with SIMULATED_LATENCY_MS=$latency_ms (PID \$!)"
REMOTE
}

# ── Utilization poller ─────────────────────────────────────────────────────
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

  cat > "$profile_dir/config.txt" <<EOF
profile:    $name
date:       $(date)
workers:    $WORKERS
duration:   $DURATION
intensity:  $INTENSITY
b1:  westus2         D2s_v3  1-core (taskset)  +${delay_b1}ms simulated
b2:  northcentralus  D2s_v3  2-core            +${delay_b2}ms simulated
b3:  eastus2         D4s_v3  4-core            +${delay_b3}ms simulated
algorithms: ${ALGORITHMS[*]}
EOF

  # Restart backends with new latency values
  restart_backend_with_latency "backend-1" "$delay_b1"
  restart_backend_with_latency "backend-2" "$delay_b2"
  restart_backend_with_latency "backend-3" "$delay_b3"

  # Wait for backends to be healthy again after restart
  wait_healthy "http://${BACKEND_IPS[backend-1]}:8080" "backend-1"
  wait_healthy "http://${BACKEND_IPS[backend-2]}:8080" "backend-2"
  wait_healthy "http://${BACKEND_IPS[backend-3]}:8080" "backend-3"

  # Start LB
  "$PROJECT_ROOT/bin/loadbalancer" \
    -port=8080 -algorithm=round_robin \
    -backends="$BACKEND_URLS" \
    >> "$profile_dir/loadbalancer.log" 2>&1 &
  LB_PID=$!
  sleep 3
  wait_healthy http://localhost:8080 "load-balancer"

  # Algorithm loop
  local total=${#ALGORITHMS[@]} current=0
  for algo in "${ALGORITHMS[@]}"; do
    current=$((current + 1))
    log "  [$current/$total] $algo"

    switch_algorithm "$algo"
    sleep 5

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
      log "  Cooling down 30s..."
      sleep 30
    fi
  done

  # Stop LB between profiles
  kill "$LB_PID" 2>/dev/null || true
  LB_PID=""
  sleep 3

  log "Profile '$name' complete — results in $profile_dir"
}

# ── Run all profiles ────────────────────────────────────────────────────────
for entry in "${PROFILES[@]}"; do
  read -r name d1 d2 d3 <<< "$entry"
  run_profile "$name" "$d1" "$d2" "$d3"
done

# ── Cross-profile summary (shared with local sweep) ────────────────────────
hr
log "Computing cross-profile summary..."
hr

python3 - "$RESULTS_DIR" "${ALGORITHMS[@]}" << 'PYEOF'
import csv, sys, os, json

results_dir = sys.argv[1]
algorithms  = sys.argv[2:]

_order   = ["none", "light", "medium", "heavy", "extreme"]
profiles = [d for d in _order if os.path.isdir(os.path.join(results_dir, d))]
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

hdr = f"{'Algorithm':<22}" + "".join(f"  {p:>9}" for p in profiles)
sep = "-" * len(hdr)

print("\n=== req/s by algorithm and latency profile ===")
print(hdr); print(sep)
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        val = rps(f"{results_dir}/{prof}/{algo}.csv")
        row += f"  {val:>8.1f} " if val else f"  {'n/a':>9}"
    print(row)

print("\n=== p50 total RTT (ms) ===")
print(hdr); print(sep)
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        vals = load(f"{results_dir}/{prof}/{algo}.csv", 'total_ms')
        row += f"  {p(vals,50):>8.0f} " if vals else f"  {'n/a':>9}"
    print(row)

print("\n=== p99 total RTT (ms) ===")
print(hdr); print(sep)
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        vals = load(f"{results_dir}/{prof}/{algo}.csv", 'total_ms')
        row += f"  {p(vals,99):>8.0f} " if vals else f"  {'n/a':>9}"
    print(row)

print("\n=== p50 network RTT (ms) ===")
print(hdr); print(sep)
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        vals = load(f"{results_dir}/{prof}/{algo}.csv", 'network_ms')
        row += f"  {p(vals,50):>8.0f} " if vals else f"  {'n/a':>9}"
    print(row)

print("\n=== backend-1 share % per profile ===")
print(hdr); print(sep)
for algo in algorithms:
    row = f"  {algo:<22}"
    for prof in profiles:
        spath = f"{results_dir}/{prof}/{algo}_stats.json"
        try:
            data     = json.load(open(spath))
            backends = data.get("backends", [])
            total    = sum(b["total_requests"] for b in backends)
            b1       = next((b["total_requests"] for b in backends if b["id"]=="backend-1"), 0)
            row     += f"  {b1/total*100:>8.1f}%" if total > 0 else f"  {'n/a':>9}"
        except:
            row += f"  {'n/a':>9}"
    print(row)

print("\n=== p50 RTT per backend per profile (from backend_id column) ===")
for algo in ["least_connections", "round_robin", "lowest_latency"]:
    print(f"\n  {algo}:")
    print(f"  {'Profile':<10}  {'b1 p50':>8}  {'b2 p50':>8}  {'b3 p50':>8}  {'b1 n':>6}  {'b2 n':>6}  {'b3 n':>6}")
    print(f"  {'-'*62}")
    for prof in profiles:
        path = f"{results_dir}/{prof}/{algo}.csv"
        by_b = {"backend-1":[], "backend-2":[], "backend-3":[]}
        try:
            for r in csv.DictReader(open(path)):
                bid = r.get("backend_id","")
                if bid in by_b and r.get("error","false") != "true":
                    try: by_b[bid].append(float(r["total_ms"]))
                    except: pass
        except: pass
        cols = "".join(f"  {p(v,50):>7.0f}ms" if v else f"  {'n/a':>8}" for v in [by_b["backend-1"],by_b["backend-2"],by_b["backend-3"]])
        ns   = "".join(f"  {len(by_b[b]):>6}" for b in ["backend-1","backend-2","backend-3"])
        print(f"  {prof:<10}{cols}{ns}")

print("\n=== backend-1 traffic share over time (early→mid→late) ===")
for algo in algorithms:
    row_parts = []
    for prof in profiles:
        upath = f"{results_dir}/{prof}/{algo}_utilization.csv"
        snaps = {}
        try:
            for r in csv.DictReader(open(upath)):
                t = int(float(r["elapsed_s"]))
                bid = r["backend_id"]
                tr = int(float(r.get("total_requests", 0)))
                if t not in snaps: snaps[t] = {}
                snaps[t][bid] = tr
        except: pass
        if not snaps:
            row_parts.append("n/a")
            continue
        times = sorted(snaps.keys())
        def b1_share_at(target):
            closest = min(times, key=lambda t: abs(t - target))
            snap = snaps[closest]
            total = sum(snap.values())
            b1 = snap.get("backend-1", 0)
            return f"{b1/total*100:.0f}%" if total > 0 else "?"
        row_parts.append(f"{b1_share_at(10)}→{b1_share_at(30)}→{b1_share_at(55)}")
    print(f"  {algo:<22}  " + "  ".join(f"{prof:>7}:{v:<14}" for prof, v in zip(profiles, row_parts)))

print(f"\nFull results: {results_dir}/")
PYEOF

hr
log "Sweep complete."
