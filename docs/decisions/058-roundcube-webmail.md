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
- **Mail hop to Stalwart via the public host:** Roundcube dials `mail.grizzly-endeavors.com:993` (IMAPS) / `:465` (submissions), *not* the in-cluster `stalwart-mail` Service. Stalwart's mail listeners carry `overrideProxyTrustedNetworks: 10.0.0.0/8`, and the pod network (10.244.x) is inside that range — so a direct in-cluster connection is treated as PROXY-protocol and reset (`errno 104`) when it carries no PROXY header. The public path rides the VPS HAProxy, which prepends the PROXY header Stalwart expects, and the cert matches this SAN (no TLS name kludge). The cost is a hairpin out to the VPS and back, which is fine for low-volume webmail.
- **Access control: Authentik forward-auth (Option A).** An Authentik `forward_single` proxy provider on the embedded outpost fronts `webmail.grizzly-endeavors.com`, bound to `grizzly-admins`. This mirrors the grizzly-invite admin gate exactly (same nginx `auth-url`/`auth-signin`/`auth-proxy-set-headers` pattern, same `X-Forwarded-Host` ConfigMap, same `/outpost.goauthentik.io` ExternalName bridge). Roundcube still performs its own IMAP mailbox login behind the gate; the SSO layer authenticates *who may reach the app* and shields the login page from exposure/brute-force.
- **Outpost provider list is now consolidated.** With a second proxy provider, the embedded outpost's `providers` M2M must enumerate both (a blueprint replaces the list wholesale). `blueprints/grizzly-webmail.yaml` owns the binding, listing the webmail provider (`!KeyOf`) and the invite provider (`!Find`); the outpost entry was removed from `grizzly-invite-admin.yaml`.

## Alternatives Considered

- **SnappyMail** — lighter (no DB, file-state) but would need a raw PVC against the foundation-stores preference, and Roundcube is the more standard, better-supported client. Rejected.
- **No webmail (IMAP client only)** — rejected: the user wants a browser inbox and shouldn't depend on the operator pulling mail by hand.
- **Full OIDC SSO (Roundcube `oauth2` + Stalwart `OAUTHBEARER`)** — the "no separate mailbox password" end-state. Deferred: it requires Stalwart to validate Authentik-issued tokens for SASL, which is really the front half of the planned "Stalwart pointed at an Authentik-backed directory" migration (its own ADR). Forward-auth (Option A) gets a secure browser inbox now without coupling this deploy to that migration.
- **In-cluster hop to `stalwart-mail.stalwart.svc`** — the original plan (keep traffic on the cluster, relax the TLS name-check via a `custom.inc.php`), but it doesn't work: those listeners treat the pod network as a PROXY-protocol source and reset the raw connection. Would require a dedicated PROXY-free internal listener on Stalwart (the "narrower PROXY trust" follow-up) — deferred; the public hop works today with no Stalwart change.
- **lab-apps placement** — rejected: DB provisioning needs the `grizzly-platform/*` secret path, and webmail is a platform-mail component, so it lives with Stalwart.

## Consequences

- Browser inbox at `webmail.grizzly-endeavors.com`, behind Authentik (grizzly-admins), no VPS/Caddy change needed (the `*.grizzly-endeavors.com` wildcard + Caddy cluster route already cover it).
- A single mailbox login remains after the SSO gate. True single-sign-on (no mailbox password) is a later step, tied to the Stalwart↔Authentik directory work.
- Adding future forward-auth apps means appending their provider to the outpost list in `grizzly-webmail.yaml` (the one owner of that binding).
- Roundcube 1.7.2 is current and actively maintained (released 2026-07-05); the pin should be bumped with upstream.
