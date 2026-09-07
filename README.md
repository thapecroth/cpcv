# imgpaste

> Upload clipboard images to an SSH host while preserving the local image
> clipboard.

![Illustration of the imgpaste workflow](assets/imgpaste-workflow.png)

**imgpaste** watches the Windows or macOS image clipboard and uploads new
images to any POSIX host reachable through OpenSSH. It keeps a stable
`latest.png` path on the remote host without replacing your screenshot tool,
clipboard workflow, or SSH configuration.

It is private-first and designed for a personal workstation or small team. The
runtime does not need GitHub, a public repository, a hosted service, or a new
screenshot app. An SSH alias, hostname, or `user@host` is supported.
Cloudflare Access, tmux, agent integrations, xclip, and Wayland helpers are
optional; none is required for the core workflow.

## What it does

1. You take a normal screenshot or copy an image.
2. A background watcher notices the clipboard image.
3. imgpaste uploads it through your existing SSH configuration.
4. The remote host receives a timestamped PNG and updates
   `~/clipboard-images/latest.png` (or your configured directory).
5. Your original image remains on the local clipboard; tmux can insert the
   remote `latest.png` path into the target pane when needed.

imgpaste sends only clipboard images. It does not capture the screen, install a
screenshot application, or require a cloud service. See
[docs/platforms.md](docs/platforms.md) for platform status, autostart, tray
controls, and packaging boundaries.

## Platform status

- **Windows 10/11:** the established PowerShell watcher and guardian. The
  optional WinForms tray UI surfaces status and safe local controls.
- **macOS 11+:** a source-installed native AppKit watcher, guardian, and
  menu-bar companion. It needs Xcode Command Line Tools and runs only in the
  logged-in user's GUI session; it is not a signed or notarized app bundle.

Keep this repository and any release artifacts private until you decide to
publish them. Nothing in the installer or runtime changes repository visibility
or uploads source code.

## Requirements

All platforms need a working SSH connection to a POSIX host (Linux, macOS, or
a BSD-style shell) and an SSH alias, hostname, or `user@host`. Authentication
belongs in your normal SSH configuration or credential manager.

| Platform | Local requirements |
| --- | --- |
| Windows | Windows 10/11; Windows PowerShell 5.1 or newer PowerShell; built-in OpenSSH `ssh.exe` and `scp.exe`. |
| macOS | macOS 11 or newer; a logged-in desktop session; Xcode Command Line Tools (`swiftc`); built-in `/usr/bin/ssh` and `/usr/bin/scp`. |

An SSH alias is recommended because it keeps proxy details, usernames, keys,
and host verification out of this repository:

```sshconfig
Host image-box
  HostName example.net
  User alice
  IdentityFile ~/.ssh/id_ed25519
```

## Install

Clone from the private remote you are authorized to use, then select your
platform. Do not paste a personal host alias or configuration into the
repository.

```text
git clone <your-private-remote> imgpaste
```

### Windows

Create your private local configuration, then install the watcher:

```powershell
Set-Location imgpaste

$configDir = Join-Path $env:LOCALAPPDATA 'imgpaste'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item .\imgpaste.config.example.psd1 (Join-Path $configDir 'config.psd1')
notepad (Join-Path $configDir 'config.psd1')

# Set HostAlias, save, and test the connection before starting the watcher.
ssh image-box true
.\install-autostart.ps1
```

Set `HostAlias` in the config to `image-box`, or another usable SSH target.
The default stable remote path is `~/clipboard-images/latest.png`. Screenshot
or copy an image, wait roughly two seconds, then use the optional tmux paste
binding on the SSH host. Automatic uploads never replace the local image with
text; **Copy latest path** remains an explicit manual fallback.

#### Build a portable Windows archive

The Windows version is intentionally transparent PowerShell, not an opaque
third-party wrapper. From a clean checkout, build a ZIP containing only the
committed source tree:

```powershell
.\build-windows.ps1
```

The command writes `build\imgpaste-windows-<commit>.zip`, checks that the
archive contains the Windows runtime files, and refuses to include local
configuration, screenshots, cache, logs, or Git metadata. The archive is a
portable source distribution; extract it, create the private configuration,
then run `install-autostart.ps1` and optionally `install-tray.ps1`.

