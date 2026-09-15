#!/usr/bin/env bash
# Check or install the opt-in cpcv tmux path-insertion plugin through SSH.
#
# This deliberately owns only the remote cpcv plugin directory and
# ~/.config/cpcv/tmux-paste.conf. In particular, it never reads, sources, or
# changes ~/.tmux.conf: the printed run-shell line remains the user's choice.
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly marker='# Managed by cpcv tmux plugin'
readonly startup_line='run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux'

die() {
  printf 'cpcv remote tmux deployment: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: deploy-remote-tmux-cpcv-plugin.sh --host SSH_ALIAS [options]

Options:
  --remote-dir RELATIVE_DIR       Remote image folder (default: clipboard-images)
  --paste-table prefix|root       cpcv binding table (default: prefix)
  --paste-key KEY                 Lowercase letter/digit, or C-v (default: v)
  --paste-secondary-table root    Optional Windows binding table; requires root/M-v
  --paste-secondary-key M-v       Optional Windows Alt-V binding; requires root/C-v primary
  --action status|apply           Check only, or install/update (default: apply)
  --reload-default-server         Reload an existing default tmux server after apply
  --format text|json              Human output, or bounded machine output (default: text)

Only cpcv-owned remote files are changed. This never edits ~/.tmux.conf.
Add this user-owned line to your remote tmux configuration to load the plugin:
  run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux
USAGE
  exit 64
}

