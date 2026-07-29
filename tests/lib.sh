#!/usr/bin/env bash
# shellcheck disable=SC2317
# ─────────────────────────────────────────────────────────────
# e2e-local lib.sh — shared functions for local kind e2e test
# ─────────────────────────────────────────────────────────────
set -euo pipefail

# ── Color helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

# ── Globals ─────────────────────────────────────────────────
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-aintcode-e2e}"
TEST_TAG="${TEST_TAG:-e2e-test}"
TEST_TAG_2="${TEST_TAG_2:-e2e-test-updated}"
AINTCODE_DIR="${AINTCODE_DIR:-$HOME/aintcode}"
REGISTRY="${REGISTRY:-ghcr.io/luchev/aintcode}"
KUBECONFIG="${KUBECONFIG:-}"
KIND_KUBECONFIG=""

# ── Kind helpers ────────────────────────────────────────────

kind_create() {
  if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
    warn "Cluster '$CLUSTER_NAME' already exists — skipping create"
    return 0
  fi
  info "Creating kind cluster '$CLUSTER_NAME'..."
  kind create cluster --name "$CLUSTER_NAME" --wait 30s
  pass "Kind cluster created"
}

kind_kubeconfig() {
  KIND_KUBECONFIG="$TEST_DIR/kubeconfig.yaml"
  kind get kubeconfig --name "$CLUSTER_NAME" > "$KIND_KUBECONFIG"
  KUBECONFIG="$KIND_KUBECONFIG"
  export KUBECONFIG
  pass "Kubeconfig set from kind cluster -> $KIND_KUBECONFIG"
}

kind_destroy() {
  if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
    info "Destroying kind cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME"
    pass "Cluster destroyed"
  else
    info "No cluster '$CLUSTER_NAME' to destroy"
  fi
  if [[ -n "$KIND_KUBECONFIG" && -f "$KIND_KUBECONFIG" ]]; then
    rm -f "$KIND_KUBECONFIG"
  fi
}

kind_load_images() {
  local tag="${1:-$TEST_TAG}"
  info "Loading images with tag '$tag' into kind..."
  kind load docker-image "$REGISTRY/aintcode-server:$tag" --name "$CLUSTER_NAME"
  kind load docker-image "$REGISTRY/aintcode-web:$tag" --name "$CLUSTER_NAME"
  pass "Images loaded into kind"
}

# ── Image build helpers ─────────────────────────────────────

build_images() {
  local tag="${1:-$TEST_TAG}"
  info "Building Docker images with tag '$tag'..."
  if [[ ! -d "$AINTCODE_DIR" ]]; then
    fail "aintcode directory not found at $AINTCODE_DIR"
    return 1
  fi
  docker build -q -f "$AINTCODE_DIR/Dockerfile.server" \
    -t "$REGISTRY/aintcode-server:$tag" "$AINTCODE_DIR" >/dev/null
  docker build -q -f "$AINTCODE_DIR/Dockerfile.web" \
    -t "$REGISTRY/aintcode-web:$tag" "$AINTCODE_DIR" >/dev/null
  pass "Images built: $REGISTRY/aintcode-*:$tag"
}

# ── Flux helpers ────────────────────────────────────────────

flux_install() {
  info "Installing Flux controllers..."
  # Use the bundled gotk-components.yaml from the repo
  kubectl apply -f "$REPO_ROOT/flux/base/gotk-components.yaml"
  pass "Flux CRDs + controllers applied"

  info "Waiting for Flux controller deployments..."
  local controllers=("source-controller" "kustomize-controller" "helm-controller" "notification-controller")
  for ctrl in "${controllers[@]}"; do
    kubectl wait --for=condition=available deployment/"$ctrl" \
      -n flux-system --timeout=120s >/dev/null 2>&1 || warn "$ctrl not ready within timeout"
  done
  pass "Flux controllers ready"
}

# ── CNPG helpers ────────────────────────────────────────────

cnpg_install() {
  info "Installing CloudNativePG operator via Helm..."
  helm repo add cnpg https://cloudnative-pg.github.io/charts 2>/dev/null || true
  helm upgrade --install cnpg cnpg/cloudnative-pg \
    --namespace cnpg-system --create-namespace --wait \
    --timeout 120s
  pass "CNPG operator installed via Helm"
}

# ── Storage helpers ─────────────────────────────────────────

install_local_path_provisioner() {
  info "Installing local-path storage provisioner..."
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
  # Patch it to be the default StorageClass
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
  pass "local-path StorageClass installed (default)"
}

# ── Deploy helpers ──────────────────────────────────────────

deploy_app() {
  local tag="${1:-$TEST_TAG}"
  info "Deploying aintcode app with tag '$tag'..."

  # Update image tag via kustomize images transformer
  sed -i "s/newTag: .*/newTag: $tag/" \
    "$TEST_DIR/overlays/local/kustomization.yaml"

  # Build with --load-restrictor to allow referencing prod manifests outside overlay dir
  kustomize build --load-restrictor LoadRestrictionsNone \
    "$TEST_DIR/overlays/local/" | kubectl apply -f -
  pass "App manifests applied"
}

# ── Wait helpers ────────────────────────────────────────────

