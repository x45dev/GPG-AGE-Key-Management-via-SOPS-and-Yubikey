#!/usr/bin/env bash
# scripts/core/04-provision-age-yubikey.sh
# Provisions a YubiKey PIV applet with an AGE identity.
# This script configures the YubiKey's PIV applet and generates a new
# hardware-backed AGE identity using age-plugin-yubikey.
# The private key for this AGE identity is generated ON THE YUBIKEY and is NON-EXPORTABLE.

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
    echo "Usage: $(basename "$0") --serial <YUBIKEY_SERIAL> --slot <PIV_SLOT> --output <IDENTITY_FILE_PATH> \\"
    echo "                      [--pin-policy <POLICY>] [--touch-policy <POLICY>]"
    echo ""
    echo "This script provisions a YubiKey's PIV applet with a new AGE identity."
    echo "The private key for this AGE identity is generated DIRECTLY ON THE YUBIKEY's PIV applet"
    echo "and is NON-EXPORTABLE. This enhances security by keeping the private key on hardware,"
    echo "but means the key cannot be backed up in the traditional sense. Backup for this key"
    echo "means safeguarding the YubiKey itself and/or encrypting secrets to multiple recipients"
    echo "(e.g., another YubiKey PIV AGE key, or a software-based AGE key that IS backable)."
    echo ""
    echo "It allows setting PIV credentials (PIN, PUK, Management Key) and configuring"
    echo "the AGE key's PIN and touch policies."
    echo ""
    echo "Arguments:"
    echo "  --serial <YUBIKEY_SERIAL>   Serial number of the YubiKey to provision."
    echo "  --slot <PIV_SLOT>           PIV slot for the AGE key (e.g., 9a, 9c, 9d, 9e, or 82-95)."
    echo "  --output <IDENTITY_FILE>    Path to save the generated AGE identity file (this is a POINTER to the YubiKey key, NOT the private key itself)."
    echo "  --pin-policy <POLICY>       Optional. PIV PIN policy for AGE key (once, always, never). Default: 'once'."
    echo "  --touch-policy <POLICY>     Optional. PIV touch policy for AGE key (cached, always, never). Default: 'cached'."
    echo ""
    echo "The script will:"
    echo "  1. Connect to the specified YubiKey."
    echo "  2. Check the PIV applet status and the target slot."
    echo "  3. Optionally reset the PIV applet or delete existing key in the slot (with confirmation)."
    echo "  4. Guide you to set new PIV PIN, PUK, and Management Key."
    echo "  5. Generate the AGE identity ON THE YUBIKEY using 'age-plugin-yubikey'."
    echo "  6. Save the AGE identity file (pointer) and display the AGE recipient public key."
    echo ""
    echo "Prerequisites:"
    echo "  - Required tools: ykman, age-plugin-yubikey, mkdir, chmod, grep, cut, xargs."
    echo "  - The YubiKey must be connected and its PIV application enabled."
    echo ""
    echo "Environment variables (e.g., from .mise.toml or .env) can provide defaults for arguments,"
    echo "including PIV_MIN_PIN_LENGTH and PIV_MIN_PUK_LENGTH for prompt validation."
    exit 1
}

# Default PIV credentials (used if the YubiKey is new or has been reset)
DEFAULT_PIV_PIN="123456"
DEFAULT_PIV_PUK="12345678"
DEFAULT_PIV_MANAGEMENT_KEY="010203040506070801020304050607080102030405060708" # Standard YubiKey default
# Configuration for minimum PIV PIN/PUK lengths (for user prompts)
PIV_MIN_PIN_LENGTH_CONFIG="${PIV_MIN_PIN_LENGTH:-6}"
PIV_MIN_PUK_LENGTH_CONFIG="${PIV_MIN_PUK_LENGTH:-8}"

# Script-specific variables for arguments and state
YK_SERIAL=""
PIV_SLOT=""
OUTPUT_IDENTITY_FILE=""
PIN_POLICY=""
TOUCH_POLICY=""