host=''
remote_dir='clipboard-images'
paste_table='prefix'
paste_key='v'
paste_secondary_table=''
paste_secondary_key=''
action='apply'
output_format='text'
reload_default_server=0
ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ConnectionAttempts=1
  -o ServerAliveInterval=3
  -o ServerAliveCountMax=2
)
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || usage; host=$2; shift 2 ;;
    --remote-dir) (($# >= 2)) || usage; remote_dir=$2; shift 2 ;;
    --paste-table) (($# >= 2)) || usage; paste_table=$2; shift 2 ;;
    --paste-key) (($# >= 2)) || usage; paste_key=$2; shift 2 ;;
    --paste-secondary-table) (($# >= 2)) || usage; paste_secondary_table=$2; shift 2 ;;
    --paste-secondary-key) (($# >= 2)) || usage; paste_secondary_key=$2; shift 2 ;;
    --action) (($# >= 2)) || usage; action=$2; shift 2 ;;
    --format) (($# >= 2)) || usage; output_format=$2; shift 2 ;;
    --reload-default-server) reload_default_server=1; shift ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

while [[ "$remote_dir" == */ ]]; do remote_dir=${remote_dir%/}; done
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die 'Host must be a simple SSH alias or user@host. Use an SSH config alias for custom ports or IPv6.'
[[ "$remote_dir" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$remote_dir" != /* && "$remote_dir" != *'..'* ]] || \
  die 'Remote directory must be a relative POSIX path without parent traversal.'
[[ "$paste_table" == prefix || "$paste_table" == root ]] || die 'Paste table must be prefix or root.'
[[ "$paste_key" =~ ^[a-z0-9]$ || "$paste_key" == C-v ]] || \
  die 'Paste key must be one lowercase letter or digit, or C-v.'
[[ "$paste_table" != root || "$paste_key" == C-v ]] || \
  die 'The managed root table supports only raw C-v.'
if [[ -n "$paste_secondary_table" || -n "$paste_secondary_key" ]]; then
  [[ "$paste_table" == root && "$paste_key" == C-v && \
     "$paste_secondary_table" == root && "$paste_secondary_key" == M-v ]] || \
    die 'The optional Windows binding must be the complete root/M-v pair with primary root/C-v.'
fi
[[ "$action" == status || "$action" == apply ]] || usage
[[ "$output_format" == text || "$output_format" == json ]] || usage

# The remote status transport is a tab-separated line made entirely of enum
# values. We never eval it or print arbitrary remote output as JSON.
remote_tmux=''
remote_plugin=''
remote_server=''
remote_binding=''
remote_secondary_binding=''
remote_override=''

validate_state_value() {
  local field=$1 value=$2
  case "$field:$value" in
    tmux:installed|tmux:missing|plugin:installed|plugin:missing|plugin:unverified|\
    server:running|server:stopped|server:unavailable|\
    binding:managed|binding:available|binding:collision|binding:pending|binding:invalid|binding:unavailable|binding:none|\
    override:none|override:explicit|override:invalid) return 0 ;;
    *) return 1 ;;
  esac
}

# Keep each SSH/SCP child addressable. If the tray's bounded Process call is
# terminated, this shell receives SIGTERM and forwards it to the active network
# child before its EXIT cleanup removes any cpcv-owned staging directory.
active_network_pid=''
temporary_output=''
stop_active_network() {
  [[ -n "$active_network_pid" ]] || return 0
  kill "$active_network_pid" >/dev/null 2>&1 || true
  wait "$active_network_pid" >/dev/null 2>&1 || true
  active_network_pid=''
}
remove_temporary_output() {
  [[ -n "$temporary_output" ]] || return 0
  /bin/rm -f -- "$temporary_output" >/dev/null 2>&1 || true
  temporary_output=''
}
on_signal() {
  stop_active_network
  remove_temporary_output
  exit 143
}
trap on_signal HUP INT TERM
run_network() {
  local status
  "$@" &
  active_network_pid=$!
  if wait "$active_network_pid"; then
    active_network_pid=''
    return 0
  else
    status=$?
    active_network_pid=''
    return "$status"
  fi
}

read_remote_state() {
  local raw record field extra response_file
  response_file=$(mktemp "${TMPDIR:-/tmp}/cpcv-tmux-ui.XXXXXX") || die 'Could not create a local tmux status file.'
  temporary_output=$response_file
  if ! run_network ssh "${ssh_options[@]}" "$host" /bin/bash -s -- "$paste_table" "$paste_key" "$paste_secondary_table" "$paste_secondary_key" > "$response_file" <<'REMOTE_STATE'
set -u
requested_table=$1
requested_key=$2
requested_secondary_table=${3:-}
requested_secondary_key=${4:-}
marker='# Managed by cpcv tmux plugin'
config="$HOME/.config/cpcv/tmux-paste.conf"
plugin="$HOME/.local/lib/cpcv/tmux/cpcv.tmux"
paste="$HOME/.local/lib/cpcv/tmux/tmux/scripts/cpcv-tmux-paste.sh"
common="$HOME/.local/lib/cpcv/tmux/tmux/scripts/cpcv-tmux-common.sh"
status="$HOME/.local/lib/cpcv/tmux/tmux/scripts/cpcv-tmux-status.sh"

managed_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && grep -Fqx "$marker" "$1"
}

canonical_tmux_key() {
  key=$1
  probe="cpcv-ui-key-probe-$$_$RANDOM"
  while tmux list-keys -T "$probe" 2>/dev/null | grep -q .; do
    probe="cpcv-ui-key-probe-$$_$RANDOM"
  done
  tmux bind-key -T "$probe" "$key" display-message CPCV_TMUX_UI_KEY_PROBE=1 >/dev/null 2>&1 || return 1
  canonical=$(tmux list-keys -T "$probe" 2>/dev/null | awk -v table="$probe" \
    '$1 == "bind-key" && $2 == "-T" && $3 == table && index($0, "CPCV_TMUX_UI_KEY_PROBE=1") { print $4; exit }')
  tmux unbind-key -T "$probe" "$key" >/dev/null 2>&1 || true
  [ -n "${canonical:-}" ] || return 1
  printf '%s' "$canonical"
}

binding_state_for() {
  local check_table=$1 check_key=$2 canonical existing
  if ! [[ "$check_table" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || \
     [[ "$check_key" == -* || "$check_key" == *[[:space:]]* || "$check_key" == *[[:cntrl:]]* ]]; then
    printf '%s' invalid
    return
  fi
  canonical=$(canonical_tmux_key "$check_key" || true)
  if [ -z "$canonical" ]; then
    printf '%s' invalid
    return
  fi
  existing=$(tmux list-keys -T "$check_table" 2>/dev/null | awk -v table="$check_table" -v key="$canonical" \
    '$1 == "bind-key" && $2 == "-T" && $3 == table && $4 == key { print; exit }')
  if [ -z "$existing" ]; then
    printf '%s' available
  elif printf '%s\n' "$existing" | grep -Fq 'CPCV_TMUX_PLUGIN=1' || \
       { [ "$check_table" = root ] && [ "$canonical" = C-v ] && printf '%s\n' "$existing" | grep -Fq 'cpcv-latest --pane'; }; then
    printf '%s' managed
  else
    printf '%s' collision
  fi
}

tmux_state=missing
plugin_state=missing
server_state=unavailable
binding_state=unavailable
secondary_binding_state=none
override_state=none
if managed_file "$config" && managed_file "$plugin" && managed_file "$paste" && \
   managed_file "$common" && managed_file "$status"; then
  plugin_state=installed
elif [ -e "$config" ] || [ -e "$plugin" ] || [ -e "$paste" ] || [ -e "$common" ] || [ -e "$status" ]; then
  plugin_state=unverified
fi

if command -v tmux >/dev/null 2>&1; then
  tmux_state=installed
  server_state=stopped
  binding_state=pending
  if [ -n "$requested_secondary_table" ]; then secondary_binding_state=pending; fi
  if tmux has-session >/dev/null 2>&1; then
    server_state=running
    configured_table=$(tmux show-options -gqv @cpcv-paste-table 2>/dev/null || true)
    configured_key=$(tmux show-options -gqv @cpcv-paste-key 2>/dev/null || true)
    effective_table=$requested_table
    effective_key=$requested_key
    if [ -n "$configured_table" ] || [ -n "$configured_key" ]; then
      override_state=explicit
      if [ -n "$configured_table" ]; then effective_table=$configured_table; else effective_table=root; fi
      if [ -n "$configured_key" ]; then effective_key=$configured_key; else effective_key=v; fi
    fi
    binding_state=$(binding_state_for "$effective_table" "$effective_key")
    if [ "$binding_state" = invalid ]; then
      override_state=invalid
    elif [ "$override_state" = none ] && [ -n "$requested_secondary_table" ]; then
      secondary_binding_state=$(binding_state_for "$requested_secondary_table" "$requested_secondary_key")
    fi
  fi
fi
printf 'CPCV_TMUX_STATE\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tmux_state" "$plugin_state" "$server_state" "$binding_state" "$secondary_binding_state" "$override_state"
REMOTE_STATE
  then
    remove_temporary_output
    die 'Could not check the remote tmux setup.'
  fi
  raw=$(< "$response_file")
  remove_temporary_output
  record=$(printf '%s\n' "$raw" | /usr/bin/grep -F $'CPCV_TMUX_STATE\t' | /usr/bin/tail -n 1 || true)
  IFS=$'\t' read -r field remote_tmux remote_plugin remote_server remote_binding remote_secondary_binding remote_override extra <<< "$record"
  [[ "$field" == CPCV_TMUX_STATE && -z "${extra:-}" ]] || die 'The remote tmux setup returned an invalid status response.'
  validate_state_value tmux "$remote_tmux" && validate_state_value plugin "$remote_plugin" && \
    validate_state_value server "$remote_server" && validate_state_value binding "$remote_binding" && \
    validate_state_value binding "$remote_secondary_binding" && \
    validate_state_value override "$remote_override" || die 'The remote tmux setup returned an invalid status value.'
}

emit_result() {
  local ok=$1 applied=$2 runtime=$3 detail=$4
  if [[ "$output_format" == json ]]; then
    # All interpolated values are local constants or allowlisted enum values.
    printf '{"ok":%s,"action":"%s","tmux":"%s","plugin":"%s","server":"%s","binding":"%s","secondaryBinding":"%s","override":"%s","applied":%s,"runtime":"%s","detail":"%s","startupLine":"%s"}\n' \
      "$ok" "$action" "$remote_tmux" "$remote_plugin" "$remote_server" "$remote_binding" "$remote_secondary_binding" "$remote_override" \
      "$applied" "$runtime" "$detail" "$startup_line"
    return
  fi
  case "$detail" in
    checked)
      if [[ "$remote_secondary_binding" == none ]]; then
        printf 'Remote tmux setup: tmux %s, plugin %s, server %s, binding %s.\n' \
          "$remote_tmux" "$remote_plugin" "$remote_server" "$remote_binding"
      else
        printf 'Remote tmux setup: tmux %s, plugin %s, server %s, primary binding %s, Windows Alt-V binding %s.\n' \
          "$remote_tmux" "$remote_plugin" "$remote_server" "$remote_binding" "$remote_secondary_binding"
      fi
      ;;
    binding-collision)
      if [[ "$applied" == true ]]; then
        printf 'The cpcv remote files were installed, but the active tmux binding belongs to another command. Choose another key before the next apply.\n'
      else
        printf 'No files were changed: the active tmux binding belongs to another command. Choose another key or resolve the user-owned @cpcv-paste-* setting.\n'
      fi
      ;;
    user-override)
      if [[ "$applied" == true ]]; then
        printf 'The cpcv remote files were installed, but an explicit user-owned @cpcv-paste-table or @cpcv-paste-key setting takes priority. Manage or remove that setting yourself before the next apply.\n'
      else
        printf 'No files were changed: an explicit user-owned @cpcv-paste-table or @cpcv-paste-key setting takes priority. Manage or remove that setting yourself before using this UI.\n'
      fi
      ;;
    reloaded)
      printf 'Remote cpcv tmux setup was installed and the running default tmux server was reloaded.\n'
      ;;
    configured-explicit-override)
      printf 'Remote cpcv tmux setup was saved and reloaded, but explicit @cpcv-paste-* options still override the UI selection.\n'
      ;;
    saved-reload-needed)
      printf 'Remote cpcv tmux setup was saved. Reload the default tmux server to use it now.\n'
      ;;
    *)
      printf 'Remote cpcv tmux setup was saved for the next tmux server.\n'
      ;;
  esac
  printf 'Add this user-owned line to your remote tmux config if it is not already there:\n%s\n' "$startup_line"
}

read_remote_state
if [[ "$action" == status ]]; then
  emit_result true false checked checked
  exit 0
fi

# A live server is the only place where we can prove that an existing binding
# is not owned by cpcv. A user-owned @cpcv-paste-* option is an explicit source
# of truth, so never stage or install a managed selection that it would hide.
if [[ "$remote_server" == running && ( "$remote_override" == explicit || "$remote_override" == invalid ) ]]; then
  emit_result false false not-applied user-override
  exit 1
fi
if [[ "$remote_server" == running && ( "$remote_binding" == collision || "$remote_binding" == invalid || \
     "$remote_secondary_binding" == collision || "$remote_secondary_binding" == invalid ) ]]; then
  emit_result false false not-applied binding-collision
  exit 1
fi

script_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
project_root=$(CDPATH= cd -P -- "$script_dir/.." && /bin/pwd -P)
plugin="$project_root/cpcv.tmux"
paste="$project_root/tmux/scripts/cpcv-tmux-paste.sh"
common="$project_root/tmux/scripts/cpcv-tmux-common.sh"
status="$project_root/tmux/scripts/cpcv-tmux-status.sh"
installer="$project_root/remote/install-tmux-cpcv-plugin.sh"
for source in "$plugin" "$paste" "$common" "$status" "$installer"; do
  [[ -f "$source" && ! -L "$source" ]] || die "Missing or unsafe tmux source: $source"
done
for source in "$plugin" "$paste" "$common" "$status"; do
  /usr/bin/grep -Fqx "$marker" "$source" || die "Unowned tmux source: $source"
done

stage_output=$(mktemp "${TMPDIR:-/tmp}/cpcv-tmux-stage.XXXXXX") || die 'Could not create a local tmux staging file.'
temporary_output=$stage_output
if ! run_network ssh "${ssh_options[@]}" "$host" 'umask 077; mktemp -d /tmp/cpcv-tmux.XXXXXX' > "$stage_output"; then
  remove_temporary_output
  die 'Could not create a remote tmux staging directory.'
fi
stage=$(< "$stage_output")
remove_temporary_output
[[ "$stage" =~ ^/tmp/cpcv-tmux\.[A-Za-z0-9]+$ ]] || die 'Remote staging path was invalid.'
cleanup() {
  run_network ssh "${ssh_options[@]}" "$host" "find '$stage' -depth -delete" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_network scp "${ssh_options[@]}" "$plugin" "$paste" "$common" "$status" "$installer" "$host:$stage/"
installer_arguments="--remote-dir '$remote_dir' --paste-table '$paste_table' --paste-key '$paste_key'"
if [[ -n "$paste_secondary_table" ]]; then
  installer_arguments+=" --paste-secondary-table '$paste_secondary_table' --paste-secondary-key '$paste_secondary_key'"
fi
run_network ssh "${ssh_options[@]}" "$host" \
  "CPCV_STAGE_DIR='$stage' /usr/bin/env bash '$stage/install-tmux-cpcv-plugin.sh' $installer_arguments >/dev/null"

runtime=saved-next-server
if ((reload_default_server)) && [[ "$remote_server" == running ]]; then
  reload_file=$(mktemp "${TMPDIR:-/tmp}/cpcv-tmux-reload.XXXXXX") || die 'Could not create a local tmux reload file.'
  temporary_output=$reload_file
  if ! run_network ssh "${ssh_options[@]}" "$host" /bin/bash -s > "$reload_file" <<'REMOTE_RELOAD'
set -u
if command -v tmux >/dev/null 2>&1 && tmux has-session >/dev/null 2>&1; then
  tmux run-shell "$HOME/.local/lib/cpcv/tmux/cpcv.tmux"
  printf 'CPCV_TMUX_RELOAD\treloaded\n'
else
  printf 'CPCV_TMUX_RELOAD\tskipped\n'
fi
REMOTE_RELOAD
  then
    remove_temporary_output
    die 'The remote tmux server could not be reloaded.'
  fi
  reload_output=$(< "$reload_file")
  remove_temporary_output
  reload_record=$(printf '%s\n' "$reload_output" | /usr/bin/grep -F $'CPCV_TMUX_RELOAD\t' | /usr/bin/tail -n 1 || true)
  [[ "$reload_record" == $'CPCV_TMUX_RELOAD\treloaded' ]] && runtime=reloaded
fi
trap - EXIT
cleanup

read_remote_state
if [[ "$remote_server" == running && ( "$remote_override" == explicit || "$remote_override" == invalid ) ]]; then
  emit_result false true reload-failed user-override
  exit 1
fi
if [[ "$remote_server" == running && ( "$remote_binding" == collision || "$remote_binding" == invalid || \
     "$remote_secondary_binding" == collision || "$remote_secondary_binding" == invalid ) ]]; then
  emit_result false true reload-failed binding-collision
  exit 1
fi
if [[ "$runtime" == reloaded ]]; then
  emit_result true true reloaded reloaded
elif [[ "$remote_server" == running ]]; then
  emit_result true true saved-reload-needed saved-reload-needed
else
  emit_result true true saved-next-server saved-next-server
fi
