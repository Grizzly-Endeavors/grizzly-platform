# ADR-082: Sonos Event Callbacks from the Restricted Segment

**Date:** 2026-10-10
**Status:** Accepted
**Relates to:** [ADR-060](060-downstream-wifi-segmentation.md) (downstream WiFi segmentation), [ADR-079](079-home-automation-stack-and-gating.md) (home automation stack)

## Context

Home Assistant (lab-apps `apps/home-automation/`) controls two Sonos speakers on the `restricted` segment and caps their volume during quiet hours. The cap only works well if HA hears about a volume change the moment it happens.

Sonos reports state changes by UPnP eventing. HA subscribes to each speaker, and the speaker then opens a TCP connection back to the callback address HA gave it, on port 1400. Two things blocked that path:

- **The segment firewall.** `restricted` is denied the platform under DAL's zone default-deny (ADR-060). The platform can reach the speakers, but they can't connect back.
- **HA's network position.** HA runs on the pod network behind a ClusterIP Service, and the cluster has no LoadBalancer implementation. Nothing outside the cluster can reach a pod address.

Without callbacks, HA's Sonos integration falls back to polling every 10 seconds. A volume bump during quiet hours would then stay loud for up to 10 seconds before being clamped.

EX50 `firewall filter` rules match zone and protocol only, with no address or port match. A filter rule would open the whole segment to the whole platform.

## Decision

- **HA exposes its event listener as a hostPort.** Container port 1400 maps to `hostPort: 1400` on whichever node runs HA. The `NODE_IP` env var comes from the downward API (`status.hostIP`), and the Sonos package sets it as `advertise_addr`. So the callback address follows HA when it moves to another node. Cilium's kube-proxy replacement provides hostPort.
- **The EX50 allows exactly that flow, through `firewall custom`.** One iptables rule accepts TCP 1400 from an ipset of the speakers (`ha-sonos-src`) to an ipset of the four k8s nodes (`ha-sonos-dst`). DAL's ruleset is legacy iptables with a single `FORWARD` chain: `RELATED,ESTABLISHED` accept first, then the zone accepts, then a final `LOGDROP`. So the inserted accept lands ahead of the drop, and replies ride the conntrack accept. `override` stays false, so DAL's own firewall is untouched.
- **The speakers get static DHCP leases** on `restricted`, so the rule and HA's manual Sonos host list can name them by IP. Both lists live in `ex50_restricted_sonos` in `network.yml`.
- **It is applied on its own.** `configure-ex50.yml --tags sonos-callbacks` renders `ansible/files/ex50/sonos-callbacks.dal.j2`. It is safe to re-apply on the live box: leases are added only when their MAC is absent, and the custom rule refills its sets and inserts the iptables rule only if missing. The from-factory base delta does not run with that tag.

## Alternatives considered

- **Accept the 10-second polling.** No firewall change, but a cap that lets the volume stay loud for up to 10 seconds.
- **`hostNetwork: true` for HA.** Same callback speed, but it puts HA's entire network surface on the node to solve one port.
- **A zone-level `firewall filter` rule.** It can't be narrowed below "all of `restricted` → all of the platform".
- **Moving the speakers to another segment.** Segments are bound to SSIDs, not devices, and the speakers join the house SSID.

## Consequences

- `restricted` is no longer fully isolated from the platform. Two speaker IPs can open TCP 1400 to the k8s node IPs. Nothing else on the segment, and no other port, is opened.
- Port 1400 is reserved on every k8s node for HA.
- Adding a speaker means adding it to `ex50_restricted_sonos` and HA's Sonos package, then re-running the tagged play. A speaker that isn't listed falls back to polling, and HA raises a `subscriptions_failed` repair issue naming it.
- Health signal: HA's repair issues. A broken callback path raises `subscriptions_failed`, and the integration keeps working by polling, so a failure here degrades the cap's speed rather than breaking it.
