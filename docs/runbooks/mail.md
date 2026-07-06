# Mail (Stalwart) — Deployment Status & Runbook

**Status as of 2026-07-06: partially deployed, in bootstrap mode.** Stalwart is running and connected to Postgres but not yet functionally configured (no listeners/blob/domain/accounts). This doc is the resume point for finishing the build. Design rationale is in ADRs [050](../decisions/050-stalwart-mail-server.md) (Stalwart), [051](../decisions/051-haproxy-l4-mail-ingress.md) (HAProxy L4 ingress), [052](../decisions/052-in-cluster-acme-cert-for-mail.md) (in-cluster ACME cert), [054](../decisions/054-cloudflare-email-routing-interim-inbound.md) (interim inbound).

## Architecture (target)

Self-hosted [Stalwart](https://stalw.art) mail server, in-cluster via Flux, state on the foundation stores (Postgres + MinIO obs). Outbound relays through **SMTP2GO** (owns IP reputation + DKIM). Inbound is our own MX: internet → Hetzner VPS → **HAProxy (TCP, PROXY protocol)** → WireGuard tunnel → NodePort → Stalwart, with TLS terminated by Stalwart. HTTP surface (JMAP/webadmin/autoconfig/MTA-STS) rides the existing Caddy path as `mail.grizzly-endeavors.com`.

## Stalwart 0.16 config model (important)

Stalwart 0.16 uses a **JSON, database-backed** config, not TOML. The static config file (`config.json`) is **only the data-store object** — everything else (blob store, listeners, TLS, domain, accounts, DKIM, relay) lives in Postgres and is set via the **first-party CLI** (`stalwartlabs/cli`, `apply` a declarative plan). This is the authentik-blueprints pattern, and in 0.16 it is mandatory, not a choice. On first boot with an empty DB, Stalwart runs in **bootstrap mode** (HTTP 8080 + a temporary admin) until setup is completed.

## What is deployed and working

- **Manifests:** `kubernetes/infrastructure/stalwart/` (namespace, externalsecret, certificate, `config.json`, deployment, service, ingress, kustomization). Applied by its **own Flux Kustomization** `kubernetes/clusters/grizzly-platform/stalwart.yaml` (dependsOn infrastructure + external-secrets-stores + cert-manager-issuers) — deliberately NOT in the `infrastructure` Kustomization (a not-ready mail pod there deadlocked core infra).
- **Image:** `stalwartlabs/stalwart:v0.16.11`. Pod `stalwart` in ns `stalwart`, 1/1 Running.
- **Data store:** foundation Postgres `10.0.0.200:5432`, db `stalwart`, user `stalwart` — connected, 27-table schema created. `config.json` = `{"@type":"PostgreSql", … authSecret via EnvironmentVariable POSTGRES_PASSWORD}`.
- **TLS:** cert-manager `Certificate/stalwart-tls` for `mail.grizzly-endeavors.com` via **letsencrypt-staging** (⚠ still staging — flip to prod before external cutover). Mounted at `/etc/stalwart/tls/{tls.crt,tls.key}`.
- **LE issuers:** `letsencrypt-staging`/`letsencrypt-prod` (cert-manager, DNS-01) using a **dedicated** Cloudflare token `secret/grizzly-platform/platform/cloudflare-certmanager` (Zone:Read+DNS:Edit, no IP lock — the shared VPS token is IP-locked, ADR-052).
- **HTTP surface:** `https://mail.grizzly-endeavors.com` is live (302, Caddy auto-routed the subdomain → tunnel → ingress-nginx → pod:8080).
- **Foundation stores provisioned:** `ansible/playbooks/setup-stalwart-stores.yml` created the PG db/role + a scoped bucket/user on MinIO obs (`10.0.0.200:9000`, bucket `stalwart`).
- **Secrets:** `ExternalSecret/stalwart-secrets` → env `POSTGRES_PASSWORD, S3_ACCESS_KEY, S3_SECRET_KEY, ADMIN_SECRET` from OpenBao `stores/stalwart` + `platform/stalwart`.
- **NodePorts allocated:** 30025/30465/30587/30993 (smtp/submissions/submission/imaps) — declared, not yet reachable externally (no HAProxy/tunnel yet).
- **Interim inbound (live):** Cloudflare Email Routing — MX→Cloudflare, `bearflinn@`/`postmaster@` → Gmail (ADR-054). Stays until the MX cutover.

## What is NOT done yet — resume here

### Next: complete the bootstrap via the CLI (Ansible)

1. **Wire a deterministic admin.** The bootstrap admin is currently a random password printed once to the pod logs (not captured). Add `STALWART_RECOVERY_ADMIN=admin:<admin_password>` env to `deployment.yaml`, sourced from `platform/stalwart` `admin_password` (the `ADMIN_SECRET` env already syncs that value — either reuse it in a constructed env or add a dedicated key). This gives the CLI stable credentials.
2. **Write `ansible/playbooks/configure-stalwart.yml`** driving `ghcr.io/stalwartlabs/cli:1.0.10` (`apply --file plan.json`), `STALWART_URL=https://mail.grizzly-endeavors.com`, admin creds from OpenBao. Author the plan against the live server (the CLI is schema-driven — use `stalwart-cli describe` / `query`). The plan configures:
   - **Blob store** — MinIO obs S3 (`endpoint http://10.0.0.200:9000`, `bucket stalwart`, keys via `EnvironmentVariable` `S3_ACCESS_KEY`/`S3_SECRET_KEY`).
   - **Storage assignments** — data=pg, blob=s3, fts=pg, lookup=pg (add foundation Redis for lookup later if wanted).
   - **Listeners** — smtp 25, submission 587, submissions 465 (implicit TLS), imaps 993 (implicit TLS), http 8080; PROXY-protocol trusted-networks (finalized in Phase 4 once the tunnel source IP is known).
   - **TLS certificate** — object referencing `/etc/stalwart/tls/tls.crt` + `tls.key`, default=true.
   - **Directory** — internal, store=pg.
   - **Default domain** `grizzly-endeavors.com`; **account** `bearflinn@grizzly-endeavors.com`; **DKIM** keys (generate).
   - Completing setup exits bootstrap mode and binds the mail listeners.
3. **Flip the cert** `certificate.yaml` issuerRef → `letsencrypt-prod`.

### Phase 4 — HAProxy L4 ingress on the VPS (ADR-051)

New Ansible role (e.g. `ansible/roles/haproxy-mail/`) + `setup-proxy-vps.yml`: HAProxy in TCP mode, PROXY protocol v2, for 25/465/587/993 → Stalwart NodePorts over the tunnel. UFW opens those ports. Add the 4 NodePorts to the WireGuard tunnel + R730xd DNAT forward set (`ansible/roles/ingress-tunnel/`; today only 30487/30356). Then set the matching PROXY trusted-networks on the Stalwart listeners.

### Phase 5 — DNS cutover + SMTP2GO (ADR-050)

Disable Cloudflare Email Routing; MX → VPS (grey `mail` A → 178.156.217.91); SPF → `include:spf.smtp2go.com`; SMTP2GO DKIM CNAMEs + return-path; DMARC; MTA-STS; autoconfig. **SMTP2GO signup** should now succeed (its verification probe hits a real mailbox, not the Cloudflare forwarder that returned "Error code 6"). Wire SMTP2GO as the outbound smarthost via the CLI plan.

## Gotchas already solved (don't rediscover)

- **0.16 config is JSON + data-store-only** (see model above). Store `@type` values are PascalCase: `PostgreSql`, `S3`, etc. Store types: `RocksDb`/`Sqlite`/`FoundationDb`/`PostgreSql`/`MySql`. SecretKey shape: `{"@type":"EnvironmentVariable","variableName":"X"}` (also `Value`→`secret`, `File`→`filePath`). PG auth fields are `authUsername` + `authSecret` (a SecretKey object), not `user`/`password`.
- **cert-manager needs a non-IP-locked CF token** — the shared `platform/cloudflare` token is pinned to the VPS IP (Cloudflare 9109). Dedicated `platform/cloudflare-certmanager`.
- **Binary has `cap_net_bind_service=ep`** → won't exec under `no_new_privs`; deployment sets `allowPrivilegeEscalation: true` + `capabilities.add: [NET_BIND_SERVICE]` (drop ALL otherwise).
- **Config path** — image default is `--config /etc/stalwart/config.json`, workdir `/var/lib/stalwart`; we render config to `/var/lib/stalwart/config.json` and pass it via `args`.
- **Flux** — Stalwart must be its own Kustomization, not a member of `infrastructure` (`wait: true`), or an unhealthy pod deadlocks the dependent Kustomizations.

## Operational readiness (to finish as it goes live)

- **Health:** `kubectl -n stalwart get pods`; `https://mail.grizzly-endeavors.com` (webadmin). Add a real health probe path once past bootstrap (currently tcpSocket:8080).
- **Metrics/logs:** logs → stdout (container runtime). Prometheus scrape + a proper metrics store are TODO.
- **Alerting:** TODO — MX reachability, cert expiry (cert-manager auto-renews), SMTP2GO relay health, queue depth.
- **Dependencies:** foundation Postgres + MinIO obs (R730xd), cert-manager LE issuer, the WireGuard tunnel + VPS HAProxy (once built), SMTP2GO (outbound only — queues if down).
- **Recovery:** stateless pod (Deployment, Recreate) — reschedules freely; durable state is in Postgres (pg_dumpall rotation) + MinIO obs (ZFS snapshots; dedicated backup TODO).

## Key facts for resuming

- OpenBao (control-node root session; see [openbao-add-secret.md](openbao-add-secret.md)): `stores/stalwart` (db_password, s3_access_key, s3_secret_key), `platform/stalwart` (admin_password), `platform/cloudflare-certmanager` (api_token).
- Foundation: Postgres `10.0.0.200:5432` db/user `stalwart`; MinIO obs S3 `http://10.0.0.200:9000` bucket `stalwart`.
- CLI: `ghcr.io/stalwartlabs/cli:1.0.10`, env `STALWART_URL` + `STALWART_USER`/`STALWART_PASSWORD` (or `STALWART_TOKEN`).
- PRs: #102 (interim inbound + LE issuer), #103 (Stalwart manifests), #104 (CF token + own Kustomization), #105 (NET_BIND_SERVICE), #106 (config path), #107 (0.16 JSON config).
