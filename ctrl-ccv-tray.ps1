<#
.SYNOPSIS
Shows a small Windows notification-area controller for ctrl-ccv.

.DESCRIPTION
This is deliberately a companion to the guardian rather than a second
watcher.  It only starts or stops processes whose exact -File argument points
to this checkout, and it reads the existing health and state files.

Run it from an STA PowerShell process, for example:
  powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File .\ctrl-ccv-tray.ps1
#>
[CmdletBinding()]
param(
    # Intended for tests and dot-sourcing.  It defines the helpers without
    # creating a notification icon or entering the Windows message loop.
    [switch]$NoRun,
    [ValidateRange(1, 60)]
    [int]$RefreshSeconds = 5
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ctrl-ccv-core.ps1")
. (Join-Path $PSScriptRoot "ctrl-ccv-remote.ps1")

# This deliberately stays a fixed first-party URL.  The tray can help a
# person find a release, but it never fetches, verifies, or starts an update
# on its own.
$script:CtrlCcvTrayReleaseUrl = "https://github.com/thapecroth/ctrl-ccv/releases/latest"

function Get-CtrlCcvTrayProcessProbe {
    param([Parameter(Mandatory)][string]$ScriptPath)

    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Where-Object {
                $_.Name -in @("powershell.exe", "pwsh.exe") -and
                (Test-CtrlCcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $ScriptPath)
            })
        return [pscustomobject]@{ Available = $true; Processes = $processes; Error = "" }
    }
    catch {
        # A status UI must never decide that a service is stopped merely
        # because process inspection was denied or unavailable.
        return [pscustomobject]@{ Available = $false; Processes = @(); Error = $_.Exception.Message }
    }
}

function Test-CtrlCcvTrayShortcutOwnership {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    # Startup filenames are shared user resources. A matching filename alone
    # is never ownership: require the system PowerShell executable, this
    # checkout's exact -File
    # argument, its working directory, and either the current marker or the
    # documented legacy description from pre-marker installs.
    try {
        if (-not (Test-Path -LiteralPath $ShortcutPath)) { return $true }
        $item = Get-Item -LiteralPath $ShortcutPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $false }
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $expectedTarget = [IO.Path]::GetFullPath((Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Source))
        $actualTarget = [IO.Path]::GetFullPath([string]$shortcut.TargetPath)
        $expectedDirectory = [IO.Path]::GetFullPath($WorkingDirectory).TrimEnd('\\')
        $actualDirectory = if ($shortcut.WorkingDirectory) { [IO.Path]::GetFullPath([string]$shortcut.WorkingDirectory).TrimEnd('\\') } else { "" }
        $description = [string]$shortcut.Description
        $marked = $description -eq "Managed by ctrl-ccv install-tray.ps1"
        $legacy = $description -eq "ctrl-ccv status and controls"
        return ($actualTarget -ieq $expectedTarget -and
            (Test-CtrlCcvProcessCommandLineForScript -CommandLine ([string]$shortcut.Arguments) -ScriptPath $ScriptPath) -and
            $actualDirectory -eq $expectedDirectory -and ($marked -or $legacy))
    }
    catch { return $false }
}

function Get-CtrlCcvTrayLatestPath {
    param([Parameter(Mandatory)]$Config)

    try {
        if (-not (Test-Path -LiteralPath $Config.LastRemotePathFile)) { return "" }
        $path = (Get-Content -LiteralPath $Config.LastRemotePathFile -Raw -ErrorAction Stop).Trim()
        if (Test-CtrlCcvRemotePath $path) { return $path }
    }
    catch { }
    return ""
}

function Get-CtrlCcvTrayUploadIssue {
    param(
        [ValidateRange(0, [int]::MaxValue)][int]$FailureCount = 0,
        [AllowNull()][string]$FailureReason = ""
    )

    # FailureReason comes from the core-owned, token-only upload status file.
    # Do not render raw subprocess output in any tray-facing surface.
    $retryDetail = "ctrl-ccv will retry automatically when it sees an image in the clipboard."
    $countDetail = if ($FailureCount -gt 1) { " $FailureCount attempts have failed." } elseif ($FailureCount -eq 1) { " One attempt has failed." } else { "" }
    switch ($FailureReason) {
        "clipboard-busy" {
            return [pscustomobject]@{
                Summary = "Clipboard is temporarily busy"
                Detail = "Another app is using the Windows clipboard. ctrl-ccv will read it again shortly; this is not an SSH upload failure. Keep the image in the clipboard until its upload is confirmed."
            }
        }
        "cloudflare-retry" {
            return [pscustomobject]@{
                Summary = "Cloudflare connection recovered"
                Detail = "ctrl-ccv refreshed Cloudflare sign-in after a connection failure. The clipboard image will retry automatically."
            }
        }
        "cloudflare-sign-in-required" {
            return [pscustomobject]@{
                Summary = "Cloudflare sign-in needs attention"
                Detail = "The local uploader is running. Complete Cloudflare sign-in through your normal SSH workflow, then ctrl-ccv will retry automatically. ctrl-ccv does not collect passwords or one-time codes.$countDetail"
            }
        }
        "ssh-mkdir-timeout" {
            return [pscustomobject]@{
                Summary = "SSH upload setup timed out"
                Detail = "The local uploader is running, but ctrl-ccv could not complete the first SSH upload step before its deadline. No image was sent. Open Connection help for guided steps.$countDetail"
            }
        }
        "ssh-mkdir-connect-timeout" {
            return [pscustomobject]@{
                Summary = "SSH upload connection timed out"
                Detail = "The local uploader is running, but ctrl-ccv's unattended SSH process did not receive an SSH greeting before its deadline. No image was sent. Open Connection help for guided steps.$countDetail"
            }
        }
        "ssh-mkdir-auth-failed" {
            return [pscustomobject]@{
                Summary = "Unattended SSH sign-in needs attention"
                Detail = "The local uploader is running, but ctrl-ccv could not complete a no-prompt sign-in. This can include a password, passphrase, approval, or one-time-code step. No image was sent. Open Connection help for guided steps.$countDetail"
            }
        }
        "ssh-mkdir-host-key-failed" {
            return [pscustomobject]@{
                Summary = "SSH server identity needs review"
                Detail = "The local uploader is running, and ctrl-ccv kept SSH host-key protection in place. No image was sent. Open Connection help for guided steps.$countDetail"
            }
        }
        "ssh-mkdir-host-not-found" {
            return [pscustomobject]@{
                Summary = "SSH connection name was not found"
                Detail = "The local uploader is running, but ctrl-ccv could not resolve the configured SSH connection. No image was sent. Open Connection help for guided steps.$countDetail"
            }
        }
        "ssh-mkdir-proxy-failed" {
            return [pscustomobject]@{
                Summary = "SSH proxy or tunnel needs attention"
                Detail = "The local uploader is running, but ctrl-ccv's unattended SSH process could not start through its proxy or tunnel. No image was sent. Open Connection help for guided steps.$countDetail"
            }
        }
        "ssh-mkdir-remote-folder-failed" {
            return [pscustomobject]@{
                Summary = "Remote upload folder needs attention"
                Detail = "ctrl-ccv reached the SSH target but could not prepare the configured remote image folder. No image was sent. Open Settings to review the remote folder, or ask the server administrator for access.$countDetail"
            }
        }
        "ssh-mkdir-failed" {
            return [pscustomobject]@{
                Summary = "SSH upload connection failed"
                Detail = "The local uploader is running, but ctrl-ccv could not complete its unattended SSH process. No image was sent. Open Connection help for guided steps.$countDetail"
            }
        }
        "scp-timeout" {
            return [pscustomobject]@{
                Summary = "Image transfer timed out"
                Detail = "ctrl-ccv could not finish transferring the clipboard image before its timeout. $retryDetail$countDetail"
            }
        }
        "scp-failed" {
            return [pscustomobject]@{
                Summary = "Image transfer failed"
                Detail = "ctrl-ccv could not transfer the clipboard image. $retryDetail$countDetail"
            }
        }
        "ssh-latest-timeout" {
            return [pscustomobject]@{
                Summary = "Upload finalization timed out"
                Detail = "The image may have transferred, but ctrl-ccv could not confirm latest.png. $retryDetail$countDetail"
            }
        }
        "ssh-latest-failed" {
            return [pscustomobject]@{
                Summary = "Upload finalization failed"
                Detail = "The image may have transferred, but ctrl-ccv could not confirm latest.png. $retryDetail$countDetail"
            }
        }
        "image-too-large" {
            return [pscustomobject]@{
                Summary = "Clipboard image is too large"
                Detail = "The image exceeded ctrl-ccv's configured size limit. Open Settings to increase MaxImageBytes or copy a smaller image."
            }
        }
        default {
            return [pscustomobject]@{
                Summary = "Upload needs retry"
                Detail = "The last clipboard image upload was not confirmed. $retryDetail$countDetail View recent activity for a redacted diagnostic."
            }
        }
    }
}

function Test-CtrlCcvTrayUploadIssue {
    param([Parameter(Mandatory)]$State)
    return ([string]$State.IssueKind -eq "Upload")
}

function Test-CtrlCcvTraySshConnectionIssue {
    <#
    .SYNOPSIS
    Indicates that the upload failed before it could prepare the remote folder.

    .DESCRIPTION
    This is deliberately narrower than a generic upload warning.  Transfer and
    finalization errors should not send someone through an SSH-connection
    walkthrough, while an early SSH failure can be checked safely without
    uploading an image.
    #>
    param([Parameter(Mandatory)]$State)

    if (-not (Test-CtrlCcvTrayUploadIssue -State $State)) { return $false }
    return ([string]$State.UploadFailureReason -in @(
        "cloudflare-sign-in-required",
        "ssh-mkdir-timeout",
        "ssh-mkdir-connect-timeout",
        "ssh-mkdir-auth-failed",
        "ssh-mkdir-host-key-failed",
        "ssh-mkdir-host-not-found",
        "ssh-mkdir-proxy-failed",
        "ssh-mkdir-failed"
    ))
}

function Get-CtrlCcvTraySshTroubleshooting {
    <#
    .SYNOPSIS
    Returns private-safe customer guidance for an initial SSH upload failure.

    .DESCRIPTION
    The assistant never uses raw log text, a host alias, remote path, or proxy
    configuration.  It explains the known failure category using only the
    token stored by the core and gives a fixed safe decision path.
    #>
    param([Parameter(Mandatory)]$State)

    $reason = [string]$State.UploadFailureReason
    $attempts = 0
    try { $attempts = [int]$State.UploadFailureCount } catch { }
    $attemptText = if ($attempts -gt 1) { "$attempts upload attempts have failed." } elseif ($attempts -eq 1) { "One upload attempt has failed." } else { "The most recent upload was not confirmed." }
    $guardianCount = (@($State.Guardians)).Count
    $watcherCount = (@($State.Watchers)).Count
    $serviceRunning = ($guardianCount -gt 0 -and $watcherCount -gt 0)
    $summary = if ($serviceRunning) {
        "ctrl-ccv's local service is running. No image was sent during this SSH failure."
    }
    else {
        "This SSH failure was recorded earlier. Refresh status to check whether the local service is running before troubleshooting the connection."
    }
    $supportCode = "CTRL_CCV-SSH-CONNECTION"

    switch ($reason) {
        "cloudflare-sign-in-required" {
            $title = "Cloudflare sign-in is required"
            $whatHappened = "ctrl-ccv found a stale Cloudflare login lock and tried the normal sign-in refresh. The refresh still needs your interaction. Existing terminal SSH sessions can remain connected while a new connection needs sign-in."
            $supportCode = "CTRL_CCV-CLOUDFLARE-SIGN-IN"
        }
        "ssh-mkdir-connect-timeout" {
            $title = "An unattended SSH check timed out"
            $whatHappened = "A new unattended ctrl-ccv process did not receive an SSH greeting before ctrl-ccv's connection deadline. An already-open terminal session can still work because it may use its own signed-in session, agent, or tunnel."
            $supportCode = "CTRL_CCV-SSH-CONNECT-TIMEOUT"
        }
        "ssh-mkdir-timeout" {
            $title = "The first SSH upload step timed out"
            $whatHappened = "ctrl-ccv could not complete the first SSH upload step before its deadline. An unattended SSH check can distinguish a connection problem from a later remote setup delay. An already-open terminal session can still work because it may use its own signed-in session, agent, or tunnel."
            $supportCode = "CTRL_CCV-SSH-COMMAND-TIMEOUT"
        }
        "ssh-mkdir-auth-failed" {
            $title = "An unattended SSH sign-in is required"
            $whatHappened = "ctrl-ccv could not complete a no-prompt sign-in. It cannot answer a password, key passphrase, hardware-key touch, approval, or one-time-code prompt while automatic uploads run."
            $supportCode = "CTRL_CCV-SSH-AUTH"
        }
        "ssh-mkdir-host-key-failed" {
            $title = "SSH server identity needs review"
            $whatHappened = "ctrl-ccv kept SSH host-key protection in place. It will not remove or accept a server identity automatically."
            $supportCode = "CTRL_CCV-SSH-HOST-KEY"
        }
        "ssh-mkdir-host-not-found" {
            $title = "The configured SSH connection was not found"
            $whatHappened = "ctrl-ccv could not resolve the saved SSH connection name from the background uploader."
            $supportCode = "CTRL_CCV-SSH-HOST-NOT-FOUND"
        }
        "ssh-mkdir-proxy-failed" {
            $title = "The SSH proxy or tunnel needs attention"
            $whatHappened = "A new unattended ctrl-ccv process could not start through its configured proxy or tunnel."
            $supportCode = "CTRL_CCV-SSH-PROXY"
        }
        default {
            $title = "An unattended SSH check could not start"
            $whatHappened = "ctrl-ccv could not prepare the remote upload folder because its new unattended SSH process failed."
        }
    }

    $steps = if ($reason -eq "cloudflare-sign-in-required") {
        @(
            "1. Open a new SSH connection through your normal terminal workflow and complete any Cloudflare browser sign-in.",
            "2. Complete passwords, approval, security-key touches, and one-time codes yourself. ctrl-ccv never collects or submits them.",
            "3. Select Test unattended SSH. When it succeeds, select Retry clipboard upload. Automatic uploads also keep retrying."
        ) -join [Environment]::NewLine
    }
    elseif ($reason -eq "ssh-mkdir-auth-failed") {
        @(
            "1. Select Test unattended SSH. It starts a new unattended ctrl-ccv process with the same no-prompt SSH settings as uploads and does not change remote files.",
            "2. If a password, passphrase, approval, security-key touch, or one-time code is required, complete that step only in your normal SSH workflow. ctrl-ccv never asks for, stores, or pastes a code.",
            "3. Make an approved unattended SSH key or agent available to ctrl-ccv, or ask your administrator which automated-upload method is approved.",
            "4. Test again. When it succeeds, select Retry clipboard upload."
        ) -join [Environment]::NewLine
    }
    else {
        @(
            "1. Select Test unattended SSH. It starts a new unattended ctrl-ccv process with the same no-prompt SSH settings as uploads and does not change remote files.",
            "2. If it fails, check your network and any SSH proxy or tunnel, then make sure a new terminal SSH connection can start.",
            "3. Select Open Settings and confirm the saved SSH connection name is the one ctrl-ccv should use.",
            "4. When the test succeeds, select Retry clipboard upload."
        ) -join [Environment]::NewLine
    }

    return [pscustomobject]@{
        Title = $title
        Summary = "$summary $attemptText"
        WhatHappened = $whatHappened
        Steps = $steps
        SupportCode = $supportCode
    }
}

function Get-CtrlCcvTrayHeartbeatText {
    param([AllowNull()]$Heartbeat)

    if ($null -eq $Heartbeat) { return "No valid health record" }
    [int]$failureCount = 0
    try { $failureCount = [int]$Heartbeat.FailureCount } catch { }
    if ($failureCount -gt 1) { return "Retrying after $failureCount failed attempts" }
    if ($failureCount -eq 1) { return "Retrying after one failed attempt" }
    if ($Heartbeat.Status -eq "checking") { return "Watcher: checking clipboard" }
    return "Watcher: idle"
}

