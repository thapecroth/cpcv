#!/usr/bin/env bash
# Managed by cpcv tmux plugin
set -euo pipefail
IFS=$'\n\t'

cpcv_tmx_load_config() {
  local config=${CPCV_TMUX_CONFIG:-"${HOME:-}/.config/cpcv/tmux-paste.conf"}
  local key='' value='' image_dir='' paste_table='' paste_key=''
  local paste_secondary_table='' paste_secondary_key=''
  local image_seen=0 table_seen=0 key_seen=0 secondary_table_seen=0 secondary_key_seen=0
  [[ -n "${HOME:-}" && -e "$config" && -f "$config" && ! -L "$config" ]] || return 2
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      image_dir)
        ((image_seen == 0)) || return 2
        image_dir=$value
        image_seen=1
        ;;
      paste_table)
        ((table_seen == 0)) || return 2
        [[ "$value" == prefix || "$value" == root ]] || return 2
        paste_table=$value
        table_seen=1
        ;;
      paste_key)
        ((key_seen == 0)) || return 2
        [[ "$value" =~ ^[a-z0-9]$ || "$value" == C-v ]] || return 2
        paste_key=$value
        key_seen=1
        ;;
      paste_secondary_table)
        ((secondary_table_seen == 0)) || return 2
        [[ "$value" == prefix || "$value" == root ]] || return 2
        paste_secondary_table=$value
        secondary_table_seen=1
        ;;
      paste_secondary_key)
        ((secondary_key_seen == 0)) || return 2
        [[ "$value" =~ ^[a-z0-9]$ || "$value" == C-v || "$value" == M-v ]] || return 2
        paste_secondary_key=$value
        secondary_key_seen=1
        ;;
      ''|'#'*) ;;
      *) return 2 ;;
    esac
  done < "$config"
  ((image_seen == 1)) || return 2
  if ((table_seen != key_seen)); then return 2; fi
  if ((secondary_table_seen != secondary_key_seen)); then return 2; fi
  if [[ "$paste_table" == root && "$paste_key" != C-v ]]; then return 2; fi
  # The only managed multi-client profile is intentionally narrow: macOS can
  # use raw Ctrl-V while Windows terminals use Alt-V.  Keeping this pair
  # explicit prevents a remote config from silently taking arbitrary root
  # table keys.
  if ((secondary_table_seen == 1)) && \
      [[ "$paste_table" != root || "$paste_key" != C-v || \
         "$paste_secondary_table" != root || "$paste_secondary_key" != M-v ]]; then
    return 2
  fi
  CPCV_TMX_CONFIG_IMAGE_DIR=$image_dir
  CPCV_TMX_CONFIG_PASTE_TABLE=$paste_table
  CPCV_TMX_CONFIG_PASTE_KEY=$paste_key
  CPCV_TMX_CONFIG_PASTE_SECONDARY_TABLE=$paste_secondary_table
  CPCV_TMX_CONFIG_PASTE_SECONDARY_KEY=$paste_secondary_key
}

cpcv_tmx_read_config_dir() {
  cpcv_tmx_load_config || return 2
  printf '%s' "$CPCV_TMX_CONFIG_IMAGE_DIR"
}

cpcv_tmx_load_binding_config() {
  cpcv_tmx_load_config || return 2
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
