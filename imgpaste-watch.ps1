# Background watcher: auto-upload new Windows clipboard images to the configured SSH target.
param([int]$IntervalSeconds = 0)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\imgpaste-core.ps1"

if ($script:ImgPasteConfig.ConfigError) {
    Write-ImgPasteLog "watcher will not start: $($script:ImgPasteConfig.ConfigError)"
    exit 1
}

if ($IntervalSeconds -le 0) { $IntervalSeconds = [int]$script:ImgPasteConfig.PollIntervalSeconds }

$mutex = New-Object System.Threading.Mutex($false, (Get-ImgPasteMutexName -Purpose "Watcher"))
if (-not $mutex.WaitOne(0, $false)) {
    Write-ImgPasteLog "watcher launch ignored; another watcher owns the mutex"
    exit 0
}

$failureCount = 0
Write-ImgPasteLog "watcher started (host=$($script:ImgPasteConfig.HostAlias), interval=${IntervalSeconds}s, mode=image-preserved, pid=$PID)"
try {
    while ($true) {
        try {
            Update-ImgPasteHeartbeat -Status "checking"
            $result = Publish-ClipboardImage
            if ($result.Ok) {
                $failureCount = 0
                if ($result.Reason -eq "uploaded") { Write-ImgPasteLog "auto-synced image $($result.RemotePath)" }
            }
            elseif ($result.Reason -ne "no-image" -and $result.Reason -ne "upload-in-progress" -and $result.Reason -ne "clipboard-changed") {
                $failureCount++
                Write-ImgPasteLog "publish failed (attempt=$failureCount): $($result.Reason) $($result.Detail)"
            }
        }
        catch {
            $failureCount++
            Write-ImgPasteLog "watcher error (attempt=$failureCount): $_"
        }
        finally { Update-ImgPasteHeartbeat -Status "idle failures=$failureCount" }

        # Avoid continuously launching a broken SSH/proxy connection.
        $delay = Get-ImgPasteRetryDelay -FailureCount $failureCount -IntervalSeconds $IntervalSeconds
        Start-Sleep -Seconds $delay
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
