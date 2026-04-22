#!/usr/bin/env bash
# check-skus.sh — Validates VM SKU availability in each target region before deploying.
#
# Usage:
#   ./scripts/azure/check-skus.sh
#
# Exit code 0 = all SKUs available, 1 = one or more unavailable.
#
# Note: az vm list-skus catches policy/subscription restrictions only.
# Real-time capacity exhaustion (SkuNotAvailable) is NOT detectable here —
# it only surfaces during an actual deployment attempt.

set -euo pipefail

# Must match BACKENDS in launch.sh
# backend-1 uses Standard_B2s; taskset in deploy-backend.sh pins it to 1 core
declare -a CHECKS=(
  "centralus   Standard_B2s   backend-1   2-vCPU"
  "westus2     Standard_B2s   backend-2   2-vCPU"
  "westeurope  Standard_B4ms  backend-3   4-vCPU"
)

SKU_CHECK_TIMEOUT=90  # seconds per az vm list-skus call

if ! az account show &>/dev/null; then
  echo "Error: not logged in to Azure. Run: az login"
  exit 1
fi

TMPDIR_RESULTS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RESULTS"' EXIT

# ── Parallel SKU checks ───────────────────────────────────────────────────────

check_sku_to_file() {
  local location="$1" sku="$2" outfile="$3"
  local info restriction_count

  info=$(timeout "$SKU_CHECK_TIMEOUT" az vm list-skus \
    --location "$location" \
    --size "$sku" \
    --resource-type "virtualMachines" \
    --output json 2>/dev/null) || { echo "TIMEOUT" > "$outfile"; return; }

  if [[ -z "$info" || "$info" == "[]" ]]; then
    echo "NOT_FOUND" > "$outfile"
    return
  fi

  restriction_count=$(echo "$info" | python3 -c "
import json, sys
data = json.load(sys.stdin)
total = sum(len(item.get('restrictions', [])) for item in data)
print(total)
" 2>/dev/null || echo "0")

  if [[ "$restriction_count" -gt 0 ]]; then
    echo "RESTRICTED" > "$outfile"
  else
    echo "OK" > "$outfile"
  fi
}

echo ""
echo "Checking VM SKU availability (running in parallel, timeout ${SKU_CHECK_TIMEOUT}s each)..."
echo ""

declare -a PIDS=()
declare -a OUTFILES=()

for entry in "${CHECKS[@]}"; do
  read -r location sku backend vcpus <<< "$entry"
  outfile="$TMPDIR_RESULTS/${backend}.txt"
  OUTFILES+=("$outfile")
  check_sku_to_file "$location" "$sku" "$outfile" &
  PIDS+=($!)
done

# Progress indicator while waiting
total=${#PIDS[@]}
done_count=0
while [[ $done_count -lt $total ]]; do
  sleep 2
  done_count=0
  for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || done_count=$((done_count + 1))
  done
  printf "\r  Waiting... (%d/%d complete)" "$done_count" "$total"
done
printf "\r  All checks complete.              \n\n"

for pid in "${PIDS[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# ── Print results ─────────────────────────────────────────────────────────────

printf "  %-12s  %-16s  %-10s  %-12s  %s\n" "Location" "SKU" "Backend" "vCPUs" "Status"
printf "  %-12s  %-16s  %-10s  %-12s  %s\n" "--------" "---" "-------" "-----" "------"

ALL_OK=true
declare -a FAILURES=()

i=0
for entry in "${CHECKS[@]}"; do
  read -r location sku backend vcpus <<< "$entry"
  outfile="${OUTFILES[$i]}"
  i=$((i + 1))

  status="UNKNOWN"
  [[ -f "$outfile" ]] && status=$(cat "$outfile")

  if [[ "$status" == "OK" ]]; then
    printf "  %-12s  %-16s  %-10s  %-12s  OK\n" "$location" "$sku" "$backend" "$vcpus"
  else
    printf "  %-12s  %-16s  %-10s  %-12s  %s\n" "$location" "$sku" "$backend" "$vcpus" "$status"
    ALL_OK=false
    FAILURES+=("$location|$sku|$backend|$vcpus")
  fi
done

echo ""

if $ALL_OK; then
  echo "All SKUs available. Safe to deploy."
  exit 0
else
  echo "Fix required — update BACKENDS in scripts/azure/launch.sh:"
  echo ""
  for failure in "${FAILURES[@]}"; do
    IFS='|' read -r location sku backend vcpus <<< "$failure"
    echo "  $backend ($location): $sku is RESTRICTED or NOT_FOUND in this region"
    echo "    Try a different region or SKU."
  done
  echo ""
  exit 1
fi
