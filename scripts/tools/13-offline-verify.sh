#!/usr/bin/env bash
# 13-offline-verify.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require sops

log info "Verifying AGE and SOPS configuration in offline mode..."
ls ~/.config/sops/age/*.txt
grep 'public key' ~/.config/sops/age/*.txt
sops -d secrets/example.yaml >/dev/null && log info "Secrets decryptable."
