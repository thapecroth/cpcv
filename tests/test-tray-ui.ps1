# Exercises the real WinForms status dialog on an STA thread, with every
# side-effecting action stubbed.  It does not create a NotifyIcon, inspect
# processes, access the clipboard, start services, or touch real state files.
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'test-tray-ui.ps1 must be launched with powershell.exe -STA.'
}

function Assert-CpcvTrayUi([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'cpcv-tray.ps1') -NoRun
Add-Type -AssemblyName System.Windows.Forms

$script:trayUiAction = ''
function Start-CpcvTrayUpload { $script:trayUiAction = 'upload' }
function Start-CpcvTrayGuardian { $script:trayUiAction = 'start'; return $true }
function Restart-CpcvTrayService { $script:trayUiAction = 'restart' }
function Show-CpcvTrayError { param([string]$Message) throw "Unexpected tray UI error: $Message" }
function Get-CpcvTrayState { return $script:trayUiCurrentState }

function Invoke-CpcvTrayDialogProbe {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][ValidateSet('upload', 'start', 'close')][string]$Action,
        [switch]$ExpectUploadDisabled
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
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cpcvTrayStatusDashboard' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) {
                throw 'Status dashboard probe exceeded its six-second deadline.'
            }
            if ($script:trayUiProbeCompleted) { return }

            $script:trayUiDialogSeen = $true
            $script:trayUiProbeCompleted = $true
            $upload = @($form.Controls.Find('cpcvTrayUploadButton', $true)) | Select-Object -First 1
            $service = @($form.Controls.Find('cpcvTrayServiceButton', $true)) | Select-Object -First 1
            $banner = @($form.Controls.Find('cpcvTrayStatusBanner', $true)) | Select-Object -First 1
            $logo = @($form.Controls.Find('cpcvTrayBrandLogo', $true)) | Select-Object -First 1
            Assert-CpcvTrayUi ($null -ne $upload) 'Status dashboard did not construct the one-shot upload button.'
            Assert-CpcvTrayUi ($null -ne $service) 'Status dashboard did not construct the service action button.'
            Assert-CpcvTrayUi ($null -ne $banner) 'Status dashboard did not construct its health banner.'
            Assert-CpcvTrayUi ($null -ne $logo -and $null -ne $logo.Image) 'Status dashboard did not construct the branded logo.'
            if ($ExpectUploadDisabled) {
                Assert-CpcvTrayUi (-not $upload.Enabled) 'Error-state dashboard left the upload action enabled.'
                return
            }
            Assert-CpcvTrayUi $upload.Enabled 'Non-error dashboard unexpectedly disabled one-shot upload.'
            switch ($Action) {
                'upload' { $upload.PerformClick() }
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
        Show-CpcvTrayStatusWindow -State $State -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CpcvTrayUi $script:trayUiDialogSeen 'Status dashboard was not shown before the UI probe deadline.'
    Assert-CpcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiProbeFailure)) "Status dashboard probe failed: $($script:trayUiProbeFailure)"
}

$baseState = [pscustomobject]@{
    Level = 'Healthy'
    Summary = 'cpcv is running'
    Detail = 'idle failures=0'
    Config = [pscustomobject]@{ DataRoot = (Join-Path $env:TEMP 'cpcv-tray-ui-test') }
    Guardians = @([pscustomobject]@{ ProcessId = 101 })
    Watchers = @([pscustomobject]@{ ProcessId = 202 })
    GuardianProbeAvailable = $true
    WatcherProbeAvailable = $true
    Heartbeat = [pscustomobject]@{ ProcessId = 202; Status = 'idle failures=0' }
    HeartbeatAgeSeconds = 1.2
    LatestPath = '/home/tester/clipboard-images/latest.png'
    LatestUploadAt = [DateTimeOffset]::UtcNow
    LatestUploadAgeSeconds = 1.2
}

