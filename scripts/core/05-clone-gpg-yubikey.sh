#!/usr/bin/env bash
# scripts/core/05-clone-gpg-yubikey.sh
# Provisions a backup YubiKey with the same GPG subkeys as the primary.
# This script "clones" the GPG subkey functionality to a second YubiKey,
# allowing it to be used as a backup or replacement for the primary.
# This script is for GPG subkeys ONLY and does not clone YubiKey PIV-backed AGE keys.

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
    echo "Usage: $(basename "$0") --serial <BACKUP_YUBIKEY_SERIAL>"
    echo ""
    echo "This script provisions a backup YubiKey with the *same* GPG subkeys as your primary GPG identity."
    echo "This allows the backup YubiKey to perform the same GPG operations as the primary."
    echo ""
    echo "IMPORTANT: This script is for GPG subkeys ONLY."
    echo "It does NOT clone YubiKey PIV-backed AGE keys. Private keys generated on a YubiKey's PIV"
    echo "applet (e.g., by '04-provision-age-yubikey.sh') are NON-EXPORTABLE by design."
    echo "To achieve redundancy for YubiKey PIV-backed AGE keys, you must provision a new, distinct"
    echo "AGE identity on the backup YubiKey and update your SOPS configuration to include both"
    echo "YubiKeys' AGE public keys as recipients."
    echo ""
    echo "Arguments:"
    echo "  --serial <BACKUP_YUBIKEY_SERIAL>   The serial number of the YubiKey to be set up as a backup."
    echo ""
    echo "CRITICAL PREREQUISITE for GPG Subkey Cloning:"
    echo "  - Local GPG subkey private material (stubs) MUST be available. This means when the primary"
    echo "    YubiKey was provisioned (using 02-provision-gpg-yubikey.sh), GPG's prompt"
    echo "    'Save changes? (y/N)' must have been answered 'N' (No) to preserve these stubs."
    echo "  - GPG master key and subkeys must have been generated (e.g., by 01-generate-gpg-master-key.sh)."
    echo "  - The GPG master key ID must be stored in '${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}'."
    echo ""
    echo "The script will:"
    echo "  1. Connect to the specified backup YubiKey."
    echo "  2. Optionally reset its OpenPGP applet (with confirmation)."
    echo "  3. Guide you to set new User and Admin PINs specifically for this backup YubiKey."
    echo "  4. Move the same GPG subkeys (Sign, Encrypt, Authenticate) to the backup YubiKey."
    echo "  5. Set touch policies for the GPG keys on the backup YubiKey."
    echo ""
    echo "IMPORTANT POST-OPERATION NOTE:"
    echo "  When switching between YubiKeys that share the same GPG identity, you MUST run:"
    echo "    gpg-connect-agent \"scd serialno\" \"learn --force\" /bye"
    echo "  This command tells gpg-agent to recognize the newly inserted card."
    echo ""
    echo "Environment variables like GPG_USER_NAME (for cardholder name), GPG_TOUCH_POLICY_*"
    echo "and OPENPGP_MIN_USER_PIN_LENGTH, OPENPGP_MIN_ADMIN_PIN_LENGTH"
    echo "can be set to customize behavior (see .mise.toml)."
    exit 1
}

# Default PINs for YubiKey OpenPGP applet (used when changing PINs on the backup YK)
DEFAULT_USER_PIN="123456"
DEFAULT_ADMIN_PIN="12345678"

# Configuration for GPG touch policies on the backup YubiKey
GPG_TOUCH_POLICY_SIG="${GPG_TOUCH_POLICY_SIG:-cached}"
GPG_TOUCH_POLICY_ENC="${GPG_TOUCH_POLICY_ENC:-cached}"
GPG_TOUCH_POLICY_AUT="${GPG_TOUCH_POLICY_AUT:-cached}"
# Configuration for minimum PIN lengths (for user prompts for the backup YK)
OPENPGP_MIN_USER_PIN_LENGTH_CONFIG="${OPENPGP_MIN_USER_PIN_LENGTH:-6}"
OPENPGP_MIN_ADMIN_PIN_LENGTH_CONFIG="${OPENPGP_MIN_ADMIN_PIN_LENGTH:-8}"

