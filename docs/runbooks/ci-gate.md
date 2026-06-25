# CI Gate — operator runbook

The centralized CI gate: a versioned `grizzly-gate` image runs the checks, cosign
signs passing images, and Kyverno refuses unsigned images at the deploy boundary.
Architecture: [ADR-028](../decisions/028-centralized-ci-gate.md),
registry: [ADR-027](../decisions/027-registry-zot.md).

## Components at a glance

| Piece | Where |
|---|---|
| Gate image + harness | `docker/grizzly-gate/` (Dockerfile, `config/` tree, `harness/`) |
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
   argo submit --from workflowtemplate/build-gate-image -n argo -p version=v0.2.0
   ```
   Thereafter, pushes to `docker/grizzly-gate/**` trigger `build-gate-image.yaml`.
5. **Onboard an app** by copying `deploy-with-gate.yaml.example` and pointing its
   `gate` job at the reusable workflow. Add a root **`gate-config.json`** to the
   app repo honestly mapping its projects (required — the gate fails closed
   without it):
   ```json
   { "version": 1, "projects": [ { "language": "rust", "path": "." } ] }
   ```
   Languages: `rust`/`python`/`node`/`ansible`/`yaml`; `path` must hold that
   adapter's marker; a node project **containing TypeScript must** add
   `"tsconfig": "tsconfig.json"` (drives project-aware typecheck + type-aware
   eslint; the gate fails closed without it). Schema + rationale: [design doc](../ci-gate.md#declaring-the-repo-gate-configjson),
   [ADR-029](../decisions/029-gate-config-honest-map.md). Then label its
   namespace gated:
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
clean, in `verify-gate-signature.yaml` change `failureAction: Audit` → `Enforce`
**and** `mutateDigest: false` → `true` (digest pinning; Kyverno only permits
mutation under Enforce), then commit. Unsigned images are then rejected at
admission.

## Common tasks

- **Change what the gate checks:** edit the relevant tool dir under
  `docker/grizzly-gate/config/<languages|util>/<tool>/` — its `manifest.toml`
  (what runs) and/or its native config file (e.g. `ruff.toml`, `clippy.toml`).
  Bump tool pins in the Dockerfile if needed, cut a new gate tag, then bump
  `gate_version` in callers. The gate's config is authoritative: it is forced
  onto each tool (via flags/env in the manifest) and ignores the repo's own
  config of the same kind.
- **Add support for a new language:** add an adapter dir under
  `config/languages/<lang>/` (`manifest.toml` + native config), give it a
  `[detect]` block (the extensions/shebangs that are mandatory evidence), and
  remove that language from the `detect.toml` `unsupported` denylist if it was
  there. A repo cannot will a language into scope — both halves are Ops changes.
  Update `ci-gate-coverage.md` and cut a new tag.
- **Pin/roll back the gate:** apps set `gate_version:` on the reusable workflow
  `with:`. Roll back by pointing it at a previous tag — no rebuild needed. (Note:
  `gate-config.json` became mandatory in **v0.3.0**; repos pinned to ≤v0.2.0 don't
  need it, repos on ≥v0.3.0 fail closed without it.)
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

**Gate errors before any check runs ("fail closed") →** the honest-map stage
rejected the repo. Common messages and fixes:
- `required gate-config.json not found` — add the file to the repo root.
- `honest-map verification failed … Undeclared code [lang] <path>` — a project of
  that language exists but isn't declared; add it to `projects` (with the
  language's marker present at that path).
- `… Unsupported languages [lang] <path>` — the gate has no adapter for that
  language; it cannot be gated. Either remove the code or have Ops add an adapter
  (see "Add support for a new language").
- `… TypeScript projects missing a tsconfig declaration` — a declared node project
  contains `.ts`/`.tsx` but no `tsconfig`; add `"tsconfig": "<path>"` to it (needed
  for project-aware typecheck + type-aware eslint).
- `declared <lang> project has no <marker>` / `invalid path` / `tsconfig is only
  valid for node` — the declaration is malformed; fix the offending `projects[i]`.

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
