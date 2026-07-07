# Garage relocation + EX50 router cutover

**Goal:** relocate the platform hardware to the garage on its own network segment, behind the Digi EX50 as the off-the-shelf router, with the ingress tunnel homed on the EX50 ([ADR-045](../decisions/045-platform-relocation-to-garage.md), [046](../decisions/046-platform-network-segmentation-via-home-eviction.md), [047](../decisions/047-ingress-tunnel-relocation-to-ex50.md), [044](../decisions/044-digi-ex50-as-off-the-shelf-router.md)).

**Done (repo work merged):**

- APs live on the new SSIDs; EX50 config authored and validated on-device; SR2024 pinned to a static address; EX50 SSH ACL hardened; rogue DHCP disabled. See the [garage-relocation-cutover runbook](../runbooks/garage-relocation-cutover.md) for the full staged plan and checkpoints.

**Remaining:**

- **The physical swap (final checkpoint).** Bear runs this offline from the cutover script — it takes the network down briefly, so it isn't driven from a session. Once complete, close this thread.
