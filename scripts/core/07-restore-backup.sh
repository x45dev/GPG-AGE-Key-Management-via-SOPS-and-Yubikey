#!/usr/bin/env bash
# scripts/core/07-restore-backup.sh
# Decrypts and extracts an encrypted backup archive created by 06-create-encrypted-backup.sh.

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
    echo "Usage: $(basename "$0") <encrypted_backup_file_path>"
    echo ""
    echo "This script decrypts an AGE-encrypted backup archive (typically a .tar.gz.age file)"
    echo "and extracts its contents to a specified output directory."
    echo ""
    echo "Arguments:"
    echo "  <encrypted_backup_file_path>  Path to the .tar.gz.age encrypted backup file."
    echo ""
    echo "Configuration is primarily via environment variables (see .mise.toml):"
    echo "  RESTORE_OUTPUT_DIR:       Directory to extract restored files (default: restored_backup_files)."
    echo "                              This directory will be created if it doesn't exist."
    echo "  RESTORE_AGE_IDENTITY_FILE: Path to the AGE identity file needed for decryption."
    echo "                              Defaults to SOPS_AGE_KEY_FILE if set, otherwise age uses its defaults or prompts."
    echo "                              If using a YubiKey, ensure it's connected and the correct identity file is specified."
    echo ""
    echo "The script will:"
    echo "  1. Validate the provided backup file path."
    echo "  2. Prompt for confirmation if the restore directory already exists."
    echo "  3. Decrypt the archive using AGE."
    echo "  4. Extract the contents of the decrypted tarball to the restore directory."
    echo "  5. Securely delete the intermediate decrypted tarball."
    echo ""
    echo "Make sure 'age', 'tar', 'mkdir', 'rm', 'shred' are installed."
    exit 1
}

# Capture the first argument as the path to the encrypted backup file.
ENCRYPTED_BACKUP_FILE_ARG="${1:-}"

if [[ "$ENCRYPTED_BACKUP_FILE_ARG" == "-h" || "$ENCRYPTED_BACKUP_FILE_ARG" == "--help" ]]; then
    usage
fi
if [ -z "$ENCRYPTED_BACKUP_FILE_ARG" ]; then
    log_error "Missing argument: Path to the encrypted backup file."
    usage
fi

log_info "Starting Backup Restoration Process..."

# --- Configuration & Environment Variables ---
# Directory name for restored files, configurable via environment variable.
RESTORE_OUTPUT_DIR_NAME="${RESTORE_OUTPUT_DIR:-restored_backup_files}" # Relative to project root
# Path to the AGE identity file for decryption. Falls back to SOPS_AGE_KEY_FILE if set, otherwise AGE defaults.
RESTORE_AGE_IDENTITY_FILE_PATH="${RESTORE_AGE_IDENTITY_FILE:-${SOPS_AGE_KEY_FILE:-}}"

# Construct full paths for restore directory and temporary decrypted tarball.
RESTORE_DIR_PATH="${BASE_DIR}/${RESTORE_OUTPUT_DIR_NAME}"
DECRYPTED_TARBALL_PATH="${RESTORE_DIR_PATH}/decrypted_backup_archive.tar.gz" # Temporary path for the decrypted tarball

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 07-restore-backup.sh with status $exit_status_for_cleanup"

    # Securely delete the intermediate decrypted tarball if it still exists.
    # This is crucial to prevent leaving unencrypted sensitive data on disk.
    if [ -f "${DECRYPTED_TARBALL_PATH}" ]; then
        log_warn "Cleaning up intermediate decrypted tarball: ${DECRYPTED_TARBALL_PATH}"
        shred -u "${DECRYPTED_TARBALL_PATH}" 2>/dev/null || rm -f "${DECRYPTED_TARBALL_PATH}"
    fi
}

# --- Prerequisite Checks ---
check_command "age"
check_command "tar"
check_command "mkdir"
check_command "rm"
check_command "shred" # For secure deletion of the intermediate decrypted tarball

# --- Step 1: Validate Backup File and Restore Directory ---
log_info "Step 1: Validating Backup File and Restore Directory."
if [ ! -f "$ENCRYPTED_BACKUP_FILE_ARG" ]; then
    log_error "Encrypted backup file not found: $ENCRYPTED_BACKUP_FILE_ARG"
    exit 1
fi
log_info "Using encrypted backup file: $ENCRYPTED_BACKUP_FILE_ARG"

# Check if the restore directory already exists and prompt for confirmation if it does.
if [ -d "$RESTORE_DIR_PATH" ]; then
    log_warn "Restore directory '${RESTORE_DIR_PATH}' already exists."
    if ! confirm "Do you want to proceed? Existing files in this directory might be overwritten by the backup."; then
        log_info "Restore process aborted by user."
        exit 0
    fi
    log_info "Proceeding with existing restore directory."
else
    # Create the restore directory if it doesn't exist.
    if ! mkdir -p "$RESTORE_DIR_PATH"; then
        log_error "Failed to create restore directory: $RESTORE_DIR_PATH"
        exit 1
    fi
    log_info "Created restore directory: $RESTORE_DIR_PATH"
fi

# --- Step 2: Decrypt Backup Archive ---
log_info "Step 2: Decrypting Backup Archive."
log_info "Attempting to decrypt '${ENCRYPTED_BACKUP_FILE_ARG}' to '${DECRYPTED_TARBALL_PATH}'..."

