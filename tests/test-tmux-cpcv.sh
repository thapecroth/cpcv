#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

die() {
  printf 'cpcv tmux test: %s\n' "$*" >&2
  exit 1
}

root=$(CDPATH= cd -P -- "${BASH_SOURCE[0]%/*}/.." && /bin/pwd -P)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/cpcv-tmux-test.XXXXXX")
cleanup() { find "$temporary" -depth -delete; }
trap cleanup EXIT HUP INT TERM

home="$temporary/home"
bin="$temporary/bin"
stage="$temporary/stage"
log="$temporary/tmux.log"
mkdir -p "$home/clipboard-images" "$bin" "$stage"
printf 'png' > "$home/clipboard-images/latest.png"

cat > "$bin/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_TMUX_LOG"
case "${1:-}" in
  show-options)
    case "$*" in
      *'@cpcv-image-dir') printf '%s' "${FAKE_TMUX_IMAGE_DIR:-}" ;;
      *'@cpcv-paste-key') printf '%s' "${FAKE_TMUX_PASTE_KEY:-}" ;;
      *'@cpcv-status') printf '%s' "${FAKE_TMUX_STATUS:-}" ;;
    esac
    ;;
  list-keys) if [[ -n "${FAKE_TMUX_BINDING:-}" ]]; then printf '%s\n' "$FAKE_TMUX_BINDING"; fi ;;
esac
TMUX
chmod 700 "$bin/tmux"

config="$temporary/tmux-paste.conf"
printf '# Managed by cpcv tmux plugin\nimage_dir=%s\n' "$home/clipboard-images" > "$config"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" CPCV_TMUX_CONFIG="$config" \
  "$root/tmux/scripts/cpcv-tmux-paste.sh" %42
grep -Fq "set-buffer -b cpcv-42-" "$log" || die 'paste helper did not create a pane-specific buffer'
grep -Fq "paste-buffer -d -p -b cpcv-42-" "$log" || die 'paste helper did not use bracketed targeted paste'
grep -Fq -- "-t %42" "$log" || die 'paste helper did not target the originating pane'
! grep -Fq 'set-clipboard' "$log" || die 'paste helper changed the system clipboard'

modified=$(stat -c %Y "$home/clipboard-images/latest.png" 2>/dev/null || stat -f %m "$home/clipboard-images/latest.png")
status=$(PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" CPCV_TMUX_CONFIG="$config" \
  CPCV_TMUX_NOW="$((modified + 2))" "$root/tmux/scripts/cpcv-tmux-status.sh")
[[ "$status" == 'cpcv · 2 sec ago' ]] || die 'status helper did not render a readable image age'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" CPCV_DIR="$home/clipboard-images" TMUX_PANE=%77 \
  bash "$root/cpcv-latest.sh"
grep -Fq -- "-t %77" "$log" || die 'latest helper did not use TMUX_PANE'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -n -T root C-v run-shell -b' "$log" || die 'plugin did not install the capture binding'
grep -Fq 'set-option -g status-right' "$log" || die 'plugin did not add the status segment'
grep -Fq 'CPCV_TMUX_STATUS=1' "$log" || die 'plugin status segment is not owned'
grep -Fq 'set-option -g status-interval 2' "$log" || die 'plugin did not set its default status refresh'
! grep -Fq 'bind-key -T prefix I run-shell -b' "$log" || die 'plugin overwrote the common TPM installer binding'
! grep -Fq 'unbind-key' "$root/cpcv.tmux" || die 'plugin removes user bindings while changing keys'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_PASTE_KEY=M-v \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -n -T root M-v run-shell -b' "$log" || die 'plugin did not honor a configured capture key'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_STATUS=off \
  bash "$root/cpcv.tmux"
! grep -Fq 'set-option -g status-right' "$log" || die 'plugin added a disabled status segment'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING='bind-key -T root C-v display-message existing-user-binding' \
  bash "$root/cpcv.tmux"
! grep -Fq 'bind-key -n -T root C-v run-shell -b' "$log" || \
  die 'plugin replaced an existing user capture binding'
! grep -Eq '^bind-key (I|C-i) ' "$root/tmux-cpcv.conf" || \
  die 'plugin bindings overwrite prefix shortcuts'

cp "$root/cpcv.tmux" "$stage/cpcv.tmux"
cp "$root/tmux/scripts/cpcv-tmux-paste.sh" "$stage/cpcv-tmux-paste.sh"
cp "$root/tmux/scripts/cpcv-tmux-common.sh" "$stage/cpcv-tmux-common.sh"
cp "$root/tmux/scripts/cpcv-tmux-status.sh" "$stage/cpcv-tmux-status.sh"
HOME="$home" CPCV_STAGE_DIR="$stage" bash "$root/remote/install-tmux-cpcv-plugin.sh" --remote-dir clipboard-images >/dev/null
installed="$home/.local/lib/cpcv/tmux"
[[ -x "$installed/cpcv.tmux" && -x "$installed/tmux/scripts/cpcv-tmux-paste.sh" && \
   -x "$installed/tmux/scripts/cpcv-tmux-common.sh" && -x "$installed/tmux/scripts/cpcv-tmux-status.sh" ]] || \
  die 'installer did not install executable plugin files'
grep -Fqx '# Managed by cpcv tmux plugin' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer did not write owned configuration'
printf 'image_dir=/outside-home\n' > "$config"
if PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" CPCV_TMUX_CONFIG="$config" \
  "$root/tmux/scripts/cpcv-tmux-paste.sh" %42; then
  die 'paste helper accepted an unsafe image directory'
fi

mkdir -p "$temporary/outside"
printf 'png' > "$temporary/outside/latest.png"
printf 'image_dir=%s/../outside\n' "$home" > "$config"
if PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" CPCV_TMUX_CONFIG="$config" \
  "$root/tmux/scripts/cpcv-tmux-paste.sh" %42; then
  die 'paste helper accepted a path that escapes HOME through parent traversal'
fi

if command -v tmux >/dev/null 2>&1; then
  (
    real=$(mktemp -d /tmp/ip.XXXXXX)
    cleanup_real() {
      TMUX_TMPDIR="$real" tmux kill-server >/dev/null 2>&1 || true
      find "$real" -depth -delete
    }
    trap cleanup_real EXIT HUP INT TERM
    TMUX_TMPDIR="$real" tmux -f /dev/null new-session -d -s ip 'sleep 30'
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    binding=$(TMUX_TMPDIR="$real" tmux list-keys -T root | \
      awk '$1 == "bind-key" && $2 == "-T" && $3 == "root" && $4 == "C-v" { print }')
    [[ "$binding" == *CPCV_TMUX_PLUGIN=1* ]] || die 'tmux run-shell did not install the capture hook'
  )
fi

printf 'PASS: tmux plugin uses a targeted transient buffer and preserves the host clipboard.\n'
