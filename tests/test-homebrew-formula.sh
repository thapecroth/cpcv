#!/usr/bin/env bash
# Static, network-free checks for the release-generated Homebrew formula.
set -euo pipefail
IFS=$'\n\t'

die() {
  printf 'cpcv Homebrew formula test: %s\n' "$*" >&2
  exit 1
}

script_path=${BASH_SOURCE[0]}
case "$script_path" in
  */*) script_parent=${script_path%/*} ;;
  *) script_parent='.' ;;
esac
tests_dir=$(CDPATH= cd -P -- "$script_parent" && /bin/pwd -P)
root=$(CDPATH= cd -P -- "$tests_dir/.." && /bin/pwd -P)
template="$root/packaging/homebrew/cpcv.rb.template"
renderer="$root/packaging/homebrew/render-formula.sh"
setup_script="$root/macos/cpcv-homebrew-setup.sh"

[[ -f "$template" && ! -L "$template" ]] || die 'Missing Homebrew formula template.'
[[ -f "$renderer" && ! -L "$renderer" ]] || die 'Missing Homebrew formula renderer.'
[[ -f "$setup_script" && ! -L "$setup_script" ]] || die 'Missing Homebrew setup helper.'
/bin/bash -n "$setup_script"
/bin/bash -n "$renderer"
/bin/bash "$setup_script" --help | /usr/bin/grep -Fq 'Usage: cpcv-setup' || \
  die 'Homebrew setup helper does not expose its fixed help path.'

for required in \
  'class Cpcv < Formula' \
  'depends_on macos: :big_sur' \
  '__VERSION__' \
  '__MACOS_SHA256__' \
  'cpcv-setup' \
  'cpcv-deploy-tmux' \
  'self-test'; do
  /usr/bin/grep -Fq -- "$required" "$template" || die "Formula template is missing: $required"
done

temporary=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cpcv-homebrew-formula.XXXXXX")
trap '/bin/rm -rf -- "$temporary"' EXIT
formula="$temporary/cpcv.rb"
/bin/bash "$renderer" \
  --version 0.3.0 \
  --sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  --output "$formula" >/dev/null
command -v ruby >/dev/null 2>&1 || die 'Ruby is required to parse the Homebrew formula template.'
ruby -c "$formula" >/dev/null
if /usr/bin/grep -Eq '__VERSION__|__MACOS_SHA256__' "$formula"; then
  die 'Formula placeholders were not replaced.'
fi

printf '%s\n' 'PASS: Homebrew formula template and setup helper are syntactically valid.'
