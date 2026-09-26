# ADR-067: Container Runtime — containerd.io from the Docker apt Repo

**Date:** 2026-08-04
**Status:** Accepted
**Relates to:** [ADR-014](014-k8s-cluster-stack.md) (cluster stack), [ADR-068](068-k8s-135-stepped-upgrade.md) (the K8s 1.35 upgrade this unblocked). Part of [#156](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/156).

## Context

The K8s nodes ran containerd from Debian trixie's own `containerd` package, pinned by Debian stable policy to the 1.7.24 branch for the distribution's lifetime. containerd's [Kubernetes support matrix](https://github.com/containerd/containerd/blob/main/RELEASES.md) requires 1.7.28+ for K8s 1.34/1.35 and drops the 1.7 branch entirely at K8s 1.36; upstream 1.7 reaches end-of-life September 2026. Upgrading the cluster off EOL K8s 1.33 (#156) therefore forced a runtime source decision: Debian would never ship a containerd new enough.

## Decision

Install **`containerd.io` from Docker's Debian apt repository** (`download.docker.com/linux/debian`), pinned by exact version in the `k8s-containerd` role and apt-held, rolled across nodes by `ansible/playbooks/upgrade-containerd.yml` (workers serial, control plane last, drain + kubelet stop around the swap).

- The Docker repo packages current containerd majors for Debian stable (2.2.6 at decision time — in-matrix for K8s 1.33 through 1.36) and keeps shipping security updates through apt, so the runtime stays maintainable with the same `apt` operational story as before.
- `containerd.io` declares `Conflicts/Replaces: containerd, runc` and bundles its own runc, so apt performs the swap in one transaction; the role no longer installs Debian's `runc`.
- The version is **pinned and held** rather than floating: the Docker repo mixes containerd major versions in a single `stable` channel, so an unpinned upgrade could jump majors on a routine `apt upgrade`. Bumps go through the role variable + upgrade playbook, with the K8s support matrix checked first.
- The role regenerates `/etc/containerd/config.toml` (schema v3) with the installed binary whenever the on-disk config predates it, then re-applies the two local deviations from upstream defaults: the systemd cgroup driver and the certs.d `config_path` for registry trust. That second one moved here from the k8s-registry-trust role in this change — config.toml needs exactly one owning role, or a regeneration silently drops another role's patch (which is how the first swapped node briefly lost the in-cluster registry mirror). k8s-registry-trust still owns the certs.d directory contents, which containerd re-reads live.

## Alternatives Considered

- **Stay on Debian's 1.7.24** — rejected: below the tested minimum for K8s 1.34/1.35, EOL upstream in September 2026, and permanently frozen by Debian stable policy. Would have recreated the EOL problem #156 existed to fix.
- **`containerd.io` 1.7.29 from the same repo** — satisfies the 1.34/1.35 minimum with a patch-level change, but the branch dies a month later, guaranteeing an immediate second migration. A bandaid.
- **Upstream release tarballs** — gets exact versions without a third-party repo, but loses apt security updates and adds systemd-unit/upgrade plumbing to the role. More surface for no gain over the repo.

## Consequences

- `download.docker.com` is now a trusted package source on every cluster node (GPG-verified, keyring at `/etc/apt/keyrings/docker-apt-keyring.gpg`). One more supply-chain party, accepted for a maintained runtime.
- Runtime upgrades are now deliberate: bump `containerd_version`, verify against the RELEASES.md matrix, run `upgrade-containerd.yml`. Routine `apt upgrade` on nodes cannot move containerd.
- K8s 1.36 (needs containerd 2.2+) requires no further runtime work when its time comes.
- crictl and CNI plugin pins in the role were brought current in the same change (1.35.0 / 1.9.1).
