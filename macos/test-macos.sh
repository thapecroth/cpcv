#!/usr/bin/env bash
# Run the native macOS uploader's network-free self-test.
#
# This script never calls launchctl, reads the clipboard, or contacts an SSH
# host. It validates the shell wrappers, then uses an already-built native
# executable when available or compiles a disposable test binary in mktemp.
set -euo pipefail
IFS=$'\n\t'

die() {
  printf 'imgpaste macOS test: %s\n' "$*" >&2
  exit 1
}

[[ "$(/usr/bin/uname -s)" == 'Darwin' ]] || die 'This test is for macOS.'
version=$(/usr/bin/sw_vers -productVersion)
major=${version%%.*}
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 11 ]] || die "macOS 11 or newer is required (detected: $version)."

script_path=${BASH_SOURCE[0]}
case "$script_path" in
  */*) script_parent=${script_path%/*} ;;
  *) script_parent='.' ;;
esac
script_dir=$(CDPATH= cd -P -- "$script_parent" && /bin/pwd -P)
source_file="$script_dir/imgpaste-macos.swift"
tray_source="$script_dir/imgpaste-tray.swift"

[[ -f "$source_file" && ! -L "$source_file" ]] || die "Missing native source: $source_file"
[[ -f "$tray_source" && ! -L "$tray_source" ]] || die "Missing tray source: $tray_source"

for shell_script in "$script_dir"/*.sh; do
  [[ -f "$shell_script" ]] || continue
  /bin/bash -n "$shell_script"
done

# Keep ownership guards from regressing even though this network-free suite
# intentionally does not manipulate a real user's launchd domain.
for managed_script in install-macos.sh uninstall-macos.sh install-tray.sh uninstall-tray.sh; do
  /usr/bin/grep -Fq 'Refusing to unload an existing' "$script_dir/$managed_script" || \
    die "Missing LaunchAgent ownership guard: $managed_script"
done
/usr/bin/grep -Fq 'owned_plist' "$script_dir/imgpaste-macos-ctl.sh" || \
  die 'Missing controller LaunchAgent ownership guard.'

command -v swiftc >/dev/null 2>&1 || \
  die 'Swift compiler not found. Install Xcode Command Line Tools with: xcode-select --install'
temporary_directory=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/imgpaste-macos-test.XXXXXX")
trap '/bin/rm -rf -- "$temporary_directory"' EXIT
test_binary="$temporary_directory/imgpaste-macos"
swiftc -O -framework AppKit "$source_file" -o "$test_binary"
swiftc -O -parse-as-library -framework AppKit "$tray_source" -o "$temporary_directory/imgpaste-tray"

"$test_binary" self-test
"$temporary_directory/imgpaste-tray" self-test
cp "$script_dir/imgpaste.macos.config.example.json" "$temporary_directory/config.json"
IMGPASTE_CONFIG="$temporary_directory/config.json" "$test_binary" validate-config
printf '%s\n' '{"hostAlias":"host;unsafe"}' > "$temporary_directory/invalid-config.json"
if IMGPASTE_CONFIG="$temporary_directory/invalid-config.json" "$test_binary" validate-config; then
  die 'Native configuration validation accepted a hostile host alias.'
fi
printf '%s\n' 'PASS: macOS shell wrappers and native self-test completed without launchd, clipboard, or network activity.'