function Get-CtrlCcvTrayState {
    # ctrl-ccv-core.ps1 owns its script-scoped cached configuration. Calling
    # its public loader avoids depending on a caller's dot-sourcing scope.
    $cfg = Get-CtrlCcvConfig
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-guardian.ps1"))
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-watch.ps1"))
    $guardianProbe = Get-CtrlCcvTrayProcessProbe -ScriptPath $guardianScript
    $watchProbe = Get-CtrlCcvTrayProcessProbe -ScriptPath $watchScript
    $guardians = @($guardianProbe.Processes)
    $watchers = @($watchProbe.Processes)

    $heartbeatInfo = $null
    $heartbeatAgeSeconds = $null
    if (Test-Path -LiteralPath $cfg.HeartbeatFile) {
        $heartbeatInfo = Get-CtrlCcvHeartbeatInfo -Path $cfg.HeartbeatFile
        if ($heartbeatInfo) {
            $heartbeatAgeSeconds = [Math]::Max(0, ((Get-Date).ToUniversalTime() - $heartbeatInfo.Timestamp.UtcDateTime).TotalSeconds)
        }
    }
    [int]$heartbeatFailureCount = 0
    if ($heartbeatInfo) {
        try { $heartbeatFailureCount = [int]$heartbeatInfo.FailureCount } catch { }
    }

    $uploadStatus = $null
    $uploadStatusPath = Get-CtrlCcvUploadStatusFilePath -Config $cfg
    if (-not [string]::IsNullOrWhiteSpace($uploadStatusPath) -and (Test-Path -LiteralPath $uploadStatusPath)) {
        $uploadStatus = Get-CtrlCcvUploadStatusInfo -Path $uploadStatusPath
    }
    $uploadIssue = $null
    $uploadFailureReason = ""
    # A tray-triggered one-shot retry shares the core upload path but not the
    # watcher's in-memory backoff counter. A newer confirmed success should
    # clear an older retry count immediately rather than leaving a yellow badge
    # in place until the watcher wakes up again.
    $confirmedUploadSupersedesHeartbeat = ($uploadStatus -and $uploadStatus.Result -eq "succeeded" -and
        ((-not $heartbeatInfo) -or $uploadStatus.Timestamp -ge $heartbeatInfo.Timestamp))
    $effectiveHeartbeatFailureCount = if ($confirmedUploadSupersedesHeartbeat) { 0 } else { $heartbeatFailureCount }
    if ($effectiveHeartbeatFailureCount -gt 0) {
        if ($uploadStatus -and $uploadStatus.Result -eq "failed") { $uploadFailureReason = $uploadStatus.Reason }
        $uploadIssue = Get-CtrlCcvTrayUploadIssue -FailureCount $effectiveHeartbeatFailureCount -FailureReason $uploadFailureReason
    }
    elseif ($uploadStatus -and $uploadStatus.Result -eq "failed") {
        $uploadFailureReason = $uploadStatus.Reason
        $uploadIssue = Get-CtrlCcvTrayUploadIssue -FailureReason $uploadFailureReason
    }

    $level = "Unknown"
    $summary = "Status is still loading"
    $detail = ""
    $issueKind = ""
    if ($cfg.ConfigError) {
        $level = "Error"
        $summary = "Configuration needs attention"
        $detail = $cfg.ConfigError
        $issueKind = "Configuration"
    }
    elseif (-not $guardianProbe.Available -or -not $watchProbe.Available) {
        $level = "Unknown"
        $summary = "Cannot inspect local processes"
        $detail = "The tray app will not start or stop processes until inspection works."
    }
    elseif ($guardians.Count -gt 1 -or $watchers.Count -gt 1) {
        $level = "Warning"
        $summary = "Duplicate ctrl-ccv process detected"
        $detail = "Use Restart service to stop only this checkout's duplicate processes."
        $issueKind = "Service"
    }
    elseif ($guardians.Count -eq 0 -and $watchers.Count -eq 0) {
        $level = "Stopped"
        $summary = "The ctrl-ccv service is stopped"
        $detail = "Start service to launch the guardian."
        $issueKind = "Service"
    }
    elseif ($guardians.Count -eq 0) {
        $level = "Warning"
        $summary = "Watcher is running without its guardian"
        $detail = "Restart service to restore watchdog protection."
        $issueKind = "Service"
    }
    elseif ($watchers.Count -eq 0) {
        $level = "Warning"
        $summary = "Automatic uploads are restarting"
        $detail = "The guardian is running, but the clipboard watcher is not active yet. It will start a replacement automatically. Refresh status in a few seconds; use Repair service only if it stays missing."
        $issueKind = "Service"
    }
    elseif (-not $heartbeatInfo) {
        $level = "Warning"
        $summary = "Watcher heartbeat is missing or invalid"
        $detail = "The guardian should recover it."
        $issueKind = "Service"
    }
    elseif ($heartbeatInfo.ProcessId -ne [int]$watchers[0].ProcessId) {
        $level = "Warning"
        $summary = "Watcher heartbeat belongs to another process"
        $detail = "The guardian should recover it."
        $issueKind = "Service"
    }
    elseif ($heartbeatAgeSeconds -gt [double]$cfg.WatchdogStaleSeconds) {
        $level = "Warning"
        $summary = "Watcher heartbeat is stale"
        $detail = "The guardian should recover it; Restart service is safe if it persists."
        $issueKind = "Service"
    }
    elseif ($uploadIssue) {
        $level = "Warning"
        $summary = $uploadIssue.Summary
        $detail = $uploadIssue.Detail
        $issueKind = "Upload"
    }
    else {
        $level = "Healthy"
        $summary = "ctrl-ccv is running"
        $detail = $heartbeatInfo.Status
    }

    # The path state file is written atomically only after a successful upload.
    # Its timestamp gives the tray a privacy-preserving answer to the practical
    # question "did my most recent image upload?" without putting a remote path
    # or host name in the notification area.
    $latestPath = Get-CtrlCcvTrayLatestPath -Config $cfg
    $latestUploadAt = $null
    $latestUploadAgeSeconds = $null
    if (-not [string]::IsNullOrWhiteSpace($latestPath)) {
        try {
            $latestFile = Get-Item -LiteralPath $cfg.LastRemotePathFile -Force -ErrorAction Stop
            if (-not $latestFile.PSIsContainer -and (($latestFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
                $latestUploadAt = [DateTimeOffset]::new($latestFile.LastWriteTimeUtc)
                $latestUploadAgeSeconds = [Math]::Max(0, ((Get-Date).ToUniversalTime() - $latestUploadAt.UtcDateTime).TotalSeconds)
            }
        }
        catch { }
    }
    return [pscustomobject]@{
        Level = $level
        Summary = $summary
        Detail = $detail
        Config = $cfg
        Guardians = $guardians
        Watchers = $watchers
        GuardianProbeAvailable = $guardianProbe.Available
        WatcherProbeAvailable = $watchProbe.Available
        Heartbeat = $heartbeatInfo
        HeartbeatAgeSeconds = $heartbeatAgeSeconds
        UploadStatus = $uploadStatus
        IssueKind = $issueKind
        UploadFailureCount = $effectiveHeartbeatFailureCount
        UploadFailureReason = $uploadFailureReason
        LatestPath = $latestPath
        LatestUploadAt = $latestUploadAt
        LatestUploadAgeSeconds = $latestUploadAgeSeconds
    }
}

function Get-CtrlCcvTrayTooltip {
    param([Parameter(Mandatory)]$State)
    # NotifyIcon accepts at most 63 characters.  Do not put hosts, paths, or
    # log details in a system-wide hover tooltip.
    $latestUpload = Get-CtrlCcvTrayLatestUploadText -State $State
    if (Test-CtrlCcvTraySshConnectionIssue -State $State) {
        $text = "ctrl-ccv: Service running - SSH needs attention"
    }
    elseif ($State.Level -eq "Healthy" -and $latestUpload -match '^Uploaded ') {
        $text = "ctrl-ccv: Healthy - $latestUpload"
    }
    else {
        $text = "ctrl-ccv: $($State.Level) - $(ConvertTo-CtrlCcvTrayDisplayText -Text $State.Summary -MaximumLength 42)"
    }
    if ($text.Length -gt 63) { return $text.Substring(0, 60) + "..." }
    return $text
}

function ConvertTo-CtrlCcvTrayDisplayText {
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(24, 2048)][int]$MaximumLength = 280
    )

    # The status dashboard is intentionally a small, local summary. Never
    # turn a subprocess/configuration detail into an unbounded or credential-
    # bearing UI string, even if a future caller changes the state source.
    $safe = Protect-CtrlCcvLogDetail $Text
    $safe = ($safe -replace '[\r\n\t]+', ' ').Trim()
    if ($safe.Length -gt $MaximumLength) { return $safe.Substring(0, $MaximumLength - 1) + [char]0x2026 }
    return $safe
}

function Get-CtrlCcvTrayStatusStyle {
    param([Parameter(Mandatory)][string]$Level)

    switch ($Level) {
        "Healthy" { return [pscustomobject]@{ Accent = "#0F766E"; Surface = "#ECFDF5"; Foreground = "#115E59"; Badge = "Healthy" } }
        "Warning" { return [pscustomobject]@{ Accent = "#B45309"; Surface = "#FFFBEB"; Foreground = "#92400E"; Badge = "Needs attention" } }
        "Error" { return [pscustomobject]@{ Accent = "#B91C1C"; Surface = "#FEF2F2"; Foreground = "#991B1B"; Badge = "Action needed" } }
        "Stopped" { return [pscustomobject]@{ Accent = "#475569"; Surface = "#F1F5F9"; Foreground = "#334155"; Badge = "Stopped" } }
        default { return [pscustomobject]@{ Accent = "#4F46E5"; Surface = "#EEF2FF"; Foreground = "#3730A3"; Badge = "Checking" } }
    }
}

function Get-CtrlCcvTrayRelativeTimeText {
    param([AllowNull()][object]$AgeSeconds)

    if ($null -eq $AgeSeconds) { return "Waiting for first heartbeat" }
    try { $seconds = [Math]::Max(0, [Math]::Round([double]$AgeSeconds)) }
    catch { return "Waiting for first heartbeat" }
    if ($seconds -lt 2) { return "Just now" }
    if ($seconds -lt 60) { return "$seconds seconds ago" }
    $minutes = [Math]::Floor($seconds / 60)
    if ($minutes -lt 60) { return "${minutes} min ago" }
    $hours = [Math]::Floor($minutes / 60)
    if ($hours -lt 24) { return "${hours} hr ago" }
    $days = [Math]::Floor($hours / 24)
    return "${days} day$($(if ($days -eq 1) { '' } else { 's' })) ago"
}

function Get-CtrlCcvTrayLatestUploadText {
    param([Parameter(Mandatory)]$State)

    # Keep this label path-free: the remote path may reveal a user name or
    # project layout, while the timestamp is enough to confirm upload progress.
    if ([string]::IsNullOrWhiteSpace($State.LatestPath) -or -not (Test-CtrlCcvRemotePath $State.LatestPath)) {
        return "No upload yet"
    }
    if ($null -eq $State.LatestUploadAgeSeconds) { return "Uploaded (time unknown)" }
    return "Uploaded $((Get-CtrlCcvTrayRelativeTimeText -AgeSeconds $State.LatestUploadAgeSeconds).ToLowerInvariant())"
}

function Get-CtrlCcvTrayGuidance {
    param([Parameter(Mandatory)]$State)

    switch ($State.Level) {
        "Healthy" { return "Take screenshots as usual. ctrl-ccv will upload new clipboard images automatically." }
        "Stopped" { return "Start automatic uploads to resume watching the image clipboard." }
        "Error" { return "Open settings, correct the local configuration, then start the service." }
        "Warning" {
            if (Test-CtrlCcvTrayUploadIssue -State $State) {
                if ([string]$State.UploadFailureReason -eq "clipboard-busy") {
                    return "ctrl-ccv is retrying the clipboard automatically. Wait for the upload confirmation; you can keep using the service."
                }
                if (Test-CtrlCcvTraySshConnectionIssue -State $State) {
                    return "The local service is running. Open Connection help to test an unattended SSH process, then retry the clipboard upload after it succeeds."
                }
                if ([string]$State.UploadFailureReason -eq "ssh-mkdir-remote-folder-failed") {
                    return "ctrl-ccv reached the SSH target but could not prepare the remote image folder. Review Settings or ask the server administrator for access before retrying."
                }
                return "ctrl-ccv will retry automatically when it sees an image. Use Retry clipboard upload to try now or View activity for details."
            }
            if ([string]$State.IssueKind -eq "Service" -and (@($State.Guardians)).Count -gt 0 -and (@($State.Watchers)).Count -eq 0) {
                return "Automatic uploads are restarting. Refresh status in a few seconds; use Repair service only if the watcher stays missing."
            }
            return "Use Repair service if this does not clear after the next health check."
        }
        default { return "Refresh status after local process inspection becomes available." }
    }
}

function Get-CtrlCcvTrayColor {
    param([Parameter(Mandatory)][string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}

function Set-CtrlCcvTrayButtonStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [ValidateSet("Primary", "Secondary", "Quiet")][string]$Kind = "Secondary"
    )

    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 1
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $Button.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    switch ($Kind) {
        "Primary" {
            $Button.BackColor = Get-CtrlCcvTrayColor "#2563EB"
            $Button.ForeColor = [System.Drawing.Color]::White
            $Button.FlatAppearance.BorderColor = Get-CtrlCcvTrayColor "#2563EB"
            $Button.FlatAppearance.MouseOverBackColor = Get-CtrlCcvTrayColor "#1D4ED8"
            $Button.FlatAppearance.MouseDownBackColor = Get-CtrlCcvTrayColor "#1E40AF"
        }
        "Quiet" {
            $Button.BackColor = Get-CtrlCcvTrayColor "#F8FAFC"
            $Button.ForeColor = Get-CtrlCcvTrayColor "#334155"
            $Button.FlatAppearance.BorderColor = Get-CtrlCcvTrayColor "#CBD5E1"
            $Button.FlatAppearance.MouseOverBackColor = Get-CtrlCcvTrayColor "#E2E8F0"
            $Button.FlatAppearance.MouseDownBackColor = Get-CtrlCcvTrayColor "#CBD5E1"
        }
        default {
            $Button.BackColor = [System.Drawing.Color]::White
            $Button.ForeColor = Get-CtrlCcvTrayColor "#1E3A5F"
            $Button.FlatAppearance.BorderColor = Get-CtrlCcvTrayColor "#93C5FD"
            $Button.FlatAppearance.MouseOverBackColor = Get-CtrlCcvTrayColor "#EFF6FF"
            $Button.FlatAppearance.MouseDownBackColor = Get-CtrlCcvTrayColor "#DBEAFE"
        }
    }
}

function New-CtrlCcvTrayMetricCard {
    param([Parameter(Mandatory)][string]$Title)

    $border = New-Object System.Windows.Forms.Panel
    $border.BackColor = Get-CtrlCcvTrayColor "#D9E2F0"
    $border.Dock = [System.Windows.Forms.DockStyle]::Fill
    $border.Padding = New-Object System.Windows.Forms.Padding(1)

    $content = New-Object System.Windows.Forms.Panel
    $content.BackColor = [System.Drawing.Color]::White
    $content.Dock = [System.Windows.Forms.DockStyle]::Fill
    $content.Padding = New-Object System.Windows.Forms.Padding(14, 12, 14, 10)
    $border.Controls.Add($content)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title.ToUpperInvariant()
    $titleLabel.AutoSize = $true
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $titleLabel.ForeColor = Get-CtrlCcvTrayColor "#64748B"
    $titleLabel.Location = New-Object System.Drawing.Point(14, 12)
    $content.Controls.Add($titleLabel)

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.AutoEllipsis = $true
    $valueLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 13)
    $valueLabel.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
    $valueLabel.Location = New-Object System.Drawing.Point(14, 33)
    $valueLabel.Size = New-Object System.Drawing.Size(215, 26)
    $content.Controls.Add($valueLabel)

    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.AutoEllipsis = $true
    $detailLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $detailLabel.ForeColor = Get-CtrlCcvTrayColor "#64748B"
    $detailLabel.Location = New-Object System.Drawing.Point(14, 62)
    $detailLabel.Size = New-Object System.Drawing.Size(215, 19)
    $content.Controls.Add($detailLabel)

    return [pscustomobject]@{ Container = $border; Value = $valueLabel; Detail = $detailLabel }
}

function Get-CtrlCcvTrayIconAssetPath {
    # Keep branding with the checked-in source rather than a user profile or
    # configuration value. A custom icon must never become another input that
    # can point the tray at an arbitrary local file.
    return (Join-Path $PSScriptRoot "assets\windows\ctrl-ccv-tray.ico")
}

function Get-CtrlCcvTrayLogoAssetPath {
    # The dashboard logo is also a checked-in project asset, not a configured
    # local path. That keeps the UI deterministic and avoids another
    # filesystem input in a process that starts at logon.
    return (Join-Path $PSScriptRoot "assets\windows\ctrl-ccv-logo.png")
}

function Get-CtrlCcvTrayLogo {
    [CmdletBinding()]
    param(
        [string]$LogoPath = (Get-CtrlCcvTrayLogoAssetPath)
    )

    $bitmap = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($LogoPath) -or -not (Test-Path -LiteralPath $LogoPath -PathType Leaf)) { return $null }
        $item = Get-Item -LiteralPath $LogoPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            [IO.Path]::GetExtension($item.Name) -ine ".png" -or $item.Length -lt 128 -or $item.Length -gt 2MB) {
            return $null
        }

        # Clone the image before closing the stream so the dashboard neither
        # locks the checkout nor keeps a handle to a partially read asset.
        $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $source = [System.Drawing.Image]::FromStream($stream, $true, $true)
            try { $bitmap = [System.Drawing.Bitmap]::new($source) }
            finally { $source.Dispose() }
        }
        finally { $stream.Dispose() }
        if ($bitmap.Width -lt 32 -or $bitmap.Height -lt 32 -or $bitmap.Width -gt 2048 -or $bitmap.Height -gt 2048) {
            $bitmap.Dispose()
            return $null
        }
        return $bitmap
    }
    catch {
        if ($bitmap) { $bitmap.Dispose() }
        # The logo is cosmetic. A bad local asset must never stop the status
        # controller or disclose a raw GDI+/filesystem error in the UI.
        return $null
    }
}

