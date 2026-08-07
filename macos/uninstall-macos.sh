#!/usr/bin/env bash
# Remove only imgpaste's per-user macOS LaunchAgent.
# Data, configuration, cached images, logs, and the compiled executable remain
# in place so a future install can resume without losing user-owned settings.
set -euo pipefail
IFS=$'\n\t'

readonly label='io.imgpaste.guardian'

die() {
  printf 'imgpaste uninstall: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' 'Usage: ./macos/uninstall-macos.sh'
}

require_macos_gui_user() {
  [[ "$(/usr/bin/uname -s)" == 'Darwin' ]] || die 'This uninstaller is for macOS.'
  local current_uid
  current_uid=$(/usr/bin/id -u)
  [[ "$current_uid" != '0' ]] || die 'Run this as the logged-in user, not with sudo.'
  /bin/launchctl print "gui/$current_uid" >/dev/null 2>&1 || \
    die 'No GUI launchd domain is available. Run this from the logged-in macOS desktop session.'
  printf '%s\n' "$current_uid"
}

if (($#)); then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
fi

uid=$(require_macos_gui_user)
domain="gui/$uid"
home_dir=${HOME:-}
[[ "$home_dir" == /* && "$home_dir" != *$'\n'* && "$home_dir" != *$'\r'* ]] || \
  die 'HOME must be an absolute local user directory.'
launch_agents="$home_dir/Library/LaunchAgents"
[[ ! -L "$launch_agents" ]] || die "Refusing symlinked LaunchAgents directory: $launch_agents"
plist="$launch_agents/$label.plist"

is_managed_plist() {
  [[ -f "$1" && ! -L "$1" ]] && /usr/bin/grep -Fq 'Managed by imgpaste install-macos.sh' "$1"
}

job_loaded() {
  /bin/launchctl print "$domain/$label" >/dev/null 2>&1
}

# Do not delete a file that this installer did not create. This also protects
# a user who deliberately reuses the label for a different LaunchAgent.
if [[ -L "$plist" ]]; then
  die "Refusing symlinked LaunchAgent path: $plist"
fi
if [[ -e "$plist" ]] && ! is_managed_plist "$plist"; then
  die "Refusing to remove an unrelated LaunchAgent: $plist"
fi

if job_loaded; then
  is_managed_plist "$plist" || die "Refusing to unload an existing $label job without this checkout's managed plist."
  /bin/launchctl bootout "$domain/$label"
fi
if [[ -e "$plist" ]]; then
  /bin/rm -f -- "$plist"
fi

printf '%s\n' 'Removed the imgpaste LaunchAgent from this GUI session.'
printf '%s\n' 'Preserved configuration, logs, cache, and the compiled executable.'
