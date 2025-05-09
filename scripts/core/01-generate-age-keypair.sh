#!/usr/bin/env bash
# scripts/core/01-generate-age-keypair.sh

set -euo pipefail
IFS=$'\n\t'

source "$(dirname "$0")/../lib/common.sh"

log info "Generating offline AGE keypair..."

require age
require age-keygen
mkdir -p keys

KEY_FILE="keys/age-keys-primary.txt"

# --- Generate Age Key ---
if [[ -f "$KEY_FILE" ]]; then
    log info "Age key file '$KEY_FILE' already exists. Skipping generation."
else
    log info "Age key file ($KEY_FILE) not found. Generating new key..."
    if age-keygen -o "$KEY_FILE"; then
        chmod 600 "$KEY_FILE"
        log info "Generated $KEY_FILE."
        log warn "IMPORTANT: Secure this file and ensure it is listed in .gitignore!"
    else
        log error "Failed to generate age key." >&2
        exit 1
    fi
fi

# --- Extract Public Key ---
PUBLIC_KEY="$(age-keygen -y ${KEY_FILE})"
if [[ -z "$PUBLIC_KEY" ]]; then
		log error "Could not extract public key from $KEY_FILE." >&2
		exit 1
fi
log info "Public key for AGE key file: $PUBLIC_KEY"
log warn "IMPORTANT: Add this public key to .sops.yaml as a recipient for file encryption."

# --- Encrypt Private Key ---
log info "Converting private key to ASCII-armored AGE encrypted format..."
AGE_KEY_FILE="${KEY_FILE%.txt}.age"
if ! age --armor --passphrase "$KEY_FILE" > "$AGE_KEY_FILE"; then
		log error "Failed to convert private key to PEM format." >&2
		exit 1
fi
log info "Converted private key to encrypted format: '${AGE_KEY_FILE}'."


log info "AGE keypair created. Run backup next."
