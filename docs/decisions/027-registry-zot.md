# ADR-027: Replace docker/distribution with zot for OCI Referrers

**Date:** 2026-06-25
**Status:** accepted

## Context

The in-cluster registry was `registry:2.8.3` (docker/distribution): anonymous, plain-HTTP, NodePort-mirrored via containerd, S3-backed on MinIO bulk. The CI gate ([ADR-026](026-centralized-ci-gate.md)) signs images with cosign, which stores signatures as OCI artifacts associated with the image digest. Reliable signature storage/discovery wants the OCI 1.1 **referrers API**, which docker/distribution 2.8 does not implement well. We also wanted Prometheus metrics from the registry.

## Decision

**Swap the registry image to zot, preserving the existing access posture.**

- zot (`ghcr.io/project-zot/zot-linux-amd64`, pinned) with the same S3/MinIO backend (`lab-registry` bucket, `registry-s3-creds`), `distSpecVersion: 1.1.0` (referrers), the search + Prometheus metrics extensions, config via ConfigMap.
- **Keep it anonymous + plain-HTTP + NodePort 30500 / ClusterIP 5000.** This is a deliberate drop-in: the containerd mirror (`k8s-registry-trust`), the DinD `--insecure-registry`, and anonymous kaniko pushes all keep working with zero changes. The only functional gain is referrers + metrics.
- **Auth is explicitly deferred.** Adding htpasswd auth ripples into containerd creds, the DinD daemon, kaniko push, and kubelet/Flux pull secrets — a big-bang change on a load-bearing registry. It is tracked as separate follow-up work, not bundled with the gate rollout.

## Alternatives Considered

- **Harbor.** Full-featured (RBAC, replication, built-in Trivy) but heavy — Postgres + Redis + multiple services to operate. Overkill for a single-tenant in-cluster registry; zot is a single binary with an S3 backend.
- **Keep docker/distribution, store signatures tag-based (cosign legacy triangulation).** Works without referrers but is fragile with mutable tags and gives no metrics — not a foundation for an enforcement boundary.
- **Add auth now.** Rejected for this change — see "Decision". The supply-chain win the gate needs is referrers, not auth; coupling them would have made a routine registry swap a multi-component migration.

## Consequences

- **Referrers available** for cosign signatures/attestations; the gate's signing model works against the in-cluster registry.
- **Registry metrics** now scraped by the R730xd Prometheus (`registry-zot` job, NodePort 30500 `/metrics`), with a `ZotRegistryDown` alert.
- **Unchanged blast radius for consumers** — pulls and pushes behave exactly as before; `k8s-registry-trust` needed no edits.
- **Auth remains an open gap** (the registry is still unauthenticated, in-cluster only). Acceptable on a LAN-only cluster; the follow-up will add auth + the credential rollout it requires.
- **Cutover is a live swap** of a load-bearing component — sequence it first and verify pulls resolve before building the gate on top (see `docs/runbooks/ci-gate.md`).
