# Archive

This directory contains archived infrastructure configurations that are no longer actively used but are preserved as portfolio material demonstrating skills progression.

## Why These Are Archived

The configurations in this archive were part of the homelab's evolution from a Proxmox-based virtualization playground to dedicated bare-metal Kubernetes infrastructure. The original laptop running Proxmox has been retired, and the infrastructure now runs on dedicated hardware (Dell OptiPlex nodes).

## Contents

### proxmox-playground/

Infrastructure as Code for provisioning a Kubernetes cluster on Proxmox VE:

- **Terraform**: Automated VM provisioning on Proxmox
- **Packer**: Custom Debian template images with cloud-init
- **Shell Scripts**: Cluster deployment and teardown automation
- **Documentation**: Setup guides and workflows

### migration-docs/

Documentation from the migration process to the current bare-metal infrastructure:

- Migration planning documents
- Step-by-step migration guides
- Integration documentation

### pre-migration-2026/

Repo state as it stood immediately before the 2026 Docker-Compose-and-bare-metal → Kubernetes migration kicked off.

### staging-vm/

The staging VM's historical create/deploy/destroy playbooks, used as a bridge during Phase 7b app migration (ADR-002, Superseded).

### migration-2026/

The full 2026 migration record — the phased plan as executed, role-assignment rationale, and the original K8s cluster standup build log. See [migration-2026/README.md](migration-2026/README.md).

### palworld-udp-forwarding.md

UDP port-forwarding notes for a Palworld server that's been decommissioned (ADR-022).

### Completed side-project docs

Rollout plans and one-off notes for finished, self-contained work — kept for the record rather than as live references:

- **ap630-debian-project.md** — the AP630 Debian port; project moved to its own repo and archived (ADR-011).
- **residuum-feedback-plan.md**, **residuum-feedback-schema.md** — the feedback-ingest service's rollout plan and DB schema design; the service has been live since 2026-04-17.

## Skills Demonstrated

These archived materials showcase:

- **Infrastructure as Code**: Terraform modules, state management, provider configuration
- **Image Building**: Packer templates with cloud-init integration
- **Virtualization**: Proxmox VE API automation
- **Kubernetes**: Cluster bootstrapping and configuration
- **Automation**: Shell scripting for deployment workflows
- **Documentation**: Technical writing and architectural planning

## Note

This archive is preserved as a portfolio piece showing the progression from a virtualized playground environment to production-grade bare-metal infrastructure. The current active infrastructure configurations are in the root of this repository.
