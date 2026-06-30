# 043: Invite admin UI gated by Authentik forward-auth, group enforced in-app

**Date:** 2026-06-30
**Status:** accepted
**Relates to:** [ADR-033](033-central-identity-authentik.md) (deferred forward-auth outposts — this is the first one), [ADR-040](040-invite-broker-cookie-bridged-enrollment.md), [ADR-041](041-group-scoped-invites.md), [ADR-042](042-multi-use-invites.md), [ADR-037](037-authentik-config-as-code-blueprints.md)

## Context

The invite broker (ADR-040/041/042) can only be provisioned by `curl`-ing `POST /api/invites` with the `ADMIN_TOKEN` bearer. We want a small, polished web UI to mint and manage invites, **registered as an app in Authentik** and reachable **only by members of `grizzly-admins`**. The broker is deliberately minimal (no OIDC client embedded), and ADR-033 deferred Authentik outposts until a concrete need — this is that need.

Two access patterns were on the table: make the broker an OIDC client itself (login/callback/session in Rust), or gate it with Authentik forward-auth via an outpost. A nuance shaped the choice: a signed-in user who is *not* a `grizzly-admin` should see a clean "not allowed" page, not be bounced back through the login flow or hit the outpost's generic deny screen.

## Decision

Gate `/admin` with **Authentik forward-auth via the embedded outpost** (first proxy provider in the homelab), and enforce the group **in the broker**, not at the outpost.

- A `forward_single` proxy provider + application (`grizzly-invite-admin`) is bound to the default embedded outpost via blueprint (`blueprints/grizzly-invite-admin.yaml`, registered in the authentik kustomization). The embedded outpost already serves `/outpost.goauthentik.io/*` on `authentik-server:80`.
- nginx (a second, path-scoped Ingress on `invite.bearflinn.com` for `/admin`) runs the external-auth subrequest against the outpost and **overwrites** the `X-authentik-groups` response header — so an external client cannot spoof it. A companion un-authenticated Ingress routes `/outpost.goauthentik.io` to the outpost via an `ExternalName` service (cross-namespace bridge). The outpost resolves which provider applies from the request **host**, but nginx's auth subrequest sends `Host` = the auth-url's host (the authentik service), not `invite.bearflinn.com`. Authentik's docs fix this with an `auth-snippet` (`X-Forwarded-Host`), but snippet annotations are off cluster-wide (`allow-snippet-annotations=false`); instead `X-Forwarded-Host` is supplied via the `auth-proxy-set-headers` annotation (a ConfigMap of extra auth-subrequest headers — the supported, snippet-free path), which the `forward_single` provider matches on.
- The application has **no policy binding**: any authenticated user passes the outpost and receives identity headers. The broker checks `grizzly-admins` from `X-authentik-groups` itself (`ADMIN_GROUP`, default `grizzly-admins`) and renders its own "not allowed" page for non-members. Only `/admin` is gated; the public surface (`/`, `/i`, `/verify`, `/healthz`, `/metrics`) and the bearer `/api` stay as-is.

## Alternatives Considered

- **In-app OIDC client** — Rejected: pushes an OAuth client, token validation, and session handling into a broker we intentionally keep minimal, duplicating identity logic Authentik already owns.
- **Bind a `grizzly-admins` policy at the outpost** — Rejected: it 403s non-members at the outpost (generic Authentik deny), defeating the "show a friendly not-allowed page" requirement. Letting everyone authenticated through and checking the group in-app is what makes the custom denial page possible; the header can't be spoofed from outside, so this isn't a weakening.
- **NetworkPolicy to close the in-cluster header-spoof vector** — Rejected (documented residual). The broker serves `/admin` *and* `/metrics` on the same port 8080, and Prometheus scrapes `/metrics` via NodePort; a Cilium policy filters by port/source, not path, so any rule permissive enough to keep scraping working also re-opens `/admin` to that source. Splitting metrics onto a second port for clean isolation wasn't worth it for the residual: the external attack is fully blocked (header overwrite), and the only remaining vector is a workload already running inside the cluster forging the header straight to `pod:8080/admin` — which already requires cluster access, past the homelab's real trust boundary.

## Consequences

- **First forward-auth deployment.** The embedded-outpost + path-scoped-Ingress pattern (auth-url / auth-signin / auth-response-headers, ExternalName passthrough, in-app group check) is now established and reusable for future admin UIs; ADR-033's deferral is lifted for this case.
- **Authorization denial is app-rendered.** Non-admins who are signed in see the broker's "not allowed" page; unauthenticated visitors still get Authentik's one-time sign-in (intrinsic to bootstrapping the outpost session), then the same in-app check.
- **No spoofable trust on the header.** nginx overwrites `X-authentik-groups`; the residual in-cluster vector is accepted and recorded here rather than mitigated with a NetworkPolicy that can't path-discriminate on the shared port.
- **Reconciles via GitOps.** Adding the blueprint is a commit; Flux regenerates the `authentik-blueprints` ConfigMap and the worker re-applies it (file-watch, up to 60m; scale the worker to force). No Authentik pod restart. The broker chart change (`adminUi` block, two Ingresses, env) ships through the normal gate-signed image + Flux path.
- **`list` now returns `link`.** The UI re-copies an existing invite's link without re-minting; additive to the bearer `/api` response too.
