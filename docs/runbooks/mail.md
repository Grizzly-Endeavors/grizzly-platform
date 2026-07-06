# Mail (Stalwart) — Deployment Status & Runbook

**Status as of 2026-07-06: functionally configured; own-MX inbound path live end-to-end.** Stalwart is configured (S3 blob store, TLS, domain, mailbox, listeners) and reachable from the internet on 25/465/587/993 via the VPS HAProxy → WireGuard tunnel path, terminating TLS with a Let's Encrypt **prod** cert. **Remaining: Phase 5** — DNS MX cutover + SMTP2GO outbound smarthost + SPF/DKIM-DNS/DMARC/MTA-STS (gated on SMTP2GO signup). Design rationale: ADRs [050](../decisions/050-stalwart-mail-server.md) (Stalwart), [051](../decisions/051-haproxy-l4-mail-ingress.md) (HAProxy L4 ingress), [052](../decisions/052-in-cluster-acme-cert-for-mail.md) (in-cluster ACME cert), [054](../decisions/054-cloudflare-email-routing-interim-inbound.md) (interim inbound).

## Architecture

Self-hosted [Stalwart](https://stalw.art) mail server, in-cluster via Flux, state on the foundation stores (Postgres + MinIO obs). Outbound will relay through **SMTP2GO** (Phase 5). Inbound is our own MX: internet → Hetzner VPS → **HAProxy (TCP, PROXY protocol v2)** → WireGuard tunnel → R730xd DNAT → K8s NodePort → Stalwart, with TLS terminated by Stalwart. HTTP surface (JMAP/webadmin/autoconfig/MTA-STS) rides the existing Caddy path as `mail.grizzly-endeavors.com`.

## Stalwart 0.16 config model (important)

Stalwart 0.16 uses a **JSON, database-backed** config. The static file (`config.json`) is **only the data-store object**; everything else (blob store, listeners, TLS, domain, accounts, DKIM, security) lives in Postgres and is applied via the **first-party CLI** (`ghcr.io/stalwartlabs/cli`) — a kubectl-style, schema-driven tool (`apply`/`get`/`query`/`update`/`describe`/`snapshot`).

## What is deployed and working

### Manifests + secrets (Flux)
- `kubernetes/infrastructure/stalwart/` applied by its own Flux Kustomization `kubernetes/clusters/grizzly-platform/stalwart.yaml` (deliberately not in `infrastructure`). Image `stalwartlabs/stalwart:v0.16.11`, 1/1 Running.
- **Data store:** foundation Postgres `10.0.0.200:5432` db/user `stalwart`. `config.json` = the PostgreSql data-store object; auth via `authSecret` → env `POSTGRES_PASSWORD`.
- **Secrets:** `ExternalSecret/stalwart-secrets` templates pod env from OpenBao: `POSTGRES_PASSWORD`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, **`STALWART_RECOVERY_ADMIN`** (`admin:<admin_password>`, the deterministic CLI admin — `user:pass`, built in the ExternalSecret `target.template`), **`ACCOUNT_PASSWORD`** (bootstrap mailbox).
- **TLS:** cert-manager `Certificate/stalwart-tls` for `mail.grizzly-endeavors.com` on **letsencrypt-prod** (DNS-01, dedicated CF token `platform/cloudflare-certmanager`). Mounted at `/etc/stalwart/tls/{tls.crt,tls.key}`; Stalwart references them via a `Certificate` object with `File` refs and serves it as `SystemSettings.defaultCertificateId`.

### CLI-applied config (`configure-stalwart.yml` + `plan.json`)
- **Blob store** → MinIO obs S3 (`http://10.0.0.200:9000`, bucket `stalwart`; `secretKey` via typed `EnvironmentVariable` object, `accessKey` = the `stalwart` username). Verified: inbound mail lands a blob in the bucket.
- **Listeners** smtp 25 / submissions 465 / submission 587 / imaps 993 / http 8080 — the four mail listeners carry `overrideProxyTrustedNetworks: 10.0.0.0/8` so they parse HAProxy's PROXY v2 header.
- **Domain** `grizzly-endeavors.com` (DKIM management = Automatic — keys generated/rotated by the server; DNS record is Phase 5).
- **Bootstrap mailbox** `bearflinn@grizzly-endeavors.com` (password from OpenBao `platform/stalwart account_password`). **TEMPORARY** — accounts move to an Authentik-backed directory later.
- **Ban allowlist** `AllowedIp 10.0.0.0/8` — see "the ingress-ban trap" gotcha.
- **Logging** a `Stdout` tracer at info (container-runtime logs); the default file tracer is disabled.

### Inbound L4 ingress (Phase 4 — ADR-051)
- **VPS:** `ansible/roles/haproxy-mail/` (via `setup-proxy-vps.yml`, tag `haproxy-mail`) runs HAProxy in TCP mode fronting 25/465/587/993, forwarding to `wg_r730xd_ip:<nodeport>` over the tunnel with `send-proxy-v2`. UFW opens the four ports (`ufw_mail_rules`). TLS is passed through, not terminated on the VPS.
- **Tunnel/DNAT:** `setup-r730xd.yml` `ingress_dnat_rules` gained the 4 mail NodePorts (30025/30465/30587/30993 → dell_inspiron), re-DNAT'd to the K8s node.
- Verified: `openssl s_client -connect 178.156.217.91:993` presents the prod cert; SMTP EHLO through HAProxy logs the real client IP (PROXY parsed).

## What is NOT done yet — Phase 5 (SMTP2GO-gated)

Disable Cloudflare Email Routing; MX → VPS (grey `mail` A → 178.156.217.91); SPF → `include:spf.smtp2go.com`; SMTP2GO DKIM CNAMEs + return-path (or publish Stalwart's own auto-generated DKIM record); DMARC; MTA-STS; autoconfig. Wire SMTP2GO as the outbound smarthost via the CLI (an `MtaRoute`/outbound-strategy object).

### ⚠ SMTP2GO signup blocker — do the inbound MX cutover FIRST (2026-07-06)

SMTP2GO's signup form validates the account email in real time and **cannot be completed yet**. Two confirmed failures:

- **Free/consumer addresses are rejected outright:** signing up with `bearflinn@gmail.com` returns **"Error code 6 — Please use an email at your own domain to sign up."** So a domain address is mandatory; the "just use Gmail" workaround does not exist here.
- **`bearflinn@grizzly-endeavors.com` returns "Error code 6 — Service unavailable."** SMTP2GO does a live MX/SMTP probe of the address, and the **interim Cloudflare Email Routing MX** (`route1/2/3.mx.cloudflare.net`, forwarding to Gmail) does not satisfy it — it defers/rejects the probe rather than returning a clean `250` for `RCPT TO`.

**Implication — the original Phase-5 ordering is inverted.** You cannot set up outbound (SMTP2GO) before inbound. Sequence must be:

1. **Grey `mail` A → VPS** and **cut MX → VPS** so external mail (and SMTP2GO's probe) reaches the *real* Stalwart mailbox, which accepts `RCPT TO:<bearflinn@grizzly-endeavors.com>` with a clean `250`. (Note: greying `mail` also makes the mailbox client-reachable by hostname — see below.)
2. **Verify** a real external message to `bearflinn@grizzly-endeavors.com` lands in the Stalwart INBOX (IMAP login already works over the VPS path — auth succeeds, INBOX currently empty because MX still → Cloudflare).
3. **Then** retry SMTP2GO signup with `bearflinn@grizzly-endeavors.com` — the probe should now get a clean `250`.
4. Add `grizzly-endeavors.com` as a verified sender in SMTP2GO (DNS: SPF/DKIM/return-path), publish DMARC/MTA-STS, and wire SMTP2GO as the outbound smarthost.

Open question for the next session: whether the CF-routing probe fails because of greylisting/deferral or an outright reject, and whether a temporary direct-MX (skip CF routing) is enough to unblock signup before the full cutover. Retiring Cloudflare Email Routing (ADR-054) is part of step 1 regardless.

## Operating the CLI

The CLI authenticates as the recovery admin. From the control node:

```
ADMIN_PW=$(bao kv get -format=json secret/grizzly-platform/platform/stalwart | jq -r .data.data.admin_password)
docker run --rm -e STALWART_URL=https://mail.grizzly-endeavors.com -e STALWART_USER=admin \
  -e STALWART_PASSWORD="$ADMIN_PW" ghcr.io/stalwartlabs/cli:1.0.10 -k <describe|get|query|apply ...>
```

Re-apply the declarative config (idempotent):

```
ansible-playbook ansible/playbooks/configure-stalwart.yml --vault-password-file .vault_pass
# after editing blob-store / listener parts of plan.json, force the required restart:
ansible-playbook ansible/playbooks/configure-stalwart.yml --vault-password-file .vault_pass -e stalwart_force_restart=true
```

## Gotchas already solved (don't rediscover)

- **No `%{env:...}%` macros in 0.16.** Macros are NOT expanded anywhere (config settings *or* directory credentials — both store the literal string). Secrets use typed `{"@type":"EnvironmentVariable","variableName":"X"}` objects (blob-store `secretKey`, data-store `authSecret`); the mailbox password is injected as a literal from OpenBao by the playbook. `SecretKey`/`SecretText`/`PublicText` also support `{"@type":"File","filePath":"..."}` (used for the TLS cert) and `{"@type":"Value","secret":"..."}`.
- **Blob-store and listener changes need a POD RESTART, not `ReloadSettings`.** The S3 client and listener sockets are built at startup; `ReloadSettings` reloads other settings but not these. The playbook restarts on first config; use `-e stalwart_force_restart=true` otherwise. (TLS cert reloads DO take via `Action/ReloadTlsCertificates` once the mounted file is updated.)
- **The ingress-ban trap.** Stalwart's `Security` auto-ban bans by source IP. All HTTP/JMAP/webadmin/CLI traffic arrives from the single ingress-nginx pod IP (no real client IP on the HTTP path), so a few failed logins ban that one IP and take down the **entire** HTTP surface → 502 everywhere. Fixed with `AllowedIp 10.0.0.0/8` (internal infra is never banned). To recover if it recurs: reach the pod directly, bypassing the banned ingress — `kubectl -n stalwart port-forward pod/<pod> 18080:8080`, then `docker run --network host -e STALWART_URL=http://localhost:18080 ... query BlockedIp` and `delete BlockedIp --ids <id>`.
- **PROXY trusted-networks is per-listener** (`overrideProxyTrustedNetworks`), NOT global (`SystemSettings.proxyTrustedNetworks`) — global would make the http listener expect PROXY from ingress-nginx (which sends none) and break it.
- **Certificate cross-reference:** the CLI's in-plan `#ref` resolution is unreliable for `id<Certificate>` fields, so `SystemSettings.defaultCertificateId` is set by the playbook after querying the cert id, not in `plan.json`.
- **0.16 store `@type` values are PascalCase** (`PostgreSql`, `S3`). MinIO endpoint goes in `region` as `{"@type":"Custom","customEndpoint":"...","customRegion":"us-east-1"}`. `credentials` on an Account is an index-keyed map (`credentials/0=...`), not a JSON array.
- **cert-manager needs a non-IP-locked CF token** — the shared `platform/cloudflare` token is IP-pinned to the VPS. Dedicated `platform/cloudflare-certmanager`.
- **Binary has `cap_net_bind_service=ep`** → deployment sets `allowPrivilegeEscalation: true` + `capabilities.add: [NET_BIND_SERVICE]` (drop ALL otherwise).
- **Flux** — Stalwart must be its own Kustomization, not a member of `infrastructure`. Also: Flux reverts manual `kubectl apply` of `stalwart/` manifests within ~5m; land changes via git.

## Operational readiness

- **Health:** `kubectl -n stalwart get pods`; `https://mail.grizzly-endeavors.com` (webadmin, 302). Container logs via the stdout tracer (`kubectl -n stalwart logs deploy/stalwart`).
- **Metrics/alerting:** TODO — Prometheus scrape, MX reachability, cert expiry (cert-manager auto-renews; note the cert reload caveat below), queue depth.
- **Dependencies:** foundation Postgres + MinIO obs (R730xd), cert-manager LE issuer, the WireGuard tunnel + VPS HAProxy, SMTP2GO (outbound, Phase 5).
- **Recovery:** stateless pod (Deployment, Recreate) — reschedules freely; durable state in Postgres + MinIO obs.

## Known follow-ups

- **TLS renewal reload:** cert-manager renews the cert without restarting the pod; Stalwart needs the mounted file to sync then an `Action/ReloadTlsCertificates` (or a pod restart) to serve the new cert. Consider a reloader (restart-on-secret-change) or confirm Stalwart's periodic auto-reload before the 60-day renewal.
- **HTTP real client IP:** the HTTP path loses the client IP at the Caddy/tunnel hop, so Stalwart's per-IP ban is ineffective for HTTP (all clients share the ingress IP, now allowlisted). Real HTTP abuse protection would need PROXY protocol end-to-end on the HTTP path or rate-limiting at Caddy.
- **Authentik-backed directory:** replace the internal directory + bootstrap `bearflinn@` mailbox with Stalwart pointed at Authentik (LDAP/OIDC). Gets its own ADR.
- **Narrower PROXY trust:** `overrideProxyTrustedNetworks` is `10.0.0.0/8` (all internal); could be narrowed to the exact post-NAT peer if that exposure ever matters.

## Key facts for resuming

- OpenBao (control-node root session; see [openbao-add-secret.md](openbao-add-secret.md)): `stores/stalwart` (db_password, s3_access_key, s3_secret_key), `platform/stalwart` (admin_password, account_password), `platform/cloudflare-certmanager` (api_token).
- Foundation: Postgres `10.0.0.200:5432` db/user `stalwart`; MinIO obs S3 `http://10.0.0.200:9000` bucket `stalwart`.
- IaC: `ansible/files/stalwart/plan.json` (declarative CLI plan), `ansible/playbooks/configure-stalwart.yml` (driver), `ansible/roles/haproxy-mail/` (VPS L4 ingress).
- PRs: #102 (interim inbound + LE issuer), #103 (manifests), #104 (CF token + own Kustomization), #105 (NET_BIND_SERVICE), #106 (config path), #107 (0.16 JSON config), #109 (recovery admin), #110 (config plan + prod cert), plus the Phase-4 mail-ingress PR.
