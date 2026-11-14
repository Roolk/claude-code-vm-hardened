# Security policy

## Reporting a vulnerability

Please report security issues **privately** using GitHub's
["Report a vulnerability"](https://github.com/Roolk/claude-code-vm-hardened/security/advisories/new) button
(Security tab -> Advisories) rather than a public issue. Include the script/section involved and how to reproduce it.

## Scope

This repository provisions a VM and applies a hardening baseline. In scope: flaws in `provision.sh`, `guest/*`,
the generated cloud-init, the pinned keys, or documentation that leads to a weaker setup than described.
Out of scope: vulnerabilities in Ubuntu, Proxmox, OpenSSH, Docker, or Claude Code themselves (report those upstream).

## Supply-chain notes

- `keys/ubuntu-cloudimage.asc` and `keys/claude-code.asc` are pinned public keys. Their fingerprints are checked in
  the scripts (`D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81` and `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`) and
  should match the values published by Canonical and Anthropic. Verify them against those sources before relying on them.
- The VM never fetches this repository after creation; updates to the hardening do not reach existing VMs unless
  you pull and re-run them yourself.
