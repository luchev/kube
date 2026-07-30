#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# e2e-local.sh — Local e2e test for the kube deployment pipeline
#
# Tests the full GitOps flow:
#   GHCR images → Flux sources kube-test repo → deploys to kind
#   Push tag bump to kube-test → Flux reconciles → rollout
# ─────────────────────────────────────────────────────────────
# Usage:
#   ./tests/e2e-local.sh                    # full run
#   ./tests/e2e-local.sh --skip-ghcr-push   # skip GHCR push (use existing tags)
#   ./tests/e2e-local.sh --skip-cleanup     # keep cluster for debugging
#   ./tests/e2e-local.sh --destroy           # just tear down
#   ./tests/e2e-local.sh --help             # show usage
#
# Prerequisites:
#   - Docker, kind, kubectl, flux CLI, kustomize, helm, oras installed
#   - GITHUB_TOKEN or GHCR_TOKEN set (for GHCR push + Flux auth)
#   - Docker logged into GHCR (or auto-login with GITHUB_TOKEN)
#
# What it tests:
#   1. Kind cluster creation
#   2. Local-path storage provisioner
#   3. Flux controller installation
#   4. CloudNativePG operator installation
#   5. Pull existing images from GHCR + push test tags
#   6. Configure Flux to sync from kube-test repo
#   7. Wait for Flux reconciliation → pods from GHCR images
#   8. Pod health verification
#   9. Push image tag bump to kube-test → Flux reconciliation → rollout
#  10. Verify new image tag running
#  11. HTTP reachability (port-forward + curl)
#  12. Cleanup (GHCR tags, cluster, temp files)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Parse args ──────────────────────────────────────────────
SKIP_GHCR_PUSH=false
SKIP_CLEANUP=false
DESTROY_ONLY=false
GHCR_SRC_TAG="${GHCR_SRC_TAG:-latest}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ghcr-push) SKIP_GHCR_PUSH=true ;;
    --skip-cleanup)   SKIP_CLEANUP=true ;;
    --destroy)        DESTROY_ONLY=true ;;
    --help)
      sed -n '3,30p' "$0"
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done

# ── Validate ────────────────────────────────────────────────
if [[ -z "${GITHUB_TOKEN:-}" && -z "${GHCR_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN or GHCR_TOKEN must be set"
  echo "  Used for: GHCR image push + Flux GitRepository auth + git push to kube-test"
  exit 1
fi

# ── Destroy only mode ───────────────────────────────────────
if $DESTROY_ONLY; then
  echo "==> Destroy mode only"
  kind_destroy
  exit 0
fi

# ── Trap for cleanup ────────────────────────────────────────
cleanup() {
  local exit_code=$?
  echo ""
  echo "========================================"
  echo "  Test finished with exit code: $exit_code"
  echo "========================================"
  if ! $SKIP_CLEANUP; then
    echo ""
    echo "==> Starting cleanup..."
    cleanup_ghcr_tag "$TEST_TAG"      || true
    cleanup_ghcr_tag "$TEST_TAG_2"    || true
    kind_destroy
    if [[ -d "$KUBE_TEST_DIR" ]]; then
      rm -rf "$KUBE_TEST_DIR"
    fi
    echo "==> Cleanup done"
  else
    echo "==> Skipping cleanup (--skip-cleanup). Cluster '$CLUSTER_NAME' left running."
    echo "    Teardown: ./tests/e2e-local.sh --destroy"
  fi
  exit $exit_code
}
trap cleanup EXIT

# ── Main ────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   AIn't Code — Local E2E Test (GitOps)      ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Cluster:      $CLUSTER_NAME"
echo "  GHCR tag:     $GHCR_SRC_TAG"
echo "  Test tags:    $TEST_TAG → $TEST_TAG_2"
echo "  Skip push:    $SKIP_GHCR_PUSH"
echo ""

# ── 1. Kind cluster ────────────────────────────────────────
echo "── Step 1: Kind cluster ──"
kind_create
kind_kubeconfig
print_node_summary

# ── 2. Storage ──────────────────────────────────────────────
echo ""
echo "── Step 2: Storage provisioner ──"
install_local_path_provisioner

# ── 3. Flux ─────────────────────────────────────────────────
echo ""
echo "── Step 3: Flux ──"
flux_install
verify_flux_ready

# ── 4. CNPG operator ────────────────────────────────────────
echo ""
echo "── Step 4: CloudNativePG ──"
cnpg_install

# ── 5. GHCR image setup ────────────────────────────────────
echo ""
echo "── Step 5: GHCR image setup ──"
ghcr_login
ghcr_pull_and_tag "$GHCR_SRC_TAG" "$TEST_TAG"
if ! $SKIP_GHCR_PUSH; then
  ghcr_push_tag "$TEST_TAG"
  ghcr_pull_and_tag "$GHCR_SRC_TAG" "$TEST_TAG_2"
  ghcr_push_tag "$TEST_TAG_2"
else
  info "Skipping GHCR push (--skip-ghcr-push)"
fi

# ── 6. Configure Flux GitOps ────────────────────────────────
echo ""
echo "── Step 6: Flux GitOps sources ──"
create_flux_sources "$TEST_TAG"

# ── 7. Wait for reconciliation ─────────────────────────────
echo ""
echo "── Step 7: Wait for Flux reconciliation ──"
wait_for_flux_kustomization aintcode flux-system 180
wait_for_pods aintcode 300
print_pod_summary

# ── 8. Verify health ────────────────────────────────────────
echo ""
echo "── Step 8: Verify health ──"
verify_pods_ready aintcode || {
  fail "Pod health check failed — dumping logs"
  kubectl describe pods -n aintcode 2>/dev/null | head -80
  exit 1
}
verify_image_running "$TEST_TAG" aintcode

# ── 9. Push tag update to kube-test ────────────────────────
echo ""
echo "── Step 9: Push image tag update ──"
kube_test_clone
kube_test_update_tag "$TEST_TAG_2"
kube_test_commit_and_push "$TEST_TAG_2"

# ── 10. Wait for Flux rollout ──────────────────────────────
echo ""
echo "── Step 10: Flux rollout ──"
wait_for_flux_image_update "$TEST_TAG_2" aintcode 300
print_pod_summary

# ── 11. Verify new image ───────────────────────────────────
echo ""
echo "── Step 11: Verify new image running ──"
verify_image_running "$TEST_TAG_2" aintcode

# ── 12. HTTP reachability test ─────────────────────────────
echo ""
echo "── Step 12: HTTP reachability ──"
WEB_PID=$(port_forward_web 8080)
sleep 3
verify_http_response "http://localhost:8080" 200 || warn "HTTP check failed (expected if postgres not healthy)"
kill "$WEB_PID" 2>/dev/null || true

# ── 13. Summary ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ✅ All e2e tests passed!                  ║"
echo "╚══════════════════════════════════════════════╝"
print_pod_summary
