# ADR-078: Custom Caddy Build Lives Off the Package Path

**Date:** 2026-09-26
**Status:** Accepted
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md) (VPS Caddy terminates public TLS). Part of [#244](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/244).

## Context

Wildcard certificates on the proxy VPS use the Cloudflare DNS-01 module, so the `caddy` role builds Caddy with `xcaddy` when `caddy_dns_provider` is set. That binary has to keep serving after routine package upgrades. The `caddy` apt package owns `/usr/bin/caddy` and the unit file's `ExecStart` / `ExecReload`. Replacing the packaged binary means the next upgrade (unattended or manual) puts the stock build back, the Caddyfile fails to load, and every site behind that instance stops.

## Decision

Install the DNS-plugin build at **`/usr/local/bin/caddy`** and point the service at it with a systemd drop-in (`/etc/systemd/system/caddy.service.d/override.conf`).

- The drop-in clears `ExecStart`, `ExecReload`, and `ExecStartPre`, then repeats the packaged unit's arguments with `/usr/local/bin/caddy` and the role's config path. Clearing is required: systemd appends drop-in commands instead of replacing them.
- The same drop-in still carries the DNS provider token. It is mode `0600`.
- The custom binary's version tracks the installed `caddy` package (`dpkg-query`), unless `caddy_version` pins one. A role run rebuilds only when `/usr/local/bin/caddy` is missing, lacks the DNS module, does not match that version, or `caddy_force_rebuild` is true. The copy and the drop-in notify the restart handler, so a run that changes nothing does not restart Caddy.
- When `/usr/bin/caddy` no longer matches the package checksum, the role reinstalls the package with `Dpkg::Options::=--force-confold` so the packaged binary comes back and the local Caddyfile stays. `/usr/bin/caddy.backup` is removed. The drop-in is in place before that reinstall, so a package-triggered restart already uses the custom binary.

## Alternatives Considered

- **`dpkg-divert` on `/usr/bin/caddy`.** Keeps a single path, but the package and the custom build still share it, and the divert has to be maintained for the life of the host. A drop-in leaves the package file untouched.
- **Official download API** (`caddyserver.com/api/download?...&p=github.com/caddy-dns/<provider>`) instead of `xcaddy`. Avoids a Go toolchain on the host. Rejected for this change: the role already builds whatever `caddy_dns_provider` is set to, and the outage is the install path, not the build tool.
- **Keep writing the custom build over `/usr/bin/caddy`.** That is the failure mode this decision closes.

## Consequences

- `apt upgrade` of `caddy` can replace `/usr/bin/caddy` only. The running service stays on `/usr/local/bin/caddy`.
- The custom binary picks up a package version bump the next time the role runs, and that run restarts Caddy once. It does not float to an unpinned upstream "latest" on every run.
- Building still needs `golang-go` and `git` on the host, and only when a rebuild is actually required.
- `systemctl show caddy -p ExecStart` and `/proc/<pid>/exe` both point at `/usr/local/bin/caddy`. `dpkg --verify caddy` does not report `/usr/bin/caddy`.

## References

- `ansible/roles/caddy/tasks/build-xcaddy.yml` — custom build at `/usr/local/bin/caddy`.
- `ansible/roles/caddy/templates/caddy-override.conf.j2` — service drop-in.
- `ansible/playbooks/setup-proxy-vps.yml` — applies the role on the proxy VPS (`--tags caddy`).
