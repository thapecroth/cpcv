# Testing and CI

CI is intentionally network-free with respect to SSH hosts. It must never
connect to a real host, Cloudflare endpoint, or contributor infrastructure, and
the macOS job must not read a real system clipboard.

## Automated checks

| Area | Windows | macOS |
| --- | --- | --- |
| Syntax/build | Parses every PowerShell script and rejects dynamic evaluation | `swiftc` builds the native uploader and menu-bar source; Bash syntax is checked |
| Process timeout | Safe simulated child-tree timeout in PowerShell | Native self-test creates a harmless local child process, forces the deadline, and verifies the child is gone |
| Configuration | Strict numeric/path validation and local-only test configs | JSON schema/invariant checks plus native validation/redaction self-test |
| Tray/status | Bounded tooltip and healthy/stale/corrupt status cases | Native tray source build and fixed controller/status contract |
| Network | Fake process/clipboard adapters only | No SSH, `launchctl`, or clipboard calls in `macos/test-macos.sh` |

The CI workflow runs Windows and `macos-latest` jobs even while the repository
is private. The native macOS test entry point is:

```bash
bash macos/test-macos.sh
```

It requires macOS 11 or newer and Xcode Command Line Tools. It compiles
disposable uploader and tray binaries on every run, then runs only their
network-free self-tests.
An authorized live SSH upload is valuable additional evidence, but must be
recorded separately and never described as a CI result unless it actually ran.

## Test changes with behavior changes

Add or update tests when changing:

- clipboard image conversion, format selection, image dimensions, or byte caps;
- child-process invocation, cancellation, timeout, output capture, or process
  group behavior;
- configuration parsing, config migration, local permissions, or status schema;
- guardian locks, startup, tray controls, or uninstall ownership checks;
- retry/backoff, latest-image behavior, cache retention, or remote path rules.

Use harmless synthetic image bytes, local fake SSH programs, and placeholder
names. Never include a real SSH profile, token, proxy URL, screenshot, host
alias, or private log in a test fixture.

## Private-repository CI

The base CI workflow is intended to remain useful while the repository is
private. CodeQL is deliberately skipped for a private repository unless the
owner enables the required GitHub Code Security capability; record a skipped
scan as skipped, not passed. Keep artifacts private. Signing/notarization
credentials belong only in protected CI secrets after the owner deliberately
adds a signed binary release process.
