# Runbook: Reaching the Digi EX50 CLI (bench bring-up)

How to get onto the EX50's scriptable **DAL Admin CLI** before/during the garage cutover. Companion to [garage-relocation-cutover.md](garage-relocation-cutover.md) (the "Bench-configure the EX50" / "Capture the DAL shell config commands into the IaC" prerequisites) and [ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md).

Last updated: 2026-07-03 · Status: **bench bring-up in progress.** Network SSH path proven; serial console blocked (see discrepancy below).

---

## The one thing to know

The scriptable surface — the **DAL "Admin CLI"** — is *identical* over SSH (network) and over the serial console. Serial's only unique value is out-of-band access when the network is down; it is **not** required to map or automate the box. For IaC (Ansible driving the EX50), **SSH to the Admin CLI is the real target**. The web UI and Digi Remote Manager (DRM) expose the same config but are not the automation path here.

---

## Management surfaces

| Surface | Endpoint | Status (2026-07-03) | Role |
|---|---|---|---|
| **SSH → Admin CLI** | `admin@<ex50>` :22 | **Open, confirmed** (`SSH-2.0-OpenSSH_10.0`, `publickey,keyboard-interactive`) | **Primary / IaC automation target.** Accepts SSH keys → key-based Ansible auth is viable. |
| **HTTPS web UI** | `https://<ex50>` :443 | **Open, confirmed** (`200 OK`) | Human/GUI config; mirror of the CLI. |
| HTTP | :80 | Open (redirect) | — |
| Serial console | RJ45 jack, RS-232 | **Blocked** — zero bytes (see below) | Out-of-band fallback only. |
| Telnet / SNMP / :8080 | :23 / :161 / :8080 | Filtered (disabled) | — |
| Digi Remote Manager | cloud | account exists | Secondary; not the main interface (per operator). |

Login for all local surfaces: user `admin`, the **unique factory password on the device label** (Digi ships per-device unique passwords, not a shared default). Held by the operator; not in this repo.

---

## Recommended bootstrap path: SSH over IPv6 link-local

The EX50 is already cabled to the flat `10.0.0.0/24` LAN, but it presents **no IPv4 address on that subnet** — it is still on its factory-default LAN subnet (check the label / user guide for the exact default; Digi DAL default LAN is typically `192.168.2.1`), which is not routable from `10.0.0.0/24`. It *is* directly reachable over **IPv6 link-local**, which needs no recabling and no matching subnet.

Discovery (how it was found):
- ARP/ND neighbor table showed MAC `00:40:9d:e0:80:81` — OUI `00:40:9D` = **Digi International** — emitting IPv6 router advertisements on `enp6s0`.
- Link-local address: `fe80::240:9dff:fee0:8081` (derived from the MAC via EUI-64).
- `nmap -6` confirmed 22/80/443 open.

Connect (replace the interface if not `enp6s0`):
```
ssh admin@fe80::240:9dff:fee0:8081%enp6s0
# web UI: https://[fe80::240:9dff:fee0:8081%25enp6s0]/   (%25 = URL-encoded % in a browser)
```
To rediscover the link-local address after a reboot/relabel: `ip -6 neigh | grep -i '00:40:9d'`.

Alternative (cleaner IPv4): put a laptop on the EX50's default LAN subnet (static IP in that range) and SSH to the default gateway, or set the EX50's LAN to `10.0.0.1/24` during bench config so it joins the platform range.

---

## Discrepancy: serial console is silent

**Symptom:** With the USB↔RS-232 adapter on `/dev/ttyUSB0` (FTDI FT232R), the console returns **zero bytes at every standard baud rate** (9600 → 460800), with or without DTR/RTS asserted.

**EX50 serial port spec** ([Digi docs](https://docs.digi.com/resources/documentation/digidocs/90002435/device/enterprise/enterprise-serial-port-pinout-and-use.htm)): female **RJ45** jack, **RS-232** levels, **DTE**. Pinout:

| RJ45 pin | Signal | Direction |
|---|---|---|
| 1 | RTS | out of EX50 |
| 2 | DCD | into EX50 |
| **3** | **RXD** | **into EX50** (← adapter TX) |
| 4 / 5 | GND | — |
| **6** | **TXD** | **out of EX50** (→ adapter RX) |
| 7 | DTR | out of EX50 |
| 8 | CTS | into EX50 |

(RI and DSR are not implemented.)

**Leading suspect (electrical/wiring, not software):** the operator's cable is a store-bought **USB-to-RS-232 DB9/DB25** lead — true RS-232 levels, so the *level* layer is fine. But a DB9 cannot reach the EX50's **RJ45** jack without an RJ45↔DB9 adapter, and **both ends are DTE**, so that adapter must implement a **TX/RX crossover** matching Digi's pinout:

```
EX50 RJ45 pin 6 (TXD) ──► DB9 pin 2 (RXD, into PC)
EX50 RJ45 pin 3 (RXD) ◄── DB9 pin 3 (TXD, out of PC)
EX50 RJ45 pin 4/5 (GND) ─ DB9 pin 5 (GND)
```
A **generic (Cisco-style) RJ45↔DB9 rollover adapter uses a different pinout and will not work** with the Digi jack. Secondary possibilities if the wiring is later confirmed correct: the serial port not being in **Login/console access mode**, or the unit being powered off during the test.

### Audit trail (what was tried / ruled out)

| Check | Result | Conclusion |
|---|---|---|
| Baud sweep 9600–460800 | 0 bytes at all | Not a baud mismatch |
| DTR/RTS toggled through all 4 states | 0 bytes at all | Console not gated on modem control lines |
| FTDI kernel enumeration + open + line-status | Healthy; `ttyUSB0` attached; control lines respond | Adapter USB side is fine |
| Level-mismatch (TTL-vs-RS-232) hypothesis | **Discarded** — cable is a true USB↔RS-232 DB9, not a bare TTL breakout | Blocker is the RJ45↔DB9 interface, not signal levels |

**To resume serial:** verify the RJ45↔DB9 adapter follows the Digi pinout above (crossover), confirm the EX50 is powered and its serial port is in Login mode, then re-test with `picocom -b 115200 /dev/ttyUSB0` (or the `serctl.py` helper used during bring-up). Not on the critical path — the network SSH surface above is sufficient to map and automate the device.

---

## Next steps

- [ ] Log into the Admin CLI over SSH (device-label password) and map the scriptable surface: config schema (`show config`), export/import format for IaC, WireGuard support (firmware ≥ 24.3.28.88, [ADR-047](../decisions/047-ingress-tunnel-relocation-to-ex50.md)), VLAN/DHCP/DNS/firewall/DNAT primitives ([ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md)).
- [ ] Enroll an SSH public key for the future Ansible role (SSH already advertises `publickey`).
- [ ] Confirm firmware version against the ≥ 24.3.28.88 WireGuard gate.
- [ ] (Optional) Fix the serial console per the discrepancy section, for true out-of-band access.
