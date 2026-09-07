# Live local watchdog test. It briefly restarts only the local watcher; no SSH
# command is requested by this test and no remote file is changed.
$ErrorActionPreference = "Stop"
$share = Split-Path $PSScriptRoot -Parent
. (Join-Path $share "cpcv-core.ps1")

function Get-Watchers {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        Test-CpcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath (Join-Path $share 'cpcv-watch.ps1')
    })
}
function Get-Guardians {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        Test-CpcvProcessCommandLineForScript -CommandLine $_.CommandLine -ScriptPath (Join-Path $share 'cpcv-guardian.ps1')
    })
}

function Wait-CpcvTestProcessExit {
    param([Parameter(Mandatory)]$Process, [ValidateRange(1, 15)][int]$TimeoutSeconds = 5)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $Process.Refresh()
        if ($Process.HasExited) { return $true }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}

$guardians = @(Get-Guardians)
if ($guardians.Count -ne 1) { throw "Expected exactly one running guardian; found $($guardians.Count)." }
$secondGuardian = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"{0}"' -f (Join-Path $share 'cpcv-guardian.ps1')))
if (-not (Wait-CpcvTestProcessExit -Process $secondGuardian)) {
    Stop-CpcvProcessTree -ProcessId $secondGuardian.Id
    throw "A duplicate guardian did not exit after failing to acquire its mutex."
}
$before = @(Get-Watchers)
if ($before.Count -ne 1) { throw "Expected exactly one running watcher; found $($before.Count)." }
$beforePid = $before[0].ProcessId
$secondWatcher = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"{0}"' -f (Join-Path $share 'cpcv-watch.ps1')))
if (-not (Wait-CpcvTestProcessExit -Process $secondWatcher)) {
    Stop-CpcvProcessTree -ProcessId $secondWatcher.Id
    throw "A duplicate watcher did not exit after failing to acquire its mutex."
}

# Simulate a stalled/dead watcher locally. The guardian must create one fresh
# replacement and never leave two active uploaders.
Stop-CpcvProcessTree -ProcessId $beforePid
$watchExitDeadline = (Get-Date).AddSeconds(8)
do {
    Start-Sleep -Milliseconds 100
    $stoppedWatchers = @(Get-Watchers | Where-Object { $_.ProcessId -eq $beforePid })
} while ($stoppedWatchers.Count -gt 0 -and (Get-Date) -lt $watchExitDeadline)
if ($stoppedWatchers.Count -gt 0) { throw "The test watcher $beforePid did not exit after tree cleanup." }

# The live watcher would normally refresh this file every poll. Write corrupt
# state only after it is gone, then let the existing guardian recover both the
# stopped watcher and bad health data without a race in the assertion itself.
Set-Content -Path $script:CpcvConfig.HeartbeatFile -Value "corrupt health state" -NoNewline
$corruptProbe = Join-Path $env:TEMP ("cpcv-corrupt-heartbeat-{0}.txt" -f [Guid]::NewGuid())
try {
    Set-Content -LiteralPath $corruptProbe -Value "corrupt health state" -NoNewline
    if (Test-CpcvHeartbeat -Path $corruptProbe) { throw "Corrupt heartbeat was accepted as healthy." }
}
finally {
    Remove-Item -LiteralPath $corruptProbe -Force -ErrorAction SilentlyContinue
}

$freshnessLimit = [Math]::Max(10, [int]$script:CpcvConfig.WatchdogCheckSeconds + 5)
$deadline = (Get-Date).AddSeconds([Math]::Max(35, ([int]$script:CpcvConfig.WatchdogCheckSeconds * 3) + 10))
$after = @()
$heartbeatInfo = $null
do {
    Start-Sleep -Seconds 1
    $after = @(Get-Watchers)
    $heartbeatInfo = Get-CpcvHeartbeatInfo -Path $script:CpcvConfig.HeartbeatFile
    $heartbeatFresh = ($null -ne $heartbeatInfo -and ((Get-Date).ToUniversalTime() - $heartbeatInfo.Timestamp.UtcDateTime).TotalSeconds -le $freshnessLimit)
} while ((Get-Date) -lt $deadline -and (
        $after.Count -ne 1 -or
        $after[0].ProcessId -eq $beforePid -or
        -not $heartbeatFresh -or
        $heartbeatInfo.ProcessId -ne [int]$after[0].ProcessId
    ))

if ($after.Count -ne 1) { throw "Guardian recovery left $($after.Count) watchers (expected one)." }
if ($after[0].ProcessId -eq $beforePid) { throw "Guardian did not replace the stalled watcher within 35 seconds." }
if ($null -eq $heartbeatInfo -or $heartbeatInfo.ProcessId -ne [int]$after[0].ProcessId) { throw "Replacement watcher did not write a matching heartbeat." }
$age = ((Get-Date).ToUniversalTime() - $heartbeatInfo.Timestamp.UtcDateTime).TotalSeconds
if ($age -gt $freshnessLimit) { throw "Replacement watcher did not refresh heartbeat (age=$age seconds)." }
Write-Host "PASS: duplicate guardian/watcher exited; corrupt health state was rejected; guardian replaced stalled watcher $beforePid with $($after[0].ProcessId) and kept one watcher"
