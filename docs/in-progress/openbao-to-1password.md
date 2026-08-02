# Thread: OpenBao → 1Password for platform secrets

**Goal:** move platform secret delivery off OpenBao onto 1Password — the `onepassword` ESO `ClusterSecretStore` for Kubernetes, and `ansible/vars/onepassword_secrets.yml` lookups for Ansible.

## Done

- The `onepassword` `ClusterSecretStore` is live and is what every workload actually uses: **23 of 23 ExternalSecrets in the cluster reference it, and none reference `openbao`.**
- `ansible/vars/onepassword_secrets.yml` defines the `vault_*` variables as 1Password lookups; 22 playbooks include it.
- Operator runbook exists: [`runbooks/onepassword-quickref.md`](../runbooks/onepassword-quickref.md) (tokens, rate limits, alert response, rotation).
- Token age and store-validation alerting is in place.

## Remains

The code has moved; the **docs have not**. Known stale spots found while deploying Langfuse (2026-08-02):

- **[`integration/secrets.md`](../integration/secrets.md) is the important one** — it is the front door every other integration guide points at, and it still documents the `openbao` store end to end, including a key format that no longer works. Compare:
  - documented: `remoteRef: {key: grizzly-platform/stores/<app>, property: db_password}`
  - actual: `remoteRef: {key: stores-<app>/db_password}` — item/field, not path/property.
  A reader following it today writes an ExternalSecret that will not sync. Worth doing first.
- Root [`INDEX.md`](../../INDEX.md) "Secrets (OpenBao)" section still frames OpenBao as the source of truth for K8s, and states Infisical holds the unseal keys — both need a pass against current reality.
- Assorted inline comments still say "from OpenBao" where the value now comes from 1Password (e.g. `authentik/blueprints/career-scanner.yaml`). The equivalent comment in `authentik/helmrelease.yaml` was corrected in passing on 2026-08-02; others were left alone rather than half-migrating a doc set that is mid-move.
- Decide the end state for the `openbao` store object and the `openbao-*` runbooks — whether OpenBao stays for the Ansible/AppRole path and non-ESO consumers, or is retired outright. That decision is what the doc rewrite should be written against, so make it before the rewrite.

## Notes

New work should use 1Password (`stores-<app>` / `platform-<app>` items) — [`integration/clickhouse.md`](../integration/clickhouse.md) and `kubernetes/infrastructure/langfuse/externalsecret.yaml` are current worked examples until `secrets.md` catches up.

Authoritative once this closes: [`runbooks/onepassword-quickref.md`](../runbooks/onepassword-quickref.md) and a rewritten [`integration/secrets.md`](../integration/secrets.md). Delete this file and its `INDEX.md` line when the docs match the code.