# Variables for holding new PIV credentials temporarily
NEW_PIV_PIN_VALUE=""
CONFIRM_NEW_PIV_PIN_VALUE=""
NEW_PIV_PUK_VALUE=""
CONFIRM_NEW_PIV_PUK_VALUE=""
NEW_PIV_MANAGEMENT_KEY_VALUE=""
CONFIRM_NEW_PIV_MANAGEMENT_KEY_VALUE=""
# Variables for holding current PIV credentials if needed for operations like reset/delete
PIV_MGMT_KEY_FOR_DELETE=""
PIV_PUK_FOR_RESET=""

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 04-provision-age-yubikey.sh with status $exit_status_for_cleanup"
    # Unset sensitive variables from script memory
    unset NEW_PIV_PIN_VALUE CONFIRM_NEW_PIV_PIN_VALUE NEW_PIV_PUK_VALUE CONFIRM_NEW_PIV_PUK_VALUE
    unset NEW_PIV_MANAGEMENT_KEY_VALUE CONFIRM_NEW_PIV_MANAGEMENT_KEY_VALUE
    unset PIV_MGMT_KEY_FOR_DELETE PIV_PUK_FOR_RESET
}

# --- Function to get and display YubiKey PIV status ---
get_and_display_yk_piv_status() {
    local yk_serial_for_status="$1"
    log_info "Fetching PIV status for YubiKey S/N ${yk_serial_for_status}..."
    local yk_piv_info_output
    local yk_piv_info_ec
    yk_piv_info_output=$(ykman -s "${yk_serial_for_status}" piv info 2>&1)
    yk_piv_info_ec=$?

    if [ $yk_piv_info_ec -ne 0 ]; then
        log_warn "Could not fetch PIV status from YubiKey S/N ${yk_serial_for_status}. ykman EC: $yk_piv_info_ec"
        log_warn "ykman output:\n${yk_piv_info_output}"
        return 1
    fi

    log_debug "YubiKey S/N ${yk_serial_for_status} PIV Info:\n${yk_piv_info_output}"

    local pin_tries puk_tries
    pin_tries=$(echo "${yk_piv_info_output}" | grep "PIN tries remaining:" | awk '{print $4}')
    puk_tries=$(echo "${yk_piv_info_output}" | grep "PUK tries remaining:" | awk '{print $4}')

    log_info "  PIV PIN tries remaining: ${pin_tries:-N/A}"
    log_info "  PIV PUK tries remaining: ${puk_tries:-N/A}"

    if [[ "${pin_tries}" == "1" || "${puk_tries}" == "1" ]]; then
        log_warn "CRITICAL: Your PIV PIN or PUK retry counter is at 1. Be extremely careful with subsequent entries."
    fi
}
# --- Parse Command-Line Arguments ---
if [[ "$#" -eq 0 ]]; then usage; fi
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --serial) YK_SERIAL="$2"; shift ;;
        --slot) PIV_SLOT="$2"; shift ;;
        --output) OUTPUT_IDENTITY_FILE="$2"; shift ;;
        --pin-policy) PIN_POLICY="$2"; shift ;;
        --touch-policy) TOUCH_POLICY="$2"; shift ;;
        *) log_error "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# --- Resolve Configuration from Arguments and Environment Variables ---
# Use argument if provided, otherwise fallback to environment variables (e.g., from .mise.toml), then to hardcoded defaults for policies.
YK_SERIAL="${YK_SERIAL:-${AGE_PRIMARY_YUBIKEY_SERIAL:-${AGE_BACKUP_YUBIKEY_SERIAL:-}}}"
PIV_SLOT="${PIV_SLOT:-${AGE_PRIMARY_YUBIKEY_PIV_SLOT:-${AGE_BACKUP_YUBIKEY_PIV_SLOT:-}}}"
OUTPUT_IDENTITY_FILE="${OUTPUT_IDENTITY_FILE:-${AGE_PRIMARY_YUBIKEY_IDENTITY_FILE:-${AGE_BACKUP_YUBIKEY_IDENTITY_FILE:-}}}"
PIN_POLICY="${PIN_POLICY:-${AGE_PRIMARY_YUBIKEY_PIN_POLICY:-once}}"
TOUCH_POLICY="${TOUCH_POLICY:-${AGE_PRIMARY_YUBIKEY_TOUCH_POLICY:-cached}}"

