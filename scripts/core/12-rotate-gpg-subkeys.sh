#!/usr/bin/env bash
# scripts/core/12-rotate-gpg-subkeys.sh
# Rotates GPG subkeys for a given master key ID.
# This involves generating new subkeys and expiring the old ones.

SHELL_OPTIONS="set -e -u -o pipefail"
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error when substituting.
# set -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status, or zero if no command exited with a non-zero status.
eval "$SHELL_OPTIONS"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    echo "Usage: $(basename "$0") [MASTER_KEY_ID]"
    echo ""
    echo "This script rotates GPG subkeys (Sign, Encrypt, Authenticate) for a specified master key."
    echo "It generates new subkeys and sets the expiration date of the old ones to now."
    echo "The GPG master private key must be available in the GPG keyring for this operation."
    echo ""
    echo "Arguments (Optional):"
    echo "  [MASTER_KEY_ID]     The GPG Master Key ID to operate on. If not provided, it will be read"
    echo "                      from the file specified by \$GPG_MASTER_KEY_ID_FILE (default: .gpg_master_key_id)."
    echo ""
    echo "Configuration is primarily via environment variables (see .mise.toml):"
    echo "  GPG_MASTER_KEY_ID_FILE: File to read the Master Key ID from if not provided as an argument."
    echo "  TEMP_GNUPGHOME_DIR_NAME: Name of the temporary GPG home directory. If this directory exists"
    echo "                           and contains the master key, it will be used. Otherwise, the default GPG home is used."
    echo "  GPG_EXPIRATION:         Expiration period for the new subkeys (e.g., 1y, 2y)."
    echo "  GPG_KEY_TYPE:           Determines the type of subkeys to generate (RSA4096 or ED25519 based)."
    echo "  GPG_SUBKEY_ROTATION_CHOICE: Which subkeys to rotate ('all', or comma-separated 'sign', 'encrypt', 'auth'). Default: 'all'."
    echo ""
    echo "The script will:"
    echo "  1. Identify the master key and ensure its private part is available."
    echo "  2. Prompt for the master key passphrase."
    echo "  3. List current subkeys."
    echo "  4. For each subkey chosen for rotation (Sign, Encrypt, Authenticate):"
    echo "     a. Expire the old subkey (sets its expiration to now)."
    echo "     b. Generate a new subkey of the same type with the configured expiration."
    echo "  5. Save changes to the GPG keyring."
    echo ""
    echo "IMPORTANT: After running this script, you MUST:"
    echo "  - Update your public key on key servers and distribute it to correspondents."
    echo "  - Re-provision any YubiKeys with the new subkeys using '02-provision-gpg-yubikey.sh' or '05-clone-gpg-yubikey.sh'."
    echo ""
    echo "Make sure 'gpg', 'awk', 'grep', 'date' are installed."
    exit 1
}

# Capture optional Master Key ID argument.
MASTER_KEY_ID_ARG="${1:-}"

# --- Configuration & Environment Variables ---
# File to read Master Key ID from if not provided as an argument.
GPG_MASTER_KEY_ID_FILE="${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}"
# Temporary GPG home directory name.
TEMP_GNUPGHOME_DIR_NAME="${TEMP_GNUPGHOME_DIR_NAME:-.gnupghome_temp_ykm}"
# Expiration for new subkeys.
GPG_EXPIRATION="${GPG_EXPIRATION:-2y}"
# Key type (RSA4096 or ED25519) to determine new subkey algorithms.
GPG_KEY_TYPE="${GPG_KEY_TYPE:-RSA4096}"
# Which subkeys to rotate: 'all', or comma-separated 'sign', 'encrypt', 'auth'.
GPG_SUBKEY_ROTATION_CHOICE_CSV="${GPG_SUBKEY_ROTATION_CHOICE:-all}"