### macOS

Install Xcode Command Line Tools if necessary, create a private JSON
configuration, validate the SSH alias in a visible terminal, then install the
per-user guardian. The installer compiles source locally, creates only
`io.imgpaste.guardian` in your GUI `launchd` domain, and never uses `sudo` or a
root LaunchDaemon.

```bash
xcode-select --install # only if swiftc is not already available
mkdir -p "$HOME/Library/Application Support/imgpaste"
chmod 700 "$HOME/Library/Application Support/imgpaste"
cp macos/imgpaste.macos.config.example.json \
  "$HOME/Library/Application Support/imgpaste/config.json"
chmod 600 "$HOME/Library/Application Support/imgpaste/config.json"
${EDITOR:-vi} "$HOME/Library/Application Support/imgpaste/config.json"

ssh image-box true
bash macos/install-macos.sh
bash macos/imgpaste-macos-ctl.sh status
```

Install the optional menu-bar companion only after the uploader installation
succeeds. It observes the existing service; it is not a second watcher.

```bash
bash macos/install-tray.sh
```

### Private and forked checkouts

If you maintain a private fork or a separate clean release candidate, clone
the remote you are authorized to use and add an upstream only when its
visibility and history are understood:

```powershell
git clone <your-private-remote> imgpaste
Set-Location imgpaste
git remote -v
```

Do not commit your personal `HostAlias`, remote path, or local data location to
any remote. A clean release candidate must be populated from an approved source
tree export, never by merging or pushing private runtime history; see
[docs/private-release-mirror.md](docs/private-release-mirror.md).

## Configuration

Configuration is local-only and must remain outside the checkout. The platform
examples are safe to copy, but deliberately not working configurations.

| Platform | Default configuration | Override |
| --- | --- | --- |
| Windows | `%LOCALAPPDATA%\imgpaste\config.psd1` | `IMGPASTE_CONFIG` |
| macOS | `~/Library/Application Support/imgpaste/config.json` | `IMGPASTE_CONFIG` |

### Windows configuration

Set `IMGPASTE_CONFIG` to choose a different PowerShell data file, for example
in an automation session:

```powershell
$env:IMGPASTE_CONFIG = 'D:\private\imgpaste\config.psd1'
```

For a persistent user setting, use `setx IMGPASTE_CONFIG "D:\private\imgpaste\config.psd1"`,
open a new PowerShell session, and restart the guardian (or sign out and back
in) so the startup process receives it.

Keep an alternate configuration outside the checkout whenever possible. If it
must live in a clone, use `config.psd1`, `*.private.psd1`, or `*.local.psd1`;
these names are ignored. An arbitrary `IMGPASTE_CONFIG` filename is **not**
automatically protected, so add it to `.git/info/exclude` and confirm with
`git status --ignored` before committing. Never put passwords, private keys,
tokens, or proxy URLs in a tracked file.

Configuration values are loaded in this order: built-in defaults, the selected
config file, then the `IMGPASTE_HOST_ALIAS`, `IMGPASTE_REMOTE_DIR`, and
`IMGPASTE_REMOTE_HOME` environment variables. The latter three are useful for
automation and intentionally override the file.

