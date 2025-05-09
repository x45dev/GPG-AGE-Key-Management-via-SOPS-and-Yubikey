#!/usr/bin/env bash
# 15-audit-secrets.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

log info "Auditing secrets and .sops.yaml consistency..."
find secrets -name '*.yaml' | while read -r f; do
  if ! grep -q 'sops:' "$f"; then
    log warn "$f has no sops metadata!"
  fi
done
