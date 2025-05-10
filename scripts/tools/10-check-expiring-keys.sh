#!/usr/bin/env bash
# scripts/tools/10-check-expiring-keys.sh
# Checks GPG keys in the current GPG keyring for expiration within a specified threshold.

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
    echo "Usage: $(basename "$0") [--days <N>] [--gnupghome <PATH>] [--all-keys]"
    echo ""
    echo "This script checks GPG keys (master and subkeys) in the specified GPG keyring"
    echo "for expiration within a given number of days."
    echo ""
    echo "Arguments (Optional):"
    echo "  --days <N>          Number of days for the expiration threshold. Keys expiring"
    echo "                      within N days will be listed."
    echo "                      Default: \$GPG_EXPIRY_CHECK_THRESHOLD_DAYS or 30 days."
    echo "  --gnupghome <PATH>  Path to the GPG home directory to check. If not provided,"
    echo "                      uses the default GPG home or \$GNUPGHOME if set."
    echo "  --all-keys          Check all keys (public keys), not just secret keys (which are checked by default)."
    echo ""
    echo "The script will output a list of keys expiring soon, including their Key ID, UID, and expiration date."
    echo "Make sure 'gpg' and 'date' (GNU date for robust date calculations) are installed."
    exit 1
}

# --- Configuration & Argument Parsing ---
DAYS_THRESHOLD_ARG=""
GNUPGHOME_ARG=""
CHECK_ALL_KEYS_FLAG=false

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --days) DAYS_THRESHOLD_ARG="$2"; shift ;;
        --gnupghome) GNUPGHOME_ARG="$2"; shift ;;
        --all-keys) CHECK_ALL_KEYS_FLAG=true ;;
        *) log_error "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Resolve configuration: Use argument if provided, else fallback to environment variable, else use a hardcoded default.
EXPIRY_THRESHOLD_DAYS="${DAYS_THRESHOLD_ARG:-${GPG_EXPIRY_CHECK_THRESHOLD_DAYS:-30}}"

# Validate that EXPIRY_THRESHOLD_DAYS is a non-negative integer.
if ! [[ "$EXPIRY_THRESHOLD_DAYS" =~ ^[0-9]+$ ]]; then
    log_error "Invalid value for --days: '${EXPIRY_THRESHOLD_DAYS}'. Must be a non-negative integer."
    usage
fi

# --- Script Specific Cleanup Function ---
# Registered with `trap` in common.sh to run on EXIT.
script_specific_cleanup() {
    local exit_status_for_cleanup=${1:-$?}
    log_debug "Running script_specific_cleanup for 10-check-expiring-keys.sh with status $exit_status_for_cleanup"
    # No specific temporary files or sensitive variables to clean up for this read-only script.
}

log_info "Checking GPG Keys Expiring Within ${EXPIRY_THRESHOLD_DAYS} Days..."

# --- Prerequisite Checks ---
check_command "gpg"
check_command "date" # GNU date is preferred for `date -d` capabilities for robust date calculations.
check_command "awk"
check_command "grep"

# --- Setup GNUPGHOME ---
# Determine which GPG home directory to use.
if [ -n "$GNUPGHOME_ARG" ]; then
    # Use the path provided via --gnupghome argument.
    if [ ! -d "$GNUPGHOME_ARG" ]; then
        log_error "Specified GPG home directory does not exist: $GNUPGHOME_ARG"
        exit 1
    fi
    export GNUPGHOME="$GNUPGHOME_ARG" # Set GNUPGHOME for subsequent GPG commands.
    log_info "Using specified GPG home: $GNUPGHOME"
elif [ -n "${GNUPGHOME:-}" ]; then
    # Use GNUPGHOME if it's already set in the environment.
    log_info "Using GPG home from environment: $GNUPGHOME"
else
    # Otherwise, GPG will use its default path (typically ~/.gnupg).
    log_info "Using default GPG home (typically ~/.gnupg)."
    # No need to explicitly unset GNUPGHOME here, as gpg will use its default if the var is not set or empty.
fi

