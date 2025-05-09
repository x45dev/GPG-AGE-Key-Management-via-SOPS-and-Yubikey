#!/usr/bin/env bash
# 14-redact-secrets.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

log info "Generating redacted copies of secrets..."
mkdir -p secrets-redacted
find secrets -name '*.yaml' | while read -r file; do
  outfile="secrets-redacted/$(basename "$file")"
  sed 's/: .*/: REDACTED/' "$file" > "$outfile"
done
