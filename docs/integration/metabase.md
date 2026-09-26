# Integration: Metabase (analytics)

**What you get:** your app's database browsable at <https://analytics.grizzly-endeavors.com> — filters, drill-downs, charts and dashboards over your own tables, without writing SQL for every follow-up question.

Metabase is a shared platform service ([ADR-065](../decisions/065-metabase-analytics-service.md)); operating it is [runbooks/metabase.md](../runbooks/metabase.md). This page is what an app owner does to get their data in.

## When to use it

- **Use it** for exploring and watching your app's own relational data — product events, usage series, anything you currently answer with a hand-run query.
- **Not** for infrastructure metrics, alerting, or dashboards on Prometheus/Loki/Tempo → that's [Grafana](observability.md). Metabase has no alerting worth relying on in the OSS build and no place in an on-call path.
- **Not** for reading LLM traces day to day → that's the [Langfuse UI](../runbooks/langfuse.md). The `langfuse` ClickHouse database *is* connected, but its schema is internal and unversioned, so anything you build on it can break on a Langfuse upgrade.

## What Metabase gets, and what it doesn't

Metabase connects to your database as **`metabase_ro`** — a role holding `CONNECT`, `USAGE` on `public`, and `SELECT`. Nothing else. Its SQL editor hands raw SQL straight to the connection, so this is the difference between a bad query returning an error and a bad query deleting your production rows.

It follows that:

- **Everything you expose is readable by every Metabase admin.** The Authentik gate is scoped to `grizzly-admins`, and Metabase does not re-check group membership per data source. If a table holds something no admin should see, it should not be in a database you connect.
- **You keep owning your schema.** Metabase never migrates, never writes, and never needs to be told about a schema change beyond a re-sync.
- **New tables are covered automatically.** `ALTER DEFAULT PRIVILEGES FOR ROLE <your app role>` is applied at provisioning time, so tables your migrations create later are readable without another grant — as long as your app creates them as its own role.

## 1 — Add your database to the provisioning play

Edit `metabase_readonly_databases` in `ansible/playbooks/setup-metabase-stores.yml`:

```yaml
metabase_readonly_databases:
  - database: grizzly_gameservers
    owner: grizzly_gameservers
  - database: your_app          # the database to expose
    owner: your_app             # the role that OWNS it — default privileges attach here
```

`owner` is not decoration. `ALTER DEFAULT PRIVILEGES` is per-granting-role, so naming the wrong role means today's tables are readable and tomorrow's are not.

Run it:

```bash
ansible-playbook -i ansible/inventory ansible/playbooks/setup-metabase-stores.yml \
  --vault-password-file .vault_pass --tags readonly -v
```

The play asserts afterwards that every table in `public` is readable by `metabase_ro` **and** that none is writable, so a wrong grant in either direction fails the run rather than shipping.

**Do not grant by hand in `psql`.** A hand grant works, is invisible to this play, and disappears the next time the database is rebuilt from scratch — leaving a dashboard that was fine for months suddenly empty with nothing in git to explain it.

## 2 — Register the connection

```bash
scripts/metabase-add-database.sh postgres your_app
```

Reads the `metabase_ro` password from 1Password, port-forwards Metabase's ClusterIP Service (bypassing the SSO gate, which would answer an API call with a sign-in redirect), creates the connection, and kicks a schema sync. Idempotent — re-running when the connection exists is a no-op.

Doing this step without step 1 gives you a connection that saves cleanly and then shows no tables, because `metabase_ro` cannot see the schema.

## 3 — Seed your questions from your own repo

Dashboards built by clicking exist only inside Metabase's database. Keep the SQL in your repo and push it up instead, so it stays reviewable, greppable, and carries its caveats in comments where the next reader will see them.

`grizzly-gameservers` is the worked example: `scripts/queries/*.sql` are the source of truth, and `just seed-metabase` turns each one into a Metabase question and assembles them into a dashboard. Copy that script's shape rather than re-deriving it — it handles API-key auth, finding the database id, and updating a question that already exists instead of creating a duplicate.

The division of labour: the platform owns the service, the grants and the connection; **your repo owns your questions.**

## Verify

```bash
# The role can read your tables and cannot write them (run on r730xd):
ssh r730xd "docker exec foundation-postgres psql -U postgres -tAd your_app -c \
  \"SELECT count(*) FROM pg_tables t WHERE t.schemaname='public'
      AND NOT has_table_privilege('metabase_ro',
          quote_ident(t.schemaname)||'.'||quote_ident(t.tablename),'SELECT')\""   # expect 0

# The connection exists and has synced (from your workstation):
kubectl -n metabase port-forward svc/metabase 3456:80 &
curl -sH "X-API-Key: $MB_API_KEY" localhost:3456/api/database | jq '.data[].name'
```

Then open the database in Metabase and confirm your tables are listed. If they aren't, it is a grant, not a bug — see the failure modes in [runbooks/metabase.md](../runbooks/metabase.md).

## See also

- [postgres.md](postgres.md) — how your app got its database and role in the first place.
- [clickhouse.md](clickhouse.md) — the analytical store, if your data is column-shaped rather than relational.
- [secrets.md](secrets.md) — how credentials reach a namespace.
- [ADR-065](../decisions/065-metabase-analytics-service.md) — why read-only roles, and what was rejected.
