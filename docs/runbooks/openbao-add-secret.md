# Adding Secrets to OpenBao (from the control node)

**TL;DR for operators and automation (incl. Claude Code):** the control node (`bear-desktop`) holds a **persistent root OpenBao session**. You can write secrets to OpenBao directly from here — no SSH to the r730xd, no interactive `bao login`, and no reason to ask the user to do it. Just set two env vars and run `bao kv put`.

## The session

- **Token:** a root token lives at `~/.vault-token` (the default token-helper path; the `bao` CLI reads it automatically). Policies: `root`.
- **CA cert:** `~/.config/openbao/ca.crt` (self-signed platform PKI — the server presents a cert this CA signs).
- **Address:** `https://10.0.0.200:8200` (LAN-only; the control node is on the flat `10.0.0.0/24`).

The two things the CLI needs that are **not** auto-detected are the address and the CA path. Export them once per shell:

```
export BAO_ADDR="https://10.0.0.200:8200"
export BAO_CACERT="$HOME/.config/openbao/ca.crt"
```

Verify the session is live before writing:

```
bao token lookup            # should show policies [root], no error
```

If that errors (`permission denied` / connection), the session has expired or the LAN is unreachable — then, and only then, ask the operator to re-authenticate. Do not fall back to asking the user to add the key manually; adding keys is self-service from here.

## Writing a secret

Path convention (KV v2, mount `secret/`): `grizzly-platform/<domain>/<name>` — domains `platform/`, `stores/`, `observability/`, `cicd/`, `flux/`. See the path-layout table in [openbao-quickref.md](openbao-quickref.md).

```
bao kv put secret/grizzly-platform/<domain>/<name> key1=value1 key2=value2
```

Generate values inline so they never land in shell history or terminal output, then read back **only the key names** to confirm:

```
bao kv put secret/grizzly-platform/stores/<app> \
  db_password="$(openssl rand -base64 36 | tr -d '\n')" \
  s3_access_key="<app>" \
  s3_secret_key="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c40)" >/dev/null

bao kv get -format=json secret/grizzly-platform/stores/<app> \
  | python3 -c "import json,sys; print(sorted(json.load(sys.stdin)['data']['data']))"
```

### Hygiene

- **Never echo secret values** to the terminal (they get captured in transcripts/logs). Pipe `put` to `>/dev/null`; confirm with key-name readback, not `bao kv get` of the value.
- **Postgres role passwords: no single quotes.** The `setup-<app>-stores.yml` playbooks pass the password through a psql `:'pw'` literal; a raw single quote breaks it. `openssl rand -base64` is safe (its alphabet is `A–Z a–z 0–9 + / =`).
- **Editing an existing secret replaces the whole version.** `bao kv put` writes a new version with exactly the keys you pass — include every key you want to keep, or use `bao kv patch` to change one.
- This is a **public repo** — the value lives only in OpenBao; never paste it into git, an ADR, or a manifest.

## After writing: wire it into IaC

A secret in OpenBao does nothing until a consumer reads it. Per [openbao-quickref.md → Adding a new platform secret](openbao-quickref.md):

1. **Ansible consumer:** add a `vault_kv2_get` lookup for each key to `ansible/vars/openbao_secrets.yml` (redefines `vault_*`).
2. **K8s consumer:** add an `ExternalSecret` (ClusterSecretStore `openbao`) in `kubernetes/infrastructure/external-secrets-stores/` (repo convention: ExternalSecrets live there, not next to the workload) and register it in that `kustomization.yaml`.
3. **Platform-level record:** add a row to the path-layout table in the quickref, and to the `migration_set` in `ansible/playbooks/migrate-platform-secrets-to-openbao.yml`.

## Why not SSH to the r730xd

The r730xd runs the OpenBao server and can be driven locally with `bao ... -address=https://127.0.0.1:8200 -ca-cert=/etc/openbao/tls/ca.crt`, but that box authenticates as the **machine identity** (Infisical universal-auth), not as an operator. The control node's root session is the operator path and is what these runbooks assume for interactive writes.
