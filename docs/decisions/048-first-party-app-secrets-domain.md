# 048: First-party app secrets under a dedicated `apps/` domain

**Date:** 2026-07-05
**Status:** accepted
**Relates to:** [ADR-024](024-platform-secrets-on-openbao.md), [ADR-025](025-personal-apps-in-separate-repo.md), [ADR-020](020-app-delivery-model.md), [ADR-038](038-nextcloud-on-foundation-stores-and-sso.md), [ADR-040](040-invite-broker-cookie-bridged-enrollment.md)

## Context

career-scanner is the first **plain first-party application** to need a home for its own secrets — keys that no platform component provisions and only the app consumes (`session_secret`, `serper_api_key`, `ollama_api_key`, and the `db_username` literal carried for convenience). The existing OpenBao domains (ADR-024) don't cleanly fit:

- `stores/<app>` holds foundation grants that Ansible provisions and the app reads (`db_password`, S3 keys). Folding app-owned keys here conflates "grants the platform issues" with "secrets the app owns," muddying who writes what.
- `platform/<name>` is where the two existing first-party integrations put their secrets — but both are **identity infrastructure**: `platform/authentik` and `platform/invite` (ADR-040 is explicit: "`platform/` domain because this is identity infrastructure, not a lab app"). career-scanner is a regular application that merely *consumes* SSO; it is not identity infra, so that rationale doesn't extend to it.
- `lab-apps/<app>` (ADR-025) is for the separate personal-apps repo. career-scanner is a first-party app under `kubernetes/apps/` (ADR-020), not a lab app.

ADR-025 flagged exactly this as deferred: *"revisit once there's more than one app to see which is cleaner."* career-scanner is that second app.

## Decision

**Introduce `secret/grizzly-platform/apps/<app>` as the home for first-party application-owned secrets** — a sibling sub-domain to `platform/` and `stores/` under the existing `grizzly-platform/` prefix. career-scanner's app-only keys live at `secret/grizzly-platform/apps/career-scanner`.

### 1. Why a new sub-domain, not an overloaded existing one

The three secret groups a foundation-riding app touches have three different owners, and the path should say so:

- **Foundation grants** (`stores/career-scanner`) — Ansible provisions, app reads.
- **OIDC contract** (`platform/authentik`, two `oidc_career_scanner_*` keys) — Authentik owns client registration; both the Authentik worker and the app read the same two keys, one source of truth (the ADR-038 pattern).
- **App-only secrets** (`apps/career-scanner`) — the app owns them; nothing on the platform provisions them.

Keeping the app-only group on its own domain makes "who writes this" legible from the path alone, which is the whole point of ADR-024's single-path-layout discipline.

### 2. No policy change required

`apps/` sits **under** `grizzly-platform/`, so it is already covered by both existing read policies: `eso-platform-read` (`secret/data/grizzly-platform/*`) for K8s consumers and `ansible-platform-read` (`grizzly-platform/*`) for Ansible. This is deliberately chosen over a top-level `secret/apps/*`, which would be net-new policy surface (a new `eso-apps-read` policy, edits to `bootstrap-openbao.yml`, a re-run). The cheapest correct option wins.

### 3. Consumption

App-only keys are K8s-consumed only, via career-scanner's own `ExternalSecret` in its `deploy/` chart (ADR-020: ExternalSecrets live next to the consuming HelmRelease). They need **no** `ansible/vars/openbao_secrets.yml` lookup — that file only carries secrets an Ansible play reads (here, just the `stores/career-scanner` grants the provisioning playbook needs).

## Consequences

- The OpenBao path layout gains an `apps/` domain; the quickref path-layout table documents it. Future first-party apps with app-owned secrets follow career-scanner: `secret/grizzly-platform/apps/<app>`.
- Identity-infrastructure services (an IdP-adjacent broker like grizzly-invite) still belong under `platform/` — `apps/` is for ordinary applications, not a blanket "all first-party apps" bucket. The distinction is owner/role, not first-party-ness.
- Resolves the ADR-025 deferral. `lab-apps/` remains the home for the separate personal-apps repo; `apps/` is its first-party analogue under `grizzly-platform/`.
