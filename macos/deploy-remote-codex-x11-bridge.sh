#!/usr/bin/env bash
# Stage and install the explicit Linux X11 bridge through an existing SSH alias.
set -euo pipefail
IFS=$'\n\t'
umask 077

die() {
  printf 'cpcv remote Codex X11 deployment: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: deploy-remote-codex-x11-bridge.sh --host SSH_ALIAS [--remote-dir clipboard-images] [--display :98] [--no-zsh-env] [--receipt ABSOLUTE_PATH]

Creates a private Xvfb display and an image clipboard bridge on a Linux SSH
target. Existing Codex processes must be restarted after deployment.
USAGE
  exit 64
}

host=''
remote_dir='clipboard-images'
display=':98'
enable_zsh=1
receipt=''
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
    --display) (($# >= 2)) || usage; display=$2; shift 2 ;;
    --no-zsh-env) enable_zsh=0; shift ;;
    --receipt) (($# >= 2)) || usage; receipt=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

while [[ "$remote_dir" == */ ]]; do remote_dir=${remote_dir%/}; done
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die 'Host must be a simple SSH alias or user@host.'
[[ "$remote_dir" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$remote_dir" != /* && "$remote_dir" != *'..'* ]] || \
  die 'Remote directory must be a relative POSIX path without parent traversal.'
[[ "$display" =~ ^:[0-9]+$ ]] || die 'Display must be a local display such as :98.'
if [[ -z "$receipt" ]]; then
  receipt="$HOME/Library/Application Support/cpcv/codex-x11-bridge.json"
fi
[[ "$receipt" == /* && "$receipt" != *$'\n'* && "$receipt" != *$'\r'* ]] || \
  die 'Receipt must be an absolute local path.'
receipt_dir=${receipt%/*}
[[ -n "$receipt_dir" && "$receipt_dir" != "$receipt" ]] || die 'Receipt path must include a filename.'

script_dir=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}" && /bin/pwd -P)
project_root=$(CDPATH= cd -P -- "$script_dir/.." && /bin/pwd -P)
bridge="$project_root/remote/cpcv-codex-x11-bridge.sh"
installer="$project_root/remote/install-codex-x11-bridge.sh"
test_script="$project_root/remote/test-codex-x11-bridge.sh"
uninstaller="$project_root/remote/uninstall-codex-x11-bridge.sh"
[[ -f "$bridge" && ! -L "$bridge" && -f "$installer" && ! -L "$installer" && \
   -f "$test_script" && ! -L "$test_script" && -f "$uninstaller" && ! -L "$uninstaller" ]] || \
  die 'Missing remote X11 bridge sources.'

stage=$(ssh "${ssh_options[@]}" "$host" 'umask 077; mktemp -d "${TMPDIR:-/tmp}/cpcv-codex-x11.XXXXXX"') || \
  die 'Could not create remote staging directory.'
[[ "$stage" =~ ^/tmp/cpcv-codex-x11\.[A-Za-z0-9]+$ ]] || die 'Remote staging path was invalid.'
cleanup() {
  ssh "${ssh_options[@]}" "$host" "find '$stage' -depth -delete" >/dev/null 2>&1 || true
}
trap cleanup EXIT

scp "${ssh_options[@]}" "$bridge" "$installer" "$test_script" "$uninstaller" "$host:$stage/"
remote_args="--remote-dir $remote_dir --display $display"
if ((enable_zsh)); then remote_args+=' --enable-zsh'; fi
ssh "${ssh_options[@]}" "$host" "CPCV_STAGE_DIR='$stage' /usr/bin/env bash '$stage/install-codex-x11-bridge.sh' $remote_args"
trap - EXIT
cleanup

[[ ! -L "$receipt_dir" && ! -L "$receipt" ]] || die 'Refusing symlinked local bridge receipt path.'
/bin/mkdir -p -- "$receipt_dir"
/bin/chmod 700 "$receipt_dir"
temporary=$(/usr/bin/mktemp "$receipt_dir/.codex-x11-bridge.XXXXXX")
trap '/usr/bin/unlink "$temporary" 2>/dev/null || true' EXIT
zsh_json=false
((enable_zsh)) && zsh_json=true
printf '{"display":"%s","enableZsh":%s,"hostAlias":"%s","remoteDir":"%s","version":"1"}\n' \
  "$display" "$zsh_json" "$host" "$remote_dir" > "$temporary"
/bin/chmod 600 "$temporary"
/bin/mv -f -- "$temporary" "$receipt"
trap - EXIT
printf 'Remote bridge installed on %s. Open a new tmux pane and restart Codex.\n' "$host"
