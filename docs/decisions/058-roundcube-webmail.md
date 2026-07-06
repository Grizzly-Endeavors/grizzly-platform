# ADR-058: Roundcube Webmail for Stalwart, Gated by Authentik Forward-Auth

**Date:** 2026-07-06
**Status:** Accepted

## Context

Stalwart ([ADR-050](050-stalwart-mail-server.md)) is the platform mailbox server, but Stalwart 0.16 ships **no webmail client** — the surface at `mail.grizzly-endeavors.com` is the *admin console* only. Reading and sending mail therefore requires an external IMAP/JMAP client (Thunderbird, a phone) or pulling messages by hand over IMAP. That is a poor day-to-day story for a mailbox that now receives real mail (own-MX inbound is live), so we want a browser inbox.

A second requirement: access must sit behind **Authentik SSO**, consistent with the rest of the platform, rather than exposing a bare webmail login to the internet.

## Decision

**Deploy [Roundcube](https://roundcube.net/) (`roundcube/roundcubemail:1.7.2-apache`) in-cluster via Flux**, as the webmail front-end for Stalwart, **gated by an Authentik forward-auth proxy provider**.

- **Placement: `kubernetes/infrastructure/roundcube/`, its own Flux Kustomization** (mirrors Stalwart) — not `lab-apps`. Although it's an upstream image, it's a component of the platform mail system and its DB provisioning needs the `grizzly-platform/*` OpenBao path (the `ansible-platform-read` AppRole is scoped there), so it lives with the platform like Stalwart does.
- **State on foundation Postgres** (db/role `roundcube`), not a PVC — per the foundation-stores preference ([ADR-003](003-foundation-stores-on-r730xd.md)). Roundcube stores only prefs/contacts/identities/cache; mail bodies stay in Stalwart. The schema is created by the image's `initdb` on first start.
- **In-cluster hop to Stalwart:** Roundcube dials `stalwart-mail.stalwart.svc:993` (IMAPS) and `:465` (submissions), keeping mail traffic on the cluster network rather than hairpinning out through the VPS. The connection is TLS-encrypted with Stalwart's real Let's Encrypt cert; peer-*name* verification is relaxed (via a mounted `custom.inc.php`) only because we dial the Service DNS name, not the cert's `mail.grizzly-endeavors.com` SAN.
- **Access control: Authentik forward-auth (Option A).** An Authentik `forward_single` proxy provider on the embedded outpost fronts `webmail.grizzly-endeavors.com`, bound to `grizzly-admins`. This mirrors the grizzly-invite admin gate exactly (same nginx `auth-url`/`auth-signin`/`auth-proxy-set-headers` pattern, same `X-Forwarded-Host` ConfigMap, same `/outpost.goauthentik.io` ExternalName bridge). Roundcube still performs its own IMAP mailbox login behind the gate; the SSO layer authenticates *who may reach the app* and shields the login page from exposure/brute-force.
- **Outpost provider list is now consolidated.** With a second proxy provider, the embedded outpost's `providers` M2M must enumerate both (a blueprint replaces the list wholesale). `blueprints/grizzly-webmail.yaml` owns the binding, listing the webmail provider (`!KeyOf`) and the invite provider (`!Find`); the outpost entry was removed from `grizzly-invite-admin.yaml`.

## Alternatives Considered

- **SnappyMail** — lighter (no DB, file-state) but would need a raw PVC against the foundation-stores preference, and Roundcube is the more standard, better-supported client. Rejected.
- **No webmail (IMAP client only)** — rejected: the user wants a browser inbox and shouldn't depend on the operator pulling mail by hand.
- **Full OIDC SSO (Roundcube `oauth2` + Stalwart `OAUTHBEARER`)** — the "no separate mailbox password" end-state. Deferred: it requires Stalwart to validate Authentik-issued tokens for SASL, which is really the front half of the planned "Stalwart pointed at an Authentik-backed directory" migration (its own ADR). Forward-auth (Option A) gets a secure browser inbox now without coupling this deploy to that migration.
- **Hairpin IMAP via the public `mail.grizzly-endeavors.com`** — clean TLS (cert matches) but routes every inbox read out to the Hetzner VPS and back, adding latency and a VPS dependency for reading local mail. Rejected in favour of the in-cluster hop with relaxed name-check.
- **lab-apps placement** — rejected: DB provisioning needs the `grizzly-platform/*` secret path, and webmail is a platform-mail component, so it lives with Stalwart.

## Consequences

- Browser inbox at `webmail.grizzly-endeavors.com`, behind Authentik (grizzly-admins), no VPS/Caddy change needed (the `*.grizzly-endeavors.com` wildcard + Caddy cluster route already cover it).
- A single mailbox login remains after the SSO gate. True single-sign-on (no mailbox password) is a later step, tied to the Stalwart↔Authentik directory work.
- Adding future forward-auth apps means appending their provider to the outpost list in `grizzly-webmail.yaml` (the one owner of that binding).
- Roundcube 1.7.2 is current and actively maintained (released 2026-07-05); the pin should be bumped with upstream.
