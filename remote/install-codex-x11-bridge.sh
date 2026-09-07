#!/usr/bin/env bash
# Install a per-user Xvfb and image clipboard publisher for native Codex paste.
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly display_unit='io.imgpaste.codex-x11.service'
readonly bridge_unit='io.imgpaste.codex-x11-bridge.service'
readonly marker='# Managed by imgpaste install-codex-x11-bridge.sh'

die() {
  printf 'imgpaste Codex X11 setup: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: install-codex-x11-bridge.sh --remote-dir RELATIVE_DIR [--display :98] [--enable-zsh]

Installs an explicit per-user Xvfb display and an X11 image clipboard bridge.
--enable-zsh adds a managed block to ~/.zshrc so new interactive shells use it.
USAGE
  exit 64
}

safe_remote_dir() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != /* && "$1" != *'..'* ]]
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

write_file() {
  local destination=$1 mode=$2
  local directory temporary
  directory=${destination%/*}
  temporary=$(mktemp "$directory/.${destination##*/}.XXXXXX")
  trap '[[ -n "${temporary:-}" ]] && /usr/bin/unlink "$temporary" 2>/dev/null || true' RETURN
  cat > "$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$destination"
  temporary=""
  trap - RETURN
}

write_ownership_manifest() {
  local bridge_hash test_hash uninstaller_hash config_hash authority_hash
  bridge_hash=$(file_hash "$bridge") || die 'Could not verify installed bridge script.'
  test_hash=$(file_hash "$test_script") || die 'Could not verify installed bridge test script.'
  uninstaller_hash=$(file_hash "$uninstaller") || die 'Could not verify installed bridge uninstaller.'
  config_hash=$(file_hash "$config") || die 'Could not verify installed bridge configuration.'
  authority_hash=$(file_hash "$authority") || die 'Could not verify installed Xauthority file.'
  write_file "$ownership" 600 <<EOF
$marker
bridge=$bridge_hash
test=$test_hash
uninstaller=$uninstaller_hash
config=$config_hash
authority=$authority_hash
EOF
}

remove_zsh_block() {
  local zshrc=$1 temporary mode starts ends
  [[ ! -L "$zshrc" ]] || die "Refusing symlinked zshrc: $zshrc"
  [[ -e "$zshrc" ]] || return 0
  [[ -f "$zshrc" && ! -L "$zshrc" ]] || die "Refusing to modify non-regular zshrc: $zshrc"
  starts=$(grep -Fxc '# >>> imgpaste Codex X11 >>>' "$zshrc" || true)
  ends=$(grep -Fxc '# <<< imgpaste Codex X11 <<<' "$zshrc" || true)
  [[ "$starts" == "$ends" && "$starts" -le 1 ]] || die 'Refusing malformed imgpaste Codex X11 zshrc markers.'
  mode=$(stat -c '%a' "$zshrc")
  temporary=$(mktemp "${zshrc%/*}/.${zshrc##*/}.XXXXXX")
  awk '
    /^# >>> imgpaste Codex X11 >>>$/ { dropping = 1; next }
    /^# <<< imgpaste Codex X11 <<<$/{ dropping = 0; next }
    !dropping { print }
  ' "$zshrc" > "$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$zshrc"
}

preflight_zsh_alias() {
  local zsh_path=$1
  "$zsh_path" -ic '(( ! $+aliases[codex] && ! $+galiases[codex] ))' >/dev/null 2>&1 || \
    die 'Refusing to modify ~/.zshrc because zsh defines an alias named codex.'
}

