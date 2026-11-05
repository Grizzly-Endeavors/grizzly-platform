# ADR-084: The grizzly-gameservers Bot Image Is Not Signature-Enforced

**Date:** 2026-11-02
**Status:** Superseded by [ADR-085](085-gameservers-bot-signature-enforced-again.md)
**Relates to:** [ADR-028](028-centralized-ci-gate.md) (the gate's Kyverno admission boundary), [ADR-069](069-kyverno-failurepolicy-tracks-failureaction.md) (named `enforce-gameservers-bot-signature` as the one fail-closed boundary; that policy is removed here)

## Context

grizzly-gameservers was the only app whose image was refused at admission without a grizzly-gate signature (`enforce-gameservers-bot-signature`, Enforce/Fail). The repo became a hackathon foundation with several people pushing to `main`, and its deploy pipeline dropped the gate to keep the push-to-live loop short: the gate added 7–14 minutes per push and had blocked every deploy since 2026-09-20 on findings unrelated to the changes being shipped (duplicate crate versions, new advisories, base-image CVEs). An unsigned image under the Enforce policy would be refused and the bot Deployment would stick on its old pod, so the policy goes with the gate.

## Decision

Remove `enforce-gameservers-bot-signature`. The bot image falls under the broad `verify-gate-signature` policy like every other first-party image: Audit with `failurePolicy: Ignore`, so an unsigned bot image is reported and admitted.

## Consequences

- No first-party image is signature-enforced at admission.
- Restoring enforcement means restoring the policy from git history only after grizzly-gameservers' `deploy.yml` runs the gate again and a gate-signed bot image is live; otherwise the rollout sticks.
