# ADR-020: Application Delivery via Per-Repo Flux Sources

**Date:** 2026-04-09
**Status:** Accepted

## Context

Phase 7 of the K8s cluster standup (`archive/migration-2026/k8s-cluster-standup.md`) migrates workloads from the staging VM and old cluster onto the new cluster. The question is how application manifests get from a developer's `git push` to a running pod.

The prior cluster used a CI-driven flow: actions-runner-controller runners had `helm` and a kubeconfig baked in, and on push to a production branch the runner would build the container image and run `helm upgrade` directly against the API server. Every app repo contained its own Helm chart; grizzly-platform did not know or care about application-level resources.

Flux was adopted for the new cluster in ADR-014, but the simplest reading of "GitOps" — all manifests in one repo — would require moving every application's chart into grizzly-platform and gating every deploy behind a PR to this repo. The operator deploys frequently across many repos and explicitly wants to minimize manual steps per deploy. Bundling all manifests into grizzly-platform would invert that: every push becomes two PRs (app + IaC), and the IaC repo becomes a bottleneck for work that has nothing to do with infrastructure.

grizzly-platform currently lives under a personal GitHub account. App repos live under the `grizzly-endeavors` org.

## Decision

**App repos own their own manifests.** Each application repo contains a `deploy/` directory with a Helm chart (or Kustomization) describing how the app runs on the cluster. This is where namespace logic, multi-image wiring, env-specific values, and all app-level knobs live. grizzly-platform does not contain application charts.

**grizzly-platform tracks each app as a Flux `GitRepository` + `Kustomization` pair** under `kubernetes/apps/<app>/`. A single top-level Flux Kustomization (`kubernetes/clusters/grizzly-platform/apps.yaml`) points at `./kubernetes/apps`, and `kubernetes/apps/kustomization.yaml` lists each app's folder. Adding a new app = new folder + one line in the list. That's the entire IaC change for a new app, ever.

**grizzly-platform moves to the `grizzly-endeavors` org.** This enables a single GitHub App installed org-wide — used both by Flux (read) to pull manifests from all app repos without per-repo deploy keys, and by the onboarding workflow (write on grizzly-platform) to open auto-merging PRs from any app repo's CI. Without the org move this still works via PATs, but the auth story becomes messy enough to undermine the "zero manual steps" goal.

**Onboarding is automated via a reusable workflow in grizzly-platform.** `.github/workflows/register-app.yaml` is a `workflow_call` that any repo in the org can invoke. It takes inputs (app name, deploy path, namespace, etc.), renders the `GitRepository` + `Kustomization` + kustomization-list entry from a template, and opens a PR on grizzly-platform with auto-merge enabled. First-time setup for a new app is a single `workflow_dispatch` from the app repo — zero hand-written IaC.

**Image tag bumps happen via CI commits inside the app repo**, not via Flux image automation. App CI builds images with immutable tags (SHA or semver), then updates `deploy/values.yaml` (or equivalent) in the same repo with the new tags and commits back with `[skip ci]`. Flux sees the app repo change and reconciles. This pattern handles multi-image apps, custom namespace logic, and anything else the app needs, because all of it is just Helm/Kustomize at deploy time.

## Alternatives Considered

- **Monorepo Flux (all manifests in grizzly-platform).** The canonical "everything in one repo" GitOps model. **Rejected** because it forces a grizzly-platform PR on every deploy across every app repo, which is the exact friction this decision is trying to eliminate. Also requires refactoring every existing app repo to remove its chart — high one-time cost, permanent ongoing cost.
- **CI-driven Helm (old flow, keep as-is).** Runners keep helm + kubeconfig, `helm upgrade` direct. **Rejected** because cluster state is no longer in git — rollback becomes "what did CI deploy last Tuesday?" instead of `git revert`, and disaster recovery means re-running N workflows instead of `flux bootstrap`. Also fights the GitOps story Phases 4–6 have been building toward.
- **Flux image automation (Option A+).** `image-reflector-controller` + `image-automation-controller` watch the registry and write tag updates back to git, so CI only has to build and push. **Rejected** because several apps have multi-image and custom namespace logic that's awkward to express as per-image `ImagePolicy` + `ImageUpdateAutomation` resources, and the complexity/debugging cost outweighs the savings over a simple `yq` + `git commit` step in CI. Can revisit per-app if a specific workload would benefit.
- **Hybrid (Flux for infra, CI-driven helm for apps).** Pragmatic but creates two delivery models to reason about, which doubles the surface area for debugging "why didn't my thing deploy." **Rejected** in favor of one consistent model.
- **Keep grizzly-platform on personal account, use PATs for onboarding automation.** Works, but per-repo PATs rotate manually, personal PATs blur ownership if the operator ever adds collaborators, and the GitHub App install-once story is strictly cleaner. **Rejected** given the only cost of moving is one stale link on `bearflinn.com` (fixable during the landing-page migration in Phase 7 itself).

## Consequences

- **Cluster state is fully in git, distributed across repos.** Reconstructing the cluster means `flux bootstrap` + Flux reading each app repo's `deploy/` dir. Rollback for an app is `git revert` in the app repo; rollback for infra is `git revert` in grizzly-platform.
- **One-time onboarding cost per new app, amortized to zero per deploy.** First deploy needs a `workflow_dispatch` (or manual PR) to register the app. Every subsequent deploy is `git push` in the app repo, full stop.
- **Tag bumps are the app repo's responsibility.** Each app's CI must do the `yq` + `git commit [skip ci]` step. A template deploy workflow lives in grizzly-platform (`.github/workflows/app-deploy.yaml` or similar) that app repos can call, so this is a two-line include per repo, not a rewrite.
- **Flux reads from many repos, not one.** Each app is a separate `GitRepository` resource. Flux metrics will show per-app reconciliation status, which is useful for alerting ("resume-site hasn't reconciled in 10m"). The GitHub App handles auth uniformly across all of them.
- **No Flux image automation controllers deployed.** Saves the complexity of `image-reflector-controller` + `image-automation-controller` and their associated `ImagePolicy` / `ImageRepository` / `ImageUpdateAutomation` resources. If a future app wants the full A+ flow, it's additive — deploy the controllers and add resources just for that app.
- **grizzly-platform URL changes.** Personal-account references (including one link on `bearflinn.com/landing-page` and any git remotes on local machines) need updating. The landing-page migration in Phase 7 is the natural place to fix the site link; local remotes are a one-time `git remote set-url`.
- **Flux `prune: true` on the apps Kustomization means deleting an app's folder from grizzly-platform deletes its in-cluster resources.** Decommissioning an app is removing its folder and the list entry — same automation can do this via the inverse of the onboarding workflow.

## References

- `archive/migration-2026/k8s-cluster-standup.md` — Phase 7 uses this model.
- `kubernetes/clusters/grizzly-platform/infrastructure.yaml` — existing pattern for a top-level Flux Kustomization, mirrored for apps.
- `kubernetes/apps/` — new directory; created during Phase 7 setup.
- `.github/workflows/register-app.yaml` — new reusable onboarding workflow, created during Phase 7 setup.
- ADR-014 (K8s cluster stack) — establishes Flux CD as the GitOps engine.
- ADR-017 (ARC v2 GitHub runners) — runners that execute app CI, including the tag-bump commit step.
