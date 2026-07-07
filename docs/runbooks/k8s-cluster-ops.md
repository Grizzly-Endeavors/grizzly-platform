# K8s Cluster — Standup, Rejoin & Upgrade

Operator entry point for building, rebuilding, or upgrading the K8s cluster ([ADR-014](../decisions/014-k8s-cluster-stack.md) stack, [ADR-016](../decisions/016-single-control-plane.md) single control plane). Each playbook below is self-documenting — its header has the full usage, prerequisites, and verification steps; this page is the map of *which playbook, in what order*, not a copy of their content.

## Full cluster standup (from bare metal)

Run in order. `dell-inspiron-15` is the control plane; `quanta`/`intel-nuc`/`optiplex` are workers.

1. Image nodes: `scripts/build-worker-iso.sh` (workers) — the control plane node uses `scripts/build-laptop-iso.sh`.
2. `ansible-playbook -l k8s_cluster ansible/playbooks/setup-k8s-worker.yml` — baseline OS config on every node (yes, including the control plane; the name predates that).
3. `ansible-playbook -l k8s_cluster ansible/playbooks/setup-k8s-containerd.yml` — container runtime on every node.
4. `ansible-playbook ansible/playbooks/setup-k8s-control-plane.yml` — kubeadm init + Cilium on `dell-inspiron-15`.
5. `ansible-playbook ansible/playbooks/join-k8s-workers.yml` — join all workers (or `-l <node>` for one).
6. `ansible-playbook ansible/playbooks/setup-k8s-cluster-metrics.yml` — wire cluster metrics into R730xd Prometheus.
7. `ansible-playbook ansible/playbooks/setup-k8s-storage.yml` — democratic-csi storage provisioning.
8. `ansible-playbook ansible/playbooks/setup-k8s-gitops.yml` — Flux bootstrap.
9. `ansible-playbook ansible/playbooks/setup-k8s-cicd.yml` — ARC runners + Argo Workflows.
10. `ansible-playbook ansible/playbooks/setup-k8s-ingress.yml` — ingress-nginx + cert-manager + external access.
11. `ansible-playbook ansible/playbooks/setup-k8s-registry-trust.yml` — containerd trust for the in-cluster registry.
12. `ansible-playbook ansible/playbooks/setup-openbao-k8s-auth.yml` — Kubernetes auth method + ESO wiring on OpenBao.

Each playbook's own header states its specific prerequisites and verification commands — read those before running. The original run of this sequence (with narrative, screenshots-in-prose, and troubleshooting notes from the actual 2026 standup) is archived at [`archive/migration-2026/k8s-cluster-standup.md`](../../archive/migration-2026/k8s-cluster-standup.md) — useful for historical context, not for operating the cluster today.

## Rebuilding or rejoining a single worker

1. Image the node: `scripts/build-worker-iso.sh`.
2. `ansible-playbook -l <node> ansible/playbooks/setup-k8s-worker.yml`
3. `ansible-playbook -l <node> ansible/playbooks/setup-k8s-containerd.yml`
4. `ansible-playbook ansible/playbooks/join-k8s-workers.yml -l <node>`

There is no dedicated node-removal playbook. Draining and removing a node is the standard manual `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` + `kubectl delete node <node>` + `kubeadm reset` on the node itself.

## Upgrading the cluster version

`ansible-playbook ansible/playbooks/upgrade-k8s-cluster.yml` — control plane first, then workers one at a time (`serial: 1`). Update `kubernetes_version` in `ansible/inventory/group_vars/k8s_cluster/k8s.yml` and `cilium_version` in `ansible/roles/k8s-cilium/defaults/main.yml` first; see the playbook's own header for the full prerequisite/verification list. Single control plane means brief API downtime during the control-plane play.
