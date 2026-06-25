# The CI Gate

A centrally-owned, versioned quality-and-supply-chain gate for every project in
the platform — so CI doesn't get rebuilt by hand per repo, and code can ship
without a human reviewing every change, because **the gate is the reviewer**.

This is the design overview. For the *why* see
[ADR-028](decisions/028-centralized-ci-gate.md) and
[ADR-027](decisions/027-registry-zot.md); to *operate* it see
[the runbook](runbooks/ci-gate.md); for exactly *what failure modes and vulnerability classes it prevents* (per tool, plus the gaps it doesn't) see [the coverage & threat model](ci-gate-coverage.md).

## The problem

Every app repo hand-rolled its own CI. Lint/test steps drifted between repos,
several had no checks at all, and nothing verified what actually got deployed —
Flux and the kubelet would run any image that landed in the registry. Giving an
agent freedom to merge and deploy meant either trusting it blindly or reviewing
everything by hand. Neither scales.

## The shape

```
  app repo CI
  ┌──────────────────────────────────────────────────────────────┐
  │ build ──► push image to registry (by digest)                  │
  │                          │                                     │
  │                          ▼                                     │
  │   ┌────────────────────────────────────────────────┐          │
  │   │  grizzly-gate  (one versioned image)            │          │
  │   │   • language adapters  (fmt / lint / test)      │          │
  │   │   • SAST + secret + dependency scan             │          │
  │   │   • image SBOM + CVE scan                        │         │
  │   │            │ pass?                               │          │
  │   │            ▼                                     │          │
  │   │   cosign sign  (the image DIGEST)               │          │
  │   └────────────────────────────────────────────────┘          │
  │                          │                                     │
  │                          ▼                                     │
  │ bump deploy tag ──► Flux reconciles                            │
  └──────────────────────────┬───────────────────────────────────┘
                             ▼
              Kyverno admission (deploy boundary)
        verify the gate signature ─► admit / refuse
```

### Six principles

1. **The gate is a versioned artifact, not a service.** It's a container image
   holding the orchestration harness, the per-language adapters, and the pinned
   scanners. One thing Ops owns and versions. Update the gate = push a new tag;
   the rules live in one place instead of copy-pasted into N pipelines where
   they drift.

2. **It runs against CI's output, not a repo it ingests.** CI already cloned and
   built. A "service that takes a repo" would re-do that work in a stateful,
   bottlenecked box. The gate runs against the source tree and the built image
   that CI hands it.

3. **Rules are data, and the config is the gate's.** The harness (a small Rust
   binary) executes a declarative `config/` tree — one self-describing dir per
   tool under `languages/` (`Cargo.toml` → `cargo fmt`/`clippy -D warnings`/
   `deny`/`test`; `pyproject.toml` → `ruff`/`mypy`/`pytest`; …) and `util/`
   (gitleaks, a Semgrep ruleset, Trivy for image SBOM/CVEs, and cross-ecosystem
   dependency SCA via osv-scanner + Trivy fs).
   Each dir carries a `manifest.toml` (what to run) next to the tool's own
   native config; the manifest forces that gate-owned config onto the tool (via
   `--config`/`--config-file`/`CLIPPY_CONF_DIR`/…), so a repo's own config
   **cannot weaken the checks** — the gate is the reviewer, not the repo. It
   fails closed: zero checks run ⇒ fail.

4. **A pass produces a signature, and the signature is the only proof that
   travels forward.** On a clean pass the gate cosign-signs the image *digest*.
   This decouples "the checks ran" from "this is allowed to deploy" — the
   signature is portable proof that survives all the way to the cluster.

5. **Enforcement is admission at the deploy boundary.** Kyverno verifies the
   signature and refuses any image that lacks a valid one. "Checks passed" is no
   longer a property of a CI log you have to trust — it's a cryptographic fact
   the cluster checks for itself.

