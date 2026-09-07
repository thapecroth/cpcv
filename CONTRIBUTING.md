# Contributing

Thanks for considering a contribution.

## Development rules

- Keep the core clipboard-to-SSH workflow dependency-free at runtime beyond
  the platform's native clipboard API and OpenSSH.
- Do not add a screenshot app, hosted service, or hard-coded SSH host.
- Preserve equivalent behavior across the Windows PowerShell and native macOS
  implementations.
  A platform-specific adapter may differ internally, but it must not silently
  weaken timeout, process-tree cleanup, redaction, path validation, cache, or
  guardian guarantees.
- Treat the tray as a local control/status client, never as a second uploader.
  It must use bounded/redacted status data, exit or reconnect harmlessly on a
  duplicate launch, and never execute arbitrary shell text supplied by the UI.
- Use per-user startup only: a Windows user Startup integration or a macOS user
  LaunchAgent. Do not add a root LaunchDaemon, service, login-item helper, or
  administrator-required installation without an explicit security design.
- Keep credentials, proxy URLs, usernames, and local paths out of tracked
  files. Use `cpcv.config.example.psd1` for examples only.
- Keep `macos/cpcv.macos.config.example.json` generic too.
  Configuration is data, not executable source; do not introduce fields that
  accept shell fragments, arbitrary executables, or unvalidated paths.
- Treat remote helper changes as opt-in and avoid silently editing remote shell,
  tmux, editor, or agent configuration.
- Preserve the hard timeout, child-process cleanup, bounded output, and
  redaction guarantees when changing process execution.
- Do not introduce dynamic evaluation (`Invoke-Expression` / `iex`) into
  tracked PowerShell. CI parses scripts and rejects those constructs.
- Keep configuration examples generic. Do not add real SSH aliases, usernames,
  host names, screenshots, logs, or personal paths to tracked files.
- Treat changes to cache retention, retries, guardian behavior, or remote paths
  as user-facing behavior and document them in `README.md` and `CHANGELOG.md`.
- Treat changes to autostart, tray controls, status schema, local IPC, file
  permissions, or macOS packaging as security-relevant and document them in
  `docs/platforms.md` and `docs/testing-and-ci.md`.
- Do not add auto-update endpoints or silently fetch or execute remote code.
  Release downloads must remain explicit, versioned, checksum-verifiable, and
  free of host-specific configuration.

## Test before opening a pull request

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\test-process-timeout.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\test-windows-e2e.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\test-tray.ps1
```

Also parse modified PowerShell scripts:

```powershell
Get-ChildItem -Recurse -Filter *.ps1 | ForEach-Object {
  $tokens = $null; $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors) { $errors | ForEach-Object Message; exit 1 }
}
```

The guardian test affects real local processes and is deliberately excluded
from CI. Run it only with a disposable/development watcher setup. CI must use
fake clipboard/process adapters and must never connect to a real SSH host,
Cloudflare endpoint, or a contributor's infrastructure.

For a tray or platform change, also test these adversarial cases:

- duplicate UI, watcher, guardian, or LaunchAgent launches leave exactly one
  active uploader;
- corrupt/stale/mismatched heartbeat or status data fails closed and recovers;
- a hung SSH/ProxyCommand process and all descendants are removed on timeout;
- raw subprocess output, host information, and credential-like text stay
  bounded and redacted in the log, status document, notifications, and UI;
- an image changed during upload cannot overwrite a newer clipboard item or
  `latest.png`;
- installation and uninstall are idempotent, per-user, and preserve data unless
  an explicit reviewed purge is requested.

For macOS changes, preserve the per-user LaunchAgent boundary, keep the Swift
source build working, preserve the validated `--prebuilt` release-bundle path,
and run `bash macos/test-macos.sh` on macOS before claiming a native change
works.

## Pull requests

Open a focused pull request from a fork or branch and complete the pull-request
template. Explain the behavior change, validation, and any security or privacy
impact. Never post credentials, screenshot contents, SSH configuration, proxy
URLs, or unredacted logs in an issue, pull request, or review.

## Releases

Maintain `CHANGELOG.md` and `VERSION` using stable Semantic Versioning. The
maintainer should update the Unreleased section, run the documented tests,
verify CI, then create and push an annotated `vX.Y.Z` tag from `main`. The
release workflow validates the metadata, rebuilds both bundles, generates
`SHA256SUMS.txt`, and publishes the GitHub Release. Releases must not contain
private host details, local paths, screenshots, logs, or credentials.

Do not modify an existing release or retag a published version. Use a new patch
version for a correction. If a separate private development archive is used,
follow [docs/private-release-mirror.md](docs/private-release-mirror.md) to
export only reviewed committed source.
