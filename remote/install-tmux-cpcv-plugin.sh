#!/usr/bin/env bash
# Install only cpcv-owned tmux plugin files on an SSH target.
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly marker='# Managed by cpcv tmux plugin'

die() {
  printf 'cpcv tmux setup: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: install-tmux-cpcv-plugin.sh --remote-dir RELATIVE_DIR

Installs the cpcv tmux plugin without changing ~/.tmux.conf. Source the
printed run-shell line from a user-owned tmux configuration to enable it.
USAGE
  exit 64
}

safe_remote_dir() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$1" != /* && "$1" != *'..'* ]]
}

write_file() {
  local destination=$1 mode=$2 directory temporary
  directory=${destination%/*}
  temporary=$(mktemp "$directory/.${destination##*/}.XXXXXX")
  trap '[[ -n "${temporary:-}" ]] && /usr/bin/unlink "$temporary" 2>/dev/null || true' RETURN
  cat > "$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$destination"
  temporary=''
  trap - RETURN
}

managed_file() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] && grep -Fqx "$marker" "$path"
}

stage_dir=${CPCV_STAGE_DIR:-}
remote_dir=''
while (($#)); do
  case "$1" in
    --remote-dir) (($# >= 2)) || usage; remote_dir=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

while [[ "$remote_dir" == */ ]]; do remote_dir=${remote_dir%/}; done
[[ -n "$stage_dir" && "$stage_dir" == /* && -d "$stage_dir" && ! -L "$stage_dir" ]] || \
  die 'CPCV_STAGE_DIR must name a regular staged directory.'
safe_remote_dir "$remote_dir" || die 'Remote directory must be a relative POSIX path without parent traversal.'
[[ "$HOME" =~ ^/[A-Za-z0-9._/-]+$ ]] || die 'HOME must be a simple absolute POSIX path.'

source_plugin="$stage_dir/cpcv.tmux"
source_paste="$stage_dir/cpcv-tmux-paste.sh"
source_common="$stage_dir/cpcv-tmux-common.sh"
source_status="$stage_dir/cpcv-tmux-status.sh"
[[ -f "$source_plugin" && ! -L "$source_plugin" ]] || die 'Missing staged tmux plugin.'
[[ -f "$source_paste" && ! -L "$source_paste" ]] || die 'Missing staged tmux paste helper.'
[[ -f "$source_common" && ! -L "$source_common" ]] || die 'Missing staged tmux common helper.'
[[ -f "$source_status" && ! -L "$source_status" ]] || die 'Missing staged tmux status helper.'
grep -Fqx "$marker" "$source_plugin" || die 'Staged tmux plugin has no ownership marker.'
grep -Fqx "$marker" "$source_paste" || die 'Staged tmux paste helper has no ownership marker.'
grep -Fqx "$marker" "$source_common" || die 'Staged tmux common helper has no ownership marker.'
grep -Fqx "$marker" "$source_status" || die 'Staged tmux status helper has no ownership marker.'

config_dir="$HOME/.config/cpcv"
plugin_dir="$HOME/.local/lib/cpcv/tmux"
script_dir="$plugin_dir/tmux/scripts"
config="$config_dir/tmux-paste.conf"
plugin="$plugin_dir/cpcv.tmux"
paste="$script_dir/cpcv-tmux-paste.sh"
common="$script_dir/cpcv-tmux-common.sh"
status="$script_dir/cpcv-tmux-status.sh"

for directory in "$config_dir" "$plugin_dir" "$script_dir" "$HOME/$remote_dir"; do
  [[ ! -L "$directory" ]] || die "Refusing symlinked directory: $directory"
  mkdir -p -- "$directory"
done
chmod 700 "$config_dir" "$plugin_dir" "$script_dir"

for path in "$plugin" "$paste" "$common" "$status" "$config"; do
  [[ ! -L "$path" ]] || die "Refusing symlinked managed path: $path"
  if [[ -e "$path" ]]; then
    managed_file "$path" || die "Refusing to replace unrelated file: $path"
  fi
done

install -m 700 "$source_plugin" "$plugin"
install -m 700 "$source_paste" "$paste"
install -m 700 "$source_common" "$common"
install -m 700 "$source_status" "$status"
write_file "$config" 600 <<EOF
$marker
image_dir=$HOME/$remote_dir
EOF

printf 'Installed cpcv tmux plugin files. Add this to your remote tmux config:\n'
printf 'run-shell %s\n' "$plugin"
printf 'Use Ctrl-V for the default capture key; Warp cannot map Cmd-V to a raw control key.\n'
