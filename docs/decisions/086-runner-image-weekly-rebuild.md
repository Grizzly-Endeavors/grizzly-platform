# ADR-086: Runner Image Rebuilt Weekly to Stay Inside GitHub's Runner Version Window

**Date:** 2026-11-15
**Status:** Accepted
**Relates to:** [ADR-017](017-arc-v2-github-runners.md) (ARC v2), [ADR-057](057-container-builds-buildkit.md) (in-cluster BuildKit builds), [ADR-081](081-job-shaped-ci-runner-pools.md) (runner pools). Refs [#294](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/294).

## Context

Every runner pod runs `registry.registry.svc.cluster.local:5000/github-runner:latest`, built from `docker/github-runner/Dockerfile`, whose base is `ghcr.io/actions/actions-runner:latest`. The image was built only when that Dockerfile changed, so it froze at whatever runner version was `latest` on the last edit.

GitHub refuses a runner once it is more than 30 days behind a newer release. v2.338.0 came out on 2026-10-06, so the image, 117 days old, was refused from 2026-11-05. ARC 0.14.0 then marked each runner `Outdated` ("Runner is deprecated"), marked the `AutoscalingRunnerSet` `Outdated`, deleted its listener and its GitHub registration, and stopped reconciling it until the set's spec changed (`autoscalingrunnerset_controller.go`, tag `gha-runner-scale-set-0.14.0`). `lab-runners`, `-fast`, `-light` and `-wide` went dark on 2026-11-05/06 and jobs queued until GitHub cancelled them (#294). Nothing alerted, because nothing the cluster scrapes watched the listeners.

## Decision

- **Rebuild weekly.** The `build-runner-image-weekly` CronWorkflow (`kubernetes/infrastructure/argo-workflows/`) runs the existing `build-runner-image` WorkflowTemplate from `master` every Sunday at 04:17 UTC, `concurrencyPolicy: Forbid`. A weekly cadence keeps the base within one runner release of upstream, well inside the 30-day window. The Dockerfile-change trigger in `.github/workflows/build-runner-image.yaml` stays for edits.
- **The base must reach BuildKit from upstream.** `buildkitd.toml` mirrors only `docker.io` through zot, and zot syncs only docker.io, gcr.io and mcr.microsoft.com, so `ghcr.io/actions/actions-runner:latest` is resolved against ghcr.io on every build and a new upstream digest invalidates every layer built on it. Adding ghcr.io to the mirror or to zot's sync would let a cached tag hide a new base; it must stay direct.
- **Alert on a missing listener.** `ARCScaleSetListenerMissing` (`ansible/roles/r730xd-prometheus/templates/rules/grizzly-platform.yml.j2`) fires when fewer than 5 listener pods in `arc-systems` are ready for 15 minutes. It reads kube-state-metrics pod series that Prometheus already scrapes. A failed weekly build is covered by the existing `ArgoWorkflowFailed` rule.
- **ARC stays on 0.14.0.** 0.15.0 changes the `AutoscalingRunnerSet` CRD, and upstream's upgrade path is to remove every scale set, the controller and the CRDs, then reinstall ([actions-runner-controller#4706](https://github.com/actions/actions-runner-controller/issues/4706)). That is its own change, not a side effect of this one. The runbook records the procedure.

## Alternatives Considered

- **Pin the base image to a runner version and bump it by hand.** A pin is the same trap with a number on it: nothing forces the bump, and the window closes in 30 days.
- **Rebuild on a webhook from actions/runner releases.** More machinery for the same result; releases come every one to two weeks and a weekly timer is inside the window either way.
- **Alert from the listener metrics (`gha_*`).** Listener pods are not scraped (only the controller is), and a missing listener emits nothing. Pod readiness in kube-state-metrics sees the absence directly.

## Consequences

- A week's worth of base updates lands in the image automatically; a build that fails, and so lets the image age toward the window, fires `ArgoWorkflowFailed`.
- Layers that do not depend on the base (when the base digest has not changed) come from the BuildKit registry cache, so tools like `kubectl` and Rust refresh only when the base moves or the Dockerfile changes.
- The alert's `5` must change with the number of scale-set HelmReleases in `kubernetes/infrastructure/github-runners/`; a mismatch fires loudly rather than staying quiet.
