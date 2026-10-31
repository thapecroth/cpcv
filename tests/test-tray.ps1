# Safe, local-only tests for the optional Windows tray companion.  They do not
# create a notification icon, touch the real uploader service, clipboard, or
# network. All temporary state is confined to TEMP.
$ErrorActionPreference = "Stop"

function Assert-CtrlCcvTray([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root "ctrl-ccv-tray.ps1") -NoRun
$busyIssue = Get-CtrlCcvTrayUploadIssue -FailureReason 'clipboard-busy' -FailureCount 34
Assert-CtrlCcvTray ($busyIssue.Summary -eq 'Clipboard is temporarily busy') 'Clipboard contention was labeled as an upload or SSH failure.'
Assert-CtrlCcvTray ($busyIssue.Detail -notmatch '34 attempts|Connection help|Restart service') 'Clipboard contention carries misleading transport recovery guidance.'
$busyState = [pscustomobject]@{ Level = 'Warning'; IssueKind = 'Upload'; UploadFailureReason = 'clipboard-busy' }
Assert-CtrlCcvTray ((Get-CtrlCcvTrayGuidance -State $busyState) -match 'retrying the clipboard automatically') 'Clipboard contention guidance does not describe automatic recovery.'
Assert-CtrlCcvTray (-not (Test-CtrlCcvTraySshConnectionIssue -State $busyState)) 'Clipboard contention starts an SSH troubleshooting flow.'
Add-Type -AssemblyName System.Drawing
$traySource = Get-Content -LiteralPath (Join-Path $root "ctrl-ccv-tray.ps1") -Raw
Assert-CtrlCcvTray ($traySource.Contains('$showStatusItem = $menu.Items.Add("View status...")')) "Tray menu no longer exposes a discoverable status action."
Assert-CtrlCcvTray ($traySource.Contains('$exitItem = $menu.Items.Add("Exit tray (service stays running)")')) "Tray exit label no longer explains that the uploader remains active."
Assert-CtrlCcvTray ($traySource.Contains('$script:CtrlCcvTrayReleaseUrl = "https://github.com/thapecroth/ctrl-ccv/releases/latest"')) "Tray update action no longer uses the hard-coded official Releases URL."
Assert-CtrlCcvTray ($traySource.Contains('function Get-CtrlCcvTrayInstalledVersion')) "Tray no longer reads a bounded installed-version display value."
Assert-CtrlCcvTray ($traySource.Contains('function Get-CtrlCcvTrayUpdateMenuText')) "Tray no longer handles unavailable installed versions safely in its update label."
Assert-CtrlCcvTray ($traySource.Contains('ctrlCcvTrayUpdateButton')) "Status dashboard no longer exposes the explicit update action."
Assert-CtrlCcvTray ($traySource.Contains('$updateItem = $menu.Items.Add((Get-CtrlCcvTrayUpdateMenuText -InstalledVersion $installedVersion))')) "Tray menu no longer labels the installed version beside the update action."
Assert-CtrlCcvTray ($traySource -match '(?s)\$updateButton\.Add_Click\(\{.*?Open-CtrlCcvTrayReleasePage') "Status dashboard update action is not wired to the official release-page handoff."
Assert-CtrlCcvTray ($traySource -match '(?s)\$updateItem\.Add_Click\(\{.*?Open-CtrlCcvTrayReleasePage') "Tray menu update action is not wired to the official release-page handoff."
Assert-CtrlCcvTray (-not ($traySource -match '(?i)\b(?:invoke-webrequest|invoke-restmethod|start-bitstransfer)\b')) "Tray update UX must not silently download an installer."
$script:releasePageLaunch = $null
function Start-Process {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    $script:releasePageLaunch = $FilePath
}
try {
    Open-CtrlCcvTrayReleasePage
}
finally {
    Remove-Item Function:\Start-Process -ErrorAction SilentlyContinue
}
Assert-CtrlCcvTray ($script:releasePageLaunch -eq 'https://github.com/thapecroth/ctrl-ccv/releases/latest') "Tray update action did not hand the exact official Releases URL to the browser."
Assert-CtrlCcvTray ($traySource.Contains('Upload clipboard image')) "Status window no longer exposes its one-shot upload action."
Assert-CtrlCcvTray ($traySource.Contains('Quick actions')) "Status window no longer has a clear quick-actions section."
Assert-CtrlCcvTray ($traySource.Contains('Refresh status')) "Status window no longer exposes an explicit refresh action."
Assert-CtrlCcvTray ($traySource.Contains('without displaying it here')) "Status dashboard no longer protects the latest path from casual display."
Assert-CtrlCcvTray (-not ($traySource -match '(?i)\bnotepad\.exe\b')) "Tray actions must not hand customer configuration or activity files to Notepad."
Assert-CtrlCcvTray (-not ($traySource -match '\bOpen-CtrlCcvTray(?:Log|Config)\b')) "Legacy raw configuration or log opening actions are still reachable from the tray."
Assert-CtrlCcvTray ($traySource.Contains('function Show-CtrlCcvTraySettingsWindow')) "Tray no longer provides the customer-facing Settings window."
Assert-CtrlCcvTray ($traySource.Contains('ctrlCcvTraySettingsSaveButton') -and $traySource.Contains('Save-CtrlCcvConfig -Config $draft')) "Settings window no longer saves through the validated configuration helper."
Assert-CtrlCcvTray ($traySource.Contains('. (Join-Path $PSScriptRoot "ctrl-ccv-remote.ps1")')) "Tray no longer loads the scoped remote tmux helper."
Assert-CtrlCcvTray ($traySource.Contains('function Show-CtrlCcvTrayTmuxSetupWindow') -and $traySource.Contains('ctrlCcvTrayTmuxApplyButton')) "Tray no longer provides the explicit tmux path-insertion window."
Assert-CtrlCcvTray ($traySource.Contains('Configure tmux path insertion...')) "Tray no longer labels the remote tmux action clearly."
Assert-CtrlCcvTray ($traySource.Contains('ctrlCcvTrayTmuxCrossPlatformRadio') -and $traySource.Contains('Windows Alt-V + macOS Ctrl-V')) "Tray no longer offers the paired Windows Alt-V and macOS Ctrl-V shortcut."
Assert-CtrlCcvTray ($traySource.Contains('tmux does not detect OS')) "Tray paired-shortcut UI could imply that tmux detects a client operating system."
Assert-CtrlCcvTray ($traySource.Contains('function Start-CtrlCcvTrayTmuxRemoteJob') -and $traySource.Contains('Receive-CtrlCcvTrayTmuxRemoteJob -Job $job')) "Tray tmux actions no longer leave the WinForms UI thread before waiting on remote commands."
Assert-CtrlCcvTray ($traySource.Contains('function Show-CtrlCcvTrayRecentActivityWindow') -and $traySource.Contains('Get-CtrlCcvTrayRecentActivityText')) "Tray no longer provides the bounded recent-activity window."
Assert-CtrlCcvTray ($traySource.Contains('ctrlCcvTrayRecentActivityRefreshButton')) "Recent-activity window no longer exposes a refresh action."
Assert-CtrlCcvTray ($traySource.Contains('function Show-CtrlCcvTrayConnectionHelpWindow') -and $traySource.Contains('ctrlCcvTrayConnectionTestButton')) "Tray no longer provides a guided unattended-SSH connection assistant."
Assert-CtrlCcvTray ($traySource.Contains('function Start-CtrlCcvTraySshConnectionCheckProcess') -and $traySource.Contains('ctrl-ccv-connection-check.ps1') -and $traySource.Contains('Stop-CtrlCcvProcessTree')) "Tray connection assistant no longer owns and safely cancels its SSH helper process."
Assert-CtrlCcvTray ($traySource.Contains('Test unattended SSH') -and $traySource.Contains('one-time-code prompt')) "Tray connection assistant no longer explains unattended or MFA-style sign-in boundaries."
Assert-CtrlCcvTray ($traySource -match '(?s)\$restartItem\.Enabled = \(\$state\.Level -ne "Error" -and -not \$hasUploadIssue') "Tray menu still offers a misleading service restart during an SSH upload issue."
Assert-CtrlCcvTray ($traySource.Contains('ctrlCcvTrayConnectionHelpButton') -and $traySource.Contains('Connection help...')) "Status dashboard no longer exposes the connection-specific recovery action."
Assert-CtrlCcvTray ($traySource.Contains('"Settings..."') -and $traySource.Contains('"View recent activity..."')) "Tray no longer labels the customer-facing settings and activity actions clearly."
Assert-CtrlCcvTray ($traySource -match '(?s)\$settingsButton\.Add_Click\(\{.*?Show-CtrlCcvTraySettingsWindow') "Status dashboard Settings button is not wired to the Settings window."
Assert-CtrlCcvTray ($traySource -match '(?s)\$tmuxButton\.Add_Click\(\{.*?Show-CtrlCcvTrayTmuxSetupWindow') "Status dashboard tmux button is not wired to the tmux path-insertion window."
Assert-CtrlCcvTray ($traySource -match '(?s)\$logButton\.Add_Click\(\{.*?Show-CtrlCcvTrayRecentActivityWindow') "Status dashboard activity button is not wired to the recent-activity window."
Assert-CtrlCcvTray ($traySource -match '(?s)\$connectionButton\.Add_Click\(\{.*?Show-CtrlCcvTrayConnectionHelpWindow') "Status dashboard connection button is not wired to the guided assistant."
Assert-CtrlCcvTray ($traySource -match '(?s)\$logItem\.Add_Click\(\{.*?Show-CtrlCcvTrayRecentActivityWindow') "Tray activity menu item is not wired to the recent-activity window."
Assert-CtrlCcvTray ($traySource -match '(?s)\$configItem\.Add_Click\(\{.*?Show-CtrlCcvTraySettingsWindow') "Tray Settings menu item is not wired to the Settings window."
Assert-CtrlCcvTray ($traySource -match '(?s)\$tmuxItem\.Add_Click\(\{.*?Show-CtrlCcvTrayTmuxSetupWindow') "Tray tmux menu item is not wired to the tmux path-insertion window."

$crossPlatformTmuxChoice = Resolve-CtrlCcvTrayTmuxPathInsertionChoice -Mode CrossPlatform
Assert-CtrlCcvTray ($crossPlatformTmuxChoice.Table -eq 'root' -and $crossPlatformTmuxChoice.Key -eq 'C-v' -and $crossPlatformTmuxChoice.SecondaryTable -eq 'root' -and $crossPlatformTmuxChoice.SecondaryKey -eq 'M-v') "Tray tmux UI no longer selects the paired Windows Alt-V and macOS Ctrl-V binding."
$recommendedTmuxChoice = Resolve-CtrlCcvTrayTmuxPathInsertionChoice -Mode Recommended
Assert-CtrlCcvTray ($recommendedTmuxChoice.Table -eq 'prefix' -and $recommendedTmuxChoice.Key -eq 'v' -and -not $recommendedTmuxChoice.SecondaryTable) "Tray tmux UI no longer offers portable prefix/v as an alternative."
$rawTmuxChoice = Resolve-CtrlCcvTrayTmuxPathInsertionChoice -Mode RawCtrlV
Assert-CtrlCcvTray ($rawTmuxChoice.Table -eq 'root' -and $rawTmuxChoice.Key -eq 'C-v') "Tray tmux UI no longer treats raw Ctrl-V as an explicit advanced choice."
$invalidTmuxChoiceRejected = $false
try { Resolve-CtrlCcvTrayTmuxPathInsertionChoice -Mode Custom -CustomKey ';' | Out-Null } catch { $invalidTmuxChoiceRejected = $true }
Assert-CtrlCcvTray $invalidTmuxChoiceRejected "Tray tmux UI accepted unsafe custom key syntax."
$invalidPairedTmuxBindingRejected = $false
try { Test-CtrlCcvRemoteTmuxBinding -Table root -Key 'C-v' -SecondaryTable root -SecondaryKey 'M-v;touch' | Out-Null } catch { $invalidPairedTmuxBindingRejected = $true }
Assert-CtrlCcvTray $invalidPairedTmuxBindingRejected "Tray tmux helper accepted unsafe paired shortcut syntax."
Assert-CtrlCcvTray ((Get-CtrlCcvTrayTmuxStartupLine) -eq 'run-shell ~/.local/lib/ctrl-ccv/tmux/ctrl-ccv.tmux') "Tray tmux UI no longer exposes the user-owned startup line."

# Remote tmux work must be collected without blocking the UI event handler,
# then removed promptly; exercise that boundary with a harmless local job so
# this test never opens SSH or touches a tmux server.
$tmuxAsyncJob = Start-Job -ScriptBlock { [pscustomobject]@{ Ok = $true; Detail = 'synthetic tmux state' } }
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($tmuxAsyncJob.State -notin @('Completed', 'Failed', 'Stopped', 'Disconnected') -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    $tmuxAsyncResult = Receive-CtrlCcvTrayTmuxRemoteJob -Job $tmuxAsyncJob
    Assert-CtrlCcvTray ($tmuxAsyncResult.Completed -and $tmuxAsyncResult.Ok -and $tmuxAsyncResult.Result.Ok) "Tray tmux async job completion was not collected safely."
    Assert-CtrlCcvTray ($null -eq (Get-Job -Id $tmuxAsyncJob.Id -ErrorAction SilentlyContinue)) "Tray tmux async job was not removed after completion."
}
finally {
    Remove-Job -Job $tmuxAsyncJob -Force -ErrorAction SilentlyContinue
}

$tmuxCancelledJob = Start-Job -ScriptBlock { Start-Sleep -Seconds 30 }
try {
    $deadline = (Get-Date).AddSeconds(10)
    while ($tmuxCancelledJob.State -eq 'NotStarted' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Stop-CtrlCcvTrayTmuxRemoteJob -Job $tmuxCancelledJob
    Assert-CtrlCcvTray ($null -eq (Get-Job -Id $tmuxCancelledJob.Id -ErrorAction SilentlyContinue)) "Tray tmux async job was not removed after cancellation."
}
finally {
    Remove-Job -Job $tmuxCancelledJob -Force -ErrorAction SilentlyContinue
}

# The tray must render only an allowlisted helper token. Exercise the exact
# bounded pipe/receiver contract with harmless local child PowerShells; no SSH
# command, clipboard, settings, or remote file is touched.
function Start-CtrlCcvTrayTestConnectionProcess {
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
    Assert-CtrlCcvTray $process.Start() 'Synthetic tray connection-check process did not start.'
    $stdoutSink = New-Object -TypeName CtrlCcvBoundedOutput -ArgumentList 4096
    $stderrSink = New-Object -TypeName CtrlCcvBoundedOutput -ArgumentList 4096
    return [pscustomobject]@{
        Process = $process
        StdOutSink = $stdoutSink
        StdErrSink = $stderrSink
        StdOutTask = $stdoutSink.PumpAsync($process.StandardOutput)
        StdErrTask = $stderrSink.PumpAsync($process.StandardError)
    }
}

$connectionOperation = Start-CtrlCcvTrayTestConnectionProcess -Script '[Console]::Out.Write('' {"Version":1,"FailureKind":"connected"} ''.Trim())'
try {
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $connectionAsyncResult = Receive-CtrlCcvTraySshConnectionCheckProcess -Operation $connectionOperation
        if (-not $connectionAsyncResult.Completed) { Start-Sleep -Milliseconds 50 }
    } while (-not $connectionAsyncResult.Completed -and (Get-Date) -lt $deadline)
    Assert-CtrlCcvTray ($connectionAsyncResult.Completed -and $connectionAsyncResult.Result.Ok -and $connectionAsyncResult.Result.FailureKind -eq 'connected') "Tray connection-check process completion was not collected safely."
    Assert-CtrlCcvTray ($null -eq $connectionOperation.Process) "Tray connection-check process was not disposed after completion."
}
finally {
    Stop-CtrlCcvTraySshConnectionCheckProcess -Operation $connectionOperation
}

$unsafeConnectionOperation = Start-CtrlCcvTrayTestConnectionProcess -Script '[Console]::Error.Write("https://example.test/?token=synthetic-secret"); [Console]::Out.Write(''{"Version":1,"FailureKind":"connected"}'')'
try {
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $unsafeConnectionResult = Receive-CtrlCcvTraySshConnectionCheckProcess -Operation $unsafeConnectionOperation
        if (-not $unsafeConnectionResult.Completed) { Start-Sleep -Milliseconds 50 }
    } while (-not $unsafeConnectionResult.Completed -and (Get-Date) -lt $deadline)
    $unsafeConnectionText = "$($unsafeConnectionResult.Result.Summary) $($unsafeConnectionResult.Result.Detail) $($unsafeConnectionResult.Result.NextStep)"
    Assert-CtrlCcvTray ($unsafeConnectionResult.Completed -and $unsafeConnectionResult.Result.FailureKind -eq 'check-unavailable') "Tray accepted a helper response with untrusted stderr."
    Assert-CtrlCcvTray ($unsafeConnectionText -notmatch 'synthetic-secret|example\.test') "Tray exposed untrusted helper output."
}
finally {
    Stop-CtrlCcvTraySshConnectionCheckProcess -Operation $unsafeConnectionOperation
}

