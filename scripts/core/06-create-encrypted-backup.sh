#!/usr/bin/env bash
# 06-create-encrypted-backup.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

BACKUP_DIR=${BACKUP_DIR:-backups}
mkdir -p "$BACKUP_DIR"
DATESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$BACKUP_DIR/key-backup-$DATESTAMP.tar.gz"

log info "Creating archive of GPG, project config, and identities..."
tar -czf "$ARCHIVE" \
  ~/.gnupg \
  ~/.config/sops/age/*.txt \
  .sops.yaml \
  keys \
  project.conf

log info "Encrypting with AGE..."
AGE_ID=$(grep '^# public key:' ~/.config/sops/age/*.txt | head -n1 | cut -d: -f2 | xargs)
age -r "$AGE_ID" -o "$ARCHIVE.age" "$ARCHIVE"
rm "$ARCHIVE"
sha256sum "$ARCHIVE.age" > "$ARCHIVE.age.sha256"
log info "Encrypted archive created at $ARCHIVE.age"
