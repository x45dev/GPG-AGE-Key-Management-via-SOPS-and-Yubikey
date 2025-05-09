#!/usr/bin/env bash
# 08-provision-additional-age-identity.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require age-plugin-yubikey
LABEL="$1"
FILE="~/.config/sops/age/$LABEL.txt"

log info "Generating AGE identity for $LABEL via YubiKey..."
age-plugin-yubikey --generate > "$FILE"

PUB=$(grep '^# public key:' "$FILE" | cut -d: -f2 | xargs)
echo "$LABEL: $PUB" >> age-recipients.txt
log info "Added $LABEL to age-recipients.txt"