# Script-specific variables
YK_BACKUP_SERIAL=""
MASTER_KEY_ID=""

# Variables for holding new PINs and passphrases temporarily for the backup YK
NEW_BACKUP_USER_PIN_VALUE=""
CONFIRM_NEW_BACKUP_USER_PIN_VALUE=""
NEW_BACKUP_ADMIN_PIN_VALUE=""
CONFIRM_NEW_BACKUP_ADMIN_PIN_VALUE=""
BACKUP_ADMIN_PIN_FOR_RESET="" # For resetting the backup YK's applet
GPG_MASTER_PASSPHRASE=""      # For authorizing subkey transfer from master

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 05-clone-gpg-yubikey.sh with status $exit_status_for_cleanup"
    # Unset sensitive variables from script memory
    unset NEW_BACKUP_USER_PIN_VALUE CONFIRM_NEW_BACKUP_USER_PIN_VALUE NEW_BACKUP_ADMIN_PIN_VALUE
    unset CONFIRM_NEW_BACKUP_ADMIN_PIN_VALUE BACKUP_ADMIN_PIN_FOR_RESET GPG_MASTER_PASSPHRASE
}

# --- Parse Command-Line Arguments ---
if [[ "$#" -eq 0 ]]; then usage; fi
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --serial) YK_BACKUP_SERIAL="$2"; shift ;; # Serial number of the YubiKey to be used as a backup
        *) log_error "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

if [ -z "$YK_BACKUP_SERIAL" ]; then log_error "Backup YubiKey serial number must be provided via --serial."; usage; fi

log_info "Starting GPG Subkey Cloning to Backup YubiKey (S/N: ${YK_BACKUP_SERIAL})"
log_warn "This script is for GPG subkeys ONLY and does not affect YubiKey PIV-backed AGE keys."

# --- Resolve Configuration Paths and Variables ---
GPG_MASTER_KEY_ID_FILE="${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}"
TEMP_GNUPGHOME_DIR_NAME="${TEMP_GNUPGHOME_DIR_NAME:-.gnupghome_temp_ykm}"
MASTER_KEY_ID_FILE_PATH="${BASE_DIR}/${GPG_MASTER_KEY_ID_FILE}"
TEMP_GNUPGHOME_PATH="${BASE_DIR}/${TEMP_GNUPGHOME_DIR_NAME}"
GPG_CARD_HOLDER_NAME="${GPG_USER_NAME:-}" # Optional cardholder name for the backup YK

# --- Prerequisite Checks ---
check_command "gpg"; check_command "ykman"; check_command "gpg-connect-agent"

# Validate configured touch policies for the backup YK
VALID_TOUCH_POLICIES=("on" "off" "fixed" "cached")
validate_touch_policy() {
    local policy_name="$1"; local policy_value="$2"
    if ! printf '%s\n' "${VALID_TOUCH_POLICIES[@]}" | grep -q -w "$policy_value"; then
        log_error "Invalid touch policy for ${policy_name}: '${policy_value}'. Must be one of: ${VALID_TOUCH_POLICIES[*]}."
        exit 1
    fi
}
validate_touch_policy "GPG Signature Key (Backup YK)" "${GPG_TOUCH_POLICY_SIG}"
validate_touch_policy "GPG Encryption Key (Backup YK)" "${GPG_TOUCH_POLICY_ENC}"
validate_touch_policy "GPG Authentication Key (Backup YK)" "${GPG_TOUCH_POLICY_AUT}"

