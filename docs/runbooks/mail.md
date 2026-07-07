# Mail (Stalwart) — Deployment Status & Runbook

**Status as of 2026-07-06: FULLY LIVE — own-MX inbound + SMTP2GO outbound, SPF/DKIM/DMARC passing.** Stalwart is configured (S3 blob store, TLS, domain, mailbox, listeners) and reachable from the internet on 25/465/587/993 via the VPS HAProxy → WireGuard tunnel path, terminating TLS with a Let's Encrypt **prod** cert. **Inbound:** Cloudflare Email Routing disabled, `MX 10 mail.grizzly-endeavors.com` → VPS → Stalwart authoritative; `bearflinn@`/`postmaster@`/`abuse@` (+ `bearflinn@bearflinn.com`) accept `RCPT` `250`. **Outbound (Part C, done):** all non-local mail relays through **SMTP2GO** (`MtaRoute` smarthost → `mail.smtp2go.com:587`); verified delivered to Gmail with **SPF pass (aligned), DKIM pass (aligned, `s646324`), DMARC pass**. Webmail: **Roundcube** at `webmail.grizzly-endeavors.com` behind Authentik ([ADR-058](../decisions/058-roundcube-webmail.md)). Design rationale: ADRs [050](../decisions/050-stalwart-mail-server.md) (Stalwart), [051](../decisions/051-haproxy-l4-mail-ingress.md) (HAProxy L4 ingress), [052](../decisions/052-in-cluster-acme-cert-for-mail.md) (in-cluster ACME cert), [054](../decisions/054-cloudflare-email-routing-interim-inbound.md) (interim inbound, superseded), [058](../decisions/058-roundcube-webmail.md) (webmail). Remaining hardening (optional): MTA-STS, DANE/TLSA, tighten DMARC `p=quarantine`→`reject`.

## Architecture