function Get-CtrlCcvTrayIcon {
    [CmdletBinding()]
    param(
        # This is overridable only so the local-only tests can exercise bad
        # assets without changing a real checkout. Production callers use the
        # project-local default above.
        [string]$IconPath = (Get-CtrlCcvTrayIconAssetPath)
    )

    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $fallback = [System.Drawing.SystemIcons]::Application
    }
    catch {
        throw "ctrl-ccv tray icons require the Windows System.Drawing assembly."
    }
    $fallbackResult = {
        param([string]$Reason)
        return [pscustomobject]@{
            Icon = $fallback
            OwnsIcon = $false
            IsFallback = $true
            Source = "Windows application icon"
            Reason = $Reason
        }
    }
    $icon = $null
    try {
        if ([string]::IsNullOrWhiteSpace($IconPath) -or -not (Test-Path -LiteralPath $IconPath -PathType Leaf)) {
            return (& $fallbackResult "missing")
        }

        $item = Get-Item -LiteralPath $IconPath -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return (& $fallbackResult "unsafe-file")
        }
        # An ICO with the resolutions appropriate for the notification area is
        # normally tens of kilobytes. Bound it before GDI+ parses it, which
        # also prevents a corrupt local asset from delaying the tray at login.
        if ($item.Length -lt 6 -or $item.Length -gt 1MB -or [IO.Path]::GetExtension($item.Name) -ine ".ico") {
            return (& $fallbackResult "invalid-file")
        }

        $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            [byte[]]$header = [byte[]]::new(6)
            $offset = 0
            while ($offset -lt $header.Length) {
                $read = $stream.Read($header, $offset, $header.Length - $offset)
                if ($read -le 0) { break }
                $offset += $read
            }
        }
        finally {
            $stream.Dispose()
        }
        if ($offset -ne 6 -or $header[0] -ne 0 -or $header[1] -ne 0 -or $header[2] -ne 1 -or $header[3] -ne 0 -or ($header[4] -eq 0 -and $header[5] -eq 0)) {
            return (& $fallbackResult "invalid-header")
        }

        $icon = New-Object System.Drawing.Icon($item.FullName)
        if ($icon.Width -lt 16 -or $icon.Height -lt 16 -or $icon.Width -gt 512 -or $icon.Height -gt 512) {
            $icon.Dispose()
            $icon = $null
            return (& $fallbackResult "unsupported-size")
        }
        return [pscustomobject]@{
            Icon = $icon
            OwnsIcon = $true
            IsFallback = $false
            Source = "project asset"
            Reason = ""
        }
    }
    catch {
        if ($icon) { $icon.Dispose() }
        # Do not surface raw GDI+/filesystem error text: it could expose a
        # local path in a tray-facing surface or log. The system icon is a
        # reliable, dependency-free fallback.
        return (& $fallbackResult "unreadable")
    }
}

function Initialize-CtrlCcvTrayNativeIconInterop {
    if ($null -ne ("CtrlCcv.Tray.NativeIconInterop" -as [type])) { return $true }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CtrlCcv.Tray {
    public static class NativeIconInterop {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);
    }
}
'@ -ErrorAction Stop
    }
    catch { }
    return ($null -ne ("CtrlCcv.Tray.NativeIconInterop" -as [type]))
}

function New-CtrlCcvTrayStatusIcon {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Drawing.Icon]$BaseIcon,
        [Parameter(Mandatory)][ValidateSet("Warning", "Error", "Stopped", "Unknown")][string]$Level
    )

    # NotifyIcon has no badge API. Compose a small, owned status variant from
    # the checked-in base icon, then clone it before releasing the native HICON.
    # The returned clone stays alive in the tray's per-level cache.
    $bitmap = $null
    $graphics = $null
    $badgeBrush = $null
    $outlinePen = $null
    $symbolPen = $null
    $symbolBrush = $null
    $symbolFont = $null
    $symbolFormat = $null
    $handleIcon = $null
    $createdIcon = $null
    [IntPtr]$nativeIconHandle = [IntPtr]::Zero
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        if (-not (Initialize-CtrlCcvTrayNativeIconInterop)) { return $null }

        $sourceSize = [Math]::Max($BaseIcon.Width, $BaseIcon.Height)
        [int]$canvasSize = [Math]::Min(64, [Math]::Max(32, [int]$sourceSize))
        $bitmap = [System.Drawing.Bitmap]::new($canvasSize, $canvasSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawIcon($BaseIcon, (New-Object System.Drawing.Rectangle -ArgumentList @(0, 0, $canvasSize, $canvasSize)))

        $style = Get-CtrlCcvTrayStatusStyle -Level $Level
        [int]$badgeDiameter = [Math]::Min(28, [Math]::Max(14, [int][Math]::Round($canvasSize * 0.48)))
        [int]$badgeMargin = [Math]::Max(1, [int][Math]::Round($canvasSize * 0.03))
        [int]$badgeLeft = $canvasSize - $badgeDiameter - $badgeMargin
        [int]$badgeTop = $canvasSize - $badgeDiameter - $badgeMargin
        $badgeRect = New-Object System.Drawing.RectangleF -ArgumentList @([single]$badgeLeft, [single]$badgeTop, [single]$badgeDiameter, [single]$badgeDiameter)
        $badgeBrush = [System.Drawing.SolidBrush]::new((Get-CtrlCcvTrayColor $style.Accent))
        $symbolBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
        $outlinePen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, [Math]::Max(1.5, $canvasSize * 0.055))
        $graphics.FillEllipse($badgeBrush, $badgeRect)
        $graphics.DrawEllipse($outlinePen, $badgeRect)

        if ($Level -in @("Warning", "Error", "Stopped")) {
            $symbolPen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, [Math]::Max(2.0, $canvasSize * 0.08))
            $symbolPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $symbolPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            [single]$centerX = $badgeLeft + ($badgeDiameter / 2.0)
            [single]$centerY = $badgeTop + ($badgeDiameter / 2.0)
            if ($Level -eq "Stopped") {
                $graphics.DrawLine($symbolPen, $badgeLeft + ($badgeDiameter * 0.30), $centerY, $badgeLeft + ($badgeDiameter * 0.70), $centerY)
            }
            else {
                $graphics.DrawLine($symbolPen, $centerX, $badgeTop + ($badgeDiameter * 0.27), $centerX, $badgeTop + ($badgeDiameter * 0.58))
                [single]$dotDiameter = [Math]::Max(2.5, $badgeDiameter * 0.13)
                $graphics.FillEllipse($symbolBrush, $centerX - ($dotDiameter / 2), $badgeTop + ($badgeDiameter * 0.71), $dotDiameter, $dotDiameter)
            }
        }
        else {
            $symbolFont = [System.Drawing.Font]::new("Segoe UI", [single]($badgeDiameter * 0.68), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $symbolFormat = [System.Drawing.StringFormat]::new()
            $symbolFormat.Alignment = [System.Drawing.StringAlignment]::Center
            $symbolFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
            $graphics.DrawString("?", $symbolFont, $symbolBrush, $badgeRect, $symbolFormat)
        }

        $nativeIconHandle = $bitmap.GetHicon()
        $handleIcon = [System.Drawing.Icon]::FromHandle($nativeIconHandle)
        $createdIcon = [System.Drawing.Icon]$handleIcon.Clone()
        return $createdIcon
    }
    catch {
        if ($createdIcon) { $createdIcon.Dispose() }
        return $null
    }
    finally {
        if ($handleIcon) { $handleIcon.Dispose() }
        if ($nativeIconHandle -ne [IntPtr]::Zero) { [void][CtrlCcv.Tray.NativeIconInterop]::DestroyIcon($nativeIconHandle) }
        if ($symbolFormat) { $symbolFormat.Dispose() }
        if ($symbolFont) { $symbolFont.Dispose() }
        if ($symbolPen) { $symbolPen.Dispose() }
        if ($outlinePen) { $outlinePen.Dispose() }
        if ($symbolBrush) { $symbolBrush.Dispose() }
        if ($badgeBrush) { $badgeBrush.Dispose() }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
    }
}

function Get-CtrlCcvTrayStatusIcon {
    param(
        [Parameter(Mandatory)][System.Drawing.Icon]$BaseIcon,
        [Parameter(Mandatory)][string]$Level,
        [Parameter(Mandatory)][hashtable]$Cache
    )

    if ($Level -eq "Healthy") { return $BaseIcon }
    $cacheKey = if ($Level -in @("Warning", "Error", "Stopped", "Unknown")) { $Level } else { "Unknown" }
    if ($Cache.ContainsKey($cacheKey)) { return $Cache[$cacheKey] }
    $icon = New-CtrlCcvTrayStatusIcon -BaseIcon $BaseIcon -Level $cacheKey
    if ($icon) {
        $Cache[$cacheKey] = $icon
        return $icon
    }
    # The text/status surfaces still report the condition if Windows cannot
    # compose a cosmetic badge on this machine.
    return $BaseIcon
}

function Start-CtrlCcvTrayGuardian {
    $cfg = Get-CtrlCcvConfig
    if ($cfg.ConfigError) { throw $cfg.ConfigError }
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-guardian.ps1"))
    $probe = Get-CtrlCcvTrayProcessProbe -ScriptPath $guardianScript
    if (-not $probe.Available) { throw "Cannot inspect local processes; refusing to start another guardian." }
    if ((@($probe.Processes)).Count -gt 0) { return $false }

    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $guardianScript)
    ) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Write-CtrlCcvLog "tray requested guardian start"
    return $true
}

function Stop-CtrlCcvTrayService {
    $guardianScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-guardian.ps1"))
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-watch.ps1"))
    $guardianProbe = Get-CtrlCcvTrayProcessProbe -ScriptPath $guardianScript
    $watchProbe = Get-CtrlCcvTrayProcessProbe -ScriptPath $watchScript
    if (-not $guardianProbe.Available -or -not $watchProbe.Available) {
        throw "Cannot inspect local processes; refusing to stop anything."
    }

    # Stop the guardian first to prevent it from immediately replacing a
    # watcher that the user explicitly asked to stop.  Both lists are scoped
    # by the exact checkout path, never a filename-only match.
    foreach ($process in @($guardianProbe.Processes) + @($watchProbe.Processes)) {
        Stop-CtrlCcvProcessTree -ProcessId ([int]$process.ProcessId)
    }
    Write-CtrlCcvLog "tray requested service stop"
}

function Restart-CtrlCcvTrayService {
    Stop-CtrlCcvTrayService
    Start-Sleep -Milliseconds 500
    [void](Start-CtrlCcvTrayGuardian)
    Write-CtrlCcvLog "tray requested service restart"
}

function Start-CtrlCcvTrayUpload {
    $cfg = Get-CtrlCcvConfig
    if ($cfg.ConfigError) { throw $cfg.ConfigError }
    $nowScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-now.ps1"))
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $nowScript), "-Silent"
    ) -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
    Write-CtrlCcvLog "tray requested one-shot clipboard upload"
}

function Start-CtrlCcvTraySshConnectionCheckProcess {
    <#
    .SYNOPSIS
    Runs the read-only SSH connection check away from the WinForms UI thread.

    .DESCRIPTION
    The tray owns the helper process directly so cancelling the window also
    stops its SSH and ProxyCommand descendants. The helper accepts no UI
    command or target and emits only a controlled JSON category.
    #>
    $root = [IO.Path]::GetFullPath($PSScriptRoot)
    $helper = Join-Path $root "ctrl-ccv-connection-check.ps1"
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw "The ctrl-ccv connection-check helper is unavailable."
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = ((@(
        "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "RemoteSigned", "-File", $helper
    ) | ForEach-Object { ConvertTo-CtrlCcvCommandArgument ([string]$_) }) -join " ")
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) { throw "Process did not start." }
        $outputLimit = ConvertTo-CtrlCcvStrictInteger -Value $script:CtrlCcvConfig.MaxCommandOutputBytes
        $limit = if ($outputLimit.IsValid) { [Math]::Max(1024, $outputLimit.Value) } else { 65536 }
        $stdoutSink = New-Object -TypeName CtrlCcvBoundedOutput -ArgumentList $limit
        $stderrSink = New-Object -TypeName CtrlCcvBoundedOutput -ArgumentList $limit
        return [pscustomobject]@{
            Process = $process
            StdOutSink = $stdoutSink
            StdErrSink = $stderrSink
            StdOutTask = $stdoutSink.PumpAsync($process.StandardOutput)
            StdErrTask = $stderrSink.PumpAsync($process.StandardError)
        }
    }
    catch {
        $process.Dispose()
        throw
    }
}

function Receive-CtrlCcvTraySshConnectionCheckProcess {
    <#
    .SYNOPSIS
    Reads a completed connection-check helper without exposing its output.
    #>
    param([Parameter(Mandatory)]$Operation)

    if ($null -eq $Operation.Process) {
        return [pscustomobject]@{ Completed = $true; Result = (Get-CtrlCcvSshConnectionCheckPresentation -FailureKind "check-unavailable") }
    }
    try {
        if (-not $Operation.Process.HasExited) {
            return [pscustomobject]@{ Completed = $false; Result = $null }
        }
    }
    catch {
        return [pscustomobject]@{ Completed = $true; Result = (Get-CtrlCcvSshConnectionCheckPresentation -FailureKind "check-unavailable") }
    }

    $failureKind = "check-unavailable"
    try {
        $Operation.Process.WaitForExit()
        $Operation.StdOutTask.Wait(2000) | Out-Null
        $Operation.StdErrTask.Wait(2000) | Out-Null
        $payload = [string]$Operation.StdOutSink.Text
        $records = @($payload -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($Operation.Process.ExitCode -eq 0 -and
            -not [bool]$Operation.StdOutSink.Truncated -and
            -not [bool]$Operation.StdErrSink.Truncated -and
            [string]::IsNullOrWhiteSpace([string]$Operation.StdErrSink.Text) -and
            $records.Count -eq 1 -and
            $records[0].Length -le 4096) {
            $record = $records[0] | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $record -and
                $null -ne $record.PSObject.Properties["Version"] -and
                $null -ne $record.PSObject.Properties["FailureKind"] -and
                [string]$record.Version -eq "1" -and
                [string]$record.FailureKind -in @(
                    "connected", "connect-timeout", "authentication", "host-key",
                    "host-not-found", "proxy", "command-timeout", "configuration",
                    "connection-failed"
                )) {
                $failureKind = [string]$record.FailureKind
            }
        }
    }
    catch { }
    finally {
        # The helper's stdout/stderr can contain implementation detail if a
        # dependency misbehaves. Discard both and rebuild text from the
        # allowlisted token below.
        try { $Operation.Process.Dispose() } catch { }
        $Operation.Process = $null
    }

    return [pscustomobject]@{ Completed = $true; Result = (Get-CtrlCcvSshConnectionCheckPresentation -FailureKind $failureKind) }
}

function Stop-CtrlCcvTraySshConnectionCheckProcess {
    param([AllowNull()]$Operation)

    if ($null -eq $Operation -or $null -eq $Operation.Process) { return }
    try {
        if (-not $Operation.Process.HasExited) {
            # Kill this directly owned wrapper plus ssh and any configured
            # ProxyCommand/tunnel descendants; Stop-Job cannot guarantee it.
            Stop-CtrlCcvProcessTree -ProcessId $Operation.Process.Id
        }
    }
    catch { }
    try { $Operation.Process.WaitForExit(5000) | Out-Null } catch { }
    try { $Operation.StdOutTask.Wait(2000) | Out-Null } catch { }
    try { $Operation.StdErrTask.Wait(2000) | Out-Null } catch { }
    try { $Operation.Process.Dispose() } catch { }
    $Operation.Process = $null
}

function Copy-CtrlCcvTrayLatestPath {
    param([Parameter(Mandatory)]$State)
    if ([string]::IsNullOrWhiteSpace($State.LatestPath) -or -not (Test-CtrlCcvRemotePath $State.LatestPath)) {
        throw "There is no valid uploaded path to copy yet."
    }
    Set-Clipboard -Value $State.LatestPath
}

function Get-CtrlCcvTrayRecentActivityText {
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateRange(1, 500)][int]$MaximumLines = 100,
        [ValidateRange(1024, 1048576)][int]$MaximumBytes = 65536
    )

    $path = [string]$Config.LogFile
    if ([string]::IsNullOrWhiteSpace($path)) { return "Recent activity is unavailable." }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "No local activity has been recorded yet." }

    $stream = $null
    $reader = $null
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return "Recent activity is unavailable because the log is not a regular file."
        }

        # Read only a bounded tail. The watcher can be writing at the same
        # time, so permit a shared read but never create or modify the log.
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $offset = [Math]::Max([int64]0, $stream.Length - [int64]$MaximumBytes)
        [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, $true)
        $text = $reader.ReadToEnd()
        if ($offset -gt 0) {
            # Discard the leading partial record after seeking into the file.
            $newline = $text.IndexOf("`n")
            if ($newline -ge 0) { $text = $text.Substring($newline + 1) }
        }
        $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last $MaximumLines)
        if ($lines.Count -eq 0) { return "No local activity has been recorded yet." }
        return (($lines | ForEach-Object {
            ConvertTo-CtrlCcvTrayDisplayText -Text $_ -MaximumLength 1200
        }) -join [Environment]::NewLine)
    }
    catch {
        # Do not surface a file path or unbounded OS exception in a UI that is
        # routinely opened from the notification area.
        return "Recent activity is temporarily unavailable."
    }
    finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Show-CtrlCcvTrayRecentActivityWindow {
    param([switch]$TestMode)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = $null
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "ctrlCcvTrayRecentActivityWindow"
        $form.Text = "ctrl-ccv recent activity"
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(760, 500)
        $form.MinimumSize = New-Object System.Drawing.Size(620, 400)
        $form.BackColor = Get-CtrlCcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

        $title = New-Object System.Windows.Forms.Label
        $title.Name = "ctrlCcvTrayRecentActivityTitle"
        $title.Text = "Recent activity"
        $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
        $title.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
        $title.Location = New-Object System.Drawing.Point(22, 18)
        $form.Controls.Add($title)

        $subtitle = New-Object System.Windows.Forms.Label
        $subtitle.Name = "ctrlCcvTrayRecentActivitySubtitle"
        $subtitle.Text = "The latest 100 local records are shown here. Sensitive values are redacted."
        $subtitle.AutoSize = $true
        $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $subtitle.ForeColor = Get-CtrlCcvTrayColor "#64748B"
        $subtitle.Location = New-Object System.Drawing.Point(24, 50)
        $form.Controls.Add($subtitle)

        $activity = New-Object System.Windows.Forms.TextBox
        $activity.Name = "ctrlCcvTrayRecentActivityTextBox"
        $activity.Multiline = $true
        $activity.ReadOnly = $true
        $activity.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
        $activity.WordWrap = $false
        $activity.Font = New-Object System.Drawing.Font("Cascadia Mono", 9)
        $activity.BackColor = [System.Drawing.Color]::White
        $activity.ForeColor = Get-CtrlCcvTrayColor "#1E293B"
        $activity.Location = New-Object System.Drawing.Point(24, 82)
        $activity.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $activity.Size = New-Object System.Drawing.Size(712, 352)
        $form.Controls.Add($activity)

        $refresh = New-Object System.Windows.Forms.Button
        $refresh.Name = "ctrlCcvTrayRecentActivityRefreshButton"
        $refresh.Text = "Refresh"
        $refresh.Size = New-Object System.Drawing.Size(104, 32)
        $refresh.Location = New-Object System.Drawing.Point(520, 450)
        $refresh.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $refresh -Kind Secondary
        $form.Controls.Add($refresh)

        $close = New-Object System.Windows.Forms.Button
        $close.Name = "ctrlCcvTrayRecentActivityCloseButton"
        $close.Text = "Close"
        $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $close.Size = New-Object System.Drawing.Size(104, 32)
        $close.Location = New-Object System.Drawing.Point(632, 450)
        $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $close -Kind Quiet
        $form.Controls.Add($close)
        $form.CancelButton = $close

        $reload = {
            $cfg = Get-CtrlCcvConfig
            $activity.Text = Get-CtrlCcvTrayRecentActivityText -Config $cfg
            $activity.SelectionStart = $activity.TextLength
            $activity.ScrollToCaret()
        }.GetNewClosure()
        $refresh.Add_Click({ & $reload })
        $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        & $reload
        [void]$form.ShowDialog()
    }
    finally {
        if ($form) { $form.Dispose() }
    }
}

