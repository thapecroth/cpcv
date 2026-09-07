#!/usr/bin/env bash
# Managed by imgpaste tmux plugin
set -euo pipefail
IFS=$'\n\t'

pane=${1:-}
tmux_bin=${TMUX_BIN:-tmux}
script_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
common="$script_dir/imgpaste-tmux-common.sh"

notify() {
  [[ "$pane" =~ ^%[0-9]+$ ]] || return 0
  "$tmux_bin" display-message -d 4000 -t "$pane" "imgpaste: $*" >/dev/null 2>&1 || true
}

fail() {
  notify "$*"
  exit 1
}

[[ "$pane" =~ ^%[0-9]+$ ]] || exit 64
command -v "$tmux_bin" >/dev/null 2>&1 || exit 127
[[ -f "$common" && ! -L "$common" ]] || fail 'tmux helper installation is incomplete'
source "$common"
image_dir=$(imgpaste_tmx_image_dir "$tmux_bin") || fail 'invalid tmux image-directory configuration'
latest="$image_dir/latest.png"
[[ -f "$latest" && -s "$latest" ]] || fail 'no uploaded image is ready'

buffer="imgpaste-${pane#%}-$$"
cleanup() {
  "$tmux_bin" delete-buffer -b "$buffer" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
"$tmux_bin" set-buffer -b "$buffer" -- "$latest"
"$tmux_bin" paste-buffer -d -p -b "$buffer" -t "$pane"
trap - EXIT HUP INT TERM
notify 'inserted latest image path'
