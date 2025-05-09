#!/usr/bin/env bash
# 10-check-expiring-keys.sh

set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require gpg

log info "Checking GPG keys expiring soon..."
gpg --list-keys --with-colons |
  awk -F: '/^pub/ {getline; split($1, a, "/"); printf "Key %s expires %s\n", $5, $2}'