function Show-CtrlCcvTrayConnectionHelpWindow {
    <#
    .SYNOPSIS
    Shows a guided, private-safe walkthrough for an early SSH upload failure.

    .DESCRIPTION
    The status dashboard is intentionally compact.  This separate assistant
    keeps the customer-facing explanation, safe unattended SSH check, and
    next steps together without turning the activity log into the primary
    troubleshooting experience.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [switch]$TestMode,
        [switch]$UseAsyncWorker
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = $null
    $checkTimer = $null
    $checkState = $null
    try {
        if (-not $TestMode) {
            $State = Get-CtrlCcvTrayState
            if (-not (Test-CtrlCcvTraySshConnectionIssue -State $State)) {
                Show-CtrlCcvTrayError "This SSH connection issue is no longer current. Refresh status to see the latest local service state."
                return
            }
        }
        $guide = Get-CtrlCcvTraySshTroubleshooting -State $State
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "ctrlCcvTrayConnectionHelpWindow"
        $form.Text = "ctrl-ccv connection assistant"
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(760, 590)
        $form.MinimumSize = New-Object System.Drawing.Size(650, 630)
        $form.BackColor = Get-CtrlCcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.KeyPreview = $true

        $title = New-Object System.Windows.Forms.Label
        $title.Name = "ctrlCcvTrayConnectionHelpTitle"
        $title.Text = "Connection assistant"
        $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
        $title.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
        $title.Location = New-Object System.Drawing.Point(24, 20)
        $form.Controls.Add($title)

        $subtitle = New-Object System.Windows.Forms.Label
        $subtitle.Name = "ctrlCcvTrayConnectionHelpSubtitle"
        $subtitle.Text = $guide.Summary
        $subtitle.AutoSize = $false
        $subtitle.ForeColor = Get-CtrlCcvTrayColor "#475569"
        $subtitle.Location = New-Object System.Drawing.Point(26, 52)
        $subtitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $subtitle.Size = New-Object System.Drawing.Size(704, 38)
        $form.Controls.Add($subtitle)

        $issueBorder = New-Object System.Windows.Forms.Panel
        $issueBorder.BackColor = Get-CtrlCcvTrayColor "#FDE68A"
        $issueBorder.Location = New-Object System.Drawing.Point(24, 96)
        $issueBorder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $issueBorder.Size = New-Object System.Drawing.Size(712, 104)
        $form.Controls.Add($issueBorder)

        $issue = New-Object System.Windows.Forms.Panel
        $issue.Name = "ctrlCcvTrayConnectionHelpIssue"
        $issue.BackColor = Get-CtrlCcvTrayColor "#FFFBEB"
        $issue.Location = New-Object System.Drawing.Point(1, 1)
        $issue.Size = New-Object System.Drawing.Size(710, 102)
        $issue.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $issueBorder.Controls.Add($issue)

        $issueTitle = New-Object System.Windows.Forms.Label
        $issueTitle.Name = "ctrlCcvTrayConnectionHelpIssueTitle"
        $issueTitle.Text = $guide.Title
        $issueTitle.AutoEllipsis = $true
        $issueTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
        $issueTitle.ForeColor = Get-CtrlCcvTrayColor "#92400E"
        $issueTitle.Location = New-Object System.Drawing.Point(16, 12)
        $issueTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $issueTitle.Size = New-Object System.Drawing.Size(670, 24)
        $issue.Controls.Add($issueTitle)

        $issueDetail = New-Object System.Windows.Forms.Label
        $issueDetail.Name = "ctrlCcvTrayConnectionHelpIssueDetail"
        $issueDetail.Text = $guide.WhatHappened
        $issueDetail.AutoEllipsis = $true
        $issueDetail.ForeColor = Get-CtrlCcvTrayColor "#78350F"
        $issueDetail.Location = New-Object System.Drawing.Point(16, 40)
        $issueDetail.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $issueDetail.Size = New-Object System.Drawing.Size(670, 48)
        $issue.Controls.Add($issueDetail)

        $stepsTitle = New-Object System.Windows.Forms.Label
        $stepsTitle.Text = "What to do"
        $stepsTitle.AutoSize = $true
        $stepsTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
        $stepsTitle.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
        $stepsTitle.Location = New-Object System.Drawing.Point(24, 218)
        $form.Controls.Add($stepsTitle)

        $steps = New-Object System.Windows.Forms.TextBox
        $steps.Name = "ctrlCcvTrayConnectionHelpSteps"
        $steps.Text = $guide.Steps
        $steps.Multiline = $true
        $steps.ReadOnly = $true
        $steps.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $steps.BackColor = $form.BackColor
        $steps.ForeColor = Get-CtrlCcvTrayColor "#334155"
        $steps.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $steps.Location = New-Object System.Drawing.Point(26, 244)
        $steps.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $steps.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $steps.Size = New-Object System.Drawing.Size(704, 120)
        $form.Controls.Add($steps)

        $checkBorder = New-Object System.Windows.Forms.Panel
        $checkBorder.BackColor = Get-CtrlCcvTrayColor "#CBD5E1"
        $checkBorder.Location = New-Object System.Drawing.Point(24, 374)
        $checkBorder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $checkBorder.Size = New-Object System.Drawing.Size(712, 82)
        $form.Controls.Add($checkBorder)

        $checkPanel = New-Object System.Windows.Forms.Panel
        $checkPanel.BackColor = [System.Drawing.Color]::White
        $checkPanel.Location = New-Object System.Drawing.Point(1, 1)
        $checkPanel.Size = New-Object System.Drawing.Size(710, 80)
        $checkPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $checkBorder.Controls.Add($checkPanel)

        $checkTitle = New-Object System.Windows.Forms.Label
        $checkTitle.Name = "ctrlCcvTrayConnectionCheckTitle"
        $checkTitle.Text = "Next: test unattended SSH"
        $checkTitle.AutoEllipsis = $true
        $checkTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
        $checkTitle.ForeColor = Get-CtrlCcvTrayColor "#1E293B"
        $checkTitle.Location = New-Object System.Drawing.Point(14, 10)
        $checkTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $checkTitle.Size = New-Object System.Drawing.Size(674, 21)
        $checkPanel.Controls.Add($checkTitle)

        $checkDetail = New-Object System.Windows.Forms.Label
        $checkDetail.Name = "ctrlCcvTrayConnectionCheckDetail"
        $checkDetail.Text = "This starts a new unattended ctrl-ccv process with upload settings. It does not use an open terminal process, upload an image, or change remote files."
        $checkDetail.AutoEllipsis = $true
        $checkDetail.ForeColor = Get-CtrlCcvTrayColor "#475569"
        $checkDetail.Location = New-Object System.Drawing.Point(14, 35)
        $checkDetail.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $checkDetail.Size = New-Object System.Drawing.Size(674, 32)
        $checkPanel.Controls.Add($checkDetail)

        $test = New-Object System.Windows.Forms.Button
        $test.Name = "ctrlCcvTrayConnectionTestButton"
        $test.Text = "Test unattended SSH"
        $test.Size = New-Object System.Drawing.Size(172, 36)
        $test.Location = New-Object System.Drawing.Point(24, 474)
        Set-CtrlCcvTrayButtonStyle -Button $test -Kind Primary
        $form.Controls.Add($test)

        $settings = New-Object System.Windows.Forms.Button
        $settings.Name = "ctrlCcvTrayConnectionSettingsButton"
        $settings.Text = "Open Settings"
        $settings.Size = New-Object System.Drawing.Size(126, 36)
        $settings.Location = New-Object System.Drawing.Point(206, 474)
        Set-CtrlCcvTrayButtonStyle -Button $settings -Kind Secondary
        $form.Controls.Add($settings)

        $retry = New-Object System.Windows.Forms.Button
        $retry.Name = "ctrlCcvTrayConnectionRetryButton"
        $retry.Text = "Retry clipboard upload"
        $retry.Size = New-Object System.Drawing.Size(166, 36)
        $retry.Location = New-Object System.Drawing.Point(342, 474)
        $retry.Enabled = $false
        Set-CtrlCcvTrayButtonStyle -Button $retry -Kind Secondary
        $form.Controls.Add($retry)

        $activity = New-Object System.Windows.Forms.Button
        $activity.Name = "ctrlCcvTrayConnectionActivityButton"
        $activity.Text = "View activity"
        $activity.Size = New-Object System.Drawing.Size(120, 36)
        $activity.Location = New-Object System.Drawing.Point(518, 474)
        Set-CtrlCcvTrayButtonStyle -Button $activity -Kind Quiet
        $form.Controls.Add($activity)

        $close = New-Object System.Windows.Forms.Button
        $close.Name = "ctrlCcvTrayConnectionCloseButton"
        $close.Text = "Close"
        $close.Size = New-Object System.Drawing.Size(92, 30)
        $close.Location = New-Object System.Drawing.Point(644, 526)
        $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        Set-CtrlCcvTrayButtonStyle -Button $close -Kind Quiet
        $form.Controls.Add($close)
        $form.CancelButton = $close

        $support = New-Object System.Windows.Forms.Label
        $support.Name = "ctrlCcvTrayConnectionSupportCode"
        $support.Text = "Safe support code: $($guide.SupportCode)"
        $support.AutoEllipsis = $true
        $support.ForeColor = Get-CtrlCcvTrayColor "#64748B"
        $support.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $support.Location = New-Object System.Drawing.Point(24, 526)
        $support.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $support.Size = New-Object System.Drawing.Size(602, 24)
        $form.Controls.Add($support)

        $setBusy = {
            param([bool]$Busy)
            $test.Enabled = -not $Busy
            $settings.Enabled = -not $Busy
            $activity.Enabled = -not $Busy
            $retry.Enabled = (-not $Busy -and [bool]$form.Tag)
            $close.Text = if ($Busy) { "Cancel and close" } else { "Close" }
        }.GetNewClosure()
        $renderCheck = {
            param([Parameter(Mandatory)]$Result)
            $checkTitle.Text = ConvertTo-CtrlCcvTrayDisplayText -Text ([string]$Result.Summary) -MaximumLength 180
            $checkDetail.Text = ConvertTo-CtrlCcvTrayDisplayText -Text ("$($Result.Detail) $($Result.NextStep)") -MaximumLength 300
            if ([bool]$Result.Ok) {
                $checkTitle.ForeColor = Get-CtrlCcvTrayColor "#0F766E"
                $checkDetail.ForeColor = Get-CtrlCcvTrayColor "#115E59"
                $form.Tag = $true
            }
            else {
                $checkTitle.ForeColor = Get-CtrlCcvTrayColor "#B45309"
                $checkDetail.ForeColor = Get-CtrlCcvTrayColor "#92400E"
                $form.Tag = $false
            }
            & $setBusy $false
        }.GetNewClosure()

        $checkState = [ordered]@{ Operation = $null; StartedAt = $null }
        $checkTimer = New-Object System.Windows.Forms.Timer
        $checkTimer.Interval = 150
        $checkTimer.Add_Tick({
            if ($null -eq $checkState.Operation) {
                $checkTimer.Stop()
                return
            }
            $completion = Receive-CtrlCcvTraySshConnectionCheckProcess -Operation $checkState.Operation
            if (-not $completion.Completed) {
                if ($checkState.StartedAt -and ((Get-Date) - $checkState.StartedAt).TotalSeconds -ge 2) {
                    $checkTitle.Text = "Testing unattended SSH..."
                    $checkDetail.Text = "This can take up to ctrl-ccv's configured command timeout. You can cancel and close this window."
                }
                return
            }
            $checkTimer.Stop()
            $checkState.Operation = $null
            $checkState.StartedAt = $null
            & $renderCheck $completion.Result
        }.GetNewClosure())

        $startCheck = {
            try {
                & $setBusy $true
                $checkTitle.Text = "Testing unattended SSH..."
                $checkDetail.Text = "This is read-only and does not upload an image or change remote files."
                if ($TestMode -and -not $UseAsyncWorker) {
                    & $renderCheck (Get-CtrlCcvSshConnectionCheckResult)
                    return
                }
                $checkState.Operation = Start-CtrlCcvTraySshConnectionCheckProcess
                $checkState.StartedAt = Get-Date
                $checkTimer.Start()
            }
            catch {
                & $renderCheck (Get-CtrlCcvSshConnectionCheckPresentation -FailureKind "check-unavailable")
            }
        }.GetNewClosure()

        $test.Add_Click({ & $startCheck }.GetNewClosure())
        $settings.Add_Click({
            try {
                $settingsSaved = [bool](Show-CtrlCcvTraySettingsWindow)
                if ($settingsSaved) {
                    # A saved connection name, SSH folder, or related setting
                    # changes what a prior check proved. Require a new check
                    # before allowing an upload retry.
                    $form.Tag = $false
                    $checkTitle.Text = "Settings saved - test again"
                    $checkDetail.Text = "The SSH settings may have changed. Test unattended SSH again before retrying the clipboard upload."
                    & $setBusy $false
                }
                else {
                    $checkTitle.Text = "Settings closed - no changes saved"
                    $checkDetail.Text = "Your previous connection-check result is unchanged."
                }
            }
            catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
        }.GetNewClosure())
        $retry.Add_Click({
            try {
                Start-CtrlCcvTrayUpload
                $checkTitle.Text = "Clipboard upload requested"
                $checkDetail.Text = "ctrl-ccv will update the status after the current clipboard image is processed."
                $retry.Enabled = $false
            }
            catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
        }.GetNewClosure())
        $activity.Add_Click({ try { Show-CtrlCcvTrayRecentActivityWindow } catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) } }.GetNewClosure())
        $close.Add_Click({ $form.Close() }.GetNewClosure())
        $form.Add_FormClosing({
            if ($checkState -and $checkState.Operation) {
                Stop-CtrlCcvTraySshConnectionCheckProcess -Operation $checkState.Operation
                $checkState.Operation = $null
            }
        }.GetNewClosure())
        $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        [void]$form.ShowDialog()
    }
    finally {
        if ($checkTimer) { $checkTimer.Stop(); $checkTimer.Dispose() }
        if ($checkState -and $checkState.Operation) { Stop-CtrlCcvTraySshConnectionCheckProcess -Operation $checkState.Operation }
        if ($form) { $form.Dispose() }
    }
}

function Add-CtrlCcvTraySettingsField {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TableLayoutPanel]$Panel,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Inputs,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()]$Value
    )

    $row = $Panel.RowCount
    $Panel.RowCount = $row + 1
    [void]$Panel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::AutoSize)))

    $fieldLabel = New-Object System.Windows.Forms.Label
    $fieldLabel.Name = "ctrlCcvTraySettings$($Key)Label"
    $fieldLabel.Text = $Label
    $fieldLabel.AutoSize = $true
    $fieldLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $fieldLabel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 14, 8)
    $fieldLabel.ForeColor = Get-CtrlCcvTrayColor "#334155"
    $Panel.Controls.Add($fieldLabel, 0, $row)

    $input = New-Object System.Windows.Forms.TextBox
    $input.Name = "ctrlCcvTraySettings$($Key)Input"
    $input.Text = [string]$Value
    $input.Dock = [System.Windows.Forms.DockStyle]::Fill
    $input.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    $input.MaxLength = 1024
    $Panel.Controls.Add($input, 1, $row)
    $Inputs[$Key] = $input
}

