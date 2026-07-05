# 049: App library visibility scoped via Authentik group policy bindings

**Date:** 2026-07-05
**Status:** accepted
**Relates to:** [ADR-043](043-invite-admin-ui-forward-auth.md) (partially superseded), [ADR-037](037-authentik-config-as-code-blueprints.md), [ADR-041](041-group-scoped-invites.md)

## Context

Authentik's app library ("My Applications" on sso.bearflinn.com) shows every application a user passes policy checks for. `grizzly-invite-admin` (the invite-minting admin UI) had no policy binding per ADR-043 — deliberately, so a signed-in non-admin got the broker's own friendly "not allowed" page (checked in-app from `X-authentik-groups`) instead of the outpost's generic 403. A side effect not weighed at the time: with no binding, every enrolled friend also saw this admin-only tool sitting in their app library, which bear doesn't want — he'd rather friends only see what's meant for them, without hiding admin apps from his own view or maintaining separate bookmarks for them.

## Decision

Bind `grizzly-invite-admin`'s `authentik_core.application` to the `grizzly-admins` group via a direct `authentik_policies.policybinding` (no expression policy needed) in `kubernetes/infrastructure/authentik/blueprints/grizzly-invite-admin.yaml`. The application entry gained `id: invite-admin-app`; the binding references it with `!KeyOf` and the group with `!Find [authentik_core.group, [name, grizzly-admins]]`.

This establishes the general pattern for scoping any app's library visibility (which is inseparable from its access control in Authentik):

- **Allow-list to specific groups:** add one non-negated group binding per allowed group, `policy_engine_mode: any` (default) — passing any one binding is enough.
- **Deny-list a specific group, leave everyone else in:** add one `negate: true` binding for that group, `policy_engine_mode: all` — that group fails the check, no one else is affected.

## Alternatives Considered

- **Leave unbound, accept library clutter** — Rejected: defeats the goal of a clean per-user app library; friends filtering past admin tooling was the exact problem being solved.
- **Fully hide the app from everyone (including bear) and bookmark it separately** — Rejected: Authentik has no per-viewer "hide from others, show to me" toggle independent of access control; a policy binding scoped to `grizzly-admins` achieves the same effect for bear (who is a member) without a separate bookmark.

## Consequences

- **Friends no longer see `grizzly-invite-admin` in their library**, and can no longer reach it at all — the binding blocks access, not just visibility, since Authentik doesn't separate the two.
- **ADR-043's denial-UX rationale is partially superseded.** A non-admin hitting `/admin` directly now gets the outpost's generic 403 before ever reaching the broker; the broker's own `X-authentik-groups` check remains in the code as defense-in-depth, but its non-admin-facing "not allowed" page is no longer reachable through normal navigation. The header-spoofing protections and residual-vector reasoning in ADR-043 are unaffected.
- **Reusable pattern for future admin-only apps.** Any new app that should stay out of friends' libraries gets the same one-binding treatment at creation time, rather than needing a retrofit.
- **Reconciles via GitOps**, same as any blueprint change (Flux regenerates the `authentik-blueprints` ConfigMap; worker re-applies on its up-to-60m file-watch, or scale-restart to force).
