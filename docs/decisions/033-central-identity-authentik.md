# 033: Authentik as the central identity provider

**Date:** 2026-06-29
**Status:** accepted
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md), [ADR-019](019-ingress-and-tls-termination.md), [ADR-024](024-platform-secrets-on-openbao.md)

## Context

Every self-hosted app manages its own users and auth, so accounts are duplicated per app and there is no central place to issue machine credentials (API keys / OAuth clients) for service-to-service access. We want one identity provider that apps delegate login to (OIDC for apps that speak it, forward-auth for those that don't) and that issues OAuth clients and tokens for machine access.

Authentik is the chosen IdP. The placement question is where it lives: the `lab-apps` repo (personal/third-party app manifests) or the platform repo. Authentik is not an app in the lab-apps sense — it becomes an auth *dependency* of both platform apps and lab-apps, and it couples to the ingress layer (forward-auth outposts terminate at ingress-nginx). The lab-apps README explicitly defers cluster-wide services (ingress, cert-manager, external-secrets, monitoring, registry) to the platform. An IdP belongs in that same tier.

This ADR records the stand-up decision (core service). App integrations — OIDC clients, forward-auth outposts, machine tokens, and declarative blueprints — are deferred follow-ups.

## Decision

**Deploy Authentik as a platform infrastructure service in grizzly-platform (`kubernetes/infrastructure/authentik`), backed by the existing R730xd foundation Postgres and Redis, with secrets from OpenBao.**

1. **Placement: platform, not lab-apps.** It reconciles through the existing `infrastructure` Flux Kustomization (one line added to `kubernetes/infrastructure/kustomization.yaml`). Deployed via the official `authentik/authentik` Helm chart (pinned `2026.5.3`) as a Flux `HelmRelease`, server + worker.
2. **Hostname `sso.bearflinn.com`.** Provider-agnostic — a future swap away from Authentik keeps the user-facing URL. Plain-HTTP in-cluster `Ingress` (class `nginx`); external TLS terminates at the VPS, and Caddy's `*.bearflinn.com` wildcard already routes any new subdomain to the cluster ingress, so no VPS/Caddy/DNS change is needed (ADR-019).
3. **Reuse the foundation stores (ADR-003), don't bundle.** The chart's bundled Postgres subchart is disabled; Authentik points at the central Postgres (`10.0.0.200:5432`) with a dedicated `authentik` DB + login role. This chart version ships no Redis subchart, so Redis is configured purely via `AUTHENTIK_REDIS__*` env, pointing at the central Redis (`10.0.0.200:6379`) on a dedicated DB index (`1`) to avoid key collisions.
4. **DB provisioning via a dedicated playbook**, `ansible/playbooks/setup-authentik.yml`, that creates the role + database idempotently through `docker exec` against the foundation Postgres container — rather than extending the shared `r730xd-postgres` role. It also wires the metrics scrape target.
5. **Secrets via OpenBao + ESO.** `secret/grizzly-platform/platform/authentik` holds `secret_key`, `db_password`, `bootstrap_password`, `bootstrap_token`; the Redis password is read from the existing `stores/redis` path (single source of truth). An `ExternalSecret` syncs them into the namespace; the HelmRelease injects them into server + worker via `global.env`.
6. **Out of the Kyverno signing gate.** The namespace is deliberately unlabelled (`grizzly.io/gated` absent). Authentik is the third-party `ghcr.io/goauthentik/server` image, not built or cosign-signed by our CI gate.
7. **Monitoring via the established NodePort pattern.** A NodePort `Service` (30891) exposes the server `:9300` metrics; the R730xd Prometheus scrapes it (new `authentik` job + `k8s-authentik.yml` target), with an `AuthentikDown` critical alert. Flux deploy failures are already covered by the wildcard `flux-system` Alert → Discord.

## Alternatives Considered

- **Put Authentik in lab-apps.** Lighter deploy pattern (no Kyverno/ADR ceremony), but it would make platform services depend on a personal-app repo for auth, and forward-auth couples to platform-owned ingress. Wrong tier.
- **Bundle per-app Postgres/Redis (as Nextcloud does in lab-apps).** Nextcloud isolates its DB to avoid handing a *lab app* the foundation superuser. Authentik *is* platform infrastructure, so sharing the foundation stores is appropriate and avoids running yet another stateful pair in-cluster (nodes are diskless — ADR-003).
- **Extend the `r730xd-postgres` role with a declarative databases list.** Cleaner long-term for many platform DBs, but a larger change to a shared role for a single consumer today. A one-shot provisioning playbook is the lighter touch; revisit if more platform services need foundation databases.
- **Stand up a dedicated Valkey for Authentik now.** The user is mid-migration from Redis to Valkey (OSS-license driven). Authentik only needs `host:port:password`, so the cutover is transparent on the shared instance — a separate cache is more moving parts than a single shared cache warrants.

## Consequences

- One identity to manage; apps progressively delegate login to Authentik and machine access gets first-class OAuth clients/tokens.
- **SSO single point of failure.** Once apps are wired to Authentik, an Authentik (or its Postgres/Redis) outage breaks login for all of them. The `AuthentikDown` critical alert exists for this; the data path (Postgres) is backed up daily by the `r730xd-postgres` role, and the pods are stateless and reschedule automatically.
- **New foundation-Postgres consumer.** Authentik shares the central Postgres and Redis; account for it in connection/memory headroom on those instances.
- **Deploy is not a pure GitOps flip.** The `authentik` DB/role must be provisioned (`setup-authentik.yml`) and the OpenBao keys seeded before the first reconcile, or the pods crash-loop until both exist.
- **Internal Authentik config is click-ops until blueprints land.** Providers, applications, outposts, and tokens are configured in the UI for now; a declarative blueprint story is the recommended next step to bring that under IaC, and warrants its own plan. _(Done: [ADR-037](037-authentik-config-as-code-blueprints.md) brings internal config under IaC via file-based blueprints.)_
