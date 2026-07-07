# Monitoring Integration Guide

> **IP addresses:** Authoritative values are in `ansible/group_vars/all/network.yml`.

How the platform monitoring system works today, and how to evolve it as the infrastructure grows.

## Current Architecture

The monitoring system uses two Ansible roles applied to each monitored machine:

- **`monitoring-base`** — installs packages and Prometheus exporters (node\_exporter on `:9100`, ipmi\_exporter on `:9290`), configures smartd for SMART health monitoring and self-tests
- **`monitoring-checks`** — deploys cron-based health check scripts that alert on critical conditions and write Prometheus-compatible metrics to the node\_exporter textfile collector

The central observability stack (Prometheus, Loki, Tempo, Grafana, Alloy) is deployed on the R730xd via `deploy-observability.yml`. See [ADR-004](decisions/004-observability-stack-on-r730xd.md) for design decisions. Prometheus scrapes all exporters; Alloy collects Docker container logs and ships to Loki; Grafana provides dashboards and cross-linked data sources.

Cron-based health checks continue to run as a belt-and-suspenders layer alongside Prometheus alerting.

### What runs where

| Component | Location | Port | Purpose |
|-----------|----------|------|---------|
| node\_exporter | Each host | 9100 | System metrics (CPU, RAM, disk I/O, network) |
| ipmi\_exporter | Hosts with BMC | 9290 | Hardware sensors (PSU, fans, temps, ECC) |
| smartd | Each host | — | Drive self-tests, SMART monitoring |
| Cron checks | Each host | — | Tier 1 (every 5m) + Tier 2 (every 15m) health checks |
| Textfile metrics | Each host | — | `.prom` files at `/var/lib/prometheus/node-exporter/` |

### Tempo tenants

Tempo runs in multi-tenant mode. Every OTLP write and every Grafana query
must set `X-Scope-OrgID`; tenant-less requests are rejected.

| Tenant | Purpose |
|---|---|
| `grizzly-platform` | Platform operational traces — Argo Workflows, future self-instrumented services, and the `feedback-ingest` service's own operational traces. Default for new producers. |
| `residuum-feedback` | Report traces emitted by the `feedback-ingest` service. Isolated so feedback volume cannot affect platform trace retention or queries. |

Grafana exposes both as separate datasources: `Tempo (grizzly-platform)`
(uid `tempo` — preserved so Prometheus exemplar links and Loki derived
fields continue to resolve) and `Tempo (residuum-feedback)` (uid
`tempo-residuum-feedback`). Add a new tenant only when there's a specific
isolation reason; default new producers to `grizzly-platform`.

### Check scripts

Located at `/usr/local/lib/monitoring/checks/` on each host:

| Script | Tier | What it checks |
|--------|------|----------------|
| `check-smart.sh` | 1 | SMART health, drive temps, reallocated sectors |
| `check-disks.sh` | 1 | Disk space usage on all mounts |
| `check-services.sh` | 1 | Required/optional systemd services, failed units |
| `check-ipmi.sh` | 1 | PSU status, CPU temps, ECC memory errors |
| `check-nfs.sh` | 1 | NFS service and export status (skips if not installed) |
| `check-snapraid.sh` | 2 | SnapRAID sync errors, scrub recency (skips if not installed) |

Each script:
- Sources `/usr/local/lib/monitoring/lib/alert.sh` for shared alert dispatch
- Writes `.prom` metrics to the textfile collector directory
- Uses file-based deduplication to avoid alert floods
- Exits cleanly if its target service isn't installed

---

## Adding a New Machine

1. Add `monitoring-base` and `monitoring-checks` roles to the machine's playbook:

```yaml
- name: Machine monitoring setup
  hosts: new-machine
  become: yes
  tags: [monitoring]
  roles:
    - monitoring-base
    - monitoring-checks
```

2. Override defaults in the machine's inventory or group vars as needed:

```yaml
# Example: disable IPMI on machines without a BMC
ipmi_exporter_enabled: false

# Example: adjust load thresholds for a 4-core machine
monitoring_load_warn: 6
monitoring_load_crit: 8

# Example: add machine-specific required services
monitoring_required_services:
  - smartd
  - prometheus-node-exporter
  - kubelet
```

