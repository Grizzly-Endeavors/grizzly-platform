# ADR-064: Langfuse as the Platform LLM-Observability Service, and ClickHouse as a Foundation Store

**Date:** 2026-08-02
**Status:** Accepted
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-012](012-hot-services-on-zfs-minio-split.md) (hot tier on ZFS), [ADR-055](055-s3-object-store-versitygw.md) (versitygw, MinIO retired), [ADR-056](056-redis-to-valkey.md) (Valkey), [ADR-033](033-central-identity-authentik.md) (Authentik), [ADR-061](061-ntfy-notification-service.md) (per-service Flux Kustomization pattern)

## Context

The platform runs first-party LLM agents — most significantly **Gary**, the ops agent in `grizzly-gameservers` that reads game configs, mutates files, restarts servers and reports back. Gary is the component the product's value rests on, and he was entirely unobservable: `crates/bot` carries `tracing` and `tracing-subscriber` but no exporter, so nothing about his behaviour reached Prometheus, Loki or Tempo.

That leaves basic questions unanswerable: how often does Gary escalate rather than fix, what does a fix cost in tokens, did a prompt change help or hurt, which games does he flail on. Ordinary APM does not answer these either — the useful unit is a **trace → spans → generations** with model, token counts, cost and latency attached, plus prompt versioning and eval scores. Product-analytics and tracing tools do not model that shape.

## Decision

Deploy **Langfuse** as a shared platform service at `langfuse.grizzly-endeavors.com`, and add **ClickHouse** as a fifth foundation store on the R730xd to back it.

**Langfuse is a platform service, not a gameservers-local one.** Projects are unlimited and free in the OSS build, so career-scanner and any future agentic app get their own project. It gets its own Flux Kustomization (like ntfy/roundcube/stalwart) so a transiently-unhealthy pod never blocks core infrastructure.

**Every bundled sub-chart is disabled.** The upstream chart ships PostgreSQL, ClickHouse, Valkey and MinIO as Bitnami sub-charts. Since 2025-08-28 those default to `bitnamilegacy/*` images that no longer receive updates, and the chart's own README recommends an external ClickHouse for exactly this reason. All four are set to `deploy: false` and pointed at foundation stores instead, which is where durable state belongs anyway ([ADR-003](003-foundation-stores-on-r730xd.md)) and which keeps [ADR-055](055-s3-object-store-versitygw.md) intact by not re-introducing MinIO. The result is zero Bitnami images.

**ClickHouse runs on the R730xd as a foundation store, not in-cluster.** Langfuse's traces need an OLAP column store, and there was no existing platform equivalent. Putting it beside the other stores means it is ZFS-backed directly rather than through iSCSI/CSI — which matters for a write-heavy store — needs no operator or CRDs, and inherits the same snapshot and backup story as Postgres and the rest. It is a **single node with no ClickHouse Keeper**: replication is what requires Keeper, and one server means non-replicated MergeTree, so consumers must never issue `ON CLUSTER` DDL.

**Authentik is the only way in, and also the only gate.** Password login is disabled and Langfuse is registered as a confidential OIDC client. Langfuse's own signup stays *enabled* rather than closed: Authentik enrollment is already invitation-gated ([ADR-040](040-invite-broker-cookie-bridged-enrollment.md)), so a second closed list inside Langfuse would mean provisioning every person twice for no added control — and with signup disabled the instance cannot be bootstrapped at all, since the first login has no account yet.

**Per-app accounts, not shared admin.** Langfuse gets its own Postgres role owning its own database, its own ClickHouse user scoped to its own database, and its own versitygw account — the same isolation model every other app gets, rather than connecting as `default`/superuser.

## Consequences

- Gary's behaviour becomes measurable: per-turn traces, tool calls, token and cost accounting, and eval scores. Langfuse's prompt management also pairs with the repo's `prompt-lib` Markdown→Rust compiler.
- Langfuse ships an **MCP server**, so an agent can query traces and metrics directly rather than through a scraped UI.
- ClickHouse is a new stateful system to operate — memory ceilings are set explicitly rather than derived from total RAM, because the R730xd also carries Postgres, kv-cache, versitygw ×2, OpenBao and the whole observability stack.
- Any `grizzly-users` member can create their own org in Langfuse. Narrowing that is a group policy binding on the application ([ADR-049](049-app-visibility-scoped-via-group-policy-bindings.md), `nextcloud.yaml` as the worked example).
- Self-hosted Langfuse is **officially unsupported** upstream and ships continuously from `master` with no release train, so the image tag is pinned deliberately and bumped by hand.
- New docs: an operator [runbook](../runbooks/langfuse.md) and a [ClickHouse integration guide](../integration/clickhouse.md).

## Alternatives Considered

**ClickHouse in-cluster via the ClickHouse operator.** This is what Langfuse's own v4 example does, and it is more Kubernetes-native. Rejected because it adds an operator and CRDs to track and upgrade, and puts a write-heavy OLAP store behind a CSI hop, to buy replication and scaling that a single homelab Langfuse will never use. The state would still land on R730xd ZFS anyway, just indirectly.

**The chart's bundled sub-charts.** Simplest to stand up, but they are frozen `bitnamilegacy/*` images, they would re-introduce MinIO against [ADR-055](055-s3-object-store-versitygw.md), and they would scatter durable state into cluster PVCs against [ADR-003](003-foundation-stores-on-r730xd.md).

**A general product-analytics tool (PostHog, OpenPanel, Umami).** These model *events by user* and are built around a browser tracker. They do not model traces, generations, token cost or prompt versions, and the systems being observed here are backend services with no web frontend at all. PostHog additionally caps self-hosted deployments at one project and its MCP server is cloud-only.

**PostHog Cloud.** Mature and immediately drivable via MCP, but it is a paid SaaS subscription for an experiment, it cannot use the Authentik SSO this platform already runs, and it would put the flagship product's data outside the lab.
