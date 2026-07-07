# Integration: secrets (OpenBao + External Secrets)

**What you get:** application credentials delivered to your workload from the platform's single secrets source of truth — as a Kubernetes `Secret` synced into your namespace (K8s apps) or as Ansible vars (IaC), without any secret material ever landing in git.

OpenBao lives on the R730xd at `https://10.0.0.200:8200` (LAN-only, no public exposure). You never talk to it directly from an app — a broker does: **External Secrets Operator (ESO)** for anything in the cluster, **AppRole** for Ansible plays. This is the one pattern the store guides ([postgres](postgres.md), [valkey](valkey.md), [s3](s3.md)) all build on, so read this first.

> This repo is public. **No secret value ever goes in git** — not in a manifest, not in a values file, not in a comment. Everything routes through OpenBao. See the [grizzly-platform-is-public](../../README.md) posture and [ADR-024](../decisions/024-platform-secrets-on-openbao.md).

## When to use it

- **Always**, for any credential, token, or key your app needs at runtime. There is no "just put it in a ConfigMap" exception.
- Use **ESO** if the consumer runs in the cluster. Use the **AppRole** path if the consumer is an Ansible play provisioning or configuring a host.

## Path layout

All platform secrets live under `secret/grizzly-platform/<domain>/<name>` (KV v2). The domains:

| Domain | For |
|---|---|
| `stores/<app>` | Foundation-store grants an app consumes — DB password, S3 keys. Provisioned by that app's `setup-<app>-stores.yml`. |
| `apps/<app>` | App-owned runtime secrets that aren't foundation grants — session keys, third-party API keys. K8s-consumed only. First consumer was career-scanner ([ADR-048](../decisions/048-first-party-app-secrets-domain.md)). |
| `platform/<name>` | Platform-level shared credentials (Cloudflare, GitHub App, Authentik). |

The authoritative path list is the table in [openbao-quickref.md](../runbooks/openbao-quickref.md#secret-path-layout) — check there before inventing a new path.

## 1 — Write the secret to OpenBao

The control node (`bear-desktop`) holds a persistent root session, so you write directly — no SSH, no interactive login:

```bash
bao kv put secret/grizzly-platform/apps/<app> \
  session_secret="$(openssl rand -base64 36)" \
  some_api_key='<value>'
```

Generate passwords **without single quotes** (`openssl rand -base64 36`) — a `'` breaks the psql `:'pw'` quoting used by the store-provisioning plays. Full hygiene: [openbao-add-secret.md](../runbooks/openbao-add-secret.md). Then add a line to the path-layout table in the quickref so the next session can find it.

## 2a — Consume in Kubernetes (ESO)

The `openbao` `ClusterSecretStore` already exists cluster-wide (ESO authenticates to OpenBao via Kubernetes auth, policy `eso-platform-read`, which grants read on `secret/data/grizzly-platform/*`). You just declare an `ExternalSecret` next to your workload that names the keys you want; ESO materializes a native `Secret` in your namespace and keeps it in sync.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-secrets
  namespace: <app>
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: <app>-secrets          # the K8s Secret ESO creates
    creationPolicy: Owner
  data:
    - secretKey: SESSION_SECRET   # key in the resulting Secret
      remoteRef:
        key: grizzly-platform/apps/<app>   # note: no `secret/` prefix, no `/data/`
        property: session_secret           # field within the OpenBao secret
```

Then consume it in your Deployment the normal way (`envFrom: [{ secretRef: { name: <app>-secrets } }]` or a `secretKeyRef`). Reference your app's chart in the app repo's `deploy/`; the `ExternalSecret` itself can live either in that chart or, for infrastructure workloads, next to the HelmRelease in this repo and registered in the directory `kustomization.yaml`.

**Need to reshape values** (e.g. build a `user:pass` string or a DSN from separate fields)? Use a `target.template` — `data` pulls the raw fields, the template composes the final env keys. The Stalwart `ExternalSecret` (`kubernetes/infrastructure/stalwart/externalsecret.yaml`) is the worked example: it builds `STALWART_RECOVERY_ADMIN: "admin:{{ .admin_password }}"` from a raw `admin_password`.

## 2b — Consume in Ansible (AppRole)

Ansible plays read `secret/grizzly-platform/*` through the `ansible-iac` AppRole (policy `ansible-platform-read`, CIDR-bound to the LAN). In a play:

```yaml
vars:
  openbao_read_enabled: true
vars_files:
  - "{{ playbook_dir }}/../vars/openbao_auth.yml"
pre_tasks:
  - name: Load OpenBao-sourced platform secrets
    ansible.builtin.include_vars:
      file: "{{ playbook_dir }}/../vars/openbao_secrets.yml"
```

Each key you consume needs a `vault_kv2_get` lookup in `ansible/vars/openbao_secrets.yml` (defines `vault_<name>`). Lookups fetch fresh on every run, so rotating a secret is just re-running the play. See [secrets-migration.md](../runbooks/secrets-migration.md) for moving an existing consumer onto this path.

## Verify

```bash
# The Secret ESO built exists and is populated:
kubectl get externalsecret <app>-secrets -n <app>          # STATUS should be SecretSynced
kubectl get secret <app>-secrets -n <app> -o jsonpath='{.data}' | jq 'keys'

# Force an immediate re-sync (don't wait out refreshInterval):
kubectl annotate externalsecret <app>-secrets -n <app> force-sync=$(date +%s) --overwrite
```

## Troubleshoot

- **`SecretSyncedError` / `permission denied`** — the path isn't under `grizzly-platform/*` (the ESO policy only grants that subtree), or you included a `secret/` or `/data/` prefix in `remoteRef.key`. The key is `grizzly-platform/<domain>/<name>` — nothing more.
- **Secret exists but is empty / a field is missing** — `property` names a field that isn't in that OpenBao secret. `bao kv get secret/grizzly-platform/<domain>/<name>` to see the real fields.
- **Stale value after rotation** — ESO refreshes every `refreshInterval` (default 1h). Force it with the `force-sync` annotation above. Ansible consumers just re-run the play.
- **Ansible can't find a var** — you added the `bao kv put` but not the `vault_kv2_get` lookup in `openbao_secrets.yml`.

## See also

- [openbao-quickref.md](../runbooks/openbao-quickref.md) — **operator** reference: addresses, policies, auth methods, path layout, rotation.
- [openbao-add-secret.md](../runbooks/openbao-add-secret.md) · [openbao-rotation.md](../runbooks/openbao-rotation.md) · [openbao-disaster-recovery.md](../runbooks/openbao-disaster-recovery.md)
- ADR [023](../decisions/023-self-hosted-openbao-on-r730xd.md) (self-hosted OpenBao), [024](../decisions/024-platform-secrets-on-openbao.md) (ESO + AppRole), [048](../decisions/048-first-party-app-secrets-domain.md) (app secrets domain).