# --- Step 1: Verify GPG Master Key ID and Local Subkey Stubs ---
log_info "Step 1: Verifying GPG Master Key ID and Local Subkey Stubs."
if [ ! -f "${MASTER_KEY_ID_FILE_PATH}" ]; then log_error "Master Key ID file not found: ${MASTER_KEY_ID_FILE_PATH}. Run 01-generate-gpg-master-key.sh first."; exit 1; fi
MASTER_KEY_ID=$(cat "${MASTER_KEY_ID_FILE_PATH}")
if [ -z "${MASTER_KEY_ID}" ]; then log_error "Failed to read Master Key ID from ${MASTER_KEY_ID_FILE_PATH} or file is empty."; exit 1; fi
log_info "Using GPG Master Key ID: ${MASTER_KEY_ID}"

# Set GNUPGHOME to the temporary directory if it exists, otherwise use default.
# This is where the GPG master key (and subkey stubs if primary YK was provisioned from here) should reside.
if [ -d "${TEMP_GNUPGHOME_PATH}" ]; then
    log_info "Using temporary GPG home for subkey material: ${TEMP_GNUPGHOME_PATH}"
    export GNUPGHOME="${TEMP_GNUPGHOME_PATH}"
else
    log_info "Temporary GPG home not found. Using default GPG home: ${HOME}/.gnupg"
    log_warn "Ensure your default GPG home contains the private subkey stubs for key ID ${MASTER_KEY_ID} for cloning to work."
    unset GNUPGHOME
fi

# Verify that local private key material (stubs) for the subkeys exists.
# This is crucial for the `keytocard` operation to work for a second YubiKey.
log_info "Verifying local GPG subkey stubs for key ID ${MASTER_KEY_ID} in GNUPGHOME=${GNUPGHOME:-$HOME/.gnupg}..."
GPG_K_OUTPUT=$(gpg --no-tty -K "${MASTER_KEY_ID}" 2>&1); GPG_K_EC=$?
if [ $GPG_K_EC -ne 0 ] || ! echo "${GPG_K_OUTPUT}" | grep -Eq '^(sec|ssb)'; then # Check for actual secret key lines
    log_error "No secret keys or subkey stubs found locally for GPG Key ID ${MASTER_KEY_ID}."
    log_error "GPG Output:\n${GPG_K_OUTPUT}"
    log_error "Cannot clone subkeys to backup YubiKey without local private key material (stubs)."
    log_error "This usually means that when the primary YubiKey was provisioned, GPG's 'Save changes?' prompt was answered 'Y' instead of 'N'."
    exit 1
fi
log_success "Local GPG subkey stubs appear to be available."

# --- Step 2: Connect to Backup YubiKey ---
log_info "Step 2: Connecting to Backup YubiKey (S/N: ${YK_BACKUP_SERIAL})."
YKMAN_LIST_OUTPUT=$(ykman list --serials 2>&1); YKMAN_LIST_EC=$?
if [ $YKMAN_LIST_EC -ne 0 ]; then log_error "Failed to list YubiKeys. EC:$YKMAN_LIST_EC. Output:\n${YKMAN_LIST_OUTPUT}"; exit 1; fi
if ! echo "${YKMAN_LIST_OUTPUT}" | grep -q -w "${YK_BACKUP_SERIAL}"; then log_error "Backup YubiKey S/N ${YK_BACKUP_SERIAL} not found. Available:\n${YKMAN_LIST_OUTPUT}"; exit 1; fi

# Instruct gpg-agent to learn about the backup YubiKey.
log_info "Targeting Backup YubiKey S/N ${YK_BACKUP_SERIAL} for GPG operations..."
GPG_CONNECT_OUTPUT=$(gpg-connect-agent "scd serialno ${YK_BACKUP_SERIAL}" "learn --force" /bye 2>&1); GPG_CONNECT_EC=$?
if [ $GPG_CONNECT_EC -ne 0 ]; then
    log_warn "Failed to set Backup YK S/N ${YK_BACKUP_SERIAL} with gpg-connect-agent. EC:$GPG_CONNECT_EC. Output:\n${GPG_CONNECT_OUTPUT}"
    if ! confirm "Continue anyway (GPG might use the wrong card if multiple are connected)?"; then exit 1; fi
