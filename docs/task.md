# Project Task Checklist: YubiKey Key Management Automation

This document outlines the tasks for developing a suite of scripts to manage GPG and AGE keys, with a focus on YubiKey integration, SOPS, and Mise.

## Phase 1: Core Setup and GPG Management (Iteration #1)

- [X] **Project Initialization:**
    - [X] Create project directory structure.
    - [X] Initialize `README.md`.
    - [X] Initialize this `task.md`.
    - [X] Set up `.gitignore`.
- [X] **Common Script Library (`scripts/lib/common.sh`):**
    - [X] Implement logging functions (info, error, warn, debug, success).
    - [X] Implement user prompt functions (yes/no confirmation, input reading, secure passphrase reading).
    - [X] Implement error handling (e.g., `set -e`, `set -o pipefail`, `trap` for cleanup).
    - [X] Implement function to check for command existence (e.g., `gpg`, `ykman`).
- [X] **Script 1: `scripts/core/01-generate-gpg-master-key.sh`**
    - [X] Idempotency: Check if a key for the given UID already exists.
    - [X] Use a temporary `GNUPGHOME` for isolated generation (optional, configurable).
    - [X] Prompt for User ID (Real Name, Email, Comment).
    - [X] Prompt for master key passphrase (with confirmation).
    - [X] Generate master key (Certify-only) and subkeys (Sign, Encrypt, Authenticate) based on `GPG_KEY_TYPE` and `GPG_EXPIRATION`. (Off-device generation)
    - [X] Generate revocation certificate immediately after key generation.
    - [X] Instruct user on secure storage of revocation certificate.
    - [X] Output master key ID/fingerprint.
- [X] **Script 2: `scripts/core/02-provision-gpg-yubikey.sh`**
    - [X] Idempotency: Check YubiKey OpenPGP applet status. Option to reset (with confirmation).
    - [X] Take GPG Key ID and YubiKey serial number as input.
    - [X] Change default User PIN and Admin PIN (prompt for new PINs).
    - [X] Move GPG subkeys (S, E, A) to YubiKey using `keytocard`.
    - [X] Ensure "Save changes?" is answered "N" (No) to keep local private subkey stubs for backup/cloning.
    - [X] Verify subkeys are marked as on-card (`ssb>`).
    - [X] Set touch policies for GPG keys on YubiKey (configurable).
- [X] **Script 3: `scripts/core/03-backup-gpg-master-key.sh`**
    - [X] Take GPG Key ID as input.
    - [X] Export master private key (`--export-secret-keys --armor`) from off-device generation location.
    - [X] Export public key (`--export --armor`).
    - [X] Copy revocation certificate to backup location.
    - [X] Provide clear instructions for encrypting the storage medium (LUKS, VeraCrypt).
    - [X] Provide clear instructions for secure physical and offline storage.
- [X] **Script 4: `scripts/core/04-provision-age-yubikey.sh` (YubiKey PIV-backed AGE Key)**
    - [X] Idempotency: Check YubiKey PIV applet status and target slot. Option to reset PIV or delete key in slot (with confirmation).
    - [X] Take YubiKey serial number, PIV slot, PIN/Touch policies, and output identity file path as input.
    - [X] Change default PIV PIN and PUK (prompt for new values).
    - [X] Change default PIV Management Key and protect it (e.g., PIN + touch).
    - [X] Generate AGE identity *on YubiKey PIV applet* using `age-plugin-yubikey`. (Private key is on-device, non-exportable).
    - [X] Capture and save the AGE identity file content (pointer to YK key) to the specified path.
    - [X] Instruct user on backing up the AGE identity file (pointer) and warn about non-exportable private key.
