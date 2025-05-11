# **Integrating SOPS with YubiKeys using AGE and GPG: A Comprehensive Guide to Secure Secret Management**

## **I. Introduction to Secure Secret Management with SOPS and YubiKeys**

### **A. The Challenge of Secret Management in Modern Workflows**

In contemporary software development and operations, the secure management of secrets—such as API keys, database credentials, private certificates, and encryption keys—is a paramount concern. The proliferation of distributed systems, microservices, and cloud infrastructure has increased the attack surface and the complexity of protecting sensitive information. Improper handling of secrets, including hardcoding them into source code, storing them in unencrypted configuration files, or transmitting them insecurely, can lead to severe security breaches, data loss, and reputational damage. Effective secret management is therefore not merely a best practice but a foundational requirement for robust and trustworthy systems.

### **B. Introducing the Core Tools**

This report focuses on integrating several powerful tools to establish a secure secret management workflow: SOPS, YubiKeys, AGE, and GPG.

* SOPS (Secrets OPerationS):  
  SOPS is an open-source editor of encrypted files that supports YAML, JSON, ENV, INI, and BINARY formats and encrypts only the values, leaving the keys in plaintext. Developed by Mozilla, SOPS simplifies the process of encrypting and decrypting structured data files.1 Its key benefits include the ability to store encrypted secrets safely in version control systems like Git and its support for multiple Key Management Services (KMS), including GPG, AGE, AWS KMS, GCP KMS, Azure Key Vault, and HashiCorp Vault.1 This flexibility makes SOPS a versatile solution for managing secrets across diverse environments.  
* YubiKeys (NFC v5+ Series):  
  YubiKeys are hardware security keys developed by Yubico, offering strong two-factor, multi-factor, and passwordless authentication, as well as cryptographic capabilities. For the purposes of this report, the relevant features of YubiKey 5 Series and newer models include the OpenPGP applet for GPG key storage 4, the PIV (Personal Identity Verification) applet which can be utilized by tools like age-plugin-yubikey 6, and the FIDO2 interface, which can also be leveraged by certain AGE plugins.8 A core security principle of YubiKeys is that private keys generated on-device or correctly transferred to the device are designed to be non-exportable, meaning the private key material should never leave the secure element of the hardware token.4  
* AGE (Actually Good Encryption):  
  AGE is a modern, simple, and secure encryption tool designed by Filippo Valsorda, often presented as a more straightforward alternative to GPG.1 AGE focuses on providing strong encryption with a minimal and easy-to-use interface, utilizing X25519 for key exchange, ChaCha20-Poly1305 for symmetric encryption, and HMAC-SHA256 for MACs. It supports a plugin architecture that allows for extending its capabilities, such as integrating with hardware security keys like YubiKeys through plugins like age-plugin-yubikey.6  
* GPG (GNU Privacy Guard):  
  GPG is a widely adopted and robust implementation of the OpenPGP standard, providing cryptographic privacy and authentication for data communication and storage.5 It is a highly flexible and feature-rich toolset, supporting a master key and subkey architecture, which is particularly useful for secure key management. GPG integrates well with smart cards, including YubiKeys, through their OpenPGP applet, allowing private keys (typically subkeys) to be stored and used on the hardware device.4

### **C. Report Objectives and Scope**

This report aims to provide a comprehensive technical guide for integrating SOPS with YubiKeys (specifically NFC v5+ models or equivalent) using either AGE or GPG as the encryption backend. It will address the common preference for off-device key generation to facilitate robust backup strategies, while also thoroughly explaining the procedures and implications of on-device key generation. A critical focus will be on the exportability (or lack thereof) of keys generated on YubiKeys and the resulting impact on backup capabilities. The scope includes detailed step-by-step instructions for key generation, YubiKey configuration, SOPS setup, and best practices for backup and recovery.

A central theme is the inherent difference between generating cryptographic keys externally (off-device) versus directly on a hardware token (on-device). Off-device generation provides the owner with direct access to the raw private key material at its inception, allowing for traditional backup methods. Conversely, on-device generation is designed to ensure the private key never exists outside the secure hardware, fundamentally altering what "backup" means; often, it refers to backing up metadata or configuration rather than the private key itself.4 This distinction is pivotal for understanding the trade-offs involved.

### **D. Key Insights & Hidden Connections**

The preference for off-device key generation, primarily for backup purposes, often stands in contrast to the maximum security model offered by on-device key generation, where keys are intended never to leave the hardware token. This report will navigate this apparent conflict by providing clear procedures for both approaches, transparently highlighting the respective security benefits and backup limitations.

The concept of "backup" itself requires careful contextualization. For keys generated off-device, a backup typically means a copy of the private key material. For keys generated on-device within a YubiKey, the private key material is generally non-exportable.4 In this scenario, any "backup" might pertain to configuration data or public key identifiers, but not the secret cryptographic material that would allow restoration on a different device if the original YubiKey is lost or damaged.6 Understanding this nuance is critical for setting realistic expectations regarding backup capabilities when using hardware security keys.

## **II. Key Generation Paradigms: Off-Device vs. On-Device**

The choice of where and how cryptographic keys are generated has profound implications for their security, manageability, and, crucially, their backup and recovery. This section explores the two primary paradigms: off-device and on-device key generation, particularly in the context of YubiKeys.

### **A. Off-Device Key Generation: Prioritizing Backup and Control**

Concept:  
Off-device key generation involves creating cryptographic keys on a trusted computer system, such as a user's desktop or a dedicated offline machine, rather than directly on the YubiKey. For GPG, this typically means generating a master key and associated subkeys using the GnuPG software.4 For AGE, it involves using the age-keygen utility to produce a key pair stored in a file.1  
Advantages:  
The primary advantage of off-device key generation is the full control it affords over the private key material at the moment of its creation. This allows for:

1. **Direct Backup:** The original private key material can be securely backed up *before* any interaction with a hardware token or its transfer to such a device.1  
2. **Flexibility:** The same master GPG key can be used to provision subkeys to multiple YubiKeys. With AGE, possessing the original private key file allows its use independently of any single hardware token.  
3. **Control over Generation Parameters:** Users have full control over key generation parameters, such as key type, size, and expiration, within the capabilities of the generation software.

Backup Implications:  
Backup is relatively straightforward. For GPG, the exported secret master key (and potentially subkeys before transfer) and revocation certificates are backed up.9 For AGE, the file containing the private key (e.g., keys.txt) is backed up.11 Standard secure backup practices, such as encryption of the backup media and offline storage in multiple locations, are essential.12  
Security Considerations:  
The security of keys generated off-device hinges on the security of the generation environment and the subsequent protection of the private key backups. For highly sensitive keys like a GPG master key, generation on a dedicated, air-gapped offline system (like Tails or a Debian Live USB) is strongly recommended to minimize exposure to malware or compromise.9 The integrity of the backups is equally critical; if a backup is compromised, the key is compromised.

### **B. On-Device YubiKey Key Generation: Maximizing Hardware Security**

Concept:  
On-device key generation involves creating cryptographic keys directly within the YubiKey's secure element. The private key material is generated by the YubiKey itself and is intended to remain confined to the hardware. For GPG, this is done using commands like gpg --card-edit followed by admin and generate.4 For AGE, plugins like age-plugin-yubikey facilitate the creation of AGE identities where the secret key material is stored in the YubiKey's PIV slots.6  
Advantages:  
The principal advantage is enhanced protection for the private key material:

