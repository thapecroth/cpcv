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

Use `macos/imgpaste-macos-ctl.sh` for fixed local actions only:

```text
status | start | stop | restart | logs | upload | config
```

It never accepts a shell fragment or host argument. `status` emits bounded JSON
with operational state and no raw subprocess output. `uninstall-macos.sh` and
`uninstall-tray.sh` remove only managed labels and preserve private data by
default.

## Tray and status controls

The tray is a local status/control client, never a second uploader.

- Windows uses a current-user `Local\ImgPaste-Tray-*` mutex; a duplicate
  launch exits harmlessly (including a second checkout for the same user).
- macOS uses a single managed `io.imgpaste.tray` LaunchAgent and calls the
  project-owned control script with fixed action names.

Both interfaces show bounded, redacted state and can request a one-shot upload,
copy the last validated remote path, start/stop/restart the local service, and
open local diagnostics. They never accept arbitrary commands, expose raw SSH
output in a tooltip, or hold SSH credentials.

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
