#!/usr/bin/env bash
# ============================================================================
# ccvm-harden - first-boot hardening for the Claude Code VM (Ubuntu 26.04 LTS).
#
# Runs INSIDE the VM as root, once, from cloud-init (and is safe to re-run).
# Reads its settings from /etc/ccvm/ccvm.conf, which provision.sh generated
# from your answers. It never downloads or executes code from the internet:
# everything it installs comes from signed apt repositories (Ubuntu, Anthropic).
#
# Usage: ccvm-harden [--config FILE] [--files-dir DIR]
# ============================================================================
set -Eeuo pipefail
umask 022

CONF=/etc/ccvm/ccvm.conf
FILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/files"
while [[ $# -gt 0 ]]; do
  case $1 in
    --config)    CONF=$2; shift 2 ;;
    --files-dir) FILES_DIR=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

export DEBIAN_FRONTEND=noninteractive
LOG() { printf '>>> %s\n' "$*"; }
WARN() { printf '    [WARN] %s\n' "$*" >&2; }
die() { printf '[FATAL] %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2154  # rc is assigned inside the trap string itself
trap 'rc=$?; printf "[FATAL] ccvm-harden failed at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -r $CONF ]] || die "config not found: $CONF"
# shellcheck source=/dev/null
source "$CONF"

# --- Defaults for anything the config omitted --------------------------------
: "${CCVM_ADMIN_USER:?CCVM_ADMIN_USER missing}"
: "${CCVM_SSH_SOURCES:?CCVM_SSH_SOURCES missing}"
: "${CCVM_SSH_PORT:=22}"
: "${CCVM_SSH_TCP_FWD:=no}"
: "${CCVM_SSH_AGENT_FWD:=no}"
: "${CCVM_TIMEZONE:=UTC}"
: "${CCVM_DISABLE_IPV6:=yes}"
: "${CCVM_EGRESS_BLOCK_LAN:=yes}"
: "${CCVM_EGRESS_ALLOW:=}"
: "${CCVM_DNS:=}"
: "${CCVM_UPDATE_POLICY:=security}"          # security | security-reboot | none
: "${CCVM_REBOOT_TIME:=04:00}"
: "${CCVM_DOCKER:=rootless}"                 # rootless | none
: "${CCVM_INSTALL_CLAUDE:=yes}"
: "${CCVM_CLAUDE_CHANNEL:=stable}"           # stable | latest
: "${CCVM_CLAUDE_AUTO_UPDATE:=no}"
: "${CCVM_CLAUDE_MODE:=default}"             # default | acceptEdits | auto
: "${CCVM_CLAUDE_POLICY:=strict}"            # strict | standard
: "${CCVM_CLAUDE_DOCKER:=no}"; : "${CCVM_CLAUDE_REMOTE:=no}"
: "${CCVM_CLAUDE_DOMAINS:=github.com api.github.com codeload.github.com objects.githubusercontent.com raw.githubusercontent.com registry.npmjs.org pypi.org files.pythonhosted.org proxy.golang.org sum.golang.org}"
: "${CCVM_SUDO_MODE:=password}"              # password | nopasswd
: "${CCVM_STATE_DIR:=/var/lib/ccvm}"

# Defence in depth: the config is root-owned, but validate what ends up in
# shell, sshd and firewall syntax anyway.
[[ $CCVM_ADMIN_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid admin user name"
[[ $CCVM_ADMIN_USER != root ]] || die "admin user must not be root"
[[ $CCVM_SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( CCVM_SSH_PORT <= 65535 )) || die "invalid ssh port"
[[ -z $CCVM_DNS || $CCVM_DNS =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "invalid dns server: $CCVM_DNS"
for s in ${CCVM_SSH_SOURCES//,/ }; do
  [[ $s =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || die "invalid ssh source: $s"
done
for s in ${CCVM_EGRESS_ALLOW//,/ }; do
  [[ $s =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || die "invalid egress allow: $s"
done
[[ $CCVM_REBOOT_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "invalid reboot time"
[[ $CCVM_TIMEZONE =~ ^[A-Za-z0-9_+./-]+$ ]] || die "invalid timezone"
for d in $CCVM_CLAUDE_DOMAINS; do
  [[ $d =~ ^(\*\.)?[A-Za-z0-9.-]+$ ]] || die "invalid domain: $d"
done
case $CCVM_UPDATE_POLICY in security|security-reboot|none) ;; *) die "bad CCVM_UPDATE_POLICY" ;; esac
case $CCVM_CLAUDE_MODE in default|acceptEdits|auto) ;; *) die "bad CCVM_CLAUDE_MODE" ;; esac
case $CCVM_CLAUDE_POLICY in strict|standard) ;; *) die "bad CCVM_CLAUDE_POLICY" ;; esac
case $CCVM_CLAUDE_CHANNEL in stable|latest) ;; *) die "bad CCVM_CLAUDE_CHANNEL" ;; esac
case $CCVM_DOCKER in rootless|none) ;; *) die "bad CCVM_DOCKER" ;; esac
case $CCVM_SUDO_MODE in password|nopasswd) ;; *) die "bad CCVM_SUDO_MODE" ;; esac
[[ $CCVM_CLAUDE_DOCKER == yes ]] && CCVM_CLAUDE_DOCKER=socket   # older configs: yes meant socket access
case $CCVM_CLAUDE_DOCKER in no|prompt|socket) ;; *) die "bad CCVM_CLAUDE_DOCKER" ;; esac
[[ $CCVM_DOCKER == rootless ]] || CCVM_CLAUDE_DOCKER=no

