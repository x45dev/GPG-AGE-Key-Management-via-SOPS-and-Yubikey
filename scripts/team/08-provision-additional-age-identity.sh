#!/usr/bin/env bash
# scripts/team/08-provision-additional-age-identity.sh
# Provisions an AGE identity on a YubiKey, typically for an additional user or purpose.
# Assumes the YubiKey's PIV applet (PINs, Management Key) is already configured.
# The private key for this AGE identity is generated ON THE YUBIKEY and is NON-EXPORTABLE.

SHELL_OPTIONS="set -e -u -o pipefail"
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error when substituting.
# set -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status, or zero if no command exited with a non-zero status.
eval "$SHELL_OPTIONS"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # Adjusted BASE_DIR for team script
LIB_SCRIPT_PATH="${BASE_DIR}/scripts/lib/common.sh"

if [ ! -f "$LIB_SCRIPT_PATH" ]; then
    echo "Error: common.sh not found at $LIB_SCRIPT_PATH"
    exit 1
fi
# shellcheck source=scripts/lib/common.sh
# Load common library functions (logging, prompts, etc.)
source "$LIB_SCRIPT_PATH"

# --- Usage Function ---
usage() {
    echo "Usage: $(basename "$0") --label <LABEL> [--serial <YK_SERIAL>] [--slot <PIV_SLOT>] \\"
    echo "                      [--output <IDENTITY_FILE_PATH>] [--pin-policy <POLICY>] [--touch-policy <POLICY>] \\"
    echo "                      [--recipients-file <RECIPIENTS_LIST_FILE>] [--no-update-recipients]"
    echo ""
    echo "This script generates a new AGE identity on a YubiKey's PIV applet."
    echo "The private key for this AGE identity is generated DIRECTLY ON THE YUBIKEY's PIV applet"
    echo "and is NON-EXPORTABLE. This enhances security by keeping the private key on hardware,"
    echo "but means the key cannot be backed up in the traditional sense. Backup for this key"
    echo "means safeguarding the YubiKey itself and/or encrypting secrets to multiple recipients."
    echo ""
    echo "It is intended for provisioning additional identities, assuming the YubiKey's PIV"
    echo "applet (PINs, Management Key) has already been appropriately configured by the YubiKey owner."
    echo "If full PIV setup is needed (PINs, PUK, Mgmt Key changes), use '04-provision-age-yubikey.sh' first."
    echo ""
    echo "Arguments:"
    echo "  --label <LABEL>                 A descriptive label for this identity (e.g., 'john-doe', 'server-backup'). Required."
    echo "  --serial <YK_SERIAL>            Optional. Serial number of the target YubiKey. If not provided, uses"
    echo "                                  ADDITIONAL_AGE_YUBIKEY_SERIAL env var or prompts if multiple YKs are present."
    echo "  --slot <PIV_SLOT>               Optional. PIV slot (e.g., 9a, 9c, 9d, 9e, 82-95). Default from env or '9c'."
    echo "  --output <IDENTITY_FILE_PATH>   Optional. Full path to save the AGE identity file (POINTER to YK key). If not provided, a path is"
    echo "                                  generated based on ADDITIONAL_AGE_IDENTITY_FILE_PATH_TEMPLATE env var, label, and serial."
    echo "  --pin-policy <POLICY>           Optional. PIV PIN policy (once, always, never). Default from env or 'once'."
    echo "  --touch-policy <POLICY>         Optional. PIV touch policy (cached, always, never). Default from env or 'cached'."
    echo "  --recipients-file <FILE_PATH>   Optional. Path to a file for appending the new AGE public key (e.g., age-recipients.txt)."
    echo "                                  Default from env or 'age-recipients.txt' in project root."
    echo "  --no-update-recipients          Optional. If set, do not append the public key to the recipients file."
    echo ""
    echo "The script will:"
    echo "  1. Validate arguments and YubiKey connectivity."
    echo "  2. Generate the AGE identity ON THE YUBIKEY using 'age-plugin-yubikey'."
    echo "  3. Save the AGE identity file (pointer)."
    echo "  4. Display the AGE recipient public key."
    echo "  5. Optionally, append the public key to a specified recipients list file."
    echo ""
    echo "Make sure 'ykman', 'age-plugin-yubikey', 'mkdir', 'chmod', 'grep', 'cut', 'xargs' are installed."
    exit 1
}

