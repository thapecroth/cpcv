# Safe, local-only tests for the optional Windows tray companion.  They do not
# create a notification icon, touch the real uploader service, clipboard, or
# network. All temporary state is confined to TEMP.
$ErrorActionPreference = "Stop"

function Assert-CpcvTray([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "cpcv-tray.ps1") -NoRun
$busyIssue = Get-CpcvTrayUploadIssue -FailureReason 'clipboard-busy' -FailureCount 34
Assert-CpcvTray ($busyIssue.Summary -eq 'Clipboard is temporarily busy') 'Clipboard contention was labeled as an upload or SSH failure.'
Assert-CpcvTray ($busyIssue.Detail -notmatch '34 attempts|Connection help|Restart service') 'Clipboard contention carries misleading transport recovery guidance.'
$busyState = [pscustomobject]@{ Level = 'Warning'; IssueKind = 'Upload'; UploadFailureReason = 'clipboard-busy' }
Assert-CpcvTray ((Get-CpcvTrayGuidance -State $busyState) -match 'retrying the clipboard automatically') 'Clipboard contention guidance does not describe automatic recovery.'
Assert-CpcvTray (-not (Test-CpcvTraySshConnectionIssue -State $busyState)) 'Clipboard contention starts an SSH troubleshooting flow.'
Add-Type -AssemblyName System.Drawing
$traySource = Get-Content -LiteralPath (Join-Path $root "cpcv-tray.ps1") -Raw
Assert-CpcvTray ($traySource.Contains('$showStatusItem = $menu.Items.Add("View status...")')) "Tray menu no longer exposes a discoverable status action."
Assert-CpcvTray ($traySource.Contains('$exitItem = $menu.Items.Add("Exit tray (service stays running)")')) "Tray exit label no longer explains that the uploader remains active."
Assert-CpcvTray ($traySource.Contains('$script:CpcvTrayReleaseUrl = "https://github.com/thapecroth/cpcv/releases/latest"')) "Tray update action no longer uses the hard-coded official Releases URL."
Assert-CpcvTray ($traySource.Contains('function Get-CpcvTrayInstalledVersion')) "Tray no longer reads a bounded installed-version display value."
Assert-CpcvTray ($traySource.Contains('function Get-CpcvTrayUpdateMenuText')) "Tray no longer handles unavailable installed versions safely in its update label."
Assert-CpcvTray ($traySource.Contains('cpcvTrayUpdateButton')) "Status dashboard no longer exposes the explicit update action."
Assert-CpcvTray ($traySource.Contains('$updateItem = $menu.Items.Add((Get-CpcvTrayUpdateMenuText -InstalledVersion $installedVersion))')) "Tray menu no longer labels the installed version beside the update action."
Assert-CpcvTray ($traySource -match '(?s)\$updateButton\.Add_Click\(\{.*?Open-CpcvTrayReleasePage') "Status dashboard update action is not wired to the official release-page handoff."
Assert-CpcvTray ($traySource -match '(?s)\$updateItem\.Add_Click\(\{.*?Open-CpcvTrayReleasePage') "Tray menu update action is not wired to the official release-page handoff."
Assert-CpcvTray (-not ($traySource -match '(?i)\b(?:invoke-webrequest|invoke-restmethod|start-bitstransfer)\b')) "Tray update UX must not silently download an installer."
$script:releasePageLaunch = $null
function Start-Process {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    $script:releasePageLaunch = $FilePath
}
try {
    Open-CpcvTrayReleasePage
}
finally {
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
}
Assert-CpcvTray ($script:releasePageLaunch -eq 'https://github.com/thapecroth/cpcv/releases/latest') "Tray update action did not hand the exact official Releases URL to the browser."
Assert-CpcvTray ($traySource.Contains('Upload clipboard image')) "Status window no longer exposes its one-shot upload action."
Assert-CpcvTray ($traySource.Contains('Quick actions')) "Status window no longer has a clear quick-actions section."
Assert-CpcvTray ($traySource.Contains('Refresh status')) "Status window no longer exposes an explicit refresh action."
Assert-CpcvTray ($traySource.Contains('without displaying it here')) "Status dashboard no longer protects the latest path from casual display."
Assert-CpcvTray (-not ($traySource -match '(?i)\bnotepad\.exe\b')) "Tray actions must not hand customer configuration or activity files to Notepad."
Assert-CpcvTray (-not ($traySource -match '\bOpen-CpcvTray(?:Log|Config)\b')) "Legacy raw configuration or log opening actions are still reachable from the tray."
Assert-CpcvTray ($traySource.Contains('function Show-CpcvTraySettingsWindow')) "Tray no longer provides the customer-facing Settings window."
Assert-CpcvTray ($traySource.Contains('cpcvTraySettingsSaveButton') -and $traySource.Contains('Save-CpcvConfig -Config $draft')) "Settings window no longer saves through the validated configuration helper."
Assert-CpcvTray ($traySource.Contains('. (Join-Path $PSScriptRoot "cpcv-remote.ps1")')) "Tray no longer loads the scoped remote tmux helper."
Assert-CpcvTray ($traySource.Contains('function Show-CpcvTrayTmuxSetupWindow') -and $traySource.Contains('cpcvTrayTmuxApplyButton')) "Tray no longer provides the explicit tmux path-insertion window."
Assert-CpcvTray ($traySource.Contains('Configure tmux path insertion...')) "Tray no longer labels the remote tmux action clearly."
Assert-CpcvTray ($traySource.Contains('cpcvTrayTmuxCrossPlatformRadio') -and $traySource.Contains('Windows Alt-V + macOS Ctrl-V')) "Tray no longer offers the paired Windows Alt-V and macOS Ctrl-V shortcut."
Assert-CpcvTray ($traySource.Contains('tmux does not detect OS')) "Tray paired-shortcut UI could imply that tmux detects a client operating system."
Assert-CpcvTray ($traySource.Contains('function Start-CpcvTrayTmuxRemoteJob') -and $traySource.Contains('Receive-CpcvTrayTmuxRemoteJob -Job $job')) "Tray tmux actions no longer leave the WinForms UI thread before waiting on remote commands."
Assert-CpcvTray ($traySource.Contains('function Show-CpcvTrayRecentActivityWindow') -and $traySource.Contains('Get-CpcvTrayRecentActivityText')) "Tray no longer provides the bounded recent-activity window."
Assert-CpcvTray ($traySource.Contains('cpcvTrayRecentActivityRefreshButton')) "Recent-activity window no longer exposes a refresh action."
Assert-CpcvTray ($traySource.Contains('function Show-CpcvTrayConnectionHelpWindow') -and $traySource.Contains('cpcvTrayConnectionTestButton')) "Tray no longer provides a guided unattended-SSH connection assistant."
Assert-CpcvTray ($traySource.Contains('function Start-CpcvTraySshConnectionCheckProcess') -and $traySource.Contains('cpcv-connection-check.ps1') -and $traySource.Contains('Stop-CpcvProcessTree')) "Tray connection assistant no longer owns and safely cancels its SSH helper process."
Assert-CpcvTray ($traySource.Contains('Test unattended SSH') -and $traySource.Contains('one-time-code prompt')) "Tray connection assistant no longer explains unattended or MFA-style sign-in boundaries."
Assert-CpcvTray ($traySource -match '(?s)\$restartItem\.Enabled = \(\$state\.Level -ne "Error" -and -not \$hasUploadIssue') "Tray menu still offers a misleading service restart during an SSH upload issue."
Assert-CpcvTray ($traySource.Contains('cpcvTrayConnectionHelpButton') -and $traySource.Contains('Connection help...')) "Status dashboard no longer exposes the connection-specific recovery action."
Assert-CpcvTray ($traySource.Contains('"Settings..."') -and $traySource.Contains('"View recent activity..."')) "Tray no longer labels the customer-facing settings and activity actions clearly."
Assert-CpcvTray ($traySource -match '(?s)\$settingsButton\.Add_Click\(\{.*?Show-CpcvTraySettingsWindow') "Status dashboard Settings button is not wired to the Settings window."
Assert-CpcvTray ($traySource -match '(?s)\$tmuxButton\.Add_Click\(\{.*?Show-CpcvTrayTmuxSetupWindow') "Status dashboard tmux button is not wired to the tmux path-insertion window."
Assert-CpcvTray ($traySource -match '(?s)\$logButton\.Add_Click\(\{.*?Show-CpcvTrayRecentActivityWindow') "Status dashboard activity button is not wired to the recent-activity window."
Assert-CpcvTray ($traySource -match '(?s)\$connectionButton\.Add_Click\(\{.*?Show-CpcvTrayConnectionHelpWindow') "Status dashboard connection button is not wired to the guided assistant."
Assert-CpcvTray ($traySource -match '(?s)\$logItem\.Add_Click\(\{.*?Show-CpcvTrayRecentActivityWindow') "Tray activity menu item is not wired to the recent-activity window."
Assert-CpcvTray ($traySource -match '(?s)\$configItem\.Add_Click\(\{.*?Show-CpcvTraySettingsWindow') "Tray Settings menu item is not wired to the Settings window."
Assert-CpcvTray ($traySource -match '(?s)\$tmuxItem\.Add_Click\(\{.*?Show-CpcvTrayTmuxSetupWindow') "Tray tmux menu item is not wired to the tmux path-insertion window."

$crossPlatformTmuxChoice = Resolve-CpcvTrayTmuxPathInsertionChoice -Mode CrossPlatform
Assert-CpcvTray ($crossPlatformTmuxChoice.Table -eq 'root' -and $crossPlatformTmuxChoice.Key -eq 'C-v' -and $crossPlatformTmuxChoice.SecondaryTable -eq 'root' -and $crossPlatformTmuxChoice.SecondaryKey -eq 'M-v') "Tray tmux UI no longer selects the paired Windows Alt-V and macOS Ctrl-V binding."
$recommendedTmuxChoice = Resolve-CpcvTrayTmuxPathInsertionChoice -Mode Recommended
Assert-CpcvTray ($recommendedTmuxChoice.Table -eq 'prefix' -and $recommendedTmuxChoice.Key -eq 'v' -and -not $recommendedTmuxChoice.SecondaryTable) "Tray tmux UI no longer offers portable prefix/v as an alternative."
$rawTmuxChoice = Resolve-CpcvTrayTmuxPathInsertionChoice -Mode RawCtrlV
Assert-CpcvTray ($rawTmuxChoice.Table -eq 'root' -and $rawTmuxChoice.Key -eq 'C-v') "Tray tmux UI no longer treats raw Ctrl-V as an explicit advanced choice."
$invalidTmuxChoiceRejected = $false
try { Resolve-CpcvTrayTmuxPathInsertionChoice -Mode Custom -CustomKey ';' | Out-Null } catch { $invalidTmuxChoiceRejected = $true }
Assert-CpcvTray $invalidTmuxChoiceRejected "Tray tmux UI accepted unsafe custom key syntax."
$invalidPairedTmuxBindingRejected = $false
try { Test-CpcvRemoteTmuxBinding -Table root -Key 'C-v' -SecondaryTable root -SecondaryKey 'M-v;touch' | Out-Null } catch { $invalidPairedTmuxBindingRejected = $true }
Assert-CpcvTray $invalidPairedTmuxBindingRejected "Tray tmux helper accepted unsafe paired shortcut syntax."
Assert-CpcvTray ((Get-CpcvTrayTmuxStartupLine) -eq 'run-shell ~/.local/lib/cpcv/tmux/cpcv.tmux') "Tray tmux UI no longer exposes the user-owned startup line."

# Remote tmux work must be collected without blocking the UI event handler,
# then removed promptly; exercise that boundary with a harmless local job so
# this test never opens SSH or touches a tmux server.
$tmuxAsyncJob = Start-Job -ScriptBlock { [pscustomobject]@{ Ok = $true; Detail = 'synthetic tmux state' } }
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($tmuxAsyncJob.State -notin @('Completed', 'Failed', 'Stopped', 'Disconnected') -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    $tmuxAsyncResult = Receive-CpcvTrayTmuxRemoteJob -Job $tmuxAsyncJob
    Assert-CpcvTray ($tmuxAsyncResult.Completed -and $tmuxAsyncResult.Ok -and $tmuxAsyncResult.Result.Ok) "Tray tmux async job completion was not collected safely."
    Assert-CpcvTray ($null -eq (Get-Job -Id $tmuxAsyncJob.Id -ErrorAction SilentlyContinue)) "Tray tmux async job was not removed after completion."
}
finally {
    Remove-Job -Job $tmuxAsyncJob -Force -ErrorAction SilentlyContinue
}

$tmuxCancelledJob = Start-Job -ScriptBlock { Start-Sleep -Seconds 30 }
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($tmuxCancelledJob.State -eq 'NotStarted' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Stop-CpcvTrayTmuxRemoteJob -Job $tmuxCancelledJob
    Assert-CpcvTray ($null -eq (Get-Job -Id $tmuxCancelledJob.Id -ErrorAction SilentlyContinue)) "Tray tmux async job was not removed after cancellation."
}
finally {
    Remove-Job -Job $tmuxCancelledJob -Force -ErrorAction SilentlyContinue
}

# The tray must render only an allowlisted helper token. Exercise the exact
# bounded pipe/receiver contract with harmless local child PowerShells; no SSH
# command, clipboard, settings, or remote file is touched.
function Start-CpcvTrayTestConnectionProcess {
    param([Parameter(Mandatory)][string]$Script)

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    Assert-CpcvTray $process.Start() 'Synthetic tray connection-check process did not start.'
    $stdoutSink = New-Object -TypeName CpcvBoundedOutput -ArgumentList 4096
    $stderrSink = New-Object -TypeName CpcvBoundedOutput -ArgumentList 4096
    return [pscustomobject]@{
        Process = $process
        StdOutSink = $stdoutSink
        StdErrSink = $stderrSink
        StdOutTask = $stdoutSink.PumpAsync($process.StandardOutput)
        StdErrTask = $stderrSink.PumpAsync($process.StandardError)
    }
}

$connectionOperation = Start-CpcvTrayTestConnectionProcess -Script '[Console]::Out.Write('' {"Version":1,"FailureKind":"connected"} ''.Trim())'
try {
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $connectionAsyncResult = Receive-CpcvTraySshConnectionCheckProcess -Operation $connectionOperation
        if (-not $connectionAsyncResult.Completed) { Start-Sleep -Milliseconds 50 }
    } while (-not $connectionAsyncResult.Completed -and (Get-Date) -lt $deadline)
    Assert-CpcvTray ($connectionAsyncResult.Completed -and $connectionAsyncResult.Result.Ok -and $connectionAsyncResult.Result.FailureKind -eq 'connected') "Tray connection-check process completion was not collected safely."
    Assert-CpcvTray ($null -eq $connectionOperation.Process) "Tray connection-check process was not disposed after completion."
}
finally {
    Stop-CpcvTraySshConnectionCheckProcess -Operation $connectionOperation
}

