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
REGISTRY="${REGISTRY:-ghcr.io/luchev/aintcode}"
KUBECONFIG="${KUBECONFIG:-}"
KIND_KUBECONFIG=""

# kube-test repo for Flux GitOps test
KUBE_TEST_REPO="${KUBE_TEST_REPO:-git@github.com:luchev/kube-test.git}"
KUBE_TEST_DIR="${KUBE_TEST_DIR:-$TEST_DIR/kube-test-work}"
KUBE_TEST_BRANCH="${KUBE_TEST_BRANCH:-main}"
KUBE_TEST_MANIFEST_PATH="${KUBE_TEST_MANIFEST_PATH:-apps/aintcode}"

# GitHub token for Flux HTTPS auth + git push
GITHUB_TOKEN="${GITHUB_TOKEN:-${GHCR_TOKEN:-}}"


# ── GHCR helpers ───────────────────────────────────────────

ghcr_login() {
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    fail "GITHUB_TOKEN or GHCR_TOKEN must be set for GHCR operations"
    return 1
  fi
  info "Logging into GHCR..."
  echo "$GITHUB_TOKEN" | docker login ghcr.io -u luchev --password-stdin >/dev/null 2>&1
  pass "GHCR login OK"
}

ghcr_pull_and_tag() {
  local src_tag="${1:-latest}"
  local dst_tag="${2:-$TEST_TAG}"
  info "Pulling images from GHCR (tag: $src_tag)..."
  docker pull "$REGISTRY/aintcode-server:$src_tag" >/dev/null
  docker pull "$REGISTRY/aintcode-web:$src_tag" >/dev/null
  docker tag "$REGISTRY/aintcode-server:$src_tag" "$REGISTRY/aintcode-server:$dst_tag"
  docker tag "$REGISTRY/aintcode-web:$src_tag" "$REGISTRY/aintcode-web:$dst_tag"
  pass "Images pulled and re-tagged as $dst_tag"
}

ghcr_push_tag() {
  local tag="${1:-$TEST_TAG}"
  info "Pushing test tag '$tag' to GHCR..."
  docker push "$REGISTRY/aintcode-server:$tag" >/dev/null
  docker push "$REGISTRY/aintcode-web:$tag" >/dev/null
  pass "Test tag '$tag' pushed to GHCR"
}

cleanup_ghcr_tag() {
  local tag="${1:-$TEST_TAG}"
  if command -v oras &>/dev/null && [[ -n "${GITHUB_TOKEN:-}" ]]; then
    info "Removing GHCR tag '$tag'..."
    ORAS_PASSWORD="$GITHUB_TOKEN" oras tag rm "$REGISTRY/aintcode-server:$tag" 2>/dev/null || true
    ORAS_PASSWORD="$GITHUB_TOKEN" oras tag rm "$REGISTRY/aintcode-web:$tag" 2>/dev/null || true
    pass "GHCR tags removed"
  else
    info "Skipping GHCR cleanup (oras not available or GITHUB_TOKEN not set)"
  fi
}


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


# ── Flux helpers ────────────────────────────────────────────

