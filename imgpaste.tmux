#!/usr/bin/env bash
# Managed by imgpaste tmux plugin
set -euo pipefail

plugin_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
paste_script="$plugin_dir/tmux/scripts/imgpaste-tmux-paste.sh"
[[ -f "$paste_script" ]] || {
  printf 'imgpaste tmux plugin: missing paste script: %s\n' "$paste_script" >&2
  exit 1
}

quote_shell() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

key=$(tmux show-options -gqv @imgpaste-paste-key || true)
key=${key:-C-v}
[[ "$key" != -* && "$key" != *[[:space:]]* && "$key" != *[[:cntrl:]]* ]] || {
  tmux display-message 'imgpaste: @imgpaste-paste-key must be one tmux key name' >&2
  exit 0
}

command="IMGPASTE_TMUX_PLUGIN=1 $(quote_shell "$paste_script") '#{pane_id}'"
existing=$(tmux list-keys -T root 2>/dev/null | \
  awk -v key="$key" '$1 == "bind-key" && $2 == "-T" && $3 == "root" && $4 == key { print; exit }' || true)
if [[ -n "$existing" && "$existing" != *'IMGPASTE_TMUX_PLUGIN=1'* ]]; then
  tmux display-message "imgpaste: $key is already bound; set @imgpaste-paste-key to an unused key" >&2
  exit 0
fi
tmux bind-key -n -T root "$key" run-shell -b "$command"
