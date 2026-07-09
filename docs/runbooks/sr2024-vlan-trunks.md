# Runbook — SR2024 VLAN trunks (downstream WiFi segmentation)

Convert the SR2024 uplink ports (EX50 gateway + the two APs) into 802.1Q trunks so the tagged `restricted` (VLAN 20) and `trusted` (VLAN 30) segments reach the EX50 and the APs, while the platform keeps riding native VLAN 1 untagged. Config artifact: [`ansible/files/aerohive/sr2024-vlan-trunks.hiveos`](../../ansible/files/aerohive/sr2024-vlan-trunks.hiveos). Decision: [ADR-059](../decisions/059-downstream-wifi-segmentation.md). This is one slice of the WiFi-segmentation work — the EX50 side is in `configure-ex50.yml`, the AP side in the `*.hiveos` AP files.

> **This is a live-network change with lock-out potential.** The EX50 uplink (`eth1/1`) carries the platform's own gateway traffic untagged on native VLAN 1. Trunking it is safe *as long as* native VLAN 1 stays the untagged native — but a mistake here drops the whole platform. Drive it from a **wired platform host**, not over WiFi, and have serial-console access to the SR2024 ready as a fallback.

## Access

Legacy SSH algorithms + default creds `admin`/`aerohive` (see [aerohive-cli-reference.md](../aerohive-cli-reference.md)):

```fish
set LEGACY '-oKexAlgorithms=+diffie-hellman-group14-sha1 -oHostKeyAlgorithms=+ssh-rsa -oPubkeyAcceptedAlgorithms=+ssh-rsa'
sshpass -p aerohive ssh -tt $LEGACY admin@10.0.0.153
```

## Step 1 — Verify port occupancy (do NOT skip)

Confirm which physical ports the EX50 and the two APs are actually on before trunking anything. The artifact assumes `eth1/1`=EX50, `eth1/3`=AP130, `eth1/4`=AP630 (verified 2026-07-09), but cabling changes — re-derive it live:

```
console page 0
show interface            # which ports are up
show mac-address-table all
```

Cross-check the learned MACs: EX50 = Digi OUI `00:40:9d` (…`e0:80:81`), APs = Aerohive OUI `88:5b:dd` (AP130) etc. The EX50 uplink port is the one you must get right. If the map differs, edit the artifact's port numbers before applying. (`eth1/3` and `eth1/4` take identical trunk config, so AP130-vs-AP630 ordering doesn't matter — only that both are AP uplinks and neither is the EX50 or the home switch chain on `eth1/2`.)

## Step 2 — Apply

Paste the artifact with `#`/blank lines stripped (HiveOS has no comment char), same render pattern as the AP configs:

```fish
grep -vE '^[[:space:]]*(#|$)' ansible/files/aerohive/sr2024-vlan-trunks.hiveos \
  | sshpass -p aerohive ssh -tt $LEGACY admin@10.0.0.153
```

The trailing `save config` persists it.

## Step 3 — Verify

- **Platform intact (most important):** from a wired platform host, `ping 10.0.0.1` and confirm SSH/kubectl to `10.0.0.x` hosts still work. Native VLAN 1 must be unaffected.
- **Trunks formed:** `show run` shows `eth1/1`, `eth1/3`, `eth1/4` in trunk mode with VLANs 20/30 allowed. Note the display gotcha — trunks may print `allow vlan 1 - 3966` even when narrowed; verify at the traffic level, not the config text.
- **VLAN reachability** (after the EX50 + AP sides are also in place): a client on the trusted SSID lands in `10.30.0.0/24` and reaches the internet; a client on the restricted segment lands in `10.20.0.0/24`.

## Rollback

Revert a port to a plain access port:

```
interface eth1/1 switchport mode access
interface eth1/1 switchport access vlan 1
save config
```

## Operational notes

- **Health/verify:** `show interface` (link), `show run` (trunk config). No metrics export from this 2017-firmware switch today.
- **Dependencies:** the EX50 must have VLANs 20/30 + their interfaces (`configure-ex50.yml`); the APs must tag their SSIDs onto 20/30 (`*.hiveos`). Trunks alone carry nothing until both ends exist.
- **Common failure mode:** platform loss after trunking `eth1/1` → native VLAN drifted off 1. Recover via serial console with the rollback above.
- **PoE caveat:** unrelated to VLANs, but the SR2024's PSE can wedge (all ports 0 W) — power-pull only (issue #84, [aerohive-cli-reference.md](../aerohive-cli-reference.md)).
