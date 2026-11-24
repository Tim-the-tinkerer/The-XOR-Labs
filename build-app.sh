#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
launch=true
for arg in "$@"; do
  case "$arg" in --no-launch) launch=false;; *) echo "Unknown option: $arg" >&2; exit 2;; esac
done
if [[ "$(uname -s)" != Darwin ]]; then echo 'This application requires macOS 13 or later and Xcode command-line tools.' >&2; exit 1; fi

# Swift Build can add nonexistent Xcode-style linker paths with standalone Command Line Tools.
# Prefer the installed Xcode for this build when the caller has not chosen a toolchain.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p 2>/dev/null || true)" == /Library/Developer/CommandLineTools ]]; then
  xcode=/Applications/Xcode.app/Contents/Developer
  if [[ -d "$xcode/Library/Frameworks" && -d "$xcode/usr/lib" ]] &&
     DEVELOPER_DIR="$xcode" xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 &&
     DEVELOPER_DIR="$xcode" xcrun --find swift >/dev/null 2>&1; then
    export DEVELOPER_DIR="$xcode"
  fi
fi
if ! xcrun --find swift >/dev/null 2>&1; then echo 'Install Xcode command-line tools with xcode-select --install.' >&2; exit 1; fi
xcrun swift build -c release
bin="$(xcrun swift build -c release --show-bin-path)"
for lab in moire parity crosstalk; do "$bin/XORLabs" "$lab" --self-test; done
"$bin/XORCipherTestRunner"
"$bin/XORPassTestRunner"

app='The XOR Labs.app'
tmp=$(mktemp -d './.xorlabs-build.XXXXXX')
staged="$tmp/$app"
backup="$tmp/previous.app"
lock=./.build/xorlabs-install.lock
locked=false
cleanup() {
  if [[ -e "$backup" || -L "$backup" ]]; then
    if [[ ! -e "$app" && ! -L "$app" ]] && ! mv -h "$backup" "$app"; then
      echo "The previous app is at $backup" >&2
      if $locked; then rm -f "$lock"; fi
      return
    fi
  fi
  rm -rf "$tmp"
  if $locked; then rm -f "$lock"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
cp "$bin/XORLabs" "$staged/Contents/MacOS/XORLabs"
cp AppInfo.plist "$staged/Contents/Info.plist"
cp -R Documentation "$staged/Contents/Resources/Documentation"
cp README.md "$staged/Contents/Resources/README.md"
cp Assets/AppIcon.icns "$staged/Contents/Resources/AppIcon.icns"
plutil -lint "$staged/Contents/Info.plist"
xattr -cr "$staged" 2>/dev/null || true
codesign --force --sign - --identifier com.tim.xorlabs --timestamp=none "$staged"
codesign --verify --strict --verbose=2 "$staged"

if ! shlock -f "$lock" -p "$$"; then
  echo 'Another build is installing The XOR Labs.app.' >&2
  exit 1
fi
locked=true
if [[ -e "$app" || -L "$app" ]]; then mv -h "$app" "$backup"; fi
mv -h "$staged" "$app"
echo "Built and tested: $app"
if $launch; then open "$app"; fi
