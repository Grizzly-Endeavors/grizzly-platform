# docs/in-progress — working rules

This directory tracks **active, multi-phase initiatives** — work that is underway, spans several steps or sessions, and is not yet finished. It is deliberately the *only* place transient status lives, so that the root `CLAUDE.md` and the durable docs (ADRs, runbooks) never carry rotting "as of <date>" state.

## What belongs here

- A multi-phase initiative that will take more than one sitting and whose state changes as it progresses (a migration, a cutover, a phased rollout). One file per thread.
- Nothing else. This is not a backlog, not a bug tracker, not a design scratchpad.

## What does NOT belong here

- **Discrete bugs, blockers, and small follow-ups** → open a GitHub issue instead. Threads here *reference* those issues (e.g. "blocked by #119"); they don't duplicate them.
- **The durable "why"** → an ADR in `../decisions/`. The durable "how to operate/recover" → a runbook in `../runbooks/`. A thread here points at those; it never restates their content. When the thread closes, the ADR + runbook + git history *are* the permanent record — this file was only scaffolding.
- **Anything already true and stable** → the relevant runbook, ADR, or the root `README.md`. If it won't be false next month, it doesn't go here.

## The discipline — close threads out

A tracker is only useful if it is honest, and it is only honest if finished threads leave. **When a thread completes:**

1. Delete its file and remove its line from `INDEX.md`.
2. Make sure the permanent record is in place — the ADR captures the decision, the runbook captures the operations, the code is merged. That is what survives; the thread does not.
3. If a stale claim about this work lives anywhere durable (root `CLAUDE.md`, `README.md`, another runbook), fix it in the same move.

A thread left here after its work is done is exactly the rotting instruction this whole structure exists to prevent. Treat "close it out" as part of finishing the work, not a chore for later.

## Format of a thread file

Keep it short — this is a pointer, not a second copy of the runbook. Each thread states: the goal in a sentence, what is already done, what remains (the honest resume point), any blockers (as issue links), and links to the authoritative ADR(s) + runbook(s). If you find yourself writing operational detail here, it belongs in the runbook.
