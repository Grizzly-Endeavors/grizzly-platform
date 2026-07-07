# MinIO → versitygw cutover (completed 2026-07-06)

Historical record of how the foundation object store moved off MinIO onto versitygw ([ADR-055](../../docs/decisions/055-s3-object-store-versitygw.md)). MinIO is fully retired; the live operations runbook is [`docs/runbooks/versitygw-deploy.md`](../../docs/runbooks/versitygw-deploy.md). This page is kept for the migration technique (the `rclone` recipe, the SnapRAID `--force-empty` caveat), not because any of it is still active.

## Coexistence during the migration

The two versitygw gateways were stood up *alongside* live MinIO (obs `:9000`, bulk `:9002`) on distinct ports and data dirs, so the stand-up disrupted nothing. MinIO was retired only after the cutover below.

## Cutover (per consumer)

Per-consumer this was an endpoint + bucket + credential swap (all consumers are S3-compatible), not an app rewrite. For each consumer:

1. Create its scoped account on the target gateway; mirror its bucket(s). Provisioning is scripted per consumer via `ansible/tasks/versitygw-provision-account.yml` (create-user `userplus` + create-bucket owned by it, through the admin port) — each `setup-<app>-stores.yml` includes it.
2. Migrate objects. **Use `rclone sync`, not `mc mirror`, for any bucket with large (multipart) objects.** `mc mirror` streams S3→S3 by piping a source GET straight into a destination multipart PUT; on the R730xd that truncated large registry blobs (`ContentLength=16777216 with Body length …`) and, because `mc mirror` aborts the whole run on the first error, it barely progressed. `rclone sync` retries per object and continues, so it converges. Recipe (env-config remotes, path-style):

   ```
   export RCLONE_CONFIG_SRC_TYPE=s3 RCLONE_CONFIG_SRC_PROVIDER=Minio  RCLONE_CONFIG_SRC_ENDPOINT=http://10.0.0.200:9002
   export RCLONE_CONFIG_DST_TYPE=s3 RCLONE_CONFIG_DST_PROVIDER=Other  RCLONE_CONFIG_DST_ENDPOINT=http://10.0.0.200:7072 RCLONE_CONFIG_DST_FORCE_PATH_STYLE=true
   # + RCLONE_CONFIG_{SRC,DST}_ACCESS_KEY_ID / _SECRET_ACCESS_KEY from OpenBao
   rclone sync src:<bucket> dst:<bucket> --transfers 8 --checkers 16 --retries 5 --low-level-retries 10
   rclone check src:<bucket> dst:<bucket> --one-way   # size parity; multipart ETags differ so some "hashes could not be checked" — size match is authoritative
   ```

   Small buckets (Nextcloud's 585 objects) copied fine with `mc mirror`. For a **live-written** store (the zot registry takes CI image pushes), a final catch-up ran **immediately before** flipping the endpoint, using `rclone copy` (not `sync`) for any catch-up *after* the flip so it never deletes newly-written destination objects.
3. Re-point the consumer's endpoint (`:9000`→`:7070`, `:9002`→`:7072`) + swap creds, then verify. For K8s consumers the flip landed on Flux reconcile after merge; MinIO stayed up as a live rollback (revert the endpoint edit → old data still there).

Consumers moved: **hot (`:9000`→`:7070`)** — Loki, Tempo, Stalwart blob store. **bulk (`:9002`→`:7072`)** — zot registry, Argo artifacts, sccache, Nextcloud (lab-apps repo). Each had an OpenBao path + (for k8s) an ExternalSecret `remoteRef.key` to re-point.

## Teardown (after all consumers migrated and verified)

- Removed the MinIO roles/creds and the `minio-obs`/`minio-bulk` Prometheus scrape jobs. (Loki/Tempo kept the `observability/s3-client` account — only its backing engine moved.)
- Stopped + removed the containers: `docker compose down` in `/opt/foundation/minio-{obs,bulk}`, then removed those compose dirs.
- Destroyed the drained `tank/foundation/minio-obs` dataset (`zfs destroy -r`; s3-hot is its own dataset — no rename needed) and removed the MinIO bulk data dir (`rm -rf /mnt/pool/foundation/minio-bulk`, leaving the sibling `s3-bulk` dir).
- Dropped the `.minio.sys/` SnapRAID exclude (kept `.sgwtmp/`).
- Retired the OpenBao `stores/minio-obs` / `stores/minio-bulk` paths (`bao kv metadata delete`).
- **SnapRAID resync (manual — the nightly wrapper would abort):** removing the bulk data deleted thousands of files, tripping `snapraid-sync.sh`'s `DELETE_THRESHOLD=40`; because a whole pool disk's tracked files vanished (minio-bulk lived entirely on `d2`/`/mnt/data/bay2`) plain `snapraid sync` refused with *"files … now missing or rewritten … use `--force-empty`"*. After verifying the disk was mounted and its emptiness was the intended deletion (`findmnt /mnt/data/bay2` — it now holds the new `foundation/s3-bulk` data), a `sudo snapraid --force-empty sync` cleared it.
