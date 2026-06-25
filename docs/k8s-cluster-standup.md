# K8s Cluster Standup Plan

> **Status (2026-04-17):** All phases below (1–8) are complete. The cluster is live on v1.33.10 with Flux green, apps migrated to GitOps, and the custom runner image / Argo / sccache work shipped. This document is retained as the build log and the reference for the shape of each phase; individual "Verify" blocks stay useful as smoke-test checklists for future bring-up. Remaining pending work (Tower PC join, GPU host, off-the-shelf router + VLANs, UPS) is tracked in `hardware.md` and the relevant ADRs.

Phased deployment of the new K8s cluster. Each phase is self-contained — it produces a working, observable state that can be verified before moving on.

**Stack:** kubeadm, Cilium/Hubble, nginx-ingress, Flux CD, democratic-csi
**Decisions:** ADR-013 (local disk), ADR-014 (stack), ADR-015 (storage), ADR-016 (single CP), ADR-017 (ARC v2), ADR-018 (Argo), ADR-019 (ingress/TLS), ADR-020 (app delivery), ADR-021 (Tower PC as plain worker)

## Nodes

| Node | Role | Specs | IP |
|------|------|-------|----|
| dell-inspiron-15 | Control plane | i3-7100U (2C/4T), 8GB | 10.0.0.226 |
| quanta | Worker | 2× Xeon E5-2670 (16C/32T), 64GB | 10.0.0.202 |
| intel-nuc | Worker | i7-12700H (14C/20T), 64GB | 10.0.0.46 |
| dell-optiplex-9020 | Worker | i7-4790 (4C/8T), 32GB | 10.0.0.187 |

---

## Phase 1: Control Plane Bootstrap

Stand up a single-node control plane on the Inspiron. No workers, no workloads — just a functioning API server with Cilium as the CNI.

**Delivers:**
- `kubeadm init` with Cilium CNI
- kubectl access from the jumpbox
- Cilium agent healthy, Hubble running
- Node in `Ready` state

**Verify before moving on:**
- `kubectl get nodes` shows Inspiron Ready
- `cilium status` reports all green
- Hubble UI or CLI can observe flows
- Control plane components healthy in `kube-system`
- Prometheus scraping kube-apiserver and etcd metrics (or exporters configured to do so)

---

## Phase 2: Workers Join

Add all three worker nodes to the cluster. Still no workloads — just a healthy multi-node cluster with networking verified between nodes.

Node-exporter and Alloy already run on all machines outside the cluster (host-level systemd), so node observability is independent of cluster health.

**Delivers:**
- containerd + kubeadm on all workers
- `kubeadm join` for Quanta, NUC, Optiplex
- Cilium networking verified cross-node

**Verify before moving on:**
- All 4 nodes Ready
- Cross-node pod communication works (deploy a test pod on each node, curl between them)
- Cilium reports healthy on all nodes
- Hubble shows cross-node flows
- Node metrics already flowing to Grafana (host-level agents, pre-existing)

---

## Phase 2.5: Cluster Metrics & Dashboards

Wire the K8s-specific metrics endpoints into the existing Prometheus/Grafana stack on R730xd. Phase 1 added apiserver + etcd scraping; this phase extends coverage to all nodes' kubelet and Cilium agents.

**Delivers:**
- Prometheus scraping kubelet (`:10250`), Cilium agent (`:9962`), Cilium operator (`:9963`) on all nodes
- K8s cluster dashboard in Grafana (node capacity, pod count, Cilium health)
- Alert rules for: node NotReady, Cilium agent down, kubelet down

**Verify before moving on:**
- Kubelet and Cilium metrics visible in Grafana
- Alerts fire when a Cilium agent is killed (test, then restore)

---

## Phase 3: Storage Provisioning

Set up democratic-csi so the cluster can dynamically provision persistent volumes from the R730xd.

**Delivers:**
- iSCSI target (targetcli) configured on R730xd
- NFS export path for dynamic provisioning on R730xd (MergerFS-backed)
- democratic-csi deployed with two StorageClasses: `iscsi-zfs` (default), `nfs-mergerfs`
- Test PVCs created and bound for both classes

