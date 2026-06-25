# grizzly-platform

Self-hosted infrastructure for Grizzly Endeavors projects (Infrastructure as Code). See `README.md` for architecture, machines, repo structure, and common commands. `docs/hardware.md` has the live machine inventory, `docs/network.md` the network topology, and `docs/decisions/` the architectural rationale. The completed 2026 migration record lives in `archive/migration-2026/`.

# CI Gate

**Start here:** `docs/runbooks/ci-gate.md` — bootstrap, Audit→Enforce rollout, key rotation, gate version bump, deploy-denied diagnosis.

- A versioned `grizzly-gate` container image (`docker/grizzly-gate/`) owns the per-language checks + scanners (rules live in the `config/` tree — one self-describing `manifest.toml` + native config per tool under `languages/` and `util/`; harness in Rust). The gate's config is authoritative: it is forced onto each tool and ignores the scanned repo's own config of the same kind. Apps call the reusable `.github/workflows/gate.yaml` after building; on a clean pass the gate cosign-signs the image **digest**. Kyverno (`kubernetes/infrastructure/kyverno{,-policies}/`) refuses unsigned images at admission in namespaces labelled `grizzly.io/gated=true`. Signing key in OpenBao `secret/grizzly-platform/cicd/cosign`; registry is zot (OCI referrers).
- ADRs: `docs/decisions/028-centralized-ci-gate.md`, `docs/decisions/027-registry-zot.md`. Enforcement starts in **Audit**; flip to Enforce only after live first-party images are signed.

# Secrets Management

**Start here:** `docs/runbooks/openbao-quickref.md` — addresses, file paths, policies, auth methods, path layout, rotate/add how-tos, deploy-time gotchas.
**Migration playbook:** `docs/runbooks/secrets-migration.md` — Phase A–E operator guide for moving consumers onto OpenBao.

- **OpenBao** (on R730xd, LAN-only at `https://10.0.0.200:8200`) is the platform secrets source of truth. Scripted unseal via Infisical bootstrap secrets (`openbao-auto-unseal.service`). Audit device enabled declaratively in `openbao.hcl` (file sink on the ZFS hot tier).
  - Role: `ansible/roles/r730xd-openbao/`
  - Playbooks: `deploy-openbao.yml`, `bootstrap-openbao.yml`, `rotate-openbao-keys.yml`, `setup-openbao-k8s-auth.yml`, `migrate-platform-secrets-to-openbao.yml`, `rollback-openbao-migration.yml`
  - Helpers: `scripts/set-openbao-bootstrap-secrets.sh` (Infisical creds), `scripts/set-openbao-approle-secrets.sh` (Ansible AppRole creds), `scripts/fetch-openbao-ca.sh` (CA → ConfigMap + controller trust store)
  - ADRs: `docs/decisions/023-self-hosted-openbao-on-r730xd.md`, `docs/decisions/024-platform-secrets-on-openbao.md`
  - Runbooks: `docs/runbooks/openbao-{quickref,rotation,disaster-recovery}.md`, `docs/runbooks/secrets-migration.md`
- **Ansible consumers:** `ansible/vars/openbao_secrets.yml` redefines in-scope `vault_*` as `community.hashi_vault.vault_kv2_get` lookups; opt-in per playbook via `openbao_read_enabled` (default false). Auth: AppRole `ansible-iac` bound to `ansible-platform-read` (CIDR-locked to 10.0.0.0/24).
- **Kubernetes consumers:** External Secrets Operator, deployed via Flux at `kubernetes/infrastructure/external-secrets/`. ClusterSecretStore `openbao` authenticates via K8s auth method using the `openbao-auth` ServiceAccount (TokenReview delegated). `ExternalSecret` manifests live next to the consuming HelmRelease.
- **Path layout:** `secret/grizzly-platform/<domain>/<name>` under KV v2. Domains: `platform/`, `stores/`, `observability/`, `cicd/`, `flux/`. Full layout in the quickref.
- **Ansible Vault** (`ansible/inventory/group_vars/all/vault.yml`, encrypted, decrypted via `.vault_pass`) post-migration holds only: Infisical bootstrap creds (chicken-and-egg with OpenBao unseal), OpenBao AppRole creds, WireGuard private keys (ingress-tunnel role references them directly — not migrated), and app-level secrets (out of scope for this migration).
- **Vault password file:** Must exist at repo root, git-ignored.
- **Infisical** holds ONLY the OpenBao unseal keys + root token (bootstrap store). Project ID = `workspaceId` in `.infisical.json` at repo root. Env slug = `prod`. Secrets stored as `--type=shared`. Not a general-purpose secret store here.
- Secrets must never appear in plaintext in IaC — use `no_log: true` for tasks that handle sensitive values.

# Rules

- All configuration and infrastructure MUST be conducted with IaC. Manual changes must be clearly documented.
- **Done means deployed.** Writing IaC is not the finish line — run the playbook, verify it works, then report completion. Never stop at "here's the code I wrote."
- Warnings are blockers. Resolve before considering work complete. If a warning truly cannot be resolved, document why.
- Decision records: When a non-obvious choice is made, write an ADR in `docs/decisions/` (use `/adr` skill).

# Operational Readiness Checklist

Every service, machine, or infrastructure component MUST have answers to the following before it is considered complete. If a question doesn't apply, document why.

## Observability
- **Health signal:** How do we know this is working right now? (e.g., systemd status, HTTP health endpoint, kubectl readiness probe, process check)
- **Metrics:** What should be measured? (e.g., disk usage, request latency, queue depth, CPU/memory) Where do metrics go?
- **Logs:** Where do logs live? Are they rotated? Can they be searched? (e.g., journald, file path, stdout to container runtime)

## Alerting
- **Failure detection:** How do we know when this breaks? What specifically triggers an alert? (e.g., service down, disk >90%, cert expiring, backup failed)
- **Alert destination:** Where do alerts go? (e.g., Ntfy, email, Slack, dashboard, UPS shutdown signal)
- **On-call response:** Who or what acts on the alert? Is there a runbook or is the fix obvious?

## Troubleshooting
- **First steps:** If this is down, what do you check first? (e.g., `systemctl status X`, `kubectl logs`, check upstream dependency)
- **Dependencies:** What does this depend on? What depends on this? (e.g., NFS requires R730xd network, K8s pods require NFS)
- **Common failure modes:** What's most likely to go wrong? (e.g., disk full, OOM, network unreachable, cert expired, DNS)
- **Recovery:** How do you restart or rebuild this? Is it automatic (systemd restart, K8s reschedule) or manual?

## Documentation
- **Decision record:** If a non-obvious choice was made, is there an ADR in `docs/decisions/`? (Use `/adr` skill)
- **Runbook:** For anything that requires multi-step recovery, is there a runbook?

When writing Ansible roles, scripts, or configs — if the operational story isn't addressed in the IaC itself (e.g., monitoring agent installed, health check configured, log rotation set up), flag it as a TODO or open question rather than silently skipping it.
