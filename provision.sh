#!/usr/bin/env bash
# ============================================================================
# provision.sh - create the hardened Claude Code VM on a Proxmox VE host.
#
# Run it from a CLONE of this repository, as root on the Proxmox node:
#     git clone https://github.com/Roolk/claude-code-vm-hardened && cd claude-code-vm-hardened
#     less provision.sh guest/ccvm-harden.sh          # review before you run it
#     sudo ./provision.sh
#
# It is deliberately NOT designed for `curl | bash`: the guest scripts are
# bundled into the cloud-init payload from your reviewed local copy, so the VM
# never fetches and executes code from the internet.
#
# Everything is asked at run time. To pre-answer a question, export its CCVM_*
# variable (see README). Extra flags:
#     --dry-run   ask the questions and generate the cloud-init user-data into
#                 ./out/, but touch nothing on Proxmox and download nothing.
# ============================================================================
# shellcheck disable=SC2034  # CCVM_* settings are consumed via indirection (${!var}) in render_conf
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
[[ ${1:-} == --dry-run ]] && DRY_RUN=1

BOLD=$'\033[1m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYN=$'\033[36m'; NC=$'\033[0m'
say()  { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n' "$CYN" "$NC" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$GRN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YEL" "$NC" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
# shellcheck disable=SC2154  # rc is assigned inside the trap string itself
trap 'rc=$?; printf "%s[FAIL]%s provision.sh aborted at line %s (exit %s)\n" "$RED" "$NC" "$LINENO" "$rc" >&2' ERR
GNUPG_TMP=""
trap '[[ -n $GNUPG_TMP ]] && rm -rf "$GNUPG_TMP"' EXIT

# Pinned fingerprint of Canonical's "UEC Image Automatic Signing Key".
UBUNTU_IMAGE_KEY_FPR=D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81
UBUNTU_RELEASE=26.04
CACHE_DIR=${CCVM_CACHE_DIR:-/var/cache/ccvm}

# ── validators ──────────────────────────────────────────────────────────────
v_nonempty() { [[ -n $1 ]]; }
v_uint()     { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
v_vmid()     { [[ $1 =~ ^[1-9][0-9]{2,8}$ ]] && ! vmid_in_use "$1"; }
v_name()     { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
v_user()     { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ $1 != root ]]; }
v_cidr()     { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && octets_ok "${1%/*}" && (( 10#${1#*/} <= 32 )); }
v_ip()       { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && octets_ok "$1"; }
v_ip_or_cidr() { v_ip "$1" || v_cidr "$1"; }
v_ip_or_blank() { [[ -z $1 ]] || v_ip "$1"; }
v_tz()       { [[ $1 =~ ^[A-Za-z0-9_+./-]+$ ]]; }
v_mem()      { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 2048 )); }
v_disk()     { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 16 )); }
v_port()     { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
v_time()     { [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
v_vlan()     { [[ -z $1 ]] || { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 4094 )); }; }
v_sources()  { local s; [[ -n $1 ]] || return 1; for s in ${1//,/ }; do v_ip_or_cidr "$s" || return 1; done; }
v_ip_list_blank() { local s; [[ -z $1 ]] && return 0; for s in ${1//,/ }; do v_ip_or_cidr "$s" || return 1; done; }
v_reldir()   { [[ $1 =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && /$1/ != */../* ]]; }
v_domains()  { local d; [[ -n $1 ]] || return 1; for d in $1; do [[ $d =~ ^(\*\.)?[A-Za-z0-9.-]+$ ]] || return 1; done; }
octets_ok()  { local o x; IFS=. read -ra o <<<"$1"; for x in "${o[@]}"; do (( 10#$x <= 255 )) || return 1; done; }

vmid_in_use() {
  (( DRY_RUN )) && return 1
  qm status "$1" &>/dev/null && return 0
  pct status "$1" &>/dev/null && return 0
  compgen -G "/etc/pve/nodes/*/qemu-server/$1.conf" >/dev/null && return 0
  compgen -G "/etc/pve/nodes/*/lxc/$1.conf" >/dev/null && return 0
  return 1
}

# ── prompting ───────────────────────────────────────────────────────────────
# ask VAR "Prompt" "default" [validator]   (a preset VAR in the environment is used as-is)
ask() {
  local var=$1 prompt=$2 def=${3-} validator=${4:-v_nonempty} val
  if [[ -n ${!var-} ]]; then
    "$validator" "${!var}" || die "preset $var has an invalid value: ${!var}"
    say "  $prompt: ${!var}  (preset)"; return 0
  fi
  if [[ ${CCVM_NONINTERACTIVE:-0} == 1 ]]; then
    [[ -n $def ]] || [[ $validator == v_vlan || $validator == v_ip_or_blank || $validator == v_ip_list_blank ]] || die "$var is required in non-interactive mode"
    printf -v "$var" '%s' "$def"; return 0
  fi
  while :; do
    read -r -p "$BOLD$prompt$NC${def:+ [$def]}: " val </dev/tty || die "no terminal available"
    val=${val:-$def}
    if "$validator" "$val"; then printf -v "$var" '%s' "$val"; return 0; fi
    warn "that value isn't valid - try again"
  done
}

# choose VAR "Question" default_index "value|label" ...
choose() {
  local var=$1 q=$2 defidx=$3; shift 3
  local -a vals=() labels=(); local i=1 o
  for o in "$@"; do vals+=("${o%%|*}"); labels+=("${o#*|}"); done
  if [[ -n ${!var-} ]]; then
    for o in "${vals[@]}"; do [[ $o == "${!var}" ]] && { say "  $q: ${!var}  (preset)"; return 0; }; done
    die "preset $var='${!var}' is not one of: ${vals[*]}"
  fi
  if [[ ${CCVM_NONINTERACTIVE:-0} == 1 ]]; then printf -v "$var" '%s' "${vals[defidx-1]}"; return 0; fi
  say ""; say "${BOLD}$q${NC}"
  for o in "${labels[@]}"; do printf '  %d) %s\n' "$i" "$o"; i=$((i+1)); done
  local pick
  while :; do
    read -r -p "Choice [$defidx]: " pick </dev/tty || die "no terminal available"
    pick=${pick:-$defidx}
    if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#vals[@]} )); then
      printf -v "$var" '%s' "${vals[pick-1]}"; return 0
    fi
    warn "enter a number from 1 to ${#vals[@]}"
  done
}

confirm() { # confirm "Question" default(y|n)
  local def=${2:-n} a
  [[ ${CCVM_NONINTERACTIVE:-0} == 1 ]] && { [[ $def == y ]]; return; }
  read -r -p "$BOLD$1$NC [${def}]: " a </dev/tty || return 1
  a=${a:-$def}; [[ $a =~ ^[Yy] ]]
}

# ── preflight ───────────────────────────────────────────────────────────────
preflight() {
  [[ -f $REPO_ROOT/guest/ccvm-harden.sh && -f $REPO_ROOT/keys/ubuntu-cloudimage.asc ]] \
    || die "run provision.sh from a full clone of the repository"
  command -v ssh-keygen >/dev/null || die "ssh-keygen is required"
  command -v openssl   >/dev/null || die "openssl is required"
  command -v base64    >/dev/null || die "base64 is required"
  command -v tar       >/dev/null || die "tar is required"
  (( DRY_RUN )) && { warn "DRY RUN: nothing will be changed on Proxmox"; return 0; }
  [[ $EUID -eq 0 ]] || die "run as root on the Proxmox host"
  local c; for c in qm pvesm pvesh pveversion curl gpg sha256sum; do
    command -v "$c" >/dev/null || die "'$c' not found - is this a Proxmox VE host?"
  done
  [[ -t 0 || ${CCVM_NONINTERACTIVE:-0} == 1 ]] || die "interactive script: stdin is not a terminal"
  local ver; ver=$(pveversion | sed -n 's|^pve-manager/\([0-9]*\)\..*|\1|p')
  [[ ${ver:-0} -ge 8 ]] || warn "tested design targets Proxmox VE 8/9; you have '$(pveversion)'"
  if [[ -f /etc/pve/corosync.conf ]]; then
    warn "this node is in a cluster: the snippets storage must be reachable from the node that runs the VM"
  fi
}

# ── host discovery ──────────────────────────────────────────────────────────
list_storages() { # list_storages <content> -> name<TAB>type<TAB>free GiB
  pvesm status --content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {printf "%s\t%s\t%.0f\n",$1,$2,$6/1048576}' | sort -t$'\t' -k3,3nr || true
}
pick_storage() { # pick_storage VAR content "Question"
  local var=$1 content=$2 q=$3 rows name type free
  local -a opts=()
  rows=$(list_storages "$content")
  if (( DRY_RUN )) && [[ -z $rows ]]; then printf -v "$var" '%s' "${!var:-local}"; return 0; fi
  if [[ -z $rows ]]; then
    if [[ $content == snippets ]]; then
      die "no storage has the 'Snippets' content type enabled.
        Cloud-init files are plain files, so this must be a DIRECTORY-type storage (ZFS pools, LVM-thin and
        Ceph cannot hold snippets). The built-in 'local' storage is the usual choice:
          Datacenter > Storage > local > Edit > Content > tick 'Snippets'
        or from a shell: first run  pvesm status --storage local  and  grep -A6 '^dir: local' /etc/pve/storage.cfg
        to see the current content list, then add ',snippets' to it:
          pvesm set local --content <existing,types>,snippets
        then run this script again."
    fi
    die "no active storage with content type '$content' - enable it in Datacenter > Storage"
  fi
  while IFS=$'\t' read -r name type free; do opts+=("$name|$name ($type, ${free} GiB free)"); done <<<"$rows"
  choose "$var" "$q" 1 "${opts[@]}"
}
list_bridges() { { ip -o link show type bridge 2>/dev/null || true; } | awk -F': ' '{sub(/@.*/,"",$2); print $2}' | sort -V; }
bridge_subnet() { { ip -4 -o addr show dev "$1" 2>/dev/null || true; } | awk '{print $4; exit}' | python3 -c 'import sys,ipaddress
l=sys.stdin.read().strip()
print(ipaddress.ip_interface(l).network if l else "")' 2>/dev/null || true; }

# ── SSH key collection ──────────────────────────────────────────────────────
# validate_pubkey_line "<line>" -> prints a sanitised "type base64 comment", or
# returns 1 (invalid line) or 2 (private key). It runs in a subshell, so the caller aborts.
validate_pubkey_line() {
  local line=$1 tmp type blob comment bits
  [[ $line == *PRIVATE* ]] && return 2
  read -r type blob comment <<<"$line"
  case $type in
    ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa) ;;
    *) return 1 ;;
  esac
  [[ $blob =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
  tmp=$(mktemp); printf '%s %s\n' "$type" "$blob" > "$tmp"
  if ! bits=$(ssh-keygen -l -f "$tmp" 2>/dev/null | awk '{print $1}'); then rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
  if [[ $type == ssh-rsa ]] && (( bits < 3072 )); then warn "RSA key with only $bits bits rejected (need >= 3072)"; return 1; fi
  comment=$(tr -cd 'A-Za-z0-9@._-' <<<"${comment:-}")
  printf '%s %s %s\n' "$type" "$blob" "${comment:-key}"
}

collect_ssh_keys() {
  SSH_KEYS=()
  local src="${CCVM_SSH_KEY_SOURCE:-}" line k data
  if [[ -z $src ]]; then
    choose src "How do you want to provide your SSH PUBLIC key(s)?" 1 \
      "paste|Paste one public key line" \
      "file|Read from a file on this host (e.g. /root/.ssh/id_ed25519.pub)" \
      "github|Download from GitHub (https://github.com/<user>.keys)"
  fi
  case $src in
    paste)
      if [[ -n ${CCVM_SSH_PUBKEY:-} ]]; then data=$CCVM_SSH_PUBKEY
      else
        say "Paste ONE public key line (starts with ssh-ed25519 / ecdsa-... / sk-...). Never a private key."
        read -r -p "> " data </dev/tty
      fi ;;
    file)
      local f=${CCVM_SSH_KEY_FILE:-}
      [[ -n $f ]] || read -r -p "Path to public key file: " f </dev/tty
      [[ -r $f ]] || die "cannot read $f"; data=$(<"$f") ;;
    github)
      local u=${CCVM_GITHUB_USER:-}
      [[ -n $u ]] || read -r -p "GitHub username: " u </dev/tty
      [[ $u =~ ^[A-Za-z0-9-]{1,39}$ ]] || die "invalid GitHub username"
      data=$(curl -fsSL --max-time 15 "https://github.com/$u.keys") || die "could not fetch keys for $u"
      info "fetched $(wc -l <<<"$data") key(s) from github.com/$u - they are validated below" ;;
    *) die "unknown key source: $src" ;;
  esac
  while IFS= read -r line; do
    [[ -z ${line// } || $line == \#* ]] && continue
    if k=$(validate_pubkey_line "$line"); then SSH_KEYS+=("$k")
    elif (( $? == 2 )); then die "that looks like a PRIVATE key - never paste those. Aborting."
    else warn "skipped an invalid/unsupported key line"; fi
  done <<<"$data"
  (( ${#SSH_KEYS[@]} > 0 )) || die "no valid public keys were provided - refusing to continue (you would be locked out)"
  ok "${#SSH_KEYS[@]} valid public key(s) accepted"
  for k in "${SSH_KEYS[@]}"; do
    local t; t=$(mktemp); printf '%s\n' "$k" > "$t"; say "    $(ssh-keygen -l -f "$t" 2>/dev/null)"; rm -f "$t"
  done
}

# ── gather settings ─────────────────────────────────────────────────────────
gather() {
  say ""; say "${BOLD}=== Claude Code VM (hardened) - setup ===${NC}"
  say "Answer each question; press Enter to accept the [default]."
  say ""; say "${BOLD}-- Virtual machine --${NC}"

  local nextid=100
  (( DRY_RUN )) || nextid=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
  ask CCVM_VMID     "VM ID"             "$nextid" v_vmid
  ask CCVM_VM_NAME  "VM hostname"       "claude-code" v_name
  ask CCVM_CORES    "CPU cores"         4  v_uint
  ask CCVM_RAM      "RAM in MB"         8192 v_mem
  ask CCVM_DISK     "Disk size in GB"   40 v_disk
  pick_storage CCVM_STORAGE "images" "Storage for the VM disk"
  pick_storage CCVM_SNIPPET_STORAGE "snippets" "Storage for the cloud-init snippet (needs the 'Snippets' content type)"

  say ""; say "${BOLD}-- Network --${NC}"
  local bridges; bridges=$(list_bridges)
  if [[ -z ${CCVM_BRIDGE:-} && -n $bridges ]]; then
    local -a bo=(); local b; while read -r b; do [[ -n $b ]] && bo+=("$b|$b"); done <<<"$bridges"
    choose CCVM_BRIDGE "Network bridge (pick the one that reaches your LAN)" 1 "${bo[@]}"
  else
    ask CCVM_BRIDGE "Network bridge" "vmbr0"
  fi
  ask CCVM_VLAN "VLAN tag (blank for none)" "" v_vlan
  choose CCVM_IP_MODE "IP addressing" 1 "dhcp|DHCP (then make a reservation on your router)" "static|Static address"
  if [[ $CCVM_IP_MODE == static ]]; then
    ask CCVM_IP "Static IP in CIDR form (e.g. 192.168.1.50/24)" "" v_cidr
    ask CCVM_GW "Gateway" "" v_ip
  fi
  ask CCVM_DNS "DNS server (blank = use DHCP/host default)" "" v_ip_or_blank

  say ""; say "${BOLD}-- Administrator account (SSH keys only) --${NC}"
  ask CCVM_ADMIN_USER "Admin username" "" v_user
  collect_ssh_keys
  local suggest=""; suggest=$(bridge_subnet "$CCVM_BRIDGE")
  say ""
  say "SSH is reachable ONLY from the addresses you list (the VM's own firewall drops the rest)."
  ask CCVM_SSH_SOURCES "Allowed SSH source(s), comma-separated CIDRs/IPs" "$suggest" v_sources
  ask CCVM_SSH_PORT "SSH port" 22 v_port
  choose CCVM_SUDO_MODE "sudo for $CCVM_ADMIN_USER" 1 \
    "password|Require a password for sudo (recommended; the password is NOT usable for SSH)" \
    "nopasswd|Passwordless sudo (a stolen SSH key then equals root)"
  if [[ $CCVM_SUDO_MODE == password ]]; then
    if [[ -z ${CCVM_ADMIN_PASSWORD_HASH:-} ]]; then
      local p1 p2
      while :; do
        read -r -s -p "${BOLD}sudo password for $CCVM_ADMIN_USER${NC} (min 14 chars; never used for SSH): " p1 </dev/tty; echo
        (( ${#p1} >= 14 )) || { warn "at least 14 characters, please"; continue; }
        read -r -s -p "Repeat it: " p2 </dev/tty; echo
        [[ $p1 == "$p2" ]] && break || warn "passwords did not match"
      done
      CCVM_ADMIN_PASSWORD_HASH=$(printf '%s' "$p1" | openssl passwd -6 -stdin)
      unset p1 p2
    fi
  fi
  choose CCVM_SSH_TCP_FWD "SSH port forwarding / tunnelling" 1 \
    "no|Disabled (recommended)" "yes|Allow AllowTcpForwarding (needed for SSH tunnels / VS Code Remote)"
  CCVM_SSH_AGENT_FWD=${CCVM_SSH_AGENT_FWD:-no}

  say ""; say "${BOLD}-- System policy --${NC}"
  local tz; tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)
  ask CCVM_TIMEZONE "Timezone" "$tz" v_tz
  choose CCVM_UPDATE_POLICY "Operating-system updates" 1 \
    "security|Automatic SECURITY updates only, never auto-reboot (recommended)" \
    "security-reboot|Automatic security updates, auto-reboot when needed" \
    "none|No automatic updates - I will run 'sudo ccvm-update' myself"
  if [[ $CCVM_UPDATE_POLICY == security-reboot ]]; then
    ask CCVM_REBOOT_TIME "Reboot window (24h, VM time)" "04:00" v_time
  fi
  choose CCVM_EGRESS_BLOCK_LAN "Should the VM be blocked from INITIATING connections to your LAN / private ranges?" 1 \
    "yes|Yes - internet and the gateway/DNS only (a compromised VM cannot pivot to your LAN)" \
    "no|No - the VM can reach everything on the LAN"
  if [[ $CCVM_EGRESS_BLOCK_LAN == yes ]]; then
    ask CCVM_EGRESS_ALLOW "Extra LAN hosts the VM may reach (comma-separated, blank for none)" "" v_ip_list_blank
  else CCVM_EGRESS_ALLOW=${CCVM_EGRESS_ALLOW:-}; fi
  choose CCVM_DISABLE_IPV6 "IPv6" 1 "yes|Disable (recommended unless you use IPv6)" "no|Keep enabled"

  say ""; say "${BOLD}-- Docker --${NC}"
  choose CCVM_DOCKER "Docker" 1 \
    "rootless|Rootless Docker for $CCVM_ADMIN_USER (recommended; the root daemon stays masked)" \
    "none|No Docker"

  say ""; say "${BOLD}-- Claude Code --${NC}"
  choose CCVM_INSTALL_CLAUDE "Install Claude Code" 1 "yes|Yes (from Anthropic's signed apt repository)" "no|No"
  if [[ $CCVM_INSTALL_CLAUDE == yes ]]; then
    choose CCVM_CLAUDE_CHANNEL "Release channel" 1 \
      "stable|stable - about a week behind, skips regressions (recommended)" "latest|latest - newest releases"
    choose CCVM_CLAUDE_AUTO_UPDATE "Claude Code updates" 1 \
      "no|Manual only: 'sudo ccvm-update' (recommended)" \
      "yes|Include Claude Code in unattended upgrades"
    choose CCVM_CLAUDE_POLICY "Claude Code policy lock-in" 1 \
      "strict|Strict - managed policy only: users cannot add permission rules, hooks, MCP servers or plugin marketplaces, and network is limited to the allow-list" \
      "standard|Standard - sandbox + deny rules enforced, but users may extend permissions/hooks/MCP"
    choose CCVM_CLAUDE_MODE "Default permission mode" 1 \
      "default|default - asks before risky actions (recommended)" \
      "acceptEdits|acceptEdits - auto-approve file edits, still asks for commands" \
      "auto|auto - a classifier approves routine actions (fewer prompts, more trust)"
    ask CCVM_CLAUDE_DOMAINS "Domains Claude's sandboxed shell may reach (space-separated)" \
      "github.com api.github.com codeload.github.com objects.githubusercontent.com raw.githubusercontent.com registry.npmjs.org pypi.org files.pythonhosted.org proxy.golang.org sum.golang.org" v_domains
    choose CCVM_BWRAP_APPARMOR_FIX "Ubuntu 26.04 AppArmor workaround so Claude's sandbox can start" 1 \
      "yes|Yes - replace Ubuntu's bwrap AppArmor profile with Anthropic's documented one (needed, or every Claude shell command fails)" \
      "no|No - leave Ubuntu's profile (Claude's sandbox will likely fail to start until you fix it yourself)"
    choose CCVM_CLAUDE_REMOTE "Claude Code Remote Control (drive this VM's sessions from another device via Anthropic's servers)" 1 \
      "no|No - SSH only (recommended; keeps non-essential outbound traffic and feature-flag lookups disabled)" \
      "yes|Yes - allow it (adds an outbound channel from this VM; telemetry stays off)"
    if [[ $CCVM_CLAUDE_REMOTE == yes ]]; then
      choose CCVM_CLAUDE_RC_AUTOSTART "Start Remote Control automatically at every boot, in tmux session 'claude-rc'? (UNTESTED)" 1 \
        "yes|Yes - always available after a reboot; you log in once with 'claude' first" \
        "no|No - I will run 'claude rc' myself"
      if [[ $CCVM_CLAUDE_RC_AUTOSTART == yes ]]; then
        ask CCVM_CLAUDE_RC_DIR "Folder under the admin's home that Remote Control works in" "projects" v_reldir
      fi
    fi
    CCVM_CLAUDE_RC_AUTOSTART=${CCVM_CLAUDE_RC_AUTOSTART:-no}; CCVM_CLAUDE_RC_DIR=${CCVM_CLAUDE_RC_DIR:-projects}
    if [[ $CCVM_DOCKER == rootless ]]; then
      # On Linux the sandbox cannot allow one Unix socket: it blocks all of them or none.
      choose CCVM_CLAUDE_DOCKER "Can Claude use Docker? (Docker cannot run inside the sandbox; a container can read anything the admin user can and its network bypasses the domain allow-list)" 1 \
        "no|No - Claude cannot run docker (recommended)" \
        "prompt|Ask every time - 'docker ...' commands run OUTSIDE the sandbox, only after you approve each one" \
        "socket|Always - sandboxed commands may use EVERY Unix socket (Docker, the systemd/D-Bus user bus): the sandbox no longer contains them"
    else CCVM_CLAUDE_DOCKER=no; fi
  else
    # shellcheck disable=SC2034  # consumed by render_conf via indirection
    CCVM_CLAUDE_CHANNEL=stable; CCVM_CLAUDE_AUTO_UPDATE=no; CCVM_CLAUDE_POLICY=strict
    CCVM_CLAUDE_MODE=default; CCVM_CLAUDE_DOCKER=no; CCVM_CLAUDE_REMOTE=no; CCVM_BWRAP_APPARMOR_FIX=no
    CCVM_CLAUDE_RC_AUTOSTART=no; CCVM_CLAUDE_RC_DIR=projects
    CCVM_CLAUDE_DOMAINS="github.com"
  fi
  CCVM_BIOS=${CCVM_BIOS:-ovmf}
  CCVM_ONBOOT=${CCVM_ONBOOT:-1}
}

summary() {
  say ""; say "${BOLD}============ Summary ============${NC}"
  printf '  %-22s %s (%s)\n' "VM" "$CCVM_VMID" "$CCVM_VM_NAME"
  printf '  %-22s %s cores / %s MB / %s GB on %s\n' "Resources" "$CCVM_CORES" "$CCVM_RAM" "$CCVM_DISK" "$CCVM_STORAGE"
  printf '  %-22s Ubuntu %s LTS cloud image, %s firmware\n' "OS" "$UBUNTU_RELEASE" "$CCVM_BIOS"
  printf '  %-22s %s%s%s\n' "Network" "$CCVM_BRIDGE" "${CCVM_VLAN:+ vlan $CCVM_VLAN}" " / ${CCVM_IP:-DHCP}${CCVM_GW:+ gw $CCVM_GW}"
  printf '  %-22s %s (keys: %s), sudo: %s\n' "Admin" "$CCVM_ADMIN_USER" "${#SSH_KEYS[@]}" "$CCVM_SUDO_MODE"
  printf '  %-22s %s on port %s (tcp-forwarding: %s)\n' "SSH allowed from" "$CCVM_SSH_SOURCES" "$CCVM_SSH_PORT" "$CCVM_SSH_TCP_FWD"
  printf '  %-22s %s\n' "OS updates" "$CCVM_UPDATE_POLICY"
  printf '  %-22s %s\n' "Block LAN egress" "$CCVM_EGRESS_BLOCK_LAN${CCVM_EGRESS_ALLOW:+ (except $CCVM_EGRESS_ALLOW)}"
  printf '  %-22s %s\n' "Docker" "$CCVM_DOCKER"
  if [[ $CCVM_INSTALL_CLAUDE == yes ]]; then
    printf '  %-22s %s channel, policy %s, mode %s, docker: %s, remote-control: %s, bwrap-apparmor-fix: %s\n' "Claude Code" "$CCVM_CLAUDE_CHANNEL" "$CCVM_CLAUDE_POLICY" "$CCVM_CLAUDE_MODE" "$CCVM_CLAUDE_DOCKER" "$CCVM_CLAUDE_REMOTE" "$CCVM_BWRAP_APPARMOR_FIX"
    if [[ $CCVM_CLAUDE_RC_AUTOSTART == yes ]]; then
      printf '  %-22s at boot in tmux session claude-rc, in ~/%s (untested)\n' "Remote Control" "$CCVM_CLAUDE_RC_DIR"
    fi
  else printf '  %-22s %s\n' "Claude Code" "not installed"; fi
  say ""
}

# ── generate cloud-init user-data ───────────────────────────────────────────
# The CCVM_* settings are read via indirection (${!var}) below.
# shellcheck disable=SC2034
render_conf() {
  local k
  printf '# Generated by provision.sh - read by ccvm-harden\n'
  for k in ADMIN_USER SSH_SOURCES SSH_PORT SSH_TCP_FWD SSH_AGENT_FWD TIMEZONE DISABLE_IPV6 \
           EGRESS_BLOCK_LAN EGRESS_ALLOW DNS UPDATE_POLICY REBOOT_TIME DOCKER INSTALL_CLAUDE \
           CLAUDE_CHANNEL CLAUDE_AUTO_UPDATE CLAUDE_MODE CLAUDE_POLICY CLAUDE_DOCKER CLAUDE_REMOTE BWRAP_APPARMOR_FIX CLAUDE_RC_AUTOSTART CLAUDE_RC_DIR CLAUDE_DOMAINS SUDO_MODE; do
    local var="CCVM_$k"
    printf 'CCVM_%s=%q\n' "$k" "${!var-}"
  done
  printf 'CCVM_KEYS_DIR=/opt/ccvm/keys\n'
}

render_userdata() {
  local bundle k
  bundle=$(tar -C "$REPO_ROOT" --owner=0 --group=0 --numeric-owner -czf - guest keys | base64 -w0)
  {
    echo '#cloud-config'
    echo '# Generated by provision.sh. Contains your public key(s) and, if you chose'
    echo '# password-sudo, a salted SHA-512 hash - keep this file root-only.'
    echo "hostname: $CCVM_VM_NAME"
    echo 'manage_etc_hosts: true'
    echo 'ssh_pwauth: false'
    echo 'disable_root: true'
    echo 'users:'
    echo "  - name: $CCVM_ADMIN_USER"
    echo '    gecos: Administrator'
    echo '    shell: /bin/bash'
    if [[ $CCVM_SUDO_MODE == password ]]; then
      echo '    lock_passwd: false'
      echo "    passwd: '$CCVM_ADMIN_PASSWORD_HASH'"
    else
      echo '    lock_passwd: true'
    fi
    echo '    ssh_authorized_keys:'
    for k in "${SSH_KEYS[@]}"; do echo "      - '$k'"; done
    echo 'package_update: true'
    echo 'packages:'
    echo '  - qemu-guest-agent'
    echo '  - gnupg'
    echo '  - curl'
    echo 'write_files:'
    echo '  - path: /etc/ccvm/ccvm.conf'
    echo "    permissions: '0600'"
    echo '    owner: root:root'
    echo '    content: |'
    render_conf | sed 's/^/      /'
    echo '  - path: /var/lib/ccvm/bundle.tgz'
    echo "    permissions: '0600'"
    echo '    owner: root:root'
    echo '    encoding: b64'
    echo "    content: $bundle"
    echo 'runcmd:'
    echo '  - [ systemctl, enable, --now, qemu-guest-agent ]'
    echo '  - [ bash, -c, "{ install -d -m 0755 /opt/ccvm && tar -xzf /var/lib/ccvm/bundle.tgz -C /opt/ccvm && rm -f /var/lib/ccvm/bundle.tgz; } || touch /var/lib/ccvm/harden.failed" ]'
    echo '  - [ bash, -c, "set -o pipefail; /opt/ccvm/guest/ccvm-harden.sh 2>&1 | tee /var/log/ccvm-harden.log || touch /var/lib/ccvm/harden.failed" ]'
  }
}

# ── ubuntu cloud image (signature + checksum verified) ──────────────────────
fetch_image() {
  local arch; arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  [[ $arch == amd64 || $arch == arm64 ]] || die "unsupported architecture: $arch"
  local base="https://cloud-images.ubuntu.com/releases/$UBUNTU_RELEASE/release"
  local img="ubuntu-$UBUNTU_RELEASE-server-cloudimg-$arch.img"
  install -d -m 0700 "$CACHE_DIR"
  GNUPG_TMP=$(mktemp -d)
  chmod 700 "$GNUPG_TMP"
  local gh=$GNUPG_TMP

  info "Fetching checksums and signature from cloud-images.ubuntu.com"
  curl -fsSL --max-time 60 "$base/SHA256SUMS"     -o "$CACHE_DIR/SHA256SUMS"
  curl -fsSL --max-time 60 "$base/SHA256SUMS.gpg" -o "$CACHE_DIR/SHA256SUMS.gpg"

  GNUPGHOME=$gh gpg --batch --quiet --import "$REPO_ROOT/keys/ubuntu-cloudimage.asc" 2>/dev/null
  local fpr; fpr=$(GNUPGHOME=$gh gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')
  [[ $fpr == "$UBUNTU_IMAGE_KEY_FPR" ]] || die "bundled Ubuntu signing key has an unexpected fingerprint: $fpr"
  local status
  status=$(GNUPGHOME=$gh gpg --batch --status-fd 1 --verify "$CACHE_DIR/SHA256SUMS.gpg" "$CACHE_DIR/SHA256SUMS" 2>/dev/null || true)
  grep -q "^\[GNUPG:\] VALIDSIG .*$UBUNTU_IMAGE_KEY_FPR" <<<"$status" \
    || die "SHA256SUMS signature is NOT valid for Canonical's image-signing key - aborting"
  rm -rf "$gh"; GNUPG_TMP=""
  ok "SHA256SUMS signature verified (key $UBUNTU_IMAGE_KEY_FPR)"

  local want; want=$(awk -v f="*$img" '$2==f {print $1}' "$CACHE_DIR/SHA256SUMS")
  [[ -n $want ]] || die "$img not listed in SHA256SUMS"
  if [[ -f $CACHE_DIR/$img ]] && [[ $(sha256sum "$CACHE_DIR/$img" | awk '{print $1}') == "$want" ]]; then
    ok "cached image matches the signed checksum"
  else
    info "Downloading $img (about 600 MB)"
    curl -fL --max-time 1800 -o "$CACHE_DIR/$img.part" "$base/$img"
    [[ $(sha256sum "$CACHE_DIR/$img.part" | awk '{print $1}') == "$want" ]] \
      || { rm -f "$CACHE_DIR/$img.part"; die "image checksum mismatch - download discarded"; }
    mv "$CACHE_DIR/$img.part" "$CACHE_DIR/$img"
    ok "image checksum verified"
  fi
  IMAGE_PATH="$CACHE_DIR/$img"
}

# ── create the VM ───────────────────────────────────────────────────────────
create_vm() {
  local snip_file="ccvm-${CCVM_VMID}-user.yaml" snip_path
  snip_path=$(pvesm path "$CCVM_SNIPPET_STORAGE:snippets/$snip_file") || die "storage '$CCVM_SNIPPET_STORAGE' does not provide a snippets path"
  install -d -m 0700 "$(dirname "$snip_path")" 2>/dev/null || true
  ( umask 077; render_userdata > "$snip_path" )
  ok "cloud-init user-data written to $snip_path (mode 600)"

  local net="virtio,bridge=$CCVM_BRIDGE${CCVM_VLAN:+,tag=$CCVM_VLAN}"
  local ipcfg="ip=dhcp"
  [[ $CCVM_IP_MODE == static ]] && ipcfg="ip=$CCVM_IP,gw=$CCVM_GW"

  info "Creating VM $CCVM_VMID"
  local -a args=(
    --name "$CCVM_VM_NAME" --ostype l26 --machine q35 --cpu host
    --cores "$CCVM_CORES" --memory "$CCVM_RAM" --balloon 0
    --scsihw virtio-scsi-single --net0 "$net"
    --agent enabled=1 --serial0 socket --vga serial0
    --onboot "$CCVM_ONBOOT" --tags ccvm --protection 0
  )
  if [[ $CCVM_BIOS == ovmf ]]; then
    args+=( --bios ovmf --efidisk0 "$CCVM_STORAGE:1,efitype=4m,pre-enrolled-keys=1" )
  fi
  qm create "$CCVM_VMID" "${args[@]}"

  info "Importing the verified Ubuntu image"
  if ! qm set "$CCVM_VMID" --scsi0 "$CCVM_STORAGE:0,import-from=$IMAGE_PATH,discard=on,ssd=1,iothread=1"; then
    warn "'import-from' failed (error above); falling back to 'qm importdisk'"
    qm importdisk "$CCVM_VMID" "$IMAGE_PATH" "$CCVM_STORAGE" >/dev/null
    # The volume name depends on the storage type (e.g. 'local:100/vm-100-disk-1.raw'
    # on a directory storage), so take it from the unusedN entry importdisk added.
    local vol; vol=$(qm config "$CCVM_VMID" | awk '/^unused[0-9]+:/ {print $2; exit}')
    [[ -n $vol ]] || die "qm importdisk did not leave an unused disk to attach"
    qm set "$CCVM_VMID" --scsi0 "$vol,discard=on,ssd=1,iothread=1"
  fi
  qm set "$CCVM_VMID" --boot order=scsi0
  qm resize "$CCVM_VMID" scsi0 "${CCVM_DISK}G"

  qm set "$CCVM_VMID" --ide2 "$CCVM_STORAGE:cloudinit" \
    --cicustom "user=$CCVM_SNIPPET_STORAGE:snippets/$snip_file" \
    --ipconfig0 "$ipcfg" \
    ${CCVM_DNS:+--nameserver "$CCVM_DNS"}
  ok "VM $CCVM_VMID created"
}

gexec() { # gexec <cmd...>  -> prints stdout, returns the in-guest exit code
  local out rc
  out=$(qm guest exec "$CCVM_VMID" --timeout 120 -- "$@" 2>/dev/null) || return 255
  command -v python3 >/dev/null || { printf '%s\n' "$out"; return 0; }
  python3 -c 'import json,sys
d=json.load(sys.stdin); sys.stdout.write(d.get("out-data","")); sys.stderr.write(d.get("err-data",""))
sys.exit(int(d.get("exitcode",0)))' <<<"$out"
  rc=$?; return "$rc"
}

first_boot() {
  confirm "Start the VM now and wait for first-boot hardening to finish?" y || { say "Start it later with: qm start $CCVM_VMID"; return 0; }
  qm start "$CCVM_VMID"
  info "First boot downloads and installs packages - this takes several minutes."
  local t=0 limit=1800 step last="" agent=0
  while :; do
    # one guest call: done? failed? and the latest ">>>" step from the hardening log
    if st=$(gexec bash -c 'if [ -f /var/lib/ccvm/harden.done ]; then echo DONE; elif [ -f /var/lib/ccvm/harden.failed ]; then echo FAILED; else grep -h "^>>>" /var/log/ccvm-harden.log 2>/dev/null | tail -n1; fi' 2>/dev/null); then
      agent=1; st=${st//$'\n'/}
      case $st in
        DONE) break ;;
        FAILED)
          warn "the hardening script FAILED inside the VM. Last log lines:"
          gexec tail -n 25 /var/log/ccvm-harden.log || true
          warn "full log: qm guest exec $CCVM_VMID -- cat /var/log/ccvm-harden.log"; return 1 ;;
        *) step=${st:-"waiting for the hardening script to start (installing the guest agent / unpacking)"} ;;
      esac
    else
      step="VM booting / cloud-init running (guest agent not up yet)"
    fi
    if [[ $step != "$last" ]] || (( t % 120 == 0 && t > 0 )); then
      info "[${t}s] $step"; last=$step
    fi
    sleep 10; t=$((t+10))
    (( t < limit )) || {
      warn "timed out after ${limit}s (guest agent reached: $([[ $agent == 1 ]] && echo yes || echo no))."
      warn "check: qm terminal $CCVM_VMID   or   qm guest exec $CCVM_VMID -- tail -n 50 /var/log/cloud-init-output.log"
      return 1; }
  done
  ok "hardening finished; rebooting once to load the updated kernel"
  qm reboot "$CCVM_VMID" || warn "could not reboot automatically; reboot it yourself"
  sleep 20; t=0
  until qm agent "$CCVM_VMID" ping &>/dev/null; do
    sleep 5; t=$((t+5)); (( t < 300 )) || { warn "VM did not return after reboot within 5 minutes"; return 0; }
  done
  local ip fp
  ip=$(gexec bash -c "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null | tr -d '\n' || true)
  fp=$(gexec ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | tr -d '\n' || true)
  say ""; say "${BOLD}Health check inside the VM:${NC}"
  gexec /usr/local/sbin/ccvm-doctor || warn "ccvm-doctor reported failures (see above)"
  say ""; say "${GRN}${BOLD}Done.${NC}"
  say "  Connect:      ssh -p $CCVM_SSH_PORT $CCVM_ADMIN_USER@${ip:-<vm-ip>}"
  say "  Host key:     ${fp:-<unavailable>}"
  say "                ^ compare this with what ssh shows on your first connection."
  say "  Then run:     claude        (log in with your Anthropic account on first start)"
  if [[ $CCVM_CLAUDE_RC_AUTOSTART == yes ]]; then
    say "  Remote:       run 'claude' once in ~/$CCVM_CLAUDE_RC_DIR to log in and trust the folder; Remote Control"
    say "                then starts within 15 s and at every boot. Watch it: tmux attach -t claude-rc"
  fi
  say "  Updates:      sudo ccvm-update       Health: sudo ccvm-doctor"
  if [[ $CCVM_DHCP_NOTE == 1 ]]; then say "  Remember:     create a DHCP reservation for this VM on your router."; fi
}

main() {
  preflight
  gather
  summary
  if (( DRY_RUN )); then
    install -d -m 0700 "$REPO_ROOT/out"
    ( umask 077; render_userdata > "$REPO_ROOT/out/user-data.yaml" )
    ok "dry run: wrote out/user-data.yaml ($(wc -c < "$REPO_ROOT/out/user-data.yaml") bytes). Nothing else was done."
    return 0
  fi
  if [[ ${CCVM_NONINTERACTIVE:-0} == 1 ]]; then
    [[ ${CCVM_CONFIRM:-} == yes ]] || die "non-interactive mode: set CCVM_CONFIRM=yes to create the VM"
  else
    confirm "Create the VM with these settings?" n || { say "Aborted."; exit 0; }
  fi
  CCVM_DHCP_NOTE=0; [[ $CCVM_IP_MODE == dhcp ]] && CCVM_DHCP_NOTE=1
  fetch_image
  create_vm
  first_boot
}
main "$@"
