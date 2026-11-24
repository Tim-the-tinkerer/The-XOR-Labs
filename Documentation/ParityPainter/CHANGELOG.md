# Changelog

## 1.1.0

- A large frame shows its coarse preview at once. Slack, Nudge, and the view no longer wait on a full-frame resample.
- The percent still counts every pixel. That count quits if you keep moving a control, then finishes when you pause. The view, the bit, the lift, and invert keep the count.
- Fit scales B once per pair. Save and Copy reuse that scale and still paint every pixel.
- Source thumbnails use a fast downsample.

## 1.0.0

- Load two images and XOR their bit-planes.
- Mask paints black where a pixel matches and white where it differs.
- XOR paints the color of that difference. Plane isolates one bit. Trace draws the difference back onto image A.
- Slack quiets small channel gaps. Lift brightens the XOR. Fit scales B onto A; Lock compares whole pixels, and Nudge slides B.
- Save and Copy use every pixel. A large frame previews on a coarser grid while the full-frame count finishes. Changing the view reuses that count. Source files are never overwritten.
- CLI for two files or `--sample`, plus `--self-test`.
