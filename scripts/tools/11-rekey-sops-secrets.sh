#!/usr/bin/env bash
# 11-rekey-sops-secrets.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require sops

log info "Re-encrypting SOPS secrets with updated recipients..."
find secrets -name '*.yaml' | while read -r file; do
  log info "Updating $file..."
  sops updatekeys "$file"
done
