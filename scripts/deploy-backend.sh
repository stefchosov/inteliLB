#!/usr/bin/env bash
# deploy-backend.sh — Compiles backend locally for Linux, copies binary to a remote
# host via SSH/SCP, and starts it as a background process.
#
# Called by aws/launch.sh and azure/launch.sh — not intended for direct use.
#
# Required env vars:
#   PUBLIC_IP    — target host IP
#   KEY_FILE     — path to SSH private key (.pem for AWS, id_rsa for Azure)
#   SSH_USER     — ec2-user (AWS) | azureuser (Azure)
#   REGION       — region label for the backend
#   ID           — backend ID (e.g. backend-1)

set -euo pipefail

PUBLIC_IP="${PUBLIC_IP:?deploy-backend.sh: PUBLIC_IP not set}"
KEY_FILE="${KEY_FILE:?deploy-backend.sh: KEY_FILE not set}"
SSH_USER="${SSH_USER:-azureuser}"
REGION="${REGION:-us-east-1}"
ID="${ID:-backend-1}"

SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30"
REMOTE="$SSH_USER@$PUBLIC_IP"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="/tmp/inteliLB-backend"

echo "  [$ID] Building backend binary for linux/amd64..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$BINARY" "$PROJECT_ROOT/cmd/backend"

echo "  [$ID] Copying binary to $PUBLIC_IP..."
scp $SSH_OPTS "$BINARY" "$REMOTE:/tmp/inteliLB-backend"

# backend-1 is pinned to a single core to simulate 1-vCPU capacity;
# the VM is Standard_B2s but taskset limits it to core 0 only.
TASKSET_PREFIX=""
if [[ "$ID" == "backend-1" ]]; then
  TASKSET_PREFIX="taskset -c 0 "
fi

echo "  [$ID] Starting backend..."
ssh $SSH_OPTS "$REMOTE" bash <<REMOTE_SCRIPT
set -e
chmod +x /tmp/inteliLB-backend

pkill -f inteliLB-backend 2>/dev/null || true
sleep 1

nohup env REGION="$REGION" ID="$ID" ${TASKSET_PREFIX}/tmp/inteliLB-backend -port=8080 \
  > /tmp/inteliLB-backend.log 2>&1 &

echo "Backend $ID started on port 8080 (PID \$!)"
REMOTE_SCRIPT

echo "  [$ID] Deploy complete — http://$PUBLIC_IP:8080"
