#!/usr/bin/env bash
# scripts/core/01-generate-gpg-master-key.sh
# Generates a GPG master key (Certify-Only) and subkeys (Sign, Encrypt, Authenticate).
# This script creates a new GPG identity, including an offline master key and
# operational subkeys, along with a revocation certificate.

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
    echo "Usage: $(basename "$0")"
    echo ""
    echo "This script guides you through generating a new GPG master key and associated subkeys."
    echo "It uses a temporary GPG home directory for isolated key generation."
    echo ""
    echo "Key generation parameters are primarily controlled by environment variables,"
    echo "which can be set in your shell or via a '.env' file loaded by Mise."
    echo "See '.mise.toml' for relevant environment variable names like:"
    echo "  GPG_USER_NAME, GPG_USER_EMAIL, GPG_KEY_COMMENT, GPG_KEY_TYPE, GPG_EXPIRATION,"
    echo "  GPG_REVOCATION_REASON, GPG_MIN_PASSPHRASE_LENGTH."
    echo ""
    echo "The script will:"
    echo "  1. Prompt for User ID components (Name, Email, Comment) if not set in env."
    echo "  2. Securely prompt for a master key passphrase."
    echo "  3. Generate a master key (Certify-Only) and subkeys (Sign, Encrypt, Authenticate)."
    echo "  4. Generate a revocation certificate."
    echo "  5. Store the master key ID in '${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}' in the project root."
    echo "  6. Leave the generated keys in a temporary GPG home ('${TEMP_GNUPGHOME_DIR_NAME:-.gnupghome_temp_ykm}') for subsequent scripts."
    echo ""
    echo "Make sure 'gpg', 'mktemp', 'awk', and 'sed' are installed and in your PATH."
    exit 1
}
# No arguments expected, but -h or --help could trigger usage
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

log_info "Starting GPG Master Key Generation Process..."
log_info "This script will create a new GPG identity."

# --- Configuration & Environment Variables ---
GPG_USER_NAME="${GPG_USER_NAME:-}"
GPG_USER_EMAIL="${GPG_USER_EMAIL:-}"
GPG_KEY_COMMENT="${GPG_KEY_COMMENT:-YubiKey Managed Key}"
GPG_KEY_TYPE="${GPG_KEY_TYPE:-RSA4096}" # RSA4096 or ED25519
GPG_EXPIRATION="${GPG_EXPIRATION:-2y}"
GPG_REVOCATION_REASON_CODE="${GPG_REVOCATION_REASON:-0}" # Default to "0" (No reason specified)
GPG_MASTER_KEY_ID_FILE="${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}" # Relative to project root
TEMP_GNUPGHOME_DIR_NAME="${TEMP_GNUPGHOME_DIR_NAME:-.gnupghome_temp_ykm}" # Relative to project root
GPG_MIN_PASSPHRASE_LENGTH_CONFIG="${GPG_MIN_PASSPHRASE_LENGTH:-12}"


# Resolve full paths for temporary GPG home and master key ID file
TEMP_GNUPGHOME="${BASE_DIR}/${TEMP_GNUPGHOME_DIR_NAME}"
MASTER_KEY_ID_FILE_PATH="${BASE_DIR}/${GPG_MASTER_KEY_ID_FILE}"

# Initialize variables that will hold sensitive data or temporary file paths
# These are cleared in the script_specific_cleanup function.
GPG_BATCH_PARAMS_FILE="" # Initialize for cleanup
GPG_PASSPHRASE=""
GPG_PASSPHRASE_CONFIRM=""

log_debug "Resolved TEMP_GNUPGHOME: ${TEMP_GNUPGHOME}"
log_debug "Resolved MASTER_KEY_ID_FILE_PATH: ${MASTER_KEY_ID_FILE_PATH}"
log_debug "GPG_KEY_TYPE: ${GPG_KEY_TYPE}, GPG_EXPIRATION: ${GPG_EXPIRATION}"
log_debug "GPG_REVOCATION_REASON_CODE: ${GPG_REVOCATION_REASON_CODE}"

# --- Prerequisite Checks ---
check_command "gpg"
check_command "mktemp"
check_command "awk"
check_command "sed"