# --- Configuration & Argument Parsing ---
LABEL_ARG=""
YK_SERIAL_ARG=""
PIV_SLOT_ARG=""
OUTPUT_IDENTITY_FILE_ARG=""
PIN_POLICY_ARG=""
TOUCH_POLICY_ARG=""
RECIPIENTS_FILE_ARG=""
NO_UPDATE_RECIPIENTS_FLAG=false

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --label) LABEL_ARG="$2"; shift ;;
        --serial) YK_SERIAL_ARG="$2"; shift ;;
        --slot) PIV_SLOT_ARG="$2"; shift ;;
        --output) OUTPUT_IDENTITY_FILE_ARG="$2"; shift ;;
        --pin-policy) PIN_POLICY_ARG="$2"; shift ;;
        --touch-policy) TOUCH_POLICY_ARG="$2"; shift ;;
        --recipients-file) RECIPIENTS_FILE_ARG="$2"; shift ;;
        --no-update-recipients) NO_UPDATE_RECIPIENTS_FLAG=true ;;
        *) log_error "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Label is mandatory.
if [ -z "$LABEL_ARG" ]; then
    log_error "Missing required argument: --label <LABEL>"
    usage
fi

# Resolve configurations: Use argument if provided, else fallback to environment variable, else use a hardcoded default.
YK_SERIAL="${YK_SERIAL_ARG:-${ADDITIONAL_AGE_YUBIKEY_SERIAL:-}}"
PIV_SLOT="${PIV_SLOT_ARG:-${ADDITIONAL_AGE_PIV_SLOT:-9c}}" # Default to slot 9c if not specified
PIN_POLICY="${PIN_POLICY_ARG:-${ADDITIONAL_AGE_PIN_POLICY:-once}}" # Default to 'once'
TOUCH_POLICY="${TOUCH_POLICY_ARG:-${ADDITIONAL_AGE_TOUCH_POLICY:-cached}}" # Default to 'cached'
RECIPIENTS_FILE_PATH_CONFIG="${RECIPIENTS_FILE_ARG:-${ADDITIONAL_AGE_RECIPIENTS_FILE:-age-recipients.txt}}"

# Construct the output identity file path if not explicitly provided by the user.
# This uses a template that includes the label and YubiKey serial for uniqueness.
if [ -n "$OUTPUT_IDENTITY_FILE_ARG" ]; then
    OUTPUT_IDENTITY_FILE="${OUTPUT_IDENTITY_FILE_ARG/#\~/$HOME}" # Expand tilde if present
else
    # If YK_SERIAL is not set (neither by arg nor env), try to auto-detect if only one YK is present.
    # This is needed to construct the default identity file path.
    if [ -z "$YK_SERIAL" ]; then
        NUM_YKS=$(ykman list --serials 2>/dev/null | wc -l | xargs) # Get count of connected YubiKeys
        if [ "$NUM_YKS" -gt 1 ]; then
            # If multiple YKs, YK_SERIAL must be provided.
            ensure_var_set "YK_SERIAL" "Multiple YubiKeys detected. Enter serial for label '${LABEL_ARG}'"
        elif [ "$NUM_YKS" -eq 1 ]; then
            YK_SERIAL=$(ykman list --serials | head -n 1 | xargs) # Get serial of the single YK
            log_info "Auto-detected YubiKey serial: ${YK_SERIAL} for label '${LABEL_ARG}'"
        else
            log_error "No YubiKey detected. Cannot proceed without a serial number for label '${LABEL_ARG}'."
            exit 1
        fi
    fi
    # Use template for identity file path, replacing placeholders.
    DEFAULT_PATH_TEMPLATE="${ADDITIONAL_AGE_IDENTITY_FILE_PATH_TEMPLATE:-~/.config/sops/age/yubikey_{{label}}_{{serial}}.txt}"
    TEMP_PATH="${DEFAULT_PATH_TEMPLATE//\{\{label\}\}/$LABEL_ARG}" # Replace {{label}}
    OUTPUT_IDENTITY_FILE="${TEMP_PATH//\{\{serial\}\}/$YK_SERIAL}"   # Replace {{serial}}
    OUTPUT_IDENTITY_FILE="${OUTPUT_IDENTITY_FILE/#\~/$HOME}"       # Expand tilde
fi

