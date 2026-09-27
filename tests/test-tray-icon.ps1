# Exercises the real WinForms notification-area API with the checked-in ICO.
# It runs for only the time needed to create and dispose a private test icon;
# it does not start the cpcv tray loop, inspect the uploader, clipboard,
# SSH, or user Startup integration.
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'test-tray-icon.ps1 must be launched with powershell.exe -STA.'
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'cpcv-tray.ps1') -NoRun
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$selection = Get-CpcvTrayIcon
$notify = $null
$statusIconCache = @{}
try {
    if ($selection.IsFallback -or -not $selection.OwnsIcon) {
        throw "The checked-in branded ICO was not selected for the WinForms tray probe."
    }
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = $selection.Icon
    $notify.Text = 'cpcv icon verification'
    $notify.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $notify.Visible) { throw 'WinForms did not accept the branded tray icon.' }

    foreach ($level in @('Warning', 'Error', 'Stopped', 'Unknown')) {
        $statusIcon = Get-CpcvTrayStatusIcon -BaseIcon $selection.Icon -Level $level -Cache $statusIconCache
        if ($null -eq $statusIcon -or $statusIcon.Handle -eq [IntPtr]::Zero -or [object]::ReferenceEquals($statusIcon, $selection.Icon)) {
            throw "Tray status icon '$level' was not created."
        }
        if ($level -eq 'Warning' -and -not [object]::ReferenceEquals($statusIcon, (Get-CpcvTrayStatusIcon -BaseIcon $selection.Icon -Level $level -Cache $statusIconCache))) {
            throw 'Tray status icon cache did not retain the warning icon.'
        }
        $notify.Icon = $statusIcon
        [System.Windows.Forms.Application]::DoEvents()
        if (-not $notify.Visible) { throw "WinForms did not retain the '$level' tray status icon." }
    }
    $notify.Icon = $selection.Icon
}
finally {
    if ($notify) {
        $notify.Visible = $false
        $notify.Dispose()
    }
    foreach ($statusIcon in @($statusIconCache.Values)) {
        if ($statusIcon) { $statusIcon.Dispose() }
    }
    if ($selection -and $selection.OwnsIcon -and $selection.Icon) { $selection.Icon.Dispose() }
}

Write-Host 'PASS: branded and dynamically badged ICOs were accepted by the real STA WinForms NotifyIcon API and disposed cleanly.'
