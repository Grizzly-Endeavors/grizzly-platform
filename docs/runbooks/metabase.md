# Runbook: Metabase

Operating the platform analytics service at <https://analytics.grizzly-endeavors.com>. The *why* is [ADR-065](../decisions/065-metabase-analytics-service.md); connecting **your app's** data to it is [integration/metabase.md](../integration/metabase.md).

## Shape

One JVM in the `metabase` namespace, stateless in-cluster. Everything durable is on the foundation stores:

```
browser ─► VPS Caddy ─► WireGuard ─► ingress-nginx ─► Authentik outpost (grizzly-admins)
                                                            │ pass
                                                            ▼
                                                      metabase :3000
                                                            │
                          ┌─────────────────────────────────┼─────────────────────────────┐
                          ▼                                 ▼                             ▼
             foundation Postgres                foundation Postgres            foundation ClickHouse
             metabase / metabase                metabase_ro / <app dbs>        metabase_ro / langfuse
             (its own state, RW)                (data sources, SELECT only)    (data sources, SELECT only)
```

The split between the second and third rows is the point: Metabase owns exactly one database and can only read the rest. See [ADR-065](../decisions/065-metabase-analytics-service.md).

| Piece | Where |
|---|---|
| Manifests | `kubernetes/infrastructure/metabase/` |
| Flux Kustomization | `kubernetes/clusters/grizzly-platform/metabase.yaml` |
| Store provisioning | `ansible/playbooks/setup-metabase-stores.yml` |
| Authentik gate | `kubernetes/infrastructure/authentik/blueprints/metabase.yaml` |
| Add a data source | `scripts/metabase-add-database.sh` |

## Standing it up

Order matters only in that Metabase crash-loops until its database exists — it recovers on its own once the play has run, no restart needed.

