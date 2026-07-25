#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# rotate-secrets.sh — generate, seal & apply new secrets
#
# Usage:
#   ./rotate-secrets.sh          # generate + seal + apply
#   ./rotate-secrets.sh --dry    # generate + seal only (no apply)
#   ./rotate-secrets.sh --help
#
# Post-rotation (password changed):
#   1. Connect to the primary Postgres and run:
#      ALTER USER aintcode PASSWORD '<new-password>';
#   2. Restart the server pod:
#      kubectl rollout restart -n aintcode deploy/server
#
# ─────────────────────────────────────────────────────────────

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry|--dry-run) DRY_RUN=true ;;
    --help|-h)
      sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //;s/^#$//'
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

# --- check deps ----------------------------------------------
command -v kubeseal >/dev/null 2>&1 || err "kubeseal not found — \`brew install kubeseal\`"
command -v kubectl >/dev/null 2>&1 || err "kubectl not found"

NAMESPACE="aintcode"
STATIC_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- generate new secrets ------------------------------------
POSTGRES_USER="${POSTGRES_USER:-aintcode}"
POSTGRES_PASS="${POSTGRES_PASS:-$(openssl rand -base64 32)}"
SESSION_SECRET="${SESSION_SECRET:-$(openssl rand -base64 32)}"
APP_BASE_URL="${APP_BASE_URL:-https://aintcode.luchev.dev}"
PORT="${PORT:-8787}"

DATABASE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASS}@postgres-rw:5432/aintcode"

info "Generated values:"
echo -e "  ${YELLOW}POSTGRES_PASS${NC}  ${POSTGRES_PASS}"
echo -e "  ${YELLOW}SESSION_SECRET${NC} ${SESSION_SECRET}"
echo -e "  ${YELLOW}DATABASE_URL${NC}   ${DATABASE_URL}"
echo ""

# --- build plain Secret YAMLs --------------------------------
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

# --- seal ----------------------------------------------------
info "Sealing server-env …"
echo "$SERVER_SECRET" | kubeseal --format yaml \
  > "${STATIC_DIR}/sealed-server-env.yaml"
ok "  wrote sealed-server-env.yaml"

info "Sealing postgres-secret …"
echo "$POSTGRES_SECRET" | kubeseal --format yaml \
  > "${STATIC_DIR}/sealed-postgres-secret.yaml"
ok "  wrote sealed-postgres-secret.yaml"

# --- apply ---------------------------------------------------
if [ "$DRY_RUN" = true ]; then
  echo ""
  warn "DRY RUN — not applying to cluster."
  echo "  To apply:  $0"
  echo ""
  info "Sealed YAMLs ready in ${STATIC_DIR}:"
  ls -la "${STATIC_DIR}/sealed-"*.yaml
  exit 0
fi

echo ""
info "Applying to cluster …"
kubectl apply -f "${STATIC_DIR}/sealed-server-env.yaml" \
             -f "${STATIC_DIR}/sealed-postgres-secret.yaml"
ok "SealedSecrets applied"

# --- verify --------------------------------------------------
echo ""
info "Verifying Secrets exist …"
for s in server-env postgres-secret; do
  if kubectl get secret -n "${NAMESPACE}" "$s" >/dev/null 2>&1; then
    ok "  secret/${s} exists"
  else
    warn "  secret/${s} NOT found — check controller logs"
  fi
done

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Secrets rotated. Next steps:${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  1. ${YELLOW}Update the password in Postgres:${NC}"
echo -e "     Connect to the primary and run:"
echo ""
echo -e "     ${CYAN}ALTER USER ${POSTGRES_USER} PASSWORD '${POSTGRES_PASS}';${NC}"
echo ""
echo -e "  2. ${YELLOW}Restart the server to pick up the new DATABASE_URL:${NC}"
echo ""
echo -e "     ${CYAN}kubectl rollout restart -n ${NAMESPACE} deploy/server${NC}"
echo ""
echo -e "  3. ${YELLOW}Commit the new SealedSecrets:${NC}"
echo ""
echo -e "     ${CYAN}git add -A && git commit -m \"Rotate secrets\"${NC}"
echo ""
