# CI Gate — Coverage & Threat Model

What the `grizzly-gate` image actually prevents, given the configs currently in `docker/grizzly-gate/config/`. This is the threat-coverage companion to the [design overview](ci-gate.md) and the [operator runbook](runbooks/ci-gate.md). Every claim here is traceable to a specific manifest, lint level, or scanner config in the tree — when the config changes, this doc must change with it.

The gate is the reviewer: a green gate is what lets an agent (or a human) ship without a second pair of eyes on the diff. So the question this doc answers is "what can no longer reach production unnoticed?" — broken into the structural guarantees that hold regardless of language, then the per-tool coverage, then an honest list of what the gate does *not* catch.

## Threat model in one paragraph

The gate sits between "an agent or contributor produced code + a built image" and "that image runs in the cluster." It assumes the author may be careless, may be an LLM taking every shortcut not explicitly denied, or may be actively hostile to the quality bar — both *weakening* the checks (relaxing the repo's own lint config, which config-forcing blocks) and *escaping* their scope (hiding code in a subdir, behind `.gitignore`, or in an un-adapted language, which the mandatory `gate-config.json` honest map blocks). It does **not** assume a compromised gate image or a compromised signing key — those are supply-chain trust roots handled by pinning + OpenBao + Kyverno, not by the checks themselves. The output is a single cosign signature over the image **digest**; everything downstream trusts that signature and nothing else.

## Structural guarantees (independent of language)

These are the properties the harness and image enforce no matter what code is being gated. They are the load-bearing ones — a gap here defeats every per-tool check below.

- **Fail-closed on empty/missing config.** `load_tree` (`harness/src/config.rs`) bails if the config root yields zero manifests (or the required `detect.toml` is absent), and `main.rs` bails if `run_checks` produced zero results. A gate that ran nothing can never report PASS. This blocks the "delete the rules to pass the gate" and "point the gate at an empty dir" failure modes.
- **Honest-map verification — scope cannot be escaped.** Every gated repo must ship a root `gate-config.json` declaring its projects (missing/malformed ⇒ fail closed), and the harness (`detect.rs`) independently walks the *whole* tree and fails closed on any **undeclared** adapter-backed code (a `.rs`/`.py`/TS/JS file no declared project covers) or any **unsupported** language (code the gate has no adapter for — Go, Ruby, …). The walk does not honor the repo's `.gitignore`, does not follow symlinks, matches extensions case-insensitively, and shebang-classifies extensionless scripts — so a repo cannot hide code in a subdir, behind `.gitignore`, under a renamed extension, or in an un-adapted language. There are **no repo-controlled exclusions** (the master evasion key); only an Ops-owned `skip_dirs` list (deps/build/VCS) is skipped, and those paths are still secret/SAST-scanned. Adapters then run **per declared project** (in each project's dir), not just at the root. This is the guarantee that makes "green gate = every line was checked" true rather than "the code at the root was checked" — it closes what was previously the largest gap (see [ADR-029](decisions/029-gate-config-honest-map.md)). Adding a new language is therefore a deliberate two-part Ops change: an adapter under `languages/` *and* its detection rules — a repo cannot will a language into scope.
- **Config forcing — the repo cannot relax the rules.** Every adapter and scanner is invoked with the gate's own config injected via `{config}` (`--config`, `--config-path`, `--config-file`, `-c`, `CLIPPY_CONF_DIR`, `--no-config-lookup`). The scanned repo's own `.clippy.toml`, `ruff.toml`, `tsconfig.json`, `.yamllint`, `.gitleaks.toml`, `deny.toml`, etc. are ignored. This is the central anti-shortcut guarantee: an author cannot weaken the bar by editing config in their own repo, because that config is never read. Rust lint *levels* are forced on the command line specifically because `Cargo.toml [lints]` is applied earlier by rustc and would otherwise win.
- **Deterministic, reproducible checks.** Every tool version is pinned in the `Dockerfile` (no floating tags). The Trivy vuln DB and the Semgrep ruleset are baked into the image at build time — scans run offline, so the same gate tag produces the same verdict regardless of when it runs or what a registry serves that day. (One acknowledged exception: `SEMGREP_RULES_REF=develop` is a branch, not a SHA — flagged as a TODO in the Dockerfile.)
- **Signature binds to the digest, not a tag.** The gate signs `app@sha256:...`. A tag can be re-pointed at a different image after the fact; a digest cannot. This closes the "gate passes image A, deploy swaps in image B under the same tag" TOCTOU gap.
- **Signing happens only after all checks pass.** `--sign` is reached only past the `failed > 0` bail in `main.rs`. There is no code path that signs a failing build.
- **Self-contained signing.** `cosign sign --tlog-upload=false` — no dependency on (and no digest leakage to) the public Rekor log; verification is key-based against the public key embedded in the Kyverno policy.
- **Admission enforcement is separate from the gate.** Kyverno (`kubernetes/infrastructure/kyverno-policies/`) refuses unsigned images in namespaces labelled `grizzly.io/gated=true`. Even if someone pushes an unsigned or gate-skipped image straight to zot, it cannot be admitted. The gate produces the proof; Kyverno is the wall.

