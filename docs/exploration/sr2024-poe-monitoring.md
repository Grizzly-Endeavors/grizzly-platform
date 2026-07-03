# SR2024 PoE Monitoring & Alerting (Deferred — post-garage-migration)

**Status:** Designed, not built. Deferred until after the garage relocation ([ADR-045](../decisions/045-platform-relocation-to-garage.md)) — the switch is about to be physically moved and re-IP'd, so building monitoring against its current placement/lease would be throwaway work. Stand this up once the switch is in its final home behind the EX50.

## Why

The SR2024's PSE (Power Sourcing Equipment / PoE) subsystem wedged: every port reported `unknown` / 0 W with PoE enabled and healthy profiles, so nothing plugged into it powered on (a 5-port PoE switch, an AP630, and an AP130 all went dark at once). See the recovery quirk in [aerohive-cli-reference.md](../aerohive-cli-reference.md#poe-troubleshooting--the-pse-wedge) — the short version is that only a **physical power-pull** clears it; `pse reset`, `pse restart`, and even a warm CLI `reboot` do **not**. Firmware is HiveOS 6.5r8 (2017), which is a prime suspect.

The failure was silent — the first anyone knew of it was an AP not powering on. We want two things next time: (1) to **know the moment it happens**, and (2) to have the switch's own logs from **before** the failure, which today are lost because the buffer is volatile and dies on the power-cycle that fixes it.

## Design

Three parts. Notify-only — see the auto-recovery note below for why we can't self-heal.

### 1. Persistent switch syslog (highest value; do this first)

Configure the SR2024's `logging server` to ship its event log off-box into the existing Loki (on R730xd) via an Alloy `loki.source.syslog` listener. This solves the "buffer wiped on reboot" problem — the pre-failure lines survive. A PSE fault reason (overload / short / thermal / undervoltage) vs. a silent hang is exactly what discriminates a hardware fault from a firmware wedge, and it only lives in the switch's log.

- Switch: `logging server <alloy-listener-ip> ...` (discover exact syntax via `logging ?`).
- Alloy: add a `loki.source.syslog` component (UDP/TCP 514) exposed on a stable node endpoint, forwarding to the existing `loki.write`. Label the stream `host="sr2024"`.

### 2. Canary AP liveness poll

Rather than trust the switch's own PSE reporting (which lies — it says "enabled" while delivering nothing), poll an AP that is **powered by** the switch's PoE. AP reachable → PoE is delivering. AP goes dark → PoE died. Because the wedge takes the whole PSE chip down at once (not a single port), any one mounted AP is a faithful proxy for the entire PoE plane. All the Aerohive APs are PoE-only (no DC input), so every mounted AP is a valid canary — no special selection needed.

- `blackbox_exporter` ICMP probe of the canary AP's IP, scraped by the existing Prometheus (R730xd).
- Alert rule: `probe_success == 0` for the canary → fires through the existing Alertmanager → Discord.

### 3. On-failure syslog capture

When the canary-down alert fires, attach the last ~20 min of the switch's syslog so the cause is in the notification itself, not something you have to go dig for.

- Alertmanager webhook → small handler that range-queries Loki for `{host="sr2024"}` over the 20 min preceding the alert and posts the chunk to Discord alongside the alert.

## Alerts (all → Discord)

| Alert | Condition | Severity |
|-------|-----------|----------|
| PoE collapse | canary AP `probe_success == 0` while switch mgmt still reachable | critical |
| Switch unreachable | switch mgmt IP probe fails | warning |
| Uptime early-warning (optional) | switch uptime approaches the ~5–6 wk mark where it wedged before | info |

## Auto-recovery — out of scope (notify-only)

Only a **physical power-pull** recovers the wedge — nothing over the network (SSH `pse restart`, `reboot`, SNMP) does. So monitoring can only *notify someone to go pull the plug*. True hands-off recovery would require the switch on a smart plug / switched PDU we can cycle from the homelab, plus an Alertmanager action to trigger it. Deferred; revisit if the wedge recurs often enough to justify the hardware.

## Open items for build time

- Confirm the switch's final IP after the garage migration / EX50 cutover (it is a DHCP lease today — see [issue #80](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/80) on moving static assignments off the Xfinity pool). Give it a reservation.
- Pick the canary AP once APs are physically mounted (any one will do) and give it a reservation.
- Verify HiveOS 6.5r8 `logging server` syntax and that it emits PSE events at a useful severity.
- Decide the Alloy syslog listener's stable ingress (NodePort / hostPort) for the switch to target.
