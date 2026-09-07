#!/usr/bin/env bash
# Managed by imgpaste tmux plugin
set -euo pipefail
IFS=$'\n\t'

pane=${1:-}
tmux_bin=${TMUX_BIN:-tmux}

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

read_config_dir() {
  local config=${IMGPASTE_TMUX_CONFIG:-"$HOME/.config/imgpaste/tmux-paste.conf"}
  local key='' value='' image_dir='' seen=0
  [[ -e "$config" ]] || return 1
  [[ -f "$config" && ! -L "$config" ]] || return 2
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      image_dir)
        ((seen == 0)) || return 2
        image_dir=$value
        seen=1
        ;;
      ''|'#'*) ;;
      *) return 2 ;;
    esac
  done < "$config"
  ((seen == 1)) || return 2
  printf '%s' "$image_dir"
}

image_dir=$("$tmux_bin" show-options -gqv @imgpaste-image-dir || true)
if [[ -z "$image_dir" ]]; then
  if [[ -e "${IMGPASTE_TMUX_CONFIG:-$HOME/.config/imgpaste/tmux-paste.conf}" ]]; then
    image_dir=$(read_config_dir) || fail 'invalid tmux image-directory configuration'
  else
    image_dir=${IMGPASTE_DIR:-"$HOME/clipboard-images"}
  fi
fi

[[ "$image_dir" != *[[:cntrl:]]* ]] || fail 'invalid image directory'
home_dir=$(CDPATH= cd -P -- "$HOME" 2>/dev/null && /bin/pwd -P 2>/dev/null) || fail 'HOME is unavailable'
image_dir=$(CDPATH= cd -P -- "$image_dir" 2>/dev/null && /bin/pwd -P 2>/dev/null) || fail 'image directory is unavailable'
[[ "$home_dir" == /* && "$home_dir" != *[[:cntrl:]]* && "$image_dir" == "$home_dir/"* ]] || \
  fail 'image directory must be below HOME'
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
