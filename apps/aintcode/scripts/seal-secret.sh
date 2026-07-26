#!/usr/bin/env bash
set -euo pipefail

command -v kubeseal >/dev/null 2>&1 || { echo "kubeseal not found — brew install kubeseal"; exit 1; }
command -v kubectl >/dev/null 2>&1  || { echo "kubectl not found"; exit 1; }

echo "==> SealedSecret generator"
echo ""

read -p "Secret name: " NAME
read -p "Namespace [default]: " NAMESPACE
NAMESPACE=${NAMESPACE:-default}

echo "Secret type:"
echo "  1) generic (key=value)"
echo "  2) docker-registry"
read -p "Choice [1]: " TYPE_CHOICE
TYPE_CHOICE=${TYPE_CHOICE:-1}

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

if [ "$TYPE_CHOICE" = "2" ]; then
  read -p "Registry server [ghcr.io]: " SERVER
  SERVER=${SERVER:-ghcr.io}
  read -p "Username: " USERNAME
  read -s -p "Password/token: " PASSWORD
  echo ""
  kubectl create secret docker-registry "$NAME" \
    --namespace "$NAMESPACE" \
    --docker-server="$SERVER" \
    --docker-username="$USERNAME" \
    --docker-password="$PASSWORD" \
    --dry-run=client -o json > "$TMP"
else
  read -p "Key (e.g. SMTP_PASS): " KEY
  read -s -p "Value: " VALUE
  echo ""
  kubectl create secret generic "$NAME" \
    --namespace "$NAMESPACE" \
    --from-literal="$KEY=$VALUE" \
    --dry-run=client -o json > "$TMP"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/../k8s/sealed-${NAME}.yaml"
kubeseal --controller-name=sealed-secrets-controller \
         --controller-namespace=kube-system \
         --format yaml \
         < "$TMP" > "$OUT"

echo "ok  wrote $OUT"
