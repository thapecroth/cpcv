# Background watcher: auto-upload new Windows clipboard images to the configured SSH target.
param([int]$IntervalSeconds = 0)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\cpcv-core.ps1"

if ($script:CpcvConfig.ConfigError) {
    Write-CpcvLog "watcher will not start: $($script:CpcvConfig.ConfigError)"
    exit 1
}

if ($IntervalSeconds -le 0) { $IntervalSeconds = [int]$script:CpcvConfig.PollIntervalSeconds }

$mutex = New-Object System.Threading.Mutex($false, (Get-CpcvMutexName -Purpose "Watcher"))
if (-not $mutex.WaitOne(0, $false)) {
    Write-CpcvLog "watcher launch ignored; another watcher owns the mutex"
    exit 0
}

$failureCount = 0
Write-CpcvLog "watcher started (host=$($script:CpcvConfig.HostAlias), interval=${IntervalSeconds}s, mode=image-preserved, pid=$PID)"
try {
    while ($true) {
        try {
            Update-CpcvHeartbeat -Status "checking"
            $result = Publish-ClipboardImage
            if ($result.Ok) {
                $failureCount = 0
                if ($result.Reason -eq "uploaded") { Write-CpcvLog "auto-synced image $($result.RemotePath)" }
            }
            elseif ($result.Reason -ne "no-image" -and $result.Reason -ne "upload-in-progress" -and $result.Reason -ne "clipboard-changed") {
                $failureCount++
                Write-CpcvLog "publish failed (attempt=$failureCount): $($result.Reason) $($result.Detail)"
            }
        }
        catch {
            $failureCount++
            Write-CpcvLog "watcher error (attempt=$failureCount): $_"
        }
        finally { Update-CpcvHeartbeat -Status "idle failures=$failureCount" }

        # Avoid continuously launching a broken SSH/proxy connection.
        $delay = Get-CpcvRetryDelay -FailureCount $failureCount -IntervalSeconds $IntervalSeconds
        Start-Sleep -Seconds $delay
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
