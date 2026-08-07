#!/usr/bin/env bash
# Read-only diagnostic for explicitly installed optional remote helpers.
set -euo pipefail

[ -r "$HOME/.config/imgpaste/env" ] && . "$HOME/.config/imgpaste/env"
IMG_DIR="${IMGPASTE_DIR:-${IMGPPASTE_DIR:-$HOME/clipboard-images}}"
BIN="$HOME/.local/bin"

echo "Image directory: $IMG_DIR"
echo "Latest image: $(readlink -f "$IMG_DIR/latest.png" 2>/dev/null || true)"
for helper in imgpaste-latest imgpaste-xclip imgpaste-wl-paste; do
  if [ -x "$BIN/$helper" ]; then
    echo "$helper: $BIN/$helper"
  else
    echo "$helper: not installed"
  fi
done

if [ -x "$BIN/imgpaste-xclip" ]; then
  echo "imgpaste-xclip targets:"
  "$BIN/imgpaste-xclip" -o -t TARGETS || true
fi
