# VLAN Redesign (exploration)

> **Status: not implemented, but no longer gated on hardware.** The router has been acquired (Digi EX50, [ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md)) and segmentation is now scheduled as part of the garage cutover. The authoritative plan is [../runbooks/garage-relocation-cutover.md](../runbooks/garage-relocation-cutover.md) (Checkpoint D) and [ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md), which **supersedes the dual-homing scheme** originally sketched below. For the live topology, see [../network.md](../network.md).

Last updated: 2026-04-17 (revised 2026-07-02 for the EX50 + evict-home approach)

## Why this isn't live yet

The lab runs on a **flat SR2024 network** today with the Xfinity gateway upstream. Segmentation was gated on an off-the-shelf router; that router (Digi EX50) is now in hand, and the VLAN work rides the garage relocation window rather than a separate effort.

The key refinement since this doc was first written ([ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md)): rather than renumber the platform or dual-home every machine, **the platform stays on `10.0.0.0/24` and home devices are evicted to their own subnet.** Same L3 boundary, none of the cluster-PKI / PV-rebinding cost. A full platform renumber (onto a non-default range for a future multi-home mesh) is deferred to its own project.

Nothing below is time-pressured — everything still operates on the current flat network until the cutover.

## Physical Layout (current)

All lab machines are in the closet:

- SR2024 switch (24-port managed)
- Dell PowerEdge R730xd (storage + observability + foundation stores)
- Quanta QSSC-2ML (K8s worker)
- Intel NUC (K8s worker)
- Dell Optiplex 9020 (K8s worker)
- Dell Inspiron 15 (K8s control plane)
- Tower PC (pending K8s worker — ADR-021)

Home drops (bedroom, garage, workshop) stay on the legacy consumer switch chain ([ADR-008](../decisions/008-keep-existing-switch-chain-for-home.md)) — they're fine as they are.

## Target Topology (post-router)

```
              [ISP / Xfinity Gateway]
                 Bridge mode
                  Living Room
                        |
                        v
              +-------------------+
              |  Off-the-shelf    |
              |  Router           |
              |  NAT/DHCP/DNS/FW  |
              |  VLAN trunk       |
              +-------------------+
                        |
                        v
            +-------------------+
            |    SR2024 Switch  |
            |  24-port managed  |
            |    VLAN trunks    |
            +-------------------+
              |  |  |  |  |  |
              v  v  v  v  v  v
           Lab machines  Home drops   APs
           (VLAN 10)    (VLAN 1)     (trunk)
```

### How it works (once the router is in place)

- **Xfinity gateway in bridge mode** — passes the public IP to the purchased router, which handles all routing.
- **Purchased router** handles NAT, DHCP, DNS, and inter-VLAN firewall rules. Typical candidates (UniFi, OPNsense on an appliance) all support this out of the box.
- **SR2024 handles L2 tagging** — trunk ports to the router; access / trunk ports per lab machine.
- **Lab machines keep static IPs** (as they already do via Ansible) on the lab VLAN.

### What this unlocks

- Inter-VLAN firewall rules — granular control over what can cross VLAN boundaries.
- Custom DHCP per VLAN — static leases for lab, dynamic for home.
- Local DNS — lab-internal resolution without `/etc/hosts` hacks.
- Full router-side config, no Xfinity gateway feature limits.

## VLAN Design (target state — per ADR-046)

Start with 2 VLANs, expand only if warranted. **The platform keeps `10.0.0.0/24`; home is evicted to `10.20.0.0/24`** (proposed) — so no platform IP changes.

| VLAN | Subnet | Purpose | Members |
|------|--------|---------|---------|
| Platform | `10.0.0.0/24`, gw `10.0.0.1` (EX50) | Platform-internal — K8s, storage, observability, foundation stores | Inspiron, Quanta, Intel NUC, Optiplex, Tower PC (once joined), R730xd, jumpbox |
| Home | `10.20.0.0/24`, gw `10.20.0.1` (EX50) | Home network — DHCP, personal devices, internet | Home/guest WiFi SSIDs (via APs), bedroom + other home drops, legacy consumer switch chain |

The EX50 routes and firewalls between the two: **default-deny `home → platform`**, with only the specific flows the platform needs; `platform → internet` allowed. Because the EX50 stays in IaC ([ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md)), those firewall rules are version-controlled.

### Optional: Storage Sub-VLAN

| VLAN | ID | Purpose | Members |
|------|----|---------|---------|
| Storage | 20 | NFS / iSCSI traffic only | R730 (dedicated NIC port), worker nodes' dedicated ports |