1. **Hardware Confinement:** The private key is generated and stored within the YubiKey's secure cryptographic co-processor and is designed never to leave it. This offers strong protection against malware, keyloggers, or physical theft of the host computer's storage.4  
2. **On-Board Operations:** Cryptographic operations requiring the private key (e.g., decryption, signing) are performed by the YubiKey itself, further reducing the exposure of the key.15

Backup Implications (The Crucial Point):  
This is where the most significant trade-off occurs and directly addresses a core user concern:

1. **Fundamental Limitation:** Private key material generated *directly on* the YubiKey is generally **non-exportable by design**.4 This is a deliberate security feature of hardware tokens like YubiKeys, intended to prevent key exfiltration.  
2. **No Traditional Private Key Backup:** Consequently, it is typically not possible to create a traditional backup of the raw private key material if it was generated on-device. If the YubiKey is lost, damaged, or reset, the private key it uniquely holds is irrecoverable.  
3. **What Can Be "Backed Up"?** For on-device generated keys, any "backup" usually pertains to:  
   * **Public Keys:** The public part of the key pair can always be exported and backed up.  
   * **Metadata or Pointers:** For age-plugin-yubikey, the generated identity file is a reference that helps the plugin identify which key on the YubiKey to use; it is not the private key itself.6 Backing up this identity file aids in reconfiguring clients but does not enable private key recovery.  
   * **Revocation Certificates (GPG):** For GPG keys generated on-card, it's possible (and highly recommended) to generate a revocation certificate immediately after key generation and back it up securely. This allows the key to be marked as compromised if the YubiKey is lost, but it does not recover the key.

Security Considerations:  
While offering the highest level of protection for the key material against external threats, on-device generation creates a potential single point of failure if the YubiKey is the sole repository of an unrecoverable key. Loss of the YubiKey means loss of access to anything encrypted solely with that key.

### **C. The Fundamental Trade-off: On-Device Security vs. External Backup Capability**

There is an inherent trade-off: maximizing the security of a private key by confining it to a hardware security element (on-device generation) necessarily restricts or eliminates the possibility of traditional external backup of that raw private key material. Conversely, generating a key off-device allows for robust external backups but requires diligent protection of the generation environment and the backups themselves. The choice depends on the specific security requirements, risk tolerance for key loss versus key theft, and the operational model.

This distinction can be conceptualized as viewing the YubiKey either as a "vault" where the key is created, lives, and dies, or as a secure "co-processor" that performs operations with a key whose master copy or origin is managed and backed up elsewhere. The latter model aligns more closely with traditional backup paradigms. The preference for off-device generation is well-aligned with the goal of maintaining independent, robust backups of the primary key material, a strategy supported by GPG master key backup procedures 4 and standard AGE key file backup practices.

### **D. Table: YubiKey Key Generation Methods & Export/Backup Capabilities**

To clarify these differences, the following table summarizes key generation methods with YubiKeys and their implications for export and backup:

| Feature | GPG (Off-Device Master, Subkeys to YubiKey) | GPG (On-Device via gpg --card-edit generate) | AGE (Standard age-keygen on Desktop) | AGE (On-Device Identity via age-plugin-yubikey) |
| :---- | :---- | :---- | :---- | :---- |
| **Key Generation Location** | Trusted Computer (Offline Recommended for Master) | YubiKey Secure Element | Trusted Computer | YubiKey Secure Element (PIV Slot) |
| **Private Key Material Storage** | Master: Offline Backup; Subkeys: YubiKey | YubiKey Secure Element | Key File on Computer Storage | YubiKey Secure Element (PIV Slot) |
| **Private Key Exportable from YubiKey for External Backup?** | Subkeys: No. Master Key: Backed up *before* transfer. | No (by design) 4 | N/A (Key is already external to YubiKey) | No (Secret material in PIV slot is not exportable) 6 |
| **Recommended Backup Approach** | Backup Master Key & Revocation Cert (offline, encrypted). Subkeys re-provisioned. | Backup Revocation Cert. Accept key loss if YubiKey fails/lost. | Backup the AGE private key file (encrypted, offline). | Backup the age-identity.txt file (pointer only, not private key). Accept key loss if YubiKey fails/lost. 6 |
| **Recovery from YubiKey Loss** | Provision subkeys to new YubiKey from Master Key backup. | Use Revocation Cert. Generate new key. Data encrypted to old key may be lost. | Restore AGE key file from backup. YubiKey loss is irrelevant for this key. | Data encrypted solely to this YubiKey identity is lost. Regenerate identity on new YubiKey (new key). |

### **E. Key Insights & Hidden Connections**

The user's stated preference for off-device generation aligns perfectly with the objective of creating robust, independent backups of the primary cryptographic material. This approach allows for recovery from YubiKey loss or failure by reprovisioning keys from the secure backup. While on-device generation offers superior protection against key exfiltration from the host system, it comes at the cost of making the YubiKey itself a single point of failure for the key it contains, unless other mitigation strategies (like encrypting to multiple recipients) are employed.

## **III. Configuring SOPS for YubiKey-Backed Encryption**

Successfully integrating YubiKeys into a SOPS workflow requires proper configuration of SOPS itself, as well as an understanding of how SOPS interacts with the underlying GPG or AGE encryption tools, which in turn communicate with the YubiKey.

### **A. Initial SOPS Setup**

SOPS is typically installed as a command-line interface (CLI) tool.1 Basic SOPS operations involve encrypting a file in place (e.g., sops --encrypt --in-place secrets.yaml) or decrypting it to standard output or a file (e.g., sops --decrypt secrets.yaml).1 The specific encryption keys (GPG fingerprints or AGE public keys) can be provided as command-line arguments or, more conveniently, managed through a configuration file.

### **B. The .sops.yaml Configuration File**

For streamlined and consistent secret management, SOPS utilizes a configuration file named .sops.yaml, typically placed in the root of a project repository or in the user's home directory (e.g., ~/.config/sops/.sops.yaml).1 This file is crucial for defining encryption policies.

Purpose and Structure:  
The .sops.yaml file allows users to:

1. **Define creation_rules:** These rules specify which keys should be used for encrypting files, often based on the file's path using regular expressions (path_regex).1  
2. **Specify Default Keys:** List GPG key fingerprints or AGE public key recipients that SOPS should use for encryption.  
3. **Automate Key Selection:** SOPS automatically applies the relevant encryption rules when a new file is created or an existing one is re-encrypted, simplifying the workflow by avoiding the need to specify keys manually for each operation.1

An example creation_rules section might look like this:

YAML

creation_rules:  
  - path_regex: secrets/dev/.\*.yaml$  
    age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  
  - path_regex: secrets/prod/.\*.yaml$  
    pgp: 'FINGERPRINT1,FINGERPRINT2'  
    # For age-plugin-yubikey, the recipient from `age-plugin-yubikey --list`  
  - path_regex: secrets/yubikey-age/.\*.yaml$  
    age: age1yubikey1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

1

This configuration becomes a central policy document for secret encryption within a project. Its accuracy and security are paramount, as it dictates how secrets are protected and which identities can decrypt them.

### **C. YubiKey Applets and Their Roles in SOPS Integration**

YubiKeys host several applications (applets) that can be used for cryptographic operations. The relevant ones for SOPS integration are:

