# Claude sandbox does not start on Ubuntu 26.04

**Symptom:** every shell command Claude tries fails before it runs:

```
apply-seccomp: write /proc/self/setgroups (nested userns is capability-restricted; caller must provide CAP_SYS_ADMIN): Permission denied
```

`sudo ccvm-doctor` shows `FAIL Claude sandbox CANNOT start`.

**Cause:** Ubuntu 26.04 ships `/etc/apparmor.d/bwrap-userns-restrict`. It runs bwrap's children under an
`unpriv_bwrap` profile that denies `CAP_SYS_ADMIN`. Claude Code's bundled `apply-seccomp` helper creates a nested user
namespace, which needs that capability. Anthropic's documented fix (an `/etc/apparmor.d/bwrap` profile) declares the same
profile name as Ubuntu's, so only one can be loaded, and Ubuntu's wins again at every boot.
Upstream: https://github.com/anthropics/claude-code/issues/101946 (open when this was written).

## Workaround A (narrow): replace Ubuntu's bwrap profile with Anthropic's

Affects only programs that run `/usr/bin/bwrap` (Claude Code; Flatpak if installed). It switches off Ubuntu 26.04's
extra user-namespace restriction *for bwrap*; the sandbox's filesystem, network and seccomp rules stay in force.
Reported in the upstream thread and confirmed working on a live VM (Ubuntu 26.04, Claude Code 2.1.311): `bwrap` reports `unconfined` and Claude runs commands. `provision.sh` applies this by default (it asks first).

```bash
sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOT'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}
EOT
sudo mkdir -p /etc/apparmor.d/disable
sudo ln -sf /etc/apparmor.d/bwrap-userns-restrict /etc/apparmor.d/disable/
sudo apparmor_parser -R /etc/apparmor.d/bwrap-userns-restrict || true
sudo apparmor_parser -r /etc/apparmor.d/bwrap
```

The `disable/` symlink is what makes it survive a reboot. Verify (should print `unconfined`):

```bash
bwrap --ro-bind / / --dev /dev --proc /proc --unshare-user cat /proc/self/attr/current
sudo ccvm-doctor | grep -i sandbox
```

Restart `claude` afterwards.

## Workaround B (weaker): allow all Unix sockets

Settings-only (`sandbox.network.allowAllUnixSockets: true`). Reported upstream to make commands run by skipping the
failing helper step. It removes Claude's Unix domain socket blocking, so sandboxed commands can reach every local socket:
an ssh-agent, the Docker socket, and the systemd user bus, through which `systemd-run --user ...` starts a process
outside the sandbox. That makes it close to no sandbox at all. Prefer A.

## Not recommended
- `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` (all programs, lost at reboot, and reported not to be
  enough here because the bwrap profile still stacks `unpriv_bwrap`).
- Turning off the sandbox (`failIfUnavailable: false` plus allowing unsandboxed commands): defeats the point of this VM.
