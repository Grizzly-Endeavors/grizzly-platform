# Runbook: Aerohive AP standalone WiFi setup (AP630 + AP130)

Stands up house WiFi on the Aerohive **AP630** (primary, WiFi 6) and one **AP130** (secondary) as a single roaming network, in **standalone mode** (no controller/cloud). This is Checkpoint B of the [garage relocation + EX50 cutover](garage-relocation-cutover.md) — the APs must be serving WiFi *before* the Xfinity gateway is bridged in Checkpoint C, so bridging doesn't black out the house.

The committed configs are `ansible/files/aerohive/ap630.hiveos` and `ap130.hiveos`. They carry `__PLACEHOLDER__` tokens (SSID, PSK, hive secret) that are rendered in at paste time and never committed. HiveOS is order-sensitive and driven over legacy-SSH, so these are applied by paste (not a full Ansible role) — see [ADR-009](../decisions/009-start-with-ap230-only.md) context, though note this deployment uses AP630 + AP130 rather than the AP230.

CLI syntax reference: [aerohive-cli-reference.md](../aerohive-cli-reference.md). Access/quirks reference: [aerohive-serial-interface.md](../aerohive-serial-interface.md) (device inventory, MACs, firmware, the `AH-XXXXXX` prompt, `save config` semantics).

## Prerequisites

- Both APs are factory-reset with CAPWAP disabled (per `docs/hardware.md` / the inventory table in the serial-interface doc). **A factory reset re-enables CAPWAP** — if either AP was reset again, its very first commands must be `no capwap client enable` then `save config` (the committed scripts start with `no capwap client enable`, so a fresh paste covers it).
- Both APs are powered via **PoE injectors** and reachable on the LAN. The SR2024's own PoE is **not delivering** (bench-confirmed 2026-07-07: ~1.2 W total across all ports, port faults) — the PSE failure tracked in [#84](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/84). Injectors are the standing arrangement until the switch PoE is fixed/replaced; the original "power from the SR2024" plan does not currently hold. See the PSE gotcha below.
- Both WiFi PSKs are set in the vault: `vault_home_wifi_psk` (existing/restricted SSID) and `vault_trusted_wifi_psk` (the trusted SSID) in `ansible/inventory/group_vars/all/vault.yml` (the `.example` shows the slots). They surface as `home_wifi_psk` / `trusted_wifi_psk` in `vars.yml`.
- You've picked both SSID names (the existing house SSID + a new trusted SSID) and a shared hive secret (see the render step).

## Step 0 — SR2024 static mgmt IP (issue #80 companion) — DONE 2026-07-07

