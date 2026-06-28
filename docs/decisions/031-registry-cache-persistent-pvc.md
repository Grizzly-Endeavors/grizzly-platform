# 031: Fix the zot dedupe-restore storm — upgrade to v2.1.18 + persistent metaDB + fresh-prefix migration

**Date:** 2026-06-28
**Status:** accepted

## Context

The in-cluster zot registry (ADR-027, then pinned at v2.1.2) intermittently locked all writes — pushes hung at `Waiting` for ~90 minutes after any restart, while reads stayed fine. Root cause, traced through the v2.1.2 source:

- The registry once ran `dedupe: true`, leaving deduped blobs in the S3 store; it was later set to `dedupe: false`.
- At startup the controller unconditionally calls `RunDedupeBlobs`, whose `DedupeTaskGenerator` "restores" every deduped digest back to independent copies. In v2.1.2 the generator's `Next()` calls `GetNextDigestWithBlobPaths` **once per digest**, and each call does a **full `storeDriver.Walk` of the entire store** — an **O(N²) scan**. Over S3 (slow `LIST`) that is ~90 min for this store (~780 blobs), each per-digest task taking the global write lock.
- It runs **once per boot** (interval `time.Duration(0)`), so it was invisible for 79 days of uptime and only resurfaced when a restart re-triggered it. The cache/index is never consulted on this path, so persisting it does **not** fix the storm.

A first attempt (persist the BoltDB index on a PVC) was necessary but **not sufficient** — it doesn't touch the O(N²) storage walk. The real fix needed a newer zot.

## Decision

**Upgrade zot v2.1.2 → v2.1.18 and re-create the store on a fresh, pruned prefix.**

1. **v2.1.18** adds a `DedupeRestoreCompleteMarker`: after one restore pass it writes a marker and all later restarts skip the restore scan entirely, plus a `fastRestart: true` storage flag that skips the startup storage→metaDB walk on a clean restart. Both require a persistent rootDir/metaDB.
2. **Persistent rootDir** — `/var/lib/zot` (BoltDB metaDB + cache) is backed by an `iscsi-zfs-retain` RWO PVC instead of `emptyDir`, so the marker/metaDB/`fastRestart` stamp survive restarts. Bulk blobs stay on MinIO/S3; only the small index is on the ZFS tier.
3. **Fresh prefix** — rather than wait out one last storm on the accumulated 34 GiB store, the in-use images (latest per repo) were exported to OCI archives with `skopeo`, zot was pointed at a new empty S3 prefix (`/lab-registry-v2`), and the keepers re-pushed. An empty store has nothing to reconcile, so the migration boots with **no storm at all**, and accumulated cruft (hundreds of UUID build tags on `grizzly-gate`, dead `grizzly-gameservers`, upstream mirror copies) is dropped. `dedupe` stays `false`.

The old `/lab-registry` prefix and the registry:2.8.3 data at the bucket root are retained as a rollback net until the migration is verified, then pruned.

## Alternatives Considered

- **Persistent PVC alone (the first attempt)** — necessary for the v2.1.18 marker/`fastRestart` to persist, but on v2.1.2 it does nothing for the O(N²) storage walk. Insufficient on its own.
- **Eat one final v2.1.2 (or v2.1.18 first-boot) storm in place** — ~90 min of degraded writes and keeps all the accumulated cruft. The fresh-prefix export/import avoids the storm and prunes in one move.
- **Nuke and rebuild every image via CI** — more wall-clock and coordination (re-push + re-run pipelines, ImagePull risk) than exporting the handful of in-use images directly.
- **DynamoDB remote `cacheDriver` / move blobs to filesystem** — would enable dedupe but adds infra or violates the storage split (bulk blobs belong on MinIO, not the fast tier). Out of scope.

## Consequences

- Restarts no longer storm: the marker skips dedupe-restore and `fastRestart` skips the metaDB walk; the registry comes back in seconds.
- The store is small and current (latest-only); future GC/any-walk cost is proportionally lower.
- `dedupe` must remain `false` on the S3 backend without a remote cache DB; re-enabling it requires DynamoDB first.
- Signatures: nothing was signed yet (Kyverno is in Audit), so no cosign artifacts needed migrating; first-party images sign on their next gate build.
- Cleanup debt: the old `/lab-registry` prefix (~34 GiB) and the `docker/` registry:2.8.3 rollback data remain in the bucket until the migration is confirmed good, then deleted.
- Unblocks revisiting the pull-through cache (#31): the sync push that "stalled indefinitely" was queued behind this same write lock, not an inherent S3/sync limitation.