# --- Ensure User Details are Provided ---
log_info "Step 1: Gathering User Information for GPG Key."
ensure_var_set "GPG_USER_NAME" "Enter your Full Name (e.g., John Doe) for the GPG key's User ID"
ensure_var_set "GPG_USER_EMAIL" "Enter your Email Address (e.g., john.doe@example.com) for the GPG key's User ID"
if [ -z "${GPG_KEY_COMMENT}" ]; then
    get_input "Enter an optional Comment (e.g., 'Work Key', press Enter to skip): " GPG_KEY_COMMENT
fi
log_info "GPG User ID will be: ${GPG_USER_NAME} (${GPG_KEY_COMMENT}) <${GPG_USER_EMAIL}>"
log_info "Key Type: ${GPG_KEY_TYPE}, Expiration: ${GPG_EXPIRATION}"
log_debug "Final User ID components - Name: '${GPG_USER_NAME}', Email: '${GPG_USER_EMAIL}', Comment: '${GPG_KEY_COMMENT}'"


# --- Script Specific Cleanup Function ---
# This function is registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    # This log message helps trace when cleanup is invoked, especially with file logging.
    log_debug "Running script_specific_cleanup for 01-generate-gpg-master-key.sh with status $exit_status_for_cleanup"

    if [ -n "${GPG_BATCH_PARAMS_FILE:-}" ] && [ -f "${GPG_BATCH_PARAMS_FILE}" ]; then
        log_debug "Removing temporary GPG batch parameters file: ${GPG_BATCH_PARAMS_FILE}"
        shred -u "${GPG_BATCH_PARAMS_FILE}" 2>/dev/null || rm -f "${GPG_BATCH_PARAMS_FILE}"
    fi
    unset GPG_PASSPHRASE
    unset GPG_PASSPHRASE_CONFIRM
    # If the script errored out before successfully creating the master key ID file,
    # and a temporary GPG home was created, clean it up to prevent leaving partial state.
    if [ "$exit_status_for_cleanup" -ne 0 ] && [ ! -f "${MASTER_KEY_ID_FILE_PATH}" ] && [ -d "${TEMP_GNUPGHOME}" ]; then
        log_warn "Cleaning up temporary GPG home (${TEMP_GNUPGHOME}) due to error before completion."
        rm -rf "${TEMP_GNUPGHOME}"
    fi
}

# --- Input Validation: Key Type ---
if [[ "${GPG_KEY_TYPE}" != "RSA4096" && "${GPG_KEY_TYPE}" != "ED25519" ]]; then
    log_error "Invalid GPG_KEY_TYPE: '${GPG_KEY_TYPE}'. Must be 'RSA4096' or 'ED25519'."
    exit 1
fi

# --- Input Validation: Expiration ---
if ! [[ "${GPG_EXPIRATION}" =~ ^[0-9]+[yYmMwWdD]?$ ]]; then
    log_warn "GPG_EXPIRATION format ('${GPG_EXPIRATION}') is unusual. GPG will validate it. Common formats: '0' (no expiration), '1y', '2m', '3w', '10d'."
fi

# --- Step 1b: Check for Existing Key in Default GPG Home (Informational) ---
log_info "Step 1b: Checking Default GPG Keyring for Existing Key (Informational)."
ORIGINAL_GNUPGHOME_WAS_SET=false
ORIGINAL_GNUPGHOME_VALUE=""
if [ -n "${GNUPGHOME:-}" ]; then
    ORIGINAL_GNUPGHOME_WAS_SET=true
    ORIGINAL_GNUPGHOME_VALUE="$GNUPGHOME"
    unset GNUPGHOME # Temporarily unset to check default keyring
    log_debug "Temporarily unset GNUPGHOME to check default keyring."
fi

