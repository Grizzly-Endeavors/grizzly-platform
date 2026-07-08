# ADR-059: App self-service provisioning via an aggregate `App` CR and additive-only controllers

**Date:** 2026-07-07
**Status:** Proposed — architecture agreed, not yet built. Deep design and open questions live in [../exploration/app-self-service-provisioning.md](../exploration/app-self-service-provisioning.md); this ADR records the shape we've committed to *if* we build it.
**Relates to:** [ADR-020](020-app-delivery-model.md) (app delivery model — this extends it), [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-023](023-self-hosted-openbao-on-r730xd.md)/[024](024-platform-secrets-on-openbao.md) (OpenBao + ESO), [ADR-033](033-central-identity-authentik.md)/[037](037-authentik-config-as-code-blueprints.md) (Authentik + blueprints), [ADR-028](028-centralized-ci-gate.md) (the gate the controller image ships through).

## Context

ADR-020 gave each app its own repo and a `deploy/` chart, so *workload* changes are a `git push` in the app repo. But *consuming a foundation* is not self-service: getting a Postgres DB is a hand-seeded OpenBao secret plus an operator running `setup-<app>-stores.yml` against the R730xd; an S3 account is the same; an SSO client is a blueprint PR to grizzly-platform plus a redeploy of the shared Authentik worker. When several apps need foundation changes at once, the operator is the serialization point — and provisioning a database means being at a terminal, not in GitOps at all.

This is deliberately being solved for scale, not for the current eight apps: the cluster runs at ~1/10th capacity, app count is expected to grow, and the operating principle is to frontload effort into a build-once system rather than repeat manual work. The goal is that onboarding an app touches grizzly-platform zero times after a one-time pointer, and never requires the operator at a terminal.

## Decision

**Apps declare their foundation needs in their own repo via a single aggregate `App` custom resource** (`platform.grizzly.io/v1`) — one block per foundation (`postgres`, `s3`, `valkey`, `sso`). This is the entire self-service surface; there is no per-resource claim zoo.

**In-cluster provisioning controllers reconcile the `App` CR into real foundation resources** — a Postgres role+DB, a versitygw account+bucket, a Valkey ACL user, an Authentik OIDC client — and **mint each generated credential into OpenBao** at the app's `stores/<app>` path. Apps consume those creds through the *existing* ExternalSecret machinery, unchanged. The controllers do what the operator does by hand today; they replace the operator as the reconciler.

**The controllers are additive-only: they can create, never read existing state, never delete.** This is the load-bearing invariant. It keeps the operator the gatekeeper for the two directions that matter — who can *see* existing state (read) and what gets *torn down* (delete) — while removing the operator from the create loop entirely. Where a foundation can honor this natively it does (OpenBao `create`/`update`-only policy; Authentik RBAC `add_*`-only token; Valkey `+acl|setuser` without `deluser`/reads; Postgres `CREATEROLE`+`CREATEDB` non-superuser that revokes its own admin over each role it creates). Where it cannot — versitygw admin is all-or-nothing root — the root cred lives behind a **minimal create-only broker** the controller calls, never in the controller itself.

**Creates are template-constrained.** The `App` CR exposes no privilege knobs; each controller only ever mints one narrow, fixed tenant shape (a role owning exactly one DB; an account scoped to one bucket; an OIDC client with a fixed flow and only the requested redirect URIs). This closes the one sharp edge of "create-only" — that a compromised controller could otherwise mint itself a new *privileged* principal and walk in the front door.

**Controllers are split per foundation, not one god-controller,** so a compromise is contained to a single store rather than the whole platform. **Removing an `App` CR orphans-and-alerts, never cascade-deletes** — teardown stays a separate, human-gated path.

grizzly-platform becomes the home of this control plane (CRDs + controllers); app repos consume it and never edit it.

## Alternatives Considered

- **Status quo (operator runs Ansible / blueprint PRs).** Rejected as the target: it's the serialization point this is meant to remove, and storage provisioning isn't even in GitOps.
- **Declarative-but-operator-gated** (app PRs a claim, operator approves-and-applies). A smaller change, but still puts the operator in the create loop on every app — the opposite of the frontload-once goal.
- **Crossplane / off-the-shelf composition.** `provider-sql` + `provider-vault` cover Postgres and OpenBao, but versitygw and Authentik have no provider, so those actuators are bespoke regardless. Running Crossplane *just* for Postgres while hand-writing the other half is more surface, not less. Bespoke controllers fit the platform's legibility and are the lighter option here. (`kro`-style composition can sit on top later; it doesn't remove the bespoke actuator work.)
- **One aggregate controller holding all four foundation admin creds.** Rejected: single point of total-platform compromise. Per-foundation split bounds the blast radius.
- **Read-then-create for idempotency.** Rejected: it breaks the no-read invariant. Idempotency is done by attempting the create and catching "already exists" instead.

## Consequences

- **Onboarding after this: repo + `deploy/` chart + one `App` CR + the one-time Flux pointer, then `git push`.** No grizzly-platform PR per app, no operator at a terminal. This is the payoff.
- **The controllers are a new, always-on concentration of the platform's most dangerous creds, fed by semi-trusted input** (the `App` CR is authored in app repos). The additive-only invariant, template-constrained creates, per-foundation split, scoped OpenBao AppRoles, NetworkPolicy pinning, and provision-volume alerting are what make that acceptable — see the exploration doc for the full threat model. Authentik is the asymmetric-risk foundation (identity compromise dominates any single data store) and may keep a human gate on new-client creation even in the self-service world.
- **Removed apps leave durable foundation state behind until the operator reaps it** (orphan-and-alert). Correct for the "operator owns teardown" model, but it means decommission is not automatic.
- **grizzly-platform's role shifts** from holding per-app manifests to hosting the control plane. Existing per-app Flux plumbing (source/release/namespace) is expected to collapse to a write-once pointer plus a namespace-scoped Flux ServiceAccount — the mechanical half tracked alongside this design.
- **Not committed to build.** This ADR fixes the *shape* so the threat model is on record before any code exists; the go/no-go and the remaining open questions (the delete path, credential rotation, the Authentik human-gate call, migrating the existing eight apps) live in the exploration doc.
