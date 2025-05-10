# **A Comprehensive Guide to Secure Key Management with YubiKey, GPG, AGE, SOPS, and Mise**

## **1. Introduction: The Imperative for Robust Key Management**

In the contemporary digital landscape, the secure management of cryptographic keys is paramount for protecting sensitive data, ensuring authentication integrity, and maintaining operational security. Hardware security keys, such as YubiKeys, offer a significant enhancement over software-based key storage by isolating private key material from potentially compromised host systems. This guide provides a comprehensive methodology for leveraging YubiKeys to store GPG (GNU Privacy Guard) and AGE private keys, integrating them into a SOPS (Secrets OPerationS) workflow for secure secret management, and orchestrating these processes with Mise, a versatile tool and environment manager.

The approach detailed herein emphasizes the creation of feature-complete and idempotent Bash scripts, managed by Mise, to automate the setup, usage, and backup of these cryptographic keys. This includes securely generating GPG master keys and subkeys, transferring subkeys to a YubiKey while keeping the master key offline, generating AGE identities on a YubiKey, and establishing robust backup strategies involving both encrypted files and cloned YubiKeys. The objective is to provide a secure, repeatable, and user-friendly system for managing critical cryptographic assets.

The complexity inherent in managing different types of cryptographic keys (GPG for established PGP workflows, AGE for modern, simpler encryption) and integrating them with hardware tokens necessitates clear, automated procedures. The YubiKey, with its multiple applets (OpenPGP for GPG, PIV for AGE via plugins), provides a versatile platform. However, this versatility also means that distinct setup and management processes are required for each key type. This guide will delineate these processes, ensuring that users understand the underlying security principles and operational steps.

## **2. Prerequisites and Environment Setup**

Before embarking on the secure management of GPG and AGE keys with YubiKeys, a foundational environment must be established. This involves installing the necessary command-line tools and configuring Mise to manage their versions and orchestrate the automation scripts.

### **2.1 Essential Command-Line Tools**

The following command-line tools are crucial for the procedures outlined in this guide:

* **GnuPG (gpg):** The core tool for OpenPGP key generation, management, and cryptographic operations.1  
* **YubiKey Manager (ykman):** Yubico's official tool for configuring various YubiKey applets, including PIV and OpenPGP settings.3  
* **age:** A simple, modern, and secure file encryption tool.5  
* **age-plugin-yubikey:** A plugin enabling AGE to use identities stored on a YubiKey's PIV applet.7  
* **SOPS (sops):** An editor for encrypted files, supporting various backends including PGP (GPG) and AGE.9  
* **pcsc-tools, ccid, libusb-compat (Linux):** System libraries and tools necessary for smart card (YubiKey) interaction.1 pcscd is a daemon that provides access to smart card readers.  
* **hopenpgp-tools (hokey):** Used for linting GPG keys against best practices.1  
* **yubikey-personalization (ykpersonalize):** For some YubiKey configuration tasks, though ykman is generally preferred for newer functionalities.1