# Ensure required variables are set, prompting if necessary.
ensure_var_set "YK_SERIAL" "Enter YubiKey serial number"
ensure_var_set "PIV_SLOT" "Enter PIV slot (e.g., 9a, 9c, 82-95)"
ensure_var_set "OUTPUT_IDENTITY_FILE" "Enter path to save AGE identity file"

# Validate PIV slot format and policy values.
if ! [[ "$PIV_SLOT" =~ ^(9[acde]|[89][0-9a-f])$ ]]; then log_error "Invalid PIV_SLOT: '${PIV_SLOT}'. Must be 9a, 9c, 9d, 9e, or hex 82-95."; usage; fi
VALID_PIN_POLICIES=("once" "always" "never"); if ! printf '%s\n' "${VALID_PIN_POLICIES[@]}" | grep -q -w "$PIN_POLICY"; then log_error "Invalid PIN_POLICY: '${PIN_POLICY}'. Must be one of: ${VALID_PIN_POLICIES[*]}."; usage; fi
VALID_TOUCH_POLICIES=("cached" "always" "never"); if ! printf '%s\n' "${VALID_TOUCH_POLICIES[@]}" | grep -q -w "$TOUCH_POLICY"; then log_error "Invalid TOUCH_POLICY: '${TOUCH_POLICY}'. Must be one of: ${VALID_TOUCH_POLICIES[*]}."; usage; fi

log_info "Starting YubiKey AGE Provisioning for YubiKey S/N: ${YK_SERIAL}, PIV Slot: ${PIV_SLOT}"
log_warn "The AGE private key will be generated ON THE YUBIKEY and is NON-EXPORTABLE."
log_info "AGE Identity File (pointer to YK key) will be saved to: ${OUTPUT_IDENTITY_FILE}"
log_info "AGE Key PIN Policy: ${PIN_POLICY}, Touch Policy: ${TOUCH_POLICY}"
log_debug "Resolved YK_SERIAL: ${YK_SERIAL}"
log_debug "Resolved PIV_SLOT: ${PIV_SLOT}"
log_debug "Resolved OUTPUT_IDENTITY_FILE: ${OUTPUT_IDENTITY_FILE}"
log_debug "Resolved PIN_POLICY: ${PIN_POLICY}"
log_debug "Resolved TOUCH_POLICY: ${TOUCH_POLICY}"
log_debug "PIV_MIN_PIN_LENGTH_CONFIG: ${PIV_MIN_PIN_LENGTH_CONFIG}"
log_debug "PIV_MIN_PUK_LENGTH_CONFIG: ${PIV_MIN_PUK_LENGTH_CONFIG}"

# --- Prerequisite Checks ---
check_command "ykman"; check_command "age-plugin-yubikey"; check_command "mkdir"; check_command "chmod"; check_command "grep"; check_command "cut"; check_command "xargs"

# --- Step 1: Connect to YubiKey and Check PIV Applet Status ---
log_info "Step 1: Connecting to YubiKey and Checking PIV Applet Status."
YKMAN_LIST_OUTPUT=$(ykman list --serials 2>&1); YKMAN_LIST_EC=$?
log_debug "ykman list output (EC:${YKMAN_LIST_EC}):\n${YKMAN_LIST_OUTPUT}"
if [ $YKMAN_LIST_EC -ne 0 ]; then log_error "Failed to list YubiKeys. EC:$YKMAN_LIST_EC. Output:\n${YKMAN_LIST_OUTPUT}"; exit 1; fi
if ! echo "${YKMAN_LIST_OUTPUT}" | grep -q -w "${YK_SERIAL}"; then log_error "YubiKey S/N ${YK_SERIAL} not found. Available:\n${YKMAN_LIST_OUTPUT}"; exit 1; fi

# Get PIV applet information.
PIV_INFO_OUTPUT=$(ykman -s "${YK_SERIAL}" piv info 2>&1); PIV_INFO_EC=$?
log_debug "ykman piv info output (EC:${PIV_INFO_EC}):\n${PIV_INFO_OUTPUT}"
# Assume current PINs/PUK/MgmtKey are defaults initially. These will be updated if user changes them or if a reset occurs.
_CURRENT_PIV_PIN="$DEFAULT_PIV_PIN"
_CURRENT_PIV_PUK="$DEFAULT_PIV_PUK"
_CURRENT_PIV_MANAGEMENT_KEY="$DEFAULT_PIV_MANAGEMENT_KEY"

