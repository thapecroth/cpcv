# External watchdog for cpcv-watch.ps1. Launched at user logon.
param([int]$CheckSeconds = 0, [int]$StaleSeconds = 0)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\cpcv-core.ps1"
Sanitize-CpcvLog

if ($script:CpcvConfig.ConfigError) {
    Write-CpcvLog "guardian will not start: $($script:CpcvConfig.ConfigError)"
    exit 1
}

if ($CheckSeconds -le 0) { $CheckSeconds = [int]$script:CpcvConfig.WatchdogCheckSeconds }
if ($StaleSeconds -le 0) { $StaleSeconds = [int]$script:CpcvConfig.WatchdogStaleSeconds }
$minimumStaleSeconds = ([int64]$script:CpcvConfig.CommandTimeoutSeconds * 3) + [int64]$CheckSeconds
if ($CheckSeconds -lt 1 -or $CheckSeconds -gt 300 -or $StaleSeconds -lt $minimumStaleSeconds -or $StaleSeconds -gt 3600) {
    Write-CpcvLog "guardian will not start: CheckSeconds must be 1-300 and StaleSeconds must be $minimumStaleSeconds-3600."
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, (Get-CpcvMutexName -Purpose "Guardian"))
if (-not $mutex.WaitOne(0, $false)) { exit 0 }

function Get-CpcvWatchProcess {
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-watch.ps1"))
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-CpcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $watchScript }
}

function Start-CpcvWatch {
    $watch = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "cpcv-watch.ps1"))
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $watch)) -WindowStyle Hidden
    Write-CpcvLog "guardian started watcher"
}

function Wait-CpcvWatchExit {
    param(
        [Parameter(Mandatory)][int[]]$ProcessIds,
        [ValidateRange(1, 30)][int]$TimeoutSeconds = 8
    )

    # taskkill is normally synchronous, but a just-terminated PowerShell
    # process can briefly retain its named mutex. Starting its replacement
    # during that window would make the replacement exit harmlessly and defer
    # recovery until the next watchdog cycle. Wait only for the PIDs we chose
    # to stop, never for an unrelated checkout's watcher.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $remaining = @(Get-CpcvWatchProcess | Where-Object { $ProcessIds -contains [int]$_.ProcessId })
        if ($remaining.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

Write-CpcvLog "guardian started (pid=$PID, stale=${StaleSeconds}s)"
try {
    while ($true) {
        $watchers = @(Get-CpcvWatchProcess)
        $heartbeat = if (Test-Path $script:CpcvConfig.HeartbeatFile) { Get-Item $script:CpcvConfig.HeartbeatFile } else { $null }
        $heartbeatAge = if ($heartbeat) { ((Get-Date) - $heartbeat.LastWriteTime).TotalSeconds } else { $null }
        $heartbeatInfo = if ($heartbeat) { Get-CpcvHeartbeatInfo -Path $heartbeat.FullName } else { $null }
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
            Start-CpcvWatch
        }
        elseif ($stale -or $watchers.Count -gt 1) {
            $watcherIds = @($watchers | ForEach-Object { [int]$_.ProcessId })
            foreach ($watcher in $watchers) { Stop-CpcvProcessTree -ProcessId $watcher.ProcessId }
            $ageText = if ($null -ne $heartbeatAge) { "$([Math]::Round($heartbeatAge))s" } else { "missing" }
            $reason = if ($watchers.Count -gt 1) { "duplicate watcher(s)" } elseif (-not $heartbeatValid) { "invalid heartbeat" } else { "stale heartbeat" }
            Write-CpcvLog "guardian restarted $reason; heartbeat age=$ageText"
            if (-not (Wait-CpcvWatchExit -ProcessIds $watcherIds)) {
                Write-CpcvLog "guardian timed out waiting for stopped watcher process(es); attempting guarded replacement"
            }
            Start-CpcvWatch
        }
        Start-Sleep -Seconds $CheckSeconds
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
