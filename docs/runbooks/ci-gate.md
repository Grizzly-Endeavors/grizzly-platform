# CI Gate — operator runbook

The centralized CI gate: a versioned `grizzly-gate` image runs the checks, cosign
signs passing images, and Kyverno refuses unsigned images at the deploy boundary.
Architecture: [ADR-026](../decisions/026-centralized-ci-gate.md),
registry: [ADR-027](../decisions/027-registry-zot.md).

## Components at a glance

| Piece | Where |
|---|---|
| Gate image + harness | `docker/grizzly-gate/` (Dockerfile, `gate.toml`, `harness/`) |
| Gate build | `kubernetes/infrastructure/argo-workflows/build-gate-image.yaml` + `.github/workflows/build-gate-image.yaml` |
| Reusable CI job | `.github/workflows/gate.yaml` (called by apps; see `.github/templates/ci/deploy-with-gate.yaml.example`) |
| Signing key | OpenBao `secret/grizzly-platform/cicd/cosign`; ESO → `cosign-signing-key` in `arc-runners` |
| Deploy boundary | `kubernetes/infrastructure/kyverno/` + `kubernetes/infrastructure/kyverno-policies/` |
| Registry | zot, `kubernetes/infrastructure/registry/` |

## Bootstrap (one-time, in order)

1. **Cut over the registry to zot first — with image migration.**

   ⚠️ **zot and `registry:2.8.3` use incompatible storage layouts.** Flipping the
   Service to zot does *not* carry the existing images over — zot starts empty.
   Already-running pods keep their cached images (`IfNotPresent`), but the runner
   image is `imagePullPolicy: Always`, so a new runner pod would `ImagePullBackOff`
   and CI would stall; any rescheduled app pod would fail to pull too. So migrate
   the images as part of the cutover, in a low-activity window:

   ```sh
   # a) Mirror existing images from the old registry INTO zot before flipping.
   #    Run zot at a temporary second Service/port, or migrate post-flip and accept
   #    a short pull-gap. Simplest: post-flip re-push via the build pipelines.
   #
   # b) After Flux reconciles zot:
   kubectl -n registry rollout status deploy/registry
   # c) Rebuild the runner image into zot (Argo pods don't need the runner image):
   argo submit --from workflowtemplate/build-runner-image -n argo
   #    then re-run each app's CI (or `skopeo copy` each image old→new) so every
   #    referenced tag exists in zot.
   ```

   Verify pulls resolve once images are present:
   ```sh
   kubectl -n registry get pods
   kubectl get pods -A | grep -i imagepull   # expect none lingering after migration
   ```

   **Rollback:** `git revert` the registry commit and push — Flux restores
   `registry:2.8.3`, which still has its original data at the old storage paths
   (zot wrote elsewhere), so the previous state returns intact.
2. **Generate the cosign keypair and store it in OpenBao:**
   ```sh
   COSIGN_PASSWORD=<pw> cosign generate-key-pair   # -> cosign.key, cosign.pub
   bao kv put secret/grizzly-platform/cicd/cosign \
     private_key=@cosign.key password=<pw> public_key=@cosign.pub
   ```
   ESO syncs `cosign-signing-key` into `arc-runners` within the refresh interval.
   Confirm: `kubectl -n arc-runners get secret cosign-signing-key`.
3. **Put the public key in the Kyverno policy.** Replace the placeholder block in
   `kubernetes/infrastructure/kyverno-policies/verify-gate-signature.yaml` with the
   contents of `cosign.pub`, commit. (Public key is not secret.)
4. **Build the gate image.** First build is manual (runners may scale from zero):
   ```sh
   argo submit --from workflowtemplate/build-gate-image -n argo -p version=v0.1.0
   ```
   Thereafter, pushes to `docker/grizzly-gate/**` trigger `build-gate-image.yaml`.
5. **Onboard an app** by copying `deploy-with-gate.yaml.example` and pointing its
   `gate` job at the reusable workflow. Label its namespace gated:
   ```sh
   kubectl label namespace <app> grizzly.io/gated=true --overwrite
   ```

