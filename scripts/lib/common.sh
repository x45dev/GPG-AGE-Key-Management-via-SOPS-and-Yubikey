#!/usr/bin/env bash
set -Eeuo pipefail

IFS=$'\n\t'
LOG_LEVEL=${LOG_LEVEL:-info}

log() {
  local level="$1"; shift
  local color
  case "$level" in
    info)  color="\033[1;34m" ;;
    warn)  color="\033[1;33m" ;;
    error) color="\033[1;31m" ;;
    *)     color="\033[0m"   ;;
  esac
  echo -e "${color}[$level]\033[0m $*"
}

confirm() {
  read -rp "$1 [y/N]: " response
  [[ "${response,,}" =~ ^y(es)?$ ]]
}

require() {
  command -v "$1" >/dev/null 2>&1 || { log error "Missing dependency: $1" >&2; exit 1; }
}

trap 'log error "An error occurred. Exiting."' ERR
