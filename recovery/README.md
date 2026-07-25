# Disaster Recovery — K3s cluster

## Sealed Secrets key

The controller private key encrypts all `sealed-*.yaml` manifests.
Without it, they're undecryptable.

### Save (before disaster)

```bash
./recovery/fetch-sealed-key.sh
```

Fetches from Bitwarden item "kube sealed secrets key" to
`data/sealed-secrets-key.yaml` (gitignored). The key is already
in Bitwarden — this is a convenience to get it onto disk.

### Restore (after rebuilding cluster)

```bash
# 1. Install the Sealed Secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/...

# 2. Restore the key before applying any SealedSecrets
./recovery/restore-sealed-key.sh

# 3. Apply app manifests
kubectl apply -f apps/aintcode/k8s/
```

## Full cluster rebuild

1. Provision new nodes (see `bootstrap-master.sh`, `add-node.sh`)
2. Install K3s on each node
3. Copy `kubectl-config-hetzner` to your local machine
4. Install CNPG operator: `kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml`
5. Restore Sealed Secrets key (above)
6. Apply all manifests: `kubectl apply -f apps/aintcode/k8s/`
7. Restore Postgres data from backup (future — no backup configured yet)