* OpenPGP Applet:  
  This applet allows a YubiKey to function as an OpenPGP smart card, capable of storing GPG keys (typically the signing, encryption, and authentication subkeys, while the master key is kept offline).4 When SOPS uses GPG for encryption or decryption, GPG tools like gpg-agent handle the interaction with the YubiKey's OpenPGP applet. SOPS itself remains largely unaware of the YubiKey's presence; it simply instructs GPG to use a specific key ID or fingerprint.18 If that key is on the YubiKey, gpg-agent will prompt for the YubiKey PIN.  
* PIV (Personal Identity Verification) Applet:  
  The PIV applet on a YubiKey provides smart card functionality based on the PIV standard. The age-plugin-yubikey leverages PIV slots (specifically, it often uses "retired" PIV key slots like 9a, 9c, 9d, 9e, and others from a pool of 20) to store the secret key material for AGE identities.6 YubiKey 4 and 5 series are officially supported by this plugin.6 SOPS interacts with age, which in turn uses the age-plugin-yubikey binary to communicate with the YubiKey's PIV applet.  
* FIDO2 Interface (Brief Mention):  
  YubiKey 5 series and later also support FIDO2. Some AGE plugins, such as age-plugin-fido2prf, can utilize FIDO2 credentials for encryption.8 This typically involves symmetric encryption using a key derived via the WebAuthn PRF extension, where the YubiKey acts as a FIDO2 authenticator.8 This is a more specialized use case.

It is important to recognize that SOPS generally operates at an abstraction layer above direct hardware interaction. It delegates the cryptographic operations to GPG or AGE (and its plugins). These underlying tools are then responsible for communicating with the YubiKey. This layered approach simplifies SOPS's own configuration but underscores the necessity of correctly setting up GPG or AGE with the YubiKey beforehand. Any issues in the GPG/AGE-to-YubiKey communication will manifest as failures in SOPS operations.

## **IV. Workflow A: SOPS with GPG and YubiKeys**

This section details integrating SOPS with GPG, where GPG keys are utilized in conjunction with a YubiKey. Both off-device (preferred for backup) and on-device GPG key generation methods are covered.

### **A. Off-Device GPG Key Generation (User Preferred & Recommended for Backup)**

This method is recommended as it allows for a comprehensive backup of the GPG master key, which is kept securely offline, while the subkeys used for daily cryptographic operations (signing, encryption, authentication) are stored on the YubiKey. This strategy aligns with established best practices for GPG key management 9 and addresses the user's preference for robust backup capabilities.

1. Rationale:  
The core idea is to protect the all-important master key (Certify key) by minimizing its exposure. Subkeys, which can be revoked and reissued if compromised or if the YubiKey is lost, handle routine tasks.  
2. Environment Preparation:  
Generating a GPG master key is a sensitive operation. It is strongly recommended to perform this in a secure, air-gapped (offline) environment to prevent potential compromise by malware or network-based attacks. Operating systems like Tails or a Debian Live USB booted on a trusted machine are suitable choices.9 Ensure GnuPG (version 2.1.17 or later for full smart card features) is installed in this environment.9  
3. Master Key (Certify-Only) Creation:  
The master key should ideally only have the "Certify" capability, meaning it's used to certify (sign) other keys (its own subkeys and potentially other people's keys) but not for direct encryption or signing of messages.

* Use the command: gpg --expert --full-gen-key.4  
* Select the desired key type (e.g., (1) RSA and RSA (default) or (9) ECC and ECC). For RSA, a key size of 4096 bits is recommended for YubiKey 5 series.4  
* Set the expiration date. For the master key, it is common practice to set it to "never" expire (0) 9, as master key rotation is a more involved process.  
* Provide your real name, email address, and an optional comment.  
* Create a strong, unique passphrase for the master key. This passphrase will be required to use the master key (e.g., to create subkeys or revoke it). Store this passphrase securely and separately from the key backups.9

4. Subkey Generation (Sign, Encrypt, Authenticate):  
Once the master key is created, generate subkeys for specific purposes.

