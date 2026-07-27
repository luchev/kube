#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# bootstrap-flux.sh — install Flux on a fresh cluster
# ─────────────────────────────────────────────────────────────
# Usage:
#   ./bootstrap-flux.sh --prod --ssh-key ~/.ssh/flux-deploy-key
#   ./bootstrap-flux.sh --dev   --ssh-key ~/.ssh/flux-deploy-key
#
# Flags:
#   --prod        Production overlay (nodeSelector pins to master node)
#   --dev         Dev overlay (no nodeSelector — works on any single node)
#   --ssh-key     Path to the SSH private key for GitHub auth (required)
#   --kubeconfig  Path to kubeconfig (optional, defaults to KUBECONFIG env or ~/.kube/config)
#   --help        Show this message
#
# What it does:
#   1. Applies Flux CRDs + controllers (clean, no nodeSelector hacks)
#   2. Creates the git-auth Secret from the provided SSH deploy key
#   3. Creates the GitRepository + Kustomization bootstrap resources
#   4. Flux takes it from there — reconciling from the repo
# ─────────────────────────────────────────────────────────────

usage() {
  sed -n '3,20p' "$0"
  exit 0
}

# ── Parse args ───────────────────────────────────────────────
MODE=""
SSH_KEY=""
KUBECONFIG="${KUBECONFIG:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod) MODE="prod" ;;
    --dev)  MODE="dev" ;;
    --ssh-key) shift; SSH_KEY="$1" ;;
    --kubeconfig) shift; KUBECONFIG="$1" ;;
    --help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: specify --prod or --dev"
  usage
fi

if [[ -z "$SSH_KEY" ]]; then
  echo "ERROR: --ssh-key is required"
  usage
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH key not found at $SSH_KEY"
  exit 1
fi

KUBECTL=(kubectl)
if [[ -n "$KUBECONFIG" ]]; then
  KUBECTL+=(--kubeconfig "$KUBECONFIG")
fi

# Detect kustomize (use kubectl kustomize as fallback)
if command -v kustomize &>/dev/null; then
  KUSTOMIZE=(kustomize)
elif "${KUBECTL[@]}" kustomize --help &>/dev/null; then
  KUSTOMIZE=("${KUBECTL[@]}" kustomize)
else
  echo "ERROR: neither 'kustomize' nor 'kubectl kustomize' is available"
  exit 1
fi

echo "==> Flux bootstrap — mode: $MODE"

# ── Resolve paths ────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
OVERLAY="$REPO_ROOT/flux/overlays/$MODE"
GOTK_SYNC="$OVERLAY/gotk-sync.yaml"
KNOWN_HOSTS="$REPO_ROOT/flux/known_hosts"

# ── Step 1: Apply Flux components (kustomize build → apply) ──
echo "==> Step 1: Installing Flux CRDs + controllers"
"${KUSTOMIZE[@]}" build "$OVERLAY" | "${KUBECTL[@]}" apply -f -

# ── Step 2: Wait for controllers ─────────────────────────────
echo "==> Step 2: Waiting for Flux controllers to be ready"
for ctrl in source-controller kustomize-controller helm-controller notification-controller; do
  "${KUBECTL[@]}" wait --for=condition=available deployment/"$ctrl" -n flux-system --timeout=120s 2>/dev/null || {
    echo "WARNING: $ctrl not ready yet — continuing (may need manual check)"
  }
done

# ── Step 3: Create git auth Secret ───────────────────────────
echo "==> Step 3: Creating git auth Secret"
if [[ ! -f "$KNOWN_HOSTS" ]]; then
  echo "Generating known_hosts entry for github.com..."
  ssh-keyscan github.com > "$KNOWN_HOSTS" 2>/dev/null || {
    echo "ERROR: could not generate known_hosts for github.com"
    exit 1
  }
fi

if ! "${KUBECTL[@]}" get secret -n flux-system flux-system &>/dev/null; then
  "${KUBECTL[@]}" create secret generic flux-system \
    -n flux-system \
    --from-file=identity="$SSH_KEY" \
    --from-file=identity.pub="$SSH_KEY.pub" \
    --from-file=known_hosts="$KNOWN_HOSTS"
  echo "Secret flux-system created."
else
  echo "Secret flux-system already exists — updating."
  "${KUBECTL[@]}" create secret generic flux-system \
    -n flux-system \
    --from-file=identity="$SSH_KEY" \
    --from-file=identity.pub="$SSH_KEY.pub" \
    --from-file=known_hosts="$KNOWN_HOSTS" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
fi

# ── Step 4: Create bootstrap resources ───────────────────────
echo "==> Step 4: Applying bootstrap GitRepository + Kustomization"
"${KUBECTL[@]}" apply -f "$GOTK_SYNC"

echo ""
echo "==> Done! Flux is bootstrapped in $MODE mode."
echo "    GitRepository: ssh://git@github.com/luchev/kube.git"
echo "    Kustomization path: ./flux/overlays/$MODE"
echo ""
echo "    Check status:  ${KUBECTL[*]} get pods -n flux-system"
echo "    Watch logs:    ${KUBECTL[*]} logs -n flux-system deployment/source-controller -f"
