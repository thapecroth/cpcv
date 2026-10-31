#!/usr/bin/env bash
# Optional POSIX helper installer. Run only after explicitly copying these
# files to the remote host; it does not modify Claude, tmux, shell rc files, or
# global clipboard commands.
set -euo pipefail

BIN="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/ctrl-ccv"
IMG_DIR="${CTRL_CCV_DIR:-$HOME/clipboard-images}"
STAGE_DIR="${CTRL_CCV_STAGE_DIR:-/tmp}"

mkdir -p "$BIN" "$CONFIG_DIR" "$IMG_DIR"
install -m 755 "$STAGE_DIR/ctrl-ccv-latest.sh" "$BIN/ctrl-ccv-latest"
install -m 755 "$STAGE_DIR/xclip-shim.sh" "$BIN/ctrl-ccv-xclip"
if [ -f "$STAGE_DIR/wl-paste-shim.sh" ]; then
  install -m 755 "$STAGE_DIR/wl-paste-shim.sh" "$BIN/ctrl-ccv-wl-paste"
fi

printf 'export CTRL_CCV_DIR=%q\n' "$IMG_DIR" > "$CONFIG_DIR/env"
cat <<EOF
Installed optional ctrl-ccv helpers in $BIN.
Image directory: $IMG_DIR

Add $BIN to PATH to use ctrl-ccv-latest. The xclip and wl-paste helpers are
named ctrl-ccv-xclip and ctrl-ccv-wl-paste intentionally: opt in to command
shadowing yourself only if you understand the impact.
EOF
