#!/usr/bin/env bash
# 04-provision-age-yubikey.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require age-plugin-yubikey
mkdir -p ~/.config/sops/age

log info "Generating AGE identity via YubiKey..."
age-plugin-yubikey --generate > "${SOPS_AGE_KEY_FILE:-~/.config/sops/age/primary.txt}"
log info "AGE identity created. Append public key to .sops.yaml."