Self-hosted [Stalwart](https://stalw.art) mail server, in-cluster via Flux, state on the foundation stores (Postgres + s3-hot versitygw blob store, ADR-055). Outbound will relay through **SMTP2GO** (Phase 5). Inbound is our own MX: internet → Hetzner VPS → **HAProxy (TCP, PROXY protocol v2)** → WireGuard tunnel → R730xd DNAT → K8s NodePort → Stalwart, with TLS terminated by Stalwart. HTTP surface (JMAP/webadmin/autoconfig/MTA-STS) rides the existing Caddy path as `mail.grizzly-endeavors.com`.

## Stalwart 0.16 config model (important)

Stalwart 0.16 uses a **JSON, database-backed** config. The static file (`config.json`) is **only the data-store object**; everything else (blob store, listeners, TLS, domain, accounts, DKIM, security) lives in Postgres and is applied via the **first-party CLI** (`ghcr.io/stalwartlabs/cli`) — a kubectl-style, schema-driven tool (`apply`/`get`/`query`/`update`/`describe`/`snapshot`).

## What is deployed and working

### Manifests + secrets (Flux)
- `kubernetes/infrastructure/stalwart/` applied by its own Flux Kustomization `kubernetes/clusters/grizzly-platform/stalwart.yaml` (deliberately not in `infrastructure`). Image `stalwartlabs/stalwart:v0.16.11`, 1/1 Running.
- **Data store:** foundation Postgres `10.0.0.200:5432` db/user `stalwart`. `config.json` = the PostgreSql data-store object; auth via `authSecret` → env `POSTGRES_PASSWORD`.
- **Secrets:** `ExternalSecret/stalwart-secrets` templates pod env from OpenBao: `POSTGRES_PASSWORD`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`, **`STALWART_RECOVERY_ADMIN`** (`admin:<admin_password>`, the deterministic CLI admin — `user:pass`, built in the ExternalSecret `target.template`), **`ACCOUNT_PASSWORD`** (bootstrap mailbox).
- **TLS:** cert-manager `Certificate/stalwart-tls` for `mail.grizzly-endeavors.com` on **letsencrypt-prod** (DNS-01, dedicated CF token `platform/cloudflare-certmanager`). Mounted at `/etc/stalwart/tls/{tls.crt,tls.key}`; Stalwart references them via a `Certificate` object with `File` refs and serves it as `SystemSettings.defaultCertificateId`.

### CLI-applied config (`configure-stalwart.yml` + `plan.json`)
- **Blob store** → s3-hot versitygw S3 (`http://10.0.0.200:7070`, bucket `stalwart`; `secretKey` via typed `EnvironmentVariable` object, `accessKey` = the `stalwart` username). Verified: inbound mail lands a blob in the bucket.
- **Listeners** smtp 25 / submissions 465 / submission 587 / imaps 993 / http 8080 — the four mail listeners carry `overrideProxyTrustedNetworks: 10.0.0.0/8` so they parse HAProxy's PROXY v2 header.
- **Domains** `grizzly-endeavors.com` (primary; DKIM management = Automatic — keys generated/rotated by the server; DNS record is Phase 5) and `bearflinn.com` (secondary, receive-only — hosts the `bearflinn@bearflinn.com` alias; `MX 10 mail.grizzly-endeavors.com`, reuses the same host + cert). The secondary domain exists both because the address is nice to keep and to satisfy SMTP2GO's >3-day domain-age gate at signup (bearflinn.com predates grizzly-endeavors.com) — sign up with `bearflinn@bearflinn.com`, then add grizzly-endeavors.com as a sending domain.
- **Bootstrap mailbox** `bearflinn@grizzly-endeavors.com` (password from OpenBao `platform/stalwart account_password`). **TEMPORARY** — accounts move to an Authentik-backed directory later. Aliases on it: `postmaster@`/`abuse@` (grizzly-endeavors.com) and `bearflinn@bearflinn.com` (cross-domain — one inbox).
- **Ban allowlist** `AllowedIp 10.0.0.0/8` — see "the ingress-ban trap" gotcha.
- **Logging** a `Stdout` tracer at info (container-runtime logs); the default file tracer is disabled.

### Inbound L4 ingress (Phase 4 — ADR-051)
- **VPS:** `ansible/roles/haproxy-mail/` (via `setup-proxy-vps.yml`, tag `haproxy-mail`) runs HAProxy in TCP mode fronting 25/465/587/993, forwarding to `wg_r730xd_ip:<nodeport>` over the tunnel with `send-proxy-v2`. UFW opens the four ports (`ufw_mail_rules`). TLS is passed through, not terminated on the VPS.
- **Tunnel/DNAT:** `setup-r730xd.yml` `ingress_dnat_rules` gained the 4 mail NodePorts (30025/30465/30587/30993 → dell_inspiron), re-DNAT'd to the K8s node.
- Verified: `openssl s_client -connect 178.156.217.91:993` presents the prod cert; SMTP EHLO through HAProxy logs the real client IP (PROXY parsed).

## Phase 5 Part A — inbound MX cutover ✅ DONE (2026-07-06)

The interim Cloudflare Email Routing inbound (ADR-054) was retired and MX cut to our own Stalwart. **DNS is hand-managed via the cloudflare-api MCP** (zone `e748f8927854bbf3e8d6a91a345d1842`); there is no DNS-as-code. What changed:

- **`mail.grizzly-endeavors.com` A → `178.156.217.91` (grey / DNS-only).** SMTP can't ride the Cloudflare proxy, so this host must be grey. It overrides the orange `*` wildcard for this name. The HTTPS webadmin surface still works — the VPS Caddy `*.grizzly-endeavors.com` wildcard vhost terminates 443 directly (grey just drops CF's proxy out of the path; verified 302 + valid cert).
- **Cloudflare Email Routing disabled** (`POST /zones/{zone}/email/routing/disable`). This auto-removed all 3 `route{1,2,3}.mx.cloudflare.net` MX records **and** the CF SPF TXT.
- **`grizzly-endeavors.com MX 10 mail.grizzly-endeavors.com`** created — inbound now routes internet → CF DNS → VPS `:25` (HAProxy L4) → tunnel → Stalwart.
- **Interim SPF `v=spf1 -all`** (domain sends no mail yet — anti-spoofing). Part C flips it to `v=spf1 include:spf.smtp2go.com ~all`.
- **`postmaster@` + `abuse@` aliases** added to the `bearflinn` mailbox (RFC 5321 requires postmaster). Codified in `configure-stalwart.yml` (EmailAlias = `{name: <local-part>, domainId}`, an index-keyed map like `credentials`).
- The interim CF DKIM `cf2024-1._domainkey` TXT is left in place (harmless, nothing signs with it now); retire in Part C.

