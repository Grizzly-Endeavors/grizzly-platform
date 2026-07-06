# OpenBao Quick Reference

First-stop pointer for "where do I find / do X with OpenBao?" Everything else lives in the linked files.

## At a glance

| | |
|---|---|
| Host | `r730xd` (`10.0.0.200`) |
| API | `https://10.0.0.200:8200` |
| CA cert | `/etc/openbao/tls/ca.crt` on r730xd (also in system trust store) |
| Version | OpenBao 2.5.x (see `ansible/roles/r730xd-openbao/defaults/main.yml`) |
| Storage | Integrated Raft at `/mnt/zfs/foundation/openbao/data` |
| Backup | Daily Raft snapshot @ 02:15 → `/mnt/zfs/foundation/openbao/backup/` |
| Seal | Shamir 5-of-3; keys live in Infisical + auto-fetched at boot |
| LAN-only | No public exposure; see ADR-019 + ADR-023 |

## File + tool locations

| Thing | Where |
|---|---|
| Role | `ansible/roles/r730xd-openbao/` |
| Deploy playbook | `ansible/playbooks/deploy-openbao.yml` |
| Bootstrap (one-time init) | `ansible/playbooks/bootstrap-openbao.yml` |
| Rotation (rekey / root / infisical-id) | `ansible/playbooks/rotate-openbao-keys.yml` |
| Vault secrets helper | `scripts/set-openbao-bootstrap-secrets.sh` |
| ADR | `docs/decisions/023-self-hosted-openbao-on-r730xd.md` |
| Rotation runbook | `docs/runbooks/openbao-rotation.md` |
| DR runbook | `docs/runbooks/openbao-disaster-recovery.md` |
| Prometheus target | `ansible/roles/r730xd-prometheus/templates/targets.d/openbao.yml.j2` |
| Prometheus alerts | `rules/grizzly-platform.yml.j2` → `openbao` group |

## Infisical bootstrap project

- **Workspace / project ID:** `.infisical.json` at repo root (`workspaceId` field). Also lives in `vars.yml` as `openbao_infisical_project_id` via a `lookup('file', $PWD + '/.infisical.json')`.
- **Environment slug:** `prod` (default `openbao_infisical_env`)
- **Secret names:**
  - `OPENBAO_UNSEAL_KEY_1` .. `OPENBAO_UNSEAL_KEY_5`
  - `OPENBAO_ROOT_TOKEN`
  - All stored as **`shared`** (not `personal`) — important, since the universal-auth machine identity on r730xd reads shared secrets.
- **Machine identity:** universal-auth; client_id + client_secret stored in Ansible vault as `vault_infisical_openbao_client_id` / `_client_secret`, templated into `/etc/openbao/infisical-auth.env` (0600 root) on r730xd.

## Admin login (from the jumpbox)

```
export VAULT_ADDR=https://10.0.0.200:8200
export VAULT_CACERT=/etc/openbao/tls/ca.crt  # copy this file over from r730xd
ROOT=$(infisical secrets get OPENBAO_ROOT_TOKEN \
  --projectId=$(jq -r .workspaceId .infisical.json) \
  --env=prod --plain --silent)
bao login "$ROOT"

# Better: mint a short-lived admin token instead of sitting on the root
bao token create -policy=grizzly-platform-admin -ttl=24h
```

## Policies bootstrapped

Applied by `bootstrap-openbao.yml`. Re-apply by re-running that playbook (idempotent).

