#!/usr/bin/env bash
# Deprecated compatibility notice. Older versions globally shadowed xclip and
# wl-paste through PATH; ctrl-ccv now installs opt-in, prefixed helpers instead.
set -eu

cat <<'EOF'
This legacy script no longer changes PATH or replaces xclip/wl-paste.
From Windows, run:
  .\install-autostart.ps1 -DeployRemoteHelpers

That installs named helpers (~/.local/bin/ctrl-ccv-xclip,
~/.local/bin/ctrl-ccv-wl-paste, and ctrl-ccv-latest) without global shadowing.
EOF
