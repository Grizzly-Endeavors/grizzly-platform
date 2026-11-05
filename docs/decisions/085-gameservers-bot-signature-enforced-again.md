# ADR-085: The grizzly-gameservers Bot Image Is Signature-Enforced Again

**Date:** 2026-11-05
**Status:** Accepted
**Supersedes:** [ADR-084](084-gameservers-bot-signature-not-enforced.md)
**Relates to:** [ADR-028](028-centralized-ci-gate.md) (the gate's Kyverno admission boundary), [ADR-069](069-kyverno-failurepolicy-tracks-failureaction.md) (names `enforce-gameservers-bot-signature` as the one fail-closed boundary)

## Context

ADR-084 removed `enforce-gameservers-bot-signature` because grizzly-gameservers' deploy pipeline had dropped the gate for a hackathon. That hackathon is over: grizzly-gameservers `main` is back to its pre-hackathon tree (the hackathon work lives on its `hackathon` branch), which means `deploy.yml` runs the gate again, and the bot is running the gate-signed digest the restored `deploy/values.yaml` pins. ADR-084's condition for restoring enforcement — the gate back in the pipeline and a signed bot image live — holds.

## Decision

Restore `enforce-gameservers-bot-signature` exactly as it was (Enforce, `failurePolicy: Fail`, scoped to the bot image only).

## Consequences

- The bot image is again the one first-party image refused at admission without a grizzly-gate signature.
- A bot image only reaches the cluster once the gate passes. Gate findings unrelated to a change still block that change's deploy, as they did before the hackathon; the running pod stays on its last signed digest meanwhile.
