# Kyverno policies — the deploy boundary

These ClusterPolicies are the enforcement half of the CI gate. They're applied
by their own Flux Kustomization (`clusters/grizzly-platform/kyverno-policies.yaml`,
`dependsOn: infrastructure`) so Kyverno's CRDs are installed first.

## verify-gate-signature

Refuses to admit first-party images that lack a valid `grizzly-gate` cosign
signature. The signature is the only proof that the gate's checks ran and
passed — see `docs/decisions/` (CI gate + Kyverno admission ADRs).

**Scope:** only namespaces labelled `grizzly.io/gated: "true"`. Third-party /
upstream images (lab-apps) live in unlabelled namespaces and are unaffected.

```sh
kubectl label namespace <app-ns> grizzly.io/gated=true
```

## Rollout: Audit → Enforce

1. Policy ships with `failureAction: Audit` (report-only). Observe PolicyReports:
   ```sh
   kubectl get clusterpolicyreport,policyreport -A
   kubectl describe clusterpolicy verify-gate-signature
   ```
2. Sign every live first-party image (re-run each app's gate).
3. Once reports are clean, flip `failureAction: Audit` → `Enforce` in
   `verify-gate-signature.yaml` and commit. Unsigned images are then rejected
   at admission.

## Bootstrap dependency

The policy embeds the gate's cosign **public** key. The committed file ships a
placeholder; replace it with the real `cosign.pub` during bootstrap (see
`docs/runbooks/ci-gate.md`). Until then the policy will fail verification for
all matched images — keep it in Audit until the key is in place.

## platform-rules.yaml.disabled

Scaffold for the deferred policy phase (probes, resource requests, ingress and
naming conventions). Not active; not listed in `kustomization.yaml`.
