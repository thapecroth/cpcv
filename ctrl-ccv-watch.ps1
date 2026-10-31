# Background watcher: auto-upload new Windows clipboard images to the configured SSH target.
param(
    [int]$IntervalSeconds = 0,
    # Define the retry helpers without acquiring a mutex or starting uploads.
    [switch]$NoRun
)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\ctrl-ccv-core.ps1"

function Get-CtrlCcvWatcherClipboardSequence {
    # The sequence number can be checked without opening or reading the
    # clipboard, even when another application temporarily owns it.
    try {
        if (-not ("CtrlCcvWatcherClipboardNative" -as [type])) {
            Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class CtrlCcvWatcherClipboardNative {
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}
'@ -ErrorAction Stop
        }
        $sequence = [CtrlCcvWatcherClipboardNative]::GetClipboardSequenceNumber()
        # Windows returns zero if the current desktop clipboard is unavailable.
        if ($sequence -ne 0) { return $sequence }
    }
    catch { }
    return $null
}

function Get-CtrlCcvWatcherClockMilliseconds {
    # Retry deadlines must not move when the system clock is corrected.
    return ([Diagnostics.Stopwatch]::GetTimestamp() * 1000.0 / [Diagnostics.Stopwatch]::Frequency)
}

function Invoke-CtrlCcvWatcherSleep {
    param([int]$Milliseconds)
    Start-Sleep -Milliseconds $Milliseconds
}

function Get-CtrlCcvWatcherUploadStatus {
    try {
        $path = Get-CtrlCcvUploadStatusFilePath -Config $script:CtrlCcvConfig
        if (-not [string]::IsNullOrWhiteSpace($path)) { return (Get-CtrlCcvUploadStatusInfo -Path $path) }
    }
    catch { }
    return $null
}

function Get-CtrlCcvWatcherRetryState {
    param(
        [Parameter(Mandatory)]$UploadResult,
        [ValidateRange(0, [int]::MaxValue)][int]$FailureCount,
        [ValidateRange(1, 86400)][int]$IntervalSeconds
    )

    $isFailure = $false
    $delay = $IntervalSeconds
    if ($UploadResult.Ok) { $FailureCount = 0 }
    elseif ($UploadResult.Reason -notin @("no-image", "upload-in-progress", "clipboard-changed", "clipboard-busy")) {
        $isFailure = $true
        if ($FailureCount -lt [int]::MaxValue) { $FailureCount++ }
        $delay = Get-CtrlCcvRetryDelay -FailureCount $FailureCount -IntervalSeconds $IntervalSeconds
    }
    # Clipboard contention is local and brief. Preserve the transport failure
    # history, but keep checking at the ordinary poll interval while it clears.
    return [pscustomobject]@{
        FailureCount = $FailureCount
        DelaySeconds = $delay
        IsFailure = $isFailure
    }
}

function Update-CtrlCcvWatcherClipboardBusyState {
    param([Parameter(Mandatory)]$UploadResult, [bool]$WasBusy)

    $isBusy = ($UploadResult.Reason -eq "clipboard-busy")
    if ($isBusy -and -not $WasBusy) {
        Write-CtrlCcvLog "Windows clipboard temporarily busy; retrying at the normal poll interval"
    }
    elseif (-not $isBusy -and $WasBusy) {
        Write-CtrlCcvLog "Windows clipboard contention cleared"
    }
    return $isBusy
}

function Enter-CtrlCcvWatcherMutex {
    param([Parameter(Mandatory)]$Mutex)
    try { return $Mutex.WaitOne(0, $false) }
    catch {
        # PowerShell can wrap the native exception in a method invocation
        # exception. Only abandonment grants ownership despite the exception.
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.Threading.AbandonedMutexException]) { return $true }
            $exception = $exception.InnerException
        }
        throw
    }
}

