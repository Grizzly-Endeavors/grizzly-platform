# versitygw — Deployment & Migration Runbook

Deployment/operations counterpart to [`versitygw-cli.md`](versitygw-cli.md) (which is "how to drive the tool"). This page is "how the stores are stood up here and how the MinIO→versitygw cutover runs" ([ADR-055](../decisions/055-s3-object-store-versitygw.md)).

## What's deployed

Two versitygw gateways run as Docker Compose services on the R730xd, each owned by a systemd unit (lifecycle + boot-ordering mount guard), modeled on the `r730xd-openbao` role:

| Instance | Role | Backing | S3 API | Admin | Metrics | Data root |
|---|---|---|---|---|---|---|
| **s3-hot** | `r730xd-s3-hot` | ZFS `tank/foundation/s3-hot` (recordsize 1M) | `10.0.0.200:7070` | `:7071` (container-internal) | `:9102` | `/mnt/zfs/foundation/s3-hot/{data,versions}` |
| **s3-bulk** | `r730xd-s3-bulk` | MergerFS+SnapRAID `/mnt/pool` | `10.0.0.200:7072` | `:7073` (container-internal) | `:9103` | `/mnt/pool/foundation/s3-bulk/{data,versions}` |

- **Coexistence:** these stand up *alongside* live MinIO (obs `:9000`, bulk `:9002`) on distinct ports and data dirs, so the stand-up disrupts nothing. MinIO is retired only after the cutover below.
- **IAM:** OpenBao Vault mode. Shared `versitygw` AppRole (policy `versitygw-iam`, CRUD+list on the `versitygw-iam` kv-v2 mount); each gateway namespaces its accounts by `--iam-vault-secret-storage-path` (`s3-hot` / `s3-bulk`). Root creds per instance in `secret/grizzly-platform/stores/{s3-hot,s3-bulk}`; AppRole creds in `secret/grizzly-platform/stores/versitygw-iam`. All three generated once by `setup-versitygw-iam.yml`.
- **Config:** 100% flags/env (versitygw is stateless) rendered into `/opt/foundation/<inst>/docker-compose.yml` (secrets in a sibling `versitygw.env`, 0600). No live reload — a config change is `systemctl restart foundation-<inst>`.
- **Metrics:** versitygw has no native Prometheus endpoint, so each gateway has a `statsd-exporter` sidecar (StatsD → Prometheus). The statsd→prom mapping (`/etc/versitygw/<inst>/statsd-mapping.yml`) starts as a pass-through — **tighten it once emitted metric names are observed**.

## Standing up from scratch (order matters)

```
# 1. ZFS dataset for the hot tier (adds tank/foundation/s3-hot):
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/r730xd-zfs.yml \
  --vault-password-file .vault_pass

# 2. OpenBao Vault-IAM backend (mount + policy + AppRole + root creds):
ansible-playbook ansible/playbooks/setup-versitygw-iam.yml --vault-password-file .vault_pass

# 3. Deploy the gateways:
ansible-playbook -i ansible/inventory/r730xd.yml ansible/playbooks/deploy-foundation-stores.yml \
  --tags s3-hot,s3-bulk --vault-password-file .vault_pass

# 4. Monitoring (statsd-exporter scrape jobs + /health blackbox probes).
#    Use the full inventory dir (not just r730xd.yml) — the prometheus template
#    reads the k8s_control_plane group from lab-nodes.yml:
ansible-playbook -i ansible/inventory ansible/playbooks/deploy-observability.yml \
  --tags prometheus --limit r730xd --vault-password-file .vault_pass
```

Health check after: `curl http://10.0.0.200:7070/health` and `:7072/health` → 200 (a 200 proves both the OpenBao AppRole auth and the startup `user.*` xattr validation passed — versitygw refuses to start if either fails).

## Provisioning a consumer account (per app)

Accounts are created against a running gateway's **admin port**, in-container (the admin port isn't LAN-published). Use the instance's root creds as admin creds:

```
AK=$(bao kv get -mount=secret -field=root_access_key grizzly-platform/stores/s3-hot)
SK=$(bao kv get -mount=secret -field=root_secret_key grizzly-platform/stores/s3-hot)
# userplus = may create/own its own buckets; user = may only use granted buckets
docker exec -e ADMIN_ACCESS_KEY_ID=$AK -e ADMIN_SECRET_KEY=$SK foundation-s3-hot \
  versitygw admin --er http://127.0.0.1:7071 create-user -a <access> -s <secret> -r userplus
docker exec -e ADMIN_ACCESS_KEY_ID=$AK -e ADMIN_SECRET_KEY=$SK foundation-s3-hot \
  versitygw admin --er http://127.0.0.1:7071 list-users
```

The account lands in OpenBao at `versitygw-iam/<storage-path>/<access>` (`bao kv list -mount=versitygw-iam s3-hot`). New (uncached) keys resolve immediately; *changes* to an existing key lag up to `--iam-cache-ttl` (120s).

## Cutover checklist (MinIO → versitygw, next phase)

Per-consumer this is an endpoint + bucket + credential swap (all consumers are S3-compatible), not an app rewrite. For each consumer:

