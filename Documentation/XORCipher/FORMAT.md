# XOR Cipher Archive Format (XOF1)

Cipher mode writes this format. Pass mode writes `.xorpass` (XOP1). That layout is [FORMAT-xorpass.md](FORMAT-xorpass.md). An archive follows the magic in its header.

# Cipher archive (XOF1)

**File extension:** `.xor`  
**Magic:** `XOF1` (`58 4F 46 31`)  
**Version:** `1`  
**Endianness:** little-endian  

## Layout

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 4 | Magic `XOF1` |
| 4 | 2 | Version (`1`) |
| 6 | 1 | Method (see below) |
| 7 | 1 | Flags (see below) |
| 8 | 2 | Key UTF-8 length |
| 10 | 8 | Original size (bytes before encryption) |
| 18 | 8 | Payload size (encrypted bytes) |
| 26 | 4 | CRC-32 of original data (ISO/ZIP polynomial) |
| 30 | 2 | Original filename UTF-8 length |
| 32 | *N* | Original filename (UTF-8, no path) |
| 32+*N* | *K* | Key field (see Methods) |
| 32+*N*+*K* | *P* | Encrypted payload |

Fixed header size is 32 bytes. Key follows the filename.

## Methods

| Value | Name | Transform |
|------:|------|-----------|
| `1` | Text key | Every byte: `b XOR keyByte`; key is the passphrase’s UTF-8 bytes, repeating. Header stores that UTF-8 string. |
| `2` | Hex key | Same XOR; key bytes are parsed from the stored hex string (`6B 65 79`, `0x6B6579`). |
| `3` | Key file | Same XOR; key bytes are the raw contents of a binary key file, repeating. Header stores those raw bytes (max 65,535). Larger files must use **omit key**. |

XOR is involutive: decrypt is the same operation as encrypt.

## Flags

| Bit | Name | Meaning |
|----:|------|---------|
| 0 (`0x01`) | Directory | Payload is a ZIP of a folder (`ditto -c -k --keepParent`). Decrypt extracts the folder tree. |
| 1 (`0x02`) | Encrypt names | Header name (and zip path components for directories) are XOR-then-hex encoded with the archive key. |
| 2 (`0x04`) | Omit key | Key field is empty (`keyLen = 0`). Decrypt requires the same key the user typed at encrypt time. |
| 3 (`0x08`) | Wrap key | Key field is the stored key material XOR-wrapped with a wrap passphrase (text key, repeating). For text/hex that material is the key string UTF-8; for a key file it is the file bytes. Decrypt requires that passphrase. The wrap passphrase is never stored. |
| 4–7 | Reserved | Must be `0` |

Omit and wrap are mutually exclusive. When neither is set, the key string is stored in the clear (v1.0 behaviour).

When the directory flag is set, **original filename** is the top-level folder name (not a `.zip` name).  
When encrypt-names is set, hex-decode that field (and each path component) then XOR with the key before restoring. Each name starts at key index 0.

## Keystream

- **Text:** every UTF-8 byte of the key string, including spaces and punctuation.
- **Hex:** parse the key string as hex (spaces, colons, dashes, and a leading `0x` are ignored). Odd length or non-hex digits are invalid.

The key cursor is preserved across 1 MiB streaming chunks so a split payload matches a one-shot transform.

## Encrypt

1. Choose method and key.
2. Stream original file; XOR each byte; compute CRC-32 of original.
3. Write header + original filename + key field (clear, omitted, or wrapped) + payload to `name.xor`.

## Decrypt

1. Verify magic and version.
2. Read method, flags, sizes, CRC, original name, and key field from the header.
3. Recover the payload key: stored in the clear, omitted (caller supplies it), or unwrap with the wrap passphrase.
4. XOR the payload with that key (same operation as encrypt).
5. Verify CRC-32 (and size when present). Wrong omitted key or wrap passphrase fails this check.
6. Write restored bytes using the stored original filename when available.

## Examples

Text key `key`:  
`Hello` → `23 00 15 07 0A`

| Source | Encrypt (key `key`) | Decrypt |
|--------|---------------------|---------|
| `Report.pdf` | `Report.xor` | `Report.pdf` |
| `notes.txt` | `notes.xor` | `notes.txt` |
