# Runbook: Aerohive AP standalone WiFi setup (AP630 + AP130)

Stands up house WiFi on the Aerohive **AP630** (primary, WiFi 6) and one **AP130** (secondary) as a single roaming network, in **standalone mode** (no controller/cloud). This is Checkpoint B of the [garage relocation + EX50 cutover](garage-relocation-cutover.md) — the APs must be serving WiFi *before* the Xfinity gateway is bridged in Checkpoint C, so bridging doesn't black out the house.

The committed configs are `ansible/files/aerohive/ap630.hiveos` and `ap130.hiveos`. They carry `__PLACEHOLDER__` tokens (SSID, PSK, hive secret) that are rendered in at paste time and never committed. HiveOS is order-sensitive and driven over legacy-SSH, so these are applied by paste (not a full Ansible role) — see [ADR-009](../decisions/009-start-with-ap230-only.md) context, though note this deployment uses AP630 + AP130 rather than the AP230.

CLI syntax reference: [aerohive-cli-reference.md](../aerohive-cli-reference.md). Access/quirks reference: [aerohive-serial-interface.md](../aerohive-serial-interface.md) (device inventory, MACs, firmware, the `AH-XXXXXX` prompt, `save config` semantics).

## Prerequisites

- Both APs are factory-reset with CAPWAP disabled (per `docs/hardware.md` / the inventory table in the serial-interface doc). **A factory reset re-enables CAPWAP** — if either AP was reset again, its very first commands must be `no capwap client enable` then `save config` (the committed scripts start with `no capwap client enable`, so a fresh paste covers it).
- Both APs are powered from the SR2024 (802.3at PoE+, no injectors) and reachable on the LAN. See the PSE-wedge gotcha below.
- The home WiFi PSK is set in the vault: `vault_home_wifi_psk` in `ansible/inventory/group_vars/all/vault.yml` (the `.example` shows the slot). It surfaces as `home_wifi_psk` in `vars.yml`.
- You've picked the SSID and a shared hive secret (see the render step).

## Step 0 — SR2024 static mgmt IP (issue #80 companion)

The EX50's DHCP pool is carved to `10.0.0.50–10.0.0.150` and **excludes** the SR2024's `.153` (issue #80, pool carve-out — no DHCP reservations). The switch currently *leases* its mgmt IP, so once that pool is in effect it must not depend on DHCP. Give it a static mgmt IP on the switch itself so `sr2024_ip` (`10.0.0.153`) stays valid:

```
interface mgt0 ip 10.0.0.153 255.255.255.0
save config
```

(Do this on the SR2024, not an AP. Verify with `show interface mgt0`.) This closes #80 for the switch without a reservation.

## Step 1 — Reach each AP over SSH

Default creds are `admin` / `aerohive`. The **AP130** runs old OpenSSH (5.9) and needs legacy algorithms enabled on your client; the **AP630** (IQ Engine 10.6r7) is modern and usually connects without them. Keep a `LEGACY` flag set handy:

```bash
LEGACY='-oKexAlgorithms=+diffie-hellman-group14-sha1 -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa -oStrictHostKeyChecking=accept-new'
# AP630 (modern): ssh admin@<ap630-ip>
# AP130 (legacy): ssh $LEGACY admin@<ap130-ip>
```

If a device rejects the connection with a cipher/kex error, add `-c aes128-cbc` (or `aes256-ctr`) to `LEGACY`. Device IPs: discover via the switch/DHCP (vendor class `AEROHIVE`, hostname `AH-XXXXXX`); the AP130 in scope is `AH-b614c0` per the inventory table.

## Step 2 — Render placeholders and paste the config

The scripts have no `show` commands (so no `--More--` paging to fight); piping the rendered lines straight into the SSH session runs them in order. The render step (a) substitutes the three placeholders, (b) strips `#` comment lines and blanks (HiveOS doesn't treat `#` as a comment), and (c) pipes to the AP. The PSK is read from the vault and never written to disk:

```bash
cd ~/Projects/grizzly-platform
PSK=$(ansible-vault view ansible/inventory/group_vars/all/vault.yml | awk -F'"' '/^vault_home_wifi_psk:/{print $2}')
SSID='YourHouseSSID'          # recommend: the EXISTING house SSID, so clients roam over seamlessly at cutover
HIVEPW='pick-a-shared-secret' # same value on both APs; any string, not committed

render() { sed -e "s/__WIFI_SSID__/$SSID/g" -e "s/__WIFI_PSK__/$PSK/g" -e "s/__HIVE_PW__/$HIVEPW/g" "$1" | grep -vE '^[[:space:]]*(#|$)'; }

# AP630 (primary)
render ansible/files/aerohive/ap630.hiveos | ssh admin@<ap630-ip>

# AP130 (secondary) — legacy SSH
render ansible/files/aerohive/ap130.hiveos | ssh $LEGACY admin@<ap130-ip>
```

Notes:
- If the PSK or hive secret contains a `/`, `&`, or `\`, change the `sed` delimiter (e.g. `s|__WIFI_PSK__|$PSK|g`) so substitution doesn't break.
- Reuse the **same** `SSID`, `PSK`, and `HIVEPW` for both APs — that's what makes them one roaming network.
- Each script ends with `save config`, so the change persists. If you re-run interactively and want to confirm, `show run` / `show ssid`.

## Step 3 — Verify (per AP)

```
show capwap client     # must show DISABLED (standalone)
show ssid              # the home SSID present, bound to home-sec on wifi0 + wifi1
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

## Later: VLAN tagging (Checkpoint D)

These configs are **flat/untagged** — the SSID rides `10.0.0.0/24` today. At [Checkpoint D](garage-relocation-cutover.md) (segmentation, [ADR-046](../decisions/046-platform-network-segmentation-via-home-eviction.md)) the home SSID is tagged onto `10.20.0.0/24` via a user-profile + `mgt0` trunk, and the SR2024 trunks that VLAN to the AP ports. That's a later PR; nothing here needs to change for the flat cutover.
