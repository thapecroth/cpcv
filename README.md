<p align="center">
  <img src="assets/windows/cpcv-logo.png" width="96" alt="cpcv clipboard upload icon">
</p>

<h1 align="center">cpcv</h1>

<p align="center">
  <strong>Screenshot locally. Paste the remote path into the tmux pane you mean.</strong>
</p>

<p align="center">
  <a href="https://github.com/thapecroth/cpcv/releases/latest">Download</a> &middot;
  <a href="#quick-start">Quick start</a> &middot;
  <a href="docs/platforms.md">Documentation</a> &middot;
  <a href="SECURITY.md">Security</a>
</p>

<p align="center">
  <a href="https://github.com/thapecroth/cpcv/actions/workflows/ci.yml"><img src="https://github.com/thapecroth/cpcv/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="https://github.com/thapecroth/cpcv/releases/latest"><img src="https://img.shields.io/github/v/release/thapecroth/cpcv?display_name=tag&sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2563eb.svg" alt="MIT License"></a>
</p>

<p align="center">
  <img src="assets/cpcv-workflow.png" width="880" alt="A copied image is uploaded to an SSH target and its remote path is pasted into a tmux pane">
</p>

**No cloud account. Your existing SSH configuration. Your image clipboard stays an image.**

cpcv is a small desktop companion for a local-to-remote terminal workflow. It
watches images you already copied, uploads them to your own SSH target, and
lets tmux insert the remote `latest.png` path into only the active pane. It
does not capture your screen or silently replace your clipboard with text.

## Why cpcv?

| You need | cpcv gives you |
| --- | --- |
| Images available to a remote coding session | Automatic SSH/SCP upload to your own target. |
| A paste that lands in the right place | `Ctrl-V` inserts the path only in the tmux pane where you press it. |
| Confidence that the upload happened | A Windows tray icon or macOS menu-bar app shows service health and the age of the latest upload. |
| A simple, private setup | No hosted service, account, browser extension, or replacement screenshot tool. |

## Quick start

Most people should use a release install. It needs no source build: use the
Windows setup wizard or the macOS Homebrew formula. Transparent ZIP bundles
remain available for people who prefer them or need an offline install.

> **Before you start**
>
> - Use Windows 10/11 or macOS 11+.
> - Have a normal SSH connection to a POSIX host. `tmux` is required on that
>   host only for pane-specific `Ctrl-V` paste.
> - Replace `image-box` below with your own working SSH alias or host. Confirm
>   it works without an interactive prompt using
>   `ssh -o BatchMode=yes image-box true` before depending on cpcv.

### 1. Choose an install

