# 038: Nextcloud on foundation stores, S3 primary storage, and Authentik SSO

**Date:** 2026-06-29
**Status:** accepted
**Relates to:** [ADR-033](033-central-identity-authentik.md), [ADR-037](037-authentik-config-as-code-blueprints.md), [ADR-024](024-platform-secrets-on-openbao.md), [ADR-003](003-foundation-stores-on-r730xd.md)

## Context

Nextcloud was stood up the day before this ADR as a personal/lab app (manifests in the `lab-apps` repo, reconciled by the `personal-apps` Flux Kustomization). Its first cut was deliberately self-contained: a bundled per-app PostgreSQL `Deployment` on an `iscsi-zfs-retain` PVC, no Redis (file-based locking), a 20Gi `iscsi-zfs-retain` PVC as primary file storage, and a per-app `pg_dumpall` backup CronJob. That shape was the fast path to "it boots," but it does not match how the platform is meant to run now that real people will use the instance:

- The R730xd already runs **foundation stores** (ADR-003): PostgreSQL, Redis, and MinIO (bulk). Authentik (ADR-033) already consumes the foundation Postgres + Redis. Running a second throwaway Postgres pod for Nextcloud duplicates a store the platform already operates and backs up.
- A fixed 20Gi file volume on the ZFS hot tier is the wrong tier and the wrong ceiling for a multi-user file-sync workload. The MinIO **bulk** instance (MergerFS + SnapRAID parity, capacity tier) is where bulk user files belong.
- Authentik is now the platform IdP with config-as-code (ADR-037), but nothing consumed it yet. Nextcloud is the natural first integration.

The original `db.yaml` carried an explicit rationale for *not* sharing the foundation Postgres: keep the lab app's blast radius and credentials isolated, and don't hand a lab app the foundation superuser password. This ADR reverses that for Nextcloud, and records why that reversal is safe.

## Decision

**Re-platform Nextcloud onto the foundation stores, use MinIO as S3 primary storage, and wire SSO through Authentik via a blueprint.** Because the day-old instance held only the default `admin` account and ~67MB of skeleton files, this is done as a **clean re-provision**, not a data migration.

### 1. Foundation Postgres, dedicated role (not superuser)

The bundled `nextcloud-db` Deployment/PVC/Service is removed. A dedicated `nextcloud` login role owns a dedicated `nextcloud` database on the foundation Postgres (`10.0.0.200:5432`), provisioned by `ansible/playbooks/setup-nextcloud-stores.yml` — the same pattern `setup-authentik.yml` uses. The app only ever receives its own scoped role credentials; it never sees the `postgres` superuser password. The foundation `pg_dumpall` backup already covers the new database, so the per-app backup CronJob + PVC are removed too.

This addresses the original `db.yaml` isolation concern: blast radius is contained by a per-app role with no superuser grant, exactly as Authentik already does. The remaining shared-instance risk (one Postgres for multiple consumers) is an accepted, deliberate trade — it's the foundation-store model, and the instance is sized and backed up for it.

### 2. Redis for caching + transactional file locking

Nextcloud points at the foundation Redis (`10.0.0.200:6379`) on a **dedicated DB index `2`** (Authentik holds index 1) for `memcache.distributed` and `memcache.locking`, with `memcache.local` on APCu. This replaces fragile file-based locking — important once multiple users hit the instance concurrently. The Redis block (including `dbindex`) is set through a `nextcloud.configs` `config.php` snippet rather than the image's `REDIS_HOST*` autoconfig, because the autoconfig does not expose the DB index.

### 3. S3 (MinIO bulk) as primary object storage

All user files live in a `nextcloud` bucket on the MinIO **bulk** instance (`10.0.0.200:9002`, path-style, non-TLS in-LAN), configured as Nextcloud **primary** object storage (`OBJECTSTORE_S3_*`). Only file *metadata* stays in Postgres; the app's small install/config/custom-apps tree stays on a modest `iscsi-zfs-retain` PVC. A scoped MinIO user (policy `nextcloud-rw`, limited to the `nextcloud` bucket) is provisioned by the same Ansible playbook — the bucket root credentials are not handed to the app.

Trade-offs accepted:

- **Tier:** bulk is the MergerFS/SnapRAID capacity tier (parity-protected, not mirrored, slower than ZFS hot). Correct for bulk file storage; the latency is acceptable for sync/share.
- **Server-side encryption** module is incompatible with object primary storage — not used.
- Alternative (S3 as an *external storage* mount with files kept on the local PVC) was rejected: it caps growth at the PVC size and leaves the main store on the wrong tier. Primary storage is the point.

### 4. Authentik SSO via blueprint (first secret-bearing blueprint)

A blueprint (`kubernetes/infrastructure/authentik/blueprints/nextcloud.yaml`) registers a confidential OAuth2/OIDC provider + application + a `groups` scope mapping. This is the first **secret-bearing** blueprint anticipated by ADR-037: the client secret is injected into the Authentik worker via `global.env` (`AUTHENTIK_NEXTCLOUD_CLIENT_*`) and referenced with `!Env`, never committed. On the Nextcloud side, the official **`user_oidc`** app is installed and its provider registered idempotently by a chart `post-installation` hook. The local password form is **kept** alongside the SSO button, so the `admin` account remains a break-glass login if Authentik is unavailable.

Group-claim provisioning mirrors Authentik groups into Nextcloud; promoting an SSO user to a Nextcloud *administrator* is a deliberate one-time `occ` action rather than an automatic claim mapping (avoids a misconfigured claim silently minting admins).

### 5. Secret layout

One OpenBao path holds the foundation grants Ansible provisions and ESO consumes: `secret/grizzly-platform/stores/nextcloud` (`db_password`, `s3_access_key`, `s3_secret_key`). It lives under `grizzly-platform/` — not `lab-apps/` — because the `ansible-platform-read` AppRole policy is scoped to `grizzly-platform/*`; Nextcloud's K8s ExternalSecret reads it cross-domain (ESO's `eso-platform-read` allows it). The OIDC client credentials live under `secret/grizzly-platform/platform/authentik` (`oidc_nextcloud_client_id`, `oidc_nextcloud_client_secret`) — Authentik owns the client registration, and both the Authentik and Nextcloud ExternalSecrets read those two keys, giving the OIDC contract a single source of truth. App-only secrets (first-install admin creds, the `db-username` literal) stay under `secret/lab-apps/nextcloud/app`.

## Consequences

- Nextcloud's durable state is now Postgres rows + MinIO objects on the R730xd, both already backed up by foundation tooling. The app PVC holds only re-creatable install/config.
- The cross-repo coupling is explicit: `grizzly-platform` owns the foundation provisioning (Ansible) + the Authentik blueprint; `lab-apps` owns the app manifests. A future app reusing the foundation stores follows the same split.
- **Backchannel hairpin:** Nextcloud reaches Authentik's OIDC endpoints via the public `sso.bearflinn.com` URL (issuer must match), which round-trips out to the Hetzner VPS and back per login. Acceptable for login-frequency traffic; an in-cluster DNS override is a possible later optimization.
- **HA is not addressed.** A single generously-resourced replica with `Recreate` is retained: the app's `/var/www/html` PVC is RWO, so multi-replica would need RWX there. Vertical sizing first; horizontal scale is a separate decision.
- Reversing the `db.yaml` isolation stance sets the precedent that lab apps *may* ride the foundation Postgres **with a dedicated per-app role**. Apps that genuinely need hard isolation should still bundle their own DB and say so.
