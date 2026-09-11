# ADR-076: Vikunja on the Foundation Stores, with Authentik as the Only Login

**Date:** 2026-09-11
**Status:** Accepted
**Relates to:** [ADR-003](003-foundation-stores-on-r730xd.md) (foundation stores), [ADR-025](025-personal-apps-in-separate-repo.md) (personal apps in lab-apps), [ADR-033](033-central-identity-authentik.md) (Authentik), [ADR-037](037-authentik-config-as-code-blueprints.md) (blueprints), [ADR-050](050-stalwart-mail-server.md) (Stalwart), [ADR-055](055-s3-object-store-versitygw.md) (versitygw), [ADR-072](072-immich-on-foundation-stores-and-sso.md) (Immich, the nearest precedent)

## Context

Vikunja is a self-hosted task and to-do app — one Go binary serving both the API and the web UI, shipped as the `vikunja/vikunja` image. It runs as a lab app at `todo.grizzly-endeavors.com`, the personal-app class ADR-025 puts in lab-apps.

It fits the platform more easily than Immich did. It needs PostgreSQL with no extensions and no superuser, runs its own schema migrations at startup, stores attachments in S3 natively, and reads its entire configuration — OIDC providers included — from environment variables. That leaves four choices to settle: where attachments live, whether it uses the shared cache, how people sign in, and whether it sends mail.

## Decision

**Relational state is a plain non-superuser role owning its own `vikunja` database on the foundation PostgreSQL**, provisioned by `setup-vikunja-stores.yml` — the standard per-app pattern.

**Attachments and project backgrounds go to a `vikunja` bucket on s3-bulk**, through Vikunja's own S3 backend with path-style addressing. With that, Vikunja has no volume in the cluster at all. s3-bulk rather than s3-hot because these are write-once user files read on demand, the same shape as Nextcloud's files, which already live there; s3-hot stays for latency-sensitive working sets.

**Vikunja does not use the kv-cache.** Its key-value store holds caches and metric counters, nothing durable, and it runs as a single replica replaced by `Recreate`, so the in-memory default is correct. Pointing it at Valkey would add a startup dependency on a shared, LRU-evicting store in exchange for warm caches across restarts. Running more than one replica is what would change this: at that point `keyvalue.type: redis` on a free kv-cache index keeps the replicas consistent.

**Authentik is the only way in.** `auth.local.enabled` and `service.enableregistration` are both off, so every Vikunja account traces back to an Authentik invitation. This departs from Nextcloud and Immich, which keep local password login as break-glass. Vikunja holds nothing that has to be reachable during an Authentik outage, and a local password would be a second credential set living outside the invite gate. Any enrolled `grizzly-users` member can sign in; there are no policy bindings, since sharing projects between people is much of the point.

**Vikunja sends mail as its own send-only Stalwart account, `vikunja@grizzly-endeavors.com`**, for due-date reminders and share/assignment notifications. It is provisioned by `configure-stalwart.yml` like `noreply` and `gary`, with its password on the `platform-stalwart` item, so the account can be revoked without touching any other sender.

**All configuration is environment variables in the Deployment**, secrets included through `secretKeyRef`. There is no config file and no render step, unlike Immich, whose OAuth settings can only come from a file.

**There is no application metrics scrape.** Vikunja's `/api/v1/metrics` reports aggregate counts (users, projects, tasks), which say nothing about whether the service is healthy, so it does not earn a NodePort and a scrape target. Health is a blackbox probe of `https://todo.grizzly-endeavors.com/health` through the whole public path (VPS Caddy, WireGuard tunnel, ingress-nginx, the pod), which raises the existing `EndpointDown` critical alert. Logs reach Loki through the Alloy DaemonSet with no configuration.

## Consequences

- **The workload is stateless in the cluster.** Recovery is a reschedule. Backups come from the foundation side: the nightly `pg_dumpall` covers the `vikunja` database, and SnapRAID parity covers the s3-bulk bucket.
- **An Authentik outage is a Vikunja sign-in outage.** The break-glass is a PR setting `VIKUNJA_AUTH_LOCAL_ENABLED=true`, plus Vikunja's `user` CLI inside the pod to set a password.
- **CalDAV clients authenticate with Vikunja API tokens**, because no account has a password.
- **A drifted SMTP password can ban mail for the whole house.** Submission hairpins through the VPS, so Stalwart sees each failed login as coming from the household's public IP, and its per-IP auto-ban trips after repeated failures. The password has one source, read both by `configure-stalwart.yml` and by Vikunja's ExternalSecret. After rotating it, re-run the play before Vikunja picks up the new value. The unban procedure is in [integration/mail.md](../integration/mail.md).
- **Vikunja ships roughly monthly, usually with security fixes**, so the pinned image tag needs regular bumps rather than set-and-forget.
- **Dependencies, in order of blast radius:** foundation Postgres (Vikunja will not start without it), Authentik (no new sign-ins), s3-bulk (attachment upload and download fail, everything else works), Stalwart (reminder mail stops). First step when it misbehaves: `kubectl -n vikunja logs deploy/vikunja`, then `vikunja doctor` inside the pod, which checks the database, file storage and mailer config.

## Alternatives Considered

- **Local login kept as break-glass**, matching Nextcloud and Immich. **Rejected** for the reasons above. A PR can re-enable it in minutes if that is ever needed.
- **Attachments on an NFS PVC.** **Rejected**: Vikunja speaks S3 natively, so a POSIX volume would be the ADR-003 carve-out without the reason that justifies it.
- **Attachments on s3-hot.** **Rejected**: these files are neither latency-sensitive nor a hot working set.
- **kv-cache (Valkey) as the key-value store.** Matches Authentik, Nextcloud and Immich, and is ready for more than one replica. **Rejected for now** — see the decision above.
- **A community Helm chart.** **Rejected** for the same reason as ADR-072 and ADR-065: it would wrap one Deployment in a second version axis to track, with every bundled store disabled anyway.

## References

- `ansible/playbooks/setup-vikunja-stores.yml` — database, role and bucket provisioning.
- `ansible/playbooks/configure-stalwart.yml` — the `vikunja` submission account.
- `kubernetes/infrastructure/authentik/blueprints/vikunja.yaml` — the OIDC provider and application.
- `Grizzly-Endeavors/lab-apps` `apps/vikunja/` — the workload manifests.
- [Vikunja config options](https://vikunja.io/docs/config-options/) and [OpenID](https://vikunja.io/docs/openid/) documentation.
