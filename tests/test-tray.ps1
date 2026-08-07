# Safe, local-only tests for the optional Windows tray companion.  They do not
# create a notification icon, touch the real uploader service, clipboard, or
# network. All temporary state is confined to TEMP.
$ErrorActionPreference = "Stop"

function Assert-ImgPasteTray([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "imgpaste-tray.ps1") -NoRun

$tempRoot = Join-Path $env:TEMP ("imgpaste-tray-test-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $shortcutPath = Join-Path $tempRoot "imgpaste-tray.lnk"
    $trayScript = [IO.Path]::GetFullPath((Join-Path $root "imgpaste-tray.ps1"))
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-NoProfile -STA -File `"$trayScript`""
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = "Managed by imgpaste install-tray.ps1"
    $shortcut.Save()
    Assert-ImgPasteTray (Test-ImgPasteTrayShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $trayScript -WorkingDirectory $root) "A marked exact tray shortcut was not recognized."
    $shortcut.Description = "Unrelated shortcut"
    $shortcut.Save()
    Assert-ImgPasteTray (-not (Test-ImgPasteTrayShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $trayScript -WorkingDirectory $root)) "An unrelated named shortcut was accepted."

    $script:trayTestConfig = @{
        HostAlias = "example-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 35; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 120
        MaxLogBytes = 1048576; MaxCacheFiles = 200; MaxCacheBytes = 268435456; MaxImageBytes = 52428800; ConfigError = ""
    }
    function Get-ImgPasteConfig { return $script:trayTestConfig }
    Set-ImgPasteAtomicText -Path $script:trayTestConfig.LastRemotePathFile -Value "/home/tester/clipboard-images/latest.png"

    $script:trayProbeMode = "healthy"
    function Get-ImgPasteTrayProcessProbe {
        param([string]$ScriptPath)
        if ($script:trayProbeMode -eq "unavailable") {
            return [pscustomobject]@{ Available = $false; Processes = @(); Error = "simulated inspection failure" }
        }
        $fakeProcessId = if ($ScriptPath -match "guardian") { 1111 } else { 4242 }
        return [pscustomobject]@{ Available = $true; Processes = @([pscustomobject]@{ ProcessId = $fakeProcessId }); Error = "" }
    }

    Set-ImgPasteAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=0" -f (Get-Date).ToUniversalTime().ToString("o"))
    $healthy = Get-ImgPasteTrayState
    Assert-ImgPasteTray ($healthy.Level -eq "Healthy") "A matching fresh heartbeat was not healthy."
    Assert-ImgPasteTray ($healthy.LatestPath -eq "/home/tester/clipboard-images/latest.png") "Tray did not read the validated latest path."
    $tooltip = Get-ImgPasteTrayTooltip -State $healthy
    Assert-ImgPasteTray ($tooltip.Length -le 63) "NotifyIcon tooltip exceeded its Windows length limit."
    Assert-ImgPasteTray ($tooltip -notmatch "example-host|clipboard-images") "NotifyIcon tooltip exposed local configuration/path details."

    Set-ImgPasteAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=0" -f (Get-Date).ToUniversalTime().AddSeconds(-121).ToString("o"))
    $stale = Get-ImgPasteTrayState
    Assert-ImgPasteTray ($stale.Level -eq "Warning" -and $stale.Summary -match "stale") "A stale heartbeat was not surfaced as a warning."

    Set-ImgPasteAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=9999 idle failures=0" -f (Get-Date).ToUniversalTime().ToString("o"))
    $wrongPid = Get-ImgPasteTrayState
    Assert-ImgPasteTray ($wrongPid.Level -eq "Warning" -and $wrongPid.Summary -match "another process") "A mismatched heartbeat PID was not surfaced as a warning."

    $script:trayProbeMode = "unavailable"
    $unknown = Get-ImgPasteTrayState
    Assert-ImgPasteTray ($unknown.Level -eq "Unknown" -and $unknown.Summary -match "Cannot inspect") "Process-inspection failure did not fail closed."

    $script:trayProbeMode = "healthy"
    $script:trayTestConfig.ConfigError = "HostAlias is required."
    $configError = Get-ImgPasteTrayState
    Assert-ImgPasteTray ($configError.Level -eq "Error" -and $configError.Summary -match "Configuration") "Invalid configuration did not take priority in tray status."
}
finally {
    Remove-Item -Path Function:\Get-ImgPasteConfig -ErrorAction SilentlyContinue
    Remove-Variable -Name trayTestConfig -Scope Script -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "PASS: tray no-run mode, bounded private tooltip, healthy/stale/mismatched heartbeat status, inspection fail-closed, and configuration error status"