# --- Calculate Threshold Date ---
# Ensure the 'date' command supports '-d' for future date calculations (GNU date does).
# On macOS, `brew install coreutils` provides `gdate` which should be used.
DATE_CMD="date"
if ! date -d "+${EXPIRY_THRESHOLD_DAYS} days" "+%s" > /dev/null 2>&1; then
    if command -v gdate > /dev/null 2>&1; then
        log_debug "Using gdate for date calculations."
        DATE_CMD="gdate"
    else
        log_error "The 'date' command on this system does not support calculating future dates robustly (e.g., 'date -d ...')."
        log_error "Please install GNU date (often available as 'gdate' via package managers like Homebrew on macOS)."
        exit 1
    fi
fi

# Calculate the future timestamp (in seconds since epoch) that marks the expiration threshold.
THRESHOLD_TIMESTAMP=$($DATE_CMD -d "+${EXPIRY_THRESHOLD_DAYS} days" "+%s")
# Get the current timestamp.
CURRENT_TIMESTAMP=$($DATE_CMD "+%s")
log_info "Checking for keys expiring on or before: $($DATE_CMD -d "@${THRESHOLD_TIMESTAMP}" "+%Y-%m-%d %H:%M:%S %Z")"

# --- Step 1: List GPG Keys and Check Expiration Dates ---
log_info "Step 1: Listing GPG Keys and Checking Expiration Dates."

# Determine which GPG command to use based on whether to check all keys or just secret keys.
GPG_LIST_CMD="gpg --no-tty --with-colons --list-keys" # Default to all public keys
if ! $CHECK_ALL_KEYS_FLAG; then
    GPG_LIST_CMD="gpg --no-tty --with-colons --list-secret-keys" # Check own (secret) keys by default
    log_info "(Checking secret keys only. Use --all-keys to check all public keys in keyring)."
fi

# Execute the GPG command to list keys in colon-delimited format.
GPG_OUTPUT=$($GPG_LIST_CMD 2>&1)
GPG_EC=$?

if [ $GPG_EC -ne 0 ]; then
    log_error "gpg command failed with exit code $GPG_EC."
    log_error "GPG Output:\n${GPG_OUTPUT}"
    exit 1
fi

if [ -z "$GPG_OUTPUT" ]; then
    log_info "No GPG keys found in the specified keyring."
    exit 0
fi

EXPIRING_KEYS_FOUND=0
HAS_KEYS_WITH_EXPIRY=0 # Flag to track if any keys with expiration dates were found at all.

echo # For better formatting before listing keys

# Process GPG output line by line.
# GPG colon-delimited format details:
# Record types: pub, sec (primary keys), sub, ssb (subkeys), uid (user IDs).
# Field meanings vary by record type. For keys:
#   Field 1: Record type (pub, sec, sub, ssb)
#   Field 5: Key ID
#   Field 7: Expiration date (timestamp, or empty if no expiration)
# For UIDs:
#   Field 10: User ID string
CURRENT_KEYID=""    # Stores the Key ID of the current primary key being processed.
CURRENT_UID=""      # Stores the UID associated with the current primary key.
CURRENT_KEYID_SUB="" # Stores the Key ID of the current subkey being processed.

