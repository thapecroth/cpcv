# Herdr image-path paste

ctrl-ccv can paste an uploaded image path into a Herdr pane without tmux. The
Windows and macOS uploaders work as usual: copy an image locally and wait
for ctrl-ccv to confirm its upload, then press the configured key in Herdr.
The image stays on your local clipboard.

The optional helper needs Python 3.8+ on the POSIX SSH host where Herdr's
panes run. It uses the Herdr socket API; the request and command environment
were checked against Herdr v0.9.5. Earlier versions need the same
`pane.send_input` and custom-command context support.

## Install on the SSH target

From a source checkout or extracted release on macOS/Linux:

```bash
bash deploy-herdr.sh --host image-box
```

With a Homebrew package containing this integration:

```bash
ctrl-ccv-deploy-herdr --host image-box
```

Use your uploader's SSH target and image directory. If you upload to a
different folder, add `--remote-dir images/custom` to the deploy command.
The default is `clipboard-images`. The helper keeps its own configuration,
so redeploy it after changing the uploader's remote folder or target.

On Windows, run these commands from the extracted release or installation
directory in PowerShell. They stage only the helper in a private temporary
remote directory and remove it after installation:

```powershell
$stage = (ssh image-box 'umask 077; mktemp -d /tmp/ctrl-ccv-herdr.XXXXXXXX').Trim()
if ($LASTEXITCODE -ne 0 -or $stage -notmatch '^/tmp/ctrl-ccv-herdr\.[A-Za-z0-9]+$') { throw 'Could not stage the Herdr helper' }
try {
    scp .\remote\ctrl-ccv-herdr.py "image-box:$stage/"
    if ($LASTEXITCODE -ne 0) { throw 'Could not copy the Herdr helper' }
    ssh image-box "python3 '$stage/ctrl-ccv-herdr.py' install --remote-dir clipboard-images"
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the Herdr helper' }
} finally {
    ssh image-box "rm -f '$stage/ctrl-ccv-herdr.py'; rmdir '$stage'"
}
```

If the source checkout is already on the SSH host, install directly there:

```bash
python3 remote/ctrl-ccv-herdr.py install --remote-dir clipboard-images
```

The installer creates only the marked helper at
`~/.local/lib/ctrl-ccv/herdr/ctrl-ccv-herdr.py` and private data configuration at
`~/.config/ctrl-ccv/herdr-paste.json`, plus the image directory if needed. It
refuses unrelated existing files and symlinked installation directories.

## Enable the binding

Add the following to `~/.config/herdr/config.toml` **on the host where the
panes run**. Merge it into your existing configuration rather than replacing
the file. Pick an unused key if `prefix+alt+v` is already assigned:

```toml
[[keys.command]]
key = "prefix+alt+v"
type = "shell"
command = 'python3 "$HOME/.local/lib/ctrl-ccv/herdr/ctrl-ccv-herdr.py" paste'
description = "Paste latest ctrl-ccv image path"
```

Inside the intended Herdr session, reload the server configuration:

```bash
herdr server reload-config
```

For a named session, reload that session, for example
`herdr --session work server reload-config`. If attaching from a local Herdr
client, use server keybindings explicitly:

```bash
herdr --remote image-box --remote-keybindings server
# For a named remote session:
herdr --remote image-box --session work --remote-keybindings server
```

Install and configure the integration on `image-box`, where the panes and
images live. Herdr owns command execution on that server. Its default remote
mode uses local keybindings and omits remote custom commands. A local desktop
configuration alone does not install the remote command. Ordinary
`ssh image-box` followed by `herdr` uses the server configuration directly.

Press the Herdr **prefix**, then **Alt-V**, in the destination pane. The
default prefix is **Ctrl-B**. Your terminal must forward these keys to Herdr.
This avoids Herdr's native remote image-paste shortcut, which uses Ctrl-V
and can intercept an image before custom commands run. You can choose
`key = "ctrl+v"` for a plain SSH session if that key is unused; for Herdr's
`--remote` mode, using Ctrl-V also requires disabling `remote_image_paste`
in the **local client's** `[keys]` settings. The recommended binding does not
need that client change. The existing desktop **Configure tmux path insertion**
action configures tmux; use these commands for Herdr.

## Behavior and troubleshooting

The helper captures `HERDR_ACTIVE_PANE_ID` and uses `HERDR_SOCKET_PATH`
provided by Herdr. It sends the stable `latest.png` path to that exact pane
in one `pane.send_input` request with an empty key list. Herdr applies the
target application's bracketed-paste mode. No Enter key is sent. Changing
focus while the helper starts cannot redirect it, and an outer tmux session
cannot capture the paste. The helper never changes an OS clipboard.

An image must exist and contain data before anything is sent. The image
directory must resolve inside the remote user's home. Socket replies have a
three-second deadline and a 64 KiB size limit; errors and mismatched
acknowledgments fail without retrying the paste. Missing-image and validation
errors produce a best-effort Herdr notification. Herdr may suppress these
notifications according to its settings or when no client is attached.

To inspect a failure, run this inside the intended Herdr pane:

```bash
HERDR_ACTIVE_PANE_ID="$HERDR_PANE_ID" python3 "$HOME/.local/lib/ctrl-ccv/herdr/ctrl-ccv-herdr.py" paste
```

This also attempts a paste into that pane. Check that Python 3 is available,
an upload has completed in the configured folder, and the server supports the
required API. There is no fallback to a default session or another pane when
context is missing.

## Remove

Remove the command binding from your Herdr configuration and reload that
session. Then remove the two ctrl-ccv-owned files after checking their contents:

```bash
rm ~/.local/lib/ctrl-ccv/herdr/ctrl-ccv-herdr.py ~/.config/ctrl-ccv/herdr-paste.json
rmdir ~/.local/lib/ctrl-ccv/herdr
```

Uploaded images and the local uploader remain available.

## API references

- [Herdr custom commands and environment](https://herdr.dev/tui/docs/configuration/#custom-command-keybindings)
- [Herdr socket transport](https://herdr.dev/tui/docs/socket-api/#socket-transport)
- [v0.9.5 input handler](https://github.com/herdrdev/herdr/blob/v0.9.5/src/app/api/panes.rs#L1930)
- [v0.9.5 bracketed-paste encoding](https://github.com/herdrdev/herdr/blob/v0.9.5/src/app/api_helpers.rs)
