# ADR-056: Redis → Valkey, on a backend-agnostic `kv-cache` slot

**Date:** 2026-07-06
**Status:** Accepted
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-012](012-hot-services-on-zfs-minio-split.md) (the ZFS dataset, 64K recordsize), [ADR-033](033-central-identity-authentik.md) (Authentik, the primary consumer).

## Context

Redis's relicensing (SSPL/RSALv2) has left its permissive OSS branch effectively sunset, so staying on it means drifting onto an unmaintained or non-OSS line. Redis ran as a foundation store on the R730xd (its own ZFS dataset per [ADR-012](012-hot-services-on-zfs-minio-split.md)), addressed by every consumer purely as `host:port:password` over the RESP wire protocol.

Two decisions are entangled here: *what backend* to run, and *what to call the slot*. Naming the slot after the product (`redis`, or now `valkey`) re-arms the same cruft the next time the backend changes — and the S3 slot is already slated to swap MinIO → versitygw ([ADR-055](055-s3-object-store-versitygw.md)). So we name the slot by **function**, not by product.

## Decision

1. **Backend → Valkey.** Replace Redis with **Valkey** (the Linux Foundation fork; wire-, RDB-, and AOF-compatible), pinned to the current stable release verified at implementation time (`valkey/valkey:9.1.0` at cutover). The image ships `valkey-server`/`valkey-cli` (no `redis-*` shims), so the compose command and health checks use the `valkey-*` names.

2. **Slot → `kv-cache` (function-named).** Rename the deployment slot from `redis` to the backend-agnostic **`kv-cache`**. The backend (Valkey) is now just the image inside a slot whose identity is durable across future swaps:
   - Ansible role `r730xd-redis` → `r730xd-kv-cache`; container `foundation-redis` → `foundation-kv-cache`; compose dir `/opt/foundation/kv-cache`; vars `kv_cache_*` (identifiers can't carry the hyphen).
   - ZFS dataset **renamed** `tank/foundation/redis` → `tank/foundation/kv-cache` (offline `zfs rename`; AOF/RDB data preserved, 64K recordsize reused).
   - OpenBao secret **renamed** `stores/redis` → `stores/kv-cache` (value unchanged, so consumers need no restart).
   - Metrics: `oliver006/redis_exporter` (the canonical RESP exporter — there is no `valkey_exporter`) keeps its fixed `redis_*` namespace at the source, **relabeled to `kv_cache_*`** in the Prometheus scrape job; alerts and the Grafana dashboard follow the new prefix.

Scope is the KV slot only. Postgres keeps its product name (no swap planned); MinIO gets the same function-naming treatment during the versitygw cutover.

## Alternatives Considered

- **Rename `redis` → `valkey`.** Rejected: a product name is exactly the cruft we're removing — it would need renaming again at the next backend swap.
- **Stay on Redis.** Rejected: the license change and unmaintained OSS branch are the whole reason to move.
- **KeyDB / Dragonfly.** Rejected: KeyDB has weaker maintenance momentum than Valkey's broad Linux Foundation backing; Dragonfly is a from-scratch reimplementation with its own license/operational model, not a drop-in for existing Redis data/clients.
- **Leave metrics as `redis_*`.** Rejected: it's the last "redis" the operator sees; a single scrape-time relabel removes it. Trade-off accepted: a break in metric-history continuity.

## Consequences

- **Near drop-in backend** — protocol/RDB/AOF compatibility means existing data files and clients carry over; the cutover is an image swap plus the slot rename.
- **Cruft-proof identity** — the next KV backend swap touches only the image, not the role/dataset/secret/metric names.
- **Maintained OSS with broad backing** (AWS, Google, Oracle, et al.) — removes the license/maintenance risk that prompted the move.
- **One-time migration steps** (see the mail/secrets-style runbook ordering): pre-seed `stores/kv-cache`, land IaC, then on the R730xd stop the old container → `zfs rename` → redeploy → cut over monitoring → verify → delete `stores/redis` and `/opt/foundation/redis`.
- Consumers verified to depend on no Redis-8-only feature (the store was pinned to `redis:7`); Valkey tracks Redis 7.2-era compatibility plus its own line.

**Supersedes** the earlier draft of this ADR, which kept the `redis` dataset and secret path as-is — those are now renamed to `kv-cache`.
