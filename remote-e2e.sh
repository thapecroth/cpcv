#!/usr/bin/env bash
# Read-only diagnostic for explicitly installed optional remote helpers.
set -euo pipefail

[ -r "$HOME/.config/cpcv/env" ] && . "$HOME/.config/cpcv/env"
IMG_DIR="${CPCV_DIR:-$HOME/clipboard-images}"
BIN="$HOME/.local/bin"

echo "Image directory: $IMG_DIR"
echo "Latest image: $(readlink -f "$IMG_DIR/latest.png" 2>/dev/null || true)"
for helper in cpcv-latest cpcv-xclip cpcv-wl-paste; do
  if [ -x "$BIN/$helper" ]; then
    echo "$helper: $BIN/$helper"
  else
    echo "$helper: not installed"
  fi
done

if [ -x "$BIN/cpcv-xclip" ]; then
  echo "cpcv-xclip targets:"
  "$BIN/cpcv-xclip" -o -t TARGETS || true
fi
