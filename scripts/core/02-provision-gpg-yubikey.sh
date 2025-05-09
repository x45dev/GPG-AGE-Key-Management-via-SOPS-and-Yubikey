#!/usr/bin/env bash
# 02-provision-gpg-yubikey.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

log info "Provisioning subkeys to YubiKey..."
require gpg
require gpg-connect-agent

gpg --edit-key ${GPG_EMAIL:-john@example.com} <<EOF
key 1
keytocard
1
y
key 1
save
EOF

log info "Subkeys written to smartcard."
