#!/usr/bin/env bash
# azure/launch.sh — Creates Azure VMs in 3 regions for inteliLB backends.
#
# CPU layout (enforced by VM size, no Docker required):
#   eastus       backend-1   Standard_B1ms  — 1 vCPU
#   westus2      backend-2   Standard_B2s   — 2 vCPUs
#   westeurope   backend-3   Standard_B4ms  — 4 vCPUs
#
# Expects KEY_FILE (path to SSH public key) to be set by deploy.sh.

set -euo pipefail

KEY_FILE="${KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
STATE_FILE="/tmp/inteliLB-azure-instances.txt"
DIR="$(cd "$(dirname "$0")" && pwd)"

# location  resource_group  id  vm_size
declare -a BACKENDS=(
  "eastus      inteliLB-eastus      backend-1   Standard_B1ms"
  "westus2     inteliLB-westus2     backend-2   Standard_B2s"
  "westeurope  inteliLB-westeurope  backend-3   Standard_B4ms"
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
  az vm create \
    --resource-group "$rg" \
    --name "$id" \
    --location "$location" \
    --image "Ubuntu2204" \
    --size "$vm_size" \
    --admin-username azureuser \
    --ssh-key-values "$(cat "$KEY_FILE")" \
    --public-ip-sku Standard \
    --output none

  # Fetch public IP separately (avoids --query + --output tsv parsing issues)
  local public_ip
  public_ip=$(az vm show \
    --resource-group "$rg" \
    --name "$id" \
    --show-details \
    --query "publicIps" \
    --output tsv)

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