if gpg --no-tty --list-keys "${GPG_USER_EMAIL}" >/dev/null 2>&1; then
    log_warn "An existing GPG key for UID '${GPG_USER_EMAIL}' was found in your DEFAULT GPG keyring."
    log_warn "This script will generate NEW keys in an ISOLATED temporary environment ('${TEMP_GNUPGHOME_DIR_NAME}')."
    log_warn "These new keys will NOT affect your default keyring unless you manually import them later."
    log_warn "However, having multiple keys with the same UID can lead to confusion."
    if ! confirm "Do you want to proceed with generating NEW keys for this UID in the isolated environment?"; then
        log_error "Key generation aborted by user due to existing key in default GPG keyring."
        # Restore GNUPGHOME if it was originally set
        if $ORIGINAL_GNUPGHOME_WAS_SET; then export GNUPGHOME="$ORIGINAL_GNUPGHOME_VALUE"; fi
        exit 1
    fi
fi

# Restore GNUPGHOME if it was originally set, before we explicitly set it for the temporary dir
if $ORIGINAL_GNUPGHOME_WAS_SET; then
    export GNUPGHOME="$ORIGINAL_GNUPGHOME_VALUE"
    log_debug "Restored original GNUPGHOME value."
fi

# --- Idempotency Check & Temporary GPG Home ---
log_info "Step 2: Preparing Temporary GPG Environment."
log_info "Using temporary GPG home: ${TEMP_GNUPGHOME}"
# Create the temporary GPG home directory with restricted permissions (700).
if ! mkdir -p "${TEMP_GNUPGHOME}"; then log_error "Failed to create temporary GPG home: ${TEMP_GNUPGHOME}"; exit 1; fi
if ! chmod 700 "${TEMP_GNUPGHOME}"; then log_error "Failed to set permissions on ${TEMP_GNUPGHOME}"; rm -rf "${TEMP_GNUPGHOME}"; exit 1; fi
# Export GNUPGHOME so subsequent GPG commands operate within this isolated environment.
export GNUPGHOME="${TEMP_GNUPGHOME}"
log_debug "Exported GNUPGHOME=${GNUPGHOME}"

# Check if a master key ID file already exists, indicating a previous run.
if [ -f "${MASTER_KEY_ID_FILE_PATH}" ]; then
    EXISTING_KEY_ID=$(cat "${MASTER_KEY_ID_FILE_PATH}")
    log_warn "A GPG master key ID file already exists: ${MASTER_KEY_ID_FILE_PATH}"
    log_warn "This file indicates a master key (ID: ${EXISTING_KEY_ID}) might have been generated previously by this script."
    # Offer the user a choice to skip or proceed with new generation.
    if confirm "Do you want to SKIP generating a new GPG key and assume the existing one is ready for subsequent steps?"; then
        log_info "Skipping GPG key generation as per user request. Using existing key ID: ${EXISTING_KEY_ID}."
        log_warn "Ensure the keys for this ID are present in '${TEMP_GNUPGHOME}' or your main GPG keyring if you intend to use them with other scripts."
        exit 0
    else
        log_info "Proceeding with new key generation. The existing ID file '${MASTER_KEY_ID_FILE_PATH}' will be overwritten upon success."
    fi
fi

# Check if a key for the specified email already exists within the *temporary* GPG home.
if gpg --no-tty --list-keys "${GPG_USER_EMAIL}" >/dev/null 2>&1; then
    log_warn "A GPG key for UID '${GPG_USER_EMAIL}' already exists in the temporary GPG home: ${TEMP_GNUPGHOME}."
    log_warn "This is unexpected if starting fresh. It might be from a previous interrupted run."
    if ! confirm "Do you want to continue with key generation? This might create a duplicate key for this UID in the temporary GPG home."; then
        log_error "Key generation aborted by user due to existing key in temporary GPG home."
        exit 1
    fi
fi

# --- Securely Get Passphrase ---
log_info "Step 3: Setting Master Key Passphrase."
log_info "You will now be prompted to enter a strong passphrase for your new GPG master key."
log_warn "Choose a unique, long, and complex passphrase. This passphrase protects your master key."
log_warn "It is CRITICAL that you remember this passphrase. Store it securely (e.g., in a reputable password manager)."
# Loop until a valid passphrase (meeting length or user override) and confirmation match.
while true; do
    get_secure_input "Enter master key passphrase (min ${GPG_MIN_PASSPHRASE_LENGTH_CONFIG} chars recommended): " GPG_PASSPHRASE
    if [ "${#GPG_PASSPHRASE}" -lt "${GPG_MIN_PASSPHRASE_LENGTH_CONFIG}" ]; then
        log_warn "Passphrase is less than ${GPG_MIN_PASSPHRASE_LENGTH_CONFIG} characters. This is not recommended for a master key."
        if ! confirm "Are you sure you want to continue with this shorter passphrase?"; then GPG_PASSPHRASE=""; continue; fi
    fi
    if [ -z "$GPG_PASSPHRASE" ]; then log_warn "Passphrase cannot be empty."; continue; fi
    get_secure_input "Confirm passphrase: " GPG_PASSPHRASE_CONFIRM
    if [ "$GPG_PASSPHRASE" == "$GPG_PASSPHRASE_CONFIRM" ]; then break;
    else log_warn "Passphrases do not match. Please try again."; fi
