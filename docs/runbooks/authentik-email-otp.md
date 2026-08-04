# Runbook: Authentik email one-time codes

Operating the email sign-up and passwordless sign-in path ([ADR-066](../decisions/066-email-otp-passwordless-signin.md)). Config lives in [`blueprints/email-otp.yaml`](../../kubernetes/infrastructure/authentik/blueprints/email-otp.yaml); the mail plant it depends on is in [mail.md](mail.md).

## Shape

Two flows and one credential path:

- **`grizzly-email-enrollment`** — prompt for address + name → invitation gate → write the user **inactive** → mail a code and confirm it → activate → log in. Reachable as the "Sign up" link on the login page, useless without a `grizzly_invite` cookie.
- **`grizzly-email-otp-setup`** — stage-configuration flow, so an already-signed-in user (typically a Discord/GitHub/Google enrollee) can add an email code from *User Settings → MFA Devices*.
- **Sign-in** rides Authentik's built-in `default-authentication-flow`. The password stage is skipped by the `grizzly-email-passwordless` policy for any user holding a confirmed `EmailDevice`; the authenticator-validation stage then mails a fresh code.

Mail goes out as `noreply@grizzly-endeavors.com` over `mail.grizzly-endeavors.com:465`, credential in 1Password `platform-stalwart/noreply_password`, injected into the pods as `AUTHENTIK_EMAIL__PASSWORD`.

## Health

| Signal | Where |
|---|---|
| Sends are working | Authentik Admin → *System → Tasks*, the `send_mails` task |
| A send failed | Authentik Admin → *Events*, `configuration_error` / task failure entries |
| The blueprint applied | Authentik Admin → *Customisation → Blueprints*, `grizzly-email-otp` shows **Successful** with a recent timestamp |
| The submission account exists | `stw query Account --where name=noreply --json` ([stalwart-cli.md](stalwart-cli.md)) |
| The credential synced | `kubectl -n authentik get externalsecret authentik-secrets` shows `SecretSynced` |

There is no dedicated Prometheus alert for code delivery. `AuthentikDown` covers the service being gone; a *silently* undelivered code shows up as users reporting it, or in the Tasks view.

## Common failures

**Code never arrives.** Walk it outward:

1. Authentik → *Events* for a send failure. A `535` there means the password drifted — see below.
2. `kubectl -n stalwart logs deploy/stalwart --tail=100` for the submission attempt.
3. Delivered but not seen — Stalwart files some legitimate mail into Junk. Check the recipient's spam folder.
4. Nothing in either log — confirm the pods actually carry the env: `kubectl -n authentik get deploy authentik-server -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AUTHENTIK_EMAIL__HOST")]}'`.

**`535` auth failed / the household loses mail.** This is the failure mode with blast radius. Submission hairpins out to the VPS, so HAProxy presents the household's **public WAN IP** to Stalwart's per-IP auto-ban — the `10.0.0.0/8` allowlist in `plan.json` does not cover it — and Authentik retries sends through Celery. A drifted password therefore bans mail for everyone, not just Authentik.

```bash
# Re-sync the credential into Stalwart's directory, then restart so it takes.
ansible-playbook -i ansible/inventory ansible/playbooks/configure-stalwart.yml \
  --vault-password-file .vault_pass -e stalwart_force_restart=true

# Clear the ban.
stw query BlockedIp --json
stw delete BlockedIp --ids <id>
```

If the ban has wedged Stalwart's HTTP surface too, port-forward past the ingress: `kubectl -n stalwart port-forward pod/<pod> 18080:8080`, then drive the CLI with `STALWART_URL=http://localhost:18080 --network host`.

**Connection reset (`errno 104`).** Something is dialling the in-cluster Service instead of `mail.grizzly-endeavors.com`. The listeners trust PROXY protocol from `10.0.0.0/8`, which covers the pod network. Use the public host.

**"That address already has an account."** The `grizzly-email-taken` validation policy fired. Expected when the address is already on a user — including an inactive shell left by an abandoned sign-up. Delete that user in *Directory → Users* to free the address.

**Sign-up denied with an invitation message.** The `grizzly-invite-gate` policy, shared with the social path. Not a mail problem — see [ADR-040](../decisions/040-invite-broker-cookie-bridged-enrollment.md). Note the invite is consumed at the user-write stage, *before* the code is sent, so abandoning at the code step spends a single-use invite (the broker's 600s idempotency grace covers an immediate retry, nothing longer).

**A password prompt appears for an email user.** The `grizzly-email-passwordless` policy returned true. Either the account has a real password hash, or it has no *confirmed* `EmailDevice` — check *Directory → Users → \<user\> → MFA Devices*. That is the intended failure direction: it asks for more proof, never less.

## Changing it

Blueprints are stateless upsert — see [`blueprints/CLAUDE.md`](../../kubernetes/infrastructure/authentik/blueprints/CLAUDE.md). Editing `email-otp.yaml` and letting Flux reconcile is enough to *change* an object; **removing** one is a two-step (mark `state: absent`, reconcile, then drop the entry), or it lingers in the running instance.

Three settings on `default-authentication-mfa-validation` hold up the passwordless invariant and must not drift:

- `last_auth_threshold: seconds=0` — a non-zero value would let a recent code stand in for this login, handing out a session for nothing but a known address.
- `not_configured_action: skip` — `configure` would force every password user, `akadmin` included, to register an email authenticator mid-login.
- `email` present in `device_classes` — without it the validation stage can't challenge with a code.

Rotating the sender password: edit `platform-stalwart/noreply_password` in 1Password, re-run `configure-stalwart.yml` with `-e stalwart_force_restart=true`, then force the ExternalSecret to re-read (`refreshPolicy: OnChange`, so `kubectl -n authentik annotate externalsecret authentik-secrets force-sync=$(date +%s) --overwrite`) and roll the authentik pods.

## See also

- [mail.md](mail.md) — the mail plant: architecture, SMTP2GO smarthost, DKIM/SPF/DMARC.
- [stalwart-cli.md](stalwart-cli.md) — driving the Stalwart config CLI.
- [integration/sso.md](../integration/sso.md) — putting an app behind Authentik and onboarding people.
- ADR [066](../decisions/066-email-otp-passwordless-signin.md), [039](../decisions/039-authentik-social-federation-invitation-enrollment.md), [040](../decisions/040-invite-broker-cookie-bridged-enrollment.md), [050](../decisions/050-stalwart-mail-server.md).
