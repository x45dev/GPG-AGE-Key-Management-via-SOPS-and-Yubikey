#!/usr/bin/env bash
# validate-config.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

[[ -f .env || -f .env.tracked ]] || log warn ".env or .env.tracked missing"
[[ -f .sops.yaml ]] || log error ".sops.yaml missing"
[[ -f project.conf || -f project.conf.example ]] || log warn "project.conf missing"
[[ -f secrets/.env.sops.yaml  ]] || log warn ".env.sops.yaml missing"
log info "Validation complete"
