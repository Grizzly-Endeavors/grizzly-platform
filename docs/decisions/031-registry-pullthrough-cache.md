# ADR-031: Transparent pull-through cache on the in-cluster zot registry

**Date:** 2026-06-28
**Status:** accepted
**Relates to:** [ADR-027](027-registry-zot.md)

## Context

Every external base image our builds depend on was being pulled from the internet on each use. Argo workflow pods (`alpine/git`, the `gcr.io` kaniko executor) are pulled fresh by containerd; the DinD daemon inside CI runners re-pulls Docker Hub base images (`docker:dind`, Dockerfile `FROM` layers) on every job. With runners scaling to zero and up to four concurrent, the same layers are fetched repeatedly over the WAN — slow, bandwidth-wasteful, and exposed to Docker Hub's anonymous rate limits and upstream outages.

We already run an in-cluster OCI registry (zot, ADR-027) backed by S3, and every node already redirects its `registry.registry.svc.cluster.local:5000` image references to the registry's NodePort via a containerd `certs.d` hosts.toml (`ansible/roles/k8s-registry-trust`). zot ships a `sync` extension that can act as an on-demand pull-through mirror. So the caching infrastructure exists; what was missing was pointing upstream pulls at it.

The owner chose a **transparent mirror** over an explicit path-rewrite scheme: route upstream pulls through zot at the containerd/dockerd layer so no image references change anywhere (including Dockerfile `FROM` lines), rather than rewriting every manifest to a `registry.../dockerhub/...` path. Scope: Docker Hub + GCR — the only two upstreams our builds actually pull.

## Decision

**Enable zot's `sync` extension as an on-demand pull-through cache for Docker Hub and GCR, and route pulls to it transparently at the containerd and dockerd layers.**

1. **zot `sync`, onDemand, 1:1 path mapping.** Two registry entries (`registry-1.docker.io`, `gcr.io`), each `onDemand: true`, `tlsVerify: true`, with `content.prefix: "**"`. The `**` prefix with no `destination` maps the request path 1:1 onto the upstream repo (`library/alpine` → `registry-1.docker.io/library/alpine`), which is exactly what a registry mirror sends. On a cache miss zot fetches upstream and stores the image in S3; subsequent pulls are served LAN-local.
2. **containerd transparent mirror.** `k8s-registry-trust` writes a `certs.d/<host>/hosts.toml` for `docker.io` and `gcr.io` pointing at the localhost NodePort mirror, with `server` set to the real upstream. containerd tries the mirror first and falls back to `server` if zot can't serve the image. This covers all node-level pulls, including Argo workflow pods (kaniko + alpine/git).
3. **dockerd registry mirror.** The DinD sidecar in CI runners adds `--registry-mirror=http://registry.registry.svc.cluster.local:5000` so Docker Hub pulls inside jobs (`docker build` FROM, `docker pull`) route through zot too. dockerd's `--registry-mirror` only mirrors Docker Hub — acceptable, because the only non-Docker-Hub external image in builds is the `gcr.io` kaniko executor, which runs as an Argo pod (cached at the containerd layer, not in DinD).

No image references change. Shallow `--depth=1` fetches on the two Argo build templates are a separate, complementary win committed alongside this.

## Alternatives Considered

- **Explicit path rewrite (`destination` prefixes + rewrite every image ref to `registry.../dockerhub/...`).** Self-documenting and collision-free in zot's storage namespace, but touches every manifest, isn't transparent, and crucially does nothing for Dockerfile `FROM` lines inside the images we build (those still hit upstream unless also rewritten). Rejected: the transparent mirror caches every layer of the stack with zero manifest churn.
- **Per-runner persistent DinD layer cache instead.** Backing the DinD `/var/lib/docker` with a PVC also reduces re-pulls, but only for the runner daemon, not Argo/containerd pulls, and it carries volume-lifecycle complexity under scale-to-zero. Tracked separately as a complementary improvement (issue #27); the pull-through cache shrinks its marginal benefit since pulls become LAN-local anyway.
- **Mirror all upstreams (add GHCR, quay, etc.).** GHCR hosts zot's own image and the ARC chart images, which are pulled before the cache can serve them (bootstrap chicken-and-egg), so the benefit is partial. Kept scope to the two upstreams builds actually pull; adding more is a one-line `defaults` change later.

## Consequences

- **External base images are fetched once, then served LAN-local** across Argo, containerd, and DinD — faster builds, less WAN bandwidth, and insulation from Docker Hub rate limits and upstream outages.
- **Cluster-wide blast radius on `docker.io`/`gcr.io` pulls.** The containerd mirror intercepts *every* pull of those hosts on every node, not just CI builds — including system images. The `server` fallback is the safety net: if zot is down or can't serve an image, containerd pulls directly from upstream, so a registry outage degrades to the pre-cache behaviour rather than a hard failure. This is the main operational risk to watch.
- **zot now needs egress to docker.io and gcr.io** and more S3 storage as cached images accumulate. No cache-eviction policy is configured yet — cached upstream images grow unbounded in the `lab-registry` bucket until pruned. A retention/GC story is an open follow-up.
- **Deploy is not a pure GitOps flip.** The zot configmap change needs a registry pod restart to reload, and the `certs.d` entries require running `setup-k8s-registry-trust.yml` across nodes (new hosts.toml files are read live — no containerd restart needed this time). The DinD mirror flows through Flux and re-rolls runners.
- **First pull of a cold image is slower** (zot synchronously fetches from upstream before serving); the win is on every pull after.