## Per-tool coverage

### Secret scanning — gitleaks (source scope, always runs)

`gitleaks detect --redact --exit-code 1` over the source tree with the default ruleset (`useDefault = true`). Prevents committed credentials from reaching the repo/registry unnoticed: cloud keys (AWS/GCP/Azure), private keys, GitHub/GitLab tokens, Slack/Stripe/Twilio tokens, generic high-entropy assigned secrets, and `.env`-style leaks. `--redact` keeps the secret value out of CI logs so the scan itself doesn't leak it. Runs on every invocation regardless of language markers, so even a repo the gate has no adapter for still gets secret-scanned.

### SAST — semgrep (source scope, always runs)

`semgrep scan --error` against the vendored `semgrep-rules` set (offline). This is the broad source-level vulnerability net across languages. Concretely it catches the OWASP-style classes that rules exist for: injection (SQL/command/template), unsafe deserialization, weak/again-broken crypto (MD5/SHA1, ECB, hardcoded IVs), SSRF patterns, path traversal, insecure temp-file creation, use of `eval`/`exec` on untrusted input, disabled TLS verification, XXE, and framework-specific footguns. Because it runs unconditionally, it covers languages with no dedicated adapter too. (Note: the harness's own test suite carries a scoped `// nosemgrep: temp-dir` with a written reason — the sanctioned way to suppress a finding, not a blanket allow.)

### Image CVE/SBOM — trivy (image scope, runs only with `--image`)

`trivy image --exit-code 1` failing on **HIGH** and **CRITICAL** vulnerabilities across both `os` and `library` package types. Prevents shipping a container whose base image or bundled dependencies carry known-exploitable CVEs. `ignore-unfixed: true` is a deliberate trade: unfixable vulns don't block deploys indefinitely (they aren't actionable at gate time), so the gate enforces "patch what's patchable," not "zero CVEs." This is the only check that inspects the built artifact rather than the source — it's what stops a clean-source repo from shipping a rotten base image.

### Rust dependency audit — cargo-deny (`Cargo.toml` marker)

`cargo deny check` with a fleet-wide config carrying **no advisory ignore list**. Prevents: dependencies with active RUSTSEC advisories (vulnerable crates), **unmaintained** crates, **yanked** versions (`yanked = "deny"`), wildcard version requirements (`wildcards = "deny"` — they defeat reproducible resolution and are a supply-chain risk), dependencies pulled from **unknown registries or git sources** (`unknown-registry`/`unknown-git = "deny"`, allow-list restricted to crates.io), and crates under licenses outside the vetted permissive allow-list (copyleft/unknown licenses fail). A repo that needs to accept a specific advisory must document it in its own tree and owns that decision — the gate won't silently absorb it.

### Rust correctness/safety — clippy + rustfmt + test (`Cargo.toml` marker)

`cargo clippy --all-targets --all-features` with `-D warnings` (warnings are blockers) and `clippy::pedantic` on. The denied lints map directly to failure classes:

