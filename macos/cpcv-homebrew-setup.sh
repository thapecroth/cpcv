#!/usr/bin/env bash
# Finish cpcv's user-session setup after Homebrew installs the formula.
# Homebrew installs package files but should not silently create GUI
# LaunchAgents or collect SSH settings during `brew install`.
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<'USAGE'
Usage: cpcv-setup

Installs and starts cpcv's per-user macOS uploader and menu-bar companion from
the Homebrew formula's verified prebuilt universal binaries. It creates a
private configuration template when needed; choose the cpcv menu-bar icon's
Settings screen afterward to enter an SSH target.
USAGE
}

if (($#)); then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
fi

script_path=${BASH_SOURCE[0]}
case "$script_path" in
  */*) script_parent=${script_path%/*} ;;
  *) script_parent='.' ;;
esac
script_dir=$(CDPATH= cd -P -- "$script_parent" && /bin/pwd -P)

uploader_installer="$script_dir/install-macos.sh"
tray_installer="$script_dir/install-tray.sh"
[[ -f "$uploader_installer" && ! -L "$uploader_installer" ]] || {
  printf '%s\n' 'cpcv Homebrew setup: native installer is unavailable.' >&2
  exit 1
}
[[ -f "$tray_installer" && ! -L "$tray_installer" ]] || {
  printf '%s\n' 'cpcv Homebrew setup: menu-bar installer is unavailable.' >&2
  exit 1
}

/bin/bash "$uploader_installer" --prebuilt
/bin/bash "$tray_installer" --prebuilt
printf '%s\n' 'cpcv is running. Choose the cpcv menu-bar icon, then Settings, to configure your SSH target.'
