#!/usr/bin/env bash
# Optional POSIX helper installer. Run only after explicitly copying these
# files to the remote host; it does not modify Claude, tmux, shell rc files, or
# global clipboard commands.
set -euo pipefail

BIN="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/cpcv"
IMG_DIR="${CPCV_DIR:-$HOME/clipboard-images}"
STAGE_DIR="${CPCV_STAGE_DIR:-/tmp}"

mkdir -p "$BIN" "$CONFIG_DIR" "$IMG_DIR"
install -m 755 "$STAGE_DIR/cpcv-latest.sh" "$BIN/cpcv-latest"
install -m 755 "$STAGE_DIR/xclip-shim.sh" "$BIN/cpcv-xclip"
if [ -f "$STAGE_DIR/wl-paste-shim.sh" ]; then
  install -m 755 "$STAGE_DIR/wl-paste-shim.sh" "$BIN/cpcv-wl-paste"
fi

printf 'export CPCV_DIR=%q\n' "$IMG_DIR" > "$CONFIG_DIR/env"
cat <<EOF
Installed optional cpcv helpers in $BIN.
Image directory: $IMG_DIR

Add $BIN to PATH to use cpcv-latest. The xclip and wl-paste helpers are
named cpcv-xclip and cpcv-wl-paste intentionally: opt in to command
shadowing yourself only if you understand the impact.
EOF
