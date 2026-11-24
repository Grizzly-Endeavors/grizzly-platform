---
name: homelab-deploy
description: Deploy applications to the Grizzly Endeavors homelab Kubernetes cluster. Use when deploying apps to the cluster, onboarding an app to Flux GitOps, writing or editing Helm charts or K8s manifests for the homelab, configuring ingress for a bearflinn.com subdomain, wiring app secrets through 1Password and External Secrets, choosing a storage class, or using the self-hosted ARC runners. Covers both first-party apps (source + deploy/ chart) and personal/third-party apps (manifests in lab-apps).
---

# Homelab Deploy

This repo (`grizzly-platform`) is the source of truth for cluster infrastructure. Read the live docs here rather than assuming volatile details (IPs, versions, node names, runner scale sets):

| Need | Read |
|---|---|
| Machines, specs, live IPs and roles | `docs/hardware.md`, `docs/network.md`, `ansible/group_vars/all/network.yml` |
| Cluster operations and smoke tests | `docs/runbooks/k8s-cluster-ops.md` |
| NodePort allocations | `docs/nodeport-allocation.md` |
| 1Password + External Secrets | `docs/runbooks/onepassword-quickref.md` |
| Self-hosted ARC GitHub runners | `docs/runbooks/github-runners.md` |
| Object storage (VersityGW) | `docs/runbooks/versitygw-deploy.md` |
| Why decisions were made | `docs/decisions/` (ADRs) |

## Durable Architecture

- **Cluster:** Kubernetes with **Cilium** CNI and **Flux** GitOps. Check `kubectl get nodes` for live nodes and versions.
- **Storage:** **democratic-csi** on the Dell R730xd. Check `kubectl get sc` for current classes.
- **Ingress / TLS:** Internet → Hetzner VPS (Caddy, wildcard `*.bearflinn.com` TLS via Cloudflare DNS-01) → WireGuard tunnel → R730xd DNAT → K8s NodePort → `ingress-nginx` → app. In-cluster web ingress is **plain HTTP** with `ingressClassName: nginx` and no `tls:` block; any unclaimed `*.bearflinn.com` subdomain auto-routes to cluster ingress (ADR-019).
- **Secrets:** Every platform secret lives in the `grizzly-platform` **1Password** vault and reaches workloads through **External Secrets Operator** (`ClusterSecretStore/onepassword`). See `docs/runbooks/onepassword-quickref.md`.
- **Registry:** First-party app images publish to **GHCR** (`ghcr.io/grizzly-endeavors/<repo>`). The in-cluster Zot registry serves internal images such as the runner image.
- **Foundation stores:** Postgres, Redis, and object storage (VersityGW) run on the R730xd (Docker Compose, ZFS/MergerFS tiers), not in-cluster. Connect over the LAN using the hosts/ports in `docs/network.md`.
- **Runners:** ARC v2 self-hosted runner pools live in `arc-runners` (manifests in `kubernetes/infrastructure/github-runners/`). See `docs/runbooks/github-runners.md` and ADR-081 for pool selection.

## Two Delivery Models

### First-party app (you own the source code)

Repo carries a `deploy/` Helm chart, a multi-stage non-root `Dockerfile`, and GitHub Actions workflows:

1. Run `.github/workflows/register-app.yaml` (reusable workflow in this repo) once to open a PR adding `kubernetes/apps/<app>/` (a Flux `GitRepository` + `HelmRelease` pointing at the app repo's `deploy/`).
2. On push to the default branch, CI builds and pushes the image to GHCR (`:<sha>`), bumps `image.tag` in `deploy/values.yaml` with `[skip ci]`, and Flux reconciles within ~1 minute. CI never runs `kubectl` or `helm` to deploy.

Mirror an active example in `kubernetes/apps/` (e.g. `career-scanner`, `cube-rule`, `grizzly-invite`).

### Personal / third-party app (upstream image or chart)

Manifests live in `~/Projects/lab-apps` under `apps/<name>/`, listed in `apps/kustomization.yaml` and reconciled by the `personal-apps` Flux Kustomization (ADR-025). Plain `Deployment`/`StatefulSet` + `Service` + `Ingress` (+ `PVC` / `ExternalSecret`) is cleaner than writing a custom chart for a single upstream image.

Mirror an active example in `lab-apps/apps/` (e.g. `actual-budget`, `nextcloud`, `vikunja`, `home-automation`).

## Ingress, Storage, Secrets, and Sizing

- **Ingress:** Plain HTTP, `ingressClassName: nginx`, no `tls:` block, host on `<app>.bearflinn.com`. Add `nginx.ingress.kubernetes.io/proxy-body-size` for uploads and `proxy-read-timeout` / `proxy-request-buffering: "off"` for streaming endpoints.
- **Storage classes:** `iscsi-zfs` (RWO, Delete — databases, SQLite, single-writer), `iscsi-zfs-retain` (RWO, Retain — stateful data that must survive Flux `prune: true`), `nfs-mergerfs` (RWX, Delete — shared/multi-reader). Never put SQLite on NFS. RWO volumes require `replicas: 1` and `strategy: Recreate`. Back up retained PVCs explicitly (no `VolumeSnapshotClass` is installed).
- **Secrets:** Reference `ClusterSecretStore/onepassword` with `remoteRef.key: <domain>-<name>/<field>`. Never put plaintext secrets in git or pass runtime secrets through CI `--set` flags. If an app cannot consume env/file secrets (stores credentials in its own DB), keep the value in 1Password as a record and skip the `ExternalSecret`.
- **Resource sizing:** Set explicit requests and limits, and **err on the side of generous** — the cluster has ample CPU and memory headroom, so don't copy minimal 50m/64Mi example floors. Always check current stable base image tags before pinning them in a `Dockerfile`.
- **Operational readiness:** Include health probes (with headroom for boot migrations) and cover observability, alerting, troubleshooting, and recovery per `CLAUDE.md`.

## Debugging (Least-Verbose First)

```bash
kubectl get pods -n <ns>
kubectl logs deploy/<app> -n <ns> --tail=20
kubectl rollout status deploy/<app> -n <ns>
flux get kustomizations -n flux-system
flux get helmreleases -A
flux reconcile kustomization <name> -n flux-system --with-source
```