function Show-CtrlCcvTraySettingsWindow {
    param([switch]$TestMode)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = $null
    try {
        $editable = Get-CtrlCcvEditableConfig
        $inputs = [ordered]@{}
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "ctrlCcvTraySettingsWindow"
        $form.Text = "ctrl-ccv settings"
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(800, 650)
        $form.MinimumSize = New-Object System.Drawing.Size(680, 560)
        $form.BackColor = Get-CtrlCcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.KeyPreview = $true
        $form.Tag = $false

        $title = New-Object System.Windows.Forms.Label
        $title.Name = "ctrlCcvTraySettingsTitle"
        $title.Text = "Settings"
        $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
        $title.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
        $title.Location = New-Object System.Drawing.Point(24, 18)
        $form.Controls.Add($title)

        $subtitle = New-Object System.Windows.Forms.Label
        $subtitle.Text = "Choose the SSH computer ctrl-ccv uses for automatic image uploads."
        $subtitle.AutoSize = $true
        $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $subtitle.ForeColor = Get-CtrlCcvTrayColor "#64748B"
        $subtitle.Location = New-Object System.Drawing.Point(26, 49)
        $form.Controls.Add($subtitle)

        $notice = New-Object System.Windows.Forms.Label
        $notice.Name = "ctrlCcvTraySettingsNotice"
        $notice.AutoSize = $false
        $notice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $notice.ForeColor = Get-CtrlCcvTrayColor "#334155"
        $notice.BackColor = Get-CtrlCcvTrayColor "#EEF2FF"
        $notice.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
        $notice.Location = New-Object System.Drawing.Point(24, 78)
        $notice.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $notice.Size = New-Object System.Drawing.Size(752, 48)
        if (-not [string]::IsNullOrWhiteSpace([string]$editable.LoadError)) {
            $notice.Text = "The existing configuration could not be read. Enter valid settings below to repair it."
            $notice.BackColor = Get-CtrlCcvTrayColor "#FEF2F2"
            $notice.ForeColor = Get-CtrlCcvTrayColor "#991B1B"
        }
        elseif ($editable.HasEnvironmentOverrides) {
            $fieldOverrides = @($editable.EnvironmentOverrides | Where-Object { $_ -ne "CTRL_CCV_CONFIG" })
            $pathNotice = if ($editable.ConfigPathIsEnvironmentOverride) {
                " Settings are saving to the configuration location selected by CTRL_CCV_CONFIG."
            }
            else { "" }
            if ($fieldOverrides.Count -gt 0) {
                $notice.Text = "Saved values are overridden for this session by: $($fieldOverrides -join ', '). Remove those environment variables for saved values to take effect.$pathNotice"
            }
            else {
                $notice.Text = "This session uses the configuration location selected by CTRL_CCV_CONFIG. Saved settings will take effect from that location."
            }
            $notice.BackColor = Get-CtrlCcvTrayColor "#FFFBEB"
            $notice.ForeColor = Get-CtrlCcvTrayColor "#92400E"
        }
        else {
            $notice.Text = "Saved changes take effect after ctrl-ccv restarts its owned local service."
        }
        $form.Controls.Add($notice)

        $tabs = New-Object System.Windows.Forms.TabControl
        $tabs.Name = "ctrlCcvTraySettingsTabs"
        $tabs.Location = New-Object System.Drawing.Point(24, 142)
        $tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $tabs.Size = New-Object System.Drawing.Size(752, 422)
        $form.Controls.Add($tabs)

        $connectionTab = New-Object System.Windows.Forms.TabPage
        $connectionTab.Name = "ctrlCcvTraySettingsConnectionTab"
        $connectionTab.Text = "Connection"
        $connectionTab.Padding = New-Object System.Windows.Forms.Padding(18, 16, 18, 16)
        $connectionTab.BackColor = [System.Drawing.Color]::White
        $tabs.TabPages.Add($connectionTab)

        $connectionLayout = New-Object System.Windows.Forms.TableLayoutPanel
        $connectionLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
        $connectionLayout.AutoScroll = $true
        $connectionLayout.ColumnCount = 2
        $connectionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 205))) | Out-Null
        $connectionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
        $connectionTab.Controls.Add($connectionLayout)
        Add-CtrlCcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "HostAlias" -Label "SSH computer or alias" -Value $editable.HostAlias
        Add-CtrlCcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "RemoteDir" -Label "Remote image folder" -Value $editable.RemoteDir
        Add-CtrlCcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "RemoteHome" -Label "Remote home (optional)" -Value $editable.RemoteHome
        Add-CtrlCcvTraySettingsField -Panel $connectionLayout -Inputs $inputs -Key "PollIntervalSeconds" -Label "Upload interval (seconds)" -Value $editable.PollIntervalSeconds

        $connectionTip = New-Object System.Windows.Forms.Label
        $connectionTip.Name = "ctrlCcvTraySettingsConnectionTip"
        $connectionTip.Text = "Use the same connection name that works with ssh <name>. Use an SSH config alias for custom ports, keys, or proxy rules."
        $connectionTip.AutoSize = $false
        $connectionTip.ForeColor = Get-CtrlCcvTrayColor "#64748B"
        $connectionTip.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $connectionTip.Dock = [System.Windows.Forms.DockStyle]::Top
        $connectionTip.Height = 46
        $connectionTip.Padding = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
        $connectionLayout.RowCount = $connectionLayout.RowCount + 1
        [void]$connectionLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::AutoSize)))
        $connectionLayout.Controls.Add($connectionTip, 0, $connectionLayout.RowCount - 1)
        $connectionLayout.SetColumnSpan($connectionTip, 2)

        $advancedTab = New-Object System.Windows.Forms.TabPage
        $advancedTab.Name = "ctrlCcvTraySettingsAdvancedTab"
        $advancedTab.Text = "Advanced"
        $advancedTab.Padding = New-Object System.Windows.Forms.Padding(18, 16, 18, 16)
        $advancedTab.BackColor = [System.Drawing.Color]::White
        $tabs.TabPages.Add($advancedTab)

        $advancedLayout = New-Object System.Windows.Forms.TableLayoutPanel
        $advancedLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
        $advancedLayout.AutoScroll = $true
        $advancedLayout.ColumnCount = 2
        $advancedLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 220))) | Out-Null
        $advancedLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
        $advancedTab.Controls.Add($advancedLayout)
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "DataRoot" -Label "Local data folder" -Value $editable.DataRoot
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "CommandTimeoutSeconds" -Label "Command timeout (seconds)" -Value $editable.CommandTimeoutSeconds
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxCommandOutputBytes" -Label "Max command output (bytes)" -Value $editable.MaxCommandOutputBytes
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "WatchdogCheckSeconds" -Label "Watchdog check (seconds)" -Value $editable.WatchdogCheckSeconds
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "WatchdogStaleSeconds" -Label "Watchdog stale after (seconds)" -Value $editable.WatchdogStaleSeconds
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxLogBytes" -Label "Max activity log (bytes)" -Value $editable.MaxLogBytes
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxCacheFiles" -Label "Max cached images" -Value $editable.MaxCacheFiles
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxCacheBytes" -Label "Max cache (bytes)" -Value $editable.MaxCacheBytes
        Add-CtrlCcvTraySettingsField -Panel $advancedLayout -Inputs $inputs -Key "MaxImageBytes" -Label "Max image (bytes)" -Value $editable.MaxImageBytes

        $feedback = New-Object System.Windows.Forms.Label
        $feedback.Name = "ctrlCcvTraySettingsFeedback"
        $feedback.AutoEllipsis = $true
        $feedback.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $feedback.ForeColor = Get-CtrlCcvTrayColor "#B91C1C"
        $feedback.Location = New-Object System.Drawing.Point(24, 576)
        $feedback.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $feedback.Size = New-Object System.Drawing.Size(500, 36)
        $form.Controls.Add($feedback)

        $save = New-Object System.Windows.Forms.Button
        $save.Name = "ctrlCcvTraySettingsSaveButton"
        $save.Text = "Save and restart"
        $save.Size = New-Object System.Drawing.Size(132, 34)
        $save.Location = New-Object System.Drawing.Point(532, 580)
        $save.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $save -Kind Primary
        $form.Controls.Add($save)

        $close = New-Object System.Windows.Forms.Button
        $close.Name = "ctrlCcvTraySettingsCloseButton"
        $close.Text = "Cancel"
        $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $close.Size = New-Object System.Drawing.Size(104, 34)
        $close.Location = New-Object System.Drawing.Point(672, 580)
        $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $close -Kind Quiet
        $form.Controls.Add($close)
        $form.CancelButton = $close

        $save.Add_Click({
            try {
                $draft = [ordered]@{}
                foreach ($key in @(
                    "HostAlias", "RemoteDir", "RemoteHome", "DataRoot",
                    "CommandTimeoutSeconds", "MaxCommandOutputBytes", "PollIntervalSeconds",
                    "WatchdogCheckSeconds", "WatchdogStaleSeconds", "MaxLogBytes",
                    "MaxCacheFiles", "MaxCacheBytes", "MaxImageBytes"
                )) {
                    $draft[$key] = $inputs[$key].Text.Trim()
                }
                [void](Save-CtrlCcvConfig -Config $draft)
                # A persisted connection change invalidates any earlier
                # connection test even if the service restart below fails.
                # Keep this result separate from restart success so callers
                # can refresh/invalidate safely after the dialog closes.
                $form.Tag = $true
                $close.Text = "Close"
                try {
                    Restart-CtrlCcvTrayService
                }
                catch {
                    $feedback.Text = "Settings were saved, but ctrl-ccv could not restart. Use the service controls after resolving the local error."
                    return
                }
                $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $form.Close()
            }
            catch {
                $feedback.Text = ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message -MaximumLength 440
            }
        }.GetNewClosure())
        $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        [void]$form.ShowDialog()
        return [bool]$form.Tag
    }
    finally {
        if ($form) { $form.Dispose() }
    }
}

function Get-CtrlCcvTrayTmuxStartupLine {
    # This is deliberately only shown and copied. The customer owns their
    # tmux startup file, and ctrl-ccv must not add or change a run-shell line.
    return "run-shell ~/.local/lib/ctrl-ccv/tmux/ctrl-ccv.tmux"
}

function Resolve-CtrlCcvTrayTmuxPathInsertionChoice {
    param(
        [Parameter(Mandatory)][ValidateSet("CrossPlatform", "Recommended", "Custom", "RawCtrlV")][string]$Mode,
        [AllowNull()][string]$CustomKey
    )

    switch ($Mode) {
        "CrossPlatform" {
            # This adds both root-table bindings to the same remote server;
            # tmux does not identify a client's OS. Windows users press Alt-V
            # (tmux M-v), while macOS users can press Ctrl-V (tmux C-v).
            return [pscustomobject]@{
                Table          = "root"
                Key            = "C-v"
                SecondaryTable = "root"
                SecondaryKey   = "M-v"
                Label          = "Windows Alt-V + macOS Ctrl-V"
            }
        }
        "Recommended" {
            return [pscustomobject]@{
                Table          = "prefix"
                Key            = "v"
                SecondaryTable = ""
                SecondaryKey   = ""
                Label          = "tmux prefix, then v"
            }
        }
        "Custom" {
            $key = if ($null -eq $CustomKey) { "" } else { $CustomKey.Trim() }
            if ($key -notmatch '^[a-z0-9]$') {
                throw "Choose one lowercase letter or number for the custom tmux prefix key."
            }
            return [pscustomobject]@{
                Table          = "prefix"
                Key            = $key
                SecondaryTable = ""
                SecondaryKey   = ""
                Label          = "tmux prefix, then $key"
            }
        }
        "RawCtrlV" {
            return [pscustomobject]@{
                Table          = "root"
                Key            = "C-v"
                SecondaryTable = ""
                SecondaryKey   = ""
                Label          = "raw Ctrl-V"
            }
        }
    }
}

function Get-CtrlCcvTrayTmuxStateValue {
    param(
        [AllowNull()][object]$State,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Fallback = ""
    )

    if ($null -eq $State) { return $Fallback }
    if ($State -is [System.Collections.IDictionary]) {
        if ($State.Contains($Name) -and $null -ne $State[$Name]) { return [string]$State[$Name] }
        return $Fallback
    }
    $property = $State.PSObject.Properties[$Name]
    if ($null -ne $property -and $null -ne $property.Value) { return [string]$property.Value }
    return $Fallback
}

function Format-CtrlCcvTrayTmuxState {
    param([AllowNull()][object]$State)

    if ($null -eq $State) { return "Remote setup has not been checked yet." }
    $connection = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Connection" -Fallback "Unavailable"
    $tmux = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Tmux" -Fallback "Unknown"
    $plugin = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Plugin" -Fallback "Unknown"
    $server = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Server" -Fallback "Unknown"
    $table = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Table" -Fallback "Unknown"
    $key = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Key" -Fallback "Unknown"
    $binding = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Binding" -Fallback "Unknown"
    $secondaryTable = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "SecondaryTable"
    $secondaryKey = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "SecondaryKey"
    $secondaryBinding = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "SecondaryBinding" -Fallback "NotSelected"
    $override = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Override" -Fallback "None"
    $detail = Get-CtrlCcvTrayTmuxStateValue -State $State -Name "Detail"
    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add("SSH: $connection    tmux: $tmux    plugin: $plugin")
    [void]$lines.Add("Default server: $server    primary binding ($table/$key): $binding")
    if ($secondaryTable -and $secondaryKey) {
        [void]$lines.Add("Paired Windows Alt-V binding ($secondaryTable/$secondaryKey): $secondaryBinding")
    }
    if ($override -and $override -ne "None") {
        [void]$lines.Add("A user-owned @ctrl-ccv-paste-* option is active and takes precedence over this screen.")
    }
    if ($detail) {
        [void]$lines.Add((ConvertTo-CtrlCcvTrayDisplayText -Text $detail -MaximumLength 480))
    }
    return ($lines -join [Environment]::NewLine)
}

function Start-CtrlCcvTrayTmuxRemoteJob {
    <#
    .SYNOPSIS
    Starts one remote tmux action outside the WinForms UI thread.

    .DESCRIPTION
    The remote helpers intentionally use bounded, synchronous SSH/SCP process
    calls. They are safe to run in a non-interactive PowerShell job, but must
    not run inside a button event handler: an Apply can require several
    bounded remote calls. The child process reloads only this checkout's
    ctrl-ccv-core and ctrl-ccv-remote helpers, so it shares the saved configuration
    but cannot touch the tray's local uploader state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Check", "Apply")][string]$Operation,
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()][string]$SecondaryTable,
        [AllowNull()][string]$SecondaryKey
    )

    $binding = Test-CtrlCcvRemoteTmuxBinding -Table $Table -Key $Key -SecondaryTable $SecondaryTable -SecondaryKey $SecondaryKey
    $root = [IO.Path]::GetFullPath($PSScriptRoot)
    return Start-Job -Name ("ctrl-ccv-tmux-{0}" -f $Operation.ToLowerInvariant()) -ScriptBlock {
        param(
            [Parameter(Mandatory)][string]$CtrlCcvRoot,
            [Parameter(Mandatory)][string]$CtrlCcvOperation,
            [Parameter(Mandatory)][string]$CtrlCcvTable,
            [Parameter(Mandatory)][string]$CtrlCcvKey,
            [AllowNull()][string]$CtrlCcvSecondaryTable,
            [AllowNull()][string]$CtrlCcvSecondaryKey
        )

        $ErrorActionPreference = "Stop"
        . (Join-Path $CtrlCcvRoot "ctrl-ccv-core.ps1")
        . (Join-Path $CtrlCcvRoot "ctrl-ccv-remote.ps1")
        if ($CtrlCcvOperation -eq "Check") {
            return Get-CtrlCcvRemoteTmuxState -Table $CtrlCcvTable -Key $CtrlCcvKey -SecondaryTable $CtrlCcvSecondaryTable -SecondaryKey $CtrlCcvSecondaryKey
        }
        return Apply-CtrlCcvRemoteTmuxBinding -Table $CtrlCcvTable -Key $CtrlCcvKey -SecondaryTable $CtrlCcvSecondaryTable -SecondaryKey $CtrlCcvSecondaryKey
    } -ArgumentList @($root, $Operation, $binding.Table, $binding.Key, $binding.SecondaryTable, $binding.SecondaryKey)
}

function Receive-CtrlCcvTrayTmuxRemoteJob {
    <#
    .SYNOPSIS
    Reads a completed remote tmux job without blocking the UI thread.

    .DESCRIPTION
    A non-completed job returns Completed = $false. Terminal jobs are removed
    as soon as their final state has been collected, so opening the tmux
    window repeatedly cannot accumulate background-job records.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.Job]$Job)

    if ($Job.State -notin @("Completed", "Failed", "Stopped", "Disconnected")) {
        return [pscustomobject]@{ Completed = $false; Ok = $false; Result = $null; Detail = "" }
    }

    $records = @()
    $errors = @()
    try {
        $records = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue -ErrorVariable +errors)
        $result = @($records | Where-Object {
            $null -ne $_ -and $null -ne $_.PSObject.Properties["Ok"]
        } | Select-Object -Last 1)[0]
        if ($null -ne $result) {
            return [pscustomobject]@{ Completed = $true; Ok = $true; Result = $result; Detail = "" }
        }

        $reason = ""
        if ($Job.ChildJobs.Count -gt 0 -and $null -ne $Job.ChildJobs[0].JobStateInfo.Reason) {
            $reason = [string]$Job.ChildJobs[0].JobStateInfo.Reason
        }
        if (-not [string]::IsNullOrWhiteSpace($reason)) {
            $detail = $reason
        }
        elseif ($errors.Count -gt 0) {
            $detail = [string]$errors[-1]
        }
        elseif ($Job.State -eq "Stopped") {
            $detail = "The remote tmux operation was cancelled."
        }
        else {
            $detail = "The remote tmux operation finished without a result."
        }
        return [pscustomobject]@{ Completed = $true; Ok = $false; Result = $null; Detail = $detail }
    }
    catch {
        return [pscustomobject]@{ Completed = $true; Ok = $false; Result = $null; Detail = $_.Exception.Message }
    }
    finally {
        try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Stop-CtrlCcvTrayTmuxRemoteJob {
    <#
    .SYNOPSIS
    Stops only the dedicated job created for the currently open tmux dialog.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Management.Automation.Job]$Job)

    if ($null -eq $Job) { return }
    try {
        if ($Job.State -notin @("Completed", "Failed", "Stopped", "Disconnected")) {
            Stop-Job -Job $Job -ErrorAction SilentlyContinue
        }
    }
    catch { }
    try { Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue } catch { }
}

