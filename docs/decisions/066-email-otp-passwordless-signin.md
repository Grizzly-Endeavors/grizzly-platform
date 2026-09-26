# 066: Email one-time-code enrollment and passwordless sign-in

**Date:** 2026-08-04
**Status:** accepted

## Context

Enrollment into Authentik had exactly one shape: click Discord, GitHub or Google on `sso.grizzly-endeavors.com`, behind the `grizzly-invite` cookie gate ([ADR-039](039-authentik-social-federation-invitation-enrollment.md), [ADR-040](040-invite-broker-cookie-bridged-enrollment.md)). Someone holding none of those three accounts could not be onboarded at all, and [ADR-039](039-authentik-social-federation-invitation-enrollment.md) recorded the consequence that with no SMTP there is no self-service anything — the only fallback was an admin-issued recovery link handed over out-of-band. The Stalwart mail plant ([ADR-050](050-stalwart-mail-server.md)) has been live since July with no application consumer, so the missing piece was wiring, not infrastructure.

## Decision

Add a second invitation-gated enrollment flow, `grizzly-email-enrollment`: the invitee gives an address, Authentik mails a one-time code, and confirming it enrolls them. That code becomes the account's **only** credential — these accounts have no password, and sign-in mails a fresh code instead of prompting for one. Authentik sends through a dedicated `noreply@grizzly-endeavors.com` Stalwart submission account. The whole thing is declared in `kubernetes/infrastructure/authentik/blueprints/email-otp.yaml`.

The invitation gate is not duplicated. The same `grizzly-invite-gate` policy from `social-login.yaml` is bound to the new flow's user-write binding, so both paths enforce one rule from one place, and access stays closed.

## Alternatives Considered

- **Authentik's `EmailStage` (tokenised confirmation link)** — the sanctioned way to verify an address in an enrollment flow, and simpler. Rejected because passwordless sign-in needs a registered `EmailDevice` anyway; using `AuthenticatorEmailStage` makes one artifact serve both, where the link approach would verify at sign-up and then need a *second* mechanism for every subsequent login. A mailed link is also more fragile in this specific setup — mail scanners follow links, which is exactly the failure the invite broker's GET/POST split was built to dodge ([ADR-040](040-invite-broker-cookie-bridged-enrollment.md)).
- **Open self-signup** — would have made the platform's IdP internet-open. Every downstream app currently assumes "has an account" means "was invited"; breaking that assumption is a change to authorization everywhere, for no benefit while onboarding is one-at-a-time.
- **Password plus email verification** — conventional, but adds a password to support, reset and leak, on a platform where nobody currently has one except `akadmin`. Since `email_link` source matching already treats control of an address as sufficient to claim an account, an address-only credential is not a weaker posture than what is already in place.
- **The identification stage's `passwordless_flow` hook** — the obvious place to link an alternate sign-in path, but Authentik renders that button as the literal string "Use a security key", which is wrong for an emailed code and not configurable.
- **Relaying straight to SMTP2GO, skipping Stalwart** — one fewer hop on the login path, but it splits mail configuration across two systems and bypasses the platform's own mail server for the first thing that would have used it.

## Consequences

- **Onboarding no longer depends on owning a social account.** The invite link is unchanged; the invitee gains a "Sign up" option next to the three provider buttons.
- **An account existing implies its address was proven.** The user-write stage creates the account inactive and a second write activates it only after the code is confirmed. An abandoned sign-up leaves an inactive shell that no path can log into, rather than a live account bound to an address nobody verified.
- **The passwordless invariant is load-bearing and narrow.** The password stage is skipped *only* for a user holding a confirmed `EmailDevice`, and the validation stage always challenges a user holding a device — so skipping the password always hands off to a challenge. Three settings on `default-authentication-mfa-validation` hold that up (`last_auth_threshold: seconds=0`, `not_configured_action: skip`, `email` in `device_classes`) and are pinned in the blueprint for that reason, even though they currently match Authentik's defaults. `not_configured_action: configure` in particular would force every password user, `akadmin` included, to register an email authenticator mid-login.
- **Authentik's built-in login flow is now patched, but only in fields Authentik does not manage.** Upstream's `flow-default-authentication-flow.yaml` declares the validation stage with no attrs and the identification stage with only `user_fields`, so these patches survive upgrades. The built-in `default-authentication-flow-password-stage` policy *is* managed upstream, so the password stage is skipped by adding a second policy beside it and switching the binding to `all` mode rather than editing it.
- **Sign-in latency now includes a mail round-trip.** Submission hairpins out to the VPS and back ([ADR-051](051-haproxy-l4-mail-ingress.md)) and then relays through SMTP2GO. Acceptable for a login, but it makes mail delivery a dependency of authentication for these users — if Stalwart or the relay is down, they cannot sign in, while social and password users still can.
- **Failed SMTP AUTH is now a household-scale risk.** Submission from the cluster presents the household's public WAN IP to Stalwart's per-IP auto-ban (the `10.0.0.0/8` allowlist does not cover the hairpin), and Authentik retries sends through Celery. A drifted `AUTHENTIK_EMAIL__PASSWORD` would ban mail for everyone. Recovery is in [runbooks/mail.md](../runbooks/mail.md).
- **Existing social users are unaffected and can opt in.** They never reach the identification stage, so nothing changes for them; the `grizzly-email-otp-setup` stage-configuration flow lets them add an email code from User Settings if they want the second path.
- **Enrollment cannot be used to send mail to arbitrary addresses** — the invitation gate runs before the code stage. Sign-in *can* trigger a send for a known address; if that ever becomes a problem, the identification stage accepts a `captcha_stage`.
