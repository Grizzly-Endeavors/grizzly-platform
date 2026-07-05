# ADR-051: HAProxy L4 Mail Ingress with PROXY Protocol on the VPS

**Date:** 2026-07-05
**Status:** Accepted (implementation pending)
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md), [ADR-050](050-stalwart-mail-server.md)

## Context

Inbound mail for Stalwart ([ADR-050](050-stalwart-mail-server.md)) needs raw TCP 25/465/587/993 carried from the VPS public IP to the in-cluster NodePort. The gameserver ingress does the raw-port carry (VPS → WireGuard tunnel → NodePort) with **iptables DNAT + masquerade** — but the masquerade rewrites the source address so the return leg routes back through the tunnel. Games don't care who connects; **mail does**: if Stalwart sees every inbound connection as coming from the tunnel gateway, SPF checks, IP greylisting, and RBL lookups all break, gutting inbound spam filtering. The HTTP path solves the equivalent problem with `X-Forwarded-For`; raw SMTP/IMAP has no header equivalent.

## Decision

**Front the four inbound mail ports with HAProxy on the VPS, in TCP mode, sending PROXY protocol** over the tunnel to Stalwart's NodePort. HAProxy terminates and re-originates the TCP connection statefully (so no masquerade / asymmetric-routing problem) and prepends a PROXY protocol v2 header carrying the true client IP. **Stalwart's listeners are configured to accept PROXY protocol** from the tunnel/HAProxy source only. TLS stays end-to-end: HAProxy passes the stream through (implicit TLS on 465/993, STARTTLS on 25/587) and Stalwart terminates it with its own cert ([ADR-052](052-in-cluster-acme-cert-for-mail.md)). This extends the VPS's existing proxy role — it is proxy *infrastructure*, not an application host.

## Alternatives Considered

- **Reuse the gameserver iptables DNAT path as-is** — rejected: the masquerade destroys the client IP, which mail's anti-spam layer depends on.
- **`caddy-l4` module (keep one proxy)** — rejected: requires an `xcaddy` custom build the Ansible caddy role would then have to manage; a separate purpose-built daemon is simpler than a bespoke Caddy binary.
- **Accept the client-IP loss and rely only on content filtering + DKIM/DMARC** — rejected: needlessly discards connecting-IP heuristics (SPF, greylisting, RBLs) that catch a real share of inbound spam, when PROXY protocol recovers them cleanly.
- **PROXY protocol via the existing Caddy** — rejected for these ports: Caddy's HTTP path is the wrong layer for raw SMTP/IMAP TCP; the 443 HTTP surface already rides Caddy.

## Consequences

- **Real sender IPs reach Stalwart**, so SPF, greylisting, and RBL scoring work.
- **New component on the VPS: HAProxy**, alongside Caddy. Managed in IaC via a new Ansible role (or extension), UFW opens 25/465/587/993, and its config is the single source of truth for the mail port map. It is lifecycle-independent of Caddy.
- **Tunnel carries four more ports.** The WireGuard tunnel and its DNAT target now also forward the mail NodePort; only these ports plus the existing 30487/30356 are reachable from the VPS.
- **PROXY protocol trust must be scoped.** Stalwart accepts PROXY headers only from the HAProxy/tunnel source; a misconfiguration here would let a client spoof its IP, so the trusted-source allowlist is load-bearing.
- **Follows the ingress-tunnel relocation.** When the tunnel moves to the EX50 ([ADR-047](047-ingress-tunnel-relocation-to-ex50.md)), the mail port forwards move with it; HAProxy on the VPS is unaffected.
