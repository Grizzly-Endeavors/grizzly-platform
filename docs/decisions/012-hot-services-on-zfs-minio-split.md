# 012: Hot Services on ZFS, MinIO Split into Obs/Bulk

**Date:** 2026-04-03
**Status:** accepted — the **tiering split** established here still stands; the **MinIO engine** is being replaced per [ADR-055](055-s3-object-store-versitygw.md) (versitygw), which keeps this two-tier layout but **renames the instances** to engine-neutral, tier-based names: `minio-obs`→`s3-hot`, `minio-bulk`→`s3-bulk` (the hot store now holds mail blobs and live app state, not just observability).

## Context

All Docker services on the R730xd (PostgreSQL, Redis, MinIO, Prometheus, Loki, Tempo, Grafana) were persisting data on the MergerFS pool (`/mnt/pool`), which is protected by SnapRAID. SnapRAID assumes data is relatively static between syncs — continuously-writing services cause dirty file warnings, long sync times, and risk inconsistency if a drive fails mid-sync. None of these services had active data yet, making this a clean migration.

Separately, a container registry and build artifact store will be needed once the K8s cluster is operational. These are write-once-read-many workloads that are well-suited to SnapRAID parity protection, but they need S3-compatible storage (MinIO). Running them on the same MinIO instance as Loki/Tempo (continuous hot writes) would defeat the storage tiering.

## Decision

Move all continuously-writing services to the ZFS raidz1 pool (`/mnt/zfs`) with per-service datasets tuned by workload. Split MinIO into two named instances on different storage tiers:

- **MinIO Obs** (`minio-obs`, ports 9000/9001) — hot instance on ZFS (`tank/foundation/minio-obs`, recordsize=1M). Serves Loki and Tempo S3 backends. Continuous writes, 30-day retention.
- **MinIO Bulk** (`minio-bulk`, ports 9002/9003) — cold instance on MergerFS (`/mnt/pool/foundation/minio-bulk`). Serves future container registry and build artifacts. Write-once-read-many, SnapRAID-compatible.

ZFS datasets with per-workload recordsize tuning:

| Dataset | Recordsize | Rationale |
|---------|-----------|-----------|
| `tank/foundation/postgres` | 8K | Matches PostgreSQL 8K page size |
| `tank/foundation/kv-cache` | 64K | Sequential AOF append + RDB dumps (renamed from `redis`; Valkey backend — ADR-056) |
| `tank/foundation/minio-obs` | 1M | Large S3 objects |
| `tank/observability/prometheus` | 128K | TSDB blocks |
| `tank/observability/loki` | 128K | WAL + cache before S3 flush |
| `tank/observability/tempo` | 128K | WAL + cache before S3 flush |
| `tank/observability/grafana` | 128K | Minimal I/O, co-located with stack |

## Alternatives Considered

- **Keep everything on MergerFS, exclude service dirs from SnapRAID** — Would avoid the migration but loses parity protection for those directories entirely. SnapRAID exclusions are all-or-nothing per path; no partial protection.
- **Single MinIO instance on ZFS for everything** — Simpler, but container images and build artifacts are large and cold. They'd consume ZFS capacity (~3.6TB usable) that's better reserved for hot data. MergerFS has ~15TB for bulk storage.
- **Separate ZFS datasets per MinIO bucket** — Over-engineering. MinIO manages its own object layout internally; ZFS dataset boundaries wouldn't align with bucket boundaries.

## Consequences

- MergerFS pool is now quiet for SnapRAID — only MinIO Bulk writes there, and those are write-once (SnapRAID-safe).
- ZFS provides checksums, lz4 compression, and per-dataset snapshots for all hot data. Enables future point-in-time recovery for PostgreSQL via ZFS snapshots.
- Two MinIO instances to manage instead of one. Separate credentials, separate Prometheus scrape targets, separate health checks.
- ZFS capacity (~3.6TB) must be monitored — hot data with 30-day retention (Loki, Tempo via MinIO Obs) plus database growth will consume space over time.
- Loki/Tempo S3 endpoint (`<r730xd_ip>:9000`) is unchanged — no config changes needed for existing observability service accounts.
