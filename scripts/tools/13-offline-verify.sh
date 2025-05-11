#!/usr/bin/env bash
# scripts/tools/13-offline-verify.sh
# Attempts to decrypt a specified SOPS file to verify key accessibility (e.g., YubiKey).

SHELL_OPTIONS="set -e -u -o pipefail"
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error when substituting.
# set -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status, or zero if no command exited with a non-zero status.
eval "$SHELL_OPTIONS"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_SCRIPT_PATH="${BASE_DIR}/scripts/lib/common.sh"

if [ ! -f "$LIB_SCRIPT_PATH" ]; then
    echo "Error: common.sh not found at $LIB_SCRIPT_PATH"
    exit 1
fi
# shellcheck source=../lib/common.sh
# Load common library functions (logging, prompts, etc.)
source "$LIB_SCRIPT_PATH"

# --- Usage Function ---
usage() {
    echo "Usage: $(basename "$0") [SOPS_FILE_TO_TEST] [AGE_IDENTITY_FILE]"
    echo ""
    echo "This script attempts to decrypt a SOPS-encrypted file to verify that the"
    echo "necessary cryptographic keys (e.g., on a YubiKey via AGE, or GPG keys)"
    echo "are accessible and operational."
    echo "This is useful for testing backup recovery or ensuring a YubiKey is correctly configured."
    echo ""
    echo "Arguments (Optional):"
    echo "  [SOPS_FILE_TO_TEST]   Path to the SOPS-encrypted file to test decryption against."
    echo "                        Default: \$OFFLINE_VERIFY_SOPS_FILE or 'secrets/example.yaml'."
    echo "  [AGE_IDENTITY_FILE]   Path to the AGE identity file to use for decryption if the SOPS file"
    echo "                        is AGE-encrypted and requires a specific identity not found by default."
    echo "                        Default: \$RESTORE_AGE_IDENTITY_FILE (which defaults to \$SOPS_AGE_KEY_FILE)."
    echo "                        If using a YubiKey for AGE, ensure it's connected."
    echo ""
    echo "The script will attempt to decrypt the SOPS file to /dev/null."
    echo "Make sure 'sops' is installed."
    exit 1
}

# Capture optional arguments.
SOPS_FILE_ARG="${1:-}"
AGE_IDENTITY_FILE_ARG="${2:-}"

# --- Configuration & Environment Variables ---
# Default SOPS file to test, relative to project root if not absolute.
DEFAULT_SOPS_TEST_FILE_CONFIG="${OFFLINE_VERIFY_SOPS_FILE:-secrets/example.yaml}"
# Default AGE identity file, uses RESTORE_AGE_IDENTITY_FILE logic (which can come from SOPS_AGE_KEY_FILE).
DEFAULT_AGE_IDENTITY_FILE_CONFIG="${RESTORE_AGE_IDENTITY_FILE:-${SOPS_AGE_KEY_FILE:-}}"

