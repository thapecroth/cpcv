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

for portable_script in "$root/cpcv.tmux" "$root/tmux-cpcv.conf"; do
  ! LC_ALL=C grep -q $'\r' "$portable_script" || \
    die "portable tmux source contains CRLF: $portable_script"
done

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
      *'@cpcv-paste-table') printf '%s' "${FAKE_TMUX_PASTE_TABLE:-}" ;;
      *'@cpcv-status') printf '%s' "${FAKE_TMUX_STATUS:-}" ;;
    esac
    ;;
  list-keys)
    table=${3:-}
    if [[ "$table" == cpcv-key-probe-* ]]; then
      [[ -f "$FAKE_TMUX_LOG.probe" ]] && cat "$FAKE_TMUX_LOG.probe"
    elif [[ -n "${FAKE_TMUX_BINDING:-}" ]]; then
      printf '%s\n' "$FAKE_TMUX_BINDING"
    fi
    ;;
  bind-key)
    if [[ "${2:-}" == -T && "${3:-}" == cpcv-key-probe-* && \
          "${5:-}" == display-message && "${6:-}" == CPCV_TMUX_KEY_PROBE=1 ]]; then
      key=${4}
      case "$key" in
        C-[A-Z]) key="C-$(printf '%s' "${key#C-}" | tr '[:upper:]' '[:lower:]')" ;;
        enter) key=Enter ;;
        space) key=Space ;;
        bspace) key=BSpace ;;
      esac
      printf 'bind-key -T %s %s display-message CPCV_TMUX_KEY_PROBE=1\n' "${3}" "$key" > "$FAKE_TMUX_LOG.probe"
    fi
    ;;
  unbind-key)
    if [[ "${3:-}" == cpcv-key-probe-* ]]; then
      rm -f "$FAKE_TMUX_LOG.probe"
    fi
    ;;
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
grep -Fq 'bind-key -T prefix v run-shell -b' "$log" || die 'plugin did not install the portable capture binding'
grep -Fq 'set-option -g status-right' "$log" || die 'plugin did not add the status segment'
grep -Fq 'CPCV_TMUX_STATUS=1' "$log" || die 'plugin status segment is not owned'
grep -Fq 'set-option -g status-interval 2' "$log" || die 'plugin did not set its default status refresh'
grep -Fq 'bind-key -T prefix v ' "$root/tmux-cpcv.conf" || die 'compatibility binding did not use prefix-v'
! grep -Fq 'unbind-key -T root' "$log" || die 'plugin removed a root binding without a managed legacy binding'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_PASTE_KEY=M-v \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T root M-v run-shell -b' "$log" || die 'plugin did not preserve an explicit legacy capture key'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_PASTE_KEY=M-v FAKE_TMUX_PASTE_TABLE=prefix \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T prefix M-v run-shell -b' "$log" || die 'plugin did not honor a configured capture table'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_PASTE_KEY=C-v FAKE_TMUX_PASTE_TABLE=root \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || die 'plugin did not honor explicit raw Ctrl-V opt-in'

managed_config="$home/.config/cpcv/tmux-paste.conf"
mkdir -p "${managed_config%/*}"
printf '# Managed by cpcv tmux plugin\nimage_dir=%s\npaste_table=root\npaste_key=C-v\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || die 'plugin did not honor the managed raw Ctrl-V setting'

printf '# Managed by cpcv tmux plugin\nimage_dir=%s\npaste_table=root\npaste_key=C-v\npaste_secondary_table=root\npaste_secondary_key=M-v\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || \
  die 'plugin did not install the managed macOS Ctrl-V binding'
grep -Fq 'bind-key -T root M-v run-shell -b' "$log" || \
  die 'plugin did not install the managed Windows Alt-V binding'

# Both destinations are checked before any old cpcv binding is removed. A user
# M-v collision therefore cannot leave an incomplete cross-platform profile.
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING=$'bind-key -T root C-v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"\nbind-key -T root M-v display-message existing-user-binding\nbind-key -T prefix v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"' \
  bash "$root/cpcv.tmux"
! grep -Fq 'unbind-key -T root C-v' "$log" || \
  die 'plugin removed the primary managed binding before checking the secondary collision'
! grep -Fq 'unbind-key -T prefix v' "$log" || \
  die 'plugin removed an old prefix binding before checking the secondary collision'
! grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || \
  die 'plugin rewrote the primary binding after a secondary collision'
! grep -Fq 'bind-key -T root M-v run-shell -b' "$log" || \
  die 'plugin overwrote a user Windows Alt-V binding'

# A managed UI change must not leave the former prefix shortcut active when it
# moves to the two raw platform shortcuts. Only a cpcv-marked prefix binding
# may be removed.
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING='bind-key -T prefix v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"' \
  bash "$root/cpcv.tmux"