if [ $PIV_INFO_EC -ne 0 ]; then
    # If `ykman piv info` fails, it might indicate a problem with the PIV applet or connection.
    log_warn "ykman piv info failed (EC:$PIV_INFO_EC). Output:\n${PIV_INFO_OUTPUT}"
    log_warn "This might indicate PIV applet issues. Reset might be necessary."
    # Check if PIV is explicitly disabled.
    if echo "${PIV_INFO_OUTPUT}" | grep -q "PIV application.*Disabled"; then log_error "PIV application is disabled on YK S/N ${YK_SERIAL}. Enable with 'ykman -s ${YK_SERIAL} config usb --enable PIV'."; exit 1; fi
else
    # Display initial PIV status including retry counters
    get_and_display_yk_piv_status "$YK_SERIAL"

    # Check for common PIV applet issues even if `ykman piv info` succeeded.
    if echo "${PIV_INFO_OUTPUT}" | grep -q "PIV application.*Disabled"; then log_error "PIV application is disabled on YK S/N ${YK_SERIAL}. Enable with 'ykman -s ${YK_SERIAL} config usb --enable PIV'."; exit 1; fi
    if echo "${PIV_INFO_OUTPUT}" | grep -q "PIN tries remaining: 0"; then log_error "PIV PIN IS BLOCKED on YK S/N ${YK_SERIAL}. Unblock with PUK: 'ykman -s ${YK_SERIAL} piv access unblock-pin ...'."; exit 1; fi
    if echo "${PIV_INFO_OUTPUT}" | grep -q "Management key tries remaining: 0"; then log_error "PIV Management Key IS BLOCKED on YK S/N ${YK_SERIAL}. PIV reset may be required."; exit 1; fi

    # Check if the target PIV slot already contains a certificate/key.
    SLOT_STATUS_LINE=$(echo "${PIV_INFO_OUTPUT}" | grep "Slot ${PIV_SLOT}:")
    log_debug "Slot status line for ${PIV_SLOT}: ${SLOT_STATUS_LINE}"
    if echo "${SLOT_STATUS_LINE}" | grep -q "Certificate: yes"; then
        log_warn "PIV Slot ${PIV_SLOT} on YK S/N ${YK_SERIAL} already contains a certificate/key."
        if confirm "Do you want to DELETE the existing key/certificate in PIV Slot ${PIV_SLOT} to generate a new AGE identity here?"; then
            log_info "Attempting to delete existing key/certificate in slot ${PIV_SLOT}..."
            # Prompt for the current PIV Management Key to authorize deletion.
            get_secure_input "Enter CURRENT PIV Management Key for YK S/N ${YK_SERIAL} (default: ${DEFAULT_PIV_MANAGEMENT_KEY:0:8}...): " PIV_MGMT_KEY_FOR_DELETE
            _CURRENT_PIV_MANAGEMENT_KEY="$PIV_MGMT_KEY_FOR_DELETE" # Assume this is the current one for subsequent ops if not reset

            YKMAN_DEL_OUT=""; YKMAN_DEL_EC=1 # Accumulate output and track overall success
            # Delete the key from the slot.
            YKMAN_DEL_KEY_OUT=$(ykman -s "${YK_SERIAL}" piv keys delete "${PIV_SLOT}" --management-key "${PIV_MGMT_KEY_FOR_DELETE}" --force 2>&1); YKMAN_DEL_KEY_EC=$?
            log_debug "ykman piv keys delete output (EC:${YKMAN_DEL_KEY_EC}):\n${YKMAN_DEL_KEY_OUT}"
            if [ $YKMAN_DEL_KEY_EC -eq 0 ]; then log_success "Key deleted from slot ${PIV_SLOT}."; YKMAN_DEL_EC=0; else YKMAN_DEL_OUT+="\nKeyDel: ${YKMAN_DEL_KEY_OUT}"; fi
            
            # Delete the certificate from the slot.
            YKMAN_DEL_CERT_OUT=$(ykman -s "${YK_SERIAL}" piv certificates delete "${PIV_SLOT}" --management-key "${PIV_MGMT_KEY_FOR_DELETE}" --force 2>&1); YKMAN_DEL_CERT_EC=$?
            log_debug "ykman piv certificates delete output (EC:${YKMAN_DEL_CERT_EC}):\n${YKMAN_DEL_CERT_OUT}"
            if [ $YKMAN_DEL_CERT_EC -eq 0 ]; then log_success "Cert deleted from slot ${PIV_SLOT}."; YKMAN_DEL_EC=0; else YKMAN_DEL_OUT+="\nCertDel: ${YKMAN_DEL_CERT_OUT}"; fi
            
            unset PIV_MGMT_KEY_FOR_DELETE # Unset sensitive variable
            if [ $YKMAN_DEL_EC -ne 0 ]; then log_error "Failed to clear PIV Slot ${PIV_SLOT}. Output:${YKMAN_DEL_OUT}"; exit 1; fi
        else log_info "Skipping slot deletion. Cannot provision AGE identity in occupied slot ${PIV_SLOT}."; exit 0; fi
    elif echo "${SLOT_STATUS_LINE}" | grep -q "Certificate: no"; then log_info "PIV Slot ${PIV_SLOT} is empty and ready.";
    else log_warn "Could not determine status of PIV Slot ${PIV_SLOT}. Proceeding with caution."; fi
