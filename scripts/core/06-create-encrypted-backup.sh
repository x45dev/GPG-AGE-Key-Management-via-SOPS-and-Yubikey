#!/usr/bin/env bash
# scripts/core/06-create-encrypted-backup.sh
# Creates an encrypted backup archive of specified key materials and configuration files.

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
    echo "This script creates a compressed and encrypted backup archive of important project files and user-specific key materials."
    echo "The archive is encrypted using AGE."
    echo ""
    echo "Configuration is primarily via environment variables (see .mise.toml):"
    echo "  BACKUP_SOURCE_ITEMS:      Comma-separated list of files/directories to back up."
    echo "                              Paths can be absolute or relative to the project root."
    echo "                              Tilde (~) expansion for home directory is supported."
    echo "  BACKUP_AGE_RECIPIENTS:    Comma-separated list of AGE public keys for encryption."
    echo "                              (Takes precedence over BACKUP_AGE_RECIPIENTS_FILE)."
    echo "  BACKUP_AGE_RECIPIENTS_FILE: Path to a file containing AGE public keys, one per line."
    echo "                              (Used if BACKUP_AGE_RECIPIENTS is not set)."
    echo "  BACKUP_OUTPUT_DIR:        Directory to store the encrypted backup (default: backups)."
    echo "  BACKUP_ARCHIVE_PREFIX:    Prefix for the backup archive filename (default: key-materials-backup)."
    echo ""
    echo "The script will:"
    echo "  1. Validate source items and AGE recipients."
    echo "  2. Create a temporary tar.gz archive of the source items."
    echo "  3. Encrypt the archive using AGE with the specified recipients."
    echo "  4. Create a SHA256 checksum file for the encrypted archive."
    echo "  5. Securely delete the unencrypted tar.gz archive."
    echo ""
    echo "Make sure 'tar', 'age', 'sha256sum', 'mkdir', 'rm', 'grep', 'cut', 'xargs' are installed."
    exit 1
}
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

log_info "Starting Encrypted Backup Creation Process..."

# --- Configuration & Environment Variables ---
# Default list of items to back up. Can include user-specific paths like ~/.gnupg and project-specific files.
DEFAULT_BACKUP_SOURCE_ITEMS="~/.gnupg, ~/.config/sops/age, .sops.yaml, keys, project.conf, .env.tracked, secrets/.env.sops.yaml, ${GPG_MASTER_KEY_ID_FILE:-.gpg_master_key_id}, ${TEMP_GNUPGHOME_DIR_NAME:-.gnupghome_temp_ykm}"
BACKUP_SOURCE_ITEMS_CSV="${BACKUP_SOURCE_ITEMS:-${DEFAULT_BACKUP_SOURCE_ITEMS}}"
# File containing AGE public keys for encryption, or direct CSV list.
BACKUP_AGE_RECIPIENTS_FILE="${BACKUP_AGE_RECIPIENTS_FILE:-age-recipients.txt}" # Relative to project root
BACKUP_AGE_RECIPIENTS_CSV="${BACKUP_AGE_RECIPIENTS:-}"
# Output directory and filename prefix for the backup.
BACKUP_OUTPUT_DIR_NAME="${BACKUP_OUTPUT_DIR:-backups}" # Relative to project root
BACKUP_ARCHIVE_PREFIX="${BACKUP_ARCHIVE_PREFIX:-key-materials-backup}"

# Construct full paths for backup files.
BACKUP_DIR_PATH="${BASE_DIR}/${BACKUP_OUTPUT_DIR_NAME}"
DATESTAMP=$(date +%Y%m%d-%H%M%S)
TEMP_ARCHIVE_BASENAME="${BACKUP_ARCHIVE_PREFIX}-${DATESTAMP}.tar.gz"
TEMP_ARCHIVE_PATH="${BACKUP_DIR_PATH}/${TEMP_ARCHIVE_BASENAME}" # Temp path for unencrypted tarball
ENCRYPTED_ARCHIVE_PATH="${TEMP_ARCHIVE_PATH}.age"
CHECKSUM_FILE_PATH="${ENCRYPTED_ARCHIVE_PATH}.sha256"

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 06-create-encrypted-backup.sh with status $exit_status_for_cleanup"

    # Securely delete the unencrypted temporary archive if it still exists.
    if [ -f "${TEMP_ARCHIVE_PATH}" ]; then
        log_warn "Cleaning up unencrypted temporary archive: ${TEMP_ARCHIVE_PATH}"
        shred -u "${TEMP_ARCHIVE_PATH}" 2>/dev/null || rm -f "${TEMP_ARCHIVE_PATH}"
    fi
}

# --- Prerequisite Checks ---
check_command "tar"
check_command "age"
check_command "sha256sum"
check_command "mkdir"
check_command "rm"
check_command "shred" # For secure deletion of the temporary unencrypted archive