grep -Fq 'unbind-key -T prefix v' "$log" || die 'plugin left an obsolete managed prefix binding after a managed platform-binding move'
grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || die 'plugin did not bind raw Ctrl-V after clearing the obsolete managed prefix binding'
grep -Fq 'bind-key -T root M-v run-shell -b' "$log" || die 'plugin did not bind Windows Alt-V after clearing the obsolete managed prefix binding'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_PASTE_KEY=p FAKE_TMUX_PASTE_TABLE=prefix \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T prefix p run-shell -b' "$log" || die 'explicit tmux options did not override the managed setting'
! grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || \
  die 'explicit tmux options did not suppress the managed macOS binding'
! grep -Fq 'bind-key -T root M-v run-shell -b' "$log" || \
  die 'explicit tmux options did not suppress the managed Windows binding'

printf '# Managed by cpcv tmux plugin\nimage_dir=%s\npaste_table=root\npaste_key=C-v\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING=$'bind-key -T root C-v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"\nbind-key -T root M-v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"' \
  bash "$root/cpcv.tmux"
grep -Fq 'unbind-key -T root M-v' "$log" || \
  die 'plugin left the managed Windows Alt-V binding after selecting single raw Ctrl-V'
! grep -Fq 'unbind-key -T root C-v' "$log" || \
  die 'plugin removed the retained managed macOS Ctrl-V binding'
! grep -Fq 'bind-key -T root M-v run-shell -b' "$log" || \
  die 'plugin rebound the removed Windows Alt-V binding after selecting single raw Ctrl-V'

printf '# Managed by cpcv tmux plugin\nimage_dir=%s\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T prefix v run-shell -b' "$log" || die 'plugin did not preserve the default for legacy managed configuration'

printf '# Managed by cpcv tmux plugin\nimage_dir=%s\npaste_table=prefix\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'managed tmux configuration is invalid' "$log" || die 'plugin accepted a partial managed binding configuration'
! grep -Fq 'bind-key -T prefix v run-shell -b' "$log" || die 'plugin bound a key from malformed managed configuration'
printf '# Managed by cpcv tmux plugin\nimage_dir=%s\npaste_table=root\npaste_key=v\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'managed tmux configuration is invalid' "$log" || die 'plugin accepted a non-raw managed root binding configuration'
! grep -Fq 'bind-key -T root v run-shell -b' "$log" || die 'plugin bound a non-raw root key from malformed managed configuration'
printf '# Managed by cpcv tmux plugin\nimage_dir=%s\npaste_table=root\npaste_key=C-v\npaste_secondary_table=root\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'managed tmux configuration is invalid' "$log" || die 'plugin accepted a partial managed secondary binding configuration'
printf '# Managed by cpcv tmux plugin\nimage_dir=%s\npaste_table=prefix\npaste_key=v\npaste_secondary_table=root\npaste_secondary_key=M-v\n' "$home/clipboard-images" > "$managed_config"
: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  bash "$root/cpcv.tmux"
grep -Fq 'managed tmux configuration is invalid' "$log" || die 'plugin accepted a secondary binding without primary raw Ctrl-V'
rm -f "$managed_config"

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_PASTE_KEY=C-v \
  FAKE_TMUX_BINDING='bind-key -T root C-v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"' \
  bash "$root/cpcv.tmux"
grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || die 'plugin did not preserve the legacy key-only Ctrl-V configuration'
! grep -Fq 'unbind-key -T root C-v' "$log" || die 'plugin removed an explicitly retained legacy Ctrl-V binding'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" FAKE_TMUX_STATUS=off \
  bash "$root/cpcv.tmux"
! grep -Fq 'set-option -g status-right' "$log" || die 'plugin added a disabled status segment'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING='bind-key -T prefix v display-message existing-user-binding' \
  bash "$root/cpcv.tmux"
! grep -Fq 'bind-key -T prefix v run-shell -b' "$log" || \
  die 'plugin replaced an existing user capture binding'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING='bind-key -T root C-v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"' \
  bash "$root/cpcv.tmux"
grep -Fq 'unbind-key -T root C-v' "$log" || die 'plugin did not remove its managed legacy Ctrl-V binding'
grep -Fq 'bind-key -T prefix v run-shell -b' "$log" || die 'plugin did not replace the managed legacy binding'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING='bind-key -T root C-v display-message existing-user-binding' \
  bash "$root/cpcv.tmux"
! grep -Fq 'unbind-key -T root C-v' "$log" || die 'plugin removed an unrelated Ctrl-V binding'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_BINDING=$'bind-key -T root C-v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"\nbind-key -T prefix v display-message existing-user-binding' \
  bash "$root/cpcv.tmux"