function Show-CtrlCcvTrayTmuxSetupWindow {
    param(
        # TestMode keeps the usual synthetic WinForms probe hidden. Its direct
        # transport branch preserves the existing deterministic stub tests;
        # UseAsyncWorker opts a probe into the production job/timer path.
        [switch]$TestMode,
        [switch]$UseAsyncWorker
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = $null
    $operationTimer = $null
    $operationState = $null
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "ctrlCcvTrayTmuxSetupWindow"
        $form.Text = "ctrl-ccv tmux path insertion"
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(760, 700)
        $form.MinimumSize = New-Object System.Drawing.Size(780, 740)
        $form.BackColor = Get-CtrlCcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.KeyPreview = $true
        $form.Tag = $false

        $title = New-Object System.Windows.Forms.Label
        $title.Name = "ctrlCcvTrayTmuxTitle"
        $title.Text = "Tmux path insertion"
        $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 17)
        $title.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
        $title.Location = New-Object System.Drawing.Point(24, 18)
        $form.Controls.Add($title)

        $subtitle = New-Object System.Windows.Forms.Label
        $subtitle.Name = "ctrlCcvTrayTmuxSubtitle"
        $subtitle.Text = "Choose how the remote tmux server inserts ctrl-ccv's latest image path. This is separate from the local uploader settings."
        $subtitle.AutoSize = $false
        $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $subtitle.ForeColor = Get-CtrlCcvTrayColor "#64748B"
        $subtitle.Location = New-Object System.Drawing.Point(26, 50)
        $subtitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $subtitle.Size = New-Object System.Drawing.Size(708, 32)
        $form.Controls.Add($subtitle)

        $notice = New-Object System.Windows.Forms.Label
        $notice.Name = "ctrlCcvTrayTmuxNotice"
        $notice.Text = "Check is read-only. Apply installs or updates only ctrl-ccv-owned remote plugin and configuration files; it never edits ~/.tmux.conf or restarts your local uploader."
        $notice.AutoSize = $false
        $notice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $notice.ForeColor = Get-CtrlCcvTrayColor "#334155"
        $notice.BackColor = Get-CtrlCcvTrayColor "#EEF2FF"
        $notice.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
        $notice.Location = New-Object System.Drawing.Point(24, 92)
        $notice.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $notice.Size = New-Object System.Drawing.Size(712, 50)
        $form.Controls.Add($notice)

        $choiceLabel = New-Object System.Windows.Forms.Label
        $choiceLabel.Text = "Path-insertion shortcut on the remote tmux server"
        $choiceLabel.AutoSize = $true
        $choiceLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
        $choiceLabel.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
        $choiceLabel.Location = New-Object System.Drawing.Point(24, 158)
        $form.Controls.Add($choiceLabel)

        $crossPlatform = New-Object System.Windows.Forms.RadioButton
        $crossPlatform.Name = "ctrlCcvTrayTmuxCrossPlatformRadio"
        $crossPlatform.Text = "Recommended: Windows Alt-V + macOS Ctrl-V"
        $crossPlatform.AutoSize = $true
        $crossPlatform.Location = New-Object System.Drawing.Point(28, 187)
        $crossPlatform.Checked = $true
        $form.Controls.Add($crossPlatform)

        $crossPlatformHint = New-Object System.Windows.Forms.Label
        $crossPlatformHint.Name = "ctrlCcvTrayTmuxCrossPlatformHint"
        $crossPlatformHint.Text = "Both shortcuts are installed for every connected client; tmux does not detect OS. On Windows, use Alt-V."
        $crossPlatformHint.AutoSize = $false
        $crossPlatformHint.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $crossPlatformHint.ForeColor = Get-CtrlCcvTrayColor "#64748B"
        $crossPlatformHint.Location = New-Object System.Drawing.Point(50, 211)
        $crossPlatformHint.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $crossPlatformHint.Size = New-Object System.Drawing.Size(686, 19)
        $form.Controls.Add($crossPlatformHint)

        $recommended = New-Object System.Windows.Forms.RadioButton
        $recommended.Name = "ctrlCcvTrayTmuxRecommendedRadio"
        $recommended.Text = "Alternative: tmux prefix, then v"
        $recommended.AutoSize = $true
        $recommended.Location = New-Object System.Drawing.Point(28, 237)
        $form.Controls.Add($recommended)

        $custom = New-Object System.Windows.Forms.RadioButton
        $custom.Name = "ctrlCcvTrayTmuxCustomRadio"
        $custom.Text = "Custom: tmux prefix, then"
        $custom.AutoSize = $true
        $custom.Location = New-Object System.Drawing.Point(28, 266)
        $form.Controls.Add($custom)

        $customKey = New-Object System.Windows.Forms.TextBox
        $customKey.Name = "ctrlCcvTrayTmuxCustomKeyInput"
        $customKey.Text = "v"
        $customKey.CharacterCasing = [System.Windows.Forms.CharacterCasing]::Lower
        $customKey.MaxLength = 1
        $customKey.Enabled = $false
        $customKey.Size = New-Object System.Drawing.Size(42, 25)
        $customKey.Location = New-Object System.Drawing.Point(214, 262)
        $customKey.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        $form.Controls.Add($customKey)

        $customHint = New-Object System.Windows.Forms.Label
        $customHint.Text = "one lowercase letter or number"
        $customHint.AutoSize = $true
        $customHint.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $customHint.ForeColor = Get-CtrlCcvTrayColor "#64748B"
        $customHint.Location = New-Object System.Drawing.Point(266, 266)
        $form.Controls.Add($customHint)

        $raw = New-Object System.Windows.Forms.RadioButton
        $raw.Name = "ctrlCcvTrayTmuxRawRadio"
        $raw.Text = "Advanced: raw Ctrl-V"
        $raw.AutoSize = $true
        $raw.Location = New-Object System.Drawing.Point(28, 295)
        $form.Controls.Add($raw)

        $rawWarning = New-Object System.Windows.Forms.Label
        $rawWarning.Name = "ctrlCcvTrayTmuxRawWarning"
        $rawWarning.Text = "Warning: this replaces ordinary Ctrl-V in the remote tmux server for every connected client. Warp and other terminals can capture Ctrl-V locally before tmux sees it, so choose this only when you have configured your terminal to forward it."
        $rawWarning.AutoSize = $false
        $rawWarning.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $rawWarning.ForeColor = Get-CtrlCcvTrayColor "#92400E"
        $rawWarning.BackColor = Get-CtrlCcvTrayColor "#FFFBEB"
        $rawWarning.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
        $rawWarning.Location = New-Object System.Drawing.Point(50, 322)
        $rawWarning.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $rawWarning.Size = New-Object System.Drawing.Size(686, 46)
        $rawWarning.Visible = $false
        $form.Controls.Add($rawWarning)

        $selection = New-Object System.Windows.Forms.Label
        $selection.Name = "ctrlCcvTrayTmuxSelectionText"
        $selection.AutoSize = $false
        $selection.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8.5)
        $selection.ForeColor = Get-CtrlCcvTrayColor "#3730A3"
        $selection.Location = New-Object System.Drawing.Point(28, 377)
        $selection.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $selection.Size = New-Object System.Drawing.Size(708, 22)
        $form.Controls.Add($selection)

        $statusLabel = New-Object System.Windows.Forms.Label
        $statusLabel.Text = "Remote tmux status"
        $statusLabel.AutoSize = $true
        $statusLabel.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
        $statusLabel.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
        $statusLabel.Location = New-Object System.Drawing.Point(24, 407)
        $form.Controls.Add($statusLabel)

        $status = New-Object System.Windows.Forms.TextBox
        $status.Name = "ctrlCcvTrayTmuxStatusText"
        $status.ReadOnly = $true
        $status.Multiline = $true
        $status.WordWrap = $true
        $status.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $status.BackColor = [System.Drawing.Color]::White
        $status.ForeColor = Get-CtrlCcvTrayColor "#334155"
        $status.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $status.Location = New-Object System.Drawing.Point(24, 431)
        $status.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $status.Size = New-Object System.Drawing.Size(712, 88)
        $status.Text = "Remote setup has not been checked yet."
        $form.Controls.Add($status)

        $startupLabel = New-Object System.Windows.Forms.Label
        $startupLabel.Text = "To load ctrl-ccv automatically when tmux starts, add this one user-owned line to your remote tmux config:"
        $startupLabel.AutoSize = $false
        $startupLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $startupLabel.ForeColor = Get-CtrlCcvTrayColor "#475569"
        $startupLabel.Location = New-Object System.Drawing.Point(24, 530)
        $startupLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $startupLabel.Size = New-Object System.Drawing.Size(712, 20)
        $form.Controls.Add($startupLabel)

        $startupLine = New-Object System.Windows.Forms.TextBox
        $startupLine.Name = "ctrlCcvTrayTmuxStartupLine"
        $startupLine.ReadOnly = $true
        $startupLine.Text = Get-CtrlCcvTrayTmuxStartupLine
        $startupLine.Font = New-Object System.Drawing.Font("Consolas", 9)
        $startupLine.BackColor = [System.Drawing.Color]::White
        $startupLine.Location = New-Object System.Drawing.Point(24, 553)
        $startupLine.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $startupLine.Size = New-Object System.Drawing.Size(540, 26)
        $form.Controls.Add($startupLine)

        $copyStartup = New-Object System.Windows.Forms.Button
        $copyStartup.Name = "ctrlCcvTrayTmuxCopyStartupButton"
        $copyStartup.Text = "Copy line"
        $copyStartup.Size = New-Object System.Drawing.Size(102, 28)
        $copyStartup.Location = New-Object System.Drawing.Point(574, 551)
        $copyStartup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $copyStartup -Kind Quiet
        $form.Controls.Add($copyStartup)

        $feedback = New-Object System.Windows.Forms.Label
        $feedback.Name = "ctrlCcvTrayTmuxFeedback"
        $feedback.AutoSize = $false
        $feedback.AutoEllipsis = $true
        $feedback.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $feedback.ForeColor = Get-CtrlCcvTrayColor "#475569"
        $feedback.Location = New-Object System.Drawing.Point(24, 588)
        $feedback.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
        $feedback.Size = New-Object System.Drawing.Size(348, 48)
        $form.Controls.Add($feedback)

        $check = New-Object System.Windows.Forms.Button
        $check.Name = "ctrlCcvTrayTmuxCheckButton"
        $check.Text = "Check remote setup"
        $check.Size = New-Object System.Drawing.Size(142, 34)
        $check.Location = New-Object System.Drawing.Point(386, 650)
        $check.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $check -Kind Secondary
        $form.Controls.Add($check)

        $apply = New-Object System.Windows.Forms.Button
        $apply.Name = "ctrlCcvTrayTmuxApplyButton"
        $apply.Text = "Install / apply"
        $apply.Size = New-Object System.Drawing.Size(126, 34)
        $apply.Location = New-Object System.Drawing.Point(536, 650)
        $apply.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $apply -Kind Primary
        $form.Controls.Add($apply)

        $close = New-Object System.Windows.Forms.Button
        $close.Name = "ctrlCcvTrayTmuxCloseButton"
        $close.Text = "Close"
        # Keep Close active during a remote operation so the user can cancel
        # its dedicated background job and leave the dialog. It must not use a
        # DialogResult, which would close before that cleanup can run.
        $close.DialogResult = [System.Windows.Forms.DialogResult]::None
        $close.Size = New-Object System.Drawing.Size(82, 34)
        $close.Location = New-Object System.Drawing.Point(670, 650)
        $close.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        Set-CtrlCcvTrayButtonStyle -Button $close -Kind Quiet
        $form.Controls.Add($close)
        $form.CancelButton = $close

        $getChoice = {
            $mode = if ($crossPlatform.Checked) { "CrossPlatform" } elseif ($recommended.Checked) { "Recommended" } elseif ($custom.Checked) { "Custom" } else { "RawCtrlV" }
            return Resolve-CtrlCcvTrayTmuxPathInsertionChoice -Mode $mode -CustomKey $customKey.Text
        }.GetNewClosure()
        $syncChoice = {
            $customKey.Enabled = $custom.Checked
            $rawWarning.Visible = $raw.Checked
            $crossPlatformHint.Visible = $crossPlatform.Checked
            try {
                $choice = & $getChoice
                $selection.Text = "Selected: $($choice.Label)."
            }
            catch {
                $selection.Text = ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message -MaximumLength 240
            }
        }.GetNewClosure()
        $showState = {
            param([AllowNull()][object]$State)
            $status.Text = Format-CtrlCcvTrayTmuxState -State $State
            $status.SelectionStart = 0
            $status.ScrollToCaret()
        }.GetNewClosure()
        $setBusy = {
            param([bool]$Busy)
            $check.Enabled = -not $Busy
            $apply.Enabled = -not $Busy
            $recommended.Enabled = -not $Busy
            $crossPlatform.Enabled = -not $Busy
            $custom.Enabled = -not $Busy
            $raw.Enabled = -not $Busy
            $customKey.Enabled = (-not $Busy -and $custom.Checked)
            $close.Text = if ($Busy) { "Cancel and close" } else { "Close" }
        }.GetNewClosure()
        $showOperationFailure = {
            param(
                [Parameter(Mandatory)]$Choice,
                [Parameter(Mandatory)][string]$Operation,
                [AllowEmptyString()][string]$Detail
            )

            $safeDetail = ConvertTo-CtrlCcvTrayDisplayText -Text $Detail -MaximumLength 340
            $failureState = [pscustomobject]@{
                Ok = $false; Connection = "Unavailable"; Tmux = "Unknown"; Plugin = "Unknown"; Server = "Unknown"
                Table = $Choice.Table; Key = $Choice.Key; SecondaryTable = $Choice.SecondaryTable; SecondaryKey = $Choice.SecondaryKey
                Binding = "Unknown"; SecondaryBinding = if ($Choice.SecondaryTable) { "Unknown" } else { "NotSelected" }; Override = "Unknown"; Detail = $safeDetail
            }
            & $showState $failureState
            $feedback.ForeColor = Get-CtrlCcvTrayColor "#B91C1C"
            $verb = if ($Operation -eq "Check") { "check the remote setup" } else { "finish the remote tmux operation" }
            $feedback.Text = if ($safeDetail) { "ctrl-ccv could not $verb. $safeDetail" } else { "ctrl-ccv could not $verb." }
        }.GetNewClosure()
        $renderCheck = {
            param([Parameter(Mandatory)]$State)

            & $showState $State
            $feedback.ForeColor = if ($State.Ok) { Get-CtrlCcvTrayColor "#0F766E" } else { Get-CtrlCcvTrayColor "#B91C1C" }
            $feedback.Text = if ($State.Ok) { "Remote setup checked. Apply remains an explicit action." } else { "ctrl-ccv could not check the remote setup. Review the status above." }
        }.GetNewClosure()
        $renderApply = {
            param(
                [Parameter(Mandatory)]$Result,
                [Parameter(Mandatory)]$Choice
            )

            $resultState = $Result.PSObject.Properties["State"]
            if ($null -ne $resultState -and $null -ne $resultState.Value) {
                & $showState $resultState.Value
            }
            else {
                $status.Text = "Selected: $($Choice.Label).`r`n" + (ConvertTo-CtrlCcvTrayDisplayText -Text ([string]$Result.Detail) -MaximumLength 480)
            }
            if ($Result.Ok) {
                $form.Tag = $true
                $feedback.ForeColor = Get-CtrlCcvTrayColor "#0F766E"
                $feedback.Text = if ($Result.Applied) {
                    "Applied now to the default tmux server. Copy the startup line so a future tmux server loads ctrl-ccv too."
                }
                elseif ($Result.Reason -eq "tmux-missing") {
                    "Saved the ctrl-ccv setting, but tmux is not installed on the SSH computer yet. Copy the startup line for after tmux is installed."
                }
                else {
                    "Saved the ctrl-ccv setting. No default tmux server was running to reload; copy the startup line for future servers."
                }
            }
            else {
                $feedback.ForeColor = Get-CtrlCcvTrayColor "#B91C1C"
                $feedback.Text = ConvertTo-CtrlCcvTrayDisplayText -Text ([string]$Result.Detail) -MaximumLength 340
            }
        }.GetNewClosure()
        $operationState = [ordered]@{
            Job = $null
            Operation = ""
            Choice = $null
            StartedAt = $null
        }
        $operationTimer = New-Object System.Windows.Forms.Timer
        $operationTimer.Interval = 150
        $operationTimer.Add_Tick({
            $job = $operationState.Job
            if ($null -eq $job) {
                $operationTimer.Stop()
                return
            }

            $completion = Receive-CtrlCcvTrayTmuxRemoteJob -Job $job
            if (-not $completion.Completed) {
                if ($operationState.StartedAt -and ((Get-Date) - $operationState.StartedAt).TotalSeconds -ge 3) {
                    $verb = if ($operationState.Operation -eq "Check") { "Checking remote tmux setup" } else { "Installing and applying the remote tmux setting" }
                    $feedback.Text = "$verb... You can cancel and close this window while it is still working."
                }
                return
            }

            $operationTimer.Stop()
            $operation = [string]$operationState.Operation
            $choice = $operationState.Choice
            $operationState.Job = $null
            $operationState.Operation = ""
            $operationState.Choice = $null
            $operationState.StartedAt = $null
            & $setBusy $false
            if ($completion.Ok) {
                if ($operation -eq "Check") { & $renderCheck $completion.Result }
                else { & $renderApply $completion.Result $choice }
            }
            else {
                & $showOperationFailure $choice $operation $completion.Detail
            }
        }.GetNewClosure())
        $startAsyncOperation = {
            param([Parameter(Mandatory)][ValidateSet("Check", "Apply")][string]$Operation)

            try {
                $choice = & $getChoice
                & $setBusy $true
                $feedback.ForeColor = Get-CtrlCcvTrayColor "#3730A3"
                $feedback.Text = if ($Operation -eq "Check") {
                    "Checking remote tmux setup..."
                }
                else {
                    "Installing and applying the remote tmux setting. This can take a few minutes..."
                }
                $operationState.Job = Start-CtrlCcvTrayTmuxRemoteJob -Operation $Operation -Table $choice.Table -Key $choice.Key -SecondaryTable $choice.SecondaryTable -SecondaryKey $choice.SecondaryKey
                $operationState.Operation = $Operation
                $operationState.Choice = $choice
                $operationState.StartedAt = Get-Date
                $operationTimer.Start()
            }
            catch {
                $choiceForError = if ($null -ne $choice) { $choice } else { [pscustomobject]@{ Table = ""; Key = "" } }
                $operationState.Job = $null
                & $setBusy $false
                & $showOperationFailure $choiceForError $Operation $_.Exception.Message
            }
        }.GetNewClosure()

        $crossPlatform.Add_CheckedChanged({ if ($crossPlatform.Checked) { & $syncChoice } }.GetNewClosure())
        $recommended.Add_CheckedChanged({ if ($recommended.Checked) { & $syncChoice } }.GetNewClosure())
        $custom.Add_CheckedChanged({ if ($custom.Checked) { & $syncChoice } }.GetNewClosure())
        $raw.Add_CheckedChanged({ if ($raw.Checked) { & $syncChoice } }.GetNewClosure())
        $customKey.Add_TextChanged({ if ($custom.Checked) { & $syncChoice } }.GetNewClosure())
        $copyStartup.Add_Click({
            try {
                Set-Clipboard -Value $startupLine.Text
                $feedback.ForeColor = Get-CtrlCcvTrayColor "#0F766E"
                $feedback.Text = "The startup line was copied. Add it to your own remote tmux configuration when you are ready."
            }
            catch {
                $feedback.ForeColor = Get-CtrlCcvTrayColor "#B91C1C"
                $feedback.Text = ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message -MaximumLength 340
            }
        }.GetNewClosure())
        if ($TestMode -and -not $UseAsyncWorker) {
            # Keep synthetic UI probes deterministic and in-process. The real
            # dialog takes the asynchronous branch below.
            $check.Add_Click({
                try {
                    $choice = & $getChoice
                    & $setBusy $true
                    & $renderCheck (Get-CtrlCcvRemoteTmuxState -Table $choice.Table -Key $choice.Key -SecondaryTable $choice.SecondaryTable -SecondaryKey $choice.SecondaryKey)
                }
                catch {
                    $choiceForError = if ($null -ne $choice) { $choice } else { [pscustomobject]@{ Table = ""; Key = "" } }
                    & $showOperationFailure $choiceForError "Check" $_.Exception.Message
                }
                finally { & $setBusy $false }
            }.GetNewClosure())
            $apply.Add_Click({
                try {
                    $choice = & $getChoice
                    & $setBusy $true
                    & $renderApply (Apply-CtrlCcvRemoteTmuxBinding -Table $choice.Table -Key $choice.Key -SecondaryTable $choice.SecondaryTable -SecondaryKey $choice.SecondaryKey) $choice
                }
                catch {
                    $choiceForError = if ($null -ne $choice) { $choice } else { [pscustomobject]@{ Table = ""; Key = "" } }
                    & $showOperationFailure $choiceForError "Apply" $_.Exception.Message
                }
                finally { & $setBusy $false }
            }.GetNewClosure())
        }
        else {
            $check.Add_Click({ & $startAsyncOperation "Check" }.GetNewClosure())
            $apply.Add_Click({ & $startAsyncOperation "Apply" }.GetNewClosure())
        }
        $close.Add_Click({ $form.Close() }.GetNewClosure())
        $form.Add_FormClosing({
            if ($null -ne $operationState -and $null -ne $operationState.Job) {
                Stop-CtrlCcvTrayTmuxRemoteJob -Job $operationState.Job
                $operationState.Job = $null
            }
        }.GetNewClosure())
        $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        & $syncChoice
        [void]$form.ShowDialog()
        return [bool]$form.Tag
    }
    finally {
        if ($operationTimer) { $operationTimer.Stop(); $operationTimer.Dispose() }
        if ($operationState -and $operationState.Job) { Stop-CtrlCcvTrayTmuxRemoteJob -Job $operationState.Job }
        if ($form) { $form.Dispose() }
    }
}

