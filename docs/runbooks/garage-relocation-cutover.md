# Runbook: Garage Relocation + EX50 Router Cutover

Staged procedure for two interlocked jobs done in one maintenance window:

1. **Physically relocate** the platform (machines + SR2024 + Xfinity gateway) from the closet to the garage — [ADR-045](../decisions/045-platform-relocation-to-garage.md).
2. **Cut the Digi EX50 in** as the router, replacing the Xfinity gateway's routing role — [ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md).

Segmentation ([ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md)) and the ingress-tunnel relocation ([ADR-047](../decisions/047-ingress-tunnel-relocation-to-ex50.md)) layer on top as later checkpoints.

> **Design principle: one variable at a time.** The work is one window because of hard dependencies (APs need switch PoE; the switch moves to the garage; bridge cutover wants APs live). But it is *staged* into checkpoints A–E, each independently verifiable and reversible. A failure at any checkpoint rolls back to the previous known-good state without touching the others.

Last updated: 2026-07-02 · Status: **planned, not yet executed.**

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
- [ ] **Bench-configure the EX50** with WAN unplugged: LAN `10.0.0.1/24`, DHCP scope for home on `10.20.0.0/24` (keep the platform range static/reserved), DNS forwarding, firewall default-deny home→platform. Flat first — do **not** enable the home VLAN yet.
- [ ] **Verify on the bench** that DAL supports what later steps rely on: a WireGuard peer + DNAT from the wg interface to a LAN host (E), multiple VLAN interfaces + inter-VLAN firewall (D), DHCP reservations, and (optionally) local DNS records. Capture the DAL shell config commands into the IaC now.
- [ ] **Garage physical prep:** rack/shelf **off the slab** (below-grade water risk), 20 A circuit + PDU sizing, active ventilation confirmed, **humidity + leak sensors placed** (ADR-045), small UPS for the network core (Xfinity + EX50 + SR2024 + APs).
- [ ] **Extend the coax** to the garage (available slack).
- [ ] **Pre-pull AP cable runs** from the garage SR2024 location to AP mount points (the only long runs; can be fully done in advance).
- [ ] **Pre-configure Aerohive APs** standalone SSID (SSID/PSK), CAPWAP disabled (already factory-reset per `docs/hardware.md`).
- [ ] **Snapshot current state** for rollback reference: `wg show`, iptables counters on R730xd, `kubectl get nodes -o wide`, `kubectl get pv`, and confirm `*.bearflinn.com` is green from an external host.

---

## Checkpoint A — Relocate on Xfinity (no logical change)

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

Goal: house WiFi served by the Aerohive APs, independent of the Xfinity gateway, so bridging Xfinity in C doesn't black out WiFi.

1. Mount/connect APs to the SR2024 (PoE); bring up the standalone SSID.
2. Verify coverage on the Aerohive SSID from around the house.

**Verify:** clients associate to the Aerohive SSID, get internet (still via Xfinity→SR2024), and roam acceptably.
**Rollback:** fall back to the Xfinity SSID; APs are additive and don't affect the wired path.

---

## Checkpoint C — Router swap (still flat)

Goal: EX50 is the router; network still flat on `10.0.0.0/24`.

1. Put the Xfinity gateway into **bridge mode** (confirmed supported on this model).
2. Insert the EX50: WAN → Xfinity gateway LAN; EX50 LAN (trunk) → SR2024 uplink. EX50 = `10.0.0.1`.
3. EX50 serves DHCP/DNS for non-static clients; platform statics unchanged.

**Verify:**
```
curl -s https://ifconfig.co             # internet via EX50 (public IP may change — informational)
kubectl get nodes -o wide               # cluster healthy
# a DHCP client (phone/laptop) pulls a lease from the EX50 and resolves DNS
curl -I https://<some>.bearflinn.com    # ingress still green (tunnel still on R730xd, transparent to the swap)
```
**Rollback:** pull the EX50, take the Xfinity gateway out of bridge mode, reconnect SR2024 → Xfinity LAN → back to Checkpoint A state. Update `home_public_ip` in `network.yml` if it changed (informational only; ingress is home-initiated so it doesn't break).

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