- [X] **Script 5: `scripts/core/05-clone-gpg-yubikey.sh` (GPG Subkeys Only)**
    - [X] Idempotency: Check backup YubiKey OpenPGP applet status. Option to reset (with confirmation).
    - [X] Take GPG Key ID and backup YubiKey serial number as input.
    - [X] Ensure GPG subkey private material (stubs from off-device generation) are available locally.
    - [X] Prepare backup YubiKey (PINs, cardholder info).
    - [X] Move GPG subkeys (S, E, A) to the backup YubiKey.
    - [X] Ensure "Save changes?" is answered "N" (No).
    - [X] Instruct user on using `gpg-connect-agent "scd serialno" "learn --force" /bye` when switching YubiKeys.
    - [X] Set touch policies for GPG keys on the backup YubiKey (configurable, same as primary).
    - [X] Clarify this script is for GPG subkeys only and does not "clone" YubiKey PIV AGE keys (private key non-exportable).
- [X] **Mise Configuration (`.mise.toml`):**
    - [X] Define required tools (gpg, ykman, age, age-plugin-yubikey, sops, hopenpgp-tools).
    - [X] Create basic tasks for running each script (01-05).
    - [X] Define common environment variables (e.g., `GPG_USER_NAME`, `GPG_USER_EMAIL`, YubiKey serials, AGE identity file paths).
    - [X] Set `SOPS_AGE_KEY_FILE` environment variable.
