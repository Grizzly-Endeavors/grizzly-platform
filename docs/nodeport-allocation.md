# NodePort Allocation

All K8s services exposed via NodePort, used by R730xd Prometheus for
external scraping and by the VPS ingress path (ADR-019).

Kubernetes default NodePort range: 30000-32767.

| Port  | Service                      | Purpose                          | Source File                                            |
|-------|------------------------------|----------------------------------|--------------------------------------------------------|
| 30356 | ingress-nginx HTTPS          | External HTTPS traffic via VPS   | `kubernetes/infrastructure/ingress-nginx/helmrelease.yaml` |
| 30487 | ingress-nginx HTTP           | External HTTP traffic via VPS    | `kubernetes/infrastructure/ingress-nginx/helmrelease.yaml` |
| 30500 | OCI registry                 | containerd pulls via localhost   | `kubernetes/infrastructure/registry/service.yaml`      |
| 30885 | ARC controller metrics       | Prometheus scraping              | `kubernetes/infrastructure/github-runners/metrics-service.yaml` |
| 30886 | Argo controller metrics      | Prometheus scraping              | `kubernetes/infrastructure/argo-workflows/metrics-services.yaml` |
| 30887 | Argo server metrics          | Prometheus scraping              | `kubernetes/infrastructure/argo-workflows/metrics-services.yaml` |
| 30888 | cert-manager metrics         | Prometheus scraping              | `kubernetes/infrastructure/cert-manager/metrics-service.yaml` |
| 30889 | ingress-nginx metrics        | Prometheus scraping              | `kubernetes/infrastructure/ingress-nginx/helmrelease.yaml` |
| 30025 | Stalwart SMTP (25)           | Inbound mail via HAProxy/tunnel  | `kubernetes/infrastructure/stalwart/service.yaml`      |
| 30465 | Stalwart submissions (465)   | Implicit-TLS submission via VPS  | `kubernetes/infrastructure/stalwart/service.yaml`      |
| 30587 | Stalwart submission (587)    | STARTTLS submission via VPS      | `kubernetes/infrastructure/stalwart/service.yaml`      |
| 30993 | Stalwart IMAPS (993)         | IMAP over TLS via VPS            | `kubernetes/infrastructure/stalwart/service.yaml`      |

## Conventions

- **30356-30500**: Traffic-carrying services (ingress, registry)
- **300xx (mail)**: Stalwart mail ports use a mnemonic mapping — the last three digits equal the mail port (25→30025, 465→30465, 587→30587, 993→30993) — so the VPS HAProxy port map (ADR-051, load-bearing) is unambiguous.
- **30885-30889**: Metrics endpoints for Prometheus
- New allocations should pick the next available port in the appropriate range
