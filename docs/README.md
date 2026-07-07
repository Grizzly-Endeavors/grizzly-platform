# Documentation

How the platform's docs are organized, and where to look for what. This page is the **shape**; [`INDEX.md`](INDEX.md) is the **listing** — one line per document.

## The README / INDEX convention

Every docs area follows the same two-file rule, so you can always guess where to look:

- **`README.md`** — the *shape* of an area: what it's for, how it's organized, the conventions that govern it. Read it to orient.
- **`INDEX.md`** — the *listing*: one terse line per item in that area. Read it to find a specific doc fast.

The rule is mechanical on purpose: **INDEX to find a doc, README to understand the area.** When you add a doc, add its line to the local `INDEX.md`; when an area's organization changes, update its `README.md`.

## Areas

| Area | Shape | Listing | What lives there |
|------|-------|---------|------------------|
| **Decisions** | [decisions/README.md](decisions/README.md) | [decisions/INDEX.md](decisions/INDEX.md) | ADRs — *why* the platform is the way it is. |
| **Integration** | [integration/README.md](integration/README.md) | [integration/INDEX.md](integration/INDEX.md) | Consumer guides — *how to leverage* a platform service (DB, secrets, SSO, mail, storage, telemetry) from an app. |
| **Runbooks** | [runbooks/README.md](runbooks/README.md) | [runbooks/INDEX.md](runbooks/INDEX.md) | Operator procedures — *how* to deploy, drive, rotate, recover live systems. |
| **In-progress** | [in-progress/README.md](in-progress/README.md) | [in-progress/INDEX.md](in-progress/INDEX.md) | Active, multi-phase work and where we left off. The only place transient status lives. |
| **Exploration** | [exploration/README.md](exploration/README.md) | [exploration/INDEX.md](exploration/INDEX.md) | Researched-but-not-committed ideas. |
| **Reference & operations** | *(this file)* | [INDEX.md](INDEX.md) | Loose reference docs (hardware, network, ports) and standing operations guides. |

## Where the durable "why" and "how" split

Three homes, one question each — keep content in the right one and none of them rots:

- **Why we chose this** → an [ADR](decisions/). Permanent.
- **How to consume this from an app** → an [integration guide](integration/). Permanent. (Distinct from a runbook: consumer-facing, not operator-facing.)
- **How to operate/recover this** → a [runbook](runbooks/). Permanent.
- **What's in flight and where we left off** → an [in-progress thread](in-progress/). Ephemeral; deleted when the work lands.
- **A discrete bug or small follow-up** → a GitHub issue. Docs link to issues rather than duplicating them.

## Archive

Historical material lives in [`../archive/`](../archive/): pre-2026 configs (`pre-migration-2026/`), the completed 2026 migration record (`migration-2026/`), and superseded one-off projects.
