# Ansible

Configuration management for active infrastructure. Previous K8s cluster and tower-pc configs are in `archive/pre-migration-2026/ansible/`.

> **IP addresses:** Authoritative values are in `group_vars/all/network.yml`. IPs in this README are for quick reference only.

## Playbooks

| Playbook | Target | Purpose |
|----------|--------|---------|
| `setup-proxy-vps.yml` | proxy-vps | Caddy reverse proxy on Hetzner VPS (DNS-01 TLS, UDP forwarding) |
| `setup-r730xd.yml` | r730xd | R730xd baseline setup (hostname, static IP, packages, Docker, monitoring) |
| `r730xd-storage.yml` | r730xd | MergerFS + SnapRAID stack — bay resolution, partitioning, pool, parity, NFS exports |
| `r730xd-zfs.yml` | r730xd | ZFS raidz1 pool + service datasets for latency-sensitive workloads |
| `deploy-foundation-stores.yml` | r730xd | PostgreSQL 16, kv-cache (Valkey), MinIO Obs (ZFS), MinIO Bulk (MergerFS) as Docker Compose services |
| `deploy-observability.yml` | r730xd | Prometheus, Alertmanager, Loki, Tempo, Grafana, Alloy on ZFS pool |
| `create-staging-vm.yml` | r730xd | Create Debian 13 staging VM via libvirt for critical services during migration |
| `deploy-staging-services.yml` | staging-vm | Deploy web services (landing-page, caz-portfolio, resume-site) to staging VM |
| `setup-claude-user.yml` | various | Restricted read-only SSH access for Claude Code troubleshooting |

## Roles

| Role | Used by | Purpose |
|------|---------|---------|
| `caddy` | setup-proxy-vps.yml | Install Caddy with xcaddy DNS provider plugins |
| `r730xd-storage-prep` | r730xd-storage.yml | Discover HDDs via iDRAC, partition GPT, format ext4, mount by bay |
| `r730xd-mergerfs` | r730xd-storage.yml | Pool data drives into unified mount at `/mnt/pool` |
| `r730xd-snapraid` | r730xd-storage.yml | Parity protection + automated sync/scrub via systemd timers |
| `r730xd-nfs-server` | r730xd-storage.yml | NFS exports of MergerFS pool for K8s PVCs |
| `r730xd-zfs` | r730xd-zfs.yml | ZFS raidz1 pool + per-service datasets with tuned recordsize |
| `r730xd-vm-host` | create-staging-vm.yml | KVM/libvirt + bridged networking on R730xd |
| `r730xd-postgres` | deploy-foundation-stores.yml | PostgreSQL 16 on Docker (host network, daily pg_dump backup) |
| `r730xd-kv-cache` | deploy-foundation-stores.yml | Key-value / cache store (Valkey) on Docker (host network, AOF+RDB persistence) |
| `r730xd-minio-obs` | deploy-foundation-stores.yml | MinIO S3 (observability) — hot instance on ZFS for Loki/Tempo |
| `r730xd-minio-bulk` | deploy-foundation-stores.yml | MinIO S3 (bulk) — cold instance on MergerFS for registry/artifacts |
| `r730xd-prometheus` | deploy-observability.yml | Prometheus + Alertmanager (metrics collection, alerting) |
| `r730xd-loki` | deploy-observability.yml | Loki log aggregation (S3 backend via MinIO Obs) |
| `r730xd-tempo` | deploy-observability.yml | Tempo distributed tracing (S3 backend via MinIO Obs) |
| `r730xd-grafana` | deploy-observability.yml | Grafana dashboards (Postgres backend, provisioned data sources) |
| `r730xd-alloy` | deploy-observability.yml | Grafana Alloy log collector (Docker socket → Loki) |
| `monitoring-base` | setup-r730xd.yml | Node exporter, IPMI exporter, smartd |
| `monitoring-checks` | setup-r730xd.yml | Custom health check scripts (SMART, disks, services, NFS, SnapRAID) |
| `claude-user` | setup-claude-user.yml | Restricted read-only SSH + sudo for troubleshooting |

## Storage Architecture

The R730xd has two storage tiers:

| Tier | Backing | Mount | Workload |
|------|---------|-------|----------|
| Hot | ZFS raidz1 (3×2TB, ~3.6TB usable) | `/mnt/zfs` | Continuous writers: databases, metrics, logs, traces |
| Cold | MergerFS + SnapRAID (5×3TB data + 2×4TB parity) | `/mnt/pool` | Bulk: container registry, build artifacts, NFS for K8s |