# Preserve the narrowly-scoped upgrade behavior: a managed legacy Ctrl-V hook
# is released when default prefix/v is unavailable, but the user prefix/v
# binding is never replaced.
grep -Fq 'unbind-key -T root C-v' "$log" || die 'plugin did not release a managed legacy Ctrl-V hook after a prefix/v collision'
! grep -Fq 'bind-key -T prefix v run-shell -b' "$log" || \
  die 'plugin overwrote a user prefix/v binding after migration'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_PASTE_KEY=M-v FAKE_TMUX_PASTE_TABLE=prefix \
  FAKE_TMUX_BINDING='bind-key -T root M-v run-shell -b "CPCV_TMUX_PLUGIN=1 old-cpcv-paste"' \
  bash "$root/cpcv.tmux"
grep -Fq 'unbind-key -T root M-v' "$log" || die 'plugin did not migrate a managed legacy custom root key'
grep -Fq 'bind-key -T prefix M-v run-shell -b' "$log" || die 'plugin did not move the custom root key to its selected table'

: > "$log"
PATH="$bin:$PATH" FAKE_TMUX_LOG="$log" HOME="$home" \
  FAKE_TMUX_PASTE_KEY=C-V FAKE_TMUX_PASTE_TABLE=root \
  FAKE_TMUX_BINDING='bind-key -T root C-v display-message existing-user-binding' \
  bash "$root/cpcv.tmux"
! grep -Fq 'bind-key -T root C-v run-shell -b' "$log" || \
  die 'plugin overwrote a canonical user binding through a key alias'

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
grep -Fqx 'paste_table=prefix' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer did not write the default managed paste table'
grep -Fqx 'paste_key=v' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer did not write the default managed paste key'
if HOME="$home" CPCV_STAGE_DIR="$stage" bash "$root/remote/install-tmux-cpcv-plugin.sh" \
  --remote-dir clipboard-images --paste-table root --paste-key v >/dev/null 2>&1; then
  die 'installer accepted an unsafe managed root-table key'
fi
if HOME="$home" CPCV_STAGE_DIR="$stage" bash "$root/remote/install-tmux-cpcv-plugin.sh" \
  --remote-dir clipboard-images --paste-secondary-table root --paste-secondary-key M-v >/dev/null 2>&1; then
  die 'installer accepted a secondary binding without primary raw Ctrl-V'
fi
HOME="$home" CPCV_STAGE_DIR="$stage" bash "$root/remote/install-tmux-cpcv-plugin.sh" \
  --remote-dir clipboard-images --paste-table root --paste-key C-v >/dev/null
grep -Fqx 'paste_table=root' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer did not persist the explicit managed raw Ctrl-V table'
grep -Fqx 'paste_key=C-v' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer did not persist the explicit managed raw Ctrl-V key'
! grep -Fq 'paste_secondary_' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer left a secondary binding behind after selecting a single raw Ctrl-V binding'
HOME="$home" CPCV_STAGE_DIR="$stage" bash "$root/remote/install-tmux-cpcv-plugin.sh" \
  --remote-dir clipboard-images --paste-table root --paste-key C-v \
  --paste-secondary-table root --paste-secondary-key M-v >/dev/null