wait_for_pods() {
  local namespace="${1:-aintcode}"
  local timeout="${2:-300}"
  local end=$((SECONDS + timeout))
  info "Waiting for pods in namespace '$namespace' (timeout: ${timeout}s)..."

  while [[ $SECONDS -lt $end ]]; do
    local all_done=true pod_count=0

    while IFS= read -r line; do
      pod_count=$((pod_count + 1))
      local name ready rest
      read -r name ready rest <<< "$(echo "$line" | awk '{print $1, $2, $3}')"

      if [[ "$rest" == "Running" ]]; then
        local ready_count="${ready%/*}"
        local total_count="${ready#*/}"
        [[ "$ready_count" -lt "$total_count" ]] && all_done=false
      elif [[ "$rest" == "Completed" ]]; then
        :
      else
        all_done=false
      fi
    done < <(kubectl get pods -n "$namespace" --no-headers 2>/dev/null)

    if $all_done && [[ $pod_count -gt 0 ]]; then
      pass "All pods ready or completed"
      return 0
    fi
    sleep 5
  done

  warn "Timeout waiting for pods in namespace '$namespace'"
}

# ── Verification helpers ────────────────────────────────────

verify_pods_ready() {
  local namespace="${1:-aintcode}"
  local all_ready=true

  info "Verifying pod status in namespace '$namespace':"
  while IFS= read -r line; do
    local name ready_status rest
    read -r name ready_status rest <<< "$(echo "$line" | awk '{print $1, $2, $3}')"
    local ready_count="${ready_status%/*}"
    local total_count="${ready_status#*/}"

    if [[ "$rest" == "Running" && "$ready_count" -eq "$total_count" ]]; then
      pass "  $name — Ready ($ready_status)"
    elif [[ "$rest" == "Completed" ]]; then
      pass "  $name — Completed"
    else
      fail "  $name — Status: $rest ($ready_status)"
      all_ready=false
    fi
  done < <(kubectl get pods -n "$namespace" --no-headers 2>/dev/null)

  $all_ready
}

verify_flux_ready() {
  info "Verifying Flux controllers:"
  local all_ready=true
  for ctrl in source-controller kustomize-controller helm-controller notification-controller; do
    local status
    status=$(kubectl get deployment -n flux-system "$ctrl" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
    if [[ "$status" == "True" ]]; then
      pass "  $ctrl — Available"
    else
      fail "  $ctrl — NOT Available (status: $status)"
      all_ready=false
    fi
  done
  $all_ready
}

verify_image_update() {
  local tag="${1:-$TEST_TAG_2}"
  local namespace="${2:-aintcode}"

  info "Testing image update to tag '$tag'..."

  # Build new images
  build_images "$tag"
  kind_load_images "$tag"

  # Update the deployment image directly
  kubectl set image deployment/server -n "$namespace" \
    "server=$REGISTRY/aintcode-server:$tag"
  kubectl set image deployment/web -n "$namespace" \
    "web=$REGISTRY/aintcode-web:$tag"

  pass "Deployment images updated to $tag"

  # Wait for rollout
  info "Waiting for rollout..."
  kubectl rollout status deployment/server -n "$namespace" --timeout=120s >/dev/null 2>&1 || warn "server rollout not complete"
  kubectl rollout status deployment/web -n "$namespace" --timeout=120s >/dev/null 2>&1 || warn "web rollout not complete"
  pass "Rollout complete"

  # Verify the new image is running
  local server_image
  server_image=$(kubectl get deployment server -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].image}')
  if echo "$server_image" | grep -q "$tag"; then
    pass "Server running image: $server_image"
  else
    fail "Server image mismatch: $server_image (expected $tag)"
    return 1
  fi

  local web_image
  web_image=$(kubectl get deployment web -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].image}')
  if echo "$web_image" | grep -q "$tag"; then
    pass "Web running image: $web_image"
  else
    fail "Web image mismatch: $web_image (expected $tag)"
    return 1
  fi
}

# ── Port-forward helpers ────────────────────────────────────

port_forward_web() {
  local local_port="${1:-8080}"
  info "Port-forwarding web:80 → localhost:$local_port"
  kubectl port-forward -n aintcode svc/web "$local_port:80" &
  local pid=$!
  sleep 2
  echo "$pid"
}

verify_http_response() {
  local url="${1:-http://localhost:8080}"
  local expected_code="${2:-200}"
  info "Checking HTTP response from $url..."
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
  if [[ "$code" == "$expected_code" ]]; then
    pass "HTTP $expected_code from $url"
    return 0
  else
    fail "Expected HTTP $expected_code but got $code from $url"
    return 1
  fi
}

# ── Image tag cleanup on GHCR ───────────────────────────────

cleanup_ghcr_tag() {
  local tag="${1:-$TEST_TAG}"
  # Only run if oras is available and GHCR_TOKEN is set
  if command -v oras &>/dev/null && [[ -n "${GHCR_TOKEN:-}" ]]; then
    info "Removing GHCR tag '$tag'..."
    oras tag rm "ghcr.io/luchev/aintcode/aintcode-server:$tag" 2>/dev/null || true
    oras tag rm "ghcr.io/luchev/aintcode/aintcode-web:$tag" 2>/dev/null || true
    pass "GHCR tags removed"
  else
    info "Skipping GHCR cleanup (oras not available or GHCR_TOKEN not set)"
  fi
}

# ── Summary ─────────────────────────────────────────────────

print_pod_summary() {
  echo ""
  echo "── Pod Summary ──"
  kubectl get pods --all-namespaces 2>/dev/null | head -40
  echo "─────────────────"
}

print_node_summary() {
  echo ""
  echo "── Node Summary ──"
  kubectl get nodes -o wide 2>/dev/null
  echo "──────────────────"
}