6. **The repo declares its map; the gate verifies it.** Principle 3 stops a repo
   *weakening* the rules; this stops a repo *escaping their scope*. A green gate
   must mean every line was checked, not just the code at the root. So every
   gated repo ships a required `gate-config.json` honestly mapping its projects,
   and the harness independently walks the tree and **fails closed** on any
   undeclared code (a `.py` no project covers) or unsupported language (one the
   gate has no adapter for). The walk is hostile by construction — it ignores the
   repo's `.gitignore`, doesn't follow symlinks, and has no repo-controlled
   exclusions — because hiding code from the gate is exactly the evasion it
   closes. See [ADR-029](decisions/029-gate-config-honest-map.md).

## Declaring the repo: `gate-config.json`

Every gated repo ships this file at its root. It declares *where* each project
lives and *what language* it is — nothing that can relax a check:

```json
{
  "version": 1,
  "projects": [
    { "language": "rust",   "path": "." },
    { "language": "python", "path": "services/api" },
    { "language": "node",   "path": "web", "tsconfig": "tsconfig.json" }
  ]
}
```

- `language` — a known adapter: `rust`, `python`, `node`, `ansible`, `yaml`.
- `path` — the project directory, relative and in-tree (`.` is the root). The
  adapter's marker (`Cargo.toml`, `pyproject.toml`, `package.json`, `ansible/`,
  `.yamllint`) must exist there, or it's a declared-but-empty lie and fails.
- `tsconfig` — node only: the repo's own tsconfig. The gate wraps it so its
  module/path resolution is honored (for both project-aware `tsc` *and*
  type-aware eslint) while the gate force-overrides strictness — the repo cannot
  weaken the type bar. **Required for any node project containing TypeScript**
  (type-aware linting needs the type program; the gate fails closed without it);
  a JS-only project may omit it.

The harness then verifies the map: any `.rs`/`.py`/TS/JS file not covered by a
matching declared project fails the gate, and any code in an un-adapted language
(Go, Ruby, …) hard-fails — the only fix is Ops adding an adapter. `ansible` and
`yaml` stay opt-in markers (a bare `.yml` is data as often as IaC), but can be
declared to run at a sub-path.

## How a repo uses it

The repo's CI calls one reusable workflow after it builds (and ships a
`gate-config.json` at its root, per above):

```yaml
jobs:
  build:   # build + push by digest, emit the digest
    ...
  gate:
    needs: build
    uses: grizzly-endeavors/grizzly-platform/.github/workflows/gate.yaml@master
    with:
      image: <registry>/myapp@${{ needs.build.outputs.digest }}
      gate_version: v0.3.0            # pin the gate
  deploy:
    needs: gate                       # only runs if the gate signed it
    ...
```

That's the whole integration. The gate owns the checks; the app repo owns
build + deploy. A full example lives in
`.github/templates/ci/deploy-with-gate.yaml.example`.

## Trust model

- **Key-based cosign**, private key in the platform secret store (OpenBao),
  delivered to CI runners by External Secrets. The public key is embedded in the
  Kyverno policy. (Keyless/Sigstore was considered and deferred — see ADR-028.)
- Enforcement is **scoped** to namespaces labelled `grizzly.io/gated=true`, so
  third-party/upstream images that the gate can't sign are unaffected.
- Rollout is staged: the policy ships in **Audit** (report-only) and flips to
  **Enforce** once live images are signed.

## What this platform builds it on

| Concern | Choice |
|---|---|
| Run the gate | existing self-hosted runners (ARC) via the DinD sidecar |
| Build the gate image | existing Argo Workflows + Kaniko |
| Registry (signature storage) | zot (OCI 1.1 referrers) |
| Signing key | OpenBao + External Secrets |
| Deploy boundary | Kyverno `verifyImages` |
| Delivery | Flux GitOps |

None of these are required to adopt the *pattern* — the five principles port to
any CI + registry + admission-controller stack. This repo is one concrete
instance of it.

## Deliberately deferred (v1)

- **DAST / live probe** of the running container — the harness is structured for
  it, but it's not wired yet.
- **SBOM attestation** — v1 signs; it doesn't yet attach/verify an SBOM
  attestation.
- **Platform policy rules at admission** (required probes, resource requests,
  naming/ingress conventions) — scaffolded but disabled.
- **Registry auth** — zot is anonymous/in-cluster for now; auth is a separate
  change because it ripples into every image pull/push path (ADR-027).
