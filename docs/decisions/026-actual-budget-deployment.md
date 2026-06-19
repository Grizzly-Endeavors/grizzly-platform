# ADR-026: Actual Budget Self-Hosted Deployment

**Date:** 2026-06-19
**Status:** Accepted

## Context

Actual Budget (self-hosted personal finance, `actualbudget/actual-server`) is
the first personal app that (a) is the source of truth for real financial data,
(b) stores everything in SQLite on local disk, and (c) integrates with a bank
aggregator (SimpleFIN). It is deployed as a personal app, so per ADR-025 its
manifests live in `lab-apps/apps/actual-budget/` and reach the cluster through
the `personal-apps` Flux Kustomization.

Three of its properties don't fit the personal-app defaults and forced explicit
decisions:

1. **Storage engine is SQLite.** ADR-025 says personal-app PVCs default to the
   `nfs-mergerfs` class (ADR-015). SQLite over NFS is a well-known corruption
   risk — file locking semantics over NFS are unreliable, and Actual keeps
   several `.sqlite` files (`account.sqlite` plus per-budget `db.sqlite`) under
   one data dir.
2. **Bank-sync secrets have no env-injection hook.** The platform convention
   (ADR-024) is `ExternalSecret` → `ClusterSecretStore/openbao` materializing a
   Secret that the workload consumes via env/volume. Actual does not read its
   SimpleFIN token, derived access key, or login password from the environment:
   they are written into `account.sqlite` (the `secrets` table) after one-time
   entry through the web UI, and live only on the PVC thereafter.
3. **The data must survive a `prune`.** The `personal-apps` Kustomization runs
   `prune: true`, and the default `iscsi-zfs` class is `reclaimPolicy: Delete`,
   so an accidental removal of the app folder would destroy the ZFS zvol.

## Decision

**Storage: `iscsi-zfs` (block device, ext4), not NFS.** A real block filesystem
gives SQLite correct locking. The PVC is `ReadWriteOnce`; the Deployment is a
single replica with `strategy: Recreate` to avoid Multi-Attach on RWO.

**Reclaim protection via a new `iscsi-zfs-retain` StorageClass** (this ADR adds
it). It is identical to `iscsi-zfs` but `reclaimPolicy: Retain`, and is
**Flux-managed** under `kubernetes/infrastructure/storage/` rather than rendered
by the `k8s-democratic-csi` Helm role. Reason: adding a class through the role
requires a full `setup-k8s-storage.yml` run (R730xd iSCSI target reconfig,
democratic-csi SSH key rotation, a roll of the CSI driver on every node) —
disproportionate blast radius for an additive class. The class omits the
per-class CSI secret parameters the Helm classes carry; those equivalents are
empty (`DATA=0`) passthroughs and the driver takes its real config from the
controller, so provisioning works without them (verified with a throwaway PVC).

The Actual PVC that already existed before this class was added remains on
`iscsi-zfs` with its **PV manually patched to `Retain`** (documented in the
PVC manifest). New stateful apps should request `iscsi-zfs-retain` directly;
migrating Actual's existing volume to the new class is not worth a data copy
given the patch already protects it.

**Secrets: OpenBao holds them as records, not as an injected Secret.** Because
Actual can't consume env-injected secrets, no `ExternalSecret` is created for
it. The SimpleFIN setup token and the server login password are stored in
OpenBao at `secret/lab-apps/actual-budget/config` purely as the recoverable
system of record (they otherwise exist only inside the PVC's SQLite, and must
never sit in plaintext in git). They are entered into the UI by hand once.

**TLS: plain-HTTP ingress behind the proxy-VPS wildcard** (inherits ADR-019).
`actual-budget.bearflinn.com` is not in `caddy_services`, so Caddy's
catch-all proxies it to the in-cluster ingress over the WireGuard tunnel; no
proxy-VPS change was needed.

**Backup: a nightly in-cluster CronJob** (in `lab-apps`) writes consistent
SQLite copies (`sqlite3 .backup`) plus the remaining files to an
`nfs-mergerfs`-backed PVC, tarred per run with N-day retention. The live data
PVC is mounted read-only. Co-scheduling onto the node holding the RWO volume is
automatic (the scheduler's volume-binding constraint).

## Alternatives Considered

- **NFS (`nfs-mergerfs`) for the data volume**, matching the ADR-025 default.
  **Rejected** — SQLite-over-NFS locking corruption risk; the whole app is
  SQLite.
- **Add `iscsi-zfs-retain` via the democratic-csi Helm role.** The "correct"
  home for storage classes, but only reachable through `setup-k8s-storage.yml`,
  whose blast radius (SSH key rotation, driver roll, R730xd reconfig) is far out
  of proportion to adding one class. **Rejected** for now in favour of a
  Flux-managed manifest; can be folded back into the role at the next genuine
  storage-playbook run.
- **An `ExternalSecret` for the SimpleFIN token / password anyway.** Would
  produce a Secret the container never reads — clutter that implies an injection
  path that doesn't exist. **Rejected**; OpenBao record-only is honest about how
  the app actually works.
- **CSI VolumeSnapshots for backup.** No `VolumeSnapshotClass` / snapshot
  controller is installed cluster-wide. **Deferred** — revisit if the
  external-snapshotter is added later; the `sqlite3 .backup` CronJob is
  application-consistent and needs no extra cluster components.
- **Storage-layer ZFS snapshots on R730xd.** Crash-consistent and zero RWO
  contention, but lives outside the cluster's IaC and snapshots all PVCs
  indiscriminately. A reasonable future addition for whole-pool DR, but the
  per-app logical backup is more portable and restorable.

## Consequences

- **A second iSCSI StorageClass exists**, Flux-owned, diverging from the
  "storage classes come from the democratic-csi role" convention. Documented
  here; the divergence is intentional and reversible.
- **OpenBao's `lab-apps/` prefix now has an entry the cluster never reads.**
  Recovery is a manual UI re-entry, not an automatic remount. The runbook for
  rebuilding Actual must say so.
- **The PVC is the single source of truth for bank credentials and budgets.**
  Losing it without a backup loses the SimpleFIN linkage and all data — hence
  the backup CronJob is not optional once real data lands.
- **Backups consume MergerFS pool space** (`nfs-mergerfs`, reclaim Delete);
  retention bounds it. The backup PVC is not itself backed up — it is the backup.
- **Restore is a documented manual procedure** (untar into a fresh PVC, or
  import via the UI), not yet automated.

## References

- ADR-015 (dynamic storage provisioning) — origin of `iscsi-zfs` / `nfs-mergerfs`.
- ADR-019 (ingress and TLS termination) — why in-cluster ingress is plain HTTP.
- ADR-024 (platform secrets on OpenBao) — path-layout convention.
- ADR-025 (personal apps in `lab-apps`) — delivery model and the NFS default this ADR deviates from.
- `kubernetes/infrastructure/storage/iscsi-zfs-retain.yaml` — the new class.
- `lab-apps/apps/actual-budget/` — the deployment (Deployment, PVC, Service, Ingress, backup CronJob).
