# Integration: deploying your app to the cluster

**What you get:** your app running on the homelab Kubernetes cluster, GitOps-managed by Flux, with a public HTTPS URL at `<app>.grizzly-endeavors.com` — and after the one-time onboarding, **zero-touch deploys**: push to `main`, your image builds, passes the CI gate, and Flux rolls it out within a minute.

This is the delivery model from [ADR-020](../decisions/020-app-delivery-model.md). It's the prerequisite for every other guide here — an app has to be *on* the cluster before it can consume Postgres, secrets, SSO, etc.

## The model in one picture

- **Your app repo owns its `deploy/` directory** (a Helm chart by default) and its CI.
- **grizzly-platform tracks your app** as a thin `GitRepository` + `Kustomization`/`HelmRelease` under `kubernetes/apps/<app>/`.
- **Tag bumps happen in your app's CI**, not via Flux image automation. Every deploy after the first is zero-touch on grizzly-platform.

## 1 — Bootstrap from the template

```bash
gh repo create grizzly-endeavors/<app> \
  --template grizzly-endeavors/app-deploy-template --private
```

The template gives you a working `deploy/` Helm chart and the CI wiring. Fill in your app; keep the `deploy/` dir (register-app refuses to onboard a repo without one).

## 2 — Register with Flux (one-time)

From your new repo's **Actions** tab, dispatch the `deploy` workflow once with your inputs. It calls the reusable [`register-app.yaml`](../../.github/workflows/register-app.yaml) in this repo, which:

1. Verifies your repo has a `deploy/` dir.
2. Renders `kubernetes/apps/<app>/` (namespace + `GitRepository` + `HelmRelease`) from templates.
3. Appends `<app>` to `kubernetes/apps/kustomization.yaml`.
4. Validates with `kubectl kustomize` and opens an **auto-merging** PR.

`app_name` and `namespace` must be **DNS-1123** (lowercase alphanumeric + hyphens). Flux starts reconciling within a minute of merge.

## 3 — Every subsequent deploy is automatic

Push to `main` → your CI builds the image, runs the **CI gate**, and on pass bumps the image tag in `deploy/values.yaml`. Flux sees the change and reconciles. You don't touch grizzly-platform again.

### The CI gate is not optional

Images are admitted only if signed. The versioned `grizzly-gate` image runs per-language checks + SCA against your code and, on pass, **cosign-signs the image digest**; **Kyverno refuses unsigned images at admission** ([ADR-028](../decisions/028-centralized-ci-gate.md)). So a build that skips or fails the gate produces an image the cluster will *not* run — `ImagePullBackOff`-adjacent admission denials, not a silent deploy of unverified code. Wire the gate into your CI per [ci-gate.md](../runbooks/ci-gate.md); don't try to route around it.

Builds run on the self-hosted ARC runners; images push to the in-cluster Zot registry.

## 4 — Ingress & TLS

Public traffic reaches the cluster over: VPS Caddy → WireGuard tunnel → R730xd DNAT → NodePort → ingress-nginx ([ADR-019](../decisions/019-ingress-and-tls-termination.md)). To get a public URL, add an Ingress to your chart with the class and a `<app>.grizzly-endeavors.com` host; cert-manager issues the TLS cert via the Let's Encrypt DNS-01 solver. Confirm the Caddy wildcard-domain path covers your host (the Caddy config is a wildcard-domain list — a genuinely new host may need a line added).

## 5 — Wire in what your app consumes

Now layer on the other integrations, each in its own guide:

- Database → [postgres.md](postgres.md) · Cache → [valkey.md](valkey.md) · Blobs → [s3.md](s3.md)
- Credentials in your namespace → [secrets.md](secrets.md)
- Login → [sso.md](sso.md) · Transactional mail → [mail.md](mail.md)
- Logs/metrics/traces → [observability.md](observability.md)

Provision the foundation-side resources with a `setup-<app>-stores.yml` play (model on `setup-career-scanner-stores.yml`) before the app expects them.

## Verify

```bash
kubectl get kustomization <app> -n flux-system      # READY=True
kubectl get helmrelease <app> -n flux-system        # READY=True
kubectl get pods -n <app>
curl -I https://<app>.grizzly-endeavors.com
```

## Troubleshoot

- **register-app PR never opened** — repo has no `deploy/` dir, or `app_name`/`namespace` isn't DNS-1123. Check the workflow run logs.
- **`kubernetes/apps/<app>` already exists** — the app is already registered; register-app refuses to clobber. Remove the folder to re-onboard.
- **Pods stuck, admission denied on the image** — the image isn't cosign-signed (CI gate skipped/failed). Fix CI so the gate signs the digest; Kyverno won't admit an unsigned image ([ci-gate.md](../runbooks/ci-gate.md)).
- **HelmRelease not READY** — `kubectl describe helmrelease <app> -n flux-system` and `flux logs`; usually a chart values error or an image tag that isn't in the registry yet.
- **URL doesn't resolve / TLS fails** — Caddy wildcard host not covered, or cert-manager hasn't issued yet (`kubectl get certificate -n <app>`).

## See also

- [`docs/templates/app-deploy/README.md`](../templates/app-deploy/README.md) — the bootstrap pointer.
- [ci-gate.md](../runbooks/ci-gate.md) — **operator** runbook for the gate; [k8s-cluster-ops.md](../runbooks/k8s-cluster-ops.md) for the cluster itself.
- ADR [020](../decisions/020-app-delivery-model.md) (delivery model), [028](../decisions/028-centralized-ci-gate.md) (CI gate), [019](../decisions/019-ingress-and-tls-termination.md) (ingress/TLS), [027](../decisions/027-registry-zot.md) (registry).
