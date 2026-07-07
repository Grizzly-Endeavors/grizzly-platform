# ADR-002: R730 Staging VM for Migration Continuity

**Date:** 2026-03-27
**Status:** Superseded (2026-04-09) — staging VM decommissioned at the end of Phase 7b after landing-page, caz-portfolio, and resume-site were migrated onto the new K8s cluster. See `archive/staging-vm/ansible/playbooks/` for the historical create/deploy/destroy playbooks and `archive/migration-2026/k8s-cluster-standup.md` §7b.4 for the teardown steps.

## Context

The lab migration requires draining the tower PC from the K8s cluster so it can be repurposed as the router and GPU inference workstation (see ADR-001). However, the tower PC is currently the primary K8s worker — it handles the majority of cluster workloads after the MSI laptop was drained (2026-03-26).

The problem: critical web services (landing pages, portfolio sites, etc.) are running on K8s and routed through the VPS. Draining the tower PC would take them offline until the new K8s cluster (Quanta + Optiplex) is fully stood up — which depends on PXE boot, storage cutover, and node joining, all of which take time.

## Decision

Stand up a staging VM on the R730xd to host critical workloads during the transition period between the old and new K8s clusters.

## Rationale

- **No downtime for production services.** Critical web services stay online while the K8s cluster is being rebuilt. The VPS proxy is updated to route to the staging VM instead of K8s during the transition.
- **Unblocks the tower PC.** Once critical workloads are on the staging VM, the tower PC can be safely drained and repurposed without service interruption.
- **R730 is already online.** Debian is installed, baseline playbook is applied, and it has plenty of CPU/RAM headroom beyond its storage duties.
- **Temporary by design.** The staging VM is explicitly short-lived — it exists only to bridge the gap. Once the new K8s cluster is healthy and workloads are migrated back, the VM is torn down.

## Scope

The staging VM hosts **critical workloads only** — services that must stay reachable during the migration:
- Public-facing web services (landing pages, portfolio sites)
- Anything routed through the VPS proxy

Non-critical workloads (scaled to 0 during MSI drain) stay down until the new cluster is ready.

## Trade-offs

- **Temporary duplication.** Services run in two places (staging VM config + K8s manifests). This is acceptable because the staging VM is short-lived and will be torn down.
- **Manual setup vs. IaC.** The staging VM could be fully automated or could be a quick manual Docker Compose setup. Given its temporary nature, speed of setup is more important than automation quality — but the setup should still be documented.
- **R730 load.** Running a VM alongside storage duties adds load, but the R730 has 8C/16T and 32GB RAM — plenty of headroom for a few web services.

## Lifecycle

1. **Phase 2A:** After R730 storage is configured, create the staging VM and migrate critical workloads to it. Update VPS proxy routing.
2. **Phase 3:** Build the new K8s cluster (Quanta + Optiplex workers). Migrate workloads from staging VM back to K8s.
3. **Phase 5 (cleanup):** Verify all services are healthy on K8s, then tear down the staging VM.