3. Run the playbook: `ansible-playbook -i inventory/machine.yml playbooks/setup-machine.yml --tags monitoring`

---

## Wiring Up Alerting

By default, all alerts go to syslog (`journalctl -t monitoring`). To enable webhook delivery:

### Option A: Generic Webhook

Set `monitoring_alert_webhook_url` in your inventory or group vars:

```yaml
monitoring_alert_webhook_url: "https://your-endpoint.example.com/alerts"
```

The payload is JSON:
```json
{
  "level": "critical",
  "check": "check-smart",
  "alert_id": "health_sda",
  "host": "r730xd",
  "message": "SMART health check FAILED for /dev/sda",
  "timestamp": "2026-03-28T14:30:00-04:00"
}
```

### Option B: Ntfy

Point the webhook URL at your Ntfy topic:

```yaml
monitoring_alert_webhook_url: "https://ntfy.example.com/platform-alerts"
```

Note: Ntfy expects different payload format. You may need to customize `alert.sh` to use Ntfy's API (simple curl with `-d "message"` and `-H "Title: ..."` headers) instead of the generic JSON POST. A Ntfy-specific dispatch function would look like:

```bash
curl -sf -H "Title: [${level^^}] ${check}" \
     -H "Priority: $([ "$level" = "critical" ] && echo "urgent" || echo "default")" \
     -H "Tags: ${level}" \
     -d "$message" \
     "$ALERT_WEBHOOK_URL" >/dev/null 2>&1
```

### Option C: Alertmanager Webhook Receiver

Prometheus + Alertmanager is running (see below); point `alert.sh` at Alertmanager's webhook receiver for unified alert routing if you want cron alerts flowing through the same pipeline. The cron-based alerts stay as a belt-and-suspenders layer regardless — see "Current Architecture" above.

---

## Prometheus + Alertmanager

Prometheus scrapes `node`/`ipmi` targets from `/etc/prometheus/targets.d/*.yml` (file-based service discovery, rendered by the `r730xd-prometheus` role) and evaluates the alert rules below; Alertmanager routes firing alerts.

These are the live Prometheus alerting rules (`ansible/roles/r730xd-prometheus/templates/rules/grizzly-platform.yml.j2`), replicating the cron check logic so the same conditions are covered by both layers:

```yaml
# rules/grizzly-platform.yml
groups:
  - name: storage
    rules:
      - alert: DiskSpaceWarning
        expr: (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Disk {{ $labels.mountpoint }} is {{ $value | printf \"%.0f\" }}% full on {{ $labels.instance }}"

      - alert: DiskSpaceCritical
        expr: (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100 > 95
        for: 2m
        labels:
          severity: critical

      - alert: SmartUnhealthy
        expr: monitoring_smart_healthy == 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "SMART health check failed for {{ $labels.device }} on {{ $labels.instance }}"

      - alert: DriveTemperatureHigh
        expr: monitoring_smart_temperature_celsius > 55
        for: 5m
        labels:
          severity: critical

      - alert: ReallocatedSectors
        expr: monitoring_smart_reallocated_sectors > 5
        for: 0m
        labels:
          severity: warning

  - name: hardware
    rules:
      - alert: PSUFailure
        expr: monitoring_ipmi_psu_failed > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Power supply failure detected on {{ $labels.instance }}"

      - alert: CPUTemperatureHigh
        expr: monitoring_ipmi_temperature_celsius > 85
        for: 5m
        labels:
          severity: critical

      - alert: ECCMemoryErrors
        expr: monitoring_ipmi_memory_errors_sel > 0
        for: 0m
        labels:
          severity: warning

  - name: services
    rules:
      - alert: ServiceDown
        expr: monitoring_service_up == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Service {{ $labels.service }} is down on {{ $labels.instance }}"

      - alert: SystemdFailedUnits
        expr: monitoring_systemd_failed_units > 0
        for: 5m
        labels:
          severity: warning

  - name: nfs
    rules:
      - alert: NFSDown
        expr: monitoring_nfs_service_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "NFS server is down on {{ $labels.instance }} — K8s PVCs affected"

  - name: snapraid
    rules:
      - alert: SnapRAIDErrors
        expr: monitoring_snapraid_errors > 0
        for: 0m
        labels:
          severity: critical

      - alert: SnapRAIDScrubOverdue
        expr: monitoring_snapraid_last_scrub_days > 7
        for: 0m
        labels:
          severity: warning
```

