# ADR-081: Job-Shaped CI Runner Pools

**Date:** 2026-10-08
**Status:** Accepted
**Relates to:** [ADR-017](017-arc-v2-github-runners.md) (ARC v2), [ADR-032](032-registry-pullthrough-cache.md) (registry pull-through cache), [ADR-078](078-claude-code-runner-scale-set.md) (Claude scale set)

## Context

Every CI job in the org ran on `lab-runners`: one pod shape (runner 4 CPU request / 8 CPU limit, DinD sidecar), at most four at once, on whichever node had room. Measuring residuum's pipelines on 2026-10-08 showed three problems with that.

- **Node placement decided the run time.** quanta (2× Xeon E5-2670, 2012) and intel-nuc (i7-12700H) differ about threefold per core. The same residuum web job ran its lint in 32 s on one run and 104 s on another, and its browser suite in 9.5 min against 27 min. In a release where the Rust and web jobs ran together, `cargo test` spent 20 minutes compiling a build that took about 3 minutes on its own, and timing-sensitive tests failed under the load. Three of four releases that day failed that way.
- **The DinD sidecar had no resources set**, so the namespace LimitRange gave it 1 CPU / 2 Gi. Containers a job starts run inside that sidecar's cgroup. residuum's Playwright browsers, four workers' worth, shared one CPU, and the scheduler counted none of their load.
- **Trivial jobs reserved build-sized pods.** A job that reads a tag or decides whether to cross-compile took one of the four 4-CPU slots, and runs queued for up to 30 minutes behind them.

## Decision

Split CI into pools shaped by the job, as separate `gha-runner-scale-set` HelmReleases in `arc-runners`, each selected by its `runs-on` name.

| Pool | Nodes | Max | Runner request / limit | DinD request / limit | For |
|------|-------|-----|------------------------|----------------------|-----|
| `lab-runners` | prefers quanta, optiplex; any | 4 | 4 / 8 CPU, 8 / 16 Gi | 0.5 / 4 CPU, 0.5 / 8 Gi | the org default |
| `lab-runners-fast` | intel-nuc only | 2 | 5 / 16 CPU, 8 / 24 Gi | 0.5 / 4 CPU, 0.5 / 8 Gi | long serial critical paths (Rust compile and test) |
| `lab-runners-wide` | quanta, optiplex only | 6 | 2 / 8 CPU, 4 / 12 Gi | 2 / 8 CPU, 2 / 12 Gi | work split across many runners (sharded browser suites, release builds) |
| `lab-runners-light` | any | 6 | 0.1 / 1 CPU, 0.25 / 2 Gi | none | shell and `gh` only |

- Every DinD sidecar carries explicit resources, so job containers get real CPU and the scheduler sees them.
- `lab-runners` leans toward quanta and optiplex so the NUC stays free for `lab-runners-fast`, and still falls back to the NUC rather than queue.
- The light pool has no DinD and no sccache credentials, and runs `run.sh` directly.
- The zot pull-through cache also mirrors `mcr.microsoft.com` under `/mcr`, so the Playwright browser image a CI run pulls into a fresh DinD comes from the LAN. That pull took 3.4 minutes from MCR on every run. The mcr entry is first in the sync list, because zot tries on-demand registries in order and skips an entry whose content rules don't match without calling upstream. zot's limits rose to 4 CPU / 4 Gi to serve multi-GB pulls to several runners at once.

The chart stays at 0.14.0 for all four sets, matching the controller. Upgrading is separate: 0.15.0 changes the EphemeralRunnerSet finalizer, and actions/actions-runner-controller#4706 (open) reports scale sets stranded in `Terminating` after the upgrade.

## Alternatives Considered

- **One pool with a preferred affinity for the NUC.** Rejected. Jobs still spill onto quanta whenever the NUC is busy, so timings stay unpredictable, and trivial jobs still reserve 4 CPUs.
- **One pool pinned to the NUC.** Rejected. Two heavy jobs at once fill it, so a release plus a couple of PRs would queue.
- **Bake the Playwright browsers into the runner image.** Rejected. Visual baselines must render in the official Playwright image at the exact version a repo installs, and that version moves with each repo's lockfile, not with this image.
- **Run the browser image as a Kubernetes sidecar so the node's containerd caches it.** Rejected for the same version coupling: every Playwright bump in a repo would need a change here.

## Consequences

- Workflows choose a pool. Jobs that don't name one keep running on `lab-runners`, so other repos need no change.
- The fast pool is two runners on one machine. When the NUC is down, or other workloads take its headroom, `lab-runners-fast` jobs stay queued in GitHub instead of moving elsewhere. The GitHub UI shows the queued job, and the listener's `gha_desired_runners` and `gha_running_jobs` gauges show the gap. The way out is to switch the job's `runs-on` to `lab-runners` or fix the NUC.
- **Health:** `kubectl get autoscalingrunnersets -n arc-runners` lists every pool with its current, pending, and running runners. Each pool has its own listener in `arc-systems`, and its metrics carry the pool name.
- More concurrent CI: up to 18 runners across the pools, against 4 before. Requests are sized so the pools' maximums fit next to the cluster's other workloads. Limits sit above requests, so an idle cluster gives a job more.
