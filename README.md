# claude-code-vm-hardened

A hardened **Ubuntu 26.04 LTS** virtual machine for running [Claude Code](https://code.claude.com) on **Proxmox VE**.

It is a security-first alternative to "one-line" installers that create a privileged LXC, switch AppArmor off, open a
web UI with a first-visitor-wins login, enable root password SSH, and let the box pull and execute upstream code as
root every night. Here:

- **SSH keys only:** one named admin user, no root login, post-quantum key exchange, modern ciphers.
- **A real VM, not a privileged container:** its own kernel, AppArmor on, no host escape through a shared kernel.
- **Nothing is downloaded and executed from the internet.** Packages come from signed apt repositories (Ubuntu,
  Anthropic), and the cloud image's GPG signature and SHA-256 are checked before it is used.
- **Everything is asked at run time.** Nothing about your network, key or username is baked into the repo.
- **Rootless Docker** (optional): the root Docker daemon is masked and nobody is in the `docker` group.
- **Claude Code runs under an enforced policy:** the sandbox is required with no unsandboxed retries, bypass mode is
  disabled, secret files and environment variables are denied, network access is allow-listed, telemetry is off.

> **Status: beta.** `provision.sh` has been run end-to-end on a real Proxmox VE host (ZFS-backed VM storage, DHCP,
> rootless Docker, Claude Code `stable`). The VM booted, accepted the admin's SSH key and passed every `ccvm-doctor`
> check but one. That run found several bugs, including the cause of the failing check, and they are fixed here. The
> in-VM hardening has also been tested in an Ubuntu 26.04 environment, including real SSH attacks against it.
> Everything listed under [Limitations](#limitations) is untested, so try it with a spare VM ID first.

## Quick start

On the Proxmox node, as root:

```bash
git clone https://github.com/Roolk/claude-code-vm-hardened
cd claude-code-vm-hardened
less provision.sh guest/ccvm-harden.sh     # review before you run it - it is short on purpose
./provision.sh
```

To try it without changing anything, run `./provision.sh --dry-run`: it asks the questions and writes the generated
cloud-init file to `./out/user-data.yaml`.

You need Proxmox VE 8 or 9, root, internet access from the node, one storage that allows **Disk image** content and
one that allows **Snippets**. Snippets only work on a *directory*-type storage (not ZFS, LVM-thin or Ceph), so enable
them on `local`: Datacenter -> Storage -> `local` -> Edit -> Content -> tick *Snippets*. The VM disk itself can still
live on ZFS.

This is deliberately **not** a `curl | bash` installer: the guest scripts are bundled from your reviewed local copy.

## What it asks you

| Prompt | Notes |
|---|---|
| VM ID, name, cores, RAM, disk, storages | Defaults: 4 cores, 8 GB, 40 GB |
| Bridge, VLAN, DHCP or static IP, DNS | Lists the bridges it finds |
| Admin username | Never `root` |
| SSH public key | Paste it, read it from a file, or download it from `github.com/<user>.keys`. Keys are validated; RSA keys under 3072 bits and private keys are refused |
| Allowed SSH sources | The CIDRs/IPs the VM's own firewall lets reach SSH. Suggests your bridge subnet |
| sudo | Password (recommended; **not** usable for SSH) or passwordless |
| SSH tunnelling | Off by default |
| OS updates | Security-only (default), security plus an auto-reboot window, or none |
| Block LAN egress | On by default: the VM can reach the internet, gateway and DNS, but not your private ranges |
| IPv6 | Disabled by default |
| Docker | Rootless (default) or none |
| Claude Code | Install or not; `stable` or `latest` channel; update policy; **strict** or **standard** policy; permission mode; sandbox domain allow-list; the Ubuntu 26.04 AppArmor workaround that lets the sandbox start (on by default); Remote Control (off by default) and whether it starts at boot; Docker access for Claude (no / ask every time / all Unix sockets) |

Every prompt can be pre-answered with an environment variable (`CCVM_VMID`, `CCVM_ADMIN_USER`, ...) plus
`CCVM_NONINTERACTIVE=1`; see the top of `provision.sh` and `tests/lint.sh` for an example. A non-interactive run only
creates the VM if you also set `CCVM_CONFIRM=yes`.

## After it finishes

```bash
ssh <admin>@<vm-ip>
claude                  # first start: log in with your Anthropic account
sudo ccvm-doctor        # read-only checks against the hardening baseline
sudo ccvm-update        # manual update of the OS and Claude Code, then runs the doctor
sudo ccvm-domains list  # show Claude's sandbox domain allow-list (untested, see below)
ccvm-push               # push the current repo's branch to GitHub with a token you type in (see below)
```

The provisioner prints the VM's SSH **host key fingerprint**, read from inside the guest. Compare it with what `ssh`
shows on your first connection: that is your protection against a man-in-the-middle on first contact. If you used
DHCP, make a reservation for the VM on your router.

## Optional features

### Remote Control at boot

If you enable Remote Control, `provision.sh` offers to keep `claude rc` running from boot in the tmux session
`claude-rc`. The VM is then reachable from claude.ai/code or the Claude app after every reboot, without anyone
logging in over SSH.

- **How it works:** a root-owned systemd *user* unit (`/etc/systemd/user/ccvm-claude-rc.service`, with linger
  enabled) runs a loop that restarts `claude remote-control` 15 s after it exits.
- **First use:** run `claude` once in the chosen folder (default `~/projects`) to sign in and answer the folder-trust
  question. The loop picks it up within a minute.
- **If Claude is not signed in** (never logged in, or the login expired), Remote Control is not started and you are
  told: a yellow notice when you SSH in, a warning from `sudo ccvm-doctor`, a line in the tmux session, and a journal
  entry (`journalctl -t ccvm-claude-rc`). It checks again every minute, so signing in with `claude` is all it takes.
- **Managing it:** `tmux attach -t claude-rc` shows it (detach with `Ctrl-b d`). `systemctl --user stop
  ccvm-claude-rc` stops it until the next boot; `systemctl --user disable ccvm-claude-rc` turns it off.
- Remote Control sessions follow the same managed policy (sandbox, permission mode) as any other session.

**Tested** on one VM: with the files installed by hand from this repo, it came back by itself after a reboot and
started Remote Control. Not yet exercised: installing it through `provision.sh` / `ccvm-harden`, and the
not-signed-in notices on a real system (they were tested with a stand-in `claude`).

### Docker access for Claude

Docker cannot run inside Claude's sandbox. Whatever can talk to the Docker daemon can do anything the admin user can:
a container can read every file the admin can, and its network traffic bypasses the sandbox's domain allow-list. The
prompt offers three answers:

- **No** (default): Claude cannot use Docker.
- **Ask every time** (`excludedCommands: ["docker *"]`): `docker ...` commands run outside the sandbox through
  Claude's normal permission flow. In the `default` mode you approve each one; in `auto` mode the classifier decides.
  Read what gets approved: a `-v ~:/x` mount or a Dockerfile Claude wrote can do anything you can. A call that
  includes a redirect, `cd` or `$(...)` stays sandboxed and fails.
- **Always** (`allowAllUnixSockets`): on Linux the sandbox cannot allow just the Docker socket, so this opens every
  Unix socket, including the systemd user bus (`systemd-run --user ...` starts a process outside the sandbox). Treat
  it as turning the sandbox off.

`ccvm-doctor` warns when either of the last two is enabled. *Ask every time* has been **tested** on one VM, with the
policy set by hand: `docker` commands ran outside the sandbox under the session's approval setting.

### Pushing Claude's commits to GitHub (`ccvm-push`)

The VM stores no GitHub credentials. Claude commits; you review and push over SSH, so pushing needs SSH access to the
VM, and that is the boundary. In the repo, run `ccvm-push` (current branch) or `ccvm-push <branch>...`. It asks for a
token, shows the commits GitHub does not have yet, and pushes only after you confirm. It never force-pushes, and the
token is used for that push only and never stored. Use a fine-grained token limited to the repo, with *Contents:
Read and write*, no *Workflows* permission, and a short expiry.

Claude can edit a repo's hooks and config, so `ccvm-push` treats them as untrusted: hooks are disabled, the push goes
to the verified `https://github.com/<owner>/<repo>` URL, and it refuses if any config could redirect the push or the
token (`url.*`, `http.*`, `credential.*`, `include*`, `core.hooksPath`, `remote.*.pushurl`, ...). It is installed
root-owned in `/usr/local/bin`, so Claude cannot rewrite it either. For the strongest setup, also add a GitHub ruleset
that requires a pull request to change `main`.

Its checks and hook-blocking were tested against a clone of this repo; a real push with it has not been made yet.

### Changing Claude's domain allow-list (untested)

`sudo ccvm-domains add example.com` or `sudo ccvm-domains remove example.com` updates both `/etc/ccvm/ccvm.conf`
(so re-running `ccvm-harden` keeps your list) and `sandbox.network.allowedDomains` in
`/etc/claude-code/managed-settings.json`. Restart `claude` afterwards. Only root can change the list, so Claude
cannot, but anything that learns your sudo password can.

It has **not yet been run on a provisioned VM**, so back up both files first:
`sudo cp -a /etc/ccvm/ccvm.conf /etc/claude-code/managed-settings.json /root/`.

## What gets hardened

| Area | Measures |
|---|---|
| Image | GPG-verified `SHA256SUMS` (pinned key fingerprint) and checksum before import |
| SSH | `publickey` only, `AllowUsers <admin>`, no root, no forwarding/X11/agent by default, ed25519 host key only, `mlkem768x25519` / curve25519 KEX, ChaCha20/AES-GCM, ETM MACs, 6 auth tries, 30 s grace, verbose logging, weak DH moduli removed, other drop-ins that re-enable passwords neutralised |
| Accounts | root password locked, cloud-init's NOPASSWD sudoers removed, `sudo` requires a password by default, password quality rules |
| Firewall | `ufw` default-deny inbound, SSH only from your sources, optional egress block of RFC1918/CGNAT/link-local (plus IPv6 ULA/link-local if IPv6 is kept), IPv6 off by default |
| Kernel | sysctl hardening (kptr, dmesg, bpf, ptrace, redirects, rp_filter, syncookies, protected_*), rare protocols and filesystems blacklisted, core dumps off |
| Detection | `auditd` rules on identity, SSH, sudo, firewall and the Claude policy; `fail2ban` on sshd (nftables); persistent journal |
| Updates | `unattended-upgrades` limited to the *-security* pockets; reboots only if you opt in |
| Docker | rootless; root `docker.service`/`docker.socket` masked; docker group emptied |
| Claude Code | installed from Anthropic's signed apt repo (key fingerprint checked against the published value); `/etc/claude-code/managed-settings.json` enforces the sandbox (`failIfUnavailable`, no unsandboxed retry), disables bypass-permissions mode, denies secrets, restricts network domains, and turns off telemetry and the auto-updater |

See [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) for what this does and does not protect against.

## Limitations

Please read these before trusting it:

- **Tested on one Proxmox setup only.** The successful run used ZFS storage for the VM disk, `local` for snippets,
  OVMF/UEFI, DHCP and no VLAN. Not yet exercised: static IPs, VLAN tags, LVM/Ceph/other storage types, clusters,
  `--bios seabios`, the `security` (no reboot) and `none` update policies, non-default SSH ports, and the "block LAN
  egress" option. Expect to fix small things if you use them, and please open an issue.
- **Claude Code's sandbox covers shell commands only.** File tools, MCP servers, hooks and plugins run outside it,
  which is why the `strict` policy blocks user-added hooks, MCP servers and marketplaces.
- **Known issue: Claude's sandbox may not start on Ubuntu 26.04, so every shell command fails.** Ubuntu ships an
  AppArmor profile (`/etc/apparmor.d/bwrap-userns-restrict`) that blocks the nested user namespace Claude Code's
  `apply-seccomp` helper needs, so each sandboxed command dies with `apply-seccomp: ... Permission denied`. This is an
  upstream interaction (see [anthropics/claude-code#101946](https://github.com/anthropics/claude-code/issues/101946)),
  so `provision.sh` applies the documented workaround by default (it asks first), and `sudo ccvm-doctor` fails
  if the sandbox cannot start. Because `failIfUnavailable` and "no unsandboxed retry" are enforced, Claude cannot
  run commands until it works. See [docs/CLAUDE-SANDBOX-UBUNTU-2604.md](docs/CLAUDE-SANDBOX-UBUNTU-2604.md).
- **Docker access weakens the sandbox.** Any of the Docker options above gives containers everything the admin user
  can reach; see [Docker access for Claude](#docker-access-for-claude).
- **Rootless Docker limits:** no privileged containers, no binding ports below 1024, slower user-space networking.
- **The egress block is IP-range based.** It stops the VM *initiating* connections to your LAN. It is not a
  substitute for network segmentation, and it does not restrict internet destinations (Claude's sandbox domain list
  does that, for shell commands only).
- **Host key on first contact:** verify the fingerprint as described in [After it finishes](#after-it-finishes).
- **Single admin account.** A stolen admin SSH key, plus the sudo password if you chose one, means full compromise
  of the VM. Protect the key with a passphrase or a hardware key (`sk-ssh-ed25519` keys are accepted).
- **The VM holds credentials.** Your Anthropic login token lives in the admin user's home.

## Layout

```
provision.sh             Proxmox side: prompts, image verification, VM creation, cloud-init
guest/ccvm-harden.sh     In-VM hardening (runs once from cloud-init; safe to re-run)
guest/ccvm-doctor        Read-only compliance check
guest/ccvm-update        Manual update command
guest/ccvm-domains       Edit Claude's sandbox domain allow-list (untested)
guest/ccvm-push          Push to GitHub yourself with a typed-in token; repo hooks/config treated as untrusted
guest/files/             sshd, sysctl, modprobe, fail2ban and auditd templates; Remote Control unit, loop
                         and login notice
keys/                    Pinned public signing keys (Ubuntu cloud images, Anthropic)
tests/lint.sh            shellcheck, a dry run, and cloud-init schema validation
```

## Development

`tests/lint.sh` needs Docker; CI runs the same checks. Please open an issue for problems, and see
[SECURITY.md](SECURITY.md) to report vulnerabilities.

## License

MIT - see [LICENSE](LICENSE).
