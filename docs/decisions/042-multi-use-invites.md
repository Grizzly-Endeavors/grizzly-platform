# 042: Multi-use invites via a per-redemption nonce ledger

**Date:** 2026-06-30
**Status:** accepted
**Relates to:** [ADR-040](040-invite-broker-cookie-bridged-enrollment.md) (generalizes its single-use invariant), [ADR-041](041-group-scoped-invites.md), [ADR-039](039-authentik-social-federation-invitation-enrollment.md)

## Context

ADR-040 made every invite strictly single-use: `/verify` consumes the one invite on first success and stays idempotent only within a short grace window, because Authentik may evaluate the flow policy twice in one enrollment. That blocks the real onboarding shape — a household or friend circle wants *one* link several people can use. We need a configurable use count per invite (finite N, or unlimited until expiry), without weakening ADR-040's invariant that the OAuth-surviving cookie carries no identity and no authorization.

The blocker is identity: the cookie carried only `{invite_id, exp}`, so two different people redeeming the same invite within the grace window are indistinguishable from one person's flow re-evaluating. A bare `use_count` keyed on the invite's single `consumed_at` would therefore mis-count — under-counting a real second redeemer (merged into the first's grace) or double-counting one flow.

## Decision

Give each *redemption* its own identity. Every click of `/i/:token` records a row in a new `invite_redemptions` table (migration `0003`) whose nonce rides in the cookie alongside the invite id (`{invite_id, rid, exp}`). `/verify`'s `consume` keys idempotency on that redemption row, not the invite: a re-evaluated flow re-verifies the same nonce (grace), while a different person on the same invite consumes a separate use. The invite gains `max_uses` (`NULL` = unlimited) and a denormalized `use_count` advanced in the same locked transaction; the invite flips to `consumed` (now meaning *exhausted*) when the cap is hit. `POST /api/invites` takes `uses` (default `1`; `0` = unlimited), defaulted by `INVITE_DEFAULT_USES`.

## Alternatives Considered

- **Counter-only (`use_count`/`max_uses`, no nonce)** — Rejected: with only the invite id in the cookie, per-person idempotency falls back to the shared grace window, which mis-counts overlapping redeemers. Correctness, not just neatness, requires per-redemption identity.
- **Shrink the grace window to seconds** — Rejected: narrows but doesn't close the mis-count race, and trades one correctness gap for a flakier enrollment under double-evaluation.
- **Carry the redemption state in the cookie** — Rejected: same posture as ADR-041's group decision — authorization/consumption state belongs in the server-side ledger, not the browser-held token.

## Consequences

- **One link onboards a group.** `POST /api/invites {"uses":5}` (or `{"uses":0}` for an unlimited, time-bounded join link) → share once. The future light web UI reads `max_uses`/`use_count`/`expires_at` (now exposed on the API) to show "2 of 5 used, expires …".
- **Authentik contract unchanged.** `/verify` still returns `{allow, groups}`; the `grizzly-invite-gate` policy and all blueprints are untouched. This is purely a `grizzly-invite` change — **no platform-side change** beyond this record and the chart's `INVITE_DEFAULT_USES` default.
- **Single-use is preserved as the default.** `max_uses` defaults to 1; the migration backfills existing rows to single-use, so behavior is unchanged unless an invite opts into more.
- **Pre-upgrade cookies are rejected.** Cookies minted before this change lack `rid` and fail to verify — acceptable given the 30-minute cookie TTL drains any in flight; deny-closed is the safe failure.
- **The ledger grows one row per click.** Tiny at homelab volume; a future cleanup cron to prune old `invite_redemptions` is noted as a follow-up, not built now.
- **ADR-040's "single-use, server-side" line is generalized,** not discarded: redemptions are still consumed server-side in a transaction with a real audit trail — there can now just be more than one per invite.