grep -Fqx 'paste_secondary_table=root' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer did not persist the managed Windows Alt-V table'
grep -Fqx 'paste_secondary_key=M-v' "$home/.config/cpcv/tmux-paste.conf" || \
  die 'installer did not persist the managed Windows Alt-V key'
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
    start_real_server() {
      local config=${1:-}
      if [[ -n "$config" ]]; then
        CPCV_TMUX_CONFIG="$config" TMUX_TMPDIR="$real" tmux -f /dev/null new-session -d -s ip 'sleep 30'
      else
        TMUX_TMPDIR="$real" tmux -f /dev/null new-session -d -s ip 'sleep 30'
      fi
    }
    stop_real_server() {
      TMUX_TMPDIR="$real" tmux kill-server >/dev/null 2>&1 || true
    }
    real_binding() {
      local table=$1 key=$2
      TMUX_TMPDIR="$real" tmux list-keys -T "$table" | \
        awk -v table="$table" -v key="$key" \
          '$1 == "bind-key" && $2 == "-T" && $3 == table && $4 == key { print; exit }'
    }
    cleanup_real() {
      stop_real_server
      find "$real" -depth -delete
    }
    trap cleanup_real EXIT HUP INT TERM

    start_real_server
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    binding=$(real_binding prefix v)
    [[ "$binding" == *CPCV_TMUX_PLUGIN=1* ]] || die 'tmux run-shell did not install the capture hook'
    legacy=$(real_binding root C-v)
    [[ -z "$legacy" ]] || die 'tmux run-shell left a default root Ctrl-V capture hook'

    dual_config="$real/tmux-paste.conf"
    printf '# Managed by cpcv tmux plugin\nimage_dir=%s/clipboard-images\npaste_table=root\npaste_key=C-v\npaste_secondary_table=root\npaste_secondary_key=M-v\n' "$HOME" > "$dual_config"
    stop_real_server
    start_real_server "$dual_config"
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    binding=$(real_binding root C-v)
    [[ "$binding" == *CPCV_TMUX_PLUGIN=1* ]] || die 'tmux run-shell did not install the managed macOS Ctrl-V hook'
    binding=$(real_binding root M-v)
    [[ "$binding" == *CPCV_TMUX_PLUGIN=1* ]] || die 'tmux run-shell did not install the managed Windows Alt-V hook'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux bind-key -T root C-v display-message CPCV_TMUX_PLUGIN=1-old
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    legacy=$(real_binding root C-v)
    [[ -z "$legacy" ]] || die 'tmux plugin did not migrate a managed legacy root Ctrl-V binding'
    binding=$(real_binding prefix v)
    [[ "$binding" == *CPCV_TMUX_PLUGIN=1* ]] || die 'tmux plugin did not replace the managed legacy binding'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux bind-key -T root C-v display-message CPCV_TMUX_PLUGIN=1-old
    TMUX_TMPDIR="$real" tmux bind-key -T prefix v display-message existing-user-binding
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    legacy=$(real_binding root C-v)
    [[ -z "$legacy" ]] || die 'target collision did not release a managed legacy root Ctrl-V binding'
    binding=$(real_binding prefix v)
    [[ "$binding" == *existing-user-binding* && "$binding" != *CPCV_TMUX_PLUGIN=1* ]] || \
      die 'tmux plugin overwrote a user prefix/v binding during migration'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux bind-key -T root M-v display-message CPCV_TMUX_PLUGIN=1-old
    TMUX_TMPDIR="$real" tmux set-option -g @cpcv-paste-key M-v
    TMUX_TMPDIR="$real" tmux set-option -g @cpcv-paste-table prefix
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    legacy=$(real_binding root M-v)
    [[ -z "$legacy" ]] || die 'tmux plugin left a managed custom root binding after a table move'
    binding=$(real_binding prefix M-v)
    [[ "$binding" == *CPCV_TMUX_PLUGIN=1* ]] || die 'tmux plugin did not move a custom root key to prefix'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux bind-key -T root C-v display-message existing-user-binding
    TMUX_TMPDIR="$real" tmux set-option -g @cpcv-paste-key C-V
    TMUX_TMPDIR="$real" tmux set-option -g @cpcv-paste-table root
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    binding=$(real_binding root C-v)
    [[ "$binding" == *existing-user-binding* && "$binding" != *CPCV_TMUX_PLUGIN=1* ]] || \
      die 'tmux plugin overwrote a canonical user binding through C-V'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux set-option -g @cpcv-paste-key C-v
    TMUX_TMPDIR="$real" tmux run-shell "$root/cpcv.tmux"
    binding=$(real_binding root C-v)
    [[ "$binding" == *CPCV_TMUX_PLUGIN=1* ]] || die 'tmux plugin did not preserve a legacy key-only Ctrl-V configuration'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux bind-key -T root C-v run-shell -b '~/.local/bin/cpcv-latest --pane "#{pane_id}"'
    TMUX_TMPDIR="$real" tmux source-file "$root/tmux-cpcv.conf"
    legacy=$(real_binding root C-v)
    [[ -z "$legacy" ]] || die 'compatibility config did not remove its old root Ctrl-V binding'
    binding=$(real_binding prefix v)
    [[ "$binding" == *cpcv-latest* ]] || die 'compatibility config did not bind prefix/v'
    [[ "$binding" == *'#{pane_id}'* ]] || die 'compatibility config expanded pane_id while sourcing'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux bind-key -T root C-v display-message existing-user-binding
    TMUX_TMPDIR="$real" tmux source-file "$root/tmux-cpcv.conf"
    binding=$(real_binding root C-v)
    [[ "$binding" == *existing-user-binding* ]] || die 'compatibility config removed an unrelated root Ctrl-V binding'

    stop_real_server
    start_real_server
    TMUX_TMPDIR="$real" tmux bind-key -T prefix v display-message existing-user-binding
    TMUX_TMPDIR="$real" tmux source-file "$root/tmux-cpcv.conf"
    binding=$(real_binding prefix v)
    [[ "$binding" == *existing-user-binding* && "$binding" != *CPCV_TMUX_COMPAT=1* ]] || \
      die 'compatibility config overwrote an unrelated prefix/v binding'
  )
fi

printf 'PASS: tmux plugin uses a targeted transient buffer and preserves the host clipboard.\n'
