#!/usr/bin/env bash
# scripts/team/17-setup-age-yubikey-redundancy.sh
# Assists in setting up AGE YubiKey redundancy by provisioning a second YubiKey
# with a new AGE identity and guiding the update of SOPS configuration.

SHELL_OPTIONS="set -e -u -o pipefail"
eval "$SHELL_OPTIONS"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # Adjusted BASE_DIR for team script
LIB_SCRIPT_PATH="${BASE_DIR}/scripts/lib/common.sh"

if [ ! -f "$LIB_SCRIPT_PATH" ]; then
    echo "Error: common.sh not found at $LIB_SCRIPT_PATH"
    exit 1
fi
# shellcheck source=scripts/lib/common.sh
source "$LIB_SCRIPT_PATH"

# --- Usage Function ---
usage() {
    echo "Usage: $(basename "$0")"
    echo ""
    echo "This script helps set up redundancy for AGE-encrypted secrets by guiding you through:"
    echo "  1. Identifying your primary YubiKey AGE identity."
    echo "  2. Provisioning a NEW, DISTINCT AGE identity on a second (backup) YubiKey."
    echo "  3. Ensuring both public keys are in your AGE recipients list file."
    echo "  4. Updating your .sops.yaml to use both AGE keys as recipients."
    echo "  5. Instructing you to rekey existing SOPS files."
    echo ""
    echo "WARNING: This script assumes your primary YubiKey AGE identity is already set up"
    echo "and its identity file path is known (e.g., via AGE_PRIMARY_YUBIKEY_IDENTITY_FILE)."
    echo "The second YubiKey will receive a COMPLETELY NEW AGE identity; it does not 'clone' the primary."
    echo ""
    echo "Environment variables from .mise.toml or .env will be used for defaults, e.g.:"
    echo "  AGE_PRIMARY_YUBIKEY_IDENTITY_FILE, BACKUP_YUBIKEY_SERIAL,"
    echo "  ADDITIONAL_AGE_PIV_SLOT, ADDITIONAL_AGE_PIN_POLICY, ADDITIONAL_AGE_TOUCH_POLICY,"
    echo "  ADDITIONAL_AGE_RECIPIENTS_FILE, SOPS_CONFIG_FILE_PATH."
    echo ""
    echo "Make sure 'age-keygen', 'ykman', 'age-plugin-yubikey', 'sops', 'awk', 'grep', 'sed' are installed."
    exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

# --- Script Specific Cleanup Function ---
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 17-setup-age-yubikey-redundancy.sh with status $exit_status_for_cleanup"
}

log_info "Starting AGE YubiKey Redundancy Setup Assistant..."
log_warn "This script will guide you to provision a NEW AGE identity on a second YubiKey."
log_warn "The private key on the second YubiKey will be DIFFERENT from the primary."

# --- Prerequisite Checks ---
check_command "age-keygen"; check_command "ykman"; check_command "age-plugin-yubikey"; check_command "sops"
check_command "awk"; check_command "grep"; check_command "sed"

# --- Configuration from Environment (Defaults from mise.toml) ---
PRIMARY_YK_AGE_IDENTITY_FILE_PATH_CONFIG="${AGE_PRIMARY_YUBIKEY_IDENTITY_FILE:-}"
BACKUP_YK_SERIAL_CONFIG="${BACKUP_YUBIKEY_SERIAL:-}" # Use BACKUP_YUBIKEY_SERIAL as a sensible default for the second YK

ADDITIONAL_AGE_PIV_SLOT_CONFIG="${ADDITIONAL_AGE_PIV_SLOT:-9d}" # Suggest a different default slot
ADDITIONAL_AGE_PIN_POLICY_CONFIG="${ADDITIONAL_AGE_PIN_POLICY:-once}"
ADDITIONAL_AGE_TOUCH_POLICY_CONFIG="${ADDITIONAL_AGE_TOUCH_POLICY:-cached}"

RECIPIENTS_LIST_FILE_CONFIG="${ADDITIONAL_AGE_RECIPIENTS_FILE:-age-recipients.txt}"
SOPS_YAML_FILE_CONFIG="${SOPS_CONFIG_FILE_PATH:-.sops.yaml}"

# --- Step 1: Identify Primary YubiKey AGE Identity ---
log_info "Step 1: Identifying Primary YubiKey AGE Identity."
ensure_var_set "PRIMARY_YK_AGE_IDENTITY_FILE_PATH_CONFIG" "Enter path to your PRIMARY YubiKey AGE identity file"

PRIMARY_YK_AGE_IDENTITY_FILE_PATH_RESOLVED="${PRIMARY_YK_AGE_IDENTITY_FILE_PATH_CONFIG/#\~/$HOME}"
if [ ! -f "$PRIMARY_YK_AGE_IDENTITY_FILE_PATH_RESOLVED" ]; then
    log_error "Primary YubiKey AGE identity file not found: $PRIMARY_YK_AGE_IDENTITY_FILE_PATH_RESOLVED"
    exit 1
