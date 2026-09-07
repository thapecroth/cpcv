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
for remote_script in "$script_dir/../remote"/*.sh; do
  [[ -f "$remote_script" ]] || continue
  /bin/bash -n "$remote_script"
done
remote_installer="$script_dir/../remote/install-codex-x11-bridge.sh"
remote_uninstaller="$script_dir/../remote/uninstall-codex-x11-bridge.sh"
[[ -f "$remote_installer" && ! -L "$remote_installer" ]] || die 'Missing remote bridge installer.'
[[ -f "$remote_uninstaller" && ! -L "$remote_uninstaller" ]] || die 'Missing remote bridge uninstaller.'
/usr/bin/grep -Fq '(( ! $+aliases[codex] && ! $+galiases[codex] ))' "$remote_installer" || \
  die 'Remote bridge installer does not reject a codex zsh alias.'
/usr/bin/grep -Fq 'verify_ownership_manifest' "$remote_installer" || \
  die 'Remote bridge installer does not verify existing managed files.'
/usr/bin/grep -Fq 'verify_ownership_manifest || die "Refusing to remove unverified managed file: $path"' "$remote_uninstaller" || \
  die 'Remote bridge uninstaller can unlink unverified regular files.'
/usr/bin/grep -Fq 'unlink_owned_file "$path"' "$remote_uninstaller" || \
  die 'Remote bridge uninstaller does not use its ownership guard.'
/usr/bin/grep -Fq 'preflight_zsh_alias "$zsh_path"' "$remote_installer" || \
  die 'Remote bridge installer does not preflight zsh aliases.'
/usr/bin/grep -Fq 'remove_zsh_block "$zshrc"' "$remote_installer" || \
  die 'Remote bridge installer does not replace its zsh block.'
/usr/bin/grep -Fq 'mkdir -p -- "$directory"' "$remote_installer" || \
  die 'Remote bridge installer is missing its directory setup step.'
preflight_line=$(/usr/bin/grep -nF 'preflight_zsh_alias "$zsh_path"' "$remote_installer" | /usr/bin/sed -n '1s/:.*//p')
remove_line=$(/usr/bin/grep -nF 'remove_zsh_block "$zshrc"' "$remote_installer" | /usr/bin/sed -n '1s/:.*//p')
first_mutation_line=$(/usr/bin/grep -nF 'mkdir -p -- "$directory"' "$remote_installer" | /usr/bin/sed -n '1s/:.*//p')
[[ "$preflight_line" =~ ^[0-9]+$ && "$remove_line" =~ ^[0-9]+$ && "$first_mutation_line" =~ ^[0-9]+$ && \
   "$preflight_line" -lt "$remove_line" && "$preflight_line" -lt "$first_mutation_line" ]] || \
  die 'Remote bridge zsh alias preflight must precede all file or zshrc mutation.'

# Keep ownership guards from regressing even though this network-free suite
# intentionally does not manipulate a real user's launchd domain.
for managed_script in install-macos.sh uninstall-macos.sh install-tray.sh uninstall-tray.sh; do
  /usr/bin/grep -Fq 'Refusing to unload an existing' "$script_dir/$managed_script" || \
    die "Missing LaunchAgent ownership guard: $managed_script"
done
/usr/bin/grep -Fq 'owned_plist' "$script_dir/imgpaste-macos-ctl.sh" || \
  die 'Missing controller LaunchAgent ownership guard.'
/usr/bin/grep -Fq 'config|doctor' "$script_dir/imgpaste-macos-ctl.sh" || \
  die 'Controller does not expose Doctor as a recovery capability.'
/usr/bin/grep -Fq 'settings-read' "$script_dir/imgpaste-macos-ctl.sh" && \
  /usr/bin/grep -Fq 'settings-save' "$script_dir/imgpaste-macos-ctl.sh" || \
  die 'Controller does not expose the structured settings actions.'
/usr/bin/grep -Fq 'native_settings_arguments' "$script_dir/imgpaste-macos-ctl.sh" || \
  die 'Controller does not preserve settings in an argument array.'
/usr/bin/grep -Fq 'launchctl kickstart -k' "$script_dir/imgpaste-macos-ctl.sh" || \
  die 'Controller does not reload an active uploader after settings save.'
/usr/bin/grep -Fq 'Check & Repair' "$tray_source" || \
  die 'Tray does not expose the compact Doctor action.'
