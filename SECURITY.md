# Security policy

## Supported versions

Security fixes target the latest `main` branch.

## Reporting a vulnerability

Please do not disclose credentials, screenshots, SSH host names, or exploit
details in a public issue. Use GitHub's private vulnerability reporting for
this repository when available. If it is unavailable, open a minimal issue
requesting a private contact channel, without technical details or secrets.

Reports are most useful when they include the affected commit, a minimal
redacted reproduction, impact, and a safe suggested fix. Test only against
systems and accounts you own or are authorized to use; do not probe arbitrary
SSH hosts, Cloudflare endpoints, or other third-party infrastructure.

## Security model

imgpaste executes the local OpenSSH client using a user-owned SSH
configuration. It does not store private keys or tokens. Clipboard images and
upload history are sensitive local data; users are responsible for protecting
their chosen SSH host, remote directory, backups, and local cache.

Security-relevant areas include local configuration parsing, subprocess
argument handling and cleanup, logs/redaction, guardian process handling,
status/tray IPC, macOS LaunchAgent installation, and the optional remote
helpers. The Windows and macOS trays are local control clients that do not
expose raw SSH output, host configuration, screenshots, or credentials in
menus, notifications, or status files.

The macOS uploader is source-installed and not a signed/notarized app bundle.
Do not describe it as a signed client or a production binary distribution.
When binary releases are intentionally built, signing identities, notarization
credentials, and Authenticode certificates must remain in protected CI secrets
and never be committed.

The runtime archive and clean release candidate have intentionally separate
histories. Keep both private unless the owner explicitly changes visibility;
move code only by reviewing a committed-tree export as documented in
`docs/private-release-mirror.md`. Do not include secret material in test
fixtures, issues, pull requests, commits, source exports, or release notes.