| Policy | Scope |
|---|---|
| `grizzly-platform-admin` | Full CRUD on `secret/*`, read sys mounts/policies |
| `ansible-readonly` | Read `secret/data/grizzly-platform/*` |
| `ansible-readwrite` | Read/write `secret/data/grizzly-platform/*` |
| `prometheus-readonly` | Read `sys/metrics` only — used by the Prometheus scrape token (issue #41) |
| `ansible-platform-read` | Read `secret/data/grizzly-platform/*` — for AppRole consumers (Phase C+) |
| `eso-platform-read` | Read `secret/data/grizzly-platform/*` — for Kubernetes auth consumers (ESO, Phase D+) |

## Auth methods

| Method | Consumer | Role | Policy | Notes |
|---|---|---|---|---|
| token (root) | Bootstrap + rotation playbooks | — | root | One-off; rotated via rotate-openbao-keys.yml --tags root-token |
| approle | Ansible IaC plays | `ansible-iac` | `ansible-platform-read` | CIDR-bound to 10.0.0.0/24. role_id + secret_id in vault.yml (via scripts/set-openbao-approle-secrets.sh). Rotate with rotate-openbao-keys.yml --tags approle-secret |
| approle | Prometheus (via OpenBao Agent) | `prometheus-metrics` | `prometheus-readonly` | secret_id CIDR-bound to 10.0.0.0/24. The `r730xd-openbao-agent` container (network_mode host) auto-auths and writes a short-TTL token to `/opt/observability/openbao-agent/sink/token`, which Prometheus bind-mounts to scrape `sys/metrics`. Provision/rotate with `setup-openbao-prometheus-agent.yml` (add `-e force_remint_secret_id=true` to rotate). |
| kubernetes | External Secrets Operator | `external-secrets` | `eso-platform-read` | SA `external-secrets:external-secrets`. Reviewer-JWT from `openbao-auth:openbao-auth-token` Secret. Refresh with rotate-openbao-keys.yml --tags k8s-auth-jwt |

## Secret path layout

All platform secrets live under `secret/grizzly-platform/<domain>/<name>` (KV v2):

| Path | Keys |
|---|---|
| `secret/grizzly-platform/platform/cloudflare` | `api_token` |
| `secret/grizzly-platform/platform/idrac` | `password` |
| `secret/grizzly-platform/platform/github-app` | `app_id`, `installation_id`, `private_key` |
| `secret/grizzly-platform/platform/github-runner` | `pat` |
| `secret/grizzly-platform/platform/authentik` | `secret_key`, `db_password`, `bootstrap_password`, `bootstrap_token`, `oidc_nextcloud_client_id`, `oidc_nextcloud_client_secret`, `oidc_career_scanner_client_id`, `oidc_career_scanner_client_secret` |
| `secret/grizzly-platform/stores/postgres` | `password` |
| `secret/grizzly-platform/stores/kv-cache` | `password` |
| `secret/grizzly-platform/stores/s3-hot` | `root_access_key`, `root_secret_key` (versitygw hot gateway root creds; ADR-055) |
| `secret/grizzly-platform/stores/s3-bulk` | `root_access_key`, `root_secret_key` (versitygw bulk gateway root creds; ADR-055) |
| `secret/grizzly-platform/stores/versitygw-iam` | `role_id`, `secret_id` (shared AppRole the gateways use for their Vault-IAM account store) |
| `secret/grizzly-platform/stores/registry` | `access_key`, `secret_key` (scoped s3-bulk account owning `lab-registry`; provisioned by `setup-registry-stores.yml`) |
| `secret/grizzly-platform/stores/nextcloud` | `db_password`, `s3_access_key`, `s3_secret_key` (foundation grants for the Nextcloud lab app; provisioned by `setup-nextcloud-stores.yml`, read cross-domain by Nextcloud's ExternalSecret) |
| `secret/grizzly-platform/stores/career-scanner` | `db_password`, `s3_access_key`, `s3_secret_key` (foundation grants for the career-scanner first-party app; provisioned by `setup-career-scanner-stores.yml`, read cross-domain by career-scanner's ExternalSecret) |
| `secret/grizzly-platform/apps/career-scanner` | `session_secret`, `serper_api_key`, `ollama_api_key`, `db_username` (app-owned secrets for the career-scanner first-party app; K8s-consumed only, via its own ExternalSecret. First consumer of the `apps/` domain — see ADR-048) |
| `secret/grizzly-platform/observability/grafana` | `admin_password` |
| `secret/grizzly-platform/observability/s3-client` | `access_key`, `secret_key` |
| `secret/grizzly-platform/observability/discord-webhook` | `url` |
| `secret/grizzly-platform/cicd/sccache-s3` | `access_key`, `secret_key` |
| `secret/grizzly-platform/cicd/argo-s3` | `access_key`, `secret_key` |
| `secret/grizzly-platform/flux/discord-webhook` | `url` |

### Adding a new platform secret

> The control node (`bear-desktop`) holds a **persistent root session** — write secrets directly with `bao kv put`, no SSH or interactive login. Setup + hygiene: [openbao-add-secret.md](openbao-add-secret.md).

1. `bao kv put secret/grizzly-platform/<domain>/<name> k1=v1 k2=v2`
2. Add a Jinja lookup for each key to `ansible/vars/openbao_secrets.yml`
   (redefines `vault_*` as a `vault_kv2_get` lookup).
3. If the secret is consumed in K8s, add an `ExternalSecret` next to
   the consuming HelmRelease and register it in the directory's
   `kustomization.yaml`.
4. If the secret is platform-level, drop a line into the path-layout
   table above and the `migration_set` in
   `ansible/playbooks/migrate-platform-secrets-to-openbao.yml`.

### Rotating a platform secret

1. Update the value: `bao kv put secret/grizzly-platform/<domain>/<name> k=<new>`
2. Ansible consumers: re-run the relevant playbook — lookups fetch
   fresh on each run.
3. K8s consumers: ESO refreshes every `refreshInterval` (default 1h);
   force immediately via
   `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite`.
4. If the old value was exposed anywhere (logs, committed configs),
   also revoke the underlying credential at its source.

## Common operations

```
# Health
ssh r730xd 'systemctl is-active foundation-openbao openbao-auto-unseal'
ssh r730xd 'bao status -address=https://127.0.0.1:8200 -ca-cert=/etc/openbao/tls/ca.crt'

# Put / get a secret
bao kv put secret/grizzly-platform/foo my_key=my_value
bao kv get secret/grizzly-platform/foo

# Manual unseal (if auto-unseal failed)
ssh r730xd
bao operator unseal <key1>
bao operator unseal <key2>
bao operator unseal <key3>

# Raft snapshot on-demand
ssh r730xd 'sudo /opt/foundation/openbao/openbao-backup.sh'
```

## Gotchas learned during the 2026-04-17 deploy

Save future-you debug time — these aren't obvious from the code alone.

- **OpenBao 2.5 dropped mlock support.** Setting `disable_mlock` in HCL errors out now, and `IPC_LOCK` is not needed. Swap hardening is on the host (not in-process).
- **Container entrypoint chowns `/openbao/config` at startup.** With our read-only mount of root-owned config files, this fails. We bypass the wrapper entirely: `user: "0:0"`, `entrypoint: ["/bin/bao"]` in compose. Running as root inside the container is fine — single-tenant, host network, capability set is still tight.
- **Self-signed CA needs a CSR with `CA:TRUE`.** A bare `x509_certificate: provider=selfsigned` produces a cert with empty Subject/Issuer and no CA constraint — curl rejects with "invalid CA certificate." The role drives the CA cert through an `openssl_csr` with `basic_constraints: ['CA:TRUE']` + `key_usage: ['cRLSign', 'keyCertSign']`.
- **`bao status` exits 2 when sealed or uninitialized.** Under `set -euo pipefail`, piping through `grep` propagates the 2 and breaks `if` checks. The auto-unseal script captures the output once (`STATUS_JSON="$(bao status ... || true)"`), then inspects it without a pipe.
- **Infisical `secrets set` defaults to `--type=personal`.** Personal secrets are per-user scoped; the universal-auth machine identity on r730xd cannot read them. All playbook push calls pass `--type=shared`.
- **`secrets get` returns data with trailing whitespace.** Pipe the root token through `| trim` before passing to `bao` env vars — otherwise `bao` rejects it as "contains non-printable characters."
- **Role defaults are NOT visible to playbooks that don't apply the role.** `bootstrap-openbao.yml` and `rotate-openbao-keys.yml` load them explicitly via `vars_files`. Don't add a default like `openbao_infisical_project_id: "CHANGE_ME_..."` to role defaults if you want the vars.yml lookup to win — it won't.
- **Infisical calls `delegate_to: localhost`.** The CLI on r730xd authenticates as the machine identity; the controller (bear-desktop / jumpbox) is logged in as the operator. Run pushes/gets from the controller to use the interactive auth.
- **Audit device syntax.** OpenBao 2.5 rejects the `bao audit enable` API path in favor of declarative config. Syntax per [openbao.org/docs/configuration/audit](https://openbao.org/docs/configuration/audit/) is `audit "<type>" "<path>" { options { ... } }`. A bug in 2.5.0-beta made stanzas ignored at boot (needed SIGHUP) — fixed in PR #2170, which landed in 2.5.2 on release/2.5.x. The role ships with a single `audit "file" "main"` device writing to `/openbao/audit/audit.log`; see `openbao.hcl.j2`.
- **`openbao_infisical_project_id` uses `lookup('env', 'PWD')`.** `playbook_dir`, `inventory_dir`, and bare relative paths all failed to locate `.infisical.json` from `group_vars/`. The `$PWD` path works because every Ansible invocation is from the repo root per README/ansible.cfg conventions. If you invoke from elsewhere, override with `-e openbao_infisical_project_id=<id>`.
- **Infisical CLI on bear-desktop is pinned at 0.38.** It works for all required subcommands but shows upgrade nags; the r730xd install is whatever the apt repo serves.

## Operational readiness checklist (per CLAUDE.md)

- [x] Health: `systemctl is-active foundation-openbao openbao-auto-unseal` + `bao status | grep Sealed: false`
- [x] Metrics: `up{job="openbao"}` via `/v1/sys/health` (unauthenticated)
- [x] Logs: Docker journald + OpenBao server logs via `docker logs foundation-openbao`
- [x] **Audit log**: enabled via declarative `audit "file" "main"` block in `openbao.hcl.j2`, writing to `/mnt/zfs/foundation/openbao/audit/audit.log`. Logrotate copytruncate keeps size bounded.
- [x] Alerts: `OpenbaoUnavailable`, `OpenbaoAutoUnsealFailed`, `OpenbaoAuditLogDiskFull` (15% tier-free warning), `OpenbaoAuditLogDiskCritical` (5% tier-free critical) → Discord via Alertmanager
- [x] Runbooks: this file, `openbao-rotation.md`, `openbao-disaster-recovery.md`, `secrets-migration.md`
- [x] ADR: `023-self-hosted-openbao-on-r730xd.md`, `024-platform-secrets-on-openbao.md`
- [x] Backup: daily cron, Raft snapshot to `/mnt/zfs/foundation/openbao/backup/` (14-day retention) + ZFS snapshots of the data dir
