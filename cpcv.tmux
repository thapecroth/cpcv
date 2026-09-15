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
  probe_table="cpcv-key-probe-$$_$RANDOM"
  while tmux list-keys -T "$probe_table" 2>/dev/null | grep -q .; do
    probe_table="cpcv-key-probe-$$_$RANDOM"
  done
  tmux bind-key -T "$probe_table" "$requested" display-message CPCV_TMUX_KEY_PROBE=1 \
    >/dev/null 2>&1 || return 1
  canonical=$(tmux list-keys -T "$probe_table" 2>/dev/null | \
    awk -v table="$probe_table" \
      '$1 == "bind-key" && $2 == "-T" && $3 == table && index($0, "CPCV_TMUX_KEY_PROBE=1") { print $4; exit }' || true)
  tmux unbind-key -T "$probe_table" "$requested" >/dev/null 2>&1 || true
  [[ -n "$canonical" ]] || return 1
  printf '%s' "$canonical"
}

configured_key=$(tmux show-options -gqv @cpcv-paste-key || true)
configured_table=$(tmux show-options -gqv @cpcv-paste-table || true)
managed_config=${CPCV_TMUX_CONFIG:-"${HOME:-}/.config/cpcv/tmux-paste.conf"}
declare -a binding_tables=()
declare -a binding_keys=()

