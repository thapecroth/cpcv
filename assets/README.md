# Artwork

`cpcv-workflow.png` and `cpcv-social-preview.png` are original project
artwork generated for cpcv. They contain no third-party logos, screenshots,
or source assets and are distributed under the repository's [MIT License](../LICENSE).

`windows/` contains the original cpcv application mark used by the Windows
tray controller. Its transparent PNG and multi-resolution ICO are maintained
alongside the generated chroma-key source; see [windows/README.md](windows/README.md).

Use `cpcv-social-preview.png` as the GitHub social-preview image through
the repository settings; GitHub does not automatically select a repository
asset for that field.

## Windows branding

`windows/cpcv-tray.ico` is the multi-resolution notification-area icon
used by `cpcv-tray.ps1`. `windows/cpcv-logo.png` is the matching
transparent logo for the Windows status UI and release material. The Windows
archive builder requires both files and verifies their basic file signatures.

The tray validates the ICO before loading it and falls back to the built-in
Windows application icon if the asset is missing, corrupt, oversized, or
unreadable. Keep the tray ICO as an `.ico` file with 16–512 px frames and at
most 1 MiB; do not point the application at a user-configured icon path.
