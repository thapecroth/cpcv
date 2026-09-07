#!/usr/bin/env bash
# Remove only remote files and user units owned by the Codex X11 bridge.
set -euo pipefail
IFS=$'\n\t'

readonly display_unit='io.cpcv.codex-x11.service'
readonly bridge_unit='io.cpcv.codex-x11-bridge.service'
readonly marker='# Managed by cpcv install-codex-x11-bridge.sh'

die() {
  printf 'cpcv Codex X11 uninstall: %s\n' "$*" >&2
  exit 1
}

managed_unit() {
  local file=$1
  [[ -f "$file" && ! -L "$file" ]] && grep -Fqx "$marker" "$file"
}

file_hash() {
  local result
  result=$(/usr/bin/sha256sum -- "$1") || return 1
  [[ "$result" =~ ^([0-9a-f]{64})[[:space:]] ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

verify_managed_file() {
  local path=$1 expected=$2 actual
  [[ ! -L "$path" ]] || return 1
  [[ ! -e "$path" ]] && return 0
  [[ -f "$path" ]] || return 1
  actual=$(file_hash "$path") || return 1
  [[ "$actual" == "$expected" ]]
}

verify_ownership_manifest() (
  local line='' key='' value=''
  local bridge_hash='' test_hash='' uninstaller_hash='' config_hash='' authority_hash=''
  [[ -f "$ownership" && ! -L "$ownership" ]] || exit 1
  exec 3< "$ownership" || exit 1
  IFS= read -r line <&3 || exit 1
  [[ "$line" == "$marker" ]] || exit 1
  while :; do
    key=''
    value=''
    if ! IFS='=' read -r key value <&3; then
      [[ -z "$key" ]] && break
    fi
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || exit 1
    case "$key" in
      bridge) [[ -z "$bridge_hash" ]] || exit 1; bridge_hash=$value ;;
      test) [[ -z "$test_hash" ]] || exit 1; test_hash=$value ;;
      uninstaller) [[ -z "$uninstaller_hash" ]] || exit 1; uninstaller_hash=$value ;;
      config) [[ -z "$config_hash" ]] || exit 1; config_hash=$value ;;
      authority) [[ -z "$authority_hash" ]] || exit 1; authority_hash=$value ;;
      *) exit 1 ;;
    esac
  done
  [[ -n "$bridge_hash" && -n "$test_hash" && -n "$uninstaller_hash" && \
     -n "$config_hash" && -n "$authority_hash" ]] || exit 1
  verify_managed_file "$bridge" "$bridge_hash" || exit 1
  verify_managed_file "$test_script" "$test_hash" || exit 1
  verify_managed_file "$uninstaller" "$uninstaller_hash" || exit 1
  verify_managed_file "$config" "$config_hash" || exit 1
  verify_managed_file "$authority" "$authority_hash" || exit 1
)

managed_payload_exists() {
  local path
  for path in "$bridge" "$test_script" "$uninstaller" "$config" "$authority" "$ownership"; do
    [[ -L "$path" || -e "$path" ]] && return 0
  done
  return 1
}

unlink_owned_unit() {
  local path=$1
  [[ ! -L "$path" ]] || die "Refusing symlinked managed path: $path"
  [[ ! -e "$path" ]] && return 0
  managed_unit "$path" || die "Refusing to remove unrelated unit: $path"
  /usr/bin/unlink -- "$path"
}

unlink_owned_file() {
  local path=$1
  [[ ! -L "$path" ]] || die "Refusing symlinked managed path: $path"
  [[ ! -e "$path" ]] && return 0
  verify_ownership_manifest || die "Refusing to remove unverified managed file: $path"
  /usr/bin/unlink -- "$path"
}

remove_zsh_block() {
  local zshrc=$1 temporary mode starts ends
  [[ ! -L "$zshrc" ]] || die "Refusing symlinked zshrc: $zshrc"
  [[ -e "$zshrc" ]] || return 0
  [[ -f "$zshrc" ]] || die "Refusing to modify non-regular zshrc: $zshrc"
  starts=$(grep -Fxc '# >>> cpcv Codex X11 >>>' "$zshrc" || true)
  ends=$(grep -Fxc '# <<< cpcv Codex X11 <<<' "$zshrc" || true)
  [[ "$starts" == "$ends" && "$starts" -le 1 ]] || die 'Refusing malformed cpcv Codex X11 zshrc markers.'
  [[ "$starts" == 1 ]] || return 0
  mode=$(stat -c '%a' "$zshrc")
  temporary=$(mktemp "${zshrc%/*}/.${zshrc##*/}.XXXXXX")
  awk '
    /^# >>> cpcv Codex X11 >>>$/ { dropping = 1; next }
    /^# <<< cpcv Codex X11 <<<$/{ dropping = 0; next }
    !dropping { print }
  ' "$zshrc" > "$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$zshrc"
}

[[ $# -eq 0 ]] || die 'This uninstaller accepts no arguments.'
[[ "$HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'HOME must be a simple absolute POSIX path.'

unit_dir="$HOME/.config/systemd/user"
library_dir="$HOME/.local/lib/cpcv"
config_dir="$HOME/.config/cpcv"
state_dir="$HOME/.local/state/cpcv/codex-x11"
display_file="$unit_dir/$display_unit"
bridge_file="$unit_dir/$bridge_unit"
config="$config_dir/codex-x11.conf"
authority="$state_dir/Xauthority"
bridge="$library_dir/cpcv-codex-x11-bridge"
test_script="$library_dir/cpcv-codex-x11-test"
uninstaller="$library_dir/cpcv-codex-x11-uninstall"
ownership="$state_dir/codex-x11.manifest"

if managed_payload_exists && ! verify_ownership_manifest; then
  die 'Refusing to remove unverified managed bridge files.'
fi
for unit_file in "$display_file" "$bridge_file"; do
  if [[ -e "$unit_file" ]]; then
    managed_unit "$unit_file" || die "Refusing to remove unrelated unit: $unit_file"
  fi
done
for unit in "$bridge_unit" "$display_unit"; do
  if /usr/bin/systemctl --user is-active --quiet "$unit"; then
    [[ -f "$unit_dir/$unit" ]] && managed_unit "$unit_dir/$unit" || \
      die "Refusing to stop unrelated active unit: $unit"
    /usr/bin/systemctl --user disable --now "$unit"
  elif [[ -f "$unit_dir/$unit" ]]; then
    /usr/bin/systemctl --user disable "$unit" >/dev/null 2>&1 || true
  fi
done

for path in "$display_file" "$bridge_file"; do
  unlink_owned_unit "$path"
done
for path in "$config" "$authority" "$bridge" "$test_script" "$uninstaller" "$ownership"; do
  unlink_owned_file "$path"
done
/usr/bin/systemctl --user daemon-reload
remove_zsh_block "$HOME/.zshrc"

for directory in "$state_dir" "$library_dir"; do
  [[ ! -L "$directory" ]] || die "Refusing symlinked managed directory: $directory"
  rmdir "$directory" 2>/dev/null || true
done
printf 'Removed cpcv Codex X11 bridge services and managed shell integration.\n'
