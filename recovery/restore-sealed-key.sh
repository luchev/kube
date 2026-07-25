#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Disaster recovery — restore the Sealed Secrets controller key
#
# Run this on a fresh cluster BEFORE applying any SealedSecret
# manifests. The controller picks up the key on startup.
#
# Prerequisites:
#   1. Sealed Secrets controller must be installed
#   2. Run ./fetch-sealed-key.sh first (saves key to data/)
# ─────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${REPO_ROOT}/data/sealed-secrets-key.yaml"

if [ ! -f "$KEY" ]; then
  echo "✘ Key file not found at ${KEY}"
  echo "  Run ./recovery/fetch-sealed-key.sh first"
  exit 1
fi

kubectl apply -f "$KEY"
echo ""
echo "Key restored. Controller will pick it up automatically."
echo "You can now apply SealedSecret manifests:"
echo "  kubectl apply -f apps/aintcode/k8s/sealed-server-env.yaml"
echo "  kubectl apply -f apps/aintcode/k8s/sealed-postgres-secret.yaml"
