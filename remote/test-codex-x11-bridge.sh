#!/usr/bin/env bash
# Verify the owned display and image/png clipboard selection without Codex TUI input.
set -euo pipefail
IFS=$'\n\t'

config_file="${CPCV_X11_CONFIG:-$HOME/.config/cpcv/codex-x11.conf}"
[[ -f "$config_file" && ! -L "$config_file" ]] || {
  printf 'Missing cpcv Codex X11 configuration: %s\n' "$config_file" >&2
  exit 64
}
display=''
image_dir=''
authority=''
key=''
value=''
while IFS='=' read -r key value || [[ -n "$key" ]]; do
  case "$key" in
    display) display=$value ;;
    image_dir) image_dir=$value ;;
    authority) authority=$value ;;
    '') ;;
    *) printf 'Unexpected configuration key: %s\n' "$key" >&2; exit 64 ;;
  esac
done < "$config_file"

while [[ "$image_dir" != '/' && "$image_dir" == */ ]]; do image_dir=${image_dir%/}; done
[[ "$display" =~ ^:[0-9]+$ && -d "$image_dir" && -f "$authority" ]] || {
  printf 'Invalid or missing cpcv Codex X11 configuration.\n' >&2
  exit 64
}
/usr/bin/systemctl --user is-active --quiet io.cpcv.codex-x11.service
/usr/bin/systemctl --user is-active --quiet io.cpcv.codex-x11-bridge.service
XAUTHORITY="$authority" DISPLAY="$display" /usr/bin/xdpyinfo >/dev/null

latest="$(readlink -f -- "$image_dir/latest.png" 2>/dev/null || true)"
[[ -n "$latest" && -f "$latest" && "$latest" == "$image_dir/"* ]] || {
  printf 'No uploaded image is available at %s/latest.png.\n' "$image_dir" >&2
  exit 1
}
temporary=$(mktemp)
trap '/usr/bin/unlink "$temporary" 2>/dev/null || true' EXIT
XAUTHORITY="$authority" DISPLAY="$display" /usr/bin/xclip -selection clipboard -target image/png -out > "$temporary"
cmp -s "$latest" "$temporary"
printf 'PASS: %s is available as image/png on %s.\n' "$latest" "$display"
