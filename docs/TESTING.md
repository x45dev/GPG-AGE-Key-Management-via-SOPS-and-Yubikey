# Manual Test Plan for YubiKey Key Management Scripts

This document outlines manual test cases for the scripts in this project.
It's crucial to test in a non-production environment, especially when dealing with cryptographic keys and hardware tokens.

**General Prerequisites for All Tests:**

1.  **Mise Environment:** Ensure `mise` is installed and the project's `mise.toml` is configured with necessary tools (`gpg`, `ykman`, `age`, `age-plugin-yubikey`, `sops`, `shellcheck`, `date`). Run `mise trust` if needed.
2.  **YubiKey(s):** Have at least one YubiKey (preferably two for cloning/backup tests) available. YubiKey 5 series or newer recommended.
3.  **GPG Installation:** Ensure `gpg` (GnuPG) is installed via your system's package manager (e.g., `apt`, `brew`, `pacman`), as it's not managed by Mise in this project.
3.  **Configuration:**
    *   Review and adjust `.env.tracked` and `secrets/.env.sops.yaml` (or create them if they don't exist) with appropriate user details (name, email) and YubiKey serials.
    *   Ensure `SOPS_AGE_KEY_FILE` in `.env.tracked` points to a valid (initially non-existent or empty) software AGE key file if testing SOPS with software AGE keys.
    *   Set `YKM_LOG_FILE=ykm-test.log` and `LOG_LEVEL=debug` in your shell or `.env` to capture detailed logs during testing.
4.  **Clean State (Optional but Recommended for Full Tests):**
    *   For GPG tests, consider starting with an empty temporary GPG home (`TEMP_GNUPGHOME_DIR_NAME` in `mise.toml`) or ensure no conflicting keys exist in your default GPG home if not using a temporary one.
    *   For YubiKey provisioning, be prepared to reset the OpenPGP and PIV applets on the YubiKey if testing full provisioning flows.

**Initial Check:** Run `mise run checkup` to validate basic configuration before proceeding with other tests.
**Test Case Format:**

*   **Test Case ID:** A unique identifier (e.g., TC-CORE-01-001).
*   **Script:** The script being tested.
*   **Objective:** What the test aims to verify.
*   **Preconditions:** Any specific setup required before running the test.
*   **Steps:** The actions to perform.
*   **Expected Results:** The anticipated outcome.
*   **Actual Results:** (To be filled in during testing)
*   **Pass/Fail:** (To be filled in during testing)
*   **Notes:** Any observations or issues.

---

## Core Scripts

### `scripts/core/01-generate-gpg-master-key.sh`

*   **Test Case ID:** TC-CORE-01-001
*   **Objective:** Verify successful generation of GPG master key, subkeys, and revocation certificate.
*   **Preconditions:**
    *   `GPG_USER_NAME`, `GPG_USER_EMAIL` configured (e.g., in `.env`).
    *   No existing `.gpg_master_key_id` file or temporary GPG home from a previous run (or choose to overwrite).
*   **Steps:**
    1.  Run `mise run generate-gpg-keys`.
    2.  Follow prompts for passphrase.
    3.  Follow prompts for revocation certificate reason (if applicable).
*   **Expected Results:**
    1.  Script completes successfully.
    2.  A temporary GPG home (e.g., `.gnupghome_temp_ykm`) is created and populated.
    3.  A `.gpg_master_key_id` file is created with the master key ID.
    4.  A `revocation-certificate-*.asc` file is created.
    5.  `gpg --list-keys` (within the temp GPG home) shows the master key and subkeys (S,E,A).
    6.  Log file (`ykm-test.log`) contains detailed steps.
*   **Notes:** Test with both RSA4096 and ED25519 key types if possible by changing `GPG_KEY_TYPE` in env.

*   **Test Case ID:** TC-CORE-01-002
*   **Objective:** Verify idempotency check for existing master key ID file.
*   **Preconditions:** TC-CORE-01-001 successfully executed. `.gpg_master_key_id` exists.
*   **Steps:**
    1.  Run `mise run generate-gpg-keys` again.
    2.  When prompted about existing key ID, choose to skip.
*   **Expected Results:**
    1.  Script exits gracefully, indicating skipping.
    2.  No new keys are generated.
*   **Steps (Variant):**
    1.  Run `mise run generate-gpg-keys` again.
    2.  When prompted, choose to proceed with new key generation.
*   **Expected Results (Variant):**
    1.  Script proceeds to generate new keys, overwriting previous temp GPG home and ID file upon success.

### `scripts/core/01-generate-age-keypair.sh`

*   **Test Case ID:** TC-CORE-01A-001
*   **Objective:** Verify successful generation of a software AGE keypair and encryption of the private key.
*   **Preconditions:**
    *   `AGE_SOFTWARE_KEY_DIR` and `AGE_SOFTWARE_KEY_FILENAME` configured (or use defaults).
    *   No existing key files in the target location (or choose to overwrite).
*   **Steps:**
    1.  Run `mise run generate-software-age-key`.
    2.  Follow prompts for passphrase.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  An encrypted private key file (e.g., `keys/age-keys-primary.txt.age`) is created.
    3.  The public key is displayed.
    4.  The original plaintext private key file is securely deleted.
    5.  Log file contains detailed steps.

### `scripts/core/02-provision-gpg-yubikey.sh`

*   **Test Case ID:** TC-CORE-02-001
*   **Objective:** Verify successful provisioning of GPG subkeys to a YubiKey.
*   **Preconditions:**
    *   TC-CORE-01-001 successfully executed (GPG keys generated).
    *   `PRIMARY_YUBIKEY_SERIAL` configured.
    *   YubiKey connected. OpenPGP applet may be empty or contain other keys (test reset option).
*   **Steps:**
    1.  Run `mise run provision-primary-gpg-yubikey`.
    2.  If prompted, confirm OpenPGP applet reset.
    3.  Follow prompts to set new User and Admin PINs.
    4.  Enter GPG master key passphrase when prompted.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  `gpg -K` (in the context of the GPG home used) shows subkeys as `ssb>`.
    3.  `ykman -s <SERIAL> openpgp info` shows keys present and touch policies set as configured.
    4.  Log file contains detailed steps.

### `scripts/core/03-backup-gpg-master-key.sh`

*   **Test Case ID:** TC-CORE-03-001
*   **Objective:** Verify successful export of GPG master key materials for backup.
*   **Preconditions:**
    *   TC-CORE-01-001 successfully executed.
*   **Steps:**
    1.  Run `mise run backup-gpg-master-key`.
    2.  Enter GPG master key passphrase when prompted.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  A backup directory (e.g., `gpg_master_key_backup`) is created.
    3.  The directory contains `master-private-key-*.asc`, `public-key-*.asc`, and `revocation-certificate-*.asc`.
    4.  Clear instructions for offline storage are displayed.

### `scripts/core/04-provision-age-yubikey.sh`

*   **Test Case ID:** TC-CORE-04-001
*   **Objective:** Verify successful provisioning of a YubiKey PIV slot with an AGE identity.
*   **Preconditions:**
    *   `PRIMARY_YUBIKEY_SERIAL` (or `BACKUP_YUBIKEY_SERIAL` if testing that task) configured.
    *   Relevant `AGE_*_YUBIKEY_PIV_SLOT`, `AGE_*_YUBIKEY_IDENTITY_FILE`, etc. configured.
    *   YubiKey connected. PIV applet may be empty or target slot may contain other keys (test reset/delete options).
*   **Steps:**
    1.  Run `mise run provision-primary-age-yubikey` (or `provision-backup-age-yubikey`).
    2.  If prompted, confirm PIV applet reset or slot deletion.
    3.  Follow prompts to set new PIV PIN, PUK, and Management Key.
    4.  Enter PIV credentials when `age-plugin-yubikey` prompts.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  An AGE identity file (pointer) is created at the specified path.
    3.  The AGE recipient public key is displayed.
    4.  `ykman -s <SERIAL> piv info` shows the certificate in the specified slot.
    5.  `age-plugin-yubikey --list -s <SERIAL>` shows the new identity.
    6.  Warnings about non-exportable private key are displayed.

### `scripts/core/05-clone-gpg-yubikey.sh`

*   **Test Case ID:** TC-CORE-05-001
*   **Objective:** Verify successful "cloning" of GPG subkeys to a backup YubiKey.
*   **Preconditions:**
    *   TC-CORE-01-001 successfully executed (GPG keys generated).
    *   TC-CORE-02-001 successfully executed on a primary YubiKey (ensuring local subkey stubs were preserved).
    *   `BACKUP_YUBIKEY_SERIAL` configured for a *different* YubiKey.
    *   Backup YubiKey connected.
*   **Steps:**
    1.  Run `mise run clone-gpg-to-backup-yubikey`.
    2.  Follow prompts similar to `02-provision-gpg-yubikey.sh` for the backup YubiKey.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  The backup YubiKey is provisioned with the same GPG subkeys.
    3.  `gpg -K` (after `gpg-connect-agent learn --force` for the backup YK) shows subkeys as `ssb>`.
    4.  Warnings about GPG-only cloning and `gpg-connect-agent` are displayed.

---
### `scripts/core/16-generate-gpg-on-yubikey.sh`

*   **Test Case ID:** TC-CORE-16-001
*   **Objective:** Verify successful generation of GPG keys directly on the YubiKey and creation of a revocation certificate.
*   **Preconditions:**
    *   `PRIMARY_YUBIKEY_SERIAL` configured.
    *   YubiKey connected. OpenPGP applet may be empty or contain other keys (test reset option).
    *   User details (`GPG_USER_NAME`, `GPG_USER_EMAIL`) configured.
*   **Steps:**
    1.  Run `mise run generate-gpg-on-yubikey --serial <YOUR_YUBIKEY_SERIAL>`.
    2.  Confirm understanding of non-backable key risks.
    3.  If prompted, confirm OpenPGP applet reset.
    4.  Follow prompts to set new User and Admin PINs.
    5.  Follow interactive GPG prompts for on-card key generation (key type, size, expiration, UID).
    6.  Enter YubiKey User PIN when prompted for revocation certificate generation.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  A `revocation-certificate-oncard-*.asc` file is created.
    3.  A `.gpg_master_key_id` file is created with the on-card master key ID.
    4.  `gpg -K` (in the default GPG home) shows stubs for the on-card keys.
    5.  `ykman -s <SERIAL> openpgp info` shows keys present.
    6.  Strong warnings about non-exportable keys and the importance of the revocation certificate are displayed.

---

## Auxiliary Scripts (Team & Tools)

### `scripts/core/06-create-encrypted-backup.sh`
*   **Test Case ID:** TC-AUX-06-001
*   **Objective:** Verify successful creation of an encrypted backup archive.
*   **Preconditions:**
    *   Some GPG/AGE keys generated (e.g., via TC-CORE-01-001 or TC-CORE-01A-001).
    *   `BACKUP_AGE_RECIPIENTS_FILE` (e.g., `age-recipients.txt`) exists and contains at least one valid AGE public key.
    *   `BACKUP_SOURCE_ITEMS` configured (or use defaults).
*   **Steps:**
    1.  Run `mise run create-backup`.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  An encrypted archive (`.tar.gz.age`) and a checksum file (`.sha256`) are created in the backup directory.
    3.  The temporary unencrypted tarball is securely deleted.

*   `scripts/core/07-restore-backup.sh`
*   **Test Case ID:** TC-AUX-07-001
*   **Objective:** Verify successful decryption and restoration of a backup archive.
*   **Preconditions:**
    *   TC-AUX-06-001 successfully executed (encrypted backup exists).
    *   The AGE identity key needed for decryption is available (e.g., `SOPS_AGE_KEY_FILE` points to the correct software key file, or YubiKey with AGE identity is connected and `RESTORE_AGE_IDENTITY_FILE` points to its identity file).
*   **Steps:**
    1.  Run `mise run restore-backup <path_to_encrypted_backup.tar.gz.age>`.
    2.  If prompted for a passphrase (for software AGE key), enter it.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  Files are extracted to the restore directory.
    3.  The intermediate decrypted tarball is securely deleted.

*   `scripts/core/12-rotate-gpg-subkeys.sh`
*   **Test Case ID:** TC-AUX-12-001
*   **Objective:** Verify successful rotation of GPG subkeys.
*   **Preconditions:**
    *   TC-CORE-01-001 successfully executed (GPG master key exists in temp GPG home).
    *   Master key passphrase is known.
*   **Steps:**
    1.  Run `mise run rotate-gpg-subkeys`.
    2.  Enter master key passphrase.
    3.  Confirm rotation.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  `gpg -K` (in temp GPG home) shows old subkeys as expired and new subkeys present.
    3.  Warnings about updating public key and re-provisioning YubiKeys are displayed.

*   `scripts/team/08-provision-additional-age-identity.sh`
*   **Test Case ID:** TC-TEAM-08-001
*   **Objective:** Verify provisioning of an additional YubiKey AGE identity.
*   **Preconditions:**
    *   A YubiKey is connected (serial known or use auto-detect for single YK).
    *   PIV applet on YubiKey is set up (PINs, Mgmt Key).
*   **Steps:**
    1.  Run `mise run provision-additional-age-identity <label_for_new_key> --serial <yk_serial_if_needed>`.
    2.  Enter PIV credentials when prompted by `age-plugin-yubikey`.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  A new AGE identity file is created.
    3.  The public key is displayed and appended to the recipients file (unless `--no-update-recipients`).

*   `scripts/team/09-update-sops-recipients.sh`
*   **Test Case ID:** TC-TEAM-09-001
*   **Objective:** Verify `.sops.yaml` is updated with AGE recipients.
*   **Preconditions:**
    *   An `age-recipients.txt` (or configured input file) exists with valid AGE public keys.
    *   A `.sops.yaml` file exists (or will be created).
*   **Steps:**
    1.  Run `mise run update-sops-config-age`.
    2.  Confirm update.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  `.sops.yaml` is updated/created with the AGE keys from the input file.
    3.  A backup of the original `.sops.yaml` is created.

*   `scripts/team/17-setup-age-yubikey-redundancy.sh`
*   **Test Case ID:** TC-TEAM-17-001
*   **Objective:** Verify guided setup of AGE YubiKey redundancy.
*   **Preconditions:**
    *   Primary YubiKey AGE identity already provisioned (e.g., via `04-provision-age-yubikey.sh`), and its identity file path is known/configured.
    *   A second (backup) YubiKey is connected, and its serial is known/configured.
*   **Steps:**
    1.  Run `mise run setup-age-yubikey-redundancy`.
    2.  Provide path to primary YK AGE identity file.
    3.  Provide serial for backup YK.
    4.  Follow prompts from the called `08-provision-additional-age-identity.sh` script for the backup YK.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  A new AGE identity is provisioned on the backup YubiKey.
    3.  The `age-recipients.txt` file is updated with both primary and backup YK public keys.
    4.  The `.sops.yaml` file is updated to include both AGE recipients.
    5.  Instructions for rekeying SOPS files are displayed.

*   `scripts/tools/10-check-expiring-keys.sh`
*   **Test Case ID:** TC-TOOL-10-001
*   **Objective:** Verify GPG key expiration check.
*   **Preconditions:** GPG keys exist in the keyring (default or specified via `--gnupghome`). Some keys should ideally be set to expire soon for a positive test.
*   **Steps:**
    1.  Run `mise run check-expiring-gpg-keys --days 7`.
*   **Expected Results:**
    1.  Script lists keys expiring within 7 days or already expired.
    2.  If no keys are expiring soon, a success message is shown.

*   `scripts/tools/11-rekey-sops-secrets.sh`
*   **Test Case ID:** TC-TOOL-11-001
*   **Objective:** Verify SOPS file rekeying.
*   **Preconditions:**
    *   At least one SOPS-encrypted file exists.
    *   `.sops.yaml` is configured with the desired *new* recipients.
    *   Keys for *old* recipients (to decrypt) and *new* recipients (to re-encrypt) are available.
*   **Steps:**
    1.  Run `mise run rekey-sops-secrets path/to/your/secret.enc.yaml --backup`.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  The specified SOPS file is re-encrypted with the new recipients.
    3.  A backup of the original file is created.

*   `scripts/tools/13-offline-verify.sh`
*   **Test Case ID:** TC-TOOL-13-001
*   **Objective:** Verify SOPS decryption test.
*   **Preconditions:**
    *   A SOPS-encrypted file exists (e.g., `secrets/example.yaml` from project setup).
    *   The necessary key (GPG or AGE identity file for `SOPS_AGE_KEY_FILE`) for decryption is available.
*   **Steps:**
    1.  Run `mise run offline-verify-secrets secrets/example.yaml`.
    2.  If YubiKey or passphrase needed, provide it.
*   **Expected Results:**
    1.  Script completes successfully, indicating successful decryption.

*   `scripts/tools/14-redact-secrets.sh`
*   **Test Case ID:** TC-TOOL-14-001
*   **Objective:** Verify file redaction.
*   **Preconditions:** A sample configuration file with `key: value` or `key=value` lines.
*   **Steps:**
    1.  Run `mise run redact-secrets path/to/sample_config.txt`.
*   **Expected Results:**
    1.  Script completes successfully.
    2.  A redacted version of the file is created in the output directory.
    3.  Values after colons/equals signs are replaced with "REDACTED".

*   `scripts/tools/15-audit-secrets.sh`
*   **Test Case ID:** TC-TOOL-15-001
*   **Objective:** Verify SOPS file audit.
*   **Preconditions:** Some SOPS-encrypted files and some plain text files exist in paths covered by default audit paths.
*   **Steps:**
    1.  Run `mise run audit-sops-secrets --decrypt-check`.
*   **Expected Results:**
    1.  Script completes.
    2.  SOPS files are identified.
    3.  Decryption attempts are made and reported for SOPS files.
    4.  Non-SOPS files are reported as having no metadata.

---

**General Verification Steps (After Key Operations):**

These steps should be performed after relevant key generation or YubiKey provisioning scripts have been run.

1.  **GPG Key Verification (After `01-generate-gpg-master-key.sh` and `02-provision-gpg-yubikey.sh`):**
    *   **List Keys:**
        *   If using the temporary GPG home: `GNUPGHOME=.gnupghome_temp_ykm gpg -K` (or your configured `TEMP_GNUPGHOME_DIR_NAME`).
        *   If keys were imported to default GPG home: `gpg -K`.
    *   **Expected:**
        *   Master key listed (e.g., `sec  rsa4096/...`).
        *   Subkeys listed (e.g., `ssb  rsa4096/...`).
        *   If YubiKey provisioned (`02-...`), subkeys should be marked with `>` (e.g., `ssb> rsa4096/...`), indicating they are on a card.
    *   **YubiKey OpenPGP Applet Info (After `02-...` or `05-...`):**
        *   `ykman -s <YUBIKEY_SERIAL> openpgp info`
    *   **Expected:**
        *   Correct version numbers.
        *   PIN retry counters (e.g., User PIN: 3, Admin PIN: 3 if newly set).
        *   Signature, Encryption, and Authentication key slots should show data (e.g., fingerprints or "No data" if empty before provisioning).
        *   Touch policies should match configured values.

2.  **AGE Key Verification:**
    *   **Software AGE Key (After `01-generate-age-keypair.sh`):**
        *   Verify the encrypted private key file exists (e.g., `keys/age-keys-primary.txt.age`).
        *   Verify the public key was displayed and matches expectations.
    *   **YubiKey PIV-backed AGE Key (After `04-...` or `08-...`):**
        *   Verify the AGE identity file (pointer) was created at the specified path.
        *   Verify the AGE recipient public key was displayed.
        *   **YubiKey PIV Applet Info:**
            *   `ykman -s <YUBIKEY_SERIAL> piv info`
            *   **Expected:** The specified PIV slot (e.g., "Slot 9a:") should show "Certificate: Yes" or similar indication of a key.
        *   **List AGE Identities on YubiKey:**
            *   `age-plugin-yubikey --list -s <YUBIKEY_SERIAL>`
            *   **Expected:** The newly generated AGE recipient public key should be listed for the correct slot.

3.  **SOPS Decryption Test (After configuring `.sops.yaml` and relevant keys):**
    *   Create a sample file (e.g., `secrets/test-sops.yaml`) with content like `test_secret: somevalue`.
    *   Ensure `.sops.yaml` is configured with the GPG fingerprint or AGE public key of the key you intend to test.
    *   Encrypt the file: `sops -e -i secrets/test-sops.yaml`.
    *   Attempt to decrypt/edit:
        *   For GPG: `sops secrets/test-sops.yaml`
        *   For YubiKey AGE: `SOPS_AGE_KEY_FILE=/path/to/yubikey_identity.txt sops secrets/test-sops.yaml`
        *   For Software AGE (plaintext key): `SOPS_AGE_KEY_FILE=/path/to/software_age_key.txt sops secrets/test-sops.yaml`
        *   For Software AGE (passphrase-encrypted `.age` file): `SOPS_AGE_KEY_FILE=/path/to/software_age_key.txt.age sops secrets/test-sops.yaml` (AGE should prompt for passphrase).
    *   **Expected:**
        *   File decrypts successfully.
        *   If using a YubiKey, you should be prompted for PIN/touch as per the key's policy.

4.  **Log File Review:**
    *   If `YKM_LOG_FILE` is configured (e.g., `YKM_LOG_FILE=ykm-test.log`), review this file after running scripts.
    *   **Expected:** Detailed execution flow, including all `log_debug` messages, command outputs (where logged), and any errors or warnings encountered. This is invaluable for troubleshooting.

This test plan is a living document and should be expanded as new features are added or existing scripts are modified.
