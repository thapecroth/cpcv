# Exercises the real WinForms status dialog on an STA thread, with every
# side-effecting action stubbed.  It does not create a NotifyIcon, inspect
# processes, access the clipboard, start services, or touch real state files.
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'test-tray-ui.ps1 must be launched with powershell.exe -STA.'
}

function Assert-CtrlCcvTrayUi([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ctrl-ccv-tray.ps1') -NoRun
Add-Type -AssemblyName System.Windows.Forms

$script:trayUiAction = ''
function Start-CtrlCcvTrayUpload { $script:trayUiAction = 'upload' }
function Start-CtrlCcvTrayGuardian { $script:trayUiAction = 'start'; return $true }
$script:trayUiRestartFails = $false
function Restart-CtrlCcvTrayService {
    if ($script:trayUiRestartFails) { throw 'synthetic restart failure' }
    $script:trayUiAction = 'restart'
}
function Open-CtrlCcvTrayReleasePage { $script:trayUiAction = 'update' }
function Show-CtrlCcvTrayError { param([string]$Message) throw "Unexpected tray UI error: $Message" }
function Get-CtrlCcvTrayState { return $script:trayUiCurrentState }

function Invoke-CtrlCcvTrayDialogProbe {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][ValidateSet('upload', 'update', 'start', 'close')][string]$Action,
        [switch]$ExpectUploadDisabled,
        [switch]$ExpectServiceDisabled,
        [Nullable[bool]]$ExpectedConnectionVisible = $null,
        [string]$ExpectedUploadText = '',
        [string]$ExpectedServiceText = ''
    )

    $script:trayUiDialogSeen = $false
    $script:trayUiAction = ''
    $script:trayUiCurrentState = $State
    $script:trayUiProbeCompleted = $false
    $script:trayUiProbeFailure = ''
    # This deadline is intentionally enforced inside the STA message loop so
    # a stale selector, control-construction exception, or changed dialog title
    # cannot leave a hidden test window running indefinitely.
    $deadline = (Get-Date).AddSeconds(6)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'ctrlCcvTrayStatusDashboard' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) {
                throw 'Status dashboard probe exceeded its six-second deadline.'
            }
            if ($script:trayUiProbeCompleted) { return }

            $script:trayUiDialogSeen = $true
            $script:trayUiProbeCompleted = $true
            $upload = @($form.Controls.Find('ctrlCcvTrayUploadButton', $true)) | Select-Object -First 1
            $service = @($form.Controls.Find('ctrlCcvTrayServiceButton', $true)) | Select-Object -First 1
            $connection = @($form.Controls.Find('ctrlCcvTrayConnectionHelpButton', $true)) | Select-Object -First 1
            $actionFeedback = @($form.Controls.Find('ctrlCcvTrayActionFeedback', $true)) | Select-Object -First 1
            $update = @($form.Controls.Find('ctrlCcvTrayUpdateButton', $true)) | Select-Object -First 1
            $subtitle = @($form.Controls.Find('ctrlCcvTraySubtitle', $true)) | Select-Object -First 1
            $banner = @($form.Controls.Find('ctrlCcvTrayStatusBanner', $true)) | Select-Object -First 1
            $logo = @($form.Controls.Find('ctrlCcvTrayBrandLogo', $true)) | Select-Object -First 1
            Assert-CtrlCcvTrayUi ($null -ne $upload) 'Status dashboard did not construct the one-shot upload button.'
            Assert-CtrlCcvTrayUi ($null -ne $service) 'Status dashboard did not construct the service action button.'
            Assert-CtrlCcvTrayUi ($null -ne $connection) 'Status dashboard did not construct the connection-assistant button.'
            Assert-CtrlCcvTrayUi ($null -ne $actionFeedback) 'Status dashboard did not construct its action guidance text.'
            Assert-CtrlCcvTrayUi ($null -ne $update -and $update.Text -eq 'Get latest version...') 'Status dashboard did not construct its explicit update action.'
            Assert-CtrlCcvTrayUi ($null -ne $subtitle -and $subtitle.Text -match 'Installed v[0-9]+\.[0-9]+\.[0-9]+') 'Status dashboard did not show the installed ctrl-ccv version.'
            Assert-CtrlCcvTrayUi ($null -ne $banner) 'Status dashboard did not construct its health banner.'
            Assert-CtrlCcvTrayUi ($null -ne $logo -and $null -ne $logo.Image) 'Status dashboard did not construct the branded logo.'
            if ($ExpectedUploadText) { Assert-CtrlCcvTrayUi ($upload.Text -eq $ExpectedUploadText) "Status dashboard upload action was '$($upload.Text)', not '$ExpectedUploadText'." }
            if ($ExpectedServiceText) { Assert-CtrlCcvTrayUi ($service.Text -eq $ExpectedServiceText) "Status dashboard service action was '$($service.Text)', not '$ExpectedServiceText'." }
            if ($null -ne $ExpectedConnectionVisible) { Assert-CtrlCcvTrayUi ($connection.Visible -eq [bool]$ExpectedConnectionVisible) "Status dashboard connection action visibility did not match the upload failure stage." }
            if ($connection.Visible) {
                $form.Width = $form.MinimumSize.Width
                $form.PerformLayout()
                Assert-CtrlCcvTrayUi ($connection.Right -le $connection.Parent.ClientSize.Width) 'Connection help action is clipped at the dashboard minimum width.'
                Assert-CtrlCcvTrayUi ($actionFeedback.Left -ge $connection.Right -and $actionFeedback.Right -le $actionFeedback.Parent.ClientSize.Width) 'Connection guidance does not reflow beside the action at the dashboard minimum width.'
            }
            if ($ExpectServiceDisabled) { Assert-CtrlCcvTrayUi (-not $service.Enabled) 'SSH upload failure left the local-service restart action enabled.' }
            if ($ExpectUploadDisabled) {
                Assert-CtrlCcvTrayUi (-not $upload.Enabled) 'Error-state dashboard left the upload action enabled.'
                return
            }
            Assert-CtrlCcvTrayUi $upload.Enabled 'Non-error dashboard unexpectedly disabled one-shot upload.'
            switch ($Action) {
                'upload' { $upload.PerformClick() }
                'update' { $update.PerformClick() }
                'start' { $service.PerformClick() }
            }
        }
        catch {
            $script:trayUiProbeFailure = $_.Exception.Message
        }
        finally {
            if (-not $form.IsDisposed) { $form.Close() }
        }
    })
    try {
        $timer.Start()
        Show-CtrlCcvTrayStatusWindow -State $State -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CtrlCcvTrayUi $script:trayUiDialogSeen 'Status dashboard was not shown before the UI probe deadline.'
    Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiProbeFailure)) "Status dashboard probe failed: $($script:trayUiProbeFailure)"
}

