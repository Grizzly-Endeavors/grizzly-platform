# 040: Invite broker — cookie-bridged Authentik enrollment

**Date:** 2026-06-29
**Status:** accepted (single-use invariant generalized by [ADR-042](042-multi-use-invites.md))
**Relates to:** [ADR-039](039-authentik-social-federation-invitation-enrollment.md), [ADR-037](037-authentik-config-as-code-blueprints.md), [ADR-033](033-central-identity-authentik.md), [ADR-003](003-foundation-stores-on-r730xd.md), [ADR-019](019-ingress-and-tls-termination.md)

## Context

ADR-039 made onboarding invitation-gated, but left a UX wall: an invitee clicks a social provider on the login page and must then **paste an invitation UUID** into a prompt. The desired flow is *send one link → invitee signs up with any provider → account created* — no pasting.

The wall is structural in Authentik, not cosmetic. When a brand-new social user authenticates, Authentik hands them to the source's `enrollment_flow` and **discards the outer flow's context**, so an invitation token carried in flow context (the `?itoken=` mechanism) does not survive the OAuth round-trip. This is the reason the token has to be re-collected by a prompt today. It is documented and actively regressed upstream (goauthentik issues #17638, #17293, #18635); a previous fix (PR #12872) removed the context-preservation people relied on. The "do it in pure config with a Source Stage" path is fragile and unproven on our pinned **2026.5.3**.

## Decision

**Move the invitation out of Authentik flow context and into a signed browser cookie, brokered by a small first-party service (`grizzly-invite`).** The cookie is scoped to `.bearflinn.com`, so unlike flow context it *survives* the OAuth round-trip (it is present on the callback to `sso.bearflinn.com`). Authentik's enrollment flow gates account creation on that cookie via an expression policy that calls the broker.

### 1. The bridge is a cookie, not flow state

The thing Authentik loses across OAuth is flow context; the thing the browser keeps is a parent-domain cookie. The broker plants a short-TTL (~30m) HMAC-signed cookie (`grizzly_invite`, `HttpOnly; Secure; SameSite=Lax; Domain=.bearflinn.com`) carrying only the invite id and an expiry. No PII, no provider binding — "any provider" is the point.

### 2. End-to-end flow

Admin mints an invite (`POST /api/invites`, bearer-token) → invitee opens `invite.bearflinn.com/i/<token>` → broker validates and plants the cookie, redirects to `sso.bearflinn.com` → invitee signs up with any provider → Authentik runs `grizzly-invite-enrollment`, whose bound expression policy reads the cookie and `POST`s it to the broker's `/verify` → broker verifies the signature, consumes the invite (single-use, server-side, in a transaction), returns `{allow:true}` → user-write creates the account in `grizzly-users`. No/invalid/used cookie ⇒ policy denies ⇒ no account. Enrollment stays closed and invitation-gated, exactly as ADR-039 requires.

**Amendment (2026-07-10) — `/i/:token` is now a read-only `GET` + a redeeming `POST`.** The original design had the invitee's `GET /i/<token>` do the work: plant the cookie and `302` to SSO. That made a state-changing, redirecting `GET`, which link-preview crawlers (iMessage/WhatsApp/Slack), Outlook SafeLinks, Defender, and antivirus scanners all trip by fetching a link *before* a human taps it — they followed the redirect (rewriting the shown link to the `sso.` URL) and received the cookie/redemption themselves, dropping the real invitee on a cookieless login page. The endpoint is now split: `GET /i/:token` validates and serves a branded landing page with **no** side effects (no cookie, no redemption, no redirect), and the page's form auto-submits a `POST /i/:token` that does the mark-clicked + redemption + cookie-plant + `303` to SSO. Only a real browser issues the `POST`; anything that merely `GET`s the link now mutates nothing and cannot rewrite the destination. The landing page also carries OpenGraph tags so the unavoidable preview fetch renders an intentional invitation card. The bridge itself (§1) and the `/verify` consume path are unchanged. Implemented in `grizzly-invite`.

### 3. Stateful broker, single source of truth for invites

The broker owns the invitation ledger (mint / list / revoke / consume) so single-use, expiry, revocation, and an audit trail are real and server-enforced — not implied by an unguessable cookie. `/verify` consumes on first success and stays idempotent within a short grace window, because Authentik may evaluate the flow policy more than once in a single enrollment. The signing key is the broker's alone; Authentik never holds it (the policy only relays the opaque cookie back to `/verify`), so the only Authentik-side change is a blueprint.

### 4. Foundation Postgres, dedicated scoped role

The ledger lives on the foundation Postgres (`10.0.0.200:5432`, ADR-003) — the same instance Authentik uses — under a dedicated `grizzly_invite` login role owning a dedicated `grizzly_invite` database, provisioned by `ansible/playbooks/setup-invite-stores.yml` (the pattern ADR-038 set for Nextcloud). The app only ever gets its own scoped credentials, never the superuser; the foundation `pg_dumpall` backup already covers the new DB. Chosen over an embedded SQLite-on-PVC store to match how the platform already runs stateful data and to avoid a single-replica PVC.

### 5. Delivery and secrets

`grizzly-invite` is a first-party Flux app (`kubernetes/apps/grizzly-invite/`) in a `grizzly.io/gated=true` namespace, so its image must be grizzly-gate-signed (ADR-028) to be admitted. Secrets live at `secret/grizzly-platform/platform/invite` (`db_password`, `signing_key`, `admin_token`) — `platform/` domain because this is identity infrastructure, not a lab app — synced by an ExternalSecret. Ingress at `invite.bearflinn.com` follows ADR-019 (no TLS block; Caddy terminates the wildcard).

### 6. Minimal crypto surface

The cookie is a hand-rolled HMAC-SHA256 token (`hmac`+`sha2`), deliberately *not* a JWT library: the available JWT crate pulls a transitive `rsa` with an unresolved timing vuln (RUSTSEC-2023-0071) for RSA algorithms we would never use. We only ever sign/verify HS256, so the small dependency surface is the safer one and keeps the gate's SCA green.

## Alternatives Considered

- **Source Stage restructure (pure Authentik config).** Embed the provider picker mid-flow so the flow owns the entry point. Rejected as the primary path: the resume mechanism is fragile (breaks if the source's own flow logs the user in) and has an open regression (#18635) on our version. It remains the fallback if the cookie/policy approach somehow can't see the cookie.
- **Stateless HMAC cookie, no broker state.** The policy verifies the cookie locally with a shared key — no service on the enrollment path. Rejected: a replayable-until-TTL cookie is a time-limited enrollment window, not a single-use invite, and there is no revocation or audit.
- **Pre-provisioned users / `itoken` in the link.** Rejected for the same reasons as ADR-039 (PII in git) and because `itoken` is precisely what does not survive the round-trip.

## Consequences

- **The broker is on the new-enrollment path.** If it is down, *new* sign-ups fail; existing logins are unaffected (they never hit the enrollment flow). Acceptable for onboarding; covered by the `InviteBrokerDown` Prometheus alert (warning, not critical).
- **Live-validation dependency.** The one true unknown is whether the flow-bound expression policy sees the cookie on the OAuth callback for a brand-new user. This is verified against the running 2026.5.3 before the old paste-prompt stages are removed; the policy + binding are added first (Audit-safe), validated across Discord/GitHub/Google, and only then are the `invitation`/prompt stages removed (two-step per the blueprint removal rule).
- **Cross-repo coupling, explicit.** `grizzly-invite` owns the service + chart; `grizzly-platform` owns the foundation provisioning (Ansible), the Flux app, the Authentik blueprint, and the secret path — the same split ADR-038 established.
- **Fail-closed everywhere.** Missing/invalid/used cookie, broker timeout, or signature mismatch all deny enrollment.
