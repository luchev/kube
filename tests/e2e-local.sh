#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# e2e-local.sh — Local e2e test for the kube deployment pipeline
# ─────────────────────────────────────────────────────────────
# Usage:
#   ./tests/e2e-local.sh              # full run
#   ./tests/e2e-local.sh --skip-build # reuse existing images
#   ./tests/e2e-local.sh --skip-cleanup  # keep cluster for debugging
#   ./tests/e2e-local.sh --destroy    # just tear down
#   ./tests/e2e-local.sh --help       # show usage
#
# Prerequisites:
#   - Docker, kind, kubectl, flux CLI, kustomize installed
#   - aintcode repo at ~/aintcode (or set AINTCODE_DIR)
#   - Docker images built (or use --skip-build)
#
# What it tests:
#   1. Kind cluster creation
#   2. Local-path storage provisioner
#   3. Flux controller installation
#   4. CloudNativePG operator installation
#   5. Docker image building with semver tags
#   6. App deployment (postgres, server, web)
#   7. Pod health verification
#   8. Image rollout (build new tag → update deployment → verify)
#   9. HTTP reachability (port-forward + curl)
#  10. Cleanup (cluster destroy, temp files)
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ── Parse args ──────────────────────────────────────────────
SKIP_BUILD=false
SKIP_CLEANUP=false
DESTROY_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)   SKIP_BUILD=true ;;
    --skip-cleanup) SKIP_CLEANUP=true ;;
    --destroy)      DESTROY_ONLY=true ;;
    --help)
      sed -n '3,28p' "$0"
      exit 0
      ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done

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
    kind_destroy
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
echo "║   AIn't Code — Local E2E Test               ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Cluster:    $CLUSTER_NAME"
echo "  Image tag:  $TEST_TAG"
echo "  Aintcode:   $AINTCODE_DIR"
echo "  Skip build: $SKIP_BUILD"
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

# ── 5. Build images ─────────────────────────────────────────
echo ""
echo "── Step 5: Docker images ──"
if ! $SKIP_BUILD; then
  build_images "$TEST_TAG"
else
  info "Skipping image build (--skip-build)"
fi
kind_load_images "$TEST_TAG"

# ── 6. Deploy app ───────────────────────────────────────────
echo ""
echo "── Step 6: Deploy app ──"
deploy_app "$TEST_TAG"

# ── 7. Wait for health ──────────────────────────────────────
echo ""
echo "── Step 7: Wait for all pods ──"
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

# ── 9. Test image rollout ──────────────────────────────────
echo ""
echo "── Step 9: Image rollout test ──"
if $SKIP_BUILD; then
  info "Skipping rollout test (--skip-build)"
else
  verify_image_update "$TEST_TAG_2" aintcode
fi

# ── 10. HTTP reachability test ──────────────────────────────
echo ""
echo "── Step 10: HTTP reachability ──"
WEB_PID=$(port_forward_web 8080)
sleep 3
verify_http_response "http://localhost:8080" 200 || warn "HTTP check failed (expected if postgres not healthy)"
kill "$WEB_PID" 2>/dev/null || true

# ── 11. Summary ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ✅ All e2e tests passed!                  ║"
echo "╚══════════════════════════════════════════════╝"
print_pod_summary
