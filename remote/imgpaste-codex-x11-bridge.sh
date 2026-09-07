#!/usr/bin/env bash
# Own the image/png selection on a private imgpaste X11 display.
set -euo pipefail
IFS=$'\n\t'

config_file="${IMGPASTE_X11_CONFIG:-$HOME/.config/imgpaste/codex-x11.conf}"
xclip="${IMGPASTE_XCLIP:-/usr/bin/xclip}"
publisher_pid=""

die() {
  printf 'imgpaste X11 bridge: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: %s --serve\n' "${0##*/}" >&2
  exit 64
}

load_config() {
  [[ -f "$config_file" && ! -L "$config_file" ]] || die "Missing configuration: $config_file"
  display=""
  image_dir=""
  authority=""
  local key="" value=""
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      display) display=$value ;;
      image_dir) image_dir=$value ;;
      authority) authority=$value ;;
      '') ;;
      *) die "Unexpected configuration key: $key" ;;
    esac
  done < "$config_file"

  while [[ "$image_dir" != '/' && "$image_dir" == */ ]]; do image_dir=${image_dir%/}; done
  [[ "$display" =~ ^:[0-9]+$ ]] || die 'Configured display must be a local display such as :98.'
  [[ "$image_dir" == "$HOME/"* && "$image_dir" != *$'\n'* && "$image_dir" != *$'\r'* ]] || \
    die 'Configured image directory must be below HOME.'
  [[ "$authority" == "$HOME/"* && -f "$authority" && ! -L "$authority" ]] || \
    die 'Configured Xauthority file is unavailable.'
}

stop_publisher() {
  [[ -n "$publisher_pid" ]] || return 0
  if kill -0 "$publisher_pid" 2>/dev/null; then
    kill "$publisher_pid" 2>/dev/null || true
  fi
  wait "$publisher_pid" 2>/dev/null || true
  publisher_pid=""
}

cleanup() {
  stop_publisher
}

publisher_is_running() {
  [[ -n "$publisher_pid" ]] && kill -0 "$publisher_pid" 2>/dev/null
}

start_publisher() {
  local target=$1
  DISPLAY="$display" XAUTHORITY="$authority" "$xclip" -quiet \
    -selection clipboard -target image/png -in "$target" &
  publisher_pid=$!
}

[[ $# -eq 1 && "$1" == '--serve' ]] || usage
[[ -x "$xclip" && ! -L "$xclip" ]] || die "xclip is unavailable: $xclip"
load_config
trap cleanup EXIT HUP INT TERM

last_target=""
while :; do
  target="$(readlink -f -- "$image_dir/latest.png" 2>/dev/null || true)"
  if [[ -z "$target" || ! -f "$target" || "$target" != "$image_dir/"* ]]; then
    stop_publisher
    last_target=""
  elif [[ "$target" != "$last_target" ]] || ! publisher_is_running; then
    stop_publisher
    start_publisher "$target"
    last_target=$target
  fi
  sleep 1
done
