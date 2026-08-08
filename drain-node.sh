#!/usr/bin/env bash
set -euo pipefail

# Drain a K3s node: cordon it and evict all workloads so they reschedule
# onto other nodes. Waits until every workload is running elsewhere before
# declaring the node ready to be evicted. Does NOT delete the node from the
# cluster or touch the machine itself. Node stays cordoned when done.
#
# Usage: ./drain-node.sh <node-name-or-ip>
# Example: ./drain-node.sh ubuntu-4gb-nbg1-1   # or 10.0.0.3

NODE="${1:?Usage: $0 <node-name-or-ip>}"
KUBECONFIG="${KUBECONFIG:-$(dirname "$0")/kubectl-config-hetzner}"
export KUBECONFIG

kubectl() { command kubectl --kubeconfig="$KUBECONFIG" "$@"; }

# CNPG scale-down/up helpers (git + Flux based — kubectl patches get reverted)
source "$(dirname "$0")/scripts/cnpg-scale-lib.sh"

# Accept an IP: resolve to node name via INTERNAL-IP column
if [[ "$NODE" =~ ^[0-9a-f.:]+$ ]]; then
  RESOLVED=$(kubectl get nodes -o wide --no-headers | awk -v ip="$NODE" '$6 == ip {print $1; exit}')
  [ -n "$RESOLVED" ] || { echo "ERROR: no node has IP $NODE"; exit 1; }
  echo "==> $NODE = $RESOLVED"
  NODE="$RESOLVED"
fi

kubectl get node "$NODE" >/dev/null 2>&1 || { echo "ERROR: node '$NODE' not in cluster"; exit 1; }
[ "$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}')" != true ] || {
  echo "ERROR: $NODE is already cordoned (stuck previous drain?). Uncordon first: kubectl uncordon $NODE"
  exit 1
}

# CNPG clusters with an instance on this node: scale them down via git + Flux
# BEFORE draining. Out-of-band PVC deletion (the old approach) leaves the
# operator wedged — it keeps recreating plain `instance run` pods on empty
# PVCs. A git scale-down makes the operator forget the instance, so the later
# scale-up (add-node.sh) creates a proper join pod. add-node.sh restores the
# recorded instance count.
cnpg_scale_down_on_node() {
  local pods podref ns pod cluster manifest current target
  pods=$(kubectl get pods -A -l cnpg.io/podRole=instance -o wide --no-headers 2>/dev/null | awk -v n="$NODE" '$8 == n {print $1 "/" $2}')
  [ -z "$pods" ] && return 0
  for podref in $pods; do
    ns="${podref%/*}"; pod="${podref#*/}"
    cluster=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.metadata.labels.cnpg\.io/cluster}' 2>/dev/null || true)
    [ -z "$cluster" ] && continue
    manifest=$(cnpg_manifest "$cluster") || { echo "ERROR: no Flux manifest for CNPG cluster $cluster"; exit 1; }
    current=$(kubectl get cluster "$cluster" -n "$ns" -o jsonpath='{.spec.instances}')
    [ "$current" -le 1 ] && { echo "==> CNPG $ns/$cluster already at 1 instance, nothing to scale down"; continue; }
    target=$((current - 1))
    echo "==> Scaling CNPG $ns/$cluster down to $target instance(s) (git + Flux)"
    cnpg_set_instances "$manifest" "$target"
    cnpg_apply_scale "$manifest" "drain-node: scale $cluster to $target instance(s) before draining $NODE"
    cnpg_wait_ready "$ns" "$cluster" 300 || { echo "ERROR: $ns/$cluster not healthy at $target instances after 300s"; exit 1; }
    echo "$ns/$cluster $current" >> "$SCALE_MARKER"
  done
}
cnpg_scale_down_on_node

# Snapshot what's scheduled here, excluding daemonsets (they never leave)
BEFORE=$(kubectl get pods -A -o wide --no-headers |
  awk -v n="$NODE" '$8 == n && $2 !~ /^(svclb-|kube-router-)/ {print $2}')
COUNT=$(echo "$BEFORE" | sed '/^$/d' | wc -l | tr -d ' ')

if echo "$BEFORE" | grep -q '^postgres-'; then
  echo "NOTE: CNPG postgres was scaled down above — no postgres pods should be drained"
fi

