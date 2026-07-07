# Integration guides — for the agent using them

These guides exist mostly for **you** (a future Claude session), so you stop reverse-engineering how to wire an app to a platform service every time. They're the consumer front door: how to leverage Postgres, Valkey, S3, secrets, SSO, mail, observability, and the deploy path from an app.

## The one rule: fix the guide, don't work around it

**If you follow a guide and it was stale, wrong, or missing what you needed — update the guide in the same change that works around the gap.** Never just solve it locally and move on, leaving the next session to hit the same wall.

- **Stale** (a path, port, flag, secret key, or endpoint changed): correct it, and if you can, note what it was verified against so the next drift is obvious.
- **Missing** (you had to figure out a step the guide skipped): add the step, with the real command/manifest you actually ran.
- **Wrong** (the guide sent you down a false path): fix it *and* leave a one-line "gotcha" so nobody repeats your dead end. A wrong entry is worse than a missing one — it actively misleads.

This is the same discipline `versitygw-cli.md` states for itself, applied to the whole directory. The guides only stay trustworthy if every session that finds a hole patches it.

## Keep the shape

- **Consumer-facing, not operator-facing.** These answer "how do I *use* this from an app." How to *run/rotate/recover* the service is a [runbook](../runbooks/); *why* it's built this way is an [ADR](../decisions/). If you're about to document rotating a key or tuning a store here, it belongs in the runbook — link to it instead.
- **Even depth, one skeleton.** Match the existing structure (what you get → when → prerequisites → provision → wire → verify → troubleshoot → see also). Real hostnames, real OpenBao paths, copy-paste examples modeled on a live consumer — not hand-wavy prose.
- **New consumable capability?** Add a guide here and a line to [`INDEX.md`](INDEX.md); wire it into the root [`INDEX.md`](../../INDEX.md) subsystem map.
- **This is a public repo.** No secret values in examples — always route through OpenBao/ESO (see [secrets.md](secrets.md)).

Updating a guide as part of your task is not scope creep — it's the point of the guide existing.