function Open-CtrlCcvTrayDataFolder {
    $path = (Get-CtrlCcvConfig).DataRoot
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    Start-Process -FilePath "explorer.exe" -ArgumentList @(('"{0}"' -f $path)) | Out-Null
}

function Get-CtrlCcvTrayInstalledVersion {
    param(
        [string]$VersionFile = (Join-Path $PSScriptRoot "VERSION")
    )

    # VERSION is bundled with each installer and portable release.  Treat it
    # only as a short display value: a missing, linked, oversized, or malformed
    # file must not put arbitrary content into the customer-facing UI.
    try {
        $item = Get-Item -LiteralPath $VersionFile -Force -ErrorAction Stop
        if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or $item.Length -gt 128) {
            return "unknown"
        }
        $version = (Get-Content -LiteralPath $VersionFile -Raw -ErrorAction Stop).Trim()
        if ($version -match '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?(?:\+[0-9A-Za-z][0-9A-Za-z.-]*)?$') {
            return $version
        }
    }
    catch { }
    return "unknown"
}

function Get-CtrlCcvTrayUpdateMenuText {
    param(
        [AllowNull()][string]$InstalledVersion = (Get-CtrlCcvTrayInstalledVersion)
    )

    # Keep this separate from the version reader so a future caller cannot
    # accidentally render an unvalidated value in the native context menu.
    if ($InstalledVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?(?:\+[0-9A-Za-z][0-9A-Za-z.-]*)?$') {
        return "Get latest version... (version unavailable)"
    }
    return "Get latest version... (v$InstalledVersion)"
}

function Open-CtrlCcvTrayReleasePage {
    # Do not accept a URL argument here.  This is an explicit, visible browser
    # handoff to the official release page, not an in-app updater.
    Start-Process -FilePath $script:CtrlCcvTrayReleaseUrl -ErrorAction Stop | Out-Null
}