fi

PRIMARY_YK_AGE_PUBLIC_KEY=$(age-keygen -y "$PRIMARY_YK_AGE_IDENTITY_FILE_PATH_RESOLVED" 2>/dev/null)
if [ -z "$PRIMARY_YK_AGE_PUBLIC_KEY" ]; then
    # If age-keygen -y fails, it might be a plugin identity file. Try to parse it.
    # This is a heuristic, assuming the public key is commented out in the identity file.
    PRIMARY_YK_AGE_PUBLIC_KEY=$(grep '^# public key:' "$PRIMARY_YK_AGE_IDENTITY_FILE_PATH_RESOLVED" | head -n 1 | cut -d: -f2- | xargs)
fi
if [ -z "$PRIMARY_YK_AGE_PUBLIC_KEY" ]; then
    log_error "Could not extract public key from primary identity file: $PRIMARY_YK_AGE_IDENTITY_FILE_PATH_RESOLVED"
    log_error "Ensure it's a valid AGE identity file (either software key or age-plugin-yubikey format)."
    exit 1
fi
log_success "Primary YubiKey AGE Public Key: $PRIMARY_YK_AGE_PUBLIC_KEY"

# --- Step 2: Provision Second YubiKey AGE Identity ---
log_info "Step 2: Provisioning NEW AGE Identity on Second YubiKey."
ensure_var_set "BACKUP_YK_SERIAL_CONFIG" "Enter serial number of the SECOND YubiKey for the new AGE identity"

BACKUP_YK_LABEL="yubikey-age-backup-$(date +%Y%m%d)" # Default label for the new identity
get_input "Enter a label for the new AGE identity on the second YubiKey (default: ${BACKUP_YK_LABEL}): " BACKUP_YK_LABEL_INPUT
BACKUP_YK_LABEL="${BACKUP_YK_LABEL_INPUT:-$BACKUP_YK_LABEL}"

# Construct path for the new identity file using the template logic from script 08
DEFAULT_PATH_TEMPLATE="${ADDITIONAL_AGE_IDENTITY_FILE_PATH_TEMPLATE:-~/.config/sops/age/yubikey_{{label}}_{{serial}}.txt}"
TEMP_PATH="${DEFAULT_PATH_TEMPLATE//\{\{label\}\}/$BACKUP_YK_LABEL}"
BACKUP_YK_AGE_IDENTITY_FILE_PATH="${TEMP_PATH//\{\{serial\}\}/$BACKUP_YK_SERIAL_CONFIG}"
BACKUP_YK_AGE_IDENTITY_FILE_PATH="${BACKUP_YK_AGE_IDENTITY_FILE_PATH/#\~/$HOME}"

log_info "The new AGE identity for the second YubiKey (S/N: ${BACKUP_YK_SERIAL_CONFIG}) will be saved to: ${BACKUP_YK_AGE_IDENTITY_FILE_PATH}"
if ! confirm "Proceed with provisioning this new identity on the second YubiKey?"; then
    log_info "Aborted provisioning of second YubiKey AGE identity."
    exit 0
fi

# Call script 08 to provision the additional identity
log_info "Calling script '08-provision-additional-age-identity.sh'..."
if ! "${BASE_DIR}/scripts/team/08-provision-additional-age-identity.sh" \
    --label "$BACKUP_YK_LABEL" \
    --serial "$BACKUP_YK_SERIAL_CONFIG" \
    --slot "$ADDITIONAL_AGE_PIV_SLOT_CONFIG" \
    --output "$BACKUP_YK_AGE_IDENTITY_FILE_PATH" \
    --pin-policy "$ADDITIONAL_AGE_PIN_POLICY_CONFIG" \
    --touch-policy "$ADDITIONAL_AGE_TOUCH_POLICY_CONFIG" \
    --no-update-recipients; then # We handle recipient file update in this script
    log_error "Failed to provision new AGE identity on the second YubiKey. See errors above."
    exit 1
fi

if [ ! -f "$BACKUP_YK_AGE_IDENTITY_FILE_PATH" ]; then
    log_error "New AGE identity file was not created at: $BACKUP_YK_AGE_IDENTITY_FILE_PATH"
    exit 1
fi

BACKUP_YK_AGE_PUBLIC_KEY=$(grep '^# public key:' "$BACKUP_YK_AGE_IDENTITY_FILE_PATH" | head -n 1 | cut -d: -f2- | xargs)
if [ -z "$BACKUP_YK_AGE_PUBLIC_KEY" ]; then
    log_error "Could not extract public key from new backup identity file: $BACKUP_YK_AGE_IDENTITY_FILE_PATH"
    exit 1
