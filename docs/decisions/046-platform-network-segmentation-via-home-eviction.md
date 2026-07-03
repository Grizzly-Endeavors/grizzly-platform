# ADR-046: Platform Network Segmentation via Home-Eviction

**Date:** 2026-07-02
**Status:** Accepted (implementation pending — see `docs/runbooks/garage-relocation-cutover.md`)
**Relates to:** [ADR-021](021-off-the-shelf-router-tower-pc-as-worker.md), [ADR-044](044-digi-ex50-as-off-the-shelf-router.md), [ADR-019](019-ingress-and-tls-termination.md)

## Context

The lab runs a flat L2 network today: platform machines and home/personal devices share `10.0.0.0/24` with only host firewalls and K8s RBAC/network-policy for isolation (`docs/network.md` explicitly notes "a real segmentation story waits on the purchased router"). With the EX50 now the router ([ADR-044](044-digi-ex50-as-off-the-shelf-router.md)), that L3 segmentation is finally possible.

The natural instinct is "put the platform on its own subnet." There are two ways to achieve that, and they have wildly different costs:

**(A) Renumber the platform** onto a fresh range (e.g. `10.10.0.0/24`). The Ansible *config-generation* layer is renumber-friendly — `network.yml` is the single source of truth and templates like `kubeadm-config.yml.j2` and the democratic-csi values files consume it as variables. But the cost does **not** live there. It lives in two layers that never re-read `network.yml`:

- **Live cluster state.** `k8s_control_plane_endpoint` is baked into the apiserver serving-cert SANs, etcd certs, every worker's `--node-ip`, and the kubeconfigs — all set at cluster init. On a single-control-plane cluster (ADR-016, no HA to pivot through) changing it is regenerate-certs / rebuild-the-CP work, not a re-run. Existing `iscsi-zfs` PVs (Postgres/Redis/MinIO-Obs/OpenBao/observability) have R730xd's portal IP persisted in the PV objects with live data behind them. OpenBao's serving cert carries `10.0.0.200` as an IP SAN.
- **Flux/GitOps literals.** Manifests like `external-secrets-stores/openbao-store.yaml` (`https://10.0.0.200:8200`), the registry, monitoring, authentik, and argo manifests carry literal IPs, not templated vars.

**(B) Keep the platform on `10.0.0.0/24` and evict *home* to a new subnet.** Home devices are DHCP — moving them is nearly free. The platform's stateful layer never moves, and the L3 firewall boundary the EX50 enforces is identical to option (A).

## Decision

**Keep the platform on `10.0.0.0/24`; evict home/personal devices to their own subnet (`10.20.0.0/24`, proposed) enforced by the EX50.** The platform subnet becomes "its own" by moving everything *else* off it, not by renumbering the platform.

- Platform machines stay on `10.0.0.0/24`, gateway = EX50 (`10.0.0.1`), all static IPs unchanged.
- Home/personal devices, home-SSID WiFi clients, and the legacy consumer switch chain move to `10.20.0.0/24` (DHCP from the EX50).
- The SR2024 carries the platform VLAN (access ports to machines) and trunks the home + guest SSIDs to the APs; the EX50 routes and firewalls between subnets (default-deny home→platform, with only the specific allows the platform actually needs).

**A full platform renumber is deferred, not rejected.** It has a real future driver — see Future Work.

## Consequences

- **Delivers the segmentation `network.md` has been flagging** with zero disturbance to the cluster, storage, PKI, or Flux manifests. No cert reissue, no PV re-pointing, no CP surgery.
- **Simplifies the old target design.** `docs/exploration/network-vlans.md` previously dual-homed each lab machine on both the home and lab subnets (two IPs per machine) to get internet + lab on a flat network. With real L3 routing on the EX50 that is unnecessary: platform machines live *solely* on the platform subnet and reach the internet via its gateway. That dual-homing scheme is retired.
- **Segmentation is staged after the router swap, not during it.** The runbook cuts the EX50 in on the still-flat `10.0.0.0/24` first (verifiable, reversible), then introduces the home subnet as an additive step — so the platform is never renumbered and each variable is isolated.
- **Firewall policy becomes real config.** The EX50 must express home↔platform rules; because the EX50 stays in IaC (ADR-044), those rules are version-controlled.

## Future Work — Deferred Platform Renumber

Keeping the platform on the **default** `10.0.0.0/24` is a known future problem: a planned **multi-home / site-to-site mesh** will collide with `10.0.0.0/24` (it is the most common default subnet and will overlap peer sites). A future renumber onto a deliberately uncommon range is therefore planned, driven by mesh addressing rather than aesthetics. It is deferred because it is a staged sub-project in its own right — drain → CP cert regeneration → PV re-pointing → Flux-literal edits → OpenBao cert reissue — and will get its own ADR when scheduled. (A related cleanup: the Flux literal IPs should resolve from a shared source so a future renumber touches one place, not many.)

## Alternatives Considered

- **Renumber the platform now (option A).** Rejected for now: high-risk stateful surgery for a segmentation outcome that home-eviction achieves for free. Justified only by the mesh driver above, which is not yet being executed.
- **Stay flat, rely on host firewalls + K8s network policy.** Rejected: that is the status quo the purchased router was meant to end; L3 segmentation is the whole point of having the EX50.
- **Storage sub-VLAN now.** Deferred (as in `network-vlans.md`) until traffic baselines show storage I/O contends on the flat lab segment.

## References

- ADR-044 — Digi EX50 (enforces the segmentation and holds the firewall policy in IaC).
- ADR-021 / `docs/exploration/network-vlans.md` — original VLAN design (dual-homing retired here).
- ADR-016 — single control plane (why a CP IP change is high-risk).
- ADR-019 — ingress topology (unaffected; tunnel relocation handled in ADR-047).
