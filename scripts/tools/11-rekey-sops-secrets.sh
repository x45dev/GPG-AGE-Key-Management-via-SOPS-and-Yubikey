#!/usr/bin/env bash
# scripts/tools/11-rekey-sops-secrets.sh
# Re-encrypts SOPS files with the current recipients defined in .sops.yaml.

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
    echo "Usage: $(basename "$0") [--dry-run] [--backup] [file_or_dir ...]"
    echo ""
    echo "This script re-encrypts SOPS-managed files using the current recipients"
    echo "defined in the relevant .sops.yaml configuration file(s)."
    echo "This is useful after updating key recipients (e.g., adding a new YubiKey AGE key)."
    echo ""
    echo "Arguments (Optional):"
    echo "  [file_or_dir ...]   One or more files or directories to process. If directories are"
    echo "                      provided, the script will search for '*.yaml' or '*.json' files within them."
    echo "                      If no arguments are provided, it defaults to paths defined by"
    echo "                      \$SOPS_REKEY_DEFAULT_PATHS (e.g., 'secrets/**/*.yaml')."
    echo "  --dry-run           List files that would be re-keyed without actually modifying them."
    echo "  --backup            Create a backup of each file (e.g., file.yaml.bak) before re-keying."
    echo ""
    echo "The script uses 'sops updatekeys' for the re-encryption process."
    echo "Make sure 'sops', 'find' (if using default paths), 'cp', 'grep' are installed."
    exit 1
}

# --- Configuration & Argument Parsing ---
DRY_RUN_FLAG=false
BACKUP_FLAG=false
declare -a TARGET_PATHS_ARGS # Array to hold file/directory arguments from the user.

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --dry-run) DRY_RUN_FLAG=true ;;
        --backup) BACKUP_FLAG=true ;;
        -*) log_error "Unknown option: $1"; usage ;; # Handle unknown options
        *) TARGET_PATHS_ARGS+=("$1") ;; # Collect file/directory paths
    esac
    shift
done

# Default paths to search for SOPS files if no arguments are provided.
# This is a comma-separated list of glob patterns.
SOPS_REKEY_DEFAULT_PATHS_CONFIG="${SOPS_REKEY_DEFAULT_PATHS:-secrets/**/*.yaml,secrets/**/*.json}"

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 11-rekey-sops-secrets.sh with status $exit_status_for_cleanup"
    # No specific temporary files are created directly by this script that need explicit cleanup here.
    # SOPS handles its own temporary files during its operations.
}

log_info "Starting SOPS Secrets Rekeying Process..."
if $DRY_RUN_FLAG; then log_warn "DRY RUN MODE: No files will be modified."; fi
if $BACKUP_FLAG; then log_info "BACKUP MODE: Original files will be backed up before rekeying."; fi

# --- Prerequisite Checks ---
check_command "sops"
check_command "find" # Used if processing directories or default glob patterns.
check_command "cp"   # Used if --backup flag is set.
check_command "grep" # Used by sops -d check (indirectly).

# --- Step 1: Determine Target Files ---
log_info "Step 1: Identifying Target SOPS Files."
declare -a FILES_TO_PROCESS # Array to hold the final list of files to be processed.

