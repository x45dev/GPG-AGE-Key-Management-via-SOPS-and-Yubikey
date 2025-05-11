#!/usr/bin/env bash
# scripts/team/09-update-sops-recipients.sh
# Updates the .sops.yaml configuration file with AGE recipients from a specified input file.

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
    echo "Usage: $(basename "$0") [--input-file <PATH>] [--sops-file <PATH>]"
    echo ""
    echo "This script updates the AGE recipients list in a .sops.yaml configuration file."
    echo "It reads AGE public keys from an input file (one key per line, comments and labels are ignored)."
    echo ""
    echo "Arguments (Optional, defaults from environment variables):"
    echo "  --input-file <PATH>   Path to the file containing AGE public keys."
    echo "                          Default: \$SOPS_AGE_RECIPIENTS_INPUT_FILE or 'age-recipients.txt'."
    echo "  --sops-file <PATH>      Path to the .sops.yaml file to update."
    echo "                          Default: \$SOPS_CONFIG_FILE_PATH or '.sops.yaml'."
    echo ""
    echo "Behavior:"
    echo "  - The script will back up the existing .sops.yaml file before making changes."
    echo "  - It attempts to replace the 'age:' list under the first 'creation_rules:' block that also"
    echo "    contains 'path_regex: 'secrets/.*\\.yaml''."
    echo "  - If this specific structure is not found, it appends a new 'creation_rules:' block."
    echo "  - WARNING: This script uses basic text manipulation. For complex .sops.yaml files,"
    echo "    manual review or a dedicated YAML tool (like yq) might be safer."
    echo "    Other keys within the matched 'creation_rules' block (e.g., 'pgp') might be affected if the"
    echo "    structure is not as expected. It primarily targets simple SOPS configurations."
    echo ""
    echo "Make sure 'awk', 'grep', 'sed', 'cp', 'mv', 'mktemp' are installed."
    exit 1
}

# --- Configuration & Argument Parsing ---
INPUT_FILE_ARG=""
SOPS_FILE_ARG=""

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --input-file) INPUT_FILE_ARG="$2"; shift ;;
        --sops-file) SOPS_FILE_ARG="$2"; shift ;;
        *) log_error "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Resolve configuration: Use argument if provided, else fallback to environment variable, else use a hardcoded default.
SOPS_AGE_RECIPIENTS_INPUT_FILE_CONFIG="${INPUT_FILE_ARG:-${SOPS_AGE_RECIPIENTS_INPUT_FILE:-age-recipients.txt}}"
SOPS_CONFIG_FILE_PATH_CONFIG="${SOPS_FILE_ARG:-${SOPS_CONFIG_FILE_PATH:-.sops.yaml}}"