| Your computer | Recommended | Alternative |
| --- | --- | --- |
| Windows 10/11 | `cpcv-vX.Y.Z-windows-setup.exe` from the [latest release](https://github.com/thapecroth/cpcv/releases/latest) | Transparent `cpcv-vX.Y.Z-windows.zip` |
| macOS 11+ (Apple Silicon or Intel) | `brew install thapecroth/cpcv/cpcv` | `cpcv-vX.Y.Z-macos-universal.zip` from the latest release |

The release page supplies `SHA256SUMS.txt`. Verify the exact Windows EXE or
ZIP you download before running it. The Windows setup wizard is per-user and
does not need administrator privileges, but it is not Authenticode-signed yet;
Windows SmartScreen can warn about it. Do not override a warning for an
unverified download.

The macOS ZIP has prebuilt universal binaries, so it does not need Xcode
Command Line Tools. The Homebrew formula verifies that ZIP's checksum, but the
binaries are ad-hoc signed, not Developer ID signed or notarized. Gatekeeper
can still ask for explicit approval after verification.

### 2. Install and connect

#### Windows setup wizard (recommended)

Download `cpcv-vX.Y.Z-windows-setup.exe`, verify its SHA-256 entry in
`SHA256SUMS.txt`, and run it. After copying cpcv, Setup opens a short connection
guide. Enter the SSH connection name you would use with `ssh <name>` (for
example, `image-box` or `me@image-box`) and a relative remote image folder.
Use an SSH config alias for a custom port or proxy; keep passwords, keys, and
proxy rules in your normal SSH configuration. Existing private cpcv settings
are preserved.

The final setup-status page tells you whether the local watcher and tray app
started, whether the SSH computer accepted a non-interactive connection,
whether `tmux` is installed there, and whether the optional cpcv tmux plugin
files were installed. The tmux plugin task is off by default and Setup never
edits the remote `~/.tmux.conf`.

Setup starts the watcher and branded tray icon now and at sign-in. Confirm your
target when it is ready:

```powershell
ssh -o BatchMode=yes image-box true
```

#### Windows portable ZIP (advanced)

Open PowerShell in the extracted `cpcv-windows` folder and run:

```powershell
$configDir = Join-Path $env:LOCALAPPDATA 'cpcv'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item .\cpcv.config.example.psd1 (Join-Path $configDir 'config.psd1')
notepad (Join-Path $configDir 'config.psd1') # Set HostAlias to image-box, then save.

ssh image-box true
.\install-autostart.ps1 -DeployRemoteHelpers
.\install-tray.ps1
```

The watcher and branded tray icon start now and at sign-in. Keep passwords,
keys, and proxy rules in your normal SSH configuration—not in `config.psd1`.

If you only want automatic uploads and not tmux paste, omit
`-DeployRemoteHelpers`.

Do not run a portable install and the setup-wizard install at the same time.
Remove the old portable startup/tray integration before switching to Setup.

#### macOS with Homebrew (recommended)

```bash
brew install thapecroth/cpcv/cpcv
cpcv-setup
```

Homebrew installs the package only; `cpcv-setup` explicitly creates and starts
the current-user services. Click the cpcv menu-bar icon, choose **Settings...**,
set your SSH target to `image-box`, and save. Then verify the connection and
install the optional tmux helper:

```bash
ssh image-box true
cpcv-deploy-tmux --host image-box
```

#### macOS universal ZIP (alternative)

Open Terminal in the extracted `cpcv` folder and run:

```bash
bash macos/install-macos.sh --prebuilt
bash macos/install-tray.sh --prebuilt
```

Click the cpcv menu-bar icon, choose **Settings…**, set your SSH target to
`image-box`, and save. Then verify the connection and install the optional
tmux helper:

```bash
ssh image-box true
bash macos/deploy-remote-tmux-cpcv-plugin.sh --host image-box
```

The menu-bar app and local uploader start now and at sign-in. If you use a
remote folder other than `clipboard-images`, pass the same value to the deploy
command with `--remote-dir`.

### 3. Enable pane-specific tmux paste

The remote helper deliberately never edits your tmux configuration. On
`image-box`, add this one line to your `~/.tmux.conf`:

```tmux
run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux
```

Reload an already-running tmux server:

```bash
tmux run-shell "$HOME/.local/lib/cpcv/tmux/cpcv.tmux"
```

If you skipped the optional tmux helpers in Windows Setup, run
`& "$env:LOCALAPPDATA\Programs\cpcv\install-autostart.ps1" -DeployRemoteHelpers`
after your SSH configuration is ready. With Homebrew, use
`cpcv-deploy-tmux --host image-box`. Then add the same `run-shell` line.

### 4. Use it

1. Take a screenshot or copy an image as usual.
2. Wait a few seconds for the status icon to report a successful upload.
3. Press physical **Ctrl-V** in the remote tmux pane that should receive the
   path.

| Platform | A healthy first upload looks like |
| --- | --- |
| Windows | Hover the cpcv tray icon: `Healthy - Uploaded …`. `No upload yet` is normal until the first image. |
| macOS | The menu-bar icon shows a checkmark when healthy; it spins during upload and shows a warning when attention is needed. |

`Ctrl-V` inserts the remote path into that one tmux pane. It does not alter
the host clipboard. Use **Copy latest path** from the tray or menu-bar app
when you explicitly want the path as text.

> **Warp users:** use physical **Ctrl-V**. Warp handles `Cmd-V` itself before
> tmux receives it.

## What happens after setup?

| You do | cpcv does |
| --- | --- |
| Screenshot or copy an image | Leaves the image on your local clipboard. |
| Wait for the background upload | Stores a timestamped image on the SSH target and updates `latest.png`. |
| Press `Ctrl-V` in tmux | Inserts the remote `latest.png` path in that pane only. |
| Need the path outside tmux | Lets you explicitly copy the last validated path from the status app. |

`latest.png` normally lives at `~/clipboard-images/latest.png` on the SSH
target. cpcv uses the `ssh` and `scp` tools you already use; there is no cpcv
server to run or account to create.

## Status, troubleshooting, and customization

| If this happens | Try this |
| --- | --- |
| Uploads are not completing | Verify `ssh image-box true`, then open the cpcv status view and check the private configuration. |
| `Ctrl-V` does nothing | Confirm the `run-shell` line is in the remote `~/.tmux.conf`, then rerun `tmux run-shell "$HOME/.local/lib/cpcv/tmux/cpcv.tmux"`. |
| tmux says `no image` | Copy an image locally and wait for the first upload. |
| You changed server or remote folder | Update macOS Settings or Windows `config.psd1`, then redeploy the remote tmux helper to that target. |

On macOS, `bash macos/cpcv-macos-ctl.sh doctor` checks the local service, SSH
reachability, remote directory, and clock synchronization. On Windows,
right-click the tray icon and choose **View status** for the dashboard,
configuration, logs, and service controls.

You can customize tmux before its `run-shell` line:

```tmux
# Hide cpcv's tmux status item, refresh it every five seconds, or choose another key.
set -g @cpcv-status off
set -g @cpcv-status-refresh 5
set -g @cpcv-paste-key M-v
```

For all configuration fields, diagnostics, and platform behavior, see
[Platform support](docs/platforms.md).

## Privacy and safety

- cpcv uploads only image clipboard content through your existing SSH setup;
  it does not replace the image clipboard with a path.
- It uses bounded, redacted diagnostics and hard timeouts for SSH/SCP commands.
- Installers operate only on cpcv-owned local services and marked remote helper
  files. They do not edit shell startup files, `PATH`, or `~/.tmux.conf`.
- Private configuration, cached images, and logs can be sensitive. They stay
  outside the checkout and are preserved by default when you uninstall.

Read [SECURITY.md](SECURITY.md) for the security model and vulnerability
reporting process.

## Update, remove, or go deeper

To update Windows, run the newer Setup EXE; it keeps private configuration and
data by default. For a portable ZIP, extract the new release and rerun its
installers. To update Homebrew, run `brew upgrade thapecroth/cpcv/cpcv` followed
by `cpcv-setup`; redeploy the tmux helper after its source changes.

To remove the Windows setup installation while preserving private settings and
images, use **Installed apps** in Windows. For portable installs, preview
`.\uninstall-tray.ps1 -WhatIf` and `.\uninstall-autostart.ps1 -WhatIf` before
running them without `-WhatIf`. For a macOS ZIP, run
`bash macos/uninstall-tray.sh` and `bash macos/uninstall-macos.sh` before
discarding it. For Homebrew, stop the user services before removing the formula:

```bash
prefix="$(brew --prefix cpcv)"
bash "$prefix/libexec/macos/uninstall-tray.sh"
bash "$prefix/libexec/macos/uninstall-macos.sh"
brew uninstall cpcv
```

- [Full platform guide](docs/platforms.md)
- [Optional native Codex image paste on a Linux SSH host](docs/platforms.md#optional-native-codex-image-paste-on-linux)
- [Release and CI details](docs/testing-and-ci.md#release-ci)
- [Contributing and development tests](CONTRIBUTING.md)
- [MIT License](LICENSE)