**Verify before moving on:**
- `kubectl get sc` shows both StorageClasses
- A test PVC using `iscsi-zfs` provisions a zvol on the R730xd and binds
- A test PVC using `nfs-mergerfs` provisions an NFS share and binds
- A test pod can write/read data through each PVC
- Storage metrics (ZFS pool usage, NFS export health) visible in Grafana
- Alert rules for ZFS pool >80% and NFS server unreachable

---

## Phase 4: Flux CD & GitOps Foundation

Install Flux and establish the repo structure so all subsequent deployments go through git.

**Delivers:**
- Flux controllers installed (source, kustomize, helm, notification)
- Git repository source pointed at this repo
- Kustomization structure for cluster infrastructure
- Flux reconciliation working — changes in git are applied to the cluster
- Pod log collection: Alloy DaemonSet (or extended host Alloy config) tailing `/var/log/containers/*.log` and shipping to Loki with pod/namespace/container labels

**Verify before moving on:**
- `flux check` passes
- `flux get all` shows sources and kustomizations healthy
- A test change pushed to git is reconciled to the cluster automatically
- Flux notification controller configured to alert on reconciliation failures
- Flux metrics visible in Grafana (reconciliation duration, errors)
- Pod logs from Flux controllers visible in Loki (query by namespace `flux-system`)

---

## Phase 5: CI/CD — GitHub Actions Runners & Workflow Engine

Self-hosted CI/CD running in the cluster. GitHub Actions runners for repo CI, plus a workflow engine for longer-running automation and pipelines.

The old cluster used actions-runner-controller (ARC) with a custom DinD image (see `archive/pre-migration-2026/kubernetes/base/github-runner/`). The runner config can be adapted but needs proper observability this time.

**Delivers:**
- actions-runner-controller (ARC) deployed via Flux
- Runner pool for the `grizzly-endeavors` org with autoscaling
- Workflow engine deployed via Flux (Argo Workflows or CLI-native alternative — to be decided during phase planning)
- Both integrated with cluster observability

**Verify before moving on:**
- Runner pods register with GitHub and appear as available in org settings
- A test workflow dispatched from GitHub runs on a self-hosted runner and completes
- Workflow engine accessible via CLI, can submit and monitor a test workflow
- Runner metrics (active jobs, queue depth, scaling events) in Grafana
- Workflow engine metrics (execution duration, failure rate) in Grafana
- Alerts on: runner pool at zero capacity, workflow failures

---

## Phase 6: Ingress & External Access

Set up nginx-ingress, cert-manager, and wire traffic through the Hetzner VPS so external traffic can reach cluster services with automated TLS.

**Delivers:**
- cert-manager deployed via Flux (jetstack Helm chart)
- ClusterIssuer configured for Let's Encrypt (staging + production)
- nginx-ingress controller deployed via Flux
- Ingress class configured
- VPS Caddy config updated to proxy to cluster ingress
- Test service reachable from the internet with a valid TLS certificate

**Verify before moving on:**
- cert-manager pods running, `cmctl check api` passes
- ClusterIssuer ready (`kubectl get clusterissuer` shows Ready=True)
- Ingress controller pods running, external IP / NodePort assigned
- A test ingress resource routes traffic correctly inside the cluster
- A test Certificate resource is issued successfully by Let's Encrypt staging
- End-to-end: internet → VPS (Caddy) → cluster (nginx-ingress) → test service (TLS)
- Ingress metrics (request rate, latency, errors) in Grafana
- cert-manager metrics (certificate expiry, issuance failures) in Grafana
- Alerts on: ingress controller down, certificate expiry < 14 days, issuance failure

---

## Phase 7: Workload Delivery & Migration

Establish the application delivery model, then migrate services from the staging VM and old cluster. The delivery model is load-bearing — getting it right once means every future deploy is `git push` in the app repo, with no grizzly-platform changes.

