# Runbook: Garage Relocation + EX50 Router Cutover

Staged procedure for two interlocked jobs done in one maintenance window:

1. **Physically relocate** the platform (machines + SR2024 + Xfinity gateway) from the closet to the garage — [ADR-045](../decisions/045-platform-relocation-to-garage.md).
2. **Cut the Digi EX50 in** as the router, replacing the Xfinity gateway's routing role — [ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md).

Segmentation ([ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md)) and the ingress-tunnel relocation ([ADR-047](../decisions/047-ingress-tunnel-relocation-to-ex50.md)) layer on top as later checkpoints.

> **Design principle: one variable at a time.** The work is one window because of hard dependencies (APs need switch PoE; the switch moves to the garage; bridge cutover wants APs live). But it is *staged* into checkpoints A–E, each independently verifiable and reversible. A failure at any checkpoint rolls back to the previous known-good state without touching the others.

Last updated: 2026-07-07 · Status: **Checkpoints A–B complete; C pre-staged, physical swap remaining (see [in-progress tracker](../in-progress/garage-ex50-cutover.md)); D–E not started.**

---

## End-state topology

```
        [Xfinity Gateway — BRIDGE mode]   (garage, coax extended)
                     |
                     | 2.5GbE WAN
                     v
             +------------------+
             |   Digi EX50      |  10.0.0.1 (platform gw) + 10.20.0.1 (home gw)
             |  NAT/DHCP/DNS/FW |  WireGuard ingress endpoint (Checkpoint E)
             |  PoE-powered     |  scriptable DAL → stays in IaC
             +------------------+
                     | 2.5GbE LAN (trunk)
                     v
             +------------------+
             |   SR2024switch   |  PoE to APs; VLAN trunk/access
             +------------------+
              |    |    |     \
   platform VLAN   ...   trunk to APs (home + guest SSIDs)
   (10.0.0.0/24)              |
   R730xd, Quanta,            v
   NUC, Optiplex,        Aerohive APs  ── home clients → 10.20.0.0/24
   Inspiron, Tower,          legacy consumer switch chain → 10.20.0.0/24
   jumpbox
```

- **Platform stays `10.0.0.0/24`** — every static IP unchanged. EX50 takes `10.0.0.1` (the address the Xfinity gateway holds today).
- **Home moves to `10.20.0.0/24`** (proposed) — DHCP from the EX50.
- **Internal DNS resolver** (`.internal`, [ADR-036](../decisions/036-internal-dns-zone.md)) can move off R730xd to the EX50 as an additive follow-up — not required by this cutover.

---

## Prerequisites (do ahead — zero downtime)

