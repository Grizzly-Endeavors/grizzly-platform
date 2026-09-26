# ADR-078: Accept cert-manager's Default Private-Key Rotation

**Date:** 2026-09-26
**Status:** Accepted
**Relates to:** [ADR-052](052-in-cluster-acme-cert-for-mail.md) (the Let's Encrypt mail certificate), [ADR-068](068-k8s-135-stepped-upgrade.md) (the K8s upgrade that left cert-manager behind its tested window). Part of [#199](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/199).

## Context

cert-manager 1.18 changes the default of `Certificate.spec.privateKey.rotationPolicy` from `Never` to `Always`. A renewal generates a new private key instead of reusing the current one. The Helm feature gate that restores the old default (`DefaultPrivateKeyRotationPolicyAlways: false`) is removed in 1.19, so the only durable opt-out is setting `rotationPolicy: Never` on each Certificate. The same release defaults `revisionHistoryLimit` to 1, which garbage-collects CertificateRequest objects older than the latest.

The only Certificate in this repo is `stalwart-tls` (`kubernetes/infrastructure/stalwart/certificate.yaml`), a Let's Encrypt leaf for `mail.grizzly-endeavors.com` issued by the DNS-01 ClusterIssuer. ACME account keys live on the ClusterIssuers (`privateKeySecretRef`) and are not governed by this field. No Certificate here is a CA. DANE/TLSA for the MX is not deployed, so nothing pins the leaf public key.

## Decision

**Leave `rotationPolicy` unset and accept `Always`.** Do not pin `Never` on `stalwart-tls`, and do not set the 1.18 feature gate. Leave `revisionHistoryLimit` unset and accept `1`.

Renewals of Let's Encrypt leaves replace the private key. The TLS Secret's `tls.crt` and `tls.key` are updated together. Clients trust the Let's Encrypt chain, not the leaf key. Stalwart already has to reload the mounted files after a renewal; a new key does not add a step.

## Alternatives Considered

- **Pin `rotationPolicy: Never` on `stalwart-tls`.** Preserves key reuse. Rejected: nothing in this platform pins that leaf key, and `Never` is the behavior upstream called out as unsafe — a renew after the key is exposed would keep serving the exposed key. A future CA Certificate whose key is a trust anchor can set `Never` on that object; this repo has no such Certificate.
- **Disable `DefaultPrivateKeyRotationPolicyAlways` for the 1.18 hop only.** Rejected: the gate disappears in 1.19, so it only delays the same decision by one minor.

## Consequences

- The next renewal of `stalwart-tls`, and of any future Certificate that does not set the field, generates a new private key.
- A Certificate that must keep its key (a trust-anchor CA) has to set `rotationPolicy: Never` explicitly.
- On the 1.18 upgrade, CertificateRequest objects beyond the latest revision are removed. Nothing in this repo reads them.