# Resolve the full path for the recipients file (where the new public key might be appended).
# If the path is not absolute, assume it's relative to the project root.
if [[ "$RECIPIENTS_FILE_PATH_CONFIG" != /* ]]; then
    RECIPIENTS_FILE_ACTUAL_PATH="${BASE_DIR}/${RECIPIENTS_FILE_PATH_CONFIG}"
else
    RECIPIENTS_FILE_ACTUAL_PATH="$RECIPIENTS_FILE_PATH_CONFIG"
fi


# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 08-provision-additional-age-identity.sh with status $exit_status_for_cleanup"
    # This script primarily calls external tools that manage their own state; no specific sensitive vars to unset here
    # beyond what common.sh might handle (like passphrases, though not directly used here).
}

# --- Input Validation for PIV Slot and Policies ---
if ! [[ "$PIV_SLOT" =~ ^(9[acde]|[89][0-9a-f])$ ]]; then log_error "Invalid PIV_SLOT: '${PIV_SLOT}'. Must be 9a, 9c, 9d, 9e, or hex 82-95."; usage; fi
VALID_PIN_POLICIES=("once" "always" "never"); if ! printf '%s\n' "${VALID_PIN_POLICIES[@]}" | grep -q -w "$PIN_POLICY"; then log_error "Invalid PIN_POLICY: '${PIN_POLICY}'. Must be one of: ${VALID_PIN_POLICIES[*]}."; usage; fi
VALID_TOUCH_POLICIES=("cached" "always" "never"); if ! printf '%s\n' "${VALID_TOUCH_POLICIES[@]}" | grep -q -w "$TOUCH_POLICY"; then log_error "Invalid TOUCH_POLICY: '${TOUCH_POLICY}'. Must be one of: ${VALID_TOUCH_POLICIES[*]}."; usage; fi


log_info "Starting Additional YubiKey AGE Identity Provisioning."
log_warn "The AGE private key will be generated ON THE YUBIKEY and is NON-EXPORTABLE."
log_info "  Label: ${LABEL_ARG}"
log_info "  YubiKey Serial: ${YK_SERIAL:- (auto-detect or first available)}"
log_info "  PIV Slot: ${PIV_SLOT}"
log_info "  Output Identity File (pointer to YK key): ${OUTPUT_IDENTITY_FILE}"
log_info "  PIN Policy: ${PIN_POLICY}, Touch Policy: ${TOUCH_POLICY}"
if ! $NO_UPDATE_RECIPIENTS_FLAG; then
    log_info "  Public key will be appended to: ${RECIPIENTS_FILE_ACTUAL_PATH}"
fi

# --- Prerequisite Checks ---
check_command "ykman"
check_command "age-plugin-yubikey"
check_command "mkdir"
check_command "chmod"
check_command "grep"
check_command "cut"
check_command "xargs"

# --- Step 1: YubiKey Connection & Target Selection ---
log_info "Step 1: Verifying YubiKey Connectivity."
if [ -n "$YK_SERIAL" ]; then # If a specific serial number is provided, verify it's connected.
    YKMAN_LIST_OUTPUT=$(ykman list --serials 2>&1); YKMAN_LIST_EC=$?
    if [ $YKMAN_LIST_EC -ne 0 ]; then log_error "Failed to list YubiKeys. EC:$YKMAN_LIST_EC. Output:\n${YKMAN_LIST_OUTPUT}"; exit 1; fi
    if ! echo "${YKMAN_LIST_OUTPUT}" | grep -q -w "${YK_SERIAL}"; then log_error "YubiKey S/N ${YK_SERIAL} not found. Available:\n${YKMAN_LIST_OUTPUT}"; exit 1; fi
    log_info "Targeting YubiKey S/N: ${YK_SERIAL}"
else
    # If no serial is provided, age-plugin-yubikey will typically use the first available YubiKey.
    log_info "No specific YubiKey serial provided. age-plugin-yubikey will use the first available YubiKey."
    # YK_SERIAL might have been auto-detected earlier for path generation. If so, it will be passed to the plugin.
fi

# --- Step 2: Generate AGE Identity on YubiKey ---
log_info "Step 2: Generating AGE Identity on YubiKey."
log_warn "This script assumes the YubiKey's PIV applet (PINs, Management Key) is already configured by its owner."
log_warn "age-plugin-yubikey will prompt for the PIV Management Key and PIV PIN as required by the YubiKey and policies."

# Construct the command array for age-plugin-yubikey.
AGE_GENERATE_CMD_ARRAY=("age-plugin-yubikey" "--generate" "--slot" "${PIV_SLOT}" "--pin-policy" "${PIN_POLICY}" "--touch-policy" "${TOUCH_POLICY}")
if [ -n "$YK_SERIAL" ]; then # Add --serial flag only if YK_SERIAL is set.
    AGE_GENERATE_CMD_ARRAY+=("--serial" "${YK_SERIAL}")
fi

log_info "Running command: ${AGE_GENERATE_CMD_ARRAY[*]}"
# Execute the command and capture its output (which includes the identity and public key).
IDENTITY_PLUGIN_OUTPUT=$("${AGE_GENERATE_CMD_ARRAY[@]}" 2>&1)
PLUGIN_EXIT_CODE=$?

if [ $PLUGIN_EXIT_CODE -ne 0 ]; then
    log_error "Failed to generate AGE identity on YubiKey. age-plugin-yubikey Exit Code: $PLUGIN_EXIT_CODE."
    log_error "age-plugin-yubikey Output:\n${IDENTITY_PLUGIN_OUTPUT}"
    log_error "Ensure the YubiKey is connected, PIV applet is enabled, and correct PIN/Management Key are entered when prompted."
    exit 1
fi
log_success "AGE identity generated successfully on YubiKey."

# --- Step 3: Save Identity File ---
log_info "Step 3: Saving AGE Identity File (pointer to YK key)."
OUTPUT_IDENTITY_DIR=$(dirname "${OUTPUT_IDENTITY_FILE}")
if ! mkdir -p "${OUTPUT_IDENTITY_DIR}"; then
    log_error "Failed to create directory for identity file: ${OUTPUT_IDENTITY_DIR}"
    exit 1
fi

# The plugin output contains the identity string and a commented line with the public key.
# Save only the identity string (lines not starting with '# public key:') to the identity file.
echo "${IDENTITY_PLUGIN_OUTPUT}" | grep -v '^# public key:' > "${OUTPUT_IDENTITY_FILE}"
if [ $? -ne 0 ] || [ ! -s "${OUTPUT_IDENTITY_FILE}" ]; then # Check if file was created and is not empty.
    log_error "Failed to save AGE identity file content to: ${OUTPUT_IDENTITY_FILE}"
    log_error "Plugin output was:\n${IDENTITY_PLUGIN_OUTPUT}"
    exit 1
fi

# Set restrictive permissions on the identity file.
if ! chmod 600 "${OUTPUT_IDENTITY_FILE}"; then
    log_warn "Failed to set permissions (chmod 600) on identity file: ${OUTPUT_IDENTITY_FILE}. Please set manually."
fi
log_success "AGE identity file saved: ${OUTPUT_IDENTITY_FILE}"

# --- Step 4: Extract and Output Public Key ---
log_info "Step 4: Extracting and Displaying Public Key."
# Extract the public key (recipient string) from the plugin output.
AGE_PUBLIC_KEY=$(echo "${IDENTITY_PLUGIN_OUTPUT}" | grep '^# public key:' | cut -d: -f2 | xargs)
if [ -z "$AGE_PUBLIC_KEY" ]; then
    log_warn "Could not extract AGE public key from age-plugin-yubikey output."
    log_warn "Plugin output was:\n${IDENTITY_PLUGIN_OUTPUT}"
else
    log_success "Generated AGE Recipient Public Key: ${AGE_PUBLIC_KEY}"
    log_warn "IMPORTANT: This public key can be added to .sops.yaml or other AGE recipient lists."
fi

# --- Step 5: Optionally Append to Recipients File ---
if ! $NO_UPDATE_RECIPIENTS_FLAG && [ -n "$AGE_PUBLIC_KEY" ]; then
    log_info "Step 5: Appending Public Key to Recipients List."
    # If the recipients file doesn't exist, ask for confirmation to create it.
    if [ ! -f "$RECIPIENTS_FILE_ACTUAL_PATH" ] && ! confirm "Recipients file '${RECIPIENTS_FILE_ACTUAL_PATH}' does not exist. Create it?"; then
        log_info "Skipping update to recipients file as it does not exist and creation was not confirmed."
    else
        # Check if the public key already exists in the file to avoid duplicates.
        if grep -q -F "${AGE_PUBLIC_KEY}" "$RECIPIENTS_FILE_ACTUAL_PATH" 2>/dev/null ; then
            log_info "Public key already exists in ${RECIPIENTS_FILE_ACTUAL_PATH}. Skipping append."
        else
            # Append the label and public key to the recipients file.
            log_info "Appending '${LABEL_ARG}: ${AGE_PUBLIC_KEY}' to ${RECIPIENTS_FILE_ACTUAL_PATH}"
            echo "${LABEL_ARG}: ${AGE_PUBLIC_KEY}" >> "$RECIPIENTS_FILE_ACTUAL_PATH"
            log_success "Public key appended."
        fi
    fi
elif $NO_UPDATE_RECIPIENTS_FLAG; then
    log_info "Skipping update to recipients file due to --no-update-recipients flag."
fi


log_info "---------------------------------------------------------------------"
log_success "Additional YubiKey AGE Identity Provisioning Complete for Label: '${LABEL_ARG}'."
log_info "---------------------------------------------------------------------"
log_warn "IMPORTANT: The AGE private key for this identity resides ONLY on this YubiKey and is NON-EXPORTABLE."
log_info "  Identity File (pointer to YK key): ${OUTPUT_IDENTITY_FILE}"
log_info "  Public Key:    ${AGE_PUBLIC_KEY:-Not extracted}"
log_warn "Next Steps:"
log_warn "  1. Back up the identity file ('${OUTPUT_IDENTITY_FILE}'). It's needed for SOPS/AGE to find the key on this YubiKey."
log_warn "  2. If you intend to use this key for SOPS encryption, add the public key to the relevant '.sops.yaml' file(s)."
log_warn "  3. Ensure the user of this YubiKey knows its PIV PIN and stores it securely."

exit 0
