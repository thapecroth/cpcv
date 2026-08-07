# Live local watchdog test. It briefly restarts only the local watcher; no SSH
# command is requested by this test and no remote file is changed.
$ErrorActionPreference = "Stop"
$share = Split-Path $PSScriptRoot -Parent
. (Join-Path $share "imgpaste-core.ps1")
$escapedShare = [regex]::Escape($share)

function Get-Watchers {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -match "-File\s+`"?$escapedShare\\imgpaste-watch\.ps1"
    })
}
function Get-Guardians {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.CommandLine -and $_.CommandLine -match "-File\s+`"?$escapedShare\\imgpaste-guardian\.ps1"
    })
}

$guardians = @(Get-Guardians)
if ($guardians.Count -ne 1) { throw "Expected exactly one running guardian; found $($guardians.Count)." }
$secondGuardian = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned', '-File', (Join-Path $share 'imgpaste-guardian.ps1'))
Start-Sleep -Seconds 2
if (-not $secondGuardian.HasExited) { Stop-Process -Id $secondGuardian.Id -Force; throw "A duplicate guardian did not exit after failing to acquire its mutex." }
$before = @(Get-Watchers)
if ($before.Count -ne 1) { throw "Expected exactly one running watcher; found $($before.Count)." }
$beforePid = $before[0].ProcessId
$secondWatcher = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned', '-File', (Join-Path $share 'imgpaste-watch.ps1'))
Start-Sleep -Seconds 2
if (-not $secondWatcher.HasExited) { Stop-Process -Id $secondWatcher.Id -Force; throw "A duplicate watcher did not exit after failing to acquire its mutex." }

Set-Content -Path $script:ImgPasteConfig.HeartbeatFile -Value "corrupt health state" -NoNewline
if (Test-ImgPasteHeartbeat -Path $script:ImgPasteConfig.HeartbeatFile) { throw "Corrupt heartbeat was accepted as healthy." }

# Simulate a stalled/dead watcher locally. The guardian must create one fresh
# replacement and never leave two active uploaders.
Stop-Process -Id $beforePid -Force
$deadline = (Get-Date).AddSeconds(35)
do {
    Start-Sleep -Seconds 1
    $after = @(Get-Watchers)
} while ((Get-Date) -lt $deadline -and ($after.Count -ne 1 -or $after[0].ProcessId -eq $beforePid))

if ($after.Count -ne 1) { throw "Guardian recovery left $($after.Count) watchers (expected one)." }
if ($after[0].ProcessId -eq $beforePid) { throw "Guardian did not replace the stalled watcher within 35 seconds." }
$age = ((Get-Date) - (Get-Item $script:ImgPasteConfig.HeartbeatFile).LastWriteTime).TotalSeconds
if ($age -gt 10) { throw "Replacement watcher did not refresh heartbeat (age=$age seconds)." }
Write-Host "PASS: duplicate guardian/watcher exited; corrupt health state was rejected; guardian replaced stalled watcher $beforePid with $($after[0].ProcessId) and kept one watcher"