$baseState = [pscustomobject]@{
    Level = 'Healthy'
    Summary = 'ctrl-ccv is running'
    Detail = 'idle failures=0'
    Config = [pscustomobject]@{ DataRoot = (Join-Path $env:TEMP 'ctrl-ccv-tray-ui-test') }
    Guardians = @([pscustomobject]@{ ProcessId = 101 })
    Watchers = @([pscustomobject]@{ ProcessId = 202 })
    GuardianProbeAvailable = $true
    WatcherProbeAvailable = $true
    Heartbeat = [pscustomobject]@{ ProcessId = 202; Status = 'idle failures=0'; FailureCount = 0 }
    HeartbeatAgeSeconds = 1.2
    IssueKind = ''
    UploadFailureCount = 0
    UploadFailureReason = ''
    LatestPath = '/home/tester/clipboard-images/latest.png'
    LatestUploadAt = [DateTimeOffset]::UtcNow
    LatestUploadAgeSeconds = 1.2
}

Invoke-CtrlCcvTrayDialogProbe -State $baseState -Action upload
Assert-CtrlCcvTrayUi ($script:trayUiAction -eq 'upload') 'Upload button did not invoke its protected action handler.'

Invoke-CtrlCcvTrayDialogProbe -State $baseState -Action update
Assert-CtrlCcvTrayUi ($script:trayUiAction -eq 'update') 'Dashboard update action did not invoke the official release-page handoff.'

$retryState = $baseState.PSObject.Copy()
$retryState.Level = 'Warning'
$retryState.Summary = 'Background SSH connection timed out'
$retryState.Detail = 'ctrl-ccv will retry automatically when it sees an image in the clipboard.'
$retryState.IssueKind = 'Upload'
$retryState.UploadFailureCount = 2
$retryState.UploadFailureReason = 'ssh-mkdir-timeout'
$retryState.Heartbeat = [pscustomobject]@{ ProcessId = 202; Status = 'idle failures=2'; FailureCount = 2 }
Invoke-CtrlCcvTrayDialogProbe -State $retryState -Action upload -ExpectedUploadText 'Retry clipboard upload' -ExpectedServiceText 'Service is running' -ExpectServiceDisabled -ExpectedConnectionVisible $true
Assert-CtrlCcvTrayUi ($script:trayUiAction -eq 'upload') 'Upload-retry dashboard did not invoke its protected retry action.'

