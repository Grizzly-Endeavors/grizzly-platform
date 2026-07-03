# ADR-044: Digi EX50 as the Off-the-Shelf Router

**Date:** 2026-07-02
**Status:** Accepted (implementation pending — see `docs/runbooks/garage-relocation-cutover.md`)
**Relates to:** [ADR-021](021-off-the-shelf-router-tower-pc-as-worker.md), [ADR-019](019-ingress-and-tls-termination.md), [ADR-036](036-internal-dns-zone.md)

## Context

ADR-021 decided to *buy* the router that replaces the Xfinity gateway's routing role, but left the specific model open ("UniFi, OPNsense-on-appliance, or similar") and — critically — assumed the box would be "configured through its own admin UI, not Ansible," i.e. routing would leave IaC. That assumption drove much of ADR-021's "less control, much less maintenance" framing.

A **Digi EX50** has now been acquired. It is not a UniFi/OPNsense-class appliance; it is a cellular-first enterprise router:

- Dual **2.5 GbE** ports (one WAN, one LAN) — no built-in switch fabric.
- WiFi 6, dual-SIM 5G/LTE.
- Can be **PoE+ powered** from a switch, or DC barrel.
- Runs **Digi Accelerated Linux (DAL)**, which is fully scriptable: the root DAL shell is reachable without jailbreaking, and DAL has supported WireGuard since firmware 24.3.28.88 plus standard firewall/port-forwarding.

Two facts reshape ADR-021's assumptions:

1. **Only two Ethernet ports** means fan-out to the platform machines *must* go through the SR2024 as a trunk — this is no longer one option among several.
2. **It is scriptable**, so routing config does **not** have to leave IaC. We can keep VLAN/DHCP/DNS/firewall/WireGuard config version-controlled and Ansible-driven, exactly as with every other host.

## Decision

**The Digi EX50 is the off-the-shelf router** that replaces the Xfinity gateway's routing role. The Xfinity gateway goes into bridge mode (confirmed supported on this model); the EX50 owns NAT, DHCP, DNS forwarding, VLANs, and firewall.

**Its configuration stays in IaC.** Because the DAL shell is scriptable, the EX50 is managed like any other platform host rather than by hand through a web UI. This is a deliberate, eyes-open divergence from ADR-021's "routing leaves IaC" premise.

**5G/cellular is not enabled for now** — there is no cellular plan. The WAN is the bridged Xfinity uplink only. The dual-SIM failover capability is available later if wanted.

**The EX50 is PoE-powered from the SR2024**, co-located with the switch and the platform machines (see [ADR-045](045-platform-relocation-to-garage.md)).

## Consequences

- **Routing comes back into IaC — deliberately.** We re-take the config-maintenance burden ADR-021 tried to shed, but we get reproducible, version-controlled router config on top of vendor-maintained firmware. This is a *middle path* between "build your own router" (ADR-001, rejected) and "buy a black box configured by hand" (ADR-021's original framing): bought hardware, scripted config.
- **The SR2024 trunk is mandatory, not optional.** With only two ports on the EX50, the single LAN port trunks to the SR2024, which fans out to every machine and AP. This matches the target topology in `docs/exploration/network-vlans.md`.
- **Unblocks the deferred network work.** VLAN segmentation ([ADR-046](046-platform-network-segmentation-via-home-eviction.md)), the internal DNS resolver's move off R730xd ([ADR-036](036-internal-dns-zone.md)), and the ingress-tunnel relocation ([ADR-047](047-ingress-tunnel-relocation-to-ex50.md)) all become possible once the EX50 is the router.
- **Firmware is a gate.** WireGuard on DAL requires ≥ 24.3.28.88; the EX50 must be firmware-checked (and updated if needed) before it can host the ingress tunnel (ADR-047).
- **ADR-021's model question is closed**; its Tower-PC-as-worker and GPU-host decisions are unaffected.

## Alternatives Considered

- **UniFi / OPNsense appliance (ADR-021's original candidates).** Not chosen — the EX50 was the hardware acquired. It has fewer ports and a different management surface, but scriptable DAL + PoE + cellular-failover headroom fit the lab well.
- **Configure the EX50 by hand through its UI (per ADR-021's assumption).** Rejected: it *can* stay in IaC, so it should, consistent with the platform's "all configuration is IaC" rule.
- **Enable 5G as primary or failover WAN now.** Deferred: no cellular plan, and below-grade placement (ADR-045) is poor for cellular signal anyway.

## References

- ADR-021 — off-the-shelf router decision (model + IaC-scope assumptions revised here).
- ADR-045 — platform relocation to the garage (physical home of the EX50).
- ADR-046 — network segmentation via home-eviction (what VLANs the EX50 enforces).
- ADR-047 — ingress-tunnel relocation to the EX50.
- ADR-036 — internal DNS zone (resolver's long-term home is this router).
- `docs/runbooks/garage-relocation-cutover.md` — the staged cutover procedure.
- Digi DAL WireGuard support: https://www.digi.com/support/knowledge-base/dal-router-wireguard-client
