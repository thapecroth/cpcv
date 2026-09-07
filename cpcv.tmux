#!/usr/bin/env bash
# Managed by cpcv tmux plugin
set -euo pipefail

plugin_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
paste_script="$plugin_dir/tmux/scripts/cpcv-tmux-paste.sh"
status_script="$plugin_dir/tmux/scripts/cpcv-tmux-status.sh"
common_script="$plugin_dir/tmux/scripts/cpcv-tmux-common.sh"
[[ -f "$paste_script" && -f "$status_script" && -f "$common_script" ]] || {
  printf 'cpcv tmux plugin: installation is incomplete\n' >&2
  exit 1
}

quote_shell() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

key=$(tmux show-options -gqv @cpcv-paste-key || true)
key=${key:-C-v}
[[ "$key" != -* && "$key" != *[[:space:]]* && "$key" != *[[:cntrl:]]* ]] || {
  tmux display-message 'cpcv: @cpcv-paste-key must be one tmux key name' >&2
  exit 0
}

command="CPCV_TMUX_PLUGIN=1 $(quote_shell "$paste_script") '#{pane_id}'"
existing=$(tmux list-keys -T root 2>/dev/null | \
  awk -v key="$key" '$1 == "bind-key" && $2 == "-T" && $3 == "root" && $4 == key { print; exit }' || true)
if [[ -n "$existing" && "$existing" != *'CPCV_TMUX_PLUGIN=1'* ]]; then
  tmux display-message "cpcv: $key is already bound; set @cpcv-paste-key to an unused key" >&2
  exit 0
fi
tmux bind-key -n -T root "$key" run-shell -b "$command"

status_enabled=$(tmux show-options -gqv @cpcv-status || true)
case "$status_enabled" in
  0|false|False|FALSE|no|No|NO|off|Off|OFF) exit 0 ;;
esac

status_segment="#(CPCV_TMUX_STATUS=1 $(quote_shell "$status_script"))"
status_right=$(tmux show-options -gqv status-right || true)
if [[ "$status_right" != *'CPCV_TMUX_STATUS=1'* ]]; then
  tmux set-option -g status-right "${status_right:+$status_right }$status_segment"
fi

status_refresh=$(tmux show-options -gqv @cpcv-status-refresh || true)
status_refresh=${status_refresh:-2}
if [[ "$status_refresh" =~ ^[1-9][0-9]?$ ]] && ((status_refresh <= 60)); then
  current_refresh=$(tmux show-options -gqv status-interval || true)
  managed_refresh=$(tmux show-options -gqv @cpcv-status-refresh-managed || true)
  if [[ -z "$managed_refresh" || "$current_refresh" == "$managed_refresh" ]]; then
    tmux set-option -g status-interval "$status_refresh"
    tmux set-option -g @cpcv-status-refresh-managed "$status_refresh"
  fi
else
  tmux display-message 'cpcv: @cpcv-status-refresh must be 1-60 seconds' >&2
fi