# Exercise the real connection assistant off-screen. Its connection check is
# replaced with a controlled result so this test cannot contact SSH, change a
# remote file, or touch the real clipboard.
$script:trayUiConnectionCheckCount = 0
$script:trayUiOriginalConnectionCheck = (Get-Command Get-CtrlCcvSshConnectionCheckResult -CommandType Function).ScriptBlock
$script:trayUiOriginalSettingsWindow = (Get-Command Show-CtrlCcvTraySettingsWindow -CommandType Function).ScriptBlock
function Get-CtrlCcvSshConnectionCheckResult {
    $script:trayUiConnectionCheckCount++
    return [pscustomobject]@{
        Ok = $true; FailureKind = 'connected'; Summary = 'Unattended SSH check passed'
        Detail = 'ctrl-ccv started a new unattended SSH process using its upload settings and did not change any remote files.'
        NextStep = 'Retry the clipboard upload.'
    }
}
$script:trayUiConnectionSettingsCount = 0
function Show-CtrlCcvTraySettingsWindow {
    $script:trayUiConnectionSettingsCount++
    return $true
}
function Invoke-CtrlCcvTrayConnectionAssistantProbe {
    param([Parameter(Mandatory)]$State)

    $script:trayUiConnectionDialogSeen = $false
    $script:trayUiConnectionProbeFailure = ''
    $script:trayUiConnectionProbeStage = 0
    $script:trayUiAction = ''
    $deadline = (Get-Date).AddSeconds(6)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'ctrlCcvTrayConnectionHelpWindow' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) { throw 'Connection assistant probe exceeded its six-second deadline.' }
            $script:trayUiConnectionDialogSeen = $true
            $test = @($form.Controls.Find('ctrlCcvTrayConnectionTestButton', $true)) | Select-Object -First 1
            $settings = @($form.Controls.Find('ctrlCcvTrayConnectionSettingsButton', $true)) | Select-Object -First 1
            $retry = @($form.Controls.Find('ctrlCcvTrayConnectionRetryButton', $true)) | Select-Object -First 1
            $issue = @($form.Controls.Find('ctrlCcvTrayConnectionHelpIssueDetail', $true)) | Select-Object -First 1
            $resultTitle = @($form.Controls.Find('ctrlCcvTrayConnectionCheckTitle', $true)) | Select-Object -First 1
            $resultDetail = @($form.Controls.Find('ctrlCcvTrayConnectionCheckDetail', $true)) | Select-Object -First 1
            $support = @($form.Controls.Find('ctrlCcvTrayConnectionSupportCode', $true)) | Select-Object -First 1
            Assert-CtrlCcvTrayUi ($null -ne $test -and $null -ne $settings -and $null -ne $retry -and $null -ne $issue -and $null -ne $resultTitle -and $null -ne $resultDetail -and $null -ne $support) 'Connection assistant did not construct its safe diagnostic controls.'
            if ($script:trayUiConnectionProbeStage -eq 0) {
                Assert-CtrlCcvTrayUi ($issue.Text -match 'terminal session can still work') 'Connection assistant did not explain why an existing terminal session can differ from an unattended SSH check.'
                Assert-CtrlCcvTrayUi ($resultDetail.Text -match 'new unattended ctrl-ccv process' -and $resultDetail.Text -match 'does not use an open terminal process') 'Connection assistant did not accurately explain the unattended check boundary.'
                Assert-CtrlCcvTrayUi (-not $retry.Enabled) 'Connection assistant enabled upload retry before an unattended SSH check passed.'
                Assert-CtrlCcvTrayUi ($support.Text -match 'CTRL_CCV-SSH-COMMAND-TIMEOUT') 'Connection assistant did not expose a controlled support code.'
                $script:trayUiConnectionProbeStage = 1
                $test.PerformClick()
                return
            }
            if ($script:trayUiConnectionProbeStage -eq 1) {
                Assert-CtrlCcvTrayUi ($script:trayUiConnectionCheckCount -eq 1) 'Connection assistant did not run exactly one safe connection check.'
                Assert-CtrlCcvTrayUi ($resultTitle.Text -match 'Unattended SSH check passed' -and $resultDetail.Text -match 'did not change any remote files') 'Connection assistant did not render the controlled check result.'
                Assert-CtrlCcvTrayUi $retry.Enabled 'Connection assistant did not enable retry after a successful unattended SSH check.'
                $script:trayUiConnectionProbeStage = 2
                $settings.PerformClick()
                return
            }
            if ($script:trayUiConnectionProbeStage -eq 2) {
                Assert-CtrlCcvTrayUi ($script:trayUiConnectionSettingsCount -eq 1) 'Connection assistant did not open Settings after a successful check.'
                Assert-CtrlCcvTrayUi (-not $retry.Enabled) 'Connection assistant kept the old check valid after Settings saved a new connection configuration.'
                Assert-CtrlCcvTrayUi ($resultTitle.Text -match 'Settings saved' -and $resultDetail.Text -match 'Test unattended SSH again') 'Connection assistant did not require a new check after Settings changed.'
                $script:trayUiConnectionProbeStage = 3
                $test.PerformClick()
                return
            }
            Assert-CtrlCcvTrayUi ($script:trayUiConnectionCheckCount -eq 2) 'Connection assistant did not require a second safe check after Settings changed.'
            Assert-CtrlCcvTrayUi $retry.Enabled 'Connection assistant did not restore retry after the new unattended SSH check passed.'
            $script:trayUiConnectionProbeStage = 4
            $retry.PerformClick()
            Assert-CtrlCcvTrayUi ($script:trayUiAction -eq 'upload') 'Connection assistant retry did not invoke the protected one-shot upload action.'
        }
        catch {
            $script:trayUiConnectionProbeFailure = $_.Exception.Message
        }
        finally {
            if ($script:trayUiConnectionProbeStage -ge 4 -and -not $form.IsDisposed) { $form.Close() }
        }
    })
    try {
        $timer.Start()
        Show-CtrlCcvTrayConnectionHelpWindow -State $State -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CtrlCcvTrayUi $script:trayUiConnectionDialogSeen 'Connection assistant was not shown before the UI probe deadline.'
    Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiConnectionProbeFailure)) "Connection assistant probe failed: $($script:trayUiConnectionProbeFailure)"
}
Invoke-CtrlCcvTrayConnectionAssistantProbe -State $retryState
Set-Item -Path Function:\Get-CtrlCcvSshConnectionCheckResult -Value $script:trayUiOriginalConnectionCheck
Set-Item -Path Function:\Show-CtrlCcvTraySettingsWindow -Value $script:trayUiOriginalSettingsWindow

