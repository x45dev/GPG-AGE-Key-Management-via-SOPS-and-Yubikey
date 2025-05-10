# YubiKey Key Management Automation

This project provides a suite of idempotent Bash scripts, orchestrated by Mise, to automate the secure management of GPG and AGE cryptographic keys using YubiKeys. It aims to establish a robust, repeatable, and user-friendly system for individuals and teams to protect sensitive data, ensure authentication integrity, and maintain operational security.

The methodology emphasizes:
- **Hardware-backed GPG Keys:** Storing GPG subkeys on a YubiKey's OpenPGP applet, with the master key kept securely offline.
- **Hardware-backed AGE Keys:** Storing AGE identities on a YubiKey's PIV applet using `age-plugin-yubikey`.
- **SOPS Integration:** Seamlessly using YubiKey-held GPG/AGE keys for encrypting and decrypting secrets with SOPS.
- **Comprehensive Backup & Recovery:** Strategies for backing up GPG master keys, "cloning" GPG YubiKeys, and managing AGE identities across multiple YubiKeys.
- **Idempotent Automation:** Ensuring all setup and provisioning scripts can be run multiple times without unintended side effects.

Refer to docs/Yubikey-Key-Management-Automation.md for the detailed comprehensive guide and plan.

## Features (Targeted)

- Automated GPG master key and subkey generation adhering to best practices.
- Secure transfer of GPG subkeys to YubiKey OpenPGP applet.
- Guided backup of the offline GPG master key.
- Automated generation of AGE identities on YubiKey PIV applet.
- "Cloning" of GPG subkeys to a backup YubiKey.
- Mise tasks for easy execution of all operations.
- Configuration of YubiKey PINs, PUKs, Management Keys, and touch policies.
- Integration with SOPS for secret management.

## Prerequisites

### 1. Hardware

- At least one YubiKey (YubiKey 5 series recommended for RSA 4096 and ECC support).
- For backup strategies, two or more YubiKeys are recommended.

### 2. Software

The following command-line tools are required. They will be managed by Mise if you use the provided `.mise.toml` configuration.

- **Mise:** For tool version management and task execution. Install from mise.jdx.dev.
- **GnuPG (gpg):** For OpenPGP operations.
  *Note: `gpg` should be installed via your system's package manager (e.g., `apt`, `brew`, `pacman`). It is not managed by Mise.
- **YubiKey Manager (ykman):** For configuring YubiKey applets.
- **age:** For modern file encryption.
- **age-plugin-yubikey:** Plugin for AGE to use YubiKey PIV applet.
- **SOPS (sops):** For managing encrypted files.
- **hopenpgp-tools (hokey):** For linting GPG keys (optional but recommended).
- **pcsc-tools, ccid, libusb-compat (Linux):** System libraries for smart card interaction. `pcscd` daemon must be running.
  - Debian/Ubuntu: `sudo apt install pcscd pcsc-tools libccid`
  - Arch Linux: `sudo pacman -Syu pcsc-tools ccid`
  - macOS: `pcsc-lite` is usually pre-installed or available via Homebrew.

## Setup

1.  **Clone the Repository:**
    ```bash
    git clone <repository-url>
    cd yubikey-key-management
    ```

2.  **Install Tools with Mise:**
    If you have Mise installed, it should automatically prompt you to install the tools defined in `.mise.toml` when you `cd` into the directory (if you have `mise activate --hook` in your shell rc). Otherwise, run:
    ```bash
    mise install
    ```
    This ensures you are using the correct versions of all required CLI tools.

3.  **Configure Environment Variables (Optional but Recommended):**
    Mise tasks can use environment variables for configuration. You can set these in your shell environment, or for project-specific settings, create a `.env` file in the project root (add `.env` to your `.gitignore`!). Mise will automatically load it.

    Example variables (see `.mise.toml` `[env]` section for more):
    ```sh
    # .env (add to .gitignore!)
    GPG_USER_NAME="Your Name"
    GPG_USER_EMAIL="your.email@example.com"
    GPG_KEY_COMMENT="Optional Comment" # e.g., "Work Key" or "Personal Key"
    GPG_KEY_TYPE="RSA4096" # Or "ED25519"
    GPG_EXPIRATION="2y"

    PRIMARY_YUBIKEY_SERIAL="1234567" # Get from 'ykman list --serials'
    BACKUP_YUBIKEY_SERIAL="7654321"  # Optional, for backup YubiKey

    # For AGE on Primary YubiKey
    AGE_PRIMARY_YUBIKEY_PIV_SLOT="9a" # e.g., 9a, 9c, 9d, 9e, or 82-95
    AGE_PRIMARY_YUBIKEY_IDENTITY_FILE="${HOME}/.config/sops/age/yubikey_primary_id.txt"
    AGE_PRIMARY_YUBIKEY_PIN_POLICY="once" # once, always, never
    AGE_PRIMARY_YUBIKEY_TOUCH_POLICY="cached" # cached, always, never

    # For AGE on Backup YubiKey (if used)
    AGE_BACKUP_YUBIKEY_PIV_SLOT="9a"
    AGE_BACKUP_YUBIKEY_IDENTITY_FILE="${HOME}/.config/sops/age/yubikey_backup_id.txt"
    AGE_BACKUP_YUBIKEY_PIN_POLICY="once"
    AGE_BACKUP_YUBIKEY_TOUCH_POLICY="cached"

    # Default SOPS AGE key file (can be a single path or comma-separated list)
    # This will be set by Mise based on other variables, or you can override it.
    # For software AGE keys, point to the .age encrypted file:
    # SOPS_AGE_KEY_FILE="keys/age-keys-primary.txt.age"
    ```
    The scripts will attempt to use these environment variables or prompt the user if they are not set.

