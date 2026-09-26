# ADR-069: Kyverno `failurePolicy` Tracks `failureAction`

**Date:** 2026-08-05
**Status:** Accepted
**Relates to:** [ADR-028](028-centralized-ci-gate.md) (the gate's Kyverno admission boundary), [ADR-032](032-registry-pullthrough-cache.md) (the zot pull-through cache whose stall exposed this), [ADR-027](027-registry-zot.md) (zot).

## Context

Kyverno exposes two independent failure axes that are easy to conflate. `failureAction` (per `verifyImages` rule) decides what happens when *verification* fails — `Audit` reports, `Enforce` rejects. `failurePolicy` (per policy) decides what happens when the *webhook itself* errors or times out — `Ignore` admits, `Fail` rejects. `verify-gate-signature` is deliberately report-only while first-party images are brought under signature (`failureAction: Audit`), but it carried `failurePolicy: Fail`.

On 2026-08-05 a wedged zot on-demand sync made manifest reads take ~5 minutes each. Kyverno's image verification needs two such reads (the manifest and the cosign `.sig` tag) against a 30s `webhookTimeoutSeconds`, so the webhook timed out — and `Fail` turned that into a rejection for **every pod in every namespace labelled `grizzly.io/gated=true`**. Agones parked new GameServers in `Creating` indefinitely. A rule that was supposed to only write reports took down admission cluster-wide.

## Decision

**`failurePolicy` MUST track `failureAction`.** A policy whose rules are `Audit` sets `failurePolicy: Ignore`; a policy whose rules are `Enforce` sets `failurePolicy: Fail`. The two flip together, in the same change.

Because `failurePolicy` is policy-scoped while `failureAction` is rule-scoped, **Audit and Enforce rules must live in separate ClusterPolicies** — otherwise no single `failurePolicy` can be correct for the whole object. That is already the shape here: `verify-gate-signature` (Audit/Ignore, broad) and `enforce-gameservers-bot-signature` (Enforce/Fail, scoped to the bot image).

## Alternatives Considered

- **Raise `webhookTimeoutSeconds`** — rejected: a longer timeout only moves the threshold, and any stall outstanding it still blocks admission. It also makes a genuinely wedged dependency stall pod creation for *longer* before failing. Treats the symptom.
- **Keep `failurePolicy: Fail` for defense in depth** — rejected: there is no depth to defend. An Audit rule never blocks anything, so failing closed on webhook error buys no enforcement — it only converts a dependency outage into an admission outage.
- **Guarantee the registry is never slow** — not achievable, and the wrong place to fix it. Admission must degrade sanely when a dependency misbehaves.

## Consequences

- A report-only policy can no longer take down cluster-wide admission. Registry, network, or Kyverno slowness degrades reporting instead of blocking workloads.
- The tradeoff accepted: when the webhook is unreachable, Audit rules silently produce no report. Acceptable precisely because they are report-only — a missing report is not a security event.
- The real deploy boundary stays fail-closed. `enforce-gameservers-bot-signature` keeps `failurePolicy: Fail`, so an unsigned bot image cannot be admitted even if Kyverno is unreachable.
- **This constrains the eventual Enforce flip.** When `verify-gate-signature` moves to `failureAction: Enforce`, `failurePolicy` must return to `Fail` in the same commit — at which point registry availability becomes a hard prerequisite for pod creation in gated namespaces. Registry health signals (a probe that exercises a manifest read, not just `/v2/`) should be in place before that flip, not after.
