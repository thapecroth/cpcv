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

Write-Host 'PASS: STA WinForms status dialog constructed with synthetic state; upload/start buttons dispatched only to stubs; error state disabled upload.'
