#!/usr/bin/env bash
# Managed by cpcv tmux plugin
set -euo pipefail
IFS=$'\n\t'

script_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
common="$script_dir/cpcv-tmux-common.sh"
[[ -f "$common" && ! -L "$common" ]] || exit 0
source "$common"

tmux_bin=${TMUX_BIN:-tmux}
status_enabled=$("$tmux_bin" show-options -gqv @cpcv-status 2>/dev/null || true)
case "$status_enabled" in
  0|false|False|FALSE|no|No|NO|off|Off|OFF) exit 0 ;;
esac

image_dir=$(cpcv_tmx_image_dir "$tmux_bin" 2>/dev/null) || exit 0
latest="$image_dir/latest.png"
[[ -f "$latest" && -s "$latest" ]] || { printf '%s' 'cpcv · no image'; exit 0; }

modified=$(stat -c %Y "$latest" 2>/dev/null || stat -f %m "$latest" 2>/dev/null || true)
[[ "$modified" =~ ^[0-9]+$ ]] || exit 0
now=${CPCV_TMUX_NOW:-}
[[ -n "$now" ]] || now=$(date +%s 2>/dev/null || true)
[[ "$now" =~ ^[0-9]+$ ]] || exit 0
if ((modified > now)); then age=0; else age=$((now - modified)); fi

if ((age == 0)); then
  label='just now'
elif ((age < 60)); then
  label="$age sec ago"
elif ((age < 3600)); then
  label="$((age / 60)) min ago"
elif ((age < 86400)); then
  label="$((age / 3600)) hr ago"
else
  label="$((age / 86400)) day ago"
fi
printf 'cpcv · %s' "$label"
