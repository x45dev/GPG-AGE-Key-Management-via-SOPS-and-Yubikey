#!/usr/bin/env bash
# scripts/tools/15-audit-secrets.sh
# Audits specified files to check if they are valid SOPS-encrypted files
# and optionally attempts decryption.

SHELL_OPTIONS="set -e -u -o pipefail"
# set -e: Exit immediately if a command exits with a non-zero status.
# set -u: Treat unset variables as an error when substituting.
# set -o pipefail: The return value of a pipeline is the status of the last command to exit with a non-zero status, or zero if no command exited with a non-zero status.
eval "$SHELL_OPTIONS"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" # Adjusted BASE_DIR for tools script
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
    echo "Usage: $(basename "$0") [--decrypt-check] [file_or_dir ...]"
    echo ""
    echo "This script audits files to check for SOPS metadata and optionally attempts"
    echo "to decrypt them to verify key accessibility and file integrity."
    echo ""
    echo "Arguments (Optional):"
    echo "  [file_or_dir ...]   One or more files or directories to process. If directories are"
    echo "                      provided, the script will search for common SOPS file extensions"
    echo "                      (e.g., *.yaml, *.json, *.sops.*) within them."
    echo "                      If no arguments are provided, it defaults to paths defined by"
    echo "                      \$AUDIT_SOPS_DEFAULT_PATHS (e.g., 'secrets/**/*.yaml')."
    echo "  --decrypt-check     Attempt to decrypt each identified SOPS file to /dev/null."
    echo "                      This uses the AGE identity specified by \$SOPS_AGE_KEY_FILE"
    echo "                      (or \$AUDIT_SOPS_AGE_IDENTITY_FILE) or default GPG keys."
    echo ""
    echo "The script will output the status for each file found."
    echo "Make sure 'sops', 'find', 'grep' are installed."
    exit 1
}

# --- Configuration & Argument Parsing ---
DECRYPT_CHECK_FLAG=false
declare -a TARGET_PATHS_ARGS # Array to hold file/directory arguments from the user.

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --decrypt-check) DECRYPT_CHECK_FLAG=true ;;
        -*) log_error "Unknown option: $1"; usage ;;
        *) TARGET_PATHS_ARGS+=("$1") ;; # Collect file/directory paths
    esac
    shift
done

# Default paths to search for SOPS files if no arguments are provided.
AUDIT_SOPS_DEFAULT_PATHS_CONFIG="${AUDIT_SOPS_DEFAULT_PATHS:-secrets/**/*.yaml,secrets/**/*.json,*.env.tracked}"
# AUDIT_SOPS_AGE_IDENTITY_FILE can be used if a specific identity is needed for audit decryption.
# For this script, we'll rely on the existing SOPS_AGE_KEY_FILE mechanism from the environment,
# which can be set via .mise.toml or .env files.
# If AUDIT_SOPS_AGE_IDENTITY_FILE were to be used explicitly by this script,
# it would be handled similarly to how 13-offline-verify.sh handles its AGE_IDENTITY_FILE_ARG.

# --- Script Specific Cleanup ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 15-audit-secrets.sh with status $exit_status_for_cleanup"
    # No specific temporary files created by this script itself that need cleanup.
}

log_info "Starting SOPS Secrets Audit Process..."
if $DECRYPT_CHECK_FLAG; then log_info "Decryption check ENABLED. Will attempt to decrypt files to /dev/null."; fi

# --- Prerequisite Checks ---
check_command "sops"
check_command "find" # Used if processing directories or default glob patterns.
check_command "grep" # Used for initial metadata check.

# --- Step 1: Determine Target Files ---
log_info "Step 1: Identifying Target Files for Audit."
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
            # If it's a directory, find common SOPS file types within it.
            # This list can be expanded based on common file extensions for SOPS files.
            while IFS= read -r file; do
                FILES_TO_PROCESS+=("$file")
            done < <(find "$expanded_path_arg" -type f \( \
                -name "*.yaml" -o -name "*.yml" -o -name "*.json" \
                -o -name "*.env" -o -name "*.ini" -o -name "*.txt" \
                -o -name "*.sops.*" \
                \)) # Broadened list to catch various potential SOPS files.
        elif [ -f "$expanded_path_arg" ]; then
            # If it's a file, add it directly.
            FILES_TO_PROCESS+=("$expanded_path_arg")
        fi
    done
