#!/usr/bin/env bash
# scripts/core/01-generate-age-keypair.sh
# Generates a software-based AGE keypair and encrypts the private key with a passphrase.

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
    echo "This script generates a new software-based AGE keypair."
    echo "The private key is then encrypted using AGE's passphrase encryption."
    echo ""
    echo "Configuration is primarily via environment variables (see .mise.toml):"
    echo "  AGE_SOFTWARE_KEY_DIR:      Directory to store the key files (default: keys)."
    echo "  AGE_SOFTWARE_KEY_FILENAME: Filename for the private key (default: age-keys-primary.txt)."
    echo "  AGE_SOFTWARE_KEY_MIN_PASSPHRASE_LENGTH: Recommended min passphrase length (default: 12)."
    echo ""
    echo "The script will:"
    echo "  1. Check if the private key file already exists; if so, it skips generation."
    echo "  2. Generate a new AGE keypair if needed."
    echo "  3. Securely prompt for a passphrase to encrypt the private key."
    echo "  4. Encrypt the private key, saving it as an ASCII-armored AGE encrypted file (e.g., age-keys-primary.txt.age)."
    echo "  5. Output the public key."
    echo ""
    echo "Make sure 'age' and 'age-keygen' are installed and in your PATH."
    exit 1
}
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

log_info "Starting Software-based AGE Keypair Generation Process..."

# --- Configuration & Environment Variables ---
# Directory to store the generated key files, relative to the project root.
AGE_SOFTWARE_KEY_DIR="${AGE_SOFTWARE_KEY_DIR:-keys}" # Relative to project root
# Filename for the (initially plaintext, then encrypted) private key.
AGE_SOFTWARE_KEY_FILENAME="${AGE_SOFTWARE_KEY_FILENAME:-age-keys-primary.txt}"
# Recommended minimum passphrase length for encrypting the private key.
# This is now informational as 'age' handles its own prompting and validation.
# AGE_SOFTWARE_KEY_MIN_PASSPHRASE_LENGTH="${AGE_SOFTWARE_KEY_MIN_PASSPHRASE_LENGTH:-12}"

# Resolve full paths for key storage.
KEY_DIR_PATH="${BASE_DIR}/${AGE_SOFTWARE_KEY_DIR}"
PLAINTEXT_KEY_FILE="${KEY_DIR_PATH}/${AGE_SOFTWARE_KEY_FILENAME}"
ENCRYPTED_KEY_FILE="${PLAINTEXT_KEY_FILE}.age" # Convention for AGE encrypted file

# Variables to temporarily hold the passphrase for encrypting the AGE key.
# These are no longer used by the script for prompting but kept for cleanup consistency.
AGE_PASSPHRASE=""
AGE_PASSPHRASE_CONFIRM=""

# --- Script Specific Cleanup ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 01-generate-age-keypair.sh with status $exit_status_for_cleanup"
    # Unset sensitive variables (though not directly used for prompting anymore)
    unset AGE_PASSPHRASE
    unset AGE_PASSPHRASE_CONFIRM
    # If script failed AND the encrypted key file was not created, remove the plaintext key if it exists
    if [ "$exit_status_for_cleanup" -ne 0 ] && [ ! -f "${ENCRYPTED_KEY_FILE}" ] && [ -f "${PLAINTEXT_KEY_FILE}" ]; then
        log_warn "Removing plaintext AGE key file '${PLAINTEXT_KEY_FILE}' due to script error before encryption."
        shred -u "${PLAINTEXT_KEY_FILE}" 2>/dev/null || rm -f "${PLAINTEXT_KEY_FILE}"
    fi
}

# --- Prerequisite Checks ---
check_command "age"
check_command "age-keygen"
check_command "mkdir"
check_command "chmod"
check_command "shred" # For secure deletion

# --- Step 1: Prepare Key Storage Directory ---
log_info "Step 1: Preparing Key Storage Directory."
if ! mkdir -p "${KEY_DIR_PATH}"; then
    log_error "Failed to create key directory: ${KEY_DIR_PATH}"
    exit 1
fi
log_info "AGE key files will be stored in: ${KEY_DIR_PATH}"

# --- Step 2: Generate AGE Keypair (with Idempotency Check) ---
log_info "Step 2: Generating AGE Keypair (if it doesn't exist)."
# Check if either the plaintext (unlikely to persist) or encrypted key file already exists.
if [[ -f "$PLAINTEXT_KEY_FILE" ]] || [[ -f "$ENCRYPTED_KEY_FILE" ]]; then
    log_warn "An AGE key file ('${PLAINTEXT_KEY_FILE}' or '${ENCRYPTED_KEY_FILE}') already exists."
    if confirm "Do you want to skip generation and use the existing key file(s)?"; then
        log_info "Skipping AGE key generation as per user request."
        # Warn if plaintext exists but encrypted does not, as this is an insecure state.
        if [[ -f "$PLAINTEXT_KEY_FILE" ]] && [[ ! -f "$ENCRYPTED_KEY_FILE" ]]; then
            log_warn "Plaintext key file '${PLAINTEXT_KEY_FILE}' exists but encrypted version '${ENCRYPTED_KEY_FILE}' does not."
            log_warn "You might need to run this script again and choose to re-encrypt, or encrypt it manually."
        fi
        exit 0
    else
        log_info "Proceeding with new key generation. Existing files may be overwritten if names conflict."
        # Note: This script will overwrite if names conflict after this confirmation.
    fi