# local-path PVCs are node-pinned (PV nodeAffinity). Once this node leaves
# the cluster, workloads using them can never reschedule — the PV points at
# a dead node. Surface them now so they can be cleaned up after the drain.
ORPHANS=""
for pv in $(kubectl get pv --no-headers -o custom-columns=NAME:.metadata.name); do
  node=$(kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null)
  [ "$node" = "$NODE" ] || continue
  claim=$(kubectl get pv "$pv" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}')
  ORPHANS="$ORPHANS $pv:$claim"
done
if [ -n "$ORPHANS" ]; then
  echo "==> local-path PVCs pinned to $NODE (unreachable after node removal):"
  for o in $ORPHANS; do
    echo "  ${o#*:} (PV ${o%%:*})"
  done
fi

echo "==> Draining $NODE ($COUNT workloads)"

# Bare pods (no ownerRefs) block kubectl drain — it refuses to evict
# controller-less pods without --force. Delete them first; they are
# unmanaged helpers and nothing recreates them.
BARE_PODS=""
while read -r podref; do
  [ -n "$podref" ] || continue
  ns="${podref%/*}"; pod="${podref#*/}"
  owner=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.metadata.ownerReferences}' 2>/dev/null)
  [ -z "$owner" ] && BARE_PODS="$BARE_PODS $ns/$pod"
done <<< "$(kubectl get pods -A -o wide --no-headers | awk -v n="$NODE" '$8 == n {print $1 "/" $2}')"
for podref in $BARE_PODS; do
  echo "  deleting bare pod $podref"
  kubectl delete pod -n "${podref%/*}" "${podref#*/}" --wait=false || true
done

kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s

# Workload names to watch (deduped): deployment pods <name>-<rs>-<hash> → strip
# 2 segments; statefulset pods <name>-<ordinal> → strip 1 segment.
WORKLOADS=""
for p in $BEFORE; do
  if [[ "$p" == *-*-* ]]; then w="${p%-*-*}"; else w="${p%-*}"; fi
  WORKLOADS="$WORKLOADS $w"
done
WORKLOADS=$(printf '%s\n' $WORKLOADS | sort -u | sed '/^$/d')

# Is workload $1 running on a node other than NODE? (STATUS is column 4)
rescheduled() {
  kubectl get pods -A -o wide --no-headers |
    awk -v n="$NODE" -v w="$1" '$8 != n && index($2, w) && $4 == "Running" {found=1} END {exit !found}'
}

# True if workload $1 uses a PVC node-pinned to NODE — it can never reschedule
# until that PVC is deleted, so the wait loop must not burn time on it.
pinned_by_pvc() {
  local w="$1" pods podref ns pod claims c o
  pods=$(kubectl get pods -A -o wide --no-headers 2>/dev/null | awk -v w="$w" 'index($2, w) {print $1"/"$2}')
  [ -z "$pods" ] && return 1
  while read -r podref; do
    [ -z "$podref" ] && continue
    ns="${podref%/*}"; pod="${podref#*/}"
    claims=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{" "}{end}' 2>/dev/null)
    for c in $claims; do
      for o in $ORPHANS; do
        [ "${o#*:}" = "$ns/$c" ] && return 0
      done
    done
  done <<< "$pods"
  return 1
}

# Known-stuck workloads — excluded from the reschedule wait, handled by the
# PVC deletion prompt instead.
PINNED=""
for w in $WORKLOADS; do pinned_by_pvc "$w" && PINNED="$PINNED $w"; done

# Poll until every non-pinned workload runs elsewhere or the timeout elapses.
# Pinned ones (PINNED) can never move and are handled by the PVC prompt.
wait_for_reschedule() {
  local deadline=$((SECONDS + $1)) missing=""
  while [ $SECONDS -lt "$deadline" ]; do
    missing=""
    for w in $WORKLOADS; do
      case " $PINNED " in *" $w "*) continue;; esac
      rescheduled "$w" || missing="$missing $w"
    done
    [ -z "$missing" ] && break
    echo "  [$(date +%H:%M:%S)] still waiting for:$missing"
    sleep 10
  done
  MISSING="$missing"
}