AGE_DECRYPT_ARGS=() # Array to hold arguments for the AGE command
# If a specific AGE identity file is provided, use it.
if [ -n "$RESTORE_AGE_IDENTITY_FILE_PATH" ]; then
    # Expand tilde (~) in the identity file path if present.
    EXPANDED_IDENTITY_FILE_PATH="${RESTORE_AGE_IDENTITY_FILE_PATH/#\~/$HOME}"
    if [ ! -f "$EXPANDED_IDENTITY_FILE_PATH" ]; then
        log_warn "Specified AGE identity file not found: ${EXPANDED_IDENTITY_FILE_PATH}"
        log_warn "AGE will attempt decryption using default identities or prompt if a passphrase is required."
    else
        log_info "Using AGE identity file for decryption: ${EXPANDED_IDENTITY_FILE_PATH}"
        AGE_DECRYPT_ARGS+=("-i" "${EXPANDED_IDENTITY_FILE_PATH}")
    fi
else
    log_info "No specific AGE identity file provided via RESTORE_AGE_IDENTITY_FILE or SOPS_AGE_KEY_FILE."
    log_info "AGE will use its default identity resolution (e.g., YubiKey plugin, default software keys, or prompt for passphrase)."
fi
log_warn "If decryption requires a YubiKey, ensure it is connected."
log_warn "If decryption requires a passphrase for a software key, AGE will prompt you."

# Perform decryption using AGE.
# Output is redirected to the temporary tarball path.
AGE_DECRYPT_OUTPUT=$(age -d "${AGE_DECRYPT_ARGS[@]}" -o "${DECRYPTED_TARBALL_PATH}" "$ENCRYPTED_BACKUP_FILE_ARG" 2>&1)
AGE_DECRYPT_EC=$?

if [ $AGE_DECRYPT_EC -ne 0 ] || [ ! -s "${DECRYPTED_TARBALL_PATH}" ]; then # Check for non-empty decrypted file
    log_error "Failed to decrypt backup archive. age Exit Code: $AGE_DECRYPT_EC"
    log_error "age Output:\n${AGE_DECRYPT_OUTPUT}"
    log_error "Ensure the correct AGE identity (YubiKey or software key file) is available and accessible, or the correct passphrase was entered if prompted."
    # DECRYPTED_TARBALL_PATH will be cleaned by trap if it exists (e.g., partial file)
    exit 1
fi
log_success "Backup archive successfully decrypted to: ${DECRYPTED_TARBALL_PATH}"

# --- Step 3: Extract Contents from Decrypted Archive ---
log_info "Step 3: Extracting Contents from Decrypted Archive."
log_info "Extracting '${DECRYPTED_TARBALL_PATH}' into '${RESTORE_DIR_PATH}'..."
# Extract the tarball into the restore directory.
# -C changes directory before extracting, ensuring paths are relative to RESTORE_DIR_PATH.
TAR_EXTRACT_OUTPUT=$(tar -xzf "${DECRYPTED_TARBALL_PATH}" -C "${RESTORE_DIR_PATH}" 2>&1)
TAR_EXTRACT_EC=$?

if [ $TAR_EXTRACT_EC -ne 0 ]; then
    log_error "Failed to extract archive contents. tar Exit Code: $TAR_EXTRACT_EC"
    log_error "tar Output:\n${TAR_EXTRACT_OUTPUT}"
    log_warn "The decrypted tarball '${DECRYPTED_TARBALL_PATH}' still exists. You can attempt manual extraction."
    # Do not exit immediately, allow cleanup of decrypted tarball by the trap.
else
    log_success "Archive contents successfully extracted to: ${RESTORE_DIR_PATH}"
fi

# --- Step 4: Securely Delete Intermediate Decrypted Tarball ---
log_info "Step 4: Securely Deleting Intermediate Decrypted Tarball."
# `shred -u` overwrites the file multiple times and then unlinks (deletes) it.
if shred -u "${DECRYPTED_TARBALL_PATH}"; then
    log_success "Intermediate decrypted tarball '${DECRYPTED_TARBALL_PATH}' securely deleted."
else
    log_warn "shred command failed for '${DECRYPTED_TARBALL_PATH}'. Attempting normal rm..."
    if rm -f "${DECRYPTED_TARBALL_PATH}"; then
        log_success "Intermediate decrypted tarball '${DECRYPTED_TARBALL_PATH}' deleted (standard rm)."
    else
        log_error "CRITICAL: Failed to delete intermediate decrypted tarball '${DECRYPTED_TARBALL_PATH}'."
        log_error "Please delete it manually and securely IMMEDIATELY from '${RESTORE_DIR_PATH}'."
    fi
fi
# Ensure variable is cleared so trap doesn't try to remove it again if it was successfully removed.
DECRYPTED_TARBALL_PATH="" 

# If tar extraction failed earlier, exit now after attempting cleanup.
if [ $TAR_EXTRACT_EC -ne 0 ]; then
    log_error "Exiting due to tar extraction failure. Please review messages above."
    exit 1 
fi

log_info "---------------------------------------------------------------------"
log_success "Backup Restoration Process Complete!"
log_info "---------------------------------------------------------------------"
log_info "Files from the backup archive '${ENCRYPTED_BACKUP_FILE_ARG}' have been extracted to:"
log_info "  ${RESTORE_DIR_PATH} (Absolute path: $(readlink -f "${RESTORE_DIR_PATH}" 2>/dev/null || echo "${RESTORE_DIR_PATH}"))"
log_warn "Review the restored files carefully before using them or moving them to their original locations."
log_warn "Be cautious about overwriting existing production files with restored versions."

exit 0