Invoke-CpcvTrayDialogProbe -State $baseState -Action upload
Assert-CpcvTrayUi ($script:trayUiAction -eq 'upload') 'Upload button did not invoke its protected action handler.'

$stoppedState = $baseState.PSObject.Copy()
$stoppedState.Level = 'Stopped'
$stoppedState.Summary = 'The cpcv service is stopped'
$stoppedState.Guardians = @()
$stoppedState.Watchers = @()
$stoppedState.Heartbeat = $null
$stoppedState.HeartbeatAgeSeconds = $null
Invoke-CpcvTrayDialogProbe -State $stoppedState -Action start
Assert-CpcvTrayUi ($script:trayUiAction -eq 'start') 'Start-service button did not invoke its protected action handler.'

$errorState = $baseState.PSObject.Copy()
$errorState.Level = 'Error'
$errorState.Summary = 'Configuration needs attention'
Invoke-CpcvTrayDialogProbe -State $errorState -Action close -ExpectUploadDisabled

$script:trayUiEditableConfig = [ordered]@{
    HostAlias = 'old-host'
    RemoteDir = 'clipboard-images'
    RemoteHome = '/home/tester'
    DataRoot = (Join-Path $env:TEMP 'cpcv-tray-ui-settings')
    CommandTimeoutSeconds = 35
    MaxCommandOutputBytes = 65536
    PollIntervalSeconds = 2
    WatchdogCheckSeconds = 15
    WatchdogStaleSeconds = 120
    MaxLogBytes = 1048576
    MaxCacheFiles = 200
    MaxCacheBytes = 268435456
    MaxImageBytes = 52428800
    Path = (Join-Path $env:TEMP 'cpcv-tray-ui-settings\config.psd1')
    Exists = $true
    HasEnvironmentOverrides = $true
    EnvironmentOverrides = @('CPCV_HOST_ALIAS')
    LoadError = ''
}
$script:trayUiSavedConfig = $null
function Get-CpcvEditableConfig { return $script:trayUiEditableConfig }
function Save-CpcvConfig {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $copy = [ordered]@{}
    foreach ($key in $Config.Keys) { $copy[[string]$key] = $Config[$key] }
    $script:trayUiSavedConfig = $copy
    return $script:trayUiEditableConfig
}

function Invoke-CpcvTraySettingsDialogProbe {
    $script:trayUiSettingsDialogSeen = $false
    $script:trayUiSettingsProbeFailure = ''
    $script:trayUiAction = ''
    $deadline = (Get-Date).AddSeconds(6)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cpcvTraySettingsWindow' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) { throw 'Settings window probe exceeded its six-second deadline.' }
            if ($script:trayUiSettingsDialogSeen) { return }
            $script:trayUiSettingsDialogSeen = $true
            $hostAlias = @($form.Controls.Find('cpcvTraySettingsHostAliasInput', $true)) | Select-Object -First 1
            $remoteDir = @($form.Controls.Find('cpcvTraySettingsRemoteDirInput', $true)) | Select-Object -First 1
            $dataRoot = @($form.Controls.Find('cpcvTraySettingsDataRootInput', $true)) | Select-Object -First 1
            $notice = @($form.Controls.Find('cpcvTraySettingsNotice', $true)) | Select-Object -First 1
            $save = @($form.Controls.Find('cpcvTraySettingsSaveButton', $true)) | Select-Object -First 1
            Assert-CpcvTrayUi ($null -ne $hostAlias -and $null -ne $remoteDir -and $null -ne $dataRoot) 'Settings window did not construct its editable connection and advanced fields.'
            Assert-CpcvTrayUi ($null -ne $notice -and $notice.Text -match 'CPCV_HOST_ALIAS') 'Settings window did not disclose the active environment override.'
            Assert-CpcvTrayUi ($null -ne $save -and $save.Enabled) 'Settings window did not construct an enabled Save and restart action.'
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
        $result = Show-CpcvTraySettingsWindow -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CpcvTrayUi $script:trayUiSettingsDialogSeen 'Settings window was not shown before the UI probe deadline.'
    Assert-CpcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiSettingsProbeFailure)) "Settings window probe failed: $($script:trayUiSettingsProbeFailure)"
    return [bool]$result
}

