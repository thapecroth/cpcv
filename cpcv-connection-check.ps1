<#
.SYNOPSIS
Runs cpcv's fixed, read-only SSH connection check for the tray assistant.

.DESCRIPTION
This small owned helper accepts no target or command from the UI. It starts
the core's same unattended SSH check used for diagnostics, then emits only a
controlled result token as JSON. The tray maps that token back to its own
safe customer-facing text and never displays this process's stdout or stderr.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

try {
    . (Join-Path $PSScriptRoot "cpcv-core.ps1")
    $result = Get-CpcvSshConnectionCheckResult
    $failureKind = [string]$result.FailureKind
    if ($failureKind -notin @(
        "connected", "connect-timeout", "authentication", "host-key",
        "host-not-found", "proxy", "command-timeout", "configuration",
        "connection-failed"
    )) {
        $failureKind = "check-unavailable"
    }
    [pscustomobject]@{ Version = 1; FailureKind = $failureKind } | ConvertTo-Json -Compress
    exit 0
}
catch {
    # Do not write an exception here: it can contain a local path or an SSH
    # implementation detail. The parent maps this controlled token safely.
    [pscustomobject]@{ Version = 1; FailureKind = "check-unavailable" } | ConvertTo-Json -Compress
    exit 1
}