add_cpcv_binding() {
  local requested_table=$1 requested_key=$2 canonical binding_index

  [[ "$requested_key" != -* && "$requested_key" != *[[:space:]]* && \
     "$requested_key" != *[[:cntrl:]]* ]] || {
    tmux display-message 'cpcv: @cpcv-paste-key must be one tmux key name' >&2
    return 1
  }
  [[ "$requested_table" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || {
    tmux display-message 'cpcv: @cpcv-paste-table must be one tmux key table name' >&2
    return 1
  }
  canonical=$(canonical_tmux_key "$requested_key") || {
    tmux display-message 'cpcv: @cpcv-paste-key is not recognized by tmux' >&2
    return 1
  }

  for binding_index in "${!binding_tables[@]}"; do
    if [[ "${binding_tables[$binding_index]}" == "$requested_table" && \
          "${binding_keys[$binding_index]}" == "$canonical" ]]; then
      tmux display-message 'cpcv: managed tmux configuration contains duplicate bindings' >&2
      return 1
    fi
  done
  binding_tables+=("$requested_table")
  binding_keys+=("$canonical")
}

cpcv_binding_requested() {
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
# portable default prefix-v.  An existing explicit @cpcv-paste-key retains the
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
  add_cpcv_binding "$table" "$key" || exit 0
elif [[ -e "$managed_config" ]]; then
  cpcv_tmx_load_binding_config || {
    tmux display-message 'cpcv: managed tmux configuration is invalid' >&2
    exit 0
  }
  if [[ -n "$CPCV_TMX_CONFIG_PASTE_TABLE" ]]; then
    key=$CPCV_TMX_CONFIG_PASTE_KEY
    table=$CPCV_TMX_CONFIG_PASTE_TABLE
    add_cpcv_binding "$table" "$key" || exit 0
    if [[ -n "$CPCV_TMX_CONFIG_PASTE_SECONDARY_TABLE" ]]; then
      add_cpcv_binding "$CPCV_TMX_CONFIG_PASTE_SECONDARY_TABLE" \
        "$CPCV_TMX_CONFIG_PASTE_SECONDARY_KEY" || exit 0
    fi
  else
    # Existing installations have an image_dir-only managed config. Keep
    # their portable prefix/v default until the UI or installer updates it.
    key=v
    table=prefix
    add_cpcv_binding "$table" "$key" || exit 0
  fi
else
  key=v
  table=prefix
  add_cpcv_binding "$table" "$key" || exit 0
fi

command="CPCV_TMUX_PLUGIN=1 $(quote_shell "$paste_script") '#{pane_id}'"

# A cpcv compatibility binding is also ours to replace; do not mistake it for
# a user command merely because it predates the plugin marker. The legacy
# cpcv-latest form only ever belonged in root/C-v, which keeps this match
# deliberately narrow.
cpcv_owned_binding() {
  local binding=$1 binding_table=$2 binding_key=$3
  [[ "$binding" == *'CPCV_TMUX_PLUGIN=1'* || "$binding" == *'CPCV_TMUX_COMPAT=1'* ]] && return 0
  [[ "$binding_table" == root && "$binding_key" == C-v && "$binding" == *'cpcv-latest --pane'* ]]
}

# Preserve the focused upgrade path from CPCV's historic raw Ctrl-V binding to
# the safe single prefix/v fallback. If prefix/v turns out to be user-owned,
# this still releases the *cpcv-owned* legacy Ctrl-V hook so normal paste is
# not trapped forever. This exception deliberately does not apply to the
# two-binding cross-platform profile: both of its destinations must preflight
# successfully before it changes any binding.
if (( ${#binding_tables[@]} == 1 )) && [[ "${binding_tables[0]}" == prefix && "${binding_keys[0]}" == v ]]; then
  legacy_root_binding=$(tmux list-keys -T root 2>/dev/null | \
    awk '$1 == "bind-key" && $2 == "-T" && $3 == "root" && $4 == "C-v" { print; exit }' || true)
  if [[ -n "$legacy_root_binding" ]] && cpcv_owned_binding "$legacy_root_binding" root C-v; then
    tmux unbind-key -T root C-v
  fi
fi

# Check every requested destination before removing old cpcv bindings. In
# particular, the dual-platform profile must not half-install if either raw
# key belongs to the user. Explicit @cpcv-paste-* options remain a single,
# higher-priority binding and never activate the managed secondary binding.
for binding_index in "${!binding_tables[@]}"; do
  binding_table=${binding_tables[$binding_index]}
  binding_key=${binding_keys[$binding_index]}
  existing=$(tmux list-keys -T "$binding_table" 2>/dev/null | \
    awk -v table="$binding_table" -v key="$binding_key" \
      '$1 == "bind-key" && $2 == "-T" && $3 == table && $4 == key { print; exit }' || true)
  if [[ -n "$existing" ]] && ! cpcv_owned_binding "$existing" "$binding_table" "$binding_key"; then
    tmux display-message "cpcv: $binding_table/$binding_key is already bound; choose another cpcv table or key" >&2
    exit 0
  fi
done

# Remove only cpcv-owned stale root bindings after all requested destinations
# have passed collision checks. A user-owned root binding is never touched.
managed_root_keys=$(tmux list-keys -T root 2>/dev/null | \
  awk '$1 == "bind-key" && $2 == "-T" && $3 == "root" && \
    (index($0, "CPCV_TMUX_PLUGIN=1") || index($0, "CPCV_TMUX_COMPAT=1") || ($4 == "C-v" && index($0, "cpcv-latest --pane"))) { print $4 }' || true)
while IFS= read -r managed_root_key; do
  [[ -n "$managed_root_key" ]] || continue
  if ! cpcv_binding_requested root "$managed_root_key"; then
    tmux unbind-key -T root "$managed_root_key"
  fi
done <<< "$managed_root_keys"

# A UI-managed change can move between prefix/v, a custom prefix key, and raw
# Ctrl-V. Once all destinations have proved safe, discard obsolete cpcv prefix
# bindings so only the selected single binding or dual-platform pair remains.
managed_prefix_keys=$(tmux list-keys -T prefix 2>/dev/null | \
  awk '$1 == "bind-key" && $2 == "-T" && $3 == "prefix" && \
    (index($0, "CPCV_TMUX_PLUGIN=1") || index($0, "CPCV_TMUX_COMPAT=1")) { print $4 }' || true)
while IFS= read -r managed_prefix_key; do
  [[ -n "$managed_prefix_key" ]] || continue
  if ! cpcv_binding_requested prefix "$managed_prefix_key"; then
    tmux unbind-key -T prefix "$managed_prefix_key"
  fi
done <<< "$managed_prefix_keys"

for binding_index in "${!binding_tables[@]}"; do
  tmux bind-key -T "${binding_tables[$binding_index]}" "${binding_keys[$binding_index]}" \
    run-shell -b "$command"
done

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
