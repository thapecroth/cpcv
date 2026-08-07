# Windows app mark

This folder contains the original imgpaste mark used by the Windows tray and
status window.

- `imgpaste-logo.png` is the 512px transparent PNG for the status UI and docs.
- `imgpaste-tray.ico` contains 16, 20, 24, 32, 40, 48, 64, 128, and 256px
  icon images for Windows notification-area scaling.
- `imgpaste-logo-chromakey.png` is the original generated source on a magenta
  chroma-key background. It is retained so the transparent derivative can be
  reproduced and audited.

The mark was generated as original project artwork for imgpaste: a clipboard,
image frame, and upward transfer arrow. It contains no third-party logo,
screenshot, or proprietary source asset and is available under this
repository's [MIT License](../../LICENSE).

The transparent derivative was produced from the chroma-key source with the
repository maintainer's image workflow, then cropped with safe padding and
resized using high-quality Lanczos resampling. Do not replace the ICO with a
single-size icon: the small 16–48px entries are necessary for a crisp tray
appearance on common Windows scale factors.
