# Platform support

imgpaste is a private-first, local clipboard-to-SSH utility. It does not need a
public repository, a hosted service, a replacement screenshot app, or an
administrator-installed background service.

## Current support

| Platform | Client | Autostart | Status UI |
| --- | --- | --- | --- |
| Windows 10/11 | PowerShell watcher and guardian | Current-user Startup shortcut | Optional WinForms notification-area app |
| macOS 11+ | Native Swift/AppKit watcher and guardian | Current-user GUI LaunchAgent | Optional native menu-bar app |

Both clients observe images already placed on the platform clipboard, then use
the system OpenSSH `ssh` and `scp` clients to upload to a generic SSH alias,
hostname, or `user@host`. Neither client captures the screen itself.

## Configuration

Configuration is private local data. Keep host aliases, proxy details,
usernames, keys, tokens, screenshots, logs, cache, and state out of the
checkout.

| Platform | Default private configuration | Example |
| --- | --- | --- |
| Windows | `%LOCALAPPDATA%\imgpaste\config.psd1` | `imgpaste.config.example.psd1` |
| macOS | `~/Library/Application Support/imgpaste/config.json` | `macos/imgpaste.macos.config.example.json` |

The macOS parser accepts only JSON data and validates `hostAlias`, relative
`remoteDir`, optional absolute POSIX `remoteHome`, data-root, size limits,
timeouts, cache limits, and watchdog timing before launching SSH. A custom
`IMGPASTE_CONFIG` value must be an absolute local file path. Put credentials
and `ProxyCommand` rules in your own SSH configuration, never in imgpaste JSON
or source.

## macOS lifecycle

macOS support is source-installed, not a signed application bundle. It requires
macOS 11 or newer, Xcode Command Line Tools, and a logged-in graphical desktop
session. It uses only these project-owned user labels:

- `io.imgpaste.guardian` runs the native guardian in `gui/$UID`.
- `io.imgpaste.tray` runs the optional menu-bar companion in `gui/$UID`.

`macos/install-macos.sh` builds the native uploader with `swiftc`, records the
selected private configuration path, writes a managed LaunchAgent, and starts
the guardian. `macos/install-tray.sh` builds and installs the optional menu
bar companion after the uploader is present. Both reject `sudo`, a missing GUI
domain, a symlinked target, and an unrelated existing LaunchAgent label.
The guardian and optional tray have a fixed PATH containing standard system
locations plus the Apple Silicon and Intel Homebrew locations, so an SSH
`ProxyCommand` can use tools such as `cloudflared` when imgpaste runs in the
background.

Use `macos/imgpaste-macos-ctl.sh` for fixed local actions only:

```text
status | start | stop | restart | logs | upload | config | settings-read | settings-save | doctor
```

It never accepts a shell fragment or builds a shell command from settings.
`status` emits bounded JSON with operational state and no raw subprocess output. `uninstall-macos.sh` and
`uninstall-tray.sh` remove only managed labels and preserve private data by
default.

## Tray and status controls

The tray is a local status/control client, never a second uploader.

- Windows uses a current-user `Local\ImgPaste-Tray-*` mutex; a duplicate
  launch exits harmlessly (including a second checkout for the same user).
- macOS uses a single managed `io.imgpaste.tray` LaunchAgent and calls the
  project-owned control script with fixed action names.

Both interfaces show bounded, redacted state, copy the last validated remote
path, control the local service, and open local diagnostics. On Windows,
**View status** opens a dashboard with a
clear health banner, automatic-upload/heartbeat/latest-image cards, an
explicit refresh control, and context-sensitive recovery guidance. It keeps
remote paths out of casual display; use **Copy latest path** when you need it.
Neither interface accepts arbitrary commands, exposes raw SSH output in a
tooltip, or holds SSH credentials.

On macOS, the everyday menu contains a disabled status row, **Copy Last Image
Path**, one contextual pause/resume action, **Check & Repair**, and **Settings**.
Restart, recent activity, and internal status details are grouped under
**Troubleshooting**. The icon is a checkmark while healthy, a spinner during an
upload or repair, and a warning triangle when either the watcher or latest
Doctor report needs attention. Successful routine actions do not interrupt the
user with dialogs.

