# Runbooks — index

One line per runbook. See [`README.md`](README.md) for what runbooks are and when to reach for one.

## Secrets (OpenBao)

- [openbao-quickref.md](openbao-quickref.md) — addresses, paths, policies, auth methods, path layout, rotate/add how-tos. **Start here for secrets.**
- [openbao-add-secret.md](openbao-add-secret.md) — adding a secret from the control node's persistent root session.
- [openbao-rotation.md](openbao-rotation.md) — unseal-key rotation procedure.
- [openbao-disaster-recovery.md](openbao-disaster-recovery.md) — recovering OpenBao from a sealed/lost state.
- [secrets-migration.md](secrets-migration.md) — Phase A–E guide for moving consumers onto OpenBao.

## Mail (Stalwart)

- [mail.md](mail.md) — deployment status, architecture, and operator runbook for the mail stack. **Start here for mail.**
- [stalwart-cli.md](stalwart-cli.md) — driving Stalwart's schema-driven config CLI (verbs, object model, recipes).

## Storage (versitygw S3)

- [versitygw-deploy.md](versitygw-deploy.md) — how the s3-hot / s3-bulk gateways are stood up and operated.
- [versitygw-cli.md](versitygw-cli.md) — driving the versitygw tool (accounts, buckets, IAM).

## CI Gate

- [ci-gate.md](ci-gate.md) — bootstrap, Audit→Enforce rollout, key rotation, gate version bump, deploy-denied diagnosis.

## Identity / invites

- [invite-authentik-reader.md](invite-authentik-reader.md) — the Authentik read-only group reader backing the invite console.

## Notifications

- [ntfy.md](ntfy.md) — self-hosted ntfy push-notification service (users, tokens, topic access, ops).

## Cluster

- [k8s-cluster-ops.md](k8s-cluster-ops.md) — full standup, single-node rebuild/rejoin, and version upgrade sequences.

## Network / hardware

- [garage-relocation-cutover.md](garage-relocation-cutover.md) — staged garage relocation + EX50 router cutover plan and checkpoints.
- [ex50-console-access.md](ex50-console-access.md) — reaching the Digi EX50 CLI during bench bring-up.
- [aerohive-ap-setup.md](aerohive-ap-setup.md) — standalone WiFi setup for the AP630 + AP130.
- [sr2024-vlan-trunks.md](sr2024-vlan-trunks.md) — converting the SR2024 uplink ports to VLAN trunks for downstream WiFi segmentation.
