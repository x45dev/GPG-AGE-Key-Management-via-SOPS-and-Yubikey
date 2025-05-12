# **Automated GPG Key Lifecycle Management: Best Practices and Implementation Strategies**

## **1\. Introduction**

GNU Privacy Guard (GPG) is a cornerstone of modern digital security, providing robust mechanisms for encryption and digital signatures. The effective management of GPG keys—including their generation, the creation of subkeys with distinct capabilities, and the timely preparation of revocation certificates—is critical for maintaining a strong security posture. Automating these lifecycle processes is essential for consistency, reliability, and integration into larger project workflows, particularly when configuration needs to be driven by environment variables.

This report details methodologies for generating GPG master keys, distinct signing, encryption, and authentication subkeys, and their corresponding revocation certificates in an automated, idempotent, and feature-complete manner. It explores solutions using GPG command-line interface (CLI) tools, Bash scripts, and Python libraries, while adhering to industry best practices for security and operational robustness. The aim is to provide a comprehensive guide for system administrators and security engineers seeking to implement such automated GPG key management systems.

## **2\. GPG Key Generation Fundamentals for Automation**

A foundational aspect of GPG usage, especially in automated or organizational contexts, is a well-defined key strategy. This typically involves a primary (master) key and several subkeys, each designated for specific cryptographic operations.

### **2.1. Master Key and Subkey Strategy**

The recommended GPG strategy separates the roles of the primary key and its subkeys to enhance security and operational flexibility.1

* **Primary Key:** This key should ideally have only the 'Certify' (C) capability. Its main purpose is to certify (sign) its own subkeys and potentially other individuals' GPG keys, forming the root of trust for the key owner. Best practice dictates keeping the private portion of the primary key offline or in highly secured storage, as its compromise would be catastrophic.2  
* **Subkeys:** These are bound to the primary key and are used for day-to-day operations:  
  * **Signing Subkey (S):** Used for signing messages, code, or documents.  
  * **Encryption Subkey (E):** Used for encrypting data intended for the key owner.  
  * **Authentication Subkey (A):** Used for authentication purposes, such as SSH login. This separation allows for more frequent rotation or revocation of subkeys if they are compromised, without affecting the primary key's integrity or the web of trust built upon it.1

### **2.2. Unattended Key Generation with GPG CLI (--batch \--generate-key)**

GnuPG provides a mechanism for unattended key generation using the \--batch option in conjunction with \--generate-key (or its alias \--gen-key).5 This method reads key parameters from a file or standard input, enabling automation. The parameter file format is text-based, with key-value pairs defining the key's characteristics.5

Key parameters include:

* Key-Type: Specifies the algorithm for the primary key (e.g., RSA, DSA, ECC). Must be capable of signing.5  
* Key-Length: The bit length of the primary key (e.g., 2048, 3072, 4096 for RSA).5  
* Key-Usage: For the primary key, this often defaults to cert,sign or can be set to cert if subkeys will handle all signing.5  
* Subkey-Type: Algorithm for the default subkey created during this batch process.5  
* Subkey-Length: Bit length for the default subkey.5  
* Subkey-Usage: Usage for the default subkey (e.g., encrypt).5  
* Name-Real: The real name for the User ID (UID).  
* Name-Comment: An optional comment for the UID.  
* Name-Email: The email address for the UID.  
* Expire-Date: Expiration date for the key and subkey (e.g., 0 for no expiration, 2y for two years, or an ISO date like 2025-12-31).5  
* Passphrase: The passphrase to protect the secret key. For GnuPG versions 2.1 and later, specifying a passphrase directly in the batch file is ignored for security reasons; %no-ask-passphrase is implicitly enabled, and a pinentry program is expected unless loopback pinentry is used with passphrase input via file descriptor.6  
* %no-protection: A control statement to generate a key without a passphrase. This is highly discouraged for production keys due to significant security risks.5

A significant limitation of the gpg \--batch \--generate-key command is that it typically handles the definition of only *one* subkey directly within the parameter block.5 This means that to create a primary key with multiple distinct subkeys (e.g., separate S, E, A subkeys), a multi-step process is required: first, generate the primary key with one default subkey (or none if specific flags are used), and then add additional subkeys using other GPG commands.

### **2.3. Adding Multiple Distinct Subkeys Non-Interactively**

Once the primary key is generated, additional subkeys with distinct capabilities (Signing, Encryption, Authentication) must be added. This can be achieved non-interactively using GPG CLI commands.

**Using gpg \--quick-add-key**

The gpg \--quick-add-key command provides a streamlined way to add a new subkey to an existing primary key, identified by its fingerprint (FPR).8  
The syntax is: gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--quick-add-key \<primary\_fpr\> \[algo \[usage \[expire\]\]\]

* \<primary\_fpr\>: The fingerprint of the master key to which the subkey will be added.  
* algo: The desired algorithm for the new subkey (e.g., rsa4096, ed25519, cv25519).  
* usage: Specifies the capabilities of the subkey. This is crucial for creating distinct subkeys:  
  * sign: Creates a subkey for signing only.5  
  * encr (or encrypt): Creates a subkey for encryption only.5  
  * auth: Creates a subkey for authentication only.5 It is possible to specify multiple usages if the algorithm supports them (e.g., sign,auth), but for distinct capabilities, each subkey would typically have a single usage flag set.5  
* expire: The desired expiration date or duration for the new subkey (e.g., 1y, 0 for no expiration).11

To create the recommended set of S, E, A subkeys, one would execute gpg \--quick-add-key three times sequentially, each with the appropriate usage parameter:

1. gpg... \--quick-add-key $PRIMARY\_FPR rsa4096 sign 1y  
2. gpg... \--quick-add-key $PRIMARY\_FPR rsa4096 encr 1y  
3. gpg... \--quick-add-key $PRIMARY\_FPR rsa4096 auth 1y (Assuming RSA 4096-bit keys expiring in 1 year, and passphrase supplied via fd 0).

**Using gpg \--edit-key with \--command-fd**

For more complex subkey configurations or when gpg \--quick-add-key might be insufficient (though it generally covers distinct S, E, A capabilities well), gpg \--edit-key can be scripted using the \--command-fd 0 option. This allows feeding GPG edit commands via standard input.8  
A heredoc in Bash can be used to supply the sequence of commands:

Bash

GPG\_PASSPHRASE="your\_passphrase"  
PRIMARY\_FPR="your\_primary\_key\_fingerprint"

echo "$GPG\_PASSPHRASE" | gpg \--pinentry-mode loopback \--passphrase-fd 0 \\  
    \--status-fd 2 \--command-fd 0 \--expert \--edit-key "$PRIMARY\_FPR" \<\<EOF  
addkey  
4 \# RSA (sign only)  
4096 \# Key size  
1y \# Expires in 1 year  
y \# Is this correct?  
y \# Really create?  
addkey  
6 \# RSA (encrypt only)  
4096 \# Key size  
1y \# Expires in 1 year  
y \# Is this correct?  
y \# Really create?  
addkey  
8 \# RSA (set your own capabilities)  
S \# Toggle off sign  
E \# Toggle off encrypt  
A \# Toggle on authenticate  
Q \# Finish  
4096 \# Key size  
1y \# Expires in 1 year  
y \# Is this correct?  
y \# Really create?  
save  
EOF

This approach provides granular control, allowing selection of specific capabilities (e.g., option 8 for RSA set-your-own, then toggling S/E/A as needed).17 However, it is more complex to script reliably than multiple gpg \--quick-add-key calls, especially regarding interactive prompts that \--batch usually suppresses. The \--expert flag is often needed to access all capability options.17

### **2.4. Generating Revocation Certificates**

Revocation certificates are crucial for declaring that a key (or subkey) should no longer be trusted. They should be generated immediately after key creation and stored securely and separately from the private keys.2

**Primary Key Revocation Certificate**

GPG creates a revocation certificate for the primary key automatically when using \--generate-key or \--full-generate-key, storing it in the $GNUPGHOME/openpgp-revocs.d/ directory, named after the key's fingerprint with a .rev extension.13  
Alternatively, a primary key revocation certificate can be generated explicitly using:  
gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--output "${PRIMARY\_FPR}\_revocation\_cert.asc" \--gen-revoke "${PRIMARY\_FPR}"  
This command will prompt for a revocation reason unless \--batch is fully effective in suppressing it or a reason code is supplied if possible through batch parameters (not standard for \--gen-revoke). The output file will contain the ASCII-armored revocation certificate.19  
**Subkey Revocation Certificates**

Generating standalone, exportable revocation certificates for *individual* subkeys is less straightforward with GPG CLI alone.

* **Revoking in Keyring:** Using gpg \--edit-key \<primary\_key\_id\>, one can select a subkey (key N) and then issue the revkey command.1 This marks the subkey as revoked *within the GPG keyring*. The updated public key (containing this revocation information) can then be exported. However, this doesn't produce a separate revocation certificate file for just the subkey that can be imported independently.  
* **gen-revoke Tool:** The gen-revoke tool is a third-party Bash script designed to address this gap.22 It generates revocation signatures for the primary key and *each* subkey individually. These signatures are then encrypted for specified recipients.  
  * **Usage for Self-Revocation:** If the key owner is the recipient, they will receive encrypted files. To obtain the raw, unencrypted revocation certificate for a subkey, the owner must decrypt the corresponding output file from gen-revoke using their primary key.22 Example: gpg \--decrypt \-o subkey\_XYZ\_revocation\_cert.asc \<primary-key-id\>-subkey-\<subkey-id\>-\<owner-key-id\>.gpg.gpg  
  * The gen-revoke script requires expect as a dependency.23

The ability to generate and store individual revocation certificates for subkeys is a critical component of a robust key management strategy, allowing for granular response to subkey compromises without needing to revoke the entire primary key or other subkeys unnecessarily.

The following table summarizes key GPG CLI commands for automating the key lifecycle:

**Table 1: GPG CLI Commands for Key Lifecycle Automation**

| Operation | GPG CLI Command | Snippet(s) Example | Notes |
| :---- | :---- | :---- | :---- |
| Primary Key Generation (Batch) | gpg \--batch \--generate-key \<param\_file\> | 6 | Parameter file defines key type, length, UID, initial subkey, passphrase (or %no-protection). Only one subkey definable here. |
| Add Signing Subkey | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--quick-add-key \<fpr\> \<algo\> sign \<expire\> | 12 | Adds a sign-only subkey. |
| Add Encryption Subkey | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--quick-add-key \<fpr\> \<algo\> encr \<expire\> | 13 | Adds an encrypt-only subkey. |
| Add Authentication Subkey | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--quick-add-key \<fpr\> \<algo\> auth \<expire\> | 13 | Adds an auth-only subkey. |
| Primary Revocation Certificate | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--output \<file\> \--gen-revoke \<key\_id\_or\_fpr\> | 19 | Generates revocation cert for the entire primary key. |
| Subkey Revocation (in-keyring) | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--command-fd 0 \--edit-key \<fpr\> (then key N, revkey, save) | 1 | Revokes subkey within the keyring. Does not produce a standalone subkey revocation certificate. |

The usage parameter for gpg \--quick-add-key is essential for creating subkeys with distinct, single capabilities.

**Table 2: Subkey usage Parameter for gpg \--quick-add-key**

| Desired Capability | usage Parameter Value | Snippet(s) |
| :---- | :---- | :---- |
| Signing Only | sign | 5 |
| Encryption Only | encr (or encrypt) | 5 |
| Authentication Only | auth | 5 |
| Default (often Encrypt) | default or \- | 15 |

## **3\. Idempotency in GPG Automation Scripts**

Idempotency ensures that running a script multiple times produces the same result as running it once, without causing errors or unintended changes on subsequent runs.24 In the context of GPG key generation, this means the script should check for the existence of keys, subkeys with specific capabilities, and revocation certificates before attempting to create them.

### **3.1. Defining Idempotency in GPG Context**

For GPG automation, an idempotent script would:

1. Check if a primary key with the specified User ID (UID) already exists.  
2. If it exists, verify if it has the required subkeys (Sign, Encrypt, Authenticate) with the correct capabilities and parameters (algorithm, length, expiration within an acceptable range).  
3. Check if revocation certificates for the primary key and each required subkey have already been generated and stored.  
4. Only proceed with creation steps for components that are missing or do not meet the desired criteria.

### **3.2. Checking for Existing Keys and Subkeys**