fi

log_info "Generating new AGE keypair into: ${PLAINTEXT_KEY_FILE}"
AGE_KEYGEN_OUTPUT=$(age-keygen -o "${PLAINTEXT_KEY_FILE}" 2>&1)
# `age-keygen -o <file>` generates a new keypair and writes the private key to <file>.
AGE_KEYGEN_EC=$?
if [ $AGE_KEYGEN_EC -ne 0 ] || [ ! -s "${PLAINTEXT_KEY_FILE}" ]; then
    log_error "Failed to generate AGE key. age-keygen Exit Code: $AGE_KEYGEN_EC"
    log_error "age-keygen Output:\n${AGE_KEYGEN_OUTPUT}"
    [ -f "${PLAINTEXT_KEY_FILE}" ] && rm -f "${PLAINTEXT_KEY_FILE}" # Clean up partial file
    exit 1
fi

# Set restrictive permissions on the plaintext private key file.
if ! chmod 600 "${PLAINTEXT_KEY_FILE}"; then
    log_warn "Failed to set permissions (chmod 600) on plaintext key file: ${PLAINTEXT_KEY_FILE}. Please set manually."
fi
log_success "Plaintext AGE keypair generated: ${PLAINTEXT_KEY_FILE}"
log_warn "IMPORTANT: This plaintext key file is highly sensitive and will be encrypted next."

# --- Extract Public Key ---
# `age-keygen -y <private_key_file>` extracts the public key from a private key file.
log_info "Step 3: Extracting Public Key."
PUBLIC_KEY="$(age-keygen -y "${PLAINTEXT_KEY_FILE}")"
if [[ -z "$PUBLIC_KEY" ]]; then
    log_error "Could not extract public key from ${PLAINTEXT_KEY_FILE}."
    exit 1
fi
log_success "AGE Public Key: ${PUBLIC_KEY}"
log_warn "IMPORTANT: Add this public key to your .sops.yaml 'age:' recipients list if you intend to use it with SOPS."

# --- Encrypt Private Key ---
# The plaintext private key is encrypted using AGE's passphrase-based encryption.
log_info "Step 4: Encrypting the Private Key with a Passphrase."
log_info "You will now be prompted by the 'age' tool to enter a passphrase for encrypting the private key."
log_warn "This passphrase is CRITICAL. If lost, you will NOT be able to decrypt the AGE key file."
log_warn "Store this passphrase securely and separately from the encrypted key file."
log_info "The 'age' tool will handle the passphrase entry directly."

# Encrypt the private key file using age
log_info "Encrypting '${PLAINTEXT_KEY_FILE}' to '${ENCRYPTED_KEY_FILE}'..."
# `age -p -o <output> <input>` encrypts <input> to <output> using a passphrase prompted by age.
# `--armor` is default for passphrase encryption.
if ! AGE_ENCRYPT_OUTPUT=$(age -p -o "${ENCRYPTED_KEY_FILE}" "${PLAINTEXT_KEY_FILE}" 2>&1); then
    log_error "Failed to encrypt AGE private key. AGE EC: $?"
    log_error "AGE Output:\n${AGE_ENCRYPT_OUTPUT}"
    exit 1
fi

log_success "AGE private key encrypted and saved to: ${ENCRYPTED_KEY_FILE}"

# --- Securely Delete Plaintext Private Key ---
log_info "Step 5: Securely Deleting Plaintext Private Key."
# `shred -u` overwrites the file multiple times and then unlinks (deletes) it.
if shred -u "${PLAINTEXT_KEY_FILE}"; then
    log_success "Plaintext private key file '${PLAINTEXT_KEY_FILE}' securely deleted."
else
    log_warn "shred command failed for '${PLAINTEXT_KEY_FILE}'. Attempting normal rm..."
    if rm -f "${PLAINTEXT_KEY_FILE}"; then
        log_success "Plaintext private key file '${PLAINTEXT_KEY_FILE}' deleted (standard rm)."
    else
        log_error "CRITICAL: Failed to delete plaintext private key file '${PLAINTEXT_KEY_FILE}'."
        log_error "Please delete it manually and securely IMMEDIATELY."
    fi
fi

log_info "---------------------------------------------------------------------"
log_success "Software-based AGE Keypair Generation and Encryption Complete!"
log_info "---------------------------------------------------------------------"
log_info "Summary:"
log_info "  - Public Key: ${PUBLIC_KEY}"
log_info "  - Encrypted Private Key File: ${ENCRYPTED_KEY_FILE}"
log_warn "Next Steps:"
log_warn "  1. VERY IMPORTANT: Remember the passphrase you entered when prompted by 'age' to encrypt the private key."
log_warn "  2. Securely back up the encrypted private key file ('${ENCRYPTED_KEY_FILE}')."
log_warn "  3. If using with SOPS, add the public key ('${PUBLIC_KEY}') to your '.sops.yaml'."
log_warn "  4. Set the SOPS_AGE_KEY_FILE environment variable to point to the encrypted private key file ('${ENCRYPTED_KEY_FILE}')."
log_warn "     When SOPS/AGE attempts decryption, you will be prompted for the passphrase you just set."

exit 0