$stoppedState = $baseState.PSObject.Copy()
$stoppedState.Level = 'Stopped'
$stoppedState.Summary = 'The ctrl-ccv service is stopped'
$stoppedState.Guardians = @()
$stoppedState.Watchers = @()
$stoppedState.Heartbeat = $null
$stoppedState.HeartbeatAgeSeconds = $null
Invoke-CtrlCcvTrayDialogProbe -State $stoppedState -Action start
Assert-CtrlCcvTrayUi ($script:trayUiAction -eq 'start') 'Start-service button did not invoke its protected action handler.'

$errorState = $baseState.PSObject.Copy()
$errorState.Level = 'Error'
$errorState.Summary = 'Configuration needs attention'
Invoke-CtrlCcvTrayDialogProbe -State $errorState -Action close -ExpectUploadDisabled

$script:trayUiEditableConfig = [ordered]@{
    HostAlias = 'old-host'
    RemoteDir = 'clipboard-images'
    RemoteHome = '/home/tester'
    DataRoot = (Join-Path $env:TEMP 'ctrl-ccv-tray-ui-settings')
    CommandTimeoutSeconds = 35
    MaxCommandOutputBytes = 65536
    PollIntervalSeconds = 2
    WatchdogCheckSeconds = 15
    WatchdogStaleSeconds = 120
    MaxLogBytes = 1048576
    MaxCacheFiles = 200
    MaxCacheBytes = 268435456
    MaxImageBytes = 52428800
    Path = (Join-Path $env:TEMP 'ctrl-ccv-tray-ui-settings\config.psd1')
    Exists = $true
    HasEnvironmentOverrides = $true
    EnvironmentOverrides = @('CTRL_CCV_HOST_ALIAS')
    LoadError = ''
}
$script:trayUiSavedConfig = $null
function Get-CtrlCcvEditableConfig { return $script:trayUiEditableConfig }
function Save-CtrlCcvConfig {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) { $copy[[string]$key] = $Config[$key] }
    $script:trayUiSavedConfig = $copy
    return $script:trayUiEditableConfig
}

function Invoke-CtrlCcvTraySettingsDialogProbe {
    $script:trayUiSettingsDialogSeen = $false
    $script:trayUiSettingsProbeFailure = ''
    $script:trayUiAction = ''
    $deadline = (Get-Date).AddSeconds(6)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'ctrlCcvTraySettingsWindow' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) { throw 'Settings window probe exceeded its six-second deadline.' }
            if ($script:trayUiSettingsDialogSeen) { return }
            $script:trayUiSettingsDialogSeen = $true
            $hostAlias = @($form.Controls.Find('ctrlCcvTraySettingsHostAliasInput', $true)) | Select-Object -First 1
            $remoteDir = @($form.Controls.Find('ctrlCcvTraySettingsRemoteDirInput', $true)) | Select-Object -First 1
            $dataRoot = @($form.Controls.Find('ctrlCcvTraySettingsDataRootInput', $true)) | Select-Object -First 1
            $notice = @($form.Controls.Find('ctrlCcvTraySettingsNotice', $true)) | Select-Object -First 1
            $save = @($form.Controls.Find('ctrlCcvTraySettingsSaveButton', $true)) | Select-Object -First 1
            Assert-CtrlCcvTrayUi ($null -ne $hostAlias -and $null -ne $remoteDir -and $null -ne $dataRoot) 'Settings window did not construct its editable connection and advanced fields.'
            Assert-CtrlCcvTrayUi ($null -ne $notice -and $notice.Text -match 'CTRL_CCV_HOST_ALIAS') 'Settings window did not disclose the active environment override.'
            Assert-CtrlCcvTrayUi ($null -ne $save -and $save.Enabled) 'Settings window did not construct an enabled Save and restart action.'
            $hostAlias.Text = 'saved-host'
            $save.PerformClick()
        }
        catch {
            $script:trayUiSettingsProbeFailure = $_.Exception.Message
            if (-not $form.IsDisposed) { $form.Close() }
        }
    })
    $result = $false
    try {
        $timer.Start()
        $result = Show-CtrlCcvTraySettingsWindow -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CtrlCcvTrayUi $script:trayUiSettingsDialogSeen 'Settings window was not shown before the UI probe deadline.'
    Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiSettingsProbeFailure)) "Settings window probe failed: $($script:trayUiSettingsProbeFailure)"
    return [bool]$result
}