| Setting | Default | Constraints and purpose |
| --- | --- | --- |
| `HostAlias` | required | SSH alias, hostname, or `user@host`. Use your SSH config for credentials and proxy details. |
| `RemoteDir` | `clipboard-images` | Relative POSIX directory below the remote home; nested paths are allowed, but absolute paths and `..` are rejected. |
| `RemoteHome` | empty | Optional absolute POSIX home used to form a pasteable fallback path before the first successful upload. Leave empty for `~/...`. |
| `DataRoot` | `%LOCALAPPDATA%\imgpaste` | Local state, logs, and image cache directory. |
| `CommandTimeoutSeconds` | `35` | Hard SSH/SCP wall-clock timeout; integer from 1 to 600. |
| `MaxCommandOutputBytes` | `65536` | Maximum captured subprocess output; integer from 1,024 to 1,048,576. |
| `PollIntervalSeconds` | `2` | Clipboard polling interval; integer from 1 to 60. |
| `WatchdogCheckSeconds` | `15` | Guardian health-check interval; integer from 1 to 300. |
| `WatchdogStaleSeconds` | `120` | Heartbeat age that causes guardian recovery; integer from 10 to 3,600 and at least `3 * CommandTimeoutSeconds + WatchdogCheckSeconds`. |
| `MaxLogBytes` | `1048576` | Per-log rotation threshold; integer from 65,536 to 104,857,600 bytes. |
| `MaxImageBytes` | `52428800` | Largest clipboard image accepted before any disk write; integer from 1 MiB to 256 MiB and no larger than `MaxCacheBytes`. |
| `MaxCacheBytes` | `268435456` | Retained `clip-*.png` cache-byte cap; integer from 8 MiB to 1 GiB and always enforced. `latest.png` is a derived working copy. |
| `MaxCacheFiles` | `200` | Maximum retained `clip-*.png` files after pruning; integer from 0 to 10,000. `0` disables only count-based pruning; `MaxCacheBytes` remains enforced. |

`imgpaste.config.example.psd1` includes commented examples of every optional
setting. Settings are validated before they are used as SSH or SCP arguments.

### macOS configuration

Copy `macos/imgpaste.macos.config.example.json` to the default location above
and edit only that private copy. Its field names match the Windows safety
model: `hostAlias`, a relative `remoteDir`, optional absolute `remoteHome`,
hard command and watchdog limits, bounded output/logs, and cache/image caps.
It is parsed strictly as JSON; it is never evaluated as shell or Swift code.

An `IMGPASTE_CONFIG` override must be an absolute local path. If it is inside a
clone, add its exact filename to `.git/info/exclude` and verify it is ignored
before committing.

## Reliability, data, and diagnosis

- Each SSH/SCP command has a hard wall-clock timeout. On expiry imgpaste kills
  the complete process tree, including a hung SSH `ProxyCommand` child.
- A guardian monitors the watcher heartbeat and restarts a missing, stalled,
  corrupt-health, or duplicate watcher. On macOS it runs as a scoped
  per-user LaunchAgent, never a root service.
- Failures back off from 2 seconds to 60 seconds. imgpaste retries the current
  clipboard image; it is not a durable offline queue.
- Process output is bounded and credential-like URLs/tokens are redacted before
  logging, notifications, and status UI. The guardian also sanitizes historical
  log lines at startup.
- `DataRoot` contains screenshots in `cache`, logs, hash/path state, and the
  heartbeat. Image size and retained cache bytes are capped, but treat it as
  sensitive local data and set retention/backup policy accordingly.