**Verified end-to-end:** a real external message from `bearflinn@gmail.com` landed in the Stalwart INBOX (IMAPS to `mail.grizzly-endeavors.com:993`); `RCPT TO` returns `250` for `bearflinn@`/`postmaster@`/`abuse@`. Home ISP blocks outbound 25, so SMTP `RCPT` probes must run from the VPS (`ssh proxy-vps`), not the control node.

## Phase 5 Part B — SMTP2GO signup (human gate) — ✅ DONE (2026-07-06)

**The blocker was domain age.** `grizzly-endeavors.com` was registered **2026-07-05 19:32 UTC** and **SMTP2GO requires the signup domain >3 days old** — so a 2026-07-06 retry failed. **Fix: signed up with `bearflinn@bearflinn.com`** (bearflinn.com is years old → passes the gate; a domain *alias* qualifies — free/consumer addresses are rejected). Then added `grizzly-endeavors.com` as a sending domain in SMTP2GO, which auto-added the DKIM/return-path/tracking CNAMEs to the zone. The activation email landed in **Junk Mail** (spam filter; see Webmail section). SMTP2GO SMTP creds now in OpenBao `stores/smtp2go`.

## Phase 5 Part C — outbound smarthost + sender auth — ✅ DONE (2026-07-06)

Outbound relays through SMTP2GO and passes sender auth. What was done:

- **Smarthost:** `MtaRoute/Relay` `smtp2go` → `mail.smtp2go.com:587` (STARTTLS), `authUsername` from OpenBao `stores/smtp2go` (injected by `configure-stalwart.yml`), `authSecret` = pod env `SMTP2GO_PASSWORD` (from `stalwart-secrets` ExternalSecret ← `stores/smtp2go`). `MtaOutboundStrategy.route` now sends all non-local mail via `'smtp2go'` (was `'mx'`). Home ISP blocks :25, so direct MX was never an option; cluster egress to SMTP2GO on 587/2525/465/8025 is open.
- **DNS:** SPF flipped to `v=spf1 include:spf.smtp2go.com ~all`; SMTP2GO's DKIM (`s646324._domainkey` CNAME → `dkim.smtp2go.net`) + return-path (`em646324` CNAME) already present; DMARC added: `_dmarc` TXT `v=DMARC1; p=quarantine; rua=mailto:postmaster@grizzly-endeavors.com; ruf=...; adkim=r; aspf=r; fo=1`. (No stale CF DKIM remained to retire — Email Routing removed it in Part A.)
- **DKIM ownership = SMTP2GO only.** Stalwart's own domains were set to `dkimManagement: Manual` and their auto-generated `DkimSignature` objects deleted, so Stalwart no longer double-signs with unpublished, auto-rotating keys (those showed as `dkim=permerror` at Gmail). SMTP2GO signs with the aligned, CNAME-managed `s646324` selector — stable, no rotation burden. Encoded in `plan.json` (Domain `dkimManagement` Manual).
- **Verified:** real send `bearflinn@grizzly-endeavors.com` → `bearflinn@gmail.com` delivered via `mail.smtp2go.com` (`250 OK`); Gmail `Authentication-Results`: **spf=pass** (mailfrom `em646324.grizzly-endeavors.com`, aligned relaxed), **dkim=pass** (`d=grizzly-endeavors.com s=s646324`, aligned), DMARC passes on that alignment.