Worth doing **if** storage I/O noticeably contends with other lab traffic on the flat network. No pressure to commit up front — the R730xd 4-port NIC makes this trivial to add when needed.

### How platform machines connect (dual-homing retired)

The original sketch dual-homed every machine on both the home and lab subnets (two IPs each) to get internet + lab access on a *flat* network. With real L3 routing on the EX50 that is unnecessary and is **retired** ([ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md)):

- Each platform machine sits on the **platform VLAN only** (single IP, its existing `10.0.0.x`), on an SR2024 access port.
- It reaches the internet via the platform subnet's gateway on the EX50 — no second interface, no VLAN tagging on the host.

The SR2024 carries the platform VLAN as access ports to the machines and trunks the home/guest SSIDs up to the APs; only the router uplink and AP ports are trunks.

## WiFi Architecture

| AP | Location | Notes |
|----|----------|-------|
| AP630 (primary) | Central location (living room or hallway) | Highest performance (4×4:4 MU-MIMO, 802.11ac Wave 2). Restored to stock HiveOS 2026-04-03 ([ADR-011](../decisions/011-ap630-restored-to-stock-wifi-ap.md)). |
| AP230 (secondary) | Secondary coverage zone | 3×3:3 MIMO. Starting point per [ADR-009](../decisions/009-start-with-ap230-only.md). |
| AP130 #1 | Garage/workshop | Workshop coverage. |
| AP130 #2 | Far side of house or closet area | Dead-spot coverage if needed. |

- Once the new router is in place, VLAN-tagged SSIDs (e.g., separate guest network) are fully supported.
- Xfinity WiFi can be disabled when AP coverage is verified.
- **PoE:** SR2024 provides 802.3at — no injectors needed.

## NetBird VPN

Unchanged by the router purchase:

- Admin-group operator access to the self-hosted infrastructure (jumpbox, R730xd, K8s nodes as needed).
- Hetzner VPS is deliberately *not* in the admin group — see [ADR-019](../decisions/019-ingress-and-tls-termination.md) and `feedback_netbird_scope.md` in memory.
- Peer-to-peer; doesn't depend on the local router.

## DNS

Superseded by [ADR-036](../decisions/036-internal-dns-zone.md): the internal naming scheme is a private `.internal` zone (`grizzly-platform.internal`), records managed declaratively (external-dns for cluster Services/Ingresses, Ansible zone files for bare-metal hosts), LAN clients pointed at the internal resolver via DHCP. ADR-036 also fixes the resolver's **long-term home as the off-the-shelf router** — i.e. the EX50 — running interim on R730xd until the EX50 lands. So the EX50 cutover unblocks moving the resolver to the router; the `.internal` naming and `/etc/hosts` retirement are the same decision, tracked in ADR-036, not here.

## Cable Runs

| From | To | Status |
|------|----|--------|
| Xfinity gateway (living room) | Closet | In place. |
| Closet (SR2024) | AP mount locations | Partial — will complete as APs get mounted. |
| Within closet | Short patch cables — all lab machines to SR2024 | Done. |

## Open Questions

- [x] ~~SR2024 VLAN capability~~ — confirmed (802.1Q, LACP, trunks).
- [x] ~~SR2024 PoE~~ — confirmed (802.3at, powers all APs without injectors).
- [x] ~~Aerohive standalone mode~~ — confirmed (`no capwap client enable`).
- [x] ~~Custom router vs. off-the-shelf~~ — decided off-the-shelf ([ADR-021](../decisions/021-off-the-shelf-router-tower-pc-as-worker.md)).
- [x] ~~Router model selection~~ — Digi EX50 ([ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md)).
- [x] ~~Xfinity gateway bridge-mode compatibility~~ — confirmed on the same gateway model at another location.
- [ ] **DAL feature-verify (bench, before cutover)** — confirm the EX50 does multi-VLAN interfaces + inter-VLAN firewall, DHCP reservations, WireGuard peer + DNAT (firmware ≥ 24.3.28.88), and optional local DNS records. See the cutover runbook prerequisites.
- [ ] **Home subnet range** — `10.20.0.0/24` proposed; confirm no collision with the planned multi-home mesh.
- [ ] **Storage VLAN worth it?** — revisit once the EX50 is in and we have traffic baselines.

## Available but Unused Network Hardware

| Device | Status | Potential Use |
|--------|--------|---------------|
| D-Link DIR-868L | Consumer router | OpenWrt AP candidate, low priority. |
| Existing consumer switches (5-port ×2, 8-port ×1, 5-port managed ×1) | In use for home drops per ADR-008. | Leave in place. |
