# Platform Secrets → OpenBao Migration

Operator guide for executing the Phase A–E migration planned in
`docs/decisions/024-platform-secrets-on-openbao.md`. Use this in
conjunction with the OpenBao quickref (`openbao-quickref.md`) and the
disaster-recovery runbook.

## Prerequisites

- OpenBao is deployed, initialized, unsealed, and reachable at
  `https://10.0.0.200:8200` from the controller.
- `infisical` CLI on the controller is logged in with project
  access (or `INFISICAL_TOKEN` exported).
- `.vault_pass` exists at the repo root.
- `kubectl`, `bao`, `ansible-playbook`, `jq`, `python3`, and
  `ansible-galaxy` are on PATH on the controller.

## Phase A — OpenBao platform readiness

```
ansible-galaxy collection install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory \
  ansible/playbooks/deploy-openbao.yml --vault-password-file .vault_pass
ansible-playbook -i ansible/inventory \
  ansible/playbooks/bootstrap-openbao.yml --vault-password-file .vault_pass
scripts/set-openbao-approle-secrets.sh
ansible-playbook ansible/playbooks/setup-openbao-k8s-auth.yml \
  --vault-password-file .vault_pass
```

### Verify

```
ssh r730xd 'sudo bao audit list'                        # shows file/ device
ssh r730xd 'sudo tail -n1 /mnt/zfs/foundation/openbao/audit/audit.log'
ssh r730xd 'sudo bao auth list | grep -E "approle|kubernetes"'
ssh r730xd 'sudo bao policy list | grep -E "platform|eso"'
```

If any of those are missing, STOP. Do not proceed until the prereq
state is complete — downstream phases assume it.

## Phase B — Seed platform secrets into OpenBao

```
ansible-playbook ansible/playbooks/migrate-platform-secrets-to-openbao.yml \
  --vault-password-file .vault_pass
```

Tagged per domain for phased rollouts: `--tags stores`, `--tags cicd`,
etc. The playbook ends with a read-back verify step that compares
OpenBao's stored values against the vault.yml source; drift fails the
run.

### Verify

```
bao kv list secret/grizzly-platform            # shows: platform/ stores/ observability/ cicd/ flux/
bao kv list secret/grizzly-platform/stores     # shows: postgres kv-cache s3-hot s3-bulk
bao kv get secret/grizzly-platform/stores/postgres   # should return the current password
```

## Phase C — Ansible consumer flip

Per-playbook, starting with the lowest-risk one. Set
`openbao_read_enabled: true` in a per-play vars override or via
`--extra-vars`:

```
ansible-playbook -i ansible/inventory \
  ansible/playbooks/deploy-foundation-stores.yml \
  --vault-password-file .vault_pass -e openbao_read_enabled=true
```

Verify the role completed without error, connect to each store, and
confirm credentials work:

```
psql -h 10.0.0.200 -U postgres               # password from OpenBao
valkey-cli -h 10.0.0.200 -a "$(bao kv get -field=password secret/grizzly-platform/stores/kv-cache)" ping
mc alias set hot http://10.0.0.200:7070 \
  "$(bao kv get -field=root_access_key secret/grizzly-platform/stores/s3-hot)" \
  "$(bao kv get -field=root_secret_key secret/grizzly-platform/stores/s3-hot)"
```

Once verified, proceed to the next playbook in order:
`deploy-observability.yml`, `setup-k8s-gitops.yml`,
`setup-k8s-cicd.yml`, `seed-app-secrets.yml`, `setup-proxy-vps.yml`.

When every playbook is verified, flip the global default in
`ansible/inventory/group_vars/all/vars.yml`:

```yaml
openbao_read_enabled: true
```

## Phase D — Deploy ESO + ExternalSecret manifests

```
scripts/fetch-openbao-ca.sh          # populates openbao-ca ConfigMap
git add kubernetes/infrastructure/external-secrets/openbao-ca-configmap.yaml
git commit -m "feat(eso): populate OpenBao CA for ClusterSecretStore"
git push
```

