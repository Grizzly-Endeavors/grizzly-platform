# ADR-083: The Personal SSID Rides the Platform VLAN

**Date:** 2026-10-11
**Status:** Accepted
**Relates to:** [ADR-060](060-downstream-wifi-segmentation.md) (partially reverses), [ADR-046](046-platform-network-segmentation-via-home-eviction.md) (wired eviction, still outstanding), [ADR-082](082-sonos-event-callbacks-from-restricted.md) (Sonos for HA)

## Context

[ADR-060](060-downstream-wifi-segmentation.md) put the personal SSID (`GrizzlyWiFi`) on its own `trusted` segment, VLAN 30, denied the platform. That only segmented the WiFi side. The owner's wired gear (desktop, laptops, TV, the Zigbee coordinator, and a Sonos Playbar + Sub) sits on the wired home drops, which ride untagged VLAN 1, the platform segment ([ADR-046](046-platform-network-segmentation-via-home-eviction.md) future work).

So the owner's phone was walled off from the owner's own wired devices. The case that surfaced it: the Playbar is wired into an unmanaged 8-port switch in the owner's room. The Sonos app, AirPlay and Spotify Connect all discover speakers by multicast, which doesn't cross VLANs, and the EX50 has no mDNS/SSDP relay. Putting the speaker on VLAN 30 needs an 802.1Q port where it plugs in. The unmanaged switch has none, and it also carries the desktop (the control node), so the whole switch can't move either.

Nobody uses `GrizzlyWiFi` as a guest network, so the guest isolation ADR-060 gave it protected nothing in practice.

## Decision

- **`GrizzlyWiFi` maps to native VLAN 1.** On both APs the personal SSID's security object binds user-profile `platform-up` (`vlan-id 1 attribute 1`), so its clients egress untagged onto the platform segment beside the wired home drops. The house SSID (`Hearthstone`) stays on `restricted`, VLAN 20.
- **The `trusted` segment stays configured but carries no SSID.** The EX50 VLAN 30 interface, zone, DHCP pool and internet rule, and the SR2024 VLAN 30 trunk allows, are left in place. A future network migration can rebind an SSID to it without rebuilding that config.
- **No separate guest SSID.** Guests have not used the network and aren't expected to.
- **Wired Sonos speakers get static leases on `lan`**, listed in `ex50_sonos` alongside the restricted-segment ones. They share the k8s nodes' subnet, so HA's event callbacks need no EX50 rule.

## Alternatives considered

- **Bridge across segments.** Open a firewall hole from trusted to the speakers and relay mDNS through the APs' Bonjour Gateway. Rejected: Sonos doesn't support crossing VLANs, AirPlay needs wide dynamic port ranges, and it adds a relay to own while making the boundary porous.
- **A managed switch (or the spare AP230's second port) as a VLAN 30 access port for the speakers.** It would work for the speakers, but it would still leave the owner's phone split from the rest of their wired gear on VLAN 1. That gear only moves properly in a wired migration.
- **The speakers on WiFi.** Rejected by the owner, since a wired drop is right there.

## Consequences

- Anyone holding the `GrizzlyWiFi` PSK is on the platform segment, with the same reach as a wired home drop: the k8s nodes, the R730xd, the iDRAC/BMC, and the EX50 admin interface. Per-host SSH keys, host firewalls and k8s RBAC/network policies are the isolation that remains. The PSK is now effectively a platform credential.
- VLAN 30 is idle. A client that somehow lands there still gets a lease and internet, so it isn't a trap, just unused.
- The owner's wireless and wired devices share one flat network until a wired migration (ADR-046) moves them all off VLAN 1 together.
- Health signal: `show station` on each AP lists `GrizzlyWiFi` clients with `VLAN 1` / `UPID 1`, and those clients hold `10.0.0.50–.150` leases.
