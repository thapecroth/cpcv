# Network-free watcher retry tests. No native clipboard, services, mutexes,
# user state files, or real sleeps are used.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "cpcv-watch.ps1") -NoRun
$ErrorActionPreference = "Stop"

function Assert-CpcvWatcher([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# A replacement watcher must accept ownership after a previous watcher
# crashed, while a healthy existing owner must still reject the duplicate.
$fakeMutex = [pscustomobject]@{ IsAbandoned = $false; IsFaulted = $false; CanAcquire = $false }
$fakeMutex | Add-Member -MemberType ScriptMethod -Name WaitOne -Value {
    param([int]$Timeout, [bool]$ExitContext)
    if ($this.IsAbandoned) { throw (New-Object System.Threading.AbandonedMutexException) }
    if ($this.IsFaulted) { throw (New-Object System.InvalidOperationException) }
    return $this.CanAcquire
}
Assert-CpcvWatcher (-not (Enter-CpcvWatcherMutex -Mutex $fakeMutex)) "A duplicate watcher was allowed past an existing mutex owner."
$fakeMutex.CanAcquire = $true
Assert-CpcvWatcher (Enter-CpcvWatcherMutex -Mutex $fakeMutex) "An available instance mutex did not allow the watcher to start."
$fakeMutex.IsAbandoned = $true
Assert-CpcvWatcher (Enter-CpcvWatcherMutex -Mutex $fakeMutex) "An abandoned instance mutex prevented watcher recovery."
$fakeMutex.IsAbandoned = $false
$fakeMutex.IsFaulted = $true
$unexpectedMutexError = $false
try { Enter-CpcvWatcherMutex -Mutex $fakeMutex | Out-Null } catch { $unexpectedMutexError = $true }
Assert-CpcvWatcher $unexpectedMutexError "An unrelated mutex error was mistaken for acquired ownership."

# A clipboard owner holding the clipboard is not a network failure, even if
# the uploader was already backing off from an earlier SSH failure.
$failureCount = 4
1..20 | ForEach-Object {
    $state = Get-CpcvWatcherRetryState -UploadResult @{ Ok = $false; Reason = "clipboard-busy" } -FailureCount $failureCount -IntervalSeconds 2
    Assert-CpcvWatcher ($state.FailureCount -eq 4 -and $state.DelaySeconds -eq 2 -and -not $state.IsFailure) "Repeated clipboard contention increased or retained the network backoff delay."
    $failureCount = $state.FailureCount
}
foreach ($reason in @("no-image", "upload-in-progress", "clipboard-changed")) {
    $state = Get-CpcvWatcherRetryState -UploadResult @{ Ok = $false; Reason = $reason } -FailureCount 4 -IntervalSeconds 2
    Assert-CpcvWatcher ($state.FailureCount -eq 4 -and $state.DelaySeconds -eq 2 -and -not $state.IsFailure) "An ordinary clipboard state was counted as a network failure."
}

# Genuine failures still protect a broken transport from continuous launches.
$failureCount = 0
foreach ($attempt in 1..15) {
    $state = Get-CpcvWatcherRetryState -UploadResult @{ Ok = $false; Reason = "ssh-mkdir-timeout" } -FailureCount $failureCount -IntervalSeconds 2
    $expectedDelay = [Math]::Min(60, 2 * [Math]::Pow(2, [Math]::Min($attempt, 5)))
    Assert-CpcvWatcher ($state.FailureCount -eq $attempt -and $state.IsFailure -and $state.DelaySeconds -eq $expectedDelay) "Transport failures no longer apply the expected capped backoff."
    $failureCount = $state.FailureCount
}
$saturated = Get-CpcvWatcherRetryState -UploadResult @{ Ok = $false; Reason = "scp-failed" } -FailureCount ([int]::MaxValue) -IntervalSeconds 2
Assert-CpcvWatcher ($saturated.FailureCount -eq [int]::MaxValue -and $saturated.DelaySeconds -eq 60) "Failure count overflow could stop the watcher."
foreach ($reason in @("uploaded", "unchanged")) {
    $recovered = Get-CpcvWatcherRetryState -UploadResult @{ Ok = $true; Reason = $reason } -FailureCount 15 -IntervalSeconds 2
    Assert-CpcvWatcher ($recovered.FailureCount -eq 0 -and $recovered.DelaySeconds -eq 2) "A confirmed successful upload did not reset backoff."
}

# Log a contention transition once, instead of flooding the activity log on
# every poll while another application keeps its clipboard handle open.
$script:watcherLogs = New-Object 'System.Collections.Generic.List[string]'
function Write-CpcvLog {
    param([string]$Message)
    $script:watcherLogs.Add($Message)
}
$wasBusy = $false
foreach ($attempt in 1..20) {
    $wasBusy = Update-CpcvWatcherClipboardBusyState -UploadResult @{ Ok = $false; Reason = "clipboard-busy" } -WasBusy $wasBusy
}
Assert-CpcvWatcher ($wasBusy -and $script:watcherLogs.Count -eq 1) "Repeated clipboard contention flooded the activity log."
$wasBusy = Update-CpcvWatcherClipboardBusyState -UploadResult @{ Ok = $true; Reason = "uploaded" } -WasBusy $wasBusy
Assert-CpcvWatcher (-not $wasBusy -and $script:watcherLogs.Count -eq 2) "Cleared clipboard contention was not reported once."
$wasBusy = Update-CpcvWatcherClipboardBusyState -UploadResult @{ Ok = $true; Reason = "unchanged" } -WasBusy $wasBusy
Assert-CpcvWatcher ($script:watcherLogs.Count -eq 2) "Healthy polling repeated the cleared-contention message."

# Replace every external dependency of the wait policy. Time advances only
# when the wait requests a fake sleep, so these checks run immediately.
function Reset-CpcvWatcherFakeWait {
    $script:watcherNow = 0.0
    $script:watcherSleeps = New-Object 'System.Collections.Generic.List[int]'
    $script:watcherHeartbeats = New-Object 'System.Collections.Generic.List[object]'
    $script:watcherSequence = 41
    $script:watcherChangeAt = [double]::PositiveInfinity
    $script:watcherSequenceUnavailableUntil = 0
    $script:watcherUploadStatus = $null
    $script:watcherUploadStatusAvailableAt = 0
}
function Get-CpcvWatcherClockMilliseconds { return $script:watcherNow }
function Invoke-CpcvWatcherSleep {
    param([int]$Milliseconds)
    Assert-CpcvWatcher ($Milliseconds -gt 0 -and $Milliseconds -le 250) "Watcher retry sleep was not split into short bounded chunks."
    $script:watcherSleeps.Add($Milliseconds)
    $script:watcherNow += $Milliseconds
}
function Get-CpcvWatcherClipboardSequence {
    if ($script:watcherNow -lt $script:watcherSequenceUnavailableUntil) { return $null }
    if ($script:watcherNow -ge $script:watcherChangeAt) { return ($script:watcherSequence + 1) }
    return $script:watcherSequence
}
function Get-CpcvWatcherUploadStatus {
    if ($script:watcherNow -ge $script:watcherUploadStatusAvailableAt) { return $script:watcherUploadStatus }
    return $null
}
function Update-CpcvHeartbeat {
    param([string]$Status)
    $script:watcherHeartbeats.Add([pscustomobject]@{ At = $script:watcherNow; Status = $Status })
}

Reset-CpcvWatcherFakeWait
$wait = Wait-CpcvWatcherRetry -DelaySeconds 60 -FailureCount 15 -ClipboardSequence 41
Assert-CpcvWatcher ($script:watcherNow -eq 60000 -and -not $wait.ClipboardChanged -and $wait.FailureCount -eq 15) "An unchanged clipboard unexpectedly interrupted transport backoff."
Assert-CpcvWatcher ($script:watcherHeartbeats.Count -ge 30) "Heartbeat went stale during the capped transport backoff."
$lastHeartbeatAt = 0.0
foreach ($heartbeat in $script:watcherHeartbeats) {
    Assert-CpcvWatcher (($heartbeat.At - $lastHeartbeatAt) -le 2000 -and $heartbeat.Status -eq "idle failures=15") "Backoff heartbeat was late or lost the active failure count."
    $lastHeartbeatAt = $heartbeat.At
}
Assert-CpcvWatcher ((60000 - $lastHeartbeatAt) -le 2000) "Heartbeat was stale when transport backoff ended."

Reset-CpcvWatcherFakeWait
$script:watcherChangeAt = 750
$wait = Wait-CpcvWatcherRetry -DelaySeconds 60 -FailureCount 15 -ClipboardSequence 41
Assert-CpcvWatcher ($wait.ClipboardChanged -and $wait.FailureCount -eq 0 -and $script:watcherNow -eq 750) "Copying a new image did not promptly wake the watcher and reset backoff."
Assert-CpcvWatcher ($script:watcherHeartbeats[$script:watcherHeartbeats.Count - 1].Status -eq "idle failures=0") "Clipboard-change wake did not expose a fresh reset heartbeat."

# The sequence captured before an upload also catches changes during SSH,
# rather than making a newer image wait through the old image's retry delay.
Reset-CpcvWatcherFakeWait
$wait = Wait-CpcvWatcherRetry -DelaySeconds 60 -FailureCount 15 -ClipboardSequence 40
Assert-CpcvWatcher ($wait.ClipboardChanged -and $wait.FailureCount -eq 0 -and $script:watcherSleeps.Count -eq 0) "A clipboard change during the failed upload was not detected immediately."

Reset-CpcvWatcherFakeWait
$wait = Wait-CpcvWatcherRetry -DelaySeconds 2 -FailureCount 4 -ClipboardSequence 41
Assert-CpcvWatcher ($script:watcherNow -eq 2000 -and $wait.FailureCount -eq 4) "Clipboard-busy retry did not preserve the earlier transport failure count at the normal interval."

# Losing and regaining sequence access alone is not a content change.
Reset-CpcvWatcherFakeWait
$script:watcherSequenceUnavailableUntil = 500
$wait = Wait-CpcvWatcherRetry -DelaySeconds 2 -FailureCount 4 -ClipboardSequence $null
Assert-CpcvWatcher ($script:watcherNow -eq 2000 -and -not $wait.ClipboardChanged -and $wait.FailureCount -eq 4) "Sequence availability was mistaken for a copied image."

# A concurrent one-shot recovery must clear the old watcher failure count,
# even though a successful automatic upload preserves the clipboard sequence.
$attemptStartedAt = [DateTimeOffset]::Parse("2026-01-01T00:00:00Z")
Reset-CpcvWatcherFakeWait
$script:watcherUploadStatus = [pscustomobject]@{ Result = "succeeded"; Timestamp = $attemptStartedAt.AddSeconds(1) }
$script:watcherUploadStatusAvailableAt = 1000
$wait = Wait-CpcvWatcherRetry -DelaySeconds 60 -FailureCount 15 -ClipboardSequence 41 -UploadSuccessAfter $attemptStartedAt
Assert-CpcvWatcher ($script:watcherNow -eq 2000 -and $wait.FailureCount -eq 0 -and -not $wait.ClipboardChanged) "A newer successful one-shot upload did not clear the stale network backoff."
Assert-CpcvWatcher ($script:watcherHeartbeats[$script:watcherHeartbeats.Count - 1].Status -eq "idle failures=0") "A one-shot recovery retained the old failed watcher heartbeat."

foreach ($status in @(
    [pscustomobject]@{ Result = "succeeded"; Timestamp = $attemptStartedAt.AddSeconds(-1) },
    [pscustomobject]@{ Result = "failed"; Timestamp = $attemptStartedAt.AddSeconds(1) }
)) {
    Reset-CpcvWatcherFakeWait
    $script:watcherUploadStatus = $status
    $wait = Wait-CpcvWatcherRetry -DelaySeconds 5 -FailureCount 4 -ClipboardSequence 41 -UploadSuccessAfter $attemptStartedAt
    Assert-CpcvWatcher ($script:watcherNow -eq 5000 -and $wait.FailureCount -eq 4) "An old success or newer failure was mistaken for a recovered upload."
}

Write-Host "PASS: abandoned instance mutex recovery, clipboard-busy polling, capped transport retry, new-image and one-shot recovery wake, unavailable sequence fallback, and fresh backoff heartbeats"