Wait for Flux to reconcile:

```
flux reconcile source git flux-system
flux get helmreleases -n flux-system external-secrets
kubectl -n external-secrets get pods    # ESO pods Ready
kubectl get clustersecretstore openbao  # Valid=True
```

Smoke-test a throwaway ExternalSecret before touching critical paths:

```
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: smoke-test, namespace: default }
spec:
  refreshInterval: 1m
  secretStoreRef: { kind: ClusterSecretStore, name: openbao }
  target: { name: smoke-test, creationPolicy: Owner }
  data:
    - secretKey: v
      remoteRef: { key: grizzly-platform/flux/discord-webhook, property: url }
EOF
kubectl get externalsecret smoke-test -w   # SecretSynced within ~30s
kubectl delete externalsecret smoke-test
kubectl delete secret smoke-test
```

Only then let Flux pick up the production ExternalSecret manifests:

```
flux reconcile kustomization flux-system --with-source
kubectl get externalsecret -A              # all SecretSynced
```

Critical check — Flux's own GitRepository auth Secret:

```
kubectl -n flux-system get secret github-app-credentials -o \
  jsonpath='{.metadata.managedFields[*].manager}'
# should include "external-secrets"
flux reconcile source git flux-system      # still succeeds after ESO takes over
```

## Phase E — Retire imperative seeding + shrink vault.yml

Once all ExternalSecrets are Ready and stable for at least 24h:

1. Remove the matching tag-blocks from
   `ansible/playbooks/seed-app-secrets.yml` (keeping `app-repo-flux`
   which pushes to GitHub, not K8s).
2. Remove Play 4 of `ansible/playbooks/setup-k8s-gitops.yml`.
3. Shrink `ansible/inventory/group_vars/all/vault.yml` — remove the
   19 migrated `vault_*` entries. Keep:
   - `vault_infisical_openbao_*` (bootstrap)
   - `vault_openbao_approle_*` (Ansible access)
   - `vault_wg_*_private_key` (not migrated)
   - `vault_gemini_api_key`, `vault_cerebras_api_key`,
     `vault_postgresql_*_user_password` (app-level, out of scope)
4. Regenerate `vault.yml.example` from the shrunken `vault.yml`.
5. Delete `ansible/group_vars/all/` (stale duplicate; see the plan).
6. Commit + push.

## Rollback

See `ansible/playbooks/rollback-openbao-migration.yml`. Short form:

```
ansible-playbook ansible/playbooks/rollback-openbao-migration.yml \
  --vault-password-file .vault_pass
```

This flips `openbao_read_enabled=false`, scales ESO to 0, re-seeds
K8s Secrets from vault.yml. `vault.yml` must still contain the
migrated entries — do NOT run Phase E step 3 until you're confident
rollback won't be needed.

## Troubleshooting

- **Ansible play fails with `vault_openbao_approle_role_id is
  undefined`**: `scripts/set-openbao-approle-secrets.sh` hasn't run
  yet. Run it, then retry.
- **ESO pod logs `x509: certificate signed by unknown authority`**:
  the openbao-ca ConfigMap still has the placeholder or a stale CA.
  Re-run `scripts/fetch-openbao-ca.sh`, commit, push.
- **ExternalSecret stuck `SecretSyncedError` with "permission
  denied"**: the K8s auth role `external-secrets` isn't bound to
  `eso-platform-read`. Re-run `setup-openbao-k8s-auth.yml`.
- **Flux GitRepository goes `Failed` during D**: the
  github-app-credentials Secret has wrong keys. Compare
  `kubectl get secret github-app-credentials -n flux-system -o yaml`
  against the pre-migration state; if ESO has pruned keys Flux needs,
  fix the ExternalSecret spec and reconcile.
- **`bao audit list` empty after deploy-openbao.yml**: the audit
  block signature in `openbao.hcl.j2` was rejected. Check
  `docker logs foundation-openbao --tail 100` for the HCL parse error.