fi

# --- Step 2: Optional PIV Applet Reset ---
log_info "Step 2: Optional PIV Applet Reset."
if confirm "Do you want to perform a full PIV applet RESET on YK S/N ${YK_SERIAL}? This WIPES ALL PIV data (keys, certs, PINs, PUK, Mgmt Key) and restores defaults."; then
    log_warn "This is a DESTRUCTIVE action. Ensure this is intended."
    # Prompt for the current PIV PUK to authorize reset.
    get_secure_input "Enter CURRENT PIV PUK for YK S/N ${YK_SERIAL} to authorize reset (if not default '${DEFAULT_PIV_PUK}', enter current): " PIV_PUK_FOR_RESET
    _CURRENT_PIV_PUK="$PIV_PUK_FOR_RESET" # Assume this is current for subsequent ops if not reset
    YKMAN_PIV_RESET_OUT=$(ykman -s "${YK_SERIAL}" piv reset --puk "${PIV_PUK_FOR_RESET}" --force 2>&1); YKMAN_PIV_RESET_EC=$?
    log_debug "ykman piv reset output (EC:${YKMAN_PIV_RESET_EC}):\n${YKMAN_PIV_RESET_OUT}"
    unset PIV_PUK_FOR_RESET # Unset sensitive variable
    if [ $YKMAN_PIV_RESET_EC -eq 0 ]; then
        log_success "YubiKey PIV applet reset successfully. PIN, PUK, Mgmt Key are now defaults."
        # After reset, current credentials are known defaults.
        _CURRENT_PIV_PIN="$DEFAULT_PIV_PIN"; _CURRENT_PIV_PUK="$DEFAULT_PIV_PUK"; _CURRENT_PIV_MANAGEMENT_KEY="$DEFAULT_PIV_MANAGEMENT_KEY"
    else log_error "Failed to reset PIV applet. EC:$YKMAN_PIV_RESET_EC. Output:\n${YKMAN_PIV_RESET_OUT}"; exit 1; fi
fi

# --- Step 3: Setting PIV Credentials ---
log_info "Step 3: Setting PIV Credentials (PIN, PUK, Management Key)."
log_warn "Choose strong, unique values. Defaults: PIN='${DEFAULT_PIV_PIN}', PUK='${DEFAULT_PIV_PUK}', MgmtKey='${DEFAULT_PIV_MANAGEMENT_KEY:0:8}...'."
# Set new PIV PIN
log_info "Setting PIV PIN..."
while true; do
    get_secure_input "Enter NEW PIV PIN (min ${PIV_MIN_PIN_LENGTH_CONFIG} chars, current/default is '${_CURRENT_PIV_PIN}'): " NEW_PIV_PIN_VALUE
    if [ "${#NEW_PIV_PIN_VALUE}" -lt "${PIV_MIN_PIN_LENGTH_CONFIG}" ]; then log_warn "PIV PIN too short (min ${PIV_MIN_PIN_LENGTH_CONFIG} chars).";
    elif [ "$NEW_PIV_PIN_VALUE" == "$DEFAULT_PIV_PIN" ]; then log_warn "Using default PIV PIN. Strongly recommended to use a unique PIN."; if ! confirm "Use default PIV PIN?"; then continue; fi; break
    else break; fi