The tray view is an optional status/control surface; it is not a second
uploader. Its compact menu shows current health, last-upload recency, copy-path,
pause/resume, Settings, and **Check & Repair**. Routine actions are silent;
warnings stay visible in the menu-bar icon and status row. Advanced restart,
activity, and status details live under **Troubleshooting**. See
[docs/platforms.md](docs/platforms.md#tray-and-status-controls).

### Windows diagnosis

Inspect the active configuration, recent log entries, and health record from
the repository root:

```powershell
. .\imgpaste-core.ps1
$cfg = Get-ImgPasteConfig
$cfg | Format-List HostAlias, RemoteDir, DataRoot, LogFile, HeartbeatFile, ConfigError
Get-Content -LiteralPath $cfg.LogFile -Tail 80
Get-Content -LiteralPath $cfg.HeartbeatFile
```

If SSH authentication needs interaction, open a visible terminal and run
`ssh <HostAlias>` once. The watcher will retry automatically. To upload the
current clipboard image once and receive a visible result, run
`.\imgpaste-now.ps1`.

The optional Windows tray can be installed separately with
`.\install-tray.ps1`; it exposes upload, start/stop/restart, logs, config,
data-folder, and copy-latest-path actions without storing SSH credentials. Its
installer does not upload an image, alter SSH configuration, or restart the
uploader. To run it manually, use `powershell.exe -NoProfile -STA
-ExecutionPolicy RemoteSigned -File .\imgpaste-tray.ps1`.

### macOS diagnosis

Use the fixed-action controller rather than editing a LaunchAgent or killing
process names directly:

```bash
bash macos/imgpaste-macos-ctl.sh status
bash macos/imgpaste-macos-ctl.sh doctor
bash macos/imgpaste-macos-ctl.sh logs
bash macos/imgpaste-macos-ctl.sh restart
```

`doctor` checks the local LaunchAgent, SSH connection, remote upload directory,
and an explicitly installed Codex X11 bridge. It can restart owned components,
repair a managed bridge, and create the configured remote directory. A bridge
removed with its uninstaller stays absent. Invalid settings, authentication,
package, permission, and ownership problems are reported without broad system
changes.
The menu-bar companion runs this same action through **Check & Repair** and
keeps the latest result in its status display. It does not show raw SSH output
or store SSH credentials.

## Optional remote helpers and legacy Windows artifacts

The core uploader on either platform needs only SSH. The optional Windows
remote-helper installation writes named helpers plus an opt-in tmux plugin to
the configured remote host:

```powershell
.\install-autostart.ps1 -DeployRemoteHelpers
```

- `imgpaste-latest` prints the latest image path, or inserts it into its
  originating tmux pane.
- `imgpaste-xclip` and `imgpaste-wl-paste` are named wrappers for tools that
  explicitly opt in to imgpaste image handling.
- The installer prints one `run-shell` line to add to a user-owned tmux config.

The installer does not edit shell rc files, `PATH`, tmux startup files,
Claude/agent settings, or global `xclip`/`wl-paste` commands. Do not symlink
helpers over real commands unless you intentionally own and test that
integration. Add `~/.local/bin` to remote `PATH` yourself if you invoke the
prefixed helpers directly.

### Tmux path paste

The tmux plugin is the path-paste workflow for an SSH terminal. It uses a
pane-specific transient tmux buffer, pastes only `latest.png` into that pane,
and never writes the host clipboard. Add the `run-shell` line printed by either
installer, then reload tmux. The default capture key is `Ctrl-V`; map your
terminal's `Cmd-V` shortcut to send `Ctrl-V` while tmux is active. Terminals
normally consume raw `Cmd-V`, so tmux cannot capture it without that terminal
mapping. If `Ctrl-V` is already bound, imgpaste leaves that binding alone; set
`@imgpaste-paste-key` to an unused tmux key before sourcing the plugin.

On macOS, explicitly deploy the plugin to the configured SSH host with:

```bash
bash macos/deploy-remote-tmux-imgpaste-plugin.sh --host image-box
```

For Windows compatibility, `setup-imgpaste.ps1`, `enable-auto-paste.ps1`, and
`setup-imgpaste.cmd` delegate to the current installer with a warning.
`install-path-shims.sh` is a no-op deprecation notice; it no longer shadows
`xclip` or `wl-paste`. `deploy-remote.sh` is an advanced manual helper installer
for files already staged on a remote host. New installations should use
`install-autostart.ps1`.

### Native Codex image paste on a Linux SSH host

Native Codex on a headless Linux SSH host reads its own X11 or Wayland
clipboard; it does not call `xclip`, so tmux path insertion and direct image
paste are separate opt-in workflows.

For an explicit Linux/Codex integration, macOS can deploy a private per-user
Xvfb display and a bridge that republishes `latest.png` as `image/png`:

```bash
bash macos/deploy-remote-codex-x11-bridge.sh --host image-box
```

The deployment uses `:98` by default, a private Xauthority cookie, two owned
user systemd services, and no global `xclip`/`wl-paste` replacement. It adds a
managed `~/.zshrc` wrapper that applies the bridge environment only to **new**
Codex sessions. If `codex` is already a zsh alias, use `--no-zsh-env` and add a
compatible wrapper yourself. Existing Codex processes must be exited and
started again.
Verify the remote clipboard with:

```bash
ssh image-box '~/.local/lib/imgpaste/imgpaste-codex-x11-test'
```

Do not point this integration at another application's X server; choose a free
display number if `:98` is occupied. Remove only this optional bridge with:

```bash
ssh image-box '~/.local/lib/imgpaste/imgpaste-codex-x11-uninstall'
```

## Update and uninstall

### Windows

Rerun `install-autostart.ps1` after updating the checkout to refresh its local
shortcuts and command wrappers. If you use the optional tray, rerun
`install-tray.ps1` as well. Restart the guardian after changing its config or
use a new logon session so it reloads the values.

Use the dedicated uninstaller from this checkout to remove the local Startup
and Start Menu shortcuts, command wrappers, and process trees launched from
this checkout. Review its targets first, then run it without `-WhatIf`:

```powershell
.\uninstall-autostart.ps1 -WhatIf
.\uninstall-autostart.ps1
```

The default preserves the checkout, local config, screenshots, logs, state, and
remote images. Removal of those data stores is explicit:

```powershell
.\uninstall-autostart.ps1 -RemoveRemoteHelpers
.\uninstall-autostart.ps1 -RemoveRemoteHelpers -RemoveRemoteImages
.\uninstall-autostart.ps1 -RemoveLocalData -RemoveLocalConfig
```

`-RemoveRemoteImages` requires `-RemoveRemoteHelpers` so the remote target is
intentional. `-RemoveLocalData` only removes the default `%LOCALAPPDATA%\imgpaste`
folder; it refuses a custom `DataRoot` so you can inspect it manually.
`-RemoveLocalConfig` removes the active `IMGPASTE_CONFIG` path if one is set.
Do not remove a checkout until its startup integration and active
guardian/watcher have been stopped.

Remove the optional tray separately; this also preserves configuration and
captured images:

```powershell
.\uninstall-tray.ps1 -WhatIf
.\uninstall-tray.ps1
```

Pass `-KeepRunning` only when you intentionally want to remove the Startup
shortcut but leave this checkout's already-running tray process alive.

### macOS

After an update, rerun the native installer to rebuild the local executable,
then restart only the scoped guardian. Rerun the tray installer too when using
the optional menu-bar app:

```bash
bash macos/install-macos.sh
bash macos/install-tray.sh
bash macos/imgpaste-macos-ctl.sh restart
```

The uninstallers remove only the matching user LaunchAgent(s). They preserve
the configuration, cache, logs, state, compiled executables, and remote images:

```bash
bash macos/uninstall-tray.sh
bash macos/uninstall-macos.sh
```

## Testing

The fast, network-free suites validate configuration-independent core behavior,
bounded output, redaction, retry behavior, process-tree cleanup, tray status,
and simulated clipboard/SSH failure recovery. They do not contact a real SSH
host or read a real clipboard in CI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\test-process-timeout.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\test-windows-e2e.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\test-tray.ps1
```

```bash
bash macos/test-macos.sh
bash tests/test-tmux-imgpaste.sh
```

`tests/test-guardian-recovery.ps1` intentionally restarts the local watcher;
run it only on a dedicated development machine. GitHub Actions runs safe
Windows and macOS checks while the repository remains private. The macOS job
builds the native sources and exercises a synthetic child-process timeout; it
does not read a real clipboard or contact an SSH host. The CodeQL workflow is
intentionally skipped on private repositories unless the owner enables the
required GitHub Code Security capability; a skipped scan is not a passing scan.
The Windows end-to-end test uses temporary local `ssh.exe`/`scp.exe` stand-ins
to verify the real upload process, remote-latest update, failure, and recovery
without accessing a real host or changing your clipboard.

## Contributing, security, releases, and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and release guidance,
[CHANGELOG.md](CHANGELOG.md) for user-visible changes, and
[SECURITY.md](SECURITY.md) for vulnerability reporting. Project artwork is
documented in [assets/README.md](assets/README.md). imgpaste is licensed under
the [MIT License](LICENSE). See [docs/testing-and-ci.md](docs/testing-and-ci.md)
for quality gates and [docs/private-release-mirror.md](docs/private-release-mirror.md)
for the safe private-candidate workflow. Use the
[private release-readiness checklist](docs/release-readiness-checklist.md)
before sharing a build or candidate.
