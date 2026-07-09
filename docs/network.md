# Network Topology

The live lab network. Flat L2 today on the SR2024, with a dedicated point-to-point WireGuard tunnel between the Hetzner VPS and the R730xd for public ingress.

> **IP addresses:** Authoritative values are in `ansible/group_vars/all/network.yml`. This doc renders the Jinja vars literally.

For the pending VLAN redesign, see [exploration/network-vlans.md](exploration/network-vlans.md).

> **Platform relocated to the garage (2026-07-05) and cut over to the Digi EX50 router (2026-07-08).** The EX50 is the gateway at `10.0.0.1` (Xfinity in bridge mode); ADRs [044](decisions/044-digi-ex50-as-off-the-shelf-router.md) (EX50 as router) and [045](decisions/045-platform-relocation-to-garage.md) (garage relocation) are realized. **Downstream WiFi segmentation ([ADR-060](decisions/060-downstream-wifi-segmentation.md), refining ADR-046) is being rolled out:** the EX50 now routes/firewalls two tagged VLANs — `trusted` (VLAN 30, `10.30.0.0/24`) and `restricted` (VLAN 20, `10.20.0.0/24`) — with the platform staying native/untagged on VLAN 1. The EX50 interfaces + zones are live; the SR2024 uplink trunks and the AP SSID→VLAN tagging are pending go-live (until then WiFi is still flat on VLAN 1). Moving the ingress tunnel onto the EX50 ([ADR-047](decisions/047-ingress-tunnel-relocation-to-ex50.md), Checkpoint E) remains later work; ingress stays on the R730xd until then. See [runbooks/sr2024-vlan-trunks.md](runbooks/sr2024-vlan-trunks.md), [runbooks/aerohive-ap-setup.md](runbooks/aerohive-ap-setup.md), [runbooks/garage-relocation-cutover.md](runbooks/garage-relocation-cutover.md).

Last updated: 2026-07-09 (EX50 router live; downstream WiFi VLANs 20/30 provisioned on the EX50, SR2024 trunk + AP SSID tagging pending go-live; ingress-move still pending)

## Physical Topology

All lab machines are in the garage on the SR2024 (relocated from the closet 2026-07-05). Non-lab drops (bedroom, workshop, etc.) continue to run through the legacy consumer switch chain — see [ADR-008](decisions/008-keep-existing-switch-chain-for-home.md).

```
                [Xfinity Gateway]
             bridge mode — WAN uplink only
                 Living Room
                      |
                      | (cable to garage)
                      v
               [Digi EX50 router]
          Gateway 10.0.0.1 / DHCP / DNS
                    Garage
                      |
                      v
          +--------------------------+
          |    SR2024 (Garage)       |
          |    24-port managed GbE   |
          |    Lab backbone          |
          +--------------------------+
              |  |  |  |  |  |
              v  v  v  v  v  v
        R730xd  Inspiron  Quanta
        (store)  (CP)     (wkr)
                 NUC      Optiplex
                 (wkr)    (wkr)
                 Tower PC (pending join)

       [Legacy consumer switch chain — home drops]
       Xfinity → basement 5-port → room 5-port mgd → 8-port unmgd
                                    bedroom/garage/workshop
```

## Current State

### Routing & DHCP