fi
sleep 1 # Give agent time to process

# --- Step 3: Check Backup YubiKey's OpenPGP Applet Status & Optionally Reset ---
log_info "Step 3: Checking Backup YubiKey's OpenPGP Applet Status."
GPG_CARD_STATUS_OUTPUT=$(gpg --no-tty --card-status 2>&1); GPG_CARD_STATUS_EC=$?
if [ $GPG_CARD_STATUS_EC -eq 0 ]; then
    if echo "${GPG_CARD_STATUS_OUTPUT}" | grep -q "Signature key .....: [^N]"; then # Check if signature key slot has data
        log_warn "Backup YubiKey's OpenPGP applet (S/N ${YK_BACKUP_SERIAL}) appears to have keys already."
        if confirm "Do you want to RESET the OpenPGP applet on this Backup YubiKey? This will WIPE ALL OpenPGP data on it."; then
            get_secure_input "Enter CURRENT Admin PIN for Backup YK S/N ${YK_BACKUP_SERIAL} to authorize reset (if not default '${DEFAULT_ADMIN_PIN}', enter current): " BACKUP_ADMIN_PIN_FOR_RESET
            YKMAN_RESET_OUTPUT=$(ykman -s "${YK_BACKUP_SERIAL}" openpgp reset --admin-pin "${BACKUP_ADMIN_PIN_FOR_RESET}" --force 2>&1); YKMAN_RESET_EC=$?
            unset BACKUP_ADMIN_PIN_FOR_RESET
            if [ $YKMAN_RESET_EC -eq 0 ]; then
                log_success "Backup YK OpenPGP applet reset successfully."
                # Reload gpg-agent to recognize the reset card.
                gpg-connect-agent "scd REOPEN" "scd KILLSCD" /bye >/dev/null 2>&1 || log_warn "gpg-connect-agent REOPEN/KILLSCD failed."
                sleep 2
                gpg-connect-agent "scd serialno ${YK_BACKUP_SERIAL}" "learn --force" /bye >/dev/null 2>&1 || log_warn "gpg-connect-agent learn after reset failed."
                sleep 1
            else log_error "Failed to reset Backup YK OpenPGP applet. EC:$YKMAN_RESET_EC. Output:\n${YKMAN_RESET_OUTPUT}"; exit 1; fi
        else log_info "Skipping OpenPGP applet reset on Backup YubiKey."; fi
    else log_info "Backup YubiKey's OpenPGP applet appears empty or ready for provisioning."; fi
else log_error "Failed to get Backup YK card status. EC:$GPG_CARD_STATUS_EC. Output:\n${GPG_CARD_STATUS_OUTPUT}"; exit 1; fi

# --- Step 4: Set OpenPGP PINs for the Backup YubiKey ---
log_info "Step 4: Setting OpenPGP PINs for the Backup YubiKey."
log_info "You will set a User PIN and an Admin PIN specifically for this Backup YubiKey."
log_warn "Choose strong, unique PINs. Defaults: User='${DEFAULT_USER_PIN}', Admin='${DEFAULT_ADMIN_PIN}'."
# Get and confirm new User PIN for the backup YK
while true; do
    get_secure_input "Enter NEW User PIN for Backup YK (min ${OPENPGP_MIN_USER_PIN_LENGTH_CONFIG} chars, different from default '${DEFAULT_USER_PIN}'): " NEW_BACKUP_USER_PIN_VALUE
    if [ "${#NEW_BACKUP_USER_PIN_VALUE}" -lt "${OPENPGP_MIN_USER_PIN_LENGTH_CONFIG}" ]; then log_warn "User PIN too short (min ${OPENPGP_MIN_USER_PIN_LENGTH_CONFIG} chars).";
    elif [ "$NEW_BACKUP_USER_PIN_VALUE" == "$DEFAULT_USER_PIN" ]; then log_warn "User PIN for Backup YK should not be the default. Choose a unique PIN.";
    else break; fi
