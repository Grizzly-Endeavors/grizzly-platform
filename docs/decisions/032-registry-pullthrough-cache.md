# 032: Transparent pull-through cache on the in-cluster zot registry

**Date:** 2026-06-28
**Status:** accepted
**Relates to:** [ADR-027](027-registry-zot.md), [ADR-031](031-registry-cache-persistent-pvc.md)

## Context

Every external base image our builds depend on was pulled from the internet on each use. Argo workflow pods (`alpine/git`, the `gcr.io` kaniko executor) are pulled fresh by containerd; the DinD daemon inside CI runners re-pulls Docker Hub base images (`docker:dind`, Dockerfile `FROM` layers) on every job. With runners scaling to zero and up to four concurrent, the same layers are fetched repeatedly over the WAN — slow, bandwidth-wasteful, and exposed to Docker Hub's anonymous rate limits and upstream outages.

We already run an in-cluster zot registry (ADR-027) that every node redirects to via a containerd `certs.d` hosts.toml (`ansible/roles/k8s-registry-trust`). zot ships a `sync` extension that can act as an on-demand pull-through mirror. A first attempt at this (issue #31, reverted in #30) appeared to fail: the S3 sync push "stalled indefinitely." That stall was later traced (ADR-031) to the v2.1.2 dedupe-restore write-lock storm holding the store lock — **not** an inherent sync/S3 problem. On v2.1.18 with that storm eliminated, an onDemand sync of `library/alpine` completes cleanly (`pushing synced local image` → `successfully synced image`), and a second pull serves LAN-local in ~0.5s. So the approach is now viable.

## Decision

**Enable zot's `sync` extension as an on-demand pull-through cache for Docker Hub and GCR, and route pulls to it transparently at the containerd and dockerd layers** — on the existing (single) registry instance, validated on v2.1.18.

1. **zot `sync`, onDemand, 1:1 path mapping.** Two registry entries (`registry-1.docker.io`, `gcr.io`), each `onDemand: true`, `tlsVerify: true`, `content.prefix: "**"` (maps the request path 1:1 onto the upstream repo). `downloadDir` on the cache PVC (sync+S3 stages locally before the S3 push). On a miss zot fetches upstream and stores in S3; later pulls are LAN-local.
2. **containerd transparent mirror.** `k8s-registry-trust` writes a `certs.d/<host>/hosts.toml` for `docker.io` and `gcr.io` pointing at the localhost NodePort, with `server` set to the real upstream. containerd tries the mirror first, falls back to `server` if zot can't serve it. Covers all node-level pulls including Argo (kaniko + alpine/git).
3. **dockerd registry mirror.** The DinD sidecar adds `--registry-mirror=…registry…:5000` so Docker Hub pulls inside CI jobs route through zot too.

No image references change anywhere (including Dockerfile `FROM` lines).

## Alternatives Considered

- **Dedicated pull-through zot instance (separate from the first-party registry).** Better isolation — cache growth/GC can't touch first-party images. Rejected for now: simpler to run one registry, and ADR-031 made the shared registry healthy enough that the original failure mode is gone. Revisit if cache growth or GC contention becomes a problem.
- **Explicit path rewrite (`destination` prefixes, rewrite every image ref).** Self-documenting but touches every manifest and does nothing for Dockerfile `FROM` lines inside built images. The transparent mirror caches the whole stack with zero manifest churn.
- **Per-runner persistent DinD layer cache (#27) instead.** Only helps the runner daemon, not Argo/containerd pulls; complementary, not a substitute.
- **Mirror GHCR/quay too.** GHCR hosts zot's own image + the ARC chart (bootstrap chicken-and-egg), so the benefit is partial. Scoped to the two upstreams builds actually pull; adding more is a one-line `defaults` change.

## Consequences

- External base images are fetched once, then served LAN-local across Argo, containerd, and DinD — faster builds, less WAN, insulation from Docker Hub rate limits/outages.
- **Cluster-wide blast radius on `docker.io`/`gcr.io` pulls:** the containerd mirror intercepts *every* pull of those hosts on every node, including system images. The `server` fallback is the safety net — if zot is down or can't serve an image, containerd pulls direct from upstream, degrading to pre-cache behaviour rather than failing. Main operational risk to watch.
- zot now needs egress to docker.io + gcr.io and more S3 storage as cached images accumulate. **No cache-eviction policy yet** — cached upstream images grow unbounded in `lab-registry` until pruned; a retention/GC story is an open follow-up. (Cache and first-party images share the store, so prune carefully.)
- **Deploy is not a pure GitOps flip:** the configmap change needs a registry pod restart to reload, and the `certs.d` entries require running `setup-k8s-registry-trust.yml` across nodes (hosts.toml is read live — no containerd restart). The DinD mirror flows through Flux and re-rolls runners.
- First pull of a cold image is slower (synchronous upstream fetch); the win is every pull after.