Continuous-write services run on ZFS to avoid SnapRAID sync issues (dirty files, long syncs). Bulk write-once-read-many data stays on MergerFS where SnapRAID provides parity protection.

## Foundation Data Stores

PostgreSQL, kv-cache (Valkey), and two MinIO instances run on the R730xd as Docker Compose services, not in K8s. K8s nodes are diskless — all stateful workloads belong on the storage server. See [ADR-003](../docs/decisions/003-foundation-stores-on-r730xd.md) for design rationale.

### Endpoints

| Service | Address | Data Directory | Storage Tier |
|---------|---------|----------------|--------------|
| PostgreSQL 16 | `postgresql://postgres:<password>@<r730xd_ip>:5432/` | `/mnt/zfs/foundation/postgres/data` | ZFS (8K recordsize) |
| kv-cache (Valkey) | `redis://:<password>@<r730xd_ip>:6379` | `/mnt/zfs/foundation/kv-cache/data` | ZFS (64K recordsize) |
| MinIO Obs API | `http://<r730xd_ip>:9000` | `/mnt/zfs/foundation/minio-obs/data` | ZFS (1M recordsize) |
| MinIO Obs Console | `http://<r730xd_ip>:9001` | — | — |
| MinIO Bulk API | `http://<r730xd_ip>:9002` | `/mnt/pool/foundation/minio-bulk/data` | MergerFS |
| MinIO Bulk Console | `http://<r730xd_ip>:9003` | — | — |

### Connecting from K8s workloads

K8s pods reach these services at `<r730xd_ip>:<port>`. Use Kubernetes Secrets or ConfigMaps to pass connection strings — do not hardcode credentials in manifests.

```yaml
# Example: Postgres connection in a K8s deployment
env:
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: foundation-postgres
        key: url
        # value: postgresql://myapp:password@<r730xd_ip>:5432/myapp
```

### Connecting from staging VM services

The staging VM (<staging_vm_ip>) reaches the R730xd host at its bridge IP. Pass connection strings via Docker Compose environment variables, same as existing staging services.

### Operations

```bash
# Deploy all foundation stores
ansible-playbook -i ansible/inventory/r730xd.yml \
  ansible/playbooks/deploy-foundation-stores.yml \
  --vault-password-file .vault_pass -v

# Deploy a single service
ansible-playbook -i ansible/inventory/r730xd.yml \
  ansible/playbooks/deploy-foundation-stores.yml \
  --vault-password-file .vault_pass --tags postgres -v

# Check service status on R730xd
docker compose -f /opt/foundation/postgres/docker-compose.yml ps
docker compose -f /opt/foundation/kv-cache/docker-compose.yml ps
docker compose -f /opt/foundation/minio-obs/docker-compose.yml ps
docker compose -f /opt/foundation/minio-bulk/docker-compose.yml ps

# View logs
docker logs foundation-postgres --tail 50
docker logs foundation-kv-cache --tail 50
docker logs minio-obs --tail 50
docker logs minio-bulk --tail 50

# Health checks
docker exec foundation-postgres pg_isready -U postgres
docker exec foundation-kv-cache valkey-cli -a <password> ping
curl http://<r730xd_ip>:9000/minio/health/live   # MinIO Obs
curl http://<r730xd_ip>:9002/minio/health/live   # MinIO Bulk
```

### Creating application databases

The playbook deploys Postgres with the superuser only. Create per-application databases as needed:

```bash
docker exec -it foundation-postgres psql -U postgres

# Then in psql:
CREATE USER myapp WITH PASSWORD 'app-password';
CREATE DATABASE myapp OWNER myapp;
```

Store application credentials in Ansible Vault and pass them to K8s via Secrets.

### Backup

- **PostgreSQL:** Daily `pg_dumpall` at 02:00 → `/mnt/zfs/foundation/postgres/backup/`, 7-day retention. Cron managed by Ansible.
- **kv-cache (Valkey):** AOF (`appendfsync everysec`) + RDB snapshots. Data in `/mnt/zfs/foundation/kv-cache/data/`. Copy `dump.rdb` off-host for backup.
- **MinIO Obs:** Loki/Tempo data with 30-day retention. ZFS snapshots available for point-in-time recovery.
- **MinIO Bulk:** Container images and build artifacts on MergerFS with SnapRAID parity. `mc mirror` for offsite replication is a future enhancement.

### Configuration tuning