# Resolve SOPS file path: Use argument if provided, else use configured default.
SOPS_FILE_TO_TEST_CONFIG="${SOPS_FILE_ARG:-${DEFAULT_SOPS_TEST_FILE_CONFIG}}"
if [[ "$SOPS_FILE_TO_TEST_CONFIG" != /* ]]; then
    SOPS_FILE_TO_TEST="${BASE_DIR}/${SOPS_FILE_TO_TEST_CONFIG}"
else
    SOPS_FILE_TO_TEST="$SOPS_FILE_TO_TEST_CONFIG"
fi

# Resolve AGE identity file path (if provided or configured).
AGE_IDENTITY_FILE_TO_USE=""
if [ -n "$AGE_IDENTITY_FILE_ARG" ]; then
    AGE_IDENTITY_FILE_TO_USE="${AGE_IDENTITY_FILE_ARG/#\~/$HOME}" # Expand tilde if present.
elif [ -n "$DEFAULT_AGE_IDENTITY_FILE_CONFIG" ]; then
    AGE_IDENTITY_FILE_TO_USE="${DEFAULT_AGE_IDENTITY_FILE_CONFIG/#\~/$HOME}" # Expand tilde.
fi

# --- Script Specific Cleanup ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 13-offline-verify.sh with status $exit_status_for_cleanup"
    # No specific temporary files or sensitive variables to clean up for this read-only (decryption to /dev/null) script.
}

log_info "Starting SOPS Secret Decryption Verification Process..."

# --- Prerequisite Checks ---
check_command "sops"

# --- Step 1: Validate Files and Configuration ---
log_info "Step 1: Validating Files and Configuration."
if [ ! -f "$SOPS_FILE_TO_TEST" ]; then
    log_error "SOPS file to test not found: $SOPS_FILE_TO_TEST"
    usage
fi
log_info "Attempting to decrypt SOPS file: $SOPS_FILE_TO_TEST"

# Prepare the SOPS command array.
SOPS_DECRYPT_CMD_ARRAY=("sops" "--decrypt" "$SOPS_FILE_TO_TEST")

# Store original SOPS_AGE_KEY_FILE environment variable value if we're overriding it temporarily.
ORIGINAL_SOPS_AGE_KEY_FILE_ENV="${SOPS_AGE_KEY_FILE:-}" # Capture from env if set.

# If a specific AGE identity file is to be used, set SOPS_AGE_KEY_FILE temporarily.
# SOPS uses this environment variable to find AGE key files.
if [ -n "$AGE_IDENTITY_FILE_TO_USE" ]; then
    if [ ! -f "$AGE_IDENTITY_FILE_TO_USE" ]; then
        log_warn "Specified AGE identity file not found: $AGE_IDENTITY_FILE_TO_USE"
        log_warn "SOPS will attempt decryption using its default AGE key resolution methods."
        # Do not add -i if file not found, let sops handle it or prompt.
    else
        log_info "Using specific AGE identity file for decryption: $AGE_IDENTITY_FILE_TO_USE"
        export SOPS_AGE_KEY_FILE="$AGE_IDENTITY_FILE_TO_USE"
        log_debug "Temporarily set SOPS_AGE_KEY_FILE to: $SOPS_AGE_KEY_FILE"
    fi
else
    log_info "No specific AGE identity file provided by argument or RESTORE_AGE_IDENTITY_FILE."
    log_info "SOPS will use its default key resolution (e.g., YubiKey plugin, default software keys, or prompt)."
    # If SOPS_AGE_KEY_FILE was already set in the environment (e.g. by mise.toml), sops will use that.
    # If it wasn't, sops uses its internal defaults.
fi

log_warn "If decryption requires a YubiKey, ensure it is connected."
log_warn "If decryption requires a passphrase for a software AGE key, SOPS/AGE will prompt you."
log_warn "If decryption uses GPG, ensure gpg-agent is running and can access keys (e.g., YubiKey GPG applet)."

# --- Step 2: Attempt Decryption ---
log_info "Step 2: Attempting Decryption."
log_info "Running command: ${SOPS_DECRYPT_CMD_ARRAY[*]} (output to /dev/null)"

# Decrypt to /dev/null to avoid exposing secrets to stdout by default.
# Capture stderr to SOPS_DECRYPT_OUTPUT for potential error messages.
SOPS_DECRYPT_OUTPUT=$("${SOPS_DECRYPT_CMD_ARRAY[@]}" > /dev/null 2>&1)
SOPS_DECRYPT_EC=$?

# Restore original SOPS_AGE_KEY_FILE environment variable if it was temporarily changed.
if [ -n "$AGE_IDENTITY_FILE_TO_USE" ] && [ -f "$AGE_IDENTITY_FILE_TO_USE" ]; then # Check if we actually set it
    if [ -n "$ORIGINAL_SOPS_AGE_KEY_FILE_ENV" ]; then
        export SOPS_AGE_KEY_FILE="$ORIGINAL_SOPS_AGE_KEY_FILE_ENV"
    else
        unset SOPS_AGE_KEY_FILE # If it wasn't set before, unset it.
    fi
    log_debug "Restored/unset SOPS_AGE_KEY_FILE environment variable."
fi


if [ $SOPS_DECRYPT_EC -eq 0 ]; then
    log_success "Successfully decrypted SOPS file: $SOPS_FILE_TO_TEST"
    log_info "This indicates that the necessary cryptographic keys are accessible and operational."
else
    log_error "Failed to decrypt SOPS file: $SOPS_FILE_TO_TEST. sops Exit Code: $SOPS_DECRYPT_EC"
    log_error "SOPS Output (if any was captured to stderr, not shown here if redirected to /dev/null for secrets):"
    # To see SOPS output for debugging, you might temporarily remove `> /dev/null 2>&1` from the sops command.
    # For now, we assume common.sh's error logging is sufficient for the script's own messages.
    # log_error "${SOPS_DECRYPT_OUTPUT}" # Be careful with this, might contain sensitive info if not careful with redirection.
    log_error "Troubleshooting steps:"
    log_error "  - Ensure the correct YubiKey (if used) is connected and responsive."
    log_error "  - If using AGE with YubiKey, ensure the PIV applet is enabled and the correct identity file was used/found."
    log_error "  - If using GPG with YubiKey, ensure the OpenPGP applet is functional and gpg-agent is working."
    log_error "  - If using a software AGE key, ensure the correct identity file was used or the correct passphrase was entered if prompted."
    log_error "  - Check that the SOPS file is actually encrypted with a key you have access to (verify .sops.yaml recipients)."
    exit 1
fi

log_info "---------------------------------------------------------------------"
log_success "SOPS Secret Decryption Verification Complete."
log_info "---------------------------------------------------------------------"

exit 0