else
    # If no arguments, use default paths defined by AUDIT_SOPS_DEFAULT_PATHS_CONFIG.
    log_info "No specific files/directories provided. Using default paths from AUDIT_SOPS_DEFAULT_PATHS: ${AUDIT_SOPS_DEFAULT_PATHS_CONFIG}"
    
    # Enable globstar for `**` pattern matching if using Bash 4+.
    # shellcheck disable=SC2039 # globstar is a Bash 4+ feature.
    if [[ -n "${BASH_VERSION:-}" ]] && [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        shopt -s globstar nullglob # nullglob ensures pattern expands to nothing if no matches.
    fi

    # Convert comma-separated glob patterns to an array.
    IFS=',' read -r -a PATTERNS_TO_SEARCH <<< "$AUDIT_SOPS_DEFAULT_PATHS_CONFIG"
    for pattern in "${PATTERNS_TO_SEARCH[@]}"; do
        pattern_trimmed=$(echo "$pattern" | xargs) # Trim whitespace.
        # Ensure pattern is treated as relative to BASE_DIR if not absolute.
        if [[ "$pattern_trimmed" != /* ]]; then
            pattern_to_eval="${BASE_DIR}/${pattern_trimmed}"
        else
            pattern_to_eval="$pattern_trimmed"
        fi
        
        # Evaluate the glob pattern.
        for file in $pattern_to_eval; do 
            if [ -f "$file" ]; then FILES_TO_PROCESS+=("$file"); fi
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
    log_info "No files found to audit with the given criteria."
    exit 0
fi

log_info "Found ${#UNIQUE_FILES_TO_PROCESS[@]} file(s) to audit."
echo # Newline for readability

# --- Step 2: Process Files ---
log_info "Step 2: Auditing Files."
OK_COUNT=0        # Count of files with SOPS metadata (and optionally decrypted).
WARN_COUNT=0      # Count of files with no clear SOPS metadata.
FAIL_COUNT=0      # Count of files that failed decryption check.

for file in "${UNIQUE_FILES_TO_PROCESS[@]}"; do
    log_info "Auditing file: $file"
    
    # Check for SOPS metadata.
    # A simple `grep 'sops:'` can be a quick initial check for YAML/JSON.
    # A more robust check is to attempt decryption (`sops -d`), as SOPS supports binary formats too.
    # We try grep first for speed, then `sops -d` as a more definitive check.
    if grep -q 'sops:' "$file" || sops -d "$file" >/dev/null 2>&1; then 
        log_info "  [METADATA OK] SOPS metadata structure likely present in: $file"
        
        # If decryption check is enabled, attempt to decrypt the file.
        if $DECRYPT_CHECK_FLAG; then
            log_info "  Attempting decryption check for: $file"
            # SOPS uses SOPS_AGE_KEY_FILE from the environment for AGE keys.
            # For GPG, it relies on the gpg-agent and available keys.
            # No need to temporarily set SOPS_AGE_KEY_FILE here unless overriding a global setting
            # specifically for this audit, which is not the current design.
            # The script 13-offline-verify.sh handles temporary override if a specific identity file is passed to it.
            
            # Decrypt to /dev/null to avoid exposing secrets.
            SOPS_DECRYPT_OUTPUT=$(sops --decrypt "$file" > /dev/null 2>&1) # Capture stderr
            SOPS_DECRYPT_EC=$?
            if [ $SOPS_DECRYPT_EC -eq 0 ]; then
                log_success "    [DECRYPT OK] Successfully decrypted: $file"
                OK_COUNT=$((OK_COUNT + 1))
            else
                log_error "    [DECRYPT FAIL] Failed to decrypt: $file. sops Exit Code: $SOPS_DECRYPT_EC"
                # log_error "    SOPS Output (stderr):\n${SOPS_DECRYPT_OUTPUT}" # Be cautious with this.
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi
        else
            # If decryption check is not enabled, count as OK if metadata is present.
            OK_COUNT=$((OK_COUNT + 1))
        fi
    else
        log_warn "  [NO METADATA] No clear SOPS metadata found in: $file. This might be a plain text file or encrypted with other means."
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
done

# --- Final Summary ---
log_info "---------------------------------------------------------------------"
log_success "SOPS Secrets Audit Complete."
log_info "Summary:"
log_info "  Files with SOPS metadata (and optionally decrypted): ${OK_COUNT}"
log_info "  Files with potential issues (no metadata):         ${WARN_COUNT}"
if $DECRYPT_CHECK_FLAG; then
    log_info "  Files that failed decryption check:                ${FAIL_COUNT}"
fi
log_info "---------------------------------------------------------------------"

# Exit with an error code if any decryption checks failed.
if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
fi
exit 0
