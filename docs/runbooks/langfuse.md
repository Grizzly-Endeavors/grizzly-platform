# Runbook: Langfuse (LLM observability)

Langfuse is the platform's LLM-observability service — traces, token/cost accounting, prompt management and eval scores for the first-party agents. Live at **https://langfuse.grizzly-endeavors.com**, login via Authentik only.

Why it exists and why it is shaped this way: [ADR-064](../decisions/064-langfuse-llm-observability.md).

## Shape

```
k8s (namespace: langfuse)              R730xd (10.0.0.200)
─────────────────────────              ───────────────────
langfuse-web    ──────────────────►    foundation-postgres    :5432
langfuse-worker ──────────────────►    foundation-kv-cache    :6379  (logical DB 2)
                ──────────────────►    versitygw s3-hot       :7070  (bucket: langfuse)
                ──────────────────►    foundation-clickhouse  :8123 / :9000
```

The web pod serves the UI and the ingestion API; the worker folds queued events into ClickHouse. **All four data stores are external** — every bundled sub-chart in the upstream chart is disabled, because they are Bitnami and now default to frozen `bitnamilegacy/*` images.

Code: `kubernetes/infrastructure/langfuse/` + `kubernetes/clusters/grizzly-platform/langfuse.yaml`. Stores provisioned by `ansible/playbooks/setup-langfuse-stores.yml`.

## Health

```bash
kubectl get pods -n langfuse                       # both 1/1 Running
curl -s -o /dev/null -w '%{http_code}\n' https://langfuse.grizzly-endeavors.com
kubectl exec -n langfuse deploy/langfuse-web -- \
  node -e 'fetch("http://localhost:3000/api/public/health").then(r=>console.log(r.status))'
```

Metrics: ClickHouse is scraped natively at `10.0.0.200:9126/metrics` (Prometheus job `clickhouse`). Alerts `ClickHouseDown`, `ClickHouseMemoryHigh` and `ClickHouseDelayedInserts` live in `ansible/roles/r730xd-prometheus/templates/rules/grizzly-platform.yml.j2`.

## Adding a project

Projects are unlimited. Create one in the UI (org → new project), then mint a key pair under **Settings → API keys**. Store the secret key in 1Password under the consuming app's item, and land it in that app's namespace with an `ExternalSecret` — see [integration/secrets.md](../integration/secrets.md).

The public/secret pair goes to the SDK along with the host `https://langfuse.grizzly-endeavors.com`.

## Onboarding a person

Nothing to do in Langfuse. Authentik is the gate: mint an invite in the [grizzly-invite](https://github.com/Grizzly-Endeavors/grizzly-invite) broker and send the link. Once enrolled, they sign in here and get their own account.

This means **any `grizzly-users` member can create their own org here.** To narrow that, bind a group policy to the `langfuse` application in `kubernetes/infrastructure/authentik/blueprints/langfuse.yaml` — `nextcloud.yaml` is the worked example ([ADR-049](../decisions/049-app-visibility-scoped-via-group-policy-bindings.md)).

## Upgrading

Self-hosted Langfuse is **officially unsupported** upstream and ships continuously from `master` — there is no release train, and the Helm chart's `appVersion` still tracks the v3 line, so the image tag is pinned by hand in `helmrelease.yaml`.

**Pin against the published image tags, not the GitHub release list — the two are not in step.** A GitHub release can exist for days before (or without) its images being pushed. Check both repositories:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://hub.docker.com/v2/repositories/langfuse/langfuse/tags/<tag>
curl -s -o /dev/null -w '%{http_code}\n' https://hub.docker.com/v2/repositories/langfuse/langfuse-worker/tags/<tag>
```

Bump `langfuse.image.tag` (and the chart `version` if moving that too), then render locally before pushing — it catches value mistakes in seconds instead of a Flux round-trip:

```bash
helm template langfuse langfuse/langfuse --version <chart> -n langfuse -f <values>
```

## Recovery

Everything durable is external, so the pods are disposable — `kubectl rollout restart deploy -n langfuse` is safe and loses nothing. Recovery therefore means recovering the stores, which follow the normal foundation-store backup story.

To rebuild from scratch: drop and re-run `setup-langfuse-stores.yml`, then let Flux reinstall. Migrations reapply on startup.

## Common failure modes

**Web pod in `CrashLoopBackOff` with `P3009`.** Prisma found a migration marked started but never finished, and refuses to proceed. The usual cause is the container being killed mid-migration — a cold database has 400+ migrations to apply, which is why the liveness probe budget is deliberately generous (~5 minutes) in `helmrelease.yaml`. Do not shorten it.

To recover, find the stuck row and confirm whether its effect actually landed before deciding:

```bash
ssh r730xd "sudo docker exec foundation-postgres psql -U postgres -d langfuse -tAc \
  \"SELECT migration_name, started_at FROM _prisma_migrations WHERE finished_at IS NULL\""
```

Read that migration's SQL in the Langfuse repo. If its changes are already present in the schema, close the bookkeeping row (equivalent to `prisma migrate resolve --applied`):

```bash
ssh r730xd "sudo docker exec foundation-postgres psql -U postgres -d langfuse -c \
  \"UPDATE _prisma_migrations SET finished_at = now(), applied_steps_count = 1 \
    WHERE migration_name = '<name>' AND finished_at IS NULL\""
```

If the changes are *not* present, mark it rolled back instead so it re-runs.

**`SIGNIN_OAUTH_ERROR` with nothing in Authentik's logs.** The request never left Langfuse. Almost always the issuer: NextAuth builds the discovery URL by concatenating `issuer + "/.well-known/openid-configuration"`, so a **trailing slash** produces a doubled slash, Authentik answers `301`, and `openid-client` refuses to follow redirects. `AUTH_CUSTOM_ISSUER` must have **no trailing slash**, even though Authentik's own issuer value has one.

**Sign-in succeeds but fails on `adapter_error_createUser`.** Signup is disabled. It must stay enabled — Authentik is the gate, and with signup off the instance cannot create even its first account.

**Media uploads fail while event ingestion looks fine.** The S3 region. versitygw validates the region embedded in a presigned URL's `X-Amz-Credential` and only accepts `us-east-1`; ordinary SigV4 requests pass with any region string, so the two paths fail differently.

**Ingestion stalls, `ClickHouseDelayedInserts` firing.** Merges are behind the write rate. Check ClickHouse memory and disk on `/mnt/zfs/foundation/clickhouse`; the worker retries, so this degrades before it drops.

## Dependencies

Langfuse depends on foundation Postgres, kv-cache, ClickHouse, versitygw s3-hot, Authentik (login), and ingress-nginx. Nothing depends on Langfuse — it is an observability sink, so its outage costs visibility, not function. Agents should treat a failed trace export as non-fatal.