$settingsSaved = Invoke-CtrlCcvTraySettingsDialogProbe
Assert-CtrlCcvTrayUi $settingsSaved 'Settings window did not report a successful save and restart.'
Assert-CtrlCcvTrayUi ($script:trayUiAction -eq 'restart') 'Settings window did not restart the owned service after saving.'
Assert-CtrlCcvTrayUi ($null -ne $script:trayUiSavedConfig -and $script:trayUiSavedConfig.Count -eq 13) 'Settings window did not submit exactly the persisted configuration fields.'
Assert-CtrlCcvTrayUi ($script:trayUiSavedConfig.HostAlias -eq 'saved-host') 'Settings window did not submit the edited SSH computer name.'
Assert-CtrlCcvTrayUi ($script:trayUiSavedConfig.RemoteDir -eq 'clipboard-images') 'Settings window unexpectedly changed an untouched remote folder.'

$script:trayUiRestartFails = $true
$script:trayUiSettingsRestartFailureSeen = $false
$script:trayUiSettingsRestartFailureProbeFailure = ''
$settingsRestartFailureDeadline = (Get-Date).AddSeconds(6)
$settingsRestartFailureTimer = New-Object System.Windows.Forms.Timer
$settingsRestartFailureTimer.Interval = 100
$settingsRestartFailureTimer.Add_Tick({
    $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'ctrlCcvTraySettingsWindow' }) | Select-Object -First 1
    if (-not $form) { return }
    try {
        if ((Get-Date) -gt $settingsRestartFailureDeadline) { throw 'Restart-failure Settings probe exceeded its six-second deadline.' }
        $save = @($form.Controls.Find('ctrlCcvTraySettingsSaveButton', $true)) | Select-Object -First 1
        $close = @($form.Controls.Find('ctrlCcvTraySettingsCloseButton', $true)) | Select-Object -First 1
        $feedback = @($form.Controls.Find('ctrlCcvTraySettingsFeedback', $true)) | Select-Object -First 1
        Assert-CtrlCcvTrayUi ($null -ne $save -and $null -ne $close -and $null -ne $feedback) 'Settings restart-failure probe could not find its controls.'
        if (-not $script:trayUiSettingsRestartFailureSeen) {
            $script:trayUiSettingsRestartFailureSeen = $true
            $save.PerformClick()
            return
        }
        Assert-CtrlCcvTrayUi ($feedback.Text -match 'Settings were saved' -and $close.Text -eq 'Close') 'Settings did not clearly report a saved configuration after restart failed.'
        $form.Close()
    }
    catch {
        $script:trayUiSettingsRestartFailureProbeFailure = $_.Exception.Message
        if (-not $form.IsDisposed) { $form.Close() }
    }
})
$settingsSavedDespiteRestartFailure = $false
try {
    $settingsRestartFailureTimer.Start()
    $settingsSavedDespiteRestartFailure = Show-CtrlCcvTraySettingsWindow -TestMode
}
finally {
    $settingsRestartFailureTimer.Stop()
    $settingsRestartFailureTimer.Dispose()
    $script:trayUiRestartFails = $false
}
Assert-CtrlCcvTrayUi $script:trayUiSettingsRestartFailureSeen 'Settings restart-failure dialog was not shown before the UI probe deadline.'
Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiSettingsRestartFailureProbeFailure)) "Settings restart-failure probe failed: $($script:trayUiSettingsRestartFailureProbeFailure)"
Assert-CtrlCcvTrayUi $settingsSavedDespiteRestartFailure 'A saved configuration was not reported to the caller after the service restart failed.'

$script:trayUiActivityReadCount = 0
function Get-CtrlCcvConfig { return [pscustomobject]@{ LogFile = (Join-Path $env:TEMP 'ctrl-ccv-tray-ui-activity\watch.log') } }
function Get-CtrlCcvTrayRecentActivityText {
    param([Parameter(Mandatory)]$Config)
    $script:trayUiActivityReadCount++
    return 'local activity record: Bearer [REDACTED]'
}