function Show-CtrlCcvTrayError {
    param([Parameter(Mandatory)][string]$Message)
    [void][System.Windows.Forms.MessageBox]::Show($Message, "ctrl-ccv", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
}

function Show-CtrlCcvTrayStatusWindow {
    param(
        [Parameter(Mandatory)]$State,
        # TestMode exists solely for the local synthetic STA smoke test. It
        # preserves the real dialog/message-loop path without flashing a
        # status window onto the user's desktop during routine validation.
        [switch]$TestMode
    )

    # The normal tray startup path has already loaded these assemblies, but
    # this public helper is also useful from a direct STA PowerShell command.
    # Load them here so opening status does not depend on hidden caller state.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $windowIcon = Get-CtrlCcvTrayIcon
    $logoImage = Get-CtrlCcvTrayLogo
    $installedVersion = Get-CtrlCcvTrayInstalledVersion
    $versionDetail = if ($installedVersion -eq "unknown") { "Version unavailable" } else { "Installed v$installedVersion" }
    $form = $null
    $tooltip = $null
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Name = "ctrlCcvTrayStatusDashboard"
        $form.Text = "ctrl-ccv status"
        $form.Icon = $windowIcon.Icon
        $form.StartPosition = if ($TestMode) { [System.Windows.Forms.FormStartPosition]::Manual } else { [System.Windows.Forms.FormStartPosition]::CenterScreen }
        if ($TestMode) {
            $form.Opacity = 0
            $form.ShowInTaskbar = $false
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
        }
        $form.ClientSize = New-Object System.Drawing.Size(840, 575)
        $form.MinimumSize = New-Object System.Drawing.Size(760, 545)
        $form.BackColor = Get-CtrlCcvTrayColor "#F6F8FC"
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
        $form.KeyPreview = $true
        $form.MinimizeBox = $false
        $form.MaximizeBox = $false
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = [System.Windows.Forms.DockStyle]::Fill
    $layout.BackColor = $form.BackColor
    $layout.Padding = New-Object System.Windows.Forms.Padding(24, 22, 24, 20)
    $layout.ColumnCount = 1
    $layout.RowCount = 5
    # The header includes a 20pt title plus a supporting line. Its bottom
    # margin needs real breathing room at 100% and high-DPI scale factors.
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 68)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 116)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 104)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList @([System.Windows.Forms.SizeType]::Absolute, 28)))
    $form.Controls.Add($layout)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Fill
    $header.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $layout.Controls.Add($header, 0, 0)

    if ($logoImage) {
        $logo = New-Object System.Windows.Forms.PictureBox
        $logo.Name = "ctrlCcvTrayBrandLogo"
        $logo.Image = $logoImage
        $logo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $logo.Size = New-Object System.Drawing.Size(48, 48)
        $logo.Location = New-Object System.Drawing.Point(0, 1)
        $header.Controls.Add($logo)
    }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = "ctrl-ccv"
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 20)
    $title.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
    $title.Location = New-Object System.Drawing.Point($(if ($logoImage) { 58 } else { 0 }), 0)
    $header.Controls.Add($title)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Name = "ctrlCcvTraySubtitle"
    $subtitle.Text = "Clipboard image uploader  ·  $versionDetail"
    $subtitle.AutoSize = $true
    $subtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $subtitle.ForeColor = Get-CtrlCcvTrayColor "#64748B"
    $subtitle.Location = New-Object System.Drawing.Point($(if ($logoImage) { 60 } else { 2 }), 34)
    $header.Controls.Add($subtitle)

    $updateButton = New-Object System.Windows.Forms.Button
    $updateButton.Name = "ctrlCcvTrayUpdateButton"
    $updateButton.Text = "Get latest version..."
    $updateButton.Size = New-Object System.Drawing.Size(145, 34)
    $updateButton.Location = New-Object System.Drawing.Point(516, 8)
    $updateButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Set-CtrlCcvTrayButtonStyle -Button $updateButton -Kind Quiet
    $header.Controls.Add($updateButton)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Name = "ctrlCcvTrayRefreshButton"
    $refreshButton.Text = "Refresh status"
    $refreshButton.Size = New-Object System.Drawing.Size(120, 34)
    $refreshButton.Location = New-Object System.Drawing.Point(672, 8)
    $refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    Set-CtrlCcvTrayButtonStyle -Button $refreshButton -Kind Quiet
    $header.Controls.Add($refreshButton)

    $statusBanner = New-Object System.Windows.Forms.Panel
    $statusBanner.Name = "ctrlCcvTrayStatusBanner"
    $statusBanner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $statusBanner.Padding = New-Object System.Windows.Forms.Padding(20, 17, 20, 14)
    $statusBanner.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $layout.Controls.Add($statusBanner, 0, 1)

    $statusDot = New-Object System.Windows.Forms.Label
    $statusDot.Text = [char]0x25CF
    $statusDot.AutoSize = $true
    $statusDot.Font = New-Object System.Drawing.Font("Segoe UI", 24)
    $statusDot.Location = New-Object System.Drawing.Point(20, 37)
    $statusBanner.Controls.Add($statusDot)

    $statusBadge = New-Object System.Windows.Forms.Label
    $statusBadge.AutoSize = $true
    $statusBadge.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 8)
    $statusBadge.Padding = New-Object System.Windows.Forms.Padding(7, 4, 7, 4)
    $statusBadge.Location = New-Object System.Drawing.Point(62, 17)
    $statusBanner.Controls.Add($statusBadge)

    $statusSummary = New-Object System.Windows.Forms.Label
    $statusSummary.AutoEllipsis = $true
    $statusSummary.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 15)
    $statusSummary.Location = New-Object System.Drawing.Point(62, 43)
    $statusSummary.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $statusSummary.Size = New-Object System.Drawing.Size(710, 28)
    $statusBanner.Controls.Add($statusSummary)

    $statusDetail = New-Object System.Windows.Forms.Label
    $statusDetail.AutoEllipsis = $true
    $statusDetail.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $statusDetail.Location = New-Object System.Drawing.Point(63, 75)
    $statusDetail.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $statusDetail.Size = New-Object System.Drawing.Size(708, 22)
    $statusBanner.Controls.Add($statusDetail)

    $metrics = New-Object System.Windows.Forms.TableLayoutPanel
    $metrics.Dock = [System.Windows.Forms.DockStyle]::Fill
    $metrics.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $metrics.ColumnCount = 3
    $metrics.RowCount = 1
    [void]$metrics.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$metrics.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 33.333)))
    [void]$metrics.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle -ArgumentList @([System.Windows.Forms.SizeType]::Percent, 33.334)))
    $layout.Controls.Add($metrics, 0, 2)

    $serviceCard = New-CtrlCcvTrayMetricCard -Title "Automatic uploads"
    $heartbeatCard = New-CtrlCcvTrayMetricCard -Title "Last heartbeat"
    $latestCard = New-CtrlCcvTrayMetricCard -Title "Latest image"
    $serviceCard.Container.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $heartbeatCard.Container.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    $latestCard.Container.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $metrics.Controls.Add($serviceCard.Container, 0, 0)
    $metrics.Controls.Add($heartbeatCard.Container, 1, 0)
    $metrics.Controls.Add($latestCard.Container, 2, 0)

    $actionsBorder = New-Object System.Windows.Forms.Panel
    $actionsBorder.BackColor = Get-CtrlCcvTrayColor "#D9E2F0"
    $actionsBorder.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actionsBorder.Padding = New-Object System.Windows.Forms.Padding(1)
    $actionsBorder.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
    $layout.Controls.Add($actionsBorder, 0, 3)

    $actions = New-Object System.Windows.Forms.Panel
    $actions.BackColor = [System.Drawing.Color]::White
    $actions.Dock = [System.Windows.Forms.DockStyle]::Fill
    $actions.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 15)
    $actionsBorder.Controls.Add($actions)

    $actionsTitle = New-Object System.Windows.Forms.Label
    $actionsTitle.Text = "Quick actions"
    $actionsTitle.AutoSize = $true
    $actionsTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
    $actionsTitle.ForeColor = Get-CtrlCcvTrayColor "#0F172A"
    $actionsTitle.Location = New-Object System.Drawing.Point(20, 16)
    $actions.Controls.Add($actionsTitle)

    $actionsCaption = New-Object System.Windows.Forms.Label
    $actionsCaption.Text = "Manage this checkout only. The tray never starts a second uploader."
    $actionsCaption.AutoSize = $true
    $actionsCaption.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $actionsCaption.ForeColor = Get-CtrlCcvTrayColor "#64748B"
    $actionsCaption.Location = New-Object System.Drawing.Point(20, 40)
    $actions.Controls.Add($actionsCaption)

    $uploadButton = New-Object System.Windows.Forms.Button
    $uploadButton.Name = "ctrlCcvTrayUploadButton"
    $uploadButton.Text = "Upload clipboard image"
    $uploadButton.Size = New-Object System.Drawing.Size(206, 38)
    $uploadButton.Location = New-Object System.Drawing.Point(20, 69)
    Set-CtrlCcvTrayButtonStyle -Button $uploadButton -Kind Primary
    $actions.Controls.Add($uploadButton)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Name = "ctrlCcvTrayCopyButton"
    $copyButton.Size = New-Object System.Drawing.Size(178, 38)
    $copyButton.Location = New-Object System.Drawing.Point(236, 69)
    Set-CtrlCcvTrayButtonStyle -Button $copyButton -Kind Secondary
    $actions.Controls.Add($copyButton)

    $serviceButton = New-Object System.Windows.Forms.Button
    $serviceButton.Name = "ctrlCcvTrayServiceButton"
    $serviceButton.Size = New-Object System.Drawing.Size(184, 38)
    $serviceButton.Location = New-Object System.Drawing.Point(424, 69)
    Set-CtrlCcvTrayButtonStyle -Button $serviceButton -Kind Secondary
    $actions.Controls.Add($serviceButton)

    $settingsButton = New-Object System.Windows.Forms.Button
    $settingsButton.Name = "ctrlCcvTraySettingsButton"
    $settingsButton.Text = "Settings..."
    $settingsButton.Size = New-Object System.Drawing.Size(112, 30)
    $settingsButton.Location = New-Object System.Drawing.Point(20, 119)
    Set-CtrlCcvTrayButtonStyle -Button $settingsButton -Kind Quiet
    $actions.Controls.Add($settingsButton)

    $logButton = New-Object System.Windows.Forms.Button
    $logButton.Name = "ctrlCcvTrayLogButton"
    $logButton.Text = "View activity..."
    $logButton.Size = New-Object System.Drawing.Size(120, 30)
    $logButton.Location = New-Object System.Drawing.Point(142, 119)
    Set-CtrlCcvTrayButtonStyle -Button $logButton -Kind Quiet
    $actions.Controls.Add($logButton)

    $dataButton = New-Object System.Windows.Forms.Button
    $dataButton.Name = "ctrlCcvTrayDataButton"
    $dataButton.Text = "Open data folder"
    $dataButton.Size = New-Object System.Drawing.Size(128, 30)
    $dataButton.Location = New-Object System.Drawing.Point(272, 119)
    Set-CtrlCcvTrayButtonStyle -Button $dataButton -Kind Quiet
    $actions.Controls.Add($dataButton)

    $tmuxButton = New-Object System.Windows.Forms.Button
    $tmuxButton.Name = "ctrlCcvTrayTmuxButton"
    $tmuxButton.Text = "Tmux path insertion..."
    $tmuxButton.Size = New-Object System.Drawing.Size(182, 30)
    $tmuxButton.Location = New-Object System.Drawing.Point(410, 119)
    Set-CtrlCcvTrayButtonStyle -Button $tmuxButton -Kind Quiet
    $actions.Controls.Add($tmuxButton)

    $connectionButton = New-Object System.Windows.Forms.Button
    $connectionButton.Name = "ctrlCcvTrayConnectionHelpButton"
    $connectionButton.Text = "Connection help..."
    $connectionButton.Size = New-Object System.Drawing.Size(160, 30)
    # The connection action appears only for an SSH-stage upload issue.  It
    # shares the guidance row rather than being squeezed into the five-button
    # row, so it remains reachable at the dashboard's minimum width.
    $connectionButton.Location = New-Object System.Drawing.Point(20, 158)
    Set-CtrlCcvTrayButtonStyle -Button $connectionButton -Kind Quiet
    $actions.Controls.Add($connectionButton)

    $actionFeedback = New-Object System.Windows.Forms.Label
    $actionFeedback.Name = "ctrlCcvTrayActionFeedback"
    $actionFeedback.AutoEllipsis = $true
    $actionFeedback.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $actionFeedback.ForeColor = Get-CtrlCcvTrayColor "#475569"
    $actionFeedback.Location = New-Object System.Drawing.Point(20, 158)
    $actionFeedback.Size = New-Object System.Drawing.Size(750, 20)
    $actions.Controls.Add($actionFeedback)

    # Keep status guidance visible beside the issue-specific action.  The
    # calculation is repeated on resize because the dashboard is resizable.
    $layoutActionFeedback = {
        $left = if ($connectionButton.Visible) { 190 } else { 20 }
        $width = [Math]::Max(0, $actions.ClientSize.Width - $left - 20)
        $actionFeedback.Location = New-Object System.Drawing.Point($left, 158)
        $actionFeedback.Size = New-Object System.Drawing.Size($width, 20)
    }.GetNewClosure()
    $actions.Add_Resize({ & $layoutActionFeedback })

    $footer = New-Object System.Windows.Forms.Label
    $footer.Text = "Tip: take a screenshot as usual; ctrl-ccv reacts only to image clipboard entries."
    $footer.AutoEllipsis = $true
    $footer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $footer.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $footer.ForeColor = Get-CtrlCcvTrayColor "#64748B"
    $footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($footer, 0, 4)

    $tooltip = New-Object System.Windows.Forms.ToolTip
    $tooltip.AutoPopDelay = 10000
    $tooltip.SetToolTip($uploadButton, "Run one safe, asynchronous upload of the current clipboard image.")
    $tooltip.SetToolTip($serviceButton, "Only processes started from this checkout can be changed.")
    $tooltip.SetToolTip($copyButton, "Copy the most recent validated remote path without displaying it here.")
    $tooltip.SetToolTip($tmuxButton, "Configure the optional ctrl-ccv path-insertion binding on the remote tmux server.")
    $tooltip.SetToolTip($connectionButton, "Explain and safely test a new unattended SSH process. This never uploads an image during the test.")
    $tooltip.SetToolTip($updateButton, "Open the official ctrl-ccv Releases page. You choose and verify any installer there.")

    $refreshDashboard = {
        param([Parameter(Mandatory)]$CurrentState)

        $style = Get-CtrlCcvTrayStatusStyle -Level $CurrentState.Level
        $statusBanner.BackColor = Get-CtrlCcvTrayColor $style.Surface
        $statusDot.ForeColor = Get-CtrlCcvTrayColor $style.Accent
        $statusBadge.Text = $style.Badge.ToUpperInvariant()
        $statusBadge.BackColor = Get-CtrlCcvTrayColor $style.Accent
        $statusBadge.ForeColor = [System.Drawing.Color]::White
        $statusSummary.Text = ConvertTo-CtrlCcvTrayDisplayText -Text $CurrentState.Summary -MaximumLength 200
        $statusSummary.ForeColor = Get-CtrlCcvTrayColor $style.Foreground
        $statusDetail.Text = ConvertTo-CtrlCcvTrayDisplayText -Text $CurrentState.Detail -MaximumLength 260
        if ([string]::IsNullOrWhiteSpace($statusDetail.Text)) { $statusDetail.Text = Get-CtrlCcvTrayGuidance -State $CurrentState }
        $statusDetail.ForeColor = Get-CtrlCcvTrayColor $style.Foreground

        $guardianCount = (@($CurrentState.Guardians)).Count
        $watcherCount = (@($CurrentState.Watchers)).Count
        $serviceRunning = ($guardianCount -gt 0 -or $watcherCount -gt 0)
        $hasUploadIssue = Test-CtrlCcvTrayUploadIssue -State $CurrentState
        $hasSshConnectionIssue = Test-CtrlCcvTraySshConnectionIssue -State $CurrentState
        $serviceCard.Value.Text = if ($CurrentState.Level -eq "Healthy" -or ($hasUploadIssue -and $serviceRunning)) {
            "Running"
        }
        elseif ($guardianCount -gt 0 -and $watcherCount -eq 0) {
            "Recovering"
        }
        elseif ($serviceRunning) {
            "Needs attention"
        }
        else {
            "Stopped"
        }
        $serviceCard.Value.ForeColor = if ($hasUploadIssue -and $serviceRunning) { Get-CtrlCcvTrayColor "#0F766E" } else { Get-CtrlCcvTrayColor $style.Foreground }
        $serviceCard.Detail.Text = if ($hasUploadIssue -and $serviceRunning) { "$guardianCount guardian; $watcherCount watcher · local service is running" } else { "$guardianCount guardian; $watcherCount watcher" }
        $heartbeatCard.Value.Text = Get-CtrlCcvTrayRelativeTimeText -AgeSeconds $CurrentState.HeartbeatAgeSeconds
        $heartbeatCard.Detail.Text = Get-CtrlCcvTrayHeartbeatText -Heartbeat $CurrentState.Heartbeat
        $hasLatestPath = (-not [string]::IsNullOrWhiteSpace($CurrentState.LatestPath) -and (Test-CtrlCcvRemotePath $CurrentState.LatestPath))
        $latestCard.Value.Text = Get-CtrlCcvTrayLatestUploadText -State $CurrentState
        $latestCard.Detail.Text = if ($hasLatestPath) { "Latest path is available locally" } else { "Upload an image to create one" }

        $uploadButton.Enabled = $CurrentState.Level -ne "Error"
        $uploadButton.Text = if ($hasUploadIssue) { "Retry clipboard upload" } else { "Upload clipboard image" }
        $copyButton.Enabled = $hasLatestPath
        $copyButton.Text = if ($hasLatestPath) { "Copy latest path" } else { "No upload path yet" }
        $serviceButton.Text = if (-not $serviceRunning) {
            "Start automatic uploads"
        }
        elseif ($hasUploadIssue) {
            "Service is running"
        }
        elseif ($CurrentState.Level -in @("Warning", "Unknown")) {
            "Repair service"
        }
        else {
            "Restart service"
        }
        $serviceButton.Enabled = ($CurrentState.Level -ne "Error" -and -not $hasUploadIssue -and $CurrentState.GuardianProbeAvailable -and ((-not $serviceRunning) -or $CurrentState.WatcherProbeAvailable))
        $connectionButton.Visible = $hasSshConnectionIssue
        $connectionButton.Enabled = $hasSshConnectionIssue
        $actionFeedback.Text = Get-CtrlCcvTrayGuidance -State $CurrentState
        & $layoutActionFeedback
        $form.Text = "ctrl-ccv status - $($style.Badge)"
    }.GetNewClosure()

    $refreshButton.Add_Click({
        try {
            $freshState = Get-CtrlCcvTrayState
            & $refreshDashboard $freshState
        }
        catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $uploadButton.Add_Click({
        try {
            Start-CtrlCcvTrayUpload
            $actionFeedback.Text = "Upload requested. Refresh status after the clipboard image is processed."
        }
        catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $copyButton.Add_Click({
        try {
            $currentState = Get-CtrlCcvTrayState
            Copy-CtrlCcvTrayLatestPath -State $currentState
            $actionFeedback.Text = "Latest upload path copied to the clipboard."
        }
        catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $serviceButton.Add_Click({
        try {
            $currentState = Get-CtrlCcvTrayState
            $currentlyRunning = ((@($currentState.Guardians)).Count -gt 0 -or (@($currentState.Watchers)).Count -gt 0)
            if ($currentlyRunning) { Restart-CtrlCcvTrayService } else { [void](Start-CtrlCcvTrayGuardian) }
            Start-Sleep -Milliseconds 350
            & $refreshDashboard (Get-CtrlCcvTrayState)
        }
        catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $settingsButton.Add_Click({
        try {
            if (Show-CtrlCcvTraySettingsWindow) { & $refreshDashboard (Get-CtrlCcvTrayState) }
        }
        catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $updateButton.Add_Click({
        try {
            Open-CtrlCcvTrayReleasePage
            $actionFeedback.Text = "Opened the official ctrl-ccv Releases page. Verify the SHA-256 before running a Setup EXE."
        }
        catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $tmuxButton.Add_Click({ try { Show-CtrlCcvTrayTmuxSetupWindow } catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) } })
    $connectionButton.Add_Click({
        try {
            $currentState = Get-CtrlCcvTrayState
            Show-CtrlCcvTrayConnectionHelpWindow -State $currentState
            & $refreshDashboard (Get-CtrlCcvTrayState)
        }
        catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) }
    })
    $logButton.Add_Click({ try { Show-CtrlCcvTrayRecentActivityWindow } catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) } })
    $dataButton.Add_Click({ try { Open-CtrlCcvTrayDataFolder } catch { Show-CtrlCcvTrayError (ConvertTo-CtrlCcvTrayDisplayText -Text $_.Exception.Message) } })

    $close = New-Object System.Windows.Forms.Button
    $close.Name = "ctrlCcvTrayCloseButton"
    $close.Text = "Close"
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $close.Size = New-Object System.Drawing.Size(92, 30)
    $close.Visible = $false
    $form.Controls.Add($close)
    $form.CancelButton = $close
    $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

        & $refreshDashboard $State
        [void]$form.ShowDialog()
    }
    finally {
        if ($tooltip) { $tooltip.Dispose() }
        if ($form) { $form.Dispose() }
        if ($logoImage) { $logoImage.Dispose() }
        if ($windowIcon -and $windowIcon.OwnsIcon -and $windowIcon.Icon) { $windowIcon.Icon.Dispose() }
    }
}

function Start-CtrlCcvTrayApplication {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
        throw "ctrl-ccv-tray.ps1 must be run with powershell.exe -STA. Use install-tray.ps1 to add a safe Startup shortcut."
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $mutex = New-Object System.Threading.Mutex($false, (Get-CtrlCcvMutexName -Purpose "Tray"))
    if (-not $mutex.WaitOne(0, $false)) { return }
    $notify = $null
    $timer = $null
    $trayIconSelection = $null
    $trayStatusIcons = @{}
    try {
        $script:CtrlCcvTrayState = Get-CtrlCcvTrayState
        $script:CtrlCcvTrayLastLevel = ""
        $script:CtrlCcvTrayLastIconLevel = "Healthy"
        $installedVersion = Get-CtrlCcvTrayInstalledVersion
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $statusItem = $menu.Items.Add("Loading status...")
        $statusItem.Enabled = $false
        $showStatusItem = $menu.Items.Add("View status...")
        [void]$menu.Items.Add("-")
        $uploadItem = $menu.Items.Add("Upload current clipboard image")
        $copyItem = $menu.Items.Add("Copy latest upload path")
        [void]$menu.Items.Add("-")
        $startItem = $menu.Items.Add("Start service")
        $stopItem = $menu.Items.Add("Stop service")
        $restartItem = $menu.Items.Add("Restart service")
        [void]$menu.Items.Add("-")
        $logItem = $menu.Items.Add("View recent activity...")
        $configItem = $menu.Items.Add("Settings...")
        $connectionHelpItem = $menu.Items.Add("Connection help...")
        $tmuxItem = $menu.Items.Add("Configure tmux path insertion...")
        $dataItem = $menu.Items.Add("Open data folder")
        $updateItem = $menu.Items.Add((Get-CtrlCcvTrayUpdateMenuText -InstalledVersion $installedVersion))
        [void]$menu.Items.Add("-")
        $exitItem = $menu.Items.Add("Exit tray (service stays running)")

        $notify = New-Object System.Windows.Forms.NotifyIcon
        $trayIconSelection = Get-CtrlCcvTrayIcon
        $notify.Icon = $trayIconSelection.Icon
        if ($trayIconSelection.IsFallback) {
            Write-CtrlCcvLog "tray icon asset was unavailable or invalid; using the Windows application icon"
        }
        $notify.ContextMenuStrip = $menu
        $notify.Visible = $true
        $context = New-Object System.Windows.Forms.ApplicationContext

        $refreshUi = {
            $script:CtrlCcvTrayState = Get-CtrlCcvTrayState
            $state = $script:CtrlCcvTrayState
            $latestUpload = Get-CtrlCcvTrayLatestUploadText -State $state
            $statusItem.Text = if (Test-CtrlCcvTraySshConnectionIssue -State $state) {
                "Status: Service running - SSH needs attention"
            }
            elseif ($state.Level -eq "Healthy" -and $latestUpload -match '^Uploaded ') {
                "Status: Healthy - $latestUpload"
            }
            else {
                "Status: $($state.Level) - $($state.Summary)"
            }
            if ($script:CtrlCcvTrayLastIconLevel -ne $state.Level) {
                $notify.Icon = Get-CtrlCcvTrayStatusIcon -BaseIcon $trayIconSelection.Icon -Level $state.Level -Cache $trayStatusIcons
                $script:CtrlCcvTrayLastIconLevel = $state.Level
            }
            $notify.Text = Get-CtrlCcvTrayTooltip -State $state
            $isRunning = ((@($state.Guardians)).Count -gt 0 -or (@($state.Watchers)).Count -gt 0)
            $hasUploadIssue = Test-CtrlCcvTrayUploadIssue -State $state
            $startItem.Enabled = ($state.Level -ne "Error" -and $state.GuardianProbeAvailable -and -not $isRunning)
            $stopItem.Enabled = ($state.GuardianProbeAvailable -and $state.WatcherProbeAvailable -and $isRunning)
            $restartItem.Enabled = ($state.Level -ne "Error" -and -not $hasUploadIssue -and $state.GuardianProbeAvailable -and $state.WatcherProbeAvailable)
            $connectionHelpItem.Visible = Test-CtrlCcvTraySshConnectionIssue -State $state
            $connectionHelpItem.Enabled = $connectionHelpItem.Visible
            $copyItem.Enabled = (-not [string]::IsNullOrWhiteSpace($state.LatestPath) -and (Test-CtrlCcvRemotePath $state.LatestPath))
            if ($script:CtrlCcvTrayLastLevel -and $script:CtrlCcvTrayLastLevel -ne $state.Level) {
                if ($state.Level -in @("Warning", "Error")) {
                    $notify.BalloonTipTitle = "ctrl-ccv: $($state.Level)"
                    $notify.BalloonTipText = $state.Summary
                    $notify.ShowBalloonTip(3000)
                }
                elseif ($state.Level -eq "Healthy" -and $script:CtrlCcvTrayLastLevel -in @("Warning", "Error")) {
                    $notify.BalloonTipTitle = "ctrl-ccv: Healthy"
                    $notify.BalloonTipText = "Uploads are working again."
                    $notify.ShowBalloonTip(2000)
                }
            }
            $script:CtrlCcvTrayLastLevel = $state.Level
        }

        $showStatusItem.Add_Click({ & $refreshUi; Show-CtrlCcvTrayStatusWindow -State $script:CtrlCcvTrayState })
        $uploadItem.Add_Click({ try { Start-CtrlCcvTrayUpload; $notify.ShowBalloonTip(2000, "ctrl-ccv", "One-shot upload requested.", [System.Windows.Forms.ToolTipIcon]::Info) } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $copyItem.Add_Click({ try { Copy-CtrlCcvTrayLatestPath -State $script:CtrlCcvTrayState; $notify.ShowBalloonTip(1500, "ctrl-ccv", "Latest upload path copied.", [System.Windows.Forms.ToolTipIcon]::Info) } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $startItem.Add_Click({ try { [void](Start-CtrlCcvTrayGuardian); & $refreshUi } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $stopItem.Add_Click({ try { Stop-CtrlCcvTrayService; & $refreshUi } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $restartItem.Add_Click({ try { Restart-CtrlCcvTrayService; & $refreshUi } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $logItem.Add_Click({ try { Show-CtrlCcvTrayRecentActivityWindow } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $configItem.Add_Click({ try { if (Show-CtrlCcvTraySettingsWindow) { & $refreshUi } } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $connectionHelpItem.Add_Click({ try { & $refreshUi; Show-CtrlCcvTrayConnectionHelpWindow -State $script:CtrlCcvTrayState; & $refreshUi } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $tmuxItem.Add_Click({ try { Show-CtrlCcvTrayTmuxSetupWindow } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $dataItem.Add_Click({ try { Open-CtrlCcvTrayDataFolder } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $updateItem.Add_Click({ try { Open-CtrlCcvTrayReleasePage } catch { Show-CtrlCcvTrayError $_.Exception.Message } })
        $notify.Add_DoubleClick({ & $refreshUi; Show-CtrlCcvTrayStatusWindow -State $script:CtrlCcvTrayState })
        $exitItem.Add_Click({ $context.ExitThread() })

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $RefreshSeconds * 1000
        $timer.Add_Tick({ & $refreshUi })
        & $refreshUi
        $timer.Start()
        [System.Windows.Forms.Application]::Run($context)
    }
    finally {
        if ($timer) { $timer.Stop(); $timer.Dispose() }
        if ($notify) { $notify.Visible = $false; $notify.Dispose() }
        foreach ($statusIcon in @($trayStatusIcons.Values)) {
            if ($statusIcon) { $statusIcon.Dispose() }
        }
        if ($trayIconSelection -and $trayIconSelection.OwnsIcon -and $trayIconSelection.Icon) { $trayIconSelection.Icon.Dispose() }
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}

if (-not $NoRun) { Start-CtrlCcvTrayApplication }
