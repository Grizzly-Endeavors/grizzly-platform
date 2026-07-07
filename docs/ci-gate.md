# The CI Gate

The gate's **design overview moved** to its own repository, alongside the source:

**https://github.com/Grizzly-Endeavors/grizzly-gate** — the README is the design overview; `docs/coverage.md` is the coverage & threat model.

This platform *consumes* that gate. The integration lives here:

- **Build:** `kubernetes/infrastructure/argo-workflows/build-gate-image.yaml` clones the grizzly-gate repo and builds the image in-cluster via rootless BuildKit.
- **Run:** apps call the reusable [`.github/workflows/gate.yaml`](../.github/workflows/gate.yaml) after building; on a clean pass the gate cosign-signs the image digest. Example: [`deploy-with-gate.yaml.example`](../.github/templates/ci/deploy-with-gate.yaml.example).
- **Enforce:** Kyverno (`kubernetes/infrastructure/kyverno{,-policies}/`) refuses unsigned images at admission in namespaces labelled `grizzly.io/gated=true`.
- **Operate:** [`docs/runbooks/ci-gate.md`](runbooks/ci-gate.md) — bootstrap, Audit→Enforce rollout, key rotation, gate version bump.

## Links

- Design overview → https://github.com/Grizzly-Endeavors/grizzly-gate
- Coverage & threat model → https://github.com/Grizzly-Endeavors/grizzly-gate/blob/master/docs/coverage.md
- ADRs (the platform's decision record, kept here): [028 centralized gate](decisions/028-centralized-ci-gate.md), [029 honest map](decisions/029-gate-config-honest-map.md), [030 cross-ecosystem SCA](decisions/030-cross-ecosystem-sca.md), [027 registry/zot](decisions/027-registry-zot.md).