$unsafeConnectionOperation = Start-CpcvTrayTestConnectionProcess -Script '[Console]::Error.Write("https://example.test/?token=synthetic-secret"); [Console]::Out.Write(''{"Version":1,"FailureKind":"connected"}'')'
try {
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $unsafeConnectionResult = Receive-CpcvTraySshConnectionCheckProcess -Operation $unsafeConnectionOperation
        if (-not $unsafeConnectionResult.Completed) { Start-Sleep -Milliseconds 50 }
    } while (-not $unsafeConnectionResult.Completed -and (Get-Date) -lt $deadline)
    $unsafeConnectionText = "$($unsafeConnectionResult.Result.Summary) $($unsafeConnectionResult.Result.Detail) $($unsafeConnectionResult.Result.NextStep)"
    Assert-CpcvTray ($unsafeConnectionResult.Completed -and $unsafeConnectionResult.Result.FailureKind -eq 'check-unavailable') "Tray accepted a helper response with untrusted stderr."
    Assert-CpcvTray ($unsafeConnectionText -notmatch 'synthetic-secret|example\.test') "Tray exposed untrusted helper output."
}
finally {
    Stop-CpcvTraySshConnectionCheckProcess -Operation $unsafeConnectionOperation
}

$cancelledConnectionOperation = Start-CpcvTrayTestConnectionProcess -Script 'Start-Sleep -Seconds 30'
$cancelledConnectionProcessId = $cancelledConnectionOperation.Process.Id
Stop-CpcvTraySshConnectionCheckProcess -Operation $cancelledConnectionOperation
Start-Sleep -Milliseconds 200
Assert-CpcvTray ($null -eq $cancelledConnectionOperation.Process -and -not (Get-Process -Id $cancelledConnectionProcessId -ErrorAction SilentlyContinue)) "Cancelling the tray connection check left its owned process running."

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
    $validVersionFile = Join-Path $tempRoot 'VERSION'
    [IO.File]::WriteAllText($validVersionFile, "1.2.3-beta.1+build.5`n", [Text.UTF8Encoding]::new($false))
    Assert-CpcvTray ((Get-CpcvTrayInstalledVersion -VersionFile $validVersionFile) -eq '1.2.3-beta.1+build.5') "Tray did not read a valid bundled SemVer version."
    $invalidVersionFile = Join-Path $tempRoot 'invalid-VERSION'
    [IO.File]::WriteAllText($invalidVersionFile, "version=secret`n", [Text.UTF8Encoding]::new($false))
    Assert-CpcvTray ((Get-CpcvTrayInstalledVersion -VersionFile $invalidVersionFile) -eq 'unknown') "Tray displayed malformed VERSION content."
    Assert-CpcvTray ((Get-CpcvTrayUpdateMenuText -InstalledVersion '1.2.3-beta.1') -eq 'Get latest version... (v1.2.3-beta.1)') "Tray update label did not include a valid installed version."
    Assert-CpcvTray ((Get-CpcvTrayUpdateMenuText -InstalledVersion 'unknown') -eq 'Get latest version... (version unavailable)') "Tray update label displayed an unavailable installed version unsafely."

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
        UploadStatusFile = (Join-Path $tempRoot "upload-status.txt")
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
        $processes = if ($script:trayProbeMode -eq "guardian-only" -and $ScriptPath -notmatch "guardian") { @() } else { @([pscustomobject]@{ ProcessId = $fakeProcessId }) }
        return [pscustomobject]@{ Available = $true; Processes = $processes; Error = "" }
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

    $script:trayProbeMode = "guardian-only"
    $recovering = Get-CpcvTrayState
    Assert-CpcvTray ($recovering.Level -eq "Warning" -and $recovering.IssueKind -eq "Service" -and $recovering.Summary -match "Automatic uploads are restarting" -and (Get-CpcvTrayGuidance -State $recovering) -match "Refresh status") "A guardian-only startup state did not explain that automatic uploads are recovering."
    $script:trayProbeMode = "healthy"

    Set-CpcvAtomicText -Path $script:trayTestConfig.UploadStatusFile -Value ("{0} result=failed reason=ssh-mkdir-connect-timeout" -f (Get-Date).ToUniversalTime().ToString("o"))
    $uploadFailure = Get-CpcvTrayState
    Assert-CpcvTray ($uploadFailure.Level -eq "Warning" -and $uploadFailure.IssueKind -eq "Upload") "A persisted upload failure was not surfaced as an upload-specific warning."
    Assert-CpcvTray ($uploadFailure.Summary -match "SSH upload connection timed out") "An unattended SSH timeout did not receive a clear summary."
    Assert-CpcvTray ($uploadFailure.Detail -match "SSH greeting") "The tray did not expose the safe, actionable handshake stage."
    Assert-CpcvTray (Test-CpcvTraySshConnectionIssue -State $uploadFailure) "An early SSH failure did not enable the connection-specific recovery path."
    $connectionGuide = Get-CpcvTraySshTroubleshooting -State $uploadFailure
    Assert-CpcvTray ($connectionGuide.Title -match "unattended SSH check" -and $connectionGuide.WhatHappened -match "terminal session can still work") "The tray did not explain the difference between an unattended SSH attempt and an interactive terminal session."
    Assert-CpcvTray ($connectionGuide.Steps -match "Test unattended SSH" -and $connectionGuide.Steps -match "Retry clipboard upload") "The connection assistant did not provide a complete customer recovery path."
    Assert-CpcvTray (("$($connectionGuide.Title) $($connectionGuide.Summary) $($connectionGuide.WhatHappened) $($connectionGuide.Steps) $($connectionGuide.SupportCode)") -notmatch "example-host|clipboard-images|/home/tester") "Connection guidance exposed private configuration or remote-path data."
    Assert-CpcvTray ((Get-CpcvTrayGuidance -State $uploadFailure) -match "Connection help") "An SSH upload warning did not direct the customer to the guided connection action."
    $failureTooltip = Get-CpcvTrayTooltip -State $uploadFailure
    Assert-CpcvTray ($failureTooltip -eq 'cpcv: Service running - SSH needs attention' -and $failureTooltip.Length -le 63 -and $failureTooltip -notmatch "example-host|clipboard-images") "Upload-failure tooltip was not bounded, private, and clear about local-service health."

    $authFailure = $uploadFailure.PSObject.Copy()
    $authFailure.UploadFailureReason = 'ssh-mkdir-auth-failed'
    $authFailureGuide = Get-CpcvTraySshTroubleshooting -State $authFailure
    Assert-CpcvTray ($authFailureGuide.Title -match 'sign-in' -and $authFailureGuide.WhatHappened -match 'one-time-code' -and $authFailureGuide.Steps -match 'never asks for, stores, or pastes a code') "The authentication walkthrough did not safely explain MFA-style prompts."

    $remoteFolderIssue = Get-CpcvTrayUploadIssue -FailureReason 'ssh-mkdir-remote-folder-failed'
    Assert-CpcvTray ($remoteFolderIssue.Summary -match 'Remote upload folder' -and $remoteFolderIssue.Detail -match 'reached the SSH target') "Remote upload-folder permission failures were not distinguished from sign-in failures."
    $remoteFolderState = $uploadFailure.PSObject.Copy()
    $remoteFolderState.UploadFailureReason = 'ssh-mkdir-remote-folder-failed'
    Assert-CpcvTray (-not (Test-CpcvTraySshConnectionIssue -State $remoteFolderState)) "A remote upload-folder permission failure incorrectly opens the connection-only assistant."
    Assert-CpcvTray ((Get-CpcvTrayGuidance -State $remoteFolderState) -match 'remote image folder') "A remote upload-folder permission failure did not direct the customer to the relevant setting or administrator."

    # Make state ordering explicit rather than relying on clock resolution: a
    # newer watcher retry must supersede an older confirmed one-shot upload,
    # while a later confirmed upload must clear that retry warning.
    $confirmedUploadAt = (Get-Date).ToUniversalTime().AddSeconds(-10)
    Set-CpcvAtomicText -Path $script:trayTestConfig.UploadStatusFile -Value ("{0} result=succeeded" -f $confirmedUploadAt.ToString("o"))
    $recovered = Get-CpcvTrayState
    Assert-CpcvTray ($recovered.Level -eq "Healthy" -and $recovered.IssueKind -eq "") "A confirmed successful upload did not clear the upload warning."

    $retryHeartbeatAt = $confirmedUploadAt.AddSeconds(5)
    Set-CpcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=2" -f $retryHeartbeatAt.ToString("o"))
    $legacyRetry = Get-CpcvTrayState
    Assert-CpcvTray ($legacyRetry.Level -eq "Warning" -and $legacyRetry.IssueKind -eq "Upload" -and $legacyRetry.UploadFailureCount -eq 2) "A retrying legacy watcher heartbeat did not fail visibly."

    Set-CpcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=2" -f $retryHeartbeatAt.AddSeconds(-2).ToString("o"))
    Set-CpcvAtomicText -Path $script:trayTestConfig.UploadStatusFile -Value ("{0} result=succeeded" -f $retryHeartbeatAt.AddSeconds(1).ToString("o"))
    $manualRecovery = Get-CpcvTrayState
    Assert-CpcvTray ($manualRecovery.Level -eq "Healthy" -and $manualRecovery.UploadFailureCount -eq 0) "A newer confirmed manual retry did not clear an older watcher retry warning."

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

Write-Host "PASS: branded tray icon loads and reaches the real NotifyIcon API; missing, corrupt, and oversized icon assets fail closed to the system fallback; tray no-run mode, customer-facing Settings/activity controls without Notepad, bounded redacted recent activity, private tooltip, service-recovery status, controlled SSH/MFA guidance, owned helper-process cancellation, healthy/stale/mismatched heartbeat status, inspection fail-closed, configuration error status, and synthetic STA UI actions"
