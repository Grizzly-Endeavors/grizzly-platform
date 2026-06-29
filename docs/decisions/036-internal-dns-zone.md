# 036: Internal DNS zone for name-based addressing

**Date:** 2026-06-29
**Status:** accepted
**Relates to:** [ADR-019](019-ingress-and-tls-termination.md), [ADR-021](021-off-the-shelf-router-tower-pc-as-worker.md), [ADR-035](035-internal-tls-openbao-pki.md)
**Tracking:** [#57](https://github.com/Grizzly-Endeavors/grizzly-platform/issues/57)

## Context

LAN and cross-machine addressing today is raw `10.0.0.x` IPs plus Ansible-managed `/etc/hosts` entries (`docs/network.md`) — there is no internal resolver, and local DNS is already noted as post-router work (ADR-021). Inside the cluster this is a solved problem (CoreDNS resolves `*.svc.cluster.local`), but everything *between* machines — OpenBao at `10.0.0.200`, NodePort targets, S3 endpoints, the dev laptop — is hand-addressed by IP. This is the recurring "fiddling with IP addresses" friction, and it is also what cert SANs (ADR-035) want to assert identity *for*.

A certificate asserts identity for a name; it does not make the name resolve. Name-based addressing is a separate, DNS-shaped piece of work from the TLS foundation.

## Decision

**Stand up an internal DNS authority for a private zone under `.internal`** (e.g. `grizzly-platform.internal`), with records managed declaratively: **external-dns** for cluster Services/Ingresses, and Ansible-managed zone files for bare-metal hosts. LAN clients resolve via the internal resolver (handed out by DHCP). Services become `name.grizzly-platform.internal` instead of raw IPs, and those names become the cert SANs in ADR-035.

## Alternatives Considered

- **`.local` (the originally proposed TLD).** Reserved for mDNS (Avahi/Bonjour); systemd-resolved treats it specially, so using it as a unicast zone causes intermittent, hard-to-debug resolution failures. Rejected outright.
- **Subdomain of an owned public domain with split-horizon** (e.g. `internal.bearflinn.com`). Works and would enable public LE certs for internal names, but pulls internal topology into a public-domain namespace and couples to external DNS management. `.internal` is ICANN-reserved (2024) for exactly this and coheres with the private-CA decision in ADR-035. Rejected in favour of `.internal`.
- **Keep `/etc/hosts` via Ansible.** Doesn't scale, is manual per-host, and offers no service-driven automation. Rejected.
- **Public DNS records pointing at private IPs.** Leaks internal topology and addresses to the world for no benefit. Rejected.

## Consequences

- **Named addressing replaces raw IPs** for cross-machine and operator access, and cert SANs (ADR-035) become real hostnames — name and certificate agree end to end.
- **`.internal` requires a private CA.** Let's Encrypt will not issue for non-public names, so this choice *depends on* the OpenBao PKI in ADR-035 — the two decisions reinforce each other.
- **Resolver placement is sequenced with ADR-021.** The authoritative resolver's long-term home is the planned off-the-shelf router; until that lands it can run on an existing always-on host (e.g. R730xd). This ADR fixes the naming scheme and approach; the resolver host is a follow-up gated on ADR-021.
- **New component (external-dns)** plus a DHCP change to point LAN clients at the internal resolver. Record management is split: external-dns owns cluster Services, Ansible owns bare-metal hosts.
- **Independent but compounding.** This can land on its own, but together with ADR-034 (transport encryption) and ADR-035 (identity/certs) it completes the shift from "IPs and `--insecure` flags" to named, trusted, encrypted services.
