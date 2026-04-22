#!/usr/bin/env bash
# deploy.sh — Deploy or tear down inteliLB backends on Azure.
#
# Usage:
#   ./scripts/deploy.sh [--key-file PATH_TO_PUBLIC_KEY]
#   ./scripts/deploy.sh --teardown
#
# Default key file: ~/.ssh/id_rsa.pub

set -euo pipefail

TEARDOWN=false
KEY_FILE="$HOME/.ssh/id_rsa.pub"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --key-file  PATH   Path to SSH public key  (default: ~/.ssh/id_rsa.pub)
  --teardown         Destroy all inteliLB Azure infrastructure
  -h, --help         Show this help

Examples:
  ./scripts/deploy.sh
  ./scripts/deploy.sh --key-file ~/.ssh/id_rsa.pub
  ./scripts/deploy.sh --teardown
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --teardown) TEARDOWN=true; shift   ;;
    --key-file) KEY_FILE="$2"; shift 2 ;;
    -h|--help)  usage; exit 0          ;;
    *) echo "Error: unknown flag '$1'"; echo; usage; exit 1 ;;
  esac
done

export KEY_FILE

DIR="$(cd "$(dirname "$0")" && pwd)"

if $TEARDOWN; then
  echo "Tearing down inteliLB Azure infrastructure..."
  bash "$DIR/azure/teardown.sh"
else
  echo "Deploying inteliLB backends on Azure..."
  bash "$DIR/azure/launch.sh"
fi
