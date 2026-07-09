# ADR-060: Downstream WiFi Segmentation — Trusted and Restricted Segments

**Date:** 2026-07-09
**Status:** Accepted (EX50 interfaces/zones live; SR2024 trunks + AP SSID tagging pending go-live)
**Relates to:** [ADR-046](046-platform-network-segmentation-via-home-eviction.md) (refines), [ADR-044](044-digi-ex50-as-off-the-shelf-router.md), [ADR-021](021-off-the-shelf-router-tower-pc-as-worker.md)

## Context

[ADR-046](046-platform-network-segmentation-via-home-eviction.md) decided to segment the platform off the home LAN by *evicting home to its own subnet* (`10.20.0.0/24`), implementation pending. That treats "home" as one monolithic segment. In practice the downstream (non-platform) devices fall into two groups with different needs:

- devices that should reach the internet freely but must never touch the platform (personal phones/laptops/tablets, and guests);
- devices whose internet access should be **conditional — governed by a policy layer rather than unconditionally on**.

The physical topology makes a WiFi-only segmentation cheap. Platform machines are wired (untagged VLAN 1 on the SR2024); the devices that need segmenting are all wireless. So the split can ride WiFi SSIDs → VLANs on the AP uplink trunks, without touching the wired switch fabric (the unmanaged consumer switch chain can't carry tags anyway) and without renumbering the platform — the same reason [ADR-046](046-platform-network-segmentation-via-home-eviction.md) chose home-eviction over a platform renumber.

## Decision

Replace ADR-046's single home subnet with **two tagged downstream WiFi VLANs**, alongside the untouched platform native VLAN:

| Segment | VLAN | Subnet | Internet egress | Platform access |
|---|---|---|---|---|
| Platform | 1 (native, untagged) | `10.0.0.0/24` | yes | — (it *is* the platform) |
| Trusted | 30 | `10.30.0.0/24` | yes | denied |
| Restricted | 20 | `10.20.0.0/24` | governed out-of-band | denied |

- **Tagged only on the WiFi path:** EX50 LAN-port trunk → SR2024 uplink ports (EX50 + both APs) → AP `mgt0` trunks. Wired access ports — lab machines and the home consumer switch chain — stay untagged VLAN 1.
- **EX50 firewall:** custom zones `trusted` / `restricted`, created just by naming them on each interface. DAL default-denies inter-zone forwarding, so segment isolation (each ↛ platform, each ↛ the other) is automatic — no explicit deny rules. Only `trusted → external` is explicitly allowed; NAT is applied at the `external` zone.
- **The restricted segment's WAN egress is intentionally not expressed in this repo.** With no external-allow rule it is dark by default (DAL default-deny); its egress policy is owned by a separate out-of-band layer. A reserved firewall-filter index range keeps the two from colliding — the base config uses indices 0–2, the out-of-band layer uses ≥ 8 — and `configure-ex50.yml`'s post-apply verification is human-visual (no whole-config assertion), so independently-layered rules coexist.
- **SSIDs:** the existing house SSID maps to `restricted`; a new SSID maps to `trusted`. Personal devices move to the trusted SSID; guests get its password.

## Consequences

- **Delivers ADR-046's segmentation on the cheap WiFi path** — no wired VLAN surgery, no platform renumber, so no cert reissue, PV re-pointing, or Flux-literal churn.
- **Refines, not replaces, ADR-046:** splits the single "home" subnet into trusted + restricted and adds `10.30.0.0/24`. Evicting the *wired* home drops (the consumer switch chain on SR2024 port 2) onto the restricted segment is out of scope here and remains ADR-046 future work.
- **Two-repo firewall boundary.** This repo owns everything up to and including the zones, the isolation (free under default-deny), and the trusted-internet rule; it deliberately writes no restricted-egress rule. The index reservation plus the non-asserting apply make it safe for a separate layer to own the restricted segment's egress.
- **Non-disruptive rollout.** The EX50 VLAN interfaces and the trusted SSID come up without moving any existing device. Moving the existing SSID onto the restricted VLAN is a deferred, commented go-live step in the AP configs, so nothing is cut over until the out-of-band egress layer is in place.
- Reclaims VLAN ID **20** from the (superseded) storage-sub-VLAN sketch in `docs/exploration/network-vlans.md`.
- **Operational note:** enabling the EX50's root shell adds an SSH access menu that breaks the non-interactive `configure-ex50.yml` apply (it pipes straight to the Admin CLI). Leave shell access disabled (its default) outside of interactive debugging.

## Alternatives Considered

- **Single home subnet (ADR-046 as written).** Rejected: can't distinguish devices that should have free internet from those whose access is governed — the two need different egress policy, which one zone can't express.
- **Wired VLAN segmentation of all home devices now.** Deferred: the devices needing segmentation are all WiFi, and the wired home drops sit behind unmanaged consumer switches that can't carry tags — expensive per-port work for no present gain. Stays ADR-046 future work.
- **Flat network + per-device firewall rules (no VLANs).** Rejected: DAL filter rules match only by zone, and a per-device list is a blocklist — a new/unknown device isn't caught by default. Zones give default-deny isolation and a true allow-list posture.
- **Repurposing built-in EX50 zones (`hotspot`/`edge`) instead of custom zones.** Rejected for legibility: custom `trusted`/`restricted` zones (created by naming them on the interface) read clearly; the built-ins carry misleading semantics.

## References

- [ADR-046](046-platform-network-segmentation-via-home-eviction.md) (home-eviction — this refines it), [ADR-044](044-digi-ex50-as-off-the-shelf-router.md) (EX50 as router), [ADR-021](021-off-the-shelf-router-tower-pc-as-worker.md) / [network-vlans.md](../exploration/network-vlans.md) (original VLAN sketch, superseded).
- Runbooks: [sr2024-vlan-trunks.md](../runbooks/sr2024-vlan-trunks.md), [aerohive-ap-setup.md](../runbooks/aerohive-ap-setup.md). EX50 config: `ansible/files/ex50/config.dal.j2` via `ansible/playbooks/configure-ex50.yml`. DAL reference: [ex50-dal-interface.md](../ex50-dal-interface.md).
