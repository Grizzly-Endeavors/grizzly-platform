# 039: Authentik social federation with invitation-gated enrollment

**Date:** 2026-06-29
**Status:** accepted
**Relates to:** [ADR-033](033-central-identity-authentik.md), [ADR-037](037-authentik-config-as-code-blueprints.md)

## Context

ADR-033 stood up Authentik as the platform IdP and ADR-037 brought its config under blueprints, but the instance can still only authenticate the bootstrapped `akadmin`. Real end users need to log in — specifically non-technical people being onboarded to apps like Nextcloud. Two constraints shape the design:

- The operator (Bear) builds these apps **for other people** and lives in the terminal himself; the priority is *their* login UX and *low per-user onboarding effort*, not self-hosting purity. Depending on an external login provider is acceptable.
- This repo is **public**. No human PII (emails, names) may be committed. Authentik is also internet-facing at `sso.bearflinn.com`, so enrollment cannot be open to anyone on the internet.

The question is how users authenticate and how access is controlled, expressed as blueprints.

## Decision

**Federate credentials to social providers (Discord + GitHub) and gate account creation behind admin-issued invitations.** No user objects are pre-provisioned.

1. **Federated credentials.** Two `authentik_sources_oauth.oauthsource` entries (Discord, GitHub). Authentik stores no password for these users; the provider vouches for identity at login. Client id/secret follow the ADR-037 secret path (`!Env` ← `global.env` ← ESO-synced `authentik-secrets` ← OpenBao `secret/grizzly-platform/platform/authentik`). Returning users are matched by the provider's stable subject id (`user_matching_mode: identifier`), not by a trusted email.
2. **Closed access via invitation.** New social logins have no match, so Authentik runs the source's `enrollment_flow` → `grizzly-invite-enrollment`. That flow prompts for an invitation code (a prompt stage with field key `token`); the invitation stage's `continue_flow_without_invitation: false` halts the flow when the code is missing or invalid. No invitation ⇒ no account. This is the documented authentik pattern for invite-only social signup (the source button is the entry point, so the source's own enrollment flow runs — no identification stage is nested inside).
3. **Auto group + active.** The flow's User Write stage creates the user active (`create_users_as_inactive: false`) and adds them to `grizzly-users` (`create_users_group`). Promotion to `grizzly-admins` stays a separate, deliberate action.
4. **No human PII in IaC.** Because accounts self-create from provider data and invitations are runtime objects, there are no `authentik_core.user` blueprint entries. Identities live only inside Authentik — never in this public repo, never in OpenBao.
5. **Single blueprint file.** Sources and the enrollment flow reference each other circularly; `!KeyOf` resolves only within one file, so the whole feature is one `social-login.yaml` applied as a single atomic transaction (avoids cross-file `!Find` needing a second 60-minute reconcile to converge).

Per-user onboarding cost: **create an invitation, send the code.** The person signs in with Discord/GitHub and pastes it.

## Alternatives Considered

- **Pre-provisioned user objects matched by email.** Declare each person as an `authentik_core.user` with their email, matched by `email_link`. Rejected: highest per-user effort (you must know each provider email exactly, and a mismatch fails silently), and it forces human emails into git or into OpenBao — unacceptable for a public repo.
- **Open self-enrollment.** Let any Discord/GitHub user self-register. Rejected: Authentik is internet-facing; this lets anyone create an account.
- **Domain allowlist enrollment.** Near-zero per-user effort, but only works if all users share an email domain — they don't (assorted personal accounts).
- **Local passwords / recovery-link enrollment.** Makes Authentik own credentials, but adds password lifecycle for non-technical users; federation is lower-friction for them. Kept only as the break-glass path.

## Consequences

- Onboarding is a per-person invitation, not a git PR — access changes are not recorded as commits. Acceptable: human identities can't be public PRs anyway, and the *mechanism* (sources, flow, group wiring) is fully in git.
- **Revocation is manual:** delete the user and their source connection in Authentik. There is no blueprint object to remove (no orphan-cruft concern from the ADR-037 removal rule, since users aren't blueprint-managed).
- **No SMTP** ⇒ no self-service password reset. The no-social / break-glass path is an admin-issued recovery link; `akadmin` keeps its bootstrap password.
- **Google deferred.** Same pattern adds Google later; for `openid`/`email`/`profile` (non-sensitive) scopes Google requires no app verification, so it's a trivial follow-up — left out only to keep the first cut to two providers.
- **Live-validation dependency.** The exact sequencing of source enrollment + the invitation gate is verified against the running instance (see the deploy runbook / plan), not asserted from docs alone.
