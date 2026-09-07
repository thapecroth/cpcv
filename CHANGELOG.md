# Changelog

All notable user-facing changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/): breaking changes increment the
major version, backwards-compatible features increment the minor version, and
fixes increment the patch version.

## Unreleased

## v0.3.0 - 2026-09-07

### Added

- Generic OpenSSH target configuration with private, local-only settings.
- Clipboard watcher, guardian, bounded subprocess execution, and optional
  remote helper integrations.
- Bounds for individual clipboard images and retained local cache bytes.
- An optional Windows notification-area tray with bounded/redacted status and
  scoped local controls.
- An original cpcv application mark, transparent dashboard logo, and
  multi-resolution Windows tray icon.
- A reproducible `build-windows.ps1` archive build that packages only committed
  source and validates required branded assets.
- An isolated Windows end-to-end upload test with local SSH/SCP stand-ins.
- A source-installed macOS 11+ native AppKit clipboard watcher, per-user
  guardian, fixed-action controller, and optional menu-bar companion.
- Private-first Windows/macOS tray, testing, and clean-tree export
  documentation.
- Windows tray CI checks that use fake local adapters rather than real SSH
  hosts or clipboard data.
- macOS CI checks that compile the native source and exercise the network-free
  process-timeout self-test.
- Documentation, community templates, and a Windows CI baseline.
- A tag-triggered GitHub Actions release workflow that validates SemVer metadata,
  rebuilds both platforms, generates SHA-256 checksums, and publishes portable
  Windows and universal macOS assets.
- A tracked `VERSION` file and portable macOS release bundle with prebuilt
  arm64/x86_64 binaries for users who do not have Xcode Command Line Tools.
- A Windows tray upload-age indicator that confirms the latest successful image
  upload in the private hover text, menu, and dashboard.

### Changed

- Installation and release guidance now support public, checksum-verified
  portable downloads without adding a hosted service or auto-update endpoint.
- The tray is documented as a bounded/redacted local control client rather than
  a second uploader.
- The Windows status experience is now a modern dashboard with a clear health
  banner, activity cards, context-sensitive recovery guidance, and grouped
  quick actions.

### Fixed

- Platform documentation distinguishes ad-hoc-signed, non-notarized portable
  macOS bundles from future Developer ID signed and notarized releases.
- macOS command timeouts now create the SSH/SCP process group before exec,
  bound reader cleanup, and exercise timeout/output/redaction paths in CI.
- Per-user installers refuse to replace, unload, or remove same-named local
  startup resources unless they can prove ownership.
- macOS log and menu-bar redaction now covers HTTP basic-auth URLs, sensitive
  headers/cookies, and common token/key/value forms.
- Windows guardian recovery now waits for a stopped watcher to release its
  mutex before starting its replacement; its live test waits for a matching
  fresh heartbeat rather than a fixed delay.
- Windows guardian launch and child-tree timeout coverage now preserve script
  paths containing spaces, including a portable archive extracted to such a
  path.

## Release process

Before a release, update the **Unreleased** section with concise user impact,
move it to a dated `vX.Y.Z` heading, set `VERSION`, run the documented tests,
and ensure CI is green. Create and push an annotated `vX.Y.Z` tag from a commit
reachable from `main`; the release workflow validates the tag, version, source,
and changelog before it builds and publishes both assets plus `SHA256SUMS.txt`.
Do not include host names, local paths, screenshots, logs, or credentials in
release notes.
