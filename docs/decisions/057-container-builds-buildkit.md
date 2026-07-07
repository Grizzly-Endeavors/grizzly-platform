# ADR-057: Container Image Builds — Kaniko → BuildKit

**Date:** 2026-07-06
**Status:** Accepted (implemented 2026-07-07)
**Relates to:** [ADR-018](018-argo-workflows.md) (Argo builds the gate image), [ADR-027](027-registry-zot.md) (zot registry — cache target), [ADR-028](028-centralized-ci-gate.md) (the gate cosign-signs the built digest). Closes [#36](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/36), [#27](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/27).

## Context

Kaniko has been archived by Google and is no longer maintained. It builds the `grizzly-gate` image in-cluster via Argo Workflows (`kubernetes/infrastructure/argo-workflows/build-gate-image.yaml`, [ADR-018](018-argo-workflows.md)). Its caching has been a persistent pain point: layer caching is currently disabled outright (`--cache=false`, [#36](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/36)) and the DinD layer cache is ephemeral ([#27](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/27)), so every build is cold.

## Decision

Replace Kaniko with **BuildKit** (rootless `buildkitd`) for **both** in-cluster image builds — `build-gate-image` and `build-runner-image` — using BuildKit's native **registry cache** import/export against the zot registry ([ADR-027](027-registry-zot.md)) to persist layers across builds. The existing hermetic-build + cosign digest-signing flow ([ADR-028](028-centralized-ci-gate.md)) is preserved — BuildKit produces the image, the gate signs the resulting digest exactly as today.

Implementation shape:

- **Daemonless, not a persistent daemon.** Each Argo workflow runs `moby/buildkit:<ver>-rootless` via `buildctl-daemonless.sh`, which starts a throwaway rootless `buildkitd`, builds, and exits — keeping the one-shot pattern the Kaniko step had, with no always-on service to operate. The registry cache lives in zot (LAN-local), so warm-from-registry is already fast; a persistent local-cache PVC is the escalation lever if builds are still too slow.
- **zot-compatible cache manifest.** The registry cache is exported with `oci-mediatypes=true,image-manifest=true` so zot stores it as an OCI image manifest — this is what sidesteps the `MANIFEST_INVALID` rejection that forced Kaniko's `--cache=false` ([#36](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/36)).
- **Rootless without privilege.** `--oci-worker-no-process-sandbox` plus an `Unconfined` seccomp/AppArmor `securityContext` (running as uid 1000) lets rootless `buildkitd` run without a privileged pod or `/dev/fuse` — the pod is the isolation boundary.
- **Base-image pulls through zot's mirror.** A shared `buildkitd-config` ConfigMap marks the in-cluster registry `http` and mirrors `docker.io` to zot's pull-through cache ([ADR-032](032-registry-pullthrough-cache.md)), so `FROM` layers come LAN-local — the BuildKit equivalent of the DinD runner's `--registry-mirror`.

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
