# Runbook: Reaching the Digi EX50 CLI (bench bring-up)

How to get onto the EX50's scriptable **DAL Admin CLI** before/during the garage cutover. Companion to [garage-relocation-cutover.md](garage-relocation-cutover.md) (the "Bench-configure the EX50" / "Capture the DAL shell config commands into the IaC" prerequisites) and [ADR-044](../decisions/044-digi-ex50-as-off-the-shelf-router.md).

Last updated: 2026-07-07 · Status: **bench bring-up complete.** Network SSH path proven and key-auth enrolled; full interface mapped in [../ex50-dal-interface.md](../ex50-dal-interface.md); the flat-cutover config is authored and validated on-device ([`ansible/playbooks/configure-ex50.yml`](../../ansible/playbooks/configure-ex50.yml) + [`ansible/files/ex50/config.dal.j2`](../../ansible/files/ex50/config.dal.j2)) — only the physical swap remains, see [garage-relocation-cutover.md](garage-relocation-cutover.md). Serial console still blocked on cable pinout (see discrepancy below; off critical path).

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

Discovery (how it was found): the IPv6 neighbor table showed a device with the **Digi International** OUI (`00:40:9D`) emitting router advertisements on the LAN interface; its EUI-64 link-local address was derived from that, and `nmap -6` confirmed 22/80/443 open. (The unit's specific MAC / link-local are kept out of this public repo — the EX50 is the border device.)

Find it and connect (replace `<iface>` with your LAN interface, e.g. `enp6s0`):
```
ip -6 neigh | grep -i '00:40:9d'          # Digi OUI -> fe80::…%<iface>
ssh admin@fe80::…%<iface>
# web UI: https://[fe80::…%25<iface>]/     (%25 = URL-encoded % in a browser)
```

Alternative (cleaner IPv4): put a laptop on the EX50's default LAN subnet (static IP in that range) and SSH to the default gateway, or set the EX50's LAN to `10.0.0.1/24` during bench config so it joins the platform range.

---

## Discrepancy: serial console is silent

**Symptom:** With the USB↔serial cable on `/dev/ttyUSB0` (FTDI FT232R), the console returns **zero bytes at every standard baud rate** (9600 → 460800), with or without DTR/RTS asserted.

**Device side is fine — confirmed over SSH.** `show serial` reports the console port `port1` in **Mode `login`** at **`9600` baud** (signals RTS/DTR/DSR). So the port is enabled, in login mode, and at a baud the sweep covered — the silence is **not** a device-config or baud problem. That isolates the fault to the **physical cable/pinout**.

**Root cause — pinout mismatch.** The cable is a **generic direct USB-to-RJ45 console cable** (no DB9/adapter in between). Those are wired to the **Cisco "rollover" console pinout**, which does not match Digi's RJ45 serial pinout — so the EX50's TXD (pin 6) never lands on the adapter's RX, and we get nothing even at the correct 9600 baud.

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

(RI and DSR are not implemented.) A cable wired for the EX50 must cross EX50 TXD (pin 6) → adapter RX and EX50 RXD (pin 3) ← adapter TX, with GND on 4/5. A Cisco-rollover console cable does not do this.

### Audit trail (what was tried / ruled out)

| Check | Result | Conclusion |
|---|---|---|
| Baud sweep 9600–460800 | 0 bytes at all | Not a baud mismatch (device is at 9600) |
| DTR/RTS toggled through all 4 states | 0 bytes at all | Console not gated on modem control lines |
| FTDI kernel enumeration + open + line-status | Healthy; `ttyUSB0` attached; control lines respond | Adapter USB side is fine |
| `show serial` over SSH | `port1` Mode `login` @ 9600 | Device-side console is enabled and correct — fault is off-device |
| Level-mismatch (TTL-vs-RS-232) hypothesis | **Discarded** — cable is a real store-bought USB↔RS-232, not a bare TTL breakout | Not a signal-level problem |
| RJ45↔DB9-adapter hypothesis | **Discarded** — cable is direct USB-to-RJ45, no adapter | Fault is the cable's internal (Cisco-rollover) pinout, not a missing adapter |

**To resume serial (optional, off critical path):** get a console cable/adapter wired to Digi's RJ45 pinout above (not a Cisco rollover), keep 9600 baud, and re-test with `picocom -b 9600 /dev/ttyUSB0` (or the `serctl.py` helper used during bring-up, pointed at 9600). The network SSH surface above already gives the full CLI, so serial is only worth fixing for true out-of-band access.

---

## Next steps

- [x] Enroll an SSH public key (`bearflinn@gmail.com`) on `auth user admin` — key auth working over link-local.
- [x] Confirm firmware against the WireGuard gate — **25.11.10.42 ≥ 24.3.28.88**, satisfied.
- [x] Map the scriptable surface (config model, domains, cutover paths) → [../ex50-dal-interface.md](../ex50-dal-interface.md).
- [x] Bench-config per the cutover runbook (LAN → `10.0.0.1/24`, DHCP pool carve-out, zone firewall, "Allow all for testing" rule dropped, SSH `wan` ACL removed) and templated into `ansible/playbooks/configure-ex50.yml` — validated on-device, not yet applied (see [garage-relocation-cutover.md](garage-relocation-cutover.md) Checkpoint C).
- [ ] (Optional) Fix the serial console per the discrepancy section, for true out-of-band access.