function Wait-CtrlCcvWatcherRetry {
    param(
        [ValidateRange(0, 86400)][double]$DelaySeconds,
        [ValidateRange(0, [int]::MaxValue)][int]$FailureCount,
        [AllowNull()]$ClipboardSequence,
        [AllowNull()]$UploadSuccessAfter
    )

    $deadline = (Get-CtrlCcvWatcherClockMilliseconds) + ($DelaySeconds * 1000.0)
    $nextHeartbeat = 0.0
    while ($true) {
        $currentSequence = Get-CtrlCcvWatcherClipboardSequence
        if ($null -ne $currentSequence) {
            if ($null -ne $ClipboardSequence -and $currentSequence -ne $ClipboardSequence) {
                Update-CtrlCcvHeartbeat -Status "idle failures=0"
                return [pscustomobject]@{ FailureCount = 0; ClipboardChanged = $true }
            }
            # An unavailable sequence is not evidence of a clipboard change.
            if ($null -eq $ClipboardSequence) { $ClipboardSequence = $currentSequence }
        }
        $now = Get-CtrlCcvWatcherClockMilliseconds
        if ($now -ge $nextHeartbeat) {
            if ($FailureCount -gt 0 -and $null -ne $UploadSuccessAfter) {
                $uploadStatus = Get-CtrlCcvWatcherUploadStatus
                if ($uploadStatus -and $uploadStatus.Result -eq "succeeded" -and $uploadStatus.Timestamp -gt $UploadSuccessAfter) {
                    # A tray/manual upload may have recovered this image while
                    # the watcher slept. Do not revive its old failed heartbeat.
                    Update-CtrlCcvHeartbeat -Status "idle failures=0"
                    return [pscustomobject]@{ FailureCount = 0; ClipboardChanged = $false }
                }
            }
            Update-CtrlCcvHeartbeat -Status "idle failures=$FailureCount"
            $nextHeartbeat = $now + 2000.0
        }
        if ($now -ge $deadline) { break }
        # Keep the watchdog heartbeat fresh throughout a long network backoff,
        # and react within one short chunk when the user copies a new image.
        $sleepMilliseconds = [int][Math]::Min(250, [Math]::Ceiling($deadline - $now))
        Invoke-CtrlCcvWatcherSleep -Milliseconds $sleepMilliseconds
    }
    return [pscustomobject]@{ FailureCount = $FailureCount; ClipboardChanged = $false }
}

if ($NoRun) { return }

if ($script:CtrlCcvConfig.ConfigError) {
    Write-CtrlCcvLog "watcher will not start: $($script:CtrlCcvConfig.ConfigError)"
    exit 1
}

if ($IntervalSeconds -le 0) { $IntervalSeconds = [int]$script:CtrlCcvConfig.PollIntervalSeconds }

$mutex = New-Object System.Threading.Mutex($false, (Get-CtrlCcvMutexName -Purpose "Watcher"))
$ownsMutex = $false
try {
    $ownsMutex = Enter-CtrlCcvWatcherMutex -Mutex $mutex
    if (-not $ownsMutex) {
        Write-CtrlCcvLog "watcher launch ignored; another watcher owns the mutex"
        return
    }

    $failureCount = 0
    $clipboardWasBusy = $false
    Write-CtrlCcvLog "watcher started (host=$($script:CtrlCcvConfig.HostAlias), interval=${IntervalSeconds}s, mode=image-preserved, pid=$PID)"
    while ($true) {
        $attemptStartedAt = [DateTimeOffset]::UtcNow
        $clipboardSequence = Get-CtrlCcvWatcherClipboardSequence
        try {
            Update-CtrlCcvHeartbeat -Status "checking"
            $result = Publish-ClipboardImage
            $clipboardWasBusy = Update-CtrlCcvWatcherClipboardBusyState -UploadResult $result -WasBusy $clipboardWasBusy
            $retryState = Get-CtrlCcvWatcherRetryState -UploadResult $result -FailureCount $failureCount -IntervalSeconds $IntervalSeconds
            $failureCount = $retryState.FailureCount
            if ($result.Ok -and $result.Reason -eq "uploaded") { Write-CtrlCcvLog "auto-synced image $($result.RemotePath)" }
            elseif ($retryState.IsFailure) {
                Write-CtrlCcvLog "publish failed (attempt=$failureCount): $($result.Reason) $($result.Detail)"
            }
        }
        catch {
            $retryState = Get-CtrlCcvWatcherRetryState -UploadResult @{ Ok = $false; Reason = "upload-error" } -FailureCount $failureCount -IntervalSeconds $IntervalSeconds
            $failureCount = $retryState.FailureCount
            Write-CtrlCcvLog "watcher error (attempt=$failureCount): $_"
        }
        finally { Update-CtrlCcvHeartbeat -Status "idle failures=$failureCount" }

        # Avoid continuously launching a broken SSH/proxy connection.
        $waitResult = Wait-CtrlCcvWatcherRetry -DelaySeconds $retryState.DelaySeconds -FailureCount $failureCount -ClipboardSequence $clipboardSequence -UploadSuccessAfter $attemptStartedAt
        $failureCount = $waitResult.FailureCount
    }
}
finally {
    try { if ($ownsMutex) { $mutex.ReleaseMutex() | Out-Null } }
    finally { $mutex.Dispose() }
}
