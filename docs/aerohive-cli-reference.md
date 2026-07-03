# Aerohive HiveOS CLI Reference

Quick reference for configuring Aerohive AP130/AP230 access points and the SR2024 managed switch in standalone mode (no controller). Compiled from the ServeTheHome community thread, Extreme Networks documentation (now largely offline), and hands-on testing notes.

> **Note:** Official Aerohive docs at docs.aerohive.com have been redirected to Extreme Networks' generic support portal and are no longer accessible. The [ServeTheHome forum thread](https://forums.servethehome.com/index.php?threads/aerohive-extreme-networks-aps-no-controller-needed.31445/) is the best community resource.

## Access Points (AP130 / AP230)

### Initial Access

| Method | Details |
|--------|---------|
| Console | Serial via 8P8C connector on device — need console cable |
| SSH | Enabled by default once the AP has an IP |
| Web UI | Browse to AP's IP address |
| Default credentials | Username: `admin`, Password: `aerohive` |

### First Steps

```
# Disable cloud/controller mode — required for standalone operation
no capwap client enable

# Change the default admin password
admin root-admin admin password <newpassword>

# Save after every configuration block
save config
```

### Configuration Order of Operations

HiveOS is order-sensitive. Follow this sequence:

1. **Radio profiles** — define PHY mode, channel width, band steering
2. **Security objects** — define encryption and PSK
3. **SSIDs** — create the network name
4. **Bind security to SSID** — associate security object with SSID
5. **User profiles** (optional) — map SSIDs to VLANs via attributes
6. **Bind user profiles to security objects** (optional) — tie VLAN assignment to the SSID
7. **Assign radio profiles to interfaces** — wifi0 (2.4GHz), wifi1 (5GHz)
8. **Assign SSIDs to interfaces** — bind SSIDs to radio interfaces

### Radio Profiles

```
# Create profile and set PHY mode
radio profile <name>
radio profile <name> phymode <mode>

# PHY modes:
#   11ng       — 2.4GHz 802.11n
#   11ac       — 5GHz 802.11ac (or auto on some firmware)
#   11ac-2g    — 2.4GHz 802.11ac
#   11ac-5g    — 5GHz 802.11ac
#   11ax-2g    — 2.4GHz 802.11ax (WiFi 6, newer firmware)
#   11ax-5g    — 5GHz 802.11ax (WiFi 6, newer firmware)

# Common radio options
radio profile <name> short-guard-interval
radio profile <name> band-steering enable
radio profile <name> band-steering mode prefer-5g
radio profile <name> weak-snr-suppress enable
radio profile <name> dfs                          # 5GHz only — enables DFS channels
radio profile <name> channel-width <20|40|80|160> # 5GHz only — 40 is safe default

# Assign to interface
interface wifi0 radio profile <name>   # wifi0 = 2.4GHz radio
interface wifi1 radio profile <name>   # wifi1 = 5GHz radio
```

**Channel width guidance:** 40MHz is a safe default for 5GHz. 80MHz gives better throughput but fewer non-overlapping channels. 160MHz can cause instability (reported pattern: works for ~1 day then drops). Start conservative.

**Power tuning:** Reducing 2.4GHz TX power helps band steering push clients to 5GHz:
```
interface wifi0 radio power 12
interface wifi0 radio tx-power-control 12
```

### SSIDs and Security

```
# Create security object with WPA2-PSK
security-object <name>
security-object <name> security protocol-suite wpa2-aes-psk ascii-key <password>

# Create SSID and bind security
ssid <ssidname>
ssid <ssidname> security-object <name>

# Assign SSID to interfaces (both radios for dual-band)
interface wifi0 ssid <ssidname>
interface wifi1 ssid <ssidname>
```

Multiple SSIDs can be assigned to the same radio interface.

### VLAN Assignment via User Profiles

To map an SSID to a VLAN, create a user profile and bind it to the security object:

