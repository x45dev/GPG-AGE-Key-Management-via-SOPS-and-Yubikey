#!/usr/bin/env bash
# scripts/core/16-generate-gpg-on-yubikey.sh
# Generates GPG master key and subkeys directly ON THE YUBIKEY.
# WARNING: Keys generated this way are NON-EXPORTABLE and NON-BACKABLE.

SHELL_OPTIONS="set -e -u -o pipefail"
eval "$SHELL_OPTIONS"

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
    echo "Usage: $(basename "$0") --serial <YUBIKEY_SERIAL>"
    echo ""
    echo "This script guides you through generating a new GPG master key and associated subkeys"
    echo "DIRECTLY ON THE SPECIFIED YUBIKEY's OpenPGP applet."
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  Keys generated using this method are NON-EXPORTABLE and NON-BACKABLE."
    echo "  If your YubiKey is lost, damaged, or reset, the GPG private keys"
    echo "  generated on it will be PERMANENTLY AND IRRECOVERABLY LOST."
    echo "  This method prioritizes maximum key security by ensuring private keys"
    echo "  never leave the hardware, but at the cost of traditional backup."
    echo "  Consider the '01-generate-gpg-master-key.sh' script for an off-device"
    echo "  master key strategy that allows for master key backup."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
    echo "Arguments:"
    echo "  --serial <YUBIKEY_SERIAL>   The serial number of the YubiKey to generate keys on."
    echo ""
    echo "Configuration is primarily via environment variables (see .mise.toml):"
    echo "  GPG_USER_NAME, GPG_USER_EMAIL, GPG_KEY_COMMENT, GPG_KEY_TYPE, GPG_EXPIRATION,"
    echo "  GPG_REVOCATION_REASON, OPENPGP_MIN_USER_PIN_LENGTH, OPENPGP_MIN_ADMIN_PIN_LENGTH."
    echo ""
    echo "The script will:"
    echo "  1. Connect to the specified YubiKey."
    echo "  2. Optionally reset the YubiKey's OpenPGP applet (with confirmation)."
    echo "  3. Guide you to set new User and Admin PINs for the OpenPGP applet."
    echo "  4. Prompt for User ID components (Name, Email, Comment) if not set in env."
    echo "  5. Use 'gpg --card-edit' and the 'generate' command to create keys on the YubiKey."
    echo "  6. Generate a revocation certificate for the on-card master key."
    echo "  7. Store the master key ID in '${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}' (this ID refers to the on-card key)."
    echo ""
    echo "Make sure 'gpg', 'ykman', 'gpg-connect-agent' are installed."
    exit 1
}

# Default PINs for YubiKey OpenPGP applet
DEFAULT_USER_PIN="123456"
DEFAULT_ADMIN_PIN="12345678"

# Script-specific variables
YK_SERIAL=""

# Variables for holding new PINs temporarily
NEW_USER_PIN_VALUE=""
NEW_ADMIN_PIN_VALUE=""
NEW_ADMIN_PIN_FOR_RESET=""

# --- Script Specific Cleanup Function ---
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 16-generate-gpg-on-yubikey.sh with status $exit_status_for_cleanup"
    unset NEW_USER_PIN_VALUE NEW_ADMIN_PIN_VALUE NEW_ADMIN_PIN_FOR_RESET
}

# --- Parse Command-Line Arguments ---
if [[ "$#" -eq 0 ]]; then usage; fi
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --serial) YK_SERIAL="$2"; shift ;;
        *) log_error "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

if [ -z "$YK_SERIAL" ]; then log_error "YubiKey serial number must be provided via --serial."; usage; fi

log_info "Starting On-YubiKey GPG Key Generation for YubiKey S/N: ${YK_SERIAL}"
log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! WARNING !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
log_warn "  Keys generated using this script are NON-EXPORTABLE and NON-BACKABLE."
log_warn "  Loss of this YubiKey means PERMANENT loss of these GPG private keys."
log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
if ! confirm "Are you absolutely sure you understand the risks and want to proceed?"; then
    log_info "Operation aborted by user."
    exit 0
fi