# Resolve full paths.
MASTER_KEY_ID_FILE_PATH="${BASE_DIR}/${GPG_MASTER_KEY_ID_FILE}"
TEMP_GNUPGHOME_PATH="${BASE_DIR}/${TEMP_GNUPGHOME_DIR_NAME}"

# Variable to temporarily hold the GPG master passphrase.
GPG_MASTER_PASSPHRASE=""

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 12-rotate-gpg-subkeys.sh with status $exit_status_for_cleanup"
    # Unset sensitive variable from script memory.
    unset GPG_MASTER_PASSPHRASE
}

log_info "Starting GPG Subkey Rotation Process..."

# --- Prerequisite Checks ---
check_command "gpg"
check_command "awk"
check_command "grep"
check_command "date" # GNU date is preferred for robust date calculations.

# --- Step 1: Determine Master Key ID ---
log_info "Step 1: Identifying GPG Master Key."
MASTER_KEY_ID=""
if [ -n "$MASTER_KEY_ID_ARG" ]; then
    MASTER_KEY_ID="$MASTER_KEY_ID_ARG"
    log_info "Using Master Key ID from argument: $MASTER_KEY_ID"
elif [ -f "$MASTER_KEY_ID_FILE_PATH" ]; then
    MASTER_KEY_ID=$(cat "$MASTER_KEY_ID_FILE_PATH")
    if [ -z "$MASTER_KEY_ID" ]; then
        log_error "Master Key ID file '${MASTER_KEY_ID_FILE_PATH}' is empty."
        usage
    fi
    log_info "Using Master Key ID from file '${MASTER_KEY_ID_FILE_PATH}': $MASTER_KEY_ID"
else
    log_error "Master Key ID not provided as argument and file '${MASTER_KEY_ID_FILE_PATH}' not found."
    usage
fi

# --- Setup GNUPGHOME ---
# This script requires the master private key to be accessible.
# It prefers using the temporary GPG home if it exists and contains the key,
# otherwise, it falls back to the user's default GPG home.
if [ -d "$TEMP_GNUPGHOME_PATH" ]; then
    log_info "Checking for master key in temporary GPG home: ${TEMP_GNUPGHOME_PATH}"
    # Check if the master key's secret part is in the temporary GPG home.
    if GNUPGHOME="${TEMP_GNUPGHOME_PATH}" gpg --no-tty --list-secret-keys "$MASTER_KEY_ID" > /dev/null 2>&1; then
        export GNUPGHOME="${TEMP_GNUPGHOME_PATH}"
        log_info "Using temporary GPG home: $GNUPGHOME (Master key found)"
    else
        log_warn "Master key $MASTER_KEY_ID not found in temporary GPG home. Using default GPG home."
        unset GNUPGHOME # Ensure default GPG home is used by unsetting the variable.
    fi
else
    log_info "Temporary GPG home not found. Using default GPG home (typically ~/.gnupg)."
    unset GNUPGHOME
fi

# Verify that the master private key is indeed available in the chosen GPG home.
if ! gpg --no-tty --list-secret-keys "$MASTER_KEY_ID" > /dev/null 2>&1; then
    log_error "Master private key for ID $MASTER_KEY_ID not found in GPG keyring (GNUPGHOME=${GNUPGHOME:-$HOME/.gnupg})."
    log_error "Subkey rotation requires the master private key. Ensure it's imported or accessible."
    exit 1
fi
log_success "Master private key for ID $MASTER_KEY_ID found."

# --- Step 2: Get Master Key Passphrase ---
log_info "Step 2: Master Key Passphrase."
# The master key passphrase is required to authorize changes to the key (expiring/adding subkeys).
ensure_var_set "GPG_MASTER_PASSPHRASE" "Enter passphrase for GPG Master Key ID '${MASTER_KEY_ID}'" --secure

# --- Step 3: Determine Subkeys to Rotate ---
log_info "Step 3: Determining Subkeys for Rotation."
declare -a SUBKEYS_TO_ROTATE # Array to potentially hold details of subkeys to rotate (not fully utilized in current logic but good for future extension).
ROTATE_SIGN=false
ROTATE_ENCRYPT=false
ROTATE_AUTH=false

