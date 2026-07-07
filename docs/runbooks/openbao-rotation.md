# Runbook: OpenBao key rotation

Rotation of OpenBao seal material (unseal keys, root token) and the Infisical bootstrap machine-identity secret. Run from the jumpbox.

## Cadence

| What | Recommended | Trigger rotation immediately if… |
|---|---|---|
| Unseal keys | Quarterly | Suspected compromise of Infisical project; departure of anyone who had access to the password-manager backup. |
| Root token | After every bootstrap + Quarterly | Any time you've used the root token and don't need it again. |
| Infisical machine-identity secret | Yearly | Suspected compromise of `/etc/openbao/infisical-auth.env`; r730xd rebuild. |

## Prerequisites

```
cd ~/Projects/grizzly-platform
# Confirm your Infisical CLI can write to the project:
infisical secrets --projectId=$(jq -r .workspaceId .infisical.json) --env=prod
# If not logged in:  infisical login   (or export INFISICAL_TOKEN=...)
```

- `.vault_pass` at repo root.
- R730xd reachable; OpenBao currently unsealed (`ssh r730xd 'bao status'`).
- The rotation playbook delegates Infisical writes to localhost, so the controller's CLI needs write access — no need to forward a token to r730xd.

## Flow 1 — Rekey unseal keys

```
ansible-playbook -i ansible/inventory \
  ansible/playbooks/rotate-openbao-keys.yml \
  --tags rekey \
  --vault-password-file .vault_pass -v
```

What happens:
1. Playbook fetches the current threshold-many unseal keys from Infisical.
2. Starts a rekey operation on OpenBao, submits current keys.
3. Receives the new keys, pushes them back to Infisical (overwriting old values).
4. Seals OpenBao and triggers `openbao-auto-unseal.service` to verify the new keys actually unseal.
5. Prints a reminder to update out-of-band copies.

Verify:
```
ssh r730xd 'bao status -address=https://127.0.0.1:8200 -ca-cert=/etc/openbao/tls/ca.crt' | grep Sealed   # false
infisical secrets get OPENBAO_UNSEAL_KEY_1 \
  --projectId="$(jq -r .workspaceId .infisical.json)" \
  --env=prod --plain --silent
```

After:
- **Update your password manager** with the new 5 keys. The old keys are dead; any backup copy must be replaced.

## Flow 2 — Rotate the root token

```
ansible-playbook -i ansible/inventory \
  ansible/playbooks/rotate-openbao-keys.yml \
  --tags root-token \
  --vault-password-file .vault_pass -v
```

What happens:
1. Playbook fetches current unseal keys from Infisical (needed for `generate-root`).
2. Fetches the current root token (to revoke it at the end).
3. Runs `bao operator generate-root -init` → submits unseal shares → decodes the new root token.
4. Pushes new root token to Infisical as `OPENBAO_ROOT_TOKEN`.
5. Uses the new token to revoke the old one.

Verify:
```
# The old root token no longer works:
bao login <old-token>    # "permission denied" expected
# The new one does:
NEW=$(infisical secrets get OPENBAO_ROOT_TOKEN \
  --projectId="$(jq -r .workspaceId .infisical.json)" \
  --env=prod --plain --silent)
bao login "$NEW"
```

> Heads-up: `infisical secrets get --plain --silent` tends to include a
> trailing newline — pipe the captured token through `| tr -d '\n'` (or
> `| xargs`) before handing it to `bao`, which rejects tokens with
> "non-printable characters."

## Flow 3 — Rotate the Infisical machine-identity secret

This is the only flow that requires a manual step first, because Infisical issues the new `client_secret` — the playbook only applies it.

1. Mint a new client_secret in Infisical UI:
   - Organization → Access Control → Identities → `openbao-r730xd` → Authentication → Universal Auth → Create Client Secret. Copy the raw value.
   - Do NOT revoke the old secret yet.
2. Run the rotation:
```
ansible-playbook -i ansible/inventory \
  ansible/playbooks/rotate-openbao-keys.yml \
  --tags infisical-identity \
  --extra-vars openbao_infisical_new_client_secret="$NEW_SECRET" \
  --vault-password-file .vault_pass -v
```
3. The playbook rewrites `/etc/openbao/infisical-auth.env` and restarts `openbao-auto-unseal.service` to prove the new secret can fetch the unseal keys.
4. When the playbook completes successfully, revoke the OLD client_secret in Infisical UI.
5. Finally, update `vault_infisical_openbao_client_secret` in `group_vars/all/vault.yml`:
```
ansible-vault edit ansible/inventory/group_vars/all/vault.yml
# set vault_infisical_openbao_client_secret: <new-secret>
```
This keeps future `deploy-openbao.yml` runs from re-templating the old value.

## If rotation fails mid-flight

- **During rekey** — `bao operator rekey -cancel` to abort. The old keys remain valid. Investigate, re-run.
- **During root-token** — `bao operator generate-root -cancel` to abort. Old token still valid.
- **During infisical-identity** — the unseal unit restart is the validation step. If it fails, restore `/etc/openbao/infisical-auth.env` from the pre-change state (the playbook backs up the old value via Ansible's default template behavior — manually `systemctl restart openbao-auto-unseal` again after restoring).

## Post-rotation monitoring

Watch for alerts for the next 24 hours:
- `OpenbaoUnavailable` — something about the new keys isn't working on the unseal path.
- `OpenbaoAutoUnsealFailed` — `openbao-auto-unseal.service` hit a failure at boot or restart.

Both alerts route to Discord via Alertmanager.