# --- Configuration & Environment Variables ---
GPG_USER_NAME="${GPG_USER_NAME:-}"
GPG_USER_EMAIL="${GPG_USER_EMAIL:-}"
GPG_KEY_COMMENT="${GPG_KEY_COMMENT:-YubiKey On-Card Key}"
GPG_KEY_TYPE="${GPG_KEY_TYPE:-RSA4096}" # RSA4096 or ED25519 (affects default choice in 'generate')
GPG_EXPIRATION="${GPG_EXPIRATION:-2y}"
GPG_REVOCATION_REASON_CODE="${GPG_REVOCATION_REASON:-0}"
GPG_MASTER_KEY_ID_FILE="${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}"
MASTER_KEY_ID_FILE_PATH="${BASE_DIR}/${GPG_MASTER_KEY_ID_FILE}"
OPENPGP_MIN_USER_PIN_LENGTH_CONFIG="${OPENPGP_MIN_USER_PIN_LENGTH:-6}"
OPENPGP_MIN_ADMIN_PIN_LENGTH_CONFIG="${OPENPGP_MIN_ADMIN_PIN_LENGTH:-8}"

# --- Prerequisite Checks ---
check_command "gpg"; check_command "ykman"; check_command "gpg-connect-agent"

# --- Step 1: Connect to YubiKey and Prepare OpenPGP Applet ---
log_info "Step 1: Connecting to YubiKey and Preparing OpenPGP Applet."
source "${BASE_DIR}/scripts/core/02-provision-gpg-yubikey.sh" --partial-for-oncard-setup "$YK_SERIAL"
# The sourced script part handles:
# - YK connection check
# - Optional applet reset
# - Setting new User and Admin PINs
# - Setting cardholder info
# It exits if any of these critical sub-steps fail.
log_info "YubiKey OpenPGP applet prepared (PINs set, optionally reset)."

# --- Step 2: Gather User Information for GPG Key ---
log_info "Step 2: Gathering User Information for GPG Key."
ensure_var_set "GPG_USER_NAME" "Enter your Full Name for the GPG key's User ID"
ensure_var_set "GPG_USER_EMAIL" "Enter your Email Address for the GPG key's User ID"
if [ -z "${GPG_KEY_COMMENT}" ]; then
    get_input "Enter an optional Comment (e.g., 'Work Key', press Enter to skip): " GPG_KEY_COMMENT
fi
log_info "GPG User ID will be: ${GPG_USER_NAME} (${GPG_KEY_COMMENT}) <${GPG_USER_EMAIL}>"

# --- Step 3: Generate Keys Directly on YubiKey ---
log_info "Step 3: Generating GPG Keys Directly on YubiKey S/N ${YK_SERIAL}."
log_warn "You will be prompted by GPG to confirm key parameters and enter the Admin PIN."
log_warn "The key type chosen (e.g., RSA 2048/3072/4096 or ECC) depends on YubiKey capabilities and GPG prompts."

# Construct GPG commands for 'gpg --card-edit'.
# The 'generate' command in card-edit mode initiates on-card key generation.
# It will prompt interactively for key parameters, UID, and PINs.
# We provide some defaults via environment variables that GPG *might* pick up,
# but the 'generate' command is largely interactive.
GPG_CARD_GEN_COMMANDS=$(cat <<EOF
admin
generate
EOF
)
# Note: The 'generate' command is interactive. We cannot fully script its internal prompts for
# key type, size, expiration, UID, and passphrase (which becomes the User PIN if not set).
# The user will need to follow GPG's on-screen prompts.

log_info "Executing 'gpg --card-edit' with 'generate' command..."
log_warn "Follow the GPG prompts carefully to configure your on-card keys."
log_warn "You will likely be asked to set key size, expiration, and confirm User ID."
log_warn "The YubiKey Admin PIN will be required."

# Set GNUPGHOME to default, as on-card generation creates stubs in the user's main keyring.
unset GNUPGHOME

GPG_CARD_GEN_OUTPUT=$(echo -e "${GPG_CARD_GEN_COMMANDS}" | gpg --no-tty --status-fd 1 --command-fd 0 --card-edit 2>&1)
GPG_CARD_GEN_EC=$?
log_debug "gpg --card-edit generate output (EC:${GPG_CARD_GEN_EC}):\n${GPG_CARD_GEN_OUTPUT}"

if [ $GPG_CARD_GEN_EC -ne 0 ]; then
    log_error "On-card GPG key generation failed. gpg Exit Code: $GPG_CARD_GEN_EC"
    log_error "GPG Output:\n${GPG_CARD_GEN_OUTPUT}"
    exit 1