flux_install() {
  info "Installing Flux controllers..."
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

create_flux_sources() {
  local test_tag="${1:-$TEST_TAG}"
  local namespace="${2:-flux-system}"

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    fail "GITHUB_TOKEN is required for Flux GitRepository auth"
    return 1
  fi

  info "Creating GitHub token secret for Flux..."
  kubectl delete secret gh-token -n "$namespace" 2>/dev/null || true
  kubectl create secret generic gh-token -n "$namespace" \
    --from-literal=username=luchev \
    --from-literal=password="$GITHUB_TOKEN"
  pass "GitHub token secret created"

  info "Creating GitRepository for kube-test..."
  cat <<EOF | kubectl apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: kube-test
  namespace: $namespace
spec:
  interval: 30s
  ref:
    branch: $KUBE_TEST_BRANCH
  url: https://github.com/luchev/kube-test
  secretRef:
    name: gh-token
EOF

  info "Creating Kustomization for aintcode app..."
  cat <<EOF | kubectl apply -f -
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: aintcode
  namespace: $namespace
spec:
  interval: 30s
  path: ./$KUBE_TEST_MANIFEST_PATH
  prune: true
  sourceRef:
    kind: GitRepository
    name: kube-test
  patches:
    - patch: |
        - op: replace
          path: /spec/replicas
          value: 1
      target:
        kind: Deployment
    - patch: |
        - op: replace
          path: /spec/instances
          value: 1
      target:
        kind: Cluster
        name: postgres
EOF
  pass "Flux GitRepository + Kustomization created"
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
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
  pass "local-path StorageClass installed (default)"
}


# ── kube-test GitOps helpers ────────────────────────────────

kube_test_clone() {
  if [[ -d "$KUBE_TEST_DIR" ]]; then
    info "kube-test workdir exists, pulling latest..."
    git -C "$KUBE_TEST_DIR" pull --ff-only origin "$KUBE_TEST_BRANCH" 2>/dev/null || true
  else
    local clone_url="$KUBE_TEST_REPO"
    # Use HTTPS with token in CI (no SSH keys available)
    if [[ -n "${GITHUB_TOKEN:-}" && "$clone_url" == git@* ]]; then
      clone_url="https://luchev:${GITHUB_TOKEN}@github.com/luchev/kube-test.git"
    fi
    info "Cloning kube-test repo..."
    git clone --depth=1 --branch "$KUBE_TEST_BRANCH" "$clone_url" "$KUBE_TEST_DIR"
  fi
  pass "kube-test repo ready at $KUBE_TEST_DIR"
}

kube_test_update_tag() {
  local new_tag="${1:-$TEST_TAG_2}"
  local file="${2:-$KUBE_TEST_DIR/$KUBE_TEST_MANIFEST_PATH/server.yaml}"

  info "Updating image tag in kube-test manifests to '$new_tag'..."
  sed_i() { local f="$1"; shift; if [[ "$(uname)" == "Darwin" ]]; then sed -i '' "$@" "$f"; else sed -i "$@" "$f"; fi; }
  sed_i "$file" "s|image: $REGISTRY/aintcode-server:.*|image: $REGISTRY/aintcode-server:$new_tag|"
  sed_i "$KUBE_TEST_DIR/$KUBE_TEST_MANIFEST_PATH/web.yaml" \
    "s|image: $REGISTRY/aintcode-web:.*|image: $REGISTRY/aintcode-web:$new_tag|"
  pass "Image tag updated to $new_tag in kube-test manifests"
}

kube_test_commit_and_push() {
  local tag="${1:-$TEST_TAG_2}"
  info "Committing and pushing tag update to kube-test..."

  git -C "$KUBE_TEST_DIR" add -A
  git -C "$KUBE_TEST_DIR" commit -m "test: bump image tag to $tag [ci skip]"

  # Use token for push auth
  local remote_url
  remote_url="https://luchev:${GITHUB_TOKEN}@github.com/luchev/kube-test.git"
  git -C "$KUBE_TEST_DIR" push "$remote_url" "$KUBE_TEST_BRANCH" >/dev/null 2>&1
  pass "Tag update pushed to kube-test"
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
  return 1
}

wait_for_flux_kustomization() {
  local name="${1:-aintcode}"
  local namespace="${2:-flux-system}"
  local timeout="${3:-180}"
  local end=$((SECONDS + timeout))

  info "Waiting for Flux Kustomization '$name' to reconcile..."
  while [[ $SECONDS -lt $end ]]; do
    local ready
    ready=$(kubectl get kustomization.kustomize.toolkit.fluxcd.io "$name" \
      -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$ready" == "True" ]]; then
      pass "Flux Kustomization '$name' reconciled"
      return 0
    fi
    sleep 5
  done

  warn "Timeout waiting for Flux Kustomization '$name'"
  kubectl describe kustomization.kustomize.toolkit.fluxcd.io "$name" -n "$namespace" 2>/dev/null | tail -30
  return 1
}

wait_for_flux_image_update() {
  local expected_tag="${1:-$TEST_TAG_2}"
  local namespace="${2:-aintcode}"
  local timeout="${3:-180}"
  local end=$((SECONDS + timeout))

  info "Waiting for pods to roll out with tag '$expected_tag'..."
  while [[ $SECONDS -lt $end ]]; do
    local image
    image=$(kubectl get deployment server -n "$namespace" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    if echo "$image" | grep -q "$expected_tag"; then
      pass "Server deployment updated to $image"
      # Wait for actual rollout
      kubectl rollout status deployment/server -n "$namespace" --timeout=60s >/dev/null 2>&1 || true
      kubectl rollout status deployment/web -n "$namespace" --timeout=60s >/dev/null 2>&1 || true
      return 0
    fi
    sleep 10
  done

  warn "Timeout waiting for image tag '$expected_tag'"
  kubectl describe deployment server -n "$namespace" 2>/dev/null | grep -A5 "Image"
  return 1
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

verify_image_running() {
  local expected_tag="${1:-$TEST_TAG}"
  local namespace="${2:-aintcode}"

  info "Verifying running images have tag '$expected_tag':"
  local ok=true
  for dep in server web; do
    local image
    image=$(kubectl get deployment "$dep" -n "$namespace" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    if echo "$image" | grep -q "$expected_tag"; then
      pass "  $dep — $image"
    else
      fail "  $dep — $image (expected tag $expected_tag)"
      ok=false
    fi
  done
  $ok
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