done
while true; do get_secure_input "Confirm NEW PIV PIN: " CONFIRM_NEW_PIV_PIN_VALUE; if [ "$NEW_PIV_PIN_VALUE" == "$CONFIRM_NEW_PIV_PIN_VALUE" ]; then break; else log_warn "PIV PINs do not match."; fi; done; unset CONFIRM_NEW_PIV_PIN_VALUE

# Set new PIV PUK
log_info "Setting PIV PUK..."
while true; do
    get_secure_input "Enter NEW PIV PUK (min ${PIV_MIN_PUK_LENGTH_CONFIG} chars, current/default is '${_CURRENT_PIV_PUK}'): " NEW_PIV_PUK_VALUE
    if [ "${#NEW_PIV_PUK_VALUE}" -lt "${PIV_MIN_PUK_LENGTH_CONFIG}" ]; then log_warn "PIV PUK too short (min ${PIV_MIN_PUK_LENGTH_CONFIG} chars).";
    elif [ "$NEW_PIV_PUK_VALUE" == "$DEFAULT_PIV_PUK" ]; then log_warn "Using default PIV PUK. Strongly recommended to use a unique PUK."; if ! confirm "Use default PIV PUK?"; then continue; fi; break
    else break; fi
done
while true; do get_secure_input "Confirm NEW PIV PUK: " CONFIRM_NEW_PIV_PUK_VALUE; if [ "$NEW_PIV_PUK_VALUE" == "$CONFIRM_NEW_PIV_PUK_VALUE" ]; then break; else log_warn "PIV PUKs do not match."; fi; done; unset CONFIRM_NEW_PIV_PUK_VALUE

# Set new PIV Management Key
log_info "Setting PIV Management Key..."
log_warn "This key is for PIV admin tasks. Store it securely! It must be 48 hexadecimal characters."
while true; do
    get_secure_input "Enter NEW PIV Management Key (48 hex chars, current/default is '${_CURRENT_PIV_MANAGEMENT_KEY:0:8}...'): " NEW_PIV_MANAGEMENT_KEY_VALUE
    if ! [[ "$NEW_PIV_MANAGEMENT_KEY_VALUE" =~ ^[0-9a-fA-F]{48}$ ]]; then log_warn "PIV Management Key must be 48 hex chars.";
    elif [ "$NEW_PIV_MANAGEMENT_KEY_VALUE" == "$DEFAULT_PIV_MANAGEMENT_KEY" ]; then log_warn "Using default PIV Mgmt Key. Strongly recommended unique."; if ! confirm "Use default PIV Mgmt Key?"; then continue; fi; break
    else break; fi
done
while true; do get_secure_input "Confirm NEW PIV Management Key: " CONFIRM_NEW_PIV_MANAGEMENT_KEY_VALUE; if [ "$NEW_PIV_MANAGEMENT_KEY_VALUE" == "$CONFIRM_NEW_PIV_MANAGEMENT_KEY_VALUE" ]; then break; else log_warn "PIV Mgmt Keys do not match."; fi; done; unset CONFIRM_NEW_PIV_MANAGEMENT_KEY_VALUE

log_info "Attempting to change PIV credentials. ykman will prompt for CURRENT credentials if they differ from script's understanding."
# Change PIV PIN using ykman.
YKMAN_CHPIN_OUT=$(ykman -s "${YK_SERIAL}" piv access change-pin --pin "${_CURRENT_PIV_PIN}" --new-pin "${NEW_PIV_PIN_VALUE}" --force 2>&1); YKMAN_CHPIN_EC=$?
log_debug "ykman piv access change-pin output (EC:${YKMAN_CHPIN_EC}):\n${YKMAN_CHPIN_OUT}"
if [ $YKMAN_CHPIN_EC -ne 0 ]; then
    log_error "Failed to change PIV PIN. EC:$YKMAN_CHPIN_EC. Output:\n${YKMAN_CHPIN_OUT}"
    # Do not exit immediately, allow other changes to be attempted or cleanup to occur.