fi
log_success "On-card GPG key generation process completed."

# --- Step 4: Identify Master Key ID and Generate Revocation Certificate ---
log_info "Step 4: Identifying Master Key ID and Generating Revocation Certificate."
# After 'generate', GPG creates stubs in the local keyring. We need to find the new master key ID.
# This assumes the UID provided during generation is unique enough to find the key.
MASTER_KEY_ID=$(gpg --no-tty --list-secret-keys --with-colons "${GPG_USER_EMAIL}" | awk -F: '/^sec>?:/ { print $5; exit }')
if [ -z "${MASTER_KEY_ID}" ]; then
    log_error "Could not retrieve the Master Key ID for UID '${GPG_USER_EMAIL}' after on-card generation."
    log_error "Please check 'gpg -K' manually to find the key ID."
    exit 1
fi
log_success "Identified on-card Master Key ID: ${MASTER_KEY_ID}"

REVOCATION_CERT_FILE="${BASE_DIR}/revocation-certificate-oncard-${MASTER_KEY_ID}.asc"
log_info "Generating revocation certificate for on-card key ${MASTER_KEY_ID}..."
log_warn "You will be prompted for the YubiKey User PIN (which acts as the passphrase for on-card keys)."

# GPG will prompt for the User PIN for --gen-revoke with on-card keys.
GPG_REVOKE_OUTPUT=$(gpg --no-tty --output "${REVOCATION_CERT_FILE}" --gen-revoke "${MASTER_KEY_ID}" 2>&1)
GPG_REVOKE_EC=$?
log_debug "gpg --gen-revoke output (EC:${GPG_REVOKE_EC}):\n${GPG_REVOKE_OUTPUT}"

if [ $GPG_REVOKE_EC -ne 0 ] || [ ! -s "${REVOCATION_CERT_FILE}" ]; then
    log_error "Failed to generate revocation certificate. GPG Exit Code: $GPG_REVOKE_EC"
    log_error "GPG Output:\n${GPG_REVOKE_OUTPUT}"
    [ -f "${REVOCATION_CERT_FILE}" ] && rm -f "${REVOCATION_CERT_FILE}"
    exit 1
fi
log_success "Revocation certificate generated: ${REVOCATION_CERT_FILE}"
log_warn "CRITICAL: Securely back up this revocation certificate (${REVOCATION_CERT_FILE})."
log_warn "Store it in multiple, secure, OFFLINE locations. This is your ONLY way to disavow the key if the YubiKey is lost."

# --- Step 5: Store Master Key ID ---
log_info "Step 5: Storing Master Key ID (references the on-card key)."
echo "${MASTER_KEY_ID}" > "${MASTER_KEY_ID_FILE_PATH}"
log_success "Master Key ID (${MASTER_KEY_ID}) for on-card key stored in ${MASTER_KEY_ID_FILE_PATH}"

log_info "---------------------------------------------------------------------"
log_success "On-YubiKey GPG Key Generation Complete for S/N ${YK_SERIAL}."
log_info "---------------------------------------------------------------------"
log_warn "!!!!!!!!!!!!!!!!!!!!!!!! REMEMBER THE RISKS !!!!!!!!!!!!!!!!!!!!!!!!!"
log_warn "  The GPG private keys (master and subkeys) generated reside ONLY on"
log_warn "  YubiKey S/N ${YK_SERIAL} and CANNOT BE BACKED UP."
log_warn "  Loss or damage to this YubiKey means PERMANENT loss of these keys."
log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
log_info "Summary:"
log_info "  - On-Card Master Key ID: ${MASTER_KEY_ID}"
log_info "  - Revocation certificate: ${REVOCATION_CERT_FILE} (BACK THIS UP SECURELY!)"
log_info "  - Master Key ID file: ${MASTER_KEY_ID_FILE_PATH}"
log_warn "Next Steps:"
log_warn "  1. VERY IMPORTANT: Securely back up the revocation certificate (${REVOCATION_CERT_FILE})."
log_warn "  2. Remember your YubiKey User and Admin PINs. Store them securely."
log_warn "  3. Your public key (for ID ${MASTER_KEY_ID}) can be exported from your GPG keyring and shared."

exit 0
