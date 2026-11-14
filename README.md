# claude-code-vm-hardened

A hardened **Ubuntu 26.04 LTS** virtual machine for running [Claude Code](https://code.claude.com) on **Proxmox VE**.

It is a security-first alternative to "one-line" installers that create a privileged LXC, switch AppArmor off,
open a web UI with a first-visitor-wins login, enable root password SSH, and let the box pull and execute
upstream code as root every night. Here:

- **SSH keys only**, one named admin user, root login off, post-quantum key exchange, modern ciphers.
- **A real VM**, not a privileged container: its own kernel, no AppArmor-unconfined, no host escape via shared kernel.
- **No code is fetched and executed from the internet.** Everything comes from signed apt repositories
  (Ubuntu, Anthropic) or the cloud image whose GPG signature and SHA-256 are checked before use.
- **Everything is asked at run time.** Nothing about your network, key or username is baked into the repo.
- **Rootless Docker** (optional): the root Docker daemon is masked and nobody is in the `docker` group.
- **Claude Code runs under an enforced policy**: sandbox required, no unsandboxed retries, bypass mode disabled,
  secret files and env vars denied, network allow-list, telemetry off.

> **Status: beta.** `provision.sh` has been run end-to-end on a real Proxmox VE host (ZFS-backed VM storage,
> DHCP, rootless Docker, Claude Code `stable`) and produced a VM that boots, accepts the admin's SSH key and passed
> `ccvm-doctor` on every check but one. That first run found several bugs, including that failing check, and they are
> fixed in this repo. The in-VM hardening was also tested
> in an Ubuntu 26.04 environment, including real SSH attacks against it. Everything else (see
> [Limitations](#limitations)) is untested, so try it with a spare VM ID first.

## Quick start

On the Proxmox node, as root:

```bash
git clone https://github.com/Roolk/claude-code-vm-hardened
cd claude-code-vm-hardened
less provision.sh guest/ccvm-harden.sh     # review before you run it - it is short on purpose
./provision.sh
```

Try it without changing anything: `./provision.sh --dry-run` asks the questions and writes the generated cloud-init
file to `./out/user-data.yaml`.

You need: Proxmox VE 8 or 9, root, internet access from the node, a storage that allows **Disk image** content,
and one that allows **Snippets**. Snippets only work on a *directory*-type storage (not ZFS/LVM-thin/Ceph), so enable it on `local`: Datacenter -> Storage -> `local` -> Edit -> Content -> tick *Snippets*. The VM disk itself can still live on ZFS.

It is intentionally **not** a `curl | bash` installer: the guest scripts are bundled from your reviewed local copy.

## What it asks you

| Prompt | Notes |
|---|---|
| VM ID, name, cores, RAM, disk, storages | Defaults: 4 cores, 8 GB, 40 GB |
| Bridge, VLAN, DHCP or static IP, DNS | Lists the bridges it finds |
| Admin username | Never `root` |
| SSH public key | Paste, read a file, or download from `github.com/<user>.keys`. Keys are validated; RSA < 3072 bits and private keys are refused |
| Allowed SSH sources | CIDRs/IPs the VM's own firewall allows to port 22. Suggests your bridge subnet |
| sudo | Password (recommended; **not** usable for SSH) or passwordless |
| SSH tunnelling | Off by default |
| OS updates | Security-only (default), security + auto-reboot window, or none |
| Block LAN egress | On by default: the VM can reach the internet, gateway and DNS, not your private ranges |
| IPv6 | Disabled by default |
| Docker | Rootless (default) or none |
| Claude Code | Install yes/no, `stable` or `latest` channel, update policy, **strict/standard** policy, permission mode, Remote Control on/off (off by default), sandbox domain allow-list, Docker-socket access |

Every prompt can be pre-answered with an environment variable (`CCVM_VMID`, `CCVM_ADMIN_USER`, ...) and
`CCVM_NONINTERACTIVE=1`; see the top of `provision.sh` and `tests/lint.sh` for an example.

## After it finishes

```bash
ssh <admin>@<vm-ip>
claude                  # first start: log in with your Anthropic account
sudo ccvm-doctor        # 35 read-only checks against the baseline
sudo ccvm-update        # manual update of OS + Claude Code, then runs the doctor
```

The provisioner prints the VM's SSH **host key fingerprint** from inside the guest. Compare it with what `ssh` shows
on your first connection - that is your protection against a man-in-the-middle on first contact.
Make a DHCP reservation for the VM on your router if you used DHCP.

## What gets hardened

| Area | Measures |
|---|---|
| Image | GPG-verified `SHA256SUMS` (pinned key fingerprint) + checksum before import |
| SSH | `publickey` only, `AllowUsers <admin>`, no root, no forwarding/X11/agent by default, ed25519 host key only, `mlkem768x25519` / curve25519 KEX, ChaCha20/AES-GCM, ETM MACs, 6 auth tries, 30 s grace, verbose logging, weak DH moduli removed, other drop-ins that re-enable passwords are neutralised |
| Accounts | root password locked, cloud-init's NOPASSWD sudoers removed, `sudo` requires a password by default, password quality rules |
| Firewall | `ufw` default-deny inbound, SSH only from your sources, optional egress block of RFC1918/CGNAT/link-local, IPv6 off |
| Kernel | sysctl hardening (kptr, dmesg, bpf, ptrace, redirects, rp_filter, syncookies, protected_*), rare protocols/filesystems blacklisted, core dumps off |
| Detection | `auditd` rules on identity, SSH, sudo, firewall, Claude policy; `fail2ban` on sshd (nftables); persistent journal |
| Updates | `unattended-upgrades` limited to the *-security* pockets; reboots only if you opt in |
| Docker | rootless; root `docker.service`/`docker.socket` masked; docker group emptied |
| Claude Code | installed from Anthropic's signed apt repo (key fingerprint checked against the published value); `/etc/claude-code/managed-settings.json` enforces the sandbox (`failIfUnavailable`, no unsandboxed retry), disables bypass-permissions mode, denies secrets, restricts network domains, turns off telemetry/auto-updater |

See [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) for what this does and does not protect against.

## Limitations

Please read these before trusting it:

- **Tested on one Proxmox setup only.** The successful run used ZFS storage for the VM disk, `local` for snippets,
  OVMF/UEFI, DHCP, and no VLAN. Not yet exercised: static IPs, VLAN tags, LVM/Ceph/other storage types, clusters,
  `--bios seabios`, the `security` (no reboot) and `none` update policies, non-default SSH ports, and the "block LAN egress" option.
  Expect to fix small things if you use them, and please open an issue.
- **Claude Code's sandbox covers shell commands only.** File tools, MCP servers, hooks and plugins run outside it.
  The `strict` policy blocks user-added hooks/MCP/marketplaces for that reason.
- **Known issue: Claude's sandbox may not start on Ubuntu 26.04 (every shell command fails).** Ubuntu ships an
  AppArmor profile (`/etc/apparmor.d/bwrap-userns-restrict`) that blocks the nested user namespace Claude Code's
  `apply-seccomp` helper needs, so each sandboxed command dies with `apply-seccomp: ... Permission denied`. This is an
  upstream interaction (see [anthropics/claude-code#101946](https://github.com/anthropics/claude-code/issues/101946)),
  and `sudo ccvm-doctor` now reports it as a FAIL. Because `failIfUnavailable` and "no unsandboxed retry" are enforced,
  Claude cannot run commands until it is resolved. See [docs/CLAUDE-SANDBOX-UBUNTU-2604.md](docs/CLAUDE-SANDBOX-UBUNTU-2604.md).
- **Docker + sandbox:** letting Claude's sandbox reach the rootless Docker socket (an opt-in prompt) means a container
  can read anything the admin user can. Leave it off unless you need it.
- **Rootless Docker limits:** no privileged containers, cannot bind ports below 1024, slower user-space networking.
- **Egress block is IP-range based.** It stops the VM *initiating* connections to your LAN; it is not a substitute for
  network segmentation, and it does not restrict internet destinations (Claude's sandbox domain list does that for
  shell commands only).
- **Host key / first contact:** verify the fingerprint as described above.
- **Single admin account.** A stolen admin SSH key plus (optionally) sudo password is full compromise of the VM.
  Protect the key (passphrase, hardware key; `sk-ssh-ed25519` keys are accepted).
- The VM keeps your Anthropic login token in the admin user's home; treat the VM as holding credentials.

## Layout

```
provision.sh             Proxmox-side: prompts, image verification, VM creation, cloud-init
guest/ccvm-harden.sh     In-VM hardening (runs once from cloud-init; safe to re-run)
guest/ccvm-doctor        Read-only compliance check
guest/ccvm-update        Manual update command
guest/files/             sshd, sysctl, modprobe, fail2ban, auditd templates
keys/                    Pinned public signing keys (Ubuntu cloud images, Anthropic)
tests/lint.sh            shellcheck + dry-run + cloud-init schema validation
```

## Development

`tests/lint.sh` needs Docker. CI runs the same checks. Please open an issue for problems, and see
[SECURITY.md](SECURITY.md) to report vulnerabilities.

## License

MIT - see [LICENSE](LICENSE).