**Delivery model (ADR-020):** each app repo owns its own manifests in a `deploy/` dir. grizzly-platform tracks each app as a Flux `GitRepository` + `Kustomization` under `kubernetes/apps/<app>/`. Onboarding a new app is automated via a reusable GitHub workflow in grizzly-platform. Tag bumps happen inside each app repo's CI — no Flux image automation.

### 7a: Platform Setup

Prereqs for the model itself. Done once, before any app migrates.

**Delivers:**
- grizzly-platform migrated from personal GitHub account to `grizzly-endeavors` org (local remotes updated, CI still passes, existing Flux `GitRepository` source for grizzly-platform repointed at new URL)
- GitHub App created and installed org-wide with:
  - `contents: read` on all repos (Flux uses this to pull app `deploy/` dirs)
  - `contents: write` + `pull-requests: write` on grizzly-platform (onboarding workflow uses this)
- Flux `GitRepository` auth for app repos switched to the GitHub App (replaces any per-repo deploy keys)
- `kubernetes/apps/` directory created with a `kustomization.yaml` listing app folders
- `kubernetes/clusters/grizzly-platform/apps.yaml` Flux Kustomization added, pointing at `./kubernetes/apps`, with `prune: true`
- `.github/workflows/register-app.yaml` reusable workflow in grizzly-platform — accepts inputs (app name, repo, deploy path, namespace, ingress host, etc.), renders the `GitRepository` + `Kustomization` from a template, opens an auto-merging PR on grizzly-platform
- `deploy/` template for app repos (Helm chart skeleton) with an example CI tag-bump step and an example `workflow_call` to `register-app.yaml`

**Verify before moving on:**
- `grizzly-endeavors/grizzly-platform` resolves; `git fetch` works from a fresh clone; CI (lint, `flux check`) passes under the new org
- Flux is reading from at least one app repo via the GitHub App (test with a throwaway "hello-world" app); no deploy keys in use
- `flux get kustomizations apps` shows `Ready=True`
- End-to-end onboarding test: run `register-app.yaml` via `workflow_dispatch` from a scratch repo, PR opens on grizzly-platform, auto-merges, Flux picks up the app within 2 minutes, pod reaches Ready
- Reverse test: delete the scratch app's folder from `kubernetes/apps/`, Flux prunes the in-cluster resources
- Onboarding workflow metrics / logs visible (GitHub Actions UI is fine; no custom dashboard needed)
- Existing non-app Flux Kustomizations (`infrastructure`, `cert-manager-issuers`) still `Ready=True` after the apps source is added

### 7b: Service Migration

Migrate services one at a time. Each migration exercises the 7a machinery and shakes out any template gaps.

**Services to migrate (landing-page first, rest TBD):**
- **landing-page** — migrated first because it's the simplest real workload, and the stale link to `bearflinn/grizzly-platform` on the site is fixed as part of this migration (new URL is `grizzly-endeavors/grizzly-platform`)
- caz-portfolio
- resume-site
- Other services from the old cluster (anything still on the staging VM). Palworld was backed up and decommissioned indefinitely — see ADR-022.

**Per-service delivers:**
- App repo has a `deploy/` dir with Helm chart
- App repo CI builds image, bumps tag in `deploy/values.yaml`, commits back with `[skip ci]`
- App onboarded via `register-app.yaml` (single `workflow_dispatch`)
- PVCs provisioned for any stateful services (both `iscsi-zfs` and `nfs-mergerfs` StorageClasses available from Phase 3)
- DNS / VPS Caddy cutover to the cluster ingress
- Staging VM / old cluster instance of the service shut down

**Verify per service:**
- Reachable via its production URL with valid TLS (via the Phase 6 VPS → cluster ingress path)
- Health checks passing (Prometheus scraping `/metrics` if exposed, or blackbox probe against the URL)
- Pod logs visible in Loki with correct namespace/pod/container labels
- Flux reconciliation for the app's `Kustomization` is `Ready=True`
- Rollback tested: `git revert` the most recent deploy-tag-bump commit in the app repo, Flux reconciles back within 2 minutes, old image running

