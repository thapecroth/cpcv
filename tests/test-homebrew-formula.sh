#!/usr/bin/env bash
# Network-free checks for the release-generated Homebrew formula.
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
if /usr/bin/grep -Fq -- 'buildpath/"cpcv"' "$formula"; then
  die 'Formula incorrectly expects a nested cpcv directory after Homebrew staging.'
fi
/usr/bin/grep -Fq -- 'source_root = buildpath' "$formula" || \
  die "Formula does not install from Homebrew's staged archive root."
/usr/bin/grep -Fq -- 'entry.basename.to_s == ".brew_home"' "$formula" || \
  die "Formula does not exclude Homebrew's transient build home."
/usr/bin/grep -Fq -- 'bin.mkpath' "$formula" || \
  die 'Formula does not create its wrapper directory.'

if command -v brew >/dev/null 2>&1 && command -v zip >/dev/null 2>&1; then
  fixture_root="$temporary/fixture"
  fixture_archive="$temporary/cpcv-fixture.zip"
  /bin/mkdir -p -- "$fixture_root/cpcv/macos"
  for target in cpcv-macos-ctl.sh cpcv-homebrew-setup.sh deploy-remote-tmux-cpcv-plugin.sh; do
    target_path="$fixture_root/cpcv/macos/$target"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$target_path"
    /bin/chmod 755 "$target_path"
  done
  (
    cd "$fixture_root"
    zip -q -r "$fixture_archive" cpcv
  )

  brew ruby -e '
require "formulary"
require "tmpdir"
require "unpack_strategy"
archive = Pathname.new(ARGV.fetch(0))
formula_path = Pathname.new(ARGV.fetch(1))
Dir.mktmpdir("cpcv-homebrew-stage") do |stage|
  Dir.chdir(stage) do
    UnpackStrategy.detect(archive, prioritize_extension: true).extract_nestedly
    entries = Dir["*"]
    raise "expected one cpcv archive root, got #{entries.inspect}" unless entries == ["cpcv"]
    Dir.chdir("cpcv") do
      buildpath = Pathname.pwd
      (buildpath/".brew_home").mkpath
      Dir.mktmpdir("cpcv-homebrew-prefix") do |prefix_path|
        prefix = Pathname.new(prefix_path)
        formula = Formulary.from_contents("cpcv", formula_path, formula_path.read)
        formula.define_singleton_method(:prefix) { prefix }
        formula.buildpath = buildpath
        formula.install

        %w[cpcv cpcv-setup cpcv-deploy-tmux].each do |name|
          wrapper = prefix/"bin"/name
          raise "missing executable wrapper: #{name}" unless wrapper.executable?
          raise "wrapper failed: #{name}" unless system(wrapper, "--help")
        end
        raise "transient .brew_home was packaged" if (prefix/"libexec"/".brew_home").exist?
        raise "macOS controller was not packaged" unless (prefix/"libexec"/"macos"/"cpcv-macos-ctl.sh").executable?
      end
    end
  end
end
' "$fixture_archive" "$formula"
else
  printf '%s\n' 'SKIP: Homebrew staged-install harness requires brew and zip.'
fi

printf '%s\n' 'PASS: Homebrew formula template, staging, and setup helper are valid.'
