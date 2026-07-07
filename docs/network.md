# Network Topology

The live lab network. Flat L2 today on the SR2024, with a dedicated point-to-point WireGuard tunnel between the Hetzner VPS and the R730xd for public ingress.

> **IP addresses:** Authoritative values are in `ansible/group_vars/all/network.yml`. This doc renders the Jinja vars literally.

For the pending VLAN redesign, see [exploration/network-vlans.md](exploration/network-vlans.md).

> **Platform physically relocated to the garage (2026-07-05).** During an extended power outage the whole lab (SR2024 + all machines) was moved from the closet to the garage and came back up on the same flat 10.0.0.x network. This was a physical move only — the **Digi EX50 router cutover and L3 segmentation were not performed** and remain pending: see [runbooks/garage-relocation-cutover.md](runbooks/garage-relocation-cutover.md) and ADRs [044](decisions/044-digi-ex50-as-off-the-shelf-router.md) (EX50 as router), [046](decisions/046-platform-network-segmentation-via-home-eviction.md) (segmentation), [047](decisions/047-ingress-tunnel-relocation-to-ex50.md) (ingress move). ADR [045](decisions/045-platform-relocation-to-garage.md) (garage relocation) is now realized. The topology below is the *live* flat network — still Xfinity gateway upstream, still no VLANs.

Last updated: 2026-07-05 (platform relocated to garage; EX50 cutover still pending)

## Physical Topology

All lab machines are in the garage on the SR2024 (relocated from the closet 2026-07-05). Non-lab drops (bedroom, workshop, etc.) continue to run through the legacy consumer switch chain — see [ADR-008](decisions/008-keep-existing-switch-chain-for-home.md).

```
                [Xfinity Gateway]
            Router / DHCP / DNS / WAN
                 Living Room
                      |
                      | (cable to garage)
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

- **Xfinity gateway still handles routing, DHCP, and upstream DNS.** This is interim — an off-the-shelf router ([ADR-021](decisions/021-off-the-shelf-router-tower-pc-as-worker.md)) will replace it, at which point the gateway goes into bridge mode.
- Lab machines use static IPs configured at the OS level (Ansible-managed).
- **DHCP plan at the EX50 cutover (issue #80):** the EX50 serves a dynamic pool of **`10.0.0.50–10.0.0.150`**, deliberately carved to contain **none** of the OS-static node IPs (`.46`, `.153`, `.187`, `.200–.203`, `.226`, `.249`). Statics are "reserved by exclusion" — outside the assignable pool, so a router or lease-table reset can never hand a statically-held address to a DHCP client. No per-host MAC reservations. The one platform device that *leases* today, the SR2024 switch (`.153`), is given a static mgmt IP on the switch itself at cutover (it sits above the pool). Boundaries live in `ansible/group_vars/all/network.yml` (`ex50_dhcp_pool_*`); applied by `ansible/playbooks/configure-ex50.yml`.

### Switching

- **SR2024** is the lab backbone in the garage. All lab machines (live cluster + R730xd + pending Tower PC) connect directly to it.
- **Flat L2** — no VLANs configured yet. VLAN design lives in [exploration/network-vlans.md](exploration/network-vlans.md) and is deferred until the purchased router arrives, so inter-VLAN routing happens on the new router rather than being grafted onto the Xfinity gateway.
- Legacy consumer switches still serve the bedroom / garage / workshop drops (ADR-008).

### WiFi

- **AP630 (primary) + one AP130 (secondary) are configured and live** (2026-07-07) as a single standalone roaming hive (`grizzly-hive`, 802.11r/k/v), one flat untagged WPA2-AES-PSK SSID. AP630: 11ax, ch 1/36. AP130: 11ng/11ac, ch 6/149. Configs: `ansible/files/aerohive/ap630.hiveos` / `ap130.hiveos`; procedure: [runbooks/aerohive-ap-setup.md](runbooks/aerohive-ap-setup.md). The spare AP230 is unconfigured.
- **APs are powered by PoE injectors** — the SR2024's own PoE is not delivering (PSE failure, [#84](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/84)); the earlier "PoE from the SR2024, no injectors" plan does not currently hold.
- Xfinity gateway WiFi can be retired once the Aerohive coverage is confirmed around the house.

### DNS

- Xfinity gateway for upstream. Lab internal names still live in `/etc/hosts` via Ansible. Local DNS (on the future router) is a target for post-router work.

### VPN / Ingress

- **NetBird** for operator admin access (admin group: jumpbox, R730xd, K8s nodes as needed). Hetzner VPS is deliberately **not** in the admin group — see `feedback_vps_home_exposure.md` in memory and [ADR-019](decisions/019-ingress-and-tls-termination.md).
- **Hetzner VPS → K8s cluster** ingress uses a dedicated WireGuard `/30` tunnel VPS ↔ R730xd, with iptables DNAT on R730xd forwarding only TCP 30487/30356 to the K8s NodePort. No subnet routes.

### Security

- **Flat lab network** — per-machine SSH keys, host firewalls, and K8s RBAC / network policies are the only isolation. A real segmentation story waits on the purchased router and the deferred VLAN config.
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
| 2× Aerohive AP130 | Spare (mount pending) | PoE, standalone-mode confirmed. |
| 1× Aerohive AP230 | Spare (mount pending) | PoE, standalone-mode confirmed. Higher performance than AP130s. |
| 1× Aerohive AP630 | Spare (mount pending) | Stock HiveOS restored 2026-04-03 ([ADR-011](decisions/011-ap630-restored-to-stock-wifi-ap.md)). Highest-performance AP. |
| R730 4-port NIC | In R730xd | Could dedicate ports to a storage VLAN once VLANs are enabled. |
| Xfinity gateway | Living room (→ garage at cutover) | WAN uplink; still the router today. Goes into bridge mode when the Digi EX50 is cut in ([ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md)); relocates to the garage with the platform ([ADR-045](decisions/045-platform-relocation-to-garage.md)). |
| Digi EX50 | Acquired (bench) | Chosen off-the-shelf router — 2× 2.5 GbE, WiFi 6, scriptable DAL (stays in IaC). Cutover pending. See [ADR-044](decisions/044-digi-ex50-as-off-the-shelf-router.md). |