echo "$GPG_OUTPUT" | while IFS= read -r line; do
    FIELD_TYPE=$(echo "$line" | cut -d: -f1)

    if [[ "$FIELD_TYPE" == "pub" || "$FIELD_TYPE" == "sec" ]]; then
        # This line is for a primary key (public or secret).
        CURRENT_KEYID=$(echo "$line" | cut -d: -f5)
        EXPIRY_TIMESTAMP=$(echo "$line" | cut -d: -f7)
        KEY_TYPE_LABEL="Master Key"
        if [[ "$FIELD_TYPE" == "sec" ]]; then KEY_TYPE_LABEL="Secret Master Key"; fi
        CURRENT_UID="" # Reset UID for new primary key block.
        CURRENT_KEYID_SUB="" # Clear subkey ID as this is a primary key line.
    elif [[ "$FIELD_TYPE" == "sub" || "$FIELD_TYPE" == "ssb" ]]; then
        # This line is for a subkey.
        # The UID is inherited from the preceding primary key.
        CURRENT_KEYID_SUB=$(echo "$line" | cut -d: -f5)
        EXPIRY_TIMESTAMP=$(echo "$line" | cut -d: -f7)
        KEY_TYPE_LABEL="Subkey"
        if [[ "$FIELD_TYPE" == "ssb" ]]; then KEY_TYPE_LABEL="Secret Subkey"; fi
    elif [[ "$FIELD_TYPE" == "uid" ]]; then
        # This line is for a User ID. Capture the first UID for the current primary key.
        if [ -z "$CURRENT_UID" ]; then
            # Decode \x3c (<) and \x3e (>) if present in UID string.
            CURRENT_UID=$(echo "$line" | cut -d: -f10 | sed 's/\\x3c/</g; s/\\x3e/>/g')
        fi
        continue # UID line doesn't have expiry for the key itself, so skip to next line.
    else
        continue # Skip other line types (e.g., fpr, grp).
    fi

    # Check if the key has an expiration date.
    if [ -n "$EXPIRY_TIMESTAMP" ]; then
        HAS_KEYS_WITH_EXPIRY=1
        EXPIRY_DATE_HR=$($DATE_CMD -d "@${EXPIRY_TIMESTAMP}" "+%Y-%m-%d %H:%M:%S %Z") # Human-readable date
        DAYS_LEFT=$(( (EXPIRY_TIMESTAMP - CURRENT_TIMESTAMP) / 86400 )) # Calculate days left

        # Determine if the key is expiring within the threshold.
        if [ "$EXPIRY_TIMESTAMP" -le "$THRESHOLD_TIMESTAMP" ]; then
            if [ "$EXPIRY_TIMESTAMP" -lt "$CURRENT_TIMESTAMP" ]; then
                # Key has already expired.
                log_warn "  [EXPIRED] ${KEY_TYPE_LABEL} ID: ${CURRENT_KEYID_SUB:-$CURRENT_KEYID}"
                log_warn "            UID: ${CURRENT_UID:- (No UID for this subkey line, refers to master)}"
                log_warn "            Expired on: ${EXPIRY_DATE_HR} (${DAYS_LEFT} days ago)"
            else
                # Key is expiring soon.
                log_warn "  [EXPIRING SOON] ${KEY_TYPE_LABEL} ID: ${CURRENT_KEYID_SUB:-$CURRENT_KEYID}"
                log_warn "                  UID: ${CURRENT_UID:- (No UID for this subkey line, refers to master)}"
                log_warn "                  Expires on: ${EXPIRY_DATE_HR} (in ${DAYS_LEFT} days)"
            fi
            EXPIRING_KEYS_FOUND=$((EXPIRING_KEYS_FOUND + 1))
        else
            # Key is not expiring soon.
            log_debug "  [OK] ${KEY_TYPE_LABEL} ID: ${CURRENT_KEYID_SUB:-$CURRENT_KEYID} expires ${EXPIRY_DATE_HR} (in ${DAYS_LEFT} days)"
        fi
    else
        # Key has no expiration date.
        log_info "  [NO EXPIRY] ${KEY_TYPE_LABEL} ID: ${CURRENT_KEYID_SUB:-$CURRENT_KEYID}"
        log_info "              UID: ${CURRENT_UID:- (No UID for this subkey line, refers to master)}"
    fi
    # Reset subkey-specific ID for next line to ensure it's only used for actual subkey lines.
    CURRENT_KEYID_SUB=""
done

echo # For better formatting after listing keys

# --- Final Summary ---
if [ $EXPIRING_KEYS_FOUND -gt 0 ]; then
    log_warn "Found ${EXPIRING_KEYS_FOUND} key(s) that are expired or expiring within ${EXPIRY_THRESHOLD_DAYS} days."
    log_warn "Please review and take appropriate action (e.g., extend expiration, rotate keys)."
else
    if [ $HAS_KEYS_WITH_EXPIRY -eq 0 ]; then
        log_success "No keys with expiration dates found in the keyring."
    else
        log_success "No GPG keys found expiring within the next ${EXPIRY_THRESHOLD_DAYS} days."
    fi
fi

exit 0