Default values are in each role's `defaults/main.yml`. Override via `--extra-vars` or by adding variables to the R730xd inventory.

| Variable | Default | Purpose |
|----------|---------|---------|
| `postgres_version` | `"16"` | Postgres Docker image tag |
| `postgres_shared_buffers` | `"2GB"` | Shared memory for caching |
| `postgres_max_connections` | `100` | Max concurrent connections |
| `kv_cache_maxmemory` | `"2gb"` | Memory limit before eviction |
| `kv_cache_maxmemory_policy` | `"allkeys-lru"` | Eviction strategy |
| `minio_obs_api_port` | `9000` | MinIO Obs S3 API port |
| `minio_obs_console_port` | `9001` | MinIO Obs web console port |
| `minio_bulk_api_port` | `9002` | MinIO Bulk S3 API port |
| `minio_bulk_console_port` | `9003` | MinIO Bulk web console port |

## Observability Stack

Prometheus, Loki, Tempo, Grafana, and Alloy run on the R730xd as Docker Compose services under `/opt/observability/`. Data persisted on the ZFS pool under `/mnt/zfs/observability/`. Loki and Tempo use MinIO Obs as their S3 backend. See [ADR-004](../docs/decisions/004-observability-stack-on-r730xd.md) for design rationale.

### Endpoints

| Service | Address | Data Directory | Storage Tier |
|---------|---------|----------------|--------------|
| Prometheus | `http://<r730xd_ip>:9090` | `/mnt/zfs/observability/prometheus/data` | ZFS (128K recordsize) |
| Alertmanager | `http://<r730xd_ip>:9093` | `/mnt/zfs/observability/prometheus/alertmanager` | ZFS |
| Loki | `http://<r730xd_ip>:3100` | `/mnt/zfs/observability/loki/data` | ZFS (128K recordsize) |
| Tempo API | `http://<r730xd_ip>:3200` | `/mnt/zfs/observability/tempo/data` | ZFS (128K recordsize) |
| Tempo OTLP gRPC | `<r730xd_ip>:4317` | — | — |
| Tempo OTLP HTTP | `<r730xd_ip>:4318` | — | — |
| Grafana | `http://<r730xd_ip>:3000` | `/mnt/zfs/observability/grafana/data` | ZFS (128K recordsize) |

### Operations

```bash
# Deploy entire observability stack
ansible-playbook -i ansible/inventory/r730xd.yml \
  ansible/playbooks/deploy-observability.yml \
  --vault-password-file .vault_pass -v

# Deploy a single service
ansible-playbook -i ansible/inventory/r730xd.yml \
  ansible/playbooks/deploy-observability.yml \
  --vault-password-file .vault_pass --tags grafana -v

# Check service status on R730xd
docker compose -f /opt/observability/prometheus/docker-compose.yml ps
docker compose -f /opt/observability/loki/docker-compose.yml ps
docker compose -f /opt/observability/grafana/docker-compose.yml ps

# View logs
docker logs observability-prometheus --tail 50
docker logs observability-loki --tail 50
docker logs observability-grafana --tail 50

# Health checks
curl http://<r730xd_ip>:9090/-/healthy
curl http://<r730xd_ip>:3100/ready
curl http://<r730xd_ip>:3000/api/health
```

## Inventory

| File | Hosts |
|------|-------|
| `proxy-vps.yml` | Hetzner VPS (SSH port 2222) |
| `r730xd.yml` | Dell R730xd storage server (<r730xd_ip>) |
| `lab-nodes.yml` | All lab machines (K8s cluster, standalone, staging) |

## Vault secrets

Secrets are in `group_vars/all/vault.yml` (encrypted). See `vault.yml.example` for the full list. The vault password file (`.vault_pass`) must exist at the repo root.

```bash
# View vault contents
ansible-vault view ansible/group_vars/all/vault.yml --vault-password-file .vault_pass

# Edit vault
ansible-vault edit ansible/group_vars/all/vault.yml --vault-password-file .vault_pass
```

## Running playbooks

```bash
# All playbooks use vault — .vault_pass must exist in repo root
ansible-playbook -i ansible/inventory/proxy-vps.yml ansible/playbooks/setup-proxy-vps.yml -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/setup-r730xd.yml -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/r730xd-storage.yml --vault-password-file .vault_pass -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/r730xd-zfs.yml --vault-password-file .vault_pass -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/deploy-foundation-stores.yml --vault-password-file .vault_pass -v
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/deploy-observability.yml --vault-password-file .vault_pass -v
```
