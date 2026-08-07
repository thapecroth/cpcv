#!/usr/bin/env bash
# Remove only the optional macOS menu-bar companion for this checkout.
set -euo pipefail

readonly label='io.imgpaste.tray'

die() {
  printf 'imgpaste tray uninstall: %s\n' "$*" >&2
  exit 1
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

uid=$(require_macos_gui_user)
domain="gui/$uid"
home_dir=${HOME:-}
[[ "$home_dir" == /* && "$home_dir" != *$'\n'* && "$home_dir" != *$'\r'* ]] || die 'HOME must be an absolute local user directory.'
launch_agents="$home_dir/Library/LaunchAgents"
[[ ! -L "$launch_agents" ]] || die "Refusing symlinked LaunchAgents directory: $launch_agents"
plist="$launch_agents/$label.plist"
if [[ -L "$plist" ]]; then die "Refusing symlinked LaunchAgent path: $plist"; fi
is_managed_plist() {
  [[ -f "$1" && ! -L "$1" ]] && /usr/bin/grep -Fq 'Managed by imgpaste install-tray.sh' "$1"
}
job_loaded() {
  launchctl print "$domain/$label" >/dev/null 2>&1
}
if [[ -e "$plist" ]] && ! is_managed_plist "$plist"; then
  die "Refusing to remove an unrelated LaunchAgent: $plist"
fi
if job_loaded; then
  is_managed_plist "$plist" || die "Refusing to unload an existing $label job without this checkout's managed plist."
  launchctl bootout "$domain/$label"
fi
if [[ -e "$plist" ]]; then rm -f -- "$plist"; fi
printf '%s\n' "Removed the optional imgpaste menu-bar companion. The uploader service and its data were preserved."
