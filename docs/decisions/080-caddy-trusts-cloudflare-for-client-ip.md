# ADR-080: Edge Caddy Recovers the Visitor IP from Cloudflare

**Date:** 2026-10-06
**Status:** Accepted
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md) (VPS Caddy → WireGuard → ingress-nginx), [ADR-078](078-caddy-custom-binary-off-package-path.md) (custom Caddy build), [ADR-079](079-home-automation-stack-and-gating.md) (Home Assistant OIDC)

## Context

The public domains are proxied by Cloudflare, so the proxy VPS's Caddy receives every request from a Cloudflare edge address. Caddy passed that socket address upstream (`X-Real-IP {remote}`) and, because it did not trust Cloudflare, replaced any incoming `X-Forwarded-For` with it. Every app behind ingress-nginx therefore saw a Cloudflare edge IP as the client, and that IP can differ from one request to the next.

The symptom that surfaced it: Home Assistant's OIDC integration binds login state to the client IP. The sign-in start and the Authentik callback arrived from different Cloudflare edges, so every login failed with "Missing state cookie". The same wrong IP feeds Authentik's event log, login-failure lockouts and IP bans in every app.

## Decision

On hosts where `caddy_trust_cloudflare_proxies` is set (the proxy VPS):

1. The custom Caddy build also includes [`github.com/WeidiDeng/caddy-cloudflare-ip`](https://github.com/WeidiDeng/caddy-cloudflare-ip). It supplies `trusted_proxies cloudflare`, a range list it refreshes from Cloudflare's published IP lists every 12 hours.
2. The global `servers` block trusts only those ranges and reads the visitor IP from `CF-Connecting-IP` (`client_ip_headers`). A request from outside Cloudflare's ranges keeps its socket address, so connecting to the VPS directly cannot spoof the header.
3. The K8s proxy vhosts send `X-Real-IP {client_ip}` and `X-Forwarded-For {client_ip}` upstream. ingress-nginx already honours forwarded headers (`use-forwarded-headers`), so apps see the visitor IP.

## Alternatives Considered

- **A static list of Cloudflare ranges in the role defaults.** No extra module or rebuild. Rejected by Bear in favour of ranges that maintain themselves; a static list silently regresses to edge IPs when Cloudflare adds a range.
- **Fixing it per app** (for example, trusting `CF-Connecting-IP` in each app). Rejected: every app has the problem, and the edge is the one place that can tell a real Cloudflare request from a spoofed header.

## Consequences

- **Module maintenance:** the module's last commit was in November 2023. Its author is a Caddy core maintainer, its scope is small (fetch and parse Cloudflare's published lists), and it builds against Caddy 2.11. If a Caddy release breaks it, the xcaddy build fails before anything is installed and the running binary stays. The fallback is Caddy's built-in `trusted_proxies static` with the published ranges.
- **Cloudflare dependency:** if the range fetch fails, Caddy keeps the last list it loaded. On a cold start with no list, client IPs fall back to Cloudflare edge addresses until the next refresh succeeds. Nothing breaks except IP attribution and IP-bound logins.
- **Verification:** an app's access log, such as ingress-nginx for any host, shows visitor addresses instead of `104.16.0.0/12`-style Cloudflare addresses.
