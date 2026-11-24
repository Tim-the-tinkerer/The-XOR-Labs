# Changelog

All notable changes to **XOR Cipher** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## [1.3.0] — 2026-11-19

### Added

- **Pass** mode. The toolbar chooses Cipher or Pass (⌘1, ⌘2). Pass is XOR Pass: Argon2id, an HMAC-SHA256 counter keystream, padding, and an HMAC-SHA256 tag. It writes `.xorpass`
- Dropping a `.xorpass` switches to Pass. Dropping a `.xor` switches to Cipher. Each archive decrypts with the format in its header
- Password, key file, or both. Standard and High stretch. Standard, Private, and Maximum padding. Clear secrets when finished

Cipher mode is unchanged. The standalone XOR Pass app is unchanged.

## [1.2.0] — 2026-09-06

### Added

- **Key file** — use the raw bytes of a binary file as the repeating XOR key
- Choose Key File… in the key row; files larger than 64 KB default to **Don’t store**

## [1.1.2] — 2026-09-06

### Fixed

- File pane overflowing into the key row and workshop (overlapping “Encrypt file names”, “Files & folders”, and Encrypt / Decrypt All)
- Sections now split leftover window height explicitly and clip to their slots

## [1.1.1] — 2026-09-06

### Fixed

- Duplicate picker titles (`Kind Kind`, `Key in file`, truncated `Direction`)
- Workshop clipping the bit board in shorter windows — that pane now scrolls
- Wrap-passphrase field placeholder overflowing the row

## [1.1.0] — 2026-09-06

### Added

- **Don't store** — omit the key from the `.xor` header; decrypt with the same key
- **Encrypt key** — XOR-wrap the stored key with a wrap passphrase (never written to the file)
- Wrong omitted key or wrap passphrase reports a clear error instead of a generic checksum failure

## [1.0.0] — 2026-09-06

### Added

- Native macOS app for the repeating-key XOR cipher
- Text key (UTF-8 bytes) and hex key (parsed keystream)
- `.xor` (XOF1) archive with key, method, CRC-32, original name
- File and folder encrypt/decrypt, optional name scrambling (XOR then hex)
- Workshop: live hex alignment of plaintext, repeating key, and ciphertext
- 8-bit board for a selected byte (P ⊕ K = C)
- Famous example: `Hello` ⊕ `key` → `23 00 15 07 0A`
- Finder Open With / double-click decrypt
- Assert-based test runner (`XORCipherTestRunner`)
