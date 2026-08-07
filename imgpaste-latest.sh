#!/usr/bin/env bash
# Optional companion: paste latest uploaded image path into the current tmux pane.
# Install as ~/.local/bin/imgpaste-latest on a POSIX SSH target.

set -euo pipefail
[ -r "$HOME/.config/imgpaste/env" ] && . "$HOME/.config/imgpaste/env"
IMG_DIR="${IMGPASTE_DIR:-${IMGPPASTE_DIR:-$HOME/clipboard-images}}"
mkdir -p "$IMG_DIR"

if [ -L "$IMG_DIR/latest.png" ] || [ -f "$IMG_DIR/latest.png" ]; then
  latest="$IMG_DIR/latest.png"
else
  latest="$(ls -1t "$IMG_DIR"/*.png "$IMG_DIR"/*.jpg "$IMG_DIR"/*.jpeg "$IMG_DIR"/*.webp "$IMG_DIR"/*.gif 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${latest:-}" ]; then
  echo "No images in $IMG_DIR" >&2
  exit 1
fi

if command -v realpath >/dev/null 2>&1; then
  latest="$(realpath "$latest")"
elif command -v readlink >/dev/null 2>&1; then
  latest="$(readlink -f "$latest" 2>/dev/null || echo "$latest")"
fi

if [ -n "${TMUX:-}" ]; then
  tmux set-buffer -b imgpaste "$latest"
  tmux paste-buffer -b imgpaste
else
  printf '%s' "$latest"
fi
