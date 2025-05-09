#!/usr/bin/env bash
# 01-generate-gpg-master-key.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

log info "Generating offline GPG master key and subkeys..."

require gpg
mkdir -p keys

cat > keys/master-key.conf <<EOF
Key-Type: 1
Key-Length: 4096
Name-Real: ${GPG_NAME:-John Example}
Name-Email: ${GPG_EMAIL:-john@example.com}
Expire-Date: 2y
%commit
EOF

gpg --batch --gen-key keys/master-key.conf
log info "Master key created. Run backup next."

