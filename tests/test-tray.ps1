# Safe, local-only tests for the optional Windows tray companion.  They do not
# create a notification icon, touch the real uploader service, clipboard, or
# network. All temporary state is confined to TEMP.
$ErrorActionPreference = "Stop"

function Assert-CpcvTray([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "cpcv-tray.ps1") -NoRun
Add-Type -AssemblyName System.Drawing
$traySource = Get-Content -LiteralPath (Join-Path $root "cpcv-tray.ps1") -Raw
Assert-CpcvTray ($traySource.Contains('$showStatusItem = $menu.Items.Add("View status...")')) "Tray menu no longer exposes a discoverable status action."
Assert-CpcvTray ($traySource.Contains('$exitItem = $menu.Items.Add("Exit tray (service stays running)")')) "Tray exit label no longer explains that the uploader remains active."
Assert-CpcvTray ($traySource.Contains('Upload clipboard image')) "Status window no longer exposes its one-shot upload action."
Assert-CpcvTray ($traySource.Contains('Quick actions')) "Status window no longer has a clear quick-actions section."
Assert-CpcvTray ($traySource.Contains('Refresh status')) "Status window no longer exposes an explicit refresh action."
Assert-CpcvTray ($traySource.Contains('without displaying it here')) "Status dashboard no longer protects the latest path from casual display."
Assert-CpcvTray (-not ($traySource -match '(?i)\bnotepad\.exe\b')) "Tray actions must not hand customer configuration or activity files to Notepad."
Assert-CpcvTray (-not ($traySource -match '\bOpen-CpcvTray(?:Log|Config)\b')) "Legacy raw configuration or log opening actions are still reachable from the tray."
Assert-CpcvTray ($traySource.Contains('function Show-CpcvTraySettingsWindow')) "Tray no longer provides the customer-facing Settings window."
Assert-CpcvTray ($traySource.Contains('cpcvTraySettingsSaveButton') -and $traySource.Contains('Save-CpcvConfig -Config $draft')) "Settings window no longer saves through the validated configuration helper."
Assert-CpcvTray ($traySource.Contains('function Show-CpcvTrayRecentActivityWindow') -and $traySource.Contains('Get-CpcvTrayRecentActivityText')) "Tray no longer provides the bounded recent-activity window."
Assert-CpcvTray ($traySource.Contains('cpcvTrayRecentActivityRefreshButton')) "Recent-activity window no longer exposes a refresh action."
Assert-CpcvTray ($traySource.Contains('"Settings..."') -and $traySource.Contains('"View recent activity..."')) "Tray no longer labels the customer-facing settings and activity actions clearly."
Assert-CpcvTray ($traySource -match '(?s)\$settingsButton\.Add_Click\(\{.*?Show-CpcvTraySettingsWindow') "Status dashboard Settings button is not wired to the Settings window."
Assert-CpcvTray ($traySource -match '(?s)\$logButton\.Add_Click\(\{.*?Show-CpcvTrayRecentActivityWindow') "Status dashboard activity button is not wired to the recent-activity window."
Assert-CpcvTray ($traySource -match '(?s)\$logItem\.Add_Click\(\{.*?Show-CpcvTrayRecentActivityWindow') "Tray activity menu item is not wired to the recent-activity window."
Assert-CpcvTray ($traySource -match '(?s)\$configItem\.Add_Click\(\{.*?Show-CpcvTraySettingsWindow') "Tray Settings menu item is not wired to the Settings window."

$healthyStyle = Get-CpcvTrayStatusStyle -Level "Healthy"
$warningStyle = Get-CpcvTrayStatusStyle -Level "Warning"
Assert-CpcvTray ($healthyStyle.Badge -eq "Healthy" -and $healthyStyle.Accent -match '^#') "Healthy state no longer has a usable visual style."
Assert-CpcvTray ($warningStyle.Badge -eq "Needs attention" -and $warningStyle.Surface -match '^#') "Warning state no longer has a usable visual style."
Assert-CpcvTray ((Get-CpcvTrayRelativeTimeText -AgeSeconds 0) -eq "Just now") "Fresh heartbeat display is incorrect."
Assert-CpcvTray ((Get-CpcvTrayRelativeTimeText -AgeSeconds 61) -eq "1 min ago") "Minute heartbeat display is incorrect."
Assert-CpcvTray ((Get-CpcvTrayRelativeTimeText -AgeSeconds $null) -eq "Waiting for first heartbeat") "Missing heartbeat display is incorrect."
$redactedDashboardText = ConvertTo-CpcvTrayDisplayText -Text 'Bearer a-secret-token password=hunter2' -MaximumLength 80
Assert-CpcvTray ($redactedDashboardText -notmatch 'a-secret-token|hunter2') "Dashboard display text failed to redact a credential-like detail."
Assert-CpcvTray ($traySource.Contains('$trayIconSelection = Get-CpcvTrayIcon')) "Tray no longer uses the safe branded-icon loader."
$brandedIconPath = Get-CpcvTrayIconAssetPath
Assert-CpcvTray (Test-Path -LiteralPath $brandedIconPath -PathType Leaf) "The checked-in branded tray icon is missing."
$brandedIcon = Get-CpcvTrayIcon
try {
    Assert-CpcvTray (-not $brandedIcon.IsFallback -and $brandedIcon.OwnsIcon -and $brandedIcon.Source -eq 'project asset') "The checked-in branded tray icon did not load."
    Assert-CpcvTray ($brandedIcon.Icon.Width -ge 16 -and $brandedIcon.Icon.Height -ge 16) "The checked-in branded tray icon is too small."
}
finally {
    if ($brandedIcon -and $brandedIcon.OwnsIcon -and $brandedIcon.Icon) { $brandedIcon.Icon.Dispose() }
}
$brandedLogoPath = Get-CpcvTrayLogoAssetPath
Assert-CpcvTray (Test-Path -LiteralPath $brandedLogoPath -PathType Leaf) "The checked-in branded dashboard logo is missing."
$brandedLogo = Get-CpcvTrayLogo
try {
    Assert-CpcvTray ($null -ne $brandedLogo -and $brandedLogo.Width -ge 32 -and $brandedLogo.Height -ge 32) "The checked-in branded dashboard logo did not load."
}
finally {
    if ($brandedLogo) { $brandedLogo.Dispose() }
}

$tempRoot = Join-Path $env:TEMP ("cpcv-tray-test-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    # Exercise the Settings persistence boundary in a fresh process so its
    # module-level CPCV_CONFIG selection cannot touch a real customer file.
    # The tray UI itself stubs these helpers in the STA probe below; this test
    # confirms the actual helper pair accepts a customer edit and writes only
    # data-only persisted fields.
    $persistenceConfigPath = Join-Path $tempRoot 'settings-config.psd1'
    $previousConfigPath = $env:CPCV_CONFIG
    $previousCoreRoot = $env:CPCV_TEST_CORE_ROOT
    try {
        $env:CPCV_CONFIG = $persistenceConfigPath
        $env:CPCV_TEST_CORE_ROOT = $root
        $persistenceScript = @'
$ErrorActionPreference = 'Stop'
Remove-Item Env:CPCV_HOST_ALIAS -ErrorAction SilentlyContinue
Remove-Item Env:CPCV_REMOTE_DIR -ErrorAction SilentlyContinue
Remove-Item Env:CPCV_REMOTE_HOME -ErrorAction SilentlyContinue
. (Join-Path $env:CPCV_TEST_CORE_ROOT 'cpcv-core.ps1')

$before = Get-CpcvEditableConfig
if ($before.Exists -or $before.LoadError) { throw 'Fresh Settings test configuration was not empty and readable.' }
$draft = [ordered]@{
    HostAlias = 'settings-host'
    RemoteDir = 'settings-images'
    RemoteHome = '/home/settings'
    DataRoot = (Join-Path (Split-Path $env:CPCV_CONFIG -Parent) 'settings-data')
    CommandTimeoutSeconds = 35
    MaxCommandOutputBytes = 65536
    PollIntervalSeconds = 2
    WatchdogCheckSeconds = 15
    WatchdogStaleSeconds = 120
    MaxLogBytes = 1048576
    MaxCacheFiles = 200
    MaxCacheBytes = 268435456
    MaxImageBytes = 52428800
}
$saved = Save-CpcvConfig -Config $draft
if (-not $saved.Exists -or $saved.HostAlias -ne 'settings-host' -or $saved.RemoteDir -ne 'settings-images') {
    throw 'Settings persistence did not return the saved editable values.'
}
$data = Import-PowerShellDataFile -LiteralPath $env:CPCV_CONFIG
if ($data.Keys.Count -ne 13 -or $data.HostAlias -ne 'settings-host' -or $data.Contains('Path') -or $data.Contains('ConfigError')) {
    throw 'Settings persistence did not write exactly the data-only editable fields.'
}
$unknownRejected = $false
try { Save-CpcvConfig -Config ([ordered]@{ NotASetting = 'nope' }) } catch { $unknownRejected = $true }
if (-not $unknownRejected) { throw 'Settings persistence accepted an unknown field.' }
$env:CPCV_HOST_ALIAS = 'session-host'
$withOverride = Get-CpcvEditableConfig
if (-not $withOverride.HasEnvironmentOverrides -or $withOverride.HostAlias -ne 'settings-host' -or $withOverride.EnvironmentOverrides -notcontains 'CPCV_HOST_ALIAS') {
    throw 'Settings persistence did not report an environment override without persisting it.'
}
if ((Get-CpcvConfig).HostAlias -ne 'session-host') { throw 'Runtime configuration did not retain its documented environment override.' }
'@
        $encodedPersistenceScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($persistenceScript))
        $persistenceOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedPersistenceScript 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Settings persistence child test failed: $($persistenceOutput | Out-String)"
        }
    }
    finally {
        if ($null -eq $previousConfigPath) { Remove-Item Env:CPCV_CONFIG -ErrorAction SilentlyContinue } else { $env:CPCV_CONFIG = $previousConfigPath }
        if ($null -eq $previousCoreRoot) { Remove-Item Env:CPCV_TEST_CORE_ROOT -ErrorAction SilentlyContinue } else { $env:CPCV_TEST_CORE_ROOT = $previousCoreRoot }
    }

    $missingIcon = Get-CpcvTrayIcon -IconPath (Join-Path $tempRoot 'missing.ico')
    Assert-CpcvTray ($missingIcon.IsFallback -and -not $missingIcon.OwnsIcon -and $missingIcon.Reason -eq 'missing') "A missing tray icon did not use the system fallback."
    Assert-CpcvTray ($null -eq (Get-CpcvTrayLogo -LogoPath (Join-Path $tempRoot 'missing.png'))) "A missing dashboard logo did not fail closed."

    $corruptIconPath = Join-Path $tempRoot 'corrupt.ico'
    [IO.File]::WriteAllText($corruptIconPath, 'not an icon', [Text.UTF8Encoding]::new($false))
    $corruptIcon = Get-CpcvTrayIcon -IconPath $corruptIconPath
    Assert-CpcvTray ($corruptIcon.IsFallback -and -not $corruptIcon.OwnsIcon) "A corrupt tray icon did not use the system fallback."

    $oversizedIconPath = Join-Path $tempRoot 'oversized.ico'
    $oversizedStream = [IO.File]::Open($oversizedIconPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $oversizedStream.SetLength((1MB) + 1) }
    finally { $oversizedStream.Dispose() }
    $oversizedIcon = Get-CpcvTrayIcon -IconPath $oversizedIconPath
    Assert-CpcvTray ($oversizedIcon.IsFallback -and -not $oversizedIcon.OwnsIcon -and $oversizedIcon.Reason -eq 'invalid-file') "An oversized tray icon did not fail closed before parsing."

    $shortcutPath = Join-Path $tempRoot "cpcv-tray.lnk"
    $trayScript = [IO.Path]::GetFullPath((Join-Path $root "cpcv-tray.ps1"))
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-NoProfile -STA -File `"$trayScript`""
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = "Managed by cpcv install-tray.ps1"
    $shortcut.Save()
    Assert-CpcvTray (Test-CpcvTrayShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $trayScript -WorkingDirectory $root) "A marked exact tray shortcut was not recognized."
    $shortcut.Description = "Unrelated shortcut"
    $shortcut.Save()
    Assert-CpcvTray (-not (Test-CpcvTrayShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $trayScript -WorkingDirectory $root)) "An unrelated named shortcut was accepted."

    $script:trayTestConfig = @{
        HostAlias = "example-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 35; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 120
        MaxLogBytes = 1048576; MaxCacheFiles = 200; MaxCacheBytes = 268435456; MaxImageBytes = 52428800; ConfigError = ""
    }
    function Get-CpcvConfig { return $script:trayTestConfig }
    Set-CpcvAtomicText -Path $script:trayTestConfig.LastRemotePathFile -Value "/home/tester/clipboard-images/latest.png"

    $missingActivity = Get-CpcvTrayRecentActivityText -Config @{ LogFile = (Join-Path $tempRoot 'missing-watch.log') }
    Assert-CpcvTray ($missingActivity -eq 'No local activity has been recorded yet.') "Missing activity log did not produce a safe empty-state message."
    $activityRecords = [System.Collections.Generic.List[string]]::new()
    for ($index = 1; $index -le 106; $index++) {
        [void]$activityRecords.Add(("activity {0:D3} " -f $index) + ('x' * 24))
    }
    [void]$activityRecords.Add('activity final Bearer a-secret-token password=hunter2')
    [IO.File]::WriteAllText(
        $script:trayTestConfig.LogFile,
        (($activityRecords -join [Environment]::NewLine) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    $recentActivity = Get-CpcvTrayRecentActivityText -Config $script:trayTestConfig -MaximumLines 3 -MaximumBytes 1024
    $recentLines = @($recentActivity -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-CpcvTray ($recentLines.Count -eq 3) "Recent activity did not honor its maximum record count."
    Assert-CpcvTray ($recentActivity -match 'activity 106' -and $recentActivity -match 'activity final') "Recent activity did not retain the bounded log tail."
    Assert-CpcvTray ($recentActivity -notmatch 'a-secret-token|hunter2') "Recent activity exposed credential-like log detail."

    $script:trayProbeMode = "healthy"
    function Get-CpcvTrayProcessProbe {
        param([string]$ScriptPath)
        if ($script:trayProbeMode -eq "unavailable") {
            return [pscustomobject]@{ Available = $false; Processes = @(); Error = "simulated inspection failure" }
        }
        $fakeProcessId = if ($ScriptPath -match "guardian") { 1111 } else { 4242 }
        return [pscustomobject]@{ Available = $true; Processes = @([pscustomobject]@{ ProcessId = $fakeProcessId }); Error = "" }
    }

    Set-CpcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=0" -f (Get-Date).ToUniversalTime().ToString("o"))
    $healthy = Get-CpcvTrayState
    Assert-CpcvTray ($healthy.Level -eq "Healthy") "A matching fresh heartbeat was not healthy."
    Assert-CpcvTray ($healthy.LatestPath -eq "/home/tester/clipboard-images/latest.png") "Tray did not read the validated latest path."
    Assert-CpcvTray ($null -ne $healthy.LatestUploadAt -and $null -ne $healthy.LatestUploadAgeSeconds -and $healthy.LatestUploadAgeSeconds -lt 5) "Tray did not derive a fresh successful-upload time from its validated state file."
    Assert-CpcvTray ((Get-CpcvTrayLatestUploadText -State $healthy) -match '^Uploaded ') "Tray did not expose a safe latest-upload status."
    $tooltip = Get-CpcvTrayTooltip -State $healthy
    Assert-CpcvTray ($tooltip.Length -le 63) "NotifyIcon tooltip exceeded its Windows length limit."
    Assert-CpcvTray ($tooltip -match 'uploaded') "Healthy tray tooltip did not report the latest successful upload."
    Assert-CpcvTray ($tooltip -notmatch "example-host|clipboard-images") "NotifyIcon tooltip exposed local configuration/path details."

    Set-CpcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=0" -f (Get-Date).ToUniversalTime().AddSeconds(-121).ToString("o"))
    $stale = Get-CpcvTrayState
    Assert-CpcvTray ($stale.Level -eq "Warning" -and $stale.Summary -match "stale") "A stale heartbeat was not surfaced as a warning."

    Set-CpcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=9999 idle failures=0" -f (Get-Date).ToUniversalTime().ToString("o"))
    $wrongPid = Get-CpcvTrayState
    Assert-CpcvTray ($wrongPid.Level -eq "Warning" -and $wrongPid.Summary -match "another process") "A mismatched heartbeat PID was not surfaced as a warning."

    $script:trayProbeMode = "unavailable"
    $unknown = Get-CpcvTrayState
    Assert-CpcvTray ($unknown.Level -eq "Unknown" -and $unknown.Summary -match "Cannot inspect") "Process-inspection failure did not fail closed."

    $script:trayProbeMode = "healthy"
    $script:trayTestConfig.ConfigError = "HostAlias is required."
    $configError = Get-CpcvTrayState
    Assert-CpcvTray ($configError.Level -eq "Error" -and $configError.Summary -match "Configuration") "Invalid configuration did not take priority in tray status."
}
finally {
    Remove-Item -Path Function:\Get-CpcvConfig -ErrorAction SilentlyContinue
    Remove-Variable -Name trayTestConfig -Scope Script -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

$uiTest = Join-Path $PSScriptRoot 'test-tray-ui.ps1'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $uiTest
if ($LASTEXITCODE -ne 0) { throw "STA tray UI test failed with exit code $LASTEXITCODE." }

$iconTest = Join-Path $PSScriptRoot 'test-tray-icon.ps1'
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $iconTest
if ($LASTEXITCODE -ne 0) { throw "STA tray icon test failed with exit code $LASTEXITCODE." }

Write-Host "PASS: branded tray icon loads and reaches the real NotifyIcon API; missing, corrupt, and oversized icon assets fail closed to the system fallback; tray no-run mode, customer-facing Settings/activity controls without Notepad, bounded redacted recent activity, bounded private tooltip, healthy/stale/mismatched heartbeat status, inspection fail-closed, configuration error status, and synthetic STA UI actions"
