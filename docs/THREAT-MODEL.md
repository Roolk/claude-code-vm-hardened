# Threat model

Scope: the VM created by `provision.sh`, an admin using it over SSH, and Claude Code running as that admin.

## Assets
1. The VM and anything stored on it (source code, tokens, the admin's Anthropic login).
2. The rest of your LAN, reachable from the VM.
3. The Proxmox host and other guests.
4. The admin's SSH private key (lives on your workstation, not the VM).

## Actors and what is addressed

| Threat | Mitigation | Residual risk |
|---|---|---|
| Internet/LAN attacker brute-forcing SSH | Key-only auth, `AllowUsers`, ufw source allow-list, fail2ban, 6 auth tries | A vulnerability in sshd itself (mitigated by security auto-updates) |
| Attacker on an allowed source network | Same as above; no password path exists | Stolen/unprotected private key = access. Use a passphrase or hardware key |
| MITM on first connection | Provisioner prints the host key fingerprint from inside the guest; only ed25519 host key exists | You must compare it |
| Tampered VM image | `SHA256SUMS` GPG-verified against a pinned fingerprint, then checksum-verified | Compromise of Canonical's signing key |
| Malicious/compromised installer or update source | No `curl \| bash`; no self-updating from a third-party git repo; only Ubuntu and Anthropic apt repos with signed metadata, key fingerprint checked | Compromise of Ubuntu or Anthropic's release pipeline |
| Compromised VM pivots to the LAN | Optional egress block of RFC1918/CGNAT/link-local (default on); VM is a full VM, not a privileged LXC | Not a replacement for VLAN/firewall segmentation at the network layer; internet egress is open |
| Container escape to VM root | Docker is rootless, root daemon masked, no docker group | A rootless-runtime or kernel bug; kernel is shared between VM processes |
| VM escape to the Proxmox host | Standard QEMU/KVM isolation; VirtIO devices only | Hypervisor bugs - keep Proxmox patched |
| Claude acting beyond what you intended | Managed policy: sandbox required, no unsandboxed retry, bypass mode disabled, deny-rules for secrets, network allow-list, default permission mode asks | Prompt injection can still trick Claude into harmful *allowed* actions inside the sandbox; the sandbox covers shell commands only (file tools, MCP, hooks run outside it) |
| Secrets exfiltrated by Claude's shell | `~/.ssh`, `~/.gnupg`, `~/.config/gh`, Docker config, Claude credentials denied to the sandbox; token env vars scrubbed; only allow-listed domains reachable | The Claude login token must be readable by Claude itself; allow-listed hosts (e.g. github.com) can be abused as an exfil channel |
| Persistence/tampering on the VM | auditd rules on identity, SSH, sudo, firewall, `/etc/claude-code`; `ccvm-doctor` re-checks the baseline | No remote log shipping; a root attacker can clear local logs |
| Unpatched software | unattended security upgrades; manual `ccvm-update` for the rest | A reboot is required for kernel fixes unless you enable the reboot window |

## Out of scope
- Physical access, Proxmox host compromise, a malicious Proxmox admin.
- Compromise of your workstation (it holds the SSH key and the Anthropic session).
- Data-loss/availability: take Proxmox backups of the VM (snapshots are not backups).
- Content you ask Claude to fetch or run (supply-chain attacks in your project's dependencies).

## Design choices worth knowing
- **VM over LXC:** a privileged, AppArmor-unconfined LXC shares the host kernel with root-equivalent access.
- **No web UI:** removes an unauthenticated-on-first-visit HTTP surface; use SSH.
- **Single admin user + rootless Docker:** simpler, and Docker no longer equals root, which is what made a separate
  unprivileged `claude` user necessary under rootful Docker.
- **Manual updates for Claude Code by default:** a new release is never pulled and executed while unattended.
- **Unprivileged user namespaces stay enabled:** rootless Docker and Claude's bubblewrap sandbox need them; Ubuntu
  restricts them with AppArmor profiles (`bwrap`, `rootlesskit`) rather than a global switch.