/usr/bin/grep -Fq 'SettingsFormView' "$tray_source" || \
  die 'Tray does not expose the native settings form.'
/usr/bin/grep -Fq 'getppid() == guardianPID' "$script_dir/imgpaste-macos.swift" || \
  die 'Watcher does not exit when its guardian exits.'
/usr/bin/grep -Fq '/bin/sleep 1' "$script_dir/install-macos.sh" || \
  die 'Installer does not wait for a replaced guardian to exit.'
/usr/bin/grep -Fq 'bootstrapped=0' "$script_dir/install-tray.sh" && \
  /usr/bin/grep -Fq 'launchctl kickstart -k "$domain/$label"' "$script_dir/install-tray.sh" || \
  die 'Tray installer does not retry and confirm its LaunchAgent startup.'
for plist_template in "$script_dir/io.imgpaste.guardian.plist.template" "$script_dir/io.imgpaste.tray.plist.template"; do
  /usr/bin/plutil -lint "$plist_template" >/dev/null || die "Invalid LaunchAgent plist: $plist_template"
  template_path=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:PATH' "$plist_template" 2>/dev/null || true)
  [[ "$template_path" == '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin' ]] || \
    die "LaunchAgent PATH does not include standard Homebrew locations: $plist_template"
done

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
settings_config="$temporary_directory/settings-config.json"
printf '%s\n' '{"hostAlias":"old-host","remoteDir":"old-images","remoteHome":"","pollIntervalSeconds":2,"futureSetting":{"keep":true}}' > "$settings_config"
settings_read="$temporary_directory/settings-read.json"
IMGPASTE_CONFIG="$settings_config" "$test_binary" settings-read > "$settings_read"
/usr/bin/grep -Fq '"hostAlias":"old-host"' "$settings_read" || \
  die 'Native settings read did not return the configured SSH target.'
IMGPASTE_CONFIG="$settings_config" "$test_binary" settings-save \
  --host-alias 'me@work-server' --remote-dir 'images/clipboard' --remote-home '/srv/imgpaste' \
  --poll-interval-seconds 7 >/dev/null
IMGPASTE_CONFIG="$settings_config" "$test_binary" validate-config
/usr/bin/grep -Fq '"hostAlias":"me@work-server"' "$settings_config" || \
  die 'Native settings save did not update the SSH target.'
/usr/bin/grep -Fq '"futureSetting":{"keep":true}' "$settings_config" || \
  die 'Native settings save did not preserve an unrelated JSON setting.'
if IMGPASTE_CONFIG="$settings_config" "$test_binary" settings-save \
  --host-alias 'host;unsafe' --remote-dir 'images' --remote-home '' --poll-interval-seconds 2 2>/dev/null; then
  die 'Native settings save accepted a hostile SSH target.'
fi
/usr/bin/grep -Fq '"hostAlias":"me@work-server"' "$settings_config" || \
  die 'Failed native settings save changed the existing configuration.'
[[ "$(/usr/bin/stat -f '%Lp' "$settings_config")" == '600' ]] || \
  die 'Native settings save did not keep the configuration private.'
/bin/ln -s "$settings_config" "$temporary_directory/settings-link.json"
if IMGPASTE_CONFIG="$temporary_directory/settings-link.json" "$test_binary" settings-read >/dev/null 2>&1; then
  die 'Native settings read accepted a symlinked configuration file.'
fi
invalid_advanced_config="$temporary_directory/invalid-advanced-settings.json"
printf '%s\n' '{"hostAlias":"old-host","remoteDir":"old-images","remoteHome":"","pollIntervalSeconds":2,"commandTimeoutSeconds":601}' > "$invalid_advanced_config"
if IMGPASTE_CONFIG="$invalid_advanced_config" "$test_binary" settings-save \
  --host-alias 'new-host' --remote-dir 'images' --remote-home '' --poll-interval-seconds 2 2>/dev/null; then
  die 'Native settings save accepted an unrelated invalid configuration value.'
fi
/usr/bin/grep -Fq '"hostAlias":"old-host"' "$invalid_advanced_config" || \
  die 'Failed native settings save changed a configuration with an invalid advanced value.'
printf '%s\n' 'PASS: macOS shell wrappers and native self-test completed without launchd, clipboard, or network activity.'