# --- Step 1: Prepare Backup Directory and Validate Inputs ---
log_info "Step 1: Preparing Backup Directory and Validating Inputs."
if ! mkdir -p "$BACKUP_DIR_PATH"; then
    log_error "Failed to create backup directory: $BACKUP_DIR_PATH"
    exit 1
fi
log_info "Encrypted backups will be stored in: $BACKUP_DIR_PATH"

# --- Resolve and Validate Source Items ---
declare -a SOURCE_PATHS_TO_ARCHIVE # Array to hold validated paths for tar
IFS=',' read -r -a ITEMS_TO_VALIDATE <<< "$BACKUP_SOURCE_ITEMS_CSV"
VALIDATED_SOURCE_ITEMS_STRING="" # For logging the list of items

log_info "Validating source items for backup:"
for item in "${ITEMS_TO_VALIDATE[@]}"; do
    # Trim whitespace from each item.
    item_trimmed=$(echo "$item" | xargs)
    if [ -z "$item_trimmed" ]; then continue; fi # Skip empty items

    # Expand tilde (~) to user's home directory.
    expanded_item="${item_trimmed/#\~/$HOME}"
    # If the path is not absolute, assume it's relative to the project's BASE_DIR.
    if [[ "$expanded_item" != /* ]]; then
        expanded_item_abs="${BASE_DIR}/${expanded_item}"
    else
        expanded_item_abs="$expanded_item"
    fi

    # Check if the resolved path exists.
    if [ -e "$expanded_item_abs" ]; then
        log_info "  [OK] Found: $item_trimmed (resolved to $expanded_item_abs)"
        # For tar, paths inside BASE_DIR are added relative to BASE_DIR.
        # Absolute paths outside BASE_DIR are added as is.
        # This requires tar to be run with -C "$BASE_DIR" for relative paths.
        if [[ "$expanded_item_abs" == "$BASE_DIR"* ]]; then
            # Calculate path relative to BASE_DIR.
            relative_path_to_base="${expanded_item_abs#$BASE_DIR/}"
            SOURCE_PATHS_TO_ARCHIVE+=("$relative_path_to_base")
            VALIDATED_SOURCE_ITEMS_STRING+="${relative_path_to_base} "
        else
            # For absolute paths outside the project, add them as is.
            SOURCE_PATHS_TO_ARCHIVE+=("$expanded_item_abs")
            VALIDATED_SOURCE_ITEMS_STRING+="${expanded_item_abs} "
        fi
    else
        log_warn "  [WARN] Source item not found, skipping: $item_trimmed (resolved to $expanded_item_abs)"
    fi
done

if [ ${#SOURCE_PATHS_TO_ARCHIVE[@]} -eq 0 ]; then
    log_error "No valid source items found to back up. Please check BACKUP_SOURCE_ITEMS environment variable."
    exit 1
fi
log_info "Final list of items to be archived: ${VALIDATED_SOURCE_ITEMS_STRING}"

# --- Get AGE Recipients ---
declare -a AGE_RECIPIENTS_ARRAY # Array to hold AGE public keys
if [ -n "$BACKUP_AGE_RECIPIENTS_CSV" ]; then
    # Use recipients from environment variable if set.
    log_info "Using AGE recipients from BACKUP_AGE_RECIPIENTS environment variable."
    IFS=',' read -r -a AGE_RECIPIENTS_ARRAY <<< "$BACKUP_AGE_RECIPIENTS_CSV"
else
    # Otherwise, read recipients from the specified file.
    RECIPIENTS_FILE_PATH="${BASE_DIR}/${BACKUP_AGE_RECIPIENTS_FILE}"
    if [ -f "$RECIPIENTS_FILE_PATH" ]; then
        log_info "Reading AGE recipients from file: $RECIPIENTS_FILE_PATH"
        # Read non-empty, non-comment lines from the file.
        mapfile -t AGE_RECIPIENTS_ARRAY < <(grep -vE '^\s*#|^\s*$' "$RECIPIENTS_FILE_PATH" | xargs)
    fi
fi

if [ ${#AGE_RECIPIENTS_ARRAY[@]} -eq 0 ]; then
    log_error "No AGE recipients specified. Set BACKUP_AGE_RECIPIENTS or provide BACKUP_AGE_RECIPIENTS_FILE."
    exit 1
fi

log_info "AGE recipients for encryption:"
RECIPIENT_ARGS=() # Array to hold '-r <recipient>' arguments for AGE command
for recipient in "${AGE_RECIPIENTS_ARRAY[@]}"; do
    recipient_trimmed=$(echo "$recipient" | xargs) # Trim whitespace
    if [ -n "$recipient_trimmed" ]; then
        log_info "  - $recipient_trimmed"
        RECIPIENT_ARGS+=("-r" "$recipient_trimmed")
    fi
done

if [ ${#RECIPIENT_ARGS[@]} -eq 0 ]; then
    log_error "No valid AGE recipients found after processing. Cannot encrypt backup."
    exit 1
fi

# --- Step 2: Create Tarball Archive ---
log_info "Step 2: Creating Tarball Archive."
log_info "Archiving items to temporary file: ${TEMP_ARCHIVE_PATH}"
# Run tar from BASE_DIR (-C "$BASE_DIR") to correctly handle relative paths within the project.
# Absolute paths in SOURCE_PATHS_TO_ARCHIVE will be handled correctly by tar.
# --ignore-failed-read allows tar to continue if some files are unreadable (e.g., sockets in .gnupg).
if ! tar -C "$BASE_DIR" --ignore-failed-read -czf "${TEMP_ARCHIVE_PATH}" "${SOURCE_PATHS_TO_ARCHIVE[@]}"; then
    log_error "Failed to create tar archive. Check tar output and permissions."
    # TEMP_ARCHIVE_PATH will be cleaned by trap if it exists
    exit 1
fi
if [ ! -s "${TEMP_ARCHIVE_PATH}" ]; then # Check if archive is non-empty
    log_error "Created tar archive is empty: ${TEMP_ARCHIVE_PATH}"
    exit 1
fi
log_success "Temporary tarball archive created: ${TEMP_ARCHIVE_PATH}"

# --- Step 3: Encrypt Archive with AGE ---
log_info "Step 3: Encrypting Archive with AGE."
log_info "Encrypting '${TEMP_ARCHIVE_PATH}' to '${ENCRYPTED_ARCHIVE_PATH}'..."
# Encrypt the tarball using AGE with the specified recipients.
AGE_ENCRYPT_OUTPUT=$(age "${RECIPIENT_ARGS[@]}" -o "${ENCRYPTED_ARCHIVE_PATH}" "${TEMP_ARCHIVE_PATH}" 2>&1)
AGE_ENCRYPT_EC=$?

if [ $AGE_ENCRYPT_EC -ne 0 ] || [ ! -s "${ENCRYPTED_ARCHIVE_PATH}" ]; then # Check for non-empty encrypted file
    log_error "Failed to encrypt archive with AGE. Exit Code: $AGE_ENCRYPT_EC"
    log_error "AGE Output:\n${AGE_ENCRYPT_OUTPUT}"
    # TEMP_ARCHIVE_PATH will be cleaned by trap. Encrypted file might be partial.
    [ -f "${ENCRYPTED_ARCHIVE_PATH}" ] && rm -f "${ENCRYPTED_ARCHIVE_PATH}" # Remove partial encrypted file
    exit 1
fi
log_success "Archive successfully encrypted: ${ENCRYPTED_ARCHIVE_PATH}"

# --- Step 4: Securely Delete Unencrypted Tarball ---
log_info "Step 4: Securely Deleting Unencrypted Tarball."
if shred -u "${TEMP_ARCHIVE_PATH}"; then
    log_success "Unencrypted tarball '${TEMP_ARCHIVE_PATH}' securely deleted."
else
    log_warn "shred command failed for '${TEMP_ARCHIVE_PATH}'. Attempting normal rm..."
    if rm -f "${TEMP_ARCHIVE_PATH}"; then
        log_success "Unencrypted tarball '${TEMP_ARCHIVE_PATH}' deleted (standard rm)."
    else
        log_error "CRITICAL: Failed to delete unencrypted tarball '${TEMP_ARCHIVE_PATH}'."
        log_error "Please delete it manually and securely IMMEDIATELY."
        # Do not exit here, as the encrypted backup is created.
    fi
fi
# Ensure variable is cleared so trap doesn't try to remove it again if it was successfully removed.
TEMP_ARCHIVE_PATH="" 

# --- Step 5: Create Checksum for Encrypted Archive ---
log_info "Step 5: Creating SHA256 Checksum for Encrypted Archive."
if sha256sum "${ENCRYPTED_ARCHIVE_PATH}" > "${CHECKSUM_FILE_PATH}"; then
    log_success "SHA256 checksum created: ${CHECKSUM_FILE_PATH}"
else
    log_error "Failed to create SHA256 checksum for ${ENCRYPTED_ARCHIVE_PATH}."
    # This is not a critical failure for the backup itself, but good for integrity.
fi

log_info "---------------------------------------------------------------------"
log_success "Encrypted Backup Creation Complete!"
log_info "---------------------------------------------------------------------"
log_info "  Encrypted Archive: ${ENCRYPTED_ARCHIVE_PATH}"
log_info "  Checksum File:     ${CHECKSUM_FILE_PATH}"
log_warn "Next Steps:"
log_warn "  1. Securely store the encrypted archive ('$(basename "${ENCRYPTED_ARCHIVE_PATH}")') and its checksum file ('$(basename "${CHECKSUM_FILE_PATH}")') in multiple, safe, offline locations."
log_warn "  2. Remember or securely store the passphrase(s) for any software AGE keys used for encryption if they were passphrase protected."
log_warn "  3. Periodically test your backup restoration process."

exit 0
