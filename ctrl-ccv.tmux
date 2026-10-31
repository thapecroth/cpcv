#!/usr/bin/env bash
# Managed by ctrl-ccv tmux plugin
set -euo pipefail

plugin_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
paste_script="$plugin_dir/tmux/scripts/ctrl-ccv-tmux-paste.sh"
status_script="$plugin_dir/tmux/scripts/ctrl-ccv-tmux-status.sh"
common_script="$plugin_dir/tmux/scripts/ctrl-ccv-tmux-common.sh"
[[ -f "$paste_script" && -f "$status_script" && -f "$common_script" ]] || {
  printf 'ctrl-ccv tmux plugin: installation is incomplete\n' >&2
  exit 1
}
source "$common_script"

quote_shell() {
  local value=$1
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

canonical_tmux_key() {
  local requested=$1 probe_table canonical

  # tmux canonicalizes aliases (for example, C-V becomes C-v).  Ask tmux to
  # parse the key in an unused, short-lived table before comparing it with an
  # existing binding.  Without this, an alias could silently overwrite a
  # user's canonical binding.  The randomized table is never selected by a
  # key mode and is emptied before this function returns.
  probe_table="ctrl-ccv-key-probe-$$_$RANDOM"
  while tmux list-keys -T "$probe_table" 2>/dev/null | grep -q .; do
    probe_table="ctrl-ccv-key-probe-$$_$RANDOM"
  done
  tmux bind-key -T "$probe_table" "$requested" display-message CTRL_CCV_TMUX_KEY_PROBE=1 \
    >/dev/null 2>&1 || return 1
  canonical=$(tmux list-keys -T "$probe_table" 2>/dev/null | \
    awk -v table="$probe_table" \
      '$1 == "bind-key" && $2 == "-T" && $3 == table && index($0, "CTRL_CCV_TMUX_KEY_PROBE=1") { print $4; exit }' || true)
  tmux unbind-key -T "$probe_table" "$requested" >/dev/null 2>&1 || true
  [[ -n "$canonical" ]] || return 1
  printf '%s' "$canonical"
}

configured_key=$(tmux show-options -gqv @ctrl-ccv-paste-key || true)
configured_table=$(tmux show-options -gqv @ctrl-ccv-paste-table || true)
managed_config=${CTRL_CCV_TMUX_CONFIG:-"${HOME:-}/.config/ctrl-ccv/tmux-paste.conf"}
declare -a binding_tables=()
declare -a binding_keys=()

add_ctrl_ccv_binding() {
  local requested_table=$1 requested_key=$2 canonical binding_index

  [[ "$requested_key" != -* && "$requested_key" != *[[:space:]]* && \
     "$requested_key" != *[[:cntrl:]]* ]] || {
    tmux display-message 'ctrl-ccv: @ctrl-ccv-paste-key must be one tmux key name' >&2
    return 1
  }
  [[ "$requested_table" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || {
    tmux display-message 'ctrl-ccv: @ctrl-ccv-paste-table must be one tmux key table name' >&2
    return 1
  }
  canonical=$(canonical_tmux_key "$requested_key") || {
    tmux display-message 'ctrl-ccv: @ctrl-ccv-paste-key is not recognized by tmux' >&2
    return 1
  }

  for binding_index in "${!binding_tables[@]}"; do
    if [[ "${binding_tables[$binding_index]}" == "$requested_table" && \
          "${binding_keys[$binding_index]}" == "$canonical" ]]; then
      tmux display-message 'ctrl-ccv: managed tmux configuration contains duplicate bindings' >&2
      return 1
    fi
  done
  binding_tables+=("$requested_table")
  binding_keys+=("$canonical")
}

ctrl_ccv_binding_requested() {
  local requested_table=$1 requested_key=$2 binding_index
  for binding_index in "${!binding_tables[@]}"; do
    [[ "${binding_tables[$binding_index]}" == "$requested_table" && \
       "${binding_keys[$binding_index]}" == "$requested_key" ]] && return 0
  done
  return 1
}

# A root-table Ctrl-V binding is convenient only when the terminal forwards a
# raw control character.  Modern terminal apps can consume it for local paste,
# and a tmux server cannot tell which client OS originated the key.  Make the
# portable default prefix-v.  An existing explicit @ctrl-ccv-paste-key retains the
# previous root-table behavior unless its owner selects a table explicitly.
if [[ -n "$configured_table" || -n "$configured_key" ]]; then
  key=${configured_key:-v}
  # An existing explicit key-only configuration was the legacy root-table
  # contract. Keep it as the higher-priority user-owned override.
  if [[ -n "$configured_table" ]]; then
    table=$configured_table
  else
    table=root
  fi
  add_ctrl_ccv_binding "$table" "$key" || exit 0
elif [[ -e "$managed_config" ]]; then
  ctrl_ccv_tmx_load_binding_config || {
    tmux display-message 'ctrl-ccv: managed tmux configuration is invalid' >&2
    exit 0
  }
  if [[ -n "$CTRL_CCV_TMX_CONFIG_PASTE_TABLE" ]]; then
    key=$CTRL_CCV_TMX_CONFIG_PASTE_KEY
    table=$CTRL_CCV_TMX_CONFIG_PASTE_TABLE
    add_ctrl_ccv_binding "$table" "$key" || exit 0
    if [[ -n "$CTRL_CCV_TMX_CONFIG_PASTE_SECONDARY_TABLE" ]]; then
      add_ctrl_ccv_binding "$CTRL_CCV_TMX_CONFIG_PASTE_SECONDARY_TABLE" \
        "$CTRL_CCV_TMX_CONFIG_PASTE_SECONDARY_KEY" || exit 0
    fi
  else
    # Existing installations have an image_dir-only managed config. Keep
    # their portable prefix/v default until the UI or installer updates it.
    key=v
    table=prefix
    add_ctrl_ccv_binding "$table" "$key" || exit 0
  fi
else
  key=v
  table=prefix
  add_ctrl_ccv_binding "$table" "$key" || exit 0
fi

command="CTRL_CCV_TMUX_PLUGIN=1 $(quote_shell "$paste_script") '#{pane_id}'"

# A ctrl-ccv compatibility binding is also ours to replace; do not mistake it for
# a user command merely because it predates the plugin marker. The legacy
# ctrl-ccv-latest form only ever belonged in root/C-v, which keeps this match
# deliberately narrow.
ctrl_ccv_owned_binding() {
  local binding=$1 binding_table=$2 binding_key=$3
  [[ "$binding" == *'CTRL_CCV_TMUX_PLUGIN=1'* || "$binding" == *'CTRL_CCV_TMUX_COMPAT=1'* ]] && return 0
  [[ "$binding_table" == root && "$binding_key" == C-v && "$binding" == *'ctrl-ccv-latest --pane'* ]]
}

# Preserve the focused upgrade path from CTRL_CCV's historic raw Ctrl-V binding to
# the safe single prefix/v fallback. If prefix/v turns out to be user-owned,
# this still releases the *ctrl-ccv-owned* legacy Ctrl-V hook so normal paste is
# not trapped forever. This exception deliberately does not apply to the
# two-binding cross-platform profile: both of its destinations must preflight
# successfully before it changes any binding.
if (( ${#binding_tables[@]} == 1 )) && [[ "${binding_tables[0]}" == prefix && "${binding_keys[0]}" == v ]]; then
  legacy_root_binding=$(tmux list-keys -T root 2>/dev/null | \
    awk '$1 == "bind-key" && $2 == "-T" && $3 == "root" && $4 == "C-v" { print; exit }' || true)
  if [[ -n "$legacy_root_binding" ]] && ctrl_ccv_owned_binding "$legacy_root_binding" root C-v; then
    tmux unbind-key -T root C-v
  fi
fi

# Check every requested destination before removing old ctrl-ccv bindings. In
# particular, the dual-platform profile must not half-install if either raw
# key belongs to the user. Explicit @ctrl-ccv-paste-* options remain a single,
# higher-priority binding and never activate the managed secondary binding.
for binding_index in "${!binding_tables[@]}"; do
  binding_table=${binding_tables[$binding_index]}
  binding_key=${binding_keys[$binding_index]}
  existing=$(tmux list-keys -T "$binding_table" 2>/dev/null | \
    awk -v table="$binding_table" -v key="$binding_key" \
      '$1 == "bind-key" && $2 == "-T" && $3 == table && $4 == key { print; exit }' || true)
  if [[ -n "$existing" ]] && ! ctrl_ccv_owned_binding "$existing" "$binding_table" "$binding_key"; then
    tmux display-message "ctrl-ccv: $binding_table/$binding_key is already bound; choose another ctrl-ccv table or key" >&2
    exit 0
  fi
done

# Remove only ctrl-ccv-owned stale root bindings after all requested destinations
# have passed collision checks. A user-owned root binding is never touched.
managed_root_keys=$(tmux list-keys -T root 2>/dev/null | \
  awk '$1 == "bind-key" && $2 == "-T" && $3 == "root" && \
    (index($0, "CTRL_CCV_TMUX_PLUGIN=1") || index($0, "CTRL_CCV_TMUX_COMPAT=1") || ($4 == "C-v" && index($0, "ctrl-ccv-latest --pane"))) { print $4 }' || true)
while IFS= read -r managed_root_key; do
  [[ -n "$managed_root_key" ]] || continue
  if ! ctrl_ccv_binding_requested root "$managed_root_key"; then
    tmux unbind-key -T root "$managed_root_key"
  fi
done <<< "$managed_root_keys"

# A UI-managed change can move between prefix/v, a custom prefix key, and raw
# Ctrl-V. Once all destinations have proved safe, discard obsolete ctrl-ccv prefix
# bindings so only the selected single binding or dual-platform pair remains.
managed_prefix_keys=$(tmux list-keys -T prefix 2>/dev/null | \
  awk '$1 == "bind-key" && $2 == "-T" && $3 == "prefix" && \
    (index($0, "CTRL_CCV_TMUX_PLUGIN=1") || index($0, "CTRL_CCV_TMUX_COMPAT=1")) { print $4 }' || true)
while IFS= read -r managed_prefix_key; do
  [[ -n "$managed_prefix_key" ]] || continue
  if ! ctrl_ccv_binding_requested prefix "$managed_prefix_key"; then
    tmux unbind-key -T prefix "$managed_prefix_key"
  fi
done <<< "$managed_prefix_keys"

for binding_index in "${!binding_tables[@]}"; do
  tmux bind-key -T "${binding_tables[$binding_index]}" "${binding_keys[$binding_index]}" \
    run-shell -b "$command"
done

status_enabled=$(tmux show-options -gqv @ctrl-ccv-status || true)
case "$status_enabled" in
  0|false|False|FALSE|no|No|NO|off|Off|OFF) exit 0 ;;
esac

status_segment="#(CTRL_CCV_TMUX_STATUS=1 $(quote_shell "$status_script"))"
status_right=$(tmux show-options -gqv status-right || true)
if [[ "$status_right" != *'CTRL_CCV_TMUX_STATUS=1'* ]]; then
  tmux set-option -g status-right "${status_right:+$status_right }$status_segment"
fi

status_refresh=$(tmux show-options -gqv @ctrl-ccv-status-refresh || true)
status_refresh=${status_refresh:-2}
if [[ "$status_refresh" =~ ^[1-9][0-9]?$ ]] && ((status_refresh <= 60)); then
  current_refresh=$(tmux show-options -gqv status-interval || true)
  managed_refresh=$(tmux show-options -gqv @ctrl-ccv-status-refresh-managed || true)
  if [[ -z "$managed_refresh" || "$current_refresh" == "$managed_refresh" ]]; then
    tmux set-option -g status-interval "$status_refresh"
    tmux set-option -g @ctrl-ccv-status-refresh-managed "$status_refresh"
  fi
else
  tmux display-message 'ctrl-ccv: @ctrl-ccv-status-refresh must be 1-60 seconds' >&2
fi