### Textfile Collector Metrics

The `monitoring_*` metrics in the alert rules above come from the cron check scripts via the textfile collector. Prometheus scrapes node\_exporter, which automatically picks up the `.prom` files — so a single scrape target yields both the standard node\_exporter metrics and the custom health check metrics.

---

## Grafana Dashboards

Grafana (via the `r730xd-grafana` role) has these dashboards provisioned:

| Dashboard | Grafana ID | Covers |
|-----------|-----------|--------|
| Node Exporter Full | 1860 (vendored at `ansible/roles/r730xd-grafana/files/dashboards/node-exporter-full.json`) | CPU, RAM, disk I/O, network, filesystem |
| IPMI Exporter | Community | PSU, fans, voltages, temperatures |
| Custom: Storage Health | — | SnapRAID status, SMART metrics, MergerFS pool usage |

### Key Prometheus Queries by Signal

| Signal | PromQL |
|--------|--------|
| Disk usage | `(1 - node_filesystem_avail_bytes/node_filesystem_size_bytes) * 100` |
| CPU temperature | `monitoring_ipmi_temperature_celsius{sensor=~".*CPU.*"}` |
| Drive temperature | `monitoring_smart_temperature_celsius` |
| SMART health | `monitoring_smart_healthy` |
| Reallocated sectors | `monitoring_smart_reallocated_sectors` |
| PSU status | `monitoring_ipmi_psu_failed` |
| NFS up | `monitoring_nfs_service_up` |
| SnapRAID errors | `monitoring_snapraid_errors` |
| System load | `node_load5` |
| Network throughput | `rate(node_network_receive_bytes_total[5m])` |

---

## Grafana Alloy

[Grafana Alloy](https://grafana.com/oss/alloy/) runs on the R730xd (`r730xd-alloy` role) as a **log shipper only** — it does not scrape metrics. It tails Docker container logs (via the Docker socket, relabeled with `container`/`compose_project`/`compose_service`) and the systemd journal, and forwards both to Loki. See `ansible/roles/r730xd-alloy/templates/config.alloy.j2` for the exact pipeline.

Metrics are unaffected by Alloy: Prometheus scrapes `node_exporter`/`ipmi_exporter` directly via file-based service discovery (`/etc/prometheus/targets.d/`), unchanged from the "Current Architecture" section above. There's no plan to have Alloy take over metrics scraping — Prometheus already does that job.

---

## Migrating to a Different Stack

If you switch from Prometheus to Zabbix, Checkmk, Datadog, or another monitoring system:

### What's Reusable

The check scripts at `/usr/local/lib/monitoring/checks/` are standalone bash scripts. They:
- Exit 0 on success, non-zero on failure
- Write human-readable output to stdout/stderr
- Can be wrapped by any agent-based monitoring system as custom checks

For example, with Zabbix agent:
```
UserParameter=smart.health,/usr/local/lib/monitoring/checks/check-smart.sh
```

### What to Replace

| Component | Replacement |
|-----------|-------------|
| `alert.sh` dispatcher | New stack's native alerting |
| Cron scheduling | New stack's agent scheduling |
| node\_exporter | Stack's own system agent (e.g., Zabbix agent, Datadog agent) |
| ipmi\_exporter | Stack's own IPMI integration |
| Textfile collector `.prom` files | Not needed — remove or keep for dual-stack |

### What to Keep Regardless

- **smartd** — drive self-tests are OS-level, independent of monitoring stack
- **ipmitool** — useful for manual diagnostics regardless of monitoring
- **edac-utils** — OS-level ECC reporting
