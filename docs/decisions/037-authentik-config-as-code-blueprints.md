# 037: Authentik config-as-code via file-based blueprints

**Date:** 2026-06-29
**Status:** accepted
**Relates to:** [ADR-033](033-central-identity-authentik.md), [ADR-024](024-platform-secrets-on-openbao.md)

## Context

ADR-033 stood up Authentik as the platform IdP but left its *internal* config (brand, flows, stages, groups, providers, applications, outposts, tokens) as click-ops, calling a declarative story "the recommended next step" that "warrants its own plan." That config is the part that actually grows — every app integration adds a provider + application — so leaving it in the UI means the IdP's behaviour lives nowhere in git, can't be reviewed, and can't be rebuilt from source.

The instance is untouched (akadmin bootstrapped, nothing configured by hand), so there is no existing UI state to reverse-engineer. This ADR records how Authentik config is brought under IaC. The question is the *delivery mechanism* for declarative config.

## Decision

**Manage Authentik internal config as file-based blueprints, delivered through the Helm chart's native `blueprints.configMaps` key.**

1. **Blueprints, the native mechanism.** Authentik's first-class config-as-code format is YAML blueprints: each entry is `{model, identifiers, attrs}`, matched by `identifiers` (idempotent upsert) and applied inside an atomic DB transaction (any failing entry rolls the whole blueprint back). The worker auto-discovers blueprint files and re-applies them on a 60-minute reconcile.
2. **Delivery via `blueprints.configMaps`.** Blueprint YAML lives as real files under `kubernetes/infrastructure/authentik/blueprints/`, turned into the `authentik-blueprints` ConfigMap by a kustomize `configMapGenerator`. The HelmRelease lists that ConfigMap under `values.blueprints.configMaps`; the chart mounts its `.yaml` keys into **server and worker** at `/blueprints/mounted/cm-<configmap-name>/` (the worker scans `/blueprints` recursively, so the subpath is irrelevant). No manual `global.volumes`/`volumeMounts` plumbing.
3. **Stable ConfigMap name (`disableNameSuffixHash: true`).** The chart references the ConfigMap by a fixed name, so the kustomize content hash is disabled. Propagation relies on kubelet projected-volume sync (~60s) plus Authentik's file-watch re-discovery — no pod restart needed on content change.
4. **Secrets via `!Env`, sourced from OpenBao.** Blueprints reference secret material with the `!Env VAR` tag, where `VAR` is injected into server+worker through the existing `global.env` block (ESO-synced `authentik-secrets`, ADR-024). Whole secret-bearing blueprint *files* can alternatively go through the chart's `blueprints.secrets`. The baseline ships **no** secret-bearing blueprints; this pattern is the documented path for the first app integration.
5. **Blueprints are authoritative.** Once an object is managed by a blueprint, the 60-minute reconcile reverts UI edits to its managed fields. Hand-edits to blueprint-owned objects are not durable — change the YAML.

The baseline shipped with this ADR is intentionally small and secret-free, to prove the loop end-to-end: a brand blueprint (`branding_title` on the default brand) and a groups blueprint (`grizzly-admins` superuser with akadmin folded in via `!Find`, plus `grizzly-users`).

## Alternatives Considered

- **API-driven init/apply Job.** A Job that POSTs config through the Authentik API on each reconcile. More moving parts (token, ordering, partial-failure handling) and reinvents what blueprints already do atomically. Rejected.
- **`terraform-provider-authentik`.** Real drift detection and a typed resource model, but introduces Terraform as a second control plane for one service in an otherwise Flux/GitOps repo, with its own state backend. Disproportionate for now; blueprints keep config in the same Git→Flux path as everything else.
- **Hand-plumbed `global.volumes` + `volumeMounts`.** Works, but the chart's `blueprints.configMaps` is the supported, less error-prone path that already targets `/blueprints/custom/` on both deployments. No reason to hand-roll it.

## Consequences

- All future Authentik config (app providers, applications, outposts, machine tokens, flow/stage tweaks) is added as reviewed YAML under `blueprints/`, not clicked into the UI. App integrations become PRs.
- **Drift is reconciled, not alerted.** A failed blueprint rolls back atomically and surfaces only as a worker-log error and a failed instance on the Admin UI Blueprints page — there is no dedicated alert yet. Adding a blueprint-failure alert is an open follow-up.
- **No secret in git** by construction (`!Env`/`blueprints.secrets`), preserving the ADR-024 invariant that secrets live only in OpenBao.
- The first secret-bearing blueprint (e.g. a break-glass admin user, or an OIDC provider client secret) must verify the `!Env` injection path and that the relevant model accepts the field — folded into that follow-up rather than the baseline.
