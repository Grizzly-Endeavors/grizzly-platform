# 034: Transparent in-cluster encryption via Cilium WireGuard

**Date:** 2026-06-29
**Status:** accepted
**Relates to:** [ADR-014](014-k8s-cluster-stack.md), [ADR-019](019-ingress-and-tls-termination.md), [ADR-035](035-internal-tls-openbao-pki.md)
**Tracking:** [#55](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/55)

## Context

The CNI is Cilium 1.18 in tunnel/VXLAN routing mode with kube-proxy replacement (ADR-014). All pod-to-pod traffic inside the cluster travels in cleartext today. Edge TLS terminates at the VPS and the VPS→R730xd leg is its own WireGuard tunnel (ADR-019), but the *cluster leg* — NodePort → ingress-nginx → backend pod, and every service-to-service hop (app→Authentik, app→registry, etc.) — is plaintext. As the platform increasingly runs third-party workloads alongside first-party ones on shared nodes, "another tenant's pod can observe a node's traffic" stops being acceptable.

Cilium ships transparent encryption as a first-class feature, so closing this gap does not require a service mesh or per-app certificates.

## Decision

**Enable Cilium transparent WireGuard encryption for pod-to-pod traffic** (`encryption.enabled: true`, `encryption.type: wireguard`) in the `k8s-cilium` role, gated behind a role default so the rollout is deliberate. Cilium self-manages the per-node WireGuard keypairs (public keys distributed via the CiliumNode CRD) — no cert-manager, no OpenBao, no key material in IaC. `encryption.nodeEncryption` stays **off** for now.

## Alternatives Considered

- **Service mesh mTLS (Istio / Linkerd).** Large operational surface, and for the *encryption* goal it is almost entirely redundant with Cilium's datapath encryption. Its unique value is service identity/authz, which we get instead from CiliumNetworkPolicy. Rejected.
- **Cilium IPsec mode instead of WireGuard.** More configuration surface and key management; WireGuard is in-kernel, simpler, and the Cilium-recommended default. Rejected.
- **`encryption.nodeEncryption: true` now.** Encrypts host/node-network traffic too, but it is beta and auto-excludes control-plane nodes to avoid bootstrap deadlock. Deferred — low-value host traffic is not worth the beta risk yet.
- **Do nothing.** Leaves intra-cluster traffic in cleartext on shared nodes, which is the exact exposure this platform's multi-user direction makes unacceptable. Rejected.

## Consequences

- **Pod-to-pod across nodes is encrypted** — this covers the ingress→backend hop and all service-to-service traffic. Same-node pod-to-pod is intentionally *not* encrypted (it never leaves the host).
- **The R730xd→NodePort hop remains plaintext.** R730xd is not a cluster node, so it sits outside Cilium's mesh and `nodeEncryption` cannot reach it. This is one trusted-host LAN hop; eliminating it is an ingress-topology change (MetalLB/mesh bridge), not an encryption setting, and is out of scope here.
- **Tunnel mode means double encapsulation** (VXLAN ~50B then WireGuard ~60B). Cilium auto-recomputes pod MTU (~1500 → ~1373) and propagates it; no manual MTU config. This is the one real efficiency cost of staying in tunnel mode.
- **Throughput cost is modest** — roughly 10–25% on saturated high-bandwidth flows, negligible for our traffic profile (web apps, auth, registry pulls). In-kernel WireGuard keeps CPU overhead small.
- **Operational prerequisites:** the WireGuard kernel module (kernel ≥5.6 — nodes run 6.12, fine) and UDP `51871` reachable node-to-node. A blocked port silently breaks encryption — verify it.
- **Rollout is a `helm upgrade` + rolling restart of the cilium agents** in a maintenance window; encryption activates per-node as agents come up. `cilium-dbg encrypt status` and Hubble's `IsEncrypted` flow flag confirm it afterward. The current pin (`1.18.8`) can move to current patch at the same time.
- **Pairs with ADR-035:** Cilium encrypts the transport; OpenBao PKI provides the authenticity/identity layer. Defense in depth, each done at the right layer.
