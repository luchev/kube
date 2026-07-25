#!/usr/bin/env bash
set -euo pipefail

# Bring up a local kind cluster with aintcode deployed.
# Prerequisites: run ./scripts/docker-build.sh in aintcode first.
# Usage: ./scripts/kind-up.sh [cluster-name]
# Default cluster name: aintcode

CLUSTER="${1:-aintcode}"

echo "==> Step 1: Create kind cluster (no-op if exists)"
kind create cluster --name "$CLUSTER" --wait 30s 2>/dev/null || true

# Write kind's kubeconfig to a temp file so kubectl uses it.
KUBECONFIG="$(mktemp)"
kind get kubeconfig --name "$CLUSTER" > "$KUBECONFIG" 2>/dev/null
export KUBECONFIG
trap 'rm -f "$KUBECONFIG"' EXIT

echo "==> Step 2: Load images into kind"
kind load docker-image "ghcr.io/luchev/aintcode-server:latest" --name "$CLUSTER"
kind load docker-image "ghcr.io/luchev/aintcode-web:latest" --name "$CLUSTER"

echo "==> Step 3: Deploy manifests"
kubectl apply -f "$(dirname "$0")/../k8s/"

echo "==> Step 4: Wait for pods..."
kubectl wait --for=condition=ready pod -l app=postgres -n aintcode --timeout=60s
kubectl wait --for=condition=ready pod -l app=server -n aintcode --timeout=60s
kubectl wait --for=condition=ready pod -l app=web -n aintcode --timeout=60s

echo ""
echo "==> All pods:"
kubectl get pods -n aintcode

echo ""
echo "==> Port-forward:  kubectl port-forward -n aintcode svc/web 8080:80"
