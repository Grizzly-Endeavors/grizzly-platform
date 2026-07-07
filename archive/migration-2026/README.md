# 2026 Migration Archive

Archived: 2026-04-17

Record of the 2026 homelab migration from the pre-migration Docker-Compose-and-bare-metal setup to the current Kubernetes cluster on repurposed enterprise + consumer hardware. All phases described here are complete; what remains (Tower PC join, GPU inference host, off-the-shelf router, UPS batteries) is tracked in ADRs and `docs/hardware.md`, not here.

## Contents

- [migration-plan.md](migration-plan.md) — The phased plan as executed: assessment, storage build-out, cluster standup, staging-VM bridge, app migration, decommissioning. Includes the risk register, the dependency graph, and a running status log.
- [new-setup-planning.md](new-setup-planning.md) — Role-assignment rationale: why the R730xd became the storage/observability host, why the Inspiron runs the control plane, why the Tower PC is "just a worker", why the GPU fleet moved off-cluster, etc. Kept for reference when building out similar infrastructure.
- [k8s-cluster-standup.md](k8s-cluster-standup.md) — The 8-phase build log for the original K8s cluster standup (control plane bootstrap through registry + QoL). Moved here from `docs/` once standup was long complete — no longer a live operational doc.

## What moved out of here

The evergreen content that was living under `docs/migration-2026/` during the migration has been promoted to the active docs tree, because it's still the source of truth for day-to-day operations:

- **Hardware inventory** → [`docs/hardware.md`](../../docs/hardware.md)
- **Network topology** → [`docs/network.md`](../../docs/network.md)
- **VLAN redesign (pending router purchase)** → [`docs/exploration/network-vlans.md`](../../docs/exploration/network-vlans.md)

## See also

- [../pre-migration-2026/](../pre-migration-2026/) — the repo state *before* this migration kicked off
- [../../docs/decisions/](../../docs/decisions/) — ADRs covering architectural choices made during and after the migration (ADR-003 onward)
