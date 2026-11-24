# XOR Pass Archive Format (XOP1)

Pass mode in XOR Cipher writes this format. The standalone XOR Pass app writes the same bytes. Cipher mode writes `.xor` (XOF1), documented in [FORMAT.md](FORMAT.md).

**File extension:** `.xorpass`  
**Magic:** `XOP1` (`58 4F 50 31`)  
**Version:** `1`  
**Endianness:** little-endian  

The cipher is XOR. A password is stretched with Argon2id into a 32-byte key. That key never repeats across the file: HMAC-SHA256 in counter mode produces the keystream, and each plaintext byte is XOR'd with the next keystream byte.

The password is not stored. Each archive has its own salt and nonce.

## Layout

| Offset | Size | Field |
|-------:|-----:|-------|
| 0 | 4 | Magic `XOP1` |
| 4 | 2 | Version (`1`) |
| 6 | 2 | Flags |
| 8 | 4 | Argon2id memory, KiB |
| 12 | 4 | Argon2id passes `t` |
| 16 | 4 | Argon2id lanes `p` |
| 20 | 4 | Argon2id output length (`32`) |
| 24 | 16 | Salt |
| 40 | 16 | Nonce |
| 56 | 8 | Ciphertext length `C` |
| 64 | 256 | Encrypted original name |
| 320 | `C` | Ciphertext |
| 320+`C` | 32 | HMAC-SHA256 tag |

The header is 320 bytes. The tag is the last 32 bytes of the file.

## Flags

| Bit | Name | Meaning |
|----:|------|---------|
| 0 (`0x0001`) | Directory | Payload is a ZIP of a folder (`ditto -c -k --keepParent`). Decrypt extracts the folder. |
| 1 (`0x0002`) | Key file | Argon2id was given a binary key file as its secret. The file is not stored. Decrypt needs the same bytes. |
| 2 (`0x0004`) | Password | Used only with the key-file flag. A typed password was mixed in as well. |
| 3–4 (`0x0018`) | Padding | `00` standard, `01` private, `10` maximum. `11` is rejected. |
| 5–15 | Reserved | Must be `0`. |

A password-only archive leaves bits 1 and 2 clear, which is the 1.0.0 layout. Bit 2 is set only when bit 1 is set. Key-file-only archives set bit 1 and leave the password empty.

## Password stretch

```
master = Argon2id(password, salt, t, m, p, outlen=32)
```

Argon2id is the official PHC implementation, version `0x13`. A key file, when present, is the secret input. With no key file the secret length is 0.

- Argon2 version `0x13`, type Argon2id.
- No secret key and no associated data.
- Password bytes are the UTF-8 of the password in NFC. A key-file-only archive uses an empty password.
- When a key file is chosen, its raw bytes are the Argon2id secret (`K` in RFC 9106). They are not stored. With no key file the secret length is 0, which is the 1.0.0 derivation.
- Salt is 16 random bytes.
- Default profile (Standard): `m = 65536` KiB (64 MiB), `t = 3`, `p = 4`. This is the RFC 9106 second recommended option.
- High profile: `m = 131072` KiB (128 MiB), `t = 4`, `p = 4`.

On open, parameters are checked before Argon2 runs:

| Parameter | Accepted |
|-----------|----------|
| Memory | 8 MiB – 256 MiB |
| Passes | 2 – 8 |
| Lanes | 1 – 4 |
| Output | 32 bytes |

## Keys

The 32-byte Argon2id output is the HMAC key for three separate keys. The nonce is mixed in here, so the keystream changes even when the salt does not.

```
bodyKey = HMAC-SHA256(master, "XORPass-body-v1" ‖ nonce)
nameKey = HMAC-SHA256(master, "XORPass-name-v1" ‖ nonce)
macKey  = HMAC-SHA256(master, "XORPass-mac-v1"  ‖ nonce)
```

The labels are UTF-8, with no separator other than the end of the string. The nonce is the raw 16 bytes.

## Keystream

The cipher is XOR with a counter-mode keystream. Block `i` (counting from 0) is 32 bytes:

```
KS_i = HMAC-SHA256(purposeKey, uint64_be(i))
```

`purposeKey` is `bodyKey` for the payload and `nameKey` for the name. The counters are independent. The name uses blocks 0…7 (256 bytes). The payload uses a fresh counter starting at 0.

## Payload

Before XOR, the payload is framed:

```
uint64_le(plaintext length) ‖ plaintext ‖ random pad
```

The pad length is chosen so the framed blob rounds up to a bucket, with at least 32 bytes of pad. Let `min = length + 8 + 32`.

**Standard** (flag bits 3–4 = `00`, the 1.0 layout):

- If `min ≤ 4096`, the bucket is the next multiple of 256.
- Otherwise the bucket is the next multiple of 4096.

**Private** (`01`):

- `min ≤ 64 KiB`: next multiple of 4 KiB
- `min ≤ 1 MiB`: next multiple of 64 KiB
- `min ≤ 16 MiB`: next multiple of 1 MiB
- Otherwise: next multiple of 16 MiB

**Maximum** (`10`): the next power of two, and at least 256.

The addition is checked. A declared length above 32 GiB is rejected before the bucket is calculated.

The ciphertext is that framed blob XOR the body keystream. Its length is the `C` stored in the header. An empty file occupies 256 ciphertext bytes.

On decrypt, the recovered length must produce the same `C`. Bytes after the plaintext are pad and are discarded.

## File name

The original file or folder name is a single path component, UTF-8, at most 255 bytes. It is packed into a fixed 256-byte block so the length is hidden:

```
uint8(name length) ‖ name ‖ random pad to 256
```

That block is XOR'd with the name keystream and stored at offset 64. The archive's own file name does not contain the original name. It is `XORPass-` plus 16 random hex digits (8 bytes) plus `.xorpass`.

Decrypt writes the restored name next to the archive. `/`, `\`, and NUL are rejected. `.` and `..` are rejected.

## Tag

Encrypt-then-MAC. The tag is HMAC-SHA256, keyed by `macKey`, over the header and the ciphertext (everything except the tag). The comparison is constant-time. A mismatch — wrong password or any modified byte — stops decryption before plaintext is written.

## Encrypt

1. Draw a 16-byte salt and a 16-byte nonce.
2. Derive `master` with Argon2id, then the three HMAC keys.
3. Encrypt the name. Frame and pad the payload. XOR with the body keystream.
4. Write header, ciphertext, and tag.
5. Save as `XORPass-` plus 16 hex digits and `.xorpass` beside the original.

A folder is zipped first (`ditto -c -k --keepParent`). Symlinks inside the folder are refused. The folder name is the encrypted name, and the directory flag is set.

## Decrypt

1. Read the header. Reject a bad magic, version, unknown flag, or Argon2 setting outside the limits above. Argon2 has not run yet.
2. Derive the keys and check the tag.
3. Decrypt the name.
4. XOR the ciphertext, read the length, check the bucket, and write only the plaintext bytes.
5. For a directory, read the ZIP central directory first and refuse `..`, an absolute path, a symlink, or any entry that is not a file or directory. Then unzip into a work directory mode `0700`. After extraction, refuse a symlink, a hard link, or a path that escapes the folder.
6. A decrypted partial file is mode `0600` before it is renamed into place. The `.xorpass` ciphertext is not given a special mode.
