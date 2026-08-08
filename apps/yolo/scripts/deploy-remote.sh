#!/usr/bin/env bash
set -euo pipefail

# Deploy yolo to a remote K3s server.
# Usage: ./scripts/deploy-remote.sh <server-host>
# Example: ./scripts/deploy-remote.sh 192.168.1.100
# Prerequisites:
#   - Server has k3s installed
#   - KUBECONFIG pointing at remote cluster
#   - SSH access to the server
#   - Images already pushed (image workflow in GitHub Actions)

SERVER="${1:?Usage: $0 <server-host>}"

SCRIPT_DIR="$(dirname "$0")"
MANIFEST_DIR="$SCRIPT_DIR/../k8s"

echo "==> Step 1: Copy manifests to server"
rsync -avz "$MANIFEST_DIR/" "$SERVER:~/yolo-k8s/" 2>/dev/null || {
  echo "rsync failed — trying scp fallback"
  scp -r "$MANIFEST_DIR/" "$SERVER:~/yolo-k8s/"
}

echo "==> Step 2: Apply on server"
ssh "$SERVER" bash -s <<'SSH'
  set -euo pipefail
  kubectl apply -f ~/yolo-k8s/namespace.yaml 2>/dev/null || true
  kubectl apply -f ~/yolo-k8s/
  echo ""
  echo "==> Waiting for pods..."
  kubectl wait --for=condition=ready pod -l app=yolo -n yolo --timeout=60s
  echo ""
  kubectl get pods -n yolo
SSH

echo ""
echo "Done. Collected data lands in the yolo-data PVC (5Gi, local-path)."
