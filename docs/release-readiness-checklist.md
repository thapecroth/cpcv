# Private release-readiness checklist

Use this checklist before sharing a private build or exporting a clean release
candidate. It does not authorize making a repository public.

## Source and privacy

- [ ] The active repository, candidate repository, and any artifacts are still
      private unless the owner has explicitly changed that state.
- [ ] `git status --short` contains only the reviewed change set.
- [ ] No tracked file contains a real host alias, username, local path,
      screenshot, log, cache entry, token, private key, credential, or proxy
      URL.
- [ ] README examples use placeholders and do not require a public URL,
      download page, GitHub account, or hosted service.
- [ ] Runtime archive history is not merged, rebased, cherry-picked, or pushed
      into the clean candidate; use the committed-tree export procedure.

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
- [ ] Candidate CI is green; skipped private-only security products are recorded
      as skipped, not as passed.
- [ ] The Windows archive was produced from a clean committed tree, contains
      the branded assets, excludes private runtime state, and passes its safe
      extracted-source checks.
- [ ] A live SSH transfer is called successful only when run against an
      authorized host and documented separately from network-free tests.
- [ ] Do not publish unsigned binary artifacts as production releases. Before
      public distribution, add reviewed signing/notarization, checksums, and
      fresh-machine verification for every supported architecture.