$cancelledConnectionOperation = Start-CtrlCcvTrayTestConnectionProcess -Script 'Start-Sleep -Seconds 30'
$cancelledConnectionProcessId = $cancelledConnectionOperation.Process.Id
Stop-CtrlCcvTraySshConnectionCheckProcess -Operation $cancelledConnectionOperation
Start-Sleep -Milliseconds 200
Assert-CtrlCcvTray ($null -eq $cancelledConnectionOperation.Process -and -not (Get-Process -Id $cancelledConnectionProcessId -ErrorAction SilentlyContinue)) "Cancelling the tray connection check left its owned process running."

$healthyStyle = Get-CtrlCcvTrayStatusStyle -Level "Healthy"
$warningStyle = Get-CtrlCcvTrayStatusStyle -Level "Warning"
Assert-CtrlCcvTray ($healthyStyle.Badge -eq "Healthy" -and $healthyStyle.Accent -match '^#') "Healthy state no longer has a usable visual style."
Assert-CtrlCcvTray ($warningStyle.Badge -eq "Needs attention" -and $warningStyle.Surface -match '^#') "Warning state no longer has a usable visual style."
Assert-CtrlCcvTray ((Get-CtrlCcvTrayRelativeTimeText -AgeSeconds 0) -eq "Just now") "Fresh heartbeat display is incorrect."
Assert-CtrlCcvTray ((Get-CtrlCcvTrayRelativeTimeText -AgeSeconds 61) -eq "1 min ago") "Minute heartbeat display is incorrect."
Assert-CtrlCcvTray ((Get-CtrlCcvTrayRelativeTimeText -AgeSeconds $null) -eq "Waiting for first heartbeat") "Missing heartbeat display is incorrect."
$redactedDashboardText = ConvertTo-CtrlCcvTrayDisplayText -Text 'Bearer a-secret-token password=hunter2' -MaximumLength 80
Assert-CtrlCcvTray ($redactedDashboardText -notmatch 'a-secret-token|hunter2') "Dashboard display text failed to redact a credential-like detail."
Assert-CtrlCcvTray ($traySource.Contains('$trayIconSelection = Get-CtrlCcvTrayIcon')) "Tray no longer uses the safe branded-icon loader."
$brandedIconPath = Get-CtrlCcvTrayIconAssetPath
Assert-CtrlCcvTray (Test-Path -LiteralPath $brandedIconPath -PathType Leaf) "The checked-in branded tray icon is missing."
$brandedIcon = Get-CtrlCcvTrayIcon
try {
    Assert-CtrlCcvTray (-not $brandedIcon.IsFallback -and $brandedIcon.OwnsIcon -and $brandedIcon.Source -eq 'project asset') "The checked-in branded tray icon did not load."
    Assert-CtrlCcvTray ($brandedIcon.Icon.Width -ge 16 -and $brandedIcon.Icon.Height -ge 16) "The checked-in branded tray icon is too small."
}
finally {
    if ($brandedIcon -and $brandedIcon.OwnsIcon -and $brandedIcon.Icon) { $brandedIcon.Icon.Dispose() }
}
$brandedLogoPath = Get-CtrlCcvTrayLogoAssetPath
Assert-CtrlCcvTray (Test-Path -LiteralPath $brandedLogoPath -PathType Leaf) "The checked-in branded dashboard logo is missing."
$brandedLogo = Get-CtrlCcvTrayLogo
try {
    Assert-CtrlCcvTray ($null -ne $brandedLogo -and $brandedLogo.Width -ge 32 -and $brandedLogo.Height -ge 32) "The checked-in branded dashboard logo did not load."
}
finally {
    if ($brandedLogo) { $brandedLogo.Dispose() }
}