done
while true; do get_secure_input "Confirm NEW User PIN for Backup YK: " CONFIRM_NEW_BACKUP_USER_PIN_VALUE; if [ "$NEW_BACKUP_USER_PIN_VALUE" == "$CONFIRM_NEW_BACKUP_USER_PIN_VALUE" ]; then break; else log_warn "User PINs do not match."; fi; done
unset CONFIRM_NEW_BACKUP_USER_PIN_VALUE

# Get and confirm new Admin PIN for the backup YK
while true; do
    get_secure_input "Enter NEW Admin PIN for Backup YK (min ${OPENPGP_MIN_ADMIN_PIN_LENGTH_CONFIG} chars, different from default '${DEFAULT_ADMIN_PIN}'): " NEW_BACKUP_ADMIN_PIN_VALUE
    if [ "${#NEW_BACKUP_ADMIN_PIN_VALUE}" -lt "${OPENPGP_MIN_ADMIN_PIN_LENGTH_CONFIG}" ]; then log_warn "Admin PIN too short (min ${OPENPGP_MIN_ADMIN_PIN_LENGTH_CONFIG} chars).";
    elif [ "$NEW_BACKUP_ADMIN_PIN_VALUE" == "$DEFAULT_ADMIN_PIN" ]; then log_warn "Admin PIN for Backup YK should not be the default. Choose a unique PIN.";
    else break; fi
done
while true; do get_secure_input "Confirm NEW Admin PIN for Backup YK: " CONFIRM_NEW_BACKUP_ADMIN_PIN_VALUE; if [ "$NEW_BACKUP_ADMIN_PIN_VALUE" == "$CONFIRM_NEW_BACKUP_ADMIN_PIN_VALUE" ]; then break; else log_warn "Admin PINs do not match."; fi; done
unset CONFIRM_NEW_BACKUP_ADMIN_PIN_VALUE

log_info "Attempting to change PINs on Backup YK via GPG. If current PINs are not default, GPG will prompt for them."
# Prepare GPG commands for changing PINs and optionally setting cardholder name on the backup YK.
GPG_CARD_SETUP_COMMANDS=$(cat <<EOF
admin
passwd
1
${DEFAULT_USER_PIN}
${NEW_BACKUP_USER_PIN_VALUE}
${NEW_BACKUP_USER_PIN_VALUE}
3
${DEFAULT_ADMIN_PIN}
${NEW_BACKUP_ADMIN_PIN_VALUE}
${NEW_BACKUP_ADMIN_PIN_VALUE}
q
EOF
)
if [ -n "${GPG_CARD_HOLDER_NAME}" ]; then
    log_info "Setting card holder name on Backup YK to: ${GPG_CARD_HOLDER_NAME}"
    GPG_CARD_SETUP_COMMANDS+=$(cat <<EOF
name
${GPG_CARD_HOLDER_NAME}

EOF
)
fi
GPG_CARD_SETUP_COMMANDS+="save"
# Execute GPG card edit commands for the backup YK.
GPG_CARD_EDIT_OUTPUT=$(echo -e "${GPG_CARD_SETUP_COMMANDS}" | gpg --no-tty --status-fd 1 --pinentry-mode loopback --command-fd 0 --card-edit 2>&1); GPG_CARD_EDIT_EC=$?
if [ $GPG_CARD_EDIT_EC -eq 0 ]; then log_success "PINs/name setup on Backup YK attempted.";
else log_error "GPG card edit on Backup YK failed. EC:$GPG_CARD_EDIT_EC. Output:\n${GPG_CARD_EDIT_OUTPUT}"; fi
log_warn "Ensure NEW Admin PIN ('${NEW_BACKUP_ADMIN_PIN_VALUE}') for Backup YK was set correctly."

