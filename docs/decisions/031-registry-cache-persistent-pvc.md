# 031: Persist the zot cache DB on a ZFS PVC

**Date:** 2026-06-28
**Status:** accepted

## Context

The in-cluster zot registry (ADR-027) stores blobs on MinIO/S3 but keeps its BoltDB index (`/var/lib/zot/cache.db`) on local filesystem. That path was an `emptyDir`, so the index was wiped on every pod restart. The registry once ran `dedupe: true` (leaving deduped blobs in S3) before being set to `dedupe: false`; with an empty cache on each boot, zot rescans the S3 store, finds the dedupe stubs, and runs `restoreDedupedBlobs` to un-dedupe them — serial, throttled to ~9 blobs/min by the task scheduler, holding a per-digest write lock. For this store (775 stubs) that locked writes for ~87 minutes per restart, and every prior restart interrupted it before completion, so it never converged. Pushes hung at `Waiting` the whole time. Diagnosed in issue #31's follow-up.

## Decision

Back `/var/lib/zot` with a small `iscsi-zfs-retain` RWO PVC instead of `emptyDir`, so the BoltDB index survives restarts. Bulk blobs stay on MinIO/S3 unchanged; only the small index moves to the fast ZFS tier. `dedupe` stays `false` (S3 without a remote cache DB cannot dedupe safely — that mismatch is what triggered the storm). The one-time restore was allowed to complete before cutover, so the S3 store is now fully materialized (no stubs remain).

## Alternatives Considered

- **DynamoDB as zot's remote `cacheDriver`** — zot's documented remote cache for S3, but it adds another stateful service to run for an index that fits in a single small BoltDB file on a single-replica registry.
- **Move all registry blobs to a ZFS PVC** — rejected: bulk write-few/read-heavy container layers belong on MinIO object storage, not the fast live tier. Only the latency-sensitive index needs fast disk.
- **Keep `emptyDir`, rely on the restore completing once** — the materialized store means restore no longer recurs, but every boot still does a full-store rescan + GC storm and rebuilds the index from scratch. A persistent index removes that entirely.

## Consequences

- Restarts are fast and writes stay available — no rescan, restore, or GC storm on boot; the storm/lock recurrence is eliminated.
- The index lives on the ZFS tier (tiny: tens of MB), keeping bulk blobs on MinIO per the registry's storage split.
- `iscsi-zfs-retain` means an accidental PVC delete doesn't silently force a full index rebuild from the 34 GiB store. The index remains reconstructible from S3 if ever lost (one rescan).
- `dedupe` must remain `false` while on the S3 backend without a remote cache DB; re-enabling it requires DynamoDB (or moving blobs to filesystem storage) first.
- Unblocks revisiting the pull-through cache (#31): the sync push that "stalled indefinitely" was almost certainly queued behind this same write lock, not an inherent S3/sync limitation.
