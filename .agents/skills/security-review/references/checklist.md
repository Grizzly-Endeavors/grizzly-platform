# Security Review Checklist

Evaluate each category against the IaC in the repo. "Addressed" means the IaC explicitly configures it. "Missing" means the IaC is silent on it.

## SSH Hardening

- [ ] Password authentication disabled (`PasswordAuthentication no`)
- [ ] Root login disabled (`PermitRootLogin no` or `prohibit-password`)
- [ ] Key-only auth enforced
- [ ] SSH port changed or access restricted by firewall/IP
- [ ] Idle timeout configured (`ClientAliveInterval`, `ClientAliveCountMax`)
- [ ] Authorized keys managed by IaC (not manually placed)
- [ ] SSH host keys rotated or verified on provision

## Firewall

- [ ] Firewall enabled and configured by IaC (ufw, nftables, iptables)
- [ ] Default deny inbound policy
- [ ] Only required ports open — each open port has a documented reason
- [ ] Outbound filtering considered (not required, but flag if nothing restricts egress)
- [ ] Firewall rules are specific (not `allow from any`)
- [ ] ICMP policy defined (allow ping or not — intentional choice)

## Network Segmentation

- [ ] VLANs defined and enforced (lab vs home vs storage)
- [ ] Inter-VLAN routing restricted to what's necessary
- [ ] Management interfaces (iDRAC, BMC, IPMI) on isolated network or restricted access
- [ ] Services only bind to interfaces they need (not 0.0.0.0 when local-only)

## Service Exposure

- [ ] Internet-exposed services enumerated and intentional
- [ ] TLS on all internet-facing endpoints
- [ ] Internal services not accidentally exposed (check NodePort ranges, Docker port mappings)
- [ ] Reverse proxy config doesn't forward to unintended backends
- [ ] Health/status endpoints not leaking sensitive info

## Secrets Management

- [ ] No plaintext secrets in IaC (passwords, tokens, keys)
- [ ] Ansible Vault used for sensitive variables
- [ ] Vault password file is git-ignored
- [ ] Secrets not logged during playbook runs (use `no_log: true`)
- [ ] API keys / tokens have minimal required permissions
- [ ] Secrets rotation plan exists (even if manual — documented)

## BMC / iDRAC / IPMI

- [ ] Default credentials changed
- [ ] Web interface restricted by network or firewall
- [ ] IPMI-over-LAN restricted to management VLAN or specific IPs
- [ ] Firmware version checked (known vulns in old iDRAC/IPMI)
- [ ] Virtual media / remote console access restricted
- [ ] BMC network interface not on the general LAN

## Container / K8s Security

- [ ] Container images from trusted sources / pinned versions (not `:latest` in production)
- [ ] Containers run as non-root where possible
- [ ] K8s RBAC configured (not everything running as cluster-admin)
- [ ] Pod security standards applied (restricted or baseline)
- [ ] Registry access controlled (even if insecure registry — is it LAN-only?)
- [ ] Secrets in K8s not stored as plaintext ConfigMaps

## Backup & Recovery

- [ ] Backup strategy exists and is documented
- [ ] Backups are not on the same machine as the data
- [ ] Backup integrity verified (test restores)
- [ ] Backup data encrypted at rest (or at minimum, access-controlled)
- [ ] Recovery procedure documented and tested

## System Hardening

- [ ] Automatic security updates enabled (unattended-upgrades or equivalent)
- [ ] Unnecessary services disabled
- [ ] Users have minimal required privileges (no shared root accounts)
- [ ] Sudo access audited and intentional
- [ ] File permissions on sensitive files (SSH keys, vault files, configs) are restrictive

## DNS & Certificates

- [ ] DNS records managed (not just manually set in a web UI)
- [ ] TLS certificates auto-renewed (cert-manager, Caddy automatic HTTPS)
- [ ] Certificate expiry monitored
- [ ] DNS provider API keys scoped minimally (e.g., zone-specific, not full account)

## Supply Chain

- [ ] Package sources are official repos (no sketchy PPAs)
- [ ] Downloaded binaries verified (checksums or GPG signatures)
- [ ] Container base images from official sources
- [ ] GitHub Actions runners are self-hosted and trusted (or pinned action versions)
