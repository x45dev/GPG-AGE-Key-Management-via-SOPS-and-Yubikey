#!/usr/bin/env bash

# Common library functions for YubiKey Key Management Automation scripts

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipestatus: if any command in a pipeline fails, the return code is the failure's code.
set -o pipefail

# --- Configuration & Globals ---
IFS=$'\n\t'

# Colors for output
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'

# Script name for logging
SCRIPT_NAME="$(basename "$0")"

# Stdout Log Level: controls what's printed to the console.
# Valid levels: debug, info, warn, error, success (error & success always print)
# Default to 'info' if not set.
LOG_LEVEL="${LOG_LEVEL:-info}"

# File Logging Configuration
# YKM_LOG_FILE: Path to the log file. If empty, no file logging.
# If set, all log levels (DEBUG, INFO, WARN, ERROR, SUCCESS) are written to this file.
YKM_LOG_FILE="${YKM_LOG_FILE:-}"
_YKM_LOG_FILE_WRITABLE_CHECKED=0
_YKM_LOG_FILE_IS_WRITABLE=0

# --- Logging Functions ---

# Internal function to write to the log file if configured
_log_to_file() {
    local level="$1"
    shift
    local message="$*" # Capture all remaining arguments as the message

    if [ -z "$YKM_LOG_FILE" ]; then
        return 0 # No file logging configured
    fi

    # Check writability only once
    if [ "$_YKM_LOG_FILE_WRITABLE_CHECKED" -eq 0 ]; then
        _YKM_LOG_FILE_WRITABLE_CHECKED=1
        local resolved_log_file="$YKM_LOG_FILE"
        # If YKM_LOG_FILE is relative and BASE_DIR is set by calling script, make it relative to BASE_DIR
        # Otherwise, if relative, it's relative to CWD.
        if [[ "$YKM_LOG_FILE" != /* && -n "${BASE_DIR:-}" && -d "${BASE_DIR:-}" ]]; then
             resolved_log_file="${BASE_DIR}/${YKM_LOG_FILE}"
        fi

        # Attempt to create the directory for the log file if it doesn't exist
        local log_file_dir
        log_file_dir=$(dirname "$resolved_log_file")
        if [ ! -d "$log_file_dir" ]; then
            if mkdir -p "$log_file_dir"; then
                # This echo is for initial setup, won't use _log_to_file to avoid recursion
                echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} ${SCRIPT_NAME}: Created log directory ${log_file_dir}" >&2
            else
                echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} ${SCRIPT_NAME}: Failed to create log directory ${log_file_dir}. File logging disabled." >&2
                YKM_LOG_FILE="" 
                _YKM_LOG_FILE_IS_WRITABLE=0
                return 0
            fi
        fi
        
        if touch "$resolved_log_file" 2>/dev/null && [ -w "$resolved_log_file" ]; then
            _YKM_LOG_FILE_IS_WRITABLE=1
            # Log a message indicating file logging has started
            printf "%s [%s] %s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "INFO" "${SCRIPT_NAME}" "File logging started to ${resolved_log_file}" >> "$resolved_log_file"
        else
            echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} ${SCRIPT_NAME}: Log file '${resolved_log_file}' is not writable or cannot be created. File logging disabled." >&2
            YKM_LOG_FILE="" # Disable further attempts
            _YKM_LOG_FILE_IS_WRITABLE=0
        fi
    fi

    if [ "$_YKM_LOG_FILE_IS_WRITABLE" -eq 1 ]; then
        # Format: YYYY-MM-DD HH:MM:SS [LEVEL] SCRIPT_NAME: Message
        printf "%s [%s] %s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "${SCRIPT_NAME}" "${message}" >> "$YKM_LOG_FILE"
    fi
}

log_info() {
    _log_to_file "INFO" "$*"
    if [[ "$LOG_LEVEL" == "debug" || "$LOG_LEVEL" == "info" ]]; then
        echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} ${SCRIPT_NAME}: $*"
    fi
}

log_success() {
    _log_to_file "SUCCESS" "$*"
    # Success messages always print to stdout, similar to errors
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} ${SCRIPT_NAME}: $*"
}

log_warn() {
    _log_to_file "WARN" "$*"
    if [[ "$LOG_LEVEL" == "debug" || "$LOG_LEVEL" == "info" || "$LOG_LEVEL" == "warn" ]]; then
        echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ${SCRIPT_NAME}: $*"
    fi
}

log_error() {
    _log_to_file "ERROR" "$*"
    # Error messages always print to stderr
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} ${SCRIPT_NAME}: $*" >&2
}

log_debug() {
    _log_to_file "DEBUG" "$*"
    if [[ "${DEBUG:-false}" == "true" || "$LOG_LEVEL" == "debug" ]]; then
        echo -e "${COLOR_CYAN}[DEBUG]${COLOR_RESET} ${SCRIPT_NAME}: $*"
    fi
}

# --- User Interaction Functions ---

# Prompts for user confirmation (yes/no)
# Usage: confirm "Do you want to proceed?"
# Returns 0 if yes, 1 if no
confirm() {
    local prompt="$1"
    local response
    _log_to_file "PROMPT" "Confirmation requested: ${prompt} (yes/no)"
    while true; do
        read -r -p "$(echo -e "${COLOR_YELLOW}[PROMPT]${COLOR_RESET} ${prompt} (yes/no): ")" response
        _log_to_file "USER_INPUT" "User response to confirmation '${prompt}': '${response}'"
        case "${response,,}" in # Convert to lowercase
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) log_warn "Invalid input. Please enter 'yes' or 'no'." ;; # This log_warn will also go to file
        esac
    done
}

# Prompts for user input
# Usage: get_input "Enter your name:" VARIABLE_NAME
get_input() {
    local prompt="$1"
    local var_name="$2"
    local input_value
    _log_to_file "PROMPT" "Input requested: ${prompt}"
    read -r -p "$(echo -e "${COLOR_YELLOW}[INPUT]${COLOR_RESET} ${prompt} ")" input_value
    _log_to_file "USER_INPUT" "User input for '${prompt}': '${input_value}' (variable: ${var_name})" # Be careful logging sensitive inputs
    eval "$var_name=\"\$input_value\""
}

# Prompts for secure input (e.g., passphrase)
# Usage: get_secure_input "Enter passphrase:" VARIABLE_NAME
get_secure_input() {
    local prompt="$1"
    local var_name="$2"
    local input_value
    _log_to_file "PROMPT" "Secure input requested: ${prompt}"
    read -r -s -p "$(echo -e "${COLOR_YELLOW}[SECURE INPUT]${COLOR_RESET} ${prompt} ")" input_value
    echo # Newline after hidden input
    _log_to_file "USER_INPUT" "User provided secure input for '${prompt}' (variable: ${var_name}, value not logged)"
    eval "$var_name=\"\$input_value\""
}

# --- Utility Functions ---

# Checks if a command exists
# Usage: check_command "gpg"
check_command() {
  command -v "$1" >/dev/null 2>&1 || { log_error "Missing dependency: '$1' is not installed or not in PATH."; exit 1; }
  log_debug "Command '$1' found."
}

# Ensures a variable is set, otherwise prompts or exits
# Usage: ensure_var_set "VAR_NAME" "Prompt message if not set" [--secure]
ensure_var_set() {
    local var_name="$1"
    local prompt_msg="$2"
    local is_secure=false
    if [[ "${3:-}" == "--secure" ]]; then
        is_secure=true
    fi

    # Check if variable is defined and non-empty
    # Indirect expansion: ${!var_name}
    if [ -z "${!var_name:-}" ]; then
        log_warn "Environment variable $var_name is not set or is empty."
        if $is_secure; then
            get_secure_input "$prompt_msg: " "$var_name"
        else
            get_input "$prompt_msg: " "$var_name"
        fi
        if [ -z "${!var_name:-}" ]; then # Check again after prompting
            log_error "$var_name is required but was not provided. Exiting."
            exit 1
        fi
    fi
    # For non-secure variables, we can log their presence. For secure ones, just that they are set.
    if $is_secure; then
        log_debug "$var_name is set (value is sensitive)."
    else
        log_debug "$var_name is set to: '${!var_name}'"
    fi
}

# --- Trap & Cleanup Handling ---

_COMMON_CLEANUP_HAS_RUN=0
common_cleanup_handler() {
    local exit_status=${1:-$?}
    if [ "$_COMMON_CLEANUP_HAS_RUN" -eq 1 ]; then
        return "$exit_status"
    fi
    _COMMON_CLEANUP_HAS_RUN=1

    # Log to file that cleanup is starting
    if [ "$_YKM_LOG_FILE_IS_WRITABLE" -eq 1 ]; then
         printf "%s [%s] %s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "DEBUG" "${SCRIPT_NAME}" "Common cleanup handler called with exit status: $exit_status" >> "$YKM_LOG_FILE"
    fi
    # Stdout debug log for cleanup
    log_debug "Common cleanup handler called with exit status: $exit_status"


    if declare -f script_specific_cleanup > /dev/null; then
        log_debug "Executing script_specific_cleanup..."
        script_specific_cleanup "$exit_status" # Pass exit status to specific cleanup
    fi

    if [ "$_YKM_LOG_FILE_IS_WRITABLE" -eq 1 ]; then
         printf "%s [%s] %s: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "INFO" "${SCRIPT_NAME}" "Script finished with exit status: $exit_status" >> "$YKM_LOG_FILE"
    fi
}
trap 'common_cleanup_handler $?' EXIT

# Initialize file logging if YKM_LOG_FILE is set.
# This call will perform the initial writability check and log the "File logging started" message.
if [ -n "$YKM_LOG_FILE" ]; then
    _log_to_file "INIT" "Common library initialized. Attempting to start file logging."
fi

