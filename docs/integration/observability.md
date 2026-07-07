# Integration: observability (logs, metrics, traces)

**What you get:** your app's telemetry flowing into the platform observability stack (Prometheus / Loki / Tempo / Grafana on the R730xd, [ADR-004](../decisions/004-observability-stack-on-r730xd.md)), visible in Grafana. The three signals have three very different amounts of wiring:

| Signal | Effort | How it gets there |
|---|---|---|
| **Logs** | **Free** | Log to stdout/stderr; the in-cluster Alloy DaemonSet ships them to Loki automatically. |
| **Metrics** | A NodePort + a scrape target | Expose `/metrics`; the R730xd Prometheus scrapes it (file-SD — there is **no in-cluster Prometheus operator**, so no `ServiceMonitor`). |
| **Traces** | SDK config | Push OTLP to Tempo with a tenant header. |

## Logs — do nothing but log to stdout

The Alloy DaemonSet (`kubernetes/infrastructure/monitoring/`) tails every pod's stdout/stderr and forwards to Loki at `http://10.0.0.200:3100`. It auto-labels each stream `namespace`, `pod`, `container`, and `job="kubernetes-pods"`. So the entire integration is: **write logs to stdout/stderr** (structured JSON is ideal — Loki/Grafana parse it), don't write to log files inside the container, and query them in Grafana's Loki datasource:

```logql
{namespace="<app>"} | json | level="error"
```

That's it. No sidecar, no config, no manifest.

## Metrics — expose `/metrics`, then add a scrape target

The platform Prometheus lives on the R730xd and discovers targets from static files (`/etc/prometheus/targets.d/*.yml`, rendered by the `r730xd-prometheus` role). It is **not** in the cluster and there is **no** `ServiceMonitor`/`PodMonitor` CRD — so exposing app metrics is a deliberate three-step, modeled on how the Flux controllers and grizzly-invite are scraped:

**1. Expose a Prometheus `/metrics` endpoint** in your app (any client library), on a container port.

**2. Publish it as a NodePort + allow the scrape** (in your app's `deploy/` chart or its `kubernetes/apps/<app>/`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <app>-metrics
  namespace: <app>
spec:
  type: NodePort
  selector: { app: <app> }
  ports:
    - port: 8080
      targetPort: metrics
      nodePort: 308XX        # claim a free port — see docs/nodeport-allocation.md
      name: metrics
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy          # NodePort traffic is SNATed by Cilium, so allow from any source
metadata: { name: allow-external-scraping, namespace: <app> }
spec:
  podSelector: { app: <app> }
  policyTypes: [Ingress]
  ingress:
    - ports: [{ port: 8080, protocol: TCP }]
```

**3. Add a scrape target** to the `r730xd-prometheus` role — a new `templates/targets.d/k8s-<app>.yml.j2` pointing at the control-plane node IP + your NodePort — then run the role:

```yaml
# ansible/roles/r730xd-prometheus/templates/targets.d/k8s-<app>.yml.j2
- targets:
    - "{{ hostvars[groups['k8s_control_plane'][0]]['ansible_host'] }}:308XX"
  labels:
    env: "grizzly-platform"
    instance: "<app>"
    component: "<app>"
```

```bash
ansible-playbook -i ansible/inventory ansible/playbooks/deploy-observability.yml --tags prometheus
```

Claim the NodePort in [nodeport-allocation.md](../nodeport-allocation.md) so it doesn't collide. This friction is the current honest state — if per-app metrics become common, an in-cluster scraper is the upgrade path, but today it's file-SD.

## Traces — OTLP to multi-tenant Tempo

Tempo runs in **multi-tenant** mode; every OTLP write **must** carry an `X-Scope-OrgID` header or it's rejected. Point your OpenTelemetry SDK/exporter at the R730xd:

```
OTLP gRPC:  http://10.0.0.200:4317
OTLP HTTP:  http://10.0.0.200:4318
Header:     X-Scope-OrgID: grizzly-platform      # default tenant for new producers
```

```python
# OTel Python, gRPC exporter
OTLPSpanExporter(
    endpoint="10.0.0.200:4317",
    insecure=True,
    headers=(("x-scope-orgid", "grizzly-platform"),),
)
```

Use the `grizzly-platform` tenant unless you have a specific isolation reason (the `residuum-feedback` tenant exists so feedback-report volume can't affect platform trace retention — that's the bar for a new tenant). Traces then show up in Grafana's `Tempo (grizzly-platform)` datasource, cross-linked from Prometheus exemplars and Loki.

## Verify

- **Logs:** `{namespace="<app>"}` returns lines in Grafana Explore within seconds of a request.
- **Metrics:** `up{instance="<app>"}` is `1` in Prometheus after the role run; your custom series are queryable.
- **Traces:** a request produces a trace in Grafana's Tempo datasource under the `grizzly-platform` tenant.

## Troubleshoot

- **No logs in Loki** — the app writes to a file instead of stdout/stderr, or crashes before logging. Confirm `kubectl logs` shows output; Alloy only sees stdout/stderr.
- **`up == 0` for your metrics target** — the NodePort isn't reachable (missing NetworkPolicy allowing port 8080 from any source — NodePort traffic is SNATed so you can't scope it to `10.0.0.0/24`), the NodePort number in the target doesn't match the Service, or the role wasn't re-run.
- **Traces rejected / 401-ish from Tempo** — missing or misspelled `X-Scope-OrgID` header. It's mandatory; there is no default tenant on the write path.
- **Metrics NodePort collision** — two Services claimed the same port. Check [nodeport-allocation.md](../nodeport-allocation.md).

## See also

- [monitoring.md](../monitoring.md) — **operator** doc: how the platform monitors its own hosts (exporters, cron checks, alert rules, Grafana dashboards, Tempo tenants).
- `kubernetes/infrastructure/monitoring/` (Alloy) · `ansible/roles/r730xd-prometheus/` (scrape targets) · `ansible/roles/r730xd-tempo/` (OTLP).
- ADR [004](../decisions/004-observability-stack-on-r730xd.md) (observability stack).