- **Runtime panics in production paths:** `unwrap_used`, `expect_used`, `panic`, `get_unwrap`, `indexing_slicing`, `string_slice` denied — code that can panic on bad input is rejected (tests are exempted via `clippy.toml`, where panics are legitimate).
- **Memory-safety escape hatch:** `-D unsafe_code` — no `unsafe` blocks reach production without a scoped `#[expect]`.
- **Silent error swallowing:** `map_err_ignore`, `let_underscore_must_use` denied — errors can't be discarded unseen.
- **Unfinished/debug code shipping:** `todo`, `unimplemented`, `dbg_macro` denied — placeholder code and debug prints don't pass.
- **Suppression hygiene:** `allow_attributes` and `allow_attributes_without_reason` denied — you cannot blanket-`#[allow]` your way past a lint; you must use `#[expect(..., reason = "…")]`. This is what makes the whole regime tamper-evident.
- **Assorted footguns:** `clone_on_ref_ptr`, `rc_buffer`, `rc_mutex` (wrong-smart-pointer bugs), `wildcard_enum_match_arm` (new enum variants silently unhandled), `shadow_unrelated` (accidental variable shadowing), `format_push_string`, `verbose_file_reads`, and more.

`cargo fmt --check` enforces consistent formatting (a quality/readability floor, not a security control). `cargo test --all-targets` runs the repo's tests — the gate fails if the suite fails, but it does not enforce that meaningful tests *exist* (see gaps).

### Python — ruff + mypy + pytest (`pyproject.toml` marker)

- **ruff `select = ["ALL"]`** with a minimal conflict-only ignore list — maximum lint enforcement, every rule group on. This includes ruff's security group (`S`, the bandit port): catches `assert` in production, hardcoded passwords, `subprocess` with `shell=True`, `eval`/`exec`, insecure hashlib usage, unsafe YAML/pickle loads, bind-all-interfaces, insecure temp files, and SSL-verification-disabled patterns. Also the bug-risk groups (`B`), comprehension/perf, and full docstring/annotation discipline. Tests are scoped-exempted for asserts, magic values, and missing annotations/docstrings so the regime stays usable. Because ruff has no warn/error split, any selected violation fails — "warnings are blockers" is automatic.
- **mypy `strict = True`** plus `warn_unreachable`, `warn_redundant_casts`, `warn_unused_ignores`, `disallow_any_generics`, `extra_checks` — prevents whole classes of type-confusion bugs, unreachable/dead code, and stale `# type: ignore` suppressions. `ignore_missing_imports` stays on so the gate doesn't fail purely because a third-party lib ships no stubs (not a code-quality signal).
- **pytest** runs the suite (`--strict-markers` so unregistered markers error). Same caveat as Rust: it runs tests, it doesn't mandate good ones. Test *discovery* is the acknowledged repo-shaped fragile case (noted in `pytest.ini`).

### Node/JS — eslint + tsc (`package.json` marker)

`npm ci` installs deps (needed for type resolution), then:

- **eslint** with a plugin-free strict core config: blocks debug leftovers (`no-debugger`, `no-alert`), the eval-class footguns (`no-eval`, `no-implied-eval`, `no-new-func`, `no-script-url` — the JS analog of `unsafe_code`), silent-failure patterns (`no-empty` with `allowEmptyCatch: false`, `no-unused-expressions`, `no-throw-literal`), likely bugs (`no-undef`, `no-unused-vars`, `no-fallthrough`, `no-self-compare`, `use-isnan`, `valid-typeof`, `no-cond-assign`), and discipline rules (`eqeqeq`, `no-var`, `no-param-reassign`, `no-shadow`).
- **tsc `--noEmit --strict`** against the gate's base tsconfig — strict null checks and full type strictness as a baseline.

⚠️ **Known limitation, called out in the manifest:** eslint here only lints `.js/.mjs/.cjs` (TypeScript files are type-checked by tsc, not linted by eslint), and `tsc` runs against the gate's `tsconfig.base.json` rather than the repo's own module/path layout — so projects with non-trivial path mapping get a strict-but-not-project-aware typecheck. Deep type-aware linting (the JS analog of clippy pedantic) needs `typescript-eslint` and is deferred. Treat Node coverage as a strong baseline, not parity with the Rust/Python regimes.

### Ansible — ansible-lint (`ansible/` dir marker)

`ansible-lint --strict` on the **`production` profile** — ansible-lint's strictest built-in bar, nothing higher exists. `--strict` makes warnings fail. Prevents the common Ansible failure/security classes the production profile encodes: missing `no_log` on tasks handling secrets, use of `command`/`shell` where a module exists, unpinned/`latest` package installs, world-readable file modes, missing `become` discipline, deprecated syntax, and idempotency violations. This directly backstops the platform's "secrets must never appear in plaintext in IaC" rule.

