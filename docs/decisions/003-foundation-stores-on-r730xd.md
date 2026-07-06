# ADR-003: Foundation Data Stores on R730xd

**Date:** 2026-04-01
**Status:** Accepted

> **Amendment (2026-07-06):** The original Context below assumed diskless, PXE-booted K8s nodes (per the then-current [ADR-005](005-nfs-root-for-pxe-nodes.md)). [ADR-013](013-local-disk-over-pxe-boot.md) superseded that — nodes now boot from local disk. **This does not change the decision.** Node disks hold only the OS; durable application state still belongs *exclusively* on the R730xd foundation stores. The operative rationale is not that nodes are physically stateless — it's a **simple management and recovery story**: one place to back up, snapshot, and restore, rather than durable state scattered across per-node disks. Where a workload genuinely needs a filesystem the SQL/KV/S3 stores can't provide (e.g. a media library), it backs onto foundation-provided storage such as NFS from the R730xd — still not a node's local disk.

## Context

The lab architecture places all stateful workloads on the R730xd storage server. K8s nodes are diskless (PXE boot) and treat compute as disposable. Services that need durable state — PostgreSQL, Redis, MinIO — must run on the R730xd, with K8s workloads connecting over the LAN at `<r730xd_ip>:<port>`.

Several design choices needed to be made about how to organize, deploy, and persist these services.

## Decisions

### Separate roles, not a single "foundation-stores" role

Each service gets its own Ansible role (`r730xd-postgres`, `r730xd-redis`, `r730xd-minio-obs`, `r730xd-minio-bulk`). They have different configuration concerns (Postgres tuning vs Redis memory policy vs MinIO bucket setup), different upgrade cadences, and independent lifecycles. A single role would create artificial coupling. This follows the existing pattern where each `r730xd-*` role is one responsibility.

### Separate Docker Compose projects per service

Each role deploys its own `docker-compose.yml` under `/opt/foundation/<service>/`. This gives independent `docker compose up/down/restart/logs` per service. No risk of one compose operation pulling down another service.

### Host network for Postgres and Redis, published ports for MinIO

Postgres and Redis use `network_mode: host`. Simplest path for LAN clients to reach `<r730xd_ip>:5432` and `<r730xd_ip>:6379` — no NAT overhead, real client IPs in logs. MinIO uses published ports to keep the API and console ports cleanly separated. MinIO Obs (observability) on ports 9000/9001, MinIO Bulk (registry/artifacts) on ports 9002/9003.

### Two MinIO instances for different workloads

MinIO is split into two instances on different storage tiers:
- **MinIO Obs** (`minio-obs`, ports 9000/9001) — hot instance on ZFS for Loki/Tempo S3 backend. Continuous writes, 30-day retention, latency-sensitive queries.
- **MinIO Bulk** (`minio-bulk`, ports 9002/9003) — cold instance on MergerFS for container registry and build artifacts. Write-once-read-many, SnapRAID-compatible.

### Data on ZFS pool (hot) and MergerFS pool (cold)

Continuously-writing services (PostgreSQL, Redis, MinIO Obs) live on the ZFS raidz1 pool at `/mnt/zfs/foundation/<service>/`. ZFS provides checksums, lz4 compression, and per-dataset recordsize tuning (8K for Postgres, 64K for Redis, 1M for MinIO). These workloads are incompatible with SnapRAID's sync-between-writes model.

MinIO Bulk lives on the MergerFS pool at `/mnt/pool/foundation/minio-bulk/`. Write-once-read-many workloads (container images, build artifacts) are well-suited to SnapRAID parity protection.

### Postgres backup via pg_dump cron

A daily `pg_dumpall` with 7-day rotation provides a basic safety net. ZFS snapshots on the Postgres dataset offer additional point-in-time recovery capability. Redis has built-in AOF/RDB persistence. MinIO Bulk backup (e.g., `mc mirror`) deferred to a follow-up. MinIO Obs data has 30-day retention and is considered reproducible (logs/traces).

## Trade-offs

- **Host network limits port flexibility.** If two Postgres instances are needed, one must use a non-default port. Acceptable — a single shared Postgres is the intended pattern.
- **No TLS between services.** Traffic is on a private LAN (`<lab_subnet>`). TLS can be added later if the threat model changes.
- **Docker volumes vs bind mounts.** We use bind mounts to `/mnt/zfs/foundation/...` (hot) and `/mnt/pool/foundation/...` (cold) rather than Docker named volumes. This makes the data location explicit and visible to ZFS snapshots, backup scripts, and operators browsing the filesystem.
