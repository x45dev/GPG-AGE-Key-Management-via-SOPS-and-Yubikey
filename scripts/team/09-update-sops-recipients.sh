#!/usr/bin/env bash
# 09-update-sops-recipients.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

log info "Updating .sops.yaml recipients from age-recipients.txt..."
AGE_KEYS=$(cut -d: -f2 age-recipients.txt | xargs)

echo "creation_rules:" > .sops.yaml
echo "  - path_regex: 'secrets/.*\\.yaml'" >> .sops.yaml
echo "    age: |" >> .sops.yaml
for key in $AGE_KEYS; do
  echo "      $key" >> .sops.yaml
done
log info ".sops.yaml updated with current recipients"