stage_dir=${IMGPASTE_STAGE_DIR:-}
remote_dir=''
display=':98'
enable_zsh=0
while (($#)); do
  case "$1" in
    --remote-dir) (($# >= 2)) || usage; remote_dir=$2; shift 2 ;;
    --display) (($# >= 2)) || usage; display=$2; shift 2 ;;
    --enable-zsh) enable_zsh=1; shift ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

while [[ "$remote_dir" == */ ]]; do remote_dir=${remote_dir%/}; done
[[ -n "$stage_dir" && "$stage_dir" == /* && -d "$stage_dir" && ! -L "$stage_dir" ]] || \
  die 'IMGPASTE_STAGE_DIR must name a regular staged directory.'
safe_remote_dir "$remote_dir" || die 'Remote directory must be a relative POSIX path without parent traversal.'
[[ "$display" =~ ^:[0-9]+$ ]] || die 'Display must be a local display such as :98.'
[[ "$HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'HOME must be a simple absolute POSIX path.'
if ((enable_zsh)); then
  zsh_path=$(command -v zsh) || die 'zsh is required for --enable-zsh.'
  zshrc="$HOME/.zshrc"
  preflight_zsh_alias "$zsh_path"
fi

for command in /usr/bin/systemctl /usr/bin/Xvfb /usr/bin/xclip /usr/bin/xauth /usr/bin/mcookie /usr/bin/xdpyinfo /usr/bin/sha256sum; do
  [[ -x "$command" && ! -L "$command" ]] || die "Required command unavailable: $command"
done
/usr/bin/systemctl --user show-environment >/dev/null || die 'No usable user systemd service manager is available.'
if command -v loginctl >/dev/null 2>&1; then
  linger=$(/usr/bin/loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)
  [[ "$linger" == 'yes' ]] || \
    printf 'imgpaste Codex X11 setup: warning: user lingering is disabled; services can stop after logout.\n' >&2
fi

source_bridge="$stage_dir/imgpaste-codex-x11-bridge.sh"
source_test="$stage_dir/test-codex-x11-bridge.sh"
source_uninstaller="$stage_dir/uninstall-codex-x11-bridge.sh"
[[ -f "$source_bridge" && ! -L "$source_bridge" ]] || die 'Missing staged X11 bridge script.'
[[ -f "$source_test" && ! -L "$source_test" ]] || die 'Missing staged X11 bridge test script.'
[[ -f "$source_uninstaller" && ! -L "$source_uninstaller" ]] || die 'Missing staged X11 bridge uninstaller.'

config_dir="$HOME/.config/imgpaste"
unit_dir="$HOME/.config/systemd/user"
library_dir="$HOME/.local/lib/imgpaste"
state_dir="$HOME/.local/state/imgpaste/codex-x11"
bridge="$library_dir/imgpaste-codex-x11-bridge"
test_script="$library_dir/imgpaste-codex-x11-test"
uninstaller="$library_dir/imgpaste-codex-x11-uninstall"
config="$config_dir/codex-x11.conf"
authority="$state_dir/Xauthority"
ownership="$state_dir/codex-x11.manifest"
display_file="$unit_dir/$display_unit"
bridge_file="$unit_dir/$bridge_unit"
number=${display#:}
socket="/tmp/.X11-unix/X$number"
lock="/tmp/.X$number-lock"

for directory in "$config_dir" "$unit_dir" "$library_dir" "$state_dir"; do
  [[ ! -L "$directory" ]] || die "Refusing symlinked directory: $directory"
  mkdir -p -- "$directory"
  chmod 700 "$directory"
done

for managed_path in "$bridge" "$test_script" "$uninstaller" "$config" "$authority" "$ownership" "$display_file" "$bridge_file"; do
  [[ ! -L "$managed_path" ]] || die "Refusing symlinked managed path: $managed_path"
done

if managed_payload_exists && ! verify_ownership_manifest; then
  die 'Refusing to replace unverified managed bridge files.'
fi

for unit_file in "$display_file" "$bridge_file"; do
  if [[ -e "$unit_file" ]]; then
    managed_unit "$unit_file" || die "Refusing to replace unrelated unit: $unit_file"
  fi
done
for unit in "$bridge_unit" "$display_unit"; do
  if /usr/bin/systemctl --user is-active --quiet "$unit"; then
    [[ -f "$unit_dir/$unit" ]] && managed_unit "$unit_dir/$unit" || \
      die "Refusing to stop unrelated active unit: $unit"
    /usr/bin/systemctl --user stop "$unit"
  fi
done

for _ in 1 2 3 4 5; do
  [[ ! -e "$socket" && ! -e "$lock" ]] && break
  sleep 1
done
[[ ! -e "$socket" && ! -e "$lock" ]] || die "Display $display is already in use. Choose another display."

install -m 700 "$source_bridge" "$bridge"
install -m 700 "$source_test" "$test_script"
install -m 700 "$source_uninstaller" "$uninstaller"
write_file "$config" 600 <<EOF
display=$display
image_dir=$HOME/$remote_dir
authority=$authority
EOF

touch "$authority"
chmod 600 "$authority"
/usr/bin/xauth -f "$authority" remove "$display" >/dev/null 2>&1 || true
cookie=$(/usr/bin/mcookie)
/usr/bin/xauth -f "$authority" add "$display" . "$cookie"

write_file "$display_file" 600 <<EOF
$marker
[Unit]
Description=imgpaste private X11 display for native Codex image paste

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb $display -screen 0 1x1x24 -nolisten tcp -noreset -auth $authority
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
write_file "$bridge_file" 600 <<EOF
$marker
[Unit]
Description=imgpaste X11 image clipboard bridge
Requires=$display_unit
After=$display_unit

[Service]
Type=simple
ExecStart=$bridge --serve
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOF
write_ownership_manifest

/usr/bin/systemctl --user daemon-reload
/usr/bin/systemctl --user enable --now "$display_unit"
for _ in 1 2 3 4 5; do
  XAUTHORITY="$authority" DISPLAY="$display" /usr/bin/xdpyinfo >/dev/null 2>&1 && break
  sleep 1
done
XAUTHORITY="$authority" DISPLAY="$display" /usr/bin/xdpyinfo >/dev/null || \
  die "Private Xvfb display $display did not become available."
/usr/bin/systemctl --user enable --now "$bridge_unit"

if ((enable_zsh)); then
  remove_zsh_block "$zshrc"
  {
    printf '\n'
    printf '%s\n' '# >>> imgpaste Codex X11 >>>'
    printf '%s\n' 'if (( $+functions[codex] )) && [[ "${functions[codex]}" != *"__imgpaste_codex_original"* ]]; then'
    printf '%s\n' '  functions -c codex __imgpaste_codex_original'
    printf '%s\n' '  function codex {'
    printf '    DISPLAY=%s XAUTHORITY=%s __imgpaste_codex_original "$@"\n' "$display" "$authority"
    printf '%s\n' '  }'
    printf '%s\n' 'elif (( ! $+functions[codex] )); then'
    printf '%s\n' '  function codex {'
    printf '    DISPLAY=%s XAUTHORITY=%s command codex "$@"\n' "$display" "$authority"
    printf '%s\n' '  }'
    printf '%s\n' 'fi'
    printf '%s\n' '# <<< imgpaste Codex X11 <<<'
  } >> "$zshrc"
  zsh_definition=$("$zsh_path" -ic 'functions codex' 2>/dev/null || true)
  [[ "$zsh_definition" == *"DISPLAY=$display"* && "$zsh_definition" == *"XAUTHORITY=$authority"* ]] || \
    die 'Fresh zsh shell did not install the private Codex display wrapper.'
fi

printf 'Installed imgpaste Codex X11 bridge on %s.\n' "$display"
printf 'New interactive zsh Codex sessions use DISPLAY=%s and XAUTHORITY=%s.\n' "$display" "$authority"
printf 'Existing Codex processes must be restarted before image paste can work.\n'
