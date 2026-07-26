#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# seal-ghcr-auth.sh — seal a new GHCR pull secret for aintcode
#
# Usage:
#   CR_PAT_READ=<token> ./apps/aintcode/scripts/seal-ghcr-auth.sh
#   ./apps/aintcode/scripts/seal-ghcr-auth.sh --token ghp_xxx
#   ./apps/aintcode/scripts/seal-ghcr-auth.sh --dry       # print only, no write
#   ./apps/aintcode/scripts/seal-ghcr-auth.sh --help
#
# Reads the token from CR_PAT_READ env var or --token flag.
# Output: apps/aintcode/k8s/sealed-ghcr-auth.yaml
# ─────────────────────────────────────────────────────────────

DRY_RUN=false
TOKEN=""

for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run) DRY_RUN=true ;;
    --token=*)       TOKEN="${arg#*=}" ;;
    --token)         echo "Use --token=VALUE"; exit 1 ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# ─/p' "$0" | sed 's/^# //;s/^#$//' | head -n -1
      exit 0
      ;;
  esac
done

TOKEN="${TOKEN:-${CR_PAT_READ:-}}"
if [ -z "$TOKEN" ]; then
  echo "✘ No token provided. Set CR_PAT_READ env var or pass --token=ghp_xxx" >&2
  exit 1
fi

# --- deps ---
command -v kubeseal >/dev/null 2>&1 || { echo "✘ kubeseal not found — brew install kubeseal"; exit 1; }
command -v kubectl >/dev/null 2>&1  || { echo "✘ kubectl not found"; exit 1; }

NAMESPACE="aintcode"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$SCRIPT_DIR/../k8s/sealed-ghcr-auth.yaml"

echo "==> Sealing ghcr pull secret with token: ${TOKEN:0:8}…"

kubectl create secret docker-registry ghcr-auth \
  --namespace "$NAMESPACE" \
  --docker-server=ghcr.io \
  --docker-username=luchev \
  --docker-password="$TOKEN" \
  --dry-run=client -o json \
| kubeseal --controller-name=sealed-secrets-controller \
           --controller-namespace=kube-system \
           --format yaml \
           > "$OUT"

echo "ok  wrote $OUT"

if [ "$DRY_RUN" = true ]; then
  echo "⚠  DRY RUN — file written but not committed."
  exit 0
fi

(cd "$SCRIPT_DIR/../.." && git add "$OUT" && git commit -m "chore: refresh sealed ghcr-auth" 2>&1 | head -2)
echo "ok  committed"
