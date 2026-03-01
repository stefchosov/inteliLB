#!/usr/bin/env bash
# azure/teardown.sh — Deletes all inteliLB Azure resource groups.
# Each resource group contains exactly one VM plus its NIC, disk, NSG, and
# public IP — so deleting the group removes everything cleanly.

set -euo pipefail

RESOURCE_GROUPS=(
  "inteliLB-eastus"
  "inteliLB-westus2"
  "inteliLB-westeurope"
)

if ! az account show &>/dev/null; then
  echo "Error: not logged in to Azure. Run: az login"
  exit 1
fi

for rg in "${RESOURCE_GROUPS[@]}"; do
  if az group show --name "$rg" &>/dev/null; then
    echo "Deleting resource group $rg..."
    az group delete --name "$rg" --yes --no-wait
    echo "  Deletion of $rg queued (runs in background)"
  else
    echo "Resource group $rg not found — skipping"
  fi
done

rm -f /tmp/inteliLB-azure-instances.txt
echo ""
echo "Done. Resource groups are being deleted (takes 2–3 min in Azure portal)."
