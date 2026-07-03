# ADR-045: Relocate the Platform to the Garage

**Date:** 2026-07-02
**Status:** Accepted (implementation pending — see `docs/runbooks/garage-relocation-cutover.md`)
**Relates to:** [ADR-008](008-keep-existing-switch-chain-for-home.md), [ADR-006](006-proceed-without-ups.md), [ADR-044](044-digi-ex50-as-off-the-shelf-router.md)

## Context

The platform machines currently live in the closet on the SR2024 (`docs/network.md`), with the Xfinity gateway upstream in the living room. A dedicated space has become available in the garage: **active ventilation, partially below-grade with cinder-block retaining walls on two of four sides, on a 20 A circuit adjacent to the electrical panel** (room to add another circuit if needed).

This is a better home for a rack of always-on gear than a closet, and it coincides with the EX50 router cutover ([ADR-044](044-digi-ex50-as-off-the-shelf-router.md)) — both jobs require powering everything down and re-cabling, so they are planned as one maintenance window.

The operator has enough coax slack to relocate the Xfinity gateway itself into the garage, so the *entire* network core (Xfinity in bridge mode → EX50 → SR2024 → machines) collapses into one room. The only new long cable runs are from the garage back out to the WiFi AP mount points.

This inverts the premise of [ADR-008](008-keep-existing-switch-chain-for-home.md): the garage was a *leaf* on the legacy consumer switch chain; it now becomes the *core* of the lab.

## Decision

**Relocate all platform hardware — R730xd, Quanta, Intel NUC, Optiplex, Inspiron, Tower PC (at join), jumpbox — plus the SR2024 and the Xfinity gateway into the garage.** The physical move is a Layer-1 change only: every machine keeps its static `10.0.0.x` address, so from the machines' point of view nothing changes.

**The move is executed as a single, staged maintenance window** with verified, independently reversible checkpoints — see `docs/runbooks/garage-relocation-cutover.md`. The physical relocation (on the existing Xfinity-routed flat network) is the first checkpoint and is fully reversible before any routing change is attempted.

**The garage's below-grade environment is treated as a first-class operational concern** (see Consequences) rather than assumed benign.

## Consequences

- **Thermal improves.** Below-grade + active ventilation is thermally favourable for the R730xd (2×750 W) and Quanta — cooler and more stable than a closet.
- **Humidity/condensation becomes a real risk.** Active ventilation pulling humid summer air across cool below-grade surfaces is a classic condensation setup. **Humidity monitoring is required** as a first-class signal alongside the existing observability stack (temp + relative humidity sensor, alert threshold, destination per the readiness checklist). A dehumidifier or humidity-aware ventilation control may be needed.
- **Water ingress is a risk.** Below-grade rooms flood/seep. All gear — including the UPS/PDU — must be kept **off the slab** (rack or shelf), and a water/leak sensor near the floor is warranted.
- **Power.** The dedicated 20 A circuit near the panel is sufficient headroom for the current fleet; a PDU sizing pass is part of the move. Even with the APC batteries dead ([ADR-006](006-proceed-without-ups.md)), the **network core (Xfinity + EX50 + SR2024 + APs) should sit on a small UPS** so WiFi and external ingress ride brief outages independently of the big servers — a partial revisit of ADR-006 scoped to the network core only.
- **ADR-008 is inverted for the garage.** The garage is no longer served by the legacy consumer switch chain; it *is* the lab backbone. The rest of the legacy chain (bedroom, other home drops) still stands per ADR-008 but now uplinks from the EX50's home subnet rather than the Xfinity gateway.
- **New cable runs are AP-only.** The WiFi APs mount around the house and home-run back to the garage SR2024 (PoE). These are the only long pulls and can be done ahead of the window with zero downtime.
- **Ingress path survives the move untouched.** The VPS→home WireGuard tunnel is home-initiated outbound (ADR-019), so relocation does not disturb it; it re-establishes automatically after the outage.

## Alternatives Considered

- **Leave the platform in the closet; only swap the router.** Rejected: the garage is a materially better environment (space, ventilation, dedicated power) and the router cutover already forces a full power-down, so combining them avoids a second disruptive window.
- **Do the move and the router cutover as separate windows.** Rejected as the default: the AP/PoE/switch dependencies (APs need switch PoE, switch moves to the garage, bridge cutover wants APs live) couple the work into one session. The runbook instead *stages* the single window into reversible checkpoints, which captures the isolation benefit without a second teardown.
- **Run new home-run cable to the garage instead of relocating the Xfinity gateway.** Unnecessary — available coax slack lets the gateway itself move, so the only long run is the (already-needed) AP cabling.

## References

- ADR-008 — legacy switch chain for home drops (garage inverted from leaf to core here).
- ADR-006 — proceed without UPS (partially revisited for the network core).
- ADR-044 — Digi EX50 router (co-located, cut over in the same window).
- ADR-019 — ingress topology (unaffected by the physical move).
- `docs/runbooks/garage-relocation-cutover.md` — staged procedure with per-checkpoint verification and rollback.
