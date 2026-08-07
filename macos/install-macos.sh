#!/usr/bin/env bash
# Build and install the per-user macOS imgpaste guardian.
#
# This installer intentionally uses a LaunchAgent in the current user's GUI
# launchd domain. It never evaluates configuration as shell code: the native
# executable receives a fixed argument vector and one validated environment
# value containing the JSON file path.
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly label='io.imgpaste.guardian'

die() {
  printf 'imgpaste install: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./macos/install-macos.sh [--config /absolute/path/config.json] [--no-start]

Builds macos/imgpaste-macos.swift into macos/build/imgpaste-macos, creates a
private default configuration when needed, and installs a LaunchAgent in the
current logged-in user's GUI launchd domain. Existing data and configuration
are never replaced.
USAGE
}

require_macos_gui_user() {
  [[ "$(/usr/bin/uname -s)" == 'Darwin' ]] || die 'This installer is for macOS.'
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

xml_escape() {
  # Emit XML character data without invoking an interpreter or a shell.
  local value=$1 character index
  for ((index = 0; index < ${#value}; index += 1)); do
    character=${value:index:1}
    case "$character" in
      '&') printf '&amp;' ;;
      '<') printf '&lt;' ;;
      '>') printf '&gt;' ;;
      '"') printf '&quot;' ;;
      "'") printf '&apos;' ;;
      *) printf '%s' "$character" ;;
    esac
  done
}

write_plist() {
  local template=$1 output=$2 executable=$3 config_file=$4 project_root=$5 log_file=$6
  local executable_xml config_xml root_xml log_xml line
  executable_xml=$(xml_escape "$executable")
  config_xml=$(xml_escape "$config_file")
  root_xml=$(xml_escape "$project_root")
  log_xml=$(xml_escape "$log_file")

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *'__IMGPASTE_EXECUTABLE__'*) printf '    <string>%s</string>\n' "$executable_xml" ;;
      *'__IMGPASTE_CONFIG__'*) printf '    <string>%s</string>\n' "$config_xml" ;;
      *'__IMGPASTE_PROJECT_ROOT__'*) printf '  <string>%s</string>\n' "$root_xml" ;;
      *'__IMGPASTE_LAUNCHD_LOG__'*) printf '  <string>%s</string>\n' "$log_xml" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$template" > "$output"
}

is_managed_plist() {
  local candidate=$1
  [[ -f "$candidate" && ! -L "$candidate" ]] && \
    /usr/bin/grep -Fq 'Managed by imgpaste install-macos.sh' "$candidate"
}

job_loaded() {
  /bin/launchctl print "$domain/$label" >/dev/null 2>&1
}

config_override=${IMGPASTE_CONFIG:-}
start_after_install=1
while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || die '--config requires an absolute path.'
      config_override=$2
      shift 2
      ;;
    --no-start)
      start_after_install=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

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
project_root=$(CDPATH= cd -P -- "$script_dir/.." && /bin/pwd -P)
source_file="$script_dir/imgpaste-macos.swift"
template="$script_dir/io.imgpaste.guardian.plist.template"
example_config="$script_dir/imgpaste.macos.config.example.json"
build_dir="$script_dir/build"
executable="$build_dir/imgpaste-macos"
app_support="$home_dir/Library/Application Support"
state_dir="$app_support/imgpaste"
default_config="$state_dir/config.json"
config_pointer="$state_dir/launchd-config-path"
launch_agents="$home_dir/Library/LaunchAgents"
plist="$launch_agents/$label.plist"
launchd_log="$state_dir/launchd.log"

[[ -f "$source_file" ]] || die "Missing native source: $source_file"
[[ -f "$template" ]] || die "Missing LaunchAgent template: $template"
[[ -f "$example_config" ]] || die "Missing configuration example: $example_config"
command -v swiftc >/dev/null 2>&1 || \
  die 'Swift compiler not found. Install Xcode Command Line Tools with: xcode-select --install'

# A label is global within a GUI launchd domain. Do not unload a job merely
# because it happens to use imgpaste's label; prove this checkout owns the
# on-disk plist before replacing or booting out anything.
[[ ! -L "$launch_agents" ]] || die "Refusing symlinked LaunchAgents directory: $launch_agents"
existing_managed_plist=0
if [[ -e "$plist" ]]; then
  is_managed_plist "$plist" || die "Refusing to replace an unrelated LaunchAgent: $plist"
  existing_managed_plist=1