id "$CCVM_ADMIN_USER" >/dev/null 2>&1 || die "admin user $CCVM_ADMIN_USER does not exist (cloud-init should have created it)"
ADMIN_UID=$(id -u "$CCVM_ADMIN_USER")
ADMIN_HOME=$(getent passwd "$CCVM_ADMIN_USER" | cut -d: -f6)
[[ -s $ADMIN_HOME/.ssh/authorized_keys ]] || die "no SSH key installed for $CCVM_ADMIN_USER - refusing to lock out password logins"

install -d -m 0755 "$CCVM_STATE_DIR"

# render FILE - fill @PLACEHOLDERS@ from the config.
render() {
  sed -e "s|@ADMIN_USER@|$CCVM_ADMIN_USER|g" \
      -e "s|@AGENT_FORWARDING@|$CCVM_SSH_AGENT_FWD|g" \
      -e "s|@TCP_FORWARDING@|$CCVM_SSH_TCP_FWD|g" "$1"
}

# ── 1. Base system ──────────────────────────────────────────────────────────
base_system() {
  LOG "Timezone: $CCVM_TIMEZONE"
  timedatectl set-timezone "$CCVM_TIMEZONE" || WARN "could not set timezone"

  LOG "Updating and upgrading OS packages"
  apt-get update -qq
  # --with-new-pkgs: a kernel update arrives as a NEW package, which plain upgrade keeps back.
  apt-get upgrade -y -qq --with-new-pkgs

  LOG "Installing security tooling"
  apt-get install -y -qq --no-install-recommends \
    ufw fail2ban auditd audispd-plugins unattended-upgrades apt-listchanges needrestart \
    apparmor apparmor-utils libpam-pwquality chrony qemu-guest-agent \
    git curl ca-certificates gnupg jq ripgrep \
    bubblewrap socat

  LOG "Removing unneeded services"
  apt-get purge -y -qq snapd lxd-installer 2>/dev/null || true
  systemctl disable --now multipathd.service multipathd.socket 2>/dev/null || true
  systemctl enable --now qemu-guest-agent.service 2>/dev/null || true
  systemctl enable --now chrony.service 2>/dev/null || true
}