GPG's \--with-colons output format is designed for machine parsing and is crucial for idempotency checks.26 Commands like gpg \--list-keys \--with-colons \--with-fingerprint \<UID\> and gpg \--list-secret-keys \--with-colons \--with-fingerprint \<UID\> provide detailed, colon-delimited information.

A script can parse this output (e.g., using awk or sed in Bash) to:

* **Identify Primary Key Fingerprint (FPR):** The fpr record type in the output gives the full fingerprint (Field 10).29  
* **Verify User ID (UID):** The uid record type contains the UID string (Field 10), which can be matched against the target UID.29  
* **Identify Subkey Fingerprints and Capabilities:** sub records denote subkeys. Their fingerprints are in subsequent fpr records. The capabilities of a subkey are listed in Field 12 of the sub record.29 This field is a string of characters, where:  
  * s: signing capability  
  * e: encryption capability  
  * a: authentication capability  
  * c: certification capability (usually for primary keys)  
  * Uppercase letters (S, E, A, C) on a pub line indicate the effective capabilities of the key, often derived from its subkeys.29

An awk script can iterate through the \--with-colons output. For each sub record associated with the primary key, it can check Field 12\. To verify an *exclusively* signing subkey, the script must confirm that 's' is present AND 'e' and 'a' are absent (or not in their active forms for that specific subkey record). Similar logic applies for exclusively encryption or authentication subkeys.

Example awk snippet to extract subkey capabilities for a given primary key fingerprint:

Bash

PRIMARY\_FPR="YOUR\_PRIMARY\_KEY\_FINGERPRINT"  
gpg \--list-keys \--with-colons \--with-fingerprint "$PRIMARY\_FPR" | \\  
awk \-F: '  
    /^pub/ { current\_fpr=$5 }  
    current\_fpr \== ENVIRON && /^sub/ {  
        kid=$5; caps=$12;  
        has\_s=0; has\_e=0; has\_a=0;  
        if (caps \~ /s/) { has\_s=1 }  
        if (caps \~ /e/) { has\_e=1 }  
        if (caps \~ /a/) { has\_a=1 }  
        \# Further logic to check for exclusive capabilities  
        print "Subkey KID: " kid ", Capabilities: " caps ", S:" has\_s ", E:" has\_e ", A:" has\_a;  
    }  
' PRIMARY\_FPR="$PRIMARY\_FPR"

This parsing is essential. For instance, a subkey might possess multiple capabilities (e.g., "sea"). If the goal is to ensure a dedicated "sign-only" subkey, merely checking for "s" is insufficient; the absence of "e" and "a" for that specific subkey must also be verified. This robust parsing ensures that the script correctly identifies whether subkeys with the *exact required distinct capabilities* exist.

### **3.3. Checking for Existing Revocation Certificates**

Idempotency for revocation certificate generation often relies on filesystem checks, as these certificates are typically exported and stored securely.

* **Primary Key Revocation Certificate:** GPG automatically stores this in $GNUPGHOME/openpgp-revocs.d/ using the key's fingerprint as the filename (e.g., \<FINGERPRINT\>.rev).13 The script can check for the existence of this file. If an explicit export path is used (e.g., ${EXPORT\_DIR}/${PRIMARY\_FPR}\_revocation\_cert.asc), that path should be checked.  
* **Subkey Revocation Certificates:** If using the gen-revoke tool, the script would define a standard output path for the *decrypted* subkey revocation certificates. Idempotency involves checking if these specific files (e.g., ${EXPORT\_DIR}/subkey\_${SUBKEY\_FPR}\_revocation\_cert.asc) already exist. GPG itself does not offer a direct command to "check if a standalone revocation certificate exists for subkey X" apart from attempting to import one and observing the result.

Defining a consistent naming convention and storage location for all exported artifacts (keys, subkey revocations) is paramount for reliable idempotency checks based on the filesystem.

## **4\. Secure Passphrase Management in Automated Scripts**

Securely handling passphrases is one of the most critical aspects of GPG automation. Passphrases protect private keys, and their compromise negates many of GPG's security benefits. For automated scripts, passphrases are often supplied via environment variables.

### **4.1. Supplying Passphrases from Environment Variables**

The recommended method for supplying a passphrase from an environment variable (e.g., GPG\_PASSPHRASE) to GPG in a script is to pipe the passphrase to GPG's standard input, using the \--passphrase-fd 0 option. This tells GPG to read the passphrase from file descriptor 0 (stdin).32

Bash

echo "$GPG\_PASSPHRASE" | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \[other\_gpg\_options\]

* \--batch: Enables non-interactive mode.  
* \--pinentry-mode loopback: Instructs GPG to use a loopback mechanism for pinentry, allowing the passphrase to be supplied programmatically rather than through an interactive terminal prompt.11  
* \--passphrase-fd 0: Tells GPG to read the passphrase from standard input.

This approach is generally preferred over passing the passphrase directly as a command-line argument (e.g., using \--passphrase "$GPG\_PASSPHRASE"), because command-line arguments can be visible in the system's process list (ps output), posing a security risk.32 While the pipe method is more secure, the security of the environment variable itself depends on the calling system (e.g., secure handling by CI/CD platforms).

For GPG versions 2.1 and later, the allow-loopback-pinentry option may need to be added to the gpg-agent.conf file within the GNUPGHOME directory used by the script.38 This explicitly permits GPG to accept passphrases in this manner.  
echo "allow-loopback-pinentry" \>\> "${GNUPGHOME}/gpg-agent.conf"

### **4.2. Using \--passphrase-file**

An alternative is the \--passphrase-file \<filepath\> option, where the passphrase is read from the specified file.32 If this method is chosen for automation:

