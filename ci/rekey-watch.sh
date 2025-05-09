#!/usr/bin/env bash
# ci/rekey-watch.sh

set -euo pipefail

log() { echo "[REKEY-CHECK] $*"; }

for f in $(find secrets -name '*.yaml'); do
  if sops -d "$f" >/dev/null 2>&1; then
    echo "$f is OK"
  else
    log "$f is encrypted with unknown or outdated recipients"
  fi
done
