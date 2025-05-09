#!/usr/bin/env bash
# 12-rotate-gpg-subkeys.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

log info "Rotating GPG subkeys (requires master key)..."
require gpg

KEYID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/ { print $5; exit }')

cat > subkey-params.conf <<EOF
Key-Type: 1
Key-Length: 2048
Subkey-Type: default
Subkey-Length: 2048
Expire-Date: 1y
%commit
EOF

gpg --batch --edit-key "$KEYID" addkey
log info "Subkeys rotated. Provision to YubiKey manually via 'gpg --edit-key' if needed."
