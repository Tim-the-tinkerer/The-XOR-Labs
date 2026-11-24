# The XOR Labs

**One operation. Four laboratories.** Native macOS 13+ · version 1.0.0

A single Swift application and executable containing four separate workspaces:

- **Moire 1.0.8** — video XOR, spatial transforms and delay, preview and export.
- **Parity Painter 1.1.0** — image XOR, masks, bit planes, trace and alignment.
- **Crosstalk 1.3.0** — sample-level audio XOR, channel and waveform folds, file comparisons, delay and listening/export controls.
- **XOR Cipher 1.3.0** — existing Cipher and Pass modes, retaining .xor and .xorpass compatibility. Repeating-key Cipher is educational, not secure encryption.

## Build

Unzip the project on your Mac. Double-click **Build The XOR Labs.command**, or in Terminal:

```sh
cd '/path/to/The XOR Labs'
bash build-app.sh
```

Use `bash build-app.sh --no-launch` to build without opening. Requires Xcode or its command-line tools (`xcode-select --install`). The script compiles the native executable, runs the three media self-tests and the two data test runners, assembles one `.app` with its bundled icon, and ad-hoc signs it. No network dependency is introduced by the merger; Moire's existing optional ffmpeg conversion still requires ffmpeg for formats described in its documentation.

If macOS is set to use standalone Command Line Tools and Xcode is installed at `/Applications/Xcode.app`, the script uses Xcode for this build. Set `DEVELOPER_DIR` to choose a specific Xcode installation. Swift Build can emit missing linker search-path warnings when building with standalone Command Line Tools.

## Use

The home window opens at launch. Choose a lab to open its original workspace in a separate native window. **Labs** is available from every workspace. Option-Command-0 opens Home; Option-Command-1 through 4 open Moire, Parity Painter, Crosstalk and XOR Cipher. Switching windows retains loaded state; each lab retains its own menus and shortcuts. Closing a lab window does not quit the suite. Quit with Command-Q. Multiple workspaces can be open at once. Use each lab's own Open or drag/drop controls when you want to select the destination explicitly. Finder opens use file type routing (archive files always go to XOR Cipher; if that lab is active, other files also go there). The bundle claims generic media as an alternate handler, not a default.

## Command line

The media CLI commands and their self-tests are available through the common executable:

```sh
BIN='./The XOR Labs.app/Contents/MacOS/XORLabs'
"$BIN" moire --help
"$BIN" parity --help
"$BIN" crosstalk --help
"$BIN" moire --self-test
```

Existing arguments after the lab name are forwarded unchanged. The data test runners are built and run by the build script.

## Architecture and scope

One SwiftPM package, one executable, four independently namespaced UI/engine modules. XORCore, XORPassCore and CArgon2 remain distinct. The suite owns window navigation, file routing, and menu switching. The original documentation and available license notices are in `Documentation/`. The Argon2 license is in `Sources/CArgon2/LICENSE`. Individual lab documents describe their original standalone apps. Use the build instructions above for the unified app.

## Verification status

The build script runs the five test suites before packaging and verifies the app signature before replacing any existing bundle. For an interactive check, open each lab, load or export a sample, and switch among the windows using the Labs menu or keyboard shortcuts.