# Parse the GPG_SUBKEY_ROTATION_CHOICE_CSV environment variable.
if [[ "$GPG_SUBKEY_ROTATION_CHOICE_CSV" == "all" ]]; then
    ROTATE_SIGN=true
    ROTATE_ENCRYPT=true
    ROTATE_AUTH=true
    log_info "Rotating all subkey types: Sign, Encrypt, Authenticate."
else
    IFS=',' read -r -a CHOICES <<< "$GPG_SUBKEY_ROTATION_CHOICE_CSV"
    for choice in "${CHOICES[@]}"; do
        choice_trimmed=$(echo "$choice" | xargs) # Trim whitespace from choice.
        case "$choice_trimmed" in
            sign) ROTATE_SIGN=true ;;
            encrypt) ROTATE_ENCRYPT=true ;;
            auth) ROTATE_AUTH=true ;;
            *) log_warn "Unknown subkey type in GPG_SUBKEY_ROTATION_CHOICE: '$choice_trimmed'. Ignoring." ;;
        esac
    done
    log_info "Selected for rotation: Sign=${ROTATE_SIGN}, Encrypt=${ROTATE_ENCRYPT}, Authenticate=${ROTATE_AUTH}"
fi

# If no valid subkey types were selected for rotation, exit.
if ! $ROTATE_SIGN && ! $ROTATE_ENCRYPT && ! $ROTATE_AUTH; then
    log_info "No subkey types selected for rotation. Exiting."
    exit 0
fi

# --- List Current Subkeys ---
log_info "Current subkey status for Master Key ID ${MASTER_KEY_ID}:"
gpg --no-tty --list-secret-keys --keyid-format long "$MASTER_KEY_ID"
echo # Newline for readability

# Confirm with the user before proceeding with the rotation.
if ! confirm "Proceed with rotating the selected subkeys for Master Key ID ${MASTER_KEY_ID}?"; then
    log_info "Subkey rotation aborted by user."
    exit 0
fi

# --- Step 4: Build GPG Edit Commands ---
log_info "Step 4: Preparing GPG Commands for Subkey Rotation."
# Start the command string with the master passphrase, which will be piped to GPG.
GPG_EDIT_COMMANDS_STRING="${GPG_MASTER_PASSPHRASE}\n"

