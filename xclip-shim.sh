#!/usr/bin/env bash
# xclip shim for imgpaste: when Claude Code / other agents ask for the clipboard image,
# serve the configured latest.png (synced from Windows by imgpaste).
#
# Install as: ~/.local/bin/xclip  (must be earlier on PATH than /usr/bin/xclip)
# Keep real binary at /usr/bin/xclip for text/other uses.

set -u

[ -r "$HOME/.config/imgpaste/env" ] && . "$HOME/.config/imgpaste/env"
REAL_XCLIP="${IMGPASTE_REAL_XCLIP:-${IMGPPASTE_REAL_XCLIP:-/usr/bin/xclip}}"
IMG_DIR="${IMGPASTE_DIR:-${IMGPPASTE_DIR:-$HOME/clipboard-images}}"
IMG="$IMG_DIR/latest.png"
# Prefer a stable absolute path string for agents (user-visible paste).
PATH_TEXT="${IMGPASTE_PATH_TEXT:-${IMGPPASTE_PATH_TEXT:-$IMG_DIR/latest.png}}"
if command -v readlink >/dev/null 2>&1 && [ -e "$IMG" ]; then
  PATH_TEXT="$(readlink -f "$IMG" 2>/dev/null || echo "$PATH_TEXT")"
fi

want_out=0
mime=""
i=0
args=("$@")
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    -o|--out)
      want_out=1
      ;;
    -t|--target)
      i=$((i + 1))
      mime="${args[$i]:-}"
      ;;
    TARGETS)
      mime="TARGETS"
      ;;
  esac
  i=$((i + 1))
done

# Prefer path-as-text so Claude/Codex paste shows a string, not a silent image.
if [ "$want_out" -eq 1 ] && [ "$mime" = "TARGETS" ]; then
  if [ -f "$IMG" ] && [ -s "$IMG" ]; then
    printf 'TIMESTAMP\nTARGETS\ntext/plain\nUTF8_STRING\nSTRING\n'
    exit 0
  fi
fi

if [ "$want_out" -eq 1 ]; then
  case "$mime" in
    ""|text/plain|UTF8_STRING|STRING|TEXT)
      if [ -f "$IMG" ] && [ -s "$IMG" ]; then
        printf '%s' "$PATH_TEXT"
        exit 0
      fi
      ;;
    image/png|image/*)
      # Intentionally do not auto-attach image bytes; user wants path string.
      if [ -f "$IMG" ] && [ -s "$IMG" ]; then
        printf '%s' "$PATH_TEXT"
        exit 0
      fi
      exit 1
      ;;
  esac
fi

# Everything else (set clipboard, etc.) -> real xclip when available.
if [ -x "$REAL_XCLIP" ]; then
  exec "$REAL_XCLIP" "$@"
fi

if [ "$want_out" -eq 1 ]; then
  exit 1
fi

echo "imgpaste xclip shim: real xclip not found at $REAL_XCLIP" >&2
exit 127