**Settings** is a form for the SSH target, remote image folder, optional remote
home, and upload interval. It validates inputs before saving and restarts the
owned uploader so a changed target takes effect. Editing raw JSON remains an
advanced fallback only.

Doctor validates configuration, the owned local LaunchAgent, SSH reachability,
remote-directory writability, and the optional marked Codex bridge. It repairs
only existing project-owned services and files; an absent optional bridge stays
absent. It refuses unrelated same-name services and reports problems without
making broad system changes.

## Optional native Codex image paste on Linux

Automatic uploads preserve the source image on the macOS clipboard. Native
Codex running inside a headless Linux SSH/tmux session is different: it
uses the process's X11 or Wayland clipboard and does not invoke the optional
`xclip` helper. Direct image paste therefore needs a remote display and an
image selection owner.

`macos/deploy-remote-codex-x11-bridge.sh` is an explicit opt-in deployment for
a configured Linux SSH host. It stages `remote/install-codex-x11-bridge.sh`,
which creates a per-user `:98` Xvfb display, private Xauthority cookie, and
two owned user systemd services. The bridge follows the configured remote
directory's `latest.png` symlink and publishes it as the X11 `image/png`
clipboard selection. It never modifies the system X server or shadows global
clipboard commands.

The deployment's default zsh integration wraps only `codex`, leaving SSH X
forwarding unchanged for other programs. Newly launched Codex processes use
the private display; existing processes must be restarted. The installer warns
when user-systemd lingering is disabled because services can stop after logout.
Run the remote test script after an upload to compare the X11 clipboard bytes
with `latest.png` before testing the Codex TUI manually.

The installed `imgpaste-codex-x11-uninstall` command disables and removes only
the two marked user units, bridge files, Xauthority data, and managed zsh
block. It preserves uploaded images and the core imgpaste configuration.

## Optional tmux path paste

`imgpaste.tmux` inserts the configured remote `latest.png` path into the pane
that triggered it, using a transient tmux buffer. It does not change an OS
clipboard. Source the plugin's printed `run-shell` line in a user-owned tmux
config. Its default capture key is `Ctrl-V`; if that key is already bound,
imgpaste leaves it unchanged, and `@imgpaste-paste-key` can select an unused
tmux key before sourcing the plugin. Warp consumes `Cmd-V` and cannot map it
to a raw control key, so use `Ctrl-V` with Warp.

The plugin appends `imgpaste · 2 sec ago` to tmux's right status area. This is
the age of `latest.png` on the target server, calculated entirely on that
server. The first plugin load sets tmux's shared status interval to two seconds
and later respects a user-managed interval. Set `@imgpaste-status off` to hide it or
`@imgpaste-status-refresh 5` before sourcing the plugin to change its default
refresh interval. The macOS Doctor checks that host and target clocks differ
by no more than five seconds.

## Reliability and security invariants

Every platform implementation must preserve these guarantees:

- A hard wall-clock timeout kills the complete SSH/SCP child-process tree,
  including a ProxyCommand child.
- Standard output and error are continuously drained but only retained to a
  configured cap, then redacted before logs or UI display.
- A guardian treats missing, stale, corrupt, or PID-mismatched health state as
  unhealthy and recovers one matching watcher.
- Clipboard changes during an upload cannot update `latest.png`, local state,
  or the user's clipboard for an obsolete image.
- Cache retention is bounded by both file count and total bytes; failed retries
  reuse a content-addressed image rather than creating unbounded files.
- SSH arguments are passed as argument arrays. Configured hosts and paths are
  strictly validated before a remote shell sees the limited, generated command.
- Local state, cache, logs, locks, and build outputs are restricted to the
  current user where the operating system permits it.

## Packaging boundary

The macOS client and menu-bar app compile locally from source. They are not
notarized, code-signed app bundles. Do not describe them as such or distribute
unsigned binaries as a production download. A future binary release needs
separate signing identities, protected CI secrets, checksums, notarization,
and fresh-machine verification. Keep the repository and all artifacts private
until the owner explicitly changes that decision.
