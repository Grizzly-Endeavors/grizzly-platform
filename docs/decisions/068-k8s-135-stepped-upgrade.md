# ADR-068: K8s 1.35 Target and the Stepped Upgrade Path

**Date:** 2026-08-04
**Status:** Accepted
**Relates to:** [ADR-014](014-k8s-cluster-stack.md) (cluster stack), [ADR-016](016-single-control-plane.md) (single CP — API downtime accepted during upgrades), [ADR-067](067-containerd-from-docker-repo.md) (runtime source swap done first). Closes [#156](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/156).

## Context

K8s 1.33 went EOL 2026-06-28. Supported minors at decision time: 1.34, 1.35, 1.36. Three constraints shaped the target and the path:

- **Agones caps the ceiling at 1.35.** The game-server fleet runs Agones 1.58 (grizzly-gameservers), whose support matrix covers K8s 1.33–1.35 only; no Agones release supports 1.36 yet. 1.36 would strand every game server.
- **1.34 is a waypoint, not a destination** — its own EOL is 2026-10-27, under three months out.
- **Neither kubeadm nor Cilium skip versions.** kubeadm upgrades one minor at a time, and Cilium's upgrade guide supports one minor at a time with a required pre-flight check.

Component compatibility verified before executing: Cilium 1.18 tops out at K8s 1.33, 1.19 at 1.34, 1.20 covers 1.33–1.36; Flux 2.8.5 and Agones 1.58 both cover through 1.35; containerd needed its own fix (ADR-067).

## Decision

**Target K8s 1.35, reached by alternating single-minor steps where every intermediate state is an upstream-tested pairing:**

1. Cilium 1.18.8 → 1.19.6 (on K8s 1.33)
2. containerd → 2.2.6 (ADR-067, on K8s 1.33)
3. K8s 1.33 → 1.34 (with Cilium 1.19 — tested pair)
4. Cilium 1.19.6 → 1.20.0 (on K8s 1.34 — tested pair)
5. K8s 1.34 → 1.35 (with Cilium 1.20 — tested pair)

Each K8s hop runs `upgrade-k8s-cluster.yml` (control plane first, workers serial:1); each Cilium hop runs the new `upgrade-cilium.yml` (pre-flight chart, then Helm upgrade via the k8s-cilium role). An etcd snapshot is taken before node work begins. Game servers are shut down through the gameservers bot's own graceful path first — their `safe-to-evict: false` PDB (allowed disruptions 0) blocks node drains by design.

## Alternatives Considered

- **Stop at 1.34** — rejected: buys <3 months of support, then the same exercise again.
- **Go to 1.36** — rejected: no Agones release supports it; the game servers are the point of the cluster.
- **Jump Cilium 1.18 → 1.20 directly** — rejected: outside Cilium's supported upgrade path (one minor at a time), and 1.18 was already untested against K8s 1.34+ so sequencing had to interleave with the K8s hops anyway.

## Consequences

- The cluster lands on K8s 1.35 (EOL 2027-02-28) / Cilium 1.20 / containerd 2.2 — every layer current and in-matrix, with headroom to take 1.36 once Agones supports it.
- In-place pod resize is GA on 1.35, making live memory *decreases* possible for game servers (grizzly-gameservers ADR-021 previously deferred reductions to the next restart).
- Two K8s upgrade windows instead of one, each with brief single-CP API downtime — accepted per ADR-016.
- cert-manager (1.16.2) and ingress-nginx (1.11.3) run beyond their upstream-tested K8s windows; both use only long-stable APIs and predate this upgrade, tracked as follow-up issues rather than blockers.