- [ ] **EX50 firmware ≥ 24.3.28.88** (required for WireGuard, Checkpoint E). Update if lower.
- [x] **EX50 config validated on-device + hardening pre-staged** (2026-07-07). The flat-cutover delta (`ansible/files/ex50/config.dal.j2`: LAN `10.0.0.1/24`, DHCP pool `10.0.0.50–10.0.0.150` off the platform statics per issue #80, drop the "allow all" rule, disable modem + built-in WiFi, NTP on) passes the on-device `validate` verb. It is **not pre-applied** — the LAN/DHCP change would collide with Xfinity's live `10.0.0.1` + serve rogue DHCP, so it lands *at* Checkpoint C once Xfinity is bridged. Already done ahead: SSH-ACL `wan` zone removed, factory DHCP server disabled, and the SR2024 mgmt made static `10.0.0.153`. Getting onto the Admin CLI: [ex50-console-access.md](ex50-console-access.md).
- [ ] **Verify on the bench** that DAL supports what later steps rely on: a WireGuard peer + DNAT from the wg interface to a LAN host (E), multiple VLAN interfaces + inter-VLAN firewall (D), DHCP reservations, and (optionally) local DNS records. Capture the DAL shell config commands into the IaC now.
- [ ] **Garage physical prep — operator-handled:** sturdy shelving is already in place (gear sits off the slab); the garage dehumidifier (hosed outside) holds ~43% RH year-round, with a closet-specific unit as contingency; 20 A circuit near the panel with headroom to add another. **These environmental logistics are settled (ADR-045) — do not relitigate.** Remaining prep for the window: PDU sizing, confirm ventilation, small UPS for the network core (Xfinity + EX50 + SR2024 + APs), and place humidity + leak sensors (as verification signals, not gating decisions).
- [ ] **Extend the coax** to the garage (available slack).
- [ ] **Pre-pull AP cable runs** from the garage SR2024 location to AP mount points (the only long runs; can be fully done in advance).
- [ ] **Pre-configure the Aerohive APs** (AP630 + AP130) — standalone SSID, CAPWAP disabled — per [aerohive-ap-setup.md](aerohive-ap-setup.md). Recommend matching the existing house SSID + PSK so clients roam over seamlessly when Xfinity is bridged.
- [ ] **Snapshot current state** for rollback reference: `wg show`, iptables counters on R730xd, `kubectl get nodes -o wide`, `kubectl get pv`, and confirm `*.bearflinn.com` is green from an external host.

---

## Checkpoint A — Relocate on Xfinity (no logical change)

**Done — 2026-07-05,** ahead of this staged plan: an extended power outage forced the physical move (SR2024 + all machines) from the closet to the garage in one go, coming back up on the same flat `10.0.0.x` network. See [docs/network.md](../network.md) and [ADR-045](../decisions/045-platform-relocation-to-garage.md). The steps below are the plan as originally staged; kept for reference and rollback context.

Goal: platform physically in the garage, still routed by the Xfinity gateway in **router** mode. Nothing about IPs or routing changes.

1. Drain/cordon K8s workers; graceful-shutdown the cluster and R730xd services (or clean OS shutdown of all machines).
2. Move machines + SR2024 + Xfinity gateway to the garage; extend coax; Xfinity **stays in router mode at `10.0.0.1`**.
3. Short-patch every machine to the SR2024; uplink SR2024 → Xfinity LAN.
4. Power up in dependency order: R730xd (storage) → control plane → workers.

**Verify:**
```
# from the jumpbox
kubectl get nodes -o wide          # all Ready, IPs unchanged (10.0.0.x)
kubectl get pv                     # all Bound
ping 10.0.0.200                    # R730xd
curl -I https://<some>.bearflinn.com   # external ingress still green (tunnel re-established)
```
**Rollback:** none needed — nothing logical changed. If a machine misbehaves it is a physical/cabling issue, not a routing one.

> House WiFi at this point is just the Xfinity radio in the garage — degraded coverage, acceptable for the window. It goes away at Checkpoint C, which is why B comes first.

---

## Checkpoint B — APs up on the garage switch

**Done — 2026-07-07.** APs are live and roaming on the standalone house SSID (shared hive secret + 802.11r/k/v), powered via PoE injectors (SR2024's own PoE is not delivering — [#84](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/84)). See [aerohive-ap-setup.md](aerohive-ap-setup.md).

Goal: house WiFi served by the Aerohive APs, independent of the Xfinity gateway, so bridging Xfinity in C doesn't black out WiFi.

1. Mount/connect APs to the SR2024 (PoE); bring up the standalone SSID per [aerohive-ap-setup.md](aerohive-ap-setup.md).
2. Verify coverage on the Aerohive SSID from around the house.

**Verify:** clients associate to the Aerohive SSID, get internet (still via Xfinity→SR2024), and roam acceptably.
**Rollback:** fall back to the Xfinity SSID; APs are additive and don't affect the wired path.

---

## Checkpoint C — Router swap (still flat)

Goal: EX50 is the router; network still flat on `10.0.0.0/24`.

> **This is a fully local, offline-runnable step.** During the swap the internet is down, so run everything from the **control node** over the LAN — nothing here needs external connectivity (no Anthropic, no GitHub). Have this file open locally before you start.

**Pre-staged already (done 2026-07-07, verified — do NOT redo):**
- SR2024 mgmt is static `10.0.0.153` (DHCP client disabled, gateway `10.0.0.1`, saved). Reach it: `ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1 -o Ciphers=+aes128-cbc admin@10.0.0.153` (creds `admin`/`aerohive`). CIDR syntax is `interface mgt0 ip 10.0.0.153/24` — **not** the old `ip ADDR MASK` form.
- EX50 SSH-ACL `wan` zone removed (WAN SSH denied). EX50 factory DHCP server disabled.
- EX50 config is **validated on-device** but deliberately **not pre-applied**: the LAN→`10.0.0.1` + DHCP change must land only once Xfinity has vacated `10.0.0.1`, else you get a duplicate gateway + rogue DHCP on the live LAN.

**Steps:**

1. Put the Xfinity gateway into **bridge mode** (confirmed supported on this model). It vacates `10.0.0.1` and stops serving DHCP.
2. Cable the EX50: WAN → Xfinity gateway LAN; EX50 LAN → SR2024. (LAN may already be patched from the bench.)
3. **Apply the EX50 router config** from the control node — it reaches the box over IPv6 link-local (unaffected by the IPv4 change). Discover the link-local first (Digi OUI `00:40:9d`), then run the playbook:
   ```
   cd ~/Projects/grizzly-platform
   ip -6 neigh | grep -i '00:40:9d'      # → fe80::…%enp6s0   (the EX50)
   ansible-playbook ansible/playbooks/configure-ex50.yml -e ex50_host='fe80::…%enp6s0'
   ```
   This sets LAN `10.0.0.1/24`, DHCP pool `10.0.0.50–10.0.0.150` (issue #80 carve-out), drops the "allow all" test rule, disables the modem + the stray built-in WiFi, NTP on — then `save`. **Fallback if ansible misbehaves offline** (same validated DAL, piped straight in):
   ```
   printf 'config\nnetwork interface lan ipv4 address 10.0.0.1/24\nnetwork interface lan ipv4 dhcp_server enable true\nnetwork interface lan ipv4 dhcp_server lease_start 50\nnetwork interface lan ipv4 dhcp_server lease_end 150\ndel firewall filter 2\nnetwork interface modem enable false\nnetwork modem modem enable false\nnetwork wifi ap digi_ap1 enable false\nservice ntp enable true\nsave\nexit\n' | ssh admin@'fe80::…%enp6s0'
   ```
4. **Renew the control node's DHCP** — it was on `.151` (outside the new pool), so pull a fresh lease from the EX50 (NetworkManager): `sudo nmcli device disconnect enp6s0 && sudo nmcli device connect enp6s0`.

**Verify (all local):**
```
ssh admin@10.0.0.1 'show config' | grep -E 'lan ipv4|dhcp_server|filter'   # LAN 10.0.0.1/24, DHCP 50–150, no filter 2
ip -4 addr show enp6s0                    # control node now has a 10.0.0.50–150 lease
ping -c2 1.1.1.1                          # internet via the EX50
kubectl get nodes -o wide                # cluster healthy
curl -I https://<some>.grizzly-endeavors.com   # ingress still green (tunnel still on R730xd, transparent to the swap)
```
**Then, once WAN is up — the one remaining hardening gate:** from an **external** host (phone on cellular, etc.), `ssh admin@<public-ip>` must **fail** (the `wan` ACL entry was pre-removed; this just confirms it). If it succeeds, re-check `show service ssh acl` — no `wan` interface entry should be present.

**Rollback:** pull the EX50, take the Xfinity gateway out of bridge mode, reconnect SR2024 → Xfinity LAN → back to Checkpoint A state. The SR2024's static `.153` and the APs keep working on the flat net regardless. Update `home_public_ip` in `network.yml` if it changed (informational only; ingress is home-initiated so it doesn't break).

> A–C get you fully relocated and routed by the EX50. D and E are additive — do them now if the window has time, otherwise a follow-up window.

---

## Checkpoint D — Segment (evict home)

Goal: platform alone on `10.0.0.0/24`; home devices on `10.20.0.0/24`. See [ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md). **The platform does not move** — this only relocates home devices.

1. Enable the home VLAN + `10.20.0.0/24` subnet on the EX50 (DHCP, gateway `10.20.0.1`).
2. On the SR2024: platform machine ports stay access on the platform VLAN; trunk the home/guest SSIDs to the APs; move the legacy consumer switch chain uplink onto the home VLAN.
3. Move home/personal devices and the home SSID onto `10.20.0.0/24`.
4. Apply the EX50 firewall policy: default-deny `home → platform`, allow only the specific flows the platform needs (e.g. operator paths); `platform → internet` allowed.

**Verify:**
```
# platform unchanged
kubectl get nodes -o wide               # still 10.0.0.x, Ready
kubectl get pv                          # still Bound
# home device is on the new subnet and firewalled off the platform
#   home client: ip addr → 10.20.0.x ; can reach internet
#   home client: cannot reach 10.0.0.0/24 platform hosts (except allowed flows)
curl -I https://<some>.bearflinn.com    # ingress still green
```
**Rollback:** collapse the home VLAN back onto the flat `10.0.0.0/24` (Checkpoint C state); platform was never touched.

---

## Checkpoint E — Move the ingress tunnel to the EX50

Goal: WireGuard endpoint + DNAT move from R730xd to the EX50. See [ADR-047](../decisions/047-ingress-tunnel-relocation-to-ex50.md). Keep R730xd's path live until the EX50 path is proven.

1. Retarget the `ingress-tunnel` role at the EX50 (DAL shell): bring up the wg interface, initiate outbound to the VPS, `PersistentKeepalive` on.
2. On the VPS: repoint the WireGuard peer to the EX50's public key; move the home-side `/30` address to the EX50. **Caddy config unchanged.**
3. On the EX50: DNAT TCP `30487`/`30356` from the wg interface → `10.0.0.226` (Inspiron). No other ports.
4. Repoint `k8s_ingress_ip` in `network.yml` from `wg_r730xd_ip` to the EX50 tunnel IP.

**Verify:**
```
# on the EX50 and VPS
wg show                                 # handshake + recent transfer on both ends
# externally
curl -I https://<some>.bearflinn.com    # green via the new path
```
5. Only after the new path is verified end-to-end: **tear down R730xd's tunnel + DNAT** and retire that side of the `ingress-tunnel` role.

**Rollback:** repoint the VPS peer back to R730xd (whose path is still intact until step 5) → back to the pre-E ingress path.

---

## Post-cutover — update the record

- [ ] `docs/network.md`, `docs/hardware.md` — move the EX50 into the live tables; reflect the garage location and the two subnets.
- [ ] `docs/exploration/network-vlans.md` — fold the realized design back in (or retire it if fully realized).
- [ ] `home_public_ip` in `network.yml` if it changed under bridge mode.
- [ ] Confirm humidity/leak/temp sensors are reporting into the observability stack with alert thresholds (ADR-045 readiness items).
- [ ] Log the completion date and any deviations here.

## Operational readiness (per CLAUDE.md checklist)

- **Health signals:** `kubectl get nodes/pv`; `wg show` on the ingress endpoint; EX50 WAN/LAN status; AP association counts; **garage temp + relative humidity + leak sensor.**
- **Failure detection / alerts:** ingress down (external synthetic check on `*.bearflinn.com`), humidity over threshold, leak sensor tripped, UPS on battery — routed to the existing alert destination (Ntfy).
- **Dependencies:** platform internet + ingress now depend on the EX50 (border) and the coax→garage run; storage still depends on R730xd; ingress no longer depends on R730xd after E.
- **Recovery:** each checkpoint above documents its rollback. EX50 config is in IaC (ADR-044), so a bricked/replaced unit is re-provisioned from the role, not rebuilt by hand.
