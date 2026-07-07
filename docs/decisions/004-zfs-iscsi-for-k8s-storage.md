# ADR-004: ZFS + iSCSI for K8s Block Storage

**Date:** 2026-04-02
**Status:** Accepted (ZFS pool created 2026-04-03; iSCSI provisioning implemented per ADR-015)
**Related:** [ADR-012](012-hot-services-on-zfs-minio-split.md) — hot services moved onto ZFS datasets

## Context

The R730xd has two storage tiers: a MergerFS/SnapRAID pool (5×3TB data + 2×4TB parity) for bulk storage, and a planned ZFS pool (3×2TB drives migrated from tower-pc) for latency-sensitive workloads. K8s PVCs need a storage backend, and the current NFS-off-MergerFS setup is adequate for throughput but not ideal for random I/O (databases, pgvector, etc.).

## Decision

Use iSCSI backed by ZFS zvols on the R730xd for K8s persistent volume storage. NFS off MergerFS remains available for bulk/non-latency-sensitive data. See [ADR-012](012-hot-services-on-zfs-minio-split.md) for the decision to also host Docker service data on ZFS datasets.

## Alternatives Considered

- **NFS for everything** — Simpler, but NFS adds protocol overhead on small random I/O and fsync-heavy workloads. Database performance (e.g., pgvector for resume-site) would suffer.
- **iSCSI off MergerFS/LVM** — Loses ZFS snapshots, checksums, and copy-on-write clones. No advantage over ZFS for block storage.

## Consequences

- **Better database performance.** iSCSI gives K8s pods block-level access — no NFS protocol overhead for random I/O and fsync.
- **ZFS snapshots for PVCs.** Can snapshot before upgrades or migrations, instant rollback.
- **Two storage tiers to manage.** ZFS pool (iSCSI, latency-sensitive) and MergerFS pool (NFS, bulk). Adds operational complexity but matches the workload split.
- **iSCSI CSI driver needed.** K8s needs a CSI driver (e.g., democratic-csi or targetcli + manual provisioning) to dynamically provision iSCSI volumes from ZFS.
- **ZFS memory pressure.** ZFS's ARC cache competes with other R730xd workloads (MergerFS, staging VM, NFS). May need to tune `zfs_arc_max`.
