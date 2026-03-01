#!/usr/bin/env bash
# azure/launch.sh — Creates Azure VMs in 3 regions for inteliLB backends.
#
# CPU layout:
#   eastus       backend-1   Standard_B1ms  → Docker --cpus=1
#   westus2      backend-2   Standard_B2s   → Docker --cpus=2
#   westeurope   backend-3   Standard_B4ms  → Docker --cpus=4
#
# Expects KEY_FILE (path to SSH public key) to be set by deploy.sh.

set -euo pipefail

KEY_FILE="${KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
STATE_FILE="/tmp/inteliLB-azure-instances.txt"
DIR="$(cd "$(dirname "$0")" && pwd)"

# location  resource_group  id  vm_size  docker_cpus
declare -a BACKENDS=(
  "eastus      inteliLB-eastus      backend-1   Standard_B1ms   1"
  "westus2     inteliLB-westus2     backend-2   Standard_B2s    2"
  "westeurope  inteliLB-westeurope  backend-3   Standard_B4ms   4"
)

launch_vm() {
  local location="$1" rg="$2" id="$3" vm_size="$4" docker_cpus="$5"

  echo "━━━ [$location] Launching $id ($vm_size, ${docker_cpus} docker CPU(s)) ━━━"

  # Create resource group
  az group create \
    --name "$rg" \
    --location "$location" \
    --output none
  echo "  Resource group: $rg"

  # Create VM
  local public_ip
  public_ip=$(az vm create \
    --resource-group "$rg" \
    --name "$id" \
    --location "$location" \
    --image "Ubuntu2204" \
    --size "$vm_size" \
    --admin-username azureuser \
    --ssh-key-values "$KEY_FILE" \
    --public-ip-sku Standard \
    --query "publicIpAddress" \
    --output tsv)

  echo "  VM created — opening port 8080..."
  az vm open-port \
    --resource-group "$rg" \
    --name "$id" \
    --port 8080 \
    --priority 1001 \
    --output none

  echo "  $id UP at $public_ip"
  echo "$public_ip $id $location $docker_cpus $rg" >> "$STATE_FILE"
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Check Azure CLI is logged in
if ! az account show &>/dev/null; then
  echo "Error: not logged in to Azure. Run: az login"
  exit 1
fi

rm -f "$STATE_FILE"

for entry in "${BACKENDS[@]}"; do
  read -r location rg id vm_size docker_cpus <<< "$entry"
  launch_vm "$location" "$rg" "$id" "$vm_size" "$docker_cpus"
done

echo ""
echo "━━━ Waiting 60s for SSH + cloud-init to finish... ━━━"
sleep 60

# Determine SSH private key from the public key path
SSH_PRIVATE_KEY="${KEY_FILE%.pub}"
if [[ "$SSH_PRIVATE_KEY" == "$KEY_FILE" ]]; then
  # KEY_FILE wasn't a .pub file — try stripping nothing and assume same path
  SSH_PRIVATE_KEY="$HOME/.ssh/id_rsa"
fi

while IFS=' ' read -r ip id location docker_cpus rg; do
  echo "Deploying $id on $ip ($location)..."
  PUBLIC_IP="$ip" \
  SSH_USER="azureuser" \
  KEY_FILE="$SSH_PRIVATE_KEY" \
  REGION="$location" \
  ID="$id" \
  DOCKER_CPUS="$docker_cpus" \
    bash "$DIR/../deploy-backend.sh"
done < "$STATE_FILE"

# ── Print LB run command ───────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "All Azure backends deployed. Run the load balancer locally:"
echo ""

BACKEND_URLS=""
while IFS=' ' read -r ip id location docker_cpus rg; do
  BACKEND_URLS+="http://$ip:8080,"
done < "$STATE_FILE"
BACKEND_URLS="${BACKEND_URLS%,}"

echo "  go run ./cmd/loadbalancer \\"
echo "    -port=8080 \\"
echo "    -algorithm=intelligent \\"
echo "    -backends=\"$BACKEND_URLS\""
echo ""
echo "CPU layout:"
while IFS=' ' read -r ip id location docker_cpus rg; do
  printf "  %-12s  %-10s  %s core(s)  http://%s:8080\n" "$location" "$id" "$docker_cpus" "$ip"
done < "$STATE_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
