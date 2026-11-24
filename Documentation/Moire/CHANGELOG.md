# Changelog

## 1.0.8

- Match Length ends the movie at the shorter clip. The longer tail is left out of the picture and the sound. Off, the movie still follows A's full length. The checkbox sits beside Loop, and Movie → Match Lengths is ⌘7. CLI: `--match-lengths`.

## 1.0.7

- Reset Offset puts Offset X and Offset Y back at zero. Scale, turn, flip, and delay stay put. The button is in the picture controls, and Movie → Reset Offset is ⌘0.

## 1.0.6

- B can be turned 90° or 180°, flipped horizontally or vertically, scaled, offset, or delayed before the XOR. Gaps and the time before a delayed frame stay A's picture. The sound is not delayed.

## 1.0.5

- Saving with XORed sound finishes on a movie longer than a few seconds. The soundtrack is written alongside the picture, so the encoder is no longer left waiting on the other track.

## 1.0.4

- WebM and MKV can be opened. Moire converts them with ffmpeg, leaves the original alone, and then plays and saves them like any other video. H.264 and HEVC are copied. VP9 and other picture is encoded to H.264.

## 1.0.3

- Sound can be Off, From A, or XOR. XOR mixes the two soundtracks sample by sample. Matching samples go silent. After B's sound ends, the rest is A. Preview plays it, and Save writes it. CLI: `--xor-audio`.

## 1.0.2

- Clear removes both videos. The button sits beside Swap. Edit → Clear Selections is ⌘K.

## 1.0.1

- Open and drop no longer skip videos. The file dialog lists every file, a dropped file URL is read in the form Finder actually sends, and access to the file stays open while the clip is loaded.

## 1.0.0

- Load two videos and XOR their color bytes, frame by frame.
- The movie follows A: its frame, its rate, and its length. B is sampled at those times.
- Fit, Fill, Stretch, and Lock place B on A's frame. Gaps XOR with black, so they stay A's picture. After B ends, the tail is A.
- Play the XOR in the window. Scrub. Loop. Sound from A can play along, and Save can write it into the movie.
- Preview long edge is 960. Save writes H.264 up to a 3840 long edge. Source files are never overwritten.
- CLI for two files or `--sample`, plus `--self-test`.
