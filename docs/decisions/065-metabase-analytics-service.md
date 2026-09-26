# ADR-065: Metabase as the Platform Analytics Front-End, on Read-Only Store Accounts

**Date:** 2026-08-03
**Status:** Accepted
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-033](033-central-identity-authentik.md) (Authentik), [ADR-049](049-app-visibility-scoped-via-group-policy-bindings.md) (group policy bindings), [ADR-061](061-ntfy-notification-service.md) (per-service Flux Kustomization pattern), [ADR-064](064-langfuse-llm-observability.md) (Langfuse + ClickHouse); grizzly-gameservers [ADR-014](https://github.com/Grizzly-Endeavors/grizzly-gameservers/blob/main/docs/decisions/014-product-event-log.md) (the product event log this reads)

## Context

`grizzly-gameservers` records two data planes: a product event log and an occupancy time series in its foundation Postgres database, and Gary's turn telemetry in Langfuse's ClickHouse. Both are shipped, populated and documented, and the only way to get a number out of either is to run SQL — `just db-query <name>` against a file in `scripts/queries/`, or a hand-rolled REST call to Langfuse's v4 metrics endpoint.

That is fine for a metric you already know you want and painful for everything else. Reading a trend means re-running a query and comparing numbers by eye; a follow-up question ("which guild is that spike?") means editing SQL and re-running; and none of it can be looked at from a phone. The queries themselves are careful — each carries comments about the traps that make a naive version wrong — but a query file is not a way to *watch* a system.

The data is also about to get more valuable rather than less: the service has real users, occupancy sampling runs every five minutes, and the productization experiment's whole point is to see whether the numbers move.

## Decision

Deploy **Metabase** as a shared platform service at `analytics.grizzly-endeavors.com`, following the same shape as ntfy, Roundcube and Langfuse: plain manifests under `kubernetes/infrastructure/metabase/` with its own Flux Kustomization, so a transiently-unhealthy pod never blocks core infrastructure from reaching Ready.

**Plain manifests, not a Helm chart.** Metabase publishes no official chart. The community chart in wide use adds a values-file indirection over what is, in the end, one Deployment, one Service and one Ingress — and it would become a second upstream to track for a service whose entire configuration surface is a dozen environment variables. Roundcube and ntfy are deployed the same way for the same reason.

**Metabase reads through dedicated read-only accounts, never an app's own role.** This is the load-bearing decision. Metabase's SQL editor hands raw SQL to the connection, so a data source wired with `grizzly_gameservers`' owner credential would let anyone with dashboard access `DELETE FROM events` — against the live product database, from a browser. Instead `setup-metabase-stores.yml` provisions a `metabase_ro` Postgres role holding `CONNECT` + `USAGE` + `SELECT` and nothing else, and a `metabase_ro` ClickHouse user holding `SELECT` on `langfuse.*`. `ALTER DEFAULT PRIVILEGES FOR ROLE <owner>` covers tables the app's own migrations create later, so a new table is readable without a follow-up grant. The playbook asserts both halves — that every table is readable, and that no table is writable — because a permission drift in either direction is invisible until it matters.

**The application database is on foundation Postgres, and only that.** Metabase's default H2 file database is explicitly not for production, and a PVC would put durable state on cluster storage against [ADR-003](003-foundation-stores-on-r730xd.md). The `metabase` role owns the `metabase` database and runs its own Liquibase migrations there. Nothing in the namespace mounts a volume that survives a restart.

**Authentik forward-auth is the only way in, scoped to `grizzly-admins`** — the same policy binding that gates grizzly-invite's provisioning UI. Metabase OSS has no SAML or JWT SSO (those are commercial features), so a proxy provider is the closest available equivalent to the OIDC integration Langfuse and Nextcloud get. Unlike the invite broker, Metabase does not re-check `X-authentik-groups` in-app, so the binding is the whole gate rather than defense in depth — which is exactly why it is scoped to admins and not to `grizzly-users`.

**Each app seeds its own content.** The platform owns the service, the grants and the integration guide; an app owns the questions and dashboards built on its data. `grizzly-gameservers` carries a seeding script that turns its `scripts/queries/*.sql` into Metabase questions, so the SQL stays version-controlled in the repo that understands its caveats rather than becoming click-ops that exists only inside Metabase's database.

## Consequences

- The gameservers data planes become browsable: filter by guild, drill into a spike, watch a trend, all from a phone, without editing SQL.
- Metabase's data source list is a standing inventory of what a compromised admin session could read. Adding a database to it is a deliberate act — one entry in `metabase_readonly_databases` plus a playbook run — not a UI click, precisely so it stays visible in git.
- **The read-only role is not a security boundary against a hostile admin**, only against accident and against a bug in a hand-written query. Anyone who passes the Authentik binding can read every row of every connected database, including Discord user ids in `events` and verbatim tool arguments in Langfuse traces.
- Langfuse's ClickHouse schema is internal and unversioned. Questions built directly on `langfuse.*` can break on a Langfuse upgrade, and that is a cost accepted per-question rather than a reason to skip the data source — the Langfuse UI remains the supported way to read traces.
- One more JVM on the cluster, sized at 2Gi requested / 6Gi limit with a pinned 4Gi heap. Idle cost is real but small; the R730xd has the headroom.
- Losing `MB_ENCRYPTION_SECRET_KEY` does not lose dashboards, but every stored data source password becomes undecryptable and has to be re-entered. It is 1Password-backed like every other platform secret.
- New docs: an operator [runbook](../runbooks/metabase.md) and an [integration guide](../integration/metabase.md) for exposing an app's database to Metabase.

## Alternatives Considered

**Grafana, which is already deployed.** It reaches Postgres and could plot the occupancy series, and reusing a running service is the cheaper move. Rejected because the questions being asked here are not time-series-shaped: "which guilds churned after their first server", "how much playtime per game", "acquisition funnel from `guild_joined` to first create" are exploratory, joined, drill-down queries. Grafana's Postgres panels are a chart builder over a query you already wrote — which is the exact position we are trying to leave — and mixing product analytics into the infrastructure monitoring stack muddles two audiences with different retention and access needs.

**Keeping `just db-query` and adding more query files.** Zero new infrastructure, and the queries stay honest because their caveats live beside them in comments. Rejected because it does not address the actual complaint: the friction is in *asking a follow-up question*, and a new query file per follow-up is the slowest possible loop. The query files survive regardless — the seeding script makes them Metabase's starting content rather than replacing them.

**Superset.** More capable on large deployments and similarly open-source. Rejected as a worse fit at this size: it wants Redis plus Celery workers plus a metadata database to run properly, which is three more moving parts than Metabase's single container, for capabilities (async query queues, fine-grained row-level security, a semantic layer) that a two-data-source homelab will not use.

**Connecting Metabase as each app's owner role.** Simplest to provision — no second role, no default-privileges bookkeeping, and new tables are readable for free. Rejected because it makes a browser tab one typo away from writing to the live product database, and because "nobody would run that" is not a control. The extra role is roughly twenty lines of Ansible.

**Metabase Cloud.** Removes the operational burden entirely. Rejected for the same reasons as PostHog Cloud in [ADR-064](064-langfuse-llm-observability.md): it is a paid subscription for an experiment, it cannot use the Authentik SSO the platform already runs, and it would require exposing the foundation Postgres to the internet or running a tunnel agent to reach data that never otherwise leaves the LAN.
