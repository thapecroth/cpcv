# One-shot: upload clipboard image without replacing it with a remote path.
param([switch]$Silent)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "cpcv-core.ps1")

function Show-Toast {
    param([string]$Title, [string]$Body)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Body
        $notify.ShowBalloonTip(2500)
        Start-Sleep -Milliseconds 400
        $notify.Dispose()
    }
    catch { }
}

$result = Publish-ClipboardImage -Force
if (-not $result.Ok) {
    $msg = if ($result.Reason -eq "no-image") { "No image on clipboard. Screenshot/copy an image first." } else { "cpcv failed: $($result.Reason)" }
    if ($result.Reason -eq "configuration-invalid" -and $result.Detail) { $msg = "cpcv configuration error: $($result.Detail)" }
    if (-not $Silent) { Show-Toast "cpcv" $msg; Write-Host $msg }
    exit 1
}
if (-not $Silent) { Show-Toast "cpcv" "Image uploaded; clipboard image preserved."; Write-Host $result.RemotePath }
exit 0
