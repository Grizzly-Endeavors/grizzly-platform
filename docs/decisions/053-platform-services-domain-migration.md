# 053: Platform-service domain migration to grizzly-endeavors.com

**Date:** 2026-07-05
**Status:** accepted
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md), [ADR-033](033-central-identity-authentik.md), [ADR-038](038-nextcloud-on-foundation-stores-and-sso.md), [ADR-040](040-invite-broker-cookie-bridged-enrollment.md), [ADR-050](050-stalwart-mail-server.md)

## Context

`grizzly-endeavors.com` was acquired to be the public home for **platform services** — anything multi-tenant or built for people beyond the owner — while personal apps stay on `bearflinn.com`. Nothing centralised the base domain: every hostname was hardcoded per-file across the Caddy edge config, the Authentik/SSO manifests, each app's own chart, and monitoring. So the move is a multi-layer cutover, not a single flip.

## Decision

**Migrate the platform services to `grizzly-endeavors.com`; leave personal apps on `bearflinn.com`; keep hostnames per-file (no central `base_domain` variable); hard cutover with a brief dual-serve window.**

- **Migrated:** Authentik SSO (`sso.`), grizzly-invite (`invite.`), grizzly-gameservers (`gameservers.` + `*.gameservers.`), nextcloud (`nextcloud.`), career-scanner (`career-scanner.`). Mail (Stalwart, [ADR-050](050-stalwart-mail-server.md)) is greenfield directly on the new domain.
- **Stayed on bearflinn.com:** landing-page, resume-site, feedback-ingest (belongs to Residuum), actual-budget, obsidian-livesync, Home Assistant, PostHog, test. caz-portfolio is on its own domain (`pennydreadfulsfx.com`).
- **Edge:** the VPS Caddy role gained `caddy_wildcard_domains` (a list of wildcard roots, each with its own Cloudflare DNS-01 cert); it now serves `*.grizzly-endeavors.com` alongside `*.bearflinn.com`. Cloudflare records mirror the existing split — web wildcard + apex **proxied** (orange), `*.gameservers` **grey** (raw game traffic bypasses the HTTP proxy).
- **SSO moved with invite:** the invite cookie-bridge ([ADR-040](040-invite-broker-cookie-bridged-enrollment.md)) requires the broker cookie and the SSO host to share a registrable domain, so `sso.` and `invite.` moved together. Authentik dual-served both `sso.` hosts during the window so each app's OIDC issuer/redirect could flip independently; the old host was dropped once all apps moved.

## Alternatives Considered

- **Central `base_domain` variable + Flux `postBuild` substitution** — rejected: app-chart hosts live in sibling repos, so centralisation would be partial and leaky for a one-time move; the honest per-file edit was cheaper and clearer.
- **Permanent 301 redirects from the old hosts** — rejected: hard cutover was chosen (no persistent clients pin the old hosts); old hostnames simply 404 after the drop.
- **Keep SSO on bearflinn.com** — rejected: it would force invite to stay too (shared cookie domain) and leave identity infrastructure off the brand domain.

## Consequences

- **Caddy now holds two wildcard certs** and serves both domains indefinitely — bearflinn.com still fronts the personal apps.
- **Per-app OIDC/redirect URIs and the external social-IdP callbacks (Discord/GitHub/Google) were re-registered** on the new host; the old callbacks were pruned after the cutover.
- **Nextcloud needed two live `occ` steps** the chart only seeds at install: `trusted_domains` and the `user_oidc` provider discovery URI. Future host changes to an already-installed Nextcloud must repeat them.
- **gameservers' Agones label keys were renamed** (`grizzly-gameservers.grizzly-endeavors.com/{game,instance}`); pre-existing shim instances carrying the old keys were decommissioned. The connection subdomains ride the grey `*.gameservers.grizzly-endeavors.com` wildcard; the VPS `game_ingress` is port-based and unchanged.
- **career-scanner's domain moved cleanly, but its login exercised two pre-existing app bugs** (OIDC discovery double-slash, missing DB functions) — tracked in career-scanner issues #9 and #10, not migration defects.
- **Monitoring needed no change** — only `landing`/`resume` (staying) have hostname-based probes; migrated apps use IP:port NodePort metrics.
- Old ADRs (033/038/040) keep their original hostnames as point-in-time records; this ADR is the pointer for the current `grizzly-endeavors.com` hosts.
