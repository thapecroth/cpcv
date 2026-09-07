#!/usr/bin/env bash
# Optional companion: insert the latest uploaded image path into one tmux pane.
# Install as ~/.local/bin/imgpaste-latest on a POSIX SSH target.

set -euo pipefail

usage() {
  printf 'Usage: %s [--pane %%PANE_ID]\n' "${0##*/}" >&2
  exit 64
}

pane=${TMUX_PANE:-}
while (($#)); do
  case "$1" in
    --pane) (($# >= 2)) || usage; pane=$2; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -r "$HOME/.config/imgpaste/env" ] && . "$HOME/.config/imgpaste/env"
IMG_DIR="${IMGPASTE_DIR:-${IMGPPASTE_DIR:-$HOME/clipboard-images}}"
[[ "$IMG_DIR" != *$'\n'* && "$IMG_DIR" != *$'\r'* ]] || {
  printf 'Invalid imgpaste image directory.\n' >&2
  exit 64
}

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

if [[ "$pane" =~ ^%[0-9]+$ ]]; then
  buffer="imgpaste-${pane#%}-$$"
  cleanup() { tmux delete-buffer -b "$buffer" >/dev/null 2>&1 || true; }
  trap cleanup EXIT HUP INT TERM
  tmux set-buffer -b "$buffer" -- "$latest"
  tmux paste-buffer -d -p -b "$buffer" -t "$pane"
  trap - EXIT HUP INT TERM
else
  printf '%s' "$latest"
fi
