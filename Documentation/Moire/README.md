# Moire

A native macOS app that XORs two videos. Where a color byte agrees, it becomes 0, so a pixel where the pictures match goes black. Where they differ, the color is the bits that disagree.

**Version:** 1.0.8 (build 9)

The movie follows clip A: its frame size, its frame rate, and its length. Clip B is sampled at A's times. Match Length stops at the shorter of the two instead, picture and sound. The source files are never overwritten.

WebM and MKV open through ffmpeg, which is looked up in Homebrew and MacPorts. H.264 and HEVC are copied into a temporary movie. VP9 and other picture is encoded to H.264. The original file stays where it is. Without ffmpeg, export those as MP4 first.

## Placement

| | |
|---|---|
| Fit | B keeps its shape and sits inside A. Bars stay A's picture. |
| Fill | B covers A. The extra is cropped. |
| Stretch | B is stretched to A's frame. |
| Lock | B keeps its pixel size and sits in the center. Gaps stay A's picture. |

Alpha is ignored. The output is opaque. After B ends, those frames are A, because the missing picture XORs as black. Match Length leaves that tail out and ends on the shorter clip.

B can be turned, flipped, scaled, offset, or delayed before that XOR. 90° is clockwise, so the top edge moves to the right. Flip H mirrors left and right. Flip V mirrors top and bottom. Scale changes the placed copy, from a quarter size to double, and the gaps stay A's picture. Offset slides that copy: positive X moves right, positive Y moves down, each as a fraction of A's frame. Reset Offset puts both axes back at zero. Delay XORs with an earlier frame of B. Until that frame exists, the picture stays A. The sound is not delayed.

Preview playback uses a long edge of 960. Save writes an H.264 `.mov` at A's size, capped at a long edge of 3840. XOR is noisy, so the encoder is given a high bit rate. It is still lossy.

Sound is Off, From A, or XOR. From A plays the first soundtrack with the preview and writes it into the saved movie. XOR mixes both soundtracks sample by sample, the same rule as the picture: matching samples go silent, and after B's sound ends the rest is A. The first play of XOR mixes the sound before the picture starts. The preview clock and the sound can drift a little on a long clip.

## Keyboard

| | |
|---|---|
| ⌘O | Open two videos |
| ⌘⇧O | Open video B |
| Space | Play or pause |
| ⌘S | Save the movie as `moire-yyyymmdd-hhmmss.mov` |
| ⌘K | Clear both videos |
| ⌘L | Load the sample pair |
| ⌥⌘S | Swap A and B |
| ⌘1–4 | Fit, Fill, Stretch, Lock |
| ⌘5 | Turn B 90° clockwise |
| ⌘6 | Turn B 180° |
| ⌘0 | Reset Offset X and Offset Y to zero |
| ⌘7 | Match the movie to the shorter video |

The sample pair is a red square crossing a blue square. Where they overlap, the XOR is magenta. Shared black stays black.

## Build

SwiftUI needs the Xcode toolchain. `build-app.sh` selects it.

```bash
cd ~/Apps-Usefull/Moire
chmod +x build-app.sh
./build-app.sh
```

```bash
./Moire.app/Contents/MacOS/Moire --self-test
./Moire.app/Contents/MacOS/Moire a.mov b.mov -o xor.mov
./Moire.app/Contents/MacOS/Moire a.mov b.mov --place fill --turn 90 --audio -o xor.mov
./Moire.app/Contents/MacOS/Moire a.mov b.mov --scale 0.5 --delay 0.4 -o xor.mov
./Moire.app/Contents/MacOS/Moire a.mov b.mov --match-lengths -o xor.mov
./Moire.app/Contents/MacOS/Moire a.mov b.mov --xor-audio -o xor.mov
./Moire.app/Contents/MacOS/Moire --sample -o sample-xor.mov
```

`--no-launch` builds and signs without opening the app.
