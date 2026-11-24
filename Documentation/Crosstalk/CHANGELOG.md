# Changelog

## 1.3.0

- Two audio files can stay loaded in every mode. Loading the second one does not switch to Files.
- First, Second, and Both choose what Channels, Waveform, and Delay hear. First is the default, so the sound stays on the top file until you choose otherwise.
- Both runs that mode on each file, then XORs the two results. The shorter one sets the length.
- One loaded file is not XORed with a built-in tone.

## 1.2.0

- Delay XORs each channel with a delayed copy of itself. 10 ms, 20 ms, and 50 ms are the presets. Stack runs those three in order.
- Sweep moves the delay across the file. The delay is a whole number of samples.
- Blend mixes the left and right of a file before the XOR. It stays off unless you turn it on. The tone is not blended.
- Left only keeps the right channel as it was.
- Volume is still playback only. Export writes the XOR at full scale.

## 1.1.1

- Playback stays at the file's sample rate and lets the output device resample. A 22050 Hz XOR was playing at the device rate, so it did not match the export.

## 1.1.0

- Export loop repeats the XOR until a time you set, up to 10 minutes. The last pass is cut there.
- Export one pass still writes the XOR once.

## 1.0.0

- XOR the channels of one file: left XOR right, on both ears.
- XOR a waveform with itself. Reverse, or the first half with the second.
- XOR two files sample by sample. Shorter, longer, or loop, with a sample slip.
- 16-bit WAV integers are XORed as they are. Matching rates come back if you XOR the second file again.
- 8-bit is the same XOR on a coarser integer.
- Originals are never overwritten. The first 10 minutes are loaded.
