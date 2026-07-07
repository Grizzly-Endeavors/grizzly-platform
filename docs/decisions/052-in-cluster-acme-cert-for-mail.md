# ADR-052: In-Cluster ACME Cert for Mail (Let's Encrypt DNS-01 via Cloudflare)

**Date:** 2026-07-05
**Status:** Accepted
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md), [ADR-050](050-stalwart-mail-server.md)

## Context

Stalwart ([ADR-050](050-stalwart-mail-server.md)) terminates TLS itself on the mail ports — the SMTP/IMAP streams are passed through HAProxy ([ADR-051](051-haproxy-l4-mail-ingress.md)), not terminated at the edge — so it needs a **publicly-trusted certificate for `mail.<domain>` inside the cluster.** Caddy's wildcard on the VPS never touches those ports. [ADR-019](019-ingress-and-tls-termination.md) deployed cert-manager with only a self-signed ClusterIssuer and explicitly deferred Let's Encrypt "until a workload actually needs a browser-trusted certificate." Mail is that workload. The cluster is on a private LAN, so HTTP-01 / TLS-ALPN-01 challenges are impractical; the Cloudflare API token is already the platform's DNS control plane.

## Decision

**Stand up a Let's Encrypt `ClusterIssuer` in cert-manager using the DNS-01 solver via Cloudflare.** cert-manager issues and renews a `Certificate` for `mail.<domain>`; Stalwart mounts it for SMTP/IMAP TLS termination. The Cloudflare API token is delivered as a Kubernetes Secret via **OpenBao + External Secrets** (never in git), scoped to Zone:Read + DNS:Edit on the mail zone.

**A dedicated cert-manager token is required — the platform token cannot be reused.** The existing `platform/cloudflare` token (Caddy's wildcard DNS-01) is **source-IP-locked to the VPS**, so cert-manager, egressing from the cluster/home IP, gets Cloudflare error `9109 "Cannot use the access token from location"`. cert-manager therefore uses a separate token at `secret/grizzly-platform/platform/cloudflare-certmanager`, scoped to Zone:Read + DNS:Edit on `grizzly-endeavors.com` with **no IP restriction** (the home egress IP is dynamic; the narrow permission scope keeps the blast radius to one zone's DNS records).

## Alternatives Considered

- **Copy Caddy's wildcard cert into the cluster as a Secret** — rejected: couples the cluster to the VPS's cert lifecycle, needs an out-of-band sync job, and cert-manager already does issuance/renewal natively.
- **Stalwart's built-in ACME** — rejected: it would need its own challenge path (HTTP-01 can't reach a private-LAN listener behind the tunnel; DNS-01 support is less proven than cert-manager's) and duplicates cert-manager, the platform's standard issuer.
- **Keep self-signed** — rejected: real IMAP/SMTP clients (Thunderbird, phones) reject untrusted certs; a public MX/submission endpoint needs a browser-trusted cert.

## Consequences

- **First browser-trusted in-cluster cert** — closes the deferral ADR-019 left open. The LE issuer is now available to future workloads that need public TLS in-cluster.
- **New secret dependency:** a dedicated Cloudflare API token in OpenBao (`platform/cloudflare-certmanager`), surfaced via ExternalSecret into the cert-manager namespace. Zone:Read + DNS:Edit on the mail zone, no IP lock — distinct from the VPS-locked Caddy token.
- **Renewal is automatic** (cert-manager), removing a manual expiry failure mode for the mail endpoint.
- **Rate limits:** use the LE staging issuer while validating, then production, to avoid burning the weekly issuance cap during setup.
- **Domain-follows:** when mail re-anchors on `grizzly-endeavors.com`, the issuer solves against whichever zone the Cloudflare token covers — add the zone, no issuer redesign.
