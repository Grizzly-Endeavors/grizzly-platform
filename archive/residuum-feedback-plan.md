# Residuum Feedback Ingestion — Lab Changes (Archived Rollout Plan)

**Archived — this plan has fully landed.** The `feedback-ingest` app has been running live in the `residuum-feedback` namespace (Flux-managed, `kubernetes/apps/feedback-ingest/`) since 2026-04-17. Kept here as a record of the rollout plan as originally written; treat any "pending" language below as historical, not current status. For current architecture, see the live manifests and `docs/monitoring-integration.md`.

What needs to land in `grizzly-platform` to stand up the feedback ingestion feature. See `~/Projects/residuum-feedback-decisions.md` for the architectural decisions this implements.

Database schema is locked in [`residuum-feedback-schema.md`](./residuum-feedback-schema.md). **Provisioning of the `residuum_feedback` database and owning role is NOT a grizzly-platform concern** — it's owned by the feedback-ingest repo via a `workflow_dispatch` gh Actions job that runs on the self-hosted runner. grizzly-platform owns the PG instance itself (the `r730xd-postgres` role) and the superuser credential in Ansible Vault, and that's where its responsibility ends for this feature's database.

---

## Status (2026-04-15, as originally written — superseded, see banner above)

Nothing in this plan has landed in `grizzly-platform` yet. The feedback-ingest service itself is scaffolded and verified end-to-end against the live `r730xd-postgres` (`residuum_feedback` database + role provisioned by the feedback-ingest repo's bootstrap workflow), but every item below is still pending:

- **K8s manifests** in `kubernetes/apps/residuum-feedback/` — not started
- **DNS A record** for `residuum-feedback.bearflinn.com` — not added
- **Tempo multitenancy** (`multitenancy_enabled: true` in `r730xd-tempo`, second Grafana datasource, docs) — not started
- **ADR** — not written
- **Optional hardening** (ingress IP allowlist, Alertmanager rule) — not started

---

## New K8s workload

Namespace: `residuum-feedback`.

New directory: `kubernetes/apps/residuum-feedback/`

| File | Purpose |
|---|---|
| `namespace.yaml` | `residuum-feedback` namespace |
| `deployment.yaml` | Single-replica Deployment; image pulled from the lab registry |
| `service.yaml` | ClusterIP on the app's HTTP port |
| `ingress.yaml` | nginx Ingress for `residuum-feedback.bearflinn.com` routing `/api/v1/*` to the Service |
| `secret.yaml` | Sealed secret carrying `FEEDBACK_UPSTREAM_TOKEN` and the Postgres connection string |
| `network-policy.yaml` | Egress to r730xd (`10.0.0.200`) on ports `5432` (Postgres) and `4318` (Tempo OTLP); ingress only from `ingress-nginx` namespace |
| `kustomization.yaml` | Standard Flux entry point |

Add `residuum-feedback` to the top-level `kubernetes/apps/kustomization.yaml` so Flux picks it up.

---

## DNS

Add an A record for `residuum-feedback.bearflinn.com` pointing at the Hetzner proxy VPS public IP — same target as every other `*.bearflinn.com` subdomain. Traffic routes through the existing Caddy → WireGuard → nginx-ingress path with no Caddyfile changes needed.

---

## Tempo multi-tenancy

The ingest service sends report traces to a dedicated tenant `residuum-feedback` via `X-Scope-OrgID: residuum-feedback`, keeping them completely isolated from existing platform traces.

**Required changes:**

1. **Verify or enable multi-tenancy in the `r730xd-tempo` role.** By default Tempo runs single-tenant; multi-tenancy requires `multitenancy_enabled: true` in `tempo-config.yml`. Check the current template and add the flag if absent, then re-deploy with `deploy-observability.yml`.

2. **Add a second Grafana data source** (via the `r730xd-grafana` role's datasource provisioning) pointed at Tempo with `X-Scope-OrgID: residuum-feedback`. This keeps report traces queryable without polluting the existing platform Tempo data source or dashboards.

3. **Document the tenant** in `docs/monitoring-integration.md` so it's clear the `residuum-feedback` tenant is reserved for report traces and shouldn't be used for anything else.

---

## Ingress trust model

The ingest service is technically reachable at `residuum-feedback.bearflinn.com` from the public internet, but rejects any request missing the shared-secret header. Two additional hardening options worth considering:

- **IP allowlist annotation on the Ingress** — restrict to the Hetzner relay VPS IP so the service is unreachable from anywhere else, even with the secret. Tightens the blast radius if the secret leaks. Annotation: `nginx.ingress.kubernetes.io/whitelist-source-range`.
- **NetworkPolicy** — already in the manifest list; ensures ingress-nginx is the only namespace that can reach the feedback pods even if something else inside the cluster tried.

---

## Observability of the ingest service itself

Match the pattern every other K8s workload in the lab follows:

- Prometheus scrape annotations on the Deployment pod template (`prometheus.io/scrape`, `prometheus.io/port`)
- No Alloy changes needed — Alloy already tails all pod logs from `/var/log/pods/` into Loki; the `residuum-feedback` namespace will appear automatically under `namespace=residuum-feedback`
- The service exports its own operational traces to the **default** Tempo tenant (not `residuum-feedback`), so service health is visible alongside the rest of the lab

A Grafana dashboard for request rate, error rate, latency, and Tempo forward success rate can be added in a follow-up once the service is running and generating real traffic.

---

## ADR

Write `docs/decisions/NNN-residuum-feedback-ingestion.md` covering:

- Why the ingestion service lives in K8s rather than as a Compose service on r730xd alongside the observability stack
- The decision to route public traffic through the relay rather than exposing the ingest path directly
- The dedicated Tempo tenant `residuum-feedback` for trace isolation
- The shared-secret-only trust model for relay → ingestion authentication
- The reuse of the existing Caddy → WG → ingress path (no new tunnel)

Number assigned at the time of writing.

---

## Still open

- ~~PG database and role provisioning via the `r730xd-postgres` role~~ — **No longer a grizzly-platform concern.** Provisioning moved to the feedback-ingest repo (`.github/workflows/bootstrap-db.yml` + `scripts/bootstrap-db.sh`). Already live: `residuum_feedback` DB + role exist on `r730xd-postgres` and the feedback-ingest service connects to them successfully. grizzly-platform's only remaining responsibility here is keeping `vault_postgres_password` current in Ansible Vault — that's the credential the bootstrap workflow consumes via the `PG_SUPERUSER_PASSWORD` gh secret.
- Whether to add an Alertmanager rule for the ingest service's health (e.g., no successful submissions in the last N hours, or high error rate) — low priority but worth noting for the operational readiness checklist
- Image pull configuration — verify the `residuum-feedback` namespace can pull from the lab registry with the same credentials already configured for other app namespaces (likely a non-issue since the lab registry is anonymous within the cluster per `kubernetes/apps/caz-portfolio/`, but confirm when the manifests land)