# Get details of existing subkeys (keygrip, capabilities, index) using GPG's colon-delimited output.
# This information is used to target specific subkeys for expiration.
SUBKEY_DETAILS=$(gpg --no-tty --with-colons --fixed-list-mode --list-secret-keys --with-keygrip "$MASTER_KEY_ID" | \
    awk -F: -v master_id="$MASTER_KEY_ID" '
        # Identify the start of the master key block.
        $1 == "sec" && $5 == master_id { current_master=1; subkey_idx=0; }
        $1 == "pub" && $5 == master_id { current_master=1; subkey_idx=0; } # Also consider pub line for master
        # Process subkey lines associated with the current master key.
        current_master && ($1 == "sub" || $1 == "ssb") {
            subkey_idx++; # GPG uses 1-based indexing for subkeys in --edit-key.
            keygrip=$10;
            capabilities=$12; # e.g., S, E, A, SEA
            print keygrip ":" capabilities ":" subkey_idx;
        }
        # Reset flag if we move past the current master key block.
        $1 != "sub" && $1 != "ssb" && $1 != "uid" && $1 != "uat" { current_master=0; }
    ')

log_debug "Subkey details from GPG:\n${SUBKEY_DETAILS}"
# Keep track of subkey indices that have already been marked for expiration to avoid processing them multiple times
# if a subkey has multiple capabilities (e.g., SE).
declare -A EXPIRED_SUBKEY_INDICES

# Process Sign (S) subkeys.
if $ROTATE_SIGN; then
    log_info "Processing Sign (S) subkeys..."
    PROCESSED_ONCE=false # Flag to track if any S subkey was found and expired.
    # Iterate through the extracted subkey details.
    while IFS=: read -r keygrip capabilities index; do
        # If the subkey has Sign capability ('S') and hasn't been expired yet.
        if [[ "$capabilities" == *"S"* ]] && [[ -z "${EXPIRED_SUBKEY_INDICES[$index]:-}" ]]; then
            log_info "  Expiring old Sign subkey (index $index, keygrip $keygrip)..."
            # Append GPG commands: select key, expire it (to today), confirm 'y'.
            GPG_EDIT_COMMANDS_STRING+=$(printf "key %s\nexpire\n%s\ny\n" "$index" "$(date +%Y-%m-%d)")
            EXPIRED_SUBKEY_INDICES[$index]=true # Mark as processed.
            PROCESSED_ONCE=true
        fi
    done <<< "$SUBKEY_DETAILS" # Pipe subkey details to the loop.
    # If at least one S subkey was expired OR if no S subkey existed, add a new one.
    if $PROCESSED_ONCE || ! echo "$SUBKEY_DETAILS" | grep -q ":.*S.*:"; then
        log_info "  Adding new Sign subkey..."
        # Append GPG commands to add a new key based on GPG_KEY_TYPE.
        if [[ "$GPG_KEY_TYPE" == "RSA4096" ]]; then GPG_EDIT_COMMANDS_STRING+=$(printf "addkey\n4\n4096\n%s\ny\n" "${GPG_EXPIRATION}"); # RSA Sign
        elif [[ "$GPG_KEY_TYPE" == "ED25519" ]]; then GPG_EDIT_COMMANDS_STRING+=$(printf "addkey\n10\n%s\ny\n" "${GPG_EXPIRATION}"); fi # EdDSA (Sign)
    fi
fi

# Process Encrypt (E) subkeys (similar logic as for Sign).
if $ROTATE_ENCRYPT; then
    log_info "Processing Encrypt (E) subkeys..."
    PROCESSED_ONCE=false
    while IFS=: read -r keygrip capabilities index; do
        if [[ "$capabilities" == *"E"* ]] && [[ -z "${EXPIRED_SUBKEY_INDICES[$index]:-}" ]]; then
            log_info "  Expiring old Encrypt subkey (index $index, keygrip $keygrip)..."
            GPG_EDIT_COMMANDS_STRING+=$(printf "key %s\nexpire\n%s\ny\n" "$index" "$(date +%Y-%m-%d)")
            EXPIRED_SUBKEY_INDICES[$index]=true
            PROCESSED_ONCE=true
        fi
    done <<< "$SUBKEY_DETAILS"
    if $PROCESSED_ONCE || ! echo "$SUBKEY_DETAILS" | grep -q ":.*E.*:"; then
        log_info "  Adding new Encrypt subkey..."
        if [[ "$GPG_KEY_TYPE" == "RSA4096" ]]; then GPG_EDIT_COMMANDS_STRING+=$(printf "addkey\n6\n4096\n%s\ny\n" "${GPG_EXPIRATION}"); # RSA Encrypt
        elif [[ "$GPG_KEY_TYPE" == "ED25519" ]]; then GPG_EDIT_COMMANDS_STRING+=$(printf "addkey\n12\n%s\ny\n" "${GPG_EXPIRATION}"); fi # ECDH (Encrypt)
    fi
fi

# Process Authenticate (A) subkeys (similar logic as for Sign).
if $ROTATE_AUTH; then
    log_info "Processing Authenticate (A) subkeys..."
    PROCESSED_ONCE=false
    while IFS=: read -r keygrip capabilities index; do
        if [[ "$capabilities" == *"A"* ]] && [[ -z "${EXPIRED_SUBKEY_INDICES[$index]:-}" ]]; then
            log_info "  Expiring old Authenticate subkey (index $index, keygrip $keygrip)..."
            GPG_EDIT_COMMANDS_STRING+=$(printf "key %s\nexpire\n%s\ny\n" "$index" "$(date +%Y-%m-%d)")
            EXPIRED_SUBKEY_INDICES[$index]=true
            PROCESSED_ONCE=true
        fi
    done <<< "$SUBKEY_DETAILS"
    if $PROCESSED_ONCE || ! echo "$SUBKEY_DETAILS" | grep -q ":.*A.*:"; then
        log_info "  Adding new Authenticate subkey..."
        if [[ "$GPG_KEY_TYPE" == "RSA4096" ]]; then GPG_EDIT_COMMANDS_STRING+=$(printf "addkey\n5\n4096\n%s\ny\n" "${GPG_EXPIRATION}"); # RSA Auth (custom usage)
        elif [[ "$GPG_KEY_TYPE" == "ED25519" ]]; then GPG_EDIT_COMMANDS_STRING+=$(printf "addkey\n10\n%s\ny\n" "${GPG_EXPIRATION}"); fi # EdDSA (Auth)
    fi
fi

# Final command to save changes in GPG.
GPG_EDIT_COMMANDS_STRING+="save\n"
log_debug "Generated GPG edit commands (passphrase redacted):\n$(printf "%s" "${GPG_EDIT_COMMANDS_STRING}" | sed '1s/.*/\[REDACTED PASSPHRASE]/')"

# --- Step 5: Execute GPG Edit Key ---
log_info "Step 5: Executing Subkey Rotation with GPG."
log_warn "GPG will now process the subkey changes. This may take a moment."
# Pipe the constructed command string to `gpg --edit-key`.
GPG_EXEC_OUTPUT=$(printf "%s" "${GPG_EDIT_COMMANDS_STRING}" | gpg --no-tty --status-fd 1 --pinentry-mode loopback --expert --edit-key "$MASTER_KEY_ID" 2>&1)
GPG_EXEC_EC=$?
unset GPG_MASTER_PASSPHRASE # Unset passphrase from script memory after use.

if [ $GPG_EXEC_EC -ne 0 ]; then
    log_error "GPG subkey rotation failed. gpg Exit Code: $GPG_EXEC_EC"
    log_error "GPG Output:\n${GPG_EXEC_OUTPUT}"
    exit 1
fi

log_success "GPG subkey rotation process completed in GPG keyring."
log_info "Final key status for Master Key ID ${MASTER_KEY_ID}:"
# Display the updated key structure for user verification.
gpg --no-tty --list-secret-keys --keyid-format long "$MASTER_KEY_ID"

log_info "---------------------------------------------------------------------"
log_success "GPG Subkey Rotation Script Finished."
log_info "---------------------------------------------------------------------"
log_warn "CRITICAL NEXT STEPS:"
log_warn "  1. Public Key Update: Your public GPG key has changed (new subkeys added, old ones expired)."
log_warn "     You MUST export your updated public key and distribute it:"
log_warn "       gpg --armor --export ${MASTER_KEY_ID} > my-updated-public-key.asc"
log_warn "     Upload it to key servers (e.g., keys.openpgp.org) and share it with your correspondents."
log_warn "  2. YubiKey Re-provisioning: The new subkeys are currently ONLY in your GPG keyring."
log_warn "     You MUST re-provision any YubiKeys that were using the old subkeys."
log_warn "     Use './scripts/core/02-provision-gpg-yubikey.sh --serial <YOUR_YUBIKEY_SERIAL>' for each YubiKey."
log_warn "     This will involve moving the NEW subkeys to the YubiKey."
log_warn "  3. Backup: Consider creating a new encrypted backup of your GPG directory now that subkeys have changed."
log_warn "Failure to update your public key and re-provision YubiKeys will lead to issues with signing, encryption, and authentication."

exit 0