else
    log_success "PIV PIN changed successfully."
    _CURRENT_PIV_PIN="${NEW_PIV_PIN_VALUE}" # Update current PIN understanding
fi

# Change PIV PUK using ykman.
YKMAN_CHPUK_OUT=$(ykman -s "${YK_SERIAL}" piv access change-puk --puk "${_CURRENT_PIV_PUK}" --new-puk "${NEW_PIV_PUK_VALUE}" --force 2>&1); YKMAN_CHPUK_EC=$?
log_debug "ykman piv access change-puk output (EC:${YKMAN_CHPUK_EC}):\n${YKMAN_CHPUK_OUT}"
if [ $YKMAN_CHPUK_EC -ne 0 ]; then
    log_error "Failed to change PIV PUK. EC:$YKMAN_CHPUK_EC. Output:\n${YKMAN_CHPUK_OUT}"
else
    log_success "PIV PUK changed successfully."
    _CURRENT_PIV_PUK="${NEW_PIV_PUK_VALUE}" # Update current PUK understanding
fi

# Change PIV Management Key using ykman.
YKMAN_CHMK_OUT=$(ykman -s "${YK_SERIAL}" piv access change-management-key --management-key "${_CURRENT_PIV_MANAGEMENT_KEY}" --new-management-key "${NEW_PIV_MANAGEMENT_KEY_VALUE}" --force 2>&1); YKMAN_CHMK_EC=$?
log_debug "ykman piv access change-management-key output (EC:${YKMAN_CHMK_EC}):\n${YKMAN_CHMK_OUT}"
if [ $YKMAN_CHMK_EC -ne 0 ]; then
    log_error "Failed to change PIV Management Key. EC:$YKMAN_CHMK_EC. Output:\n${YKMAN_CHMK_OUT}"
else
    log_success "PIV Management Key changed successfully."
    _CURRENT_PIV_MANAGEMENT_KEY="${NEW_PIV_MANAGEMENT_KEY_VALUE}" # Update current Mgmt Key understanding
fi
log_warn "Ensure NEW PIV credentials were set. Store them securely!"

# Optionally protect the Management Key with PIN and touch.
if confirm "Do you want to protect the PIV Management Key with PIN and touch (recommended)?"; then
    log_info "Protecting Management Key with PIN and touch..."
    # This re-sets the management key to itself but adds the --protect flag.
    YKMAN_PROTECTMK_OUT=$(ykman -s "${YK_SERIAL}" piv access change-management-key --management-key "${NEW_PIV_MANAGEMENT_KEY_VALUE}" --new-management-key "${NEW_PIV_MANAGEMENT_KEY_VALUE}" --protect --force 2>&1); YKMAN_PROTECTMK_EC=$?
    log_debug "ykman piv access change-management-key --protect output (EC:${YKMAN_PROTECTMK_EC}):\n${YKMAN_PROTECTMK_OUT}"
    if [ $YKMAN_PROTECTMK_EC -eq 0 ]; then log_success "PIV Management Key protected."; else log_error "Failed to protect PIV Mgmt Key. EC:$YKMAN_PROTECTMK_EC. Output:\n${YKMAN_PROTECTMK_OUT}"; fi
fi

# Display PIV status after credential changes
get_and_display_yk_piv_status "$YK_SERIAL"

# --- Step 4: Generate AGE Identity on YubiKey ---
log_info "Step 4: Generating AGE Identity on YubiKey."
log_info "Using PIV Slot: ${PIV_SLOT}, PIN Policy: ${PIN_POLICY}, Touch Policy: ${TOUCH_POLICY}"
AGE_GENERATE_CMD="age-plugin-yubikey --generate --serial ${YK_SERIAL} --slot ${PIV_SLOT} --pin-policy ${PIN_POLICY} --touch-policy ${TOUCH_POLICY}"
log_info "Running: ${AGE_GENERATE_CMD}"
log_debug "Full age-plugin-yubikey command: ${AGE_GENERATE_CMD}"
# age-plugin-yubikey will prompt for PIV Management Key and PIV PIN as needed.
log_warn "age-plugin-yubikey will now prompt for the PIV Management Key ('${NEW_PIV_MANAGEMENT_KEY_VALUE}') and PIV PIN ('${NEW_PIV_PIN_VALUE}') as required by policies."
IDENTITY_PLUGIN_OUTPUT=$(${AGE_GENERATE_CMD} 2>&1); PLUGIN_EXIT_CODE=$?
log_debug "age-plugin-yubikey --generate output (EC:${PLUGIN_EXIT_CODE}):\n${IDENTITY_PLUGIN_OUTPUT}"
# Unset sensitive variables from script memory immediately after use.
unset NEW_PIV_PIN_VALUE; unset NEW_PIV_PUK_VALUE; unset NEW_PIV_MANAGEMENT_KEY_VALUE