* Enter key edit mode: gpg --expert --edit-key <KEY_ID> (replace <KEY_ID> with your master key's ID or fingerprint).  
* Use the addkey command for each subkey.4  
  * **Signing Subkey:** Choose RSA (or an appropriate ECC curve), capability Sign.  
  * **Encryption Subkey:** Choose RSA (or an appropriate ECC curve), capability Encrypt.  
  * **Authentication Subkey:** Choose RSA (or an appropriate ECC curve), capability Authenticate. (You may need to toggle default capabilities off and Authenticate on).  
* Set an appropriate expiration date for subkeys (e.g., 1-2 years is common, as they are easier to rotate).9  
* Save changes after adding all subkeys: save.

5. Secure Backup of GPG Master Key and Revocation Certificate:  
This is a critical step for disaster recovery.

* **Export the Secret Master Key:** gpg --export-secret-keys --armor <KEY_ID> > master-key.sec This file contains your private master key. Protect it diligently.9  
* **Backup Storage:** Store master-key.sec on multiple encrypted USB drives, kept in physically separate and secure locations. Consider using tools like paperkey for an additional analog backup of the most critical parts of the key.9 These backups must be kept offline.  
* **Generate a Revocation Certificate:** gpg --output revocation-cert.asc --gen-revoke <KEY_ID> This certificate is used to publicly declare that your key is no longer valid if it's compromised or you lose access. Store this certificate securely, separately from the master key backup, and ideally in a location accessible even if your primary systems are down.4  
* After backing up, you can remove the private master key from your online GPG keyring, leaving only the public part and the secret subkey stubs (once subkeys are moved to the YubiKey). The actual private master key should only reside on your secure offline backups.

6. Transferring GPG Subkeys to YubiKey's OpenPGP Applet:  
With the YubiKey inserted:

* Enter key edit mode: gpg --edit-key <KEY_ID>.  
* For each subkey you want to transfer (typically all three: Sign, Encrypt, Authenticate):  
  * Select the subkey: key <N> (where <N> is the subkey number, e.g., key 1).  
  * Transfer to card: keytocard.  
  * Choose the appropriate slot on the YubiKey (1 for Signature, 2 for Encryption, 3 for Authentication).4  
  * You will be prompted for the master key passphrase and then the YubiKey's Admin PIN (default is 12345678, which should be changed).  
  * Deselect the key: key <N> again to toggle selection off.  
* After transferring a subkey, GPG replaces the local copy of the private subkey with a "stub" that indicates the key is now on a smart card. gpg -K will show ssb> for subkeys on the card.9  
* When prompted to save changes upon quitting gpg --edit-key, the Yubico documentation 4 advises answering N (no) if one wishes to keep the private keys on the hard drive (perhaps for backup before they are stubs). However, if following the offline master key model, the goal *is* to have stubs on the online machine, with the true private master key backed up offline. The drduh guide 9 implicitly supports the stub model on the working machine. The critical aspect is that the *master key's private part* must be backed up from the secure generation environment *before* it's removed or becomes a stub.

**7. Configuring SOPS to Use the YubiKey-Stored GPG Key:**

* Identify the GPG key fingerprint of the master key (or the relevant subkey if SOPS allows subkey specification, though usually the master key fingerprint is used, and GPG handles subkey selection).  
* Add this GPG key fingerprint to your .sops.yaml file under a pgp entry in the creation_rules section.1 Example:  
  YAML  
  creation_rules:  
    - pgp: 'YOUR_GPG_KEY_FINGERPRINT'

* When encrypting, SOPS will use this fingerprint: sops --encrypt --pgp YOUR_GPG_KEY_FINGERPRINT -i secrets.yaml (or it will use the rule from .sops.yaml automatically).

**8. Decryption Process:**

* When sops --decrypt secrets.yaml is run, SOPS invokes GPG.  
* GPG, through gpg-agent, detects that the required private key (subkey) is on a smart card.  
* gpg-agent will prompt for the YubiKey's User PIN (default is 123456, which should be changed), unless it's already cached.  
* The YubiKey performs the decryption operation using the on-card private subkey. The decrypted content is then passed back to SOPS.

The presence of "stubs" in the local GPG keyring is essential. These stubs inform GPG that the actual private key operations must be delegated to the smart card (YubiKey) associated with that stub. The YubiKey, in this model, acts as a kind of "Hardware Security Module-lite" for the GPG subkeys, performing cryptographic operations internally and enhancing security over software-only GPG keys for daily tasks.

### **B. On-Device GPG Key Generation (Understanding the Limitations)**

This method prioritizes maximum key security by ensuring the private key material never touches the host computer's storage, even during generation.

1. Rationale:  
Some users opt for this if their primary threat model involves potential compromise of the host computer.  
**2. Procedure:**

* Insert the YubiKey.  
* Run gpg --card-edit.  
* In the gpg/card> prompt, type admin to enable administrative commands.  
* Type generate to start the on-card key generation process.4  
* Follow the prompts to choose key sizes, expiration dates, and provide user ID information. The YubiKey will generate the master key and subkeys directly on its secure element.  
* Change the default User and Admin PINs if not already done.

**3. Critical Analysis: Non-Exportability and Backup Limitations:**

* **Crucial Warning:** Private keys generated directly on the YubiKey using this method **cannot be backed up or exported from the YubiKey** [4 ("Warning: Generating the PGP on the YubiKey...means that the key can not be backed up so if your YubiKey is lost or damaged the PGP key is irrecoverable."), 4]. This is a fundamental security feature of the OpenPGP card specification.  
* **Risk:** If the YubiKey is lost, stolen, damaged, or reset, the GPG keys and any data encrypted solely to them are permanently irrecoverable. This presents a significant operational risk if no alternative access or recovery methods are in place.  
* **Revocation Certificate:** It is absolutely vital to generate a revocation certificate *immediately after* on-card key generation (while still in gpg --card-edit, or by exporting the public key stub to the host and then generating a revocation certificate for it) and store it securely elsewhere. This is the only way to disavow the key if the YubiKey is lost.

4. Using this GPG Key with SOPS:  
The process is similar to the off-device method. SOPS will use the GPG key ID/fingerprint associated with the key now residing on the YubiKey. The .sops.yaml configuration and encryption/decryption commands remain the same.  
Regardless of the generation method, but especially for on-device generated keys with no traditional backup, having a pre-generated revocation certificate stored securely and accessibly is non-negotiable. If the YubiKey is lost or the key compromised, this certificate is the primary mechanism to inform others that the key should no longer be trusted.

## **V. Workflow B: SOPS with AGE and YubiKeys**

This section explores using AGE, a modern encryption tool, with SOPS, including scenarios with and without YubiKey hardware integration for key storage.

### **A. Off-Device AGE Key Generation (Standard Method - Recommended for Backup)**

This is the simplest way to use AGE and allows for straightforward backup of the private key.

1. Rationale:  
AGE is designed for simplicity and security. Generating keys off-device provides direct control over the private key file, facilitating backup.  
**2. Key Generation:**

* Use the age-keygen command to generate a new AGE key pair: age-keygen -o keys.txt 1  
* This command creates a file (e.g., keys.txt) containing two lines:  
  * A comment line showing the public key (starts with age1...).  
  * The private key itself (starts with AGE-SECRET-KEY-1...).

**3. Backing up the AGE Private Key File:**

* The keys.txt file (or whatever name was chosen) contains the private key and **must be backed up securely** [11 ("Please back it up on a secure location or you will lose access to your secrets.")].  
* Treat this file with the same level of care as a GPG master secret key. Encrypt the backup file using a strong passphrase and store it in multiple secure, preferably offline, locations.12

**4. Using this Standard AGE Key with SOPS:**

* **Encryption:**  
  * Add the AGE public key (the age1... string) to your .sops.yaml file under an age entry in creation_rules.1 Example:  
    YAML  
    creation_rules:  
      - age: 'age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

  * Alternatively, specify the public key directly during encryption: sops --encrypt --age age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx -i secrets.yaml  
* **Decryption:**  
  * SOPS needs access to the AGE private key. This is typically provided via:  
    * The SOPS_AGE_KEY_FILE environment variable pointing to the path of your keys.txt file: export SOPS_AGE_KEY_FILE=/path/to/your/keys.txt  
    * If the `keys.txt` file is passphrase-encrypted (e.g., `keys.txt.age`), `SOPS_AGE_KEY_FILE` should point to this encrypted file. `age` (called by `sops`) will then prompt for the passphrase.
    * The SOPS_AGE_KEY environment variable containing the private key string directly.  
    * Placing the private key string in the default location ~/.config/sops/age/keys.txt.1 SOPS will automatically look for keys there.

### **B. On-Device AGE Identity with age-plugin-yubikey**

This method leverages a YubiKey to store the secret material for an AGE identity, using the age-plugin-yubikey plugin.

1. Rationale:  
This approach aims to provide hardware-backed security for AGE keys by storing the sensitive cryptographic material within the YubiKey's PIV (Personal Identity Verification) applet.  
**2. Setup and Configuration of age-plugin-yubikey:**

* **Installation:** Install the age-plugin-yubikey binary. This can be done using package managers like cargo install age-plugin-yubikey, Homebrew (brew install age-plugin-yubikey), or specific distribution packages (e.g., for Arch Linux, Debian, NixOS).6  
* **PATH Configuration:** Ensure the installed plugin binary (e.g., age-plugin-yubikey on Linux/macOS, age-plugin-yubikey.exe on Windows) is accessible in your system's PATH environment variable. This allows age (and by extension, SOPS) to discover and execute the plugin.6 This dependency on an external binary is an important operational consideration, especially in CI/CD environments or when setting up new machines.

3. Generating a YubiKey-Backed AGE Identity:  
The age-plugin-yubikey stores the secret key material within one of the YubiKey's PIV slots. It officially supports YubiKey 4 and 5 series and typically uses one of the 20 "retired" PIV slots (e.g., slot 9a, 9c, 9d, 9e) to avoid conflict with standard PIV usage.6

* **Identity File Generation:**  
  * **Interactive Mode:** Run age-plugin-yubikey. This will guide you through selecting a YubiKey, a PIV slot, and setting PIN/touch policies, then create an identity file.6  
  * **Programmatic Mode:** Use command-line flags to generate an identity and print it to standard output, which can then be redirected to a file: age-plugin-yubikey --generate[--name NAME] > yubikey_identity.txt 6 The resulting file (e.g., yubikey_identity.txt) is the "identity" that AGE clients use. This file contains metadata that the plugin uses to locate and interact with the correct key on the YubiKey.6

**4. Understanding the age-identity File and SOPS_AGE_KEY_FILE Usage:**

* **Identity File Contents:** The yubikey_identity.txt file **is not the private key itself**. It's a specially formatted string that acts as a pointer or recipe for the age-plugin-yubikey to use the actual private key stored on the YubiKey.6 It typically starts with AGE-PLUGIN-YUBIKEY-.  
* **SOPS Decryption:**  
  * Set the SOPS_AGE_KEY_FILE environment variable to the path of this yubikey_identity.txt file.6  
  * Alternatively, the content of yubikey_identity.txt can be placed in the default AGE keys file at ~/.config/sops/age/keys.txt.  
  * **Important Note for Plugin Keys in `keys.txt` or when `SOPS_AGE_KEY_FILE` points to a file with multiple identities:** If placing a plugin-generated identity (like the one from age-plugin-yubikey) into `~/.config/sops/age/keys.txt` or a custom file pointed to by `SOPS_AGE_KEY_FILE`, it is often necessary to precede the identity string with a comment line containing its corresponding public key recipient. This is because there isn't a universal way for AGE to derive the recipient from a generic plugin identity string.11 Example for `~/.config/sops/age/keys.txt`:  
    # recipient: age1yubikey1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  
    AGE-PLUGIN-YUBIKEY-1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx  
    11

5. Obtaining the Public Key (Recipient) for Encryption:  
To encrypt data to this YubiKey-backed AGE identity, you need its public key (also called the recipient string).

* Use the command: age-plugin-yubikey --list This will list all YubiKey-based AGE recipients found on connected and compatible YubiKeys. The output will be one or more strings starting with age1yubikey1....6  
* This recipient string is what you add to your .sops.yaml under an age entry or use with sops --encrypt --age age1yubikey1....

**6. Critical Analysis: Non-Exportability of Private Key Material and Backup Implications:**

* The actual secret cryptographic material generated by age-plugin-yubikey and stored within the YubiKey's PIV slot **is not exportable from the YubiKey** [6 ("The ability to export or back up private keys generated on the YubiKey is not mentioned in the document.")]. This is consistent with the fundamental security design of YubiKeys, which aims to prevent private key extraction.10  
* **Backup of yubikey_identity.txt:** Backing up the yubikey_identity.txt file is useful for easily reconfiguring SOPS/AGE on a new system or after an OS reinstall, as it saves you from needing to regenerate this pointer file (which simply reads information from the YubiKey slot again). However, this file **does not contain the private key material and cannot be used to recover the key if the YubiKey itself is lost, damaged, or reset.**  
* If the YubiKey containing the unique secret material is lost, any data encrypted *solely* to that YubiKey-backed AGE identity becomes permanently inaccessible. This directly addresses the user's concern: exporting the *actual private key* generated on-device via this plugin for backup purposes is not possible.

It is crucial to dispel any misconception that the yubikey_identity.txt file is a backup of the private key. It is merely a reference or configuration that enables the age-plugin-yubikey to interact with the non-exportable key securely stored on the YubiKey hardware. If the identity file is lost, it can typically be regenerated using a command like `age-plugin-yubikey --identity --serial <YUBIKEY_SERIAL> --slot <SLOT>`. Loss of the YubiKey itself means the identity file becomes a pointer to a non-existent key.

Users employing age-plugin-yubikey should also be mindful of PIV slot management. While the plugin typically uses "retired" slots, awareness of which slots are in use is important if the PIV applet is utilized for other functions like certificate-based authentication or digital signatures, to avoid conflicts. The command age-plugin-yubikey --list-all can help identify all PIV keys on the YubiKey that the plugin considers compatible.6

### **C. (Briefly) On-Device AGE Identity with age-plugin-fido2prf**

YubiKey 5 NFC+ and newer models support FIDO2, which can also be used with AGE through plugins like age-plugin-fido2prf.

1. Overview:  
This plugin allows the use of FIDO2 credentials (often residing on hardware authenticators like YubiKeys) for AGE encryption, typically leveraging the WebAuthn PRF (Pseudo-Random Function) extension.8  
2. Symmetric Nature:  
Encryption using this method is often symmetric in nature. Instead of a traditional public/private key pair for asymmetric encryption, encryption is performed to a FIDO2 "identity" string. Decryption requires interaction with the FIDO2 authenticator that holds the corresponding credential.8  
3. Usage:  
Encryption might look like age -e -i <FIDO2_IDENTITY_STRING> secrets.txt. Decryption would require the FIDO2 authenticator to be present.  
4. Backup Considerations:  
Similar to other on-device key generation methods, the private key material associated with the FIDO2 credential resides on the authenticator (YubiKey) and is generally designed to be non-exportable [8 ("Keys are generally not exportable from FIDO2 security keys.")]. Loss of the authenticator means loss of the ability to decrypt.

## **VI. Comparative Analysis: GPG vs. AGE in YubiKey-Integrated SOPS Workflows**

Choosing between GPG and AGE for use with SOPS and YubiKeys involves considering several factors, including ease of use, key management paradigms, backup capabilities, security models, and the broader ecosystem.

### **A. Ease of Use and Setup Complexity**

* **GPG:**  
  * The initial setup, particularly the generation of an offline master key and separate subkeys, and their transfer to a YubiKey, can be complex and involve many steps.4  
  * GnuPG is a mature and powerful toolset, but its extensive options and concepts can present a steep learning curve for new users.  
  * Once configured, interaction with the YubiKey via gpg-agent for SOPS operations is generally robust and transparent to the user (requiring only PIN entry).  
* **AGE (Standard, Off-Device Key):**  
  * Key generation is significantly simpler: a single age-keygen command produces the necessary key pair.1  
  * The conceptual overhead is lower, with fewer distinct key types or components to manage initially.  
* **AGE (with age-plugin-yubikey):**  
  * Plugin installation and ensuring it's in the PATH adds an initial setup step not present with standard AGE.6  
  * Generating the YubiKey-backed identity and obtaining the correct recipient string requires plugin-specific commands (age-plugin-yubikey --generate, age-plugin-yubikey --list).  
  * Understanding the distinction between the identity file (a pointer) and an actual private key file is crucial.6

### **B. Key Management and Backup Capabilities/Limitations with YubiKeys**

* **GPG:**  
  * **Off-Device Master:** Allows for a full, secure backup of the master key. If a YubiKey holding subkeys is lost or damaged, new subkeys can be generated from the master key and provisioned to a replacement YubiKey.9 This offers excellent recoverability.  
  * **On-Device Generation:** GPG keys generated directly on the YubiKey are non-exportable and cannot be backed up. Loss of the YubiKey means irrecoverable loss of those specific keys.4  
* **AGE (Standard, Off-Device Key):**  
  * The keys.txt file containing the private key can and must be fully backed up.11 YubiKey loss is irrelevant to this key's security or accessibility unless the YubiKey was used for something like Full Disk Encryption protecting the system where keys.txt is stored.  
* **AGE (with age-plugin-yubikey):**  
  * The actual secret cryptographic material stored in the YubiKey's PIV slot by the plugin is non-exportable.6  
  * The yubikey_identity.txt file is only a pointer and not a backup of the private key. Loss of the YubiKey means that specific AGE identity's decrypting capability is lost permanently.

### **C. Security Model Differences**

* **GPG:**  
  * Based on the well-established OpenPGP standard. Offers a complex but feature-rich security model, including a hierarchical trust system (master key certifies subkeys), distinct capabilities for subkeys (Sign, Encrypt, Authenticate), and a formal revocation mechanism.  
  * YubiKey interaction occurs via the OpenPGP applet.5  
* **AGE:**  
  * Aims for a simpler, more modern design to avoid some of GPG's historical complexities and potential pitfalls. Uses current cryptographic primitives like X25519 and ChaCha20-Poly1305.  
  * Its plugin architecture allows for flexible extensions, including hardware key support.  
  * age-plugin-yubikey interacts with the YubiKey's PIV applet.6 It's important to note that the OpenPGP and PIV applets are distinct applications on the YubiKey.7

### **D. Ecosystem and Tooling**

* **GPG:**  
  * Extremely mature and widely supported across operating systems and applications. However, it is sometimes perceived as cumbersome or difficult to use correctly.  
* **AGE:**  
  * Newer, with a rapidly growing ecosystem. Its simplicity is a core design goal and a significant draw for many users and developers. Tooling is generally more focused and less sprawling than GPG's.

The choice between GPG and AGE often comes down to a trade-off between GPG's extensive features and established history versus AGE's modern design and simplicity. When YubiKey integration is factored in, the decision also hinges on the preferred key management model (offline master vs. on-card identity) and tolerance for risk associated with key loss versus key theft from the host system. If the primary concern is the compromise of the host computer, storing key material on the YubiKey (either GPG subkeys or an age-plugin-yubikey identity) is beneficial. If the primary concern is the loss or damage of the YubiKey itself, having an externally backed-up master key (GPG) or original private key (standard AGE) is superior.

### **E. Table: GPG vs. AGE with YubiKeys for SOPS Comparison**

| Feature | GPG (Off-Device Master, Subkeys on YubiKey) | AGE (Standard Off-Device Key File) | AGE (with age-plugin-yubikey, Identity on YubiKey) |
| :---- | :---- | :---- | :---- |
| **Key Generation (Off-Device Focus)** | Complex (Master \+ Subkeys, offline env recommended) 9 | Simple (age-keygen -o keys.txt) 1 | Plugin generates identity; secret material on YubiKey. Identity file created. 6 |
| **YubiKey Storage Mechanism** | OpenPGP Applet (for Subkeys) 5 | N/A (Private key is software-based, not on YubiKey) | PIV Applet (Retired Slots) 6 |
| **Private Key Backup (Off-Device Generated Master/Key)** | Master Key: Yes, full backup possible and essential. Subkeys: Re-provisioned from master. 9 | Yes, keys.txt (private key file) fully backupable and essential. 11 | N/A (Secret material is generated on YubiKey for this method) |
| **Private Key Backup (On-Device Generated Key/Identity)** | N/A (Focus is off-device master). If GPG key generated on-card: No backup of private key. 4 | N/A | Secret material on YubiKey: No export/backup. Identity file: Pointer only, not private key backup. 6 |
| **SOPS Integration Complexity** | Moderate (GPG setup, then fingerprint in .sops.yaml) | Simple (Public key in .sops.yaml, SOPS_AGE_KEY_FILE for private key) | Moderate (Plugin install, identity file setup, recipient in .sops.yaml, SOPS_AGE_KEY_FILE for identity file) |
| **Primary Security Benefit with YubiKey** | Hardware protection for daily-use subkeys; master key offline. | N/A (YubiKey not directly holding this AGE private key) | Hardware protection for AGE secret material; operations on YubiKey. |
| **Recovery from YubiKey Loss (with Off-Device Master)** | High: Re-provision subkeys to new YubiKey from master key backup. Use revocation cert for lost YubiKey. 9 | N/A (YubiKey not involved with this key) | Low: Secret material on lost YubiKey is gone. Data encrypted solely to it is inaccessible. New identity needed. |

### **F. Key Insights & Hidden Connections**

The simplicity of AGE can be a significant advantage, particularly for teams or individuals who find GPG's complexity a barrier.1 However, GPG's mature features, such as distinct capabilities for subkeys (signing, encryption, authentication) and a more formalized revocation system, can be beneficial in scenarios requiring granular control or adherence to established OpenPGP practices. The choice is not merely about the encryption algorithm but encompasses the entire key management lifecycle and the operational environment.

## **VII. Comprehensive Backup and Recovery Strategies**

A robust backup and recovery strategy is paramount when dealing with cryptographic keys, as their loss can lead to irreversible data loss or loss of access. The approach to backup differs significantly based on whether keys are generated off-device or on-device.

### **A. Best Practices for Backing Up Off-Device Generated Keys**

When keys are generated on a trusted computer, the user has direct access to the private key material, allowing for comprehensive backups.

* **GPG Master Keys:**  
  * **Multiple Encrypted Backups:** The exported secret master key should be encrypted and stored on multiple physical media (e.g., high-quality USB drives). These backups should be kept in geographically separate, secure locations (e.g., a home safe and a bank deposit box).9  
  * **Paperkey:** Consider using paperkey to create a physical, paper-based backup of the essential components of the GPG secret key. This can offer resilience against digital media failure.9  
  * **Strictly Offline Storage:** The primary backups of the GPG master key must be stored offline to protect them from network-based threats.  
  * **Passphrase Security:** The strong passphrase for the master key should be memorized or stored securely, separate from the key material itself.  
* **Standard AGE Private Key Files (keys.txt):**  
  * **Encryption:** The keys.txt file containing the AGE private key should be encrypted using a strong symmetric encryption tool (e.g., GPG itself, or VeraCrypt for a container) before being backed up.  
  * **Multiple Secure Locations:** Store the encrypted backup in multiple secure, preferably offline, locations, similar to GPG master key backups.12  
  * This file should be treated with the same level of security diligence as a GPG master key.  
* **Revocation Certificates (GPG):**  
  * A GPG revocation certificate, generated at the time of key creation, is essential. It allows the key to be marked as invalid if it's compromised or the passphrase is forgotten.  
  * Store the revocation certificate securely and separately from the primary key backups. It should be accessible even if the primary key is lost.4

### **B. Addressing the Core Concern: The Reality of Non-Exportable On-Device Generated Private Keys**

It is critical to reiterate that private key material generated *directly on* a YubiKey (e.g., GPG keys via gpg --card-edit generate, or AGE identities via age-plugin-yubikey) is, by design, **non-exportable**.4 This is a fundamental security feature of such hardware tokens, preventing the private key from ever existing outside the secure element.

This means that if the YubiKey is the *sole* repository of such a private key, and that YubiKey is subsequently lost, stolen, damaged, or reset, the private key it contained is permanently and irrecoverably gone. No "export for backup" of the raw private key is possible in these scenarios.

### **C. Mitigation Strategies for YubiKey Loss/Damage**

Given the non-exportability of on-device generated keys, mitigation strategies are crucial.

* Primary Strategy (Aligns with User Preference): Use Off-Device Generated Keys.  
  This is the most robust approach for ensuring recoverability.  
  * **GPG:** If using the recommended GPG setup (off-device master key, subkeys on YubiKey), the loss of a YubiKey is manageable. New subkeys can be generated from the securely backed-up master key and provisioned to a replacement YubiKey.9 The revocation certificate for the subkeys on the lost YubiKey should also be used.  
  * **Standard AGE Keys:** If using standard AGE keys generated off-device (the keys.txt file), the YubiKey is not involved in storing the private key. Loss of a YubiKey is therefore irrelevant to the accessibility of this AGE key, unless the YubiKey was used for a secondary purpose like encrypting the drive where keys.txt was stored.  
* For On-Device Generated Keys (If Chosen Despite Backup Limitations):  
  If on-device generation is chosen, the strategy shifts from private key backup to risk mitigation and redundancy of access.  
  * **GPG (On-Device):** The primary recourse upon YubiKey loss is to use the pre-generated revocation certificate to publicly invalidate the lost key. A new GPG key must then be generated on a new YubiKey. Any data encrypted solely to the lost key will be inaccessible. (Our scripts include `16-generate-gpg-on-yubikey.sh` for this scenario, with strong warnings).  
  * **age-plugin-yubikey:** AGE does not have a formal revocation mechanism like GPG's. If the YubiKey holding the age-plugin-yubikey identity is lost, secrets encrypted *only* to that specific YubiKey identity become inaccessible. Mitigation involves:  
    * Restoring secrets from a separate backup if they were also encrypted to another, recoverable key (e.g., a standard AGE key or a GPG key with an offline master).  
    * Re-encrypting all relevant secrets to a new YubiKey identity generated on a replacement device.  
  * **Multiple YubiKeys (Limited Applicability for On-Device Generated Keys):** It is generally not possible to "clone" a YubiKey's on-device generated private key to another YubiKey due to the non-exportable nature of the keys [10 ("It is not possible to create an exact copy of a YubiKey.")]. However, one could:  
    1. Generate *separate and distinct* on-device keys on multiple YubiKeys.  
    2. Encrypt secrets to *all* of these YubiKey identities (i.e., list multiple YubiKey AGE recipients or GPG fingerprints in SOPS). This provides redundancy of access but increases management complexity (e.g., needing to update all keys if one is compromised). The Yubico Authenticator guide 21 discusses methods for backing up OATH/OTP credentials, sometimes by adding the same credential secret to multiple YubiKeys during setup or by saving the original QR code/secret key. This process is specific to symmetric OATH/OTP secrets and does not apply to the asymmetric PGP or PIV keys used by GPG and age-plugin-yubikey.

### **D. Backing Up the age-plugin-yubikey Identity File**

As previously established, the identity file created by age-plugin-yubikey (e.g., yubikey_identity.txt or its contents in ~/.config/sops/age/keys.txt) is a pointer or configuration string, not the private key itself.6

* **Value of Backing It Up:** If the host operating system is reinstalled or the user moves to a new machine, having a backup of this identity file saves the minor inconvenience of regenerating it using age-plugin-yubikey --identity --slot SLOT > yubikey_identity.txt (which simply re-reads information from the YubiKey to recreate the pointer).  
* **Limitation:** This backup provides no assistance if the YubiKey itself (containing the actual non-exportable secret material) is lost or damaged.  
* It can be stored with other configuration files or dotfiles. The identity file can typically be regenerated using a command like `age-plugin-yubikey --identity --serial <YUBIKEY_SERIAL> --slot <SLOT>`.

The choice of key generation method should be dictated by the desired backup outcome. If full private key backup is a primary requirement, then off-device generation must be chosen. Attempting to achieve full private key backup after choosing on-device generation will lead to the realization that it's generally not feasible. For on-device keys, the focus shifts from "backing up the key material" to "creating redundancy for access," perhaps by encrypting critical secrets to multiple distinct keys, at least one of which is recoverable.

It is worth noting that Yubico's YubiHSM product line, distinct from standard YubiKeys, *does* offer mechanisms for backing up keys stored on the HSM using wrap keys.22 This distinction highlights that the non-exportability of on-device generated keys on standard YubiKeys is a deliberate design choice for that product category and its intended use cases, and that different hardware solutions exist for enterprise-grade key backup requirements.

## **VIII. Conclusion and Tailored Recommendations**

This report has detailed the integration of SOPS with YubiKeys using GPG and AGE, with a strong emphasis on key generation methodologies and their profound impact on backup and recovery capabilities. The analysis consistently shows a fundamental trade-off between the enhanced hardware security of on-device key generation and the robust backup potential of off-device key generation.

### **A. Summary of Findings Aligned with User Preferences**

The core user preference for off-device key generation to ensure comprehensive backup is well-supported by the available tools and best practices.

* **GPG with Off-Device Master Key:** This method allows the master GPG key (and its crucial revocation certificate) to be securely backed up offline. Daily cryptographic operations are handled by subkeys transferred to the YubiKey, benefiting from hardware protection. This offers a strong balance.  
* **Standard AGE with Off-Device Key File:** Generating an AGE key pair using age-keygen results in a private key file (keys.txt) that can be securely backed up. This approach is simpler than GPG's master/subkey architecture.  
* **On-Device Key Generation (GPG or age-plugin-yubikey):** In contrast, private key material generated directly on the YubiKey is, by design, non-exportable. This maximizes the key's protection against host compromise but means that if the YubiKey is lost or damaged, the key is irrecoverable. Any "backup" associated with such keys (e.g., the age-plugin-yubikey identity file) is for configuration or identification purposes only, not for private key restoration.

### **B. Guidance on Choosing Workflows Based on Security Posture and Backup Needs**

The selection of a workflow should be guided by an assessment of the primary risks (key theft vs. key loss) and the non-negotiable requirement for backup.

**Recommendation for User's Stated Preference (Prioritizing Backup):**

1. **GPG Workflow:**  
   * **Action:** Generate a GPG master key and subkeys in a secure offline environment. Securely back up the master key and its revocation certificate in multiple offline locations. Transfer only the subkeys (Sign, Encrypt, Authenticate) to the YubiKey's OpenPGP applet.  
   * **SOPS Integration:** Configure SOPS to use the GPG key fingerprint associated with these keys.  
   * **Rationale:** This provides excellent hardware security for daily operations via the YubiKey, while ensuring full recoverability of the ability to issue new subkeys from the master key backup if the YubiKey is lost or compromised.  
2. **AGE Workflow (Standard Key):**  
   * **Action:** Generate a standard AGE key pair using age-keygen -o keys.txt. Securely back up the keys.txt file (which contains the private key) using encryption and offline storage.  
   * **SOPS Integration:** Configure SOPS to use the AGE public key for encryption and provide the path to the (backed-up) keys.txt file (e.g., via SOPS_AGE_KEY_FILE) for decryption.  
   * **Rationale:** This is simpler to set up than the GPG workflow and provides full private key backup. If the `keys.txt` is passphrase-encrypted (e.g. as `keys.txt.age` by `01-generate-age-keypair.sh`), `SOPS_AGE_KEY_FILE` should point to this file, and `age` will prompt for the passphrase.

If Considering age-plugin-yubikey (On-Device AGE Identity):  
While this provides the benefit of storing AGE secret material within the YubiKey's PIV hardware, it must be adopted with full awareness of the backup limitation. The secret material is non-exportable from the YubiKey. This option is suitable if:

* The risk of losing access due to YubiKey loss/damage for that specific identity is acceptable.  
* Or, critical secrets are also encrypted to other, recoverable keys (e.g., a GPG key with an offline master, or a standard AGE key that is backed up).

### **C. Reiteration of the Implications of On-Device Key Generation for Backup Strategies**

A final, unequivocal statement: choosing to generate private keys directly on a YubiKey (whether GPG keys via gpg --card-edit generate or AGE identities via age-plugin-yubikey) fundamentally means forgoing traditional, full private key backup for those specific keys. The security benefit of ensuring the key never leaves the hardware comes at the cost of making that hardware a single point of failure for the key it exclusively contains. Any associated "backup" files (like the age-plugin-yubikey identity file) are for configuration or identification, not for recovering the private key material itself if the YubiKey is rendered unusable.

### **D. Final Security Considerations**

Beyond the choice of tools and key generation methods, several overarching security practices are vital:

* **Physical Security:** Protect the YubiKey from physical theft or unauthorized access.  
* **Strong PINs:** Change default YubiKey PINs (User and Admin for GPG; PIV PIN for age-plugin-yubikey) to strong, unique values. Be aware of PIN retry limits to avoid locking the device.9  
* **Software Updates:** Keep the operating system, GnuPG, AGE, SOPS, YubiKey Manager, and YubiKey firmware up to date to benefit from the latest security patches and features.  
* **Principle of Least Privilege:** Only load keys onto YubiKeys or configure SOPS with keys that are necessary for the intended workflow.

For users prioritizing robust backup capabilities, the "least regret" path involves off-device key generation. This approach ensures that even if the hardware token is lost, damaged, or becomes obsolete, the ability to access encrypted data or re-establish secure communication channels via the backed-up master/private key is retained. Keys generated off-device also offer greater long-term flexibility and portability should hardware or workflow requirements change significantly in the future, as the original key material is not intrinsically tied to a single, non-exportable hardware instance.

#### **Works cited**

1. Secure Secret Management with SOPS in Terraform & Terragrunt - DEV Community, accessed May 10, 2025, [https://dev.to/hkhelil/secure-secret-management-with-sops-in-terraform-terragrunt-231a](https://dev.to/hkhelil/secure-secret-management-with-sops-in-terraform-terragrunt-231a)  
2. Secure Secret Management with SOPS in Helm - DEV Community, accessed May 10, 2025, [https://dev.to/hkhelil/secure-secret-management-with-sops-in-helm-1940](https://dev.to/hkhelil/secure-secret-management-with-sops-in-helm-1940)  
3. Manage Kubernetes secrets with SOPS - Flux, accessed May 10, 2025, [https://fluxcd.io/flux/guides/mozilla-sops/](https://fluxcd.io/flux/guides/mozilla-sops/)  
4. Using Your YubiKey with OpenPGP – Yubico, accessed May 10, 2025, [https://support.yubico.com/hc/en-us/articles/360013790259-Using-Your-YubiKey-with-OpenPGP](https://support.yubico.com/hc/en-us/articles/360013790259-Using-Your-YubiKey-with-OpenPGP)  
5. PGP - Yubico Developers, accessed May 10, 2025, [https://developers.yubico.com/PGP/](https://developers.yubico.com/PGP/)  
6. str4d/age-plugin-yubikey - GitHub, accessed May 10, 2025, [https://github.com/str4d/age-plugin-yubikey](https://github.com/str4d/age-plugin-yubikey)  
7. Securing SSH with OpenPGP or PIV - Yubico Developers, accessed May 10, 2025, [https://developers.yubico.com/PIV/Guides/Securing_SSH_with_OpenPGP_or_PIV.html](https://developers.yubico.com/PIV/Guides/Securing_SSH_with_OpenPGP_or_PIV.html)  
8. age-encryption - npm, accessed May 10, 2025, [https://www.npmjs.com/package/age-encryption?activeTab=readme](https://www.npmjs.com/package/age-encryption?activeTab=readme)  
9. drduh/YubiKey-Guide: Community guide to using YubiKey ... - GitHub, accessed May 10, 2025, [https://github.com/drduh/YubiKey-Guide](https://github.com/drduh/YubiKey-Guide)  
10. How to back up credentials, accessed May 10, 2025, [https://docs.yubico.com/yesdk/users-manual/application-oath/oath-backup-credentials.html](https://docs.yubico.com/yesdk/users-manual/application-oath/oath-backup-credentials.html)  
11. Secrets & Facts - Clan Documentation, accessed May 10, 2025, [https://docs.clan.lol/getting-started/secrets/](https://docs.clan.lol/getting-started/secrets/)  
12. How to Backup Your Private Keys - OSL, accessed May 10, 2025, [https://osl.com/academy/article/how-to-backup-your-private-keys](https://osl.com/academy/article/how-to-backup-your-private-keys)  
13. Best Practices For Protecting Private Keys - FasterCapital, accessed May 10, 2025, [https://fastercapital.com/topics/best-practices-for-protecting-private-keys.html](https://fastercapital.com/topics/best-practices-for-protecting-private-keys.html)  
14. GPG Keys - Purism user documentation, accessed May 10, 2025, [https://docs.puri.sm/Hardware/Librem_Key/GPG.html](https://docs.puri.sm/Hardware/Librem_Key/GPG.html)  
15. Has anyone managed to replace file encryption using gpg or sops with age for any... | Hacker News, accessed May 10, 2025, [https://news.ycombinator.com/item?id=28437130](https://news.ycombinator.com/item?id=28437130)  
16. A Comprehensive Guide to SOPS: Managing Your Secrets Like A Visionary, Not a Functionary - GitGuardian Blog, accessed May 10, 2025, [https://blog.gitguardian.com/a-comprehensive-guide-to-sops/](https://blog.gitguardian.com/a-comprehensive-guide-to-sops/)  
17. Framework and NixOS - Sops-nix Secrets Management - dade, accessed May 10, 2025, [https://0xda.de/blog/2024/07/framework-and-nixos-sops-nix-secrets-management/](https://0xda.de/blog/2024/07/framework-and-nixos-sops-nix-secrets-management/)  
18. Working example of sops-nix with Yubikey? : r/NixOS - Reddit, accessed May 10, 2025, [https://www.reddit.com/r/NixOS/comments/1dbsx17/working_example_of_sopsnix_with_yubikey/](https://www.reddit.com/r/NixOS/comments/1dbsx17/working_example_of_sopsnix_with_yubikey/)  
19. 5.2. Using the card only for subkeys, accessed May 10, 2025, [https://www.gnupg.org/howtos/card-howto/en/ch05s02.html](https://www.gnupg.org/howtos/card-howto/en/ch05s02.html)  
20. Difference between so many PINs : r/yubikey - Reddit, accessed May 10, 2025, [https://www.reddit.com/r/yubikey/comments/tkuv5y/difference_between_so_many_pins/](https://www.reddit.com/r/yubikey/comments/tkuv5y/difference_between_so_many_pins/)  
21. How to Reset Your YubiKey and Create a Backup - Privacy Guides, accessed May 10, 2025, [https://www.privacyguides.org/articles/2025/03/06/yubikey-reset-and-backup/](https://www.privacyguides.org/articles/2025/03/06/yubikey-reset-and-backup/)  
22. YubiHSM 2: Backup and Restore - Yubico Product Documentation, accessed May 10, 2025, [https://docs.yubico.com/hardware/yubihsm-2/hsm-2-user-guide/hsm2-backup-restore.html](https://docs.yubico.com/hardware/yubihsm-2/hsm-2-user-guide/hsm2-backup-restore.html)
