#!/usr/bin/env bash
# Deprecated compatibility notice. Older versions globally shadowed xclip and
# wl-paste through PATH; cpcv now installs opt-in, prefixed helpers instead.
set -eu

cat <<'EOF'
This legacy script no longer changes PATH or replaces xclip/wl-paste.
From Windows, run:
  .\install-autostart.ps1 -DeployRemoteHelpers

That installs named helpers (~/.local/bin/cpcv-xclip,
~/.local/bin/cpcv-wl-paste, and cpcv-latest) without global shadowing.
EOF
