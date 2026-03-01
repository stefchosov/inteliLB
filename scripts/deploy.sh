#!/usr/bin/env bash
# deploy.sh — Unified deployment dispatcher for inteliLB backends.
#
# Usage:
#   ./scripts/deploy.sh --provider aws   [--key-name KEY_PAIR_NAME] [--key-file PATH_TO_PEM]
#   ./scripts/deploy.sh --provider azure [--key-file PATH_TO_PUBLIC_KEY]
#   ./scripts/deploy.sh --provider aws   --teardown
#   ./scripts/deploy.sh --provider azure --teardown
#
# Defaults:
#   --key-name  inteliLB-key                (AWS key pair name)
#   --key-file  ~/.ssh/inteliLB-key.pem     (AWS) | ~/.ssh/id_rsa.pub (Azure)

set -euo pipefail

PROVIDER=""
TEARDOWN=false
KEY_NAME="inteliLB-key"
KEY_FILE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") --provider aws|azure [OPTIONS]

Options:
  --provider  aws|azure          Cloud provider (required)
  --teardown                     Destroy all inteliLB infrastructure
  --key-name  NAME               AWS EC2 key pair name      (default: inteliLB-key)
  --key-file  PATH               AWS: path to .pem file     (default: ~/.ssh/<key-name>.pem)
                                 Azure: path to public key  (default: ~/.ssh/id_rsa.pub)
  -h, --help                     Show this help

Examples:
  # Deploy to AWS
  ./scripts/deploy.sh --provider aws --key-name my-key --key-file ~/.ssh/my-key.pem

  # Deploy to Azure
  ./scripts/deploy.sh --provider azure --key-file ~/.ssh/id_rsa.pub

  # Tear down AWS infrastructure
  ./scripts/deploy.sh --provider aws --teardown

  # Tear down Azure infrastructure
  ./scripts/deploy.sh --provider azure --teardown
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)  PROVIDER="$2";  shift 2 ;;
    --teardown)  TEARDOWN=true;  shift   ;;
    --key-name)  KEY_NAME="$2";  shift 2 ;;
    --key-file)  KEY_FILE="$2";  shift 2 ;;
    -h|--help)   usage; exit 0           ;;
    *) echo "Error: unknown flag '$1'"; echo; usage; exit 1 ;;
  esac
done

if [[ -z "$PROVIDER" ]]; then
  echo "Error: --provider is required"
  echo
  usage
  exit 1
fi

if [[ "$PROVIDER" != "aws" && "$PROVIDER" != "azure" ]]; then
  echo "Error: --provider must be 'aws' or 'azure', got '$PROVIDER'"
  exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"

# Set default key file per provider
if [[ -z "$KEY_FILE" ]]; then
  if [[ "$PROVIDER" == "aws" ]]; then
    KEY_FILE="$HOME/.ssh/${KEY_NAME}.pem"
  else
    KEY_FILE="$HOME/.ssh/id_rsa.pub"
  fi
fi

export KEY_NAME KEY_FILE

if $TEARDOWN; then
  echo "Tearing down inteliLB infrastructure on $PROVIDER..."
  bash "$DIR/$PROVIDER/teardown.sh"
else
  echo "Deploying inteliLB backends on $PROVIDER..."
  bash "$DIR/$PROVIDER/launch.sh"
fi
