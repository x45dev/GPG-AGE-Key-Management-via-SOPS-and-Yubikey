#!/usr/bin/env bash
# 05-clone-gpg-yubikey.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

log info "Cloning subkeys to backup YubiKey (requires master key)..."
gpg --edit-key ${GPG_EMAIL:-john@example.com}
log info "Run 'keytocard' and insert backup YubiKey when prompted."
