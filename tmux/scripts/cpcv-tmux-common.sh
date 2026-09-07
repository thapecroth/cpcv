#!/usr/bin/env bash
# Managed by cpcv tmux plugin
set -euo pipefail
IFS=$'\n\t'

cpcv_tmx_read_config_dir() {
  local config=${CPCV_TMUX_CONFIG:-"${HOME:-}/.config/cpcv/tmux-paste.conf"}
  local key='' value='' image_dir='' seen=0
  [[ -n "${HOME:-}" && -e "$config" && -f "$config" && ! -L "$config" ]] || return 2
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

cpcv_tmx_image_dir() {
  local tmux_bin=${1:-tmux} config image_dir home_dir
  [[ -n "${HOME:-}" ]] || return 2
  image_dir=$("$tmux_bin" show-options -gqv @cpcv-image-dir 2>/dev/null || true)
  if [[ -z "$image_dir" ]]; then
    config=${CPCV_TMUX_CONFIG:-"$HOME/.config/cpcv/tmux-paste.conf"}
    if [[ -e "$config" ]]; then
      image_dir=$(cpcv_tmx_read_config_dir) || return 2
    else
      image_dir=${CPCV_DIR:-"$HOME/clipboard-images"}
    fi
  fi
  [[ "$image_dir" != *[[:cntrl:]]* ]] || return 2
  home_dir=$(CDPATH= cd -P -- "$HOME" 2>/dev/null && /bin/pwd -P 2>/dev/null) || return 2
  image_dir=$(CDPATH= cd -P -- "$image_dir" 2>/dev/null && /bin/pwd -P 2>/dev/null) || return 2
  [[ "$home_dir" == /* && "$home_dir" != *[[:cntrl:]]* && "$image_dir" == "$home_dir/"* ]] || return 2
  printf '%s' "$image_dir"
}
