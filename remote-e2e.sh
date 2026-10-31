#!/usr/bin/env bash
# Read-only diagnostic for explicitly installed optional remote helpers.
set -euo pipefail

[ -r "$HOME/.config/ctrl-ccv/env" ] && . "$HOME/.config/ctrl-ccv/env"
IMG_DIR="${CTRL_CCV_DIR:-$HOME/clipboard-images}"
BIN="$HOME/.local/bin"

echo "Image directory: $IMG_DIR"
echo "Latest image: $(readlink -f "$IMG_DIR/latest.png" 2>/dev/null || true)"
for helper in ctrl-ccv-latest ctrl-ccv-xclip ctrl-ccv-wl-paste; do
  if [ -x "$BIN/$helper" ]; then
    echo "$helper: $BIN/$helper"
  else
    echo "$helper: not installed"
  fi
done

if [ -x "$BIN/ctrl-ccv-xclip" ]; then
  echo "ctrl-ccv-xclip targets:"
  "$BIN/ctrl-ccv-xclip" -o -t TARGETS || true
fi
