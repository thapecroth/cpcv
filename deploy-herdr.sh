#!/usr/bin/env bash
# Install the opt-in Herdr path-paste helper through an existing SSH alias.
set -euo pipefail
IFS=$'\n\t'
umask 077

die() { printf 'cpcv Herdr deployment: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'Usage: %s --host SSH_ALIAS [--remote-dir clipboard-images]\n' "${0##*/}"
}

host=''
remote_dir='clipboard-images'
while (($#)); do
  case "$1" in
    --host) (($# >= 2)) || die '--host requires a value'; host=$2; shift 2 ;;
    --remote-dir) (($# >= 2)) || die '--remote-dir requires a value'; remote_dir=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die 'Use a simple SSH alias or user@host.'
[[ "$remote_dir" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && "$remote_dir" != *'..'* ]] || \
  die 'Use a relative remote directory without parent traversal.'

script_parent=${BASH_SOURCE[0]%/*}
[[ "$script_parent" != "${BASH_SOURCE[0]}" ]] || script_parent='.'
root=$(CDPATH= cd -P -- "$script_parent" && /bin/pwd -P)
helper="$root/remote/cpcv-herdr.py"
[[ -f "$helper" && ! -L "$helper" ]] || die 'Missing Herdr helper source.'
ssh_options=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1 -o ServerAliveInterval=3 -o ServerAliveCountMax=2)
stage=$(ssh "${ssh_options[@]}" "$host" 'command -v python3 >/dev/null && umask 077 && mktemp -d /tmp/cpcv-herdr.XXXXXXXX') || \
  die 'Could not stage the helper; check unattended SSH and Python 3 on the target.'
[[ "$stage" =~ ^/tmp/cpcv-herdr\.[A-Za-z0-9]+$ ]] || die 'Invalid remote staging path.'
cleanup() {
  ssh "${ssh_options[@]}" "$host" "rm -f '$stage/cpcv-herdr.py'; rmdir '$stage'" >/dev/null 2>&1 || true
}
trap cleanup EXIT
scp "${ssh_options[@]}" "$helper" "$host:$stage/"
ssh "${ssh_options[@]}" "$host" "python3 '$stage/cpcv-herdr.py' install --remote-dir '$remote_dir'"