**Verify before closing Phase 7:**
- All in-scope services migrated; staging VM / old cluster instances shut down
- No stale DNS or Caddy routes pointing at decommissioned hosts
- `flux get kustomizations -A` all `Ready=True`
- All migrated services have at least one dashboard panel and one alert in Grafana (per the observability checklist in `CLAUDE.md`)

---

## Phase 8: Completeness — Registry, Custom Images & QoL

Polish pass across the cluster infrastructure. Everything here is deferrable — the cluster is functional without it — but rounds out the platform for day-to-day use.

**Delivers:**
- In-cluster OCI registry deployed via Flux, backed by MinIO bulk storage *(done in Phase 7b)*
- Custom GitHub Actions runner image (Rust, Helm, Node, gh CLI, cross-compile toolchain) built automatically via Argo WorkflowTemplate + Kaniko when the Dockerfile changes (`docker/github-runner/Dockerfile`)
- Runner scale set updated to use custom image from the in-cluster registry
- GitHub Actions workflow (`.github/workflows/build-runner-image.yaml`) triggers the Argo build on Dockerfile push to master
- K8s cluster upgraded from v1.32.13 to v1.33.10, Cilium from v1.17.2 to v1.18.8
- Flux CLI upgraded from v2.7.5 to v2.8.5 (required K8s 1.33+; API resources migrated via `flux migrate`)
- LimitRanges on `arc-runners` and `argo` namespaces (default resource requests/limits for ephemeral pods)
- Argo default ServiceAccount (`argo-workflow`) — operators no longer need `--serviceaccount` per submission
- Consolidated NodePort allocation doc (`docs/nodeport-allocation.md`)

**Tracing:**
- ARC workflow-level tracing via `inception-health/otel-export-trace-action` → Tempo (controller-level tracing not supported by ARC v2)
- Argo → Tempo: OTLP env vars configured on the controller (Phase 5) and OTel metrics exporter is active. Trace spans require v4.1.0+ (PR #15585 merged to `main` Feb 2026, not backported to v4.0.x). Bump chart to v4.1+ when released — no manifest changes needed, traces will flow automatically.

**Deferred / Skipped:**
- **Registry TLS** — Deferred. The registry is internal-only, served over plain HTTP behind the containerd `hosts.toml` mirror and DinD `--insecure-registry`. Adding self-signed TLS via cert-manager would require CA distribution to all nodes and DinD containers for no external benefit. Revisit if registry auth is ever needed.
- **PodDisruptionBudgets** — Skipped. All critical controllers (Flux, ARC, Argo, cert-manager) are single-replica. PDBs for `replicas: 1` either block all drains or are meaningless. Cluster has a single control plane (ADR-016); node drains are manual, deliberate. Add PDBs if any controller scales to 2+.
- **Image pull secrets** — Not applicable. Registry is unauthenticated; containerd uses `hosts.toml` mirror. Revisit if auth is added.
- **Grafana dashboards via Flux** — Skipped. Grafana runs on R730xd Docker Compose, not in K8s. Ansible provisioning (JSON files, 30s auto-reload) works well.
- **Argo chart bump** — Deferred pending upstream release of chart shipping app v4.1.0+. TODO tracked in `kubernetes/infrastructure/argo-workflows/helmrelease.yaml`.
- ~~**Flux CLI upgrade**~~ — Done. K8s upgraded to 1.33.10, Flux to v2.8.5.

**Verify before considering complete:**
- Custom runner image builds and pushes automatically on Dockerfile change
- A workflow using Rust/Helm/Node runs successfully on the custom image
- `argo submit` works without `--serviceaccount` flag
- LimitRanges applied in `arc-runners` and `argo` namespaces
- ARC `otel-export-trace-action` spans visible in Tempo for at least one test workflow
- Argo workflow traces visible in Tempo/Grafana once chart v4.1+ is available

---

## Not Phased (Ongoing)

These happen continuously, not as a discrete phase:

- **Namespace creation** — infra namespaces by function, app projects manage their own
- **Alert tuning** — refine thresholds as real workload patterns emerge
- **Cilium network policies** — add as needed, not upfront
- **Cluster upgrades** — kubeadm upgrade process, single CP means brief API downtime
