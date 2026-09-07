#!/usr/bin/env bash
# Local control surface for the native macOS cpcv uploader.
#
# This script accepts a small fixed action set. It does not parse, source, or
# evaluate JSON: configuration is handed directly to the project-owned native
# executable as a validated environment value. launchctl is always scoped to
# gui/$UID.
set -euo pipefail
IFS=$'\n\t'

readonly label='io.cpcv.guardian'
readonly status_capabilities='["status","start","stop","restart","logs","upload","config","settings-read","settings-save","doctor"]'
readonly recovery_capabilities='["status","config","settings-read","settings-save","doctor"]'

die() {
  printf 'cpcv control: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./macos/cpcv-macos-ctl.sh <action> [arguments]

Actions: status, start, stop, restart, logs, upload, config, doctor,
         settings-read, settings-save

settings-save accepts only:
  --host-alias HOST --remote-dir FOLDER --remote-home HOME --poll-interval-seconds SECONDS
USAGE
}

require_macos_gui_user() {
  [[ "$(/usr/bin/uname -s)" == 'Darwin' ]] || die 'This control script is for macOS.'
  local current_uid
  current_uid=$(/usr/bin/id -u)
  [[ "$current_uid" != '0' ]] || die 'Run this as the logged-in user, not with sudo.'
  /bin/launchctl print "gui/$current_uid" >/dev/null 2>&1 || \
    die 'No GUI launchd domain is available. Run this from the logged-in macOS desktop session.'
  printf '%s\n' "$current_uid"
}

require_macos_11() {
  local version major
  version=$(/usr/bin/sw_vers -productVersion)
  major=${version%%.*}
  [[ "$major" =~ ^[0-9]+$ && "$major" -ge 11 ]] || \
    die "macOS 11 or newer is required (detected: $version)."
}