# CNPG clusters owning pinned PVCs — read the cnpg.io/cluster label while the
# PVC still exists (labels are gone after deletion).
cnpg_clusters() {
  for o in $ORPHANS; do
    claim="${o#*:}"
    c=$(kubectl get pvc "${claim#*/}" -n "${claim%/*}" -o jsonpath='{.metadata.labels.cnpg\.io/cluster}' 2>/dev/null || true)
    [ -n "$c" ] && echo "${claim%/*}/$c" || true
  done | sort -u
}

# Wait until every affected CNPG cluster is Ready with all instances, and every
# replica is streaming with 0 WAL lag — proof the data was recovered from the
# primary before the old node's disk is destroyed.
wait_cnpg_caught_up() {
  local deadline=$((SECONDS + $1)) fail=0
  for nc in $CNPG_CLUSTERS; do
    local ns="${nc%/*}" c="${nc#*/}" ready="" instances="" ready_inst="" primary="" lag0=""
    # If the cluster needs more instances than schedulable nodes remain, the
    # replica can NEVER be rescheduled — don't burn the timeout polling for it.
    local need="" sched=""
    need=$(kubectl get cluster "$c" -n "$ns" -o jsonpath='{.spec.instances}' 2>/dev/null || true)
    sched=$(kubectl get nodes --no-headers 2>/dev/null | grep -v SchedulingDisabled | grep -c Ready || true)
    if [ -n "$need" ] && [ "$need" -gt "$sched" ] 2>/dev/null; then
      echo "==> CNPG $ns/$c: CANNOT recover — needs $need instance(s) but only $sched schedulable node(s) remain."
      echo "    No pod can be rescheduled to. Nothing the drain script can do: join a node"
      echo "    (add-node.sh) or scale the cluster to $sched instance(s) first, then re-run."
      fail=1
      continue
    fi
    echo "==> CNPG $ns/$c: waiting for replica recovery..."
    while [ $SECONDS -lt "$deadline" ]; do
      lag0=""
      ready=$(kubectl get cluster "$c" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      instances=$(kubectl get cluster "$c" -n "$ns" -o jsonpath='{.status.instances}' 2>/dev/null || true)
      ready_inst=$(kubectl get cluster "$c" -n "$ns" -o jsonpath='{.status.readyInstances}' 2>/dev/null || true)
      if [ "$ready" = "True" ] && [ "${instances:-0}" != "0" ] && [ "$ready_inst" = "$instances" ]; then
        primary=$(kubectl get cluster "$c" -n "$ns" -o jsonpath='{.status.currentPrimary}' 2>/dev/null || true)
        if [ -n "$primary" ]; then
          lag0=$(kubectl exec -n "$ns" "$primary" -c postgres -- psql -U postgres -tA -c \
            "SELECT count(*) FROM pg_stat_replication WHERE state='streaming' AND pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)=0" 2>/dev/null | tr -d '[:space:]' || true)
          [ -n "$lag0" ] && [ "$lag0" -ge $((instances - 1)) ] && break
        fi
      fi
      sleep 10
    done
    if [ "$ready" = "True" ] && [ "${instances:-0}" != "0" ] && [ "$ready_inst" = "$instances" ] && [ -n "$lag0" ] && [ "$lag0" -ge $((instances - 1)) ]; then
      echo "  OK: $ns/$c Ready, ${ready_inst}/${instances} instances, $lag0 replica(s) caught up"
    else
      echo "  TIMEOUT: $ns/$c not fully recovered (ready=$ready, ${ready_inst:-?}/${instances:-?} instances)"
      fail=1
    fi
  done
  return $fail
}

# CNPG uses required podAntiAffinity on hostname by default. If the cluster
# needs more instances than schedulable nodes remain, the replica can NEVER
# come back — not even after PVC deletion. Warn before the user deletes PVCs.
cnpg_affinity_warn() {
  local nc ns c instances sched
  for nc in $CNPG_CLUSTERS; do
    ns="${nc%/*}"; c="${nc#*/}"
    instances=$(kubectl get cluster "$c" -n "$ns" -o jsonpath='{.status.instances}' 2>/dev/null || true)
    sched=$(kubectl get nodes --no-headers 2>/dev/null | grep -v SchedulingDisabled | grep -c Ready || true)
    if [ -n "$instances" ] && [ "$instances" -gt "$sched" ] 2>/dev/null; then
      echo "  WARNING: $nc needs $instances instance(s) but only $sched schedulable node(s) remain."
      echo "           Required hostname anti-affinity means the replica can't come back even"
      echo "           after PVC deletion — join a node or scale the cluster to $sched first."
    fi
  done
}

if [ -n "$PINNED" ]; then
  echo "==> Workloads that cannot reschedule (local-path PVC pinned to $NODE):$PINNED"
  echo "    They are excluded from the wait — deleting their PVCs unblocks them."
fi

echo "==> Waiting for the rest to run on other nodes (timeout 300s)..."
wait_for_reschedule 300

if [ -z "$MISSING" ] && [ -z "$PINNED" ]; then
  echo "==> All workloads rescheduled:"
  for w in $WORKLOADS; do
    kubectl get pods -A -o wide --no-headers |
      awk -v n="$NODE" -v w="$w" '$8 != n && index($2, w) && $4 == "Running" {print "  " $1 "/" w " → " $8; exit}'
  done
  REMAIN=$(kubectl get pods -A -o wide --no-headers | awk -v n="$NODE" '$8 == n {print $1 "/" $2}')
  if [ -n "$REMAIN" ]; then
    echo "==> Still on $NODE (daemonsets expected):"
    echo "$REMAIN"
  fi
  echo "==> $NODE ready to be evicted: kubectl delete node $NODE"
else
  [ -n "$MISSING" ] && {
    echo "==> TIMEOUT: not rescheduled after 300s:"
    for w in $MISSING; do
      kubectl get pods -A -o wide --no-headers | awk -v w="$w" 'index($2, w) {printf "  %s status=%s node=%s\n", $1 "/" $2, $4, $8}'
    done
  }
  # Stuck usually because local-path PVCs are node-pinned to NODE (PV
  # nodeAffinity). Deleting them lets the workload reschedule on a fresh volume.
  if [ -n "$ORPHANS" ]; then
    echo
    echo "==> Stuck on local-path PVCs pinned to $NODE:"
    for o in $ORPHANS; do echo "  ${o#*:} (PV ${o%%:*})"; done
    # Labels needed for CNPG tracking vanish on deletion — capture now.
    CNPG_CLUSTERS=$(cnpg_clusters)
    cnpg_affinity_warn
    read -r -p "Delete these PVCs now? (data on $NODE's disk is LOST) [y/N] " ans
    case "$ans" in
      [yY]*)
        for o in $ORPHANS; do
          claim="${o#*:}"
          kubectl delete pvc -n "${claim%/*}" "${claim#*/}"
        done
        # CNPG wedges when a managed pod stays Pending referencing a deleted
        # PVC (Defaulting-for-Cluster loop, never rebuilds). Delete such pods
        # so the owning controller rebuilds PVC + pod itself.
        for o in $ORPHANS; do
          claim="${o#*:}"; claim_ns="${claim%/*}"; claim_name="${claim#*/}"
          for pod in $(kubectl get pods -n "$claim_ns" -o name 2>/dev/null | sed 's#^pod/##' || true); do
            [ -z "$pod" ] && continue
            claims=$(kubectl get pod -n "$claim_ns" "$pod" -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{" "}{end}' 2>/dev/null || true)
            case " $claims " in
              *" $claim_name "*)
                kubectl delete pod -n "$claim_ns" "$pod" --wait=false >/dev/null 2>&1 || true
                echo "  deleted stale pod $claim_ns/$pod (PVC $claim_name deleted)"
                ;;
            esac
          done
        done
        PINNED=""
        # Gate node eviction on CNPG confirming data recovery from peers.
        set +e
        wait_cnpg_caught_up 600
        CNPG_OK=$?
        set -e
        echo "==> Waiting 120s more for reschedule on fresh volumes..."
        wait_for_reschedule 120
        if [ -z "$MISSING" ] && [ "$CNPG_OK" -eq 0 ]; then
          echo "==> All workloads rescheduled. $NODE ready to be evicted: kubectl delete node $NODE"
        else
          [ "$CNPG_OK" -ne 0 ] && echo "==> CNPG did NOT confirm replica recovery — node NOT safe to evict."
          echo "==> STILL STUCK: $MISSING — node NOT ready, resolve manually first."
        fi
        ;;
      *)
        echo "Skipped. Node NOT ready to be evicted — resolve stuck workloads first: $MISSING"
        ;;
    esac
  else
    echo "==> Node NOT ready to be evicted — resolve stuck workloads first: $MISSING"
  fi
fi
