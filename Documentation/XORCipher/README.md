# XOR Cipher

Native macOS app with two modes. **Cipher** encrypts files (and optional text) into a **`.xor`** archive using a repeating-key [XOR cipher](https://en.wikipedia.org/wiki/XOR_cipher). **Pass** is XOR Pass: Argon2id, an HMAC-SHA256 counter keystream, and a tag, written as **`.xorpass`**.

Cipher is educational and is not suitable for protecting real secrets. Pass is the stronger mode. The standalone XOR Pass app is still in the next folder and writes the same `.xorpass` files.

![Version](https://img.shields.io/badge/version-1.3.0-blue)
![macOS](https://img.shields.io/badge/macOS-13%2B-lightgrey)

## Features

- **Cipher / Pass** in the toolbar (⌘1, ⌘2). Dropping an archive switches to the mode named by the file
- **Pass:** Argon2id password stretch, optional key file, salt, nonce, padding, encrypted names, HMAC-SHA256 tag, `.xorpass`
- **Repeating key** XORed with every byte (`C = P ⊕ K`) in Cipher mode
- **XOR is its own inverse:** the same key encrypts and decrypts
- **Workshop:** live hex alignment plus an 8-bit board for one selected byte
- **Simple flow:** drop files or folders → Encrypt or Decrypt (auto-detected)
- **Directory support:** one folder → one `.xor`; decrypt restores the full tree
- **`.xor` (XOF1)** container: key kind, optional key, original name, CRC-32, payload
- **Key kinds:**
  - **Text** — UTF-8 bytes of a passphrase, repeating
  - **Hex** — keystream from hex digits (`6B 65 79`, `0x6B6579`)
  - **Key file** — raw bytes of a binary file, repeating (a one-time pad if the file is at least as long as the message)
- **Key in the file:**
  - **Store key** — writes it in the header (convenient; anyone with the file can decrypt)
  - **Don't store** — omits it; type the same key to decrypt
  - **Encrypt key** — XOR-wraps the stored key with a wrap passphrase (never written to the file)
- **Encrypt file names** — optional; XOR then hex-encode so names stay path-safe
- Famous example: `Hello` ⊕ `key` → `23 00 15 07 0A`
- Drag-and-drop, Open… (⌘O), Encrypt / Decrypt All (⌘↩)
- Auto-decrypt when opening a `.xor` from Finder
- Custom app icon

## Requirements

- macOS 13 or later
- Swift toolchain (`xcode-select --install` if needed)

## Build & run

```bash
cd "/Users/timbestler/Apps - Encryption/XORCipher"
chmod +x build-app.sh run.sh
./build-app.sh       # tests, builds XORCipher.app, and opens it
# or
./run.sh
```

Build without launching:

```bash
./build-app.sh --no-launch
```

## How it works

XOR (exclusive or) compares bits: the result is **1** when the bits **disagree**, **0** when they **match**. Applied to each plaintext byte and the next key byte:

```
P  01001000   H   (0x48)
K  01101011   k   (0x6B)
C  00100011   #   (0x23)
```

The key repeats for the length of the message. Because `P ⊕ K ⊕ K = P`, encrypting twice with the same key restores the original — that is the Vernam / XOR cipher.

```
Plain:  Hello
Key:    keyke
Hex:    23 00 15 07 0A
```

The second byte is `00` because `e ⊕ e = 0`.

Pass mode does not repeat the password. Argon2id stretches it, and an HMAC-SHA256 counter makes a new keystream for each archive. The byte layout is in [FORMAT-xorpass.md](FORMAT-xorpass.md).

## How to use

Choose **Cipher** or **Pass** in the toolbar. ⌘1 is Cipher. ⌘2 is Pass.

### Encrypt (Cipher)

1. Drop or **Open…** any file **or folder**
2. Choose **Text**, **Hex**, or a **Key file**, set the key, choose how it is stored, and optionally **Encrypt file names**
3. Click **Encrypt** (or **Encrypt / Decrypt All**)
4. Result next to the original:
   - `song.mp3` → `song.xor`
   - `Photos/` → `Photos.xor` (entire folder tree)

### Encrypt (Pass)

1. Switch to **Pass**
2. Drop or **Open…** a file or a folder
3. Type the password in both fields, choose a key file, or do both
4. Click **Encrypt**

The result is next to the original, named `XORPass-` plus random hex, with the extension `.xorpass`. The original name is inside the archive.

### Decrypt

**Pass:** drop the `.xorpass`, type the same password, and choose the same key file if you used one. The window switches to Pass.

**Store key:** double-click a `.xor` in Finder — the app reads the key from the header and decrypts.

**Don't store:** enter the same key, then **Decrypt**.

**Encrypt key:** enter the wrap passphrase, then **Decrypt**.

### Workshop

Toggle **Text** to XOR a message live. Click a hex column to see that byte’s eight bits. Ciphertext is often not printable, so **Hex** is the usual output; ASCII, Base64, and Binary are available too.

Decrypt in the workshop by pasting hex (spaces allowed) and switching to **Decrypt**.

## Keyboard shortcuts

| Action | Shortcut |
|--------|----------|
| Cipher mode | ⌘1 |
| Pass mode | ⌘2 |
| Open files | ⌘O |
| Encrypt / Decrypt All | ⌘↩ |
| Hello ⊕ key | ⇧⌘E |
| Wiki ⊕ pedia | ⇧⌘K |
| Random hex key | ⇧⌘R |

## Project layout

```
XORCipher/
├── Package.swift
├── AppInfo.plist
├── Assets/AppIcon.icns
├── build-app.sh
├── run.sh
├── README.md
├── CHANGELOG.md
├── FORMAT.md
├── FORMAT-xorpass.md
├── SECURITY.md
├── SECURITY-xorpass.md
├── Scripts/GenerateAppIcon.swift
├── Sources/
│   ├── CArgon2/               # Argon2id used by Pass mode
│   ├── XORPassCore/           # .xorpass format + cipher
│   ├── XORCore/               # .xor format + repeating-key cipher
│   └── XORCipher/             # SwiftUI app
└── Tests/
    ├── XORCipherTestRunner/
    └── XORPassTestRunner/
```

## Documentation

| Doc | Contents |
|-----|----------|
| [CHANGELOG.md](CHANGELOG.md) | Release history |
| [FORMAT.md](FORMAT.md) | Binary layout of `.xor` (XOF1) |
| [FORMAT-xorpass.md](FORMAT-xorpass.md) | Binary layout of `.xorpass` (XOP1) |
| [SECURITY.md](SECURITY.md) | Cipher mode — educational only |
| [SECURITY-xorpass.md](SECURITY-xorpass.md) | Pass mode |

## Tests

```bash
swift run XORCipherTestRunner
```

(Uses an assert-based runner so it works with Command Line Tools; XCTest is not required.)

## Version

**1.3.0** — see [CHANGELOG.md](CHANGELOG.md).

## License / disclaimer

For learning and experimentation. A short repeating XOR key is breakable with frequency analysis and known-plaintext; do **not** use this for real security. Omitting or wrapping the header key keeps it out of the file, but it does not turn XOR into real encryption. A one-time pad is theoretically unbreakable only when the key is truly random, as long as the message, never reused, and kept secret.
