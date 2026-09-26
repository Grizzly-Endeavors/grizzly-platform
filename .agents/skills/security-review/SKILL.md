---
name: security-review
description: Audit grizzly-platform infrastructure security posture. Use when setting up new machines, roles, or services; when reviewing existing IaC for security gaps; when the user asks about attack surface, hardening, or exposure; or when preparing a machine or service for production use. Covers SSH, firewalls, network segmentation, secrets handling, service exposure, BMC/iDRAC, backup security, and supply chain.
---

# Security Review

Structured audit of self-hosted infrastructure security. Operate in two modes:

1. **Targeted review** — Audit a specific file, role, playbook, or machine config being worked on.
2. **Posture assessment** — Broad sweep across the repo and (optionally) live machines.

## Targeted Review

When reviewing a specific piece of IaC, walk through every applicable category from the checklist in `references/checklist.md`. For each:

- State whether it's addressed, partially addressed, or missing.
- If missing, state the risk and suggest a concrete fix (IaC, not manual).
- If not applicable, say so briefly.

Output format: a concise table with Category | Status | Finding | Recommendation columns.

## Posture Assessment

Read `references/checklist.md` for the full checklist. Then:

1. Read all active Ansible roles, playbooks, inventory files, and scripts in the repo.
2. For each machine in the AGENTS.md architecture table, check what the IaC declares against the checklist.
3. Identify gaps — things the IaC doesn't address at all.
4. Produce a prioritized gap report: Critical (actively exploitable or data-loss risk), High (missing standard hardening), Medium (defense-in-depth gaps), Low (nice-to-have).

If the user wants live verification (SSH into machines), confirm before doing so. Compare live state against what IaC declares — flag any drift.

## Principles

- Never recommend security theater. Every recommendation must address a real threat in a self-hosted infrastructure context (e.g., don't recommend WAF for an internal-only service).
- Recommendations must be implementable as IaC. If something can't be automated, flag it as a manual step requiring documentation.
- Consider the threat model: self-hosted infrastructure on a residential network, internet-exposed via VPN tunnel to VPS, iDRAC/BMC on the local network.
- Don't just find problems — prioritize them. A missing firewall rule on an internet-facing service matters more than a missing log rotation config.