if [ ${#TARGET_PATHS_ARGS[@]} -gt 0 ]; then
    # If specific files or directories are provided as arguments.
    log_info "Processing specified files/directories: ${TARGET_PATHS_ARGS[*]}"
    for path_arg in "${TARGET_PATHS_ARGS[@]}"; do
        expanded_path_arg="${path_arg/#\~/$HOME}" # Expand tilde for home directory.
        if [ ! -e "$expanded_path_arg" ]; then
            log_warn "Specified path does not exist, skipping: $expanded_path_arg"
            continue
        fi
        if [ -d "$expanded_path_arg" ]; then
            # If it's a directory, find .yaml and .json files within it.
            # Then, for each found file, check if it's a valid SOPS file.
            while IFS= read -r file; do
                # `sops -d "$file" >/dev/null 2>&1` attempts decryption to /dev/null.
                # If successful (exit code 0), it's a SOPS file we can likely process.
                if sops -d "$file" >/dev/null 2>&1; then
                    FILES_TO_PROCESS+=("$file")
                else
                    log_debug "Skipping non-SOPS or unreadable file in directory: $file"
                fi
            done < <(find "$expanded_path_arg" -type f \( -name "*.yaml" -o -name "*.json" -o -name "*.sops.*" \)) # Common SOPS extensions
        elif [ -f "$expanded_path_arg" ]; then
            # If it's a file, check if it's a SOPS file.
            if sops -d "$expanded_path_arg" >/dev/null 2>&1; then
                 FILES_TO_PROCESS+=("$expanded_path_arg")
            else
                log_warn "Specified file is not a SOPS encrypted file or is unreadable, skipping: $expanded_path_arg"
            fi
        fi
    done
else
    # If no arguments, use default paths defined by SOPS_REKEY_DEFAULT_PATHS_CONFIG.
    log_info "No specific files/directories provided. Using default paths: ${SOPS_REKEY_DEFAULT_PATHS_CONFIG}"
    
    # Enable globstar for `**` pattern matching if using Bash 4+.
    # shellcheck disable=SC2039 # globstar is a Bash 4+ feature.
    if [[ -n "${BASH_VERSION:-}" ]] && [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        shopt -s globstar nullglob # nullglob ensures pattern expands to nothing if no matches.
    fi

    # Convert comma-separated glob patterns to an array.
    IFS=',' read -r -a PATTERNS_TO_SEARCH <<< "$SOPS_REKEY_DEFAULT_PATHS_CONFIG"
    for pattern in "${PATTERNS_TO_SEARCH[@]}"; do
        pattern_trimmed=$(echo "$pattern" | xargs) # Trim whitespace.
        # Ensure pattern is treated as relative to BASE_DIR if not absolute.
        if [[ "$pattern_trimmed" != /* ]]; then
            pattern_to_eval="${BASE_DIR}/${pattern_trimmed}"
        else
            pattern_to_eval="$pattern_trimmed"
        fi
        
        # Evaluate the glob pattern.
        # Loop through files matching the glob and check if they are SOPS files.
        # Note: Direct globbing like this can be problematic with filenames containing spaces.
        # `find` is generally more robust for complex cases.
        for file in $pattern_to_eval; do
            if [ -f "$file" ]; then # Ensure it's a regular file.
                 if sops -d "$file" >/dev/null 2>&1; then # Check if it's a SOPS file.
                    FILES_TO_PROCESS+=("$file")
                else
                    log_debug "Skipping non-SOPS or unreadable file from glob: $file"
                fi
            fi
        done
    done
    # Disable globstar if it was enabled by this script.
    # shellcheck disable=SC2039
    if [[ -n "${BASH_VERSION:-}" ]] && [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        shopt -u globstar nullglob
    fi
fi

# Remove duplicate file paths from the list.
# shellcheck disable=SC2207 # Word splitting is intentional here for `tr`.
UNIQUE_FILES_TO_PROCESS=($(echo "${FILES_TO_PROCESS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

if [ ${#UNIQUE_FILES_TO_PROCESS[@]} -eq 0 ]; then
    log_info "No SOPS files found to process with the given criteria."
    exit 0
fi

log_info "Found ${#UNIQUE_FILES_TO_PROCESS[@]} SOPS file(s) to process:"
for file in "${UNIQUE_FILES_TO_PROCESS[@]}"; do
    log_info "  - $file"
done
echo # Newline for readability

# Confirm with the user before proceeding, unless it's a dry run.
if ! $DRY_RUN_FLAG; then
    if ! confirm "Proceed with rekeying these ${#UNIQUE_FILES_TO_PROCESS[@]} file(s)?"; then
        log_info "Rekeying process aborted by user."
        exit 0
    fi
fi

# --- Step 2: Process Files ---
log_info "Step 2: Processing SOPS Files."
SUCCESS_COUNT=0
FAIL_COUNT=0

for file in "${UNIQUE_FILES_TO_PROCESS[@]}"; do
    log_info "Processing file: $file"
    if $DRY_RUN_FLAG; then
        log_info "  [DRY RUN] Would rekey: $file"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        continue # Skip to the next file in dry run mode.
    fi

    # If backup flag is set, create a backup of the original file.
    if $BACKUP_FLAG; then
        BACKUP_FILE_PATH="${file}.$(date +%Y%m%d-%H%M%S).bak"
        log_info "  Creating backup: ${BACKUP_FILE_PATH}"
        if ! cp "$file" "$BACKUP_FILE_PATH"; then
            log_error "  Failed to create backup for $file. Skipping rekey for this file."
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue # Skip to the next file if backup fails.
        fi
    fi

    log_info "  Running 'sops updatekeys $file'..."
    # `sops updatekeys <file>` re-encrypts the file using the current keys defined in its .sops.yaml.
    SOPS_UPDATE_OUTPUT=$(sops updatekeys "$file" 2>&1)
    SOPS_UPDATE_EC=$?

    if [ $SOPS_UPDATE_EC -eq 0 ]; then
        log_success "  Successfully rekeyed: $file"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log_error "  Failed to rekey: $file. sops Exit Code: $SOPS_UPDATE_EC"
        log_error "  SOPS Output:\n$(echo "${SOPS_UPDATE_OUTPUT}" | sed 's/^/    /')" # Indent SOPS output for readability.
        FAIL_COUNT=$((FAIL_COUNT + 1))
        # If backup was created and rekeying failed, attempt to restore the backup.
        if $BACKUP_FLAG && [ -f "$BACKUP_FILE_PATH" ]; then
            log_info "  Restoring from backup: $BACKUP_FILE_PATH"
            if ! mv "$BACKUP_FILE_PATH" "$file"; then
                log_error "  CRITICAL: Failed to restore $file from backup $BACKUP_FILE_PATH. Manual intervention required."
            else
                log_info "  File $file restored from backup."
            fi
        fi
    fi
done

# --- Final Summary ---
log_info "---------------------------------------------------------------------"
if $DRY_RUN_FLAG; then
    log_success "SOPS Rekeying Dry Run Complete."
    log_info "  ${SUCCESS_COUNT} file(s) would have been processed."
else
    log_success "SOPS Rekeying Process Complete."
    log_info "  Successfully rekeyed: ${SUCCESS_COUNT} file(s)."
    if [ $FAIL_COUNT -gt 0 ]; then
        log_error "  Failed to rekey:    ${FAIL_COUNT} file(s)."
        log_warn "Please review the errors above for failed files."
    fi
fi
log_info "---------------------------------------------------------------------"

# Exit with an error code if any files failed to rekey.
if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
fi
exit 0
