# Security Policy

**XOR Cipher has two modes.**

**Cipher** is an educational repeating-key XOR and writes `.xor`. The rest of this file describes Cipher. **Pass** is XOR Pass and writes `.xorpass`: Argon2id, an HMAC-SHA256 counter keystream, and an HMAC-SHA256 tag. Pass is documented in [SECURITY-xorpass.md](SECURITY-xorpass.md). Pass is a personal file cipher and has not been audited.

**Cipher mode is an educational tool, not a security product.**

It implements a repeating-key [XOR cipher](https://en.wikipedia.org/wiki/XOR_cipher) and packages results in a custom `.xor` (XOF1) container. That is useful for learning, demos, and light obfuscation of non-sensitive data. **It must not be used to protect real secrets, personal data, credentials, financial records, or anything whose exposure would cause harm.**

For real protection on a Mac, use something designed for it: **FileVault**, **encrypted disk images**, **age**, **GPG**, or a mature archive tool with modern cryptography (e.g. AES-GCM + a proper password KDF).

This project has **not** been independently audited. There is no bug bounty.

---

## What this app does

| Capability | Notes |
|------------|--------|
| Repeating-key XOR | Text (UTF-8), hex, or binary key file, applied to every byte |
| Wrap output in `.xor` (XOF1) | Header stores method, optional key, sizes, CRC-32, original name |
| Folders | Packed with `ditto` ZIP, then XOR-transformed |
| Optional name scrambling | XOR then hex-encode path components |
| Auto-decrypt on open | Convenience only — not an access-control mechanism |

**Store key** (default) writes the key in the clear. Anyone with the `.xor` file can read it and decrypt.

**Don't store** omits the key. Decrypt needs the same key. The payload is still repeating-key XOR, so a short key remains breakable from the ciphertext alone.

**Encrypt key** XOR-wraps the stored key with a wrap passphrase that is never written to the file. That only hides the header key. It is the same XOR cipher, not AES, and it does not stop attacks on a short repeating payload key.

---

## What it is *not*

- **Not confidential encryption.** A short repeating XOR key is breakable with frequency analysis, known-plaintext (crib dragging), and period-finding. Many-time-pad reuse of the same keystream is a classic failure.
- **Not a one-time pad.** A one-time pad requires a truly random key as long as the message, never reused, and kept secret. This app repeats a short key and stores it in the header.
- **Not authenticated encryption.** CRC-32 detects accidental corruption; it does **not** stop a deliberate attacker from modifying the payload or header.
- **Not a password-based system.** There is no password, no key derivation (PBKDF2/Argon2/etc.), and no AES/ChaCha.
- **Not secure against a stolen or shared file** when the key is stored in the clear. **Don't store** and **Encrypt key** keep the secret out of the file, but the payload is still repeating-key XOR.
- **Not a substitute for disk encryption, HTTPS, or secure messaging.**

### Optional “encrypt file names”

Name scrambling XORs UTF-8 names and stores hex. It:

- Does **not** hide the fact that a file is an XOR archive (`XOF1` magic, `.xor` extension)
- Still stores the (possibly scrambled) name and the **key in the header**