# --- Step 5: Move GPG Subkeys to Backup YubiKey ---
log_info "Step 5: Moving GPG Subkeys to Backup YubiKey."
ensure_var_set "GPG_MASTER_PASSPHRASE" "Enter GPG Master Key passphrase for Key ID '${MASTER_KEY_ID}' to authorize subkey transfer" --secure
# Prepare GPG commands for moving the same subkeys to the backup YK.
# The 'N' at the end of 'quit' is crucial to preserve local stubs.
KEYTOCARD_COMMANDS=$(cat <<EOF
${GPG_MASTER_PASSPHRASE}
key 1
keytocard
1
key 1
key 2
keytocard
2
key 2
key 3
keytocard
3
key 3
quit
N
EOF
)
log_info "Moving subkeys to Backup YK... You will be prompted for its NEW User PIN ('${NEW_BACKUP_USER_PIN_VALUE}')."
log_warn "This script automates answering 'N' (No) to GPG's 'Save changes?' prompt. This is CRITICAL to keep local private key stubs, enabling this cloning process."
# Execute GPG keytocard commands for the backup YK.
GPG_KEYTOCARD_OUTPUT=$(echo -e "${KEYTOCARD_COMMANDS}" | gpg --no-tty --status-fd 1 --pinentry-mode loopback --command-fd 0 --expert --edit-key "${MASTER_KEY_ID}" 2>&1); GPG_KEYTOCARD_EC=$?
unset GPG_MASTER_PASSPHRASE # Unset passphrase from script memory
if [ $GPG_KEYTOCARD_EC -ne 0 ]; then log_error "GPG keytocard for Backup YK failed. EC:$GPG_KEYTOCARD_EC. Output:\n${GPG_KEYTOCARD_OUTPUT}"; fi
log_success "Subkey transfer to Backup YK attempted."

# --- Step 6: Verify Subkeys on Backup YubiKey ---
log_info "Step 6: Verifying Subkeys on Backup YubiKey."
log_info "Ensuring gpg-agent is focused on Backup YK (S/N ${YK_BACKUP_SERIAL}) for verification..."
# Ensure gpg-agent knows about the backup YK before checking key status.
gpg-connect-agent "scd serialno ${YK_BACKUP_SERIAL}" "learn --force" /bye >/dev/null 2>&1; sleep 1
GPG_K_BACKUP_OUTPUT=$(gpg --no-tty -K "${MASTER_KEY_ID}" 2>&1)
GPG_CARD_STATUS_BACKUP_OUTPUT=$(gpg --no-tty --card-status 2>&1)
log_debug "gpg -K (Backup YK):\n${GPG_K_BACKUP_OUTPUT}"
log_debug "gpg --card-status (Backup YK):\n${GPG_CARD_STATUS_BACKUP_OUTPUT}"
# Check card status for presence of keys.
if echo "${GPG_CARD_STATUS_BACKUP_OUTPUT}" | grep -q "Signature key .....: [^N]"; then
    log_success "Subkeys appear provisioned on Backup YK according to 'gpg --card-status'."
else log_warn "Could not verify subkeys on Backup YK via 'gpg --card-status'. Check manually."; fi
# Check local GPG keyring to see if subkeys are marked as stubs pointing to a card.
if ! echo "${GPG_K_BACKUP_OUTPUT}" | grep -E 'ssb>'; then
     log_warn "Local 'gpg -K' does not show subkeys as stubs pointing to a card. This might be okay if 'gpg --card-status' is positive, but ensure gpg-agent has correctly learned the card."
fi

# --- Step 7: Set Touch Policies for GPG Keys on Backup YubiKey ---
log_info "Step 7: Setting Touch Policies for GPG Keys on Backup YubiKey."
log_info "Touch policies for Backup YK: SIG='${GPG_TOUCH_POLICY_SIG}', ENC='${GPG_TOUCH_POLICY_ENC}', AUT='${GPG_TOUCH_POLICY_AUT}'."
log_warn "You will be prompted for the Backup YK's NEW Admin PIN ('${NEW_BACKUP_ADMIN_PIN_VALUE}') by ykman for each policy change."
TOUCH_POLICY_ALL_SUCCESS=true

