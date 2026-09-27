# ADR-078: Claude Code on a Separate ARC Scale Set

**Date:** 2026-09-26
**Status:** Accepted
**Relates to:** [ADR-017](017-arc-v2-github-runners.md) (ARC v2), [ADR-063](063-gate-runs-in-cluster.md) (gate Job RBAC in `arc-runners`), [ADR-073](073-retire-openbao.md) (1Password as the secrets source of truth)

## Context

Bear wants `@claude` mentions in this repo to run [Claude Code](https://github.com/anthropics/claude-code-action) on the org's self-hosted runners. The Anthropic credential is a Claude Code OAuth token (`claude setup-token`). The `grizzly-endeavors` org is on GitHub Free, so organization Actions secrets are not available to private repositories. The token therefore has to reach the job from the runner pod, not from `secrets.*`.

`lab-runners` is the shared CI pool: four slots, DinD, and the sccache S3 credentials. Putting the OAuth token in that pod environment would expose it to every CI job, and a Claude session would take a CI slot.

## Decision

Run Claude on a second ARC scale set, `claude-runners`, in the existing `arc-runners` namespace.

1. **Separate HelmRelease** (`arc-runner-set-claude`) of `gha-runner-scale-set` 0.14.0. `minRunners: 0`, `maxRunners: 2`. Same runner image and the same 4 CPU / 8 Gi request, 8 CPU / 16 Gi limit, as `lab-runners`, so a Rust compile fits. It registers with the same `github-runner-pat` the listener already uses. That PAT is not placed in the runner container env.
2. **Token only on this scale set.** `CLAUDE_CODE_OAUTH_TOKEN` comes from the `claude-code-oauth` Secret, key `token`. External Secrets materializes that Secret from 1Password item `cicd-claude-code`, field `oauth_token`. The value is never in git. The chart's ServiceAccount for this set is `claude-runners-gha-rs-no-permission`, and it is not bound to the gate-job Role.
3. **No DinD sidecar and no sccache credentials.** Claude edits the checkout and compiles with the toolchain already in the runner image. It does not push images. The privileged dockerd and the s3-bulk keys stay on `lab-runners`.
4. **Workflow** `.github/workflows/claude.yml` uses `runs-on: claude-runners`. It runs only when the actor is `BearFlinn` or the event author's association is `OWNER` or `MEMBER`, and only when the text contains `@claude`. The default model is `claude-sonnet-5`. The `model:opus` label on the issue or PR selects `claude-opus-5-5`, passed as `--model` in `claude_args`. GitHub authentication is the Claude GitHub App via the action's OIDC exchange (`id-token: write`), not the workflow `GITHUB_TOKEN`.

## Alternatives Considered

- **Inject the token into `lab-runners`.** Rejected. Every CI job on that pool would see the token, and Claude would compete with the four CI slots. The token's value is an account credential that can spend the Claude subscription.
- **A hand-created Kubernetes Secret (`kubectl create secret`).** Rejected. Platform credentials are 1Password items synced by External Secrets (`creationPolicy: Owner`). A hand-made Secret of the same name is not the source of truth and will be overwritten or left drifting.
- **`secrets.CLAUDE_CODE_OAUTH_TOKEN`.** Rejected for the org-wide reason above. This repo happens to be public, so a repository secret would work here, but the runner env is what a later private repo can share without an org secret.
- **DinD and sccache on the Claude pods.** Rejected. Image push is not this pool's job, and the build cache is an optimization. Both would copy extra credentials and a privileged container onto the pod that holds the OAuth token.

## Consequences

- A job must request `claude-runners` to see the token in its environment. Jobs on `lab-runners` do not.
- The pre-existing gate-job Role on `lab-runners-gha-rs-no-permission` can still create a Job that mounts any Secret in `arc-runners`, including `claude-code-oauth`. That residual is the one ADR-063 already accepts for a single-tenant org. The Claude ServiceAccount is not granted that Role.
- GitHub Free provides one runner group (Default). Both scale sets share its repository policy, so this scale set cannot be hidden from public repositories independently of `lab-runners`. This repo is public and already schedules jobs onto that group. The `@claude` workflow does not trigger on `pull_request`; a fork workflow that does, and that sets `runs-on: claude-runners`, still lands on a pod with the token if the org allows that fork workflow to run. Fork approval withholds Actions secrets, not runner process environment variables.
- **Health:** the scale-set listener pod in `arc-runners`, and a queued job creating a runner pod. `minRunners: 0`, so an idle pool has no runner pod.
- **Metrics:** the same listener gauges as `lab-runners`. Prometheus scrapes the ARC controller (`arc-controller`, NodePort 30885), not each listener.
- **Logs:** the GitHub Actions run log. The ephemeral pod's logs exist until the scale set deletes it.
- **Alerts:** `ARCControllerDown` and `ARCRunnerPodCrashLooping` already cover `arc-runners`. A missing 1Password item shows up as `ExternalSecret` `SecretSyncedError` and as runner pods stuck in `CreateContainerConfigError` once a job is queued.
- **Recovery:** Flux reconciles the HelmRelease. Rotate the token by editing the 1Password item and force-syncing the ExternalSecret (`refreshPolicy: OnChange` does not poll). Re-run `@claude` to start a new pod.
- **First steps when a mention does nothing:** confirm the actor is allowed, then `kubectl get externalsecret claude-code-oauth -n arc-runners` and `kubectl get pods -n arc-runners`. The listener depends on `github-runner-pat`; the runner pod depends on `claude-code-oauth` and on the Claude GitHub App being installed on this repository.
