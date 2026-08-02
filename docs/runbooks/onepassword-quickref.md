# Runbook: 1Password platform secrets

Every platform secret lives in the **`grizzly-platform`** 1Password vault. Two service account tokens read it, and nothing else does.

| Consumer | Token | Where the token lives | How it reads |
|---|---|---|---|
| External Secrets Operator | `eso-reader` | `onepassword-token` Secret in the `external-secrets` namespace, written by `ansible/playbooks/setup-1password-eso.yml` | `ClusterSecretStore/onepassword` → 22 ExternalSecrets |
| Ansible | `ansible-reader` | `vault_op_service_account_token` in the ansible-vault encrypted `ansible/inventory/group_vars/all/vault.yml` | `community.general.onepassword` lookups in `ansible/vars/onepassword_secrets.yml` |

Item naming is one item per domain, `<domain>-<name>`, field labels unchanged. **The field is part of the key**, not a separate property: `remoteRef.key: stores-postgres/password`.

## Rate limits

Two separate ceilings, and the second one is the one that bites:

- **Per token, per hour** — 1,000 reads, 100 writes.
- **Per _account_, per 24h** — 1,000 requests, **shared across every service account token**. Exhausting it with one token breaks the other.

Check current usage against either token. This call is free — it does not itself count against the quota:

```
OP_SERVICE_ACCOUNT_TOKEN="$(cat ~/.config/op-tokens/eso-reader)" op service-account ratelimit
```

ExternalSecrets use `refreshPolicy: OnChange`, so ESO does not poll. Its only recurring traffic is hourly store validation (`refreshInterval: 1h` on the store) — 24 calls/day. That is deliberate: validation is what makes the store's `Ready` condition a liveness signal for the token.

## Responding to alerts

| Alert | What it means | Do this |
|---|---|---|
| `OnePasswordTokenNearingMaxAge` | Tokens are 76+ days old and 1Password caps service account lifetime at 90 days | Re-mint both tokens — see below |
| `ClusterSecretStoreNotReady` | Store validation failed: the token is expired, revoked, or lost vault access | Re-mint. Confirm with `op service-account ratelimit` using that token |
| `ExternalSecretNotReady` | One ExternalSecret stopped syncing — almost always a bad `remoteRef.key` | `kubectl describe externalsecret -n <ns> <name>`; check the item/field exists with `op item get <item> --vault grizzly-platform` |
| `ExternalSecretsProviderErrors` | Provider is returning errors | Check quota first, then auth |
| `OnePasswordApiVolumeHigh` | ESO burned >500 calls/24h against a 1,000/day shared cap | Something is re-reading in a loop. Check for an ExternalSecret stuck in a retry cycle |

A dead token does **not** break running workloads — Secrets already materialised keep serving. It breaks the *next* rotation. That is why these are warnings, and why the alerts are the only signal you get.

## Rotating the tokens

**Minting needs a human.** A service account cannot create, rotate, or revoke another service account, and there is no admin API for this on an Individual plan. The control node has no persistent `op` user session, so start by signing in:

```
eval $(op signin)
```

1. **Mint.** Vault grants are **immutable after creation** — get the scope right the first time, and capture the token immediately because it is shown exactly once. `--expires-in` must be under 2160h (90 days).

   ```
   op service-account create eso-reader --expires-in 2159h \
     --vault grizzly-platform:read_items
   op service-account create ansible-reader --expires-in 2159h \
     --vault grizzly-platform:read_items
   ```

2. **Store them.** Tokens live outside the repo at `~/.config/op-tokens/<name>`, mode 0600 — this repo is public.

3. **Update the encrypted vault.** `vault_op_eso_service_account_token` (ESO) and `vault_op_service_account_token` (Ansible):

   ```
   ansible-vault edit ansible/inventory/group_vars/all/vault.yml \
     --vault-password-file .vault_pass
   ```

4. **Record the mint date.** Set `onepassword_tokens_minted` in `ansible/inventory/group_vars/all/vars.yml` to today. This is recorded by hand because **a token's expiry cannot be read back from it** — `op whoami`, `op account get` and `op service-account` all omit it, and the token carries no `exp` claim. The age alert is derived from this date, so a stale value means the alert lies.

5. **Apply.** This rewrites the cluster Secret, republishes the mint-date metric, and reloads the Prometheus rules:

   ```
   ansible-playbook -i ansible/inventory \
     ansible/playbooks/setup-1password-eso.yml --vault-password-file .vault_pass
   ```

6. **Verify.** The store should re-validate against the new token, and Ansible should resolve a secret:

   ```
   kubectl get clustersecretstore onepassword
   kubectl get externalsecret -A
   ```

## Adding or changing a secret

Write to 1Password, then make the change visible to the cluster. Because ExternalSecrets sync `OnChange`, **editing an item in 1Password alone will never reach the cluster** — there is no polling to pick it up. Change the ExternalSecret's spec or metadata in git and let Flux apply it, or force it by hand:

```
kubectl annotate externalsecret -n <ns> <name> force-sync="$(date +%s)" --overwrite
```

## Troubleshooting

- **ESO metrics** — `curl http://10.0.0.226:30894/metrics` (also scraped by r730xd Prometheus as job `external-secrets`).
- **Store rejected the token** — `kubectl describe clustersecretstore onepassword` carries the provider error.
- **`op` says "no active session found"** — that is the user session, not the service accounts; `eval $(op signin)`. Service account calls need `OP_SERVICE_ACCOUNT_TOKEN` set instead and never use the session.
- **Lookup returns a value with a trailing newline** — the Ansible lookup appends one. `ansible/vars/onepassword_secrets.yml` pipes every lookup through `| trim` for this reason; keep new entries consistent.