# ── 2. Accounts and sudo ────────────────────────────────────────────────────
accounts() {
  LOG "Locking root password and enforcing sudo policy"
  passwd -l root >/dev/null

  local sudo_file=/etc/sudoers.d/10-ccvm-admin tmp
  tmp=$(mktemp)
  {
    echo "# Managed by ccvm-harden."
    echo "Defaults use_pty"
    if [[ $CCVM_SUDO_MODE == nopasswd ]]; then
      echo "$CCVM_ADMIN_USER ALL=(ALL) NOPASSWD:ALL"
    else
      echo "$CCVM_ADMIN_USER ALL=(ALL) ALL"
    fi
  } > "$tmp"
  chmod 0440 "$tmp"
  # Ubuntu 26.04 ships sudo-rs; its checker is visudo-rs. Fall back to visudo.
  local checker=""
  for c in visudo visudo-rs; do command -v "$c" >/dev/null 2>&1 && { checker=$c; break; }; done
  [[ -n $checker ]] || die "no sudoers syntax checker found (visudo/visudo-rs)"
  "$checker" -c -f "$tmp" >/dev/null || die "generated sudoers file failed validation"
  install -m 0440 -o root -g root "$tmp" "$sudo_file"
  rm -f "$tmp"
  # cloud-init's own sudoers drop-in would otherwise grant NOPASSWD.
  if [[ $CCVM_SUDO_MODE == password ]]; then
    rm -f /etc/sudoers.d/90-cloud-init-users
  fi

  if [[ $CCVM_SUDO_MODE == password ]]; then
    local st
    st=$(passwd -S "$CCVM_ADMIN_USER" | awk '{print $2}')
    [[ $st == P ]] || WARN "sudo requires a password but $CCVM_ADMIN_USER has none set (status=$st); sudo will not work"
  fi

  install -d -m 0755 /etc/security/pwquality.conf.d
  printf 'minlen = 14\nminclass = 3\n' > /etc/security/pwquality.conf.d/10-ccvm.conf
}

# ── 3. SSH ──────────────────────────────────────────────────────────────────
ssh_hardening() {
  LOG "Hardening sshd (keys only, user $CCVM_ADMIN_USER, port $CCVM_SSH_PORT)"
  install -d -m 0755 /etc/ssh/sshd_config.d
  render "$FILES_DIR/sshd.conf.in" > /etc/ssh/sshd_config.d/00-ccvm.conf
  [[ $CCVM_SSH_PORT != 22 ]] && echo "Port $CCVM_SSH_PORT" >> /etc/ssh/sshd_config.d/00-ccvm.conf
  chmod 0644 /etc/ssh/sshd_config.d/00-ccvm.conf
  install -m 0644 "$FILES_DIR/issue.net" /etc/issue.net

  # sshd keeps the FIRST value it sees, so anything left in other drop-ins that
  # re-enables passwords must go (cloud-init writes 50-cloud-init.conf).
  local f
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ $f == /etc/ssh/sshd_config.d/00-ccvm.conf ]] && continue
    if grep -qiE '^\s*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)\s+(yes|prohibit-password|without-password)' "$f"; then
      WARN "neutralising $f (re-enabled weaker auth)"
      sed -i -E 's/^(\s*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)\s+)(yes|prohibit-password|without-password)/\1no/I' "$f"
    fi
  done

  # Only an ed25519 host key.
  rm -f /etc/ssh/ssh_host_rsa_key* /etc/ssh/ssh_host_ecdsa_key*
  [[ -f /etc/ssh/ssh_host_ed25519_key ]] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key

  # Shrink the Diffie-Hellman moduli to >= 3072 bits (only used by legacy kex, which is off).
  if [[ -f /etc/ssh/moduli ]]; then
    awk '$5 >= 3071' /etc/ssh/moduli > /etc/ssh/moduli.safe
    if [[ -s /etc/ssh/moduli.safe ]]; then mv /etc/ssh/moduli.safe /etc/ssh/moduli; else rm -f /etc/ssh/moduli.safe; fi
  fi

  # Never restart into a config sshd rejects: that locks the box out.
  sshd -t || die "sshd config test failed; leaving the running sshd untouched"
  # Ubuntu uses socket activation for ssh; make it a plain service so Port/ListenAddress apply.
  systemctl disable --now ssh.socket 2>/dev/null || true
  systemctl enable ssh.service >/dev/null 2>&1 || true
  systemctl restart ssh.service
}