function Invoke-CtrlCcvTrayRecentActivityDialogProbe {
    $script:trayUiActivityDialogSeen = $false
    $script:trayUiActivityProbeFailure = ''
    $deadline = (Get-Date).AddSeconds(6)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'ctrlCcvTrayRecentActivityWindow' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) { throw 'Recent-activity window probe exceeded its six-second deadline.' }
            if ($script:trayUiActivityDialogSeen) { return }
            $script:trayUiActivityDialogSeen = $true
            $activity = @($form.Controls.Find('ctrlCcvTrayRecentActivityTextBox', $true)) | Select-Object -First 1
            $refresh = @($form.Controls.Find('ctrlCcvTrayRecentActivityRefreshButton', $true)) | Select-Object -First 1
            $close = @($form.Controls.Find('ctrlCcvTrayRecentActivityCloseButton', $true)) | Select-Object -First 1
            Assert-CtrlCcvTrayUi ($null -ne $activity -and $activity.ReadOnly -and $activity.Text -match 'Bearer \[REDACTED\]') 'Recent-activity window did not display its protected read-only activity text.'
            Assert-CtrlCcvTrayUi ($null -ne $refresh -and $null -ne $close) 'Recent-activity window did not construct Refresh and Close controls.'
            $refresh.PerformClick()
            $form.Close()
        }
        catch {
            $script:trayUiActivityProbeFailure = $_.Exception.Message
            if (-not $form.IsDisposed) { $form.Close() }
        }
    })
    try {
        $timer.Start()
        Show-CtrlCcvTrayRecentActivityWindow -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CtrlCcvTrayUi $script:trayUiActivityDialogSeen 'Recent-activity window was not shown before the UI probe deadline.'
    Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiActivityProbeFailure)) "Recent-activity window probe failed: $($script:trayUiActivityProbeFailure)"
}

Invoke-CtrlCcvTrayRecentActivityDialogProbe
Assert-CtrlCcvTrayUi ($script:trayUiActivityReadCount -ge 2) 'Recent-activity Refresh did not reload the bounded activity source.'

$script:trayUiTmuxChecks = @()
$script:trayUiTmuxApplies = @()
function Get-CtrlCcvRemoteTmuxState {
    param([string]$Table, [string]$Key, [string]$SecondaryTable, [string]$SecondaryKey)
    $script:trayUiTmuxChecks += [pscustomobject]@{ Table = $Table; Key = $Key; SecondaryTable = $SecondaryTable; SecondaryKey = $SecondaryKey }
    return [pscustomobject]@{
        Ok = $true
        Connection = 'Connected'
        Tmux = 'Installed'
        Plugin = 'Installed'
        Server = 'Running'
        Table = $Table
        Key = $Key
        SecondaryTable = $SecondaryTable
        SecondaryKey = $SecondaryKey
        Binding = 'Available'
        SecondaryBinding = if ($SecondaryTable) { 'Available' } else { 'NotSelected' }
        Override = 'None'
        Detail = ''
    }
}
function Apply-CtrlCcvRemoteTmuxBinding {
    param([string]$Table, [string]$Key, [string]$SecondaryTable, [string]$SecondaryKey)
    $script:trayUiTmuxApplies += [pscustomobject]@{ Table = $Table; Key = $Key; SecondaryTable = $SecondaryTable; SecondaryKey = $SecondaryKey }
    $state = [pscustomobject]@{
        Ok = $true
        Connection = 'Connected'
        Tmux = 'Installed'
        Plugin = 'Installed'
        Server = 'Running'
        Table = $Table
        Key = $Key
        SecondaryTable = $SecondaryTable
        SecondaryKey = $SecondaryKey
        Binding = 'Managed'
        SecondaryBinding = if ($SecondaryTable) { 'Managed' } else { 'NotSelected' }
        Override = 'None'
        Detail = ''
    }
    return [pscustomobject]@{
        Ok = $true
        Reason = 'applied'
        Detail = 'The ctrl-ccv binding is active in the default tmux server.'
        Applied = $true
        NeedsStartupLine = $true
        State = $state
    }
}

