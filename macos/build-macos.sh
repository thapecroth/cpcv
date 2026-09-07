#!/usr/bin/env bash
# Build a clean universal macOS release archive for cpcv.
#
# The archive starts with committed source only, then adds ad-hoc-signed
# universal native binaries. It deliberately does not include local settings,
# caches, logs, Git history, or an Apple Developer ID signature/notarization.
set -euo pipefail
IFS=$'\n\t'
umask 077

die() {
  printf 'cpcv macOS build: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: bash macos/build-macos.sh [--output-directory DIRECTORY] [--release-tag vX.Y.Z] [--allow-dirty]

Builds a portable macOS 11+ universal ZIP from the committed Git tree. The
archive includes arm64 and x86_64 native binaries, source, installers, and
release metadata. Binaries are ad-hoc signed only; they are not notarized.
USAGE
}

script_path=${BASH_SOURCE[0]}
case "$script_path" in
  */*) script_parent=${script_path%/*} ;;
  *) script_parent='.' ;;
esac
script_dir=$(CDPATH= cd -P -- "$script_parent" && /bin/pwd -P)
repository=$(git -C "$script_dir/.." rev-parse --show-toplevel 2>/dev/null) || \
  die 'Run this script from a cpcv Git checkout with git available.'
repository=$(CDPATH= cd -P -- "$repository" && /bin/pwd -P)
expected_root=$(CDPATH= cd -P -- "$script_dir/.." && /bin/pwd -P)
[[ "$repository" == "$expected_root" ]] || die 'build-macos.sh must live in the cpcv repository macos directory.'

output_directory="$repository/build"
release_tag=''
allow_dirty=0
while (($#)); do
  case "$1" in
    --output-directory)
      (($# >= 2)) || die '--output-directory requires a directory.'
      output_directory=$2
      shift 2
      ;;
    --release-tag)
      (($# >= 2)) || die '--release-tag requires a tag such as v0.3.0.'
      release_tag=$2
      shift 2
      ;;
    --allow-dirty)
      allow_dirty=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

for command in git swiftc lipo codesign ditto unzip; do
  command -v "$command" >/dev/null 2>&1 || die "Required command is unavailable: $command"
done

if (( ! allow_dirty )); then
  dirty=$(git -C "$repository" status --porcelain --untracked-files=no)
  [[ -z "$dirty" ]] || die 'Refusing to build from modified tracked files. Commit or stash changes, or pass --allow-dirty (the archive still contains HEAD only).'
fi

version_file="$repository/VERSION"
[[ -f "$version_file" && ! -L "$version_file" ]] || die 'Missing tracked VERSION file.'
version=$(tr -d '\r\n' < "$version_file")
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$version" =~ $semver ]] || die 'VERSION must contain stable SemVer.'
source_version=$(/usr/bin/sed -nE 's/^private let cpcvVersion = "([^"]+)"$/\1/p' "$repository/macos/cpcv-macos.swift")
[[ "$source_version" == "$version" ]] || die 'VERSION must match cpcvVersion in macos/cpcv-macos.swift.'
release_tag=${release_tag:-"v$version"}
[[ "$release_tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
  die 'Release tag must be stable SemVer such as v0.3.0.'
[[ "$release_tag" == "v$version" ]] || die "Release tag $release_tag does not match VERSION $version."

mkdir -p -- "$output_directory"
output_directory=$(CDPATH= cd -P -- "$output_directory" && /bin/pwd -P)
archive="$output_directory/cpcv-${release_tag}-macos-universal.zip"
[[ ! -e "$archive" ]] || die "Refusing to overwrite an existing build artifact: $archive"

stage=$(/usr/bin/mktemp -d "$output_directory/.cpcv-macos-build.XXXXXX")
trap '/bin/rm -rf -- "$stage"' EXIT
bundle="$stage/cpcv"
git -C "$repository" archive --format=tar --prefix=cpcv/ HEAD | /usr/bin/tar -x -C "$stage"
[[ -d "$bundle" && ! -L "$bundle" ]] || die 'git archive did not produce the expected cpcv bundle root.'

build_directory="$bundle/macos/build"
[[ ! -e "$build_directory" || ! -L "$build_directory" ]] || die 'Refusing a symlinked macOS build path in the archive.'
/bin/mkdir -p -- "$build_directory"
/bin/chmod 700 "$build_directory"
export MACOSX_DEPLOYMENT_TARGET=11.0

compile_universal() {
  local source_file=$1 output_file=$2 parse_as_library=$3 base arm64 x86_64
  base=${output_file##*/}
  arm64="$stage/${base}-arm64"
  x86_64="$stage/${base}-x86_64"
  local -a common=(-O -framework AppKit)
  if [[ "$parse_as_library" == 'true' ]]; then
    common+=(-parse-as-library)
  fi
  swiftc "${common[@]}" -target arm64-apple-macosx11.0 "$source_file" -o "$arm64"
  swiftc "${common[@]}" -target x86_64-apple-macosx11.0 "$source_file" -o "$x86_64"
  /usr/bin/lipo -create "$arm64" "$x86_64" -output "$output_file"
  /bin/chmod 700 "$output_file"
  /usr/bin/codesign --force --sign - "$output_file"
  /usr/bin/codesign --verify --strict "$output_file"
}