1. Create its scoped account on the target gateway (above); mirror its bucket(s). Provisioning is scripted per consumer via `ansible/tasks/versitygw-provision-account.yml` (create-user `userplus` + create-bucket owned by it, through the admin port) — each `setup-<app>-stores.yml` includes it.
2. Migrate objects. **Use `rclone sync`, not `mc mirror`, for any bucket with large (multipart) objects.** `mc mirror` streams S3→S3 by piping a source GET straight into a destination multipart PUT; on the R730xd that truncated large registry blobs (`ContentLength=16777216 with Body length …`) and, because `mc mirror` aborts the whole run on the first error, it barely progressed. `rclone sync` retries per object and continues, so it converges. Recipe (env-config remotes, path-style):

   ```
   export RCLONE_CONFIG_SRC_TYPE=s3 RCLONE_CONFIG_SRC_PROVIDER=Minio  RCLONE_CONFIG_SRC_ENDPOINT=http://10.0.0.200:9002
   export RCLONE_CONFIG_DST_TYPE=s3 RCLONE_CONFIG_DST_PROVIDER=Other  RCLONE_CONFIG_DST_ENDPOINT=http://10.0.0.200:7072 RCLONE_CONFIG_DST_FORCE_PATH_STYLE=true
   # + RCLONE_CONFIG_{SRC,DST}_ACCESS_KEY_ID / _SECRET_ACCESS_KEY from OpenBao
   rclone sync src:<bucket> dst:<bucket> --transfers 8 --checkers 16 --retries 5 --low-level-retries 10
   rclone check src:<bucket> dst:<bucket> --one-way   # size parity; multipart ETags differ so some "hashes could not be checked" — size match is authoritative
   ```

   Small buckets (Nextcloud's 585 objects) copy fine with `mc mirror`. For a **live-written** store (the zot registry takes CI image pushes), run a final catch-up **immediately before** flipping the endpoint, and use `rclone copy` (not `sync`) for any catch-up *after* the flip so it never deletes newly-written destination objects.
3. Re-point the consumer's endpoint (`:9000`→`:7070`, `:9002`→`:7072`) + swap creds, then verify. For K8s consumers the flip lands on Flux reconcile after merge; MinIO stays up until PR 3 as a live rollback (revert the endpoint edit → old data still there).

Consumers to move (ADR-055): **hot (`:9000`→`:7070`)** — Loki (`r730xd-loki` defaults/template), Tempo (`r730xd-tempo`), Stalwart blob store (via Stalwart CLI + `setup-stalwart-stores.yml`). **bulk (`:9002`→`:7072`)** — zot registry (`kubernetes/infrastructure/registry/configmap.yaml`), Argo artifacts (`kubernetes/infrastructure/argo-workflows/helmrelease.yaml`), sccache, Nextcloud (manifests in the **lab-apps** repo). Each has an OpenBao path + (for k8s) an ExternalSecret `remoteRef.key` to re-point.

After all consumers are migrated and verified — **done 2026-07-06, this is the record of how**:

- Remove the MinIO roles/creds and the `minio-obs`/`minio-bulk` Prometheus scrape jobs. (Loki/Tempo keep the `observability/minio-client` account — only its backing engine moved.)
- Stop + remove the containers: `docker compose down` in `/opt/foundation/minio-{obs,bulk}`, then remove those compose dirs.
- Destroy the drained `tank/foundation/minio-obs` dataset (`zfs destroy -r`; s3-hot is its own dataset — no rename needed) and remove the MinIO bulk data dir (`rm -rf /mnt/pool/foundation/minio-bulk` — be precise, the sibling `s3-bulk` dir stays).
- Drop the `.minio.sys/` SnapRAID exclude (keep `.sgwtmp/`).
- Retire the OpenBao `stores/minio-obs` / `stores/minio-bulk` paths (`bao kv metadata delete`).
- **SnapRAID resync (do this manually — the nightly wrapper will abort):** removing the bulk data deletes thousands of files, tripping `snapraid-sync.sh`'s `DELETE_THRESHOLD=40`, and if a whole pool disk's tracked files vanish (here minio-bulk lived entirely on `d2`/`/mnt/data/bay2`) plain `snapraid sync` refuses with *"files … now missing or rewritten … use `--force-empty`"*. **Before forcing, verify the disk is mounted and its emptiness is the intended deletion** (`findmnt /mnt/data/bay2`; it should now hold the new `foundation/s3-bulk` data), *not* a failed mount — then `sudo snapraid --force-empty sync`.

## Troubleshooting

- **Gateway won't start / unit failed:** `systemctl status foundation-<inst>`, then `cd /opt/foundation/<inst> && docker compose up -d` to see the pull/run error. `docker logs foundation-<inst>`. Startup fails closed if OpenBao is sealed/unreachable (Vault IAM) or the backing FS lacks `user.*` xattr support.
- **`Couldn't parse PEM` at start:** the OpenBao CA must be passed as PEM *content* (`VGW_IAM_VAULT_SERVER_CERT`), not a path — the role inlines it from the host CA bundle; check that bundle exists.
- **Auth works but S3 request 403s right after a key change:** IAM cache (`--iam-cache-ttl`, 120s). Wait it out or restart.
- **Dependencies:** OpenBao (unsealed) for non-root IAM; the ZFS mount (s3-hot) / MergerFS mount (s3-bulk) — the systemd unit's `RequiresMountsFor` refuses to start onto a missing mount.
- **Recovery:** stateless — `systemctl restart foundation-<inst>` (or reschedule) loses nothing; all state is the backend dir + OpenBao.