function Invoke-CtrlCcvTrayTmuxDialogProbe {
    $script:trayUiTmuxDialogSeen = $false
    $script:trayUiTmuxProbeFailure = ''
    $script:trayUiTmuxChecks = @()
    $script:trayUiTmuxApplies = @()
    $script:trayUiAction = ''
    $deadline = (Get-Date).AddSeconds(6)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'ctrlCcvTrayTmuxSetupWindow' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) { throw 'Tmux path-insertion window probe exceeded its six-second deadline.' }
            if ($script:trayUiTmuxDialogSeen) { return }
            $script:trayUiTmuxDialogSeen = $true
            $crossPlatform = @($form.Controls.Find('ctrlCcvTrayTmuxCrossPlatformRadio', $true)) | Select-Object -First 1
            $crossPlatformHint = @($form.Controls.Find('ctrlCcvTrayTmuxCrossPlatformHint', $true)) | Select-Object -First 1
            $recommended = @($form.Controls.Find('ctrlCcvTrayTmuxRecommendedRadio', $true)) | Select-Object -First 1
            $custom = @($form.Controls.Find('ctrlCcvTrayTmuxCustomRadio', $true)) | Select-Object -First 1
            $raw = @($form.Controls.Find('ctrlCcvTrayTmuxRawRadio', $true)) | Select-Object -First 1
            $customKey = @($form.Controls.Find('ctrlCcvTrayTmuxCustomKeyInput', $true)) | Select-Object -First 1
            $warning = @($form.Controls.Find('ctrlCcvTrayTmuxRawWarning', $true)) | Select-Object -First 1
            $status = @($form.Controls.Find('ctrlCcvTrayTmuxStatusText', $true)) | Select-Object -First 1
            $startup = @($form.Controls.Find('ctrlCcvTrayTmuxStartupLine', $true)) | Select-Object -First 1
            $check = @($form.Controls.Find('ctrlCcvTrayTmuxCheckButton', $true)) | Select-Object -First 1
            $apply = @($form.Controls.Find('ctrlCcvTrayTmuxApplyButton', $true)) | Select-Object -First 1
            Assert-CtrlCcvTrayUi ($null -ne $crossPlatform -and $null -ne $crossPlatformHint -and $null -ne $recommended -and $null -ne $custom -and $null -ne $raw -and $null -ne $customKey) 'Tmux path-insertion window did not construct all binding choices.'
            Assert-CtrlCcvTrayUi ($crossPlatform.Checked -and $crossPlatformHint.Visible -and $crossPlatformHint.Text -match 'every connected client' -and $crossPlatformHint.Text -match 'Alt-V' -and -not $customKey.Enabled) 'Tmux path-insertion window did not default to its paired Windows Alt-V and macOS Ctrl-V choice.'
            Assert-CtrlCcvTrayUi ($null -ne $warning -and $null -ne $status -and $status.ReadOnly) 'Tmux path-insertion window did not construct its protected warning and status controls.'
            Assert-CtrlCcvTrayUi ($null -ne $startup -and $startup.ReadOnly -and $startup.Text -eq 'run-shell ~/.local/lib/ctrl-ccv/tmux/ctrl-ccv.tmux') 'Tmux path-insertion window did not display the user-owned startup line.'
            Assert-CtrlCcvTrayUi ($null -ne $check -and $null -ne $apply -and $check.Enabled -and $apply.Enabled) 'Tmux path-insertion window did not expose enabled explicit Check and Apply actions.'
            $check.PerformClick()
            Assert-CtrlCcvTrayUi ($script:trayUiTmuxChecks.Count -eq 1 -and $script:trayUiTmuxChecks[0].Table -eq 'root' -and $script:trayUiTmuxChecks[0].Key -eq 'C-v' -and $script:trayUiTmuxChecks[0].SecondaryTable -eq 'root' -and $script:trayUiTmuxChecks[0].SecondaryKey -eq 'M-v') 'Tmux Check did not use the paired Windows Alt-V and macOS Ctrl-V binding.'
            Assert-CtrlCcvTrayUi ($status.Text -match 'Connected' -and $status.Text -match 'Available') 'Tmux Check did not render the safe remote status.'
            $apply.PerformClick()
            Assert-CtrlCcvTrayUi ($script:trayUiTmuxApplies.Count -eq 1 -and $script:trayUiTmuxApplies[0].Table -eq 'root' -and $script:trayUiTmuxApplies[0].Key -eq 'C-v' -and $script:trayUiTmuxApplies[0].SecondaryTable -eq 'root' -and $script:trayUiTmuxApplies[0].SecondaryKey -eq 'M-v') 'Tmux Apply did not send both paired binding arguments.'
            Assert-CtrlCcvTrayUi ($status.Text -match 'Managed') 'Tmux Apply did not render the paired applied binding state.'
            $raw.Checked = $true
            Assert-CtrlCcvTrayUi ($raw.Checked -and $warning.Visible) 'Tmux path-insertion window did not disclose the raw Ctrl-V warning.'
        }
        catch {
            $script:trayUiTmuxProbeFailure = $_.Exception.Message
        }
        finally {
            if (-not $form.IsDisposed) { $form.Close() }
        }
    })
    $result = $false
    try {
        $timer.Start()
        $result = Show-CtrlCcvTrayTmuxSetupWindow -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CtrlCcvTrayUi $script:trayUiTmuxDialogSeen 'Tmux path-insertion window was not shown before the UI probe deadline.'
    Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiTmuxProbeFailure)) "Tmux path-insertion window probe failed: $($script:trayUiTmuxProbeFailure)"
    return [bool]$result
}

$tmuxApplied = Invoke-CtrlCcvTrayTmuxDialogProbe
Assert-CtrlCcvTrayUi $tmuxApplied 'Tmux path-insertion window did not report a successful explicit apply.'
Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiAction)) 'Tmux path-insertion window unexpectedly restarted or changed the local uploader service.'