$tempRoot = Join-Path $env:TEMP ("ctrl-ccv-tray-test-{0}" -f [Guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $validVersionFile = Join-Path $tempRoot 'VERSION'
    [IO.File]::WriteAllText($validVersionFile, "1.2.3-beta.1+build.5`n", [Text.UTF8Encoding]::new($false))
    Assert-CtrlCcvTray ((Get-CtrlCcvTrayInstalledVersion -VersionFile $validVersionFile) -eq '1.2.3-beta.1+build.5') "Tray did not read a valid bundled SemVer version."
    $invalidVersionFile = Join-Path $tempRoot 'invalid-VERSION'
    [IO.File]::WriteAllText($invalidVersionFile, "version=secret`n", [Text.UTF8Encoding]::new($false))
    Assert-CtrlCcvTray ((Get-CtrlCcvTrayInstalledVersion -VersionFile $invalidVersionFile) -eq 'unknown') "Tray displayed malformed VERSION content."
    Assert-CtrlCcvTray ((Get-CtrlCcvTrayUpdateMenuText -InstalledVersion '1.2.3-beta.1') -eq 'Get latest version... (v1.2.3-beta.1)') "Tray update label did not include a valid installed version."
    Assert-CtrlCcvTray ((Get-CtrlCcvTrayUpdateMenuText -InstalledVersion 'unknown') -eq 'Get latest version... (version unavailable)') "Tray update label displayed an unavailable installed version unsafely."

    # Exercise the Settings persistence boundary in a fresh process so its
    # module-level CTRL_CCV_CONFIG selection cannot touch a real customer file.
    # The tray UI itself stubs these helpers in the STA probe below; this test
    # confirms the actual helper pair accepts a customer edit and writes only
    # data-only persisted fields.
    $persistenceConfigPath = Join-Path $tempRoot 'settings-config.psd1'
    $previousConfigPath = $env:CTRL_CCV_CONFIG
    $previousCoreRoot = $env:CTRL_CCV_TEST_CORE_ROOT
    try {
        $env:CTRL_CCV_CONFIG = $persistenceConfigPath
        $env:CTRL_CCV_TEST_CORE_ROOT = $root
        $persistenceScript = @'
$ErrorActionPreference = 'Stop'
Remove-Item Env:CTRL_CCV_HOST_ALIAS -ErrorAction SilentlyContinue
Remove-Item Env:CTRL_CCV_REMOTE_DIR -ErrorAction SilentlyContinue
Remove-Item Env:CTRL_CCV_REMOTE_HOME -ErrorAction SilentlyContinue
. (Join-Path $env:CTRL_CCV_TEST_CORE_ROOT 'ctrl-ccv-core.ps1')

$before = Get-CtrlCcvEditableConfig
if ($before.Exists -or $before.LoadError) { throw 'Fresh Settings test configuration was not empty and readable.' }
$draft = [ordered]@{
    HostAlias = 'settings-host'
    RemoteDir = 'settings-images'
    RemoteHome = '/home/settings'
    DataRoot = (Join-Path (Split-Path $env:CTRL_CCV_CONFIG -Parent) 'settings-data')
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
$saved = Save-CtrlCcvConfig -Config $draft
if (-not $saved.Exists -or $saved.HostAlias -ne 'settings-host' -or $saved.RemoteDir -ne 'settings-images') {
    throw 'Settings persistence did not return the saved editable values.'
}
$data = Import-PowerShellDataFile -LiteralPath $env:CTRL_CCV_CONFIG
if ($data.Keys.Count -ne 13 -or $data.HostAlias -ne 'settings-host' -or $data.Contains('Path') -or $data.Contains('ConfigError')) {
    throw 'Settings persistence did not write exactly the data-only editable fields.'
}
$unknownRejected = $false
try { Save-CtrlCcvConfig -Config ([ordered]@{ NotASetting = 'nope' }) } catch { $unknownRejected = $true }
if (-not $unknownRejected) { throw 'Settings persistence accepted an unknown field.' }
$env:CTRL_CCV_HOST_ALIAS = 'session-host'
$withOverride = Get-CtrlCcvEditableConfig
if (-not $withOverride.HasEnvironmentOverrides -or $withOverride.HostAlias -ne 'settings-host' -or $withOverride.EnvironmentOverrides -notcontains 'CTRL_CCV_HOST_ALIAS') {
    throw 'Settings persistence did not report an environment override without persisting it.'
}
if ((Get-CtrlCcvConfig).HostAlias -ne 'session-host') { throw 'Runtime configuration did not retain its documented environment override.' }
'@
        $encodedPersistenceScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($persistenceScript))
        $persistenceOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedPersistenceScript 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Settings persistence child test failed: $($persistenceOutput | Out-String)"
        }
    }
    finally {
        if ($null -eq $previousConfigPath) { Remove-Item Env:CTRL_CCV_CONFIG -ErrorAction SilentlyContinue } else { $env:CTRL_CCV_CONFIG = $previousConfigPath }
        if ($null -eq $previousCoreRoot) { Remove-Item Env:CTRL_CCV_TEST_CORE_ROOT -ErrorAction SilentlyContinue } else { $env:CTRL_CCV_TEST_CORE_ROOT = $previousCoreRoot }
    }

    $missingIcon = Get-CtrlCcvTrayIcon -IconPath (Join-Path $tempRoot 'missing.ico')
    Assert-CtrlCcvTray ($missingIcon.IsFallback -and -not $missingIcon.OwnsIcon -and $missingIcon.Reason -eq 'missing') "A missing tray icon did not use the system fallback."
    Assert-CtrlCcvTray ($null -eq (Get-CtrlCcvTrayLogo -LogoPath (Join-Path $tempRoot 'missing.png'))) "A missing dashboard logo did not fail closed."

    $corruptIconPath = Join-Path $tempRoot 'corrupt.ico'
    [IO.File]::WriteAllText($corruptIconPath, 'not an icon', [Text.UTF8Encoding]::new($false))
    $corruptIcon = Get-CtrlCcvTrayIcon -IconPath $corruptIconPath
    Assert-CtrlCcvTray ($corruptIcon.IsFallback -and -not $corruptIcon.OwnsIcon) "A corrupt tray icon did not use the system fallback."

    $oversizedIconPath = Join-Path $tempRoot 'oversized.ico'
    $oversizedStream = [IO.File]::Open($oversizedIconPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $oversizedStream.SetLength((1MB) + 1) }
    finally { $oversizedStream.Dispose() }
    $oversizedIcon = Get-CtrlCcvTrayIcon -IconPath $oversizedIconPath
    Assert-CtrlCcvTray ($oversizedIcon.IsFallback -and -not $oversizedIcon.OwnsIcon -and $oversizedIcon.Reason -eq 'invalid-file') "An oversized tray icon did not fail closed before parsing."

    $shortcutPath = Join-Path $tempRoot "ctrl-ccv-tray.lnk"
    $trayScript = [IO.Path]::GetFullPath((Join-Path $root "ctrl-ccv-tray.ps1"))
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-NoProfile -STA -File `"$trayScript`""
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = "Managed by ctrl-ccv install-tray.ps1"
    $shortcut.Save()
    Assert-CtrlCcvTray (Test-CtrlCcvTrayShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $trayScript -WorkingDirectory $root) "A marked exact tray shortcut was not recognized."
    $shortcut.Description = "Unrelated shortcut"
    $shortcut.Save()
    Assert-CtrlCcvTray (-not (Test-CtrlCcvTrayShortcutOwnership -ShortcutPath $shortcutPath -ScriptPath $trayScript -WorkingDirectory $root)) "An unrelated named shortcut was accepted."

    $script:trayTestConfig = @{
        HostAlias = "example-host"; RemoteDir = "clipboard-images"; RemoteHome = "/home/tester"; DataRoot = $tempRoot
        LocalCache = (Join-Path $tempRoot "cache"); StateFile = (Join-Path $tempRoot "last-hash.txt")
        LastRemotePathFile = (Join-Path $tempRoot "last-remote-path.txt"); LogFile = (Join-Path $tempRoot "watch.log")
        UploadStatusFile = (Join-Path $tempRoot "upload-status.txt")
        HeartbeatFile = (Join-Path $tempRoot "watch.heartbeat"); CommandTimeoutSeconds = 35; MaxCommandOutputBytes = 65536
        PollIntervalSeconds = 2; WatchdogCheckSeconds = 15; WatchdogStaleSeconds = 120
        MaxLogBytes = 1048576; MaxCacheFiles = 200; MaxCacheBytes = 268435456; MaxImageBytes = 52428800; ConfigError = ""
    }
    function Get-CtrlCcvConfig { return $script:trayTestConfig }
    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.LastRemotePathFile -Value "/home/tester/clipboard-images/latest.png"

    $missingActivity = Get-CtrlCcvTrayRecentActivityText -Config @{ LogFile = (Join-Path $tempRoot 'missing-watch.log') }
    Assert-CtrlCcvTray ($missingActivity -eq 'No local activity has been recorded yet.') "Missing activity log did not produce a safe empty-state message."
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
    $recentActivity = Get-CtrlCcvTrayRecentActivityText -Config $script:trayTestConfig -MaximumLines 3 -MaximumBytes 1024
    $recentLines = @($recentActivity -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-CtrlCcvTray ($recentLines.Count -eq 3) "Recent activity did not honor its maximum record count."
    Assert-CtrlCcvTray ($recentActivity -match 'activity 106' -and $recentActivity -match 'activity final') "Recent activity did not retain the bounded log tail."
    Assert-CtrlCcvTray ($recentActivity -notmatch 'a-secret-token|hunter2') "Recent activity exposed credential-like log detail."

    $script:trayProbeMode = "healthy"
    function Get-CtrlCcvTrayProcessProbe {
        param([string]$ScriptPath)
        if ($script:trayProbeMode -eq "unavailable") {
            return [pscustomobject]@{ Available = $false; Processes = @(); Error = "simulated inspection failure" }
        }
        $fakeProcessId = if ($ScriptPath -match "guardian") { 1111 } else { 4242 }
        $processes = if ($script:trayProbeMode -eq "guardian-only" -and $ScriptPath -notmatch "guardian") { @() } else { @([pscustomobject]@{ ProcessId = $fakeProcessId }) }
        return [pscustomobject]@{ Available = $true; Processes = $processes; Error = "" }
    }

    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=0" -f (Get-Date).ToUniversalTime().ToString("o"))
    $healthy = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($healthy.Level -eq "Healthy") "A matching fresh heartbeat was not healthy."
    Assert-CtrlCcvTray ($healthy.LatestPath -eq "/home/tester/clipboard-images/latest.png") "Tray did not read the validated latest path."
    Assert-CtrlCcvTray ($null -ne $healthy.LatestUploadAt -and $null -ne $healthy.LatestUploadAgeSeconds -and $healthy.LatestUploadAgeSeconds -lt 5) "Tray did not derive a fresh successful-upload time from its validated state file."
    Assert-CtrlCcvTray ((Get-CtrlCcvTrayLatestUploadText -State $healthy) -match '^Uploaded ') "Tray did not expose a safe latest-upload status."
    $tooltip = Get-CtrlCcvTrayTooltip -State $healthy
    Assert-CtrlCcvTray ($tooltip.Length -le 63) "NotifyIcon tooltip exceeded its Windows length limit."
    Assert-CtrlCcvTray ($tooltip -match 'uploaded') "Healthy tray tooltip did not report the latest successful upload."
    Assert-CtrlCcvTray ($tooltip -notmatch "example-host|clipboard-images") "NotifyIcon tooltip exposed local configuration/path details."

    $script:trayProbeMode = "guardian-only"
    $recovering = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($recovering.Level -eq "Warning" -and $recovering.IssueKind -eq "Service" -and $recovering.Summary -match "Automatic uploads are restarting" -and (Get-CtrlCcvTrayGuidance -State $recovering) -match "Refresh status") "A guardian-only startup state did not explain that automatic uploads are recovering."
    $script:trayProbeMode = "healthy"

    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.UploadStatusFile -Value ("{0} result=failed reason=ssh-mkdir-connect-timeout" -f (Get-Date).ToUniversalTime().ToString("o"))
    $uploadFailure = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($uploadFailure.Level -eq "Warning" -and $uploadFailure.IssueKind -eq "Upload") "A persisted upload failure was not surfaced as an upload-specific warning."
    Assert-CtrlCcvTray ($uploadFailure.Summary -match "SSH upload connection timed out") "An unattended SSH timeout did not receive a clear summary."
    Assert-CtrlCcvTray ($uploadFailure.Detail -match "SSH greeting") "The tray did not expose the safe, actionable handshake stage."
    Assert-CtrlCcvTray (Test-CtrlCcvTraySshConnectionIssue -State $uploadFailure) "An early SSH failure did not enable the connection-specific recovery path."
    $connectionGuide = Get-CtrlCcvTraySshTroubleshooting -State $uploadFailure
    Assert-CtrlCcvTray ($connectionGuide.Title -match "unattended SSH check" -and $connectionGuide.WhatHappened -match "terminal session can still work") "The tray did not explain the difference between an unattended SSH attempt and an interactive terminal session."
    Assert-CtrlCcvTray ($connectionGuide.Steps -match "Test unattended SSH" -and $connectionGuide.Steps -match "Retry clipboard upload") "The connection assistant did not provide a complete customer recovery path."
    Assert-CtrlCcvTray (("$($connectionGuide.Title) $($connectionGuide.Summary) $($connectionGuide.WhatHappened) $($connectionGuide.Steps) $($connectionGuide.SupportCode)") -notmatch "example-host|clipboard-images|/home/tester") "Connection guidance exposed private configuration or remote-path data."
    Assert-CtrlCcvTray ((Get-CtrlCcvTrayGuidance -State $uploadFailure) -match "Connection help") "An SSH upload warning did not direct the customer to the guided connection action."
    $failureTooltip = Get-CtrlCcvTrayTooltip -State $uploadFailure
    Assert-CtrlCcvTray ($failureTooltip -eq 'ctrl-ccv: Service running - SSH needs attention' -and $failureTooltip.Length -le 63 -and $failureTooltip -notmatch "example-host|clipboard-images") "Upload-failure tooltip was not bounded, private, and clear about local-service health."

    $authFailure = $uploadFailure.PSObject.Copy()
    $authFailure.UploadFailureReason = 'ssh-mkdir-auth-failed'
    $authFailureGuide = Get-CtrlCcvTraySshTroubleshooting -State $authFailure
    Assert-CtrlCcvTray ($authFailureGuide.Title -match 'sign-in' -and $authFailureGuide.WhatHappened -match 'one-time-code' -and $authFailureGuide.Steps -match 'never asks for, stores, or pastes a code') "The authentication walkthrough did not safely explain MFA-style prompts."

    $remoteFolderIssue = Get-CtrlCcvTrayUploadIssue -FailureReason 'ssh-mkdir-remote-folder-failed'
    Assert-CtrlCcvTray ($remoteFolderIssue.Summary -match 'Remote upload folder' -and $remoteFolderIssue.Detail -match 'reached the SSH target') "Remote upload-folder permission failures were not distinguished from sign-in failures."
    $remoteFolderState = $uploadFailure.PSObject.Copy()
    $remoteFolderState.UploadFailureReason = 'ssh-mkdir-remote-folder-failed'
    Assert-CtrlCcvTray (-not (Test-CtrlCcvTraySshConnectionIssue -State $remoteFolderState)) "A remote upload-folder permission failure incorrectly opens the connection-only assistant."
    Assert-CtrlCcvTray ((Get-CtrlCcvTrayGuidance -State $remoteFolderState) -match 'remote image folder') "A remote upload-folder permission failure did not direct the customer to the relevant setting or administrator."

    # Make state ordering explicit rather than relying on clock resolution: a
    # newer watcher retry must supersede an older confirmed one-shot upload,
    # while a later confirmed upload must clear that retry warning.
    $confirmedUploadAt = (Get-Date).ToUniversalTime().AddSeconds(-10)
    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.UploadStatusFile -Value ("{0} result=succeeded" -f $confirmedUploadAt.ToString("o"))
    $recovered = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($recovered.Level -eq "Healthy" -and $recovered.IssueKind -eq "") "A confirmed successful upload did not clear the upload warning."

    $retryHeartbeatAt = $confirmedUploadAt.AddSeconds(5)
    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=2" -f $retryHeartbeatAt.ToString("o"))
    $legacyRetry = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($legacyRetry.Level -eq "Warning" -and $legacyRetry.IssueKind -eq "Upload" -and $legacyRetry.UploadFailureCount -eq 2) "A retrying legacy watcher heartbeat did not fail visibly."

    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=2" -f $retryHeartbeatAt.AddSeconds(-2).ToString("o"))
    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.UploadStatusFile -Value ("{0} result=succeeded" -f $retryHeartbeatAt.AddSeconds(1).ToString("o"))
    $manualRecovery = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($manualRecovery.Level -eq "Healthy" -and $manualRecovery.UploadFailureCount -eq 0) "A newer confirmed manual retry did not clear an older watcher retry warning."

    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=4242 idle failures=0" -f (Get-Date).ToUniversalTime().AddSeconds(-121).ToString("o"))
    $stale = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($stale.Level -eq "Warning" -and $stale.Summary -match "stale") "A stale heartbeat was not surfaced as a warning."

    Set-CtrlCcvAtomicText -Path $script:trayTestConfig.HeartbeatFile -Value ("{0} pid=9999 idle failures=0" -f (Get-Date).ToUniversalTime().ToString("o"))
    $wrongPid = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($wrongPid.Level -eq "Warning" -and $wrongPid.Summary -match "another process") "A mismatched heartbeat PID was not surfaced as a warning."

    $script:trayProbeMode = "unavailable"
    $unknown = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($unknown.Level -eq "Unknown" -and $unknown.Summary -match "Cannot inspect") "Process-inspection failure did not fail closed."

    $script:trayProbeMode = "healthy"
    $script:trayTestConfig.ConfigError = "HostAlias is required."
    $configError = Get-CtrlCcvTrayState
    Assert-CtrlCcvTray ($configError.Level -eq "Error" -and $configError.Summary -match "Configuration") "Invalid configuration did not take priority in tray status."
}
finally {
    Remove-Item -Path Function:\Get-CtrlCcvConfig -ErrorAction SilentlyContinue
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
