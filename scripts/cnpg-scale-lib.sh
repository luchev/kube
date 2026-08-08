#!/usr/bin/env bash
# Shared helpers for the CNPG scale-down/up dance used by drain-node.sh and
# add-node.sh.
#
# Why git + Flux instead of kubectl patch:
#   - The postgres Cluster CR is managed by Flux GitOps (apps/aintcode/k8s).
#     Manual `kubectl patch spec.instances` gets reverted within ~30s by the
#     aintcode kustomization.
#   - Scaling through git is also the ONLY clean recovery: scale down → the
#     operator forgets the instance → scale up → it creates a real join pod
#     (pg_basebackup) instead of a plain `instance run` on an empty PVC.
#
# Sourced by drain-node.sh / add-node.sh. Requires kubectl + flux CLI on PATH
# and KUBECONFIG exported (the caller sets both). Uses the K3S_KUBECONFIG
# convention: KUBECONFIG defaults to ./kubectl-config-hetzner in the repo root.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$REPO_DIR/kubectl-config-hetzner}"
export KUBECONFIG

# Marker file recording which clusters were scaled down (and their original
# instance count) by drain-node.sh, so add-node.sh can scale them back up.
SCALE_MARKER="$REPO_DIR/.cnpg-scale-back"

# Name of the Flux kustomization that manages the given app directory.
# e.g. apps/aintcode/k8s -> aintcode
cnpg_kustomization() {
  local app
  app="$(echo "$1" | sed -n 's#.*/apps/\([^/]*\)/k8s/.*#\1#p')"
  [ -n "$app" ] || { echo "ERROR: cannot derive kustomization name from path $1" >&2; exit 1; }
  echo "$app"
}

# Manifest file for a CNPG cluster in the Flux repo. Expects
# apps/*/k8s/*.yaml containing `kind: Cluster` with matching name.
cnpg_manifest() {
  local name="$1" f
  for f in "$REPO_DIR"/apps/*/k8s/*.yaml; do
    [ -f "$f" ] || continue
    if grep -q '^kind: Cluster' "$f" && grep -q "^  name: $name\$" "$f"; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# Replace `instances: N` with the given count in a manifest.
cnpg_set_instances() {
  local manifest="$1" count="$2"
  sed -i.bak "s/^  instances: [0-9]*/  instances: $count/" "$manifest"
  rm -f "$manifest.bak"
  grep -q "^  instances: $count\$" "$manifest" || {
    echo "ERROR: failed to set instances: $count in $manifest" >&2
    exit 1
  }
}

# Commit the manifest change and push; then tell Flux to reconcile it.
# Rebase first: remote may have moved (CI image bumps, other commits).
cnpg_apply_scale() {
  local manifest="$1" msg="$2"
  git -C "$REPO_DIR" add "$manifest"
  git -C "$REPO_DIR" commit -m "$msg"
  git -C "$REPO_DIR" pull --rebase --autostash origin main >/dev/null 2>&1 || true
  git -C "$REPO_DIR" push origin main
  flux reconcile source git flux-system
  flux reconcile kustomization "$(cnpg_kustomization "$manifest")"
}

# Wait until a CNPG cluster reports all instances ready (status.instances ==
# status.readyInstances). Timeout in seconds. Exits 1 on timeout.
cnpg_wait_ready() {
  local ns="$1" cluster="$2" timeout="$3"
  local deadline=$((SECONDS + timeout)) instances ready spec
  spec=$(kubectl get cluster "$cluster" -n "$ns" -o jsonpath='{.spec.instances}' 2>/dev/null || true)
  echo "==> CNPG $ns/$cluster: waiting for all $spec instances ready (${timeout}s)..."
  while [ $SECONDS -lt "$deadline" ]; do
    instances=$(kubectl get cluster "$cluster" -n "$ns" -o jsonpath='{.status.instances}' 2>/dev/null || true)
    ready=$(kubectl get cluster "$cluster" -n "$ns" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)
    # require status to have reached the spec target: status trails spec
    # during scale-up, so a self-consistent 1/1 would falsely pass mid-scale
    [ "$instances" = "$spec" ] && [ "$ready" = "$instances" ] && {
      echo "  OK: $ns/$cluster $ready/$instances instances ready"
      return 0
    }
    sleep 10
  done
  echo "  TIMEOUT: $ns/$cluster spec=$spec instances=$instances ready=$ready" >&2
  return 1
}

# Wait until every replica is streaming with 0 WAL lag — proof the new
# instance recovered all data from the primary. Timeout in seconds.
cnpg_wait_caught_up() {
  local ns="$1" cluster="$2" timeout="$3"
  local deadline=$((SECONDS + timeout)) primary lag0 need
  need=$(kubectl get cluster "$cluster" -n "$ns" -o jsonpath='{.spec.instances}' 2>/dev/null || true)
  echo "==> CNPG $ns/$cluster: waiting for replica(s) to catch up (${timeout}s)..."
  while [ $SECONDS -lt "$deadline" ]; do
    primary=$(kubectl get cluster "$cluster" -n "$ns" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
    if [ -n "$primary" ]; then
      lag0=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -tA -c \
        "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)=0" 2>/dev/null | tr -d '[:space:]' || true)
      [ -n "$lag0" ] && [ "$lag0" -ge $((need - 1)) ] && {
        echo "  OK: $ns/$cluster $lag0/$((need - 1)) replicas caught up (0 lag)"
        return 0
      }
    fi
    sleep 10
  done
  echo "  TIMEOUT: $ns/$cluster replicas not caught up (lag0=$lag0 need=$((need - 1)))" >&2
  return 1
}