validate_universal_binary() {
  local binary=$1 architectures architecture
  [[ -x "$binary" && ! -L "$binary" ]] || die "Missing safe executable: $binary"
  architectures=$(/usr/bin/lipo -archs "$binary")
  for architecture in arm64 x86_64; do
    [[ " $architectures " == *" $architecture "* ]] || die "Expected $architecture in universal binary: $binary"
  done
  /usr/bin/codesign --verify --strict "$binary"
}

uploader="$build_directory/cpcv-macos"
tray="$build_directory/cpcv-tray"
compile_universal "$bundle/macos/cpcv-macos.swift" "$uploader" false
compile_universal "$bundle/macos/cpcv-tray.swift" "$tray" true
validate_universal_binary "$uploader"
validate_universal_binary "$tray"
"$uploader" self-test >/dev/null
"$tray" self-test >/dev/null

printf '{"version":"%s","tag":"%s","architectures":["arm64","x86_64"],"signature":"ad-hoc","notarized":false}\n' \
  "$version" "$release_tag" > "$bundle/RELEASE-METADATA.json"

/usr/bin/ditto -c -k --keepParent "$bundle" "$archive"
[[ -f "$archive" && ! -L "$archive" ]] || die 'ditto did not create the expected ZIP.'
/usr/bin/unzip -tqq "$archive"
for required in \
  cpcv/README.md \
  cpcv/LICENSE \
  cpcv/VERSION \
  cpcv/RELEASE-METADATA.json \
  cpcv/macos/install-macos.sh \
  cpcv/macos/install-tray.sh \
  cpcv/macos/build/cpcv-macos \
  cpcv/macos/build/cpcv-tray; do
  /usr/bin/unzip -Z1 "$archive" | /usr/bin/grep -Fx -- "$required" >/dev/null || \
    die "Build archive is missing required file: $required"
done
if /usr/bin/unzip -Z1 "$archive" | /usr/bin/grep -Eq '(^|/)(\.git/|cache/|build/\.cpcv-|last-hash\.txt|last-remote-path\.txt|watch\.heartbeat|(?:cpcv\.config|config)\.(?:psd1|json)|.*\.log(?:\.[0-9]+)?$)'; then
  die 'Build archive unexpectedly contains local or generated state.'
fi

revision=$(git -C "$repository" rev-parse --short=12 HEAD)
bytes=$(/usr/bin/stat -f '%z' "$archive")
printf 'Artifact: %s\nRevision: %s\nBytes: %s\nSource: committed Git HEAD plus CI-buildable universal macOS binaries\n' \
  "$archive" "$revision" "$bytes"
