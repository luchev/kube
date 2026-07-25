#!/usr/bin/env bash
set -euo pipefail

# Fetch k3s kubeconfig from a remote server and fix the server IP.
# Usage: ./get-remote-kubeconfig.sh <server-host>
# Example: ./get-remote-kubeconfig.sh 89.167.78.168

SERVER="${1:?Usage: $0 <server-host>}"
DEST="${2:-$(dirname "$0")/kubectl-config-hetzner}"

scp "root@$SERVER:/etc/rancher/k3s/k3s.yaml" "$DEST"

# The server's k3s.yaml has server: https://127.0.0.1:6443 — replace with real IP
sed -i 's|https://127.0.0.1:6443|https://'"$SERVER"':6443|' "$DEST"

echo "Saved to $DEST"
echo "Use:  kubectl --kubeconfig=$DEST get pods -n aintcode"
