#!/usr/bin/env bash
# deploy-backend.sh — Provider-agnostic: copies source to any Linux host via
# SSH/SCP and starts the backend container with the specified CPU limit.
#
# Called by aws/launch.sh and azure/launch.sh — not intended for direct use.
#
# Required env vars:
#   PUBLIC_IP    — target host IP
#   KEY_FILE     — path to SSH private key (.pem for AWS, id_rsa for Azure)
#   SSH_USER     — ec2-user (AWS) | azureuser (Azure)
#   REGION       — region label for the backend
#   ID           — backend ID (e.g. backend-1)
#   DOCKER_CPUS  — CPU limit passed to docker run --cpus

set -euo pipefail

PUBLIC_IP="${PUBLIC_IP:?deploy-backend.sh: PUBLIC_IP not set}"
KEY_FILE="${KEY_FILE:?deploy-backend.sh: KEY_FILE not set}"
SSH_USER="${SSH_USER:-ec2-user}"
REGION="${REGION:-us-east-1}"
ID="${ID:-backend-1}"
DOCKER_CPUS="${DOCKER_CPUS:-1}"

SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=30"
REMOTE="$SSH_USER@$PUBLIC_IP"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "  [$ID] Packing source..."
tar -czf /tmp/inteliLB-src.tar.gz \
  -C "$PROJECT_ROOT" \
  --exclude='.git' \
  --exclude='*.docx' \
  --exclude='results.csv' \
  .

echo "  [$ID] Copying to $PUBLIC_IP..."
scp $SSH_OPTS /tmp/inteliLB-src.tar.gz "$REMOTE:/tmp/inteliLB-src.tar.gz"

echo "  [$ID] Building and starting backend (${DOCKER_CPUS} CPU(s))..."
ssh $SSH_OPTS "$REMOTE" bash <<REMOTE_SCRIPT
set -e

mkdir -p /opt/inteliLB
tar -xzf /tmp/inteliLB-src.tar.gz -C /opt/inteliLB

# Install Docker — detect package manager (dnf = AWS AL2023, apt = Ubuntu/Azure)
if ! command -v docker &>/dev/null; then
  if command -v dnf &>/dev/null; then
    sudo dnf install -y docker
  elif command -v apt-get &>/dev/null; then
    sudo apt-get update -y
    sudo apt-get install -y docker.io
  else
    echo "ERROR: no supported package manager found (dnf or apt-get)" >&2
    exit 1
  fi
  sudo systemctl enable docker
  sudo systemctl start docker
fi

# Stop any existing backend container
sudo docker rm -f inteliLB-backend 2>/dev/null || true

# Build and run with CPU limit
cd /opt/inteliLB
sudo docker build -f Dockerfile.backend -t inteliLB-backend .

sudo docker run -d \
  --name inteliLB-backend \
  --restart unless-stopped \
  --cpus="$DOCKER_CPUS" \
  -p 8080:8080 \
  -e REGION="$REGION" \
  -e ID="$ID" \
  inteliLB-backend

echo "Backend $ID started — ${DOCKER_CPUS} CPU(s), port 8080"
sudo docker ps --filter name=inteliLB-backend --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
REMOTE_SCRIPT

echo "  [$ID] Deploy complete — http://$PUBLIC_IP:8080  (${DOCKER_CPUS} CPU(s))"