if [ $PLUGIN_EXIT_CODE -ne 0 ]; then log_error "Failed to generate AGE identity. age-plugin-yubikey EC:$PLUGIN_EXIT_CODE. Output:\n${IDENTITY_PLUGIN_OUTPUT}"; exit 1; fi
log_success "AGE identity generated successfully on YubiKey."

# --- Step 5: Save AGE Identity File and Extract Public Key ---
log_info "Step 5: Saving AGE Identity File and Extracting Public Key."
OUTPUT_IDENTITY_DIR=$(dirname "${OUTPUT_IDENTITY_FILE}")
if ! mkdir -p "${OUTPUT_IDENTITY_DIR}"; then log_error "Failed to create directory for identity file: ${OUTPUT_IDENTITY_DIR}"; exit 1; fi
# The identity file contains a pointer/recipe for the plugin, not the private key itself.
echo "${IDENTITY_PLUGIN_OUTPUT}" | grep -v '^# public key:' > "${OUTPUT_IDENTITY_FILE}"
if [ $? -ne 0 ] || [ ! -s "${OUTPUT_IDENTITY_FILE}" ]; then log_error "Failed to save AGE identity file to: ${OUTPUT_IDENTITY_FILE}. Plugin output:\n${IDENTITY_PLUGIN_OUTPUT}"; exit 1; fi
if ! chmod 600 "${OUTPUT_IDENTITY_FILE}"; then log_error "Failed to set permissions (chmod 600) on ${OUTPUT_IDENTITY_FILE}. Set manually."; fi
log_success "AGE identity file saved: ${OUTPUT_IDENTITY_FILE}"

# Extract the public key (recipient string) from the plugin output.
AGE_PUBLIC_KEY=$(echo "${IDENTITY_PLUGIN_OUTPUT}" | grep '^# public key:' | cut -d: -f2 | xargs)
if [ -z "${AGE_PUBLIC_KEY}" ]; then log_warn "Could not extract AGE public key from plugin output:\n${IDENTITY_PLUGIN_OUTPUT}";
else
    log_success "AGE Recipient Public Key: ${AGE_PUBLIC_KEY}"
    log_warn "IMPORTANT: Add this public key to your .sops.yaml 'age:' recipients list."
fi

log_info "---------------------------------------------------------------------"
log_success "YubiKey AGE Provisioning Complete for S/N ${YK_SERIAL}, PIV Slot ${PIV_SLOT}."
log_info "---------------------------------------------------------------------"
log_warn "IMPORTANT: The AGE private key generated for this identity resides ONLY on this YubiKey (S/N ${YK_SERIAL}, Slot ${PIV_SLOT}) and is NON-EXPORTABLE."
log_warn "  - If this YubiKey is lost or damaged, this specific AGE private key is irrecoverable."
log_warn "  - To decrypt data encrypted with this key, this YubiKey (or another YubiKey with a *different* AGE key that the data was *also* encrypted to) is required."
log_info "The identity file (${OUTPUT_IDENTITY_FILE}) is a POINTER to the key on the YubiKey; it is NOT the private key itself."
log_warn "Next Steps:"
log_warn "  1. Back up the identity file ('${OUTPUT_IDENTITY_FILE}'). It's needed for SOPS/AGE to find the key on this YubiKey."
log_warn "  2. CRITICAL: Remember your new PIV PIN, PUK, and Management Key. They have been unset from script memory. Store them securely!"
log_info "  3. To use this key with SOPS, ensure SOPS_AGE_KEY_FILE is set to point to '${OUTPUT_IDENTITY_FILE}' (Mise tasks can help manage this)."
log_info "  4. For redundancy, consider provisioning a backup YubiKey with its own AGE identity and encrypting secrets to both."

exit 0
