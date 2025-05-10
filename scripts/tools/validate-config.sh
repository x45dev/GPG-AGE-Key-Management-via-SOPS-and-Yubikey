#!/usr/bin/env bash
# scripts/tools/validate-config.sh
# Validates the project's environment configuration, checking for key files and variables.

SHELL_OPTIONS="set -e -u -o pipefail" # Keep pipefail for robustness in checks
eval "$SHELL_OPTIONS"

# Correctly determine BASE_DIR relative to this script's location
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_SCRIPT_PATH="${BASE_DIR}/scripts/lib/common.sh"

if [ ! -f "$LIB_SCRIPT_PATH" ]; then
    echo "Error: common.sh not found at $LIB_SCRIPT_PATH"
    exit 1
fi
# shellcheck source=../lib/common.sh
source "$LIB_SCRIPT_PATH"

# --- Usage Function ---
usage() {
    echo "Usage: $(basename "$0")"
    echo ""
    echo "This script validates the project's environment configuration by checking for"
    echo "the existence of key files and the setting of important environment variables."
    echo "It sources variables defined in .mise.toml and .env files."
    echo ""
    echo "It will report errors for critical missing items and warnings for recommended ones."
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

log_info "Starting Project Configuration Validation..."
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

# File Checks
log_info "Checking for essential configuration files..."

if [ -f "${BASE_DIR}/.env.tracked" ]; then
    log_success "  Found .env.tracked"
else
    log_warn "  Optional: .env.tracked file is missing. Defaults from mise.toml will be used."
    VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
fi

if [ -f "${BASE_DIR}/.sops.yaml" ]; then
    log_success "  Found .sops.yaml"
else
    log_error "  CRITICAL: .sops.yaml file is missing. SOPS operations will likely fail."
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
fi

if [ -f "${BASE_DIR}/secrets/.env.sops.yaml" ]; then
    log_success "  Found secrets/.env.sops.yaml (for SOPS-managed environment variables)"
else
    log_warn "  Optional: secrets/.env.sops.yaml file is missing. No SOPS-managed secrets will be loaded via this file."
    VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
fi

# Environment Variable Checks (Variables are sourced by Mise before script execution)
log_info "Checking essential environment variables (values from .mise.toml or .env files)..."

check_env_var() {
    local var_name="$1"
    local level="$2" # "error" or "warn"
    local message_if_missing="$3"

    if [ -z "${!var_name:-}" ]; then
        if [ "$level" == "error" ]; then
            log_error "  CRITICAL: Environment variable ${var_name} is not set. ${message_if_missing}"
            VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
        else
            log_warn "  Optional: Environment variable ${var_name} is not set. ${message_if_missing}"
            VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
        fi
    else
        log_success "  Found ${var_name} (value is present, not displayed for potential sensitivity)"
    fi
}

check_env_var "GPG_USER_NAME" "error" "Required for GPG key generation."
check_env_var "GPG_USER_EMAIL" "error" "Required for GPG key generation."
check_env_var "PRIMARY_YUBIKEY_SERIAL" "warn" "Required for most primary YubiKey operations."
check_env_var "AGE_PRIMARY_YUBIKEY_IDENTITY_FILE" "warn" "Often used as default for SOPS_AGE_KEY_FILE."

log_info "Logging configuration:"
log_info "  LOG_LEVEL (for stdout): ${LOG_LEVEL:-info (default)}"
if [ -n "${YKM_LOG_FILE:-}" ]; then
    log_info "  YKM_LOG_FILE (for file logging): ${YKM_LOG_FILE}"
else
    log_info "  YKM_LOG_FILE (for file logging): Not set (file logging disabled)."
fi

echo # Newline for readability
if [ $VALIDATION_ERRORS -gt 0 ]; then
    log_error "Configuration validation failed with ${VALIDATION_ERRORS} critical error(s)."
    exit 1
elif [ $VALIDATION_WARNINGS -gt 0 ]; then
    log_warn "Configuration validation complete with ${VALIDATION_WARNINGS} warning(s)."
    log_warn "Review warnings. Some functionalities might be limited or use defaults."
    exit 0 # Warnings do not cause failure for this script
else
    log_success "Configuration validation complete. All essential checks passed."
fi

exit 0
