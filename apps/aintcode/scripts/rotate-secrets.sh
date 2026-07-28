#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# rotate-secrets.sh — generate, seal & apply new secrets
#
# Usage:
#   ./apps/aintcode/scripts/rotate-secrets.sh          # full rotation
#   ./apps/aintcode/scripts/rotate-secrets.sh --dry    # generate + seal only
#   ./apps/aintcode/scripts/rotate-secrets.sh --no-commit
#   ./apps/aintcode/scripts/rotate-secrets.sh --help
#
# Sealed YAMLs are written to apps/aintcode/k8s/ (committed alongside manifests).
# ─────────────────────────────────────────────────────────────

DRY_RUN=false
NO_COMMIT=false
for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run) DRY_RUN=true ;;
    --no-commit)     NO_COMMIT=true ;;
    --help|-h)
      sed -n '/^# Usage:/,/^# ─/p' "$0" | sed 's/^# //;s/^#$//' | head -n -1
      exit 0
      ;;
  esac
done

# --- helpers -------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "${GREEN}ok${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠ $*${NC}"; }
err()   { echo -e "${RED}✘ $*${NC}"; exit 1; }
step()  { echo ""; echo -e "${GREEN}── ${CYAN}$*${NC}"; }

# --- check deps ----------------------------------------------
command -v kubeseal >/dev/null 2>&1 || err "kubeseal not found — \`brew install kubeseal\`"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"

NAMESPACE="aintcode"
CLUSTER="postgres"        # CNPG Cluster resource name
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATIC_DIR="$(cd "${SCRIPT_DIR}/../k8s" && pwd)"

# --- generate new secrets ------------------------------------
POSTGRES_USER="${POSTGRES_USER:-aintcode}"
POSTGRES_PASS="${POSTGRES_PASS:-$(openssl rand -base64 32)}"
SESSION_SECRET="${SESSION_SECRET:-$(openssl rand -base64 32)}"
APP_BASE_URL="${APP_BASE_URL:-https://aintcode.com}"
PORT="${PORT:-8787}"

DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASS}@postgres-rw:5432/aintcode"

info "Generated values:"
echo -e "  ${YELLOW}POSTGRES_PASS${NC}  ${POSTGRES_PASS}"
echo -e "  ${YELLOW}SESSION_SECRET${NC} ${SESSION_SECRET}"
echo -e "  ${YELLOW}DATABASE_URL${NC}   ${DATABASE_URL}"

step "Update password in Postgres …"
PRIMARY_POD=$(kubectl get pod -n "${NAMESPACE}" \
  -l "cnpg.io/cluster=${CLUSTER},cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$PRIMARY_POD" ]; then
  # fallback: try role=primary label (older CNPG versions)
  PRIMARY_POD=$(kubectl get pod -n "${NAMESPACE}" \
    -l "cluster=${CLUSTER},role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

ALTER_USER_DONE=false
if [ -n "$PRIMARY_POD" ]; then
  if kubectl exec -n "${NAMESPACE}" "${PRIMARY_POD}" -- \
    psql -c "ALTER USER ${POSTGRES_USER} PASSWORD '${POSTGRES_PASS}';" 2>/dev/null; then
    ALTER_USER_DONE=true
    ok "Password updated in Postgres (pod ${PRIMARY_POD})"
  fi
fi

if [ "$ALTER_USER_DONE" = false ]; then
  PGPASS_CMD="kubectl exec -n ${NAMESPACE} <primary-pod> -- psql -c \"ALTER USER ${POSTGRES_USER} PASSWORD '${POSTGRES_PASS}';\""
  warn "Could not run ALTER USER (primary pod unavailable)."
  echo ""
  echo "  The sealed secrets will still be applied, but Postgres still has the old password."
  echo "  Run this once the primary is back:"
  echo "    ${PGPASS_CMD}"
  echo ""
fi

step "Build and seal Secret YAMLs …"

SERVER_SECRET=$(cat <<-YAML
apiVersion: v1
kind: Secret
metadata:
  name: server-env
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  DATABASE_URL: ${DATABASE_URL}
  SESSION_SECRET: ${SESSION_SECRET}
  APP_BASE_URL: ${APP_BASE_URL}
  PORT: ${PORT}
YAML
)

POSTGRES_SECRET=$(cat <<-YAML
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: ${NAMESPACE}
type: kubernetes.io/basic-auth
stringData:
  username: ${POSTGRES_USER}
  password: ${POSTGRES_PASS}
YAML
)

echo "$SERVER_SECRET" | kubeseal --format yaml \
  > "${STATIC_DIR}/sealed-server-env.yaml"
ok "  wrote sealed-server-env.yaml"

echo "$POSTGRES_SECRET" | kubeseal --format yaml \
  > "${STATIC_DIR}/sealed-postgres-secret.yaml"
ok "  wrote sealed-postgres-secret.yaml"

if [ "$DRY_RUN" = true ]; then
  echo ""
  warn "DRY RUN — stopping before apply. Sealed YAMLs ready in ${STATIC_DIR}:"
  ls -la "${STATIC_DIR}/sealed-"*.yaml
  exit 0
fi

step "Delete existing Secrets so SealedSecrets controller recreates them …"
for s in server-env postgres-secret; do
  if kubectl get secret -n "${NAMESPACE}" "$s" &>/dev/null; then
    kubectl delete secret -n "${NAMESPACE}" "$s"
    ok "deleted secret $s"
  fi
done

step "Apply SealedSecrets to cluster …"
kubectl apply -f "${STATIC_DIR}/sealed-server-env.yaml" \
             -f "${STATIC_DIR}/sealed-postgres-secret.yaml"
ok "SealedSecrets applied"

step "Restart server deployment …"
kubectl rollout restart -n "${NAMESPACE}" deploy/server
# wait for rollout to complete
if kubectl rollout status -n "${NAMESPACE}" deploy/server --timeout=120s; then
  ok "Server rollout complete"
else
  warn "Server rollout not finished within timeout — check manually:"
  echo "  kubectl rollout status -n ${NAMESPACE} deploy/server"
fi

step "Commit new sealed YAMLs …"
if [ "$NO_COMMIT" = true ]; then
  echo "  ${YELLOW}Skip commit (--no-commit). To commit:${NC}"
  echo "  cd ${SCRIPT_DIR}/../.. && git add -A && git commit -m \"Rotate secrets\""
else
  cd "${SCRIPT_DIR}/../.."
  git add "${STATIC_DIR}/sealed-server-env.yaml" "${STATIC_DIR}/sealed-postgres-secret.yaml"
  git commit -m "Rotate secrets" 2>&1 | head -2
  ok "Committed"
fi

# --- done -----------------------------------------------------
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Secrets rotated and applied.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${YELLOW}Verify the API is working:${NC}"
echo -e "    ${CYAN}curl https://aintcode.com/api/problems${NC}"
echo ""
