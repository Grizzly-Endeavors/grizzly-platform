# ADR-055: S3 Object Store — MinIO → Versity S3 Gateway (versitygw)

**Date:** 2026-07-06
**Status:** Proposed — **pending live validation.** Do not implement until the spike (see Consequences) passes. If it fails, the fallback is Garage and this ADR is replaced by a Garage ADR.
**Relates to:** [ADR-012](012-hot-services-on-zfs-minio-split.md) (retains the obs/bulk tiering split; supersedes only the MinIO *engine* choice), [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores). Consumers to re-point: [ADR-018](018-argo-workflows.md) (Argo artifacts), [ADR-027](027-registry-zot.md) (zot registry), [ADR-038](038-nextcloud-on-foundation-stores-and-sso.md) (Nextcloud), plus Loki/Tempo and Stalwart blob store.

## Context

MinIO's community edition is being gutted and its OSS branch has been effectively unmaintained for 3+ months with known CVEs — migrating off it is a security priority, and it must happen before more consumers pile onto it. The two current instances sit on deliberately-tiered storage per [ADR-012](012-hot-services-on-zfs-minio-split.md): `minio-obs` on the ZFS hot pool (Loki/Tempo/Stalwart, continuous writes) and `minio-bulk` on the MergerFS+SnapRAID pool (registry/artifacts, write-once). The MergerFS+SnapRAID pool **also serves NFS shares, so it cannot be retired** — and SnapRAID only protects static/immutable files, so whatever replaces MinIO on that tier **must store one file per object**. Separately, the platform is trending toward app-facing/tenant S3 (versioning, object-lock, IAM) beyond what MinIO's community edition or a subset store would cover.

## Decision

Replace both MinIO instances with **versitygw** (Versity S3 Gateway) — a stateless S3 gateway that stores objects as plain files at human-readable POSIX paths on the *existing* storage tiers, retaining the [ADR-012](012-hot-services-on-zfs-minio-split.md) two-tier split. Durability is delegated to ZFS and SnapRAID (the gateway holds no authoritative state); IAM is backed by OpenBao (versitygw's Vault IAM mode). As part of the cutover, **rename the instances** from `minio-obs`/`minio-bulk` to engine-neutral, tier-based **`s3-hot`** (ZFS) and **`s3-bulk`** (MergerFS+SnapRAID): "obs" is now misleading (the hot store holds Stalwart blobs and live app state, not just observability), and the name should not encode the engine. This is **provisional pending a live spike** — commit only after validation succeeds.

## Alternatives Considered

- **Garage** (Deuxfleurs) — the fallback. Its content-addressed immutable data blocks compose with SnapRAID and its LMDB metadata fits the ZFS tier, but it lacks versioning, object-lock, SSE, and bucket policies (per-key model only), and single-node `replication_factor=1` carries a documented metadata-corruption risk (it is designed for ≥3 nodes). Chosen only if the versitygw spike fails.
- **SeaweedFS** — rejected: packs many objects into large, continuously-mutated volume files, which defeats SnapRAID (the exact reason obs is kept off it) and wants to own raw disks it can't share with NFS.
- **Ceph RGW** — rejected: wants dedicated RADOS OSD disks (can't coexist on the shared NFS pool) and its multi-node HA value is wasted on a single R730xd.
- **Keep MinIO** — rejected: unmaintained, CVE-bearing, and every new dependent raises the migration cost.

## Consequences

- **Validation gate (must pass before implementation):** stand up one versitygw instance against a scratch directory on the MergerFS pool and exercise (1) object versioning, (2) object-lock retention/legal-hold, (3) a Nextcloud + `s3cmd`/`aws s3` round-trip, and (4) throughput vs the current MinIO. Success flips this ADR to Accepted; failure routes to Garage.
- **Full S3 API surface** — versioning, object-lock, bucket policies, ACLs, multipart — unlocks future tenant/app-facing use and gives Nextcloud/archiving proper primitives. Also the career-relevant S3 IAM/policy/versioning experience Bear wants.
- **Objects stored as ordinary files** at predictable paths → SnapRAID-friendly (immutable object/version files), coexists with the NFS shares on the same pool, human-debuggable, no proprietary on-disk format or data-layer lock-in.
- **No metadata-DB single point of failure** — the gateway is stateless, so durability rides on ZFS/SnapRAID which already exist and are already protected; there is no RF=1 corruption problem to design around. HA later = run multiple gateway replicas over the same backend.
- **Consumers must be re-pointed and re-credentialed** — Loki/Tempo, the zot registry ([ADR-027](027-registry-zot.md)), Argo artifacts ([ADR-018](018-argo-workflows.md)), Stalwart blobs, and Nextcloud ([ADR-038](038-nextcloud-on-foundation-stores-and-sso.md)). All are S3-compatible, so this is an endpoint + key swap, not an app rewrite.
- **Translation-layer cost** — versitygw adds a gateway hop (some per-request overhead) and its object-lock/versioning correctness depends on the gateway plus backend-FS xattr support; this is precisely what the spike de-risks.
- **Two instances retained** — same operational multiplicity as today; the tiering rationale in [ADR-012](012-hot-services-on-zfs-minio-split.md) is unchanged.
- **Instance rename folded in** — `minio-obs`→`s3-hot`, `minio-bulk`→`s3-bulk`. This touches the Ansible roles (`r730xd-minio-obs`→`r730xd-s3-hot`), the ZFS dataset (`tank/foundation/minio-obs`→`.../s3-hot`), data paths, OpenBao secret paths, Prometheus scrape targets/health checks, and every consumer's endpoint/bucket reference — but all of that is *already* in scope for the engine swap, so doing the rename now is essentially free and avoids a second disruptive pass later. Amends the instance naming in [ADR-012](012-hot-services-on-zfs-minio-split.md). Establishes the convention: foundation stores are named by tier/role, not by engine.
- Pin the versitygw image to the current stable release *at implementation time* (verify then, don't carry a version from this record).
