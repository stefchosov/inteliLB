#!/usr/bin/env bash
# azure/launch.sh — Creates Azure VMs in 3 regions for inteliLB backends.
#
# CPU layout:
#   westus2          backend-1   Standard_D2s_v3  — 2 vCPU VM, pinned to 1 core via taskset
#   northcentralus   backend-2   Standard_D2s_v3  — 2 vCPUs
#   eastus2          backend-3   Standard_D4s_v4  — 4 vCPUs  (v3 capacity scarce; eastus/southcentralus blocked)
#
# DSv3 quota per region is 4 vCPUs on Azure for Students — each backend
# must be in its own region (2+2+4 cores across three separate quota pools).
#
# Azure for Students only permits VM resources in a small set of US regions;
# northeurope/westeurope/etc. pass the RG probe but block NSG/NIC/VM creation.
#
# Expects KEY_FILE (path to SSH public key) to be set by deploy.sh.

set -euo pipefail

KEY_FILE="${KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
STATE_FILE="/tmp/inteliLB-azure-instances.txt"
DIR="$(cd "$(dirname "$0")" && pwd)"

# location  resource_group  id  vm_size
# All backends use Dv3-series — Dv5 is NotAvailableForSubscription on
# Azure for Students; Dv3 is confirmed available in all target regions.
# backend-1 is still pinned to 1 core via taskset in deploy-backend.sh.
declare -a BACKENDS=(
  "westus2        inteliLB-westus2        backend-1   Standard_D2s_v3"
  "northcentralus inteliLB-northcentralus backend-2   Standard_D2s_v3"
  "eastus2        inteliLB-eastus2        backend-3   Standard_D4s_v4"
)

launch_vm() {
  local location="$1" rg="$2" id="$3" vm_size="$4"

  echo "━━━ [$location] Launching $id ($vm_size) ━━━"

  # Create resource group
  az group create \
    --name "$rg" \
    --location "$location" \
    --output none
  echo "  Resource group: $rg"

  # Create VM
  echo "  [debug] az vm create: rg=$rg id=$id location=$location size=$vm_size"
  set -x
  az vm create \
    --resource-group "$rg" \
    --name "$id" \
    --location "$location" \
    --image "Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest" \
    --size "$vm_size" \
    --admin-username azureuser \
    --generate-ssh-keys \
    --public-ip-sku Standard \
    --output none
  set +x

  # Fetch public IP separately
  local public_ip
  echo "  [debug] fetching public IP for $id..."
  set -x
  public_ip=$(az vm show \
    --resource-group "$rg" \
    --name "$id" \
    --show-details \
    --query "publicIps" \
    --output tsv)
  set +x

  echo "  VM created — opening port 8080..."
  az vm open-port \
    --resource-group "$rg" \
    --name "$id" \
    --port 8080 \
    --priority 1001 \
    --output none

  echo "  $id UP at $public_ip"
  echo "$public_ip $id $location $rg" >> "$STATE_FILE"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Check Azure CLI is logged in
if ! az account show &>/dev/null; then
  echo "Error: not logged in to Azure. Run: az login"
  exit 1
fi

# ── Region policy pre-flight ──────────────────────────────────────────────────
# Create a test resource group in each target region to verify the subscription
# policy allows it. This is instant and free, unlike az vm list-skus.
echo "Checking region access (creating test resource groups)..."
REGION_OK=true
declare -A REGION_STATUS
PROBE_SUFFIX="inteliLB-probe-$$"

for entry in "${BACKENDS[@]}"; do
  read -r location rg id vm_size <<< "$entry"
  probe_rg="${PROBE_SUFFIX}-${location}"
  if az group create --name "$probe_rg" --location "$location" --output none 2>/dev/null; then
    # RG creation alone is not sufficient — test an actual compute resource (NSG)
    # since Azure for Students blocks VM/NIC/NSG in some regions even if RGs succeed.
    if az network nsg create --name probe-nsg --resource-group "$probe_rg" \
        --location "$location" --output none 2>/dev/null; then
      REGION_STATUS[$location]="OK"
      echo "  $location — OK"
    else
      REGION_STATUS[$location]="BLOCKED"
      echo "  $location — BLOCKED by subscription policy (VM resources denied)"
      REGION_OK=false
    fi
    az group delete --name "$probe_rg" --yes --no-wait 2>/dev/null || true
  else
    REGION_STATUS[$location]="BLOCKED"
    echo "  $location — BLOCKED by subscription policy"
    REGION_OK=false
  fi
done

if ! $REGION_OK; then
  echo ""
  echo "One or more regions are blocked. Update BACKENDS in launch.sh to use allowed regions."
  echo "Allowed regions for this subscription (run: az account list-locations -o table)"
  exit 1
fi
echo ""

rm -f "$STATE_FILE"

for entry in "${BACKENDS[@]}"; do
  read -r location rg id vm_size <<< "$entry"
  launch_vm "$location" "$rg" "$id" "$vm_size"
done

echo ""
echo "━━━ Waiting 60s for SSH + cloud-init to finish... ━━━"
sleep 60

# Determine SSH private key from the public key path
SSH_PRIVATE_KEY="${KEY_FILE%.pub}"
if [[ "$SSH_PRIVATE_KEY" == "$KEY_FILE" ]]; then
  SSH_PRIVATE_KEY="$HOME/.ssh/id_rsa"
fi

while IFS=' ' read -r ip id location rg; do
  echo "Deploying $id on $ip ($location)..."
  PUBLIC_IP="$ip" \
  SSH_USER="azureuser" \
  KEY_FILE="$SSH_PRIVATE_KEY" \
  REGION="$location" \
  ID="$id" \
    bash "$DIR/../deploy-backend.sh"
done < "$STATE_FILE"

# ── Print LB run command ───────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "All Azure backends deployed. Run the load balancer locally:"
echo ""

BACKEND_URLS=""
while IFS=' ' read -r ip id location rg; do
  BACKEND_URLS+="http://$ip:8080,"
done < "$STATE_FILE"
BACKEND_URLS="${BACKEND_URLS%,}"

echo "  go run ./cmd/loadbalancer \\"
echo "    -port=8080 \\"
echo "    -algorithm=intelligent \\"
echo "    -backends=\"$BACKEND_URLS\""
echo ""
echo "VM layout:"
while IFS=' ' read -r ip id location rg; do
  printf "  %-12s  %-10s  http://%s:8080\n" "$location" "$id" "$ip"
done < "$STATE_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
