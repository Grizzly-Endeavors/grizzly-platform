# ADR-077: Decommission the Residuum Platform Assistant

**Date:** 2026-09-20
**Status:** accepted
**Supersedes:** [ADR-062](062-residuum-platform-assistant.md) (Residuum as the platform assistant, on the R730xd with a stock image)

## Context

ADR-062 stood up Residuum on the R730xd as a personal platform assistant: a stock-image compose service on the foundation tier, reachable only through its outbound relay, able to change the platform by opening and merging pull requests. It ran continuously for two months and accumulated 31M of state, but the operating use it was built for did not materialize — it was not being consulted, and its ambient triggers (pulse, heartbeat, scheduled actions, inbox) were producing activity nobody was reading.

An idle assistant is not free. This one held an org-wide GitHub token that could merge its own PRs into repos Flux reconciles, which means an unused service retained a standing path to production. ADR-062 accepted that reach deliberately, on the premise that the assistant was worth it; with the usefulness gone, only the exposure remained. It also carried a role, a playbook, a runbook, four 1Password-backed secrets, a pinned image plus four pinned CLI binaries needing periodic version review, and a step in the ZFS pool-maintenance sequence.

## Decision

**Remove the deployment entirely.** The `r730xd-residuum` role, `deploy-residuum.yml`, and the operator runbook are deleted. On the R730xd the systemd unit, compose directory, read-only tools volume, container, and pinned image are gone, and Residuum is dropped from the ZFS pool quiesce/restart sequence. The four `vault_residuum_*` lookups are removed from `ansible/vars/onepassword_secrets.yml`; the 1Password item `platform-residuum` and the credentials behind it are revoked at their sources by the operator, since nothing reads them.

The agent's state was archived to a tarball off the foundation tier before deletion, so what it learned is recoverable, and `/mnt/zfs/foundation/residuum` no longer exists on `tank`.

ADR-062's design stays on record as the pattern to reuse. Nothing in it failed: the stock-image constraint held, the runtime tools volume worked as intended and drove two fixes upstream, and the relay-only access model never leaked a LAN listener. It is retired for lack of use, not for a defect.

**This decommissions the R730xd instance only.** The `feedback-ingest` service, the `residuum-feedback` namespace, and that Tempo tenant and Grafana datasource belong to the Residuum open-source project rather than to this deployment, and are untouched. The `residuum.bearflinn.com` redirect to `agent-residuum.com` likewise points at the public project and stays.

## Alternatives Considered

- **Stop the unit and keep the role and runbook in place.** Leaves IaC, a runbook, and pinned tool versions describing a service that does not exist, and the pool-maintenance runbook stepping over a dead unit. Dormant IaC rots; the ADR keeps the design if it is wanted back.
- **Keep it running but revoke the merge rights.** Addresses the exposure and not the cost. A propose-only assistant nobody consults still needs image bumps, tool-version review, and a place in the ZFS sequence, in exchange for output nobody reads.
- **Delete the state without archiving.** Rejected: the memory, workspace and vector store are the only non-reproducible part of the deployment, and 11M compressed is a cheap hedge against wanting to read back what it had learned.

## Consequences

- There is no platform assistant. Nothing opens PRs against platform repos unattended, and the org's GitHub token surface shrinks by one credential that could merge to a Flux-reconciled branch.
- The foundation tier carries one less consumer; `tank/foundation` holds no Residuum data, and the pool quiesce sequence is one step shorter.
- Restoring the assistant means re-creating the role from ADR-062's pattern, re-issuing the four credentials, and restoring the archived state directory. The tarball is the operator's copy — it is not in a backup rotation, so its durability is whatever the operator gives it.
