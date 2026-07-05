# ADR-050: Stalwart as the Platform Mail Server

**Date:** 2026-07-05
**Status:** Accepted (implementation pending)

## Context

The platform has no first-party email. We want a self-hosted mailbox server for `grizzly-endeavors.com` (domain acquisition + broader service migration pending — see Consequences; `bearflinn.com` is the current domain and a viable interim). Email has hard network requirements that collide with the ingress model: the public path is HTTP-only ([ADR-019](019-ingress-and-tls-termination.md)) and the home ISP blocks port 25 with no PTR control, so the mail server's public face must be the Hetzner VPS. Outbound deliverability (IP reputation, warmup, DKIM) is the hardest part of running your own MX.

## Decision

**Deploy [Stalwart](https://github.com/stalwartlabs/stalwart)** — an all-in-one Rust mail + collaboration server (SMTP, IMAP, JMAP, POP3, CalDAV/CardDAV) — **in-cluster via Flux**, as the platform mail server.

- **Outbound relays through SMTP2GO** as a smarthost. SMTP2GO owns the sending IP reputation and **performs DKIM signing** — the whole reason to use a relay. This makes Hetzner's outbound port-25 block irrelevant and removes IP-warmup from our plate. Outbound egresses the cluster directly to SMTP2GO (587/2525/API); it never touches the VPS or the ingress tunnel.
- **Inbound: we are our own MX.** Inbound 25/465/587/993 reach the VPS and are carried to the in-cluster NodePort using the gameserver ingress topology (VPS → WireGuard tunnel → NodePort), but via an L4 proxy with PROXY protocol rather than raw DNAT — see [ADR-051](051-haproxy-l4-mail-ingress.md). Port 443 (JMAP / webmail / autoconfig / MTA-STS) rides the **existing Caddy HTTP path** as `mail.<domain>`, no new plumbing.
- **State lives on the foundation stores, not a PVC.** Stalwart's directory/metadata → foundation **PostgreSQL**; message blobs → foundation **MinIO (S3)**. This is what the foundation stores ([ADR-003](003-foundation-stores-on-r730xd.md)) exist for; diskless PXE nodes hold no durable state.
- **TLS for SMTP/IMAP is terminated by Stalwart** using a publicly-trusted cert for `mail.<domain>` minted in-cluster — see [ADR-052](052-in-cluster-acme-cert-for-mail.md).

## Alternatives Considered

- **Managed email (Fastmail / Google Workspace)** — rejected: cost, less control, and it defeats the self-host-for-fun-and-integration goal that motivates this platform.
- **Mailcow / Mailu / Mail-in-a-Box** — rejected: heavier multi-container Docker stacks (Postfix + Dovecot + Rspamd + …) vs a single self-describing Rust binary that already speaks every protocol and backs onto external SQL/S3.
- **Run Stalwart directly on the VPS** — rejected: the VPS is deliberately a stateless proxy, not an application/state host. Proxy *infrastructure* for mail belongs there ([ADR-051](051-haproxy-l4-mail-ingress.md)); the mailbox server and its data do not.
- **Self-host outbound too (own MX sending + Hetzner port-25 unblock request)** — rejected: puts IP reputation, warmup, and DKIM operations on us for no benefit. SMTP2GO does this better and removes the port-25 dependency entirely.
- **In-cluster PVC for Stalwart's embedded (RocksDB) store** — rejected: the foundation stores are the platform's durable-state answer; a large mail PVC would duplicate that and skip the existing Postgres backup / ZFS snapshot story.

## Consequences

- **Ingress split across two paths:** raw mail ports (25/465/587/993) via HAProxy + tunnel ([ADR-051](051-haproxy-l4-mail-ingress.md)); HTTP surface (443) via existing Caddy on `mail.<domain>`.
- **New dependency: the in-cluster Let's Encrypt DNS-01 issuer** ([ADR-052](052-in-cluster-acme-cert-for-mail.md)) — this is the first workload that needs a browser-trusted cert inside the cluster, the consumer ADR-019 anticipated.
- **Foundation stores gain a mail consumer.** Mail data inherits the existing Postgres `pg_dumpall` rotation and ZFS snapshots; the MinIO blob bucket wants a durable (hot ZFS) tier and its own backup consideration, settled at deploy.
- **Third-party dependency on SMTP2GO for outbound.** If SMTP2GO is down, outbound queues in Stalwart and drains on recovery; inbound and mailbox access are unaffected. Acceptable — it's a relay, not the mailbox.
- **DNS (Cloudflare):** `MX → VPS`, SPF listing SMTP2GO's includes, DKIM CNAMEs from SMTP2GO, DMARC, MTA-STS, autoconfig/autodiscover.
- **Domain sequencing:** mail is a natural first mover onto `grizzly-endeavors.com` — a fresh domain pairs cleanly with SMTP2GO handling reputation from zero. If the domain isn't yet acquired at deploy time, stand up on `bearflinn.com` and re-anchor during the migration; the topology is domain-agnostic.
- **Pre-1.0 software.** Stalwart is on the `0.16.x` line (feature-complete, pre-1.0 at time of writing). Pin to the current stable release at deploy and track upstream releases.
