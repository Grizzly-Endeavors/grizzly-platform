# ADR-021: Off-the-Shelf Router; Tower PC Joins Cluster as Plain Worker

**Date:** 2026-04-17
**Status:** Accepted (supersedes ADR-001; also closes the Tower-PC-as-router thread left open by ADR-011)

## Context

ADR-001 (2026-03-27) planned to consolidate the lab router onto the Tower PC alongside a multi-GPU inference workload. That decision was briefly superseded by the AP630-as-router experiment (ADR-003), which itself failed on hardware limits (ADR-010) and was reverted, reinstating ADR-001 via ADR-011.

Since ADR-011, two things have changed:

1. **Tower PC PSU won't carry the planned GPUs.** The intended inference fleet (1080 Ti + 1060 + 1050 Ti) would sit above the Tower PC's PSU headroom. Rather than upgrade the PSU, a separate machine is being built to host the inference workload. That pulls the "CPU is underutilized by GPU inference" rationale out from under ADR-001 — the Tower PC is no longer running GPU inference at all.
2. **DIY-router overhead isn't worth it for this lab.** A Tower-PC-as-router setup means owning nftables/dnsmasq/DNS config in IaC, operating it under the same rules as every other service (observability, failure modes, reboots = network outage), and doing so indefinitely for a single home network. The operator decided this is a poor ROI versus buying an off-the-shelf router and spending the time on upstream projects (Residuum, cluster apps, etc.).

Current physical state: all lab machines are in the closet, SR2024 is the lab backbone, and the Xfinity gateway is still handling routing / DHCP / DNS for the whole house. VLANs are not configured — the network is flat. The cluster has been running this way for ~11 days without issue.

## Decision

**Buy an off-the-shelf router.** A consumer or prosumer router (e.g., UniFi, OPNsense-on-appliance, or similar) will replace the Xfinity gateway's routing role when it arrives. The specific model is deferred; the important decision is that the routing box is bought rather than built. Xfinity gateway goes into bridge mode at that point.

**Tower PC joins the K8s cluster as a plain worker.** No router role, no GPU role. Its i7-4790 + 24 GB RAM is useful compute that the cluster can absorb with zero additional operational burden. It runs the same baseline Ansible + containerd setup as Quanta / NUC / Optiplex.

**GPU inference moves to a separate, yet-to-be-built host.** The GPU fleet (1080 Ti / 1060 / 1050 Ti) is reserved for that machine. Specs, role, and any observability / IaC for it will be captured in a future ADR once hardware lands; until then it's a footnote in `docs/hardware.md`.

**Until the new router arrives:** the lab stays on SR2024 flat L2 with the Xfinity gateway upstream. VLANs are deferred — they were always cheapest to configure alongside a real router, and doing them on top of Xfinity-gateway routing doesn't buy much.

## Consequences

- **Routing is off the IaC critical path.** The off-the-shelf router will be configured through its own admin UI, not Ansible. This is a deliberate trade: less control, much less maintenance. A reasonable router still supports VLANs, static leases, and firewall rules — the pieces we actually need.
- **Tower PC becomes cluster compute.** +4C/8T and +24 GB RAM to the cluster once it joins. It will be added to `ansible/inventory/lab-nodes.yml` as a worker at join time, not before.
- **No cluster workload depends on Tower PC.** Like any other worker, it can fail without breaking the cluster. This closes the "router reboot = lab outage" concern from ADR-001.
- **GPU workloads won't run on the cluster node fleet.** When the new GPU host is built, it will run inference as a standalone service (Ollama / vLLM / TGI) exposed over the LAN, consumed by cluster workloads or developer tools as needed.
- **VLAN design (`archive/network-vlans-design.md`) stays on the shelf.** The target two- or three-VLAN split (home / lab / optional storage) is still the right end state; it just waits until the router is in place.
- **ADR-001 is superseded.** ADR-011 is left as-is — its AP630-specific conclusions stand; the "Tower PC resumes router role" sentence in it is now historical context only.
- **NetBird / VPS ingress path is unaffected.** The ingress tunnel (ADR-019) still terminates on R730xd today; nothing about the router change alters the VPS→cluster path. If the ingress tunnel is ever moved to a different host, that's a separate decision.

## Alternatives Considered

- **Upgrade Tower PC's PSU and keep the original ADR-001 plan.** Rejected: fixes one constraint but preserves all the DIY-routing overhead this ADR is explicitly trying to shed.
- **Put the GPU fleet in a cluster node.** Rejected: inference workloads have a very different failure/reboot profile than cluster workers; cluster drains shouldn't take inference offline and vice versa. Keeping it separate also means no NVIDIA / device-plugin integration work in the cluster.
- **Run the router in a VM on R730xd.** Rejected: the R730xd is already on the critical path for ingress (ADR-019) and foundation stores. Adding routing to it widens that blast radius and couples internet availability to storage-server maintenance.
- **Keep the Xfinity gateway as the router forever.** Rejected (long-term): no VLANs, no per-host firewalling, limited DHCP control. Acceptable as an interim state while the purchased router is selected and deployed.

## References

- ADR-001 (superseded) — original Tower-PC-as-router decision.
- ADR-011 — AP630 returned to stock; Tower PC previously slated to resume router role.
- ADR-019 — Ingress & TLS termination (unchanged by this ADR).
- `archive/network-vlans-design.md` — target VLAN design; realized in refined form by [ADR-060](060-downstream-wifi-segmentation.md).
- `docs/hardware.md` — Tower PC + pending GPU host tracked in the "Future / Pending Hardware" section.
