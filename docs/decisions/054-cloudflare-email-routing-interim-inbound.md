# ADR-054: Cloudflare Email Routing as Interim Inbound (Bootstrap)

**Date:** 2026-07-05
**Status:** Accepted (interim — to be superseded by the [ADR-050](050-stalwart-mail-server.md) own-MX cutover)
**Relates to:** [ADR-050](050-stalwart-mail-server.md), [ADR-052](052-in-cluster-acme-cert-for-mail.md), [ADR-053](053-platform-services-domain-migration.md)

## Context

The self-hosted mail stack ([ADR-050](050-stalwart-mail-server.md)) relays outbound through **SMTP2GO**, but SMTP2GO signup requires a **receiving address at `grizzly-endeavors.com`** — a chicken-and-egg, since the only thing that would provide one (Stalwart, our own MX) is the entire unbuilt mail project. At the time of this record the domain had no MX and nothing at it could receive mail. We need a receive path *before* Stalwart exists, purely to unblock the SMTP2GO account.

## Decision

**Enable Cloudflare Email Routing** on the `grizzly-endeavors.com` zone as a free, reversible **interim** inbound path, forwarding `bearflinn@` and `postmaster@` to `bearflinn@gmail.com`. This is explicitly temporary: the MX points at Cloudflare (`route{1,2,3}.mx.cloudflare.net`) only until Stalwart's inbound is live, at which point it is torn down and MX is cut over to the VPS per ADR-050 (own-MX). Configured out-of-band via the Cloudflare API (records: 3× MX, Cloudflare's `cf2024-1._domainkey` DKIM TXT, and SPF `include:_spf.mx.cloudflare.net`); catch-all left at `drop`.

## Alternatives Considered

- **Deploy Stalwart's full inbound path first, then sign up for SMTP2GO** — rejected: inverts the natural build order and stands up the entire new L4 ingress plane ([ADR-051](051-haproxy-l4-mail-ingress.md)) + in-cluster cert ([ADR-052](052-in-cluster-acme-cert-for-mail.md)) just to receive one verification email.
- **Sign up for SMTP2GO with `bearflinn@gmail.com` instead** — rejected: the SMTP2GO account should be anchored to the platform domain, and a domain receive path is needed regardless for sender-domain verification and ongoing mail.
- **Make Cloudflare Email Routing the permanent inbound** — rejected: it forwards only (no mailboxes, no IMAP/JMAP), which defeats ADR-050's self-hosted-mailbox goal. Fine as a bridge, not a destination.

## Consequences

- **SMTP2GO signup is unblocked** — `bearflinn@grizzly-endeavors.com` receives and forwards to Gmail immediately.
- **This is a manual, non-IaC change** to public DNS (Cloudflare records are hand-managed, [ADR-053](053-platform-services-domain-migration.md)) — documented here as required. There is no DNS-as-code in this repo to carry it.
- **Cutover is a hard prerequisite of the ADR-050 deploy:** when Stalwart inbound is proven, disable Email Routing, remove its MX/SPF, point MX at the VPS, and switch SPF to SMTP2GO's include. The Cloudflare and own-MX MX records are mutually exclusive.
- **SPF will need merging/replacing:** the interim SPF lists Cloudflare's include; once SMTP2GO is the sender it becomes `include:spf.smtp2go.com`. Track this so outbound doesn't fail SPF during the transition window.