# Set touch policy for Signature key on backup YK
YKMAN_TOUCH_SIG_OUTPUT=$(ykman -s "${YK_BACKUP_SERIAL}" openpgp keys set-touch sig "${GPG_TOUCH_POLICY_SIG}" --admin-pin "${NEW_BACKUP_ADMIN_PIN_VALUE}" --force 2>&1); YKMAN_TOUCH_SIG_EC=$?
if [ $YKMAN_TOUCH_SIG_EC -ne 0 ]; then log_error "Failed to set SIG touch on Backup YK. EC:$YKMAN_TOUCH_SIG_EC. Output:\n${YKMAN_TOUCH_SIG_OUTPUT}"; TOUCH_POLICY_ALL_SUCCESS=false; else log_info "SIG touch policy set on Backup YK."; fi

# Set touch policy for Encryption key on backup YK
YKMAN_TOUCH_ENC_OUTPUT=$(ykman -s "${YK_BACKUP_SERIAL}" openpgp keys set-touch enc "${GPG_TOUCH_POLICY_ENC}" --admin-pin "${NEW_BACKUP_ADMIN_PIN_VALUE}" --force 2>&1); YKMAN_TOUCH_ENC_EC=$?
if [ $YKMAN_TOUCH_ENC_EC -ne 0 ]; then log_error "Failed to set ENC touch on Backup YK. EC:$YKMAN_TOUCH_ENC_EC. Output:\n${YKMAN_TOUCH_ENC_OUTPUT}"; TOUCH_POLICY_ALL_SUCCESS=false; else log_info "ENC touch policy set on Backup YK."; fi

# Set touch policy for Authentication key on backup YK
YKMAN_TOUCH_AUT_OUTPUT=$(ykman -s "${YK_BACKUP_SERIAL}" openpgp keys set-touch aut "${GPG_TOUCH_POLICY_AUT}" --admin-pin "${NEW_BACKUP_ADMIN_PIN_VALUE}" --force 2>&1); YKMAN_TOUCH_AUT_EC=$?
if [ $YKMAN_TOUCH_AUT_EC -ne 0 ]; then log_error "Failed to set AUT touch on Backup YK. EC:$YKMAN_TOUCH_AUT_EC. Output:\n${YKMAN_TOUCH_AUT_OUTPUT}"; TOUCH_POLICY_ALL_SUCCESS=false; else log_info "AUT touch policy set on Backup YK."; fi

unset NEW_BACKUP_ADMIN_PIN_VALUE; unset NEW_BACKUP_USER_PIN_VALUE # Unset PINs from script memory

if $TOUCH_POLICY_ALL_SUCCESS; then log_success "Touch policies set successfully on Backup YK.";
else log_error "One or more touch policy settings failed on Backup YK. Check ykman output and Admin PIN."; fi

log_info "---------------------------------------------------------------------"
log_success "GPG Subkey Cloning to Backup YubiKey (S/N ${YK_BACKUP_SERIAL}) Complete."
log_info "---------------------------------------------------------------------"
log_info "Your Backup YubiKey (S/N: ${YK_BACKUP_SERIAL}) should now have the same GPG subkeys as your primary."
log_warn "CRITICAL REMINDER: When switching between YubiKeys that share the same GPG identity (e.g., primary and this backup):"
log_warn "  You MUST run the following command AFTER inserting the YubiKey you intend to use:"
log_warn "    gpg-connect-agent \"scd serialno\" \"learn --force\" /bye"
log_warn "  This command is essential for gpg-agent to correctly associate your GPG key stubs with the serial number of the currently inserted YubiKey."
log_warn "  Failure to do so will result in GPG errors like 'No secret key' or attempts to use the wrong card."
log_warn "Remember the User PIN and Admin PIN for your Backup YubiKey. They have been unset from script memory. Store them securely."

exit 0
