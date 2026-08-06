# luchev/kube

Kubernetes cluster config and infra for aintcode.com.

- **Production cluster**: 2-node K3s on Hetzner, CNPG Postgres HA, Traefik
- **GitOps**: Flux reconciles from this repo
- **CI**: GHCR image build/push in [aintcode](https://github.com/luchev/aintcode)

## E2E test

[`tests/e2e-local.sh`](tests/e2e-local.sh) validates the full deployment pipeline locally in kind:

1. Spins up a kind cluster
2. Installs Flux + CloudNativePG
3. Pulls existing GHCR images, pushes test tags
4. Configures Flux to sync from [kube-test](https://github.com/luchev/kube-test)
5. Verifies pods come up healthy
6. Bumps the image tag in kube-test, waits for Flux rollout
7. HTTP smoke test
8. Cleans up (GHCR tags, cluster, temp files)

### Prerequisites

- Docker, kind, kubectl, helm, oras
- `GITHUB_TOKEN` or `GHCR_TOKEN` env var with `read:packages` + `write:packages` + `repo` scope

### Run

```bash
./tests/e2e-local.sh              # full run (~8 min)
./tests/e2e-local.sh --skip-ghcr-push   # reuse existing test tags
./tests/e2e-local.sh --skip-cleanup     # keep cluster for debugging
./tests/e2e-local.sh --destroy          # tear down cluster
```

### Debug failures

- `--skip-cleanup` leaves the kind cluster running — inspect with `kubectl get pods -n aintcode`
- Flux logs: `kubectl logs -n flux-system deployment/kustomize-controller`
- Pod logs: `kubectl logs -n aintcode deployment/server`
- The script dumps pod descriptions on health check failure (step 8)

### CI

The [`e2e` workflow](.github/workflows/e2e.yml) runs the same script on PRs to `main`.
Requires `GHCR_TOKEN` secret — a PAT with `write:packages` and `repo` scopes.
