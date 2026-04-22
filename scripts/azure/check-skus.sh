#!/usr/bin/env bash
# check-skus.sh — Validates VM SKU availability in each target region before deploying.
#
# Usage:
#   ./scripts/azure/check-skus.sh
#
# Exit code 0 = all SKUs available, 1 = one or more unavailable.

set -euo pipefail

# Must match BACKENDS in launch.sh
declare -a CHECKS=(
  "eastus2     Standard_B1s   backend-1   1-vCPU"
  "westus2     Standard_B2s   backend-2   2-vCPU"
  "westeurope  Standard_B4ms  backend-3   4-vCPU"
)

# Ordered fallback SKUs per vCPU tier (cheapest first)
declare -A FALLBACKS
FALLBACKS["1"]="Standard_B1ms Standard_B1s Standard_A1_v2 Standard_D2s_v5"
FALLBACKS["2"]="Standard_B2s Standard_B2ms Standard_A2_v2 Standard_D2s_v5"
FALLBACKS["4"]="Standard_B4ms Standard_B4s_v2 Standard_A4_v2 Standard_D4s_v5"

if ! az account show &>/dev/null; then
  echo "Error: not logged in to Azure. Run: az login"
  exit 1
fi

check_sku() {
  local location="$1" sku="$2"
  local info
  info=$(az vm list-skus \
    --location "$location" \
    --size "$sku" \
    --resource-type "virtualMachines" \
    --output json 2>/dev/null)

  if [[ -z "$info" || "$info" == "[]" ]]; then
    echo "NOT_FOUND"
  elif echo "$info" | grep -q "NotAvailableForSubscription"; then
    echo "RESTRICTED"
  else
    echo "OK"
  fi
}

find_fallback() {
  local location="$1" vcpu_tier="$2"
  for sku in ${FALLBACKS[$vcpu_tier]}; do
    result=$(check_sku "$location" "$sku")
    if [[ "$result" == "OK" ]]; then
      echo "$sku"
      return
    fi
  done
  echo "NONE"
}

echo ""
echo "Checking VM SKU availability..."
echo ""
printf "  %-12s  %-16s  %-10s  %-12s  %s\n" "Location" "SKU" "Backend" "vCPUs" "Status"
printf "  %-12s  %-16s  %-10s  %-12s  %s\n" "--------" "---" "-------" "-----" "------"

ALL_OK=true
declare -a FAILURES=()

for entry in "${CHECKS[@]}"; do
  read -r location sku backend vcpus <<< "$entry"
  status=$(check_sku "$location" "$sku")

  if [[ "$status" == "OK" ]]; then
    printf "  %-12s  %-16s  %-10s  %-12s  OK\n" "$location" "$sku" "$backend" "$vcpus"
  else
    tier="${vcpus%-vCPU}"
    fallback=$(find_fallback "$location" "$tier")
    if [[ "$fallback" != "NONE" ]]; then
      printf "  %-12s  %-16s  %-10s  %-12s  %-12s  → use %s\n" \
        "$location" "$sku" "$backend" "$vcpus" "$status" "$fallback"
    else
      printf "  %-12s  %-16s  %-10s  %-12s  %-12s  → no fallback found\n" \
        "$location" "$sku" "$backend" "$vcpus" "$status"
    fi
    ALL_OK=false
    FAILURES+=("$location|$sku|$backend|$vcpus|$fallback")
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
    IFS='|' read -r location sku backend vcpus fallback <<< "$failure"
    if [[ "$fallback" != "NONE" ]]; then
      echo "  $backend ($location): change $sku → $fallback"
    else
      echo "  $backend ($location): $sku unavailable and no fallback found in this region"
      echo "    Try a different region. Available regions: eastus2, westus2, westeurope, centralus, northeurope"
    fi
  done
  echo ""
  exit 1
fi