# Resolve full paths for input and SOPS files (relative to project root if not absolute).
if [[ "$SOPS_AGE_RECIPIENTS_INPUT_FILE_CONFIG" != /* ]]; then
    AGE_RECIPIENTS_INPUT_FILE="${BASE_DIR}/${SOPS_AGE_RECIPIENTS_INPUT_FILE_CONFIG}"
else
    AGE_RECIPIENTS_INPUT_FILE="$SOPS_AGE_RECIPIENTS_INPUT_FILE_CONFIG"
fi

if [[ "$SOPS_CONFIG_FILE_PATH_CONFIG" != /* ]]; then
    SOPS_YAML_FILE="${BASE_DIR}/${SOPS_CONFIG_FILE_PATH_CONFIG}"
else
    SOPS_YAML_FILE="$SOPS_CONFIG_FILE_PATH_CONFIG"
fi

# Variable to hold the path to the temporary SOPS YAML file during modification.
TEMP_SOPS_YAML_FILE=""

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 09-update-sops-recipients.sh with status $exit_status_for_cleanup"
    # Remove the temporary SOPS YAML file if it exists.
    if [ -n "$TEMP_SOPS_YAML_FILE" ] && [ -f "$TEMP_SOPS_YAML_FILE" ]; then
        log_debug "Removing temporary SOPS YAML file: $TEMP_SOPS_YAML_FILE"
        rm -f "$TEMP_SOPS_YAML_FILE"
    fi
}

log_info "Starting SOPS Configuration Update for AGE Recipients."
log_info "  Input AGE recipients file: ${AGE_RECIPIENTS_INPUT_FILE}"
log_info "  Target SOPS config file:   ${SOPS_YAML_FILE}"

# --- Prerequisite Checks ---
check_command "awk"
check_command "grep"
check_command "sed"
check_command "cp"
check_command "mv"
check_command "mktemp"

# --- Step 1: Validate Input Files ---
log_info "Step 1: Validating Input Files."
if [ ! -f "$AGE_RECIPIENTS_INPUT_FILE" ]; then
    log_error "AGE recipients input file not found: $AGE_RECIPIENTS_INPUT_FILE"
    exit 1
fi

# --- Step 2: Read AGE Public Keys ---
log_info "Step 2: Reading AGE Public Keys from Input File."
declare -a AGE_KEYS_ARRAY
# Read non-empty lines from the input file that are not comments (#).
# For each such line, take the last field (assuming format like 'label: age1... key' or just 'age1... key').
# Filter for lines that actually look like AGE keys (start with 'age1').
# `xargs` is used to trim leading/trailing whitespace from each key.
mapfile -t AGE_KEYS_ARRAY < <(grep -vE '^\s*#|^\s*$' "$AGE_RECIPIENTS_INPUT_FILE" | awk '{print $NF}' | grep '^age1' | xargs)

if [ ${#AGE_KEYS_ARRAY[@]} -eq 0 ]; then
    log_warn "No valid AGE public keys (starting with 'age1') found in ${AGE_RECIPIENTS_INPUT_FILE}."
    if ! confirm "Do you want to proceed? This will likely result in an empty 'age:' list in .sops.yaml."; then
        log_info "Operation aborted by user."
        exit 0
    fi
fi

log_info "Found ${#AGE_KEYS_ARRAY[@]} AGE public key(s):"
for key in "${AGE_KEYS_ARRAY[@]}"; do
    log_info "  - $key"
done

# --- Step 3: Prepare .sops.yaml (Backup) ---
log_info "Step 3: Preparing to Update SOPS Configuration File."
SOPS_YAML_BACKUP_FILE=""
if [ -f "$SOPS_YAML_FILE" ]; then
    # Create a timestamped backup of the existing .sops.yaml file.
    SOPS_YAML_BACKUP_FILE="${SOPS_YAML_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    log_info "Backing up existing '${SOPS_YAML_FILE}' to '${SOPS_YAML_BACKUP_FILE}'..."
    if ! cp "$SOPS_YAML_FILE" "$SOPS_YAML_BACKUP_FILE"; then
        log_error "Failed to create backup of ${SOPS_YAML_FILE}. Aborting."
        exit 1
    fi
    log_success "Backup created: ${SOPS_YAML_BACKUP_FILE}"
else
    log_info "SOPS config file '${SOPS_YAML_FILE}' does not exist. A new one will be created."
fi

# Confirm with the user before proceeding with the update.
if ! confirm "Proceed with updating '${SOPS_YAML_FILE}' with the listed AGE keys?"; then
    log_info "Operation aborted by user. Original file (if it existed) is preserved."
    if [ -n "$SOPS_YAML_BACKUP_FILE" ]; then
        log_info "Backup file '${SOPS_YAML_BACKUP_FILE}' can be deleted if not needed."
    fi
    exit 0
fi

# --- Step 4: Construct New AGE Block for .sops.yaml ---
NEW_AGE_BLOCK=""
if [ ${#AGE_KEYS_ARRAY[@]} -eq 1 ]; then
    # Single AGE key: format as 'age: "key"'
    NEW_AGE_BLOCK="    age: '${AGE_KEYS_ARRAY[0]}'"
elif [ ${#AGE_KEYS_ARRAY[@]} -gt 1 ]; then
    # Multiple AGE keys: format as a YAML multi-line scalar (literal block scalar '>-' or folded block scalar).
    # SOPS typically uses a comma-separated list for multiple recipients on a single line,
    # or a multi-line list. We'll use the multi-line format for clarity.
    NEW_AGE_BLOCK="    age: >-\n" # Start multi-line literal block scalar
    for key_idx in "${!AGE_KEYS_ARRAY[@]}"; do
        NEW_AGE_BLOCK+="      ${AGE_KEYS_ARRAY[$key_idx]}"
        # Add comma for all but the last key if formatting as a single line comma separated list.
        # For multi-line, YAML spec implies newlines are sufficient.
        # However, SOPS examples often show commas. Let's add them for robustness.
        if [ "$key_idx" -lt $((${#AGE_KEYS_ARRAY[@]} - 1)) ]; then
             NEW_AGE_BLOCK+=","
        fi
        NEW_AGE_BLOCK+="\n"
    done
    # Remove trailing comma and newline if any from the loop.
    NEW_AGE_BLOCK=$(echo -e "$NEW_AGE_BLOCK" | sed 's/,\n$/\n/' | sed '$ d') # Removes trailing comma then last newline
else # No keys
    NEW_AGE_BLOCK="    age: '' # No AGE keys provided"
fi

# --- Step 5: Update .sops.yaml ---
log_info "Step 4: Updating '${SOPS_YAML_FILE}'." # Renumbered step for clarity
# Create a temporary file to write the new SOPS YAML content.
TEMP_SOPS_YAML_FILE=$(mktemp "${SOPS_YAML_FILE}.tmp.XXXXXX")

if [ ! -f "$SOPS_YAML_FILE" ] || [ ! -f "$SOPS_YAML_BACKUP_FILE" ]; then # If original doesn't exist or backup failed
    # Create a new .sops.yaml with a default creation_rules block.
    log_info "Creating new '${SOPS_YAML_FILE}' with default creation_rules."
    {
        echo "creation_rules:"
        echo "  - path_regex: 'secrets/.*\\.yaml'" # Default path_regex
        echo -e "${NEW_AGE_BLOCK}"
    } > "$TEMP_SOPS_YAML_FILE"
else
    # If .sops.yaml exists, attempt to preserve other content while replacing/adding the AGE block.
    # This is a simplified approach that overwrites the 'creation_rules' for 'secrets/.*.yaml'
    # and appends other top-level keys. It's not a full YAML parser.
    log_warn "WARNING: This script will OVERWRITE the existing 'creation_rules' block for 'path_regex: secrets/.*\\.yaml' in '${SOPS_YAML_FILE}' with ONLY the specified AGE keys."
    log_warn "Other keys within that specific rule (like 'pgp') will be removed from that rule."
    log_warn "Other 'creation_rules' entries and other top-level keys in your .sops.yaml will be preserved if possible."
    log_warn "This is a limitation of shell-based YAML manipulation. For complex .sops.yaml files, consider manual updates or a tool like 'yq'."
    if ! confirm "Are you sure you want to proceed with modifying '${SOPS_YAML_FILE}'?"; then
        log_info "Operation aborted by user. Original file restored from backup."
        rm -f "$TEMP_SOPS_YAML_FILE" # Clean up temp file
        mv "$SOPS_YAML_BACKUP_FILE" "$SOPS_YAML_FILE" # Restore backup
        log_info "Restored '${SOPS_YAML_FILE}' from backup."
        exit 0
    fi
    
    # Construct the new file content.
    {
        # Print content before 'creation_rules:' from the backup.
        awk '/^creation_rules:/ {exit} {print}' "$SOPS_YAML_BACKUP_FILE"
        
        # Add the new/updated creation_rules block.
        echo "creation_rules:"
        echo "  - path_regex: 'secrets/.*\\.yaml'" # Target rule
        echo -e "${NEW_AGE_BLOCK}"
        
        # Attempt to append other creation_rules from the backup, skipping the one we modified.
        # This is still fragile. A proper YAML parser (like yq) is better for robust modification.
        # This awk script tries to find other rules (lines starting with '  - ') that are not our target.
        awk '
            BEGIN { in_creation_rules = 0; in_target_rule_block = 0; }
            /^creation_rules:/ { in_creation_rules = 1; next; }
            !in_creation_rules { next; } # Skip lines outside creation_rules block (already handled)
            
            # Detect start of a rule item
            /^\s*-\s*path_regex:/ {
                if ($0 ~ /secrets\/.*\.yaml/) { # This is our target rule, skip its original form
                    in_target_rule_block = 1;
                } else { # This is a different rule, print it and subsequent indented lines
                    in_target_rule_block = 0;
                    print;
                }
                next;
            }
            # If in a target rule block, skip lines until next rule or end of block
            in_target_rule_block && /^\s*-\s*path_regex:/ { in_target_rule_block = 0; } # Reset if new rule starts
            in_target_rule_block { next; }

            # Print lines belonging to other rules or if not in target rule block
            { print }
        ' "$SOPS_YAML_BACKUP_FILE"

        # Append any content that was after the 'creation_rules:' block entirely.
        awk 'BEGIN{p=0} /^creation_rules:/ {p=1; while(getline > 0 && ($0 ~ /^\s+/ || $0 ~ /^\s*$/ || $0 ~ /^creation_rules:/)) next; if (NR > 0) print} p && NR > 0 {print}' "$SOPS_YAML_BACKUP_FILE"

    } > "$TEMP_SOPS_YAML_FILE"
fi

# Replace the original .sops.yaml with the modified temporary file.
if mv "$TEMP_SOPS_YAML_FILE" "$SOPS_YAML_FILE"; then
    log_success "'${SOPS_YAML_FILE}' updated successfully."
    TEMP_SOPS_YAML_FILE="" # Clear var so cleanup trap doesn't try to remove it.
else
    log_error "Failed to move temporary file to ${SOPS_YAML_FILE}. Changes not applied."
    log_error "The attempted new content is in: $TEMP_SOPS_YAML_FILE (this temp file will be cleaned up on exit)."
    exit 1
fi

log_info "---------------------------------------------------------------------"
log_success "SOPS Configuration Update Complete."
log_info "---------------------------------------------------------------------"
log_info "Review the updated '${SOPS_YAML_FILE}' to ensure it meets your expectations."
if [ -n "$SOPS_YAML_BACKUP_FILE" ] && [ -f "$SOPS_YAML_BACKUP_FILE" ]; then # Check if backup file still exists
    log_info "A backup of the original file was saved to: ${SOPS_YAML_BACKUP_FILE}"
fi

exit 0
