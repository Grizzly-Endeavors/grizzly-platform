# ADR-063: CI Gate Runs as an In-Cluster Job

**Date:** 2026-07-23
**Status:** Accepted
**Relates to:** [ADR-028](028-centralized-ci-gate.md) (the gate itself), [ADR-057](057-container-builds-buildkit.md) (the same ephemeral-DinD cache problem, for image builds), [ADR-003](003-foundation-stores-on-r730xd.md) (versitygw carries the source handoff)

## Context

The reusable gate workflow ran the gate image with `docker run` inside the runner pod's DinD sidecar. The DinD image store is an `emptyDir` that dies with the ephemeral runner pod, so every gate invocation pulled and extracted the full gate image — ~1.4 GB compressed, all language toolchains and scanners — from zot again. Measured on career-scanner: ~6 minutes of a 12.5-minute gate job was image pull/extract, on every push, for every gated repo.

A second, unrelated cost of the `docker run` model: the cosign signing key had to be injected as env vars on the runner container to be forwarded into the gate container, which exposed it to every workflow step of every job on the shared runner pool (flagged as an accepted risk in the runner-scale-set values at the time).

Slimming or splitting the gate image was considered but doesn't remove the structural problem — any image pulled into an ephemeral DinD store is cold every run.

## Decision

The gate workflow (`.github/workflows/gate.yaml`) submits the gate as a **Kubernetes Job in the `arc-runners` namespace** instead of running it in DinD:

1. The runner tars its checkout and uploads it to the `build-cache` bucket on versitygw (`gate-src/<job>.tar.gz`), signed with curl's native sigv4 using the S3 credentials the runner pods already carry for sccache. An S3 handoff (rather than a clone in the Job) is required because most gated repos are private, and it hands the gate the exact tree CI checked out.
2. The runner creates a Job (name unique per repo+run+attempt) using its own ServiceAccount token; `gate-job-rbac.yaml` grants the runner SA jobs create/get/list/watch/delete, pods read, and pods/log read in `arc-runners` — and deliberately no secrets access.
3. The Job's init container (curlimages/curl) fetches the tarball; the gate container extracts it and execs the harness with `--sign`. The cosign key and S3 credentials reach only the Job's pod via `secretKeyRef` — they are no longer in the runner container env at all.
4. The runner streams the pod's logs into the CI log, then reads the verdict from the Job's status conditions (log streaming is best-effort; status is truth). `backoffLimit: 0` (a gate verdict must never be retried into a pass), `activeDeadlineSeconds: 1800`, `ttlSecondsAfterFinished: 3600` for postmortem access, then GC. The workflow deletes the tarball in an `always()` cleanup step.

Because the Job's pod is scheduled by kubelet, the gate image lands in **node containerd's cache**: after the first run per node (and per new gate tag), pull cost drops to a tag re-resolve plus any changed layers. `imagePullPolicy: Always` stays correct for both digest-pinned `gate_version` callers and `latest` callers — containerd re-resolves the tag cheaply and pulls only missing layers.

## Alternatives Considered

- **Slim/split the gate image** — reduces the constant but keeps the cold-pull-every-run structure; also fragments the "one versioned gate artifact" model (ADR-028). Rejected.
- **Persistent volume for DinD's image store** — concurrent runner pods cannot safely share one dockerd graph store, and per-runner PVCs multiply storage while still missing cross-runner reuse. Rejected (same reasoning as ADR-057).
- **Argo Workflows instead of a bare Job** — Argo is already in-cluster and adds artifact handling and GC, but a Job with `ttlSecondsAfterFinished` covers the need with fewer moving parts and no new runner→Argo API surface. Revisit if gate orchestration grows stages.
- **Clone in the Job instead of the S3 tarball** — needs a GitHub token in-cluster for private repos and risks gating a different tree than CI checked out. Rejected.

## Consequences

- Gate wall-clock drops by the image pull time (~6 min/run measured) on warm nodes; all four gated repos benefit with **zero per-repo change** since they consume `gate.yaml@master`.
- The cosign key is off the runner pool. Residual exposure documented in `gate-job-rbac.yaml`: job-create permission in `arc-runners` is effectively read access to that namespace's secrets (a crafted Job could mount them), so this is a hygiene boundary, not a hard one — acceptable single-tenant; a dedicated gate namespace with admission policy is the escalation path.
- The gate's Rust checks (clippy, test-build) still compile cold inside the Job; a warm compile cache is a separate follow-up (sccache is not yet in the gate image — tracked in grizzly-gate).
- Gate runs now consume cluster scheduling capacity in `arc-runners` (requests 4 CPU / 8 Gi per gate run) rather than living inside the runner pod's own allocation.
- The `build-cache` bucket briefly holds source tarballs of private repos; they are deleted in the workflow's cleanup step and the bucket is LAN-internal.
