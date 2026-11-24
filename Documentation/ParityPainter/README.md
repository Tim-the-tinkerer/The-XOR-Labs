# Parity Painter

A native macOS tool that loads two images, XORs their bit-planes, and paints the difference. Black where a pixel matches, white where it does not. Useful for comparing photos, spotting an edit, or making a picture out of the bits.

This is not the Parity puzzle. That game lives in Apps-Games.

**Version:** 1.1.0 (build 2)

The source files are never overwritten. The long edge is capped at 8192 px.

## Views

| View | What you see |
|---|---|
| Mask | Black matches. White differs. This is the comparison. |
| XOR | Each channel, XORed. Black is a match. Color is the difference. |
| Plane | One bit of that XOR. Bit 0 is the finest grain, bit 7 the coarsest. |
| Trace | Image A, with differing pixels traced toward white. |

**Channel** limits the test to red, green, blue, luma, or all three. **Slack** treats a channel gap at or under N as a match, which quiets JPEG noise. Slack is an absolute gap, not an XOR magnitude: 127 and 128 differ by 1 and XOR to 255, so slack 1 blacks them out and slack 0 paints 255.

**Lift** multiplies the XOR so a faint difference becomes visible. Mask stays black and white.

**Fit** scales B onto A's pixels. **Lock** does not resample. **Nudge** slides B. Positive X moves B right, positive Y moves it down. Pixels of B that fall off the frame compare against black.

**Invert** flips the paint: white where they match.

The percent is a full-frame count. A large photo shows a coarse preview at once, and the count catches up when you pause. Slack, Nudge, and the view do not wait for that count. Switching the view, the bit, the lift, or invert keeps the count. Fit scales B once for the pair, and Save and Copy reuse that scale. They still paint every pixel.

## Keyboard

| | |
|---|---|
| ⌘O | Open two images |
| ⌘⇧O | Open image B |
| ⌘V | Paste an image (into B once A is filled) |
| ⌘⇧V | Paste into A |
| ⇧⌘C | Copy the difference |
| ⌘S | Save the difference as `parity-<view>-yyyymmdd-hhmmss.png` |
| ⌘K | Clear |
| ⌘L | Load the sample pair |
| ⌥⌘S | Swap A and B |
| ⌘1–4 | Mask, XOR, Plane, Trace |
| ⌘I | Invert |

The sample pair is a small landscape. The sun has moved, and a door was added. Shared ground and windows stay black.

## Build

SwiftUI needs the Xcode toolchain. `build-app.sh` selects it.

```bash
cd ~/Apps-Usefull/ParityPainter
chmod +x build-app.sh
./build-app.sh
```

```bash
./ParityPainter.app/Contents/MacOS/ParityPainter --self-test
./ParityPainter.app/Contents/MacOS/ParityPainter before.png after.png
./ParityPainter.app/Contents/MacOS/ParityPainter before.jpg after.jpg --slack 8 --mode trace -o edit.png
./ParityPainter.app/Contents/MacOS/ParityPainter --sample --mode xor -o sample-xor.png
```

`--no-launch` builds and signs without opening the app.
