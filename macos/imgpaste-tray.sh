#!/usr/bin/env bash
# Launch the compiled native macOS menu-bar companion from any working directory.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tray_bin="$script_dir/build/imgpaste-tray"
if [[ ! -x "$tray_bin" || -L "$tray_bin" ]]; then
  printf '%s\n' "imgpaste tray is not built. Run: $script_dir/install-tray.sh" >&2
  exit 1
fi
exec "$tray_bin" --root "$root_dir"