The EX50's DHCP pool is carved to `10.0.0.50–10.0.0.150` and **excludes** the SR2024's `.153` (issue #80, pool carve-out — no DHCP reservations). The switch *leased* its mgmt IP, so once that pool is in effect it must not depend on DHCP. It's now static (verify with `show interface mgt0` → `IP addr=10.0.0.153; DHCP client=disabled`). For reference, the actual on-device commands (HiveOS 6.5r8) were:

```
interface mgt0 ip 10.0.0.153/24        # CIDR form — NOT `ip ADDR MASK` (that errors)
ip route default gateway 10.0.0.1
no interface mgt0 dhcp client          # else DHCP stays primary and the static is only a fallback
save config
```

Gotcha: setting the static IP drops your SSH session the instant it applies (mgt0 changes subnet) — reconnect at the new address for the remaining lines. This closes #80 for the switch without a reservation.

## Step 1 — Reach each AP over SSH

Default creds are `admin` / `aerohive`. The **AP130** runs old OpenSSH (5.9) and needs legacy algorithms enabled on your client; the **AP630** (IQ Engine 10.6r7) is modern and usually connects without them. Keep a `LEGACY` flag set handy:

```bash
LEGACY='-oKexAlgorithms=+diffie-hellman-group14-sha1 -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa -oStrictHostKeyChecking=accept-new'
# AP630 (modern): ssh admin@<ap630-ip>
# AP130 (legacy): ssh $LEGACY admin@<ap130-ip>
```

If a device rejects the connection with a cipher/kex error, add `-c aes128-cbc` (or `aes256-ctr`) to `LEGACY`. Device IPs: discover via the switch/DHCP (vendor class `AEROHIVE`, hostname `AH-XXXXXX`); the AP130 in scope is `AH-b614c0` per the inventory table.

## Step 2 — Render placeholders and paste the config

The scripts have no `show` commands (so no `--More--` paging to fight); piping the rendered lines straight into the SSH session runs them in order. The render step (a) substitutes the placeholders, (b) strips `#` comment lines and blanks (HiveOS doesn't treat `#` as a comment), and (c) pipes to the AP. Both PSKs are read from the vault and never written to disk:

```bash
cd ~/Projects/grizzly-platform
PSK=$(ansible-vault view ansible/inventory/group_vars/all/vault.yml | awk -F'"' '/^vault_home_wifi_psk:/{print $2}')
PSK2=$(ansible-vault view ansible/inventory/group_vars/all/vault.yml | awk -F'"' '/^vault_trusted_wifi_psk:/{print $2}')
SSID='YourHouseSSID'          # the EXISTING house SSID (restricted segment), so clients roam over seamlessly
TSSID='YourTrustedSSID'       # the NEW trusted SSID (personal + guest devices)
HIVEPW='pick-a-shared-secret' # same value on both APs; any string, not committed

render() {
  sed -e "s|__WIFI_SSID__|$SSID|g" -e "s|__TRUSTED_SSID__|$TSSID|g" \
      -e "s|__WIFI_PSK__|$PSK|g"   -e "s|__WIFI_PSK2__|$PSK2|g" \
      -e "s|__HIVE_PW__|$HIVEPW|g" "$1" | grep -vE '^[[:space:]]*(#|$)'
}

# AP630 (primary)
render ansible/files/aerohive/ap630.hiveos | ssh admin@<ap630-ip>

# AP130 (secondary) — legacy SSH
render ansible/files/aerohive/ap130.hiveos | ssh $LEGACY admin@<ap130-ip>
```

Notes:
- The `sed` delimiter is `|` (not `/`) so PSKs/secrets containing a `/` don't break substitution; if a value contains a literal `|`, pick another delimiter.
- Reuse the **same** SSIDs, PSKs, and `HIVEPW` for both APs — that's what makes them one roaming network.
- This paste tags the **trusted** SSID onto VLAN 30 and leaves the existing SSID on native VLAN 1 (the `restricted-up` / `home-sec` binding lines are commented — that's the go-live step below). Each script ends with `save config`. Confirm with `show run` / `show ssid`.

## Step 3 — Verify (per AP)

```
show capwap client     # must show DISABLED (standalone)
show ssid              # both SSIDs present — existing bound to home-sec, trusted to trusted-sec, on wifi0 + wifi1
show interface wifi0   # 2.4 GHz radio up on its assigned channel
show interface wifi1   # 5 GHz radio up on its assigned channel
show station           # clients appear here once associated
```

Then, from around the house:
- A client associates to the home SSID and gets internet (still via Xfinity → SR2024 at this pre-cutover stage).
- Walk between the AP630 and AP130 coverage areas — the client **roams** without dropping (shared `grizzly-hive` + 802.11r/k/v). `show station` on each AP shows the client moving between them.

## Optional hardening (separate pass)

Rotating the Aerohive admin password off the `admin`/`aerohive` default is worth doing, but do it **across all Aerohive gear at once** (SR2024 + AP630 + AP130 + AP230) so creds don't diverge — track it as its own hardening task, not inline here. Command: `admin root-admin admin password <new>` then `save config`.

## Gotchas

- **PSE wedge (SR2024 PoE):** if an AP won't power on and `show pse port-brief` shows *every* port `unknown`/`0.000 W`, the switch's PoE controller has latched — only a physical power-pull of the switch clears it (`pse reset`/`restart` and a warm reboot do **not**). See [aerohive-cli-reference.md](../aerohive-cli-reference.md#poe-troubleshooting--the-pse-wedge).
- **CAPWAP re-enables on factory reset** — always `no capwap client enable` + `save config` first (the scripts do).
- **`save config` is required** — HiveOS changes are not persistent until saved (the scripts include it at the end).
- **Channel plan** — AP630 uses 2.4:ch1 / 5:ch36, AP130 uses 2.4:ch6 / 5:ch149, so the two never share a channel. Adjust if you add more APs.
- **5 GHz width is 40 MHz** (conservative) — 80/160 MHz tempt higher throughput but cause drops on these units; widen only after stability is proven.

## VLAN tagging + go-live ([ADR-060](../decisions/060-downstream-wifi-segmentation.md))

The APs carry two SSIDs on `mgt0` trunked to the SR2024 (native VLAN 1 untagged + tagged 20/30 — pair this with [`sr2024-vlan-trunks.md`](sr2024-vlan-trunks.md) and the EX50's `configure-ex50.yml`):

- **Trusted SSID → VLAN 30** (`10.30.0.0/24`) — active as soon as the config is pasted. Personal + guest devices: internet, isolated from the platform.
- **Existing SSID → VLAN 20** (`10.20.0.0/24`, restricted) — **deferred to go-live.** The two binding lines (`user-profile restricted-up …` + `security-object home-sec default-user-profile-attr 20`) are commented in both `.hiveos` files, so a normal paste leaves the existing SSID on native VLAN 1 exactly as before. Nobody is cut over early.

**Go-live** (do only once the out-of-band egress layer that governs VLAN 20 is in place, so the restricted segment isn't dark with no way back): apply those two lines to **both** APs and `save config`. From that point the existing SSID's clients re-associate into `10.20.0.0/24`.

```bash
printf 'user-profile restricted-up vlan-id 20 attribute 20\nsecurity-object home-sec default-user-profile-attr 20\nsave config\n' | ssh admin@<ap630-ip>
printf 'user-profile restricted-up vlan-id 20 attribute 20\nsecurity-object home-sec default-user-profile-attr 20\nsave config\n' | ssh $LEGACY admin@<ap130-ip>
```
