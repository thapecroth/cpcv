#!/usr/bin/env bash
# Deprecated compatibility notice. Older versions globally shadowed xclip and
# wl-paste through PATH; imgpaste now installs opt-in, prefixed helpers instead.
set -eu

cat <<'EOF'
This legacy script no longer changes PATH or replaces xclip/wl-paste.
From Windows, run:
  .\install-autostart.ps1 -DeployRemoteHelpers

That installs named helpers (~/.local/bin/imgpaste-xclip,
~/.local/bin/imgpaste-wl-paste, and imgpaste-latest) without global shadowing.
EOF
