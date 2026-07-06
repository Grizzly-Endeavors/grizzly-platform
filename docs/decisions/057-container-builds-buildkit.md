# ADR-057: Container Image Builds — Kaniko → BuildKit

**Date:** 2026-07-06
**Status:** Accepted (implementation pending — part of the OSS-sunset migration batch)
**Relates to:** [ADR-018](018-argo-workflows.md) (Argo builds the gate image), [ADR-027](027-registry-zot.md) (zot registry — cache target), [ADR-028](028-centralized-ci-gate.md) (the gate cosign-signs the built digest). Closes [#36](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/36), [#27](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/27).

## Context

Kaniko has been archived by Google and is no longer maintained. It builds the `grizzly-gate` image in-cluster via Argo Workflows (`kubernetes/infrastructure/argo-workflows/build-gate-image.yaml`, [ADR-018](018-argo-workflows.md)). Its caching has been a persistent pain point: layer caching is currently disabled outright (`--cache=false`, [#36](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/36)) and the DinD layer cache is ephemeral ([#27](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/27)), so every build is cold.

## Decision

Replace Kaniko with **BuildKit** (rootless `buildkitd`) for in-cluster image builds, using BuildKit's native **registry cache** import/export against the zot registry ([ADR-027](027-registry-zot.md)) to persist layers across builds. The existing hermetic-build + cosign digest-signing flow ([ADR-028](028-centralized-ci-gate.md)) is preserved — BuildKit produces the image, the gate signs the resulting digest exactly as today.

## Alternatives Considered

- **Buildah** — daemonless and simpler to reason about, but it does not hand us BuildKit's turnkey registry-based cache import/export; we'd wire caching manually. BuildKit's cache story is the specific win that closes #36/#27.
- **Stay on Kaniko** — rejected: archived and unmaintained.
- **Docker-in-Docker (`docker build`)** — rejected: needs a privileged daemon and its layer cache is ephemeral unless a persistent volume is bolted on ([#27](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/27)) — the very problem we're eliminating.

## Consequences

- **Closes [#36](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/36)** — layer caching is re-enabled via BuildKit's registry cache (no more `--cache=false`).
- **Closes [#27](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/27)** — cache persists in the registry rather than in an ephemeral DinD volume, so cache survival no longer depends on pod/volume lifetime.
- **Better security posture** — rootless `buildkitd` avoids the privileged daemon a DinD build would require.
- **Dockerfiles are unchanged** — only the build *step* in the Argo workflow changes; the gate's build → sign → admit pipeline is otherwise intact.
- **Signing invariant must hold** — verify the cosign signature still covers the built image *digest* after the swap, so Kyverno admission ([ADR-028](028-centralized-ci-gate.md)) is unaffected.
- Pin the BuildKit version from the authoritative source at implementation time — do not carry a version from this record.
