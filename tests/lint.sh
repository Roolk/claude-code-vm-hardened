#!/usr/bin/env bash
# Static checks: shellcheck on every script, then a dry-run of provision.sh whose
# generated cloud-init user-data is validated with cloud-init's own schema checker.
# Needs Docker. Run from the repository root:  tests/lint.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "== shellcheck"
docker run --rm --name ccvm-lint-shellcheck -v "$PWD":/mnt -w /mnt koalaman/shellcheck:stable -x -S warning \
  provision.sh guest/ccvm-harden.sh guest/ccvm-doctor guest/ccvm-update guest/ccvm-domains tests/lint.sh

echo "== dry-run user-data"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
key="$tmp/k"; ssh-keygen -q -t ed25519 -N '' -f "$key"
rm -rf out
CCVM_NONINTERACTIVE=1 CCVM_VMID=999 CCVM_ADMIN_USER=tester CCVM_SSH_KEY_SOURCE=paste \
CCVM_SSH_PUBKEY="$(cat "$key.pub")" CCVM_SSH_SOURCES=10.0.0.0/24 CCVM_BRIDGE=vmbr0 \
CCVM_SUDO_MODE=password CCVM_ADMIN_PASSWORD_HASH='$6$salt$abcdefghijklmnopqrstuv' \
  ./provision.sh --dry-run >/dev/null

echo "== cloud-init schema"
docker run --rm --name ccvm-lint-cloudinit-schema -v "$PWD/out":/o ubuntu:26.04 bash -c \
  'apt-get update -qq >/dev/null && apt-get install -y -qq cloud-init >/dev/null 2>&1 && cloud-init schema --config-file /o/user-data.yaml'
rm -rf out
echo "OK"
