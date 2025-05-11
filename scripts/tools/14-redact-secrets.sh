#!/usr/bin/env bash
# scripts/tools/14-redact-secrets.sh
# Creates visually redacted copies of specified files.

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
    echo "Usage: $(basename "$0") [--output-dir <PATH>] [file_or_dir ...]"
    echo ""
    echo "This script creates visually redacted copies of specified files. It is intended for"
    echo "quickly obscuring values in configuration files (e.g., YAML, JSON, .env files)"
    echo "for sharing examples or for quick visual audits, NOT for robust data sanitization."
    echo ""
    echo "Arguments (Optional):"
    echo "  [file_or_dir ...]   One or more files or directories to process. If directories are"
    echo "                      provided, the script will search for files matching common config"
    echo "                      extensions (e.g., *.yaml, *.json, *.env*) within them."
    echo "                      If no arguments are provided, it defaults to paths defined by"
    echo "                      \$REDACT_DEFAULT_SOURCE_PATHS (e.g., 'secrets/**/*.yaml')."
    echo "  --output-dir <PATH> Path to the directory where redacted files will be saved."
    echo "                      Default: \$REDACT_OUTPUT_DIR_NAME or 'redacted_output' in project root."
    echo "                      The script will attempt to preserve the source directory structure within this output directory."
    echo ""
    echo "Redaction Method:"
    echo "  The script uses 'sed' to replace content after a colon (':') or equals sign ('=')"
    echo "  on a line with 'REDACTED'. This is a VERY SIMPLE redaction."
    echo "  WARNING: This method is NOT foolproof and may NOT correctly redact multi-line values,"
    echo "  complex data structures, or values not following a simple 'key: value' or 'key=value' pattern."
    echo "  Always review redacted files carefully before sharing."
    echo ""
    echo "Make sure 'sed', 'find', 'mkdir', 'cp' are installed."
    exit 1
}

# --- Configuration & Argument Parsing ---
OUTPUT_DIR_ARG=""
declare -a TARGET_PATHS_ARGS # Array to hold file/directory arguments from the user.

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --output-dir) OUTPUT_DIR_ARG="$2"; shift ;;
        -*) log_error "Unknown option: $1"; usage ;;
        *) TARGET_PATHS_ARGS+=("$1") ;; # Collect file/directory paths
    esac
    shift
done

# Default paths to search for source files if no arguments are provided.
REDACT_DEFAULT_SOURCE_PATHS_CONFIG="${REDACT_DEFAULT_SOURCE_PATHS:-secrets/**/*.yaml,secrets/**/*.json,*.env.tracked}"
# Default output directory name.
REDACT_OUTPUT_DIR_NAME_CONFIG="${OUTPUT_DIR_ARG:-${REDACT_OUTPUT_DIR_NAME:-redacted_output}}"

