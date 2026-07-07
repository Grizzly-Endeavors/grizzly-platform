# Docs — index

One line per document. See [`README.md`](README.md) for how the docs are organized. Grouped areas have their own index — jump to those for decisions, runbooks, in-progress work, and exploration.

## Reference

- [hardware.md](hardware.md) — machine inventory, specs, live roles.
- [network.md](network.md) — network topology, IPs, tunnels.
- [nodeport-allocation.md](nodeport-allocation.md) — K8s NodePort registry.

## Operations & standup

- [monitoring-integration.md](monitoring-integration.md) — observability stack architecture (Prometheus/Loki/Tempo/Grafana).

## CI Gate

- [ci-gate.md](ci-gate.md) — what the CI gate is (overview).
- [ci-gate-coverage.md](ci-gate-coverage.md) — coverage & threat model.
- *(operator procedures: [runbooks/ci-gate.md](runbooks/ci-gate.md))*

## Networking hardware

- [ex50-dal-interface.md](ex50-dal-interface.md) — Digi EX50 DAL admin CLI interface map.
- [aerohive-cli-reference.md](aerohive-cli-reference.md) — HiveOS CLI quick reference.
- [aerohive-serial-interface.md](aerohive-serial-interface.md) — Aerohive serial/management access notes.
- [ap630-debian-project.md](ap630-debian-project.md) — AP630 Debian-on-aarch64 project (moved to [Grizzly-Endeavors/ap630-debian](https://github.com/Grizzly-Endeavors/ap630-debian)).

## Application integration

- [residuum-feedback-plan.md](residuum-feedback-plan.md) — Residuum feedback-ingest service rollout plan.
- [residuum-feedback-schema.md](residuum-feedback-schema.md) — Postgres schema for feedback ingestion.

## Grouped areas (own index)

- [decisions/INDEX.md](decisions/INDEX.md) — ADRs (why).
- [runbooks/INDEX.md](runbooks/INDEX.md) — operator procedures (how).
- [in-progress/INDEX.md](in-progress/INDEX.md) — active multi-phase work (what's in flight).
- [exploration/INDEX.md](exploration/INDEX.md) — researched-but-not-committed ideas.
- [templates/app-deploy/](templates/app-deploy/) — starter files for deploying a new app to the cluster.
