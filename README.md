# cpcv

> Keep an image on your Mac or Windows clipboard, upload it over SSH, and paste
> its remote path into the exact tmux pane that needs it.

![Illustration of the cpcv workflow](assets/cpcv-workflow.png)

cpcv is built around a small, practical tmux workflow:

1. Take a screenshot or copy an image normally.
2. cpcv uploads it to your SSH target and updates `latest.png`.
3. Press `Ctrl-V` in tmux.
4. The remote path is inserted only into the active tmux pane.

The local clipboard stays an image. cpcv never silently replaces it with a
file path or text.

## Download a release

Every annotated `vX.Y.Z` tag on `main` automatically builds and publishes two
portable ZIPs on the [Releases page](https://github.com/thapecroth/cpcv/releases),
plus `SHA256SUMS.txt`:

- `cpcv-vX.Y.Z-windows.zip` contains the readable PowerShell client, installers,
  source, and branded assets. It is not an EXE or MSI.
- `cpcv-vX.Y.Z-macos-universal.zip` contains source plus prebuilt arm64 and
  x86_64 macOS 11+ binaries. They are ad-hoc signed, not Developer ID signed or
  notarized.

Download the matching ZIP and `SHA256SUMS.txt`, then compare the ZIP's SHA-256
with the matching line before extracting it. Do not run an asset whose checksum
does not match.

On Windows, extract the ZIP, open PowerShell in the extracted `cpcv-windows`
folder, create `%LOCALAPPDATA%\cpcv\config.psd1` from the included example, then
run `./install-autostart.ps1` and `./install-tray.ps1`. The branded notification
area icon starts immediately and at sign-in; its hover text, menu, and dashboard
show the latest successful upload age without exposing your SSH host or path.

On macOS, extract the universal ZIP, enter its `cpcv` folder, and run:

```bash
bash macos/install-macos.sh --prebuilt
bash macos/install-tray.sh --prebuilt
```

The macOS bundle does not need Xcode Command Line Tools, but macOS may require
you to explicitly approve the verified, non-notarized binaries in Gatekeeper.
The installers still require macOS 11+ and a logged-in graphical desktop
session.

## Start here: tmux path paste

The remote plugin is the primary way to use cpcv. It uses a pane-specific,
transient tmux buffer, so the image path goes only to the pane where you pressed
the key. It does not use or alter the host clipboard.

### macOS

For a source checkout, first install the uploader and its menu-bar app. The
menu-bar **Settings…**
screen lets you choose the SSH target, remote folder, optional remote home, and
upload interval without editing JSON.

```bash
xcode-select --install # only when swiftc is not already available
bash macos/install-macos.sh
bash macos/install-tray.sh
```

Then deploy the tmux plugin to the SSH host that receives your images:

```bash
bash macos/deploy-remote-tmux-cpcv-plugin.sh --host image-box
```

On that SSH host, add this one line to your own `~/.tmux.conf`:

```tmux
run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux
```

Reload an existing tmux server immediately:

```bash
tmux run-shell "$HOME/.local/lib/cpcv/tmux/cpcv.tmux"
```

For persistence after editing `~/.tmux.conf`:

```bash
tmux source-file ~/.tmux.conf
```

Copy an image, wait for the menu-bar icon to report an upload, then press
**Ctrl-V** in the remote tmux pane.

### Windows

Create a private configuration outside the checkout, then install the watcher
and deploy the optional tmux files:

```powershell
Set-Location cpcv
$configDir = Join-Path $env:LOCALAPPDATA 'cpcv'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item .\cpcv.config.example.psd1 (Join-Path $configDir 'config.psd1')
notepad (Join-Path $configDir 'config.psd1')

# Set HostAlias, then verify normal SSH works.
ssh image-box true
.\install-autostart.ps1 -DeployRemoteHelpers
.\install-tray.ps1
```

Add the printed `run-shell` line to the remote tmux configuration, then load it
with the same `tmux run-shell` command shown above.

## What you see in tmux

Once loaded, the plugin adds a compact status item on the right side of tmux:

```text
cpcv · 2 sec ago
```

It is the age of the most recent upload on the SSH target. The calculation uses
the target's own `latest.png` timestamp and clock, so a mismatched local clock
cannot make the label lie. The macOS **Check & Repair** action additionally
checks host/target clock drift and flags a difference greater than five seconds.

Tmux has one shared status refresh interval. The first plugin load sets it to
two seconds, then respects a later interval you manage yourself. Put either
setting before the plugin's `run-shell` line if you want to change it:

```tmux
# Hide the status item.
set -g @cpcv-status off

# Keep it visible but refresh every five seconds.
set -g @cpcv-status-refresh 5
```

If `Ctrl-V` is already used by your tmux configuration, cpcv leaves that
binding alone. Pick another tmux key before the `run-shell` line:

```tmux
set -g @cpcv-paste-key M-v
```

### About Command-V

`Cmd-V` belongs to the terminal application, not tmux. Many terminals consume
it before tmux can receive a key. In Warp, `Cmd-V` is Warp's native paste action
and its keybinding editor cannot send a raw `Ctrl-V` byte to tmux. Use physical
**Ctrl-V** in Warp. Other terminals may offer an explicit raw-control-key
mapping; only enable one if it sends `Ctrl-V` while the tmux pane is focused.

## Everyday workflow

| You do | cpcv does |
| --- | --- |
| Screenshot or copy an image | Leaves the image on the local clipboard. |
| Wait for automatic upload | Stores a timestamped image remotely and advances `latest.png`. |
| Press `Ctrl-V` in a tmux pane | Inserts the remote `latest.png` path into that pane only. |
| Check the tmux status bar | Shows the target-side age of the latest upload. |
| Choose **Copy Latest Image Path** in the tray | Explicitly copies the path as text; this is the manual fallback. |

`latest.png` defaults to `~/clipboard-images/latest.png` on the SSH target.
The uploader needs only your existing SSH configuration; it does not require a
cloud service, a screenshot replacement, GitHub, or a remote agent.

## Changing your target

On macOS, open the cpcv menu-bar icon and choose **Settings…**. Change the
SSH target or remote folder, save, then deploy the tmux plugin to that new host:

```bash
bash macos/deploy-remote-tmux-cpcv-plugin.sh --host new-image-box
```

Load the plugin in that host's tmux server as shown above. Saving Settings
restarts an active local uploader safely; a paused uploader remains paused.

On Windows, update the private `config.psd1`, restart the watcher, and rerun
`install-autostart.ps1 -DeployRemoteHelpers` for a newly selected SSH target.

## Check that it is working

On macOS, the menu-bar icon is the simplest status view. **View Recent
Activity…** starts with the last successful upload and remote image path; an
empty diagnostic log is normal when there have been no failures.

The command-line checks are useful too:

```bash
bash macos/cpcv-macos-ctl.sh status
bash macos/cpcv-macos-ctl.sh doctor
bash macos/cpcv-macos-ctl.sh logs
```

`doctor` verifies the local service, SSH reachability, remote directory, clock
synchronization, and any already-installed optional Codex bridge. It repairs
only cpcv-owned components.

On the SSH target, inspect the plugin and status label directly:

```bash
tmux list-keys -T root | grep CPCV_TMUX_PLUGIN
~/.local/lib/cpcv/tmux/tmux/scripts/cpcv-tmux-status.sh
```

If `Ctrl-V` does nothing, first load the plugin into the running server again:

```bash
tmux run-shell "$HOME/.local/lib/cpcv/tmux/cpcv.tmux"
```

If the status says `no image`, copy an image locally and wait for the upload to
complete. Check **Check & Repair** if the local tray reports attention needed.

## Local requirements and configuration

| Platform | Needs |
| --- | --- |
| macOS | macOS 11+, a logged-in desktop session, Xcode Command Line Tools, built-in OpenSSH. |
| Windows | Windows 10/11, PowerShell 5.1+ or newer PowerShell, built-in OpenSSH. |
| SSH target | A POSIX shell, tmux for path paste, and your normal SSH authentication. |

Keep configuration private and outside the checkout:

| Platform | Default private configuration |
| --- | --- |
| macOS | `~/Library/Application Support/cpcv/config.json` |
| Windows | `%LOCALAPPDATA%\cpcv\config.psd1` |

The essential settings are an SSH alias/host, a relative remote directory, an
optional remote home, and an upload interval. Use the macOS Settings UI or the
provided private configuration examples. Full field descriptions and platform
details are in [docs/platforms.md](docs/platforms.md).

An SSH alias keeps usernames, keys, proxy settings, and host verification out
of cpcv configuration:

```sshconfig
Host image-box
  HostName example.net
  User alice
  IdentityFile ~/.ssh/id_ed25519
```

## Privacy and safety

- Automatic uploads send only image clipboard content; they do not replace the
  image clipboard with text.
- SSH/SCP commands have hard timeouts and bounded, redacted diagnostic output.
- Guardians restart only their matching local watcher; macOS uses per-user
  LaunchAgents and never requires `sudo`.
- Remote installation writes only marked cpcv plugin files. It does not
  edit shell startup files, `PATH`, or your tmux configuration.
- Local image caches, logs, and state can contain sensitive data. Retention is
  bounded, but choose your own backup and privacy policy.

## Optional: native Codex image clipboard on the SSH host

Tmux path paste and native image paste are separate workflows. If you run
native Codex on a Linux SSH host and explicitly want it to read images as a
clipboard, the optional bridge creates a private per-user Xvfb/X11 clipboard:

```bash
bash macos/deploy-remote-codex-x11-bridge.sh --host image-box
ssh image-box '~/.local/lib/cpcv/cpcv-codex-x11-test'
```

It does not replace global `xclip` or `wl-paste`. See
[docs/platforms.md](docs/platforms.md#native-codex-image-paste-on-a-linux-ssh-host)
before enabling it.

## Update or remove

After updating a macOS source checkout, rebuild both local pieces:

```bash
bash macos/install-macos.sh
bash macos/install-tray.sh
```

For an extracted macOS release bundle, use the `--prebuilt` commands shown in
[Download a release](#download-a-release) instead.

After updating the remote plugin source, redeploy it and reload the active tmux
server:

```bash
bash macos/deploy-remote-tmux-cpcv-plugin.sh --host image-box
ssh image-box 'tmux run-shell "$HOME/.local/lib/cpcv/tmux/cpcv.tmux"'
```

Uninstallers preserve your configuration, cached images, and remote images
unless you explicitly ask them to remove those data stores:

```bash
bash macos/uninstall-tray.sh
bash macos/uninstall-macos.sh
```

```powershell
.\uninstall-tray.ps1 -WhatIf
.\uninstall-autostart.ps1 -WhatIf
```

## Development and tests

```bash
bash macos/test-macos.sh
bash tests/test-tmux-cpcv.sh
```

Windows tests are documented in [docs/testing-and-ci.md](docs/testing-and-ci.md).
For security and release guidance, see [SECURITY.md](SECURITY.md),
[CONTRIBUTING.md](CONTRIBUTING.md), and [docs/platforms.md](docs/platforms.md).

cpcv is licensed under the [MIT License](LICENSE).
