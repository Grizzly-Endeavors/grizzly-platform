# ADR-061: Self-Hosted ntfy as a Shared Platform Notification Service

**Date:** 2026-07-09
**Status:** Accepted
**Relates to:** [ADR-058](058-roundcube-webmail.md) (per-service Flux Kustomization + behind-Authentik contrast), [ADR-024](024-platform-secrets-on-openbao.md) (ESO + OpenBao), [ADR-004](004-observability-stack-on-r730xd.md)

## Context

The platform's only push channel was Flux → Discord alerts (`kubernetes/infrastructure/notifications/`). That covers *system* alerts (Flux reconciliation events), but there is no general-purpose way for an application to send a notification — an operational alert, a "job finished/failed" nudge, or a human-in-the-loop approval — to a phone or another service. Discord webhooks are a poor fit for per-app publish tokens, interactive approve/deny callbacks, and a clean programmatic subscribe API.

## Decision

Self-host **ntfy** as a shared platform service at `ntfy.grizzly-endeavors.com`.

- **Shared, not per-app:** one instance, many topics; each app gets a token scoped to its topic(s).
- **Private:** `auth-default-access: deny-all` plus per-topic tokens — it's internet-exposed, so nothing reads or writes a topic without an explicit grant.
- **Its own token auth, NOT behind the Authentik forward-auth gate.** The ntfy mobile apps and long-poll/stream subscribers authenticate to ntfy directly with a token; SSO forward-auth doesn't fit that client model. (Contrast [roundcube](058-roundcube-webmail.md), a browser app that *does* sit behind the gate.)
- **A platform service in `grizzly-platform`** (`kubernetes/infrastructure/ntfy/`) on `grizzly-endeavors.com` — not a personal app in lab-apps — because any platform app may publish to it. It gets its own Flux Kustomization (like roundcube/stalwart) so a transiently-unhealthy pod never blocks core infrastructure.
- **State:** SQLite (message cache, attachments, auth DB) on a **retained** `iscsi-zfs` PVC — block storage, since SQLite is unsafe over NFS, and retained so a Flux prune or accidental PVC delete doesn't destroy the token set.
- **Credentials:** consumer publish tokens are minted post-deploy with the `ntfy` CLI and stored in OpenBao (`grizzly-platform/platform/ntfy`), consumed via External Secrets — the standard platform secret pattern.
- **Complements, not replaces, Flux → Discord.** Discord stays the independent system-alert path, so a ntfy outage is still noticed on a separate channel.

## Consequences

- Apps get a one-line HTTP publish API plus **interactive action buttons** (e.g. approve/deny that POST back to the app's own endpoint), and phones/browsers/services can subscribe over stream/SSE/WebSocket.
- Two notification channels now exist (Discord for system alerts, ntfy for app + interactive) — intentional and independent.
- ntfy is **not a durable queue** (best-effort delivery + short server-side cache); it's documented as a nudge layer over an app's own source of truth, not a message bus.
- New docs: an operator [runbook](../runbooks/ntfy.md) and a consumer [integration guide](../integration/ntfy.md).

## Alternatives Considered

- **Extend Flux → Discord for app notifications.** Rejected: Discord webhooks lack per-app scoped tokens, interactive callback buttons, and a subscribe API. Kept for system alerts only.
- **Per-app notification integrations** (each app wired to its own push provider). Rejected: fragmented, with duplicated secrets and setup; a single shared service is simpler and cheaper.
- **Put ntfy behind Authentik forward-auth** (as roundcube is). Rejected: it breaks the mobile-app + token/long-poll model; ntfy's own deny-all + token auth is the correct layer.
- **Use hosted ntfy.sh.** Rejected: self-hosting keeps notifications on-platform and private, avoids a shared public topic namespace, and is free.

## References

- [ADR-058](058-roundcube-webmail.md) (the per-service Flux Kustomization pattern and the behind-Authentik contrast), [ADR-024](024-platform-secrets-on-openbao.md) (ESO + OpenBao secret pattern).
- Operate: [runbooks/ntfy.md](../runbooks/ntfy.md). Consume: [integration/ntfy.md](../integration/ntfy.md). Manifests: `kubernetes/infrastructure/ntfy/` + `kubernetes/clusters/grizzly-platform/ntfy.yaml`.