fi
if job_loaded && (( ! existing_managed_plist )); then
  die "Refusing to unload an existing $label job without this checkout's managed plist."
fi

[[ ! -L "$state_dir" ]] || die "Refusing symlinked data directory: $state_dir"
/bin/mkdir -p -- "$state_dir"
/bin/chmod 700 "$state_dir"
[[ ! -L "$launchd_log" ]] || die "Refusing symlinked launchd log path: $launchd_log"

if [[ -n "$config_override" ]]; then
  config_file=$(absolute_existing_file "$config_override") || \
    die 'IMGPASTE_CONFIG/--config must name an existing, non-symlinked absolute JSON file.'
else
  if [[ ! -e "$default_config" ]]; then
    /usr/bin/install -m 600 "$example_config" "$default_config"
    printf 'Created private configuration template: %s\n' "$default_config"
  fi
  config_file=$(absolute_existing_file "$default_config") || \
    die "Default configuration is not a regular file: $default_config"
fi
/bin/chmod 600 "$config_file"

# Record the selected config path for the local control script. It is metadata,
# not configuration, and lets a tray launched later find an explicit override.
pointer_tmp=$(/usr/bin/mktemp "$state_dir/.launchd-config-path.XXXXXX")
trap '/bin/rm -f -- "$pointer_tmp"' EXIT
printf '%s\n' "$config_file" > "$pointer_tmp"
/bin/chmod 600 "$pointer_tmp"
/bin/mv -f -- "$pointer_tmp" "$config_pointer"
trap - EXIT

[[ ! -L "$build_dir" ]] || die "Refusing symlinked build directory: $build_dir"
/bin/mkdir -p -- "$build_dir"
/bin/chmod 700 "$build_dir"
[[ ! -L "$executable" ]] || die "Refusing symlinked executable path: $executable"
build_tmp=$(/usr/bin/mktemp -d "$build_dir/.imgpaste-build.XXXXXX")
trap '/bin/rm -rf -- "$build_tmp"' EXIT
swiftc -O -framework AppKit "$source_file" -o "$build_tmp/imgpaste-macos"
[[ -x "$build_tmp/imgpaste-macos" ]] || die 'Swift compilation did not produce an executable.'
"$build_tmp/imgpaste-macos" self-test >/dev/null
/bin/chmod 700 "$build_tmp/imgpaste-macos"
/bin/mv -f -- "$build_tmp/imgpaste-macos" "$executable"
/bin/rmdir -- "$build_tmp"
trap - EXIT

[[ ! -L "$plist" ]] || die "Refusing symlinked LaunchAgent path: $plist"
[[ ! -L "$launch_agents" ]] || die "Refusing symlinked LaunchAgents directory: $launch_agents"
/bin/mkdir -p -- "$launch_agents"
if [[ -e "$plist" ]] && ! is_managed_plist "$plist"; then
  die "Refusing to replace an unrelated LaunchAgent: $plist"
fi
plist_tmp=$(/usr/bin/mktemp "$launch_agents/.${label}.XXXXXX")
trap '/bin/rm -f -- "$plist_tmp"' EXIT
write_plist "$template" "$plist_tmp" "$executable" "$config_file" "$project_root" "$launchd_log"
/usr/bin/plutil -lint "$plist_tmp" >/dev/null || die 'Generated LaunchAgent plist is invalid.'
/bin/chmod 600 "$plist_tmp"

# Only an already verified managed label in this user's GUI bootstrap
# namespace is ever unloaded. A new/colliding label is left untouched.
if (( existing_managed_plist )) && job_loaded; then
  is_managed_plist "$plist" || die "LaunchAgent ownership changed during installation; refusing to unload $label."
  /bin/launchctl bootout "$domain/$label"
fi
/bin/mv -f -- "$plist_tmp" "$plist"
trap - EXIT

if ((start_after_install)); then
  /bin/launchctl bootstrap "$domain" "$plist"
  /bin/launchctl kickstart -k "$domain/$label"
  printf 'Installed and started %s in %s.\n' "$label" "$domain"
else
  printf 'Installed %s in %s (not started).\n' "$label" "$domain"
fi
printf 'Native executable: %s\nConfiguration: %s\n' "$executable" "$config_file"
