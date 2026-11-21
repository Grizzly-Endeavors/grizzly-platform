# ADR-087: Runner Pod CPU History From a Filtered Kubelet cAdvisor Scrape

**Date:** 2026-11-21
**Status:** Accepted
**Relates to:** [ADR-004](004-observability-stack-on-r730xd.md) (Prometheus on the R730xd), [ADR-081](081-job-shaped-ci-runner-pools.md) (runner pools).

## Context

Prometheus scrapes each kubelet's `/metrics` (job `kubelet`) but not `/metrics/cadvisor`, so no per-container CPU series exist for pods in the cluster. The only `container_cpu_usage_seconds_total` series come from the cAdvisor container on the R730xd and describe Docker containers. The CPU a CI job used on a runner pod in `arc-runners` cannot be read once the ephemeral pod is gone, while kube-state-metrics already retains the pod names that match GitHub's `runner_name`.

Prometheus keeps 30 days with a 10 GiB size cap, and a full cAdvisor scrape per node exposes thousands of series, most of them irrelevant here.

## Decision

- **Add a `kubelet-cadvisor` scrape job** in `ansible/roles/r730xd-prometheus/templates/prometheus.yml.j2`. It reuses the `kubelet` job's targets file (`targets.d/k8s-kubelet.yml`), bearer token and CA, sets `metrics_path: /metrics/cadvisor`, and inherits the global 15s interval. The `prometheus-metrics` ClusterRole already grants `nodes/metrics`.
- **Keep one metric for one namespace.** `metric_relabel_configs` keep only `container_cpu_usage_seconds_total` and, of those, only series with `namespace="arc-runners"`. The `namespace`, `pod` and `container` labels stay, so `pod` equals the job's `runner_name`.
- **Read a runner's CPU with** `sum by (pod, container) (increase(container_cpu_usage_seconds_total{namespace="arc-runners"}[1h]))`, or `rate(...)` over the job's window.
- **Apply with** `ansible/playbooks/setup-k8s-cluster-metrics.yml`, which re-templates the config and recreates the Prometheus container.

## Alternatives Considered

- **Keep the full cAdvisor metric set.** Cardinality grows with every pod and cgroup in the cluster and competes with the 10 GiB cap for no current need.
- **Scrape cAdvisor through metrics-server or a separate agent.** Metrics-server holds only the current sample, and a new agent adds a component to run for data the kubelet already exposes.

## Consequences

- Series exist only while a runner pod runs; the pod-level series (`container=""`) and per-container series (`runner`, `dind`) both appear.
- At 15s sampling, CPU is meaningful for job steps of about a minute or longer.
- Watching another namespace's CPU means widening the `namespace` regex in the job.