# ── 4. Firewall ─────────────────────────────────────────────────────────────
firewall() {
  LOG "Configuring ufw (default deny in; ssh only from: $CCVM_SSH_SOURCES)"
  if [[ $CCVM_DISABLE_IPV6 == yes ]]; then
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  else
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  fi

  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw default deny routed >/dev/null

  local s
  for s in ${CCVM_SSH_SOURCES//,/ }; do
    ufw allow in proto tcp from "$s" to any port "$CCVM_SSH_PORT" comment 'ccvm ssh' >/dev/null
  done

  if [[ $CCVM_EGRESS_BLOCK_LAN == yes ]]; then
    LOG "Blocking VM-initiated connections to private/LAN ranges (egress)"
    local gw dns
    gw=$(ip -4 route show default | awk '{print $3; exit}')
    # Exceptions first: ufw evaluates rules in order.
    [[ -n $gw ]] && ufw allow out to "$gw" comment 'ccvm gateway' >/dev/null
    for dns in $CCVM_DNS $(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u); do
      [[ $dns =~ ^127\. ]] && continue
      ufw allow out to "$dns" port 53 comment 'ccvm dns' >/dev/null
    done
    for s in ${CCVM_EGRESS_ALLOW//,/ }; do
      ufw allow out to "$s" comment 'ccvm egress allow' >/dev/null
    done
    local net
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
      ufw deny out to "$net" comment 'ccvm no-lan' >/dev/null
    done
    # With IPv6 on, the LAN is also reachable via link-local and ULA addresses.
    # Neighbour discovery and DHCPv6 are accepted earlier by ufw's before6.rules.
    if [[ $CCVM_DISABLE_IPV6 != yes ]]; then
      for net in fe80::/10 fc00::/7; do
        ufw deny out to "$net" comment 'ccvm no-lan' >/dev/null
      done
    fi
  fi

  ufw logging low >/dev/null
  ufw --force enable >/dev/null
  systemctl enable ufw.service >/dev/null 2>&1 || true
}

# ── 5. Kernel, modules, logging ─────────────────────────────────────────────
system_hardening() {
  LOG "Applying sysctl, module blacklist, journald and fail2ban settings"
  install -d -m 0755 /etc/sysctl.d /etc/modprobe.d /etc/fail2ban/jail.d /etc/audit/rules.d
  rm -f /etc/sysctl.d/60-ccvm.conf /etc/sysctl.d/61-ccvm-ipv6.conf
  install -m 0644 "$FILES_DIR/sysctl.conf" /etc/sysctl.d/99-zz-ccvm.conf
  if [[ $CCVM_DISABLE_IPV6 == yes ]]; then
    printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' > /etc/sysctl.d/99-zz-ccvm-ipv6.conf
  else
    rm -f /etc/sysctl.d/99-zz-ccvm-ipv6.conf
  fi
  sysctl --system >/dev/null || WARN "some sysctl keys were rejected (kernel may lack them)"

  install -m 0644 "$FILES_DIR/modprobe.conf" /etc/modprobe.d/ccvm-blacklist.conf

  install -d -m 0755 /etc/systemd/journald.conf.d /etc/systemd/coredump.conf.d
  printf '[Journal]\nStorage=persistent\nCompress=yes\nSystemMaxUse=500M\n' > /etc/systemd/journald.conf.d/10-ccvm.conf
  printf '[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf.d/10-ccvm.conf
  systemctl restart systemd-journald

  install -m 0644 "$FILES_DIR/fail2ban.local" /etc/fail2ban/jail.d/10-ccvm.local
  # Add the port to the existing [sshd] section: a second [sshd] header in the
  # same file is a DuplicateSectionError and fail2ban refuses to start.
  if [[ $CCVM_SSH_PORT != 22 ]]; then
    sed -i "/^\[sshd\]\$/a port = $CCVM_SSH_PORT" /etc/fail2ban/jail.d/10-ccvm.local
  fi
  systemctl enable fail2ban.service >/dev/null 2>&1 || true
  systemctl restart fail2ban.service || WARN "fail2ban did not start"

  render "$FILES_DIR/audit.rules.in" > /etc/audit/rules.d/60-ccvm.rules
  augenrules --load >/dev/null 2>&1 || WARN "could not load audit rules now (will load on next boot)"
  systemctl enable auditd.service >/dev/null 2>&1 || true
}

# ── 6. Automatic updates ────────────────────────────────────────────────────
updates() {
  LOG "Update policy: $CCVM_UPDATE_POLICY"
  if [[ $CCVM_UPDATE_POLICY == none ]]; then
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "0";\n' > /etc/apt/apt.conf.d/20auto-upgrades
    rm -f /etc/apt/apt.conf.d/51ccvm-unattended
    return 0
  fi

  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\n' > /etc/apt/apt.conf.d/20auto-upgrades
  {
    echo '// Managed by ccvm-harden. #clear drops the distro default origin list.'
    echo '#clear Unattended-Upgrade::Allowed-Origins;'
    echo 'Unattended-Upgrade::Allowed-Origins {'
    echo '  "${distro_id}:${distro_codename}-security";'
    echo '  "${distro_id}ESMApps:${distro_codename}-apps-security";'
    echo '  "${distro_id}ESM:${distro_codename}-infra-security";'
    if [[ $CCVM_CLAUDE_AUTO_UPDATE == yes ]]; then
      echo '  "Anthropic:stable";'
      echo '  "Anthropic:latest";'
    fi
    echo '};'
    echo 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'
    echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
    if [[ $CCVM_UPDATE_POLICY == security-reboot ]]; then
      echo 'Unattended-Upgrade::Automatic-Reboot "true";'
      echo 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";'
      echo "Unattended-Upgrade::Automatic-Reboot-Time \"$CCVM_REBOOT_TIME\";"
    else
      echo 'Unattended-Upgrade::Automatic-Reboot "false";'
    fi
  } > /etc/apt/apt.conf.d/51ccvm-unattended
  systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
}

# ── 7. Claude Code (signed apt repository, pinned key) ──────────────────────
claude_code() {
  [[ $CCVM_INSTALL_CLAUDE == yes ]] || { LOG "Skipping Claude Code install"; return 0; }
  LOG "Installing Claude Code from Anthropic's signed apt repo ($CCVM_CLAUDE_CHANNEL channel)"

  local key=/etc/apt/keyrings/claude-code.asc
  local src="${CCVM_KEYS_DIR:-$FILES_DIR/../keys}/claude-code.asc"
  [[ -s $src ]] || die "pinned Claude Code key not found at $src"
  # Verify the key's fingerprint against the value published in Anthropic's docs
  # before trusting it for apt.
  local want=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE got
  got=$(gpg --show-keys --with-colons "$src" | awk -F: '$1=="fpr"{print $10; exit}')
  [[ $got == "$want" ]] || die "Claude Code signing key fingerprint mismatch: got '$got'"
  install -d -m 0755 /etc/apt/keyrings
  install -m 0644 -o root -g root "$src" "$key"

  echo "deb [signed-by=$key] https://downloads.claude.ai/claude-code/apt/$CCVM_CLAUDE_CHANNEL $CCVM_CLAUDE_CHANNEL main" \
    > /etc/apt/sources.list.d/claude-code.list
  apt-get update -qq
  apt-get install -y -qq claude-code
  claude --version

  claude_policy
}

# Managed settings live in /etc/claude-code and outrank user/project settings.
claude_policy() {
  LOG "Writing Claude Code managed policy ($CCVM_CLAUDE_POLICY, mode $CCVM_CLAUDE_MODE)"
  install -d -m 0755 /etc/claude-code

  local domains_json
  local -a dom_arr
  read -r -a dom_arr <<< "$CCVM_CLAUDE_DOMAINS"   # read -a does not glob-expand '*.example.com'
  domains_json=$(printf '%s\n' "${dom_arr[@]}" | jq -R . | jq -s .)

  # Docker access for Claude. On Linux, network.allowUnixSockets (a path list) is
  # ignored: the seccomp filter blocks every AF_UNIX socket or none.
  #   prompt: "docker ..." runs outside the sandbox through the normal permission prompt
  #   socket: allowAllUnixSockets - every Unix socket, including the systemd user bus
  jq -n \
    --arg mode "$CCVM_CLAUDE_MODE" \
    --arg policy "$CCVM_CLAUDE_POLICY" \
    --arg channel "$CCVM_CLAUDE_CHANNEL" \
    --arg remote "$CCVM_CLAUDE_REMOTE" \
    --argjson domains "$domains_json" \
    --arg docker "$CCVM_CLAUDE_DOCKER" \
    --arg home "$ADMIN_HOME" '
    {
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      permissions: {
        defaultMode: $mode,
        disableBypassPermissionsMode: "disable",
        deny: [
          "Read(~/.ssh/**)", "Edit(~/.ssh/**)",
          "Read(~/.gnupg/**)", "Edit(~/.gnupg/**)",
          "Read(~/.config/gh/**)", "Read(~/.docker/config.json)",
          "Read(~/.claude/.credentials.json)", "Edit(~/.claude/.credentials.json)",
          "Read(**/.env)", "Read(**/.env.*)", "Read(**/secrets/**)",
          "Read(**/*.pem)", "Read(**/*.key)", "Read(**/id_rsa)", "Read(**/id_ed25519)",
          "Read(//etc/shadow)", "Read(//etc/ssh/ssh_host_*)",
          "Edit(//etc/**)", "Edit(~/.bashrc)", "Edit(~/.profile)", "Edit(~/.bash_profile)"
        ]
      },
      sandbox: ({
        enabled: true,
        failIfUnavailable: true,
        allowUnsandboxedCommands: false,
        autoAllowBashIfSandboxed: true,
        credentials: {
          files: [
            {path: "~/.ssh", mode: "deny"},
            {path: "~/.gnupg", mode: "deny"},
            {path: "~/.config/gh", mode: "deny"},
            {path: "~/.docker/config.json", mode: "deny"},
            {path: "~/.claude/.credentials.json", mode: "deny"}
          ],
          envVars: [
            {name: "GITHUB_TOKEN", mode: "deny"}, {name: "GH_TOKEN", mode: "deny"},
            {name: "NPM_TOKEN", mode: "deny"}, {name: "AWS_SECRET_ACCESS_KEY", mode: "deny"},
            {name: "AWS_SESSION_TOKEN", mode: "deny"}, {name: "ANTHROPIC_API_KEY", mode: "deny"}
          ]
        },
        network: ({ allowedDomains: $domains }
          + (if $docker == "socket" then { allowAllUnixSockets: true } else {} end)
          + (if $policy == "strict" then { allowManagedDomainsOnly: true } else {} end))
      } + (if $docker == "prompt" then { excludedCommands: ["docker *"] } else {} end)),
      env: ({
        DISABLE_TELEMETRY: "1",
        DISABLE_ERROR_REPORTING: "1",
        DISABLE_AUTOUPDATER: "1"
      } + (if $remote == "yes" then {} else { CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1" } end)),
      autoUpdatesChannel: $channel
    }
    + (if $policy == "strict" then {
        allowManagedPermissionRulesOnly: true,
        allowManagedHooksOnly: true,
        allowManagedMcpServersOnly: true,
        strictKnownMarketplaces: []
      } else {} end)
  ' > /etc/claude-code/managed-settings.json
  chmod 0644 /etc/claude-code/managed-settings.json
  jq -e . /etc/claude-code/managed-settings.json >/dev/null || die "generated managed-settings.json is not valid JSON"
  install -d -m 0755 /etc/claude-code/managed-settings.d

  # A working directory for projects, owned by the admin user.
  install -d -m 0750 -o "$CCVM_ADMIN_USER" -g "$CCVM_ADMIN_USER" "$ADMIN_HOME/projects"
}

# ── 8. Rootless Docker ──────────────────────────────────────────────────────
docker_rootless() {
  [[ $CCVM_DOCKER == rootless ]] || { LOG "Skipping Docker"; return 0; }
  LOG "Installing rootless Docker for $CCVM_ADMIN_USER"
  apt-get install -y -qq --no-install-recommends \
    docker.io uidmap dbus-user-session slirp4netns passt rootlesskit docker-compose-v2 docker-buildx

  # The root daemon must never run: it is the privilege-escalation path rootless avoids.
  systemctl disable --now docker.service docker.socket containerd.service 2>/dev/null || true
  systemctl mask docker.service docker.socket 2>/dev/null || true
  # Nobody belongs in the docker group.
  if getent group docker >/dev/null; then
    for m in $(getent group docker | cut -d: -f4 | tr ',' ' '); do gpasswd -d "$m" docker >/dev/null || true; done
  fi

  grep -q "^$CCVM_ADMIN_USER:" /etc/subuid || usermod --add-subuids 100000-165535 "$CCVM_ADMIN_USER"
  grep -q "^$CCVM_ADMIN_USER:" /etc/subgid || usermod --add-subgids 100000-165535 "$CCVM_ADMIN_USER"

  loginctl enable-linger "$CCVM_ADMIN_USER"
  systemctl start "user@${ADMIN_UID}.service"
  local i=0
  while [[ ! -S /run/user/$ADMIN_UID/bus && $i -lt 30 ]]; do sleep 1; i=$((i+1)); done
  [[ -S /run/user/$ADMIN_UID/bus ]] || { WARN "user bus not available; rootless Docker setup skipped"; return 0; }

  local setup=/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh
  [[ -x $setup ]] || setup=$(command -v dockerd-rootless-setuptool.sh || true)
  [[ -n $setup ]] || { WARN "dockerd-rootless-setuptool.sh not found"; return 0; }

  local rt="XDG_RUNTIME_DIR=/run/user/$ADMIN_UID DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$ADMIN_UID/bus"
  # shellcheck disable=SC2086
  runuser -u "$CCVM_ADMIN_USER" -- env $rt PATH="/usr/share/docker.io/contrib:$PATH" "$setup" install --force \
    || WARN "rootless Docker setup reported errors"
  # shellcheck disable=SC2086
  runuser -u "$CCVM_ADMIN_USER" -- env $rt systemctl --user enable --now docker.service \
    || WARN "could not enable the user docker service"

  # Point the admin's shells at the rootless socket.
  local marker="# ccvm rootless docker"
  if ! grep -q "$marker" "$ADMIN_HOME/.bashrc" 2>/dev/null; then
    {
      echo "$marker"
      echo 'export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"'
    } >> "$ADMIN_HOME/.bashrc"
    chown "$CCVM_ADMIN_USER:$CCVM_ADMIN_USER" "$ADMIN_HOME/.bashrc"
  fi
}

# ── 9. Tools and finish ─────────────────────────────────────────────────────
tooling() {
  LOG "Installing ccvm-update, ccvm-doctor and ccvm-domains"
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for t in ccvm-update ccvm-doctor ccvm-domains; do
    [[ -f $here/$t ]] && install -m 0755 -o root -g root "$here/$t" "/usr/local/sbin/$t"
  done
  # shell prompt reminder of pending reboot is left to needrestart/motd.
  apt-get -y -qq autoremove
  apt-get -qq clean
}

main() {
  LOG "ccvm-harden starting ($(date -u +%FT%TZ))"
  base_system
  accounts
  ssh_hardening
  firewall
  system_hardening
  updates
  claude_code
  docker_rootless
  tooling
  date -u +%FT%TZ > "$CCVM_STATE_DIR/harden.done"
  LOG "ccvm-harden complete"
}
main