```
# Create user profile: maps to a VLAN via an attribute number
user-profile <profilename> vlan-id <vlan-id> attribute <attr-number>

# Bind the attribute to the security object
security-object <objectname> default-user-profile-attr <attr-number>
```

The `attribute` number is an arbitrary identifier that links the user profile to the security object. Each SSID/security-object pair needs a unique attribute number.

Optional QoS can be added to user profiles, but this is often better handled at the router/switch level:
```
user-profile <name> qos-policy <policyname> vlan-id <vlan-id> attribute <attr>
```

### Management Interface

```
# Set management VLAN (if AP management traffic needs tagging)
interface mgt0 vlan <vlan-id> native-vlan-id <vlan-id> trunk allowed vlan <vlan-list>
```

### Multi-AP Roaming (Hive)

For seamless roaming across multiple APs without a controller:

```
hive <hivename>
hive <hivename> password <password>
interface mgt0 hive <hivename>

# Set static channels to avoid roaming conflicts
interface wifi0 radio channel <channel>
interface wifi1 radio channel <channel>
```

Use 5GHz backhaul for inter-AP communication. Supports 802.11r/k/v fast roaming.

### System Administration

```
# DNS and NTP
dns server-ip <ipaddress>
ntp server <ipaddress>
clock time-zone <GMToffset>

# LED control
no system led power-saving-mode
system led brightness off

# Console timeout (0 = never)
console timeout 0

# Save and backup
save config
save config tftp://<server-ip>:<filename> current now
```

### Useful Show Commands

```
show run                    # Full running configuration
show capwap client          # Controller/cloud status (should show disabled)
show interface wifi0        # 2.4GHz radio stats
show interface wifi1        # 5GHz radio stats
show station                # Connected clients
show ssid                   # SSID configuration
```

### Firmware Notes

- ExtremeCloud IQ Connect (free tier) can push firmware updates without a support contract
- Direct firmware downloads from Extreme are paywalled
- The free cloud tier lacks multi-user PSK, cloud RADIUS, and WIPS
- If an AP was previously cloud-managed, Extreme support (+1 800-872-8440) can disassociate it given the serial number and MAC
- Factory reset: hold reset button ~11 seconds until LED turns amber

---

## SR2024 Switch

### Initial Access

Console, SSH, or web UI. Default credentials: `admin` / `aerohive`.

**Note:** The switch web UI exists but is read-only and doesn't let you change anything meaningful. Use CLI (serial or SSH) for all configuration. The command `system web-server enable` is accepted but doesn't appear in `show run` — the web server appears to always be running, it just serves a limited interface.

### First Steps

```
no capwap client enable
save config
```

### VLAN Configuration

```
# Create VLANs
vlan <id> name <name>

# Examples
vlan 10 name Management
vlan 50 name IoT
vlan 40 name Guest
vlan 65 name Secure
```

### Port Configuration

**Access ports** (single VLAN, untagged):
```
interface eth1/<port> switchport mode access
interface eth1/<port> switchport access vlan <id>
```

**Trunk ports** (carry multiple tagged VLANs):
```
interface eth1/<port> switchport mode trunk
interface eth1/<port> switchport trunk allow vlan <id>
# Repeat for each VLAN on the trunk
```

Note: each `allow vlan` command adds a VLAN to the trunk — they're additive, not replacements.

**Trunk VLAN gotcha:** When inspecting with `show run`, trunk ports may display `allow vlan 1 - 3966` (all VLANs) even if you only added specific ones. Verify trunk filtering is working as expected at the traffic level, not just in the config output.

### Link Aggregation (LACP)

```
# Create aggregate group and add member ports
agg <group-number>
interface eth1/<port> agg <group-number>
interface eth1/<port> agg <group-number>

# Enable LACP and configure
interface agg<group-number> lacp enable
interface agg<group-number> flow-control auto

# Assign VLAN to the aggregate
interface agg<group-number> switchport mode access
interface agg<group-number> switchport access vlan <id>
# Or trunk mode:
interface agg<group-number> switchport mode trunk
interface agg<group-number> switchport trunk allow vlan <id>
```

