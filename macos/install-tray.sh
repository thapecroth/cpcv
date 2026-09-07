#!/usr/bin/env bash
# Install the optional native macOS menu-bar status companion.
set -euo pipefail
umask 077

readonly label='io.imgpaste.tray'

die() {
  printf 'imgpaste tray install: %s\n' "$*" >&2
  exit 1
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

is_managed_plist() {
  [[ -f "$1" && ! -L "$1" ]] && /usr/bin/grep -Fq 'Managed by imgpaste install-tray.sh' "$1"
}

job_loaded() {
  launchctl print "$domain/$label" >/dev/null 2>&1
}

if ! command -v swiftc >/dev/null 2>&1; then
  printf '%s\n' "imgpaste tray requires Apple's Swift compiler. Install it with: xcode-select --install" >&2
  exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
launcher="$script_dir/imgpaste-tray.sh"
controller="$script_dir/imgpaste-macos-ctl.sh"
template="$script_dir/io.imgpaste.tray.plist.template"
source_file="$script_dir/imgpaste-tray.swift"
build_dir="$script_dir/build"
tray_bin="$build_dir/imgpaste-tray"
uploader_bin="$build_dir/imgpaste-macos"
uid=$(require_macos_gui_user)
require_macos_11
domain="gui/$uid"
home_dir=${HOME:-}
[[ "$home_dir" == /* && "$home_dir" != *$'\n'* && "$home_dir" != *$'\r'* ]] || die 'HOME must be an absolute local user directory.'
launch_agents="$home_dir/Library/LaunchAgents"
plist="$launch_agents/$label.plist"

[[ -x "$launcher" && ! -L "$launcher" ]] || { printf '%s\n' "Missing safe executable launcher: $launcher" >&2; exit 1; }
[[ -x "$controller" && ! -L "$controller" ]] || { printf '%s\n' "Missing safe executable macOS controller: $controller. Install the macOS uploader first." >&2; exit 1; }
[[ -f "$template" ]] || { printf '%s\n' "Missing template: $template" >&2; exit 1; }
[[ -f "$source_file" && ! -L "$source_file" ]] || { printf '%s\n' "Missing tray source: $source_file" >&2; exit 1; }
[[ -x "$uploader_bin" && ! -L "$uploader_bin" ]] || { printf '%s\n' "Install the native macOS uploader first: $script_dir/install-macos.sh" >&2; exit 1; }
[[ ! -L "$build_dir" ]] || { printf '%s\n' "Refusing symlinked build directory: $build_dir" >&2; exit 1; }
mkdir -p "$build_dir"
chmod 700 "$build_dir"
[[ ! -L "$tray_bin" ]] || { printf '%s\n' "Refusing symlinked tray binary: $tray_bin" >&2; exit 1; }
build_tmp=$(mktemp -d "$build_dir/.imgpaste-tray-build.XXXXXX")
trap 'rm -rf -- "$build_tmp"' EXIT
swiftc -O -parse-as-library -framework AppKit "$source_file" -o "$build_tmp/imgpaste-tray"
chmod 700 "$build_tmp/imgpaste-tray"
mv -f -- "$build_tmp/imgpaste-tray" "$tray_bin"
rmdir -- "$build_tmp"
trap - EXIT
[[ ! -L "$launch_agents" ]] || die "Refusing symlinked LaunchAgents directory: $launch_agents"
existing_managed_plist=0
if [[ -e "$plist" ]]; then
  is_managed_plist "$plist" || die "Refusing to replace an unrelated LaunchAgent: $plist"
  existing_managed_plist=1
fi
if job_loaded && (( ! existing_managed_plist )); then
  die "Refusing to unload an existing $label job without this checkout's managed plist."
fi
mkdir -p "$launch_agents"
[[ ! -L "$plist" ]] || die "Refusing symlinked LaunchAgent path: $plist"
if [[ -e "$plist" ]] && ! is_managed_plist "$plist"; then
  die "Refusing to replace an unrelated LaunchAgent: $plist"
fi

# Escape only the replacement-side characters accepted by sed. The launcher
# is discovered locally, never received from controller output or config.
escaped_launcher=$(printf '%s' "$launcher" | sed 's/[\\&|]/\\&/g')
temporary=$(/usr/bin/mktemp "$launch_agents/.${label}.XXXXXX")
trap '/bin/rm -f -- "$temporary"' EXIT
sed "s|__IMGPASTE_TRAY_LAUNCHER__|$escaped_launcher|g" "$template" > "$temporary"
/usr/bin/plutil -lint "$temporary" >/dev/null || die 'Generated LaunchAgent plist is invalid.'
chmod 600 "$temporary"
if (( existing_managed_plist )) && job_loaded; then
  is_managed_plist "$plist" || die "LaunchAgent ownership changed during installation; refusing to unload $label."
  launchctl bootout "$domain/$label"
  for _ in {1..5}; do
    job_loaded || break
    /bin/sleep 1
  done
  job_loaded && die "The existing $label job did not stop."
fi
mv -f -- "$temporary" "$plist"
trap - EXIT

bootstrapped=0
for _ in {1..5}; do
  if launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
    bootstrapped=1
    break
  fi
  /bin/sleep 1
done
((bootstrapped == 1)) || die "Could not start $label in $domain."
launchctl kickstart -k "$domain/$label"
printf '%s\n' "Installed and started the optional imgpaste menu-bar companion."
printf '%s\n' "It observes the existing uploader; it does not change SSH settings or upload data during installation."