# The production path launches remote SSH/SCP work in a job and lets the
# WinForms timer keep processing messages. Replace only the job factory with a
# harmless local job; this verifies the dialog becomes busy immediately,
# receives its result later, and leaves no job behind without using a network.
$script:trayUiTmuxAsyncStarts = @()
$script:trayUiTmuxAsyncJobIds = @()
function Start-CtrlCcvTrayTmuxRemoteJob {
    param([string]$Operation, [string]$Table, [string]$Key, [string]$SecondaryTable, [string]$SecondaryKey)

    $script:trayUiTmuxAsyncStarts += [pscustomobject]@{ Operation = $Operation; Table = $Table; Key = $Key; SecondaryTable = $SecondaryTable; SecondaryKey = $SecondaryKey }
    $job = Start-Job -ScriptBlock {
        param([string]$InnerOperation, [string]$InnerTable, [string]$InnerKey, [string]$InnerSecondaryTable, [string]$InnerSecondaryKey)
        Start-Sleep -Milliseconds 300
        return [pscustomobject]@{
            Ok = $true; Connection = 'Connected'; Tmux = 'Installed'; Plugin = 'Installed'; Server = 'Running'
            Table = $InnerTable; Key = $InnerKey; SecondaryTable = $InnerSecondaryTable; SecondaryKey = $InnerSecondaryKey
            Binding = 'Available'; SecondaryBinding = if ($InnerSecondaryTable) { 'Available' } else { 'NotSelected' }; Override = 'None'; Detail = ''
        }
    } -ArgumentList @($Operation, $Table, $Key, $SecondaryTable, $SecondaryKey)
    $script:trayUiTmuxAsyncJobIds += $job.Id
    return $job
}

function Invoke-CtrlCcvTrayTmuxAsyncDialogProbe {
    $script:trayUiTmuxAsyncDialogSeen = $false
    $script:trayUiTmuxAsyncProbeFailure = ''
    $script:trayUiTmuxAsyncStarts = @()
    $script:trayUiTmuxAsyncJobIds = @()
    $script:trayUiTmuxAsyncStep = 0
    $deadline = (Get-Date).AddSeconds(10)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 75
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'ctrlCcvTrayTmuxSetupWindow' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) { throw 'Async tmux path-insertion window probe exceeded its ten-second deadline.' }
            $script:trayUiTmuxAsyncDialogSeen = $true
            $check = @($form.Controls.Find('ctrlCcvTrayTmuxCheckButton', $true)) | Select-Object -First 1
            $apply = @($form.Controls.Find('ctrlCcvTrayTmuxApplyButton', $true)) | Select-Object -First 1
            $status = @($form.Controls.Find('ctrlCcvTrayTmuxStatusText', $true)) | Select-Object -First 1
            Assert-CtrlCcvTrayUi ($null -ne $check -and $null -ne $apply -and $null -ne $status) 'Async tmux path-insertion window did not construct its controls.'
            if ($script:trayUiTmuxAsyncStep -eq 0) {
                $check.PerformClick()
                Assert-CtrlCcvTrayUi (-not $check.Enabled -and -not $apply.Enabled) 'Async tmux Check did not return to the UI loop in a busy state.'
                $script:trayUiTmuxAsyncStep = 1
                return
            }
            if ($script:trayUiTmuxAsyncStep -eq 1 -and $status.Text -match 'Connected' -and $status.Text -match 'Available') {
                Assert-CtrlCcvTrayUi ($check.Enabled -and $apply.Enabled) 'Async tmux Check did not restore controls after its background job completed.'
                $script:trayUiTmuxAsyncStep = 2
                $form.Close()
            }
        }
        catch {
            $script:trayUiTmuxAsyncProbeFailure = $_.Exception.Message
            if (-not $form.IsDisposed) { $form.Close() }
        }
    })
    try {
        $timer.Start()
        [void](Show-CtrlCcvTrayTmuxSetupWindow -TestMode -UseAsyncWorker)
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CtrlCcvTrayUi $script:trayUiTmuxAsyncDialogSeen 'Async tmux path-insertion window was not shown before the UI probe deadline.'
    Assert-CtrlCcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiTmuxAsyncProbeFailure)) "Async tmux path-insertion window probe failed: $($script:trayUiTmuxAsyncProbeFailure)"
    Assert-CtrlCcvTrayUi ($script:trayUiTmuxAsyncStep -eq 2) 'Async tmux Check did not render its completed result before the dialog closed.'
}

Invoke-CtrlCcvTrayTmuxAsyncDialogProbe
Assert-CtrlCcvTrayUi ($script:trayUiTmuxAsyncStarts.Count -eq 1 -and $script:trayUiTmuxAsyncStarts[0].Operation -eq 'Check' -and $script:trayUiTmuxAsyncStarts[0].Table -eq 'root' -and $script:trayUiTmuxAsyncStarts[0].Key -eq 'C-v' -and $script:trayUiTmuxAsyncStarts[0].SecondaryTable -eq 'root' -and $script:trayUiTmuxAsyncStarts[0].SecondaryKey -eq 'M-v') 'Async tmux Check did not start both paired bindings in a background job.'
foreach ($jobId in @($script:trayUiTmuxAsyncJobIds)) {
    Assert-CtrlCcvTrayUi ($null -eq (Get-Job -Id $jobId -ErrorAction SilentlyContinue)) 'Async tmux dialog left its completed background job behind.'
}

Write-Host 'PASS: STA WinForms status dialog constructed with synthetic state; upload/start buttons dispatched only to stubs; error state disabled upload; a saved Settings change invalidated a prior SSH check until it was retested; Settings saved the edited SSH computer name through the persistence helper and restarted the service; recent activity rendered protected text and refreshed; tmux path insertion checked and applied only explicit remote binding choices without restarting the local uploader; its production job path stays responsive and removes completed jobs.'