fi
log_success "New Backup YubiKey AGE Public Key: $BACKUP_YK_AGE_PUBLIC_KEY"

# --- Step 3: Update AGE Recipients List File ---
log_info "Step 3: Updating AGE Recipients List File."
RECIPIENTS_FILE_ACTUAL_PATH="${BASE_DIR}/${RECIPIENTS_LIST_FILE_CONFIG}"
if [[ "$RECIPIENTS_LIST_FILE_CONFIG" == /* ]]; then RECIPIENTS_FILE_ACTUAL_PATH="$RECIPIENTS_LIST_FILE_CONFIG"; fi

log_info "Ensuring both public keys are in: ${RECIPIENTS_FILE_ACTUAL_PATH}"
touch "$RECIPIENTS_FILE_ACTUAL_PATH" # Ensure file exists

KEYS_TO_ADD=("$PRIMARY_YK_AGE_PUBLIC_KEY" "$BACKUP_YK_AGE_PUBLIC_KEY")
LABELS_FOR_KEYS=("primary-yubikey-age" "$BACKUP_YK_LABEL") # Corresponding labels

for i in "${!KEYS_TO_ADD[@]}"; do
    key="${KEYS_TO_ADD[$i]}"
    label="${LABELS_FOR_KEYS[$i]}"
    if ! grep -q -F "$key" "$RECIPIENTS_FILE_ACTUAL_PATH"; then
        log_info "  Adding '$label: $key' to ${RECIPIENTS_FILE_ACTUAL_PATH}"
        echo "$label: $key" >> "$RECIPIENTS_FILE_ACTUAL_PATH"
    else
        log_info "  Key for '$label' ($key) already in ${RECIPIENTS_FILE_ACTUAL_PATH}."
    fi
done
log_success "AGE recipients list file updated."

# --- Step 4: Update .sops.yaml ---
log_info "Step 4: Updating .sops.yaml."
log_info "Calling script '09-update-sops-recipients.sh' to update .sops.yaml using '${RECIPIENTS_FILE_ACTUAL_PATH}'..."

SOPS_YAML_FILE_ACTUAL_PATH="${BASE_DIR}/${SOPS_YAML_FILE_CONFIG}"
if [[ "$SOPS_YAML_FILE_CONFIG" == /* ]]; then SOPS_YAML_FILE_ACTUAL_PATH="$SOPS_YAML_FILE_CONFIG"; fi

if ! "${BASE_DIR}/scripts/team/09-update-sops-recipients.sh" \
    --input-file "$RECIPIENTS_FILE_ACTUAL_PATH" \
    --sops-file "$SOPS_YAML_FILE_ACTUAL_PATH"; then
    log_error "Failed to update .sops.yaml. See errors above."
    exit 1
fi
log_success ".sops.yaml updated to include both AGE YubiKey recipients."

# --- Step 5: Guide Rekeying ---
log_info "Step 5: Rekeying Existing SOPS Files."
log_warn "Your .sops.yaml has been updated to encrypt secrets to BOTH YubiKey AGE identities."
log_warn "You MUST now rekey your existing SOPS-encrypted files for this change to take effect."
log_info "To rekey all secrets (as defined by SOPS_REKEY_DEFAULT_PATHS in .mise.toml, typically 'secrets/**/*.yaml'):"
log_info "  Run: mise run rekey-sops-secrets"
log_info "Alternatively, to rekey specific files or directories:"
log_info "  Run: mise run rekey-sops-secrets path/to/your/secret1.yaml path/to/other/secrets_dir/"
log_warn "During rekeying, SOPS will decrypt files using any of the *previously* configured keys"
log_warn "and then re-encrypt them using *all* keys currently in your .sops.yaml (i.e., both YubiKey AGE keys)."
log_warn "Ensure the YubiKey(s) needed for initial decryption are connected, and their identity files are accessible via SOPS_AGE_KEY_FILE."

log_info "---------------------------------------------------------------------"
log_success "AGE YubiKey Redundancy Setup Assistant Complete."
log_info "---------------------------------------------------------------------"
log_info "Summary of actions:"
log_info "  - Primary YubiKey AGE Public Key: $PRIMARY_YK_AGE_PUBLIC_KEY"
log_info "  - New Backup YubiKey AGE Public Key: $BACKUP_YK_AGE_PUBLIC_KEY (Identity file: $BACKUP_YK_AGE_IDENTITY_FILE_PATH)"
log_info "  - Recipients list '${RECIPIENTS_FILE_ACTUAL_PATH}' updated."
log_info "  - SOPS config '${SOPS_YAML_FILE_ACTUAL_PATH}' updated."
log_warn "CRITICAL: Proceed to rekey your SOPS files as instructed above."

exit 0
