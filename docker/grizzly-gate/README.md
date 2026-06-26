# grizzly-gate moved

The CI gate's source (Dockerfile, `config/` tree, Rust `harness/`) now lives in its own public repository:

**https://github.com/Grizzly-Endeavors/grizzly-gate**

It was extracted from this path so the gate can be shared and read on its own. The platform still owns the integration:

- **Build:** `kubernetes/infrastructure/argo-workflows/build-gate-image.yaml` clones the grizzly-gate repo and builds it in-cluster via Kaniko. The trigger workflow now lives in that repo (`.github/workflows/build-gate-image.yaml`).
- **Consume:** apps call the reusable `.github/workflows/gate.yaml` (unchanged); Kyverno enforces the signature at admission.
- **Operate:** see [`docs/runbooks/ci-gate.md`](../../docs/runbooks/ci-gate.md).
