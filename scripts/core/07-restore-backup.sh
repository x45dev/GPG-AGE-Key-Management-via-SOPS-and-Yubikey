#!/usr/bin/env bash
# 07-restore-backup.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

BACKUP_PATH="$1"
[[ -f "$BACKUP_PATH" ]] || { log error "Missing backup: $BACKUP_PATH"; exit 1; }

log info "Decrypting backup archive with AGE..."
age -d -o restore.tar.gz "$BACKUP_PATH"
log info "Extracting..."
tar -xzf restore.tar.gz -C ./restore-temp
log info "Contents extracted to ./restore-temp"
