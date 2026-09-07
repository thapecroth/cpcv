# imgpaste

> Keep an image on your Mac or Windows clipboard, upload it over SSH, and paste
> its remote path into the exact tmux pane that needs it.

![Illustration of the imgpaste workflow](assets/imgpaste-workflow.png)

imgpaste is built around a small, practical tmux workflow:

1. Take a screenshot or copy an image normally.
2. imgpaste uploads it to your SSH target and updates `latest.png`.
3. Press `Ctrl-V` in tmux.
4. The remote path is inserted only into the active tmux pane.

The local clipboard stays an image. imgpaste never silently replaces it with a
file path or text.

## Start here: tmux path paste

The remote plugin is the primary way to use imgpaste. It uses a pane-specific,
transient tmux buffer, so the image path goes only to the pane where you pressed
the key. It does not use or alter the host clipboard.

### macOS

First install the uploader and its menu-bar app. The menu-bar **Settings…**
screen lets you choose the SSH target, remote folder, optional remote home, and
upload interval without editing JSON.

```bash
xcode-select --install # only when swiftc is not already available
bash macos/install-macos.sh
bash macos/install-tray.sh
```

Then deploy the tmux plugin to the SSH host that receives your images:

```bash
bash macos/deploy-remote-tmux-imgpaste-plugin.sh --host image-box
```

On that SSH host, add this one line to your own `~/.tmux.conf`:

```tmux
run-shell ~/.local/lib/imgpaste/tmux/imgpaste.tmux
```

Reload an existing tmux server immediately:

```bash
tmux run-shell "$HOME/.local/lib/imgpaste/tmux/imgpaste.tmux"
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
Set-Location imgpaste
$configDir = Join-Path $env:LOCALAPPDATA 'imgpaste'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item .\imgpaste.config.example.psd1 (Join-Path $configDir 'config.psd1')
notepad (Join-Path $configDir 'config.psd1')

# Set HostAlias, then verify normal SSH works.
ssh image-box true
.\install-autostart.ps1 -DeployRemoteHelpers
```

Add the printed `run-shell` line to the remote tmux configuration, then load it
with the same `tmux run-shell` command shown above.

## What you see in tmux

Once loaded, the plugin adds a compact status item on the right side of tmux:

```text
imgpaste · 2 sec ago
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
set -g @imgpaste-status off

# Keep it visible but refresh every five seconds.
set -g @imgpaste-status-refresh 5
```

If `Ctrl-V` is already used by your tmux configuration, imgpaste leaves that
binding alone. Pick another tmux key before the `run-shell` line:

```tmux
set -g @imgpaste-paste-key M-v
```

### About Command-V

`Cmd-V` belongs to the terminal application, not tmux. Many terminals consume
it before tmux can receive a key. In Warp, `Cmd-V` is Warp's native paste action
and its keybinding editor cannot send a raw `Ctrl-V` byte to tmux. Use physical
**Ctrl-V** in Warp. Other terminals may offer an explicit raw-control-key
mapping; only enable one if it sends `Ctrl-V` while the tmux pane is focused.

## Everyday workflow

| You do | imgpaste does |
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

On macOS, open the imgpaste menu-bar icon and choose **Settings…**. Change the
SSH target or remote folder, save, then deploy the tmux plugin to that new host:

```bash
bash macos/deploy-remote-tmux-imgpaste-plugin.sh --host new-image-box
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
bash macos/imgpaste-macos-ctl.sh status
bash macos/imgpaste-macos-ctl.sh doctor
bash macos/imgpaste-macos-ctl.sh logs
```

`doctor` verifies the local service, SSH reachability, remote directory, clock
synchronization, and any already-installed optional Codex bridge. It repairs
only imgpaste-owned components.

On the SSH target, inspect the plugin and status label directly:

```bash
tmux list-keys -T root | grep IMGPASTE_TMUX_PLUGIN
~/.local/lib/imgpaste/tmux/tmux/scripts/imgpaste-tmux-status.sh
```

If `Ctrl-V` does nothing, first load the plugin into the running server again:

```bash
tmux run-shell "$HOME/.local/lib/imgpaste/tmux/imgpaste.tmux"
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
| macOS | `~/Library/Application Support/imgpaste/config.json` |
| Windows | `%LOCALAPPDATA%\imgpaste\config.psd1` |

The essential settings are an SSH alias/host, a relative remote directory, an
optional remote home, and an upload interval. Use the macOS Settings UI or the
provided private configuration examples. Full field descriptions and platform
details are in [docs/platforms.md](docs/platforms.md).

An SSH alias keeps usernames, keys, proxy settings, and host verification out
of imgpaste configuration:

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
- Remote installation writes only marked imgpaste plugin files. It does not
  edit shell startup files, `PATH`, or your tmux configuration.
- Local image caches, logs, and state can contain sensitive data. Retention is
  bounded, but choose your own backup and privacy policy.

## Optional: native Codex image clipboard on the SSH host

Tmux path paste and native image paste are separate workflows. If you run
native Codex on a Linux SSH host and explicitly want it to read images as a
clipboard, the optional bridge creates a private per-user Xvfb/X11 clipboard:

```bash
bash macos/deploy-remote-codex-x11-bridge.sh --host image-box
ssh image-box '~/.local/lib/imgpaste/imgpaste-codex-x11-test'
```

It does not replace global `xclip` or `wl-paste`. See
[docs/platforms.md](docs/platforms.md#native-codex-image-paste-on-a-linux-ssh-host)
before enabling it.

## Update or remove

After updating a macOS checkout, rebuild both local pieces:

```bash
bash macos/install-macos.sh
bash macos/install-tray.sh
```

After updating the remote plugin source, redeploy it and reload the active tmux
server:

```bash
bash macos/deploy-remote-tmux-imgpaste-plugin.sh --host image-box
ssh image-box 'tmux run-shell "$HOME/.local/lib/imgpaste/tmux/imgpaste.tmux"'
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
bash tests/test-tmux-imgpaste.sh
```

Windows tests are documented in [docs/testing-and-ci.md](docs/testing-and-ci.md).
For security, releases, and private-fork guidance, see [SECURITY.md](SECURITY.md),
[CONTRIBUTING.md](CONTRIBUTING.md), and
[docs/private-release-mirror.md](docs/private-release-mirror.md).

imgpaste is licensed under the [MIT License](LICENSE).
