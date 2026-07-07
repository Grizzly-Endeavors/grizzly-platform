# ADR-019: Ingress & TLS Termination Topology

**Date:** 2026-04-09
**Status:** Accepted

## Context

Phase 6 of the K8s cluster standup (`archive/migration-2026/k8s-cluster-standup.md`) needs to put external HTTP(S) traffic in front of cluster workloads. The question is not *whether* to run nginx-ingress — ADR-014 already picked it — but how traffic reaches the cluster from the public internet, where TLS terminates, and how the VPS bridges to a cluster on a private LAN.

The relevant existing pieces:
- **Hetzner VPS** (`proxy-vps`) has a public IP, runs Caddy with a `*.bearflinn.com` wildcard certificate issued via Cloudflare DNS-01.
- **R730xd** is on the home LAN (`10.0.0.0/24`). It has NetBird installed out-of-band as an admin-group member for operator use (jumpbox, laptop). This is a temporary placeholder for the ingress tunnel termination; a future off-the-shelf router ([ADR-021](021-off-the-shelf-router-tower-pc-as-worker.md)) may take over boundary duties later, or the tunnel may stay on R730xd — the ADR-021 decision does not force a move.
- **K8s cluster** (one control plane + three workers) is entirely on the home LAN, not individually reachable from the internet.
- **cert-manager** has not previously been deployed via GitOps; the old cluster installed it via an Ansible playbook for a short-lived LE-based flow.

## Decision

**TLS termination stays on the VPS.** nginx-ingress handles hostname routing only; the cluster leg of the traffic path is plaintext HTTP. Caddy owns the wildcard cert (Cloudflare DNS-01) and forwards `Host` + `X-Real-IP`; nginx-ingress reads those headers to recover the client address.

**ingress-nginx runs as a DaemonSet with a NodePort service**, fixed on `30487` (HTTP) and `30356` (HTTPS). Controller metrics are exposed on `30889`. The DaemonSet means any node can serve an incoming request; kube-proxy handles the forwarding even when the request lands on a node whose controller pod is the target.

**VPS → cluster connectivity uses a dedicated point-to-point WireGuard tunnel** between the VPS and R730xd (`10.200.0.1` ↔ `10.200.0.2`, `/30`). R730xd initiates (it's behind home NAT) and sends `PersistentKeepalive`; the VPS listens on `51820/udp`. **iptables on R730xd DNATs only TCP `30487` and `30356` from the `wg0` interface** to `dell-inspiron-15` (`10.0.0.226`). Nothing else on the home LAN is reachable from the VPS through the tunnel.

**cert-manager ships with a single self-signed ClusterIssuer.** Let's Encrypt (staging or production) is deferred until a workload actually needs a browser-trusted certificate.

## Alternatives Considered

- **NetBird subnet route advertising `10.0.0.0/24` to the VPS.** This is how a NetBird admin-group member is normally used. It works: Caddy targets any LAN IP directly and traffic flows through the mesh. **Rejected** because it puts the VPS — a publicly-reachable box — in a position to address every host on the home LAN. For a single-purpose HTTP ingress, that's wildly disproportionate attack surface. A VPS compromise should be scoped to the one service it was bridging, not to the whole home network.
- **Run nginx-ingress on `hostNetwork` binding to the host's 80/443.** Cleanest client-IP story, fewest hops. **Rejected** because it couples ingress to a specific node (binding is not HA by itself), complicates NodePort scraping for metrics, and doesn't play well with the LAN being private anyway (we still need *some* bridge from the VPS).
- **LoadBalancer service type via MetalLB.** Would give ingress-nginx a LAN IP instead of a NodePort. **Rejected for now** because MetalLB would be a net-new component added solely for ingress, and the existing NodePort pattern already works and is scraped by the Prometheus observability stack in exactly the same way as ARC, Argo, and Flux. Can revisit if load-balancer semantics become valuable for multiple services.
- **Let's Encrypt ClusterIssuer up front.** Would require putting the Cloudflare API token inside the cluster as a Secret and seeding it via Ansible. **Rejected for now** because no workload currently requires a browser-trusted in-cluster cert — the VPS already holds the wildcard. The self-signed issuer covers internal needs (webhook trust, test certs). LE gets added when there's a consumer.

## Consequences

- **External traffic path is four hops:** Internet → VPS Caddy (TLS) → WG tunnel → R730xd iptables DNAT → K8s NodePort → DaemonSet pod → workload. Each hop is observable (Caddy logs, `wg show`, iptables counters, Prometheus ingress-nginx metrics, Alloy pod logs in Loki).
- **R730xd is on the critical path for external ingress.** If R730xd goes down, external traffic to any `*.bearflinn.com` subdomain stops — even though the cluster itself may still be healthy. This is acceptable for the lifespan of this design. If the WG tunnel and iptables rules ever migrate to a different host (e.g., the purchased off-the-shelf router from [ADR-021](021-off-the-shelf-router-tower-pc-as-worker.md)), the move is additive — no Flux manifest or Caddy config changes required, only the `ingress-tunnel` role re-running on a new target.
- **Client IP preservation relies on headers, not TCP.** `externalTrafficPolicy: Cluster` means kube-proxy may SNAT the source address before handing traffic to the ingress-nginx pod, so the real client address is only available via `X-Real-IP` / `X-Forwarded-For` from Caddy. `use-forwarded-headers: "true"` is set in the ingress-nginx config so logs, rate-limiting, and backend services see the right address.
- **WireGuard keys are rotated manually.** No automated rotation — the two keypairs live in `ansible/group_vars/all/vault.yml`. If either side is compromised, regenerate both keys, re-vault, re-run the `ingress-tunnel` role on both hosts.
- **Self-signed only means nothing in-cluster has browser-trusted TLS.** Workloads that need TLS-terminated endpoints internally (e.g., mTLS between services, dashboards over HTTPS) will use the self-signed issuer and require explicit trust bundles. A Let's Encrypt ClusterIssuer will be added the first time a workload actually needs it.
- **No NetBird on K8s nodes.** Operator access to cluster nodes is via the existing SSH / `k8s-control` jumpbox path, not via NetBird. This keeps the K8s nodes out of the mesh and reduces the admin-group's blast radius.

## References

- `ansible/roles/ingress-tunnel/` — WireGuard + iptables role (server/client variants).
- `kubernetes/infrastructure/ingress-nginx/helmrelease.yaml` — NodePort DaemonSet config.
- `kubernetes/infrastructure/cert-manager/cluster-issuer.yaml` — self-signed issuer.
- `ansible/roles/caddy/templates/Caddyfile-k8s.j2` — VPS wildcard catch-all and upstream header handling.
- ADR-021 (off-the-shelf router; Tower PC as worker) — supersedes ADR-001; future router may or may not take over R730xd's bridge role.
- ADR-014 (K8s cluster stack) — establishes nginx-ingress + VPS-side TLS termination.