# Resolve output directory path (relative to project root if not absolute).
if [[ "$REDACT_OUTPUT_DIR_NAME_CONFIG" != /* ]]; then
    REDACT_OUTPUT_DIR_ACTUAL="${BASE_DIR}/${REDACT_OUTPUT_DIR_NAME_CONFIG}"
else
    REDACT_OUTPUT_DIR_ACTUAL="$REDACT_OUTPUT_DIR_NAME_CONFIG"
fi

# --- Script Specific Cleanup ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 14-redact-secrets.sh with status $exit_status_for_cleanup"
    # No specific temporary files created by this script itself that need cleanup.
}

log_info "Starting File Redaction Process..."
log_info "Output directory for redacted files: ${REDACT_OUTPUT_DIR_ACTUAL}"
log_warn "Redaction is superficial (replaces content after ':' or '=' with 'REDACTED'). Review output carefully."

# --- Prerequisite Checks ---
check_command "sed"
check_command "find"
check_command "mkdir"
check_command "cp" # Though we use sed to new file, cp might be useful for non-redacted parts if logic changes.

# --- Prepare Output Directory ---
if [ -d "$REDACT_OUTPUT_DIR_ACTUAL" ]; then
    log_warn "Output directory '${REDACT_OUTPUT_DIR_ACTUAL}' already exists."
    if ! confirm "Do you want to proceed? Existing files in this directory might be overwritten."; then
        log_info "Redaction process aborted by user."
        exit 0
    fi
else
    if ! mkdir -p "$REDACT_OUTPUT_DIR_ACTUAL"; then
        log_error "Failed to create output directory: $REDACT_OUTPUT_DIR_ACTUAL"
        exit 1
    fi
fi
log_info "Redacted files will be placed in: $REDACT_OUTPUT_DIR_ACTUAL"

# --- Step 1: Determine Target Files ---
log_info "Step 1: Identifying Target Files for Redaction."
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
            # If it's a directory, find common config file types within it.
            # This list can be expanded based on common file extensions for configs.
            while IFS= read -r file; do
                FILES_TO_PROCESS+=("$file")
            done < <(find "$expanded_path_arg" -type f \( \
                -name "*.yaml" -o -name "*.yml" -o -name "*.json" \
                -o -name "*.toml" -o -name "*.ini" -o -name "*.conf" \
                -o -name "*.properties" -o -name "*.env*" \
                -o -name "*rc" \
                \))
        elif [ -f "$expanded_path_arg" ]; then
            # If it's a file, add it directly.
            FILES_TO_PROCESS+=("$expanded_path_arg")
        fi
    done
else
    # If no arguments, use default paths defined by REDACT_DEFAULT_SOURCE_PATHS_CONFIG.
    log_info "No specific files/directories provided. Using default paths from REDACT_DEFAULT_SOURCE_PATHS: ${REDACT_DEFAULT_SOURCE_PATHS_CONFIG}"
    
    # Enable globstar for `**` pattern matching if using Bash 4+.
    # shellcheck disable=SC2039 # globstar is a Bash 4+ feature.
    if [[ -n "${BASH_VERSION:-}" ]] && [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
        shopt -s globstar nullglob # nullglob ensures pattern expands to nothing if no matches.
    fi

    # Convert comma-separated glob patterns to an array.
    IFS=',' read -r -a PATTERNS_TO_SEARCH <<< "$REDACT_DEFAULT_SOURCE_PATHS_CONFIG"
    for pattern in "${PATTERNS_TO_SEARCH[@]}"; do
        pattern_trimmed=$(echo "$pattern" | xargs) # Trim whitespace.
        # Ensure pattern is treated as relative to BASE_DIR if not absolute.
        if [[ "$pattern_trimmed" != /* ]]; then
            pattern_to_eval="${BASE_DIR}/${pattern_trimmed}"
        else
            pattern_to_eval="$pattern_trimmed"
        fi
        
        # Evaluate the glob pattern.
        # Note: Direct globbing like `for file in $pattern_to_eval` can be problematic with filenames containing spaces.
        # Using `find` or a more careful loop is generally more robust for complex cases,
        # but for simple project structures, this might suffice.
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
    log_info "No files found to process with the given criteria."
    exit 0
fi

log_info "Found ${#UNIQUE_FILES_TO_PROCESS[@]} file(s) to process for redaction."

# --- Step 2: Process Files ---
log_info "Step 2: Redacting Files."
SUCCESS_COUNT=0
FAIL_COUNT=0

for source_file in "${UNIQUE_FILES_TO_PROCESS[@]}"; do
    # Determine output path, attempting to preserve relative directory structure from BASE_DIR.
    relative_path_from_base="${source_file#$BASE_DIR/}" # Remove BASE_DIR prefix if present.
    if [[ "$source_file" == "$BASE_DIR/"* ]]; then # File is within BASE_DIR.
        output_file="${REDACT_OUTPUT_DIR_ACTUAL}/${relative_path_from_base}"
    else # File is an absolute path outside BASE_DIR, or a relative path not starting from BASE_DIR.
        # For simplicity, just use basename for files outside the project structure.
        # A more complex approach could try to recreate parts of the absolute path.
        output_file="${REDACT_OUTPUT_DIR_ACTUAL}/$(basename "$source_file")"
    fi
    
    # Create the directory structure for the output file.
    output_file_dir=$(dirname "$output_file")
    if ! mkdir -p "$output_file_dir"; then
        log_error "Failed to create output directory structure: $output_file_dir for $source_file. Skipping."
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    log_info "Redacting: '$source_file' -> '$output_file'"
    
    # Simple sed redaction:
    # This sed script attempts to match lines with 'key: value' or 'key = value' patterns,
    # including those potentially starting with 'export' (common in .env files).
    # It replaces the value part with 'REDACTED'.
    # WARNING: This is a line-based, regex approach and is NOT foolproof.
    # It will NOT correctly redact multi-line YAML/JSON strings, complex data structures,
    # or values that do not conform to these simple patterns.
    # Always review the output carefully.
    sed_script='
    s/^\(\s*export\s\+\)\?\([a-zA-Z_][a-zA-Z0-9_]*\s*[:=]\s*\).*/\1\2REDACTED/
    '
    # Example transformations:
    # `API_KEY: secretvalue` becomes `API_KEY: REDACTED`
    # `DB_PASSWORD = "super secret"` becomes `DB_PASSWORD = REDACTED`
    # `  user: myuser` becomes `  user: REDACTED`
    # `export MY_VAR="something"` becomes `export MY_VAR=REDACTED`

    if sed -E "$sed_script" "$source_file" > "$output_file"; then
        log_success "  Redacted: $source_file"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log_error "  Failed to redact: $source_file (sed command failed)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        [ -f "$output_file" ] && rm "$output_file" # Clean up partial output file if sed failed.
    fi
done

log_info "---------------------------------------------------------------------"
log_success "File Redaction Process Complete."
log_info "  Successfully redacted: ${SUCCESS_COUNT} file(s)."
if [ $FAIL_COUNT -gt 0 ]; then
    log_error "  Failed to redact:    ${FAIL_COUNT} file(s)."
    log_warn "Please review the errors above for failed files."
fi
log_info "Redacted files are located in: ${REDACT_OUTPUT_DIR_ACTUAL}"
log_warn "REMINDER: This redaction is superficial. Always review redacted files carefully before sharing."
log_info "---------------------------------------------------------------------"

# Exit with an error code if any files failed to be redacted.
if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
fi
exit 0
