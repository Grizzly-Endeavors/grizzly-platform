# Runbook — GitHub Actions runners (ARC)

How the org's self-hosted runners stay registered, and what to do when a pool goes dark. Manifests: `kubernetes/infrastructure/github-runners/` (controller plus five scale sets in `arc-runners`) and `kubernetes/infrastructure/argo-workflows/build-runner-image*.yaml` (the image). Decisions: [ADR-017](../decisions/017-arc-v2-github-runners.md), [081](../decisions/081-job-shaped-ci-runner-pools.md), [086](../decisions/086-runner-image-weekly-rebuild.md).

## The 30-day runner version window

Every runner pod runs `registry.registry.svc.cluster.local:5000/github-runner:latest` (`imagePullPolicy: Always`), built from `docker/github-runner/Dockerfile` on `ghcr.io/actions/actions-runner:latest`. GitHub refuses a runner once it is more than 30 days behind a newer release. The `build-runner-image-weekly` CronWorkflow rebuilds the image from `master` every Sunday at 04:17 UTC to keep it inside the window; a push that changes `docker/github-runner/` also rebuilds it (`.github/workflows/build-runner-image.yaml`). `ghcr.io` is not mirrored through zot, so each build resolves the base from upstream.

## What ARC does when a runner is refused

ARC (0.14.x) marks the runner `Outdated`, marks the `AutoscalingRunnerSet` `Outdated`, deletes the set's listener pod in `arc-systems` and its GitHub registration, and stops reconciling the set until its spec changes. The set stays torn down until then: no listener, no runners, and jobs for that `runs-on` label queue until GitHub cancels them. A fresh image alone does not revive it.

## Health signals

```fish
kubectl -n arc-systems get pods                      # one <set>-<hash>-listener per scale set, plus the controller
kubectl -n arc-runners get autoscalingrunnersets     # all five sets
kubectl -n argo get cronworkflow build-runner-image-weekly
kubectl -n argo get workflows --sort-by=.metadata.creationTimestamp | tail
```

Alerts: `ARCScaleSetListenerMissing` (fewer than 5 ready listeners for 15 minutes), `ArgoWorkflowFailed` (a build failed), `ARCControllerDown`, `ARCRunnerPodCrashLooping`.

## Recovery: a set is `Outdated` or has no listener

1. Rebuild the image and confirm it succeeded: `argo submit --from cronworkflow/build-runner-image-weekly -n argo` (or `--from workflowtemplate/build-runner-image -n argo`).
2. Change each affected scale set's spec so ARC re-evaluates it (the controller compares a hash of the spec). Edit a value in its HelmRelease under `kubernetes/infrastructure/github-runners/` through a PR, let Flux apply it, and confirm the set's `phase` leaves `Outdated` and its listener pod returns.
3. Confirm a queued job picks up a runner.

## Upgrading ARC

The pinned chart version appears in all six HelmReleases in `kubernetes/infrastructure/github-runners/` (controller plus five scale sets) and must match across them. 0.15.0 and later change the `AutoscalingRunnerSet` CRD; upstream's upgrade is to remove every scale set, the controller and the CRDs, then install the new version ([upgrade guide](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets#upgrading-arc)). Plan it as an outage of every pool and check the current release notes first.
