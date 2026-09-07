#!/usr/bin/env bash
# Stage the opt-in tmux path-insertion plugin through an existing SSH alias.
set -euo pipefail
IFS=$'\n\t'
umask 077

die() {
  printf 'imgpaste remote tmux deployment: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: deploy-remote-tmux-imgpaste-plugin.sh --host SSH_ALIAS [--remote-dir clipboard-images]

Installs only imgpaste-owned remote plugin files. It does not edit tmux or
shell startup files; source the printed run-shell line yourself.
USAGE
  exit 64
}

host=''
remote_dir='clipboard-images'
ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=8
  -o ConnectionAttempts=1
  -o ServerAliveInterval=3
  -o ServerAliveCountMax=2
)
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || usage; host=$2; shift 2 ;;
    --remote-dir) (($# >= 2)) || usage; remote_dir=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

while [[ "$remote_dir" == */ ]]; do remote_dir=${remote_dir%/}; done
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die 'Host must be a simple SSH alias or user@host.'
[[ "$remote_dir" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$remote_dir" != /* && "$remote_dir" != *'..'* ]] || \
  die 'Remote directory must be a relative POSIX path without parent traversal.'

script_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
project_root=$(CDPATH= cd -P -- "$script_dir/.." && /bin/pwd -P)
plugin="$project_root/imgpaste.tmux"
paste="$project_root/tmux/scripts/imgpaste-tmux-paste.sh"
installer="$project_root/remote/install-tmux-imgpaste-plugin.sh"
[[ -f "$plugin" && ! -L "$plugin" && -f "$paste" && ! -L "$paste" && -f "$installer" && ! -L "$installer" ]] || \
  die 'Missing tmux plugin sources.'

stage=$(ssh "${ssh_options[@]}" "$host" 'umask 077; mktemp -d "${TMPDIR:-/tmp}/imgpaste-tmux.XXXXXX"') || \
  die 'Could not create remote staging directory.'
[[ "$stage" =~ ^/tmp/imgpaste-tmux\.[A-Za-z0-9]+$ ]] || die 'Remote staging path was invalid.'
cleanup() {
  ssh "${ssh_options[@]}" "$host" "find '$stage' -depth -delete" >/dev/null 2>&1 || true
}
trap cleanup EXIT

scp "${ssh_options[@]}" "$plugin" "$paste" "$installer" "$host:$stage/"
ssh "${ssh_options[@]}" "$host" "IMGPASTE_STAGE_DIR='$stage' /usr/bin/env bash '$stage/install-tmux-imgpaste-plugin.sh' --remote-dir '$remote_dir'"
trap - EXIT
cleanup
printf 'Remote tmux plugin installed on %s. Add the printed run-shell line, reload tmux, and map Cmd-V to Ctrl-V in your terminal.\n' "$host"
