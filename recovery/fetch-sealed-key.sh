#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Disaster recovery — export the Sealed Secrets controller key
#
# The controller key is needed to decrypt SealedSecrets on a
# fresh cluster. Save it before you need it.
#
# Store:   saved to ../data/sealed-secrets-key.yaml (gitignored)
# Source:  Bitwarden item "kube sealed secrets key" (notes field)
# ─────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${REPO_ROOT}/data/sealed-secrets-key.yaml"

mkdir -p "$(dirname "$OUT")"

bw get notes "kube sealed secrets key" > "$OUT"

echo "Saved controller key to ${OUT}"
echo "  (gitignored — not committed)"
