# Crosstalk

A native macOS tool. It XORs audio.

XOR is not a mix. Where two samples agree, those bits become zero. Where they disagree, the surviving bits are a new waveform. `1000 XOR 2000` is `1080`, not `3000`.

## Four ways

**Channels.** One file. Each sample is left XOR right, and both ears hear that. A mono file has the same waveform on both sides, so the XOR is silence. That silence means the two sides agreed.

**Waveform.** One file. Each channel is folded with itself.

- **Reverse.** Sample *i* XOR the sample across from it. The result reads the same forwards and backwards. Doing it again is silence, because the two sides of the result are identical.
- **Halves.** The first half XOR the second half. An odd length has a middle sample with no partner, and that sample passes through. The built-in tone is the same waveform twice, so its halves agree and the XOR erases them.

**Files.** Two recordings, sample by sample. The first file sets the sample rate. Drop both at once, or open the second with ⌘⇧O.

- **Shorter** keeps the overlap. This is the default.
- **Longer** continues to the later ending. Past the shorter file the missing side is zero, and XOR with zero leaves those samples as they are.
- **Loop** repeats the shorter file.
- **Slip** slides the second file. Positive starts it later. The shift is a whole number of samples, up to 2 seconds either way.

A mono file against a stereo file is XORed with both channels. Two stereo files XOR left with left and right with right.

If the rates differ, the second file is lined up on the first with linear interpolation. Those are new integers, so that pass will not reverse exactly.

**Delay.** One file. Each channel is XORed with a delayed copy of itself.

- **10 ms, 20 ms, 50 ms.** 10 ms at 44.1 kHz is 441 samples. The delay is a whole number of samples.
- **Stack** runs those three in order. Each stage XORs the previous result with a delayed copy of itself.
- **Sweep** moves the delay across the file. Stack keeps the three delays still.
- **Blend** mixes the left and right of a file before the XOR. It stays off unless you turn it on. The built-in tone is not blended. 0 is the left channel. 1 is the right.
- **Left only** keeps the right channel as it was.

Delay 0 XORs every sample with itself and is silence. Before the delay has filled, those samples pass through. 220 Hz at 50 ms is 11 cycles, so that tone is erased. A song at 50 ms does not line up.

The window still opens on Channels. Delay, with no file of your own, plays a 220 Hz tone so that erasure is there to hear.

Both file wells stay open in every mode. Loading a second file does not change the mode. **First**, **Second**, and **Both** choose what Channels, Waveform, and Delay hear. First is the default. Both runs that mode on each file, then XORs those results. The shorter one sets the length. A single loaded file is not XORed with a built-in tone. Files still XORs the two recordings directly, with slip and length.

## Coming back

At 16-bit, when the rates match, XOR the result with the second file and the first one comes back. A 16-bit WAV uses those integers directly. `−32768` is kept.

8-bit is the same XOR on a coarser integer. The file is still 16-bit so a player can open it, and that export is for listening.

Volume is playback only. It does not change which bits are written.

Export asks where to write. The original stays where it is. The first 10 minutes are loaded.

**Export loop** repeats that XOR until a time you set, up to 10 minutes. A last pass that does not fit is cut at that time. **Export one pass** writes the XOR once. At 16-bit, with matching rates, the one-pass file is the one you can XOR back.

## Hear it

The window opens on a built-in stereo tone: 220 Hz on the left, 330 Hz on the right. Press Play. Channels is the two of them XORed. Waveform → Halves erases the tone, because each half is the same waveform. Files XORs a 220 Hz tone with a 330 Hz tone until you drop your own.

## Build

```bash
./build-app.sh
```

`--no-launch` builds and tests without opening the app. The build uses Xcode's toolchain.

```bash
Crosstalk --self-test
Crosstalk --channels song.wav --out ~/Desktop/song-channels.wav
Crosstalk --waveform song.wav --fold reverse --out ~/Desktop/song-reverse.wav
Crosstalk --waveform song.wav --fold halves --out ~/Desktop/song-halves.wav
Crosstalk a.wav b.wav --out ~/Desktop/a-xor-b.wav
Crosstalk a.wav b.wav --length longer --slip 12 --bits 16 --out ~/Desktop/slipped.wav
Crosstalk --channels song.wav --repeat 30 --out ~/Desktop/song-channels-loop.wav
Crosstalk --delay song.wav --delay-ms 20 --out ~/Desktop/song-delay.wav
Crosstalk --delay song.wav --stack --out ~/Desktop/song-stack.wav
Crosstalk --delay song.wav --blend --mix 0.5 --out ~/Desktop/song-blend.wav
Crosstalk --delay --hz 220 --delay-ms 50 --seconds 8 --out ~/Desktop/tone.wav
Crosstalk --channels a.wav --with b.wav --pick both --out ~/Desktop/a-and-b-channels.wav
```

`--with` is the second file. `--pick` is `first`, `second`, or `both`. Files already takes two files, so those two options are not for it.

`--repeat` is seconds, from just over 0 to 600. Without it, the file is one pass.

## Keys

| Key | Action |
| --- | --- |
| Space | Play / Stop |
| 1, 2, 3, 4 | Channels, Waveform, Files, Delay |
| R, H | Reverse, Halves |
| S, L, P | Shorter, Longer, Loop |
| T | Stack 10 ms, then 20 ms, then 50 ms |
| B | Blend the file's left and right |
| ⌘O | Open audio |
| ⌘⇧O | Open the second file. It stays loaded in every mode. |
| ⌘E | Export one pass |
| ⌘⇧E | Export a repeating loop |
| ⌘K | Back to the built-in tones |
