# External watchdog for imgpaste-watch.ps1. Launched at user logon.
param([int]$CheckSeconds = 0, [int]$StaleSeconds = 0)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\imgpaste-core.ps1"
Sanitize-ImgPasteLog

if ($script:ImgPasteConfig.ConfigError) {
    Write-ImgPasteLog "guardian will not start: $($script:ImgPasteConfig.ConfigError)"
    exit 1
}

if ($CheckSeconds -le 0) { $CheckSeconds = [int]$script:ImgPasteConfig.WatchdogCheckSeconds }
if ($StaleSeconds -le 0) { $StaleSeconds = [int]$script:ImgPasteConfig.WatchdogStaleSeconds }
$minimumStaleSeconds = ([int64]$script:ImgPasteConfig.CommandTimeoutSeconds * 3) + [int64]$CheckSeconds
if ($CheckSeconds -lt 1 -or $CheckSeconds -gt 300 -or $StaleSeconds -lt $minimumStaleSeconds -or $StaleSeconds -gt 3600) {
    Write-ImgPasteLog "guardian will not start: CheckSeconds must be 1-300 and StaleSeconds must be $minimumStaleSeconds-3600."
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, (Get-ImgPasteMutexName -Purpose "Guardian"))
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

function Get-ImgPasteWatchProcess {
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-watch.ps1"))
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-ImgPasteProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $watchScript }
}

function Start-ImgPasteWatch {
    $watch = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "imgpaste-watch.ps1"))
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", $watch) -WindowStyle Hidden
    Write-ImgPasteLog "guardian started watcher"
}

Write-ImgPasteLog "guardian started (pid=$PID, stale=${StaleSeconds}s)"
try {
    while ($true) {
        $watchers = @(Get-ImgPasteWatchProcess)
        $heartbeat = if (Test-Path $script:ImgPasteConfig.HeartbeatFile) { Get-Item $script:ImgPasteConfig.HeartbeatFile } else { $null }
        $heartbeatAge = if ($heartbeat) { ((Get-Date) - $heartbeat.LastWriteTime).TotalSeconds } else { $null }
        $heartbeatInfo = if ($heartbeat) { Get-ImgPasteHeartbeatInfo -Path $heartbeat.FullName } else { $null }
        $heartbeatValid = ($null -ne $heartbeatInfo -and $watchers.Count -eq 1 -and $heartbeatInfo.ProcessId -eq [int]$watchers[0].ProcessId)
        $stale = $false
        if ($heartbeat) {
            $stale = (-not $heartbeatValid) -or ($heartbeatAge -lt -5) -or ($heartbeatAge -gt $StaleSeconds)
        }
        # A pre-watchdog watcher has no heartbeat.  Give a new one a grace
        # period, but recover an old process that was already stuck at logon.
        if (-not $heartbeat -and $watchers.Count -gt 0) {
            $stale = @($watchers | Where-Object {
                try { ((Get-Date) - [datetime]$_.CreationDate).TotalSeconds -gt $StaleSeconds } catch { $false }
            }).Count -gt 0
        }

        if ($watchers.Count -eq 0) {
            Start-ImgPasteWatch
        }
        elseif ($stale -or $watchers.Count -gt 1) {
            foreach ($watcher in $watchers) { Stop-ImgPasteProcessTree -ProcessId $watcher.ProcessId }
            $ageText = if ($null -ne $heartbeatAge) { "$([Math]::Round($heartbeatAge))s" } else { "missing" }
            $reason = if ($watchers.Count -gt 1) { "duplicate watcher(s)" } elseif (-not $heartbeatValid) { "invalid heartbeat" } else { "stale heartbeat" }
            Write-ImgPasteLog "guardian restarted $reason; heartbeat age=$ageText"
            Start-Sleep -Seconds 2
            Start-ImgPasteWatch
        }
        Start-Sleep -Seconds $CheckSeconds
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