done
unset GPG_PASSPHRASE_CONFIRM
log_success "Passphrase accepted."

# --- Prepare GPG Batch Parameters ---
log_info "Step 4: Preparing GPG Key Generation Parameters."
# Create a temporary file to hold GPG batch parameters. This avoids passing sensitive info like passphrases directly on the command line.
GPG_BATCH_PARAMS_FILE=$(mktemp "${TEMP_GNUPGHOME}/gpg_batch_params.XXXXXX")
if [ -z "$GPG_BATCH_PARAMS_FILE" ] || [ ! -f "$GPG_BATCH_PARAMS_FILE" ]; then log_error "Failed to create temp file for GPG batch params."; exit 1; fi
chmod 600 "${GPG_BATCH_PARAMS_FILE}"

# Construct batch parameters (passphrase is not logged here for security)
BATCH_CONTENT=$(cat <<EOF
%echo Generating GPG Key
Key-Type: ${GPG_KEY_TYPE%%[0-9]*}
Key-Length: ${GPG_KEY_TYPE//[!0-9]/}
Key-Usage: cert
Name-Real: ${GPG_USER_NAME}
Name-Email: ${GPG_USER_EMAIL}
Name-Comment: ${GPG_KEY_COMMENT}
Expire-Date: ${GPG_EXPIRATION}
Passphrase: ${GPG_PASSPHRASE}
%commit
%echo done
EOF
)
echo "${BATCH_CONTENT}" > "${GPG_BATCH_PARAMS_FILE}"
log_debug "GPG Batch Parameters File created at: ${GPG_BATCH_PARAMS_FILE}"
# Log content without passphrase for debugging
log_debug "GPG Batch Parameters Content (passphrase redacted):\n$(echo "${BATCH_CONTENT}" | sed 's/^Passphrase: .*$/Passphrase: \[REDACTED]/')"


# For ED25519 keys, GPG does not expect/use Key-Length, so remove it from batch params.
if [[ "${GPG_KEY_TYPE}" == "ED25519" ]]; then
    if ! sed -i '/^Key-Length: $/d' "${GPG_BATCH_PARAMS_FILE}"; then log_error "Failed to modify GPG batch params for ED25519."; exit 1; fi
    log_debug "Modified GPG batch params for ED25519 (removed Key-Length)."
fi

# --- Generate Master Key ---
log_info "Step 5: Generating GPG Master Key (Certify-Only)."
log_info "This may take a few minutes depending on system entropy..."
# Use --batch to enable non-interactive mode, reading parameters from the file.
# --status-fd 1 sends machine-readable status messages to stdout, useful for parsing success/failure.
GPG_GEN_OUTPUT=$(gpg --no-tty --batch --yes --status-fd 1 --full-generate-key "${GPG_BATCH_PARAMS_FILE}" 2>&1)
GPG_GEN_EXIT_CODE=$?
log_debug "gpg --full-generate-key output (EC:${GPG_GEN_EXIT_CODE}):\n${GPG_GEN_OUTPUT}"
# Securely delete the batch parameters file immediately after use.
shred -u "${GPG_BATCH_PARAMS_FILE}" 2>/dev/null || rm -f "${GPG_BATCH_PARAMS_FILE}"; GPG_BATCH_PARAMS_FILE=""

# Check for successful key creation based on exit code and GPG status messages.
if [ $GPG_GEN_EXIT_CODE -ne 0 ] || ! echo "${GPG_GEN_OUTPUT}" | grep -q "KEY_CREATED"; then
    log_error "GPG master key generation failed. GPG Exit Code: $GPG_GEN_EXIT_CODE"
    log_error "GPG Output:\n${GPG_GEN_OUTPUT}"
    exit 1
fi
log_success "GPG master key generated successfully."

# Extract the newly generated Master Key ID using GPG's colon-delimited output format.
MASTER_KEY_ID=$(gpg --no-tty --list-secret-keys --with-colons "${GPG_USER_EMAIL}" | awk -F: '/^sec:/ { print $5; exit }')
if [ -z "${MASTER_KEY_ID}" ]; then log_error "Could not retrieve the Master Key ID for ${GPG_USER_EMAIL}."; exit 1; fi
log_success "Generated Master Key ID: ${MASTER_KEY_ID}"
log_debug "Extracted MASTER_KEY_ID: ${MASTER_KEY_ID}"

# --- Add Subkeys (Sign, Encrypt, Authenticate) ---
log_info "Step 6: Adding Sign, Encrypt, and Authenticate Subkeys."

# Construct the command sequence to be piped to gpg
build_subkey_commands() {
    printf "%s\n" "${GPG_PASSPHRASE}"
    if [[ "${GPG_KEY_TYPE}" == "RSA4096" ]]; then
        printf "addkey\n"
        printf "4\n" # RSA (sign only)
        printf "4096\n"
        printf "%s\n" "${GPG_EXPIRATION}"
        printf "y\n" # Confirm
        printf "addkey\n"
        printf "6\n" # RSA (encrypt only)
        printf "4096\n"
        printf "%s\n" "${GPG_EXPIRATION}"
        printf "y\n" # Confirm
        printf "addkey\n"
        printf "5\n" # RSA (set your own capabilities) -> then choose A for Authenticate
        printf "4096\n"
        printf "%s\n" "${GPG_EXPIRATION}"
        printf "y\n" # Confirm
    elif [[ "${GPG_KEY_TYPE}" == "ED25519" ]]; then
        printf "addkey\n"
        printf "10\n" # ECC (sign only) -> EdDSA
        printf "%s\n" "${GPG_EXPIRATION}"
        printf "y\n" # Confirm
        printf "addkey\n"
        printf "12\n" # ECC (encrypt only) -> ECDH
        printf "%s\n" "${GPG_EXPIRATION}"
        printf "y\n" # Confirm
        printf "addkey\n"
        printf "10\n" # ECC (sign only) -> EdDSA again for Authentication capability
        printf "%s\n" "${GPG_EXPIRATION}"
        printf "y\n" # Confirm
    fi
    printf "save\n"
}

# Use --command-fd 0 to pipe commands to GPG.
# --pinentry-mode loopback allows passphrase to be piped.
GPG_EDIT_OUTPUT=$(build_subkey_commands | gpg --no-tty --command-fd 0 --status-fd 1 --pinentry-mode loopback --expert --edit-key "${MASTER_KEY_ID}" 2>&1)
GPG_EDIT_EXIT_CODE=$?
log_debug "gpg --edit-key for subkeys output (EC:${GPG_EDIT_EXIT_CODE}):\n${GPG_EDIT_OUTPUT}"
if [ $GPG_EDIT_EXIT_CODE -ne 0 ] || ! echo "${GPG_EDIT_OUTPUT}" | grep -q "save"; then
    log_error "Failed to add GPG subkeys. GPG Exit Code: $GPG_EDIT_EXIT_CODE"
    log_error "GPG Edit Output:\n${GPG_EDIT_OUTPUT}"
    gpg --no-tty --list-secret-keys "${MASTER_KEY_ID}"
    exit 1
fi
log_success "Sign, Encrypt, and Authenticate subkeys added."
log_info "Current key structure:"
# Display the final key structure for user verification.
gpg --no-tty --list-secret-keys "${MASTER_KEY_ID}"

# --- Generate Revocation Certificate ---
log_info "Step 7: Generating Revocation Certificate."
REVOCATION_CERT_FILE="${BASE_DIR}/revocation-certificate-${MASTER_KEY_ID}.asc"
log_debug "Revocation certificate will be saved to: ${REVOCATION_CERT_FILE}"

# If revocation reason is "0" (No reason specified), optionally prompt for a description.
REVOCATION_REASON_TEXT="" # Optional text for reason 0
if [[ "$GPG_REVOCATION_REASON_CODE" == "0" ]]; then
    get_input "Enter optional description for revocation (or press Enter for none): " REVOCATION_REASON_TEXT
    log_debug "Revocation reason text (for code 0): '${REVOCATION_REASON_TEXT}'"
fi

# Construct the input for gpg --gen-revoke
# This includes the passphrase, reason code, optional text, and confirmations.
GPG_REVOKE_INPUT_STRING="${GPG_PASSPHRASE}\n${GPG_REVOCATION_REASON_CODE}\n${REVOCATION_REASON_TEXT}\ny\ny\n"
log_debug "GPG revoke input (passphrase redacted):\n$(printf "%s" "${GPG_REVOKE_INPUT_STRING}" | sed '1s/.*/\[REDACTED PASSPHRASE]/')"
GPG_REVOKE_OUTPUT=$(printf "%s" "${GPG_REVOKE_INPUT_STRING}" | gpg --no-tty --command-fd 0 --status-fd 1 --pinentry-mode loopback --output "${REVOCATION_CERT_FILE}" --gen-revoke "${MASTER_KEY_ID}" 2>&1)
GPG_REVOKE_EXIT_CODE=$?
log_debug "gpg --gen-revoke output (EC:${GPG_REVOKE_EXIT_CODE}):\n${GPG_REVOKE_OUTPUT}"
unset GPG_PASSPHRASE # Unset passphrase from script memory immediately after use.


if [ $GPG_REVOKE_EXIT_CODE -ne 0 ] || [ ! -s "${REVOCATION_CERT_FILE}" ]; then
    log_error "Failed to generate revocation certificate. GPG Exit Code: $GPG_REVOKE_EXIT_CODE"
    log_error "GPG Revoke Output:\n${GPG_REVOKE_OUTPUT}"
    [ -f "${REVOCATION_CERT_FILE}" ] && rm -f "${REVOCATION_CERT_FILE}"
    exit 1
fi
log_success "Revocation certificate generated: ${REVOCATION_CERT_FILE}"
log_warn "CRITICAL: Securely back up this revocation certificate (${REVOCATION_CERT_FILE})."
log_warn "Store it in multiple, secure, OFFLINE locations, separate from your master key backup."
log_warn "This certificate is used to declare your master key invalid if it is ever compromised."

# --- Store Master Key ID ---
log_info "Step 8: Storing Master Key ID."
# Save the Master Key ID to a file for easy reference by other scripts.
echo "${MASTER_KEY_ID}" > "${MASTER_KEY_ID_FILE_PATH}"
log_success "Master Key ID (${MASTER_KEY_ID}) stored in ${MASTER_KEY_ID_FILE_PATH}"

log_info "---------------------------------------------------------------------"
log_success "GPG Key Generation Process Complete!"
log_info "---------------------------------------------------------------------"
log_info "Summary:"
log_info "  - Master Key ID: ${MASTER_KEY_ID}"
log_info "  - Keys generated in temporary GPG home: ${TEMP_GNUPGHOME}"
log_info "  - Revocation certificate: ${REVOCATION_CERT_FILE}"
log_info "  - Master Key ID file: ${MASTER_KEY_ID_FILE_PATH}"
log_warn "Next Steps:"
log_warn "  1. VERY IMPORTANT: Remember the master key passphrase you set. It has been unset from script memory."
log_warn "  2. Securely back up the revocation certificate (${REVOCATION_CERT_FILE})."
log_warn "  3. Run '03-backup-gpg-master-key.sh' to export and guide the backup of your GPG master private key from '${TEMP_GNUPGHOME}'."
log_warn "  4. After backing up, you can proceed to provision a YubiKey using '02-provision-gpg-yubikey.sh'."
log_warn "  5. The temporary GPG home ('${TEMP_GNUPGHOME}') contains the full private master key and subkeys. It will NOT be automatically deleted by this script on success, to allow other scripts to use it. Use 'mise run clean-temp-gpg' to remove it later if desired, AFTER backing up."

exit 0