### YAML — yamllint (`.yamllint` marker, opt-in)

`yamllint --strict` on a tightened default ruleset. A repo opts in by shipping a `.yamllint` marker, but the *rules* applied are the gate's, not the repo's. Catches structural YAML hazards: duplicate keys, the **implicit/explicit octal** trap (`forbid-implicit-octal`/`forbid-explicit-octal` — the classic file-mode `0644`-vs-`644` footgun), non-canonical truthy values, document-start consistency, and line-length (error at 160). This is a correctness floor for the platform's enormous surface of Helm/Flux/CI YAML.

## What the gate does NOT prevent (gaps & non-goals)

Being explicit here matters more than the coverage list — these are the things a green gate does *not* promise, and treating them as covered is how something slips through.

- **It does not verify the gate image or signing key.** A compromised `grizzly-gate` image or a leaked cosign private key (OpenBao `secret/grizzly-platform/cicd/cosign`) defeats everything. That trust root is protected by pinning + OpenBao access control + key rotation (see the runbook), not by any check here.
- **It does not mandate meaningful tests.** `cargo test`/`pytest` fail if the existing suite fails, but a repo with zero or trivial tests passes the test step. The gate enforces "tests don't regress," not "behavior is tested." Coverage thresholds are not enforced.
- **Semgrep ruleset is pinned to a branch, not a SHA.** `SEMGREP_RULES_REF=develop` means two builds of the same gate Dockerfile at different times can vendor different rules. Reproducibility holds *within* a built gate tag, not across rebuilds of the same tag. (TODO in the Dockerfile.)
- **`ignore-unfixed: true` lets unpatchable HIGH/CRITICAL CVEs ship.** Deliberate, but it means the image is not guaranteed CVE-free — only free of *fixable* HIGH/CRITICAL vulns.
- **No license/SCA scanning outside Rust.** `cargo-deny` covers Rust dependencies (advisories, licenses, sources). There is no equivalent dependency-advisory or license gate for npm, PyPI, or Go dependencies — Python/Node dep vulns are only caught insofar as Trivy sees them in the built image's `library` layer, and licenses aren't checked at all for those ecosystems.
- **Node coverage is a baseline, not parity** (see the Node section): TS files aren't eslinted, typecheck isn't project-aware, no type-aware lint rules.
- **No IaC/Kubernetes-manifest security scanning.** Trivy runs in `image` mode only here; there is no `trivy config` / Checkov / kube-linter step, so misconfigured K8s manifests, Dockerfiles, or Terraform are not scanned for security posture by the gate (Kyverno enforces a separate set of admission policies at deploy time).
- **No runtime, behavioral, or business-logic review.** The gate is static + scan-based. Logic errors that are syntactically clean, type-correct, and pattern-free pass. "The gate is the reviewer" means the reviewer is a very strict linter, not a human who understands intent.
- **Detection is extension/shebang-based, bounded by the denylist.** Honest-map verification closes the old presence-based scope hole, but its completeness rests on the detection ruleset. A *code* language that is neither adapter-backed nor on the `detect.toml` denylist (seeded with go/ruby/java/kotlin/scala/c/cpp/csharp/php/swift/perl/lua/elixir/dart) would not be flagged — extend the denylist as new languages appear. Likewise, code hidden under an Ops-owned `skip_dirs` name (`node_modules/`, `target/`, …) is not adapter-checked (though still secret/SAST-scanned); that list is the one detection boundary an attacker could lean on, so it's kept tight. And `ansible`/`yaml` remain opt-in markers, not extension-detected — a repo with Ansible content but no declared `ansible` project gets no ansible-lint (a bare `.yml` is too ambiguous to mandate).

## Keeping this doc honest

This file enumerates behavior derived from a specific config snapshot. When you change a lint level, add/remove a tool, bump a pin, or alter a scanner's severity/scope, update the matching section here in the same change — and bump the gate tag. If a claim in this doc and the config in `docker/grizzly-gate/config/` disagree, the config wins and this doc is the bug.