The successful operation of YubiKeys, particularly for GPG, often relies on a chain of daemons and services. On Linux systems, this typically involves pcscd for low-level smart card reader access, scdaemon (GPG's smart card daemon) interfacing with pcscd, and gpg-agent which brokers GPG operations and communicates with scdaemon.11 For AGE, age-plugin-yubikey interacts with the YubiKey's PIV applet, which may also utilize system libraries like pcscd or direct PIV interaction libraries. A failure at any point in this chain can lead to operational issues, making the correct installation and configuration of these components vital.

### **2.2 Mise Configuration for Tool Management**

Mise will be used to manage the versions of these tools, ensuring a consistent and reproducible environment. The following snippet for mise.toml (or the global ~/.config/mise/config.toml) defines the required tools and their desired versions. Mise can install these tools if they are not already present and ensure they are available in the PATH when Mise tasks are run or when the Mise environment is activated.13

**Table: Example mise.toml Tool Configuration**

| Tool Name | Mise Configuration Example | Notes |
| :---- | :---- | :---- |
| GnuPG (gpg) | (System Managed) | Install via OS package manager (e.g., apt, brew, pacman). |
| YubiKey Manager | ykman = "latest" | Or a specific version like "5.1.0". |
| age | age = "latest" | Or a specific version like "1.1.1". |
| age-plugin-yubikey | age-plugin-yubikey = "latest" | Or a specific version. Ensure the plugin binary is in PATH. Mise might manage this directly if a plugin exists, or it might need manual path adjustment. 7 |
| SOPS | sops = "latest" | Or a specific version like "3.8.1". |
| pcsc-tools etc. | (System Managed) | Typically installed via system package manager (e.g., apt, pacman). Mise does not usually manage system libraries directly. |
| hopenpgp-tools | hopenpgp-tools = "latest" | Or a specific version. |

```ini
# Example ~/.config/mise/config.toml or project-specific mise.toml
[tools]
# gpg: Install via OS package manager (e.g., apt, brew, pacman)
ykman = "latest"            # For YubiKey configuration
age = "latest"              # For AGE encryption/decryption
age-plugin-yubikey = "latest" # Plugin for AGE with YubiKey
sops = "latest"             # For secret management
hopenpgp-tools = "latest"   # For GPG key linting (hokey)

# For Linux systems, ensure pcscd (and gpg) are installed and running via your system's package manager.
# e.g., on Debian/Ubuntu: sudo apt install gpg pcscd pcsc-tools
# e.g., on Arch Linux: sudo pacman -Syu gpg pcsc-tools ccid
```

This configuration ensures that when scripts are executed via Mise tasks, they use predictable versions of these critical tools. The age-plugin-yubikey binary, in particular, must be accessible in the system's PATH for age and SOPS to utilize YubiKey-backed AGE identities.7 Mise helps manage this by including the paths to tool binaries it manages in the environment.

## **3. Part 1: Mastering GPG with YubiKey**

GNU Privacy Guard (GPG) remains a cornerstone for secure communication and data protection through encryption and digital signatures. Integrating GPG with a YubiKey significantly enhances security by storing private subkeys on the hardware token, requiring its physical presence and a PIN for cryptographic operations.

### **3.1 Foundations: GPG Key Generation Strategy**

A robust GPG setup involves a strategic approach to key generation, emphasizing an offline master key and online subkeys.

* **Master Key (Certify-Only):** The master key is the root of trust for an OpenPGP identity. Its primary role should be to certify subkeys and manage User IDs (UIDs). By restricting its capability to "Certify-only," its attack surface is minimized. Should this key ever be compromised (a highly unlikely event if kept securely offline), its inability to directly sign or encrypt limits the immediate damage.1  
* **Subkeys (Sign, Encrypt, Authenticate):** Three distinct subkeys are typically generated:  
  * **Signing Subkey (S):** Used for digitally signing emails, documents, code commits, etc.  
  * **Encryption Subkey (E):** Used for encrypting data and communications.  
  * **Authentication Subkey (A):** Used for authentication purposes, such as SSH access. These subkeys are derived from the master key and are the ones transferred to the YubiKey for daily use.1 This separation allows for subkeys to be revoked and replaced if compromised, without affecting the master key's validity or the web of trust built upon it.  
* **Offline Master Key:** The private portion of the master key must be kept offline. This means it should be stored on an encrypted medium (e.g., a USB drive encrypted with LUKS or VeraCrypt) and physically secured (e.g., in a safe). It should only be accessed in a secure, air-gapped environment when necessary (e.g., for signing a new subkey or extending expiration dates).1 This practice protects the master key from malware, remote attacks, or compromise of the daily-use computer. The security of the entire GPG identity hinges on the master key; its compromise would be catastrophic, requiring a full identity revocation and re-establishment of trust. This strategy, while enhancing security, introduces a usability trade-off: the master key is not readily available. This complexity underscores the need for clear procedures and automation to manage infrequent but critical master key operations.  
* **Key Types and Sizes:**  
  * **RSA vs. ECC:** Both RSA and Elliptic Curve Cryptography (ECC) are strong options. ECC keys (e.g., Ed25519 for signing/authentication, Cv25519/X25519 for encryption) offer comparable security to larger RSA keys but with smaller key sizes and often faster operations.4 RSA 4096-bit keys are widely supported, extremely strong, and a common recommendation.2 YubiKey 5 series devices, for example, support RSA 4096 and various ECC curves including Curve 25519 and NIST P-256/P-384.2 The choice may depend on YubiKey model compatibility and specific security requirements.  
  * **Recommended Sizes:** For RSA, 4096 bits for both master and subkeys is a robust choice.2 For ECC, Curve 25519 (Ed25519/X25519) is highly recommended where supported.4  
* **Expiration Dates:** All keys (master and subkeys) should have an expiration date, typically 1-2 years in the future.1 This is a crucial security hygiene practice, prompting periodic review and renewal, which can also serve as a test of backup and recovery procedures. Setting calendar reminders for key expiration is advisable.

The YubiKey typically serves as a secure "safe deposit box" for the subkeys, not the master key.15 This distinction is vital: the master key remains the ultimate authority, stored offline, while the YubiKey enables secure and convenient daily use of the operational subkeys, protected by PIN and physical presence.2

**Table: GPG Key Configuration Summary**

| Key Role | Recommended Capability(ies) | Algorithm Choice (Example) | Key Size (RSA) | Key Size (ECC) | Recommended Expiration |
| :---- | :---- | :---- | :---- | :---- | :---- |
| Master Key | Certify (C) only | RSA or EdDSA (Ed25519) | 4096 bits | Curve 25519 | 1-2 years |
| Signing Subkey | Sign (S) | RSA or EdDSA (Ed25519) | 4096 bits | Curve 25519 | 1-2 years |
| Encryption Subkey | Encrypt (E) | RSA or X25519 (Cv25519) | 4096 bits | Curve 25519 | 1-2 years |
| Authentication Subkey | Authenticate (A) | RSA or EdDSA (Ed25519) | 4096 bits | Curve 25519 | 1-2 years |

### **3.2 Scripting GPG Setup: Generating Master Key and Subkeys**

Automating the GPG key generation process with a Bash script ensures consistency and adherence to best practices.

* **Bash Script Design:** The script should:  
  1. Optionally create and use a temporary $GNUPGHOME directory to isolate the key generation process, preventing interference with existing GPG configurations.1  
  2. Prompt for user details: Real Name, Email Address, and an optional Comment. These form the User ID (UID).  
  3. Prompt securely (e.g., using read -s) for a strong master key passphrase. Consider integrating a passphrase generator or suggesting tools like pwgen or diceware.1  
  4. Generate the master key using gpg --expert --full-gen-key or gpg --full-generate-key. The script should allow selection of key type (e.g., RSA, or specific ECC options like "RSA (sign only)" or "ECC (sign and certify)") and specify "Certify-only" capability for the master key. Key size (e.g., 4096 for RSA) and expiration date (e.g., "1y") should be configured.1  
  5. Automatically add Sign, Encrypt, and Authenticate subkeys using gpg --expert --edit-key $KEYID and the addkey command. These subkeys should inherit or be configured with compatible algorithms/sizes and the same expiration date as the master key.1  
  6. Immediately after master key generation, create a revocation certificate using gpg --gen-revoke $KEYID.1 The script must instruct the user to print this certificate and/or store it in multiple, highly secure, offline locations, *separate* from the master key backup itself.  
  7. **Idempotency:** True idempotency in key generation is complex. If a key with the same UID already exists, gpg --full-generate-key may create an additional key or require interactive confirmation. The script should first check if a key for the provided UID exists (e.g., gpg --list-keys <UID>). If found, it should inform the user and offer options: exit, proceed with generating a new key (which might be for a different UID or after manual deletion of the old one by the user), or attempt to use the existing key if suitable for the subsequent steps (though this adds complexity). This check prevents accidental duplication.  
* **Secure Passphrase Handling:** The script must emphasize the importance of strong, unique passphrases for the master key. The passphrase protects the master key when it's stored, even if encrypted.

The script translates GPG best practices 16 and procedural steps 1 into an automated workflow, reducing the likelihood of manual errors.

### **3.3 Moving GPG Subkeys to the YubiKey**

Once the master key and subkeys are generated, the subkeys are moved to the YubiKey's OpenPGP applet.

* **YubiKey OpenPGP Applet Preparation:**  
  1. The script should use gpg --card-edit to interact with the YubiKey.  
  2. **PIN Management:** It is critical to change the default YubiKey OpenPGP PINs: User PIN (default: 123456) and Admin PIN (default: 12345678).1 The script should prompt the user for new, strong, unique PINs and apply them using the passwd command within gpg --card-edit (admin mode). For idempotency, the script could check if PINs are default (though this is hard to do reliably with gpg alone; ykman openpgp info might offer clues if ykman integration is considered for this part) or simply offer to perform the PIN change, warning the user if they've already set them.  
  3. Optionally, the script can set cardholder information (name, login, etc.) using commands like name, login within gpg --card-edit.1  
  4. For a strictly idempotent clean slate, ykman openpgp reset could be used (with explicit user confirmation due to its destructive nature) before provisioning, ensuring the applet is in a factory default state.  
* **Bash Script for keytocard:**  
  1. The script will automate the gpg --edit-key $KEYID sequence.  
  2. Within the edit-key interface, it will select each subkey in turn (e.g., key 1, key 2, key 3) and use the keytocard command to move it to the corresponding slot on the YubiKey (Signature, Encryption, Authentication).1  
  3. **Critical Step - Handling "Save changes?":** After each keytocard operation (or after all are done and quit is issued), GPG prompts "Save changes? (y/N)". The script must ensure this is answered with "N" (No).2 This is a nuanced but vital step: answering "N" prevents GPG from deleting the local copy of the private subkey material (or its stub). This local copy is essential for backing up the subkeys or for provisioning a second "cloned" YubiKey with the same subkeys. If "Y" is selected, GPG might remove the local private key, assuming it now resides solely on the card, hindering backup options.  
* **Verification:** After the keytocard operations, the script should execute gpg -K (or gpg --list-secret-keys) and verify (or instruct the user to verify) that the subkeys (ssb) are now marked with > (e.g., ssb>), indicating they are stubs for keys stored on a smartcard.1

This automated process ensures the subkeys are securely transferred to the YubiKey, making them available for daily cryptographic operations while being protected by the hardware token.

### **3.4 Securing the Offline GPG Master Key**

The security of the entire GPG identity rests upon the master key. Its offline backup must be meticulously secured.

* **Exporting the Master Key:** The key generation script (from 3.2) should also facilitate the export of the master private key:  
  ```bash
  gpg --export-secret-keys --armor $KEYID > master-key.priv.asc
  ```
  It's also prudent to export the public key:  
  ```bash
  gpg --export --armor $KEYID > public-key.asc
  ```
  And, as mentioned, the revocation certificate:  
  ```bash
  # (already generated, e.g., revocation.asc)
  ```
* **Encryption of the Exported Private Key:** The master-key.priv.asc file itself is already encrypted with the master key passphrase chosen during generation. However, for an additional layer of security, the storage medium itself should be encrypted (e.g., a LUKS-encrypted USB drive or a VeraCrypt container).1 This protects the key even if the storage medium is lost or stolen and the master key passphrase were somehow compromised. This encrypted volume should use a *different, very strong* passphrase than the GPG master key passphrase.  
* **Physical Storage:**  
  * Store the encrypted medium containing master-key.priv.asc, public-key.asc, and revocation.asc (though the revocation certificate is often recommended to be stored separately from the primary master key backup) in multiple, reliable offline locations.  
  * Examples include physically secure locations like a home safe and a bank deposit box, ensuring geographical separation if possible to protect against localized disasters.1  
* **Digital Storage (with Extreme Caution):** Storing the *encrypted* master key file in a highly reputable password manager's secure notes or a trusted encrypted cloud storage service can be considered as a tertiary backup. The security of this approach hinges entirely on the strength of the password manager's master password or the cloud storage encryption and access controls. The primary backups should always be offline.  
* **Regular Verification:** Periodically (e.g., annually or when renewing keys), verify that the backups are readable. This involves accessing the offline storage, decrypting the volume, and attempting to import the master key into a temporary, air-gapped GPG environment to ensure its integrity.

The offline master key backup is the ultimate recovery mechanism for the GPG identity. If a YubiKey is lost or subkeys are compromised, the master key is required to issue new subkeys or revoke old ones.18 The effort invested in its security is therefore critical. The potential difficulty in accessing a very securely stored master key when needed highlights the need for a balance between extreme security and practical recoverability, making well-documented procedures and redundant backups essential.

## **4. Part 2: Leveraging AGE with YubiKey for Modern Encryption**

AGE (Actually Good Encryption) is a modern encryption tool designed for simplicity and security, offering an alternative to GPG for certain use cases, particularly file encryption.5 The age-plugin-yubikey allows AGE identities to be stored on a YubiKey, combining AGE's ease of use with hardware-backed key security.

### **4.1 Introduction to AGE and age-plugin-yubikey**

* **AGE Simplicity and Security:** AGE aims to provide a straightforward and secure file encryption experience, avoiding the extensive feature set and historical complexities of OpenPGP.5 It uses modern cryptographic primitives like X25519 for key exchange and ChaCha20-Poly1305 for authenticated encryption.  
* **age-plugin-yubikey Functionality:**  
  * This plugin enables AGE to use private keys generated and stored on a YubiKey's PIV (Personal Identity Verification) applet.7 This is distinct from the OpenPGP applet used by GPG. This separation means GPG keys and YubiKey-held AGE keys are managed independently and reside in different secure areas of the device, each potentially protected by different PINs.  
  * The PIV applet provides several "slots" typically used for X.509 certificates and their associated private keys. age-plugin-yubikey utilizes one of these PIV slots, often a "retired" slot (e.g., slots 9a, 9c, 9d, 9e, or the range 82-95) to store an ECDSA P-256 private key used for the AGE identity.8  
  * When an AGE identity is created on the YubiKey, age-plugin-yubikey generates an "identity file" (e.g., yubikey-identity.txt). This file is crucial: it contains metadata, such as the YubiKey's serial number and the PIV slot used, which allows age (via the plugin) to locate and use the correct private key on the YubiKey.8 Importantly, this identity file does *not* contain the private key itself; the private key remains securely on the YubiKey. Losing the identity file is an inconvenience (it can be regenerated if the YubiKey serial and slot are known), but losing the YubiKey means losing access to the actual private key material.

### **4.2 Scripting AGE Identity Setup on YubiKey**

Automating the setup of an AGE identity on a YubiKey involves preparing the PIV applet and then using age-plugin-yubikey to generate the key.

* **PIV Applet Preparation with ykman:**  
  1. The script should use ykman piv info to check the current status of the PIV applet and its slots.  
  2. **Idempotency and Slot Management:** Before generating a new AGE key in a PIV slot, the script must ensure the slot is available or can be made available. If the script is rerun, the target slot might already contain a key.  
     * The script could check if a certificate/key already exists in the target slot using ykman piv certificates list <SLOT> and ykman piv keys list <SLOT>.  
     * If the slot is occupied and needs to be reused, the script should, after user confirmation, delete the existing certificate and key using ykman piv certificates delete <SLOT> and ykman piv keys delete <SLOT>.22  
     * Alternatively, for a guaranteed clean state (again, with user confirmation due to its destructive nature), ykman piv reset can be used to wipe the entire PIV applet, restoring it to factory defaults.22 This makes subsequent provisioning steps highly idempotent.  
  3. **PIV PIN/PUK Management:** The script should guide the user to change the default PIV PIN (default: 123456) and PUK (default: 12345678) to strong, unique values using ykman piv access change-pin and ykman piv access change-puk.4 The PIV Management Key should also be changed from its default and ideally protected by the PIN and touch.4  
* **Generating AGE Identity with age-plugin-yubikey:**  
  1. The script will invoke age-plugin-yubikey --generate to create the ECDSA P-256 key directly on the YubiKey in a specified PIV slot.7 The user should be able to specify:  
     * --serial SERIAL: The serial number of the target YubiKey, if multiple are connected.  
     * --slot SLOT: The PIV slot to use (e.g., 9a, 9c, or one from 82-95).  
     * --pin-policy PIN-POLICY: Defines when the PIV PIN is required (e.g., once per session, always for every operation, never).7  
     * --touch-policy TOUCH-POLICY: Defines when a physical touch of the YubiKey is required (e.g., always, cached for ~15 seconds, never).4 A PIN policy of once with a touch policy of cached often strikes a good balance between security and usability.4  
  2. The script must capture the output from age-plugin-yubikey --generate, which includes the AGE recipient string (the public key, starting age1yubikey1...) and the content for the identity file.  
* **Saving the Identity File:** The script should save the identity file content to a well-known and secure location, for example, ~/.config/sops/age/yubikey-identity.txt or a project-specific path. This file is essential for SOPS and other age clients to use the YubiKey-backed identity.8

**Table: AGE Identity Configuration on YubiKey**

| Parameter | Script Option/Variable | Recommended Value/Choice | Description |
| :---- | :---- | :---- | :---- |
| YubiKey Serial | --serial | (Auto-detect if one YK) / User-specified | Targets a specific YubiKey if multiple are present. |
| PIV Slot | --slot | 9a, 9c, 9d, 9e, or 82-95 (retired slots) | Specifies the PIV slot for the AGE key. 8 |
| PIV PIN | (Interactive Prompt) | Strong, unique 6-8 character alphanumeric PIN | Protects access to PIV operations. Changed via ykman. 4 |
| PIN Policy | --pin-policy | once (per session) | Determines how often the PIV PIN is required for operations. 8 |
| Touch Policy | --touch-policy | cached (touch required, cached for ~15s) or always | Determines if physical touch is required. 8 |
| Identity File Path | (Script Output Path) | ~/.config/sops/age/yubikey-identity.txt or project-local | Location to save the AGE identity file (pointer to the YubiKey key). 8 |

This scripted approach simplifies the creation of hardware-backed AGE identities, making them accessible for tools like SOPS.

## **5. Part 3: Integrating YubiKey with SOPS for Secret Management**

SOPS (Secrets OPerationS) is a powerful tool for managing secrets by encrypting values within structured files like YAML or JSON. It can integrate with YubiKey-backed GPG keys and AGE identities, providing a secure and convenient workflow for handling sensitive configuration data.

### **5.1 SOPS Overview and Key Management**

* **SOPS Functionality:** SOPS encrypts specific values within files, leaving the overall structure intact. This means a YAML file, for instance, remains a valid YAML file, but sensitive fields are replaced with encrypted blobs.9  
* **Key Groups and Creation Rules:** The core of SOPS configuration is the .sops.yaml file. This file defines creation_rules that specify which cryptographic keys (GPG fingerprints, AGE recipients, cloud KMS keys, etc.) should be used to encrypt secrets. These rules can be targeted to specific files or paths using path_regex.9 A single secret can be encrypted for multiple recipients, allowing different users or systems (each with their own key) to decrypt it.  
* **Automatic Decryption:** When a SOPS-encrypted file is opened with sops <filename> (which typically invokes $EDITOR), SOPS transparently decrypts the encrypted values, provided the necessary decryption key is available (e.g., GPG subkey on YubiKey, AGE identity on YubiKey with SOPS_AGE_KEY_FILE set).10 This seamless experience is a key advantage of SOPS.

SOPS acts as an abstraction layer over various encryption backends. Whether using a YubiKey-held GPG subkey or a YubiKey-held AGE identity, the user interaction with SOPS (sops edit...) remains largely consistent once the initial setup is complete.

### **5.2 Configuring SOPS for YubiKey-backed GPG Decryption**

To use GPG subkeys stored on a YubiKey with SOPS:

* **.sops.yaml Configuration:** The .sops.yaml file must list the GPG fingerprint of the encryption subkey that resides on the YubiKey as a PGP recipient. Example:  
  ```yaml
  creation_rules:
    - path_regex: 'secrets/.*.yaml'
      pgp: 'YOUR_GPG_ENCRYPTION_SUBKEY_FINGERPRINT'
  ```
  Replace YOUR_GPG_ENCRYPTION_SUBKEY_FINGERPRINT with the actual fingerprint of the GPG encryption subkey that was moved to the YubiKey in Part 1.10  
* **Workflow:**  
  * **Encryption:** To encrypt a new secret file or add encrypted values, SOPS uses the public key corresponding to the specified fingerprint. This public key should be in the local GPG keyring.  
    ```bash
    sops --encrypt --pgp YOUR_GPG_ENCRYPTION_SUBKEY_FINGERPRINT -i mysecrets.yaml
    # Or, if.sops.yaml is configured, simply edit:
    # sops mysecrets.yaml
    ```
  * **Decryption/Editing:** When sops mysecrets.yaml is executed, SOPS invokes gpg. gpg then communicates with gpg-agent, which handles the interaction with the YubiKey's OpenPGP applet. The user will be prompted for their YubiKey User PIN to authorize the decryption operation.11 The gpg-agent (often in conjunction with scdaemon and pcscd) is the critical intermediary facilitating this hardware interaction.11 If gpg-agent is not correctly configured or running, decryption will fail.

### **5.3 Configuring SOPS for YubiKey-backed AGE Decryption**

To use AGE identities stored on a YubiKey (via age-plugin-yubikey) with SOPS:

* **.sops.yaml Configuration:** The .sops.yaml file must list the AGE recipient public key (the string starting with age1yubikey1...) associated with the identity on the YubiKey. Example:  
  ```yaml
  creation_rules:
    - path_regex: 'secrets/.*.yaml'
      age: 'age1yubikey1qg8nf40dfw4gprmywplggtg2wuvv55fcmujzrm65z8s3j6rhwje2vm3hhs7'
  ```
  This public key is obtained when generating the AGE identity on the YubiKey (Part 2) or by running age-plugin-yubikey --list.6  
* **Environment Variables / Identity File:** For SOPS to decrypt using a YubiKey-held AGE identity, it needs to know where the corresponding AGE *identity file* (the pointer generated in Part 2, e.g., yubikey-identity.txt) is located. This is typically achieved by setting the SOPS_AGE_KEY_FILE environment variable 6:  
  ```bash
  export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/yubikey-identity.txt"
  ```
  Mise can manage this environment variable, setting it appropriately when tasks are run or the environment is activated. This identity file is the crucial bridge that allows SOPS (via age and age-plugin-yubikey) to find and use the correct key on the specific YubiKey.8  
* **Workflow:**  
  * **Encryption:**  
    ```bash
    sops --encrypt --age age1yubikey1qg8nf40dfw4gprmywplggtg2wuvv55fcmujzrm65z8s3j6rhwje2vm3hhs7 -i mysecrets.yaml
    # Or, if.sops.yaml is configured, simply edit:
    # sops mysecrets.yaml
    ```
  * **Decryption/Editing:** When sops mysecrets.yaml is executed (and SOPS_AGE_KEY_FILE is correctly set), SOPS calls age. The age tool, in turn, invokes age-plugin-yubikey using the information from the identity file. The plugin then interacts with the YubiKey's PIV applet, potentially prompting for the PIV PIN and/or touch confirmation, depending on the policies set during AGE identity generation.7

**Table: SOPS Configuration Examples (.sops.yaml)**

| Scenario | .sops.yaml Snippet | Required Environment Variables (Example) |
| :---- | :---- | :---- |
| GPG with YubiKey Encryption Subkey | creation_rules:<br/>- pgp: 'FINGERPRINT_OF_YK_GPG_ENC_SUBKEY' | (None specific to SOPS, relies on gpg-agent) |
| AGE with Single YubiKey | creation_rules:<br/>- age: 'age1yubikey1primary...' | SOPS_AGE_KEY_FILE=/path/to/primary_yubikey.txt |
| AGE with Primary & Backup YubiKeys | creation_rules:<br/>- age: >-<br/>age1yubikey1primary...,<br/>age1yubikey1backup... | SOPS_AGE_KEY_FILE=/path/to/current_yubikey.txt (needs to point to the identity file of the YubiKey being used for decryption) |

For the "AGE with Primary & Backup YubiKeys" scenario, the SOPS_AGE_KEY_FILE should point to the identity file of the YubiKey currently plugged in and intended for decryption. SOPS will try all configured age identities from SOPS_AGE_KEY_FILE. If multiple identity files are needed (e.g. one for a local key, one for a yubikey), SOPS_AGE_KEY_FILE can be a comma-separated list of paths.

### **5.4 Mise Integration for SOPS Workflows**

Mise can streamline SOPS operations by defining tasks in mise.toml. These tasks ensure the correct environment (tool versions, SOPS_AGE_KEY_FILE variable) is active.

* **Mise Tasks for SOPS:** Example mise.toml tasks:  
  ```ini
  # Example mise.toml tasks
  [[env]]
  # Define a default path for the YubiKey AGE identity file
  # This can be overridden per project or by user config
  SOPS_AGE_KEY_FILE = "~/.config/sops/age/yubikey-identity.txt"

  [tasks.sops-edit]
  description = "Edit an encrypted SOPS file"
  run = "sops {{arg(name='file')}}"
  # Example: mise run sops-edit secrets/myconfig.yaml

  [tasks.sops-encrypt-file]
  description = "Encrypt a SOPS file in place"
  run = "sops --encrypt -i {{arg(name='file')}}"
  # Example: mise run sops-encrypt-file secrets/myconfig.yaml

  [tasks.sops-decrypt-file]
  description = "Decrypt a SOPS file in place"
  run = "sops --decrypt -i {{arg(name='file')}}"
  # Example: mise run sops-decrypt-file secrets/myconfig.yaml
  ```
  These tasks 30 provide a standardized way to interact with SOPS, abstracting away the need for users to manually set environment variables or remember specific command flags. This is particularly beneficial in team environments, ensuring consistency and reducing errors. For instance, different tasks could be defined to use different SOPS_AGE_KEY_FILE paths if a project involves multiple distinct YubiKey identities (e.g., for different environments or roles).

## **6. Part 4: Comprehensive YubiKey Backup and Recovery Strategies**

While YubiKeys provide robust hardware security for private keys, they are physical devices susceptible to loss, damage, or failure. Therefore, comprehensive backup and recovery strategies are essential.

### **6.1 Backing Up GPG Keys**

* **Offline Master Key Backup:** As detailed in Section 3.4, the encrypted GPG master private key file (master-key.priv.asc), its corresponding public key (public-key.asc), and the revocation certificate (revocation.asc) are the most critical components. These must be stored securely offline, ideally on encrypted media in multiple, geographically separate locations.1  
* **Subkey Stubs Backup:** After moving subkeys to the YubiKey using keytocard (and crucially, answering "N" to "Save changes?" as per Section 3.3), the local ~/.gnupg directory (specifically files within private-keys-v1.d/) contains "stubs." These stubs are pointers indicating that the private key material resides on a smartcard.1 Backing up the entire ~/.gnupg directory (or at least private-keys-v1.d/, pubring.kbx, and trustdb.gpg) after YubiKey provisioning effectively backs up these stubs and the public keys. A more targeted backup can be made by exporting all secret keys and stubs:  
  ```bash
  gpg --export-secret-keys --armor $KEYID > all-private-keys-and-stubs.asc
  ```
  This exported file will contain the master private key (if it's in the keyring) and the stubs for the subkeys on the card. This file should also be encrypted and stored securely offline.  
* **The Role of the Master Key in Recovery:** The master private key is the ultimate backup for the GPG identity. If a YubiKey is lost or its OpenPGP applet becomes corrupted:  
  1. The master key can be used to revoke the compromised/lost subkeys.  
  2. New subkeys can be generated, certified by the master key, and moved to a new YubiKey.  
  3. If the private portions of the original subkeys were backed up *before* their initial transfer to any YubiKey (a more advanced and less common practice), the master key could be used to re-import these subkeys and then move them to a new YubiKey. This reinforces the paramount importance of the offline master key backup.

### **6.2 Backing Up AGE Identities (YubiKey-held)**

Backing up AGE identities stored on a YubiKey's PIV applet presents a different challenge because the private keys are designed to be non-exportable from the hardware.7

* **No Direct Key Export:** The AGE private key generated on the YubiKey via age-plugin-yubikey cannot be extracted.  
* **Strategy: Provisioning a Second (Backup) YubiKey:** The primary "backup" method involves having one or more additional YubiKeys.  
  * **For Decrypting the Same Data:** To allow a backup YubiKey to decrypt files originally encrypted for the primary YubiKey's AGE identity, those files must be encrypted to *both* YubiKeys' AGE recipients. This means the backup YubiKey will have its *own distinct* AGE private key.  
  * **Script for Provisioning Backup YubiKey (AGE):** The script from Section 4.2 can be re-run for the backup YubiKey. This will generate a *new* AGE private key on the backup YubiKey and a corresponding *new* identity file and public recipient string.  
* **Managing Multiple AGE Recipients in SOPS:** The .sops.yaml file must be updated to include the AGE recipient public keys from both the primary and any backup YubiKeys. This ensures that SOPS encrypts secrets such that any of the listed YubiKeys can decrypt them.28 Example .sops.yaml with primary and backup YubiKey AGE recipients:  
  ```yaml
  creation_rules:
    - age: >-
        age1yubikey1primary...,
        age1yubikey1backup...
  ```
* **AGE Identity File Backup:** The AGE identity file (e.g., yubikey-identity.txt) itself can and should be backed up. While it doesn't contain the private key, it's a useful pointer. If lost, it can be regenerated using age-plugin-yubikey --identity --serial <YUBIKEY_SERIAL> --slot <SLOT> provided the serial and slot are known.8

This backup strategy for YubiKey-held AGE keys shifts the focus from backing up key material to managing multiple recipients and ensuring data is encrypted for all necessary YubiKeys. The .sops.yaml file becomes a critical point of configuration for access control.

### **6.3 Creating a "Cloned" Backup YubiKey for GPG**

A "cloned" GPG YubiKey means having a second YubiKey loaded with the *exact same* GPG subkeys as the primary YubiKey. This is achievable if the private subkey material was preserved locally during the initial provisioning of the first YubiKey (by answering "N" to "Save changes?" after keytocard 2).

* **Procedure:**  
  1. **Ensure Subkey Availability:** Verify that the private portions of the GPG subkeys are still present in the local GPG keyring (e.g., in ~/.gnupg/private-keys-v1.d/) or can be restored from a backup that includes the master key and the original subkey private data (exported *before* any keytocard operation).  
  2. **Prepare Second YubiKey:** Initialize the backup YubiKey's OpenPGP applet: change default PINs, set cardholder attributes, etc., as detailed in Section 3.3. ykman openpgp reset can ensure a clean state.  
  3. **Transfer Subkeys:** Use gpg --edit-key $KEYID and the keytocard command sequence to move the *same* Sign, Encrypt, and Authenticate subkeys to the backup YubiKey.2 Again, answer "N" to "Save changes?" to preserve the local copies.  
* **Handling GPG Key Stubs:** GPG associates private key stubs with specific smartcard serial numbers. These associations are stored in files within ~/.gnupg/private-keys-v1.d/. When swapping between the primary and backup YubiKeys (which have different serial numbers but contain the same logical subkeys), GPG may become confused or try to access the wrong card.  
  * **Solution:** After inserting the backup YubiKey (or switching back to the primary), instruct GPG to "learn" the currently connected card. The command gpg-connect-agent "scd serialno" "learn --force" /bye forces gpg-agent to update its mapping of key stubs to the serial number of the inserted YubiKey.18 Alternatively, deleting the specific .key files from private-keys-v1.d/ and then running gpg --card-status will also cause GPG to re-learn the card association.18  
* **Bash Script for Backup GPG YubiKey Provisioning:** A script can automate the keytocard process for the backup YubiKey and then either run gpg-connect-agent "scd serialno" "learn --force" /bye or provide clear instructions for the user to do so.

This "cloning" is not a direct hardware-to-hardware copy (YubiKeys generally prevent private key export from the card 32). Instead, it's a software-driven re-provisioning of the same original key material onto a second device. The gpg-connect-agent learn --force command is the linchpin for making this setup work seamlessly when switching between YubiKeys.

### **6.4 Encrypted File Backups of Key Material**

Beyond YubiKey-specific backups, maintaining encrypted file backups of essential key material and configuration provides an additional layer of resilience.

* **What to Back Up as Files:**  
  * The GPG master private key export (master-key.priv.asc), already encrypted by its passphrase.  
  * The GPG revocation certificate (revocation.asc), stored unencrypted but within the larger encrypted backup.  
  * The exported GPG secret subkeys/stubs (all-private-keys-and-stubs.asc).  
  * All AGE identity files (e.g., yubikey-primary-age.txt, yubikey-backup-age.txt). These are not secret but are crucial for recovery and use.  
  * A plain text file containing all YubiKey PINs (OpenPGP User/Admin, PIV PIN), PUKs (OpenPGP Reset Code, PIV PUK), the YubiKey PIV Management Key, and the YubiKey device Lock Code.4 This file is extremely sensitive and *must* be robustly encrypted as part of the backup archive.  
  * Copies of relevant configuration files like ~/.gnupg/gpg.conf, ~/.gnupg/gpg-agent.conf, and .sops.yaml.  
* **Encryption Method:**  
  * Collect all these files into a single archive (e.g., a .tar.gz file).  
  * Encrypt this archive using AGE or GPG.  
    * If using GPG, encrypt it to a dedicated GPG key pair used *only* for backup purposes (and whose private key is also securely backed up!), or use symmetric encryption (gpg -c --cipher-algo AES256 archive.tar.gz) with a very strong, unique passphrase.  
    * If using AGE, encrypt it to one or more AGE recipients (e.g., a software AGE key backed up securely, or even a YubiKey-held AGE identity if the recovery scenario allows for its use).  
* **Storage:** Store this master encrypted archive in multiple secure locations:  
  * Offline: On encrypted USB drives, stored separately from primary YubiKeys and master key backups.  
  * Online (with caution): In a trusted, end-to-end encrypted cloud storage service. The security of this relies entirely on the strength of the archive's encryption and passphrase.

This multi-faceted file backup provides defense in depth. For instance, the PINs/PUKs file is critical; if YubiKeys and paper backups of PINs are lost or destroyed (e.g., in a fire), an offsite encrypted digital backup of this information can be a lifesaver, provided its encryption is sound and the decryption passphrase is recoverable.

## **7. Part 5: Idempotent Bash Scripts and Mise Task Orchestration**

To ensure reliable and repeatable setup and management of YubiKey-held keys, the automation scripts must be idempotent, and their execution should be managed by Mise.

### **7.1 Principles of Idempotent Scripting**

An idempotent operation, if performed multiple times, yields the same result as if performed only once. This is a crucial property for automation scripts to prevent unintended side effects or errors on subsequent runs.33

* **Techniques for Idempotency in Bash Scripts:**  
  * **State Checking:** Before performing an action, the script should check if the desired state already exists. For example:  
    * gpg -K | grep -q $KEYID_FINGERPRINT to check if a GPG key is in the keyring.  
    * ykman openpgp info or ykman piv info to check YubiKey applet status or specific slot configurations.  
    * age-plugin-yubikey --list to see if an AGE identity is already present on a connected YubiKey.  
  * **Conditional Execution:** Use if/then/else constructs based on the results of state checks to perform actions only when necessary.  
  * **Safe Creation/Deletion:** Employ commands that handle pre-existing or non-existent states gracefully. For example, mkdir -p /path/to/dir creates a directory if it doesn't exist and doesn't error if it does. For deletion, rm -f /path/to/file removes a file without erroring if it's missing, though careful error handling (rm file || true) is often preferred over suppressing errors with -f.33  
  * **Atomic Operations:** When modifying configurations, create the new version in a temporary file and then atomically move or rename it to the final destination.  
  * **Targeted Resets:** For YubiKey applets, achieving idempotency often means either checking the current configuration meticulously and skipping if correct, or (with user confirmation) resetting the applet to a known default state before re-provisioning. For example, ykman openpgp reset or ykman piv reset 22 can ensure a clean slate, making the subsequent provisioning steps inherently idempotent. This is a destructive action and must be handled with care, but it guarantees a predictable starting point.

### **7.2 Structure of the Provided Bash Scripts**

The Bash scripts for automating YubiKey GPG and AGE setup will be designed with modularity, configurability, and robustness in mind.

* **Modular Design:** Scripts will be organized by function:  
  * 01-generate-gpg-master-key.sh: Generates the offline GPG master key, subkeys, and revocation certificate.  
  * 02-provision-gpg-yubikey.sh: Prepares a YubiKey's OpenPGP applet and moves GPG subkeys to it.  
  * 03-backup-gpg-master-key.sh: Guides the user through securely backing up the GPG master key.  
  * 04-provision-age-yubikey.sh: Prepares a YubiKey's PIV applet and generates an AGE identity on it.  
  * 05-clone-gpg-yubikey.sh: Provisions a backup YubiKey with the same GPG subkeys as a primary.  
* **Configuration:** Scripts will use environment variables (potentially sourced from a project.conf file or passed by Mise tasks) for user-specific data like name, email, preferred key types/sizes, and target YubiKey serial numbers. This parameterization is key to reusability and applying scripts idempotently to different YubiKeys (primary, backup) or for different users.  
* **Error Handling:** Implement robust error handling using set -e (exit on error), set -o pipefail (fail if any command in a pipe fails), and trap commands to catch ERR and EXIT signals for cleanup or informative messages.33  
* **User Prompts & Confirmation:** For any destructive action (e.g., resetting a YubiKey applet, overwriting existing key files), the scripts will clearly explain the action and prompt the user for explicit confirmation.  
* **Logging:** Scripts will provide basic logging of significant actions performed and their outcomes.

### **7.3 Mise Task Definitions (mise.toml)**

Mise tasks will serve as the user-friendly interface to these Bash scripts, orchestrating their execution and ensuring the correct environment.

* **Orchestrating Scripts:** mise.toml will define tasks that call the individual Bash scripts.  
  ```ini
  # Example mise.toml tasks
  [[env]]
  # User-specifics, can be in .mise.local.toml or global config
  GPG_USER_NAME = "Your Name"
  GPG_USER_EMAIL = "your.email@example.com"
  PRIMARY_YUBIKEY_SERIAL = "1234567"
  BACKUP_YUBIKEY_SERIAL = "7654321"
  AGE_IDENTITY_FILE_PRIMARY = "~/.config/sops/age/yubikey_primary_id.txt"
  # Use primary by default for SOPS
  SOPS_AGE_KEY_FILE = "${AGE_IDENTITY_FILE_PRIMARY}" # Corrected syntax

  [tasks.generate-gpg-keys]
  description = "Generate new GPG master key and subkeys."
  run = "./scripts/core/01-generate-gpg-master-key.sh"
  # Env vars like GPG_USER_NAME, GPG_USER_EMAIL are inherited from the global [env] or .env files

  [tasks.provision-primary-gpg-yubikey]
  description = "Provision primary YubiKey with GPG subkeys."
  depends = ["generate-gpg-keys"] # Example dependency
  run = "./scripts/core/02-provision-gpg-yubikey.sh --serial {{env.PRIMARY_YUBIKEY_SERIAL}}"

  [tasks.provision-primary-age-yubikey]
  description = "Provision primary YubiKey with an AGE identity."
  run = "./scripts/core/04-provision-age-yubikey.sh --serial {{env.PRIMARY_YUBIKEY_SERIAL}} --output {{env.AGE_IDENTITY_FILE_PRIMARY}}"

  #... other tasks for backup, SOPS editing, etc....
  ```
* **Task Dependencies:** Mise's depends array can define execution order (e.g., GPG keys must be generated before they can be moved to a YubiKey).31  
* **Passing Parameters:** Mise task arguments or environment variables defined in mise.toml can be passed to the Bash scripts.6  
* **Environment Management:** Mise tasks automatically run within the Mise-managed environment, ensuring the correct versions of ykman, age, etc., are used (gpg is system-managed).6 Tasks can also set specific environment variables required by the scripts, like SOPS_AGE_KEY_FILE.

By using Mise tasks, complex multi-step operations are simplified into single commands (e.g., mise run provision-new-yubikey), improving usability, reducing errors, and standardizing workflows, especially in team settings.

**Table: Example Mise Task Definitions for Key Operations**

| Task Name (Mise) | Brief Description | Bash Script Called (Example) | Key mise.toml Elements |
| :---- | :---- | :---- | :---- |
| generate-gpg-keys | Generate GPG master key, subkeys, revocation cert. | 01-generate-gpg-master-key.sh | run, env (for user details) |
| provision-gpg-yubikey | Move GPG subkeys to a specified YubiKey. | 02-provision-gpg-yubikey.sh | run (with --serial arg), depends (on generate-gpg-keys) |
| backup-gpg-master | Guide secure backup of GPG master key. | 03-backup-gpg-master-key.sh | run, depends (on generate-gpg-keys) |
| provision-age-yubikey | Generate AGE identity on a specified YubiKey. | 04-provision-age-yubikey.sh | run (with --serial, --output args for identity file) |
| sops-edit-secret | Edit a SOPS-encrypted file using configured YubiKey. | (Direct sops command) | run = "sops {{arg(name='file')}}" env (to set SOPS_AGE_KEY_FILE if using AGE) |
| clone-gpg-to-backup-yubikey | Provision backup YubiKey with same GPG subkeys. | 05-clone-gpg-yubikey.sh | run (with --serial for backup YK), depends (on generate-gpg-keys) |

## **8. Security Best Practices and Considerations**

Maintaining the security of YubiKey-held cryptographic keys involves adherence to several best practices across hardware, software, and user behavior.

* **YubiKey PINs, PUKs, and Management Keys:**  
  * Change all default PINs immediately upon receiving a YubiKey or resetting an applet. Use strong, unique PINs for the OpenPGP applet (User PIN, Admin PIN) and the PIV applet (PIN).4  
  * Securely store the PUKs (PIN Unblocking Keys) for both OpenPGP (Reset Code) and PIV. If a PIN is entered incorrectly too many times, the PUK is needed to unblock it. If the PUK is also entered incorrectly too many times, the applet may become permanently blocked or reset, potentially leading to loss of access to the keys on that applet.25  
  * Change the default YubiKey PIV Management Key. This key controls administrative functions on the PIV applet, such as generating keys or importing certificates. Protect the new management key, for instance, by requiring PIN and touch confirmation for its use, configurable via ykman piv access change-management-key --protect.4  
* **YubiKey Lock Code:** Set a YubiKey device lock code using ykman config set-lock-code. This code protects the overall YubiKey configuration, preventing unauthorized enabling or disabling of its various applications (OpenPGP, PIV, FIDO, etc.) if the YubiKey is left unattended in an unlocked computer.4  
* **Touch Policies:** Configure touch policies for sensitive operations.  
  * For GPG subkeys, use ykman openpgp keys set-touch <KEY_SLOT> <POLICY> (e.g., cached or on) to require a physical touch for signing, decryption, or authentication.4  
  * For AGE PIV keys, specify the touch policy (e.g., --touch-policy cached or --touch-policy always) during generation with age-plugin-yubikey 8, or use ykman piv keys generate... --touch-policy <POLICY> if generating PIV keys directly with ykman. This ensures that even if a system is compromised and the PIN is known, operations cannot be performed without physical interaction.  
* **Physical Security:** Treat YubiKeys like any other valuable physical key. Protect them from theft, loss, and damage. Keep backup YubiKeys and offline master key backups in physically secure, preferably geographically separate, locations.  
* **Software Updates:** Regularly update all related software: GnuPG, AGE, age-plugin-yubikey, SOPS, ykman, Mise, and the operating system. Updates often include security patches for known vulnerabilities.16  
* **Revocation Certificates (GPG):** Ensure the GPG master key revocation certificate is generated during initial key setup, printed, and stored in multiple secure, offline locations, separate from the master key backup itself.1 This allows the master key to be marked as invalid if it's ever compromised or lost.  
* **Least Privilege:** Only load necessary keys onto YubiKeys. For extremely sensitive or distinct roles, consider using separate YubiKeys.  
* **Regular Review:** Periodically (e.g., annually):  
  * Review GPG and AGE key expiration dates and renew them before they expire.  
  * Test backup and recovery procedures to ensure they work as expected.  
  * Re-evaluate the overall security posture and update practices based on new threats or recommendations.

The combination of these practices creates a layered security model. If one layer is breached (e.g., a PIN is compromised), other layers (like touch policies or the physical security of the offline master key) provide continued protection or enable recovery. However, no amount of technical security can compensate for poor user discipline. Maintaining the secrecy of PINs, the physical security of the YubiKeys and backups, and adhering to regular review processes are critical human factors.

## **9. Troubleshooting Common Issues**

Encountering issues during setup or use is common. This section outlines potential problems and diagnostic steps.

* **YubiKey Not Detected by System/GPG/AGE:**  
  * **pcscd Service (Linux/macOS):** Ensure the pcscd (PC/SC Smart Card Daemon) service is installed and running. Check its status (systemctl status pcscd) and restart it if necessary.11  
  * **scdaemon (GPG):** GPG's scdaemon must be functioning correctly and able to communicate with pcscd. Errors like "No SmartCard daemon" or "Card not present" often point to issues here.11 Try gpg-connect-agent "scd serialno" /bye or gpg --card-status.  
  * **USB Connection:** Verify the YubiKey is securely plugged in. Try a different USB port or cable.  
  * **YubiKey Mode (CCID):** Ensure the CCID interface is enabled on the YubiKey for GPG and PIV operations. Use ykman config usb --enable CCID or check current modes with ykman config usb --list.  
  * **Driver Issues (Windows):** Ensure appropriate YubiKey drivers (e.g., Minidriver) are installed.  
* **GPG Errors:**  
  * **"No secret key" / "Decryption failed: No secret key":**  
    * YubiKey not inserted or not recognized.  
    * gpg-agent not running or not configured correctly (ensure use-agent is in gpg.conf).  
    * Incorrect key selected for operation.  
    * Key stubs might be pointing to the wrong card serial if using multiple YubiKeys (use gpg-connect-agent "scd serialno" "learn --force" /bye after inserting the correct card).18  
  * **PIN Prompts Not Appearing or Failing:**  
    * pinentry program issues. Ensure a pinentry program (e.g., pinentry-gtk-2, pinentry-curses, pinentry-mac) is installed and configured for gpg-agent.  
    * Incorrect PIN being entered. Too many wrong attempts will block the PIN.  
  * **gpg: card_construct_keyinfo failed: No such device or similar:** Often indicates scdaemon cannot find or communicate with the YubiKey via pcscd.  
* **AGE / age-plugin-yubikey Errors:**  
  * **Plugin Not Found:** Ensure age-plugin-yubikey binary is in the system PATH and executable.  
  * **PIV Applet Issues:**  
    * Incorrect PIV slot specified in the AGE identity file or during generation.  
    * PIV PIN required but not provided, or incorrect PIN.  
    * PIV Management Key issues if the operation requires it.  
    * PIV applet may need a reset (ykman piv reset) if misconfigured.  
  * **Specific age-plugin-yubikey error messages:** Consult the plugin's documentation or GitHub issues for known problems.  
* **SOPS Decryption Failures:**  
  * **Incorrect Key in .sops.yaml:** GPG fingerprint or AGE recipient in .sops.yaml does not match any available decryption key.  
  * **SOPS_AGE_KEY_FILE Issues (for AGE):**  
    * Variable not set.  
    * Path is incorrect or identity file is missing/corrupted.  
    * Identity file does not correspond to the YubiKey being used or the recipient in .sops.yaml.  
  * **Underlying GPG/AGE Errors:** SOPS will often propagate errors from the backend encryption tool. Check GPG or AGE logs/verbose output.  
* **Mise Task Failures:**  
  * **Script Errors:** The underlying Bash script called by the Mise task is failing. Enable verbose execution in the script (e.g., bash -x./myscript.sh) or add detailed logging to pinpoint the issue.  
  * **Tool Version Conflicts:** Unlikely if Mise is managing all tools (except system-provided ones like `gpg`), but ensure `mise doctor` reports a healthy environment.  
  * **Incorrect Paths or Permissions:** Scripts might be trying to access files or directories with incorrect paths or insufficient permissions.  
* **General Debugging Steps:**  
  * **Increase Verbosity:** Most tools offer verbose or debug flags (e.g., gpg -vvv --debug-all, sops --debug, ykman --log-level DEBUG <command>).  
  * **Check Logs:** Review gpg-agent logs (often configured in gpg-agent.conf), system logs (journalctl), and any logs produced by the scripts themselves.  
  * **Isolate the Problem:** If a complex workflow (e.g., Mise task -> SOPS -> AGE -> YubiKey) fails, try each component individually (e.g., can age decrypt directly using the YubiKey? Can gpg access the card?).  
  * **ykman Diagnostics:** Use ykman info, ykman openpgp info, and ykman piv info to check the YubiKey's status and applet configurations.

## **10. Conclusion and Recommendations**

The integration of YubiKeys with GPG, AGE, and SOPS, orchestrated by Mise and automated with idempotent Bash scripts, offers a robust and secure framework for managing cryptographic keys and secrets. This approach significantly enhances security by moving private key operations to hardware tokens, mitigating risks associated with software-based key storage.

**Key Achievements of this Methodology:**

1. **Enhanced GPG Security:** By establishing an offline master key strategy and moving operational GPG subkeys to the YubiKey, the core identity is protected from online threats, while daily cryptographic tasks remain convenient and secure.1  
2. **Modern Encryption with AGE on YubiKey:** The use of age-plugin-yubikey allows modern, simple AGE encryption to benefit from hardware-backed keys stored on the YubiKey's PIV applet, providing an alternative to GPG for specific use cases.7  
3. **Secure Secret Management with SOPS:** SOPS provides a seamless workflow for editing and managing encrypted configuration files, transparently leveraging YubiKey-held GPG or AGE keys for decryption.6  
4. **Robust Backup and Recovery:** The guide outlines comprehensive strategies for backing up GPG master keys, GPG subkey configurations (for "cloning" to a backup YubiKey), and managing AGE identities across multiple YubiKeys. Encrypted file backups of critical metadata like PINs and identity file pointers add another layer of resilience.4  
5. **Automation and Idempotency:** The development of idempotent Bash scripts, managed and executed by Mise, ensures that the setup and provisioning processes are repeatable, reliable, and less prone to human error.30

**Recommendations for Implementation:**

* **Phased Adoption:** Implement these measures in stages, starting with GPG key setup and YubiKey provisioning, followed by AGE, and then SOPS integration. Thoroughly test each stage.  
* **User Training:** If deploying in a team, ensure users understand the security principles, the importance of PIN management, physical YubiKey security, and backup procedures.  
* **Secure Environment for Initial Setup:** Perform initial GPG master key generation and sensitive backup operations in a trusted, preferably offline (air-gapped), environment to minimize any risk of compromise during these critical steps.1  
* **Regular Audits and Testing:** Periodically audit key configurations, test backup restoration procedures, and review access controls for SOPS-managed secrets. Ensure key expiration dates are tracked and keys are renewed in a timely manner.  
* **Customize Scripts:** While the provided scripts will aim for general applicability, review and customize them to fit specific environmental constraints or organizational policies. Pay close attention to paths, permissions, and default settings.  
* **Prioritize Offline Backups:** Emphasize the critical importance of offline, encrypted backups for the GPG master key and other sensitive materials. These are the ultimate safeguard against catastrophic data loss or identity compromise.

By diligently following the procedures and best practices outlined in this guide, individuals and organizations can establish a highly secure, manageable, and resilient system for their cryptographic keys and secrets, leveraging the powerful combination of YubiKeys, GPG, AGE, SOPS, and Mise. The initial investment in careful setup and automation pays significant dividends in long-term security and operational efficiency.

#### **Works cited**

1. GnuPG offline Master key using a YubiKey (for Arch Linux) · GitHub, accessed May 9, 2025, https://gist.github.com/fervic/ad30e9f76008eade565be81cef2f8f8c  
2. Using Your YubiKey with OpenPGP – Yubico, accessed May 9, 2025, https://support.yubico.com/hc/en-us/articles/360013790259-Using-Your-YubiKey-with-OpenPGP  
3. drduh/YubiKey-Guide: Community guide to using YubiKey for GnuPG and SSH - protect secrets with hardware crypto. - GitHub, accessed May 9, 2025, https://github.com/drduh/YubiKey-Guide  
4. An Opinionated YubiKey Set-Up Guide | Pro Custodibus, accessed May 9, 2025, https://www.procustodibus.com/blog/2023/04/how-to-set-up-a-yubikey/  
5. age(1) - Arch Linux manual pages, accessed May 9, 2025, https://man.archlinux.org/man/age.1.en  
6. Secrets | mise-en-place, accessed May 9, 2025, https://mise.jdx.dev/environments/secrets.html  
7. age-plugin-yubikey - crates.io: Rust Package Registry, accessed May 9, 2025, https://crates.io/crates/age-plugin-yubikey/0.3.3  
8. str4d/age-plugin-yubikey - GitHub, accessed May 9, 2025, https://github.com/str4d/age-plugin-yubikey  
9. getsops/sops: Simple and flexible tool for managing secrets - GitHub, accessed May 9, 2025, https://github.com/getsops/sops  
10. A Comprehensive Guide to SOPS: Managing Your Secrets Like A Visionary, Not a Functionary - GitGuardian Blog, accessed May 9, 2025, https://blog.gitguardian.com/a-comprehensive-guide-to-sops/  
11. Argo-cd, sops, ksops, yubikey? : r/kubernetes - Reddit, accessed May 9, 2025, https://www.reddit.com/r/kubernetes/comments/1hw2drs/argocd_sops_ksops_yubikey/  
12. Yubikey OpenPGP Setup for SSH and Commit Signing - Tethik's weblog - Joakim Uddholm, accessed May 9, 2025, https://joakim.uddholm.com/yubikey-openpgp-setup-for-ssh-and-commit-signing/  
13. Walkthrough | mise-en-place, accessed May 9, 2025, https://mise.jdx.dev/walkthrough.html  
14. Dev Tools | mise-en-place, accessed May 9, 2025, https://mise.jdx.dev/dev-tools/  
15. OfflineMasterKey - Debian Wiki, accessed May 9, 2025, https://wiki.debian.org/OfflineMasterKey  
16. OpenPGP Best Practices - Riseup.net, accessed May 9, 2025, https://riseup.net/ru/security/message-security/openpgp/gpg-best-practices  
17. Gpg: Best practices - FVue, accessed May 9, 2025, https://www.fvue.nl/wiki/Gpg:_Best_practices  
18. gnupg - Create backup Yubikey with identical PGP keys ..., accessed May 9, 2025, https://security.stackexchange.com/questions/181551/create-backup-yubikey-with-identical-pgp-keys  
19. Age (Actually Good Encryption) - Asecuritysite.com, accessed May 9, 2025, https://asecuritysite.com/age/index  
20. I saw people starting to use `age` as a replacement to gpg. Can someone speak to... | Hacker News, accessed May 9, 2025, https://news.ycombinator.com/item?id=24376142  
21. tv42/yubage: `age-plugin-yubikey` implementation, encrypt ... - GitHub, accessed May 9, 2025, https://github.com/tv42/yubage  
22. PIV Commands — ykman CLI and YubiKey Manager GUI Guide ..., accessed May 9, 2025, https://docs.yubico.com/software/yubikey/tools/ykman/PIV_Commands.html  
23. How to Reset Your YubiKey and Create a Backup - Privacy Guides, accessed May 9, 2025, https://www.privacyguides.org/articles/2025/03/06/yubikey-reset-and-backup/  
24. Resetting the Smart Card (PIV) application on the YubiKey - Yubico Support, accessed May 9, 2025, https://support.yubico.com/hc/en-us/articles/360013645480-Resetting-the-Smart-Card-PIV-Application-on-Your-YubiKey  
25. The PIV PIN, PUK, and management key - Yubico Product Documentation, accessed May 9, 2025, https://docs.yubico.com/yesdk/users-manual/application-piv/pin-puk-mgmt-key.html  
26. Yubikey + gpg key + sops-nix : r/NixOS - Reddit, accessed May 9, 2025, https://www.reddit.com/r/NixOS/comments/1dbalru/yubikey_gpg_key_sopsnix/  
27. Working example of sops-nix with Yubikey? : r/NixOS - Reddit, accessed May 9, 2025, https://www.reddit.com/r/NixOS/comments/1dbsx17/working_example_of_sopsnix_with_yubikey/  
28. Secrets & Facts - Clan Documentation, accessed May 10, 2025, https://docs.clan.lol/getting-started/secrets/  
29. Nix secrets for dummies | Farid Zakaria's Blog, accessed May 9, 2025, https://fzakaria.com/2024/07/12/nix-secrets-for-dummies  
30. mise run | mise-en-place, accessed May 9, 2025, https://mise.jdx.dev/cli/run.html  
31. Tasks | mise-en-place, accessed May 9, 2025, https://mise.jdx.dev/tasks/  
32. How to back up credentials, accessed May 9, 2025, https://docs.yubico.com/yesdk/users-manual/application-oath/oath-backup-credentials.html  
33. How to write idempotent Bash scripts (2019) - Hacker News, accessed May 9, 2025, https://news.ycombinator.com/item?id=29483070  
34. Yubi key passwordless sign-in best practice : r/Intune - Reddit, accessed May 9, 2025, https://www.reddit.com/r/Intune/comments/1jzowxp/yubi_key_passwordless_signin_best_practice/