* The file containing the passphrase must have highly restrictive permissions (e.g., chmod 400 or chmod 600, readable only by the script's user).  
* The file should be temporary and securely deleted immediately after use. Storing it on a ramdisk, if feasible, can prevent it from being written to persistent storage.  
* Bash process substitution can be used to avoid creating an actual file on disk, for example: gpg \--batch \--pinentry-mode loopback \--passphrase-file \<(echo "$GPG\_PASSPHRASE")....32 This combines the security benefits of piping with the \--passphrase-file interface.

Managing secure file creation, permissions, and deletion adds complexity, making the \--passphrase-fd 0 method often simpler for ephemeral environments.

### **4.3. The Role and Configuration of gpg-agent in Automation**

The gpg-agent is a daemon that manages secret keys and caches passphrases. In automated, often ephemeral environments like CI/CD pipelines:

* Relying on a pre-existing, long-running gpg-agent with cached passphrases is generally not viable or secure. Each script execution should ideally be self-contained.  
* The \--pinentry-mode loopback option, as used with \--passphrase-fd 0, effectively bypasses the agent's interactive passphrase prompting for that specific GPG invocation.  
* If there's a need to ensure a clean agent state or apply new configurations (like allow-loopback-pinentry), commands such as gpgconf \--kill gpg-agent or gpg-connect-agent reloadagent /bye might be executed at the beginning of the script.39 However, for isolated script runs with passphrases supplied via environment variables and \--passphrase-fd 0, direct agent interaction for passphrase caching is often unnecessary.

### **4.4. Risks of \--no-protection (Passphrase-less Keys)**

GPG allows the creation of keys without passphrase protection using the %no-protection control statement in batch key generation parameter files, or the \--passphrase '' option with gpg \--quick-generate-key.5  
This practice is strongly discouraged for any primary keys or sensitive subkeys intended for operational use.

* If a private key file without passphrase protection is compromised (e.g., exfiltrated from a server), it is immediately usable by an attacker to decrypt messages or forge signatures.43  
* The passphrase on a private key serves as a critical last line of defense.  
* The use of \--no-protection might only be considered for extremely short-lived, special-purpose keys in highly controlled, ephemeral environments where the key material is generated, used, and securely destroyed within a very brief window, and the risk of file compromise during that window is negligible. Given the query implies keys for a project, this is unlikely to be an acceptable risk.

The following table compares passphrase handling techniques:

**Table 3: Passphrase Handling Techniques Comparison**

| Method | Security Considerations | Bash Snippet Example (Conceptual) | Pros | Cons |
| :---- | :---- | :---- | :---- | :---- |
| \--passphrase-fd 0 from Env Var (via echo) | Env var security depends on host. Pipe is generally secure. Avoids passphrase in process arguments. GPG 2.1+ may need allow-loopback-pinentry. | \`echo "$PASS" \\ | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0...\` | Widely used, relatively simple. Avoids passphrase in ps output. |
| \--passphrase-file \<(echo "$PASS") | Similar to piped stdin; avoids disk write for passphrase. | gpg \--batch \--pinentry-mode loopback \--passphrase-file \<(echo "$PASS")... | Avoids passphrase in ps output and explicit temp file on disk. | Relies on shell's process substitution. |
| \--passphrase-file /path/to/file | File must have strict permissions (e.g., 400). Secure deletion is critical. Risk of passphrase exposure if file is not handled properly. | echo "$PASS" \> /tmp/pfile; chmod 400 /tmp/pfile; gpg... \--passphrase-file /tmp/pfile; rm \-f /tmp/pfile | Explicit control over file. | Complex to manage securely (permissions, secure deletion, avoiding persistent storage). High risk if not implemented perfectly. |
| \--passphrase "$PASS" (Direct CLI Argument) | **HIGHLY INSECURE.** Passphrase visible in process list (ps). | gpg \--batch \--passphrase "$PASS"... | Simple to write. | Major security vulnerability; passphrase exposed in process list. **Should not be used.** |
| %no-protection / \--passphrase '' | No passphrase on private key. If key file is stolen, it's immediately usable. | Batch file: %no-protection \<br\> CLI: gpg... \--passphrase ''... | No passphrase needed for operations. | Extremely insecure if private key file is ever compromised. Only for highly specialized, ephemeral, low-risk scenarios. **Not recommended for general use.** |

## **5\. Python-Based GPG Automation: python-gnupg and PGPy**

Python offers libraries for interacting with GPG, which can provide a higher-level interface than raw Bash scripting. Two prominent libraries are python-gnupg and PGPy.

### **5.1. python-gnupg Approach**

python-gnupg acts as a wrapper around the GPG command-line executable.38 It simplifies invoking GPG commands and parsing their output from within Python.

* **Key Generation:** Primary keys (and typically one initial subkey) are generated using gpg.gen\_key(input\_data), where input\_data is created by gpg.gen\_key\_input(\*\*params).38 The parameters for gen\_key\_input (e.g., key\_type, key\_length, name\_real, passphrase, subkey\_type, subkey\_usage) map to those used in GPG's batch generation mode.  
* **Subkey Addition:** Additional subkeys can be added using gpg.add\_subkey(fingerprint, algorithm='rsa', usage='encrypt', expire='-').38 The documentation for python-gnupg 38 indicates that the usage parameter for add\_subkey defaults to 'encrypt'. It is not explicitly clear from these documents whether setting usage='sign' or usage='auth' directly translates to creating subkeys with *only* those distinct capabilities, or if it would require passing specific GPG CLI arguments via an extra\_args parameter. The gen\_key\_input method does have a subkey\_usage parameter 48, but this applies to the single subkey that can be defined during the initial batch generation of the primary key.  
* **Revocation Certificate Generation:**  
  * **Primary Key:** A revocation certificate for the primary key can be generated by invoking gpg.gen\_revoke(key\_input, passphrase) or by directly executing the gpg \--generate-revocation command via gpg.run() or a similar subprocess call. The library's high-level API for generating a revocation certificate as a storable artifact is not as explicit as for key generation itself.38 Standard GPG CLI methods like gpg \--output revoke.asc \--gen-revoke KEYID are often used.20  
  * **Subkeys:** python-gnupg does not appear to offer a direct high-level method for generating and exporting standalone revocation certificates for individual subkeys.1 This would likely necessitate scripting gpg \--edit-key commands (using key N then revkey) via gpg.run() and then exporting the updated primary key, or using an external tool like gen-revoke and processing its output.  
* **Passphrase Handling:** Passphrases can be supplied to methods like gen\_key, add\_subkey, export\_keys, etc. The library handles passing these to the underlying GPG process, often requiring allow-loopback-pinentry in gpg-agent.conf for GPG 2.1+.38

The utility of python-gnupg for creating a full set of distinct S, E, A subkeys and their individual revocation certificates might be limited if it requires falling back to raw GPG command execution for these specific advanced features.

### **5.2. PGPy Approach**

PGPy is a pure Python implementation of the OpenPGP standard (RFC 4880\) and does not require an external GPG executable.55 This gives it more direct control over key and signature objects.

* **Key Generation:** A new primary key is created with key \= pgpy.PGPKey.new(PubKeyAlgorithm.RSAEncryptOrSign, 4096).55  
* **UID Addition:** A User ID is created with uid \= pgpy.PGPUID.new('Name', comment='Comment', email='user@example.com') and added to the key using key.add\_uid(uid, usage={KeyFlags.Certify, KeyFlags.Sign,...}, key\_expiration=datetime,...).55 The primary key implicitly gains KeyFlags.Certify.  
* **Subkey Addition:** New keys are generated with pgpy.PGPKey.new(...) and then added as subkeys using primary\_key.add\_subkey(subkey\_obj, usage={KeyFlags.Sign}). The usage parameter takes a set of KeyFlags constants, allowing for precise capability assignment.15  
  * Sign-only: usage={KeyFlags.Sign}  
  * Encrypt-only: usage={KeyFlags.EncryptCommunications}  
  * Authenticate-only: usage={KeyFlags.Authentication} This explicit control via KeyFlags directly addresses the requirement for distinct subkey capabilities.  
* **Revocation Certificate Generation:**  
  * **Primary Key:** A revocation signature for the primary key is generated using rev\_sig \= primary\_key.revoke(reason=RevocationReason.Superseded, comment="..."). The resulting PGPSignature object can be converted to an ASCII-armored string using str(rev\_sig) and saved to a .asc file.50  
  * **Subkeys:** Individual subkeys are revoked by calling revoke() on the primary key, targeting the subkey object: rev\_sig \= primary\_key.revoke(subkey\_to\_revoke, sigtype=SignatureType.SubkeyRevocation, reason=...). The sigtype=SignatureType.SubkeyRevocation ensures the correct type of revocation signature is created.55 The resulting PGPSignature object can then be exported as an ASCII-armored string (str(rev\_sig)) and saved to a .asc file, which GPG can import to recognize the subkey revocation.55 This provides a direct, programmatic way to generate standalone revocation certificates for individual subkeys.  
* **Passphrase Handling:** Private keys are protected using key.protect("your\_passphrase", SymmetricKeyAlgorithm.AES256, HashAlgorithm.SHA256) and unlocked using a context manager: with key.unlock("your\_passphrase"):....42 The passphrase can be sourced from an environment variable within the Python script.  
* **Idempotency:** Achieved by attempting to load an existing key (e.g., by fingerprint or from a file). If loaded, its key.uids can be checked for matching UIDs, and key.subkeys can be iterated to inspect each subkey\_obj.fingerprint and subkey\_obj.key\_flags against desired values.15 Revocation certificate idempotency involves checking for the existence of previously exported .asc files.

### **5.3. Comparative Analysis for this Use Case**

| Feature | GPG CLI (Bash) | python-gnupg | PGPy |
| :---- | :---- | :---- | :---- |
| **Primary Key Generation** | Native (--generate-key \--batch) | Native (gen\_key, gen\_key\_input) | Native (PGPKey.new, add\_uid) |
| **Distinct Sign Subkey Gen** | Native (--quick-add-key \<fpr\> \<alg\> sign \<exp\>) | Via add\_subkey (clarity on distinct sign usage needs verification, may need extra\_args) | Native (add\_subkey with usage={KeyFlags.Sign}) |
| **Distinct Encrypt Subkey Gen** | Native (--quick-add-key \<fpr\> \<alg\> encr \<exp\>) | Native (add\_subkey with usage='encrypt' or default) | Native (add\_subkey with usage={KeyFlags.EncryptCommunications}) |
| **Distinct Auth Subkey Gen** | Native (--quick-add-key \<fpr\> \<alg\> auth \<exp\>) | Via add\_subkey (clarity on distinct auth usage needs verification, may need extra\_args) | Native (add\_subkey with usage={KeyFlags.Authentication}) |
| **Primary Revocation Cert Gen & Export** | Native (--generate-revocation) | Via gen\_revoke method or raw GPG call (run()) | Native (key.revoke(), then str(rev\_sig\_obj) to export) |
| **Individual Subkey Revoke Cert Gen & Export** | Complex (via gen-revoke tool \+ gpg \--decrypt, or complex gpg \--edit-key scripting) | Very Complex (likely requires raw GPG calls via run() or external gen-revoke tool) | Native (primary\_key.revoke(subkey, sigtype=SubkeyRevocation), then str(rev\_sig\_obj) to export) |
| **Idempotency (UID check)** | Scriptable (parse \--with-colons) | Scriptable (parse list\_keys() output) | Native (load key, iterate key.uids) |
| **Idempotency (Subkey capability check)** | Scriptable (parse \--with-colons field 12\) | Scriptable (parse list\_keys() subkey capabilities string) | Native (iterate key.subkeys, check subkey.key\_flags) |
| **Passphrase from Env Var** | Native (e.g., \`echo "$PASS" \\ | gpg \--passphrase-fd 0...\`) | Native (passphrase arg to methods, library handles interaction with GPG CLI) |
| **Dependencies** | GPG CLI, gen-revoke (optional, for subkey revokes), expect (for gen-revoke) | GPG CLI, python-gnupg library | PGPy library (pure Python, no GPG CLI needed) |

For the comprehensive set of requirements, particularly distinct subkey capabilities and individual subkey revocation certificate generation and export, PGPy appears to offer the most direct and integrated programmatic solution due to its object-oriented nature and pure Python implementation. GPG CLI with Bash scripting provides full power but requires more intricate scripting for parsing and managing state for advanced features like individual subkey revocation exports. python-gnupg, being a wrapper, might necessitate falling back to raw GPG commands for some of these advanced, specific needs, potentially reducing its abstraction benefits in those areas.

## **6\. Best Practices for Scripting and Security**

Automating GPG key lifecycle management requires adherence to security best practices to prevent accidental exposure or misuse of sensitive key material.

### **6.1. Structuring Scripts for Clarity and Maintainability**

Regardless of the chosen tool (Bash, Python), scripts should be well-structured:

* **Modular Design:** Break down the process into logical functions or methods (e.g., create\_primary\_key, add\_signing\_subkey, generate\_primary\_revocation, check\_existing\_key).77  
* **Clear Naming:** Use descriptive variable and function names (e.g., USER\_EMAIL, PRIMARY\_KEY\_FINGERPRINT, SIGN\_SUBKEY\_EXPIRY).  
* **Comprehensive Comments:** Document the purpose of each code block, assumptions made, and the rationale behind specific GPG options or parameters used.77 This is vital for long-term maintenance and understanding by other team members.

### **6.2. Robust Error Handling**

Effective error handling is critical for reliable automation.

* **GPG CLI (Bash):**  
  * **Exit Codes:** Always check the exit code of GPG commands ($? in Bash). A non-zero exit code usually indicates an error, but GPG's exit codes can be generic (e.g., 1 for bad signature, 2 for most other errors).28  
  * **\--status-fd \<n\>:** This option directs GPG to write machine-readable status messages to a specified file descriptor.28 These messages provide granular feedback on operations. Key status messages include 11:  
    * \[GNUPG:\] KEY\_CREATED \<type\> \<fingerprint\> \<handle\>: Indicates successful primary key creation.  
    * \[GNUPG:\] SUBKEY\_CREATED \<fingerprint\_primary\> \<fingerprint\_subkey\> \<handle\>: Indicates successful subkey creation.  
    * \[GNUPG:\] REVOKESIG: Indicates a revocation signature was made (often seen during \--gen-revoke).  
    * \[GNUPG:\] GOOD\_PASSPHRASE: Confirms correct passphrase entry.  
    * \[GNUPG:\] BAD\_PASSPHRASE: Indicates incorrect passphrase.  
    * \[GNUPG:\] KEY\_CONSIDERED \<fingerprint\> \<flags\>: Provides information about a key being considered for an operation. Flags indicate usability (e.g., 0 for usable, 1 for expired, 2 for revoked, 4 for no UID).  
    * \[GNUPG:\] INV\_RECP \<key\_id\>: Invalid recipient.  
    * \[GNUPG:\] ERRSIG \<key\_id\> \<algo\> \<hash\_algo\> \<class\> \<timestamp\> \<policy\_url\_or\_fpr\>: Error verifying signature.  
    * \[GNUPG:\] KEYEXPIRED, \[GNUPG:\] SIGEXPIRED: Key or signature has expired.  
    * \[GNUPG:\] NEED\_PASSPHRASE \<keygrip\> \<tty\> \<cache\_id\>: Passphrase is required.  
    * \[GNUPG:\] USERID\_HINT \<keygrip\> \<uid\_hash\> \<uid\_string\>: Hint for passphrase prompt.  
    * \[GNUPG:\] KEY\_NOT\_CREATED: Key generation failed for some reason.  
    * \[GNUPG:\] NODATA: Indicates no data was processed, which can be an error in some contexts.  
    * \[GNUPG:\] IMPORTED \<fpr\>: Key successfully imported.  
    * \[GNUPG:\] IMPORT\_OK \<count\_unchanged\> \<count\_new\_keys\>: Status of import operation.  
    * \[GNUPG:\] IMPORT\_PROBLEM \<count\_problems\> \<keyid\_or\_fpr\>: Problem during import. Parsing these status lines allows the script to react specifically to different outcomes.  
* **Python Libraries:**  
  * python-gnupg: Results from methods often include a status attribute and stderr output that can be checked.  
  * PGPy: Utilizes Python's standard exception handling. Catch specific exceptions like PGPError, PGPKeyImportError, PGPDecryptionError (for unlocking keys) to handle issues gracefully.72  
* **Insufficient Entropy:** Key generation can fail or hang if the system lacks sufficient entropy, especially in virtualized or headless environments.87 Scripts should detect this (e.g., via timeout or specific GPG error messages like "Not enough random bytes available") and log appropriate guidance. Solutions might involve installing tools like rng-tools or haveged, though their configuration requires care to ensure true randomness if used for critical key generation.88

### **6.3. Managing GNUPGHOME Permissions and Isolation**

The GNUPGHOME directory contains sensitive keyring files. For automated scripts:

* **Temporary GNUPGHOME:** It is highly recommended to use a temporary, script-specific GNUPGHOME directory for each run. This directory should be created with restrictive permissions (e.g., chmod 700 $GNUPGHOME\_TMP) to ensure only the script's user can access it.  
* **Isolation:** This prevents interference with the user's regular GPG keyring or other concurrent automated processes.  
* **Secure Deletion:** After the script has completed its operations and exported all necessary artifacts (keys, revocation certificates), the temporary GNUPGHOME directory and its contents should be securely deleted. Improper GNUPGHOME management, such as using a shared or world-readable directory, or failing to clean up temporary keyrings, can lead to private key exposure.

### **6.4. Securely Storing Generated Keys and Revocation Certificates**

The long-term security of the GPG setup hinges on the secure storage of the generated artifacts.

* **Private Keys (Master and Subkeys):**  
  * Must be protected by strong, unique passphrases.  
  * Backups should be made immediately after generation.  
  * Store these backups in multiple, geographically separate, secure offline locations (e.g., encrypted USB drives in a safe, paperkey backups).2 The primary master key's private part, in particular, should be kept offline.  
* **Revocation Certificates:**  
  * Store these with equal or greater security than the private keys, but *separately*.19  
  * If a private key is compromised, its revocation certificate is needed to declare it invalid.  
  * If a revocation certificate is compromised, an attacker could prematurely or maliciously revoke a valid key, causing disruption.  
* **File Permissions:** When exporting keys or certificates to files, the script must ensure these files are created with restrictive permissions (e.g., chmod 600 or chmod 400\) before they are moved to their final secure storage.

Automation scripts can facilitate the secure export of these artifacts, but the responsibility for their long-term secure storage lies with the user or organization.

### **6.5. Ensuring Sufficient Entropy for Key Generation**

GPG relies on a source of unpredictable random data (entropy) for generating cryptographically strong keys. In environments with low activity, such as virtual machines or headless servers often used for automation, insufficient entropy can cause key generation to hang indefinitely or fail with messages like "Not enough random bytes available. Please do some other work...".87

* **Detection:** Scripts can implement timeouts for GPG key generation commands or parse GPG's stderr/status output for entropy-related error messages.  
* **Mitigation:**  
  * On systems where this is a persistent issue, installing an entropy-gathering daemon like rng-tools (which can use hardware RNGs if available) or haveged might be necessary.  
  * It is important to configure these tools correctly. Using /dev/urandom to feed /dev/random via rng-tools has been cautioned against if strong cryptographic guarantees are needed, as /dev/urandom itself might not always provide true entropy, especially on newly booted systems.88 Prioritize hardware RNGs if available.  
  * For critical key generation, ensuring a high-quality entropy source is paramount. Weak entropy leads to weak keys.

The following table outlines key GPG status messages useful for script-based error handling:

**Table 4: Key GPG Status Messages and Exit Codes for Automation**

| GPG Status Message (from \--status-fd) | GPG Exit Code (Typical) | Meaning | Recommended Script Action |
| :---- | :---- | :---- | :---- |
| \[GNUPG:\] KEY\_CREATED \<type\> \<fpr\> \<handle\> | 0 | Primary key successfully created. | Success, log fingerprint. |
| \[GNUPG:\] SUBKEY\_CREATED \<primary\_fpr\> \<subkey\_fpr\> \<handle\> | 0 | Subkey successfully created. | Success, log subkey fingerprint. |
| \[GNUPG:\] REVOKESIG | 0 | Revocation signature successfully created. | Success, confirm revocation certificate export. |
| \[GNUPG:\] GOOD\_PASSPHRASE | 0 (usually part of a larger op) | Passphrase accepted. | Continue operation. |
| \[GNUPG:\] BAD\_PASSPHRASE | 1 or 2 | Incorrect passphrase supplied. | Failure, log error, do not retry with same passphrase. Prompt for new if interactive. |
| \[GNUPG:\] KEY\_NOT\_CREATED | 2 | Key generation failed (reason may be in stderr or other status lines). | Failure, log error and any preceding status messages (e.g., entropy issues). |
| \[GNUPG:\] KEYEXPIRED \<fpr\> | (Context-dependent) | Key has expired. | Log warning/error; may prevent use of key. |
| \[GNUPG:\] SIGEXPIRED | (Context-dependent) | Signature has expired. | Log warning. |
| \[GNUPG:\] INV\_RECP \<keyid\> | 2 | Invalid or unusable recipient key during encryption. | Failure, log error, check recipient key status. |
| \[GNUPG:\] ERRSIG \<keyid\>... | 1 or 2 | Error verifying a signature. | Failure if verification is critical, log details. |
| \[GNUPG:\] NODATA | 2 | No input data provided when expected (e.g. for encryption/signing). | Failure, check input to GPG. |
| \[GNUPG:\] NEED\_PASSPHRASE \<keygrip\>... | (Usually part of a prompt) | GPG requires a passphrase and is attempting to prompt. | If unexpected in batch mode, indicates loopback pinentry or \--passphrase-fd issue. Fail. |
| gpg: decryption failed: No secret key (stderr) | 2 | Secret key required for decryption is not available. | Failure, ensure correct key is in keyring and accessible. |
| gpg: Not enough random bytes available. (stderr) | 2 | Insufficient entropy for key generation. | Failure, log error, advise on entropy generation. |
| gpg: key B...1: error changing passphrase: No passphrase given (stderr) | 2 | Attempted to change/set passphrase to empty when not allowed or failed. | Failure, check passphrase logic. |

*Note: GPG exit codes can be general. Parsing \--status-fd is more reliable for specifics.*

## **7\. Comprehensive Example Scripts (Conceptual Outlines & Key Snippets)**

Implementing a fully automated, idempotent GPG key lifecycle management script requires careful orchestration of the commands and checks discussed. Below are conceptual outlines for Bash and Python (PGPy) approaches.

### **7.1. Full Lifecycle Bash Script Outline**

This script would use GPG CLI commands and tools like awk for parsing. Environment variables would supply parameters like UID components and passphrases.

Bash

\#\!/bin/bash  
set \-euo pipefail \# Strict mode

\# \--- Configuration (from environment variables or arguments) \---  
GPG\_USER\_NAME="${GPG\_USER\_NAME:-"Automated Key User"}"  
GPG\_USER\_EMAIL="${GPG\_USER\_EMAIL:-"automation@example.com"}"  
GPG\_USER\_COMMENT="${GPG\_USER\_COMMENT:-"Automated GPG Key"}"  
GPG\_PASSPHRASE="${GPG\_PASSPHRASE}" \# Must be set  
GPG\_KEY\_TYPE="${GPG\_KEY\_TYPE:-RSA}"  
GPG\_KEY\_LENGTH="${GPG\_KEY\_LENGTH:-4096}"  
GPG\_SUBKEY\_TYPE="${GPG\_SUBKEY\_TYPE:-RSA}" \# For subkeys  
GPG\_SUBKEY\_LENGTH="${GPG\_SUBKEY\_LENGTH:-4096}" \# For subkeys  
GPG\_EXPIRY\_MASTER="${GPG\_EXPIRY\_MASTER:-0}" \# 0 for no expiry  
GPG\_EXPIRY\_SUBKEY="${GPG\_EXPIRY\_SUBKEY:-1y}" \# 1 year for subkeys  
EXPORT\_DIR="./gpg\_artifacts"  
GNUPGHOME\_TMP="$(mktemp \-d)"

\# \--- Utility Functions \---  
cleanup() {  
  echo "Cleaning up temporary GNUPGHOME: $GNUPGHOME\_TMP"  
  rm \-rf "$GNUPGHOME\_TMP"  
}  
trap cleanup EXIT

\# Set GNUPGHOME for this script's operations  
export GNUPGHOME="$GNUPGHOME\_TMP"  
mkdir \-p "$EXPORT\_DIR"  
chmod 700 "$GNUPGHOME\_TMP"  
echo "allow-loopback-pinentry" \> "${GNUPGHOME}/gpg-agent.conf"  
gpgconf \--kill gpg-agent \>/dev/null 2\>&1 |  
| true \# Ensure agent picks up new conf

\# Function to log messages  
log\_msg() { echo "\[INFO\] $1"; }  
log\_err() { echo " $1" \>&2; }

\# Function to check GPG command status  
\# Usage: check\_gpg\_status $? "$gpg\_status\_output" "Success Message" "Failure Message"  
check\_gpg\_status() {  
  local exit\_code="$1"  
  local status\_output="$2"  
  local success\_msg\_pattern="$3"  
  local operation\_desc="$4"

  if \[ "$exit\_code" \-ne 0 \]; then  
    log\_err "$operation\_desc failed with exit code $exit\_code."  
    log\_err "GPG Status Output: $status\_output"  
    log\_err "GPG Stderr: $(cat gpg\_stderr.log)" \# Assuming stderr is captured  
    return 1  
  fi  
  if\! echo "$status\_output" | grep \-qE "\\\[GNUPG:\\\] ${success\_msg\_pattern}"; then  
    log\_err "$operation\_desc did not yield expected success status '$success\_msg\_pattern'."  
    log\_err "GPG Status Output: $status\_output"  
    log\_err "GPG Stderr: $(cat gpg\_stderr.log)"  
    return 1  
  fi  
  log\_msg "$operation\_desc successful."  
  return 0  
}

\# \--- Idempotency Check: Primary Key \---  
log\_msg "Checking for existing primary key for UID: $GPG\_USER\_EMAIL"  
PRIMARY\_FPR=$(gpg \--list-keys \--with-colons "$GPG\_USER\_EMAIL" 2\>/dev/null | awk \-F: '/^pub/ &&\!/revoked/ &&\!/expired/{fpr\_line=1;next} fpr\_line && /^fpr/{print $10;exit}' |  
| true)

if; then  
  log\_msg "No existing primary key found. Proceeding with generation."  
  \# \--- 1\. Generate Master Key (Certify) \+ Default Subkey (Encrypt) \---  
  PARAM\_FILE\_CONTENT=$(cat \<\<EOF  
%echo Generating GPG key  
Key-Type: $GPG\_KEY\_TYPE  
Key-Length: $GPG\_KEY\_LENGTH  
Key-Usage: cert  
Subkey-Type: $GPG\_SUBKEY\_TYPE  
Subkey-Length: $GPG\_SUBKEY\_LENGTH  
Subkey-Usage: encrypt  
Name-Real: $GPG\_USER\_NAME  
Name-Email: $GPG\_USER\_EMAIL  
Name-Comment: $GPG\_USER\_COMMENT  
Expire-Date: $GPG\_EXPIRY\_MASTER  
Passphrase: $GPG\_PASSPHRASE  
%commit  
%echo Key generation committed  
EOF  
)  
  \# Using a temporary file descriptor for status messages  
  exec 3\>gpg\_status.log  
  gpg\_output=$(echo "$PARAM\_FILE\_CONTENT" | gpg \--batch \--status-fd 3 \--generate-key \- 2\>gpg\_stderr.log)  
  gpg\_status\_output=$(cat gpg\_status.log)  
  exec 3\>&-

  if\! check\_gpg\_status $? "$gpg\_status\_output" "KEY\_CREATED" "Primary key generation"; then exit 1; fi  
  PRIMARY\_FPR=$(echo "$gpg\_status\_output" | awk \-F' ' '/\\\[GNUPG:\\\] KEY\_CREATED/{print $3}')  
  log\_msg "Primary key created with FPR: $PRIMARY\_FPR"  
  \# Export public and secret keys immediately  
  echo "$GPG\_PASSPHRASE" | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--armor \--export "$PRIMARY\_FPR" \> "${EXPORT\_DIR}/${PRIMARY\_FPR}\_pub.asc"  
  chmod 600 "${EXPORT\_DIR}/${PRIMARY\_FPR}\_pub.asc"  
  echo "$GPG\_PASSPHRASE" | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \--armor \--export-secret-keys "$PRIMARY\_FPR" \> "${EXPORT\_DIR}/${PRIMARY\_FPR}\_sec.asc"  
  chmod 400 "${EXPORT\_DIR}/${PRIMARY\_FPR}\_sec.asc"  
else  
  log\_msg "Primary key found with FPR: $PRIMARY\_FPR. Skipping generation."  
fi

\# \--- Idempotency Check & Add Subkeys (Sign, Auth) \---  
\# Function to check for subkey with specific capability (simplified)  
check\_subkey\_cap() {  
  local fpr="$1" cap\_char="$2" exclusive="$3"  
  gpg \--list-keys \--with-colons \--with-fingerprint "$fpr" 2\>/dev/null | \\  
  awk \-F: \-v cap\="$cap\_char" \-v excl="$exclusive" '  
    /^sub/ {  
      key\_caps \= $12;  
      is\_target\_cap \= (index(key\_caps, cap) \> 0);  
      is\_exclusive \= 1;  
      if (excl \== "true") {  
        if (cap \== "s" && (index(key\_caps, "e") \> 0 |  
| index(key\_caps, "a") \> 0)) { is\_exclusive \= 0; }  
        if (cap \== "e" && (index(key\_caps, "s") \> 0 |  
| index(key\_caps, "a") \> 0)) { is\_exclusive \= 0; }  
        if (cap \== "a" && (index(key\_caps, "s") \> 0 |  
| index(key\_caps, "e") \> 0)) { is\_exclusive \= 0; }  
      }  
      if (is\_target\_cap && is\_exclusive) { print $5; exit 0; } \# Print subkey fingerprint  
    }  
    END { exit 1 } \# Not found  
  '  
}

\# Add Signing Subkey  
SIGN\_SUBKEY\_FPR=$(check\_subkey\_cap "$PRIMARY\_FPR" "s" "true")  
if; then  
  log\_msg "Adding signing subkey..."  
  exec 3\>gpg\_status.log  
  echo "$GPG\_PASSPHRASE" | gpg \--batch \--status-fd 3 \--pinentry-mode loopback \--passphrase-fd 0 \\  
    \--quick-add-key "$PRIMARY\_FPR" "$GPG\_SUBKEY\_TYPE" sign "$GPG\_EXPIRY\_SUBKEY" 2\>gpg\_stderr.log  
  gpg\_status\_output=$(cat gpg\_status.log)  
  exec 3\>&-  
  if\! check\_gpg\_status $? "$gpg\_status\_output" "SUBKEY\_CREATED" "Signing subkey addition"; then exit 1; fi  
  SIGN\_SUBKEY\_FPR=$(echo "$gpg\_status\_output" | awk \-F' ' '/\\\[GNUPG:\\\] SUBKEY\_CREATED/{print $4}')  
else  
  log\_msg "Signing subkey already exists with FPR: $SIGN\_SUBKEY\_FPR."  
fi

\# Add Authentication Subkey  
AUTH\_SUBKEY\_FPR=$(check\_subkey\_cap "$PRIMARY\_FPR" "a" "true")  
if; then  
  log\_msg "Adding authentication subkey..."  
  exec 3\>gpg\_status.log  
  echo "$GPG\_PASSPHRASE" | gpg \--batch \--status-fd 3 \--pinentry-mode loopback \--passphrase-fd 0 \\  
    \--quick-add-key "$PRIMARY\_FPR" "$GPG\_SUBKEY\_TYPE" auth "$GPG\_EXPIRY\_SUBKEY" 2\>gpg\_stderr.log  
  gpg\_status\_output=$(cat gpg\_status.log)  
  exec 3\>&-  
  if\! check\_gpg\_status $? "$gpg\_status\_output" "SUBKEY\_CREATED" "Authentication subkey addition"; then exit 1; fi  
  AUTH\_SUBKEY\_FPR=$(echo "$gpg\_status\_output" | awk \-F' ' '/\\\[GNUPG:\\\] SUBKEY\_CREATED/{print $4}')  
else  
  log\_msg "Authentication subkey already exists with FPR: $AUTH\_SUBKEY\_FPR."  
fi

\# (Encryption subkey was created with primary key or needs similar check/add logic if not)  
ENCR\_SUBKEY\_FPR=$(check\_subkey\_cap "$PRIMARY\_FPR" "e" "true")  
if; then  
    log\_msg "Adding encryption subkey..."  
    \# Add logic similar to SIGN/AUTH subkeys if it wasn't created initially  
    \# For this example, assume it was created with the primary key or handle as needed.  
    log\_msg "Encryption subkey needs to be added or was expected with primary."  
fi

\# \--- 3\. Generate Revocation Certificates \---  
\# Primary Key Revocation  
PRIMARY\_REV\_CERT\_PATH="${EXPORT\_DIR}/${PRIMARY\_FPR}\_primary\_revocation.asc"  
if; then  
  log\_msg "Generating primary key revocation certificate..."  
  exec 3\>gpg\_status.log  
  echo "$GPG\_PASSPHRASE" | gpg \--batch \--status-fd 3 \--pinentry-mode loopback \--passphrase-fd 0 \\  
    \--output "$PRIMARY\_REV\_CERT\_PATH" \--gen-revoke "$PRIMARY\_FPR" 2\>gpg\_stderr.log  
  \# \--gen-revoke does not produce KEY\_CREATED/SUBKEY\_CREATED style status, check for REVOKESIG or file creation  
  \# For simplicity, we check exit code and file existence here. Robust parsing would check status-fd for REVOKESIG.  
  gpg\_status\_output=$(cat gpg\_status.log) \# Capture status if needed for REVOKESIG  
  exec 3\>&-  
  if \[ $? \-ne 0 \] ||; then  
    log\_err "Primary key revocation certificate generation failed."  
    log\_err "GPG Stderr: $(cat gpg\_stderr.log)"  
    exit 1  
  fi  
  chmod 400 "$PRIMARY\_REV\_CERT\_PATH"  
  log\_msg "Primary key revocation certificate generated: $PRIMARY\_REV\_CERT\_PATH"  
else  
  log\_msg "Primary key revocation certificate already exists: $PRIMARY\_REV\_CERT\_PATH"  
fi

\# Subkey Revocation Certificates (using gen-revoke, if installed)  
if command \-v gen-revoke.bash \>/dev/null 2\>&1; then  
  log\_msg "gen-revoke.bash found. Generating subkey revocation certificates."  
  \# gen-revoke encrypts output. Decrypt for self-storage.  
  \# This requires gen-revoke to be configured and public key of $GPG\_USER\_EMAIL to be in keyring  
  \# For each subkey (SIGN\_SUBKEY\_FPR, ENCR\_SUBKEY\_FPR, AUTH\_SUBKEY\_FPR if they exist)  
  \#   SUBKEY\_FPR\_VAR\_NAME should be the variable holding the subkey FPR (e.g. SIGN\_SUBKEY\_FPR)  
  \#   SUBKEY\_TYPE\_NAME should be a descriptive name (e.g. "signing")  
  for subkey\_info in "SIGN\_SUBKEY\_FPR:signing" "ENCR\_SUBKEY\_FPR:encryption" "AUTH\_SUBKEY\_FPR:authentication"; do  
    SUBKEY\_FPR\_VAR\_NAME=$(echo "$subkey\_info" | cut \-d: \-f1)  
    SUBKEY\_TYPE\_NAME=$(echo "$subkey\_info" | cut \-d: \-f2)  
    CURRENT\_SUBKEY\_FPR="${\!SUBKEY\_FPR\_VAR\_NAME}" \# Indirect expansion

    if; then  
      SUBKEY\_REV\_CERT\_PATH="${EXPORT\_DIR}/${CURRENT\_SUBKEY\_FPR}\_${SUBKEY\_TYPE\_NAME}\_subkey\_revocation.asc"  
      if; then  
        log\_msg "Generating revocation for $SUBKEY\_TYPE\_NAME subkey ($CURRENT\_SUBKEY\_FPR)..."  
        \# Create a temporary directory for gen-revoke outputs  
        GEN\_REVOKE\_TMP\_DIR=$(mktemp \-d)  
        ( \# Subshell to manage current directory for gen-revoke  
          cd "$GEN\_REVOKE\_TMP\_DIR"  
          \# gen-revoke needs passphrase for primary key  
          \# It uses 'expect' so direct echo piping is tricky.  
          \# Assuming gen-revoke handles passphrase input or uses agent if configured.  
          \# For full automation, gen-revoke might need modification or an expect script wrapper.  
          \# This is a simplified call; real automation needs robust passphrase handling for gen-revoke.  
          if\! gen-revoke.bash "$PRIMARY\_FPR" "$GPG\_USER\_EMAIL"; then  
            log\_err "gen-revoke failed for $SUBKEY\_TYPE\_NAME subkey."  
            rm \-rf "$GEN\_REVOKE\_TMP\_DIR"  
            continue \# Or exit 1 depending on desired strictness  
          fi  
            
          \# Find the encrypted revocation cert for the current subkey and decrypt it  
          \# Filename pattern: \<primary-key-id\>-subkey-\<subkey-id\>-\<rcpt\>.gpg.gpg  
          \# Subkey ID is usually the last 16 hex chars of its fingerprint.  
          SUBKEY\_SHORT\_ID=$(echo "$CURRENT\_SUBKEY\_FPR" | rev | cut \-c1-16 | rev)  
          ENCRYPTED\_REV\_CERT=$(find. \-name "${PRIMARY\_FPR}\-subkey-${SUBKEY\_SHORT\_ID}\-\*.gpg.gpg" \-print \-quit)

          if &&; then  
            log\_msg "Decrypting revocation for $SUBKEY\_TYPE\_NAME subkey..."  
            echo "$GPG\_PASSPHRASE" | gpg \--batch \--pinentry-mode loopback \--passphrase-fd 0 \\  
              \--output "$SUBKEY\_REV\_CERT\_PATH" \--decrypt "$ENCRYPTED\_REV\_CERT" 2\>gpg\_stderr.log  
            if \[ $? \-ne 0 \] ||; then  
              log\_err "Failed to decrypt $SUBKEY\_TYPE\_NAME subkey revocation certificate."  
              log\_err "GPG Stderr: $(cat../gpg\_stderr.log)" \# stderr from main script dir  
              rm \-f "$SUBKEY\_REV\_CERT\_PATH" \# Clean up partial file  
            else  
              chmod 400 "$SUBKEY\_REV\_CERT\_PATH"  
              log\_msg "$SUBKEY\_TYPE\_NAME subkey revocation certificate generated: $SUBKEY\_REV\_CERT\_PATH"  
            fi  
          else  
            log\_err "Could not find encrypted revocation certificate from gen-revoke for $SUBKEY\_TYPE\_NAME subkey ($CURRENT\_SUBKEY\_FPR)."  
          fi  
          cd.. \# Back to original directory  
        )  
        rm \-rf "$GEN\_REVOKE\_TMP\_DIR"  
      else  
        log\_msg "$SUBKEY\_TYPE\_NAME subkey revocation certificate already exists: $SUBKEY\_REV\_CERT\_PATH"  
      fi  
    else  
      log\_msg "Skipping revocation for $SUBKEY\_TYPE\_NAME subkey as its FPR is not set."  
    fi  
  done  
else  
  log\_warn "gen-revoke.bash not found. Skipping individual subkey revocation certificate generation."  
  log\_warn "To generate individual subkey revocation certificates, install gen-revoke from https://github.com/projg2/gen-revoke"  
fi

log\_msg "GPG key lifecycle management script finished."  
log\_msg "Artifacts are in: $EXPORT\_DIR"  
log\_msg "Temporary GNUPGHOME was: $GNUPGHOME\_TMP (now deleted if script exits cleanly)"  
\# Cleanup trap will handle deleting GNUPGHOME\_TMP

**Note on Bash Script:** The gen-revoke part is complex to fully automate due to its expect dependency and passphrase handling. A more robust solution might involve modifying gen-revoke or using an expect script to drive it if passphrases cannot be agent-handled. The above is a conceptual illustration. The check\_subkey\_cap function is simplified; robust parsing of GPG's colon output for exclusive capabilities is more involved.

### **7.2. Python Script Outline (Illustrating PGPy for Key Tasks)**

This script would use the PGPy library for native Python GPG operations.

Python

import pgpy  
from pgpy.constants import PubKeyAlgorithm, KeyFlags, HashAlgorithm, SymmetricKeyAlgorithm, CompressionAlgorithm, SignatureType, RevocationReason  
import os  
import datetime  
import shutil

\# \--- Configuration (from environment variables) \---  
GPG\_USER\_NAME \= os.environ.get("GPG\_USER\_NAME", "Automated Key User")  
GPG\_USER\_EMAIL \= os.environ.get("GPG\_USER\_EMAIL", "automation@example.com")  
GPG\_USER\_COMMENT \= os.environ.get("GPG\_USER\_COMMENT", "Automated GPG Key")  
GPG\_PASSPHRASE \= os.environ.get("GPG\_PASSPHRASE") \# Must be set  
GPG\_PRIMARY\_ALGO \= PubKeyAlgorithm.RSAEncryptOrSign  
GPG\_PRIMARY\_KEY\_LENGTH \= int(os.environ.get("GPG\_PRIMARY\_KEY\_LENGTH", 4096))  
GPG\_SUBKEY\_ALGO \= PubKeyAlgorithm.RSAEncryptOrSign  
GPG\_SUBKEY\_LENGTH \= int(os.environ.get("GPG\_SUBKEY\_LENGTH", 4096))  
GPG\_MASTER\_EXPIRY\_YEARS \= int(os.environ.get("GPG\_MASTER\_EXPIRY\_YEARS", 0)) \# 0 for no expiry  
GPG\_SUBKEY\_EXPIRY\_DAYS \= int(os.environ.get("GPG\_SUBKEY\_EXPIRY\_DAYS", 365)) \# 1 year

EXPORT\_DIR \= "./gpg\_artifacts\_pgpy"  
PRIMARY\_KEY\_PATH \= os.path.join(EXPORT\_DIR, f"{GPG\_USER\_EMAIL}\_primary\_key.asc")  
PRIMARY\_PUBKEY\_PATH \= os.path.join(EXPORT\_DIR, f"{GPG\_USER\_EMAIL}\_primary\_pubkey.asc")

def log\_msg(message): print(f"\[INFO\] {message}")  
def log\_err(message): print(f" {message}", file=sys.stderr)

def main():  
    if not GPG\_PASSPHRASE:  
        log\_err("GPG\_PASSPHRASE environment variable not set.")  
        return

    os.makedirs(EXPORT\_DIR, exist\_ok=True)  
      
    primary\_key \= None

    \# \--- Idempotency Check: Load existing primary key if present \---  
    if os.path.exists(PRIMARY\_KEY\_PATH):  
        try:  
            log\_msg(f"Attempting to load existing primary key from: {PRIMARY\_KEY\_PATH}")  
            primary\_key, \_ \= pgpy.PGPKey.from\_file(PRIMARY\_KEY\_PATH)  
            with primary\_key.unlock(GPG\_PASSPHRASE):  
                \# Verify UID  
                found\_uid \= False  
                for uid\_obj in primary\_key.userids:  
                    if uid\_obj.email \== GPG\_USER\_EMAIL and uid\_obj.name \== GPG\_USER\_NAME:  
                        found\_uid \= True  
                        log\_msg(f"Existing primary key with matching UID found: {primary\_key.fingerprint}")  
                        break  
                if not found\_uid:  
                    log\_msg("Existing key file found, but UID does not match. Will create new key.")  
                    primary\_key \= None \# Force recreation  
        except Exception as e:  
            log\_err(f"Failed to load or unlock existing primary key: {e}. Will create new key.")  
            primary\_key \= None

    \# \--- 1\. Generate Primary Key (if not found or invalid) \---  
    if not primary\_key:  
        log\_msg("Generating new primary key...")  
        primary\_key \= pgpy.PGPKey.new(GPG\_PRIMARY\_ALGO, GPG\_PRIMARY\_KEY\_LENGTH)  
        uid \= pgpy.PGPUID.new(GPG\_USER\_NAME, comment=GPG\_USER\_COMMENT, email=GPG\_USER\_EMAIL)  
          
        key\_creation\_time \= datetime.datetime.now(datetime.timezone.utc)  
        key\_expiration\_date \= None  
        if GPG\_MASTER\_EXPIRY\_YEARS \> 0:  
            key\_expiration\_date \= key\_creation\_time \+ datetime.timedelta(days=GPG\_MASTER\_EXPIRY\_YEARS \* 365)

        primary\_key.add\_uid(  
            uid,  
            usage={KeyFlags.Certify}, \# Primary key for certification  
            hashes=,  
            ciphers=,  
            compression=,  
            key\_flags=\[KeyFlags.Certify\], \# Explicitly stating primary key capability  
            key\_expiration=key\_expiration\_date,  
            created=key\_creation\_time  
        )  
        primary\_key.protect(GPG\_PASSPHRASE, SymmetricKeyAlgorithm.AES256, HashAlgorithm.SHA256)  
          
        with open(PRIMARY\_KEY\_PATH, "w") as f:  
            f.write(str(primary\_key))  
        os.chmod(PRIMARY\_KEY\_PATH, 0o400) \# Read-only for owner  
        with open(PRIMARY\_PUBKEY\_PATH, "w") as f:  
            f.write(str(primary\_key.pubkey))  
        os.chmod(PRIMARY\_PUBKEY\_PATH, 0o644)  
        log\_msg(f"New primary key generated and saved. FPR: {primary\_key.fingerprint}")

    with primary\_key.unlock(GPG\_PASSPHRASE):  
        \# \--- 2\. Add Subkeys (Sign, Encrypt, Auth) with Idempotency \---  
        subkey\_specs \=

        needs\_save \= False  
        for cap\_name, key\_flags\_set, desc\_name in subkey\_specs:  
            found\_subkey \= False  
            for sk\_id, sk\_obj in primary\_key.subkeys.items():  
                if sk\_obj.key\_flags \== key\_flags\_set: \# Simple check, could be more robust (algo, length)  
                    log\_msg(f"Existing {desc\_name} subkey found: {sk\_obj.fingerprint}")  
                    found\_subkey \= True  
                    \# Store fingerprint for revocation if needed later  
                    os.environ \= str(sk\_obj.fingerprint)  
                    break  
              
            if not found\_subkey:  
                log\_msg(f"Generating {desc\_name} subkey...")  
                new\_subkey \= pgpy.PGPKey.new(GPG\_SUBKEY\_ALGO, GPG\_SUBKEY\_LENGTH)  
                subkey\_creation\_time \= datetime.datetime.now(datetime.timezone.utc)  
                subkey\_expiration\_date \= subkey\_creation\_time \+ datetime.timedelta(days=GPG\_SUBKEY\_EXPIRY\_DAYS)  
                primary\_key.add\_subkey(  
                    new\_subkey,   
                    usage=key\_flags\_set,  
                    key\_expiration=subkey\_expiration\_date,  
                    created=subkey\_creation\_time  
                )  
                needs\_save \= True  
                log\_msg(f"{desc\_name.capitalize()} subkey added: {new\_subkey.fingerprint}")  
                os.environ \= str(new\_subkey.fingerprint)

        if needs\_save:  
            log\_msg("Saving primary key with new subkeys...")  
            with open(PRIMARY\_KEY\_PATH, "w") as f:  
                f.write(str(primary\_key)) \# This saves the primary key with all its components

        \# \--- 3\. Generate Revocation Certificates \---  
        \# Primary Key Revocation  
        primary\_rev\_cert\_path \= os.path.join(EXPORT\_DIR, f"{primary\_key.fingerprint}\_primary\_rev.asc")  
        if not os.path.exists(primary\_rev\_cert\_path):  
            log\_msg("Generating primary key revocation certificate...")  
            primary\_rev\_sig \= primary\_key.revoke(  
                reason=RevocationReason.NoReason,   
                comment="Revocation certificate for primary key"  
            )  
            with open(primary\_rev\_cert\_path, "w") as f:  
                f.write(str(primary\_rev\_sig))  
            os.chmod(primary\_rev\_cert\_path, 0o400)  
            log\_msg(f"Primary key revocation certificate saved to {primary\_rev\_cert\_path}")  
        else:  
            log\_msg(f"Primary key revocation certificate already exists: {primary\_rev\_cert\_path}")

        \# Subkey Revocation Certificates  
        for sk\_id, sk\_obj in primary\_key.subkeys.items():  
            subkey\_fpr \= str(sk\_obj.fingerprint)  
            \# Determine a descriptive name based on flags for filename  
            subkey\_desc \= "subkey"  
            if sk\_obj.key\_flags \== {KeyFlags.Sign}: subkey\_desc \= "signing\_subkey"  
            elif sk\_obj.key\_flags \== {KeyFlags.EncryptCommunications}: subkey\_desc \= "encryption\_subkey"  
            elif sk\_obj.key\_flags \== {KeyFlags.Authentication}: subkey\_desc \= "authentication\_subkey"

            subkey\_rev\_cert\_path \= os.path.join(EXPORT\_DIR, f"{subkey\_fpr}\_{subkey\_desc}\_rev.asc")  
            if not os.path.exists(subkey\_rev\_cert\_path):  
                log\_msg(f"Generating revocation certificate for subkey {subkey\_fpr} ({subkey\_desc})...")  
                try:  
                    \# Ensure the subkey object itself is used for revocation targeting  
                    subkey\_rev\_sig \= primary\_key.revoke(  
                        target=sk\_obj, \# Target the subkey object directly  
                        sigtype=SignatureType.SubkeyRevocation,   
                        reason=RevocationReason.NoReason,  
                        comment=f"Revocation certificate for {subkey\_desc} {subkey\_fpr}"  
                    )  
                    with open(subkey\_rev\_cert\_path, "w") as f:  
                        f.write(str(subkey\_rev\_sig))  
                    os.chmod(subkey\_rev\_cert\_path, 0o400)  
                    log\_msg(f"Subkey {subkey\_fpr} revocation certificate saved to {subkey\_rev\_cert\_path}")  
                except Exception as e:  
                    log\_err(f"Failed to generate revocation for subkey {subkey\_fpr}: {e}")  
            else:  
                log\_msg(f"Subkey {subkey\_fpr} revocation certificate already exists: {subkey\_rev\_cert\_path}")

    log\_msg("PGPy key lifecycle management script finished.")  
    log\_msg(f"Artifacts are in: {EXPORT\_DIR}")

if \_\_name\_\_ \== "\_\_main\_\_":  
    import sys  
    if not os.environ.get("GPG\_PASSPHRASE"):  
        print("Error: GPG\_PASSPHRASE environment variable must be set.", file=sys.stderr)  
        sys.exit(1)  
    main()

**Note on Python (PGPy) Script:** This script provides a more complete conceptual flow for PGPy, including basic idempotency for the primary key and subkey addition based on capabilities. Subkey revocation certificate export is demonstrated. Error handling and more robust idempotency checks (e.g., for expiration dates, algorithms) would be needed for a production system.

## **8\. Conclusion and Final Recommendations**

Automating the GPG key lifecycle, including the generation of master keys, distinct subkeys (Signing, Encryption, Authentication), and their respective revocation certificates, is achievable with careful planning and scripting. The choice of tooling—GPG CLI via Bash, python-gnupg, or PGPy—depends on project requirements, existing infrastructure, and desired level of abstraction.

* **GPG CLI with Bash Scripting:** Offers the most direct control over GnuPG's full feature set. It is universally available where GPG is installed.  
  * **Strengths:** No additional language dependencies (beyond Bash and standard utilities like awk). Full access to all GPG commands and options.  
  * **Challenges:** Requires complex scripting for robust idempotency (parsing \--with-colons output), error handling (parsing \--status-fd messages), and managing the generation of individual subkey revocation certificates (often necessitating a tool like gen-revoke and subsequent decryption).  
* **python-gnupg:** Provides a Pythonic wrapper around the GPG CLI.  
  * **Strengths:** Simplifies many common GPG operations and parsing GPG output compared to raw Bash.  
  * **Challenges:** For advanced features like ensuring distinct subkey capabilities beyond the default encryption subkey via add\_subkey, or generating standalone subkey revocation certificates, it may require passing raw GPG commands, diminishing its abstraction benefits. The documentation on specific usage parameters for add\_subkey to create distinct sign-only or auth-only subkeys is not definitively clear from the reviewed materials.  
* **PGPy:** A pure Python implementation of OpenPGP.  
  * **Strengths:** No dependency on an external GPG executable. Offers an object-oriented model for fine-grained control over key and signature creation, including explicit support for setting distinct KeyFlags for subkeys (Sign, EncryptCommunications, Authentication) and programmatically generating and exporting GPG-compatible revocation certificates for both primary keys and individual subkeys using SignatureType.SubkeyRevocation. This makes it well-suited for the feature-complete requirements of the query.  
  * **Challenges:** May not support the absolute newest or most esoteric GPG features or algorithms as rapidly as the GPG CLI itself. Requires understanding of OpenPGP object structures.

**Recommendations:**

1. **For Feature Completeness and Python Integration:** If a Python-based solution is preferred and the project requires robust generation of distinct subkeys and their individual revocation certificates programmatically, **PGPy is the recommended library.** Its direct API for these advanced operations simplifies development and enhances maintainability for these specific tasks.  
2. **For Maximum Control and GPG CLI Familiarity:** If the environment already heavily utilizes Bash scripting or requires features only accessible via the latest GPG CLI, **a well-structured Bash script** is a viable solution. This approach demands meticulous implementation of idempotency checks (parsing \--with-colons output for UIDs and subkey capabilities) and error handling (parsing \--status-fd messages). The gen-revoke tool (or a similar custom solution) will be necessary for generating individual subkey revocation certificates, followed by decryption if the owner is the recipient.  
3. **Passphrase Security:** Regardless of the chosen tool, passphrases supplied via environment variables must be handled with extreme care. Use the echo "$VAR" | gpg \--pinentry-mode loopback \--passphrase-fd 0... pattern (or its Python equivalent) to avoid exposing passphrases in process listings. Ensure the GNUPGHOME directory (especially if temporary) has strict permissions (chmod 700).  
4. **Avoid Passphrase-less Keys:** The use of %no-protection or empty passphrases for primary or operational subkeys is strongly discouraged due to the severe security risks if the private key files are compromised.  
5. **Secure Storage:** Emphasize the critical importance of securely storing all generated private key material (master and subkeys) and all revocation certificates (primary and subkey) in multiple, secure, offline locations. Revocation certificates should be stored separately from their corresponding private keys.  
6. **Idempotency and Error Handling:** Implement robust idempotency checks for all generated artifacts (keys by UID/fingerprint and subkey capabilities, revocation certificates by file existence). Thoroughly parse GPG status messages and handle exit codes or Python exceptions to ensure script reliability.

By carefully selecting the appropriate tools and adhering to security best practices, a robust and automated GPG key lifecycle management system can be successfully implemented.

#### **Works cited**

1. Subkeys \- Debian Wiki, accessed May 11, 2025, [https://wiki.debian.org/Subkeys](https://wiki.debian.org/Subkeys)  
2. OpenPGP Best Practices \- Riseup.net, accessed May 11, 2025, [https://riseup.net/ru/security/message-security/openpgp/gpg-best-practices](https://riseup.net/ru/security/message-security/openpgp/gpg-best-practices)  
3. PGP and SSH keys on a Yubikey NEO \- Eric Severance, accessed May 11, 2025, [https://esev.com/blog/post/2015-01-pgp-ssh-key-on-yubikey-neo/](https://esev.com/blog/post/2015-01-pgp-ssh-key-on-yubikey-neo/)  
4. Perfectly reasonable security for GPG, SSH and password management using a Yubikey hardware device \- Network Automation ramblings by Kristian Larsson, accessed May 11, 2025, [https://plajjan.github.io/2018-09-15-perfectly-reasonable-security.html](https://plajjan.github.io/2018-09-15-perfectly-reasonable-security.html)  
5. Unattended GPG key generation (Using the GNU Privacy Guard), accessed May 11, 2025, [https://www.gnupg.org/documentation/manuals/gnupg/Unattended-GPG-key-generation.html](https://www.gnupg.org/documentation/manuals/gnupg/Unattended-GPG-key-generation.html)  
6. Using the GNU Privacy Guard: Unattended GPG key generation, accessed May 11, 2025, [https://gnupg.org/documentation/manuals/gnupg-2.0/Unattended-GPG-key-generation.html](https://gnupg.org/documentation/manuals/gnupg-2.0/Unattended-GPG-key-generation.html)  
7. Creating gpg keys non-interactively \- gists · GitHub, accessed May 11, 2025, [https://gist.github.com/woods/8970150](https://gist.github.com/woods/8970150)  
8. GPG unattended ECC key and subkey generation \- Information Security Stack Exchange, accessed May 11, 2025, [https://security.stackexchange.com/questions/213709/gpg-unattended-ecc-key-and-subkey-generation](https://security.stackexchange.com/questions/213709/gpg-unattended-ecc-key-and-subkey-generation)  
9. T4514 Batch mode/unattended key generation: support multiple subkeys \- GnuPG, accessed May 11, 2025, [https://dev.gnupg.org/T4514](https://dev.gnupg.org/T4514)  
10. How to add all input required information in one single gpg command line?, accessed May 11, 2025, [https://security.stackexchange.com/questions/133405/how-to-add-all-input-required-information-in-one-single-gpg-command-line](https://security.stackexchange.com/questions/133405/how-to-add-all-input-required-information-in-one-single-gpg-command-line)  
11. GPG(1), accessed May 11, 2025, [https://www.gnupg.org/documentation/manuals/gnupg26/gpg.1.html](https://www.gnupg.org/documentation/manuals/gnupg26/gpg.1.html)  
12. GNUPG \- Creating a subkey in a single command \- Super User, accessed May 11, 2025, [https://superuser.com/questions/1300653/gnupg-creating-a-subkey-in-a-single-command](https://superuser.com/questions/1300653/gnupg-creating-a-subkey-in-a-single-command)  
13. OpenPGP Key Management (Using the GNU Privacy Guard), accessed May 11, 2025, [https://www.gnupg.org/documentation/manuals/gnupg/OpenPGP-Key-Management.html](https://www.gnupg.org/documentation/manuals/gnupg/OpenPGP-Key-Management.html)  
14. Usage of GPG keys \- Serverspace.io, accessed May 11, 2025, [https://serverspace.io/support/help/usage-of-gpg-keys/](https://serverspace.io/support/help/usage-of-gpg-keys/)  
15. OpenPGP Key Management (Using the GNU Privacy Guard), accessed May 11, 2025, [https://www.gnupg.org/(fr)/documentation/manuals/gnupg/OpenPGP-Key-Management.html](https://www.gnupg.org/\(fr\)/documentation/manuals/gnupg/OpenPGP-Key-Management.html)  
16. Why can't I run gpg in non-interactive mode successfully? \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/35123114/why-cant-i-run-gpg-in-non-interactive-mode-successfully](https://stackoverflow.com/questions/35123114/why-cant-i-run-gpg-in-non-interactive-mode-successfully)  
17. Generating More Secure GPG Keys: A Step-by-Step Guide \- Atomic Spin, accessed May 11, 2025, [https://spin.atomicobject.com/secure-gpg-keys-guide/](https://spin.atomicobject.com/secure-gpg-keys-guide/)  
18. GPG Keys \- Purism user documentation, accessed May 11, 2025, [https://docs.puri.sm/Hardware/Librem\_Key/GPG.html](https://docs.puri.sm/Hardware/Librem_Key/GPG.html)  
19. Creating a revocation key \- Security \- Institute for Advanced Study, accessed May 11, 2025, [https://www.ias.edu/security/creating-revocation-key](https://www.ias.edu/security/creating-revocation-key)  
20. How the correct way to revoke GPG on key server? \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/59664526/how-the-correct-way-to-revoke-gpg-on-key-server](https://stackoverflow.com/questions/59664526/how-the-correct-way-to-revoke-gpg-on-key-server)  
21. Using the GNU Privacy Guard: OpenPGP Key Management, accessed May 11, 2025, [https://gnupg.org/documentation/manuals/gnupg-2.0/OpenPGP-Key-Management.html](https://gnupg.org/documentation/manuals/gnupg-2.0/OpenPGP-Key-Management.html)  
22. gen-revoke: extending revocation certificates to subkeys – Michał Górny, accessed May 11, 2025, [https://blogs.gentoo.org/mgorny/2019/02/20/gen-revoke-extending-revocation-certificates-to-subkeys/](https://blogs.gentoo.org/mgorny/2019/02/20/gen-revoke-extending-revocation-certificates-to-subkeys/)  
23. projg2/gen-revoke: Generate revocation signatures for OpenPGP key and subkeys, for multiple recipients \- GitHub, accessed May 11, 2025, [https://github.com/projg2/gen-revoke](https://github.com/projg2/gen-revoke)  
24. EF Core 9.0: Breaking Change in Migration Idempotent Scripts \- Jaliya's Blog, accessed May 11, 2025, [https://jaliyaudagedara.blogspot.com/2025/01/ef-core-90-breaking-change-in-migration.html](https://jaliyaudagedara.blogspot.com/2025/01/ef-core-90-breaking-change-in-migration.html)  
25. Creating Idempotent DDL Scripts for Database Migrations \- Redgate Software, accessed May 11, 2025, [https://www.red-gate.com/hub/product-learning/flyway/creating-idempotent-ddl-scripts-for-database-migrations](https://www.red-gate.com/hub/product-learning/flyway/creating-idempotent-ddl-scripts-for-database-migrations)  
26. Generate fingerprint with PGP Public Key \- Server Fault, accessed May 11, 2025, [https://serverfault.com/questions/1059871/generate-fingerprint-with-pgp-public-key](https://serverfault.com/questions/1059871/generate-fingerprint-with-pgp-public-key)  
27. How to display gpg key details without importing it? \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/22136029/how-to-display-gpg-key-details-without-importing-it](https://stackoverflow.com/questions/22136029/how-to-display-gpg-key-details-without-importing-it)  
28. gpg \- OpenPGP encryption and signing tool \- Ubuntu Manpage, accessed May 11, 2025, [https://manpages.ubuntu.com/manpages/oracular/man1/gpg.1.html](https://manpages.ubuntu.com/manpages/oracular/man1/gpg.1.html)  
29. gnupg/doc/DETAILS at master \- GitHub, accessed May 11, 2025, [https://github.com/CSNW/gnupg/blob/master/doc/DETAILS](https://github.com/CSNW/gnupg/blob/master/doc/DETAILS)  
30. how to interpret outpuf of gpg \--list-keys \--with-colons \--with-fingerprint \--with-fingerprint, accessed May 11, 2025, [https://unix.stackexchange.com/questions/667463/how-to-interpret-outpuf-of-gpg-list-keys-with-colons-with-fingerprint-wi](https://unix.stackexchange.com/questions/667463/how-to-interpret-outpuf-of-gpg-list-keys-with-colons-with-fingerprint-wi)  
31. Parsing the GnuPG secret key list \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/45362488/parsing-the-gnupg-secret-key-list](https://stackoverflow.com/questions/45362488/parsing-the-gnupg-secret-key-list)  
32. Pass password to GPG via script \- Information Security Stack Exchange, accessed May 11, 2025, [https://security.stackexchange.com/questions/177941/pass-password-to-gpg-via-script](https://security.stackexchange.com/questions/177941/pass-password-to-gpg-via-script)  
33. gpg asks for password even with \--passphrase \- Unix & Linux Stack Exchange, accessed May 11, 2025, [https://unix.stackexchange.com/questions/60213/gpg-asks-for-password-even-with-passphrase](https://unix.stackexchange.com/questions/60213/gpg-asks-for-password-even-with-passphrase)  
34. Security of bash script involving gpg symmetric encryption \- Unix & Linux Stack Exchange, accessed May 11, 2025, [https://unix.stackexchange.com/questions/469518/security-of-bash-script-involving-gpg-symmetric-encryption](https://unix.stackexchange.com/questions/469518/security-of-bash-script-involving-gpg-symmetric-encryption)  
35. GNUPG \- stdin encrypted file and passphrase on windows \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/13021070/gnupg-stdin-encrypted-file-and-passphrase-on-windows](https://stackoverflow.com/questions/13021070/gnupg-stdin-encrypted-file-and-passphrase-on-windows)  
36. GnuPG, Prompt for passphrase from bash script \- Unix & Linux Stack Exchange, accessed May 11, 2025, [https://unix.stackexchange.com/questions/638056/gnupg-prompt-for-passphrase-from-bash-script](https://unix.stackexchange.com/questions/638056/gnupg-prompt-for-passphrase-from-bash-script)  
37. Automating Passphrase in a Bash Script (steghide, gpg, etc.) \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/25331218/automating-passphrase-in-a-bash-script-steghide-gpg-etc](https://stackoverflow.com/questions/25331218/automating-passphrase-in-a-bash-script-steghide-gpg-etc)  
38. python-gnupg \- Read the Docs, accessed May 11, 2025, [https://gnupg.readthedocs.io/](https://gnupg.readthedocs.io/)  
39. gpg: signing failed: Inappropriate ioctl for device · Issue \#2798 \- GitHub, accessed May 11, 2025, [https://github.com/keybase/keybase-issues/issues/2798](https://github.com/keybase/keybase-issues/issues/2798)  
40. gpg decryption fails with no secret key error \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/28321712/gpg-decryption-fails-with-no-secret-key-error](https://stackoverflow.com/questions/28321712/gpg-decryption-fails-with-no-secret-key-error)  
41. gpg-preset-passphrase: caching passphrase failed: Not supported \- Super User, accessed May 11, 2025, [https://superuser.com/questions/1539189/gpg-preset-passphrase-caching-passphrase-failed-not-supported](https://superuser.com/questions/1539189/gpg-preset-passphrase-caching-passphrase-failed-not-supported)  
42. gpg remove passphrase \- gnupg \- Super User, accessed May 11, 2025, [https://superuser.com/questions/1360324/gpg-remove-passphrase](https://superuser.com/questions/1360324/gpg-remove-passphrase)  
43. How safe is GPG password protection for private keys? : r/privacy \- Reddit, accessed May 11, 2025, [https://www.reddit.com/r/privacy/comments/4cbmwx/how\_safe\_is\_gpg\_password\_protection\_for\_private/](https://www.reddit.com/r/privacy/comments/4cbmwx/how_safe_is_gpg_password_protection_for_private/)  
44. What are the risks of creating a gnupg private key with no passphrase? \- Super User, accessed May 11, 2025, [https://superuser.com/questions/888945/what-are-the-risks-of-creating-a-gnupg-private-key-with-no-passphrase](https://superuser.com/questions/888945/what-are-the-risks-of-creating-a-gnupg-private-key-with-no-passphrase)  
45. python-gnupg/pretty\_bad\_protocol/gnupg.py at master · isislovecruft/python-gnupg \- GitHub, accessed May 11, 2025, [https://github.com/isislovecruft/python-gnupg/blob/master/pretty\_bad\_protocol/gnupg.py](https://github.com/isislovecruft/python-gnupg/blob/master/pretty_bad_protocol/gnupg.py)  
46. Python Wrapper for GnuPG 0.3.6 documentation, accessed May 11, 2025, [https://gnupg.readthedocs.io/en/0.3.6/](https://gnupg.readthedocs.io/en/0.3.6/)  
47. working example of using gnupg in python \- gists · GitHub, accessed May 11, 2025, [https://gist.github.com/ryantuck/56c5aaa8f9124422ac964629f4c8deb0?permalink\_comment\_id=3997948](https://gist.github.com/ryantuck/56c5aaa8f9124422ac964629f4c8deb0?permalink_comment_id=3997948)  
48. gnupg package — gnupg 2.3.0 documentation \- PythonHosted.org, accessed May 11, 2025, [https://pythonhosted.org/gnupg/gnupg.html](https://pythonhosted.org/gnupg/gnupg.html)  
49. Python Wrapper for GnuPG 0.5.0 documentation, accessed May 11, 2025, [https://gnupg.readthedocs.io/en/0.5.0/](https://gnupg.readthedocs.io/en/0.5.0/)  
50. How to generate the revocation certificate after being made a revoker with GnuPG, accessed May 11, 2025, [https://superuser.com/questions/882217/how-to-generate-the-revocation-certificate-after-being-made-a-revoker-with-gnupg](https://superuser.com/questions/882217/how-to-generate-the-revocation-certificate-after-being-made-a-revoker-with-gnupg)  
51. Do I need to revoke both my OpenPGP primary key and subkey?, accessed May 11, 2025, [https://security.stackexchange.com/questions/94165/do-i-need-to-revoke-both-my-openpgp-primary-key-and-subkey](https://security.stackexchange.com/questions/94165/do-i-need-to-revoke-both-my-openpgp-primary-key-and-subkey)  
52. Python GNUPG Unknown system error when loading private key \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/77641923/python-gnupg-unknown-system-error-when-loading-private-key](https://stackoverflow.com/questions/77641923/python-gnupg-unknown-system-error-when-loading-private-key)  
53. How to actually revoke a GitHub GPG key? · community · Discussion \#108355, accessed May 11, 2025, [https://github.com/orgs/community/discussions/108355](https://github.com/orgs/community/discussions/108355)  
54. Refactor general stuff to django-mailman3, to allow apps to hook up together in Mailman Suite easily, and then use that to hook up django-pgpmailman. \- neuromancer.sk, accessed May 11, 2025, [https://neuromancer.sk/articles/3](https://neuromancer.sk/articles/3)  
55. Examples — PGPy 0.6.0 documentation, accessed May 11, 2025, [https://pgpy.readthedocs.io/en/latest/examples.html](https://pgpy.readthedocs.io/en/latest/examples.html)  
56. PGP vs GPG: The Key Differences Explained \- jscape, accessed May 11, 2025, [https://www.jscape.com/blog/pgp-vs-gpg-the-key-differences-explained](https://www.jscape.com/blog/pgp-vs-gpg-the-key-differences-explained)  
57. PGP vs. GPG: Key Differences in Encryption | GoAnywhere MFT, accessed May 11, 2025, [https://www.goanywhere.com/blog/pgp-vs-gpg-whats-the-difference](https://www.goanywhere.com/blog/pgp-vs-gpg-whats-the-difference)  
58. PGPy v0.3.0 Released \- Security Innovation Blog, accessed May 11, 2025, [https://blog.securityinnovation.com/blog/2014/12/pgpy-030-released.html](https://blog.securityinnovation.com/blog/2014/12/pgpy-030-released.html)  
59. PGPy/docs/source/examples/keys.rst at master \- GitHub, accessed May 11, 2025, [https://github.com/SecurityInnovation/PGPy/blob/master/docs/source/examples/keys.rst](https://github.com/SecurityInnovation/PGPy/blob/master/docs/source/examples/keys.rst)  
60. pgpy key.decrypt is not returning decrypted text \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/68661279/pgpy-key-decrypt-is-not-returning-decrypted-text](https://stackoverflow.com/questions/68661279/pgpy-key-decrypt-is-not-returning-decrypted-text)  
61. How to Encrpyt message using PGPY in Python3 \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/62099669/how-to-encrpyt-message-using-pgpy-in-python3](https://stackoverflow.com/questions/62099669/how-to-encrpyt-message-using-pgpy-in-python3)  
62. PGPy API — PGPy 0.6.0 documentation, accessed May 11, 2025, [https://pgpy.readthedocs.io/en/latest/api.html](https://pgpy.readthedocs.io/en/latest/api.html)  
63. monkeysphere/openpgp2ssh.py · master \- monkeypy \- 0xacab, accessed May 11, 2025, [https://0xacab.org/monkeysphere/monkeypy/-/blob/master/monkeysphere/openpgp2ssh.py?ref\_type=heads](https://0xacab.org/monkeysphere/monkeypy/-/blob/master/monkeysphere/openpgp2ssh.py?ref_type=heads)  
64. OpenPGP interoperability test suite \- GitLab, accessed May 11, 2025, [https://sequoia-pgp.gitlab.io/openpgp-interoperability-test-suite/](https://sequoia-pgp.gitlab.io/openpgp-interoperability-test-suite/)  
65. Key Revocation Certificates \- PGP, accessed May 11, 2025, [https://www.sindark.com/genre/PGP/Revocation.pdf](https://www.sindark.com/genre/PGP/Revocation.pdf)  
66. Issues importing GPG private key and decrypting message \- Super User, accessed May 11, 2025, [https://superuser.com/questions/1896948/issues-importing-gpg-private-key-and-decrypting-message](https://superuser.com/questions/1896948/issues-importing-gpg-private-key-and-decrypting-message)  
67. PGPy/pgpy/pgp.py at master · SecurityInnovation/PGPy \- GitHub, accessed May 11, 2025, [https://github.com/SecurityInnovation/PGPy/blob/master/pgpy/pgp.py](https://github.com/SecurityInnovation/PGPy/blob/master/pgpy/pgp.py)  
68. How to generate a revocation certificate for my OpenPGP key pair/Personal key?, accessed May 11, 2025, [https://kb.mailfence.com/kb/how-to-generate-a-revocation-certificate-for-my-openpgp-key-pair-personal-key/](https://kb.mailfence.com/kb/how-to-generate-a-revocation-certificate-for-my-openpgp-key-pair-personal-key/)  
69. How to Generate Your Own Public and Secret Keys for PGP Encryption \- DEV Community, accessed May 11, 2025, [https://dev.to/adityabhuyan/how-to-generate-your-own-public-and-secret-keys-for-pgp-encryption-1joh](https://dev.to/adityabhuyan/how-to-generate-your-own-public-and-secret-keys-for-pgp-encryption-1joh)  
70. Revoking a subkey \- Security | Institute for Advanced Study, accessed May 11, 2025, [https://www.ias.edu/security/revoking-subkey](https://www.ias.edu/security/revoking-subkey)  
71. How to decrypt pgp armored string using PGPy when the armored string isn't from PGPy?, accessed May 11, 2025, [https://stackoverflow.com/questions/72744900/how-to-decrypt-pgp-armored-string-using-pgpy-when-the-armored-string-isnt-from](https://stackoverflow.com/questions/72744900/how-to-decrypt-pgp-armored-string-using-pgpy-when-the-armored-string-isnt-from)  
72. PGPKey.encrypt should raise a more informative exception when is\_protected is True but is\_unlocked is False · Issue \#204 · SecurityInnovation/PGPy \- GitHub, accessed May 11, 2025, [https://github.com/SecurityInnovation/PGPy/issues/204](https://github.com/SecurityInnovation/PGPy/issues/204)  
73. Subkey in PGP Encryption \- MuleSoft Cryto Connector \- Mulesy, accessed May 11, 2025, [https://mulesy.com/subkey-in-pgp-encryption/](https://mulesy.com/subkey-in-pgp-encryption/)  
74. Inspecting a pgp key in C\# and VB.NET \- PGP examples with .NET \- DidiSoft, accessed May 11, 2025, [https://didisoft.com/net-openpgp/examples/working-with-a-key/](https://didisoft.com/net-openpgp/examples/working-with-a-key/)  
75. example of using PGPy for creating and verifying digital signatures \- GitHub Gist, accessed May 11, 2025, [https://gist.github.com/williballenthin/89913cf450e2055b6ecca768cb79a90a](https://gist.github.com/williballenthin/89913cf450e2055b6ecca768cb79a90a)  
76. openpgp D. K. Gillmor Internet-Draft ACLU Intended status: Informational 8 May 2025 Expires \- IETF Datatracker, accessed May 11, 2025, [https://datatracker.ietf.org/meeting/112/agenda/openpgp-drafts.pdf](https://datatracker.ietf.org/meeting/112/agenda/openpgp-drafts.pdf)  
77. 10 Scripting Best Practices for Automation Engineers \- Eyer.ai, accessed May 11, 2025, [https://www.eyer.ai/blog/10-scripting-best-practices-for-automation-engineers/](https://www.eyer.ai/blog/10-scripting-best-practices-for-automation-engineers/)  
78. GPG Esoteric Options (Using the GNU Privacy Guard), accessed May 11, 2025, [https://www.gnupg.org/documentation/manuals/gnupg/GPG-Esoteric-Options.html](https://www.gnupg.org/documentation/manuals/gnupg/GPG-Esoteric-Options.html)  
79. gnupg/doc/DETAILS at master · gpg/gnupg \- GitHub, accessed May 11, 2025, [https://github.com/gpg/gnupg/blob/master/doc/DETAILS](https://github.com/gpg/gnupg/blob/master/doc/DETAILS)  
80. How to use gpg command-line to check passphrase is correct \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/11381123/how-to-use-gpg-command-line-to-check-passphrase-is-correct](https://stackoverflow.com/questions/11381123/how-to-use-gpg-command-line-to-check-passphrase-is-correct)  
81. using \--status-fd, accessed May 11, 2025, [https://gnupg-users.gnupg.narkive.com/Ekq1Un3w/using-status-fd](https://gnupg-users.gnupg.narkive.com/Ekq1Un3w/using-status-fd)  
82. why is gpg subkey getting a warning \- Information Security Stack Exchange, accessed May 11, 2025, [https://security.stackexchange.com/questions/261574/why-is-gpg-subkey-getting-a-warning](https://security.stackexchange.com/questions/261574/why-is-gpg-subkey-getting-a-warning)  
83. gnupg \- GPG encryption failed \- Unusable public key \- Information Security Stack Exchange, accessed May 11, 2025, [https://security.stackexchange.com/questions/219326/gpg-encryption-failed-unusable-public-key](https://security.stackexchange.com/questions/219326/gpg-encryption-failed-unusable-public-key)  
84. Message signed by revoked subkey still shown as valid · Issue \#2346 \- GitHub, accessed May 11, 2025, [https://github.com/keybase/keybase-issues/issues/2346](https://github.com/keybase/keybase-issues/issues/2346)  
85. GnuPG often asks for subkey passphrase when signing/encrypting messages even with large \[default|max\]-cache-ttl in gpg-agent.conf \- Unix & Linux Stack Exchange, accessed May 11, 2025, [https://unix.stackexchange.com/questions/779021/gnupg-often-asks-for-subkey-passphrase-when-signing-encrypting-messages-even-wit](https://unix.stackexchange.com/questions/779021/gnupg-often-asks-for-subkey-passphrase-when-signing-encrypting-messages-even-wit)  
86. Encrypt file using PGP in python throws error, PGPError: Key 169ADF2575FB does not have the required usage flag EncryptStorage, EncryptCommunications \- Stack Overflow, accessed May 11, 2025, [https://stackoverflow.com/questions/74054610/encrypt-file-using-pgp-in-python-throws-error-pgperror-key-169adf2575fb-does-n](https://stackoverflow.com/questions/74054610/encrypt-file-using-pgp-in-python-throws-error-pgperror-key-169adf2575fb-does-n)  
87. GPG key generation: Not enough random bytes available \- Linux Audit, accessed May 11, 2025, [https://linux-audit.com/gpg-key-generation-not-enough-random-bytes-available/](https://linux-audit.com/gpg-key-generation-not-enough-random-bytes-available/)  
88. Bug \#706011 “gpg \--key-gen doesn't have enough entropy and rng-t...” : Bugs : gnupg package : Ubuntu \- Launchpad Bugs, accessed May 11, 2025, [https://bugs.launchpad.net/bugs/706011](https://bugs.launchpad.net/bugs/706011)  
89. \[GPG Security Best Practice\] \#gpg \#security \#encryption \- GitHub Gist, accessed May 11, 2025, [https://gist.github.com/Integralist/f7e17034800b65b51eb7e9807720025a](https://gist.github.com/Integralist/f7e17034800b65b51eb7e9807720025a)