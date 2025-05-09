#!/usr/bin/env bash
# 03-backup-gpg-master-key.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require gpg
mkdir -p backups

log info "Exporting secret and public GPG keys..."
gpg --export-secret-keys > backups/master-key.priv.asc
gpg --export > backups/master-key.pub.asc
log info "Encrypted backup recommended using AGE or external vault."
