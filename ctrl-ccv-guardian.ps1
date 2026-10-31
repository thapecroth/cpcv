# External watchdog for ctrl-ccv-watch.ps1. Launched at user logon.
param([int]$CheckSeconds = 0, [int]$StaleSeconds = 0)

$ErrorActionPreference = "Continue"
. "$PSScriptRoot\ctrl-ccv-core.ps1"
Sanitize-CtrlCcvLog

if ($script:CtrlCcvConfig.ConfigError) {
    Write-CtrlCcvLog "guardian will not start: $($script:CtrlCcvConfig.ConfigError)"
    exit 1
}

if ($CheckSeconds -le 0) { $CheckSeconds = [int]$script:CtrlCcvConfig.WatchdogCheckSeconds }
if ($StaleSeconds -le 0) { $StaleSeconds = [int]$script:CtrlCcvConfig.WatchdogStaleSeconds }
$minimumStaleSeconds = ([int64]$script:CtrlCcvConfig.CommandTimeoutSeconds * 3) + [int64]$CheckSeconds
if ($CheckSeconds -lt 1 -or $CheckSeconds -gt 300 -or $StaleSeconds -lt $minimumStaleSeconds -or $StaleSeconds -gt 3600) {
    Write-CtrlCcvLog "guardian will not start: CheckSeconds must be 1-300 and StaleSeconds must be $minimumStaleSeconds-3600."
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, (Get-CtrlCcvMutexName -Purpose "Guardian"))
try { $ownsMutex = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
if (-not $ownsMutex) { $mutex.Dispose(); exit 0 }

function Get-CtrlCcvWatchProcess {
    $watchScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-watch.ps1"))
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { Test-CtrlCcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath $watchScript }
}

function Start-CtrlCcvWatch {
    $watch = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "ctrl-ccv-watch.ps1"))
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-STA", "-WindowStyle", "Hidden", "-ExecutionPolicy", "RemoteSigned", "-File", ('"{0}"' -f $watch)) -WindowStyle Hidden
    Write-CtrlCcvLog "guardian started watcher"
}

function Wait-CtrlCcvWatchExit {
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
        $remaining = @(Get-CtrlCcvWatchProcess | Where-Object { $ProcessIds -contains [int]$_.ProcessId })
        if ($remaining.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

Write-CtrlCcvLog "guardian started (pid=$PID, stale=${StaleSeconds}s)"
try {
    while ($true) {
        $watchers = @(Get-CtrlCcvWatchProcess)
        $heartbeat = if (Test-Path $script:CtrlCcvConfig.HeartbeatFile) { Get-Item $script:CtrlCcvConfig.HeartbeatFile } else { $null }
        $heartbeatAge = if ($heartbeat) { ((Get-Date) - $heartbeat.LastWriteTime).TotalSeconds } else { $null }
        $heartbeatInfo = if ($heartbeat) { Get-CtrlCcvHeartbeatInfo -Path $heartbeat.FullName } else { $null }
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
            Start-CtrlCcvWatch
        }
        elseif ($stale -or $watchers.Count -gt 1) {
            $watcherIds = @($watchers | ForEach-Object { [int]$_.ProcessId })
            foreach ($watcher in $watchers) { Stop-CtrlCcvProcessTree -ProcessId $watcher.ProcessId }
            $ageText = if ($null -ne $heartbeatAge) { "$([Math]::Round($heartbeatAge))s" } else { "missing" }
            $reason = if ($watchers.Count -gt 1) { "duplicate watcher(s)" } elseif (-not $heartbeatValid) { "invalid heartbeat" } else { "stale heartbeat" }
            Write-CtrlCcvLog "guardian restarted $reason; heartbeat age=$ageText"
            if (-not (Wait-CtrlCcvWatchExit -ProcessIds $watcherIds)) {
                Write-CtrlCcvLog "guardian timed out waiting for stopped watcher process(es); attempting guarded replacement"
            }
            Start-CtrlCcvWatch
        }
        Start-Sleep -Seconds $CheckSeconds
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