### System Administration

```
save config
show run
show interface                  # All port status (link, speed, duplex)
show interface mgt0             # Management IP, VLAN, DHCP status
show interface eth1/<port>      # Specific port details
show mac-address-table          # NOTE: requires subcommand, bare form errors
```

Note: `show vlan` is incomplete on its own — it requires a subcommand. Use `show run` to see VLAN assignments.

### PoE / PSE Commands

The PoE subsystem is spelled **`pse`** (Power Sourcing Equipment), not `poe` — `show poe` and friends error with "unknown keyword".

```
show pse port-brief             # Per-port: Status, Priority, Consumption(W), Profile
show pse profile                # Power profiles: priority, mode (802.3af/at), power limit
pse ?                           # Global PSE config: enable, guard-band, max-power-source,
                                #   power-management-type, legacy, reset, restart
```

A port with nothing plugged in reads `Status: unknown` / `0.000 W` — that's **normal for an empty port**. It only means trouble on a port that has a powered device attached (see the wedge below).

### PoE Troubleshooting — the PSE wedge

**Symptom:** Nothing powers on. `show pse port-brief` shows **every** port `unknown` / `0.000 W`, including ports with a PD (AP or downstream PoE switch) plugged in. But the config looks completely healthy: `pse enable` reports "already enabled", profiles are `802.3 AT` at `32.0 W`, `max-power-source`/`guard-band` are at defaults. It's not a config or power-budget problem and **not** the PD's draw — the PSE controller chip has silently latched into a bad state and is reporting garbage.

**Recovery ladder — what does NOT work, in order tried:**

1. `pse reset` — rewrites PSE *parameters* to default (config-level). **Did nothing.**
2. `pse restart` — restarts the PSE *chip firmware* without touching config. **Did nothing.**
3. Warm `reboot` from the CLI. **Did nothing** — the wedge survives a software reboot; the PoE rail/chip stays latched through it.
4. **Physical power-pull (unplug the switch, wait, plug back in). This is the only thing that recovered it.**

**Implications:**

- Because only a hard power-cycle clears it, **nothing over the network can auto-recover this** — remote monitoring can notify, but a human has to pull the plug (or the switch needs a smart PDU we can cycle).
- Firmware is HiveOS 6.5r8 (2017) — an old-firmware PSE hang is a prime suspect. If it recurs near a repeatable *uptime*, that fingerprints a firmware aging bug (mitigation: scheduled reboot — **but note a warm reboot did NOT clear this instance**, so a power-cycle via PDU would be needed).
- Monitoring + alerting design (canary-AP liveness poll + persistent switch syslog to capture the pre-failure cause) is written up in [exploration/sr2024-poe-monitoring.md](exploration/sr2024-poe-monitoring.md), deferred until after the garage migration.

---

## Common Pitfalls

- **Case sensitivity in object names:** `IoTNetwork` and `IotNetwork` are different objects. Be consistent.
- **Typos in object references:** The CLI won't always error if you reference a non-existent object — the binding just silently fails.
- **Save config:** Changes are not persistent until `save config` is run. Get in the habit of saving after each logical block.
- **CAPWAP:** If left enabled, the AP will try to find a controller and may override local config. Always `no capwap client enable` first.
- **Channel width vs. stability:** Start at 40MHz and work up. 160MHz is tempting but causes drops on many units.
- **PoE:** The SR2024 does provide PoE (802.3at/PoE+) despite not being the "P" model. All three APs confirmed powered by the switch. The subsystem is spelled `pse`, not `poe`. **It can wedge** — all ports `unknown`/0 W despite a healthy config, recoverable only by a physical power-pull (`pse reset`/`restart` and a warm reboot don't clear it). See [PoE Troubleshooting — the PSE wedge](#poe-troubleshooting--the-pse-wedge).
- **Firmware association:** Used APs may be locked to a previous cloud account. Contact Extreme support to release them before setup.