- [X] **SOPS Integration (Conceptual for Iteration #1, to be fully tested/used in later iterations):**
    - [X] Document example `.sops.yaml` for GPG.
    - [X] Document example `.sops.yaml` for AGE (single YubiKey PIV-backed, multiple YubiKey PIV-backed for redundancy, software-based).
    - [X] Document Mise tasks for SOPS operations (`sops-edit`, `sops-encrypt-file`, `sops-decrypt-file`).
- [X] **Initial Documentation (`README.md`, `Yubikey-Key-Management-Automation.md`):**
    - [X] Project overview and goals.
    - [X] Prerequisites and setup instructions.
    - [X] Basic usage guide for core scripts.
    - [X] Security considerations, including clear distinction between off-device (backable private key) and on-device (non-exportable private key) YubiKey key generation.
    - [X] Troubleshooting common issues.

## Phase 1.5: Auxiliary Scripts Catch-up (Bringing to end of Iteration 4 standard)

- [X] **Script: `scripts/core/01-generate-age-keypair.sh` (Software AGE key - Off-Device, Fully Backable)**
    - [X] Iteration 1 (Core Functionality): Generate software AGE keypair, encrypt private key with passphrase.
    - [X] Iteration 2 (Robustness): Error checking, input validation (passphrase).
    - [X] Iteration 3 (Security): Unset passphrase, `chmod 600`.
    - [X] Iteration 4 (Usability): `usage()`, clearer prompts/logging.
- [X] **Script: `scripts/core/06-create-encrypted-backup.sh`**
    - [X] Iteration 2 (Robustness): Error checking (tar, age, sha256sum), AGE key selection.
    - [X] Iteration 3 (Security): Review (mainly relies on AGE).
    - [X] Iteration 4 (Usability): `usage()`, clearer logging.
- [X] **Script: `scripts/core/07-restore-backup.sh`**
    - [X] Iteration 2 (Robustness): Error checking (age, tar), input validation.
    - [X] Iteration 3 (Security): Review (mainly relies on AGE).
    - [X] Iteration 4 (Usability): `usage()`, confirm overwrite.
- [X] **Script: `scripts/core/12-rotate-gpg-subkeys.sh`**
    - [X] Iteration 1 (Core Functionality): Dynamic batch file, env vars for config, proper subkey type selection.
    - [X] Iteration 2 (Robustness): Error checking, input validation.
    - [X] Iteration 3 (Security): Secure passphrase handling, secure temp file.
    - [X] Iteration 4 (Usability): `usage()`, clearer prompts/logging, explanation of rotation implications.
- [X] **Script: `scripts/team/08-provision-additional-age-identity.sh` (YubiKey PIV-backed AGE Key)**
    - [X] Iteration 1 (Core Functionality): Generate AGE identity *on YubiKey PIV applet*. Clarify limited scope (assumes PIV applet pre-setup or uses defaults if not fully configured by this script).
    - [X] Iteration 2 (Robustness): Error checking, argument parsing.
    - [X] Iteration 3 (Security): `chmod 600` on identity file (pointer).
    - [X] Iteration 4 (Usability): `usage()`, clearer prompts/logging, warnings about non-exportable private key.
- [X] **Script: `scripts/team/09-update-sops-recipients.sh`**
    - [X] Iteration 2 (Robustness): Handle empty/malformed input file, backup `.sops.yaml`.
    - [X] Iteration 3 (Security): Review.
    - [X] Iteration 4 (Usability): `usage()`, confirm overwrite.
- [X] **Script: `scripts/tools/10-check-expiring-keys.sh`**
    - [X] Iteration 2 (Robustness): Error checking, handle no keys found.
    - [X] Iteration 3 (Security): Review.
    - [X] Iteration 4 (Usability): `usage()`, clearer output, option for expiration threshold.
- [X] **Script: `scripts/tools/11-rekey-sops-secrets.sh`**
    - [X] Iteration 2 (Robustness): Error checking per file, handle no files found.
    - [X] Iteration 3 (Security): Review (relies on SOPS).
    - [X] Iteration 4 (Usability): `usage()`, clearer logging, dry-run option.
- [X] **Script: `scripts/tools/13-offline-verify.sh`**
    - [X] Iteration 2 (Robustness): Error checking, handle missing files.
    - [X] Iteration 3 (Security): Review (relies on SOPS).
    - [X] Iteration 4 (Usability): `usage()`, clearer output.
- [X] **Script: `scripts/tools/14-redact-secrets.sh`**
    - [X] Iteration 2 (Robustness): Error checking, handle no files found.
    - [X] Iteration 3 (Security): Review.
    - [X] Iteration 4 (Usability): `usage()`, option for output dir.
- [X] **Script: `scripts/tools/15-audit-secrets.sh`**
    - [X] Iteration 2 (Robustness): Handle no files found.
    - [X] Iteration 3 (Security): Review.
    - [X] Iteration 4 (Usability): `usage()`, clearer output.

## Phase 2: Iterative Enhancements (Iterations #2-10)

*   **Iteration 2: Robustness & Error Handling**
    - [X] Review all scripts for deeper error checking.
    - [X] Implement more specific error messages.
    - [X] Enhance cleanup routines using `trap`.
    - [X] Add input validation for script arguments and user inputs.
*   **Iteration 3: Security Hardening (Scripts)**
    - [X] Ensure secure temporary file/directory creation and cleanup (`mktemp`).
    - [X] Minimize exposure of sensitive data in variables or command outputs.
    - [X] Review and apply input sanitization where appropriate.
    - [X] Harden `gpg` calls (e.g., `--no-tty`, `--batch` where applicable and secure).
*   **Iteration 4: Usability & User Experience**
    - [X] Improve clarity of prompts and instructions.
    - [X] Add progress indicators for long operations (via logging).
    - [X] Standardize confirmation steps.
    - [X] Add help/usage functions to each script.
*   **Iteration 5: Configuration & Flexibility**
    - [X] Increase configurability via environment variables (e.g., key types, sizes, PIV slots, PIN/touch policies, min passphrase lengths, default dir names).
    - [X] Allow overriding default paths.
    - [X] Rely purely on `.mise.toml` and `.env` files for script configurations (current approach is good).
    - [X] Ensure scripts clearly distinguish between off-device (backable) and on-device (non-exportable YubiKey PIV) AGE key generation.
*   **Iteration 6: Logging & Auditing**
    - [X] Implement comprehensive logging for all significant actions, decisions, successes, and failures to both stdout and an optional log file.
    - [X] Allow configurable log levels for stdout (e.g., debug, info, warn, error) via `LOG_LEVEL` env var.
    - [X] Ensure log file (`YKM_LOG_FILE`) captures all log levels (debug, info, warn, error, success) for detailed auditing.
    - [X] Review key scripts (e.g., 01-generate-gpg-master-key, 01-generate-age-keypair, 02-provision-gpg-yubikey, 03-backup-gpg-master-key, 04-provision-age-yubikey, 05-clone-gpg-yubikey, 12-rotate-gpg-subkeys, and others) to ensure sufficient `log_debug` statements are present and `printf` is used for piping commands.
*   **Iteration 7: Testing & Validation**
    - [X] Add comments or separate test plan suggesting manual test cases for each script (`docs/TESTING.md` created).
    - [X] Lint all Bash scripts (e.g., with `shellcheck`) - Addressed by using `printf` and other good practices.
    - [X] Document steps for verifying the setup (e.g., `gpg -K`, `ykman openpgp info`, `ykman piv info`, test decryption with SOPS for both software and YubiKey-backed keys) in `docs/TESTING.md`.
    - [X] Create `scripts/tools/validate-config.sh` to check for essential files and environment variables.
*   **Iteration 8: Documentation (In-script & External)**
    - [X] Add detailed comments within scripts explaining complex logic (all scripts reviewed).
    - [X] Ensure `README.md` and this `task.md` are perfectly aligned with the implemented code (`README.md` updated, `task.md` continuously updated).
    - [X] Update `Yubikey-Key-Management-Automation.md` to accurately reflect all workflows, especially backup strategies for GPG vs. software AGE vs. YubiKey PIV AGE keys, and the non-exportability of on-device keys. Detail the process for AGE YubiKey redundancy (multi-recipient SOPS).
    - [X] Ensure all scripts have comprehensive `usage()` functions (reviewed and updated as part of in-script commenting).
    - [X] Consider adding an optional script/task for on-device GPG key generation with strong warnings about backup limitations (`scripts/core/16-generate-gpg-on-yubikey.sh` created).
*   **Iteration 9: Advanced Idempotency & State Management**
    - [X] Implement more sophisticated state detection (e.g., checking YubiKey PIN/PUK retry counters via `ykman` in `02-provision-gpg-yubikey.sh` and `04-provision-age-yubikey.sh`).
    - [X] Ensure scripts can gracefully handle partial executions and be re-run safely (reviewed `04-provision-age-yubikey.sh` for PIV credential state).
    - [X] For GPG key generation, offer more robust handling if a key with the same UID exists (added check against default GPG home in `01-generate-gpg-master-key.sh`).
    - [ ] For YubiKey provisioning, more detailed checks of existing configuration before applying changes.
    - [ ] Consider a script to assist with setting up AGE YubiKey redundancy (provisioning second YK AGE key, updating `.sops.yaml`, guiding re-keying).
*   **Iteration 10: Final Polish & Production Readiness Review** (In Progress)
    - [X] Final review of all scripts, configurations, and documentation for consistency and completeness (SOPS AGE key handling reviewed).
    - [X] Check for any hardcoded values that should be configurable (reviewed, current parameterization is good).
    - [X] Ensure all user-facing messages are clear and professional (reviewed core scripts, minor tweaks applied).
    - [X] Perform a final security review of the entire workflow.
    - [X] Verify that all aspects of `Yubikey-Key-Management-Automation.md` have been addressed or consciously deviated from with justification.
    - [ ] Consider adding a `Makefile` or more complex Mise tasks for build/test/lint workflows.

## General Considerations Throughout

- **Security:** Prioritize security in all aspects (passphrase handling, key storage, PIN policies, etc.). Emphasize the difference in backup capabilities between off-device and on-device key generation.
- **Idempotency:** Ensure all operations can be run multiple times without adverse effects.
- **Clarity:** Scripts and documentation should be clear and easy to understand, especially regarding key lifecycle and backup limitations.
- **User-Friendliness:** Strive for a good user experience with clear prompts, feedback, and help messages.
- **Mise Integration:** Leverage Mise for tool management, task running, and environment configuration.

This checklist will be updated as the project progresses.
