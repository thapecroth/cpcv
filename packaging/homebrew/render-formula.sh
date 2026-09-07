#!/usr/bin/env bash
# Render the versioned Homebrew formula from the release's verified macOS ZIP.
set -euo pipefail
IFS=$'\n\t'
umask 077

die() {
  printf 'cpcv Homebrew formula: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: render-formula.sh --version X.Y.Z --sha256 SHA256 --output Formula/cpcv.rb
USAGE
}

version=''
sha256=''
output=''
while (($#)); do
  case "$1" in
    --version) (($# >= 2)) || die '--version requires stable SemVer.'; version=$2; shift 2 ;;
    --sha256) (($# >= 2)) || die '--sha256 requires a SHA-256 digest.'; sha256=$2; shift 2 ;;
    --output) (($# >= 2)) || die '--output requires a path.'; output=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
  die 'Version must be stable SemVer such as 0.3.0.'
[[ "$sha256" =~ ^[a-f0-9]{64}$ ]] || die 'SHA-256 must be 64 lowercase hexadecimal characters.'
[[ -n "$output" ]] || die '--output is required.'

script_path=${BASH_SOURCE[0]}
case "$script_path" in
  */*) script_parent=${script_path%/*} ;;
  *) script_parent='.' ;;
esac
script_dir=$(CDPATH= cd -P -- "$script_parent" && /bin/pwd -P)
template="$script_dir/cpcv.rb.template"
[[ -f "$template" && ! -L "$template" ]] || die 'Formula template is unavailable.'

output_dir=${output%/*}
[[ "$output_dir" != "$output" && -n "$output_dir" ]] || output_dir='.'
mkdir -p -- "$output_dir"
output_dir=$(CDPATH= cd -P -- "$output_dir" && /bin/pwd -P)
output_name=${output##*/}
[[ "$output_name" == 'cpcv.rb' ]] || die 'Formula output must be named cpcv.rb.'
output_path="$output_dir/$output_name"
[[ ! -L "$output_path" ]] || die 'Refusing a symlinked formula output path.'

temporary=$(/usr/bin/mktemp "$output_dir/.cpcv.rb.XXXXXX")
trap '/bin/rm -f -- "$temporary"' EXIT
/usr/bin/sed \
  -e "s/__VERSION__/$version/g" \
  -e "s/__MACOS_SHA256__/$sha256/g" \
  "$template" > "$temporary"
if /usr/bin/grep -Eq '__VERSION__|__MACOS_SHA256__' "$temporary"; then
  die 'Formula template placeholders were not fully replaced.'
fi
/bin/chmod 644 "$temporary"
/bin/mv -f -- "$temporary" "$output_path"
trap - EXIT
printf '%s\n' "$output_path"
