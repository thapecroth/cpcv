#!/usr/bin/env bash
# wl-paste shim: serve latest.png when agents request image/png from clipboard.
[ -r "$HOME/.config/cpcv/env" ] && . "$HOME/.config/cpcv/env"
REAL_WL="${CPCV_REAL_WLPASTE:-/usr/bin/wl-paste}"
IMG="${CPCV_DIR:-$HOME/clipboard-images}/latest.png"

want_type=""
list_types=0
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -t|--type)
      i=$((i + 1))
      want_type="${args[$i]:-}"
      ;;
    -l|--list-types)
      list_types=1
      ;;
  esac
  i=$((i + 1))
done

PATH_TEXT="${CPCV_PATH_TEXT:-$IMG}"
if command -v readlink >/dev/null 2>&1 && [ -e "$IMG" ]; then
  PATH_TEXT="$(readlink -f "$IMG" 2>/dev/null || echo "$PATH_TEXT")"
fi

if [ "$list_types" -eq 1 ]; then
  if [ -f "$IMG" ] && [ -s "$IMG" ]; then
    # Path-as-text only (no silent image attach).
    printf 'text/plain\n'
    exit 0
  fi
fi

if [ -z "$want_type" ] || [ "$want_type" = "text/plain" ] || [ "$want_type" = "image/png" ] || [ "$want_type" = "image/*" ]; then
  if [ -f "$IMG" ] && [ -s "$IMG" ]; then
    printf '%s' "$PATH_TEXT"
    exit 0
  fi
  exit 1
fi

if [ -x "$REAL_WL" ]; then
  exec "$REAL_WL" "$@"
fi

exit 1