absolute_existing_file() {
  local value=$1 directory base
  [[ "$value" == /* ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ -f "$value" && ! -L "$value" ]] || return 1
  directory=${value%/*}
  base=${value##*/}
  [[ -n "$directory" && -n "$base" ]] || return 1
  directory=$(CDPATH= cd -P -- "$directory" && /bin/pwd -P) || return 1
  printf '%s/%s\n' "$directory" "$base"
}

emit_status() {
  # Every value here is static. Never include config contents, hosts, paths,
  # subprocess output, or credentials in a fallback status response.
  local state=$1 message=$2 capabilities=${3:-$status_capabilities}
  printf '{"version":"1","mode":"macos","pid":null,"updatedAt":null,"state":"%s","lastSuccessAt":null,"lastError":"%s","activeChildPgid":null,"capabilities":%s,"latestPath":null,"lastRemotePath":null,"logFile":null,"doctorOverall":null,"doctorSummary":null,"doctorUpdatedAt":null}\n' \
    "$state" "$message" "$capabilities"
}

resolve_config() {
  local requested=${CPCV_CONFIG:-} selected=''
  if [[ -n "$requested" ]]; then
    absolute_existing_file "$requested" || return 1
    return 0
  fi

  if [[ -r "$config_pointer" ]] && [[ ! -L "$config_pointer" ]]; then
    # Bound metadata before reading it. A corrupt pointer fails closed rather
    # than becoming an arbitrary argument to the native executable.
    local pointer_bytes
    pointer_bytes=$(/usr/bin/wc -c < "$config_pointer" | /usr/bin/tr -d '[:space:]')
    if [[ "$pointer_bytes" =~ ^[0-9]+$ ]] && ((pointer_bytes > 0 && pointer_bytes <= 4096)); then
      IFS= read -r selected < "$config_pointer" || true
      if [[ "$selected" != *$'\n'* && "$selected" != *$'\r'* ]]; then
        if absolute_existing_file "$selected"; then
          return 0
        fi
      fi
    fi
  fi

  absolute_existing_file "$default_config"
}

job_loaded() {
  /bin/launchctl print "$domain/$label" >/dev/null 2>&1
}

owned_plist() {
  [[ -f "$plist" && ! -L "$plist" ]] && \
    /usr/bin/grep -Fq 'Managed by cpcv install-macos.sh' "$plist"
}

require_owned_plist() {
  [[ ! -L "$launch_agents" ]] || die "Refusing symlinked LaunchAgents directory: $launch_agents"
  owned_plist || die "LaunchAgent is not owned by this checkout. Run: $script_dir/install-macos.sh"
}

require_binary() {
  [[ -x "$executable" && ! -L "$executable" ]] || \
    die "Native executable is not installed. Run: $script_dir/install-macos.sh"
}

require_config() {
  config_file=$(resolve_config) || \
    die "Configuration is missing or unsafe. Create or repair: $default_config"
}

settings_save_arguments_are_shaped() {
  (( $# == 8 )) && \
    [[ "$1" == '--host-alias' && "$3" == '--remote-dir' && "$5" == '--remote-home' && "$7" == '--poll-interval-seconds' ]]
}

(( $# >= 1 )) || { usage >&2; exit 2; }
action=$1
shift
case "$action" in
  status|start|stop|restart|logs|upload|config|doctor|settings-read)
    (( $# == 0 )) || { usage >&2; exit 2; }
    ;;
  settings-save)
    settings_save_arguments_are_shaped "$@" || { usage >&2; exit 2; }
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

uid=$(require_macos_gui_user)
require_macos_11
domain="gui/$uid"
home_dir=${HOME:-}
[[ "$home_dir" == /* && "$home_dir" != *$'\n'* && "$home_dir" != *$'\r'* ]] || \
  die 'HOME must be an absolute local user directory.'
script_path=${BASH_SOURCE[0]}
case "$script_path" in
  */*) script_parent=${script_path%/*} ;;
  *) script_parent='.' ;;
esac
script_dir=$(CDPATH= cd -P -- "$script_parent" && /bin/pwd -P)
executable="$script_dir/build/cpcv-macos"
state_dir="$home_dir/Library/Application Support/cpcv"
default_config="$state_dir/config.json"
config_pointer="$state_dir/launchd-config-path"
launch_agents="$home_dir/Library/LaunchAgents"
plist="$launch_agents/$label.plist"

case "$action" in
  status)
    if [[ ! -x "$executable" || -L "$executable" ]]; then
      emit_status 'not-installed' 'The native cpcv executable is not installed.' "$recovery_capabilities"
      exit 0
    fi
    if ! config_file=$(resolve_config); then
      emit_status 'configuration-invalid' 'The local JSON configuration is missing or unsafe.' "$recovery_capabilities"
      exit 0
    fi
    if ! job_loaded; then
      emit_status 'stopped' 'The cpcv LaunchAgent is not loaded in this GUI session.'
      exit 0
    fi
    if ! owned_plist; then
      emit_status 'ownership-conflict' 'A same-label LaunchAgent is loaded but is not owned by this checkout.' "$recovery_capabilities"
      exit 0
    fi
    exec /usr/bin/env CPCV_CONFIG="$config_file" "$executable" status
    ;;
  start)
    require_binary
    require_config
    require_owned_plist
    if job_loaded; then
      printf '%s\n' 'cpcv service is already loaded.'
    else
      /bin/launchctl bootstrap "$domain" "$plist"
      /bin/launchctl kickstart -k "$domain/$label"
      printf '%s\n' 'Started cpcv service.'
    fi
    ;;
  stop)
    if job_loaded; then
      require_owned_plist
      /bin/launchctl bootout "$domain/$label"
      printf '%s\n' 'Stopped cpcv service. The LaunchAgent plist and all data were preserved.'
    else
      printf '%s\n' 'cpcv service is already stopped.'
    fi
    ;;
  restart)
    require_binary
    require_config
    require_owned_plist
    /bin/launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap "$domain" "$plist"
    /bin/launchctl kickstart -k "$domain/$label"
    printf '%s\n' 'Restarted cpcv service.'
    ;;
  logs)
    require_binary
    require_config
    exec /usr/bin/env CPCV_CONFIG="$config_file" "$executable" logs
    ;;
  upload)
    require_binary
    require_config
    exec /usr/bin/env CPCV_CONFIG="$config_file" "$executable" upload
    ;;
  config)
    require_config
    exec /usr/bin/open "$config_file"
    ;;
  settings-read)
    require_binary
    require_config
    exec /usr/bin/env CPCV_CONFIG="$config_file" "$executable" settings-read
    ;;
  settings-save)
    require_binary
    require_config
    native_settings_arguments=(settings-save "$@")
    /usr/bin/env CPCV_CONFIG="$config_file" "$executable" "${native_settings_arguments[@]}" >/dev/null
    if job_loaded; then
      if [[ ! -L "$launch_agents" ]] && owned_plist; then
        if /bin/launchctl kickstart -k "$domain/$label"; then
          printf '%s\n' 'Settings saved and automatic uploads restarted.'
        else
          printf '%s\n' 'Settings saved, but automatic uploads could not restart. Choose Check & Repair in the menu bar app.'
        fi
      else
        printf '%s\n' 'Settings saved. Automatic uploads were not restarted because this checkout does not own the local service.'
      fi
    else
      printf '%s\n' 'Settings saved. Automatic uploads remain paused.'
    fi
    ;;
  doctor)
    if ! config_file=$(resolve_config); then config_file=$default_config; fi
    if [[ ! -x "$executable" || -L "$executable" ]]; then
      installer="$script_dir/install-macos.sh"
      [[ -f "$installer" && ! -L "$installer" ]] || die 'The native installer is unavailable.'
      if [[ -f "$config_file" && ! -L "$config_file" ]]; then
        /bin/bash "$installer" --config "$config_file" >/dev/null
      else
        /bin/bash "$installer" >/dev/null
      fi
    fi
    require_binary
    exec /usr/bin/env CPCV_CONFIG="$config_file" "$executable" doctor
    ;;
esac
