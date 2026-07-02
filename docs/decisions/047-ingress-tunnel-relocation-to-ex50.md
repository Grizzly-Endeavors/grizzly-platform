# ADR-047: Relocate the Ingress Tunnel to the EX50

**Date:** 2026-07-02
**Status:** Accepted (implementation pending — sequenced after the router cutover in `docs/runbooks/garage-relocation-cutover.md`)
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md), [ADR-044](044-digi-ex50-as-off-the-shelf-router.md)

## Context

External ingress today ([ADR-019](019-ingress-and-tls-termination.md)) flows: Internet → VPS Caddy (TLS) → point-to-point WireGuard tunnel → **R730xd** iptables DNAT (TCP `30487`/`30356` only) → `dell-inspiron-15` (`10.0.0.226`) NodePort → ingress-nginx. R730xd initiates the tunnel outbound (it is behind home NAT) and sends `PersistentKeepalive`; the VPS listens.

ADR-019 explicitly flagged the downside: **R730xd is on the critical path for external ingress** — if it goes down, every `*.bearflinn.com` service is unreachable even if the cluster is healthy — and anticipated the fix: "If the WG tunnel and iptables rules ever migrate to a different host (e.g., the purchased off-the-shelf router), the move is additive."

That host now exists. The EX50 ([ADR-044](044-digi-ex50-as-off-the-shelf-router.md)) is the always-on border device, runs scriptable DAL, and supports WireGuard (firmware ≥ 24.3.28.88) plus DNAT/port-forwarding. Terminating the ingress tunnel on the border router — rather than on the storage server — is where it belongs.

## Decision

**Move the ingress WireGuard endpoint and the DNAT rules from R730xd to the EX50.** The EX50 becomes the home end of the VPS↔home tunnel, initiates outbound to the VPS, and DNATs TCP `30487`/`30356` from the tunnel interface to `dell-inspiron-15` (`10.0.0.226`). Only those two ports are forwarded; nothing else on the platform subnet is reachable from the VPS through the tunnel.

**The configuration stays in IaC.** Because DAL is scriptable (ADR-044), the existing `ingress-tunnel` role is retargeted from R730xd to the EX50 rather than replaced by hand-config. R730xd's tunnel + DNAT are then retired.

**This is sequenced as a discrete step after the basic router cutover is verified** — not folded into the same change that swaps the router — so a WireGuard/DNAT issue on the EX50 cannot block the core cutover.

## Consequences

- **R730xd leaves the external-ingress critical path**, resolving the standing downside in ADR-019. R730xd remains critical for storage/foundation-stores, but a storage-server reboot no longer takes down `*.bearflinn.com`.
- **The VPS peer is repointed.** The VPS's WireGuard peer entry gets the EX50's public key and the home-side `/30` address moves to the EX50. **Caddy is unchanged** — it still targets `k8s_ingress_ip:{30487,30356}`; only the WG peer and the host holding `k8s_ingress_ip` change. `k8s_ingress_ip` in `network.yml` is repointed from `wg_r730xd_ip` to the EX50's tunnel IP.
- **Key rotation gets a new home.** ADR-019's manual WG key rotation now regenerates the VPS↔EX50 pair; the EX50 side is driven through the `ingress-tunnel` role against the DAL shell rather than against R730xd.
- **Reversible.** Until R730xd's tunnel is torn down, rollback is re-pointing the VPS peer back to R730xd. The cutover runbook keeps R730xd's path intact until the EX50 path is verified end-to-end.
- **Firmware gate.** The EX50 must be on DAL ≥ 24.3.28.88 before this step; verified during cutover prerequisites.
- **No Flux/cluster changes.** ingress-nginx, cert-manager, and the NodePort DaemonSet are untouched — this is purely an edge-of-network relocation.

## Alternatives Considered

- **Leave the tunnel on R730xd.** Rejected: it keeps the storage server on the ingress critical path for no benefit now that a proper border device exists — exactly the state ADR-019 wanted to move away from.
- **Terminate the tunnel on a K8s node directly.** Rejected: couples ingress to a specific cluster node's lifecycle (drains/reboots) and re-introduces the node-pinning problem; the border router is lifecycle-independent of the cluster.
- **Do it in the same step as the router swap.** Rejected: adds a new WG endpoint as a variable inside the already-consequential router cutover. Staging it afterward keeps each change independently verifiable and reversible.

## References

- ADR-019 — ingress & TLS termination (this ADR executes the "migrate to the router" path it anticipated).
- ADR-044 — Digi EX50 router (scriptable DAL; WireGuard + DNAT support).
- `ansible/roles/ingress-tunnel/` — role retargeted from R730xd to the EX50.
- `ansible/group_vars/all/network.yml` — `k8s_ingress_ip` repointed to the EX50 tunnel IP.
- `docs/runbooks/garage-relocation-cutover.md` — Checkpoint E.
