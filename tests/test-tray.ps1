# Safe, local-only tests for the optional Windows tray companion.  They do not
# create a notification icon, touch the real uploader service, clipboard, or
# network. All temporary state is confined to TEMP.
$ErrorActionPreference = "Stop"

function Assert-ImgPasteTray([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "imgpaste-tray.ps1") -NoRun
Add-Type -AssemblyName System.Drawing
$traySource = Get-Content -LiteralPath (Join-Path $root "imgpaste-tray.ps1") -Raw
Assert-ImgPasteTray ($traySource.Contains('$showStatusItem = $menu.Items.Add("View status...")')) "Tray menu no longer exposes a discoverable status action."
Assert-ImgPasteTray ($traySource.Contains('$exitItem = $menu.Items.Add("Exit tray (service stays running)")')) "Tray exit label no longer explains that the uploader remains active."
Assert-ImgPasteTray ($traySource.Contains('Upload clipboard image')) "Status window no longer exposes its one-shot upload action."
Assert-ImgPasteTray ($traySource.Contains('Quick actions')) "Status window no longer has a clear quick-actions section."
Assert-ImgPasteTray ($traySource.Contains('Refresh status')) "Status window no longer exposes an explicit refresh action."
Assert-ImgPasteTray ($traySource.Contains('without displaying it here')) "Status dashboard no longer protects the latest path from casual display."

$healthyStyle = Get-ImgPasteTrayStatusStyle -Level "Healthy"
$warningStyle = Get-ImgPasteTrayStatusStyle -Level "Warning"
Assert-ImgPasteTray ($healthyStyle.Badge -eq "Healthy" -and $healthyStyle.Accent -match '^#') "Healthy state no longer has a usable visual style."
Assert-ImgPasteTray ($warningStyle.Badge -eq "Needs attention" -and $warningStyle.Surface -match '^#') "Warning state no longer has a usable visual style."
Assert-ImgPasteTray ((Get-ImgPasteTrayRelativeTimeText -AgeSeconds 0) -eq "Just now") "Fresh heartbeat display is incorrect."
Assert-ImgPasteTray ((Get-ImgPasteTrayRelativeTimeText -AgeSeconds 61) -eq "1 min ago") "Minute heartbeat display is incorrect."
Assert-ImgPasteTray ((Get-ImgPasteTrayRelativeTimeText -AgeSeconds $null) -eq "Waiting for first heartbeat") "Missing heartbeat display is incorrect."
$redactedDashboardText = ConvertTo-ImgPasteTrayDisplayText -Text 'Bearer a-secret-token password=hunter2' -MaximumLength 80
Assert-ImgPasteTray ($redactedDashboardText -notmatch 'a-secret-token|hunter2') "Dashboard display text failed to redact a credential-like detail."
Assert-ImgPasteTray ($traySource.Contains('$trayIconSelection = Get-ImgPasteTrayIcon')) "Tray no longer uses the safe branded-icon loader."
$brandedIconPath = Get-ImgPasteTrayIconAssetPath
Assert-ImgPasteTray (Test-Path -LiteralPath $brandedIconPath -PathType Leaf) "The checked-in branded tray icon is missing."
$brandedIcon = Get-ImgPasteTrayIcon
try {
    Assert-ImgPasteTray (-not $brandedIcon.IsFallback -and $brandedIcon.OwnsIcon -and $brandedIcon.Source -eq 'project asset') "The checked-in branded tray icon did not load."
    Assert-ImgPasteTray ($brandedIcon.Icon.Width -ge 16 -and $brandedIcon.Icon.Height -ge 16) "The checked-in branded tray icon is too small."
}
finally {
    if ($brandedIcon -and $brandedIcon.OwnsIcon -and $brandedIcon.Icon) { $brandedIcon.Icon.Dispose() }
}
$brandedLogoPath = Get-ImgPasteTrayLogoAssetPath
Assert-ImgPasteTray (Test-Path -LiteralPath $brandedLogoPath -PathType Leaf) "The checked-in branded dashboard logo is missing."
$brandedLogo = Get-ImgPasteTrayLogo
try {
    Assert-ImgPasteTray ($null -ne $brandedLogo -and $brandedLogo.Width -ge 32 -and $brandedLogo.Height -ge 32) "The checked-in branded dashboard logo did not load."
}
finally {
    if ($brandedLogo) { $brandedLogo.Dispose() }
}

$tempRoot = Join-Path $env:TEMP ("imgpaste-tray-test-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $missingIcon = Get-ImgPasteTrayIcon -IconPath (Join-Path $tempRoot 'missing.ico')
    Assert-ImgPasteTray ($missingIcon.IsFallback -and -not $missingIcon.OwnsIcon -and $missingIcon.Reason -eq 'missing') "A missing tray icon did not use the system fallback."
    Assert-ImgPasteTray ($null -eq (Get-ImgPasteTrayLogo -LogoPath (Join-Path $tempRoot 'missing.png'))) "A missing dashboard logo did not fail closed."

    $corruptIconPath = Join-Path $tempRoot 'corrupt.ico'
    [IO.File]::WriteAllText($corruptIconPath, 'not an icon', [Text.UTF8Encoding]::new($false))
    $corruptIcon = Get-ImgPasteTrayIcon -IconPath $corruptIconPath
    Assert-ImgPasteTray ($corruptIcon.IsFallback -and -not $corruptIcon.OwnsIcon) "A corrupt tray icon did not use the system fallback."

    $oversizedIconPath = Join-Path $tempRoot 'oversized.ico'
    $oversizedStream = [IO.File]::Open($oversizedIconPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $oversizedStream.SetLength((1MB) + 1) }
    finally { $oversizedStream.Dispose() }
    $oversizedIcon = Get-ImgPasteTrayIcon -IconPath $oversizedIconPath
    Assert-ImgPasteTray ($oversizedIcon.IsFallback -and -not $oversizedIcon.OwnsIcon -and $oversizedIcon.Reason -eq 'invalid-file') "An oversized tray icon did not fail closed before parsing."

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

$uiTest = Join-Path $PSScriptRoot 'test-tray-ui.ps1'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $uiTest
if ($LASTEXITCODE -ne 0) { throw "STA tray UI test failed with exit code $LASTEXITCODE." }

$iconTest = Join-Path $PSScriptRoot 'test-tray-icon.ps1'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $iconTest
if ($LASTEXITCODE -ne 0) { throw "STA tray icon test failed with exit code $LASTEXITCODE." }

Write-Host "PASS: branded tray icon loads and reaches the real NotifyIcon API; missing, corrupt, and oversized icon assets fail closed to the system fallback; tray no-run mode, discoverable controls, bounded private tooltip, healthy/stale/mismatched heartbeat status, inspection fail-closed, configuration error status, and synthetic STA UI actions"