**Optional hardening not yet done:** MTA-STS (`mta-sts` host + `/.well-known/mta-sts.txt` policy served via Caddy + `_mta-sts` TXT + `_smtp._tls` TLSRPT), DANE/TLSA on the MX, and tightening DMARC `p=quarantine`→`reject` once aggregate reports look clean. Stalwart's `Domain` `dnsZoneFile` (from `get Domain b`) is a ready-made checklist for these.

## Webmail (Roundcube) — ADR-058

Stalwart 0.16 ships no mailbox UI (the `mail.grizzly-endeavors.com` surface is the *admin console* only), so the browser inbox is **Roundcube** at `https://webmail.grizzly-endeavors.com`, gated by **Authentik forward-auth** (grizzly-admins). IaC in `kubernetes/infrastructure/roundcube/` (own Flux Kustomization `kubernetes/clusters/grizzly-platform/roundcube.yaml`), foundation-provisioned by `ansible/playbooks/setup-roundcube-stores.yml`.

- **State:** foundation Postgres db/role `roundcube` (schema auto-created by the image's initdb on first start); no PVC. Secrets: `stores/roundcube` db_password + `platform/roundcube` des_key (24-char), via `ExternalSecret/roundcube-secrets`.
- **Mail path:** dials the **public** `mail.grizzly-endeavors.com:993` (IMAPS) / `:465` (submissions), not the in-cluster Service — the mail listeners' `overrideProxyTrustedNetworks 10.0.0.0/8` covers the pod net, so a direct in-cluster connection is treated as PROXY-protocol and reset (errno 104). The public path rides the VPS HAProxy (which adds the PROXY header) and the cert matches, so no TLS kludge. Hairpins out to the VPS and back; a PROXY-free internal listener (the "narrower PROXY trust" follow-up) would bring it back in-cluster.
- **Login:** after the Authentik gate, Roundcube does its own mailbox login — user `bearflinn@grizzly-endeavors.com`, password = OpenBao `platform/stalwart account_password`. (Full OIDC SSO / no mailbox password is deferred to the Stalwart↔Authentik directory work.)
- **Forward-auth:** blueprint `authentik/blueprints/grizzly-webmail.yaml` (proxy provider + app + grizzly-admins policy + the embedded-outpost provider list, which now owns BOTH the webmail and invite providers). Mirrors the grizzly-invite admin gate. Adding another forward-auth app = append its provider to the outpost list in that file.
- **Reading a message by hand (no UI needed):** IMAPS `mail.grizzly-endeavors.com:993`, user `bearflinn@grizzly-endeavors.com`, password from OpenBao `platform/stalwart account_password`. Note Stalwart's spam filter files some legit mail under **`Junk Mail`** (folder names have spaces → quote them in IMAP SELECT).

## Operating the CLI

**Full CLI reference: [`stalwart-cli.md`](stalwart-cli.md)** — verbs, schema model (index-keyed maps, typed secrets, singletons), recipes (accounts/aliases, reloads, auto-ban recovery, snapshot/backup), and the object catalog. Quick version below.

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
- **0.16 store `@type` values are PascalCase** (`PostgreSql`, `S3`). The S3 endpoint goes in `region` as `{"@type":"Custom","customEndpoint":"...","customRegion":"us-east-1"}`. `credentials` on an Account is an index-keyed map (`credentials/0=...`), not a JSON array.
- **cert-manager needs a non-IP-locked CF token** — the shared `platform/cloudflare` token is IP-pinned to the VPS. Dedicated `platform/cloudflare-certmanager`.
- **Binary has `cap_net_bind_service=ep`** → deployment sets `allowPrivilegeEscalation: true` + `capabilities.add: [NET_BIND_SERVICE]` (drop ALL otherwise).
- **Flux** — Stalwart must be its own Kustomization, not a member of `infrastructure`. Also: Flux reverts manual `kubectl apply` of `stalwart/` manifests within ~5m; land changes via git.

## Operational readiness

- **Health:** `kubectl -n stalwart get pods`; `https://mail.grizzly-endeavors.com` (webadmin, 302). Container logs via the stdout tracer (`kubectl -n stalwart logs deploy/stalwart`).
- **Metrics/alerting:** TODO — Prometheus scrape, MX reachability, cert expiry (cert-manager auto-renews; note the cert reload caveat below), queue depth.
- **Dependencies:** foundation Postgres + s3-hot versitygw (R730xd), cert-manager LE issuer, the WireGuard tunnel + VPS HAProxy, SMTP2GO (outbound, Phase 5).
- **Recovery:** stateless pod (Deployment, Recreate) — reschedules freely; durable state in Postgres + s3-hot versitygw.

## Known follow-ups

- **TLS renewal reload:** cert-manager renews the cert without restarting the pod; Stalwart needs the mounted file to sync then an `Action/ReloadTlsCertificates` (or a pod restart) to serve the new cert. Consider a reloader (restart-on-secret-change) or confirm Stalwart's periodic auto-reload before the 60-day renewal.
- **HTTP real client IP:** the HTTP path loses the client IP at the Caddy/tunnel hop, so Stalwart's per-IP ban is ineffective for HTTP (all clients share the ingress IP, now allowlisted). Real HTTP abuse protection would need PROXY protocol end-to-end on the HTTP path or rate-limiting at Caddy.
- **Authentik-backed directory:** replace the internal directory + bootstrap `bearflinn@` mailbox with Stalwart pointed at Authentik (LDAP/OIDC). Gets its own ADR.
- **Narrower PROXY trust:** `overrideProxyTrustedNetworks` is `10.0.0.0/8` (all internal); could be narrowed to the exact post-NAT peer if that exposure ever matters.

## Key facts for resuming

- OpenBao (control-node root session; see [openbao-add-secret.md](openbao-add-secret.md)): `stores/stalwart` (db_password, s3_access_key, s3_secret_key), `platform/stalwart` (admin_password, account_password), `platform/cloudflare-certmanager` (api_token). Part C adds `stores/smtp2go`.
- Foundation: Postgres `10.0.0.200:5432` db/user `stalwart`; s3-hot versitygw S3 `http://10.0.0.200:7070` bucket `stalwart`.
- **DNS (hand-managed via cloudflare-api MCP):**
  - `grizzly-endeavors.com` zone `e748f8927854bbf3e8d6a91a345d1842`: `mail` A `133307cf1f603655b77fbeb9a1ea151c` → 178.156.217.91 grey; MX `69dcc3b46ebe2455d4052dc8d9ce69f8` → mail; SPF TXT `f10af94070358437c817b82b3cb99a68` (`v=spf1 -all`, interim). CF DKIM `cf2024-1._domainkey` `90525406a6d7a7926cd67a249e84573c` (retire in Part C). Stalwart domain id `b`, mailbox account id `b`.
  - `bearflinn.com` zone `f782f7b2a8fd90195427dd0b0eca474c`: `MX 10 mail.grizzly-endeavors.com` id `3f6399b8d18a30854450898955a5aa9e` (receive-only for the `bearflinn@bearflinn.com` alias). No SPF/DKIM (doesn't send; sending stays on grizzly-endeavors.com). Email Routing is disabled/unconfigured.
- IaC: `ansible/files/stalwart/plan.json` (declarative CLI plan), `ansible/playbooks/configure-stalwart.yml` (driver), `ansible/roles/haproxy-mail/` (VPS L4 ingress).
- PRs: #102 (interim inbound + LE issuer), #103 (manifests), #104 (CF token + own Kustomization), #105 (NET_BIND_SERVICE), #106 (config path), #107 (0.16 JSON config), #109 (recovery admin), #110 (config plan + prod cert), plus the Phase-4 mail-ingress PR.