- **The Digi EX50 is the router/gateway at `10.0.0.1`** ([ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md)) — routing, DHCP, and DNS forwarding. The Xfinity gateway is in **bridge mode** (WAN uplink only), cut over 2026-07-08.
- Lab machines use static IPs configured at the OS level (Ansible-managed).
- **DHCP (issue #80, resolved):** the EX50 serves a dynamic pool of **`10.0.0.50–10.0.0.150`**, carved to contain **none** of the OS-static node IPs (`.46`, `.153`, `.187`, `.200–.203`, `.226`, `.249`) — statics are "reserved by exclusion" (outside the assignable pool), so a lease-table reset can never hand out a held address. No per-host MAC reservations. The SR2024 switch (the one device that leased) is now static `10.0.0.153` on the switch itself (DHCP client disabled). Boundaries live in `ansible/group_vars/all/network.yml` (`ex50_dhcp_pool_*`), applied by `ansible/playbooks/configure-ex50.yml`.

### Switching

- **SR2024** is the lab backbone in the garage. All lab machines (live cluster + R730xd + pending Tower PC) connect directly to it.
- **Flat L2 today; downstream WiFi VLANs pending go-live.** VLANs 20 (restricted) / 30 (trusted) are defined in IaC and provisioned on the EX50 ([ADR-060](decisions/060-downstream-wifi-segmentation.md)); the next step converts the SR2024 uplink ports to the EX50 gateway (`eth1/1`) and the two APs (`eth1/3`, `eth1/4`) into trunks carrying native VLAN 1 + tagged 20/30 — see [runbooks/sr2024-vlan-trunks.md](runbooks/sr2024-vlan-trunks.md). All other ports stay untagged VLAN 1. Inter-VLAN routing + firewall run on the EX50.
- Legacy consumer switches still serve the bedroom / garage / workshop drops (ADR-008), untagged on VLAN 1.

### WiFi

- **AP630 (primary) + one AP130 (secondary) are configured and live** (2026-07-07) as a single standalone roaming hive (`grizzly-hive`, 802.11r/k/v), WPA2-AES-PSK. AP630: 11ax, ch 1/36. AP130: 11ng/11ac, ch 6/149. Configs: `ansible/files/aerohive/ap630.hiveos` / `ap130.hiveos`; procedure: [runbooks/aerohive-ap-setup.md](runbooks/aerohive-ap-setup.md). The spare AP230 is unconfigured.
- **WiFi VLAN tagging is staged, not yet live** ([ADR-060](decisions/060-downstream-wifi-segmentation.md)): the `.hiveos` configs define a second (trusted, VLAN 30) SSID and an `mgt0` trunk, and map the existing SSID to the restricted VLAN 20 as a deferred go-live step. Today both APs still broadcast the single untagged SSID on native VLAN 1 until the AP paste + SR2024 trunks are applied.
- **APs are powered by PoE injectors** — the SR2024's own PoE is not delivering (PSE failure, [#84](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/84)); the earlier "PoE from the SR2024, no injectors" plan does not currently hold.
- House WiFi is the Aerohive roaming hive (`Hearthstone` SSID); the Xfinity gateway is now in bridge mode.

### DNS

- The EX50 is the LAN resolver (DNS forwarding to upstream) — DHCP clients get `10.0.0.1`. Lab internal names still live in `/etc/hosts` via Ansible; a local `.internal` resolver on the EX50 (ADR-036) is a possible follow-up.

### VPN / Ingress

- **NetBird** for operator admin access (admin group: jumpbox, R730xd, K8s nodes as needed). Hetzner VPS is deliberately **not** in the admin group — see `feedback_vps_home_exposure.md` in memory and [ADR-019](decisions/019-ingress-and-tls-termination.md).
- **Hetzner VPS → K8s cluster** ingress uses a dedicated WireGuard `/30` tunnel VPS ↔ R730xd, with iptables DNAT on R730xd forwarding only TCP 30487/30356 to the K8s NodePort. No subnet routes.

### Security

- **Flat lab network** — per-machine SSH keys, host firewalls, and K8s RBAC / network policies are the only isolation. A real segmentation story waits on the deferred VLAN config (Checkpoint D).
- External exposure is scoped: only the VPS is publicly reachable, and it reaches home via the point-to-point WG tunnel to R730xd on exactly two TCP ports.

## Management Network

Out-of-band management (iDRAC, BMC/IPMI) lives on the lab subnet and is reachable directly from any lab-side machine.

| Interface | IP | Notes |
|-----------|-----|-------|
| R730xd iDRAC | `{{ r730xd_idrac_ip }}` | SSH racadm working; no Enterprise license (no virtual media). HTTPS web UI fine for basic monitoring. |
| Quanta BMC/IPMI | `{{ quanta_bmc_ip }}` | Static IP, dedicated NIC port. |

## Network Equipment Available

| Equipment | Location | Notes |
|-----------|----------|-------|
| SR2024 (24-port managed GbE + 2 SFP) | Garage (live) | VLAN-capable; flat today, VLANs deferred per [ADR-021](decisions/021-off-the-shelf-router-tower-pc-as-worker.md). |
| 1× Aerohive AP130 (#1) | Live, PoE injector | Secondary AP in the standalone roaming hive — see above. |
| 1× Aerohive AP130 (#2) | Spare (mount pending) | PoE, standalone-mode confirmed. Older firmware, 1 bad NAND block. |
| 1× Aerohive AP230 | Spare (mount pending) | PoE, standalone-mode confirmed. Higher performance than AP130s. |
| 1× Aerohive AP630 | Live, PoE injector | Primary AP in the standalone roaming hive — see above. Stock HiveOS restored 2026-04-03 ([ADR-011](decisions/011-ap630-restored-to-stock-wifi-ap.md)). |
| R730 4-port NIC | In R730xd | Could dedicate ports to a storage VLAN once VLANs are enabled. |
| Xfinity gateway | Living room | **Bridge mode** — WAN uplink to the EX50 only (cut over 2026-07-08, [ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md)). |
| Digi EX50 | Garage (live) | **The router/gateway at `10.0.0.1`** (cut over 2026-07-08) — 2× 2.5 GbE, scriptable DAL in IaC (`configure-ex50.yml`); its own WiFi off (the Aerohive APs serve WiFi). See [ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md). |
