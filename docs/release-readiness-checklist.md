# Release-readiness checklist

Use this checklist before creating a public or private cpcv release.

## Source and privacy

- [ ] `git status --short` contains only the reviewed change set.
- [ ] No tracked file contains a real host alias, username, local path,
      screenshot, log, cache entry, token, private key, credential, or proxy
      URL.
- [ ] README examples use placeholders; public download instructions do not
      contain local paths, hosts, credentials, or an auto-update mechanism.
- [ ] If a private runtime archive is used, only a reviewed committed-tree export
      reaches the release candidate.

## Behavior and reliability

- [ ] Windows safe core, timeout, isolated end-to-end upload, and tray tests
      pass.
- [ ] If claiming macOS support, native parse/build and network-free behavior
      tests pass.
- [ ] A deliberately hung SSH child tree is terminated at the hard deadline on
      each platform being claimed as supported.
- [ ] Duplicate watcher, guardian, tray, or LaunchAgent launches result in one
      active uploader.
- [ ] Missing, stale, corrupt, or mismatched health/status state fails closed
      and recovers without a restart storm.
- [ ] Empty, busy, oversized, and changing clipboard cases leave the latest
      remote image and user clipboard safe.
- [ ] Failed network/auth/proxy simulations redact output and back off without
      retry storms or unbounded cache growth.

## Install and UI

- [ ] Windows autostart/tray installation and scoped uninstallation are
      idempotent and preserve data by default.
- [ ] If claiming macOS support, installation creates only the current user's
      `io.cpcv.*` jobs and never creates a root LaunchDaemon.
- [ ] The tray status is bounded and redacted, and every control action targets
      the current checkout/service only.
- [ ] The Windows dashboard and branded tray icon have been visually inspected
      at a normal desktop scale; no subtitle, status, or primary action is
      clipped.
- [ ] A fresh authorized user session for each claimed platform can install,
      start, inspect status, stop, restart, and uninstall without administrator
      privileges.

## Candidate and distribution

- [ ] The clean candidate's file diff, full reachable history, remote, and
      visibility have been reviewed.
- [ ] Candidate CI is green; the release tag is annotated, stable SemVer, and
      matches `VERSION`, the macOS source version, and its changelog heading.
- [ ] The Windows archive was produced from a clean committed tree, contains
      the branded assets, excludes private runtime state, and passes its safe
      extracted-source checks.
- [ ] The macOS archive was produced from committed source plus verified
      universal arm64/x86_64 binaries, excludes private runtime state, and
      passes both native self-tests.
- [ ] `SHA256SUMS.txt` has been generated from the exact release assets and
      successfully verifies them.
- [ ] A live SSH transfer is called successful only when run against an
      authorized host and documented separately from network-free tests.
- [ ] The release notes accurately state that the macOS binaries are ad-hoc
      signed but not notarized; they do not claim Developer ID or production
      signing.
- [ ] Before claiming a production-signed binary release, add reviewed Apple
      notarization and Windows Authenticode, protected CI secrets, and
      fresh-machine verification for every supported architecture.