## Usage

All operations are performed via Mise tasks defined in `.mise.toml`. Run `mise run <task-name>` or `mise <task-name>` if the task is not shadowed by another command.

You can list all available tasks with `mise tasks` or `mise run --help`.
### Core Workflow

1.  **Generate GPG Master Key and Subkeys:**
    ```bash
    mise run generate-gpg-keys
    ```
    This script will guide you through creating a new GPG master key (kept offline) and associated subkeys. It will also generate a revocation certificate. **Store the master key passphrase and revocation certificate very securely! The passphrase is critical and unrecoverable if lost.**

2.  **Provision Primary YubiKey with GPG Subkeys:**
    Ensure your primary YubiKey is connected.
    ```bash
    mise run provision-primary-gpg-yubikey
    ```
    This moves the GPG subkeys (Sign, Encrypt, Authenticate) to your YubiKey's OpenPGP applet and configures PINs and touch policies.

3.  **Backup GPG Master Key:**
    ```bash
    mise run backup-gpg-master-key
    ```
    This script exports the GPG master private key and public key and provides instructions for secure offline backup. **This is a critical step.**

4.  **Provision Primary YubiKey with AGE Identity (Optional):**
    If you plan to use AGE encryption with your YubiKey:
    ```bash
    mise run provision-primary-age-yubikey
    ```
    This generates an AGE identity on your YubiKey's PIV applet, configures PINs/PUK/Management Key, and saves the identity file.

### Backup YubiKey Operations

If you have a second YubiKey for backup:

1.  **Clone GPG Subkeys to Backup YubiKey:**
    Ensure your backup YubiKey is connected.
    ```bash
    mise run clone-gpg-to-backup-yubikey
    ```
    This provisions the backup YubiKey with the *same* GPG subkeys as the primary.

2.  **Provision Backup YubiKey with its own AGE Identity (Optional):**
    Ensure your backup YubiKey is connected.
    ```bash
    mise run provision-backup-age-yubikey
    ```
    This generates a *new, distinct* AGE identity on your backup YubiKey's PIV applet.

### SOPS Integration

Configure your `.sops.yaml` file to use your GPG key fingerprint or AGE recipient(s).

**Example `.sops.yaml` for GPG:**
```yaml
creation_rules:
  - path_regex: 'secrets/.*\.yaml'
    pgp: 'YOUR_GPG_ENCRYPTION_SUBKEY_FINGERPRINT'
```

**Example `.sops.yaml` for AGE (Primary YubiKey):**
```yaml
creation_rules:
  - path_regex: 'secrets/.*\.yaml'
    age: 'YOUR_PRIMARY_YUBIKEY_AGE_RECIPIENT_PUBLIC_KEY'
```

**Example `.sops.yaml` for AGE (Primary and Backup YubiKeys):**
```yaml
creation_rules:
  - path_regex: 'secrets/.*\.yaml'
    age: >-
      YOUR_PRIMARY_YUBIKEY_AGE_RECIPIENT_PUBLIC_KEY,
      YOUR_BACKUP_YUBIKEY_AGE_RECIPIENT_PUBLIC_KEY
```

**Mise Tasks for SOPS:**
```bash
mise run sops-edit path/to/your/secret.enc.yaml
mise run sops-encrypt-file path/to/your/secret.enc.yaml
mise run sops-decrypt-file path/to/your/secret.enc.yaml
```
Ensure `SOPS_AGE_KEY_FILE` is set correctly in your environment (Mise tasks will help manage this) if using AGE.

## Security Best Practices

- **Strong PINs/Passphrases:** Use strong, unique PINs for your YubiKey applets and a very strong passphrase for your GPG master key.
- **Secure Backups:** Store GPG master key backups and revocation certificates in multiple, secure, offline, and geographically separate locations.
- **Physical Security:** Treat your YubiKeys as valuable physical keys.
- **Touch Policies:** Enable touch policies for sensitive operations on your YubiKey.
- **Regular Updates:** Keep all software (Mise, GPG, ykman, OS, etc.) up to date.
- **Review and Test:** Periodically review your key setup and test your backup and recovery procedures.

## Troubleshooting

Refer to Section 9 of docs/Yubikey-Key-Management-Automation.md for common issues and solutions. Key areas include:
- `pcscd` service not running.
- `gpg-agent` or `scdaemon` issues.
- YubiKey not detected or CCID interface not enabled.
- Incorrect PINs or PUKs.
- `SOPS_AGE_KEY_FILE` not set or pointing to the wrong identity file.

## Contributing

Contributions, suggestions, and bug reports are welcome. Please open an issue or pull request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