## Rollout: Audit → Enforce

`verify-gate-signature` ships with `failureAction: Audit` (report-only).

```sh
kubectl get clusterpolicy verify-gate-signature
kubectl get clusterpolicyreport,policyreport -A          # see what would be blocked
```

Once every live first-party image in gated namespaces is signed and reports are
clean, change `failureAction: Audit` → `Enforce` in the policy and commit.
Unsigned images are then rejected at admission.

## Common tasks

- **Change what the gate checks:** edit `docker/grizzly-gate/gate.toml` (and tool
  pins in the Dockerfile), cut a new gate tag, then bump `gate_version` in callers.
- **Pin/roll back the gate:** apps set `gate_version:` on the reusable workflow
  `with:`. Roll back by pointing it at a previous tag — no rebuild needed.
- **Rotate the signing key:** generate a new keypair, `bao kv put` it (step 2),
  update the public key in the policy (step 3), rebuild nothing — re-sign images on
  next CI run. Keep Audit until everything is re-signed under the new key, then
  Enforce. Old signatures under the retired key fail verification by design.
- **Add a policy exception (third-party / can't-sign image):** keep the consuming
  namespace **unlabelled** (`grizzly.io/gated` absent) — the policy only matches
  gated namespaces. For a one-off in a gated namespace, add a digest to an
  `exclude` block on the rule (document why).

## Troubleshooting

**"Gate failed" in CI →** read the job log; the harness prints a PASS/FAIL summary
table. The failing adapter/scanner name points at the cause (clippy, gitleaks,
trivy CVE, etc.). No signature is produced, so deploy won't proceed.

**Gate job errors with "cosign signing material not present" →** the
`cosign-signing-key` secret isn't synced. Check ESO:
```sh
kubectl -n arc-runners get externalsecret cosign-signing-key
kubectl -n arc-runners describe externalsecret cosign-signing-key   # SecretSynced?
```
Then confirm the OpenBao path exists (`bao kv get secret/grizzly-platform/cicd/cosign`).

**Deploy denied at admission (Enforce) →**
```sh
kubectl get events -n <app> --field-selector reason=PolicyViolation
kubectl describe clusterpolicy verify-gate-signature
```
Usual causes: image wasn't signed (gate didn't pass / wasn't run), the public key
in the policy is stale or still the placeholder, or the namespace was labelled
gated before its images were signed. Verify manually:
```sh
cosign verify --key cosign.pub --allow-insecure-registry \
  registry.registry.svc.cluster.local:5000/<app>@<digest>
```

**All deploys to gated namespaces hang/fail, gate unrelated →** Kyverno may be
down (`failurePolicy: Fail`). `kubectl -n kyverno get pods`; the `KyvernoDown`
alert covers this.

## Operational readiness

- **Health:** `kubectl -n kyverno get pods`, `kubectl -n registry get pods`;
  `kubectl get clusterpolicy`. Gate health = the CI job status.
- **Metrics:** zot `/metrics` (Prometheus `registry-zot` job) and Kyverno
  (`kyverno` job via NodePort 30888). Dashboards/alerts in
  `ansible/roles/r730xd-prometheus`.
- **Alerts:** `ZotRegistryDown` (critical), `KyvernoDown` (critical — blocks
  admission), `GateSignatureVerificationFailing` (warning).
- **Logs:** gate → CI run logs; Kyverno decisions → `kubectl -n kyverno logs` +
  Pod events on denied workloads; zot → `kubectl -n registry logs`.
- **Dependencies:** gate needs runners + zot + (to sign) OpenBao/ESO; Kyverno needs
  the cosign public key in-policy and reachable zot. The deploy boundary depends on
  Kyverno being up.
- **Recovery:** all components are Flux-reconciled Deployments/HelmReleases —
  delete a pod and it reschedules. The signing key and policy public key are the
  only stateful, operator-managed pieces (rotation above).
