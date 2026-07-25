#!/usr/bin/env bash
set -euo pipefail

# Deploy aintcode to a remote K3s server.
# Usage: ./scripts/deploy.sh <server-host>
# Example: ./scripts/deploy.sh 192.168.1.100
# Prerequisites:
#   - Server has k3s installed
#   - KUBECONFIG pointing at remote cluster
#   - SSH access to the server
#   - Images already pushed (run docker-push.sh in aintcode)

SERVER="${1:?Usage: $0 <server-host>}"

SCRIPT_DIR="$(dirname "$0")"
MANIFEST_DIR="$SCRIPT_DIR/../k8s/aintcode"

echo "==> Step 1: Copy manifests to server"
rsync -avz "$MANIFEST_DIR/" "$SERVER:~/aintcode-k8s/" 2>/dev/null || {
  echo "rsync failed — trying scp fallback"
  scp -r "$MANIFEST_DIR/" "$SERVER:~/aintcode-k8s/"
}

echo "==> Step 2: Apply on server"
ssh "$SERVER" bash -s <<'SSH'
  set -euo pipefail
  kubectl apply -f ~/aintcode-k8s/namespace.yaml 2>/dev/null || true
  kubectl apply -f ~/aintcode-k8s/
  echo ""
  echo "==> Waiting for pods..."
  kubectl wait --for=condition=ready pod -l app=postgres -n aintcode --timeout=60s
  kubectl wait --for=condition=ready pod -l app=server -n aintcode --timeout=60s
  kubectl wait --for=condition=ready pod -l app=web -n aintcode --timeout=60s
  echo ""
  kubectl get pods -n aintcode
  echo ""
  echo "==> Ingress status:"
  kubectl get ingress -n aintcode
SSH

echo ""
echo "Done. Point your domain's A record to the server IP and update the Ingress host."
