# OSS-sunset migrations

**Goal:** move off open-source dependencies that were sunset, relicensed, or otherwise no longer a good long-term bet, onto maintained replacements — without disrupting live services.

**Done:**

- **kv-cache: Redis → Valkey** — the cache slot is backend-agnostic and running Valkey ([ADR-056](../decisions/056-redis-to-valkey.md)).
- **Object store: MinIO → versitygw** — s3-hot (`:7070`) and s3-bulk (`:7072`) versitygw gateways are live on the R730xd and MinIO has been **fully removed** ([ADR-055](../decisions/055-s3-object-store-versitygw.md); runbooks [versitygw-deploy.md](../runbooks/versitygw-deploy.md), [versitygw-cli.md](../runbooks/versitygw-cli.md)).

**Remaining:**

- **Container builds: Kaniko → BuildKit** — deploy the BuildKit-based build path ([ADR-057](../decisions/057-container-builds-buildkit.md)). This is the last leg; once it lands, close this thread.

**Note:** the s3-bulk drive-enumeration blocker ([#119](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/119)) tracked here earlier is a storage-side racadm issue, not part of this migration — it lives as its own GitHub issue.
