# Integration: sending mail (Stalwart)

**What you get:** the ability to send transactional email (password resets, notifications, receipts) from your app through the self-hosted Stalwart mail server, delivered with aligned SPF/DKIM/DMARC so it lands in inboxes rather than spam.

Submit to Stalwart over SMTP:

```
mail.grizzly-endeavors.com:587    (submission, STARTTLS)
mail.grizzly-endeavors.com:465    (submissions, implicit TLS)
```

Stalwart relays all outbound through **SMTP2GO** as the smarthost; DKIM/SPF/DMARC pass for the `grizzly-endeavors.com` domain ([ADR-050](../decisions/050-stalwart-mail-server.md)).

## The two rules that make or break this

1. **Dial the *public* host, `mail.grizzly-endeavors.com`, even from inside the cluster — never an in-cluster Service.** The mail listeners trust PROXY-protocol from `10.0.0.0/8`, which *covers the pod network*, so a direct in-cluster connection is parsed as a PROXY header and reset (`errno 104`, connection reset). The public path rides the VPS HAProxy, which prepends the PROXY header correctly, and the TLS cert matches. Your traffic hairpins out to the VPS and back — accepted trade-off for a correct handshake.
2. **Your `From:` address must be `<something>@grizzly-endeavors.com`.** DMARC alignment is anchored on that domain (SMTP2GO signs DKIM as `d=grizzly-endeavors.com`). A `From:` on any other domain will fail alignment and get filtered. Do not send as `bearflinn.com` (receive-only) or a bare service hostname.

## When to use it

- **Use it** for app-generated transactional mail from a `@grizzly-endeavors.com` sender.
- Not for bulk/marketing sends (that's a different deliverability posture) and not for receiving mail into an app (inbound is human mailboxes today).

## Prerequisites

- Stalwart live (it is — see [mail.md](../runbooks/mail.md)).
- A **submission credential** for your app (below). There isn't a shared "any app can send" account by design — each sender gets its own account so it can be revoked independently.

## 1 — Provision a submission account

Stalwart accounts are declared in its config plan and applied by the CLI, not created ad-hoc. Add a dedicated account for your app to `ansible/files/stalwart/plan.json` (an `Account` with a `credentials` entry, alongside the existing bootstrap mailbox), give it a password sourced from OpenBao, and apply with `configure-stalwart.yml`. Store the password at `secret/grizzly-platform/stores/<app>` (or reuse your app's existing stores path) under e.g. `smtp_password`:

```bash
bao kv patch secret/grizzly-platform/stores/<app> \
  smtp_password="$(openssl rand -base64 36)"
# then add the account to plan.json and:
ansible-playbook -i ansible/inventory ansible/playbooks/configure-stalwart.yml \
  --vault-password-file .vault_pass -e stalwart_force_restart=true -v
```

Blob/listener/credential changes need a pod restart to take — hence `stalwart_force_restart=true`. The Stalwart config CLI verbs and object model are in [stalwart-cli.md](../runbooks/stalwart-cli.md); the account/credential shape is the `credentials` index-keyed map documented there.

## 2 — Wire it into your app

Land the SMTP password with an `ExternalSecret` ([secrets.md](secrets.md)):

```yaml
data:
  - secretKey: SMTP_PASSWORD
    remoteRef: { key: grizzly-platform/stores/<app>, property: smtp_password }
```

Then configure your mailer — host, port 587 (STARTTLS) or 465 (implicit TLS), your account username + the synced password, and an aligned `From:`:

```
SMTP_HOST=mail.grizzly-endeavors.com
SMTP_PORT=587
SMTP_USER=<app>@grizzly-endeavors.com
SMTP_PASS=${SMTP_PASSWORD}
MAIL_FROM=<app>@grizzly-endeavors.com
```

## Verify

Home ISP blocks outbound `:25`, but submission `:587/:465` is fine from the cluster. Send a real message and check the headers on the receiving side:

```bash
# quick check from a pod with swaks or your app's own "send test" path
swaks --server mail.grizzly-endeavors.com:587 -tls \
  --auth-user <app>@grizzly-endeavors.com --auth-password "$SMTP_PASSWORD" \
  --from <app>@grizzly-endeavors.com --to you@gmail.com
```

In the delivered message's `Authentication-Results`, confirm **spf=pass**, **dkim=pass** (`d=grizzly-endeavors.com`), and **dmarc=pass**. Anything less means the `From:` isn't aligned or the account isn't relaying.

## Troubleshoot

- **Connection reset (`errno 104`) right after TCP connect** — you dialed an in-cluster Service or IP instead of `mail.grizzly-endeavors.com`. The listener expected a PROXY header. Use the public host.
- **Mail sends but lands in spam / dmarc=fail** — `From:` isn't `@grizzly-endeavors.com`, so DKIM/SPF don't align. Fix the sender address.
- **`535` auth failed** — wrong account username or the password drifted from OpenBao. Re-apply the plan; confirm the `ExternalSecret` synced the current value.
- **Nothing sends and no error in-app** — verify the pod actually has egress to the VPS path and that `configure-stalwart.yml` was re-run with a restart after adding the account.

## See also

- [mail.md](../runbooks/mail.md) — **operator** runbook: architecture, ingress path, SMTP2GO smarthost, DKIM/SPF/DMARC, restart procedure.
- [stalwart-cli.md](../runbooks/stalwart-cli.md) — driving Stalwart's config CLI (accounts, credentials, listeners).
- [secrets.md](secrets.md) — landing the SMTP password.
- ADR [050](../decisions/050-stalwart-mail-server.md) (Stalwart), [051](../decisions/051-haproxy-l4-mail-ingress.md) (L4 mail ingress).
