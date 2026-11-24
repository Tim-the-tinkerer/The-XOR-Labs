# Security

Pass mode in XOR Cipher. The standalone XOR Pass app uses the same construction.

**Applies to XOR Pass 1.2.1 · archive format XOP1 (version 1)**  
**Implementation:** `Sources/XORPassCore/`  
**Password stretch:** official PHC Argon2 20190702 in `Sources/CArgon2/phc/` (Argon2id, RFC 9106), called through `xorpass_argon2.c`

XOR Pass encrypts files with a password. The cipher operation is XOR. The keystream is not the password and it is not a short repeating key.

This is a personal utility. It has not been independently audited. For a disk, FileVault is the right tool. For a file you have to hand to someone else, a widely reviewed format such as `age` is the safer default.

## What protects the file

```
master   = Argon2id(password, salt, t, m, p) → 32 bytes
bodyKey  = HMAC-SHA256(master, "XORPass-body-v1" ‖ nonce)
nameKey  = HMAC-SHA256(master, "XORPass-name-v1" ‖ nonce)
macKey   = HMAC-SHA256(master, "XORPass-mac-v1"  ‖ nonce)
KS_i     = HMAC-SHA256(purposeKey, uint64_be(i))
C        = P ⊕ KS
tag      = HMAC-SHA256(macKey, header ‖ ciphertext)
```

| Property | How |
|----------|-----|
| Password stretch | Argon2id. Standard is 64 MiB, 3 passes, 4 lanes (RFC 9106 second recommendation). High is 128 MiB, 4 passes, 4 lanes. |
| Key file | Optional. The file’s raw bytes are the Argon2id secret. A password, a key file, or both. The key file is not written into the archive. |
| Plaintext files | A decrypted partial is mode `0600`. The work directory that holds a decrypted ZIP is mode `0700`. |
| Folder archives | ZIP entries are checked before `ditto` extracts them. |
| Salt | 16 random bytes, stored in the header. A new salt for every archive. |
| Nonce | 16 random bytes, stored in the header. Mixed into the three HMAC keys, so the keystream is unique per archive. |
| Cipher | XOR with an HMAC-SHA256 counter keystream. The body and the file name use different keys. |
| Integrity | Encrypt-then-MAC, HMAC-SHA256 over the header and the ciphertext. A wrong password or a changed byte fails the tag. Plaintext is not written. |
| Padding | At least 32 bytes of pad. Standard rounds to 256 bytes under 4 KiB, then to 4 KiB. Private uses 4 KiB, 64 KiB, 1 MiB, and 16 MiB buckets. Maximum rounds up to the next power of two. The exact length sits inside the ciphertext. |
| File name | Fixed 256-byte block, XOR'd with the name keystream. The name on disk is `XORPass-` plus 16 random hex digits. |
| Parameter limits | Memory, passes, and lanes are checked before Argon2 runs. Caps: 8–256 MiB, 2–8 passes, 1–4 lanes. |

The password is NFC-normalized UTF-8. It is not written into the archive and it is not saved by the app. **Clear secrets when finished** is on by default, so the password, the confirmation, and the key file are cleared when Encrypt or Decrypt finishes. Turn that off if you want them to stay in the window.

## What this does not cover

- A password that can be guessed. Argon2id makes each guess expensive. It does not make a short password strong.
- Malware, a keylogger, or someone reading the screen on this Mac.
- The fact that a file is an XOR Pass archive (`XOP1`, `.xorpass`).
- The padded size bucket. A 1-byte file and a 200-byte file can share a bucket; the exact size is hidden, the bucket is not.
- A folder that contains a symlink. Packing refuses those.
- An audit. Argon2id is the official PHC implementation from 20190702, checked against the RFC 9106 test vector. The keystream is HMAC-SHA256 counter mode. The packaging around them is this app's own format.

## XOR Cipher

XOR Cipher, in the folder next to this one, is the educational repeating-key cipher. Its key can sit in the header, and a short repeating key is recoverable from the ciphertext. XOR Pass does not read or write `.xor` files, and XOR Cipher is unchanged.
