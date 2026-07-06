# Grizzly Platform

Self-hosted infrastructure for Grizzly Endeavors projects. Bare-metal IaC on repurposed enterprise and consumer hardware. Workloads run on a four-node Kubernetes cluster (one control plane, three workers). Storage is served by a Dell R730xd over iSCSI (ZFS raidz1) and NFS (MergerFS + SnapRAID). Apps deploy via Flux GitOps. Public ingress terminates at a Hetzner VPS and routes through a dedicated WireGuard tunnel to the cluster.

**Traffic flow:** Internet → Hetzner VPS (Caddy wildcard TLS) → dedicated WireGuard tunnel → R730xd iptables DNAT → K8s NodePort → ingress-nginx → app ([ADR-019](docs/decisions/019-ingress-and-tls-termination.md))

## Infrastructure

- **K8s cluster** — v1.33.10. `dell-inspiron-15` (control plane) + `quanta`, `intel-nuc`, `optiplex` (workers). Cilium CNI, Flux GitOps, democratic-csi for storage, cert-manager, ingress-nginx, ARC v2 runners, Argo Workflows, in-cluster OCI registry. See [docs/k8s-cluster-standup.md](docs/k8s-cluster-standup.md).
- **Dell R730xd** — Storage server (Debian 13, 32 GB ECC, 14 drive bays). Two storage tiers: ZFS raidz1 for latency-sensitive services (Postgres, kv-cache, MinIO Obs, Prometheus, Loki, Tempo, Grafana), MergerFS + SnapRAID for bulk (MinIO Bulk, NFS for K8s PVCs). Also terminates the VPS → home ingress WireGuard tunnel.
- **Hetzner VPS** — Caddy reverse proxy with per-domain wildcard TLS (`*.grizzly-endeavors.com` for platform services, `*.bearflinn.com` for personal apps — both via Cloudflare DNS-01). Routes to the cluster through the WG tunnel.

Full machine list with specs in [docs/hardware.md](docs/hardware.md). Network topology in [docs/network.md](docs/network.md).

### Pending work

Not blocking day-to-day operations; tracked in ADRs and `docs/hardware.md`:

- Tower PC joins the cluster as a plain worker ([ADR-021](docs/decisions/021-off-the-shelf-router-tower-pc-as-worker.md))
- GPU inference host (standalone, off-cluster — see `docs/hardware.md`)
- Off-the-shelf router to replace Xfinity gateway — unblocks VLANs ([docs/exploration/network-vlans.md](docs/exploration/network-vlans.md))
- Jumpbox imaging (AMD C60 mini PC)
- UPS battery replacement ([ADR-006](docs/decisions/006-proceed-without-ups.md))

## Repository Structure

```
ansible/           Playbooks, roles, and inventory for active infrastructure
kubernetes/        K8s manifests (Flux-managed apps + infrastructure)
docker/            Docker Compose projects on the R730xd (foundation stores, observability)
configs/           Machine-specific configs (jumpbox desktop, R730xd preseed, etc.)
scripts/           Shell utilities (cluster standup, jumpbox image building)
docs/              Architecture, operations, and decision records
archive/           Historical configs (pre-2026 repo state + 2026 migration record)
```

## Quick Start

```bash
# All playbooks decrypt secrets via .vault_pass (git-ignored)

# R730xd storage server
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/setup-r730xd.yml -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/r730xd-storage.yml --vault-password-file .vault_pass -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/deploy-foundation-stores.yml --vault-password-file .vault_pass -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/deploy-observability.yml --vault-password-file .vault_pass -v

# Hetzner VPS proxy
ansible-playbook -i ansible/inventory/proxy-vps.yml ansible/playbooks/setup-proxy-vps.yml -v
```

## Documentation

| Document | Contents |
|----------|----------|
| [docs/README.md](docs/README.md) | Documentation index |
| [docs/hardware.md](docs/hardware.md) | Machine inventory, specs, live roles |
| [docs/network.md](docs/network.md) | Network topology, IPs, tunnels |
| [docs/k8s-cluster-standup.md](docs/k8s-cluster-standup.md) | How the cluster was built; smoke tests |
| [docs/monitoring-integration.md](docs/monitoring-integration.md) | Observability stack architecture |
| [docs/nodeport-allocation.md](docs/nodeport-allocation.md) | K8s NodePort registry |
| [docs/decisions/](docs/decisions/) | ADRs — why things are the way they are |
| [archive/](archive/) | Pre-2026 configs and the 2026 migration record |

## License

MIT