$settingsSaved = Invoke-CpcvTraySettingsDialogProbe
Assert-CpcvTrayUi $settingsSaved 'Settings window did not report a successful save and restart.'
Assert-CpcvTrayUi ($script:trayUiAction -eq 'restart') 'Settings window did not restart the owned service after saving.'
Assert-CpcvTrayUi ($null -ne $script:trayUiSavedConfig -and $script:trayUiSavedConfig.Count -eq 13) 'Settings window did not submit exactly the persisted configuration fields.'
Assert-CpcvTrayUi ($script:trayUiSavedConfig.HostAlias -eq 'saved-host') 'Settings window did not submit the edited SSH computer name.'
Assert-CpcvTrayUi ($script:trayUiSavedConfig.RemoteDir -eq 'clipboard-images') 'Settings window unexpectedly changed an untouched remote folder.'

$script:trayUiActivityReadCount = 0
function Get-CpcvConfig { return [pscustomobject]@{ LogFile = (Join-Path $env:TEMP 'cpcv-tray-ui-activity\watch.log') } }
function Get-CpcvTrayRecentActivityText {
    param([Parameter(Mandatory)]$Config)
    $script:trayUiActivityReadCount++
    return 'local activity record: Bearer [REDACTED]'
}

function Invoke-CpcvTrayRecentActivityDialogProbe {
    $script:trayUiActivityDialogSeen = $false
    $script:trayUiActivityProbeFailure = ''
    $deadline = (Get-Date).AddSeconds(6)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 100
    $timer.Add_Tick({
        $form = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Name -eq 'cpcvTrayRecentActivityWindow' }) | Select-Object -First 1
        if (-not $form) { return }
        try {
            if ((Get-Date) -gt $deadline) { throw 'Recent-activity window probe exceeded its six-second deadline.' }
            if ($script:trayUiActivityDialogSeen) { return }
            $script:trayUiActivityDialogSeen = $true
            $activity = @($form.Controls.Find('cpcvTrayRecentActivityTextBox', $true)) | Select-Object -First 1
            $refresh = @($form.Controls.Find('cpcvTrayRecentActivityRefreshButton', $true)) | Select-Object -First 1
            $close = @($form.Controls.Find('cpcvTrayRecentActivityCloseButton', $true)) | Select-Object -First 1
            Assert-CpcvTrayUi ($null -ne $activity -and $activity.ReadOnly -and $activity.Text -match 'Bearer \[REDACTED\]') 'Recent-activity window did not display its protected read-only activity text.'
            Assert-CpcvTrayUi ($null -ne $refresh -and $null -ne $close) 'Recent-activity window did not construct Refresh and Close controls.'
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
        Show-CpcvTrayRecentActivityWindow -TestMode
    }
    finally {
        $timer.Stop()
        $timer.Dispose()
    }
    Assert-CpcvTrayUi $script:trayUiActivityDialogSeen 'Recent-activity window was not shown before the UI probe deadline.'
    Assert-CpcvTrayUi ([string]::IsNullOrWhiteSpace($script:trayUiActivityProbeFailure)) "Recent-activity window probe failed: $($script:trayUiActivityProbeFailure)"
}

Invoke-CpcvTrayRecentActivityDialogProbe
Assert-CpcvTrayUi ($script:trayUiActivityReadCount -ge 2) 'Recent-activity Refresh did not reload the bounded activity source.'

Write-Host 'PASS: STA WinForms status dialog constructed with synthetic state; upload/start buttons dispatched only to stubs; error state disabled upload; Settings saved the edited SSH computer name through the persistence helper and restarted the service; recent activity rendered protected text and refreshed.'
