# ADR-056: Redis → Valkey

**Date:** 2026-07-06
**Status:** Accepted (implementation pending — part of the OSS-sunset migration batch)
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-012](012-hot-services-on-zfs-minio-split.md) (the `redis` ZFS dataset, 64K recordsize).

## Context

Redis's relicensing (SSPL/RSALv2) has left its permissive OSS branch effectively sunset, so staying on it means drifting onto an unmaintained or non-OSS line. Redis runs as a foundation store on the R730xd (its own ZFS dataset per [ADR-012](012-hot-services-on-zfs-minio-split.md)), so the swap is contained to that one deployment slot.

## Decision

Replace Redis with **Valkey** — the Linux Foundation fork — in the same deployment slot and ZFS dataset. Valkey is wire-, RDB-, and AOF-compatible, so it is a near drop-in. Pin to the current stable Valkey release verified at implementation time.

## Alternatives Considered

- **Stay on Redis** — rejected: the license change and unmaintained OSS branch are the whole reason to move; keeping it defeats the purpose.
- **KeyDB** — rejected: multithreaded Redis fork with weaker maintenance momentum than Valkey's broad Linux Foundation backing.
- **Dragonfly** — rejected: a from-scratch reimplementation with its own license and operational model, not a drop-in for existing Redis data/clients.

## Consequences

- **Near drop-in** — protocol/RDB/AOF compatibility means existing data files and clients carry over; the change is largely an image swap in the foundation role.
- **Maintained OSS with broad backing** (AWS, Google, Oracle, et al.) — removes the license/maintenance risk that prompted the move.
- **Verify consumers** don't depend on any Redis-8-only feature before cutover; Valkey tracks Redis 7.2-era compatibility plus its own line.
- The ZFS `redis` dataset (64K recordsize, tuned for AOF append + RDB dumps) is reused as-is.
- Pin the Valkey version from the authoritative source at implementation time — do not carry a version from this record.
