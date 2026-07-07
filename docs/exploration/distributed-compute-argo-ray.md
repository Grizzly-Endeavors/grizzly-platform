# Distributed Compute: Argo Workflows + Ray on K8s

**Date:** 2026-04-04
**Status:** Exploring

## Context

Post-migration cluster has ~54 cores, 100+ threads, and 216+ GB RAM across 5+ nodes. Goal is to maximize distributed CPU/RAM compute for two use cases:

1. **Job orchestration** — CI/CD, ETL, data export pipelines, scheduled batch work
2. **Large-scale data processing/analysis** — distributed computation over lab telemetry and other datasets

## Approach

Run both Argo Workflows and Ray on K8s simultaneously. They're both standard K8s workloads and share cluster resources through normal scheduling — no need to dedicate nodes or switch modes.

### Argo Workflows

- K8s-native DAG/workflow engine. Controller + ephemeral job pods.
- Near-zero resource usage when idle; pods spin up on demand across nodes.
- Immediate value: automate CI/CD, data exports (Prometheus/Loki to Parquet on s3-bulk), scheduled ETL.
- Artifacts stored in s3-bulk (versitygw, on MergerFS).

### Ray (via KubeRay Operator)

- Distributed Python compute framework. Operator supports RayJob resources that create temporary clusters per job.
- Scales across heterogeneous nodes (different core counts/RAM) natively.
- Use cases: anomaly detection, forecasting, clustering, ML training (CPU-only models like XGBoost scale linearly with cores), dataset transformations.
- Reads/writes datasets from s3-bulk (same as Argo artifacts).

### How They Compose

Argo can orchestrate Ray — a workflow step can submit a RayJob. Pipeline pattern:

```
Argo: export data from Prometheus/Loki
  -> Argo: transform to Parquet, store in s3-bulk
    -> Argo: submit RayJob for distributed analysis
      -> Ray: read from s3-bulk, compute, write results back
        -> Argo: post-processing, notification, dashboard update
```

## Key Enabler

The s3-bulk versitygw instance (MergerFS, ~15 TB) serves as the shared interchange layer between Argo artifacts and Ray datasets. Already deployed and running.

## Resource Estimates

| Component | Idle Footprint | Active Footprint |
|-----------|---------------|-----------------|
| Argo controller | ~200 MB RAM, minimal CPU | Same (jobs are separate pods) |
| KubeRay operator | ~200 MB RAM, minimal CPU | Same (Ray clusters are separate pods) |
| Argo job pods | 0 (don't exist until triggered) | Varies per workflow |
| Ray head + workers | 0 (RayJob mode, ephemeral) | Claims what the job needs |

## Progression

1. Stand up Argo Workflows first — immediate utility for automation and data pipeline work
2. Use Argo to build structured datasets (export lab telemetry to Parquet on s3-bulk)
3. Add KubeRay when there's data worth crunching at scale
4. Compose them: Argo DAGs that include RayJob steps

## Distributed Trace Analysis

### Data Source

Tempo is already collecting traces via OpenTelemetry (gRPC 4317, HTTP 4318) with S3 backend on s3-hot (versitygw, ZFS). Expected trace producers:

- **Argo Workflows** — OTel-instrumented workflow steps, DAG-level spans
- **Self-hosted AI agents** — end-to-end traces covering prompt construction, LLM calls, tool use, responses
- **Application services** — request-level traces from web services (resume-site, landing-page, etc.)

### Export Pipeline

Tempo exposes a query API (port 3200) that supports bulk span export. Same Argo-to-Ray pattern:

```
Tempo API (query by time range / service / tag)
  -> Argo: export spans to Parquet on s3-bulk
    -> Ray: distributed analysis across span datasets
      -> Results to Grafana / s3-bulk / Postgres
```

### Analysis Opportunities

**Structural analysis:**
- Automatic service dependency graph extraction from trace parent/child relationships
- Detect topology changes over time (new dependencies appearing, old ones disappearing)

**Performance analysis:**
- Latency distribution modeling per service/endpoint — percentiles, histograms, trend detection
- Statistical outlier detection on span durations (find the slow calls without manual thresholds)
- Bottleneck identification — which service is on the critical path most often?

**AI agent-specific:**
- Token usage and latency per model/provider, broken down by agent type and task
- Tool-use patterns — which tools do agents call most, which fail, which are slowest?
- Retry and error rate analysis — correlate agent failures with downstream service health
- Cost attribution — map agent traces to compute time across the cluster

**Infra agent change-impact analysis:**
- Instrument the infra management agent with OTel so every action (Ansible run, service restart, K8s rollout, config change) produces a trace with structured attributes (target host, action type, affected resources)
- Correlate agent action timestamps with anomalies in other signals during the same time window:
  - Prometheus: CPU/memory spikes, error rate increases, request latency jumps on affected or downstream nodes
  - Loki: connection resets, OOM kills, crash loops in pods that depend on what the agent touched
  - Tempo: elevated latency or error spans in services running on the same node or depending on the restarted service
- Build automated change-impact reports: "Agent restarted service X at T — here's what happened across the cluster in the following N minutes"
- Over time, learn blast radius patterns: "rolling restarts of deployment Y consistently cause 30s of elevated 5xx in service Z"
- Feed this back into the agent itself — before taking an action, check historical impact data to predict consequences and choose lower-impact timing (e.g., avoid restarts during high-traffic windows)

**Cross-signal correlation (traces + metrics + logs):**
- Join trace span IDs with log entries in Loki for root-cause analysis at scale
- Correlate trace latency spikes with Prometheus metrics (CPU, memory, disk I/O) on the nodes involved
- Detect cascading failures — trace propagation delay maps to which service degraded first

### Storage Considerations

- Raw traces in Tempo (ZFS, hot) — retained for real-time query and debugging
- Exported Parquet on s3-bulk (MergerFS, cold) — retained long-term for batch analysis
- Tempo retention policy vs Parquet retention can differ — keep raw traces for days/weeks, Parquet for months/years

## Open Questions

- Cluster resource limits / quotas — how much to reserve for always-on services vs batch compute?
- Ray autoscaling config — min 0 workers (fully ephemeral) vs keeping a small warm pool?
- Data format standardization — Parquet seems right, but need to decide on partitioning scheme
- Whether to add Apache Iceberg or Delta Lake on top of s3-bulk for table semantics
- Tempo retention policy — how long to keep raw traces vs relying on Parquet exports?
- Trace sampling strategy — head-based vs tail-based sampling as volume grows
- Schema for exported span Parquet files — flatten nested attributes or preserve hierarchy?