**1 — Seed the credentials in 1Password** (vault `grizzly-platform`). Four values, all generated locally, none of which should contain a single quote (the Postgres plays pass them through psql's `:'pw'` literal):

```bash
openssl rand -base64 36   # stores-metabase / db_password
openssl rand -base64 36   # stores-metabase / readonly_db_password
openssl rand -base64 36   # stores-metabase / clickhouse_password
openssl rand -base64 32   # platform-metabase / encryption_key
```

**2 — Provision the stores:**

```bash
ansible-playbook -i ansible/inventory ansible/playbooks/setup-metabase-stores.yml \
  --vault-password-file .vault_pass -v
```

Three tagged plays: `--tags db` (Metabase's own role + database), `--tags readonly` (the `metabase_ro` Postgres role and its grants), `--tags clickhouse` (the `metabase_ro` ClickHouse user). The `readonly` play asserts both that every app table is readable and that none is writable, and fails the run either way.

**3 — Let Flux apply it.** The Kustomization reconciles on merge to `main`; force it with `flux reconcile kustomization metabase --with-source`.

**4 — Create the first admin.** Visit <https://analytics.grizzly-endeavors.com> (you must be in `grizzly-admins` to get past the gate) and complete the setup wizard. Skip the "add your data" step; step 6 does it properly. Store the credentials in 1Password as `platform-metabase` / `admin_email` + `admin_password` — this is the instance's bootstrap account, the equivalent of Authentik's `akadmin`, and it is the only way back in if the gate itself is what's broken.

**5 — Mint an API key.** Admin → Settings → Authentication → API keys → Create, in the **Administrators** group. Store it in 1Password as `platform-metabase` / `api_key`; it cannot be retrieved again afterwards. Both scripts below read it from there.

**6 — Add the data sources:**

```bash
scripts/metabase-add-database.sh postgres grizzly_gameservers
scripts/metabase-add-database.sh clickhouse langfuse
```

**7 — Seed an app's questions**, from that app's own repo — for gameservers, `just seed-metabase` in `grizzly-gameservers`.

## Accounts

Metabase's account model is **separate from Authentik**. The forward-auth binding decides who reaches the login page; Metabase decides who has an account. Both have to be true, and neither implies the other.

- **`platform-metabase` in 1Password** holds the bootstrap admin (`admin_email` / `admin_password`) and the `api_key` the scripts use. Keep the bootstrap account — it is the way in when the SSO path is the thing that's broken.
- **Adding a person:** Admin → People → Invite, and make sure they are also in `grizzly-admins` in Authentik or they will never see the login page. There is no SMTP wired up, so hand them the invite link out of band.
- **Removing a person** takes both halves too: deactivate them in Metabase *and* drop them from `grizzly-admins`. Doing only the second leaves an account that works the moment anyone re-adds them to the group.

## Health

```bash
kubectl -n metabase get pods
kubectl -n metabase logs deploy/metabase --tail=100
kubectl -n metabase port-forward svc/metabase 3456:80    # then curl /api/health
```

`/api/health` returns `{"status":"ok"}` only once migrations have finished. The startup probe allows five minutes for that; a cold first boot legitimately takes a couple of minutes.

## Adding another database

Two steps, both in git:

1. Add `{database, owner}` to `metabase_readonly_databases` in `ansible/playbooks/setup-metabase-stores.yml` and re-run with `--tags readonly`.
2. `scripts/metabase-add-database.sh postgres <database>`.

Doing only the second gives a connection that saves cleanly and then shows no tables, because `metabase_ro` cannot see the schema. Never grant by hand in `psql` — a hand grant is invisible to the play and is lost the next time the database is rebuilt. Full walkthrough in [integration/metabase.md](../integration/metabase.md).

## Upgrading

Bump the tag in `kubernetes/infrastructure/metabase/deployment.yaml` and merge. Metabase's OSS line is `v0.x` (`v1.x` is the commercial build — do not cross the streams), and patch releases land near-weekly, so check [the releases page](https://github.com/metabase/metabase/releases) rather than carrying a version forward.

The Deployment uses `Recreate` deliberately: the new pod runs Liquibase migrations against the shared application database, and a rolling update would briefly point the old version at an already-migrated schema. Expect a few seconds of downtime, and more on a minor-version bump that migrates a lot.

**Migrations are one-way.** Rolling the image tag back after a minor-version upgrade will not roll the schema back, and the older Metabase will refuse to start against it. If a bump goes wrong, the recovery path is restoring the `metabase` database from a foundation Postgres backup, not editing the tag.

## Failure modes

**Pod crash-loops with a connection error to `10.0.0.200:5432`.** The `metabase` role or database doesn't exist yet, or its password drifted from 1Password. Re-run the play with `--tags db` — the password-sync task runs unconditionally and `ALTER ROLE`s it back.

**`Cannot decrypt encrypted String`.** `MB_ENCRYPTION_SECRET_KEY` changed or was lost. Dashboards and questions are fine; the stored data source passwords are not. Restore the original key from 1Password, or delete and re-add each data source. Note the ExternalSecret is `refreshPolicy: OnChange` and does not poll — after changing the 1Password value you must also touch the ExternalSecret, or the pod keeps using the old one until it restarts.

**A data source shows zero tables.** Two different causes that look identical.

First check `initial_sync_status` — `scripts/metabase-add-database.sh` waits for it, but a sync requested while Metabase is still finishing startup is accepted and quietly does nothing. If it is `incomplete`, just ask again: Admin → Databases → the database → *Sync database schema now*.

If it is `complete` and the tables are still missing, it is grants. For Postgres, re-run the play with `--tags readonly`; for ClickHouse, `--tags clickhouse` — the `system.databases`/`tables`/`columns` grants are what the schema sync walks, and without them the connection health-checks green and finds nothing.

**A saved question against Langfuse breaks after a Langfuse upgrade.** Expected. Langfuse's ClickHouse schema is internal and unversioned; questions built on it are best-effort by design ([ADR-065](../decisions/065-metabase-analytics-service.md)). Fix the question or fall back to the Langfuse UI.

**Sign-in loops, or the browser lands on a generic 403.** The 403 is the outpost refusing someone outside `grizzly-admins` — that is the gate working. A loop instead means the forward-auth wiring is off: check that the `metabase` proxy provider is in the embedded outpost's provider list in `blueprints/grizzly-webmail.yaml` (that one file owns the whole list), and that `metabase-auth-headers` carries the right `X-Forwarded-Host`.

**Queries time out at five minutes.** That is the nginx ceiling in `ingress.yaml`, and it is deliberate. A question that slow wants a model or a summary table, not a longer timeout.

## See also

- [ADR-065](../decisions/065-metabase-analytics-service.md) — why Metabase, why read-only roles, what was rejected.
- [integration/metabase.md](../integration/metabase.md) — expose an app's database to Metabase.
- [integration/postgres.md](../integration/postgres.md), [integration/clickhouse.md](../integration/clickhouse.md) — the stores underneath.
- [runbooks/langfuse.md](langfuse.md) — the supported way to read Gary's traces.
